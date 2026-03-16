const core = @import("../core_ext.zig");

pub const ArrayObj = core.lexbor_array_obj_t;

pub fn create() ?*core.lexbor_array_obj_t {
    return core.lexbor_array_obj_create();
}

pub fn init(array: ?*core.lexbor_array_obj_t, size_: usize, struct_size: usize) core.lexbor_status_t {
    const status = core.lexbor_array_obj_init(array, size_, struct_size);
    return @enumFromInt(status);
}

pub fn clean(array: ?*core.lexbor_array_obj_t) void {
    core.lexbor_array_obj_clean(array);
}

pub fn destroy(array: ?*core.lexbor_array_obj_t, self_destroy: bool) ?*core.lexbor_array_obj_t {
    return core.lexbor_array_obj_destroy(array, self_destroy);
}

pub fn expand(array: ?*core.lexbor_array_obj_t, up_to: usize) ?*u8 {
    return core.lexbor_array_obj_expand(array, up_to);
}

pub fn push(array: ?*core.lexbor_array_obj_t) ?*anyopaque {
    return core.lexbor_array_obj_push(array);
}

pub fn pushWoCls(array: ?*core.lexbor_array_obj_t) ?*anyopaque {
    return core.lexbor_array_obj_push_wo_cls(array);
}

pub fn pushN(array: ?*core.lexbor_array_obj_t, count: usize) ?*anyopaque {
    return core.lexbor_array_obj_push_n(array, count);
}

pub fn pop(array: ?*core.lexbor_array_obj_t) ?*anyopaque {
    return core.lexbor_array_obj_pop(array);
}

pub fn delete(array: ?*core.lexbor_array_obj_t, begin: usize, length_: usize) void {
    core.lexbor_array_obj_delete(array, begin, length_);
}

pub inline fn erase(array: ?*core.lexbor_array_obj_t) void {
    core.lexbor_array_obj_erase(array);
}

pub inline fn get(array: ?*core.lexbor_array_obj_t, idx: usize) ?*anyopaque {
    return core.lexbor_array_obj_get(array, idx);
}

pub inline fn length(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_length(array);
}

pub inline fn size(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_size(array);
}

pub inline fn structSize(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_struct_size(array);
}

pub inline fn last(array: ?*core.lexbor_array_obj_t) ?*anyopaque {
    return core.lexbor_array_obj_last(array);
}

pub fn eraseNoi(array: ?*core.lexbor_array_obj_t) void {
    core.lexbor_array_obj_erase_noi(array);
}

pub fn getNoi(array: ?*core.lexbor_array_obj_t, idx: usize) ?*anyopaque {
    return core.lexbor_array_obj_get_noi(array, idx);
}

pub fn lengthNoi(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_length_noi(array);
}

pub fn sizeNoi(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_size_noi(array);
}

pub fn structSizeNoi(array: ?*core.lexbor_array_obj_t) usize {
    return core.lexbor_array_obj_struct_size_noi(array);
}

pub fn lastNoi(array: ?*core.lexbor_array_obj_t) ?*anyopaque {
    return core.lexbor_array_obj_last_noi(array);
}
