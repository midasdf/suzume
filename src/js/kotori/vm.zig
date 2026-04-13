const std = @import("std");
const ctime = @cImport({
    @cInclude("time.h");
});
const bytecode_mod = @import("bytecode.zig");
const value_mod = @import("value.zig");
const object_mod = @import("object.zig");

const Bytecode = bytecode_mod.Bytecode;
const OpCode = bytecode_mod.OpCode;
const JsValue = value_mod.JsValue;
const JsObject = object_mod.JsObject;
const FunctionObj = object_mod.FunctionObj;
const UpvalueCell = object_mod.UpvalueCell;
const string_pool_mod = @import("string_pool.zig");
const StringId = string_pool_mod.StringId;
const StringPool = string_pool_mod.StringPool;

const CallFrame = struct {
    bc: *const Bytecode,
    ip: u32,
    base_sp: u32,
    upvalues: []?*UpvalueCell,
    this_val: JsValue = JsValue.undefined_val,
    has_this_on_stack: bool = false,
    is_construct: bool = false,
    async_promise: ?*JsObject = null, // Promise to resolve when async function returns
};

pub const VM = struct {
    frames: [256]CallFrame = undefined,
    frame_count: u32 = 0,
    stack: [4096]JsValue = undefined,
    sp: u32 = 0,
    globals: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    allocator: std.mem.Allocator,
    pool: *StringPool,
    // Heap tracking for cleanup
    objects: std.ArrayListUnmanaged(*JsObject) = .{},
    upvalue_cells: std.ArrayListUnmanaged(*UpvalueCell) = .{},
    closure_entries: std.ArrayListUnmanaged(ClosureEntry) = .{},
    // Built-in prototypes
    array_proto: ?*JsObject = null,
    string_proto: ?*JsObject = null,
    number_proto: ?*JsObject = null,
    element_proto: ?*JsObject = null,
    // DOM property interception (set by kotori_dom.zig)
    dom_get_prop: ?*const fn (*VM, *JsObject, StringId) ?JsValue = null,
    dom_set_prop: ?*const fn (*VM, *JsObject, StringId, JsValue) bool = null,
    // Timer queue (setTimeout/setInterval)
    timers: std.ArrayListUnmanaged(TimerEntry) = .{},
    next_timer_id: u32 = 1,

    // Promise / microtask queue
    microtasks: std.ArrayListUnmanaged(MicrotaskEntry) = .{},
    continuations: std.ArrayListUnmanaged(*Continuation) = .{},
    promise_proto: ?*JsObject = null,
    error_proto: ?*JsObject = null,

    // Symbol support
    next_symbol_id: u32 = 5, // 0-4 reserved for well-known symbols
    symbol_descriptions: std.AutoArrayHashMapUnmanaged(u32, ?StringId) = .{},

    // Generator support
    active_generator: ?*object_mod.GeneratorData = null,
    date_proto: ?*JsObject = null,

    // Console state
    console_timers: std.StringHashMapUnmanaged(i64) = .{},
    console_counts: std.StringHashMapUnmanaged(u32) = .{},
    console_indent: u32 = 0,

    // HTTP fetch callback (set by browser runtime)
    http_fetch_ctx: ?*anyopaque = null,
    http_fetch_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, method: []const u8, body: ?[]const u8) ?HttpFetchResult = null,

    // Module system
    module_exports: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    module_loader_ctx: ?*anyopaque = null,
    module_loader_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, specifier: []const u8) ?[]const u8 = null,

    // Exception handling
    try_stack: [32]TryContext = undefined,
    try_depth: u32 = 0,

    pub const TimerEntry = struct {
        id: u32,
        callback: JsValue,
        delay_ms: u32,
        is_interval: bool,
        fired: bool = false,
        cancelled: bool = false,
    };

    pub const MicrotaskEntry = union(enum) {
        /// Promise .then/.catch handler: call handler(arg), resolve result_promise
        promise_reaction: struct {
            handler: JsValue, // function to call (or undefined = passthrough)
            arg: JsValue, // resolved/rejected value
            result_promise: *JsObject, // promise returned by .then()
            is_reject: bool, // true if this is a rejection handler
        },
        /// Resume a suspended async function with a resolved value
        resume_async: struct {
            cont: *Continuation,
            value: JsValue,
            is_reject: bool,
        },
    };

    pub const HttpFetchResult = struct {
        status: u32,
        body: []u8, // allocated with the provided allocator
        content_type: []const u8,
    };

    pub const Continuation = struct {
        bc: *const Bytecode,
        ip: u32, // IP after the await_ opcode
        saved_stack: []JsValue, // locals + temporaries from base_sp to sp
        upvalues: []?*UpvalueCell,
        this_val: JsValue,
        async_promise: *JsObject, // the async function's promise
        has_this_on_stack: bool,
    };

    const TryContext = struct {
        catch_offset: u32,
        frame_idx: u32,
        sp: u32,
    };

    // Well-known Symbol IDs
    pub const SYMBOL_ITERATOR: u32 = 0;
    pub const SYMBOL_TO_PRIMITIVE: u32 = 1;
    pub const SYMBOL_HAS_INSTANCE: u32 = 2;
    pub const SYMBOL_TO_STRING_TAG: u32 = 3;
    pub const SYMBOL_ASYNC_ITERATOR: u32 = 4;

    pub fn init(allocator: std.mem.Allocator, bc: *const Bytecode, pool: *StringPool) VM {
        var self = VM{ .allocator = allocator, .pool = pool };
        // Push the top-level frame
        self.frames[0] = .{
            .bc = bc,
            .ip = 0,
            .base_sp = 0,
            .upvalues = &.{},
        };
        self.frame_count = 1;
        // Reserve stack slots for locals
        self.sp = bc.local_count;
        return self;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.microtasks.deinit(self.allocator);
        for (self.continuations.items) |cont| {
            self.allocator.free(cont.saved_stack);
            self.allocator.destroy(cont);
        }
        self.continuations.deinit(self.allocator);
        self.symbol_descriptions.deinit(self.allocator);
        for (self.closure_entries.items) |entry| {
            self.allocator.free(entry.upvalues);
        }
        self.closure_entries.deinit(self.allocator);
        for (self.objects.items) |obj| {
            obj.deinit(self.allocator);
            self.allocator.destroy(obj);
        }
        self.objects.deinit(self.allocator);
        for (self.upvalue_cells.items) |cell| {
            self.allocator.destroy(cell);
        }
        self.upvalue_cells.deinit(self.allocator);
        self.module_exports.deinit(self.allocator);
        self.console_timers.deinit(self.allocator);
        self.console_counts.deinit(self.allocator);
    }

    pub fn execute(self: *VM) !JsValue {
        return self.run(0);
    }

    /// Load new bytecode for execution, preserving globals and prototypes.
    /// Used for multi-eval (multiple <script> blocks in same global scope).
    pub fn loadCode(self: *VM, bc: *const Bytecode) void {
        self.frames[0] = .{
            .bc = bc,
            .ip = 0,
            .base_sp = 0,
            .upvalues = &.{},
        };
        self.frame_count = 1;
        self.sp = bc.local_count;
        self.try_depth = 0;
    }

    fn run(self: *VM, until_frame: u32) anyerror!JsValue {
        while (self.frame_count > until_frame) {
            const frame = &self.frames[self.frame_count - 1];
            if (frame.ip >= frame.bc.code.items.len) {
                // Fell off the end of top-level script
                if (self.frame_count == 1) break;
                return JsValue.undefined_val;
            }

            const op: OpCode = @enumFromInt(frame.bc.code.items[frame.ip]);
            frame.ip += 1;

            switch (op) {
                .load_const => {
                    const idx = self.readU16(frame);
                    self.push(frame.bc.constants.items[idx]);
                },
                .pop => _ = self.pop(),
                .dup => self.push(self.stack[self.sp - 1]),
                .swap => {
                    const tmp = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = self.stack[self.sp - 2];
                    self.stack[self.sp - 2] = tmp;
                },

                // ── Arithmetic ───────────────────────────────────────
                .add => {
                    const b = self.pop();
                    const a = self.pop();
                    if (a.isString() or b.isString()) {
                        self.push(try self.stringConcat(a, b));
                    } else {
                        self.push(JsValue.jsAdd(a, b));
                    }
                },
                .sub => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsSub(a, b)); },
                .mul => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsMul(a, b)); },
                .div => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsDiv(a, b)); },
                .mod => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsMod(a, b)); },
                .power => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsPow(a, b)); },
                .neg => self.push(JsValue.jsNeg(self.pop())),

                // ── Comparison ───────────────────────────────────────
                .eq => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsEq(a, b)); },
                .ne => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsNe(a, b)); },
                .strict_eq => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsStrictEq(a, b)); },
                .strict_ne => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsStrictNe(a, b)); },
                .lt => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsLt(a, b)); },
                .le => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsLe(a, b)); },
                .gt => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsGt(a, b)); },
                .ge => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsGe(a, b)); },

                // ── Logical / Bitwise ────────────────────────────────
                .not => self.push(JsValue.jsNot(self.pop())),
                .bit_not => self.push(JsValue.jsBitNot(self.pop())),
                .bit_and => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsBitAnd(a, b)); },
                .bit_or => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsBitOr(a, b)); },
                .bit_xor => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsBitXor(a, b)); },
                .shl => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsShl(a, b)); },
                .shr => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsShr(a, b)); },
                .ushr => { const b = self.pop(); const a = self.pop(); self.push(JsValue.jsUshr(a, b)); },

                .instanceof_ => {
                    const rhs = self.pop(); // constructor (right)
                    const lhs = self.pop(); // instance (left)
                    if (!rhs.isObject()) {
                        self.push(JsValue.initBool(false));
                        continue;
                    }
                    const ctor = rhs.asJsObject();
                    const proto_sid = try self.pool.intern("prototype");
                    const target_proto_val = ctor.getProperty(proto_sid);
                    if (target_proto_val == null or !target_proto_val.?.isObject()) {
                        self.push(JsValue.initBool(false));
                        continue;
                    }
                    const target_proto = target_proto_val.?.asJsObject();
                    if (lhs.isObject()) {
                        var cur: ?*JsObject = lhs.asJsObject().prototype;
                        var found = false;
                        while (cur) |p| {
                            if (p == target_proto) {
                                found = true;
                                break;
                            }
                            cur = p.prototype;
                        }
                        self.push(JsValue.initBool(found));
                    } else {
                        self.push(JsValue.initBool(false));
                    }
                },

                .in_ => {
                    const rhs = self.pop(); // object (right)
                    const lhs = self.pop(); // key (left)
                    if (!rhs.isObject()) {
                        self.push(JsValue.initBool(false));
                        continue;
                    }
                    const obj = rhs.asJsObject();
                    if (lhs.isString()) {
                        self.push(JsValue.initBool(obj.getProperty(lhs.asStringId()) != null));
                    } else if (lhs.isInt()) {
                        var buf: [20]u8 = undefined;
                        const key_str = std.fmt.bufPrint(&buf, "{d}", .{lhs.asInt()}) catch {
                            self.push(JsValue.initBool(false));
                            continue;
                        };
                        const key_id = try self.pool.intern(key_str);
                        self.push(JsValue.initBool(obj.getProperty(key_id) != null));
                    } else {
                        self.push(JsValue.initBool(false));
                    }
                },

                // ── Variables ────────────────────────────────────────
                .load_local => {
                    const slot = self.readU16(frame);
                    self.push(self.stack[frame.base_sp + slot]);
                },
                .store_local => {
                    const slot = self.readU16(frame);
                    self.stack[frame.base_sp + slot] = self.pop();
                },
                .load_global => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    if (self.globals.get(name_id)) |val| {
                        self.push(val);
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },
                .store_global => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const val = self.pop();
                    try self.globals.put(self.allocator, name_id, val);
                },
                .load_upvalue => {
                    const idx = self.readU16(frame);
                    if (idx < frame.upvalues.len) {
                        if (frame.upvalues[idx]) |cell| {
                            self.push(cell.value);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },
                .store_upvalue => {
                    const idx = self.readU16(frame);
                    const val = self.pop();
                    if (idx < frame.upvalues.len) {
                        if (frame.upvalues[idx]) |cell| {
                            cell.value = val;
                        }
                    }
                },

                // ── Control flow ─────────────────────────────────────
                .jump => {
                    const offset = self.readI16(frame);
                    frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                },
                .jump_if_false => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (!val.isTruthy()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },
                .jump_if_true => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (val.isTruthy()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },
                .jump_if_not_nullish => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (!val.isNull() and !val.isUndefined()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },
                .jump_if_nullish => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (val.isNull() or val.isUndefined()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },

                // ── Functions ────────────────────────────────────────
                .new_function => {
                    const ci = self.readU16(frame);
                    const template_val = frame.bc.constants.items[ci];
                    const template_obj = template_val.asJsObject();
                    const func_data = &template_obj.data.function;

                    // Create upvalue cells for this closure
                    var uv_array: []?*UpvalueCell = &.{};
                    if (func_data.upvalue_count > 0) {
                        uv_array = try self.allocator.alloc(?*UpvalueCell, func_data.upvalue_count);
                        for (func_data.upvalue_defs[0..func_data.upvalue_count], 0..) |def, i| {
                            if (def.is_local) {
                                // Capture parent's local — find or create cell
                                const stack_idx = frame.base_sp + def.index;
                                uv_array[i] = try self.getOrCreateUpvalue(stack_idx);
                            } else {
                                // Capture parent's upvalue
                                if (def.index < frame.upvalues.len) {
                                    uv_array[i] = frame.upvalues[def.index];
                                } else {
                                    uv_array[i] = null;
                                }
                            }
                        }
                    }

                    if (func_data.upvalue_count == 0) {
                        // No upvalues — just push the template directly
                        // Ensure function has a .prototype property for instanceof/new
                        const proto_sid = try self.pool.intern("prototype");
                        if (template_obj.getProperty(proto_sid) == null) {
                            const fn_proto = try self.createObj(.{});
                            try template_obj.setProperty(self.allocator, proto_sid, JsValue.initObject(fn_proto));
                        }
                        self.push(template_val);
                    } else {
                        // Create a closure object referencing (not owning) template's bytecode
                        const closure = try self.allocator.create(JsObject);
                        closure.* = .{
                            .obj_type = .function,
                            .data = .{ .function = .{
                                .bytecode = func_data.bytecode,
                                .param_count = func_data.param_count,
                                .local_count = func_data.local_count,
                                .name = func_data.name,
                                .upvalue_count = func_data.upvalue_count,
                                .upvalue_defs = func_data.upvalue_defs,
                                .owns_bytecode = false,
                                .is_async = func_data.is_async,
                            } },
                        };
                        try self.objects.append(self.allocator, closure);
                        // Ensure closure has a .prototype property for instanceof/new
                        const c_proto_sid = try self.pool.intern("prototype");
                        const fn_proto = try self.createObj(.{});
                        try closure.setProperty(self.allocator, c_proto_sid, JsValue.initObject(fn_proto));
                        self.push(JsValue.initObject(closure));
                        try self.storeClosureUpvalues(closure, uv_array);
                    }
                },

                .call => {
                    const arg_count = self.readU16(frame);
                    const func_val = self.stack[self.sp - 1 - arg_count];

                    if (!func_val.isObject()) {
                        self.sp -= arg_count + 1;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    const obj = func_val.asJsObject();

                    // Native function call
                    if (obj.obj_type == .native_function) {
                        const native = obj.data.native_fn;
                        const base = self.sp - arg_count;
                        const result = try native(@ptrCast(self), JsValue.undefined_val, self.stack[base..self.sp]);
                        self.sp = base - 1; // pop func
                        self.push(result);
                        continue;
                    }

                    if (obj.obj_type != .function) {
                        self.sp -= arg_count + 1;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    const func = &obj.data.function;

                    // Async generator function: create AsyncGeneratorObject
                    if (func.is_generator and func.is_async) {
                        const base = self.sp - arg_count;
                        var ag_init_args: []JsValue = &.{};
                        if (arg_count > 0) {
                            ag_init_args = try self.allocator.alloc(JsValue, arg_count);
                            @memcpy(ag_init_args, self.stack[base..self.sp]);
                        }
                        self.sp = base - 1;
                        const ag_obj = try self.createAsyncGeneratorObject(obj);
                        ag_obj.data.generator_data.init_args = ag_init_args;
                        self.push(JsValue.initObject(ag_obj));
                        continue;
                    }

                    // Generator function: don't execute, create GeneratorObject
                    if (func.is_generator) {
                        const base = self.sp - arg_count;
                        // Save args before popping
                        var init_args: []JsValue = &.{};
                        if (arg_count > 0) {
                            init_args = try self.allocator.alloc(JsValue, arg_count);
                            @memcpy(init_args, self.stack[base..self.sp]);
                        }
                        self.sp = base - 1; // pop args + func
                        const gen_obj = try self.createGeneratorObject(obj);
                        gen_obj.data.generator_data.init_args = init_args;
                        self.push(JsValue.initObject(gen_obj));
                        continue;
                    }

                    const base = self.sp - arg_count;

                    // Pad missing args with undefined
                    while (self.sp - base < func.param_count) {
                        self.push(JsValue.undefined_val);
                    }

                    // Reserve slots for extra locals (beyond params)
                    const extra_locals = if (func.local_count > func.param_count)
                        func.local_count - func.param_count
                    else
                        0;
                    var j: u16 = 0;
                    while (j < extra_locals) : (j += 1) {
                        self.push(JsValue.undefined_val);
                    }

                    // Look up closure upvalues
                    const uv_array = self.getClosureUpvalues(obj);

                    // For async functions: create a Promise
                    const async_p: ?*JsObject = if (func.is_async) try self.createPromiseObj() else null;

                    // Push call frame
                    self.frames[self.frame_count] = .{
                        .bc = &func.bytecode,
                        .ip = 0,
                        .base_sp = base,
                        .upvalues = uv_array,
                        .async_promise = async_p,
                    };
                    self.frame_count += 1;
                },

                .return_ => {
                    var result = self.pop();
                    const ret_frame = self.frames[self.frame_count - 1];
                    self.closeUpvaluesAbove(ret_frame.base_sp);
                    // For construct: if result is not an object, return this
                    if (ret_frame.is_construct and !result.isObject()) {
                        result = ret_frame.this_val;
                    }
                    self.sp = ret_frame.base_sp - 1; // pop function value
                    if (ret_frame.has_this_on_stack) self.sp -= 1; // pop this
                    self.frame_count -= 1;
                    self.push(result);
                },

                .return_undefined => {
                    const ret_frame = self.frames[self.frame_count - 1];
                    self.closeUpvaluesAbove(ret_frame.base_sp);
                    self.sp = ret_frame.base_sp - 1;
                    if (ret_frame.has_this_on_stack) self.sp -= 1;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) break;
                    // For construct: return this
                    if (ret_frame.is_construct) {
                        self.push(ret_frame.this_val);
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                .close_upvalue => {
                    const slot = self.readU16(frame);
                    const abs_slot = frame.base_sp + slot;
                    self.closeUpvalueAt(abs_slot);
                },

                // ── Objects ──────────────────────────────────────────
                .new_object => {
                    _ = self.readU16(frame); // prop count (informational)
                    const obj = try self.allocator.create(JsObject);
                    obj.* = .{};
                    try self.objects.append(self.allocator, obj);
                    self.push(JsValue.initObject(obj));
                },

                .get_prop => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const obj_val = self.pop();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        // globalThis proxy — forward property access to globals
                        if (obj.obj_type == .window_proxy) {
                            if (self.globals.get(name_id)) |global_val| {
                                self.push(global_val);
                                continue;
                            }
                        }
                        // DOM node/style property interception
                        if ((obj.obj_type == .dom_node or obj.obj_type == .dom_style) and self.dom_get_prop != null) {
                            if (self.dom_get_prop.?(self, obj, name_id)) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                        // Check for getter (own or prototype)
                        if (obj.getters) |getters| {
                            if (getters.get(name_id)) |getter_fn| {
                                const result = try self.callJsFunction(getter_fn, obj_val, &.{});
                                self.push(result);
                                continue;
                            }
                        }
                        if (obj.prototype) |proto| {
                            if (proto.getters) |getters| {
                                if (getters.get(name_id)) |getter_fn| {
                                    const result = try self.callJsFunction(getter_fn, obj_val, &.{});
                                    self.push(result);
                                    continue;
                                }
                            }
                        }
                        // Array .length
                        if (obj.obj_type == .array) {
                            if (self.pool.get(name_id)) |name_str| {
                                if (std.mem.eql(u8, name_str, "length")) {
                                    self.push(JsValue.initNumber(@floatFromInt(obj.data.array.items.len)));
                                    continue;
                                }
                            }
                        }
                        if (obj.getProperty(name_id)) |val| {
                            self.push(val);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else if (obj_val.isString()) {
                        // String .length
                        if (self.pool.get(name_id)) |name_str| {
                            if (std.mem.eql(u8, name_str, "length")) {
                                if (self.pool.get(obj_val.asStringId())) |s| {
                                    self.push(JsValue.initNumber(@floatFromInt(s.len)));
                                } else {
                                    self.push(JsValue.initNumber(0));
                                }
                                continue;
                            }
                        }
                        // String prototype methods
                        if (self.string_proto) |sp| {
                            if (sp.getProperty(name_id)) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                        self.push(JsValue.undefined_val);
                    } else if (obj_val.isNumber() or obj_val.isInt()) {
                        // Number prototype methods
                        if (self.number_proto) |num_p| {
                            if (num_p.getProperty(name_id)) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                        self.push(JsValue.undefined_val);
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                .define_getter => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const func = self.pop(); // getter function
                    const obj_val = self.peek(); // object stays on stack
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        if (obj.getters == null) {
                            obj.getters = .{};
                        }
                        try obj.getters.?.put(self.allocator, name_id, func);
                    }
                },
                .define_setter => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const func = self.pop(); // setter function
                    const obj_val = self.peek(); // object stays on stack
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        if (obj.setters == null) {
                            obj.setters = .{};
                        }
                        try obj.setters.?.put(self.allocator, name_id, func);
                    }
                },

                .set_prop => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const val = self.pop();
                    const obj_val = self.pop();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        // Check for setter (own or prototype)
                        if (obj.setters) |setters_map| {
                            if (setters_map.get(name_id)) |setter_fn| {
                                _ = try self.callJsFunction(setter_fn, obj_val, &.{val});
                                self.push(val);
                                continue;
                            }
                        }
                        if (obj.prototype) |proto| {
                            if (proto.setters) |setters_map| {
                                if (setters_map.get(name_id)) |setter_fn| {
                                    _ = try self.callJsFunction(setter_fn, obj_val, &.{val});
                                    self.push(val);
                                    continue;
                                }
                            }
                        }
                        // DOM node/style property interception
                        if ((obj.obj_type == .dom_node or obj.obj_type == .dom_style) and self.dom_set_prop != null) {
                            if (self.dom_set_prop.?(self, obj, name_id, val)) {
                                self.push(val);
                                continue;
                            }
                        }
                        // __proto__ assignment → set prototype
                        if (self.pool.get(name_id)) |name_str| {
                            if (std.mem.eql(u8, name_str, "__proto__") and val.isObject()) {
                                obj.prototype = val.asJsObject();
                                self.push(val);
                                continue;
                            }
                        }
                        try obj.setProperty(self.allocator, name_id, val);
                    }
                    self.push(val); // set_prop is expression, leaves value
                },

                .get_elem => {
                    const key = self.pop();
                    const obj_val = self.pop();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        // Symbol property access (walk prototype chain)
                        if (key.isSymbol()) {
                            const sym_id = key.asSymbolId();
                            if (self.findSymbolProp(obj, sym_id)) |val| {
                                self.push(val);
                                continue;
                            }
                            self.push(JsValue.undefined_val);
                            continue;
                        }
                        if (obj.obj_type == .array) {
                            const idx = self.toArrayIndex(key);
                            if (idx) |i| {
                                if (i < obj.data.array.items.len) {
                                    self.push(obj.data.array.items[i]);
                                    continue;
                                }
                            }
                        }
                        // Fall back to property access for string keys
                        if (key.isString()) {
                            if (obj.getProperty(key.asStringId())) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                    }
                    self.push(JsValue.undefined_val);
                },

                .set_elem => {
                    const val = self.pop();
                    const key = self.pop();
                    const obj_val = self.pop();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        // Symbol property access
                        if (key.isSymbol()) {
                            const sym_id = key.asSymbolId();
                            if (obj.symbol_props == null) {
                                obj.symbol_props = .{};
                            }
                            try obj.symbol_props.?.put(self.allocator, sym_id, val);
                            self.push(val);
                            continue;
                        }
                        if (obj.obj_type == .array) {
                            if (self.toArrayIndex(key)) |i| {
                                // Grow array if needed
                                while (obj.data.array.items.len <= i) {
                                    try obj.data.array.append(self.allocator, JsValue.undefined_val);
                                }
                                obj.data.array.items[i] = val;
                            }
                        } else if (key.isString()) {
                            try obj.setProperty(self.allocator, key.asStringId(), val);
                        }
                    }
                    self.push(val);
                },

                // ── Arrays ──────────────────────────────────────────
                .new_array => {
                    _ = self.readU16(frame); // capacity hint
                    const obj = try self.allocator.create(JsObject);
                    obj.* = .{
                        .obj_type = .array,
                        .data = .{ .array = .{} },
                        .prototype = self.array_proto,
                    };
                    try self.objects.append(self.allocator, obj);
                    self.push(JsValue.initObject(obj));
                },

                .array_push => {
                    const val = self.pop();
                    const arr_val = self.peek();
                    if (arr_val.isObject()) {
                        const obj = arr_val.asJsObject();
                        if (obj.obj_type == .array) {
                            try obj.data.array.append(self.allocator, val);
                        }
                    }
                },

                .spread_into_array => {
                    // Stack: [array, iterable] → [array]
                    const iterable = self.pop();
                    const arr_val = self.peek();
                    if (arr_val.isObject()) {
                        const arr = arr_val.asJsObject();
                        if (arr.obj_type == .array) {
                            if (iterable.isObject()) {
                                const iter_obj = iterable.asJsObject();
                                if (iter_obj.obj_type == .array) {
                                    // Fast path: array spread
                                    for (iter_obj.data.array.items) |item| {
                                        try arr.data.array.append(self.allocator, item);
                                    }
                                } else if (iter_obj.obj_type == .generator) {
                                    // Generator: collect all yielded values by calling .next() until done
                                    const g_next_id = try self.pool.intern("next");
                                    const g_done_id = try self.pool.intern("done");
                                    const g_value_id = try self.pool.intern("value");
                                    var g_iters: u32 = 0;
                                    while (g_iters < 10000) : (g_iters += 1) {
                                        const g_next_fn = iter_obj.getProperty(g_next_id) orelse break;
                                        const g_result = try self.callJsFunction(g_next_fn, iterable, &.{});
                                        if (!g_result.isObject()) break;
                                        const g_result_obj = g_result.asJsObject();
                                        const g_done = g_result_obj.getProperty(g_done_id) orelse JsValue.initBool(true);
                                        if (g_done.isTruthy()) break;
                                        const g_value = g_result_obj.getProperty(g_value_id) orelse JsValue.undefined_val;
                                        try arr.data.array.append(self.allocator, g_value);
                                    }
                                } else if (iter_obj.obj_type == .iterator) {
                                    // Iterator object: drain into array
                                    try self.drainIteratorIntoArray(iterable, arr);
                                } else if (self.findSymbolProp(iter_obj, SYMBOL_ITERATOR)) |iter_fn| {
                                    // Custom iterable with Symbol.iterator
                                    const iterator = try self.callJsFunction(iter_fn, iterable, &.{});
                                    try self.drainIteratorIntoArray(iterator, arr);
                                }
                            } else if (iterable.isString()) {
                                // Spread string into chars
                                if (self.pool.get(iterable.asStringId())) |s| {
                                    for (s) |c| {
                                        const char_str = try self.pool.intern(&.{c});
                                        try arr.data.array.append(self.allocator, JsValue.initString(char_str));
                                    }
                                }
                            }
                        }
                    }
                },

                .call_spread => {
                    // Stack: [func, args_array] → [result]
                    const args_val = self.pop();
                    const func = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            const result = try self.callJsFunction(func, JsValue.undefined_val, args_obj.data.array.items);
                            self.push(result);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                .call_method_spread => {
                    // Stack: [this, func, args_array] → [result]
                    const args_val = self.pop();
                    const func = self.pop();
                    const this_val = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            const result = try self.callJsFunction(func, this_val, args_obj.data.array.items);
                            self.push(result);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                .construct_spread => {
                    // Stack: [func, args_array] → [result]
                    const args_val = self.pop();
                    const func_val = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            // Create new object, set prototype, call constructor
                            if (func_val.isObject()) {
                                const ctor = func_val.asJsObject();
                                const new_obj = try self.createObj(.{});
                                // Set prototype
                                const proto_id = try self.pool.intern("prototype");
                                if (ctor.getProperty(proto_id)) |proto_val| {
                                    if (proto_val.isObject()) {
                                        new_obj.prototype = proto_val.asJsObject();
                                    }
                                }
                                _ = try self.callJsFunction(func_val, JsValue.initObject(new_obj), args_obj.data.array.items);
                                self.push(JsValue.initObject(new_obj));
                            } else {
                                self.push(JsValue.undefined_val);
                            }
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                // ── This / method calls / constructor ───────────────
                .load_this => {
                    self.push(frame.this_val);
                },

                .call_method => {
                    const arg_count = self.readU16(frame);
                    // Stack: [..., this_obj, method_func, arg0, ..., argN-1]
                    const func_pos = self.sp - 1 - arg_count;
                    const this_pos = func_pos - 1;
                    const func_val = self.stack[func_pos];
                    const this_val = self.stack[this_pos];

                    if (!func_val.isObject()) {
                        self.sp = this_pos;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    const obj = func_val.asJsObject();

                    // Native function
                    if (obj.obj_type == .native_function) {
                        const native = obj.data.native_fn;
                        const base = self.sp - arg_count;
                        const result = try native(@ptrCast(self), this_val, self.stack[base..self.sp]);
                        self.sp = this_pos;
                        self.push(result);
                        continue;
                    }

                    if (obj.obj_type != .function) {
                        self.sp = this_pos;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    const func = &obj.data.function;
                    const base = self.sp - arg_count;

                    while (self.sp - base < func.param_count) {
                        self.push(JsValue.undefined_val);
                    }

                    const extra_locals = if (func.local_count > func.param_count)
                        func.local_count - func.param_count
                    else
                        0;
                    var j: u16 = 0;
                    while (j < extra_locals) : (j += 1) {
                        self.push(JsValue.undefined_val);
                    }

                    const uv_array = self.getClosureUpvalues(obj);

                    const async_p: ?*JsObject = if (func.is_async) try self.createPromiseObj() else null;

                    self.frames[self.frame_count] = .{
                        .bc = &func.bytecode,
                        .ip = 0,
                        .base_sp = base,
                        .upvalues = uv_array,
                        .this_val = this_val,
                        .has_this_on_stack = true,
                        .async_promise = async_p,
                    };
                    self.frame_count += 1;
                },

                .construct => {
                    const arg_count = self.readU16(frame);
                    const func_val = self.stack[self.sp - 1 - arg_count];

                    if (!func_val.isObject()) {
                        self.sp -= arg_count + 1;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    const obj = func_val.asJsObject();

                    // Native function construct (e.g. new Map(), new Set(), new Error())
                    if (obj.obj_type == .native_function) {
                        const native = obj.data.native_fn;
                        const base = self.sp - arg_count;
                        const result = try native(@ptrCast(self), JsValue.undefined_val, self.stack[base..self.sp]);
                        // Set prototype from constructor's .prototype property
                        if (result.isObject()) {
                            const result_obj = result.asJsObject();
                            const p_sid = try self.pool.intern("prototype");
                            if (obj.getProperty(p_sid)) |proto_val| {
                                if (proto_val.isObject()) {
                                    result_obj.prototype = proto_val.asJsObject();
                                }
                            }
                        }
                        self.sp = base - 1; // pop func
                        self.push(result);
                        continue;
                    }

                    if (obj.obj_type != .function) {
                        self.sp -= arg_count + 1;
                        self.push(JsValue.undefined_val);
                        continue;
                    }

                    // Create the new object for `this`
                    const new_obj = try self.allocator.create(JsObject);
                    new_obj.* = .{};
                    // Set prototype from constructor's .prototype property
                    const proto_id = try self.pool.intern("prototype");
                    if (obj.getProperty(proto_id)) |proto_val| {
                        if (proto_val.isObject()) {
                            new_obj.prototype = proto_val.asJsObject();
                        }
                    }
                    try self.objects.append(self.allocator, new_obj);
                    const this_val = JsValue.initObject(new_obj);

                    const func = &obj.data.function;
                    const base = self.sp - arg_count;

                    while (self.sp - base < func.param_count) {
                        self.push(JsValue.undefined_val);
                    }

                    const extra_locals = if (func.local_count > func.param_count)
                        func.local_count - func.param_count
                    else
                        0;
                    var j: u16 = 0;
                    while (j < extra_locals) : (j += 1) {
                        self.push(JsValue.undefined_val);
                    }

                    const uv_array = self.getClosureUpvalues(obj);

                    self.frames[self.frame_count] = .{
                        .bc = &func.bytecode,
                        .ip = 0,
                        .base_sp = base,
                        .upvalues = uv_array,
                        .this_val = this_val,
                        .is_construct = true,
                    };
                    self.frame_count += 1;
                },

                // ── RegExp ───────────────────────────────────────────
                .new_regexp => {
                    const pat_ci = self.readU16(frame);
                    const flags_ci = self.readU16(frame);
                    const pattern_id = @as(StringId, @bitCast(frame.bc.constants.items[pat_ci].asInt()));
                    const flags_id = @as(StringId, @bitCast(frame.bc.constants.items[flags_ci].asInt()));
                    const re_obj = try self.createRegExp(pattern_id, flags_id);
                    self.push(JsValue.initObject(re_obj));
                },

                // ── Iteration ────────────────────────────────────────
                .get_length => {
                    const obj_val = self.pop();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        if (obj.obj_type == .array) {
                            self.push(JsValue.initNumber(@floatFromInt(obj.data.array.items.len)));
                            continue;
                        }
                    }
                    if (obj_val.isString()) {
                        if (self.pool.get(obj_val.asStringId())) |s| {
                            self.push(JsValue.initNumber(@floatFromInt(s.len)));
                            continue;
                        }
                    }
                    self.push(JsValue.initNumber(0));
                },

                .get_keys => {
                    const obj_val = self.pop();
                    const arr = try self.createArray();
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        for (obj.properties.keys()) |key_id| {
                            arr.data.array.append(self.allocator, JsValue.initString(key_id)) catch {};
                        }
                    }
                    self.push(JsValue.initObject(arr));
                },

                // ── Exception handling ───────────────────────────────
                .try_begin => {
                    const offset = self.readI16(frame);
                    const catch_ip: u32 = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    self.try_stack[self.try_depth] = .{
                        .catch_offset = catch_ip,
                        .frame_idx = self.frame_count - 1,
                        .sp = self.sp,
                    };
                    self.try_depth += 1;
                },

                .try_end => {
                    if (self.try_depth > 0) self.try_depth -= 1;
                },

                .throw_ => {
                    const thrown = self.pop();
                    if (self.try_depth == 0) {
                        // Uncaught exception
                        return JsValue.undefined_val;
                    }
                    self.try_depth -= 1;
                    const tc = self.try_stack[self.try_depth];
                    // Unwind frames to the try's frame
                    while (self.frame_count > tc.frame_idx + 1) {
                        const f = self.frames[self.frame_count - 1];
                        self.closeUpvaluesAbove(f.base_sp);
                        self.frame_count -= 1;
                    }
                    self.sp = tc.sp;
                    self.push(thrown); // catch parameter
                    self.frames[self.frame_count - 1].ip = tc.catch_offset;
                },

                // ── Async / Promise ──────────────────────────────────
                .get_async_iterator => {
                    const iterable = self.pop();
                    // Check Symbol.asyncIterator first
                    if (iterable.isObject()) {
                        const obj = iterable.asJsObject();
                        if (self.findSymbolProp(obj, SYMBOL_ASYNC_ITERATOR)) |iter_fn| {
                            const result = try self.callJsFunction(iter_fn, iterable, &.{});
                            self.push(result);
                            continue;
                        }
                    }
                    // Fallback to sync iterator
                    if (try self.resolveIterator(iterable)) |iterator| {
                        self.push(iterator);
                    } else {
                        const done_iter = try self.createObj(.{ .obj_type = .iterator });
                        done_iter.data = .{ .iterator_data = .{ .source = JsValue.undefined_val } };
                        try self.registerNativeMethod(done_iter, "next", &nativeArrayIteratorNext);
                        self.push(JsValue.initObject(done_iter));
                    }
                },

                .get_iterator => {
                    const iterable = self.pop();
                    if (try self.resolveIterator(iterable)) |iterator| {
                        self.push(iterator);
                    } else {
                        // Non-iterable: push a "done" iterator (empty loop, no crash)
                        const done_iter = try self.createObj(.{ .obj_type = .iterator });
                        done_iter.data = .{ .iterator_data = .{ .source = JsValue.undefined_val } };
                        try self.registerNativeMethod(done_iter, "next", &nativeArrayIteratorNext);
                        self.push(JsValue.initObject(done_iter));
                    }
                },

                .yield_delegate => {
                    if (self.active_generator) |gen| {
                        const iterable = self.pop();
                        const iterator = try self.resolveIterator(iterable) orelse {
                            self.push(JsValue.undefined_val);
                            continue;
                        };
                        // First call to inner iterator
                        const result = try self.callIteratorNext(iterator, JsValue.undefined_val);
                        const done = try self.getIterResultDone(result);
                        if (done) {
                            const value = try self.getIterResultValue(result);
                            self.push(value); // yield* expression result
                            continue;
                        }
                        // Not done: store delegate, suspend like yield_value
                        gen.delegate_iterator = iterator;
                        const yield_val = try self.getIterResultValue(result);
                        // Save state
                        const f = &self.frames[self.frame_count - 1];
                        const base = f.base_sp;
                        const stack_len = self.sp - base;
                        if (gen.saved_stack.len > 0) self.allocator.free(gen.saved_stack);
                        const saved = try self.allocator.alloc(JsValue, stack_len);
                        @memcpy(saved, self.stack[base..self.sp]);
                        gen.saved_ip = f.ip;
                        gen.saved_stack = saved;
                        gen.state = .suspended_yield;
                        self.frame_count -= 1;
                        self.sp = base;
                        if (self.sp > 0) self.sp -= 1;
                        return try self.createIterResult(yield_val, false);
                    } else {
                        _ = self.pop();
                        self.push(JsValue.undefined_val);
                    }
                },

                .yield_value => {
                    if (self.active_generator) |gen| {
                        const yield_val = self.pop();
                        // Save current execution state
                        const f = &self.frames[self.frame_count - 1];
                        const base = f.base_sp;
                        const stack_len = self.sp - base;
                        // Allocate and copy saved state
                        if (gen.saved_stack.len > 0) {
                            self.allocator.free(gen.saved_stack);
                        }
                        const saved = try self.allocator.alloc(JsValue, stack_len);
                        @memcpy(saved, self.stack[base..self.sp]);
                        gen.saved_ip = f.ip;
                        gen.saved_stack = saved;
                        gen.state = .suspended_yield;
                        // Pop frame — this makes run() exit (frame_count drops to until_frame)
                        self.frame_count -= 1;
                        self.sp = base;
                        // Pop the function slot that was pushed for the call
                        if (self.sp > 0) self.sp -= 1;
                        // Return {value, done: false}
                        const result = try self.createIterResult(yield_val, false);
                        return result;
                    } else {
                        // yield outside generator — just pass through
                        // (value already on stack)
                    }
                },

                .await_ => {
                    const val = self.pop();
                    // Non-promise or non-object: pass through synchronously
                    if (!val.isObject()) {
                        self.push(val);
                        continue;
                    }
                    const obj = val.asJsObject();
                    if (obj.obj_type != .promise) {
                        self.push(val);
                        continue;
                    }
                    const pd = &obj.data.promise_data;
                    switch (pd.state) {
                        .fulfilled => {
                            // Already resolved: push result synchronously
                            self.push(pd.result);
                        },
                        .rejected => {
                            // Already rejected: throw
                            self.push(pd.result);
                            // Re-use throw logic
                            if (self.try_depth == 0) return JsValue.undefined_val;
                            self.try_depth -= 1;
                            const tc = self.try_stack[self.try_depth];
                            while (self.frame_count > tc.frame_idx + 1) {
                                const f = self.frames[self.frame_count - 1];
                                self.closeUpvaluesAbove(f.base_sp);
                                self.frame_count -= 1;
                            }
                            self.sp = tc.sp;
                            self.push(pd.result);
                            self.frames[self.frame_count - 1].ip = tc.catch_offset;
                        },
                        .pending => {
                            // Suspend: save frame as continuation
                            const cur_frame = self.frames[self.frame_count - 1];
                            const async_promise = cur_frame.async_promise orelse {
                                // Not in an async function — just push undefined
                                self.push(JsValue.undefined_val);
                                continue;
                            };
                            const stack_size = self.sp - cur_frame.base_sp;
                            const saved = try self.allocator.alloc(JsValue, stack_size);
                            @memcpy(saved, self.stack[cur_frame.base_sp..self.sp]);

                            const cont = try self.allocator.create(Continuation);
                            cont.* = .{
                                .bc = cur_frame.bc,
                                .ip = cur_frame.ip, // already past await_ opcode
                                .saved_stack = saved,
                                .upvalues = cur_frame.upvalues,
                                .this_val = cur_frame.this_val,
                                .async_promise = async_promise,
                                .has_this_on_stack = cur_frame.has_this_on_stack,
                            };
                            try self.continuations.append(self.allocator, cont);

                            // Add continuation as handler on the awaited promise
                            const handler_promise = try self.createPromiseObj();
                            try obj.data.promise_data.handlers.append(self.allocator, .{
                                .on_fulfilled = JsValue.undefined_val, // marker: use resume_async
                                .on_rejected = JsValue.undefined_val,
                                .result_promise = handler_promise,
                            });
                            // Store continuation ref on the handler promise for lookup
                            const cont_id = try self.pool.intern("__continuation");
                            // Encode continuation pointer as a number
                            try handler_promise.setProperty(self.allocator, cont_id, JsValue.initNumber(@floatFromInt(@intFromPtr(cont))));

                            // Pop current frame (suspend)
                            self.closeUpvaluesAbove(cur_frame.base_sp);
                            self.sp = cur_frame.base_sp - 1; // pop function slot
                            if (cur_frame.has_this_on_stack) self.sp -= 1;
                            self.frame_count -= 1;
                            // Push async promise as result to caller
                            self.push(JsValue.initObject(async_promise));
                        },
                    }
                },

                .async_return => {
                    const result = self.pop();
                    const ret_frame = self.frames[self.frame_count - 1];
                    self.closeUpvaluesAbove(ret_frame.base_sp);

                    const async_p = ret_frame.async_promise;
                    // Resolve the async function's promise
                    if (async_p) |ap| {
                        try self.resolvePromise(ap, result);
                    }

                    self.sp = ret_frame.base_sp - 1;
                    if (ret_frame.has_this_on_stack) self.sp -= 1;
                    self.frame_count -= 1;

                    if (self.frame_count <= until_frame) {
                        break;
                    }
                    // Push the async function's promise as return value to caller
                    if (async_p) |ap| {
                        self.push(JsValue.initObject(ap));
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },

                // ── Special ──────────────────────────────────────────
                .typeof_ => {
                    const val = self.pop();
                    const type_str: []const u8 = if (val.isUndefined())
                        "undefined"
                    else if (val.isNull())
                        "object" // typeof null === "object" in JS
                    else if (val.isBool())
                        "boolean"
                    else if (val.isNumber() or val.isInt())
                        "number"
                    else if (val.isString())
                        "string"
                    else if (val.isSymbol())
                        "symbol"
                    else if (val.isObject()) blk: {
                        const o = val.asJsObject();
                        break :blk if (o.obj_type == .function or o.obj_type == .native_function) "function" else "object";
                    } else "undefined";
                    const sid = try self.pool.intern(type_str);
                    self.push(JsValue.initString(sid));
                },
                .void_ => {
                    _ = self.pop();
                    self.push(JsValue.undefined_val);
                },
                // ── Modules ──────────────────────────────────────────
                .import_binding => {
                    const module_ci = self.readU16(frame);
                    const name_ci = self.readU16(frame);
                    const module_sid = frame.bc.constants.items[module_ci].asStringId();
                    const binding_sid = frame.bc.constants.items[name_ci].asStringId();
                    // Try to load from module_exports (pre-linked) or trigger module load
                    if (self.module_exports.get(binding_sid)) |val| {
                        self.push(val);
                    } else {
                        // Module not loaded yet — try loader callback
                        if (self.module_loader_fn) |loader| {
                            if (self.pool.get(module_sid)) |specifier| {
                                if (loader(self.module_loader_ctx.?, self.allocator, specifier)) |_source| {
                                    _ = _source; // TODO: compile and execute module, then retry
                                }
                            }
                        }
                        // Fallback: push undefined for unresolved import
                        self.push(JsValue.undefined_val);
                    }
                },
                .export_binding => {
                    const name_ci = self.readU16(frame);
                    const name_sid = frame.bc.constants.items[name_ci].asStringId();
                    // The exported value is the current global with this name
                    const val = self.globals.get(name_sid) orelse JsValue.undefined_val;
                    self.module_exports.put(self.allocator, name_sid, val) catch {};
                },
                .export_default => {
                    const val = self.pop();
                    const default_sid = self.pool.intern("default") catch unreachable;
                    self.module_exports.put(self.allocator, default_sid, val) catch {};
                },

                .halt => {
                    if (self.sp > 0) return self.pop();
                    return JsValue.undefined_val;
                },
            }
        }

        if (self.sp > 0) return self.stack[self.sp - 1];
        return JsValue.undefined_val;
    }

    // ── Upvalue management ───────────────────────────────────────────

    const ClosureEntry = struct {
        closure: *JsObject,
        upvalues: []?*UpvalueCell,
    };

    fn storeClosureUpvalues(self: *VM, closure: *JsObject, uvs: []?*UpvalueCell) !void {
        try self.closure_entries.append(self.allocator, .{ .closure = closure, .upvalues = uvs });
    }

    fn getClosureUpvalues(self: *VM, closure: *JsObject) []?*UpvalueCell {
        for (self.closure_entries.items) |entry| {
            if (entry.closure == closure) return entry.upvalues;
        }
        return &.{};
    }

    fn getOrCreateUpvalue(self: *VM, stack_idx: u32) !*UpvalueCell {
        // Check existing open upvalues
        for (self.upvalue_cells.items) |cell| {
            if (cell.is_open and cell.stack_index == stack_idx) return cell;
        }
        // Create new
        const cell = try self.allocator.create(UpvalueCell);
        cell.* = .{
            .value = self.stack[stack_idx],
            .is_open = true,
            .stack_index = stack_idx,
        };
        try self.upvalue_cells.append(self.allocator, cell);
        return cell;
    }

    fn closeUpvaluesAbove(self: *VM, min_slot: u32) void {
        for (self.upvalue_cells.items) |cell| {
            if (cell.is_open and cell.stack_index >= min_slot) {
                cell.value = self.stack[cell.stack_index];
                cell.is_open = false;
            }
        }
    }

    fn closeUpvalueAt(self: *VM, slot: u32) void {
        for (self.upvalue_cells.items) |cell| {
            if (cell.is_open and cell.stack_index == slot) {
                cell.value = self.stack[slot];
                cell.is_open = false;
            }
        }
    }

    // ── Array helpers ─────────────────────────────────────────────────

    fn toArrayIndex(_: *VM, key: JsValue) ?usize {
        if (key.isInt()) {
            const i = key.asInt();
            if (i >= 0) return @intCast(i);
        }
        if (key.isNumber()) {
            const n = key.asNumber();
            const i: i64 = @intFromFloat(n);
            if (@as(f64, @floatFromInt(i)) == n and i >= 0) return @intCast(i);
        }
        return null;
    }

    // ── String helpers ────────────────────────────────────────────────

    fn stringConcat(self: *VM, a: JsValue, b: JsValue) !JsValue {
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const a_str = formatValue(self.pool, a, &buf_a);
        const b_str = formatValue(self.pool, b, &buf_b);
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, a_str);
        try buf.appendSlice(self.allocator, b_str);
        const new_id = try self.pool.intern(buf.items);
        return JsValue.initString(new_id);
    }

    fn formatValue(pool: *StringPool, val: JsValue, buf: *[64]u8) []const u8 {
        if (val.isString()) return pool.get(val.asStringId()) orelse "";
        if (val.isInt()) return std.fmt.bufPrint(buf, "{d}", .{val.asInt()}) catch "0";
        if (val.isNumber()) {
            const n = val.asNumber();
            if (std.math.isNan(n)) return "NaN";
            if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
            // Whole-number floats: format as integer for clean output
            if (n == @trunc(n) and @abs(n) < 1e15) {
                const i: i64 = @intFromFloat(n);
                return std.fmt.bufPrint(buf, "{d}", .{i}) catch "0";
            }
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch "0";
        }
        if (val.isBool()) return if (val.asBool()) "true" else "false";
        if (val.isNull()) return "null";
        if (val.isUndefined()) return "undefined";
        if (val.isObject()) {
            const obj = val.asJsObject();
            if (obj.obj_type == .function or obj.obj_type == .native_function) return "[Function]";
            if (obj.obj_type == .array) return "[Array]";
            if (obj.obj_type == .dom_node) return "[object HTMLElement]";
            if (obj.obj_type == .dom_style) return "[object CSSStyleDeclaration]";
            if (obj.obj_type == .promise) return "[object Promise]";
            return "[object Object]";
        }
        return "";
    }

    // ── Stack helpers ────────────────────────────────────────────────

    inline fn push(self: *VM, val: JsValue) void {
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    inline fn pop(self: *VM) JsValue {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    inline fn peek(self: *VM) JsValue {
        return self.stack[self.sp - 1];
    }

    fn readU16(_: *VM, frame: *CallFrame) u16 {
        const bytes: *const [2]u8 = @ptrCast(frame.bc.code.items[frame.ip..][0..2]);
        frame.ip += 2;
        return std.mem.bytesToValue(u16, bytes);
    }

    fn readI16(_: *VM, frame: *CallFrame) i16 {
        const bytes: *const [2]u8 = @ptrCast(frame.bc.code.items[frame.ip..][0..2]);
        frame.ip += 2;
        return std.mem.bytesToValue(i16, bytes);
    }

    // ── Built-in objects ────────────────────────────────────────────

    pub fn initBuiltins(self: *VM) !void {
        // ── console ──
        const console_obj = try self.createObj(.{});
        try self.registerNativeMethod(console_obj, "log", &nativeConsoleLog);
        try self.registerNativeMethod(console_obj, "warn", &nativeConsoleWarn);
        try self.registerNativeMethod(console_obj, "error", &nativeConsoleError);
        try self.registerNativeMethod(console_obj, "info", &nativeConsoleInfo);
        try self.registerNativeMethod(console_obj, "debug", &nativeConsoleDebug);
        try self.registerNativeMethod(console_obj, "dir", &nativeConsoleDir);
        try self.registerNativeMethod(console_obj, "assert", &nativeConsoleAssert);
        try self.registerNativeMethod(console_obj, "time", &nativeConsoleTime);
        try self.registerNativeMethod(console_obj, "timeEnd", &nativeConsoleTimeEnd);
        try self.registerNativeMethod(console_obj, "timeLog", &nativeConsoleTimeLog);
        try self.registerNativeMethod(console_obj, "count", &nativeConsoleCount);
        try self.registerNativeMethod(console_obj, "countReset", &nativeConsoleCountReset);
        try self.registerNativeMethod(console_obj, "clear", &nativeConsoleNoOp);
        try self.registerNativeMethod(console_obj, "trace", &nativeConsoleTrace);
        try self.registerNativeMethod(console_obj, "group", &nativeConsoleGroup);
        try self.registerNativeMethod(console_obj, "groupCollapsed", &nativeConsoleGroup);
        try self.registerNativeMethod(console_obj, "groupEnd", &nativeConsoleGroupEnd);
        try self.registerNativeMethod(console_obj, "table", &nativeConsoleTable);

        const console_id = try self.pool.intern("console");
        try self.globals.put(self.allocator, console_id, JsValue.initObject(console_obj));

        // ── Array.prototype ──
        self.array_proto = try self.createObj(.{});
        const ap = self.array_proto.?;
        try self.registerNativeMethod(ap, "push", &nativeArrayPush);
        try self.registerNativeMethod(ap, "pop", &nativeArrayPop);
        try self.registerNativeMethod(ap, "shift", &nativeArrayShift);
        try self.registerNativeMethod(ap, "indexOf", &nativeArrayIndexOf);
        try self.registerNativeMethod(ap, "includes", &nativeArrayIncludes);
        try self.registerNativeMethod(ap, "join", &nativeArrayJoin);
        try self.registerNativeMethod(ap, "reverse", &nativeArrayReverse);
        try self.registerNativeMethod(ap, "slice", &nativeArraySlice);
        try self.registerNativeMethod(ap, "concat", &nativeArrayConcat);
        try self.registerNativeMethod(ap, "forEach", &nativeArrayForEach);
        try self.registerNativeMethod(ap, "map", &nativeArrayMap);
        try self.registerNativeMethod(ap, "filter", &nativeArrayFilter);
        try self.registerNativeMethod(ap, "reduce", &nativeArrayReduce);
        try self.registerNativeMethod(ap, "reduceRight", &nativeArrayReduceRight);
        try self.registerNativeMethod(ap, "find", &nativeArrayFind);
        try self.registerNativeMethod(ap, "findIndex", &nativeArrayFindIndex);
        try self.registerNativeMethod(ap, "some", &nativeArraySome);
        try self.registerNativeMethod(ap, "every", &nativeArrayEvery);
        try self.registerNativeMethod(ap, "sort", &nativeArraySort);
        try self.registerNativeMethod(ap, "splice", &nativeArraySplice);
        try self.registerNativeMethod(ap, "flat", &nativeArrayFlat);
        try self.registerNativeMethod(ap, "flatMap", &nativeArrayFlatMap);
        try self.registerNativeMethod(ap, "fill", &nativeArrayFill);
        try self.registerNativeMethod(ap, "at", &nativeArrayAt);
        try self.registerNativeMethod(ap, "unshift", &nativeArrayUnshift);
        try self.registerNativeMethod(ap, "keys", &nativeArrayKeys);
        try self.registerNativeMethod(ap, "values", &nativeArrayValues);
        try self.registerNativeMethod(ap, "entries", &nativeArrayEntries);
        try self.registerNativeMethod(ap, "toString", &nativeArrayToString);
        // Register Symbol.iterator on array prototype
        if (ap.symbol_props == null) ap.symbol_props = .{};
        const arr_iter_fn = try self.createNativeFn(&nativeArraySymbolIterator);
        try ap.symbol_props.?.put(self.allocator, SYMBOL_ITERATOR, JsValue.initObject(arr_iter_fn));

        // ── String.prototype ──
        self.string_proto = try self.createObj(.{});
        const sp = self.string_proto.?;
        try self.registerNativeMethod(sp, "charAt", &nativeStringCharAt);
        try self.registerNativeMethod(sp, "charCodeAt", &nativeStringCharCodeAt);
        try self.registerNativeMethod(sp, "indexOf", &nativeStringIndexOf);
        try self.registerNativeMethod(sp, "includes", &nativeStringIncludes);
        try self.registerNativeMethod(sp, "substring", &nativeStringSubstring);
        try self.registerNativeMethod(sp, "slice", &nativeStringSlice);
        try self.registerNativeMethod(sp, "split", &nativeStringSplit);
        try self.registerNativeMethod(sp, "trim", &nativeStringTrim);
        try self.registerNativeMethod(sp, "toUpperCase", &nativeStringToUpperCase);
        try self.registerNativeMethod(sp, "toLowerCase", &nativeStringToLowerCase);
        try self.registerNativeMethod(sp, "startsWith", &nativeStringStartsWith);
        try self.registerNativeMethod(sp, "endsWith", &nativeStringEndsWith);
        try self.registerNativeMethod(sp, "replace", &nativeStringReplace);
        try self.registerNativeMethod(sp, "match", &nativeStringMatch);
        try self.registerNativeMethod(sp, "search", &nativeStringSearch);
        try self.registerNativeMethod(sp, "repeat", &nativeStringRepeat);
        try self.registerNativeMethod(sp, "padStart", &nativeStringPadStart);
        try self.registerNativeMethod(sp, "padEnd", &nativeStringPadEnd);
        try self.registerNativeMethod(sp, "trimStart", &nativeStringTrimStart);
        try self.registerNativeMethod(sp, "trimEnd", &nativeStringTrimEnd);
        try self.registerNativeMethod(sp, "replaceAll", &nativeStringReplaceAll);
        try self.registerNativeMethod(sp, "lastIndexOf", &nativeStringLastIndexOf);
        try self.registerNativeMethod(sp, "concat", &nativeStringConcat);
        try self.registerNativeMethod(sp, "at", &nativeStringAt);

        // ── Number.prototype ──
        self.number_proto = try self.createObj(.{});
        const np = self.number_proto.?;
        try self.registerNativeMethod(np, "toFixed", &nativeNumberToFixed);
        try self.registerNativeMethod(np, "toString", &nativeNumberToString);
        try self.registerNativeMethod(np, "toPrecision", &nativeNumberToPrecision);
        try self.registerNativeMethod(np, "toExponential", &nativeNumberToExponential);
        try self.registerNativeMethod(np, "valueOf", &nativeNumberValueOf);

        // ── Number constructor ──
        {
            const num_ctor = try self.createObj(.{});
            try self.registerNativeMethod(num_ctor, "isNaN", &nativeNumberIsNaN);
            try self.registerNativeMethod(num_ctor, "isFinite", &nativeNumberIsFinite);
            try self.registerNativeMethod(num_ctor, "isInteger", &nativeNumberIsInteger);
            try self.registerNativeMethod(num_ctor, "parseInt", &nativeParseInt);
            try self.registerNativeMethod(num_ctor, "parseFloat", &nativeParseFloat);
            try num_ctor.setProperty(self.allocator, try self.pool.intern("MAX_SAFE_INTEGER"), JsValue.initNumber(9007199254740991.0));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("MIN_SAFE_INTEGER"), JsValue.initNumber(-9007199254740991.0));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("EPSILON"), JsValue.initNumber(2.220446049250313e-16));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("NaN"), JsValue.nan_val);
            try num_ctor.setProperty(self.allocator, try self.pool.intern("POSITIVE_INFINITY"), JsValue.initNumber(std.math.inf(f64)));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("NEGATIVE_INFINITY"), JsValue.initNumber(-std.math.inf(f64)));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("MAX_VALUE"), JsValue.initNumber(std.math.floatMax(f64)));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("MIN_VALUE"), JsValue.initNumber(std.math.floatMin(f64)));
            try num_ctor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(np));
            try self.globals.put(self.allocator, try self.pool.intern("Number"), JsValue.initObject(num_ctor));
        }

        // ── Object ──
        const obj_constructor = try self.createObj(.{});
        try self.registerNativeMethod(obj_constructor, "keys", &nativeObjectKeys);
        try self.registerNativeMethod(obj_constructor, "values", &nativeObjectValues);
        try self.registerNativeMethod(obj_constructor, "entries", &nativeObjectEntries);
        try self.registerNativeMethod(obj_constructor, "assign", &nativeObjectAssign);
        try self.registerNativeMethod(obj_constructor, "create", &nativeObjectCreate);
        try self.registerNativeMethod(obj_constructor, "defineProperty", &nativeObjectDefineProperty);
        try self.registerNativeMethod(obj_constructor, "defineProperties", &nativeObjectDefineProperties);
        try self.registerNativeMethod(obj_constructor, "setPrototypeOf", &nativeObjectSetPrototypeOf);
        try self.registerNativeMethod(obj_constructor, "getPrototypeOf", &nativeObjectGetPrototypeOf);
        try self.registerNativeMethod(obj_constructor, "getOwnPropertyNames", &nativeObjectKeys); // same as keys for now
        try self.registerNativeMethod(obj_constructor, "getOwnPropertyDescriptor", &nativeObjectGetOwnPropertyDescriptor);
        try self.registerNativeMethod(obj_constructor, "freeze", &nativeObjectPassthrough);
        try self.registerNativeMethod(obj_constructor, "seal", &nativeObjectPassthrough);
        try self.registerNativeMethod(obj_constructor, "preventExtensions", &nativeObjectPassthrough);
        try self.registerNativeMethod(obj_constructor, "isFrozen", &nativeReturnFalse);
        try self.registerNativeMethod(obj_constructor, "isSealed", &nativeReturnFalse);
        try self.registerNativeMethod(obj_constructor, "isExtensible", &nativeReturnTrue);
        const obj_id = try self.pool.intern("Object");
        try self.globals.put(self.allocator, obj_id, JsValue.initObject(obj_constructor));

        // ── Array constructor ──
        const arr_constructor = try self.createObj(.{});
        try self.registerNativeMethod(arr_constructor, "isArray", &nativeArrayIsArray);
        try self.registerNativeMethod(arr_constructor, "from", &nativeArrayFrom);
        // Array.prototype accessible from constructor
        const proto_id = try self.pool.intern("prototype");
        try arr_constructor.setProperty(self.allocator, proto_id, JsValue.initObject(ap));
        const arr_id = try self.pool.intern("Array");
        try self.globals.put(self.allocator, arr_id, JsValue.initObject(arr_constructor));

        // ── Map constructor ──
        const map_constructor = try self.createNativeFn(&nativeMapConstructor);
        const map_id = try self.pool.intern("Map");
        try self.globals.put(self.allocator, map_id, JsValue.initObject(map_constructor));

        // ── Set constructor ──
        const set_constructor = try self.createNativeFn(&nativeSetConstructor);
        const set_id = try self.pool.intern("Set");
        try self.globals.put(self.allocator, set_id, JsValue.initObject(set_constructor));

        // ── JSON ──
        const json_obj = try self.createObj(.{});
        try self.registerNativeMethod(json_obj, "stringify", &nativeJsonStringify);
        try self.registerNativeMethod(json_obj, "parse", &nativeJsonParse);
        const json_id = try self.pool.intern("JSON");
        try self.globals.put(self.allocator, json_id, JsValue.initObject(json_obj));

        // ── Math ──
        const math_obj = try self.createObj(.{});
        try self.registerNativeMethod(math_obj, "floor", &nativeMathFloor);
        try self.registerNativeMethod(math_obj, "ceil", &nativeMathCeil);
        try self.registerNativeMethod(math_obj, "round", &nativeMathRound);
        try self.registerNativeMethod(math_obj, "abs", &nativeMathAbs);
        try self.registerNativeMethod(math_obj, "min", &nativeMathMin);
        try self.registerNativeMethod(math_obj, "max", &nativeMathMax);
        try self.registerNativeMethod(math_obj, "random", &nativeMathRandom);
        try self.registerNativeMethod(math_obj, "pow", &nativeMathPow);
        try self.registerNativeMethod(math_obj, "sqrt", &nativeMathSqrt);
        try self.registerNativeMethod(math_obj, "log", &nativeMathLog);
        try self.registerNativeMethod(math_obj, "log10", &nativeMathLog10);
        try self.registerNativeMethod(math_obj, "trunc", &nativeMathTrunc);
        try self.registerNativeMethod(math_obj, "sign", &nativeMathSign);
        // Math constants
        const pi_id = try self.pool.intern("PI");
        try math_obj.setProperty(self.allocator, pi_id, JsValue.initNumber(std.math.pi));
        const e_id = try self.pool.intern("E");
        try math_obj.setProperty(self.allocator, e_id, JsValue.initNumber(std.math.e));
        const inf_id = try self.pool.intern("Infinity");
        try math_obj.setProperty(self.allocator, inf_id, JsValue.initNumber(std.math.inf(f64)));
        const math_id = try self.pool.intern("Math");
        try self.globals.put(self.allocator, math_id, JsValue.initObject(math_obj));

        // ── Global functions ──
        const parse_int_obj = try self.createNativeFn(&nativeParseInt);
        const parse_int_id = try self.pool.intern("parseInt");
        try self.globals.put(self.allocator, parse_int_id, JsValue.initObject(parse_int_obj));

        const parse_float_obj = try self.createNativeFn(&nativeParseFloat);
        const parse_float_id = try self.pool.intern("parseFloat");
        try self.globals.put(self.allocator, parse_float_id, JsValue.initObject(parse_float_obj));

        const is_nan_obj = try self.createNativeFn(&nativeIsNaN);
        const is_nan_id = try self.pool.intern("isNaN");
        try self.globals.put(self.allocator, is_nan_id, JsValue.initObject(is_nan_obj));

        const is_finite_obj = try self.createNativeFn(&nativeIsFinite);
        const is_finite_id = try self.pool.intern("isFinite");
        try self.globals.put(self.allocator, is_finite_id, JsValue.initObject(is_finite_obj));

        // ── setTimeout / setInterval / clearTimeout / clearInterval ──
        const set_timeout_obj = try self.createNativeFn(&nativeSetTimeout);
        const set_timeout_id = try self.pool.intern("setTimeout");
        try self.globals.put(self.allocator, set_timeout_id, JsValue.initObject(set_timeout_obj));

        const set_interval_obj = try self.createNativeFn(&nativeSetInterval);
        const set_interval_id = try self.pool.intern("setInterval");
        try self.globals.put(self.allocator, set_interval_id, JsValue.initObject(set_interval_obj));

        const clear_timeout_obj = try self.createNativeFn(&nativeClearTimer);
        const clear_timeout_id = try self.pool.intern("clearTimeout");
        try self.globals.put(self.allocator, clear_timeout_id, JsValue.initObject(clear_timeout_obj));

        const clear_interval_obj = try self.createNativeFn(&nativeClearTimer);
        const clear_interval_id = try self.pool.intern("clearInterval");
        try self.globals.put(self.allocator, clear_interval_id, JsValue.initObject(clear_interval_obj));

        // ── Promise ──
        {
            // Promise prototype with then/catch/finally
            const proto = try self.createObj(.{});
            self.promise_proto = proto;
            try self.registerNativeMethod(proto, "then", &nativePromiseThen);
            try self.registerNativeMethod(proto, "catch", &nativePromiseCatch);
            try self.registerNativeMethod(proto, "finally", &nativePromiseFinally);

            // Promise constructor
            const promise_ctor = try self.createNativeFn(&nativePromiseConstructor);
            const promise_id = try self.pool.intern("Promise");
            try self.globals.put(self.allocator, promise_id, JsValue.initObject(promise_ctor));

            // Promise.resolve / Promise.reject (static methods on constructor)
            try self.registerNativeMethod(promise_ctor, "resolve", &nativePromiseResolve);
            try self.registerNativeMethod(promise_ctor, "reject", &nativePromiseReject);
            try self.registerNativeMethod(promise_ctor, "all", &nativePromiseAll);
            try self.registerNativeMethod(promise_ctor, "race", &nativePromiseRace);
            try self.registerNativeMethod(promise_ctor, "allSettled", &nativePromiseAllSettled);
            try self.registerNativeMethod(promise_ctor, "any", &nativePromiseAny);
        }

        // ── fetch ──
        {
            const fetch_obj = try self.createNativeFn(&nativeFetch);
            const fetch_id = try self.pool.intern("fetch");
            try self.globals.put(self.allocator, fetch_id, JsValue.initObject(fetch_obj));
        }

        // ── Date ──
        {
            const date_proto = try self.createObj(.{});
            self.date_proto = date_proto;
            // Getters (local)
            try self.registerNativeMethod(date_proto, "getTime", &nativeDateGetTime);
            try self.registerNativeMethod(date_proto, "getFullYear", &nativeDateGetFullYear);
            try self.registerNativeMethod(date_proto, "getMonth", &nativeDateGetMonth);
            try self.registerNativeMethod(date_proto, "getDate", &nativeDateGetDate);
            try self.registerNativeMethod(date_proto, "getDay", &nativeDateGetDay);
            try self.registerNativeMethod(date_proto, "getHours", &nativeDateGetHours);
            try self.registerNativeMethod(date_proto, "getMinutes", &nativeDateGetMinutes);
            try self.registerNativeMethod(date_proto, "getSeconds", &nativeDateGetSeconds);
            try self.registerNativeMethod(date_proto, "getMilliseconds", &nativeDateGetMilliseconds);
            try self.registerNativeMethod(date_proto, "getTimezoneOffset", &nativeDateGetTimezoneOffset);
            // Getters (UTC)
            try self.registerNativeMethod(date_proto, "getUTCFullYear", &nativeDateGetUTCFullYear);
            try self.registerNativeMethod(date_proto, "getUTCMonth", &nativeDateGetUTCMonth);
            try self.registerNativeMethod(date_proto, "getUTCDate", &nativeDateGetUTCDate);
            try self.registerNativeMethod(date_proto, "getUTCDay", &nativeDateGetUTCDay);
            try self.registerNativeMethod(date_proto, "getUTCHours", &nativeDateGetUTCHours);
            try self.registerNativeMethod(date_proto, "getUTCMinutes", &nativeDateGetUTCMinutes);
            try self.registerNativeMethod(date_proto, "getUTCSeconds", &nativeDateGetUTCSeconds);
            try self.registerNativeMethod(date_proto, "getUTCMilliseconds", &nativeDateGetUTCMilliseconds);
            // Setters (local)
            try self.registerNativeMethod(date_proto, "setTime", &nativeDateSetTime);
            try self.registerNativeMethod(date_proto, "setFullYear", &nativeDateSetFullYear);
            try self.registerNativeMethod(date_proto, "setMonth", &nativeDateSetMonth);
            try self.registerNativeMethod(date_proto, "setDate", &nativeDateSetDate);
            try self.registerNativeMethod(date_proto, "setHours", &nativeDateSetHours);
            try self.registerNativeMethod(date_proto, "setMinutes", &nativeDateSetMinutes);
            try self.registerNativeMethod(date_proto, "setSeconds", &nativeDateSetSeconds);
            try self.registerNativeMethod(date_proto, "setMilliseconds", &nativeDateSetMilliseconds);
            // Setters (UTC)
            try self.registerNativeMethod(date_proto, "setUTCFullYear", &nativeDateSetUTCFullYear);
            try self.registerNativeMethod(date_proto, "setUTCMonth", &nativeDateSetUTCMonth);
            try self.registerNativeMethod(date_proto, "setUTCDate", &nativeDateSetUTCDate);
            try self.registerNativeMethod(date_proto, "setUTCHours", &nativeDateSetUTCHours);
            try self.registerNativeMethod(date_proto, "setUTCMinutes", &nativeDateSetUTCMinutes);
            try self.registerNativeMethod(date_proto, "setUTCSeconds", &nativeDateSetUTCSeconds);
            try self.registerNativeMethod(date_proto, "setUTCMilliseconds", &nativeDateSetUTCMilliseconds);
            // Conversion
            try self.registerNativeMethod(date_proto, "toISOString", &nativeDateToISOString);
            try self.registerNativeMethod(date_proto, "toJSON", &nativeDateToISOString);
            try self.registerNativeMethod(date_proto, "toString", &nativeDateToString);
            try self.registerNativeMethod(date_proto, "toDateString", &nativeDateToDateString);
            try self.registerNativeMethod(date_proto, "toTimeString", &nativeDateToTimeString);
            try self.registerNativeMethod(date_proto, "toUTCString", &nativeDateToUTCString);
            try self.registerNativeMethod(date_proto, "toLocaleDateString", &nativeDateToLocaleDateString);
            try self.registerNativeMethod(date_proto, "toLocaleTimeString", &nativeDateToLocaleTimeString);
            try self.registerNativeMethod(date_proto, "toLocaleString", &nativeDateToLocaleString);
            try self.registerNativeMethod(date_proto, "valueOf", &nativeDateValueOf);
            // Constructor
            const date_ctor = try self.createNativeFn(&nativeDateConstructor);
            try date_ctor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(date_proto));
            try self.registerNativeMethod(date_ctor, "now", &nativeDateNow);
            try self.registerNativeMethod(date_ctor, "parse", &nativeDateParse);
            try self.registerNativeMethod(date_ctor, "UTC", &nativeDateUTC);
            try self.globals.put(self.allocator, try self.pool.intern("Date"), JsValue.initObject(date_ctor));
        }

        // ── Error constructors ──
        {
            const error_proto = try self.createObj(.{});
            self.error_proto = error_proto;
            const name_sid = try self.pool.intern("name");
            const msg_sid = try self.pool.intern("message");
            try error_proto.setProperty(self.allocator, name_sid, JsValue.initString(try self.pool.intern("Error")));
            try error_proto.setProperty(self.allocator, msg_sid, JsValue.initString(try self.pool.intern("")));
            try self.registerNativeMethod(error_proto, "toString", &nativeErrorToString);

            const error_ctor = try self.createNativeFn(&nativeErrorConstructor);
            const ctor_proto_sid = try self.pool.intern("prototype");
            try error_ctor.setProperty(self.allocator, ctor_proto_sid, JsValue.initObject(error_proto));
            try self.globals.put(self.allocator, try self.pool.intern("Error"), JsValue.initObject(error_ctor));

            // Sub-error types
            const error_types = [_][]const u8{ "TypeError", "ReferenceError", "SyntaxError", "RangeError", "URIError", "EvalError", "AggregateError" };
            for (error_types) |err_name| {
                const sub_proto = try self.createObj(.{});
                sub_proto.prototype = error_proto;
                try sub_proto.setProperty(self.allocator, name_sid, JsValue.initString(try self.pool.intern(err_name)));
                try sub_proto.setProperty(self.allocator, msg_sid, JsValue.initString(try self.pool.intern("")));
                try self.registerNativeMethod(sub_proto, "toString", &nativeErrorToString);

                const sub_ctor = try self.createNativeFn(&nativeErrorConstructor);
                try sub_ctor.setProperty(self.allocator, ctor_proto_sid, JsValue.initObject(sub_proto));
                try self.globals.put(self.allocator, try self.pool.intern(err_name), JsValue.initObject(sub_ctor));
            }
        }

        // ── Global constants ──
        const undef_id = try self.pool.intern("undefined");
        try self.globals.put(self.allocator, undef_id, JsValue.undefined_val);
        const null_id = try self.pool.intern("null");
        try self.globals.put(self.allocator, null_id, JsValue.null_val);
        const nan_id = try self.pool.intern("NaN");
        try self.globals.put(self.allocator, nan_id, JsValue.nan_val);
        try self.globals.put(self.allocator, inf_id, JsValue.initNumber(std.math.inf(f64)));

        // ── WeakMap / WeakSet ──
        {
            const wm_ctor = try self.createNativeFn(&nativeWeakMapConstructor);
            try self.globals.put(self.allocator, try self.pool.intern("WeakMap"), JsValue.initObject(wm_ctor));
            const ws_ctor = try self.createNativeFn(&nativeWeakSetConstructor);
            try self.globals.put(self.allocator, try self.pool.intern("WeakSet"), JsValue.initObject(ws_ctor));
        }

        // ── globalThis ──
        const global_this = try self.createObj(.{ .obj_type = .window_proxy });
        try self.globals.put(self.allocator, try self.pool.intern("globalThis"), JsValue.initObject(global_this));

        // ── Symbol ──
        {
            const symbol_fn = try self.createNativeFn(&nativeSymbolConstructor);
            try self.globals.put(self.allocator, try self.pool.intern("Symbol"), JsValue.initObject(symbol_fn));

            // Symbol.for, Symbol.keyFor
            try self.registerNativeMethod(symbol_fn, "for", &nativeSymbolFor);
            try self.registerNativeMethod(symbol_fn, "keyFor", &nativeSymbolKeyFor);

            // Well-known symbols as static properties
            try symbol_fn.setProperty(self.allocator, try self.pool.intern("iterator"), JsValue.initSymbol(SYMBOL_ITERATOR));
            try symbol_fn.setProperty(self.allocator, try self.pool.intern("toPrimitive"), JsValue.initSymbol(SYMBOL_TO_PRIMITIVE));
            try symbol_fn.setProperty(self.allocator, try self.pool.intern("hasInstance"), JsValue.initSymbol(SYMBOL_HAS_INSTANCE));
            try symbol_fn.setProperty(self.allocator, try self.pool.intern("toStringTag"), JsValue.initSymbol(SYMBOL_TO_STRING_TAG));
            try symbol_fn.setProperty(self.allocator, try self.pool.intern("asyncIterator"), JsValue.initSymbol(SYMBOL_ASYNC_ITERATOR));
        }
    }

    const NativeFn = object_mod.JsObject.NativeFn;

    pub fn createObj(self: *VM, opts: struct { obj_type: object_mod.ObjType = .ordinary }) !*JsObject {
        const obj = try self.allocator.create(JsObject);
        obj.* = .{ .obj_type = opts.obj_type };
        try self.objects.append(self.allocator, obj);
        return obj;
    }

    pub fn registerNativeMethod(self: *VM, target: *JsObject, name: []const u8, func: NativeFn) !void {
        const fn_obj = try self.allocator.create(JsObject);
        fn_obj.* = .{ .obj_type = .native_function, .data = .{ .native_fn = func } };
        try self.objects.append(self.allocator, fn_obj);
        const name_id = try self.pool.intern(name);
        try target.setProperty(self.allocator, name_id, JsValue.initObject(fn_obj));
    }

    pub fn vmFromCtx(ctx: *anyopaque) *VM {
        return @ptrCast(@alignCast(ctx));
    }

    // ── console methods ─────────────────────────────────────────────

    fn consoleWriteWithPrefix(vm: *VM, prefix: []const u8, args: []const JsValue) void {
        const stderr = std.fs.File.stderr();
        var indent: u32 = 0;
        while (indent < vm.console_indent) : (indent += 1) _ = stderr.write("  ") catch 0;
        if (prefix.len > 0) {
            _ = stderr.write(prefix) catch 0;
            _ = stderr.write(" ") catch 0;
        }
        for (args, 0..) |arg, i| {
            if (i > 0) _ = stderr.write(" ") catch 0;
            var buf: [64]u8 = undefined;
            _ = stderr.write(formatValue(vm.pool, arg, &buf)) catch 0;
        }
        _ = stderr.write("\n") catch 0;
    }

    fn nativeConsoleLog(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleWarn(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "[WARN]", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleError(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "[ERROR]", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleInfo(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "[INFO]", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleDebug(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "[DEBUG]", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleAssert(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len > 0 and args[0].isTruthy()) return JsValue.undefined_val;
        consoleWriteWithPrefix(vmFromCtx(ctx), "[ASSERT]", if (args.len > 1) args[1..] else &.{});
        return JsValue.undefined_val;
    }
    fn nativeConsoleTrace(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        consoleWriteWithPrefix(vmFromCtx(ctx), "Trace:", args);
        return JsValue.undefined_val;
    }
    fn nativeConsoleNoOp(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.undefined_val;
    }
    fn nativeConsoleDir(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return JsValue.undefined_val;
        const val = args[0];
        const stderr = std.fs.File.stderr();
        if (val.isObject()) {
            const obj = val.asJsObject();
            _ = stderr.write("{ ") catch 0;
            var first = true;
            var it = obj.properties.iterator();
            while (it.next()) |entry| {
                if (!first) _ = stderr.write(", ") catch 0;
                first = false;
                if (vm.pool.get(entry.key_ptr.*)) |key_str| _ = stderr.write(key_str) catch 0;
                _ = stderr.write(": ") catch 0;
                var buf: [64]u8 = undefined;
                _ = stderr.write(formatValue(vm.pool, entry.value_ptr.*, &buf)) catch 0;
            }
            _ = stderr.write(" }\n") catch 0;
        } else {
            var buf: [64]u8 = undefined;
            _ = stderr.write(formatValue(vm.pool, val, &buf)) catch 0;
            _ = stderr.write("\n") catch 0;
        }
        return JsValue.undefined_val;
    }
    fn nativeConsoleTime(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const label = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse "default"
        else
            "default";
        if (vm.console_timers.count() < 1024) {
            vm.console_timers.put(vm.allocator, label, std.time.milliTimestamp()) catch {};
        }
        return JsValue.undefined_val;
    }
    fn nativeConsoleTimeEnd(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const label = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse "default"
        else
            "default";
        if (vm.console_timers.get(label)) |start| {
            const elapsed = std.time.milliTimestamp() - start;
            const stderr = std.fs.File.stderr();
            var buf: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s}: {d}ms\n", .{ label, elapsed }) catch return JsValue.undefined_val;
            _ = stderr.write(s) catch 0;
            _ = vm.console_timers.remove(label);
        }
        return JsValue.undefined_val;
    }
    fn nativeConsoleTimeLog(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const label = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse "default"
        else
            "default";
        if (vm.console_timers.get(label)) |start| {
            const elapsed = std.time.milliTimestamp() - start;
            const stderr = std.fs.File.stderr();
            var buf: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s}: {d}ms", .{ label, elapsed }) catch return JsValue.undefined_val;
            _ = stderr.write(s) catch 0;
            if (args.len > 1) {
                for (args[1..]) |arg| {
                    _ = stderr.write(" ") catch 0;
                    var vbuf: [64]u8 = undefined;
                    _ = stderr.write(formatValue(vm.pool, arg, &vbuf)) catch 0;
                }
            }
            _ = stderr.write("\n") catch 0;
        }
        return JsValue.undefined_val;
    }
    fn nativeConsoleCount(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const label = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse "default"
        else
            "default";
        const entry = vm.console_counts.getOrPut(vm.allocator, label) catch return JsValue.undefined_val;
        if (!entry.found_existing) {
            if (vm.console_counts.count() > 1024) {
                _ = vm.console_counts.remove(label);
                return JsValue.undefined_val;
            }
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        const stderr = std.fs.File.stderr();
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}: {d}\n", .{ label, entry.value_ptr.* }) catch return JsValue.undefined_val;
        _ = stderr.write(s) catch 0;
        return JsValue.undefined_val;
    }
    fn nativeConsoleCountReset(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const label = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse "default"
        else
            "default";
        _ = vm.console_counts.remove(label);
        return JsValue.undefined_val;
    }
    fn nativeConsoleGroup(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len > 0) consoleWriteWithPrefix(vm, "", args);
        if (vm.console_indent < 16) vm.console_indent += 1;
        return JsValue.undefined_val;
    }
    fn nativeConsoleGroupEnd(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (vm.console_indent > 0) vm.console_indent -= 1;
        return JsValue.undefined_val;
    }
    fn nativeConsoleTable(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return JsValue.undefined_val;
        const val = args[0];
        const stderr = std.fs.File.stderr();
        if (val.isObject()) {
            const obj = val.asJsObject();
            if (obj.obj_type == .array) {
                for (obj.data.array.items, 0..) |item, i| {
                    var ibuf: [20]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&ibuf, "{d}\t", .{i}) catch continue;
                    _ = stderr.write(idx_str) catch 0;
                    var buf: [64]u8 = undefined;
                    _ = stderr.write(formatValue(vm.pool, item, &buf)) catch 0;
                    _ = stderr.write("\n") catch 0;
                }
            } else {
                return nativeConsoleDir(ctx, JsValue.undefined_val, args);
            }
        }
        return JsValue.undefined_val;
    }

    // ── Array methods ───────────────────────────────────────────────

    fn nativeArrayPush(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        for (args) |arg| try obj.data.array.append(vm.allocator, arg);
        return JsValue.initNumber(@floatFromInt(obj.data.array.items.len));
    }

    fn nativeArrayPop(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array or obj.data.array.items.len == 0) return JsValue.undefined_val;
        return obj.data.array.pop() orelse JsValue.undefined_val;
    }

    fn nativeArrayShift(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array or obj.data.array.items.len == 0) return JsValue.undefined_val;
        const val = obj.data.array.items[0];
        _ = obj.data.array.orderedRemove(0);
        return val;
    }

    fn nativeArrayIndexOf(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.initNumber(-1);
        const obj = this.asJsObject();
        if (obj.obj_type != .array or args.len == 0) return JsValue.initNumber(-1);
        for (obj.data.array.items, 0..) |item, i| {
            if (JsValue.jsStrictEq(item, args[0]).asBool())
                return JsValue.initNumber(@floatFromInt(i));
        }
        return JsValue.initNumber(-1);
    }

    fn nativeArrayIncludes(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .array or args.len == 0) return JsValue.initBool(false);
        for (obj.data.array.items) |item| {
            if (JsValue.jsStrictEq(item, args[0]).asBool()) return JsValue.initBool(true);
        }
        return JsValue.initBool(false);
    }

    fn nativeArrayJoin(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const sep = if (args.len > 0 and args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse ","
        else
            ",";
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        for (obj.data.array.items, 0..) |item, i| {
            if (i > 0) try buf.appendSlice(vm.allocator, sep);
            var num_buf: [64]u8 = undefined;
            try buf.appendSlice(vm.allocator, formatValue(vm.pool, item, &num_buf));
        }
        const sid = try vm.pool.intern(buf.items);
        return JsValue.initString(sid);
    }

    fn nativeArrayReverse(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return this;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return this;
        std.mem.reverse(JsValue, obj.data.array.items);
        return this;
    }

    fn nativeArraySlice(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const len: i64 = @intCast(obj.data.array.items.len);
        var start: i64 = if (args.len > 0) clampToI64(args[0]) else 0;
        var end: i64 = if (args.len > 1) clampToI64(args[1]) else len;
        if (start < 0) start = @max(start + len, 0);
        if (end < 0) end = @max(end + len, 0);
        start = @min(start, len);
        end = @min(end, len);
        if (end < start) end = start;
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        const s: usize = @intCast(start);
        const e: usize = @intCast(end);
        for (obj.data.array.items[s..e]) |item| {
            try new_arr.data.array.append(vm.allocator, item);
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayConcat(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items) |item| try new_arr.data.array.append(vm.allocator, item);
        for (args) |arg| {
            if (arg.isObject()) {
                const a = arg.asJsObject();
                if (a.obj_type == .array) {
                    for (a.data.array.items) |item| try new_arr.data.array.append(vm.allocator, item);
                    continue;
                }
            }
            try new_arr.data.array.append(vm.allocator, arg);
        }
        return JsValue.initObject(new_arr);
    }

    // ── String methods ──────────────────────────────────────────────

    fn getStr(ctx: *anyopaque, this: JsValue) ?[]const u8 {
        if (!this.isString()) return null;
        return vmFromCtx(ctx).pool.get(this.asStringId());
    }

    fn nativeStringCharAt(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const idx: usize = if (args.len > 0) clampToUsize(args[0]) else 0;
        if (idx >= s.len) return JsValue.initString(try vm.pool.intern(""));
        return JsValue.initString(try vm.pool.intern(s[idx .. idx + 1]));
    }

    fn nativeStringCharCodeAt(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.nan_val;
        const idx: usize = if (args.len > 0) clampToUsize(args[0]) else 0;
        if (idx >= s.len) return JsValue.nan_val;
        return JsValue.initNumber(@floatFromInt(s[idx]));
    }

    fn nativeStringIndexOf(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initNumber(-1);
        if (args.len == 0) return JsValue.initNumber(-1);
        const vm = vmFromCtx(ctx);
        if (!args[0].isString()) return JsValue.initNumber(-1);
        const needle = vm.pool.get(args[0].asStringId()) orelse return JsValue.initNumber(-1);
        if (needle.len == 0) return JsValue.initNumber(0);
        if (std.mem.indexOf(u8, s, needle)) |pos| {
            return JsValue.initNumber(@floatFromInt(pos));
        }
        return JsValue.initNumber(-1);
    }

    fn nativeStringIncludes(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initBool(false);
        if (args.len == 0) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        if (!args[0].isString()) return JsValue.initBool(false);
        const needle = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);
        return JsValue.initBool(std.mem.indexOf(u8, s, needle) != null);
    }

    fn nativeStringSubstring(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const len = s.len;
        var start: usize = if (args.len > 0) @min(clampToUsize(args[0]), len) else 0;
        var end: usize = if (args.len > 1) @min(clampToUsize(args[1]), len) else len;
        if (start > end) {
            const tmp = start;
            start = end;
            end = tmp;
        }
        return JsValue.initString(try vm.pool.intern(s[start..end]));
    }

    fn nativeStringSlice(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const len: i64 = @intCast(s.len);
        var start: i64 = if (args.len > 0) clampToI64(args[0]) else 0;
        var end: i64 = if (args.len > 1) clampToI64(args[1]) else len;
        if (start < 0) start = @max(start + len, 0);
        if (end < 0) end = @max(end + len, 0);
        start = @min(start, len);
        end = @min(end, len);
        if (end < start) end = start;
        const si: usize = @intCast(start);
        const ei: usize = @intCast(end);
        return JsValue.initString(try vm.pool.intern(s[si..ei]));
    }

    fn nativeStringSplit(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);

        if (args.len == 0 or !args[0].isString()) {
            // No separator — return array with the whole string
            try new_arr.data.array.append(vm.allocator, this);
            return JsValue.initObject(new_arr);
        }

        const sep = vm.pool.get(args[0].asStringId()) orelse "";
        if (sep.len == 0) {
            // Split every character
            for (s) |c| {
                const sid = try vm.pool.intern(s[@intFromPtr(&c) - @intFromPtr(s.ptr) ..][0..1]);
                try new_arr.data.array.append(vm.allocator, JsValue.initString(sid));
            }
        } else {
            var rest = s;
            while (rest.len > 0) {
                if (std.mem.indexOf(u8, rest, sep)) |pos| {
                    const sid = try vm.pool.intern(rest[0..pos]);
                    try new_arr.data.array.append(vm.allocator, JsValue.initString(sid));
                    rest = rest[pos + sep.len ..];
                } else {
                    const sid = try vm.pool.intern(rest);
                    try new_arr.data.array.append(vm.allocator, JsValue.initString(sid));
                    break;
                }
            }
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeStringTrim(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const trimmed = std.mem.trim(u8, s, " \t\n\r");
        return JsValue.initString(try vm.pool.intern(trimmed));
    }

    fn nativeStringToUpperCase(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        var buf = try vm.allocator.alloc(u8, s.len);
        defer vm.allocator.free(buf);
        for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return JsValue.initString(try vm.pool.intern(buf));
    }

    fn nativeStringToLowerCase(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        var buf = try vm.allocator.alloc(u8, s.len);
        defer vm.allocator.free(buf);
        for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return JsValue.initString(try vm.pool.intern(buf));
    }

    fn nativeStringStartsWith(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initBool(false);
        if (args.len == 0 or !args[0].isString()) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const prefix = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);
        return JsValue.initBool(std.mem.startsWith(u8, s, prefix));
    }

    fn nativeStringEndsWith(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initBool(false);
        if (args.len == 0 or !args[0].isString()) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const suffix = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);
        return JsValue.initBool(std.mem.endsWith(u8, s, suffix));
    }

    fn nativeStringReplace(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        if (args.len < 2 or !args[0].isString() or !args[1].isString()) return this;
        const vm = vmFromCtx(ctx);
        const needle = vm.pool.get(args[0].asStringId()) orelse return this;
        const replacement = vm.pool.get(args[1].asStringId()) orelse return this;
        // Replace first occurrence only (like JS String.replace with string arg)
        if (std.mem.indexOf(u8, s, needle)) |pos| {
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(vm.allocator);
            try buf.appendSlice(vm.allocator, s[0..pos]);
            try buf.appendSlice(vm.allocator, replacement);
            try buf.appendSlice(vm.allocator, s[pos + needle.len ..]);
            return JsValue.initString(try vm.pool.intern(buf.items));
        }
        return this;
    }

    // ── JS callback invocation ──────────────────────────────────────

    fn callJsFunction(self: *VM, func_val: JsValue, this_val: JsValue, args: []const JsValue) !JsValue {
        if (!func_val.isObject()) return JsValue.undefined_val;
        const obj = func_val.asJsObject();

        // Handle native functions directly
        if (obj.obj_type == .native_function) {
            // Push func on stack so getCallerFuncObj can find it
            self.push(func_val);
            const result = try obj.data.native_fn(@ptrCast(self), this_val, args);
            self.sp -= 1; // pop func
            return result;
        }

        if (obj.obj_type != .function) return JsValue.undefined_val;

        const func = &obj.data.function;
        const target = self.frame_count;

        self.push(func_val); // function slot (popped by return)
        const base = self.sp;
        for (args) |arg| self.push(arg);
        while (self.sp - base < func.param_count) self.push(JsValue.undefined_val);
        const extra: u16 = if (func.local_count > func.param_count) func.local_count - func.param_count else 0;
        var j: u16 = 0;
        while (j < extra) : (j += 1) self.push(JsValue.undefined_val);

        const uv_array = self.getClosureUpvalues(obj);
        self.frames[self.frame_count] = .{
            .bc = &func.bytecode,
            .ip = 0,
            .base_sp = base,
            .upvalues = uv_array,
            .this_val = this_val,
        };
        self.frame_count += 1;

        _ = try self.run(target);
        return self.pop();
    }

    // ── Higher-order array methods ──────────────────────────────────

    fn nativeArrayForEach(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            _ = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
        }
        return JsValue.undefined_val;
    }

    fn nativeArrayMap(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            try new_arr.data.array.append(vm.allocator, result);
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayFilter(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (result.isTruthy()) {
                try new_arr.data.array.append(vm.allocator, item);
            }
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayReduce(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        const items = obj.data.array.items;
        var acc: JsValue = undefined;
        var start: usize = 0;
        if (args.len > 1) {
            acc = args[1];
        } else {
            if (items.len == 0) return JsValue.undefined_val;
            acc = items[0];
            start = 1;
        }
        for (items[start..], start..) |item, i| {
            const cb_args = [_]JsValue{ acc, item, JsValue.initNumber(@floatFromInt(i)), this };
            acc = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
        }
        return acc;
    }

    fn nativeArrayReduceRight(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        const items = obj.data.array.items;
        if (items.len == 0 and args.len < 2) return JsValue.undefined_val;
        var acc: JsValue = if (args.len > 1) args[1] else items[items.len - 1];
        const end: usize = if (args.len > 1) items.len else items.len -| 1;
        var i: usize = end;
        while (i > 0) {
            i -= 1;
            const cb_args = [_]JsValue{ acc, items[i], JsValue.initNumber(@floatFromInt(i)), this };
            acc = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
        }
        return acc;
    }

    fn nativeArrayFind(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (result.isTruthy()) return item;
        }
        return JsValue.undefined_val;
    }

    fn nativeArrayFindIndex(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initNumber(-1);
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.initNumber(-1);
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (result.isTruthy()) return JsValue.initNumber(@floatFromInt(i));
        }
        return JsValue.initNumber(-1);
    }

    fn nativeArraySome(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (result.isTruthy()) return JsValue.initBool(true);
        }
        return JsValue.initBool(false);
    }

    fn nativeArrayEvery(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(true);
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.initBool(true);
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (!result.isTruthy()) return JsValue.initBool(false);
        }
        return JsValue.initBool(true);
    }

    fn nativeArraySort(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return this;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return this;
        const items = obj.data.array.items;
        if (items.len <= 1) return this;
        const has_comparefn = args.len > 0 and args[0].isObject();
        const vm = vmFromCtx(ctx);
        // Simple insertion sort (stable, fine for typical array sizes)
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0) {
                const cmp = if (has_comparefn) blk: {
                    const cb_args = [_]JsValue{ items[j - 1], key };
                    const r = try vm.callJsFunction(args[0], JsValue.undefined_val, &cb_args);
                    break :blk r.toNumber();
                } else blk: {
                    // Default: lexicographic comparison
                    var buf_a: [64]u8 = undefined;
                    var buf_b: [64]u8 = undefined;
                    const a_bytes = formatValue(vm.pool, items[j - 1], &buf_a);
                    const b_bytes = formatValue(vm.pool, key, &buf_b);
                    const order = std.mem.order(u8, a_bytes, b_bytes);
                    break :blk switch (order) {
                        .gt => @as(f64, 1),
                        .lt => @as(f64, -1),
                        .eq => @as(f64, 0),
                    };
                };
                if (cmp <= 0) break;
                items[j] = items[j - 1];
                j -= 1;
            }
            items[j] = key;
        }
        return this;
    }

    fn nativeArraySplice(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const len: i64 = @intCast(obj.data.array.items.len);
        var start: i64 = if (args.len > 0) clampToI64(args[0]) else 0;
        if (start < 0) start = @max(start + len, 0);
        start = @min(start, len);
        const delete_count: usize = if (args.len > 1) @intCast(@min(@max(clampToI64(args[1]), 0), len - start)) else @intCast(len - start);
        // Create return array with deleted elements
        const deleted = try vm.allocator.create(JsObject);
        deleted.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, deleted);
        const s: usize = @intCast(start);
        for (0..delete_count) |di| {
            try deleted.data.array.append(vm.allocator, obj.data.array.items[s + di]);
        }
        // Remove deleted elements
        for (0..delete_count) |_| {
            _ = obj.data.array.orderedRemove(s);
        }
        // Insert new elements
        if (args.len > 2) {
            for (args[2..], 0..) |arg, ii| {
                obj.data.array.insert(vm.allocator, s + ii, arg) catch break;
            }
        }
        // Update length property
        const len_id = vm.pool.intern("length") catch return JsValue.initObject(deleted);
        obj.setProperty(vm.allocator, len_id, JsValue.initNumber(@floatFromInt(obj.data.array.items.len))) catch {};
        return JsValue.initObject(deleted);
    }

    fn nativeArrayFlat(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const depth: u32 = if (args.len > 0) @intFromFloat(@max(0, @min(args[0].toNumber(), 100))) else 1;
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        try flattenArray(vm, obj, new_arr, depth);
        return JsValue.initObject(new_arr);
    }

    fn flattenArray(vm: *VM, src: *JsObject, dst: *JsObject, depth: u32) !void {
        for (src.data.array.items) |item| {
            if (depth > 0 and item.isObject()) {
                const inner = item.asJsObject();
                if (inner.obj_type == .array) {
                    try flattenArray(vm, inner, dst, depth - 1);
                    continue;
                }
            }
            try dst.data.array.append(vm.allocator, item);
        }
    }

    fn nativeArrayFlatMap(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const callback = args[0];
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items, 0..) |item, i| {
            const cb_args = [_]JsValue{ item, JsValue.initNumber(@floatFromInt(i)), this };
            const result = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
            if (result.isObject()) {
                const r_obj = result.asJsObject();
                if (r_obj.obj_type == .array) {
                    for (r_obj.data.array.items) |sub| try new_arr.data.array.append(vm.allocator, sub);
                    continue;
                }
            }
            try new_arr.data.array.append(vm.allocator, result);
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayFill(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return this;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return this;
        const val = args[0];
        const len: i64 = @intCast(obj.data.array.items.len);
        var start: i64 = if (args.len > 1) clampToI64(args[1]) else 0;
        var end: i64 = if (args.len > 2) clampToI64(args[2]) else len;
        if (start < 0) start = @max(start + len, 0);
        if (end < 0) end = @max(end + len, 0);
        start = @min(start, len);
        end = @min(end, len);
        const s: usize = @intCast(start);
        const e: usize = @intCast(end);
        for (obj.data.array.items[s..e]) |*slot| slot.* = val;
        return this;
    }

    fn nativeArrayAt(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const len: i64 = @intCast(obj.data.array.items.len);
        var idx: i64 = clampToI64(args[0]);
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) return JsValue.undefined_val;
        return obj.data.array.items[@intCast(idx)];
    }

    fn nativeArrayUnshift(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        // Insert args at the beginning in order
        var insert_idx: usize = 0;
        for (args) |arg| {
            obj.data.array.insert(vm.allocator, insert_idx, arg) catch break;
            insert_idx += 1;
        }
        const len_id = vm.pool.intern("length") catch return JsValue.initNumber(@floatFromInt(obj.data.array.items.len));
        obj.setProperty(vm.allocator, len_id, JsValue.initNumber(@floatFromInt(obj.data.array.items.len))) catch {};
        return JsValue.initNumber(@floatFromInt(obj.data.array.items.len));
    }

    fn nativeArrayKeys(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (0..obj.data.array.items.len) |i| {
            try new_arr.data.array.append(vm.allocator, JsValue.initNumber(@floatFromInt(i)));
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayValues(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items) |item| {
            try new_arr.data.array.append(vm.allocator, item);
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayEntries(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .array) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.allocator.create(JsObject);
        new_arr.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
        try vm.objects.append(vm.allocator, new_arr);
        for (obj.data.array.items, 0..) |item, i| {
            const pair = try vm.allocator.create(JsObject);
            pair.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = vm.array_proto };
            try vm.objects.append(vm.allocator, pair);
            try pair.data.array.append(vm.allocator, JsValue.initNumber(@floatFromInt(i)));
            try pair.data.array.append(vm.allocator, item);
            try new_arr.data.array.append(vm.allocator, JsValue.initObject(pair));
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeArrayToString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        // toString delegates to join with comma separator
        return nativeArrayJoin(ctx, this, &.{});
    }

    // ── Timer methods ──────────────────────────────────────────────

    fn nativeSetTimeout(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        return addTimer(ctx, args, false);
    }

    fn nativeSetInterval(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        return addTimer(ctx, args, true);
    }

    fn addTimer(ctx: *anyopaque, args: []const JsValue, is_interval: bool) !JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return JsValue.undefined_val;
        const callback = args[0];
        if (!callback.isObject()) return JsValue.undefined_val;
        const delay: u32 = if (args.len > 1) @intFromFloat(@max(0, @min(args[1].toNumber(), 2147483647))) else 0;
        const id = vm.next_timer_id;
        vm.next_timer_id += 1;
        try vm.timers.append(vm.allocator, .{
            .id = id,
            .callback = callback,
            .delay_ms = delay,
            .is_interval = is_interval,
        });
        return JsValue.initNumber(@floatFromInt(id));
    }

    fn nativeClearTimer(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const id: u32 = @intFromFloat(@max(0, args[0].toNumber()));
        for (vm.timers.items) |*entry| {
            if (entry.id == id) {
                entry.cancelled = true;
                break;
            }
        }
        return JsValue.undefined_val;
    }

    /// Fire all pending timers once. Called from the browser event loop.
    /// For simplicity, all timers fire immediately when runPendingTimers is called
    /// (delay is tracked but not enforced by kotori — the caller controls timing).
    pub fn runPendingTimers(self: *VM) !bool {
        if (self.timers.items.len == 0) return false;
        var fired_any = false;
        // Process timers (copy to avoid issues with modification during iteration)
        var i: usize = 0;
        while (i < self.timers.items.len) {
            var entry = &self.timers.items[i];
            if (entry.cancelled) {
                _ = self.timers.swapRemove(i);
                continue;
            }
            if (entry.fired and !entry.is_interval) {
                _ = self.timers.swapRemove(i);
                continue;
            }
            // Fire the callback
            entry.fired = true;
            fired_any = true;
            _ = self.callJsFunction(entry.callback, JsValue.undefined_val, &.{}) catch {};
            // After callback, re-check bounds (callback may have added timers)
            if (i < self.timers.items.len) {
                if (!self.timers.items[i].is_interval or self.timers.items[i].cancelled) {
                    _ = self.timers.swapRemove(i);
                    continue;
                }
                // Reset interval for next round
                self.timers.items[i].fired = false;
            }
            i += 1;
        }
        return fired_any;
    }

    /// Check if any timers are pending (unfired, not cancelled).
    pub fn hasPendingTimers(self: *VM) bool {
        for (self.timers.items) |entry| {
            if (!entry.cancelled and (!entry.fired or entry.is_interval)) return true;
        }
        return false;
    }

    // ── Promise helpers ──────────────────────────────────────────────

    fn createPromiseObj(self: *VM) !*JsObject {
        const obj = try self.allocator.create(JsObject);
        obj.* = .{
            .obj_type = .promise,
            .data = .{ .promise_data = .{} },
            .prototype = self.promise_proto,
        };
        try self.objects.append(self.allocator, obj);
        return obj;
    }

    fn resolvePromise(self: *VM, promise: *JsObject, value: JsValue) !void {
        if (promise.obj_type != .promise) return;
        var pd = &promise.data.promise_data;
        if (pd.state != .pending) return; // already settled

        // Resolution with a thenable (another promise)
        if (value.isObject()) {
            const val_obj = value.asJsObject();
            if (val_obj.obj_type == .promise) {
                const inner_pd = &val_obj.data.promise_data;
                switch (inner_pd.state) {
                    .fulfilled => return self.resolvePromise(promise, inner_pd.result),
                    .rejected => return self.rejectPromise(promise, inner_pd.result),
                    .pending => {
                        // Chain: when inner resolves, resolve outer
                        try inner_pd.handlers.append(self.allocator, .{
                            .on_fulfilled = JsValue.undefined_val,
                            .on_rejected = JsValue.undefined_val,
                            .result_promise = promise,
                        });
                        return;
                    },
                }
            }
        }

        pd.state = .fulfilled;
        pd.result = value;
        // Queue handlers as microtasks
        for (pd.handlers.items) |handler| {
            // Check if this is a continuation resume
            const cont_id = self.pool.intern("__continuation") catch continue;
            if (handler.result_promise.getProperty(cont_id)) |cont_val| {
                if (cont_val.isNumber()) {
                    const ptr_int: usize = @intFromFloat(cont_val.asNumber());
                    const cont: *Continuation = @ptrFromInt(ptr_int);
                    try self.microtasks.append(self.allocator, .{ .resume_async = .{
                        .cont = cont,
                        .value = value,
                        .is_reject = false,
                    } });
                    continue;
                }
            }
            try self.microtasks.append(self.allocator, .{ .promise_reaction = .{
                .handler = handler.on_fulfilled,
                .arg = value,
                .result_promise = handler.result_promise,
                .is_reject = false,
            } });
        }
        pd.handlers.items.len = 0; // clear handlers
    }

    fn rejectPromise(self: *VM, promise: *JsObject, reason: JsValue) !void {
        if (promise.obj_type != .promise) return;
        var pd = &promise.data.promise_data;
        if (pd.state != .pending) return;

        pd.state = .rejected;
        pd.result = reason;
        for (pd.handlers.items) |handler| {
            const cont_id = self.pool.intern("__continuation") catch continue;
            if (handler.result_promise.getProperty(cont_id)) |cont_val| {
                if (cont_val.isNumber()) {
                    const ptr_int: usize = @intFromFloat(cont_val.asNumber());
                    const cont: *Continuation = @ptrFromInt(ptr_int);
                    try self.microtasks.append(self.allocator, .{ .resume_async = .{
                        .cont = cont,
                        .value = reason,
                        .is_reject = true,
                    } });
                    continue;
                }
            }
            try self.microtasks.append(self.allocator, .{ .promise_reaction = .{
                .handler = handler.on_rejected,
                .arg = reason,
                .result_promise = handler.result_promise,
                .is_reject = true,
            } });
        }
        pd.handlers.items.len = 0;
    }

    /// Drain the microtask queue. Called from the browser event loop
    /// (always before processing macrotasks/timers).
    pub fn runMicrotasks(self: *VM) !bool {
        if (self.microtasks.items.len == 0) return false;
        var ran_any = false;
        // Process until empty (handlers can enqueue more microtasks)
        while (self.microtasks.items.len > 0) {
            const task = self.microtasks.orderedRemove(0);
            ran_any = true;
            switch (task) {
                .promise_reaction => |reaction| {
                    if (reaction.handler.isObject()) {
                        // Call the handler function
                        const result = self.callJsFunction(reaction.handler, JsValue.undefined_val, &.{reaction.arg}) catch JsValue.undefined_val;
                        if (reaction.is_reject) {
                            // .catch handler: resolve the result promise (not reject)
                            try self.resolvePromise(reaction.result_promise, result);
                        } else {
                            try self.resolvePromise(reaction.result_promise, result);
                        }
                    } else {
                        // No handler: pass through value
                        if (reaction.is_reject) {
                            try self.rejectPromise(reaction.result_promise, reaction.arg);
                        } else {
                            try self.resolvePromise(reaction.result_promise, reaction.arg);
                        }
                    }
                },
                .resume_async => |res| {
                    if (res.is_reject) {
                        // Rejection in async function — reject the async promise
                        try self.rejectPromise(res.cont.async_promise, res.value);
                        continue;
                    }
                    // Restore the suspended frame
                    const cont = res.cont;
                    const base = self.sp + 1; // +1 for function slot
                    self.push(JsValue.undefined_val); // function slot placeholder
                    // Restore saved stack (locals + temporaries)
                    for (cont.saved_stack) |val| self.push(val);
                    // Push the resolved value (result of await)
                    self.push(res.value);

                    const target = self.frame_count;
                    self.frames[self.frame_count] = .{
                        .bc = cont.bc,
                        .ip = cont.ip,
                        .base_sp = base,
                        .upvalues = cont.upvalues,
                        .this_val = cont.this_val,
                        .has_this_on_stack = cont.has_this_on_stack,
                        .async_promise = cont.async_promise,
                    };
                    self.frame_count += 1;
                    _ = self.run(target) catch {};
                },
            }
        }
        return ran_any;
    }

    /// Check if any microtasks are pending.
    pub fn hasPendingMicrotasks(self: *VM) bool {
        return self.microtasks.items.len > 0;
    }

    // ── Promise native functions ────────────────────────────────────

    /// new Promise(function(resolve, reject) { ... })
    fn nativePromiseConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const promise = try vm.createPromiseObj();
        const promise_val = JsValue.initObject(promise);

        if (args.len == 0 or !args[0].isObject()) return promise_val;
        const executor = args[0];

        // Create resolve/reject native functions that capture this promise
        const resolve_fn = try vm.createPromiseSetter(promise, false);
        const reject_fn = try vm.createPromiseSetter(promise, true);

        // Call executor(resolve, reject) synchronously
        _ = vm.callJsFunction(executor, JsValue.undefined_val, &.{
            JsValue.initObject(resolve_fn),
            JsValue.initObject(reject_fn),
        }) catch {};

        return promise_val;
    }

    /// Promise.resolve(value)
    fn nativePromiseResolve(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const value = if (args.len > 0) args[0] else JsValue.undefined_val;
        // If already a promise, return it
        if (value.isObject()) {
            if (value.asJsObject().obj_type == .promise) return value;
        }
        const promise = try vm.createPromiseObj();
        try vm.resolvePromise(promise, value);
        return JsValue.initObject(promise);
    }

    /// Promise.reject(reason)
    fn nativePromiseReject(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const reason = if (args.len > 0) args[0] else JsValue.undefined_val;
        const promise = try vm.createPromiseObj();
        try vm.rejectPromise(promise, reason);
        return JsValue.initObject(promise);
    }

    /// promise.then(onFulfilled, onRejected)
    fn nativePromiseThen(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const promise = this.asJsObject();
        if (promise.obj_type != .promise) return JsValue.undefined_val;

        const on_fulfilled = if (args.len > 0) args[0] else JsValue.undefined_val;
        const on_rejected = if (args.len > 1) args[1] else JsValue.undefined_val;
        const result_promise = try vm.createPromiseObj();

        const pd = &promise.data.promise_data;
        switch (pd.state) {
            .pending => {
                // Enqueue handler
                try pd.handlers.append(vm.allocator, .{
                    .on_fulfilled = on_fulfilled,
                    .on_rejected = on_rejected,
                    .result_promise = result_promise,
                });
            },
            .fulfilled => {
                // Already resolved: queue microtask
                try vm.microtasks.append(vm.allocator, .{ .promise_reaction = .{
                    .handler = on_fulfilled,
                    .arg = pd.result,
                    .result_promise = result_promise,
                    .is_reject = false,
                } });
            },
            .rejected => {
                try vm.microtasks.append(vm.allocator, .{ .promise_reaction = .{
                    .handler = on_rejected,
                    .arg = pd.result,
                    .result_promise = result_promise,
                    .is_reject = true,
                } });
            },
        }
        return JsValue.initObject(result_promise);
    }

    /// promise.catch(onRejected) — sugar for .then(undefined, onRejected)
    fn nativePromiseCatch(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const on_rejected = if (args.len > 0) args[0] else JsValue.undefined_val;
        return nativePromiseThen(ctx, this, &.{ JsValue.undefined_val, on_rejected });
    }

    /// promise.finally(onFinally)
    fn nativePromiseFinally(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        // Simplified: just call .then with same callback for both paths
        const callback = if (args.len > 0) args[0] else JsValue.undefined_val;
        return nativePromiseThen(ctx, this, &.{ callback, callback });
    }

    /// Helper: create a native function that resolves or rejects a specific promise.
    /// Used by the Promise constructor for the resolve/reject callbacks.
    fn createPromiseSetter(self: *VM, promise: *JsObject, is_reject: bool) !*JsObject {
        // Store the target promise + mode in a wrapper object's properties
        const wrapper = try self.allocator.create(JsObject);
        wrapper.* = .{ .obj_type = .native_function, .data = .{ .native_fn = if (is_reject) &nativeRejectCb else &nativeResolveCb } };
        try self.objects.append(self.allocator, wrapper);
        // Store the target promise reference as a property
        const target_id = try self.pool.intern("__target");
        try wrapper.setProperty(self.allocator, target_id, JsValue.initObject(promise));
        return wrapper;
    }

    fn nativeResolveCb(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        // Find the target promise from our function object
        // The function object is on the stack just before the args
        const target = getCallbackTarget(vm) orelse return JsValue.undefined_val;
        const value = if (args.len > 0) args[0] else JsValue.undefined_val;
        try vm.resolvePromise(target, value);
        return JsValue.undefined_val;
    }

    fn nativeRejectCb(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const target = getCallbackTarget(vm) orelse return JsValue.undefined_val;
        const reason = if (args.len > 0) args[0] else JsValue.undefined_val;
        try vm.rejectPromise(target, reason);
        return JsValue.undefined_val;
    }

    fn getCallbackTarget(vm: *VM) ?*JsObject {
        // In a native call, the function object is at stack[sp - arg_count - 1]
        // But we don't have arg_count here. Instead, look up from the call site:
        // The function was stored at base - 1 of the caller's perspective.
        // For native calls in .call opcode: func is at stack[sp - 1 - arg_count] before call.
        // After args are consumed, func_val was popped. We need another approach.
        //
        // Alternative: scan recent native_function objects for __target property
        // Simplest: use the pool to look up __target on recently called functions.
        //
        // Actually, for .call opcode, the func_val is at stack[self.sp - 1 - arg_count]
        // and after the native call, sp is adjusted. But during the native call,
        // the stack hasn't been adjusted yet.
        //
        // Let's look at the call opcode: `const func_val = self.stack[self.sp - 1 - arg_count]`
        // then native is called, then `self.sp = base - 1; self.push(result);`
        // So during the native call, func_val is still on the stack.
        // But we can't easily know arg_count from inside the native.
        //
        // Pragmatic solution: store target promise as a global with unique key.
        // Or better: we can walk back from sp to find a native_function with __target.
        // Let's check the stack below current args.
        const target_id = vm.pool.intern("__target") catch return null;
        // Walk stack backwards to find the function object
        var i = vm.sp;
        while (i > 0) {
            i -= 1;
            const val = vm.stack[i];
            if (val.isObject()) {
                const obj = val.asJsObject();
                if (obj.obj_type == .native_function) {
                    if (obj.getProperty(target_id)) |target_val| {
                        if (target_val.isObject()) {
                            const target = target_val.asJsObject();
                            if (target.obj_type == .promise) return target;
                        }
                    }
                }
            }
        }
        return null;
    }

    // ── fetch API ────────────────────────────────────────────────────

    fn nativeFetch(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const fetch_fn = vm.http_fetch_fn orelse {
            // No HTTP client — return rejected promise
            const p = try vm.createPromiseObj();
            const err_id = try vm.pool.intern("fetch not available");
            try vm.rejectPromise(p, JsValue.initString(err_id));
            return JsValue.initObject(p);
        };
        const fetch_ctx = vm.http_fetch_ctx orelse return JsValue.undefined_val;

        // Get URL from first argument
        if (args.len == 0) {
            const p = try vm.createPromiseObj();
            const err_id = try vm.pool.intern("fetch requires a URL");
            try vm.rejectPromise(p, JsValue.initString(err_id));
            return JsValue.initObject(p);
        }

        const url_str = if (args[0].isString())
            vm.pool.get(args[0].asStringId()) orelse ""
        else
            "";

        if (url_str.len == 0) {
            const p = try vm.createPromiseObj();
            const err_id = try vm.pool.intern("invalid URL");
            try vm.rejectPromise(p, JsValue.initString(err_id));
            return JsValue.initObject(p);
        }

        // Parse options (second argument)
        var method: []const u8 = "GET";
        var body: ?[]const u8 = null;
        if (args.len > 1 and args[1].isObject()) {
            const opts = args[1].asJsObject();
            const method_id = vm.pool.intern("method") catch null;
            if (method_id) |mid| {
                if (opts.getProperty(mid)) |mv| {
                    if (mv.isString()) {
                        method = vm.pool.get(mv.asStringId()) orelse "GET";
                    }
                }
            }
            const body_id = vm.pool.intern("body") catch null;
            if (body_id) |bid| {
                if (opts.getProperty(bid)) |bv| {
                    if (bv.isString()) {
                        body = vm.pool.get(bv.asStringId());
                    }
                }
            }
        }

        // Make the HTTP request (synchronous)
        const result = fetch_fn(fetch_ctx, vm.allocator, url_str, method, body);
        if (result == null) {
            const p = try vm.createPromiseObj();
            const err_id = try vm.pool.intern("network error");
            try vm.rejectPromise(p, JsValue.initString(err_id));
            return JsValue.initObject(p);
        }

        const resp = result.?;
        defer vm.allocator.free(resp.body);
        defer if (resp.content_type.len > 0) vm.allocator.free(resp.content_type);

        // Create Response object
        const response = try vm.createObj(.{});

        // response.status
        const status_id = try vm.pool.intern("status");
        try response.setProperty(vm.allocator, status_id, JsValue.initNumber(@floatFromInt(resp.status)));

        // response.ok
        const ok_id = try vm.pool.intern("ok");
        try response.setProperty(vm.allocator, ok_id, JsValue.initBool(resp.status >= 200 and resp.status < 300));

        // response.url
        const url_id = try vm.pool.intern("url");
        const url_sid = try vm.pool.intern(url_str);
        try response.setProperty(vm.allocator, url_id, JsValue.initString(url_sid));

        // Store body as __body property (for text()/json())
        const body_id_key = try vm.pool.intern("__body");
        const body_sid = try vm.pool.intern(resp.body);
        try response.setProperty(vm.allocator, body_id_key, JsValue.initString(body_sid));

        // response.text() → Promise<string>
        try vm.registerNativeMethod(response, "text", &nativeResponseText);

        // response.json() → Promise<object>
        try vm.registerNativeMethod(response, "json", &nativeResponseJson);

        // Return resolved Promise with Response
        const promise = try vm.createPromiseObj();
        try vm.resolvePromise(promise, JsValue.initObject(response));
        return JsValue.initObject(promise);
    }

    fn nativeResponseText(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        const body_key = try vm.pool.intern("__body");
        const body_val = obj.getProperty(body_key) orelse JsValue.undefined_val;
        // Return resolved Promise with body string
        const promise = try vm.createPromiseObj();
        try vm.resolvePromise(promise, body_val);
        return JsValue.initObject(promise);
    }

    fn nativeResponseJson(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        const body_key = try vm.pool.intern("__body");
        const body_val = obj.getProperty(body_key) orelse JsValue.undefined_val;
        // Parse JSON using the existing JSON.parse builtin
        const parsed = try nativeJsonParse(@ptrCast(vm), JsValue.undefined_val, &.{body_val});
        const promise = try vm.createPromiseObj();
        try vm.resolvePromise(promise, parsed);
        return JsValue.initObject(promise);
    }

    // ── Object methods ─────────────────────────────────────────────

    fn nativeObjectKeys(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.createArray();
        if (args.len == 0 or !args[0].isObject()) return JsValue.initObject(new_arr);
        const obj = args[0].asJsObject();
        for (obj.properties.keys()) |key_id| {
            try new_arr.data.array.append(vm.allocator, JsValue.initString(key_id));
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeObjectValues(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.createArray();
        if (args.len == 0 or !args[0].isObject()) return JsValue.initObject(new_arr);
        const obj = args[0].asJsObject();
        for (obj.properties.values()) |val| {
            try new_arr.data.array.append(vm.allocator, val);
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeObjectEntries(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.createArray();
        if (args.len == 0 or !args[0].isObject()) return JsValue.initObject(new_arr);
        const obj = args[0].asJsObject();
        const keys = obj.properties.keys();
        const vals = obj.properties.values();
        for (keys, vals) |key_id, val| {
            const pair = try vm.createArray();
            try pair.data.array.append(vm.allocator, JsValue.initString(key_id));
            try pair.data.array.append(vm.allocator, val);
            try new_arr.data.array.append(vm.allocator, JsValue.initObject(pair));
        }
        return JsValue.initObject(new_arr);
    }

    fn nativeObjectAssign(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0 or !args[0].isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const target = args[0].asJsObject();
        for (args[1..]) |src_val| {
            if (!src_val.isObject()) continue;
            const src = src_val.asJsObject();
            for (src.properties.keys(), src.properties.values()) |key, val| {
                try target.setProperty(vm.allocator, key, val);
            }
        }
        return args[0];
    }

    fn nativeObjectCreate(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const new_obj = try vm.createObj(.{});
        if (args.len > 0 and args[0].isObject()) {
            new_obj.prototype = args[0].asJsObject();
        }
        return JsValue.initObject(new_obj);
    }

    fn nativeObjectDefineProperty(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 3 or !args[0].isObject()) return if (args.len > 0) args[0] else JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const target = args[0].asJsObject();
        // Get property name from string arg
        if (!args[1].isString()) return args[0];
        const name_id = args[1].asStringId();
        // Descriptor object
        if (!args[2].isObject()) return args[0];
        const desc = args[2].asJsObject();
        // Check for value property
        const value_id = try vm.pool.intern("value");
        if (desc.getProperty(value_id)) |val| {
            try target.setProperty(vm.allocator, name_id, val);
        }
        // Check for get property (getter)
        const get_id = try vm.pool.intern("get");
        if (desc.getProperty(get_id)) |getter| {
            // For now, just call the getter and store its result
            if (getter.isObject()) {
                const result = try vm.callJsFunction(getter, args[0], &.{});
                try target.setProperty(vm.allocator, name_id, result);
            }
        }
        return args[0];
    }

    fn nativeObjectDefineProperties(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 2 or !args[0].isObject() or !args[1].isObject()) return if (args.len > 0) args[0] else JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const target = args[0].asJsObject();
        const props = args[1].asJsObject();
        const value_id = try vm.pool.intern("value");
        for (props.properties.keys(), props.properties.values()) |key, desc_val| {
            if (!desc_val.isObject()) continue;
            const desc = desc_val.asJsObject();
            if (desc.getProperty(value_id)) |val| {
                try target.setProperty(vm.allocator, key, val);
            }
        }
        return args[0];
    }

    fn nativeObjectSetPrototypeOf(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 2 or !args[0].isObject()) return if (args.len > 0) args[0] else JsValue.undefined_val;
        const target = args[0].asJsObject();
        if (args[1].isObject()) {
            target.prototype = args[1].asJsObject();
        } else if (args[1].isNull()) {
            target.prototype = null;
        }
        return args[0];
    }

    fn nativeObjectGetPrototypeOf(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        _ = ctx;
        if (args.len == 0 or !args[0].isObject()) return JsValue.null_val;
        const obj = args[0].asJsObject();
        if (obj.prototype) |proto| return JsValue.initObject(proto);
        return JsValue.null_val;
    }

    fn nativeObjectGetOwnPropertyDescriptor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 2 or !args[0].isObject() or !args[1].isString()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = args[0].asJsObject();
        const name_id = args[1].asStringId();
        // Only check own properties (not prototype chain)
        const val = obj.properties.get(name_id) orelse return JsValue.undefined_val;
        const desc = try vm.createObj(.{});
        const value_id = try vm.pool.intern("value");
        try desc.setProperty(vm.allocator, value_id, val);
        const writable_id = try vm.pool.intern("writable");
        try desc.setProperty(vm.allocator, writable_id, JsValue.initBool(true));
        const enumerable_id = try vm.pool.intern("enumerable");
        try desc.setProperty(vm.allocator, enumerable_id, JsValue.initBool(true));
        const configurable_id = try vm.pool.intern("configurable");
        try desc.setProperty(vm.allocator, configurable_id, JsValue.initBool(true));
        return JsValue.initObject(desc);
    }

    fn nativeObjectPassthrough(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        return if (args.len > 0) args[0] else JsValue.undefined_val;
    }

    fn nativeReturnFalse(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initBool(false);
    }

    fn nativeReturnTrue(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initBool(true);
    }

    // ── Array static methods ───────────────────────────────────────

    fn nativeArrayIsArray(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(false);
        if (!args[0].isObject()) return JsValue.initBool(false);
        return JsValue.initBool(args[0].asJsObject().obj_type == .array);
    }

    fn nativeArrayFrom(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const new_arr = try vm.createArray();
        if (args.len == 0) return JsValue.initObject(new_arr);
        const src = args[0];
        if (src.isObject()) {
            const obj = src.asJsObject();
            if (obj.obj_type == .array) {
                for (obj.data.array.items) |item| {
                    try new_arr.data.array.append(vm.allocator, item);
                }
            }
        }
        return JsValue.initObject(new_arr);
    }

    // ── RegExp methods ────────────────────────────────────────────

    fn createRegExp(self: *VM, pattern_id: StringId, flags_id: StringId) !*JsObject {
        var global = false;
        var ignore_case = false;
        var multiline = false;
        if (self.pool.get(flags_id)) |flags| {
            for (flags) |ch| {
                switch (ch) {
                    'g' => global = true,
                    'i' => ignore_case = true,
                    'm' => multiline = true,
                    else => {},
                }
            }
        }
        const obj = try self.allocator.create(JsObject);
        obj.* = .{
            .obj_type = .regexp,
            .data = .{ .regexp_data = .{
                .source = pattern_id,
                .global = global,
                .ignore_case = ignore_case,
                .multiline = multiline,
            } },
        };
        try self.objects.append(self.allocator, obj);
        // Set properties
        const source_id = try self.pool.intern("source");
        try obj.setProperty(self.allocator, source_id, JsValue.initString(pattern_id));
        const global_id = try self.pool.intern("global");
        try obj.setProperty(self.allocator, global_id, JsValue.initBool(global));
        const ic_id = try self.pool.intern("ignoreCase");
        try obj.setProperty(self.allocator, ic_id, JsValue.initBool(ignore_case));
        // Methods
        try self.registerNativeMethod(obj, "test", &nativeRegExpTest);
        try self.registerNativeMethod(obj, "exec", &nativeRegExpExec);
        return obj;
    }

    fn nativeRegExpTest(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0 or !args[0].isString()) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .regexp) return JsValue.initBool(false);
        const re = obj.data.regexp_data;
        const pattern = vm.pool.get(re.source) orelse return JsValue.initBool(false);
        const str = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);
        return JsValue.initBool(simpleMatch(pattern, str, re.ignore_case) != null);
    }

    fn nativeRegExpExec(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0 or !args[0].isString()) return JsValue.null_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .regexp) return JsValue.null_val;
        const re = obj.data.regexp_data;
        const pattern = vm.pool.get(re.source) orelse return JsValue.null_val;
        const str = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
        const match_result = simpleMatch(pattern, str, re.ignore_case) orelse return JsValue.null_val;
        // Return [matched_string] with index property
        const arr = try vm.createArray();
        const matched = str[match_result.start..match_result.end];
        const match_sid = try vm.pool.intern(matched);
        try arr.data.array.append(vm.allocator, JsValue.initString(match_sid));
        const index_id = try vm.pool.intern("index");
        try arr.setProperty(vm.allocator, index_id, JsValue.initNumber(@floatFromInt(match_result.start)));
        return JsValue.initObject(arr);
    }

    const MatchResult = struct { start: usize, end: usize };

    /// Simple pattern matcher supporting: literal chars, ., ^, $, \d, \w, \s, *, +, ?
    /// Not a full regex engine but covers common JS patterns.
    fn simpleMatch(pattern: []const u8, str: []const u8, ignore_case: bool) ?MatchResult {
        // Try matching at each position
        var anchored_start = false;
        var pat = pattern;
        if (pat.len > 0 and pat[0] == '^') {
            anchored_start = true;
            pat = pat[1..];
        }
        var anchored_end = false;
        if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len < 2 or pat[pat.len - 2] != '\\')) {
            anchored_end = true;
            pat = pat[0 .. pat.len - 1];
        }

        if (anchored_start) {
            if (matchAt(pat, str, 0, ignore_case)) |end| {
                if (anchored_end and end != str.len) return null;
                return .{ .start = 0, .end = end };
            }
            return null;
        }

        var pos: usize = 0;
        while (pos <= str.len) : (pos += 1) {
            if (matchAt(pat, str, pos, ignore_case)) |end| {
                if (anchored_end and end != str.len) continue;
                return .{ .start = pos, .end = end };
            }
        }
        return null;
    }

    /// Try to match pattern starting at str[pos]. Returns end position if match.
    fn matchAt(pat: []const u8, str: []const u8, start: usize, ignore_case: bool) ?usize {
        var pi: usize = 0;
        var si: usize = start;

        while (pi < pat.len) {
            // Check for quantifier after current atom
            const atom_len = atomLength(pat, pi);
            const after_atom = pi + atom_len;
            if (after_atom < pat.len and (pat[after_atom] == '*' or pat[after_atom] == '+' or pat[after_atom] == '?')) {
                const quant = pat[after_atom];
                const min: usize = if (quant == '+') 1 else 0;
                const max: usize = if (quant == '?') 1 else str.len - si + 1;
                // Greedy: try max matches first, then fewer
                var count: usize = 0;
                while (count < max and si + count <= str.len) {
                    if (!matchAtom(pat, pi, str, si + count, ignore_case)) break;
                    count += 1;
                }
                // Try from count down to min
                while (count >= min) {
                    if (matchAt(pat[after_atom + 1 ..], str, si + count, ignore_case)) |end| return end;
                    if (count == 0) break;
                    count -= 1;
                }
                return null;
            }

            // No quantifier — must match exactly once
            if (!matchAtom(pat, pi, str, si, ignore_case)) return null;
            si += 1;
            pi += atom_len;
        }
        return si;
    }

    fn atomLength(pat: []const u8, pi: usize) usize {
        if (pi < pat.len and pat[pi] == '\\' and pi + 1 < pat.len) return 2;
        if (pi < pat.len and pat[pi] == '[') {
            // Character class — find closing ]
            var j = pi + 1;
            if (j < pat.len and pat[j] == ']') j += 1; // ] at start is literal
            while (j < pat.len and pat[j] != ']') j += 1;
            if (j < pat.len) return j - pi + 1;
        }
        return 1;
    }

    fn matchAtom(pat: []const u8, pi: usize, str: []const u8, si: usize, ignore_case: bool) bool {
        if (si >= str.len) return false;
        const ch = str[si];
        if (pat[pi] == '.') return ch != '\n';
        if (pat[pi] == '\\' and pi + 1 < pat.len) {
            return switch (pat[pi + 1]) {
                'd' => ch >= '0' and ch <= '9',
                'D' => !(ch >= '0' and ch <= '9'),
                'w' => (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_',
                'W' => !((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_'),
                's' => ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r',
                'S' => !(ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'),
                'n' => ch == '\n',
                't' => ch == '\t',
                'r' => ch == '\r',
                else => ch == pat[pi + 1],
            };
        }
        if (pat[pi] == '[') {
            return matchCharClass(pat, pi, ch);
        }
        if (ignore_case) {
            const a = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            const b = if (pat[pi] >= 'A' and pat[pi] <= 'Z') pat[pi] + 32 else pat[pi];
            return a == b;
        }
        return ch == pat[pi];
    }

    fn matchCharClass(pat: []const u8, pi: usize, ch: u8) bool {
        var j = pi + 1;
        var negate = false;
        if (j < pat.len and pat[j] == '^') {
            negate = true;
            j += 1;
        }
        var matched = false;
        while (j < pat.len and pat[j] != ']') {
            if (j + 2 < pat.len and pat[j + 1] == '-' and pat[j + 2] != ']') {
                // Range
                if (ch >= pat[j] and ch <= pat[j + 2]) matched = true;
                j += 3;
            } else {
                if (ch == pat[j]) matched = true;
                j += 1;
            }
        }
        return if (negate) !matched else matched;
    }

    // ── Map methods ──────────────────────────────────────────────

    fn nativeMapConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const map_obj = try vm.allocator.create(JsObject);
        map_obj.* = .{ .obj_type = .map, .data = .{ .map_data = .{} } };
        try vm.objects.append(vm.allocator, map_obj);
        // Register methods
        try vm.registerNativeMethod(map_obj, "set", &nativeMapSet);
        try vm.registerNativeMethod(map_obj, "get", &nativeMapGet);
        try vm.registerNativeMethod(map_obj, "has", &nativeMapHas);
        try vm.registerNativeMethod(map_obj, "delete", &nativeMapDelete);
        try vm.registerNativeMethod(map_obj, "clear", &nativeMapClear);
        try vm.registerNativeMethod(map_obj, "forEach", &nativeMapForEach);
        try vm.registerNativeMethod(map_obj, "keys", &nativeMapKeys);
        try vm.registerNativeMethod(map_obj, "values", &nativeMapValues);
        try vm.registerNativeMethod(map_obj, "entries", &nativeMapEntries);
        return JsValue.initObject(map_obj);
    }

    fn mapFindIndex(map_obj: *JsObject, key: JsValue) ?usize {
        for (map_obj.data.map_data.items, 0..) |entry, i| {
            if (JsValue.jsStrictEq(entry.key, key).asBool()) return i;
        }
        return null;
    }

    fn nativeMapSet(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len < 2) return this;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return this;
        if (mapFindIndex(obj, args[0])) |idx| {
            obj.data.map_data.items[idx].val = args[1];
        } else {
            try obj.data.map_data.append(vm.allocator, .{ .key = args[0], .val = args[1] });
        }
        // Update size property
        const size_id = try vm.pool.intern("size");
        try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(@floatFromInt(obj.data.map_data.items.len)));
        return this;
    }

    fn nativeMapGet(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        if (mapFindIndex(obj, args[0])) |idx| return obj.data.map_data.items[idx].val;
        return JsValue.undefined_val;
    }

    fn nativeMapHas(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.initBool(false);
        return JsValue.initBool(mapFindIndex(obj, args[0]) != null);
    }

    fn nativeMapDelete(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.initBool(false);
        if (mapFindIndex(obj, args[0])) |idx| {
            _ = obj.data.map_data.orderedRemove(idx);
            const size_id = try vm.pool.intern("size");
            try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(@floatFromInt(obj.data.map_data.items.len)));
            return JsValue.initBool(true);
        }
        return JsValue.initBool(false);
    }

    fn nativeMapClear(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        obj.data.map_data.clearRetainingCapacity();
        const size_id = try vm.pool.intern("size");
        try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(0));
        return JsValue.undefined_val;
    }

    fn nativeMapForEach(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        const callback = args[0];
        for (obj.data.map_data.items) |entry| {
            const cb_args = [_]JsValue{ entry.val, entry.key, this };
            _ = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
        }
        return JsValue.undefined_val;
    }

    fn nativeMapKeys(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        const arr = try vm.createArray();
        for (obj.data.map_data.items) |entry| {
            try arr.data.array.append(vm.allocator, entry.key);
        }
        return JsValue.initObject(arr);
    }

    fn nativeMapValues(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        const arr = try vm.createArray();
        for (obj.data.map_data.items) |entry| {
            try arr.data.array.append(vm.allocator, entry.val);
        }
        return JsValue.initObject(arr);
    }

    fn nativeMapEntries(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .map) return JsValue.undefined_val;
        const arr = try vm.createArray();
        for (obj.data.map_data.items) |entry| {
            const pair = try vm.createArray();
            try pair.data.array.append(vm.allocator, entry.key);
            try pair.data.array.append(vm.allocator, entry.val);
            try arr.data.array.append(vm.allocator, JsValue.initObject(pair));
        }
        return JsValue.initObject(arr);
    }

    // ── Set methods ──────────────────────────────────────────────

    fn nativeSetConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const set_obj = try vm.allocator.create(JsObject);
        set_obj.* = .{ .obj_type = .set, .data = .{ .set_data = .{} } };
        try vm.objects.append(vm.allocator, set_obj);
        try vm.registerNativeMethod(set_obj, "add", &nativeSetAdd);
        try vm.registerNativeMethod(set_obj, "has", &nativeSetHas);
        try vm.registerNativeMethod(set_obj, "delete", &nativeSetDelete);
        try vm.registerNativeMethod(set_obj, "clear", &nativeSetClear);
        try vm.registerNativeMethod(set_obj, "forEach", &nativeSetForEach);
        try vm.registerNativeMethod(set_obj, "keys", &nativeSetValues); // keys() === values() for Set
        try vm.registerNativeMethod(set_obj, "values", &nativeSetValues);
        try vm.registerNativeMethod(set_obj, "entries", &nativeSetEntries);
        return JsValue.initObject(set_obj);
    }

    fn setFindIndex(set_obj: *JsObject, val: JsValue) ?usize {
        for (set_obj.data.set_data.items, 0..) |item, i| {
            if (JsValue.jsStrictEq(item, val).asBool()) return i;
        }
        return null;
    }

    fn nativeSetAdd(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return this;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return this;
        if (setFindIndex(obj, args[0]) == null) {
            try obj.data.set_data.append(vm.allocator, args[0]);
            const size_id = try vm.pool.intern("size");
            try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(@floatFromInt(obj.data.set_data.items.len)));
        }
        return this;
    }

    fn nativeSetHas(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.initBool(false);
        return JsValue.initBool(setFindIndex(obj, args[0]) != null);
    }

    fn nativeSetDelete(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.initBool(false);
        if (setFindIndex(obj, args[0])) |idx| {
            _ = obj.data.set_data.orderedRemove(idx);
            const size_id = try vm.pool.intern("size");
            try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(@floatFromInt(obj.data.set_data.items.len)));
            return JsValue.initBool(true);
        }
        return JsValue.initBool(false);
    }

    fn nativeSetClear(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.undefined_val;
        obj.data.set_data.clearRetainingCapacity();
        const size_id = try vm.pool.intern("size");
        try obj.setProperty(vm.allocator, size_id, JsValue.initNumber(0));
        return JsValue.undefined_val;
    }

    fn nativeSetForEach(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.undefined_val;
        const callback = args[0];
        for (obj.data.set_data.items) |item| {
            const cb_args = [_]JsValue{ item, item, this };
            _ = try vm.callJsFunction(callback, JsValue.undefined_val, &cb_args);
        }
        return JsValue.undefined_val;
    }

    fn nativeSetValues(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.undefined_val;
        const arr = try vm.createArray();
        for (obj.data.set_data.items) |item| {
            try arr.data.array.append(vm.allocator, item);
        }
        return JsValue.initObject(arr);
    }

    fn nativeSetEntries(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        if (!this.isObject()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (obj.obj_type != .set) return JsValue.undefined_val;
        const arr = try vm.createArray();
        for (obj.data.set_data.items) |item| {
            const pair = try vm.createArray();
            try pair.data.array.append(vm.allocator, item);
            try pair.data.array.append(vm.allocator, item);
            try arr.data.array.append(vm.allocator, JsValue.initObject(pair));
        }
        return JsValue.initObject(arr);
    }

    // ── JSON methods ───────────────────────────────────────────────

    fn nativeJsonStringify(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        try jsonSerialize(vm, args[0], &buf);
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn jsonSerialize(vm: *VM, val: JsValue, buf: *std.ArrayListUnmanaged(u8)) !void {
        if (val.isNull() or val.isUndefined()) {
            try buf.appendSlice(vm.allocator, "null");
        } else if (val.isBool()) {
            try buf.appendSlice(vm.allocator, if (val.asBool()) "true" else "false");
        } else if (val.isInt()) {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{val.asInt()}) catch "0";
            try buf.appendSlice(vm.allocator, s);
        } else if (val.isNumber()) {
            const n = val.asNumber();
            if (std.math.isNan(n) or std.math.isInf(n)) {
                try buf.appendSlice(vm.allocator, "null");
            } else {
                var tmp: [64]u8 = undefined;
                const s = formatValue(vm.pool, val, &tmp);
                try buf.appendSlice(vm.allocator, s);
            }
        } else if (val.isString()) {
            const s = vm.pool.get(val.asStringId()) orelse "";
            try buf.append(vm.allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(vm.allocator, "\\\""),
                    '\\' => try buf.appendSlice(vm.allocator, "\\\\"),
                    '\n' => try buf.appendSlice(vm.allocator, "\\n"),
                    '\r' => try buf.appendSlice(vm.allocator, "\\r"),
                    '\t' => try buf.appendSlice(vm.allocator, "\\t"),
                    else => try buf.append(vm.allocator, c),
                }
            }
            try buf.append(vm.allocator, '"');
        } else if (val.isObject()) {
            const obj = val.asJsObject();
            if (obj.obj_type == .array) {
                try buf.append(vm.allocator, '[');
                for (obj.data.array.items, 0..) |item, i| {
                    if (i > 0) try buf.append(vm.allocator, ',');
                    try jsonSerialize(vm, item, buf);
                }
                try buf.append(vm.allocator, ']');
            } else if (obj.obj_type == .function or obj.obj_type == .native_function) {
                try buf.appendSlice(vm.allocator, "undefined");
            } else {
                try buf.append(vm.allocator, '{');
                var first = true;
                for (obj.properties.keys(), obj.properties.values()) |key_id, prop_val| {
                    // Skip function values in JSON
                    if (prop_val.isObject()) {
                        const p = prop_val.asJsObject();
                        if (p.obj_type == .function or p.obj_type == .native_function) continue;
                    }
                    if (!first) try buf.append(vm.allocator, ',');
                    first = false;
                    const key_str = vm.pool.get(key_id) orelse "";
                    try buf.append(vm.allocator, '"');
                    try buf.appendSlice(vm.allocator, key_str);
                    try buf.append(vm.allocator, '"');
                    try buf.append(vm.allocator, ':');
                    try jsonSerialize(vm, prop_val, buf);
                }
                try buf.append(vm.allocator, '}');
            }
        } else {
            try buf.appendSlice(vm.allocator, "null");
        }
    }

    fn nativeJsonParse(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0 or !args[0].isString()) return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const s = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
        var pos: usize = 0;
        return jsonParseValue(vm, s, &pos) catch JsValue.undefined_val;
    }

    fn jsonParseValue(vm: *VM, s: []const u8, pos: *usize) error{OutOfMemory}!JsValue {
        jsonSkipWhitespace(s, pos);
        if (pos.* >= s.len) return JsValue.undefined_val;
        return switch (s[pos.*]) {
            '"' => jsonParseString(vm, s, pos),
            '{' => jsonParseObject(vm, s, pos),
            '[' => jsonParseArray(vm, s, pos),
            't' => {
                if (pos.* + 4 <= s.len and std.mem.eql(u8, s[pos.* .. pos.* + 4], "true")) {
                    pos.* += 4;
                    return JsValue.initBool(true);
                }
                return JsValue.undefined_val;
            },
            'f' => {
                if (pos.* + 5 <= s.len and std.mem.eql(u8, s[pos.* .. pos.* + 5], "false")) {
                    pos.* += 5;
                    return JsValue.initBool(false);
                }
                return JsValue.undefined_val;
            },
            'n' => {
                if (pos.* + 4 <= s.len and std.mem.eql(u8, s[pos.* .. pos.* + 4], "null")) {
                    pos.* += 4;
                    return JsValue.null_val;
                }
                return JsValue.undefined_val;
            },
            else => jsonParseNumber(s, pos),
        };
    }

    fn jsonSkipWhitespace(s: []const u8, pos: *usize) void {
        while (pos.* < s.len and (s[pos.*] == ' ' or s[pos.*] == '\t' or s[pos.*] == '\n' or s[pos.*] == '\r')) pos.* += 1;
    }

    fn jsonParseString(vm: *VM, s: []const u8, pos: *usize) !JsValue {
        pos.* += 1; // skip opening "
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        while (pos.* < s.len and s[pos.*] != '"') {
            if (s[pos.*] == '\\' and pos.* + 1 < s.len) {
                pos.* += 1;
                switch (s[pos.*]) {
                    'n' => try buf.append(vm.allocator, '\n'),
                    'r' => try buf.append(vm.allocator, '\r'),
                    't' => try buf.append(vm.allocator, '\t'),
                    '"' => try buf.append(vm.allocator, '"'),
                    '\\' => try buf.append(vm.allocator, '\\'),
                    '/' => try buf.append(vm.allocator, '/'),
                    else => try buf.append(vm.allocator, s[pos.*]),
                }
            } else {
                try buf.append(vm.allocator, s[pos.*]);
            }
            pos.* += 1;
        }
        if (pos.* < s.len) pos.* += 1; // skip closing "
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn jsonParseNumber(s: []const u8, pos: *usize) !JsValue {
        const start = pos.*;
        if (pos.* < s.len and (s[pos.*] == '-' or s[pos.*] == '+')) pos.* += 1;
        while (pos.* < s.len and s[pos.*] >= '0' and s[pos.*] <= '9') pos.* += 1;
        if (pos.* < s.len and s[pos.*] == '.') {
            pos.* += 1;
            while (pos.* < s.len and s[pos.*] >= '0' and s[pos.*] <= '9') pos.* += 1;
        }
        if (pos.* < s.len and (s[pos.*] == 'e' or s[pos.*] == 'E')) {
            pos.* += 1;
            if (pos.* < s.len and (s[pos.*] == '-' or s[pos.*] == '+')) pos.* += 1;
            while (pos.* < s.len and s[pos.*] >= '0' and s[pos.*] <= '9') pos.* += 1;
        }
        if (pos.* == start) return JsValue.undefined_val;
        const n = std.fmt.parseFloat(f64, s[start..pos.*]) catch return JsValue.nan_val;
        return JsValue.initNumber(n);
    }

    fn jsonParseObject(vm: *VM, s: []const u8, pos: *usize) !JsValue {
        pos.* += 1; // skip {
        const obj = try vm.createObj(.{});
        jsonSkipWhitespace(s, pos);
        if (pos.* < s.len and s[pos.*] == '}') {
            pos.* += 1;
            return JsValue.initObject(obj);
        }
        while (pos.* < s.len) {
            jsonSkipWhitespace(s, pos);
            if (pos.* >= s.len or s[pos.*] != '"') break;
            const key_val = try jsonParseString(vm, s, pos);
            jsonSkipWhitespace(s, pos);
            if (pos.* < s.len and s[pos.*] == ':') pos.* += 1;
            const val = try jsonParseValue(vm, s, pos);
            try obj.setProperty(vm.allocator, key_val.asStringId(), val);
            jsonSkipWhitespace(s, pos);
            if (pos.* < s.len and s[pos.*] == ',') {
                pos.* += 1;
            } else break;
        }
        if (pos.* < s.len and s[pos.*] == '}') pos.* += 1;
        return JsValue.initObject(obj);
    }

    fn jsonParseArray(vm: *VM, s: []const u8, pos: *usize) !JsValue {
        pos.* += 1; // skip [
        const arr = try vm.createArray();
        jsonSkipWhitespace(s, pos);
        if (pos.* < s.len and s[pos.*] == ']') {
            pos.* += 1;
            return JsValue.initObject(arr);
        }
        while (pos.* < s.len) {
            const val = try jsonParseValue(vm, s, pos);
            try arr.data.array.append(vm.allocator, val);
            jsonSkipWhitespace(s, pos);
            if (pos.* < s.len and s[pos.*] == ',') {
                pos.* += 1;
            } else break;
        }
        if (pos.* < s.len and s[pos.*] == ']') pos.* += 1;
        return JsValue.initObject(arr);
    }

    // ── Math methods ───────────────────────────────────────────────

    fn nativeMathFloor(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@floor(args[0].toNumber()));
    }

    fn nativeMathCeil(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@ceil(args[0].toNumber()));
    }

    fn nativeMathRound(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@round(args[0].toNumber()));
    }

    fn nativeMathAbs(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@abs(args[0].toNumber()));
    }

    fn nativeMathMin(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initNumber(std.math.inf(f64));
        var result = args[0].toNumber();
        for (args[1..]) |a| {
            const n = a.toNumber();
            if (std.math.isNan(n)) return JsValue.nan_val;
            if (n < result) result = n;
        }
        return JsValue.initNumber(result);
    }

    fn nativeMathMax(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initNumber(-std.math.inf(f64));
        var result = args[0].toNumber();
        for (args[1..]) |a| {
            const n = a.toNumber();
            if (std.math.isNan(n)) return JsValue.nan_val;
            if (n > result) result = n;
        }
        return JsValue.initNumber(result);
    }

    fn nativeMathRandom(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        // Simple PRNG — good enough for non-crypto use
        const S = struct {
            var state: u64 = 0x853c49e6748fea9b;
        };
        S.state ^= S.state << 13;
        S.state ^= S.state >> 7;
        S.state ^= S.state << 17;
        const f: f64 = @as(f64, @floatFromInt(S.state & 0x1FFFFFFFFFFFFF)) / @as(f64, @floatFromInt(@as(u64, 0x1FFFFFFFFFFFFF)));
        return JsValue.initNumber(f);
    }

    fn nativeMathPow(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 2) return JsValue.nan_val;
        return JsValue.initNumber(std.math.pow(f64, args[0].toNumber(), args[1].toNumber()));
    }

    fn nativeMathSqrt(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@sqrt(args[0].toNumber()));
    }

    fn nativeMathLog(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@log(args[0].toNumber()));
    }

    fn nativeMathLog10(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(std.math.log10(args[0].toNumber()));
    }

    fn nativeMathTrunc(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        return JsValue.initNumber(@trunc(args[0].toNumber()));
    }

    fn nativeMathSign(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const n = args[0].toNumber();
        if (std.math.isNan(n)) return JsValue.nan_val;
        if (n > 0) return JsValue.initNumber(1);
        if (n < 0) return JsValue.initNumber(-1);
        return JsValue.initNumber(0);
    }

    // ── Global functions ───────────────────────────────────────────

    fn nativeParseInt(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const vm = vmFromCtx(ctx);
        if (args[0].isNumber()) return JsValue.initNumber(@trunc(args[0].asNumber()));
        if (args[0].isInt()) return args[0];
        if (!args[0].isString()) return JsValue.nan_val;
        const s = std.mem.trim(u8, vm.pool.get(args[0].asStringId()) orelse return JsValue.nan_val, " \t\n\r");
        if (s.len == 0) return JsValue.nan_val;
        // Determine radix
        var radix: u8 = 10;
        var start: usize = 0;
        if (args.len > 1) {
            const r = args[1].toNumber();
            if (!std.math.isNan(r) and r >= 2 and r <= 36) radix = @intFromFloat(r);
        } else if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            radix = 16;
            start = 2;
        }
        var neg = false;
        if (start < s.len and s[start] == '-') {
            neg = true;
            start += 1;
        } else if (start < s.len and s[start] == '+') {
            start += 1;
        }
        var result: f64 = 0;
        var found = false;
        for (s[start..]) |c| {
            const digit: u8 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'a' and c <= 'z')
                c - 'a' + 10
            else if (c >= 'A' and c <= 'Z')
                c - 'A' + 10
            else
                break;
            if (digit >= radix) break;
            found = true;
            result = result * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
        }
        if (!found) return JsValue.nan_val;
        return JsValue.initNumber(if (neg) -result else result);
    }

    fn nativeParseFloat(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        if (args[0].isNumber()) return args[0];
        if (args[0].isInt()) return JsValue.initNumber(@floatFromInt(args[0].asInt()));
        if (!args[0].isString()) return JsValue.nan_val;
        const vm = vmFromCtx(ctx);
        const s = std.mem.trim(u8, vm.pool.get(args[0].asStringId()) orelse return JsValue.nan_val, " \t\n\r");
        const n = std.fmt.parseFloat(f64, s) catch return JsValue.nan_val;
        return JsValue.initNumber(n);
    }

    fn nativeIsNaN(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(true);
        return JsValue.initBool(std.math.isNan(args[0].toNumber()));
    }

    fn nativeIsFinite(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(false);
        const n = args[0].toNumber();
        return JsValue.initBool(!std.math.isNan(n) and !std.math.isInf(n));
    }

    fn nativeStringMatch(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.null_val;
        if (args.len == 0) return JsValue.null_val;
        const vm = vmFromCtx(ctx);
        // Accept RegExp object or string pattern
        var pattern: []const u8 = undefined;
        var ignore_case = false;
        if (args[0].isObject()) {
            const obj = args[0].asJsObject();
            if (obj.obj_type == .regexp) {
                const re = obj.data.regexp_data;
                pattern = vm.pool.get(re.source) orelse return JsValue.null_val;
                ignore_case = re.ignore_case;
            } else return JsValue.null_val;
        } else if (args[0].isString()) {
            pattern = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
        } else return JsValue.null_val;

        const result = simpleMatch(pattern, s, ignore_case) orelse return JsValue.null_val;
        const arr = try vm.createArray();
        const matched = s[result.start..result.end];
        const match_sid = try vm.pool.intern(matched);
        try arr.data.array.append(vm.allocator, JsValue.initString(match_sid));
        const index_id = try vm.pool.intern("index");
        try arr.setProperty(vm.allocator, index_id, JsValue.initNumber(@floatFromInt(result.start)));
        return JsValue.initObject(arr);
    }

    fn nativeStringSearch(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initNumber(-1);
        if (args.len == 0) return JsValue.initNumber(-1);
        const vm = vmFromCtx(ctx);
        var pattern: []const u8 = undefined;
        var ignore_case = false;
        if (args[0].isObject()) {
            const obj = args[0].asJsObject();
            if (obj.obj_type == .regexp) {
                const re = obj.data.regexp_data;
                pattern = vm.pool.get(re.source) orelse return JsValue.initNumber(-1);
                ignore_case = re.ignore_case;
            } else return JsValue.initNumber(-1);
        } else if (args[0].isString()) {
            pattern = vm.pool.get(args[0].asStringId()) orelse return JsValue.initNumber(-1);
        } else return JsValue.initNumber(-1);

        const result = simpleMatch(pattern, s, ignore_case) orelse return JsValue.initNumber(-1);
        return JsValue.initNumber(@floatFromInt(result.start));
    }

    // ── String extra methods ───────────────────────────────────────

    fn nativeStringRepeat(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return JsValue.initString(try vm.pool.intern(""));
        const count = clampToUsize(args[0]);
        if (count == 0 or s.len == 0) return JsValue.initString(try vm.pool.intern(""));
        if (count > 10000) return JsValue.initString(try vm.pool.intern("")); // safety limit
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        var i: usize = 0;
        while (i < count) : (i += 1) try buf.appendSlice(vm.allocator, s);
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn nativeStringPadStart(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return this;
        const target_len = clampToUsize(args[0]);
        if (target_len <= s.len) return this;
        const pad_str = if (args.len > 1 and args[1].isString())
            vm.pool.get(args[1].asStringId()) orelse " "
        else
            " ";
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        const pad_needed = target_len - s.len;
        var i: usize = 0;
        while (i < pad_needed) : (i += 1) {
            try buf.append(vm.allocator, pad_str[i % pad_str.len]);
        }
        try buf.appendSlice(vm.allocator, s);
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn nativeStringPadEnd(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return this;
        const target_len = clampToUsize(args[0]);
        if (target_len <= s.len) return this;
        const pad_str = if (args.len > 1 and args[1].isString())
            vm.pool.get(args[1].asStringId()) orelse " "
        else
            " ";
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        try buf.appendSlice(vm.allocator, s);
        var i: usize = 0;
        const pad_needed = target_len - s.len;
        while (i < pad_needed) : (i += 1) {
            try buf.append(vm.allocator, pad_str[i % pad_str.len]);
        }
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn nativeStringTrimStart(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const trimmed = std.mem.trimLeft(u8, s, " \t\r\n");
        return JsValue.initString(try vm.pool.intern(trimmed));
    }

    fn nativeStringTrimEnd(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        const trimmed = std.mem.trimRight(u8, s, " \t\r\n");
        return JsValue.initString(try vm.pool.intern(trimmed));
    }

    fn nativeStringReplaceAll(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        if (args.len < 2) return this;
        const search = if (args[0].isString()) vm.pool.get(args[0].asStringId()) orelse return this else return this;
        const replacement = if (args[1].isString()) vm.pool.get(args[1].asStringId()) orelse "" else "";
        if (search.len == 0) return this;
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        var i: usize = 0;
        while (i < s.len) {
            if (i + search.len <= s.len and std.mem.eql(u8, s[i..][0..search.len], search)) {
                try buf.appendSlice(vm.allocator, replacement);
                i += search.len;
            } else {
                try buf.append(vm.allocator, s[i]);
                i += 1;
            }
        }
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn nativeStringLastIndexOf(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.initNumber(-1);
        const vm = vmFromCtx(ctx);
        if (args.len == 0) return JsValue.initNumber(-1);
        const search = if (args[0].isString()) vm.pool.get(args[0].asStringId()) orelse return JsValue.initNumber(-1) else return JsValue.initNumber(-1);
        if (search.len > s.len) return JsValue.initNumber(-1);
        var last: i32 = -1;
        var i: usize = 0;
        while (i + search.len <= s.len) : (i += 1) {
            if (std.mem.eql(u8, s[i..][0..search.len], search)) {
                last = @intCast(i);
            }
        }
        return JsValue.initNumber(@floatFromInt(last));
    }

    fn nativeStringConcat(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        try buf.appendSlice(vm.allocator, s);
        for (args) |arg| {
            if (arg.isString()) {
                if (vm.pool.get(arg.asStringId())) |str| {
                    try buf.appendSlice(vm.allocator, str);
                }
            }
        }
        return JsValue.initString(try vm.pool.intern(buf.items));
    }

    fn nativeStringAt(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const s = getStr(ctx, this) orelse return JsValue.undefined_val;
        const vm = vmFromCtx(ctx);
        if (args.len == 0 or s.len == 0) return JsValue.undefined_val;
        const len: i64 = @intCast(s.len);
        var idx: i64 = clampToI64(args[0]);
        if (idx < 0) idx += len;
        if (idx < 0 or idx >= len) return JsValue.undefined_val;
        const uidx: usize = @intCast(idx);
        return JsValue.initString(try vm.pool.intern(s[uidx .. uidx + 1]));
    }

    // ── Helper: create array ───────────────────────────────────────

    fn createArray(self: *VM) !*JsObject {
        const obj = try self.allocator.create(JsObject);
        obj.* = .{ .obj_type = .array, .data = .{ .array = .{} }, .prototype = self.array_proto };
        try self.objects.append(self.allocator, obj);
        return obj;
    }

    fn createNativeFn(self: *VM, func: NativeFn) !*JsObject {
        const fn_obj = try self.allocator.create(JsObject);
        fn_obj.* = .{ .obj_type = .native_function, .data = .{ .native_fn = func } };
        try self.objects.append(self.allocator, fn_obj);
        return fn_obj;
    }

    // ── Helpers ──────────────────────────────────────────────────────

    fn clampToI64(val: JsValue) i64 {
        if (val.isInt()) return val.asInt();
        const n = val.toNumber();
        if (std.math.isNan(n)) return 0;
        if (n >= 2147483648.0) return 2147483647;
        if (n <= -2147483649.0) return -2147483648;
        // Truncate toward zero (same as JS ToInteger)
        if (n > 0) return @intFromFloat(@floor(n));
        return -@as(i64, @intFromFloat(@floor(-n)));
    }

    fn clampToUsize(val: JsValue) usize {
        const n = val.toNumber();
        if (std.math.isNan(n) or n < 0) return 0;
        return @intFromFloat(@min(n, 4294967295.0));
    }

    // ── Promise aggregation methods ────────────────────────────────

    fn nativePromiseAll(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const result_promise = try vm.createPromiseObj();
        const items = getArrayItems(args) orelse {
            try vm.resolvePromise(result_promise, JsValue.initObject(try vm.createArray()));
            return JsValue.initObject(result_promise);
        };
        if (items.len == 0) {
            try vm.resolvePromise(result_promise, JsValue.initObject(try vm.createArray()));
            return JsValue.initObject(result_promise);
        }
        // Shared state: results array + counter stored as properties on a state object
        const state = try vm.createObj(.{});
        const results = try vm.createArray();
        for (0..items.len) |_| try results.data.array.append(vm.allocator, JsValue.undefined_val);
        try state.setProperty(vm.allocator, try vm.pool.intern("r"), JsValue.initObject(results));
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(0));
        try state.setProperty(vm.allocator, try vm.pool.intern("t"), JsValue.initNumber(@floatFromInt(items.len)));
        try state.setProperty(vm.allocator, try vm.pool.intern("p"), JsValue.initObject(result_promise));
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(false)); // done flag

        for (items, 0..) |item, idx| {
            // Wrap each item with Promise.resolve behavior
            const wrapped: JsValue = if (item.isObject() and item.asJsObject().obj_type == .promise)
                item
            else blk: {
                const p = try vm.createPromiseObj();
                try vm.resolvePromise(p, item);
                break :blk JsValue.initObject(p);
            };
            // Create resolve handler that captures index + state
            const handler_obj = try vm.createObj(.{});
            handler_obj.obj_type = .native_function;
            handler_obj.data = .{ .native_fn = &promiseAllOnFulfilled };
            try handler_obj.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try handler_obj.setProperty(vm.allocator, try vm.pool.intern("i"), JsValue.initNumber(@floatFromInt(idx)));
            // Create reject handler
            const rej_obj = try vm.createObj(.{});
            rej_obj.obj_type = .native_function;
            rej_obj.data = .{ .native_fn = &promiseAggReject };
            try rej_obj.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            // Attach .then(handler, reject)
            _ = try nativePromiseThen(@ptrCast(vm), wrapped, &.{ JsValue.initObject(handler_obj), JsValue.initObject(rej_obj) });
        }
        return JsValue.initObject(result_promise);
    }

    fn promiseAllOnFulfilled(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const done_val = state.getProperty(try vm.pool.intern("d")) orelse JsValue.initBool(false);
        if (done_val.isBool() and done_val.asBool()) return JsValue.undefined_val;
        const idx: usize = @intFromFloat((caller.getProperty(try vm.pool.intern("i")) orelse JsValue.initNumber(0)).asNumber());
        const results = (state.getProperty(try vm.pool.intern("r")) orelse return JsValue.undefined_val).asJsObject();
        const val = if (args.len > 0) args[0] else JsValue.undefined_val;
        if (idx < results.data.array.items.len) results.data.array.items[idx] = val;
        const count = (state.getProperty(try vm.pool.intern("c")) orelse JsValue.initNumber(0)).asNumber() + 1;
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(count));
        const total = (state.getProperty(try vm.pool.intern("t")) orelse JsValue.initNumber(0)).asNumber();
        if (count >= total) {
            try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(true));
            const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
            try vm.resolvePromise(promise, JsValue.initObject(results));
        }
        return JsValue.undefined_val;
    }

    fn promiseAggReject(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const done_val = state.getProperty(try vm.pool.intern("d")) orelse JsValue.initBool(false);
        if (done_val.isBool() and done_val.asBool()) return JsValue.undefined_val;
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(true));
        const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
        const reason = if (args.len > 0) args[0] else JsValue.undefined_val;
        try vm.rejectPromise(promise, reason);
        return JsValue.undefined_val;
    }

    fn nativePromiseRace(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const result_promise = try vm.createPromiseObj();
        const items = getArrayItems(args) orelse return JsValue.initObject(result_promise);
        if (items.len == 0) return JsValue.initObject(result_promise); // never settles per spec

        const state = try vm.createObj(.{});
        try state.setProperty(vm.allocator, try vm.pool.intern("p"), JsValue.initObject(result_promise));
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(false));

        for (items) |item| {
            const wrapped: JsValue = if (item.isObject() and item.asJsObject().obj_type == .promise)
                item
            else blk: {
                const p = try vm.createPromiseObj();
                try vm.resolvePromise(p, item);
                break :blk JsValue.initObject(p);
            };
            const res_fn = try vm.createObj(.{});
            res_fn.obj_type = .native_function;
            res_fn.data = .{ .native_fn = &promiseRaceOnSettle };
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("m"), JsValue.initBool(false)); // mode: false=resolve
            const rej_fn = try vm.createObj(.{});
            rej_fn.obj_type = .native_function;
            rej_fn.data = .{ .native_fn = &promiseRaceOnSettle };
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("m"), JsValue.initBool(true)); // mode: true=reject
            _ = try nativePromiseThen(@ptrCast(vm), wrapped, &.{ JsValue.initObject(res_fn), JsValue.initObject(rej_fn) });
        }
        return JsValue.initObject(result_promise);
    }

    fn promiseRaceOnSettle(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const done_val = state.getProperty(try vm.pool.intern("d")) orelse JsValue.initBool(false);
        if (done_val.isBool() and done_val.asBool()) return JsValue.undefined_val;
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(true));
        const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
        const val = if (args.len > 0) args[0] else JsValue.undefined_val;
        const is_reject = (caller.getProperty(try vm.pool.intern("m")) orelse JsValue.initBool(false)).asBool();
        if (is_reject) try vm.rejectPromise(promise, val) else try vm.resolvePromise(promise, val);
        return JsValue.undefined_val;
    }

    fn nativePromiseAllSettled(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const result_promise = try vm.createPromiseObj();
        const items = getArrayItems(args) orelse {
            try vm.resolvePromise(result_promise, JsValue.initObject(try vm.createArray()));
            return JsValue.initObject(result_promise);
        };
        if (items.len == 0) {
            try vm.resolvePromise(result_promise, JsValue.initObject(try vm.createArray()));
            return JsValue.initObject(result_promise);
        }
        const state = try vm.createObj(.{});
        const results = try vm.createArray();
        for (0..items.len) |_| try results.data.array.append(vm.allocator, JsValue.undefined_val);
        try state.setProperty(vm.allocator, try vm.pool.intern("r"), JsValue.initObject(results));
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(0));
        try state.setProperty(vm.allocator, try vm.pool.intern("t"), JsValue.initNumber(@floatFromInt(items.len)));
        try state.setProperty(vm.allocator, try vm.pool.intern("p"), JsValue.initObject(result_promise));

        for (items, 0..) |item, idx| {
            const wrapped: JsValue = if (item.isObject() and item.asJsObject().obj_type == .promise)
                item
            else blk: {
                const p = try vm.createPromiseObj();
                try vm.resolvePromise(p, item);
                break :blk JsValue.initObject(p);
            };
            const res_fn = try vm.createObj(.{});
            res_fn.obj_type = .native_function;
            res_fn.data = .{ .native_fn = &promiseAllSettledOnSettle };
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("i"), JsValue.initNumber(@floatFromInt(idx)));
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("m"), JsValue.initBool(false));
            const rej_fn = try vm.createObj(.{});
            rej_fn.obj_type = .native_function;
            rej_fn.data = .{ .native_fn = &promiseAllSettledOnSettle };
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("i"), JsValue.initNumber(@floatFromInt(idx)));
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("m"), JsValue.initBool(true));
            _ = try nativePromiseThen(@ptrCast(vm), wrapped, &.{ JsValue.initObject(res_fn), JsValue.initObject(rej_fn) });
        }
        return JsValue.initObject(result_promise);
    }

    fn promiseAllSettledOnSettle(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const idx: usize = @intFromFloat((caller.getProperty(try vm.pool.intern("i")) orelse JsValue.initNumber(0)).asNumber());
        const is_reject = (caller.getProperty(try vm.pool.intern("m")) orelse JsValue.initBool(false)).asBool();
        const results = (state.getProperty(try vm.pool.intern("r")) orelse return JsValue.undefined_val).asJsObject();
        const val = if (args.len > 0) args[0] else JsValue.undefined_val;
        // Create {status, value/reason} object
        const entry = try vm.createObj(.{});
        const status_str = if (is_reject) "rejected" else "fulfilled";
        try entry.setProperty(vm.allocator, try vm.pool.intern("status"), JsValue.initString(try vm.pool.intern(status_str)));
        if (is_reject) {
            try entry.setProperty(vm.allocator, try vm.pool.intern("reason"), val);
        } else {
            try entry.setProperty(vm.allocator, try vm.pool.intern("value"), val);
        }
        if (idx < results.data.array.items.len) results.data.array.items[idx] = JsValue.initObject(entry);
        const count = (state.getProperty(try vm.pool.intern("c")) orelse JsValue.initNumber(0)).asNumber() + 1;
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(count));
        const total = (state.getProperty(try vm.pool.intern("t")) orelse JsValue.initNumber(0)).asNumber();
        if (count >= total) {
            const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
            try vm.resolvePromise(promise, JsValue.initObject(results));
        }
        return JsValue.undefined_val;
    }

    fn nativePromiseAny(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const result_promise = try vm.createPromiseObj();
        const items = getArrayItems(args) orelse {
            // Empty → reject with AggregateError
            const err = try vm.createObj(.{});
            if (vm.error_proto) |ep| err.prototype = ep;
            try err.setProperty(vm.allocator, try vm.pool.intern("message"), JsValue.initString(try vm.pool.intern("All promises were rejected")));
            try err.setProperty(vm.allocator, try vm.pool.intern("name"), JsValue.initString(try vm.pool.intern("AggregateError")));
            try err.setProperty(vm.allocator, try vm.pool.intern("errors"), JsValue.initObject(try vm.createArray()));
            try vm.rejectPromise(result_promise, JsValue.initObject(err));
            return JsValue.initObject(result_promise);
        };
        if (items.len == 0) {
            const err = try vm.createObj(.{});
            if (vm.error_proto) |ep| err.prototype = ep;
            try err.setProperty(vm.allocator, try vm.pool.intern("message"), JsValue.initString(try vm.pool.intern("All promises were rejected")));
            try err.setProperty(vm.allocator, try vm.pool.intern("name"), JsValue.initString(try vm.pool.intern("AggregateError")));
            try err.setProperty(vm.allocator, try vm.pool.intern("errors"), JsValue.initObject(try vm.createArray()));
            try vm.rejectPromise(result_promise, JsValue.initObject(err));
            return JsValue.initObject(result_promise);
        }
        const state = try vm.createObj(.{});
        const errors = try vm.createArray();
        for (0..items.len) |_| try errors.data.array.append(vm.allocator, JsValue.undefined_val);
        try state.setProperty(vm.allocator, try vm.pool.intern("e"), JsValue.initObject(errors));
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(0));
        try state.setProperty(vm.allocator, try vm.pool.intern("t"), JsValue.initNumber(@floatFromInt(items.len)));
        try state.setProperty(vm.allocator, try vm.pool.intern("p"), JsValue.initObject(result_promise));
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(false));

        for (items, 0..) |item, idx| {
            const wrapped: JsValue = if (item.isObject() and item.asJsObject().obj_type == .promise)
                item
            else blk: {
                const p = try vm.createPromiseObj();
                try vm.resolvePromise(p, item);
                break :blk JsValue.initObject(p);
            };
            // Resolve handler: first to fulfill wins
            const res_fn = try vm.createObj(.{});
            res_fn.obj_type = .native_function;
            res_fn.data = .{ .native_fn = &promiseAnyOnFulfilled };
            try res_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            // Reject handler: count rejections
            const rej_fn = try vm.createObj(.{});
            rej_fn.obj_type = .native_function;
            rej_fn.data = .{ .native_fn = &promiseAnyOnRejected };
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("s"), JsValue.initObject(state));
            try rej_fn.setProperty(vm.allocator, try vm.pool.intern("i"), JsValue.initNumber(@floatFromInt(idx)));
            _ = try nativePromiseThen(@ptrCast(vm), wrapped, &.{ JsValue.initObject(res_fn), JsValue.initObject(rej_fn) });
        }
        return JsValue.initObject(result_promise);
    }

    fn promiseAnyOnFulfilled(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const done_val = state.getProperty(try vm.pool.intern("d")) orelse JsValue.initBool(false);
        if (done_val.isBool() and done_val.asBool()) return JsValue.undefined_val;
        try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(true));
        const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
        const val = if (args.len > 0) args[0] else JsValue.undefined_val;
        try vm.resolvePromise(promise, val);
        return JsValue.undefined_val;
    }

    fn promiseAnyOnRejected(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const caller = getCallerFuncObj(vm) orelse return JsValue.undefined_val;
        const state = (caller.getProperty(try vm.pool.intern("s")) orelse return JsValue.undefined_val).asJsObject();
        const done_val = state.getProperty(try vm.pool.intern("d")) orelse JsValue.initBool(false);
        if (done_val.isBool() and done_val.asBool()) return JsValue.undefined_val;
        const idx: usize = @intFromFloat((caller.getProperty(try vm.pool.intern("i")) orelse JsValue.initNumber(0)).asNumber());
        const errors = (state.getProperty(try vm.pool.intern("e")) orelse return JsValue.undefined_val).asJsObject();
        const reason = if (args.len > 0) args[0] else JsValue.undefined_val;
        if (idx < errors.data.array.items.len) errors.data.array.items[idx] = reason;
        const count = (state.getProperty(try vm.pool.intern("c")) orelse JsValue.initNumber(0)).asNumber() + 1;
        try state.setProperty(vm.allocator, try vm.pool.intern("c"), JsValue.initNumber(count));
        const total = (state.getProperty(try vm.pool.intern("t")) orelse JsValue.initNumber(0)).asNumber();
        if (count >= total) {
            try state.setProperty(vm.allocator, try vm.pool.intern("d"), JsValue.initBool(true));
            const promise = (state.getProperty(try vm.pool.intern("p")) orelse return JsValue.undefined_val).asJsObject();
            const err = try vm.createObj(.{});
            if (vm.error_proto) |ep| err.prototype = ep;
            try err.setProperty(vm.allocator, try vm.pool.intern("message"), JsValue.initString(try vm.pool.intern("All promises were rejected")));
            try err.setProperty(vm.allocator, try vm.pool.intern("name"), JsValue.initString(try vm.pool.intern("AggregateError")));
            try err.setProperty(vm.allocator, try vm.pool.intern("errors"), JsValue.initObject(errors));
            try vm.rejectPromise(promise, JsValue.initObject(err));
        }
        return JsValue.undefined_val;
    }

    // Helper: get array items from first argument
    fn getArrayItems(args: []const JsValue) ?[]const JsValue {
        if (args.len == 0 or !args[0].isObject()) return null;
        const obj = args[0].asJsObject();
        if (obj.obj_type != .array) return null;
        return obj.data.array.items;
    }

    // Helper: find calling native function on the stack.
    // callJsFunction pushes func_val before calling native, so it's at sp-1
    // (since native runs before sp is adjusted). Walk back to find it.
    fn getCallerFuncObj(vm: *VM) ?*JsObject {
        const s_id = vm.pool.intern("s") catch return null;
        var i = vm.sp;
        while (i > 0) {
            i -= 1;
            const val = vm.stack[i];
            if (val.isObject()) {
                const obj = val.asJsObject();
                if (obj.obj_type == .native_function) {
                    if (obj.getProperty(s_id) != null) return obj;
                }
            }
        }
        return null;
    }

    // ── Date helpers ──────────────────────────────────────────────

    fn msToLocalTm(ms: i64) ctime.struct_tm {
        const secs: ctime.time_t = @intCast(@divTrunc(ms, 1000));
        var tm: ctime.struct_tm = undefined;
        _ = ctime.localtime_r(&secs, &tm);
        return tm;
    }

    fn msToUtcTm(ms: i64) ctime.struct_tm {
        const secs: ctime.time_t = @intCast(@divTrunc(ms, 1000));
        var tm: ctime.struct_tm = undefined;
        _ = ctime.gmtime_r(&secs, &tm);
        return tm;
    }

    fn tmToLocalMs(tm_ptr: *ctime.struct_tm, orig_ms: i64) i64 {
        tm_ptr.tm_isdst = -1;
        const secs = ctime.mktime(tm_ptr);
        return @as(i64, secs) * 1000 + @rem(orig_ms, 1000);
    }

    fn getDateMs(this: JsValue) ?i64 {
        if (!this.isObject()) return null;
        const obj = this.asJsObject();
        if (obj.obj_type != .date) return null;
        return obj.data.date_ms;
    }

    fn setDateMs(this: JsValue, ms: i64) void {
        if (!this.isObject()) return;
        const obj = this.asJsObject();
        if (obj.obj_type != .date) return;
        obj.data = .{ .date_ms = ms };
    }

    fn getMsRemainder(ms: i64) u32 {
        const r = @rem(ms, 1000);
        return @intCast(if (r < 0) r + 1000 else r);
    }

    // ── Date constructor + static ───────────────────────────────────

    fn nativeDateConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const obj = try vm.allocator.create(JsObject);
        obj.* = .{ .obj_type = .date, .data = .{ .date_ms = 0 }, .prototype = vm.date_proto };
        try vm.objects.append(vm.allocator, obj);
        if (args.len == 0) {
            obj.data = .{ .date_ms = std.time.milliTimestamp() };
        } else if (args.len == 1) {
            if (args[0].isNumber()) {
                obj.data = .{ .date_ms = @intFromFloat(args[0].asNumber()) };
            } else if (args[0].isInt()) {
                obj.data = .{ .date_ms = args[0].asInt() };
            } else if (args[0].isString()) {
                const str = vm.pool.get(args[0].asStringId()) orelse "";
                obj.data = .{ .date_ms = parseDateString(str) };
            }
        } else {
            // new Date(y, m, d?, h?, min?, s?, ms?)
            var tm: ctime.struct_tm = std.mem.zeroes(ctime.struct_tm);
            tm.tm_year = @as(c_int, @intFromFloat(args[0].toNumber())) - 1900;
            tm.tm_mon = if (args.len > 1) @intFromFloat(args[1].toNumber()) else 0;
            tm.tm_mday = if (args.len > 2) @intFromFloat(args[2].toNumber()) else 1;
            tm.tm_hour = if (args.len > 3) @intFromFloat(args[3].toNumber()) else 0;
            tm.tm_min = if (args.len > 4) @intFromFloat(args[4].toNumber()) else 0;
            tm.tm_sec = if (args.len > 5) @intFromFloat(args[5].toNumber()) else 0;
            tm.tm_isdst = -1;
            const secs = ctime.mktime(&tm);
            const extra_ms: i64 = if (args.len > 6) @intFromFloat(args[6].toNumber()) else 0;
            obj.data = .{ .date_ms = @as(i64, secs) * 1000 + extra_ms };
        }
        return JsValue.initObject(obj);
    }

    fn nativeDateNow(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initNumber(@floatFromInt(std.time.milliTimestamp()));
    }

    fn nativeDateParse(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0 or !args[0].isString()) return JsValue.nan_val;
        const vm = vmFromCtx(ctx);
        const s = vm.pool.get(args[0].asStringId()) orelse return JsValue.nan_val;
        const ms = parseDateString(s);
        if (ms == std.math.minInt(i64)) return JsValue.nan_val;
        return JsValue.initNumber(@floatFromInt(ms));
    }

    fn nativeDateUTC(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len < 2) return JsValue.nan_val;
        var tm: ctime.struct_tm = std.mem.zeroes(ctime.struct_tm);
        tm.tm_year = @as(c_int, @intFromFloat(args[0].toNumber())) - 1900;
        tm.tm_mon = @intFromFloat(args[1].toNumber());
        tm.tm_mday = if (args.len > 2) @intFromFloat(args[2].toNumber()) else 1;
        tm.tm_hour = if (args.len > 3) @intFromFloat(args[3].toNumber()) else 0;
        tm.tm_min = if (args.len > 4) @intFromFloat(args[4].toNumber()) else 0;
        tm.tm_sec = if (args.len > 5) @intFromFloat(args[5].toNumber()) else 0;
        // Use timegm for UTC
        const secs = timegm(&tm);
        const extra_ms: i64 = if (args.len > 6) @intFromFloat(args[6].toNumber()) else 0;
        return JsValue.initNumber(@floatFromInt(@as(i64, secs) * 1000 + extra_ms));
    }

    fn timegm(tm_ptr: *ctime.struct_tm) ctime.time_t {
        // POSIX timegm — available on Linux/macOS
        return ctime.timegm(tm_ptr);
    }

    // ── Date parsing ────────────────────────────────────────────────

    fn parseDateString(s: []const u8) i64 {
        if (parseISO8601(s)) |ms| return ms;
        if (parseRFC2822(s)) |ms| return ms;
        return std.math.minInt(i64); // invalid
    }

    fn parseISO8601(s: []const u8) ?i64 {
        if (s.len < 10) return null;
        const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
        if (s[4] != '-') return null;
        const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
        if (s[7] != '-') return null;
        const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
        var hour: u8 = 0;
        var min: u8 = 0;
        var sec: u8 = 0;
        var ms: i64 = 0;
        var tz_offset_min: i32 = 0;
        var is_utc = false;
        var pos: usize = 10;
        if (pos < s.len and s[pos] == 'T') {
            pos += 1;
            if (pos + 2 <= s.len) { hour = std.fmt.parseInt(u8, s[pos..][0..2], 10) catch return null; pos += 2; }
            if (pos < s.len and s[pos] == ':') pos += 1;
            if (pos + 2 <= s.len) { min = std.fmt.parseInt(u8, s[pos..][0..2], 10) catch return null; pos += 2; }
            if (pos < s.len and s[pos] == ':') pos += 1;
            if (pos + 2 <= s.len) { sec = std.fmt.parseInt(u8, s[pos..][0..2], 10) catch return null; pos += 2; }
            if (pos < s.len and s[pos] == '.') {
                pos += 1;
                var frac: i64 = 0;
                var digits: u32 = 0;
                while (pos < s.len and s[pos] >= '0' and s[pos] <= '9') : (pos += 1) {
                    frac = frac * 10 + (s[pos] - '0');
                    digits += 1;
                }
                // Normalize to milliseconds
                while (digits < 3) : (digits += 1) frac *= 10;
                while (digits > 3) : (digits -= 1) frac = @divTrunc(frac, 10);
                ms = frac;
            }
            if (pos < s.len) {
                if (s[pos] == 'Z') { is_utc = true; } else if (s[pos] == '+' or s[pos] == '-') {
                    const sign: i32 = if (s[pos] == '+') 1 else -1;
                    pos += 1;
                    if (pos + 2 <= s.len) {
                        const tz_h = std.fmt.parseInt(i32, s[pos..][0..2], 10) catch return null;
                        pos += 2;
                        if (pos < s.len and s[pos] == ':') pos += 1;
                        var tz_m: i32 = 0;
                        if (pos + 2 <= s.len) {
                            tz_m = std.fmt.parseInt(i32, s[pos..][0..2], 10) catch 0;
                        }
                        tz_offset_min = sign * (tz_h * 60 + tz_m);
                    }
                }
            }
        } else {
            is_utc = true; // date-only forms are UTC per spec
        }
        var tm: ctime.struct_tm = std.mem.zeroes(ctime.struct_tm);
        tm.tm_year = year - 1900;
        tm.tm_mon = @as(c_int, @intCast(month)) - 1;
        tm.tm_mday = day;
        tm.tm_hour = hour;
        tm.tm_min = min;
        tm.tm_sec = sec;
        if (is_utc) {
            const secs = timegm(&tm);
            return @as(i64, secs) * 1000 + ms;
        } else if (tz_offset_min != 0) {
            const secs = timegm(&tm);
            return @as(i64, secs) * 1000 + ms - @as(i64, tz_offset_min) * 60000;
        } else {
            tm.tm_isdst = -1;
            const secs = ctime.mktime(&tm);
            return @as(i64, secs) * 1000 + ms;
        }
    }

    fn parseRFC2822(s: []const u8) ?i64 {
        // Look for month names
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var month_idx: ?usize = null;
        var month_pos: usize = 0;
        for (months, 0..) |m, i| {
            if (std.mem.indexOf(u8, s, m)) |p| {
                month_idx = i;
                month_pos = p;
                break;
            }
        }
        if (month_idx == null) return null;
        // Extract day before month name
        var day: u8 = 0;
        if (month_pos >= 2) {
            const before = std.mem.trimRight(u8, std.mem.trimLeft(u8, s[0..month_pos], " ,"), " ,");
            // Try last number token
            var it = std.mem.splitBackwardsAny(u8, before, " ,");
            if (it.next()) |tok| {
                day = std.fmt.parseInt(u8, tok, 10) catch 0;
            }
        }
        // Extract year after month name
        var year: i32 = 0;
        var pos = month_pos + 3;
        while (pos < s.len and (s[pos] == ' ' or s[pos] == ',')) pos += 1;
        // Next might be day or year
        if (day == 0 and pos < s.len) {
            const end = std.mem.indexOfAnyPos(u8, s, pos, " ,") orelse s.len;
            day = std.fmt.parseInt(u8, s[pos..end], 10) catch 0;
            pos = end;
            while (pos < s.len and (s[pos] == ' ' or s[pos] == ',')) pos += 1;
        }
        if (pos < s.len) {
            const end = std.mem.indexOfAnyPos(u8, s, pos, " ,") orelse s.len;
            year = std.fmt.parseInt(i32, s[pos..end], 10) catch 0;
            pos = end;
        }
        if (year == 0 or day == 0) return null;
        // Try to find time HH:MM:SS
        var hour: u8 = 0;
        var min: u8 = 0;
        var sec: u8 = 0;
        if (std.mem.indexOf(u8, s[pos..], ":")) |colon_off| {
            const time_start = pos + colon_off - 2;
            if (time_start + 8 <= s.len) {
                hour = std.fmt.parseInt(u8, s[time_start..][0..2], 10) catch 0;
                min = std.fmt.parseInt(u8, s[time_start + 3 ..][0..2], 10) catch 0;
                sec = std.fmt.parseInt(u8, s[time_start + 6 ..][0..2], 10) catch 0;
            }
        }
        var tm: ctime.struct_tm = std.mem.zeroes(ctime.struct_tm);
        tm.tm_year = year - 1900;
        tm.tm_mon = @intCast(month_idx.?);
        tm.tm_mday = day;
        tm.tm_hour = hour;
        tm.tm_min = min;
        tm.tm_sec = sec;
        // Check for GMT/UTC
        if (std.mem.indexOf(u8, s, "GMT") != null or std.mem.indexOf(u8, s, "UTC") != null) {
            return @as(i64, timegm(&tm)) * 1000;
        }
        tm.tm_isdst = -1;
        return @as(i64, ctime.mktime(&tm)) * 1000;
    }

    // ── Date getters (local) ────────────────────────────────────────

    fn nativeDateGetTime(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initNumber(@floatFromInt(getDateMs(this) orelse return JsValue.nan_val));
    }
    fn nativeDateGetFullYear(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(@as(i32, tm.tm_year) + 1900));
    }
    fn nativeDateGetMonth(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_mon));
    }
    fn nativeDateGetDate(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_mday));
    }
    fn nativeDateGetDay(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_wday));
    }
    fn nativeDateGetHours(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_hour));
    }
    fn nativeDateGetMinutes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_min));
    }
    fn nativeDateGetSeconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToLocalTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_sec));
    }
    fn nativeDateGetMilliseconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const ms = getDateMs(this) orelse return JsValue.nan_val;
        return JsValue.initNumber(@floatFromInt(getMsRemainder(ms)));
    }
    fn nativeDateGetTimezoneOffset(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const ms = getDateMs(this) orelse return JsValue.nan_val;
        const local = msToLocalTm(ms);
        // tm_gmtoff is seconds east of UTC (POSIX extension, available on Linux/macOS)
        return JsValue.initNumber(@floatFromInt(@divTrunc(-@as(i64, local.tm_gmtoff), 60)));
    }

    // ── Date getters (UTC) ──────────────────────────────────────────

    fn nativeDateGetUTCFullYear(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(@as(i32, tm.tm_year) + 1900));
    }
    fn nativeDateGetUTCMonth(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_mon));
    }
    fn nativeDateGetUTCDate(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_mday));
    }
    fn nativeDateGetUTCDay(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_wday));
    }
    fn nativeDateGetUTCHours(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_hour));
    }
    fn nativeDateGetUTCMinutes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_min));
    }
    fn nativeDateGetUTCSeconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const tm = msToUtcTm(getDateMs(this) orelse return JsValue.nan_val);
        return JsValue.initNumber(@floatFromInt(tm.tm_sec));
    }
    fn nativeDateGetUTCMilliseconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const ms = getDateMs(this) orelse return JsValue.nan_val;
        return JsValue.initNumber(@floatFromInt(getMsRemainder(ms)));
    }

    // ── Date setters (local) ────────────────────────────────────────

    fn nativeDateSetTime(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const ms: i64 = @intFromFloat(args[0].toNumber());
        setDateMs(this, ms);
        return JsValue.initNumber(@floatFromInt(ms));
    }
    fn nativeDateSetFullYear(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_year = @as(c_int, @intFromFloat(args[0].toNumber())) - 1900;
        if (args.len > 1) tm.tm_mon = @intFromFloat(args[1].toNumber());
        if (args.len > 2) tm.tm_mday = @intFromFloat(args[2].toNumber());
        const new_ms = tmToLocalMs(&tm, orig);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetMonth(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_mon = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_mday = @intFromFloat(args[1].toNumber());
        const new_ms = tmToLocalMs(&tm, orig);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetDate(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_mday = @intFromFloat(args[0].toNumber());
        const new_ms = tmToLocalMs(&tm, orig);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetHours(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_hour = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_min = @intFromFloat(args[1].toNumber());
        if (args.len > 2) tm.tm_sec = @intFromFloat(args[2].toNumber());
        var new_ms = tmToLocalMs(&tm, orig);
        if (args.len > 3) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[3].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetMinutes(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_min = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_sec = @intFromFloat(args[1].toNumber());
        var new_ms = tmToLocalMs(&tm, orig);
        if (args.len > 2) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[2].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetSeconds(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToLocalTm(orig);
        tm.tm_sec = @intFromFloat(args[0].toNumber());
        var new_ms = tmToLocalMs(&tm, orig);
        if (args.len > 1) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[1].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetMilliseconds(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        const new_ms = orig - @rem(orig, 1000) + @as(i64, @intFromFloat(args[0].toNumber()));
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }

    // ── Date setters (UTC) ──────────────────────────────────────────

    fn nativeDateSetUTCFullYear(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_year = @as(c_int, @intFromFloat(args[0].toNumber())) - 1900;
        if (args.len > 1) tm.tm_mon = @intFromFloat(args[1].toNumber());
        if (args.len > 2) tm.tm_mday = @intFromFloat(args[2].toNumber());
        const new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCMonth(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_mon = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_mday = @intFromFloat(args[1].toNumber());
        const new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCDate(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_mday = @intFromFloat(args[0].toNumber());
        const new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCHours(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_hour = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_min = @intFromFloat(args[1].toNumber());
        if (args.len > 2) tm.tm_sec = @intFromFloat(args[2].toNumber());
        var new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        if (args.len > 3) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[3].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCMinutes(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_min = @intFromFloat(args[0].toNumber());
        if (args.len > 1) tm.tm_sec = @intFromFloat(args[1].toNumber());
        var new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        if (args.len > 2) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[2].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCSeconds(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        var tm = msToUtcTm(orig);
        tm.tm_sec = @intFromFloat(args[0].toNumber());
        var new_ms = @as(i64, timegm(&tm)) * 1000 + @rem(orig, 1000);
        if (args.len > 1) { new_ms = new_ms - @rem(new_ms, 1000) + @as(i64, @intFromFloat(args[1].toNumber())); }
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }
    fn nativeDateSetUTCMilliseconds(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.nan_val;
        const orig = getDateMs(this) orelse return JsValue.nan_val;
        const new_ms = orig - @rem(orig, 1000) + @as(i64, @intFromFloat(args[0].toNumber()));
        setDateMs(this, new_ms);
        return JsValue.initNumber(@floatFromInt(new_ms));
    }

    // ── Date conversion methods ─────────────────────────────────────

    fn nativeDateToISOString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.undefined_val;
        const tm = msToUtcTm(ms);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            @as(i32, tm.tm_year) + 1900,
            @as(u32, @intCast(tm.tm_mon)) + 1,
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
            getMsRemainder(ms),
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateValueOf(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initNumber(@floatFromInt(getDateMs(this) orelse return JsValue.nan_val));
    }

    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    fn fmtTzOffset(buf: []u8, offset_sec: i64) []const u8 {
        const offset_min = @divTrunc(offset_sec, 60);
        const sign: u8 = if (offset_min >= 0) '+' else '-';
        const abs_min: u64 = @intCast(@abs(offset_min));
        const h: u32 = @intCast(@divTrunc(abs_min, 60));
        const m: u32 = @intCast(@rem(abs_min, 60));
        return std.fmt.bufPrint(buf, "{c}{d:0>2}{d:0>2}", .{ sign, h, m }) catch "+0000";
    }

    fn nativeDateToString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        const wday: usize = @intCast(tm.tm_wday);
        const mon: usize = @intCast(tm.tm_mon);
        var tz_buf: [8]u8 = undefined;
        const tz_str = fmtTzOffset(&tz_buf, tm.tm_gmtoff);
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT{s}", .{
            day_names[wday], month_names[mon],
            @as(u32, @intCast(tm.tm_mday)), @as(i32, tm.tm_year) + 1900,
            @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)),
            tz_str,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToDateString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        const wday: usize = @intCast(tm.tm_wday);
        const mon: usize = @intCast(tm.tm_mon);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {d}", .{
            day_names[wday], month_names[mon], @as(u32, @intCast(tm.tm_mday)), @as(i32, tm.tm_year) + 1900,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToTimeString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        var tz_buf: [8]u8 = undefined;
        const tz_str = fmtTzOffset(&tz_buf, tm.tm_gmtoff);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} GMT{s}", .{
            @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)),
            tz_str,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToUTCString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToUtcTm(ms);
        const wday: usize = @intCast(tm.tm_wday);
        const mon: usize = @intCast(tm.tm_mon);
        var buf: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            day_names[wday], @as(u32, @intCast(tm.tm_mday)), month_names[mon],
            @as(i32, tm.tm_year) + 1900,
            @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)),
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToLocaleDateString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}/{d}/{d}", .{
            @as(u32, @intCast(tm.tm_mon)) + 1, @as(u32, @intCast(tm.tm_mday)), @as(i32, tm.tm_year) + 1900,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToLocaleTimeString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        const h = @as(u32, @intCast(tm.tm_hour));
        const ampm: []const u8 = if (h < 12) "AM" else "PM";
        const h12 = if (h == 0) 12 else if (h > 12) h - 12 else h;
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}:{d:0>2}:{d:0>2} {s}", .{
            h12, @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)), ampm,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeDateToLocaleString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const ms = getDateMs(this) orelse return JsValue.initString(try vm.pool.intern("Invalid Date"));
        const tm = msToLocalTm(ms);
        const h = @as(u32, @intCast(tm.tm_hour));
        const ampm: []const u8 = if (h < 12) "AM" else "PM";
        const h12 = if (h == 0) 12 else if (h > 12) h - 12 else h;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}/{d}/{d}, {d}:{d:0>2}:{d:0>2} {s}", .{
            @as(u32, @intCast(tm.tm_mon)) + 1, @as(u32, @intCast(tm.tm_mday)), @as(i32, tm.tm_year) + 1900,
            h12, @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)), ampm,
        }) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    // ── Number methods ────────────────────────────────────────────

    fn nativeNumberToFixed(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const n = this.toNumber();
        const digits: usize = if (args.len > 0) blk: {
            const d = args[0].toNumber();
            if (std.math.isNan(d) or d < 0) break :blk 0;
            if (d > 100) break :blk 100;
            break :blk @intFromFloat(d);
        } else 0;
        var buf: [320]u8 = undefined;
        // Format: integer part, then '.', then decimal digits
        // Use a simple approach: multiply, round, format
        if (std.math.isNan(n)) return JsValue.initString(try vm.pool.intern("NaN"));
        if (std.math.isInf(n)) return JsValue.initString(try vm.pool.intern(if (n > 0) "Infinity" else "-Infinity"));
        const factor = std.math.pow(f64, 10.0, @floatFromInt(digits));
        const rounded = @round(n * factor) / factor;
        if (digits == 0) {
            const i: i64 = @intFromFloat(rounded);
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return JsValue.undefined_val;
            return JsValue.initString(try vm.pool.intern(s));
        }
        // Format with decimal point
        const negative = rounded < 0;
        const abs_val = @abs(rounded);
        const int_part: u64 = @intFromFloat(abs_val);
        const frac_val = abs_val - @as(f64, @floatFromInt(int_part));
        const frac_scaled: u64 = @intFromFloat(@round(frac_val * factor));
        var result_buf = std.ArrayListUnmanaged(u8){};
        defer result_buf.deinit(vm.allocator);
        if (negative) try result_buf.append(vm.allocator, '-');
        const int_str = std.fmt.bufPrint(&buf, "{d}", .{int_part}) catch return JsValue.undefined_val;
        try result_buf.appendSlice(vm.allocator, int_str);
        try result_buf.append(vm.allocator, '.');
        // Pad fractional part with leading zeros
        const frac_str = std.fmt.bufPrint(&buf, "{d}", .{frac_scaled}) catch return JsValue.undefined_val;
        var pad: usize = 0;
        while (pad + frac_str.len < digits) : (pad += 1) {
            try result_buf.append(vm.allocator, '0');
        }
        try result_buf.appendSlice(vm.allocator, frac_str);
        return JsValue.initString(try vm.pool.intern(result_buf.items));
    }

    fn nativeNumberToString(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const n = this.toNumber();
        if (std.math.isNan(n)) return JsValue.initString(try vm.pool.intern("NaN"));
        if (std.math.isInf(n)) return JsValue.initString(try vm.pool.intern(if (n > 0) "Infinity" else "-Infinity"));
        const radix: u8 = if (args.len > 0) blk: {
            const r = args[0].toNumber();
            if (std.math.isNan(r) or r < 2 or r > 36) break :blk 10;
            break :blk @intFromFloat(r);
        } else 10;
        if (radix == 10) {
            var buf: [64]u8 = undefined;
            const s = formatValue(vm.pool, this, &buf);
            return JsValue.initString(try vm.pool.intern(s));
        }
        // Integer radix conversion
        const int_val: i64 = @intFromFloat(n);
        var buf: [65]u8 = undefined;
        var pos: usize = buf.len;
        const negative = int_val < 0;
        var val: u64 = if (negative) @intCast(-int_val) else @intCast(int_val);
        const digits_chars = "0123456789abcdefghijklmnopqrstuvwxyz";
        if (val == 0) {
            pos -= 1;
            buf[pos] = '0';
        } else {
            while (val > 0) {
                pos -= 1;
                buf[pos] = digits_chars[@intCast(val % radix)];
                val /= radix;
            }
        }
        if (negative) {
            pos -= 1;
            buf[pos] = '-';
        }
        return JsValue.initString(try vm.pool.intern(buf[pos..]));
    }

    fn nativeNumberToPrecision(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const n = this.toNumber();
        if (std.math.isNan(n)) return JsValue.initString(try vm.pool.intern("NaN"));
        if (std.math.isInf(n)) return JsValue.initString(try vm.pool.intern(if (n > 0) "Infinity" else "-Infinity"));
        if (args.len == 0) {
            var buf: [64]u8 = undefined;
            const s = formatValue(vm.pool, this, &buf);
            return JsValue.initString(try vm.pool.intern(s));
        }
        const prec: usize = blk: {
            const p = args[0].toNumber();
            if (std.math.isNan(p) or p < 1) break :blk 1;
            if (p > 100) break :blk 100;
            break :blk @intFromFloat(p);
        };
        // Simple implementation using exponential notation conversion
        var buf: [320]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{e}", .{n}) catch return JsValue.undefined_val;
        _ = prec;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeNumberToExponential(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const n = this.toNumber();
        if (std.math.isNan(n)) return JsValue.initString(try vm.pool.intern("NaN"));
        if (std.math.isInf(n)) return JsValue.initString(try vm.pool.intern(if (n > 0) "Infinity" else "-Infinity"));
        _ = args;
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{e}", .{n}) catch return JsValue.undefined_val;
        return JsValue.initString(try vm.pool.intern(s));
    }

    fn nativeNumberValueOf(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        return JsValue.initNumber(this.toNumber());
    }

    fn nativeNumberIsNaN(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(false);
        const v = args[0];
        // Check for the JS NaN value (TAG_NAN) or a float NaN
        if (v.bits == JsValue.nan_val.bits) return JsValue.initBool(true);
        if (v.isNumber()) return JsValue.initBool(std.math.isNan(v.asNumber()));
        return JsValue.initBool(false);
    }

    fn nativeNumberIsFinite(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(false);
        const v = args[0];
        if (v.isNumber()) return JsValue.initBool(std.math.isFinite(v.asNumber()));
        if (v.isInt()) return JsValue.initBool(true);
        return JsValue.initBool(false);
    }

    fn nativeNumberIsInteger(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        if (args.len == 0) return JsValue.initBool(false);
        const v = args[0];
        if (v.isInt()) return JsValue.initBool(true);
        if (v.isNumber()) {
            const n = v.asNumber();
            if (std.math.isNan(n) or std.math.isInf(n)) return JsValue.initBool(false);
            return JsValue.initBool(@floor(n) == n);
        }
        return JsValue.initBool(false);
    }

    // ── Error methods ───────────────────────────────────────────────

    fn nativeErrorConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const err_obj = try vm.createObj(.{});
        // Prototype is set by construct opcode when called with `new`.
        // When called without `new`, we default to Error.prototype.
        if (vm.error_proto) |ep| {
            err_obj.prototype = ep;
        }
        const msg_sid = try vm.pool.intern("message");
        if (args.len > 0 and args[0].isString()) {
            try err_obj.setProperty(vm.allocator, msg_sid, args[0]);
        } else if (args.len > 0) {
            var buf: [64]u8 = undefined;
            const s = formatValue(vm.pool, args[0], &buf);
            try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern(s)));
        } else {
            try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern("")));
        }
        return JsValue.initObject(err_obj);
    }

    // ── Iterator support ──────────────────────────────────────────────

    fn resolveIterator(self: *VM, iterable: JsValue) !?JsValue {
        if (iterable.isObject()) {
            const obj = iterable.asJsObject();
            if (obj.obj_type == .generator or obj.obj_type == .async_generator) return iterable;
            if (self.findSymbolProp(obj, SYMBOL_ITERATOR)) |iter_fn| {
                return try self.callJsFunction(iter_fn, iterable, &.{});
            }
            if (obj.obj_type == .array) {
                return JsValue.initObject(try self.createArrayIterator(iterable));
            }
        }
        if (iterable.isString()) {
            return JsValue.initObject(try self.createStringIterator(iterable));
        }
        return null;
    }

    fn findSymbolProp(_: *VM, obj: *JsObject, sym_id: u32) ?JsValue {
        var current: ?*JsObject = obj;
        while (current) |cur| {
            if (cur.symbol_props) |sp| {
                if (sp.get(sym_id)) |val| return val;
            }
            current = cur.prototype;
        }
        return null;
    }

    fn createArrayIterator(self: *VM, source: JsValue) !*JsObject {
        const iter = try self.createObj(.{ .obj_type = .iterator });
        iter.data = .{ .iterator_data = .{ .source = source } };
        try self.registerNativeMethod(iter, "next", &nativeArrayIteratorNext);
        return iter;
    }

    fn createStringIterator(self: *VM, source: JsValue) !*JsObject {
        const iter = try self.createObj(.{ .obj_type = .iterator });
        iter.data = .{ .iterator_data = .{ .source = source } };
        try self.registerNativeMethod(iter, "next", &nativeStringIteratorNext);
        return iter;
    }

    fn nativeArrayIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const obj = this.asJsObject();
        if (obj.obj_type != .iterator) return try vm.createIterResult(JsValue.undefined_val, true);
        var data = &obj.data.iterator_data;
        if (!data.source.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const src = data.source.asJsObject();
        if (src.obj_type != .array) return try vm.createIterResult(JsValue.undefined_val, true);
        if (data.index < src.data.array.items.len) {
            const val = src.data.array.items[data.index];
            data.index += 1;
            return try vm.createIterResult(val, false);
        }
        return try vm.createIterResult(JsValue.undefined_val, true);
    }

    fn nativeStringIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const obj = this.asJsObject();
        if (obj.obj_type != .iterator) return try vm.createIterResult(JsValue.undefined_val, true);
        var data = &obj.data.iterator_data;
        if (!data.source.isString()) return try vm.createIterResult(JsValue.undefined_val, true);
        const s = vm.pool.get(data.source.asStringId()) orelse return try vm.createIterResult(JsValue.undefined_val, true);
        if (data.index >= s.len) return try vm.createIterResult(JsValue.undefined_val, true);
        const byte = s[data.index];
        const cp_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(byte) catch 1);
        const end = @min(data.index + cp_len, @as(u32, @intCast(s.len)));
        const char_str = try vm.pool.intern(s[data.index..end]);
        data.index = end;
        return try vm.createIterResult(JsValue.initString(char_str), false);
    }

    fn nativeArraySymbolIterator(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        return JsValue.initObject(try vm.createArrayIterator(this));
    }

    fn callIteratorNext(self: *VM, iterator: JsValue, sent_value: JsValue) !JsValue {
        const next_id = try self.pool.intern("next");
        if (iterator.isObject()) {
            const obj = iterator.asJsObject();
            if (obj.getProperty(next_id)) |next_fn| {
                return try self.callJsFunction(next_fn, iterator, &.{sent_value});
            }
        }
        return try self.createIterResult(JsValue.undefined_val, true);
    }

    fn getIterResultDone(self: *VM, result: JsValue) !bool {
        if (!result.isObject()) return true;
        const done_id = try self.pool.intern("done");
        const done = result.asJsObject().getProperty(done_id) orelse JsValue.initBool(true);
        return done.isTruthy();
    }

    fn getIterResultValue(self: *VM, result: JsValue) !JsValue {
        if (!result.isObject()) return JsValue.undefined_val;
        const value_id = try self.pool.intern("value");
        return result.asJsObject().getProperty(value_id) orelse JsValue.undefined_val;
    }

    fn drainIteratorIntoArray(self: *VM, iterator_val: JsValue, arr: *JsObject) !void {
        const next_id = try self.pool.intern("next");
        const done_id = try self.pool.intern("done");
        const value_id = try self.pool.intern("value");
        var iterations: u32 = 0;
        while (iterations < 10000) : (iterations += 1) {
            if (!iterator_val.isObject()) break;
            const iter_obj = iterator_val.asJsObject();
            const next_fn = iter_obj.getProperty(next_id) orelse break;
            const result = try self.callJsFunction(next_fn, iterator_val, &.{});
            if (!result.isObject()) break;
            const result_obj = result.asJsObject();
            const done = result_obj.getProperty(done_id) orelse JsValue.initBool(true);
            if (done.isTruthy()) break;
            const value = result_obj.getProperty(value_id) orelse JsValue.undefined_val;
            try arr.data.array.append(self.allocator, value);
        }
    }

    // ── Generator support ───────────────────────────────────────────

    fn createGeneratorObject(self: *VM, func_obj: *JsObject) !*JsObject {
        const gen_obj = try self.createObj(.{ .obj_type = .generator });
        gen_obj.data = .{ .generator_data = .{
            .state = .suspended_start,
            .func_obj = func_obj,
        } };
        try self.registerNativeMethod(gen_obj, "next", &nativeGeneratorNext);
        try self.registerNativeMethod(gen_obj, "return", &nativeGeneratorReturn);
        return gen_obj;
    }

    fn createIterResult(self: *VM, value: JsValue, done: bool) !JsValue {
        const obj = try self.createObj(.{});
        const value_id = try self.pool.intern("value");
        const done_id = try self.pool.intern("done");
        try obj.setProperty(self.allocator, value_id, value);
        try obj.setProperty(self.allocator, done_id, JsValue.initBool(done));
        return JsValue.initObject(obj);
    }

    fn nativeGeneratorNext(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;

        // yield* delegation active
        if (gen.delegate_iterator) |delegate| {
            const sent = if (args.len > 0) args[0] else JsValue.undefined_val;
            const result = try vm.callIteratorNext(delegate, sent);
            const done = try vm.getIterResultDone(result);
            if (done) {
                gen.delegate_iterator = null;
                // Resume generator with inner return value as yield* expression result
                gen.state = .executing;
                const final_value = try vm.getIterResultValue(result);
                return try vm.executeGenerator(gen, final_value, true);
            } else {
                const value = try vm.getIterResultValue(result);
                return try vm.createIterResult(value, false);
            }
        }

        switch (gen.state) {
            .completed => {
                return try vm.createIterResult(JsValue.undefined_val, true);
            },
            .executing, .await_pending => {
                return JsValue.undefined_val;
            },
            .suspended_start => {
                gen.state = .executing;
                return try vm.executeGenerator(gen, JsValue.undefined_val, false);
            },
            .suspended_yield => {
                gen.state = .executing;
                const sent_value = if (args.len > 0) args[0] else JsValue.undefined_val;
                return try vm.executeGenerator(gen, sent_value, true);
            },
        }
    }

    fn nativeGeneratorReturn(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;
        gen.state = .completed;
        const value = if (args.len > 0) args[0] else JsValue.undefined_val;
        return try vm.createIterResult(value, true);
    }

    fn executeGenerator(self: *VM, gen: *object_mod.GeneratorData, sent_value: JsValue, is_resume: bool) !JsValue {
        const func_obj = gen.func_obj;
        const func = &func_obj.data.function;
        const target_frame = self.frame_count;

        if (is_resume) {
            // Resuming from yield: restore saved stack
            // Push function slot
            self.push(JsValue.initObject(func_obj));
            const frame_base = self.sp;
            // Restore saved locals + temporaries
            for (gen.saved_stack) |val| {
                self.push(val);
            }

            const uv_array = self.getClosureUpvalues(func_obj);
            self.frames[self.frame_count] = .{
                .bc = &func.bytecode,
                .ip = gen.saved_ip,
                .base_sp = frame_base,
                .upvalues = uv_array,
                .this_val = gen.this_val,
            };
            self.frame_count += 1;

            // Push sent_value as the result of the yield expression
            self.push(sent_value);

            // Set active generator so yield_value handler can save state
            const prev_gen = self.active_generator;
            self.active_generator = gen;
            defer self.active_generator = prev_gen;

            const result = self.run(target_frame) catch |err| {
                gen.state = .completed;
                return err;
            };

            // If run returned normally (return statement), generator is done
            if (gen.state == .executing) {
                gen.state = .completed;
                return try self.createIterResult(result, true);
            }
            // If yield_value was hit, it already returned the result
            return result;
        } else {
            // First call (suspended_start): start from beginning
            self.push(JsValue.initObject(func_obj)); // function slot
            const base = self.sp;

            // Push saved initial args as params
            for (gen.init_args) |arg| {
                self.push(arg);
            }
            // Pad missing params
            while (self.sp - base < func.param_count) {
                self.push(JsValue.undefined_val);
            }
            // Reserve extra local slots beyond params
            const extra_locals = if (func.local_count > func.param_count)
                func.local_count - func.param_count
            else
                0;
            var j: u16 = 0;
            while (j < extra_locals) : (j += 1) {
                self.push(JsValue.undefined_val);
            }

            const uv_array = self.getClosureUpvalues(func_obj);
            self.frames[self.frame_count] = .{
                .bc = &func.bytecode,
                .ip = 0,
                .base_sp = base,
                .upvalues = uv_array,
                .this_val = gen.this_val,
            };
            self.frame_count += 1;

            const prev_gen = self.active_generator;
            self.active_generator = gen;
            defer self.active_generator = prev_gen;

            const result = self.run(target_frame) catch |err| {
                gen.state = .completed;
                return err;
            };

            if (gen.state == .executing) {
                gen.state = .completed;
                return try self.createIterResult(result, true);
            }
            return result;
        }
    }

    // ── Async Generator support ──────────────────────────────────────

    fn createAsyncGeneratorObject(self: *VM, func_obj: *JsObject) !*JsObject {
        const gen_obj = try self.createObj(.{ .obj_type = .async_generator });
        gen_obj.data = .{ .generator_data = .{
            .state = .suspended_start,
            .func_obj = func_obj,
        } };
        try self.registerNativeMethod(gen_obj, "next", &nativeAsyncGeneratorNext);
        try self.registerNativeMethod(gen_obj, "return", &nativeAsyncGeneratorReturn);
        return gen_obj;
    }

    fn nativeAsyncGeneratorNext(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .async_generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;

        const result = switch (gen.state) {
            .completed => try vm.createIterResult(JsValue.undefined_val, true),
            .executing, .await_pending => return JsValue.undefined_val,
            .suspended_start => blk: {
                gen.state = .executing;
                break :blk try vm.executeGenerator(gen, JsValue.undefined_val, false);
            },
            .suspended_yield => blk: {
                gen.state = .executing;
                const sent = if (args.len > 0) args[0] else JsValue.undefined_val;
                break :blk try vm.executeGenerator(gen, sent, true);
            },
        };

        // Wrap in resolved Promise
        return try vm.createResolvedPromise(result);
    }

    fn nativeAsyncGeneratorReturn(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .async_generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;
        gen.state = .completed;
        const value = if (args.len > 0) args[0] else JsValue.undefined_val;
        const result = try vm.createIterResult(value, true);
        return try vm.createResolvedPromise(result);
    }

    fn createResolvedPromise(self: *VM, value: JsValue) !JsValue {
        const promise = try self.createObj(.{ .obj_type = .promise });
        promise.data = .{ .promise_data = .{
            .state = .fulfilled,
            .result = value,
        } };
        if (self.promise_proto) |pp| promise.prototype = pp;
        return JsValue.initObject(promise);
    }

    // ── WeakMap / WeakSet native functions ───────────────────────────

    fn nativeWeakMapConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const obj = try vm.createObj(.{ .obj_type = .weak_map });
        obj.data = .{ .weak_map_data = .{} };
        try vm.registerNativeMethod(obj, "set", &nativeWeakMapSet);
        try vm.registerNativeMethod(obj, "get", &nativeWeakMapGet);
        try vm.registerNativeMethod(obj, "has", &nativeWeakMapHas);
        try vm.registerNativeMethod(obj, "delete", &nativeWeakMapDelete);
        return JsValue.initObject(obj);
    }

    fn nativeWeakMapSet(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject() or args.len < 2) return this;
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_map) return this;
        if (!args[0].isObject()) return error.TypeError;
        const key = @intFromPtr(args[0].asObject());
        try obj.data.weak_map_data.put(vm.allocator, key, args[1]);
        return this;
    }

    fn nativeWeakMapGet(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_map) return JsValue.undefined_val;
        if (!args[0].isObject()) return JsValue.undefined_val;
        const key = @intFromPtr(args[0].asObject());
        if (obj.data.weak_map_data.get(key)) |val| return val;
        return JsValue.undefined_val;
    }

    fn nativeWeakMapHas(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_map) return JsValue.initBool(false);
        if (!args[0].isObject()) return JsValue.initBool(false);
        const key = @intFromPtr(args[0].asObject());
        return JsValue.initBool(obj.data.weak_map_data.contains(key));
    }

    fn nativeWeakMapDelete(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_map) return JsValue.initBool(false);
        if (!args[0].isObject()) return JsValue.initBool(false);
        const key = @intFromPtr(args[0].asObject());
        return JsValue.initBool(obj.data.weak_map_data.orderedRemove(key));
    }

    fn nativeWeakSetConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const obj = try vm.createObj(.{ .obj_type = .weak_set });
        obj.data = .{ .weak_set_data = .{} };
        try vm.registerNativeMethod(obj, "add", &nativeWeakSetAdd);
        try vm.registerNativeMethod(obj, "has", &nativeWeakSetHas);
        try vm.registerNativeMethod(obj, "delete", &nativeWeakSetDelete);
        return JsValue.initObject(obj);
    }

    fn nativeWeakSetAdd(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject() or args.len == 0) return this;
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_set) return this;
        if (!args[0].isObject()) return error.TypeError;
        const key = @intFromPtr(args[0].asObject());
        try obj.data.weak_set_data.put(vm.allocator, key, {});
        return this;
    }

    fn nativeWeakSetHas(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_set) return JsValue.initBool(false);
        if (!args[0].isObject()) return JsValue.initBool(false);
        const key = @intFromPtr(args[0].asObject());
        return JsValue.initBool(obj.data.weak_set_data.contains(key));
    }

    fn nativeWeakSetDelete(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        if (!this.isObject() or args.len == 0) return JsValue.initBool(false);
        const obj = this.asJsObject();
        if (obj.obj_type != .weak_set) return JsValue.initBool(false);
        if (!args[0].isObject()) return JsValue.initBool(false);
        const key = @intFromPtr(args[0].asObject());
        return JsValue.initBool(obj.data.weak_set_data.orderedRemove(key));
    }

    // ── Symbol native functions ──────────────────────────────────────

    fn nativeSymbolConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        const id = vm.next_symbol_id;
        vm.next_symbol_id += 1;
        var desc: ?StringId = null;
        if (args.len > 0 and args[0].isString()) {
            desc = args[0].asStringId();
        }
        try vm.symbol_descriptions.put(vm.allocator, id, desc);
        return JsValue.initSymbol(id);
    }

    fn nativeSymbolFor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len == 0 or !args[0].isString()) return JsValue.undefined_val;
        const key_str = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
        // Check if already in global registry
        for (vm.symbol_descriptions.keys(), vm.symbol_descriptions.values()) |sym_id, desc| {
            if (desc) |d| {
                if (vm.pool.get(d)) |s| {
                    if (std.mem.eql(u8, s, key_str)) {
                        return JsValue.initSymbol(sym_id);
                    }
                }
            }
        }
        // Create new symbol in registry
        const id = vm.next_symbol_id;
        vm.next_symbol_id += 1;
        try vm.symbol_descriptions.put(vm.allocator, id, args[0].asStringId());
        return JsValue.initSymbol(id);
    }

    fn nativeSymbolKeyFor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (args.len == 0 or !args[0].isSymbol()) return JsValue.undefined_val;
        const sym_id = args[0].asSymbolId();
        if (vm.symbol_descriptions.get(sym_id)) |desc| {
            if (desc) |d| {
                return JsValue.initString(d);
            }
        }
        return JsValue.undefined_val;
    }

    fn nativeErrorToString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        const name_sid = try vm.pool.intern("name");
        const msg_sid = try vm.pool.intern("message");
        const name_val = obj.getProperty(name_sid) orelse JsValue.initString(try vm.pool.intern("Error"));
        const msg_val = obj.getProperty(msg_sid) orelse JsValue.initString(try vm.pool.intern(""));
        const name_str = if (name_val.isString()) vm.pool.get(name_val.asStringId()) orelse "Error" else "Error";
        const msg_str = if (msg_val.isString()) vm.pool.get(msg_val.asStringId()) orelse "" else "";
        if (msg_str.len == 0) {
            return JsValue.initString(try vm.pool.intern(name_str));
        }
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(vm.allocator);
        try buf.appendSlice(vm.allocator, name_str);
        try buf.appendSlice(vm.allocator, ": ");
        try buf.appendSlice(vm.allocator, msg_str);
        return JsValue.initString(try vm.pool.intern(buf.items));
    }
};
