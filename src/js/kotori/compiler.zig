const std = @import("std");
const parser_mod = @import("parser.zig");
const ast_mod = @import("ast.zig");
const bytecode_mod = @import("bytecode.zig");
const value_mod = @import("value.zig");
const object_mod = @import("object.zig");
const string_pool_mod = @import("string_pool.zig");

const Parser = parser_mod.Parser;
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const null_node = ast_mod.null_node;
const BinaryOp = ast_mod.BinaryOp;
const UnaryOp = ast_mod.UnaryOp;
const Bytecode = bytecode_mod.Bytecode;
const OpCode = bytecode_mod.OpCode;
const JsValue = value_mod.JsValue;
const FunctionObj = object_mod.FunctionObj;
const UpvalueDef = object_mod.UpvalueDef;
const StringId = string_pool_mod.StringId;

const Local = struct {
    name: StringId,
    depth: i32, // -1 = uninitialized
    is_captured: bool,
};

const UpvalueInfo = struct {
    index: u16,
    is_local: bool,
};

fn FixedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        fn append(self: *@This(), item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        fn pop(self: *@This()) T {
            self.len -= 1;
            return self.buffer[self.len];
        }
    };
}

const LoopContext = struct {
    break_jumps: [32]u32 = undefined,
    break_count: u8 = 0,
    continue_jumps: [32]u32 = undefined,
    continue_count: u8 = 0,
    scope_depth: i32,
    is_switch: bool = false,
};

const ClassField = struct {
    name: StringId,
    init: NodeIndex,
};

const FunctionScope = struct {
    locals: FixedArray(Local, 4096) = .{},
    upvalues: FixedArray(UpvalueInfo, 512) = .{},
    scope_depth: i32 = 0,
    bc: Bytecode = Bytecode.init(),
    parent: ?*FunctionScope = null,
    is_script: bool = true, // true for top-level, false for functions
    is_async: bool = false, // true for async functions
    loop_stack: [16]LoopContext = undefined,
    loop_depth: u8 = 0,
};

