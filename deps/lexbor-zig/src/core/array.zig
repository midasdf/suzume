const core = @import("../core_ext.zig");

pub const Array = core.lexbor_array_t;

pub fn create() ?*core.lexbor_array_t {
    return core.lexbor_array_create();
}

pub fn init(array: ?*core.lexbor_array_t, size_: usize) core.lexbor_status_t {
    const status = core.lexbor_array_init(array, size_);
    return @enumFromInt(status);
}

pub fn clean(array: ?*core.lexbor_array_t) void {
    core.lexbor_array_clean(array);
}

pub fn destroy(array: ?*core.lexbor_array_t, self_destroy: bool) ?*core.lexbor_array_t {
    return core.lexbor_array_destroy(array, self_destroy);
}

pub fn expand(array: ?*core.lexbor_array_t, up_to: usize) ?*?*anyopaque {
    return core.lexbor_array_expand(array, up_to);
}

pub fn push(array: ?*core.lexbor_array_t, value: ?*anyopaque) core.lexbor_status_t {
    const status = core.lexbor_array_push(array, value);
    return @enumFromInt(status);
}

pub fn pop(array: ?*core.lexbor_array_t) ?*anyopaque {
    return core.lexbor_array_pop(array);
}

pub fn insert(array: ?*core.lexbor_array_t, idx: usize, value: ?*anyopaque) core.lexbor_status_t {
    const status = core.lexbor_array_insert(array, idx, value);
    return @enumFromInt(status);
}

pub fn set(array: ?*core.lexbor_array_t, idx: usize, value: ?*anyopaque) core.lexbor_status_t {
    const status = core.lexbor_array_set(array, idx, value);
    return @enumFromInt(status);
}

pub fn delete(array: ?*core.lexbor_array_t, begin: usize, length_: usize) void {
    return core.lexbor_array_delete(array, begin, length_);
}

pub inline fn get(array: ?*core.lexbor_array_t, idx: usize) ?*anyopaque {
    return core.lexbor_array_get(array, idx);
}

pub inline fn length(array: ?*core.lexbor_array_t) usize {
    return core.lexbor_array_length(array);
}

pub inline fn size(array: ?*core.lexbor_array_t) usize {
    return core.lexbor_array_size(array);
}

pub fn getNoi(array: ?*core.lexbor_array_t, idx: usize) ?*anyopaque {
    return core.lexbor_array_get_noi(array, idx);
}

pub fn lengthNoi(array: ?*core.lexbor_array_t) usize {
    return core.lexbor_array_length_noi(array);
}

pub fn sizeNoi(array: ?*core.lexbor_array_t) usize {
    return core.lexbor_array_size_noi(array);
}
