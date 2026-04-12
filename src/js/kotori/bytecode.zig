// Bytecode definitions for the kotori JS engine.
// OpCode enum defines all VM instructions.
// Bytecode struct is a builder for emitting bytecode sequences.

const std = @import("std");
const value = @import("value.zig");
pub const JsValue = value.JsValue;

pub const OpCode = enum(u8) {
    // Stack
    load_const,
    pop,
    dup,
    swap,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    power,

    // Comparison
    eq,
    ne,
    strict_eq,
    strict_ne,
    lt,
    le,
    gt,
    ge,

    // Logical / bitwise
    not,
    bit_not,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,
    instanceof_,
    in_,

    // Variables
    load_local,
    store_local,
    load_global,
    store_global,
    load_upvalue,
    store_upvalue,

    // Control flow
    jump,
    jump_if_false,
    jump_if_true,

    // Functions
    new_function, // operand: u16 constant index → FunctionObj
    call, // operand: u16 arg count
    return_,
    return_undefined,
    close_upvalue, // operand: u16 stack slot to close

    // Objects
    new_object, // operand: u16 property count
    get_prop, // operand: u16 constant index → StringId
    set_prop, // operand: u16 constant index → StringId
    get_elem, // stack: [obj, key] → [value]
    set_elem, // stack: [obj, key, value] → [value]

    // Arrays
    new_array, // operand: u16 element count
    array_push, // stack: [array, value] → [array] — append value to array

    // This / method calls / constructor
    load_this,
    call_method, // operand: u16 arg count (stack: [this, func, args...])
    construct, // operand: u16 arg count (stack: [func, args...])

    // RegExp
    new_regexp, // operand: u16 const index for pattern, next u16 for flags

    // Iteration
    get_length, // stack: [obj] → [number] — get .length property
    get_keys, // stack: [obj] → [array] — get Object.keys()

    // Exception handling
    try_begin, // operand: i16 offset to catch handler
    try_end,
    throw_,

    // Async / Promise
    await_, // stack: [value] → [resolved_value] (suspends if pending)
    async_return, // stack: [value] → resolve async function's promise, return

    // Modules
    import_binding, // operand: u16 const index (module specifier), next u16 const index (binding name)
    export_binding, // operand: u16 const index (exported name)
    export_default, // stack: [value] → [] — register default export

    // Special
    typeof_,
    void_,
    halt,
};

pub const Bytecode = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(JsValue),
    local_count: u16,
    param_count: u16,
    max_stack: u16,

    pub fn init() Bytecode {
        return .{
            .code = .{},
            .constants = .{},
            .local_count = 0,
            .param_count = 0,
            .max_stack = 0,
        };
    }

    pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
    }

    /// Append a single opcode byte.
    pub fn emit(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode) !void {
        try self.code.append(allocator, @intFromEnum(op));
    }

    /// Append opcode followed by a u16 operand in little-endian order.
    pub fn emitWithU16(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode, operand: u16) !void {
        try self.code.append(allocator, @intFromEnum(op));
        try self.code.append(allocator, @intCast(operand & 0xFF));
        try self.code.append(allocator, @intCast((operand >> 8) & 0xFF));
    }

    /// Append opcode followed by an i16 operand in little-endian order.
    pub fn emitWithI16(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode, operand: i16) !void {
        const u: u16 = @bitCast(operand);
        try self.emitWithU16(allocator, op, u);
    }

    /// Add a value to the constant pool and return its index.
    pub fn addConstant(self: *Bytecode, allocator: std.mem.Allocator, val: JsValue) !u16 {
        const index: u16 = @intCast(self.constants.items.len);
        try self.constants.append(allocator, val);
        return index;
    }

    /// Return the current byte offset (length of emitted code).
    pub fn currentOffset(self: *const Bytecode) u32 {
        return @intCast(self.code.items.len);
    }

    /// Emit a jump instruction with a placeholder offset (0x0000).
    /// Returns the byte position of the placeholder so it can be patched later.
    pub fn emitJump(self: *Bytecode, allocator: std.mem.Allocator, op: OpCode) !u32 {
        try self.code.append(allocator, @intFromEnum(op));
        const patch_pos: u32 = @intCast(self.code.items.len);
        try self.code.append(allocator, 0x00); // placeholder low byte
        try self.code.append(allocator, 0x00); // placeholder high byte
        return patch_pos;
    }

    /// Patch the i16 jump offset at `patch_pos` to reach the current code position.
    /// The offset is relative to the byte immediately after the two operand bytes.
    pub fn patchJump(self: *Bytecode, patch_pos: u32) void {
        self.patchJumpTo(patch_pos, self.currentOffset());
    }

    /// Patch the i16 jump offset at `patch_pos` to reach an arbitrary target position.
    pub fn patchJumpTo(self: *Bytecode, patch_pos: u32, target: u32) void {
        const after_operand: u32 = patch_pos + 2;
        const delta: i16 = @intCast(@as(i32, @intCast(target)) - @as(i32, @intCast(after_operand)));
        const u: u16 = @bitCast(delta);
        self.code.items[patch_pos] = @intCast(u & 0xFF);
        self.code.items[patch_pos + 1] = @intCast((u >> 8) & 0xFF);
    }
};
