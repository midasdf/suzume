// Heap-allocated JS objects: ordinary objects, functions, upvalue cells.

const std = @import("std");
const value_mod = @import("value.zig");
const string_pool = @import("string_pool.zig");
const bytecode_mod = @import("bytecode.zig");

const JsValue = value_mod.JsValue;
const StringId = string_pool.StringId;
const Bytecode = bytecode_mod.Bytecode;

pub const ObjType = enum(u8) {
    ordinary,
    function,
    array,
    native_function,
    dom_node,
    dom_style,
    window_proxy,
    map,
    set,
    regexp,
};

pub const JsObject = struct {
    obj_type: ObjType = .ordinary,
    properties: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    prototype: ?*JsObject = null,
    data: ObjData = .none,

    pub const NativeFn = *const fn (ctx: *anyopaque, this: value_mod.JsValue, args: []const value_mod.JsValue) anyerror!value_mod.JsValue;

    pub const RegExpData = struct {
        source: string_pool.StringId, // pattern source
        global: bool = false,
        ignore_case: bool = false,
        multiline: bool = false,
    };

    pub const MapEntry = struct {
        key: value_mod.JsValue,
        val: value_mod.JsValue,
    };

    pub const ObjData = union(enum) {
        none,
        function: FunctionObj,
        array: std.ArrayListUnmanaged(value_mod.JsValue),
        native_fn: NativeFn,
        dom_node: *anyopaque,
        dom_style: *anyopaque,
        map_data: std.ArrayListUnmanaged(MapEntry),
        set_data: std.ArrayListUnmanaged(value_mod.JsValue),
        regexp_data: RegExpData,
    };

    pub fn deinit(self: *JsObject, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        switch (self.data) {
            .function => |*f| f.deinit(allocator),
            .array => |*a| a.deinit(allocator),
            .map_data => |*m| m.deinit(allocator),
            .set_data => |*s| s.deinit(allocator),
            .none, .native_fn, .dom_node, .dom_style, .regexp_data => {},
        }
    }

    pub fn getProperty(self: *const JsObject, name: StringId) ?JsValue {
        if (self.properties.get(name)) |v| return v;
        if (self.prototype) |proto| return proto.getProperty(name);
        return null;
    }

    pub fn setProperty(self: *JsObject, allocator: std.mem.Allocator, name: StringId, val: JsValue) !void {
        try self.properties.put(allocator, name, val);
    }
};

pub const FunctionObj = struct {
    bytecode: Bytecode,
    param_count: u16 = 0,
    local_count: u16 = 0,
    name: ?StringId = null,
    upvalue_count: u16 = 0,
    upvalue_defs: []UpvalueDef = &.{},
    owns_bytecode: bool = true,

    pub fn deinit(self: *FunctionObj, allocator: std.mem.Allocator) void {
        if (self.owns_bytecode) {
            self.bytecode.deinit(allocator);
            if (self.upvalue_defs.len > 0) allocator.free(self.upvalue_defs);
        }
    }
};

/// Describes how to capture one upvalue when creating a closure.
pub const UpvalueDef = struct {
    index: u16,
    is_local: bool, // true = capture parent's local, false = capture parent's upvalue
};

/// A heap-allocated cell for a captured variable.
/// Open: `value` is kept in sync with the stack slot.
/// Closed: `value` holds the variable after the stack frame is gone.
pub const UpvalueCell = struct {
    value: JsValue = JsValue.undefined_val,
    is_open: bool = true,
    stack_index: u32 = 0, // which stack slot this tracks (while open)
};
