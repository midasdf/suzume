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

const FunctionScope = struct {
    locals: FixedArray(Local, 256) = .{},
    upvalues: FixedArray(UpvalueInfo, 256) = .{},
    scope_depth: i32 = 0,
    bc: Bytecode = Bytecode.init(),
    parent: ?*FunctionScope = null,
    is_script: bool = true, // true for top-level, false for functions
    loop_stack: [16]LoopContext = undefined,
    loop_depth: u8 = 0,
};

pub const Compiler = struct {
    parser: Parser,
    allocator: std.mem.Allocator,
    current: FunctionScope,
    /// Compiled FunctionObj constants (heap-allocated, owned by caller via Bytecode constants)
    functions: std.ArrayListUnmanaged(*object_mod.JsObject) = .{},

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

    const CompileError = error{OutOfMemory, Overflow, ParseError};

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

            .binary => |bin| {
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
                try self.compileNode(bin.lhs);
                try self.compileNode(bin.rhs);
                try self.emitOp(binaryOpToOpCode(bin.op));
            },

            .unary => |u| {
                try self.compileNode(u.operand);
                try self.emitOp(unaryOpToOpCode(u.op));
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

            .block => |list| {
                self.beginScope();
                const items = self.parser.ast.getNodeList(list);
                for (items) |item| {
                    try self.compileNode(item);
                }
                try self.endScope();
            },

            .return_stmt => |expr_idx| {
                if (expr_idx != null_node) {
                    try self.compileNode(expr_idx);
                    try self.emitOp(.return_);
                } else {
                    try self.emitOp(.return_undefined);
                }
            },

            .break_stmt => |_| try self.compileBreak(),
            .continue_stmt => |_| try self.compileContinue(),
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
            .member => |m| try self.compileMemberAccess(m.object, m.property),
            .computed_member => |m| try self.compileComputedMember(m.object, m.property),

            // ── This / Update ────────────────────────────────────────
            .this => try self.emitOp(.load_this),
            .update => |u| try self.compileUpdate(u.operand, u.op),

            else => try self.emitConstant(JsValue.undefined_val),
        }
    }

    // ── Variable compilation ─────────────────────────────────────────

    fn compileVarDeclarator(self: *Compiler, name_node: NodeIndex, init_node: NodeIndex) CompileError!void {
        const name_id = switch (self.parser.ast.getNode(name_node)) {
            .identifier => |id| id,
            else => return, // destructuring not yet supported
        };

        // Compile initializer (or undefined)
        if (init_node != null_node) {
            try self.compileNode(init_node);
        } else {
            try self.emitConstant(JsValue.undefined_val);
        }

        if (self.current.scope_depth > 0 or !self.current.is_script) {
            const slot = try self.addLocal(name_id);
            if (!self.current.is_script and self.current.scope_depth == 0) {
                // Function-level local: slot pre-allocated by VM, store pops the init value
                try self.emitOpU16(.store_local, slot);
            }
            // Block-scope locals (depth > 0): the pushed init value IS the slot.
            // It stays on the stack; endScope will pop it when the block exits.
        } else {
            // Global variable
            const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(name_id)));
            try self.emitOpU16(.store_global, ci);
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
        };

        // Add params as locals
        const params = self.parser.ast.getNodeList(func.params);
        for (params) |p_idx| {
            const p = self.parser.ast.getNode(p_idx);
            switch (p) {
                .identifier => |id| _ = try self.addLocal(id),
                else => _ = try self.addLocal(0), // placeholder
            }
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
                try self.emitOp(.return_);
            },
        }

        // Implicit return undefined
        try self.emitOp(.return_undefined);

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
            else => {
                try self.compileNode(callee);
                for (arg_items) |arg| {
                    try self.compileNode(arg);
                }
                try self.emitOpU16(.call, @intCast(arg_items.len));
            },
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
            try self.compileNode(e_idx);
            try self.emitOp(.array_push);
        }
    }

    fn compileObjectLiteral(self: *Compiler, list: NodeList) CompileError!void {
        const props = self.parser.ast.getNodeList(list);
        try self.emitOpU16(.new_object, @intCast(props.len));
        for (props) |p_idx| {
            const p = self.parser.ast.getNode(p_idx);
            switch (p) {
                .property => |prop| {
                    // Get key name
                    const key_node = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key_node) {
                        .identifier => |id| id,
                        .string_literal => |id| id,
                        else => 0,
                    };
                    try self.emitOp(.dup); // dup object ref
                    try self.compileNode(prop.value);
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    try self.emitOpU16(.set_prop, ci);
                    try self.emitOp(.pop); // discard set_prop result, keep object
                },
                else => {},
            }
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