pub const Compiler = struct {
    parser: Parser,
    allocator: std.mem.Allocator,
    current: FunctionScope,
    /// Compiled FunctionObj constants (heap-allocated, owned by caller via Bytecode constants)
    functions: std.ArrayListUnmanaged(*object_mod.JsObject) = .empty,
    /// Instance field initializers for current class constructor
    pending_class_fields: ?[]const ClassField = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Compiler {
        return .{
            .parser = Parser.init(allocator, source),
            .allocator = allocator,
            .current = .{},
        };
    }

    /// Init with a shared StringPool (pool outlives the compiler).
    pub fn initWithPool(allocator: std.mem.Allocator, source: []const u8, pool: *string_pool_mod.StringPool) Compiler {
        return .{
            .parser = Parser.initWithPool(allocator, source, pool),
            .allocator = allocator,
            .current = .{},
        };
    }

    pub fn compile(self: *Compiler) !Bytecode {
        const program_idx = try self.parser.parse();
        try self.compileNode(program_idx);
        try self.emitOp(.halt);
        self.current.bc.local_count = @intCast(self.current.locals.len);
        const result = self.current.bc;
        self.current.bc = Bytecode.init();
        return result;
    }

    pub fn deinit(self: *Compiler) void {
        self.parser.deinit();
        self.current.bc.deinit(self.allocator);
        for (self.functions.items) |obj| {
            obj.deinit(self.allocator);
            self.allocator.destroy(obj);
        }
        self.functions.deinit(self.allocator);
    }

    const CompileError = error{ OutOfMemory, Overflow, ParseError };

    // ── Scope management ─────────────────────────────────────────────

    fn beginScope(self: *Compiler) void {
        self.current.scope_depth += 1;
    }

    fn endScope(self: *Compiler) CompileError!void {
        self.current.scope_depth -= 1;
        // Pop locals that go out of scope
        while (self.current.locals.len > 0) {
            const local = self.current.locals.buffer[self.current.locals.len - 1];
            if (local.depth <= self.current.scope_depth) break;
            if (local.is_captured) {
                try self.emitOpU16(.close_upvalue, @intCast(self.current.locals.len - 1));
            } else {
                try self.emitOp(.pop);
            }
            _ = self.current.locals.pop();
        }
    }

    fn addLocal(self: *Compiler, name: StringId) !u16 {
        const idx: u16 = @intCast(self.current.locals.len);
        try self.current.locals.append(.{
            .name = name,
            .depth = self.current.scope_depth,
            .is_captured = false,
        });
        return idx;
    }

    fn resolveLocal(_: *Compiler, scope: *FunctionScope, name: StringId) ?u16 {
        var i: usize = scope.locals.len;
        while (i > 0) {
            i -= 1;
            if (scope.locals.buffer[i].name == name) {
                return @intCast(i);
            }
        }
        return null;
    }

    fn addUpvalue(_: *Compiler, scope: *FunctionScope, index: u16, is_local: bool) !u16 {
        // Check if we already have this upvalue
        for (scope.upvalues.buffer[0..scope.upvalues.len], 0..) |uv, i| {
            if (uv.index == index and uv.is_local == is_local) {
                return @intCast(i);
            }
        }
        const uv_idx: u16 = @intCast(scope.upvalues.len);
        try scope.upvalues.append(.{ .index = index, .is_local = is_local });
        return uv_idx;
    }

    fn resolveUpvalue(self: *Compiler, scope: *FunctionScope, name: StringId) !?u16 {
        const parent = scope.parent orelse return null;

        // Check parent's locals
        if (self.resolveLocal(parent, name)) |local_idx| {
            parent.locals.buffer[local_idx].is_captured = true;
            return try self.addUpvalue(scope, local_idx, true);
        }

        // Check parent's upvalues (recursive)
        if (try self.resolveUpvalue(parent, name)) |uv_idx| {
            return try self.addUpvalue(scope, uv_idx, false);
        }

        return null;
    }

    // ── Emit helpers ─────────────────────────────────────────────────

    fn emitOp(self: *Compiler, op: OpCode) CompileError!void {
        try self.current.bc.emit(self.allocator, op);
    }

    fn emitOpU16(self: *Compiler, op: OpCode, operand: u16) CompileError!void {
        try self.current.bc.emitWithU16(self.allocator, op, operand);
    }

    fn emitConstant(self: *Compiler, val: JsValue) CompileError!void {
        const ci = try self.current.bc.addConstant(self.allocator, val);
        try self.emitOpU16(.load_const, ci);
    }

    // ── Node compilation ─────────────────────────────────────────────

    fn compileNode(self: *Compiler, idx: NodeIndex) CompileError!void {
        if (idx == null_node) return;
        const node = self.parser.ast.getNode(idx);
        switch (node) {
            .number_literal => |n| try self.emitConstant(JsValue.initNumber(n)),
            .bool_literal => |b| try self.emitConstant(JsValue.initBool(b)),
            .null_literal => try self.emitConstant(JsValue.null_val),
            .string_literal => |sid| try self.emitConstant(JsValue.initString(sid)),
            .regex_literal => |re| {
                const pat_ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(re.pattern));
                try self.emitOpU16(.new_regexp, pat_ci);
                const flags_ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(re.flags));
                // Emit flags index as additional u16
                try self.current.bc.code.append(self.allocator, @intCast(flags_ci & 0xFF));
                try self.current.bc.code.append(self.allocator, @intCast((flags_ci >> 8) & 0xFF));
            },

            .template_literal => |list| {
                // Template literal: [str, expr, str, expr, ..., str]
                // Compile each part and concatenate with add (string +)
                const items = self.parser.ast.getNodeList(list);
                if (items.len == 0) {
                    // Empty template → empty string
                    const empty_id = self.parser.pool.intern("") catch return error.OutOfMemory;
                    try self.emitConstant(JsValue.initString(empty_id));
                } else {
                    try self.compileNode(items[0]);
                    for (items[1..]) |item| {
                        try self.compileNode(item);
                        try self.emitOp(.add);
                    }
                }
            },

            .tagged_template => |tt| {
                // tag`str${expr}str` → tag(strings_array, expr1, expr2, ...)
                // Check if tag is a member expression for proper this binding
                const tag_node = self.parser.ast.getNode(tt.tag);
                const is_method = tag_node == .member or tag_node == .computed_member;

                // 1. Compile the tag function (with this for member calls)
                if (is_method) {
                    switch (tag_node) {
                        .member => |m| {
                            try self.compileNode(m.object); // push this
                            try self.emitOp(.dup);
                            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                            try self.emitOpU16(.get_prop, ci); // stack: [this, func]
                        },
                        .computed_member => |m| {
                            try self.compileNode(m.object); // push this
                            try self.emitOp(.dup);
                            try self.compileNode(m.property);
                            try self.emitOp(.get_elem); // stack: [this, func]
                        },
                        else => unreachable,
                    }
                } else {
                    try self.compileNode(tt.tag);
                }

                // 2. Create the strings array from quasi parts
                const quasis = self.parser.ast.getNodeList(tt.quasi);
                try self.emitOpU16(.new_array, @intCast(quasis.len));
                for (quasis) |q| {
                    try self.compileNode(q);
                    try self.emitOp(.array_push);
                }

                // 3. Add .raw property (separate array with same contents)
                try self.emitOp(.dup); // dup strings array
                try self.emitOpU16(.new_array, @intCast(quasis.len));
                for (quasis) |q| {
                    try self.compileNode(q);
                    try self.emitOp(.array_push);
                }
                const raw_id = try self.parser.pool.intern("raw");
                const raw_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(raw_id)));
                try self.emitOpU16(.set_prop, raw_ci);
                try self.emitOp(.pop); // pop set_prop result

                // 4. Compile each expression argument
                const exprs = self.parser.ast.getNodeList(tt.exprs);
                for (exprs) |e| {
                    try self.compileNode(e);
                }

                // 5. Call with proper this binding
                if (is_method) {
                    try self.emitOpU16(.call_method, @intCast(1 + exprs.len));
                } else {
                    try self.emitOpU16(.call, @intCast(1 + exprs.len));
                }
            },

            .binary => |bin| {
                // Comma operator: evaluate lhs (discard), evaluate rhs (keep)
                if (bin.op == .comma) {
                    try self.compileNode(bin.lhs);
                    try self.emitOp(.pop);
                    try self.compileNode(bin.rhs);
                    return;
                }
                // Short-circuit for logical_and / logical_or
                if (bin.op == .logical_and) {
                    try self.compileNode(bin.lhs);
                    try self.emitOp(.dup);
                    const skip = try self.current.bc.emitJump(self.allocator, .jump_if_false);
                    try self.emitOp(.pop);
                    try self.compileNode(bin.rhs);
                    self.current.bc.patchJump(skip);
                    return;
                }
                if (bin.op == .logical_or) {
                    try self.compileNode(bin.lhs);
                    try self.emitOp(.dup);
                    const skip = try self.current.bc.emitJump(self.allocator, .jump_if_true);
                    try self.emitOp(.pop);
                    try self.compileNode(bin.rhs);
                    self.current.bc.patchJump(skip);
                    return;
                }
                if (bin.op == .nullish) {
                    try self.compileNode(bin.lhs);
                    try self.emitOp(.dup);
                    const skip = try self.current.bc.emitJump(self.allocator, .jump_if_not_nullish);
                    try self.emitOp(.pop);
                    try self.compileNode(bin.rhs);
                    self.current.bc.patchJump(skip);
                    return;
                }
                try self.compileNode(bin.lhs);
                try self.compileNode(bin.rhs);
                try self.emitOp(binaryOpToOpCode(bin.op));
            },

            .unary => |u| {
                if (u.op == .delete_) {
                    try self.compileDelete(u.operand);
                } else {
                    try self.compileNode(u.operand);
                    try self.emitOp(unaryOpToOpCode(u.op));
                }
            },

            .conditional => |c| {
                try self.compileNode(c.test_);
                const else_jump = try self.current.bc.emitJump(self.allocator, .jump_if_false);
                try self.compileNode(c.consequent);
                const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
                self.current.bc.patchJump(else_jump);
                try self.compileNode(c.alternate);
                self.current.bc.patchJump(end_jump);
            },

            .program => |list| {
                const items = self.parser.ast.getNodeList(list);
                for (items, 0..) |item, i| {
                    const is_last = (i == items.len - 1);
                    const item_node = self.parser.ast.getNode(item);
                    if (is_last and item_node == .expression_stmt) {
                        // Last expression in program: keep value on stack for eval
                        try self.compileNode(item_node.expression_stmt);
                    } else {
                        try self.compileNode(item);
                    }
                }
            },

            .expression_stmt => |expr_idx| {
                try self.compileNode(expr_idx);
                try self.emitOp(.pop);
            },

            .empty_statement => {}, // no-op, don't push anything

            // ── Variables ────────────────────────────────────────────
            .var_decl => |decl| {
                const declarators = self.parser.ast.getNodeList(decl.declarators);
                for (declarators) |d_idx| {
                    const d = self.parser.ast.getNode(d_idx);
                    switch (d) {
                        .var_declarator => |vd| try self.compileVarDeclarator(vd.name, vd.init_),
                        else => {},
                    }
                }
            },

            .identifier => |name_id| try self.compileIdentifierLoad(name_id),

            .assignment => |a| try self.compileAssignment(a.lhs, a.rhs, a.op),

            // ── Control flow ─────────────────────────────────────────
            .if_stmt => |s| {
                try self.compileNode(s.test_);
                const else_jump = try self.current.bc.emitJump(self.allocator, .jump_if_false);
                try self.compileNode(s.consequent);
                if (s.alternate != null_node) {
                    const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
                    self.current.bc.patchJump(else_jump);
                    try self.compileNode(s.alternate);
                    self.current.bc.patchJump(end_jump);
                } else {
                    self.current.bc.patchJump(else_jump);
                }
            },

            .while_stmt => |s| {
                const loop_start = self.current.bc.currentOffset();
                try self.compileNode(s.test_);
                const exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_false);
                self.pushLoopCtx(self.current.scope_depth, false);
                try self.compileNode(s.body);
                self.patchContinueJumps(loop_start);
                try self.emitLoop(loop_start);
                self.current.bc.patchJump(exit_jump);
                self.patchBreakJumps();
                self.popLoopCtx();
            },

            .do_while_stmt => |s| {
                const loop_start = self.current.bc.currentOffset();
                self.pushLoopCtx(self.current.scope_depth, false);
                try self.compileNode(s.body);
                const continue_target = self.current.bc.currentOffset();
                self.patchContinueJumps(continue_target);
                try self.compileNode(s.test_);
                const back_jump = try self.current.bc.emitJump(self.allocator, .jump_if_true);
                self.current.bc.patchJumpTo(back_jump, loop_start);
                self.patchBreakJumps();
                self.popLoopCtx();
            },

            .for_stmt => |s| {
                self.beginScope();
                if (s.init_ != null_node) {
                    try self.compileNode(s.init_);
                }
                const loop_start = self.current.bc.currentOffset();
                var exit_jump: ?u32 = null;
                if (s.test_ != null_node) {
                    try self.compileNode(s.test_);
                    exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_false);
                }
                self.pushLoopCtx(self.current.scope_depth, false);
                try self.compileNode(s.body);
                const continue_target = self.current.bc.currentOffset();
                self.patchContinueJumps(continue_target);
                if (s.update != null_node) {
                    try self.compileNode(s.update);
                    try self.emitOp(.pop);
                }
                try self.emitLoop(loop_start);
                if (exit_jump) |ej| {
                    self.current.bc.patchJump(ej);
                }
                self.patchBreakJumps();
                self.popLoopCtx();
                try self.endScope();
            },

            .for_of_stmt => |s| try self.compileForOfIn(s.left, s.right, s.body, false, s.is_await),
            .for_in_stmt => |s| try self.compileForOfIn(s.left, s.right, s.body, true, false),

            .block => |list| {
                self.beginScope();
                const items = self.parser.ast.getNodeList(list);
                for (items) |item| {
                    try self.compileNode(item);
                }
                try self.endScope();
            },

            .return_stmt => |expr_idx| {
                if (self.current.is_async) {
                    if (expr_idx != null_node) {
                        try self.compileNode(expr_idx);
                    } else {
                        try self.emitConstant(JsValue.undefined_val);
                    }
                    try self.emitOp(.async_return);
                } else {
                    if (expr_idx != null_node) {
                        try self.compileNode(expr_idx);
                        try self.emitOp(.return_);
                    } else {
                        try self.emitOp(.return_undefined);
                    }
                }
            },

            .break_stmt => try self.compileBreak(),
            .continue_stmt => try self.compileContinue(),
            .switch_stmt => |s| try self.compileSwitch(s.discriminant, s.cases),
            .try_stmt => |t| try self.compileTryCatch(t),
            .throw_stmt => |expr_idx| {
                try self.compileNode(expr_idx);
                try self.emitOp(.throw_);
            },

            // ── Functions ────────────────────────────────────────────
            .function_decl => |func| try self.compileFunctionDecl(func),
            .function_expr => |func| try self.compileFunctionExpr(func),
            .arrow_function => |func| try self.compileFunctionExpr(func),
            .call => |c| try self.compileCall(c.callee, c.args),
            .new_expr => |n| try self.compileNewExpr(n.callee, n.args),

            // ── Objects ──────────────────────────────────────────────
            .array_literal => |list| try self.compileArrayLiteral(list),
            .object_literal => |list| try self.compileObjectLiteral(list),
            .member => |m| {
                if (m.optional) {
                    try self.compileOptionalMember(m.object, m.property);
                } else {
                    try self.compileMemberAccess(m.object, m.property);
                }
            },
            .computed_member => |m| {
                if (m.optional) {
                    try self.compileOptionalComputedMember(m.object, m.property);
                } else {
                    try self.compileComputedMember(m.object, m.property);
                }
            },

            // ── Classes ──────────────────────────────────────────────
            .class_decl => |cls| try self.compileClassDecl(cls),

            // ── This / Update ────────────────────────────────────────
            .this => try self.emitOp(.load_this),
            .update => |u| try self.compileUpdate(u.operand, u.op),
            .await_expr => |operand| {
                try self.compileNode(operand);
                try self.emitOp(.await_);
            },
            .yield_expr => |y| {
                if (y.argument != null_node) {
                    try self.compileNode(y.argument);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                if (y.delegate) {
                    try self.emitOp(.yield_delegate);
                } else {
                    try self.emitOp(.yield_value);
                }
            },

            // ── ES Modules ──────────────────────────────────────────
            .import_decl => |decl| try self.compileImportDecl(decl),
            .export_default => |inner| {
                try self.compileNode(inner);
                try self.emitOp(.export_default);
            },
            .export_decl => |inner| try self.compileExportDecl(inner),
            .export_named => |decl| try self.compileExportNamed(decl),
            .export_all => {
                // export * from "mod" — handled at module linking time, nothing to emit
            },
            .import_specifier, .export_specifier => {
                // Internal nodes, compiled via parent
            },

            else => try self.emitConstant(JsValue.undefined_val),
        }
    }

    // ── Variable compilation ─────────────────────────────────────────

    fn compileVarDeclarator(self: *Compiler, name_node: NodeIndex, init_node: NodeIndex) CompileError!void {
        switch (self.parser.ast.getNode(name_node)) {
            .identifier => |name_id| {
                // Simple: const x = expr
                if (init_node != null_node) {
                    try self.compileNode(init_node);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                try self.storeBinding(name_id);
            },
            .array_pattern => |list| {
                // const [a, b, c] = expr
                if (init_node != null_node) {
                    try self.compileNode(init_node);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                try self.compileArrayDestructure(list);
                try self.emitOp(.pop); // pop the source array
            },
            .object_pattern => |list| {
                // const {x, y} = expr
                if (init_node != null_node) {
                    try self.compileNode(init_node);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                try self.compileObjectDestructure(list);
                try self.emitOp(.pop); // pop the source object
            },
            else => {
                // Unknown pattern — push undefined as fallback
                try self.emitConstant(JsValue.undefined_val);
            },
        }
    }

    fn storeBinding(self: *Compiler, name_id: StringId) CompileError!void {
        if (self.current.scope_depth > 0 or !self.current.is_script) {
            const slot = try self.addLocal(name_id);
            if (!self.current.is_script and self.current.scope_depth == 0) {
                try self.emitOpU16(.store_local, slot);
            }
        } else {
            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name_id)));
            try self.emitOpU16(.store_global, ci);
        }
    }

    fn compileArrayDestructure(self: *Compiler, list: NodeList) CompileError!void {
        const elements = self.parser.ast.getNodeList(list);
        for (elements, 0..) |elem, i| {
            if (elem == null_node) continue; // skip holes: [a, , b]
            const node = self.parser.ast.getNode(elem);
            switch (node) {
                .identifier => |name_id| {
                    // dup source, push index, get_elem, store
                    try self.emitOp(.dup);
                    try self.emitConstant(JsValue.initNumber(@floatFromInt(i)));
                    try self.emitOp(.get_elem);
                    try self.storeBinding(name_id);
                },
                .assign_pattern => |ap| {
                    // [a = default] — get element, if undefined use default
                    try self.emitOp(.dup);
                    try self.emitConstant(JsValue.initNumber(@floatFromInt(i)));
                    try self.emitOp(.get_elem);
                    try self.compileDefaultValue(ap.left, ap.right);
                },
                .rest_element => |rest_target| {
                    // [...rest] — slice from index i to end
                    const rest_node = self.parser.ast.getNode(rest_target);
                    switch (rest_node) {
                        .identifier => |name_id| {
                            try self.emitRestSlice(name_id, i);
                        },
                        else => {},
                    }
                },
                .spread => |inner| {
                    // Arrow param path: ...rest parsed as .spread instead of .rest_element
                    const spread_node = self.parser.ast.getNode(inner);
                    switch (spread_node) {
                        .identifier => |name_id| {
                            try self.emitRestSlice(name_id, i);
                        },
                        else => {},
                    }
                },
                .assignment => |asgn| {
                    // Arrow param path: [x = default] parsed as .assignment instead of .assign_pattern
                    try self.emitOp(.dup);
                    try self.emitConstant(JsValue.initNumber(@floatFromInt(i)));
                    try self.emitOp(.get_elem);
                    try self.compileDefaultValue(asgn.lhs, asgn.rhs);
                },
                .array_pattern, .array_literal => |nested| {
                    // Nested: const [[a, b]] = expr
                    try self.emitOp(.dup);
                    try self.emitConstant(JsValue.initNumber(@floatFromInt(i)));
                    try self.emitOp(.get_elem);
                    try self.compileArrayDestructure(nested);
                    try self.emitOp(.pop);
                },
                .object_pattern, .object_literal => |nested| {
                    // Nested: const [{x}] = expr
                    try self.emitOp(.dup);
                    try self.emitConstant(JsValue.initNumber(@floatFromInt(i)));
                    try self.emitOp(.get_elem);
                    try self.compileObjectDestructure(nested);
                    try self.emitOp(.pop);
                },
                else => {
                    // Skip holes (elision)
                },
            }
        }
    }

    fn compileObjectDestructure(self: *Compiler, list: NodeList) CompileError!void {
        const props = self.parser.ast.getNodeList(list);
        for (props) |prop_idx| {
            const prop_node = self.parser.ast.getNode(prop_idx);
            switch (prop_node) {
                .property => |prop| {
                    // Get the property key name
                    const key_name = switch (self.parser.ast.getNode(prop.key)) {
                        .identifier => |id| id,
                        else => continue,
                    };
                    const value_node = self.parser.ast.getNode(prop.value);
                    switch (value_node) {
                        .identifier => |target_id| {
                            // {key: target} or shorthand {x}
                            try self.emitOp(.dup);
                            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_name)));
                            try self.emitOpU16(.get_prop, ci);
                            try self.storeBinding(target_id);
                        },
                        .assign_pattern => |ap| {
                            // {key = default} or {key: target = default}
                            try self.emitOp(.dup);
                            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_name)));
                            try self.emitOpU16(.get_prop, ci);
                            try self.compileDefaultValue(ap.left, ap.right);
                        },
                        .array_pattern, .array_literal => |nested| {
                            // {key: [a, b]}
                            try self.emitOp(.dup);
                            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_name)));
                            try self.emitOpU16(.get_prop, ci);
                            try self.compileArrayDestructure(nested);
                            try self.emitOp(.pop);
                        },
                        .object_pattern, .object_literal => |nested| {
                            // {key: {a, b}}
                            try self.emitOp(.dup);
                            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_name)));
                            try self.emitOpU16(.get_prop, ci);
                            try self.compileObjectDestructure(nested);
                            try self.emitOp(.pop);
                        },
                        else => {},
                    }
                },
                .rest_element => |rest_target| {
                    // {...rest} — for now, just assign the whole object
                    const rest_node = self.parser.ast.getNode(rest_target);
                    switch (rest_node) {
                        .identifier => |name_id| {
                            try self.emitOp(.dup);
                            try self.storeBinding(name_id);
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn emitRestSlice(self: *Compiler, name_id: StringId, start_index: usize) CompileError!void {
        try self.emitOp(.dup);
        const slice_id = try self.parser.pool.intern("slice");
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(slice_id)));
        try self.emitOp(.dup);
        try self.emitOpU16(.get_prop, ci);
        try self.emitOp(.swap);
        try self.emitConstant(JsValue.initNumber(@floatFromInt(start_index)));
        try self.emitOpU16(.call, 1);
        try self.storeBinding(name_id);
    }

    fn compileDefaultValue(self: *Compiler, target_node: NodeIndex, default_node: NodeIndex) CompileError!void {
        // Stack has the value. If undefined, replace with default.
        // dup, push undefined, strict_eq, jump_if_false skip, pop, compile default, skip:
        try self.emitOp(.dup);
        try self.emitConstant(JsValue.undefined_val);
        try self.emitOp(.strict_eq);
        const skip_default = try self.current.bc.emitJump(self.allocator, .jump_if_false);
        try self.emitOp(.pop); // pop the undefined value
        try self.compileNode(default_node); // push default
        self.current.bc.patchJump(skip_default);
        // Now store the value
        const target = self.parser.ast.getNode(target_node);
        switch (target) {
            .identifier => |name_id| try self.storeBinding(name_id),
            else => {},
        }
    }

    fn compileIdentifierLoad(self: *Compiler, name_id: StringId) CompileError!void {
        // Try local first
        if (self.resolveLocal(&self.current, name_id)) |slot| {
            try self.emitOpU16(.load_local, slot);
            return;
        }
        // Try upvalue
        if (try self.resolveUpvalue(&self.current, name_id)) |uv_idx| {
            try self.emitOpU16(.load_upvalue, uv_idx);
            return;
        }
        // Global
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name_id)));
        try self.emitOpU16(.load_global, ci);
    }

    fn compileIdentifierStore(self: *Compiler, name_id: StringId) CompileError!void {
        if (self.resolveLocal(&self.current, name_id)) |slot| {
            try self.emitOpU16(.store_local, slot);
            return;
        }
        if (try self.resolveUpvalue(&self.current, name_id)) |uv_idx| {
            try self.emitOpU16(.store_upvalue, uv_idx);
            return;
        }
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name_id)));
        try self.emitOpU16(.store_global, ci);
    }

    fn compileAssignment(self: *Compiler, lhs: NodeIndex, rhs: NodeIndex, op: BinaryOp) CompileError!void {
        const lhs_node = self.parser.ast.getNode(lhs);
        switch (lhs_node) {
            .identifier => |name_id| {
                if (op == .assign) {
                    try self.compileNode(rhs);
                } else if (op == .logical_and_assign or op == .logical_or_assign or op == .nullish_assign) {
                    try self.compileLogicalAssignment(name_id, rhs, op);
                    return;
                } else {
                    // Compound assignment: load current, compute, store
                    try self.compileIdentifierLoad(name_id);
                    try self.compileNode(rhs);
                    try self.emitOp(compoundAssignOp(op));
                }
                // Dup before store so assignment is an expression
                try self.emitOp(.dup);
                try self.compileIdentifierStore(name_id);
            },
            .member => |m| {
                // obj.prop = val
                try self.compileNode(m.object);
                try self.compileNode(rhs);
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                try self.emitOpU16(.set_prop, ci);
            },
            .computed_member => |m| {
                // obj[key] = val
                try self.compileNode(m.object);
                try self.compileNode(m.property);
                try self.compileNode(rhs);
                try self.emitOp(.set_elem);
            },
            else => {
                // Unsupported LHS — just evaluate RHS
                try self.compileNode(rhs);
            },
        }
    }

    fn compileLogicalAssignment(self: *Compiler, name_id: StringId, rhs: NodeIndex, op: BinaryOp) CompileError!void {
        try self.compileIdentifierLoad(name_id);
        try self.emitOp(.dup);
        const skip = switch (op) {
            .logical_and_assign => try self.current.bc.emitJump(self.allocator, .jump_if_false),
            .logical_or_assign => try self.current.bc.emitJump(self.allocator, .jump_if_true),
            .nullish_assign => try self.current.bc.emitJump(self.allocator, .jump_if_not_nullish),
            else => unreachable,
        };
        try self.emitOp(.pop);
        try self.compileNode(rhs);
        try self.emitOp(.dup);
        try self.compileIdentifierStore(name_id);
        self.current.bc.patchJump(skip);
    }

    fn compileDelete(self: *Compiler, operand: NodeIndex) CompileError!void {
        switch (self.parser.ast.getNode(operand)) {
            .member => |m| {
                try self.compileNode(m.object);
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                try self.emitOpU16(.delete_prop, ci);
            },
            .computed_member => |m| {
                try self.compileNode(m.object);
                try self.compileNode(m.property);
                try self.emitOp(.delete_elem);
            },
            else => {
                try self.compileNode(operand);
                try self.emitOp(.pop);
                try self.emitConstant(JsValue.initBool(true));
            },
        }
    }

    // ── Function compilation ─────────────────────────────────────────

    fn compileFunctionDecl(self: *Compiler, func: ast_mod.Function) CompileError!void {
        const name_id = func.name orelse return;
        try self.compileFunctionBody(func);
        // Bind to variable
        if (self.current.scope_depth > 0 or !self.current.is_script) {
            _ = try self.addLocal(name_id);
        } else {
            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name_id)));
            try self.emitOpU16(.store_global, ci);
        }
    }

    fn compileFunctionExpr(self: *Compiler, func: ast_mod.Function) CompileError!void {
        try self.compileFunctionBody(func);
        // Value left on stack
    }

    fn compileFunctionBody(self: *Compiler, func: ast_mod.Function) CompileError!void {
        // Save current scope — parent must point to saved copy, not self.current
        // (self.current gets overwritten, so &self.current would be self-referential)
        var saved = self.current;
        self.current = .{
            .parent = &saved,
            .is_script = false,
            .is_async = func.is_async,
        };

        // Add params as locals
        const params = self.parser.ast.getNodeList(func.params);
        for (params) |p_idx| {
            const p = self.parser.ast.getNode(p_idx);
            switch (p) {
                .identifier => |id| _ = try self.addLocal(id),
                .assign_pattern => |ap| {
                    // Default param: use the left-hand identifier as local name
                    const left = self.parser.ast.getNode(ap.left);
                    switch (left) {
                        .identifier => |id| _ = try self.addLocal(id),
                        else => _ = try self.addLocal(0),
                    }
                },
                .rest_element => |operand| {
                    // Rest param: use the identifier as local name
                    const elem = self.parser.ast.getNode(operand);
                    switch (elem) {
                        .identifier => |id| _ = try self.addLocal(id),
                        else => _ = try self.addLocal(0),
                    }
                },
                .array_pattern, .object_pattern, .array_literal, .object_literal => {
                    // Destructuring param: placeholder local for the whole arg
                    _ = try self.addLocal(0);
                },
                .assignment => |asgn| {
                    // Arrow param path: ({a} = {}) parsed as .assignment
                    const left = self.parser.ast.getNode(asgn.lhs);
                    switch (left) {
                        .identifier => |id| _ = try self.addLocal(id),
                        else => _ = try self.addLocal(0),
                    }
                },
                else => _ = try self.addLocal(0), // placeholder
            }
        }

        // Emit default parameter value checks (before body)
        // VM already pads missing args with undefined, so we check and replace
        for (params, 0..) |p_idx, i| {
            const p = self.parser.ast.getNode(p_idx);
            switch (p) {
                .assign_pattern => |ap| {
                    // if (param === undefined) param = default_expr;
                    try self.emitOpU16(.load_local, @intCast(i));
                    try self.emitConstant(JsValue.undefined_val);
                    try self.emitOp(.strict_ne);
                    const jump_over = try self.current.bc.emitJump(self.allocator, .jump_if_true);
                    // Evaluate default expression and store
                    try self.compileNode(ap.right);
                    try self.emitOpU16(.store_local, @intCast(i));
                    self.current.bc.patchJump(jump_over);
                    // If left side is a destructuring pattern, destructure after default check
                    const left = self.parser.ast.getNode(ap.left);
                    switch (left) {
                        .array_pattern, .array_literal => |list| {
                            try self.emitOpU16(.load_local, @intCast(i));
                            try self.compileArrayDestructure(list);
                            try self.emitOp(.pop);
                        },
                        .object_pattern, .object_literal => |list| {
                            try self.emitOpU16(.load_local, @intCast(i));
                            try self.compileObjectDestructure(list);
                            try self.emitOp(.pop);
                        },
                        else => {},
                    }
                },
                .rest_element => {
                    try self.emitOpU16(.collect_rest, @intCast(i));
                    try self.emitOpU16(.store_local, @intCast(i));
                },
                .array_pattern, .array_literal => |list| {
                    // Destructuring array param: load arg, destructure into new locals
                    try self.emitOpU16(.load_local, @intCast(i));
                    try self.compileArrayDestructure(list);
                    try self.emitOp(.pop);
                },
                .object_pattern, .object_literal => |list| {
                    // Destructuring object param: load arg, destructure into new locals
                    try self.emitOpU16(.load_local, @intCast(i));
                    try self.compileObjectDestructure(list);
                    try self.emitOp(.pop);
                },
                .assignment => |asgn| {
                    // Arrow param path: ({a} = {}) parsed as .assignment
                    try self.emitOpU16(.load_local, @intCast(i));
                    try self.emitConstant(JsValue.undefined_val);
                    try self.emitOp(.strict_ne);
                    const jump_over = try self.current.bc.emitJump(self.allocator, .jump_if_true);
                    try self.compileNode(asgn.rhs);
                    try self.emitOpU16(.store_local, @intCast(i));
                    self.current.bc.patchJump(jump_over);
                    // Destructure if lhs is a pattern
                    const left = self.parser.ast.getNode(asgn.lhs);
                    switch (left) {
                        .array_pattern, .array_literal => |list| {
                            try self.emitOpU16(.load_local, @intCast(i));
                            try self.compileArrayDestructure(list);
                            try self.emitOp(.pop);
                        },
                        .object_pattern, .object_literal => |list| {
                            try self.emitOpU16(.load_local, @intCast(i));
                            try self.compileObjectDestructure(list);
                            try self.emitOp(.pop);
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // Emit instance field initializers (class constructor)
        if (self.pending_class_fields) |fields| {
            for (fields) |field| {
                try self.emitOp(.load_this);
                if (field.init != null_node) {
                    try self.compileNode(field.init);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(field.name)));
                try self.emitOpU16(.set_prop, ci);
                try self.emitOp(.pop);
            }
            self.pending_class_fields = null;
        }

        // Compile body
        const body = self.parser.ast.getNode(func.body);
        switch (body) {
            .block => |list| {
                const items = self.parser.ast.getNodeList(list);
                for (items) |item| {
                    try self.compileNode(item);
                }
            },
            else => {
                // Arrow function expression body
                try self.compileNode(func.body);
                if (self.current.is_async) {
                    try self.emitOp(.async_return);
                } else {
                    try self.emitOp(.return_);
                }
            },
        }

        // Implicit return undefined
        if (self.current.is_async) {
            try self.emitConstant(JsValue.undefined_val);
            try self.emitOp(.async_return);
        } else {
            try self.emitOp(.return_undefined);
        }

        // Build the FunctionObj
        self.current.bc.local_count = @intCast(self.current.locals.len);
        self.current.bc.param_count = @intCast(params.len);

        const fn_bc = self.current.bc;
        const upvalue_count: u16 = @intCast(self.current.upvalues.len);

        // Build upvalue defs
        var uv_defs: []UpvalueDef = &.{};
        if (upvalue_count > 0) {
            uv_defs = try self.allocator.alloc(UpvalueDef, upvalue_count);
            for (self.current.upvalues.buffer[0..upvalue_count], 0..) |uv, i| {
                uv_defs[i] = .{ .index = uv.index, .is_local = uv.is_local };
            }
        }

        // Restore parent scope
        self.current = saved;

        // Create the function object on the heap
        const obj = try self.allocator.create(object_mod.JsObject);
        obj.* = .{
            .obj_type = .function,
            .data = .{ .function = .{
                .bytecode = fn_bc,
                .param_count = @intCast(params.len),
                .local_count = fn_bc.local_count,
                .name = func.name,
                .upvalue_count = upvalue_count,
                .upvalue_defs = uv_defs,
                .is_async = func.is_async,
                .is_generator = func.is_generator,
            } },
        };

        try self.functions.append(self.allocator, obj);

        // Emit new_function with constant index pointing to the object
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initObject(obj));
        try self.emitOpU16(.new_function, ci);
    }

    fn compileCall(self: *Compiler, callee: NodeIndex, args: NodeList) CompileError!void {
        const callee_node = self.parser.ast.getNode(callee);
        const arg_items = self.parser.ast.getNodeList(args);

        // Check if any arg is a spread node
        var has_spread = false;
        for (arg_items) |arg| {
            if (self.parser.ast.getNode(arg) == .spread) {
                has_spread = true;
                break;
            }
        }

        if (has_spread) {
            switch (callee_node) {
                .member => |m| {
                    try self.compileNode(m.object); // [this]
                    try self.emitOp(.dup); // [this, this]
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                    try self.emitOpU16(.get_prop, ci); // [this, func]
                    try self.emitOpU16(.new_array, 0); // [this, func, args[]]
                    try self.compileSpreadArgs(arg_items);
                    try self.emitOp(.call_method_spread);
                },
                else => {
                    try self.compileNode(callee); // [func]
                    try self.emitOpU16(.new_array, 0); // [func, args[]]
                    try self.compileSpreadArgs(arg_items);
                    try self.emitOp(.call_spread);
                },
            }
            return;
        }

        switch (callee_node) {
            .member => |m| {
                // Method call: obj.method(args) → this binding
                try self.compileNode(m.object); // push obj (this)
                try self.emitOp(.dup); // dup for property lookup
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                try self.emitOpU16(.get_prop, ci); // get method
                // Stack: [obj, method_func]
                for (arg_items) |arg| {
                    try self.compileNode(arg);
                }
                try self.emitOpU16(.call_method, @intCast(arg_items.len));
            },
            .computed_member => |m| {
                // Computed method call: obj[key](args) → this binding
                try self.compileNode(m.object); // push obj (this)
                try self.emitOp(.dup); // dup for property lookup
                try self.compileNode(m.property); // push key
                try self.emitOp(.get_elem); // get method
                // Stack: [obj, method_func]
                for (arg_items) |arg| {
                    try self.compileNode(arg);
                }
                try self.emitOpU16(.call_method, @intCast(arg_items.len));
            },
            else => {
                try self.compileNode(callee);
                for (arg_items) |arg| {
                    try self.compileNode(arg);
                }
                try self.emitOpU16(.call, @intCast(arg_items.len));
            },
        }
    }

    fn compileSpreadArgs(self: *Compiler, arg_items: []const NodeIndex) CompileError!void {
        for (arg_items) |arg| {
            switch (self.parser.ast.getNode(arg)) {
                .spread => |inner| {
                    try self.compileNode(inner);
                    try self.emitOp(.spread_into_array);
                },
                else => {
                    try self.compileNode(arg);
                    try self.emitOp(.array_push);
                },
            }
        }
    }

    fn compileNewExpr(self: *Compiler, callee: NodeIndex, args: NodeList) CompileError!void {
        try self.compileNode(callee);
        const arg_items = self.parser.ast.getNodeList(args);
        for (arg_items) |arg| {
            try self.compileNode(arg);
        }
        try self.emitOpU16(.construct, @intCast(arg_items.len));
    }

    // ── Object compilation ───────────────────────────────────────────

    fn compileArrayLiteral(self: *Compiler, list: NodeList) CompileError!void {
        const elems = self.parser.ast.getNodeList(list);
        try self.emitOpU16(.new_array, @intCast(elems.len));
        for (elems) |e_idx| {
            switch (self.parser.ast.getNode(e_idx)) {
                .spread => |inner| {
                    try self.compileNode(inner);
                    try self.emitOp(.spread_into_array);
                },
                else => {
                    try self.compileNode(e_idx);
                    try self.emitOp(.array_push);
                },
            }
        }
    }

    fn compileObjectLiteral(self: *Compiler, list: NodeList) CompileError!void {
        const props = self.parser.ast.getNodeList(list);
        try self.emitOpU16(.new_object, @intCast(props.len));
        for (props) |p_idx| {
            const p = self.parser.ast.getNode(p_idx);
            switch (p) {
                .property => |prop| {
                    if (prop.computed) {
                        switch (prop.kind) {
                            .init => {
                                try self.emitOp(.dup);
                                try self.compileNode(prop.key);
                                try self.compileNode(prop.value);
                                try self.emitOp(.set_elem);
                                try self.emitOp(.pop);
                            },
                            .get, .set => {
                                // Computed accessors need descriptor support; keep object shape stable.
                            },
                        }
                        continue;
                    }
                    const key_id = try self.literalPropertyKeyId(prop.key);
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    switch (prop.kind) {
                        .init => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.set_prop, ci);
                            try self.emitOp(.pop);
                        },
                        .get => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.define_getter_lit, ci);
                            try self.emitOp(.pop); // pop dup'd obj
                        },
                        .set => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.define_setter_lit, ci);
                            try self.emitOp(.pop); // pop dup'd obj
                        },
                    }
                },
                .spread => |inner| {
                    try self.emitOp(.dup);
                    try self.compileNode(inner);
                    try self.emitOp(.spread_into_object);
                    try self.emitOp(.pop);
                },
                else => {},
            }
        }
    }

    fn literalPropertyKeyId(self: *Compiler, key_idx: NodeIndex) CompileError!StringId {
        const key_node = self.parser.ast.getNode(key_idx);
        return switch (key_node) {
            .identifier => |id| id,
            .string_literal => |id| id,
            .number_literal => |n| blk: {
                var buf: [64]u8 = undefined;
                const s = if (n == @trunc(n) and @abs(n) < 1e15)
                    std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch return error.OutOfMemory
                else
                    std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.OutOfMemory;
                break :blk self.parser.pool.intern(s) catch return error.OutOfMemory;
            },
            else => self.parser.pool.intern("") catch return error.OutOfMemory,
        };
    }

    fn compileClassDecl(self: *Compiler, cls: ast_mod.Class) CompileError!void {
        const methods = self.parser.ast.getNodeList(cls.body);

        // Collect fields and find constructor
        var constructor_func: ?ast_mod.Function = null;
        var inst_fields: [64]ClassField = undefined;
        var inst_field_n: usize = 0;
        var static_fields: [64]ClassField = undefined;
        var static_field_n: usize = 0;

        for (methods) |m_idx| {
            const m = self.parser.ast.getNode(m_idx);
            switch (m) {
                .property => |prop| {
                    const key = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key) {
                        .identifier => |id| id,
                        else => continue,
                    };
                    if (!prop.method) {
                        const f = ClassField{ .name = key_id, .init = prop.value };
                        if (prop.is_static) {
                            if (static_field_n < static_fields.len) {
                                static_fields[static_field_n] = f;
                                static_field_n += 1;
                            }
                        } else {
                            if (inst_field_n < inst_fields.len) {
                                inst_fields[inst_field_n] = f;
                                inst_field_n += 1;
                            }
                        }
                        continue;
                    }
                    if (!prop.is_static) {
                        const name = self.parser.pool.get(key_id) orelse "";
                        if (std.mem.eql(u8, name, "constructor")) {
                            const val = self.parser.ast.getNode(prop.value);
                            switch (val) {
                                .function_decl => |f| constructor_func = f,
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // 1. Compile constructor (with instance field initializers injected)
        if (inst_field_n > 0) {
            self.pending_class_fields = inst_fields[0..inst_field_n];
        }
        if (constructor_func) |func| {
            var ctor = func;
            ctor.name = cls.name;
            try self.compileFunctionBody(ctor);
        } else {
            const empty_body = self.parser.ast.addNodeList(self.allocator, &.{}) catch return error.OutOfMemory;
            const empty_block = self.parser.ast.addNode(self.allocator, .{ .block = empty_body }) catch return error.OutOfMemory;
            const empty_params = self.parser.ast.addNodeList(self.allocator, &.{}) catch return error.OutOfMemory;
            try self.compileFunctionBody(.{
                .name = cls.name,
                .params = empty_params,
                .body = empty_block,
            });
        }
        // Stack: [ctor]

        // 2. Create prototype object and set on constructor
        //    ctor.prototype = {}
        const proto_id = try self.parser.pool.intern("prototype");
        const proto_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(proto_id)));
        try self.emitOp(.dup); // [ctor, ctor]
        try self.emitOpU16(.new_object, 0); // [ctor, ctor, proto]
        try self.emitOpU16(.set_prop, proto_ci); // [ctor, proto] (set_prop pops ctor+proto, pushes proto)
        try self.emitOp(.pop); // [ctor]

        // 3. If extends, set up prototype chain before adding methods
        if (cls.super_class != null_node) {
            // ctor.prototype.__proto__ = SuperClass.prototype
            try self.emitOp(.dup); // [ctor, ctor]
            try self.emitOpU16(.get_prop, proto_ci); // [ctor, ctor_proto]

            try self.compileNode(cls.super_class); // [ctor, ctor_proto, Super]
            const super_proto_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(proto_id)));
            try self.emitOpU16(.get_prop, super_proto_ci); // [ctor, ctor_proto, super_proto]

            const dunder_id = try self.parser.pool.intern("__proto__");
            const dunder_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(dunder_id)));
            try self.emitOpU16(.set_prop, dunder_ci); // [ctor, set_result]
            try self.emitOp(.pop); // [ctor]
        }

        // 4. Add methods
        // Check if there are any instance methods to add
        var has_instance_methods = false;
        for (methods) |m_idx| {
            const m = self.parser.ast.getNode(m_idx);
            switch (m) {
                .property => |prop| {
                    if (prop.method and !prop.is_static) {
                        const key = self.parser.ast.getNode(prop.key);
                        switch (key) {
                            .identifier => |id| {
                                const kname = self.parser.pool.get(id) orelse "";
                                if (!std.mem.eql(u8, kname, "constructor")) {
                                    has_instance_methods = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
            if (has_instance_methods) break;
        }

        // Get prototype once if needed: [ctor] → [ctor, proto]
        if (has_instance_methods) {
            try self.emitOp(.dup); // [ctor, ctor]
            try self.emitOpU16(.get_prop, proto_ci); // [ctor, proto]
        }

        for (methods) |m_idx| {
            const m = self.parser.ast.getNode(m_idx);
            switch (m) {
                .property => |prop| {
                    const key = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key) {
                        .identifier => |id| id,
                        else => continue,
                    };

                    const kname = self.parser.pool.get(key_id) orelse "";
                    if (std.mem.eql(u8, kname, "constructor")) continue;
                    if (!prop.method) continue;

                    if (prop.is_static) {
                        // Static method: set on constructor directly
                        // Stack is [ctor, proto] or [ctor] — need to reach ctor
                        // We'll handle static methods in a second pass
                        continue;
                    }

                    // Instance method/getter/setter: on proto
                    // Stack: [ctor, proto]
                    try self.emitOp(.dup); // [ctor, proto, proto]
                    const val = self.parser.ast.getNode(prop.value);
                    switch (val) {
                        .function_decl => |f| try self.compileFunctionBody(f),
                        else => try self.compileNode(prop.value),
                    }
                    // [ctor, proto, proto, method_fn]
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    switch (prop.kind) {
                        .init => {
                            try self.emitOpU16(.set_prop, ci);
                            try self.emitOp(.pop);
                        },
                        .get => {
                            try self.emitOpU16(.define_getter, ci);
                            try self.emitOp(.pop); // pop dup'd proto
                        },
                        .set => {
                            try self.emitOpU16(.define_setter, ci);
                            try self.emitOp(.pop); // pop dup'd proto
                        },
                    }
                    // [ctor, proto]
                },
                else => {},
            }
        }

        // Pop proto if we pushed it
        if (has_instance_methods) {
            try self.emitOp(.pop); // [ctor]
        }

        // 5. Static methods: set on constructor
        for (methods) |m_idx| {
            const m = self.parser.ast.getNode(m_idx);
            switch (m) {
                .property => |prop| {
                    if (!prop.is_static or !prop.method) continue;
                    const key = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key) {
                        .identifier => |id| id,
                        else => continue,
                    };

                    // Stack: [ctor]
                    try self.emitOp(.dup); // [ctor, ctor]
                    const val = self.parser.ast.getNode(prop.value);
                    switch (val) {
                        .function_decl => |f| try self.compileFunctionBody(f),
                        else => try self.compileNode(prop.value),
                    }
                    // [ctor, ctor, static_fn]
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    switch (prop.kind) {
                        .init => {
                            try self.emitOpU16(.set_prop, ci); // [ctor, static_fn]
                            try self.emitOp(.pop); // [ctor]
                        },
                        .get => {
                            try self.emitOpU16(.define_getter, ci);
                            try self.emitOp(.pop); // pop dup'd ctor
                        },
                        .set => {
                            try self.emitOpU16(.define_setter, ci);
                            try self.emitOp(.pop); // pop dup'd ctor
                        },
                    }
                },
                else => {},
            }
        }

        // 6. Static field initializers: set on constructor
        for (static_fields[0..static_field_n]) |field| {
            try self.emitOp(.dup); // [ctor, ctor]
            if (field.init != null_node) {
                try self.compileNode(field.init);
            } else {
                try self.emitConstant(JsValue.undefined_val);
            }
            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(field.name)));
            try self.emitOpU16(.set_prop, ci);
            try self.emitOp(.pop); // [ctor]
        }

        // 7. Store constructor as class name (stack: [ctor])
        if (cls.name) |name_id| {
            try self.storeBinding(name_id);
        }
    }

    fn compileMemberAccess(self: *Compiler, object: NodeIndex, property: StringId) CompileError!void {
        try self.compileNode(object);
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(property)));
        try self.emitOpU16(.get_prop, ci);
    }

    fn compileComputedMember(self: *Compiler, object: NodeIndex, property: NodeIndex) CompileError!void {
        try self.compileNode(object);
        try self.compileNode(property);
        try self.emitOp(.get_elem);
    }

    fn compileOptionalMember(self: *Compiler, object: NodeIndex, property: StringId) CompileError!void {
        try self.compileNode(object); // [obj]
        try self.emitOp(.dup); // [obj, obj]
        const null_jump = try self.current.bc.emitJump(self.allocator, .jump_if_nullish); // pops → [obj]
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(property)));
        try self.emitOpU16(.get_prop, ci); // [result]
        const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
        self.current.bc.patchJump(null_jump); // [obj] (null/undefined)
        try self.emitOp(.pop); // []
        try self.emitConstant(JsValue.undefined_val); // [undefined]
        self.current.bc.patchJump(end_jump);
    }

    fn compileOptionalComputedMember(self: *Compiler, object: NodeIndex, property: NodeIndex) CompileError!void {
        try self.compileNode(object); // [obj]
        try self.emitOp(.dup); // [obj, obj]
        const null_jump = try self.current.bc.emitJump(self.allocator, .jump_if_nullish); // pops → [obj]
        try self.compileNode(property); // [obj, key]
        try self.emitOp(.get_elem); // [result]
        const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
        self.current.bc.patchJump(null_jump); // [obj]
        try self.emitOp(.pop); // []
        try self.emitConstant(JsValue.undefined_val); // [undefined]
        self.current.bc.patchJump(end_jump);
    }

    // ── Loop helper ──────────────────────────────────────────────────

    fn emitLoop(self: *Compiler, loop_start: u32) CompileError!void {
        try self.emitOp(.jump);
        const current = self.current.bc.currentOffset();
        const delta: i16 = @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current + 2)));
        const u: u16 = @bitCast(delta);
        try self.current.bc.code.append(self.allocator, @intCast(u & 0xFF));
        try self.current.bc.code.append(self.allocator, @intCast((u >> 8) & 0xFF));
    }

    // ── Loop context management ─────────────────────────────────────

    fn pushLoopCtx(self: *Compiler, scope_depth: i32, is_switch: bool) void {
        self.current.loop_stack[self.current.loop_depth] = .{
            .scope_depth = scope_depth,
            .is_switch = is_switch,
        };
        self.current.loop_depth += 1;
    }

    fn popLoopCtx(self: *Compiler) void {
        self.current.loop_depth -= 1;
    }

    fn patchBreakJumps(self: *Compiler) void {
        const ctx = &self.current.loop_stack[self.current.loop_depth - 1];
        for (ctx.break_jumps[0..ctx.break_count]) |patch_pos| {
            self.current.bc.patchJump(patch_pos);
        }
    }

    fn patchContinueJumps(self: *Compiler, target: u32) void {
        const ctx = &self.current.loop_stack[self.current.loop_depth - 1];
        for (ctx.continue_jumps[0..ctx.continue_count]) |patch_pos| {
            self.current.bc.patchJumpTo(patch_pos, target);
        }
    }

    /// Emit pops for locals deeper than target_depth (for break/continue cleanup).
    fn emitPopLocalsToDepth(self: *Compiler, target_depth: i32) CompileError!void {
        var i = self.current.locals.len;
        while (i > 0) {
            i -= 1;
            if (self.current.locals.buffer[i].depth <= target_depth) break;
            if (self.current.locals.buffer[i].is_captured) {
                try self.emitOpU16(.close_upvalue, @intCast(i));
            } else {
                try self.emitOp(.pop);
            }
        }
    }

    /// Find innermost break-able context (loop or switch).
    fn findBreakContext(self: *Compiler) ?*LoopContext {
        if (self.current.loop_depth == 0) return null;
        return &self.current.loop_stack[self.current.loop_depth - 1];
    }

    /// Find innermost loop (skip switches — continue doesn't apply to switch).
    fn findLoopContext(self: *Compiler) ?*LoopContext {
        var i = self.current.loop_depth;
        while (i > 0) {
            i -= 1;
            if (!self.current.loop_stack[i].is_switch) return &self.current.loop_stack[i];
        }
        return null;
    }

    /// Compile for-of / for-in loops.
    /// for (var x of iterable) { body }
    /// for (var k in obj) { body }
    ///
    /// Strategy: convert to index-based loop over array.
    /// for-of: iterate values of iterable (array directly)
    /// for-in: iterate keys of object (get_keys → array, then iterate)
    fn compileForOfIn(self: *Compiler, left: NodeIndex, right: NodeIndex, body: NodeIndex, is_for_in: bool, is_await: bool) CompileError!void {
        self.beginScope();

        // Determine the loop variable name from the left side
        const left_node = self.parser.ast.getNode(left);
        var var_name: ?StringId = null;
        switch (left_node) {
            .var_decl => |decl| {
                const declarators = self.parser.ast.getNodeList(decl.declarators);
                if (declarators.len > 0) {
                    const d = self.parser.ast.getNode(declarators[0]);
                    switch (d) {
                        .var_declarator => |vd| {
                            const vn = self.parser.ast.getNode(vd.name);
                            switch (vn) {
                                .identifier => |id| var_name = id,
                                else => {},
                            }
                        },
                        else => {},
                    }
                }
            },
            .identifier => |name_id| var_name = name_id,
            else => {},
        }

        if (var_name == null) {
            try self.endScope();
            return;
        }

        // Declare loop variable as local + push undefined placeholder
        try self.emitConstant(JsValue.undefined_val);
        _ = try self.addLocal(var_name.?);

        // Compile the right-hand expression (iterable/object)
        try self.compileNode(right);

        if (!is_for_in) {
            // ── for-of: iterator protocol ──────────────────────────────
            if (is_await) {
                try self.emitOp(.get_async_iterator);
            } else {
                try self.emitOp(.get_iterator);
            }
            const iter_name = self.parser.pool.intern("__iter") catch return error.OutOfMemory;
            _ = try self.addLocal(iter_name);

            const loop_start = self.current.bc.currentOffset();

            // Load iterator, dup for call_method consumption
            try self.compileIdentifierLoad(iter_name);
            try self.emitOp(.dup);
            // Get .next method
            const next_id = try self.parser.pool.intern("next");
            const next_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(next_id)));
            try self.emitOpU16(.get_prop, next_ci);
            // call_method 0: consumes iter+next_fn, pushes result
            try self.emitOpU16(.call_method, 0);
            // for-await-of: await the .next() result (Promise → {value, done})
            if (is_await) {
                try self.emitOp(.await_);
            }
            // dup result, check .done
            try self.emitOp(.dup);
            const done_id = try self.parser.pool.intern("done");
            const done_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(done_id)));
            try self.emitOpU16(.get_prop, done_ci);
            const exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_true);
            // Not done: get .value
            const value_id = try self.parser.pool.intern("value");
            const value_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(value_id)));
            try self.emitOpU16(.get_prop, value_ci);
            // Store to loop variable (matches existing for-in pattern: no pop after store)
            try self.compileStoreVar(var_name.?);

            self.pushLoopCtx(self.current.scope_depth, false);
            try self.compileNode(body);
            const continue_target = self.current.bc.currentOffset();
            self.patchContinueJumps(continue_target);
            try self.emitLoop(loop_start);

            self.current.bc.patchJump(exit_jump);
            try self.emitOp(.pop); // discard final result object
            self.patchBreakJumps();
            self.popLoopCtx();
            try self.endScope();
            return;
        }

        // ── for-in: index-based (unchanged) ───────────────────────
        try self.emitOp(.get_keys);
        const iterable_name = self.parser.pool.intern("__iter") catch return error.OutOfMemory;
        _ = try self.addLocal(iterable_name);

        // get_length
        try self.emitOp(.dup);
        try self.emitOp(.get_length);
        const len_name = self.parser.pool.intern("__len") catch return error.OutOfMemory;
        _ = try self.addLocal(len_name);

        // Push index = 0
        try self.emitConstant(JsValue.initNumber(0));
        const idx_name = self.parser.pool.intern("__idx") catch return error.OutOfMemory;
        _ = try self.addLocal(idx_name);

        // Loop start: check idx < len
        const loop_start = self.current.bc.currentOffset();
        try self.compileIdentifierLoad(idx_name);
        try self.compileIdentifierLoad(len_name);
        try self.emitOp(.lt);
        const exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_false);

        self.pushLoopCtx(self.current.scope_depth, false);

        // Load iterable[idx] → store to loop variable
        try self.compileIdentifierLoad(iterable_name);
        try self.compileIdentifierLoad(idx_name);
        try self.emitOp(.get_elem);
        try self.compileStoreVar(var_name.?);

        // Compile body
        try self.compileNode(body);

        // Continue target: increment idx
        const continue_target = self.current.bc.currentOffset();
        self.patchContinueJumps(continue_target);

        // idx = idx + 1
        try self.compileIdentifierLoad(idx_name);
        try self.emitConstant(JsValue.initNumber(1));
        try self.emitOp(.add);
        try self.compileStoreVar(idx_name);

        // Jump back to loop start
        try self.emitLoop(loop_start);

        // Exit
        self.current.bc.patchJump(exit_jump);
        self.patchBreakJumps();
        self.popLoopCtx();
        try self.endScope();
    }

    fn compileStoreVar(self: *Compiler, name: StringId) CompileError!void {
        if (self.resolveLocal(&self.current, name)) |slot| {
            try self.current.bc.emitWithU16(self.allocator, .store_local, slot);
            return;
        }
        if (try self.resolveUpvalue(&self.current, name)) |slot| {
            try self.current.bc.emitWithU16(self.allocator, .store_upvalue, slot);
            return;
        }
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name)));
        try self.current.bc.emitWithU16(self.allocator, .store_global, ci);
    }

    fn compileBreak(self: *Compiler) CompileError!void {
        if (self.findBreakContext()) |ctx| {
            try self.emitPopLocalsToDepth(ctx.scope_depth);
            const jump = try self.current.bc.emitJump(self.allocator, .jump);
            ctx.break_jumps[ctx.break_count] = jump;
            ctx.break_count += 1;
        }
    }

    fn compileContinue(self: *Compiler) CompileError!void {
        if (self.findLoopContext()) |ctx| {
            try self.emitPopLocalsToDepth(ctx.scope_depth);
            const jump = try self.current.bc.emitJump(self.allocator, .jump);
            ctx.continue_jumps[ctx.continue_count] = jump;
            ctx.continue_count += 1;
        }
    }

    fn compileTryCatch(self: *Compiler, t: anytype) CompileError!void {
        // try_begin → offset to catch handler
        const try_begin_patch = try self.current.bc.emitJump(self.allocator, .try_begin);

        // Compile try body
        try self.compileNode(t.block);

        // try_end
        try self.emitOp(.try_end);

        // Jump over catch
        const end_jump = try self.current.bc.emitJump(self.allocator, .jump);

        // Patch try_begin to point to catch handler
        self.current.bc.patchJump(try_begin_patch);

        // Compile catch clause
        if (t.handler != null_node) {
            const handler = self.parser.ast.getNode(t.handler);
            switch (handler) {
                .catch_clause => |cc| {
                    self.beginScope();
                    // Thrown value is on the stack (pushed by VM throw handler)
                    if (cc.param != null_node) {
                        const param_node = self.parser.ast.getNode(cc.param);
                        switch (param_node) {
                            .identifier => |id| _ = try self.addLocal(id),
                            else => _ = try self.addLocal(0),
                        }
                    } else {
                        // No catch parameter — pop the thrown value
                        try self.emitOp(.pop);
                    }
                    try self.compileNode(cc.body);
                    try self.endScope();
                },
                else => {},
            }
        } else {
            // No catch clause — pop thrown value
            try self.emitOp(.pop);
        }

        // Patch end jump
        self.current.bc.patchJump(end_jump);
    }

    fn compileUpdate(self: *Compiler, operand: NodeIndex, op: ast_mod.UnaryOp) CompileError!void {
        const node = self.parser.ast.getNode(operand);
        const is_inc = (op == .pre_inc or op == .post_inc);
        const is_pre = (op == .pre_inc or op == .pre_dec);

        switch (node) {
            .identifier => |name_id| {
                try self.compileIdentifierLoad(name_id);
                if (!is_pre) try self.emitOp(.dup); // post: save old value
                try self.emitConstant(JsValue.initNumber(1));
                try self.emitOp(if (is_inc) .add else .sub);
                if (is_pre) try self.emitOp(.dup); // pre: save new value
                try self.compileIdentifierStore(name_id);
            },
            .member => |m| {
                // obj.prop++ — compile as: obj.prop = obj.prop ± 1
                // Result is new value (imprecise for post-inc expression, correct for statements)
                try self.compileNode(m.object); // [obj]
                try self.emitOp(.dup); // [obj, obj]
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                try self.emitOpU16(.get_prop, ci); // [obj, old]
                try self.emitConstant(JsValue.initNumber(1));
                try self.emitOp(if (is_inc) .add else .sub); // [obj, new]
                try self.emitOpU16(.set_prop, ci); // [new]
            },
            else => try self.compileNode(operand),
        }
    }

    fn compileSwitch(self: *Compiler, discriminant: NodeIndex, cases_list: NodeList) CompileError!void {
        try self.compileNode(discriminant); // push discriminant

        const cases = self.parser.ast.getNodeList(cases_list);

        // Phase 1: Case matching — compare and jump to bodies
        var body_patches: [64]u32 = undefined;
        var has_default = false;

        for (cases, 0..) |case_idx, i| {
            const sc = self.parser.ast.getNode(case_idx).switch_case;
            if (sc.test_ == null_node) {
                // default case — no comparison needed
                has_default = true;
                body_patches[i] = 0; // placeholder, handled separately
                continue;
            }
            try self.emitOp(.dup); // dup discriminant
            try self.compileNode(sc.test_); // push case value
            try self.emitOp(.strict_eq); // compare
            const skip = try self.current.bc.emitJump(self.allocator, .jump_if_false);
            // Match: pop discriminant and jump to body
            try self.emitOp(.pop);
            body_patches[i] = try self.current.bc.emitJump(self.allocator, .jump);
            self.current.bc.patchJump(skip);
        }

        // No match: pop discriminant and jump to default or end
        try self.emitOp(.pop);
        const no_match_jump = try self.current.bc.emitJump(self.allocator, .jump);

        // Phase 2: Bodies (with fallthrough and break support)
        self.pushLoopCtx(self.current.scope_depth, true); // switch uses break context

        for (cases, 0..) |case_idx, i| {
            const sc = self.parser.ast.getNode(case_idx).switch_case;
            if (sc.test_ == null_node) {
                // default body — patch no_match_jump here
                self.current.bc.patchJump(no_match_jump);
            } else {
                self.current.bc.patchJump(body_patches[i]);
            }

            const body_items = self.parser.ast.getNodeList(sc.body);
            for (body_items) |item| {
                try self.compileNode(item);
            }
        }

        // If no default, patch no_match to end
        if (!has_default) {
            self.current.bc.patchJump(no_match_jump);
        }

        self.patchBreakJumps();
        self.popLoopCtx();
    }

    // ── ES Modules ──────────────────────────────────────────────

    fn compileImportDecl(self: *Compiler, decl: ast_mod.ImportDecl) CompileError!void {
        // Emit import_binding for each specifier so the VM can resolve them.
        const source_ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(decl.source));
        const specs = self.parser.ast.getNodeList(decl.specifiers);
        for (specs) |spec_idx| {
            const spec = self.parser.ast.getNode(spec_idx).import_specifier;
            // Emit: import_binding <module_ci> <binding_name_ci>
            // The VM will load module, get the exported value, and store as global
            const binding_name = if (spec.kind == .named) spec.imported.? else spec.local;
            const name_ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(binding_name));
            try self.emitOpU16(.import_binding, source_ci);
            try self.current.bc.code.append(self.allocator, @intCast(name_ci & 0xFF));
            try self.current.bc.code.append(self.allocator, @intCast((name_ci >> 8) & 0xFF));
            // Store as local binding name
            try self.storeBinding(spec.local);
        }
        // Side-effect imports (no specifiers) still need to trigger module load
        if (specs.len == 0) {
            // Push module specifier and pop — VM import_binding with special "no-binding" marker
            try self.emitConstant(JsValue.initString(decl.source));
            try self.emitOp(.pop);
        }
    }

    fn compileExportDecl(self: *Compiler, inner: NodeIndex) CompileError!void {
        // Compile the declaration normally
        try self.compileNode(inner);
        // Then emit export_binding for each declared name
        const inner_node = self.parser.ast.getNode(inner);
        switch (inner_node) {
            .var_decl => |vd| {
                const declarators = self.parser.ast.getNodeList(vd.declarators);
                for (declarators) |d_idx| {
                    const d = self.parser.ast.getNode(d_idx).var_declarator;
                    const name_node = self.parser.ast.getNode(d.name);
                    if (name_node == .identifier) {
                        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(name_node.identifier));
                        try self.emitOpU16(.export_binding, ci);
                    }
                }
            },
            .function_decl => |f| {
                if (f.name) |name| {
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(name));
                    try self.emitOpU16(.export_binding, ci);
                }
            },
            .class_decl => |cls| {
                if (cls.name) |name| {
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(name));
                    try self.emitOpU16(.export_binding, ci);
                }
            },
            else => {},
        }
    }

    fn compileExportNamed(self: *Compiler, decl: ast_mod.ExportDecl) CompileError!void {
        if (decl.source != null) {
            // Re-export: export { a } from "mod" — handled at module linking time
            return;
        }
        // Local export: export { a, b as c }
        // Load each local value and emit export_binding with exported name
        const specs = self.parser.ast.getNodeList(decl.specifiers);
        for (specs) |spec_idx| {
            const spec = self.parser.ast.getNode(spec_idx).export_specifier;
            // Load the local variable
            try self.compileIdentifierLoad(spec.local);
            // Export under the exported name
            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initString(spec.exported));
            try self.emitOpU16(.export_binding, ci);
        }
    }
};

fn binaryOpToOpCode(op: BinaryOp) OpCode {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .power => .power,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .eq => .eq,
        .ne => .ne,
        .strict_eq => .strict_eq,
        .strict_ne => .strict_ne,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        .instanceof => .instanceof_,
        .in_ => .in_,
        else => .add,
    };
}

fn unaryOpToOpCode(op: UnaryOp) OpCode {
    return switch (op) {
        .neg => .neg,
        .not => .not,
        .bit_not => .bit_not,
        .typeof_ => .typeof_,
        .void_ => .void_,
        else => .not,
    };
}

fn compoundAssignOp(op: BinaryOp) OpCode {
    return switch (op) {
        .add_assign => .add,
        .sub_assign => .sub,
        .mul_assign => .mul,
        .div_assign => .div,
        .mod_assign => .mod,
        .power_assign => .power,
        .bit_and_assign => .bit_and,
        .bit_or_assign => .bit_or,
        .bit_xor_assign => .bit_xor,
        .shl_assign => .shl,
        .shr_assign => .shr,
        .ushr_assign => .ushr,
        else => .add,
    };
}
