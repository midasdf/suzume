const core = @import("../core_ext.zig");

pub const Dobject = core.lexbor_dobject_t;

pub fn create() ?*core.lexbor_dobject_t {
    return core.lexbor_dobject_create();
}

pub fn init(dobject: ?*core.lexbor_dobject_t, chunk_size: usize, struct_size: usize) core.lexbor_status_t {
    const status = core.lexbor_dobject_init(dobject, chunk_size, struct_size);
    return @enumFromInt(status);
}

pub fn clean(dobject: ?*core.lexbor_dobject_t) void {
    core.lexbor_dobject_clean(dobject);
}

pub fn destroy(dobject: ?*core.lexbor_dobject_t, destroy_self: bool) ?*core.lexbor_dobject_t {
    return core.lexbor_dobject_destroy(dobject, destroy_self);
}

pub fn initList_entries(dobject: ?*core.lexbor_dobject_t, pos: usize) ?*u8 {
    return core.lexbor_dobject_init_list_entries(dobject, pos);
}

pub fn alloc(dobject: ?*core.lexbor_dobject_t) ?*anyopaque {
    return core.lexbor_dobject_alloc(dobject);
}

pub fn calloc(dobject: ?*core.lexbor_dobject_t) ?*anyopaque {
    return core.lexbor_dobject_calloc(dobject);
}

pub fn free(dobject: ?*core.lexbor_dobject_t, data: ?*anyopaque) ?*anyopaque {
    return core.lexbor_dobject_free(dobject, data);
}

pub fn byAbsolutePosition(dobject: ?*core.lexbor_dobject_t, pos: usize) ?*anyopaque {
    return core.lexbor_dobject_by_absolute_position(dobject, pos);
}

pub inline fn allocated(dobject: ?*core.lexbor_dobject_t) usize {
    return core.lexbor_dobject_allocated(dobject);
}

pub inline fn cacheLength(dobject: ?*core.lexbor_dobject_t) usize {
    return core.lexbor_dobject_cache_length(dobject);
}

pub fn allocatedNoi(dobject: ?*core.lexbor_dobject_t) usize {
    return core.lexbor_dobject_allocated_noi(dobject);
}

pub fn cacheLengthNoi(dobject: ?*core.lexbor_dobject_t) usize {
    return core.lexbor_dobject_cache_length_noi(dobject);
}
