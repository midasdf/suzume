const core = @import("../core_ext.zig");

pub const Entry = core.lexbor_bst_map_entry_t;
pub const BstMap = core.lexbor_bst_map_t;

pub fn create() ?*core.lexbor_bst_map_t {
    return core.lexbor_bst_map_create();
}

pub fn init(bst_map: ?*core.lexbor_bst_map_t, size: usize) core.lexbor_status_t {
    const status = core.lexbor_bst_map_init(bst_map, size);
    return @enumFromInt(status);
}

pub fn clean(bst_map: ?*core.lexbor_bst_map_t) void {
    core.lexbor_bst_map_clean(bst_map);
}

pub fn destroy(bst_map: ?*core.lexbor_bst_map_t, self_destroy: bool) ?*core.lexbor_bst_map_t {
    return core.lexbor_bst_map_destroy(bst_map, self_destroy);
}

pub fn search(bst_map: ?*core.lexbor_bst_map_t, scope: ?*core.lexbor_bst_entry_t, key: []const u8, key_len: usize) ?*core.lexbor_bst_map_entry_t {
    return core.lexbor_bst_map_search(bst_map, scope, @ptrCast(key.ptr), key_len);
}

pub fn insert(bst_map: ?*core.lexbor_bst_map_t, scope: ?*?*core.lexbor_bst_entry_t, key: []const u8, key_len: usize, value: ?*anyopaque) ?*core.lexbor_bst_map_entry_t {
    return core.lexbor_bst_map_insert(bst_map, scope, @ptrCast(key.ptr), key_len, value);
}

pub fn insertNotExists(bst_map: ?*core.lexbor_bst_map_t, scope: ?*?*core.lexbor_bst_entry_t, key: []const u8, key_len: usize) ?*core.lexbor_bst_map_entry_t {
    return core.lexbor_bst_map_insert_not_exists(bst_map, scope, @ptrCast(key.ptr), key_len);
}

pub fn remove(bst_map: ?*core.lexbor_bst_map_t, scope: ?*?*core.lexbor_bst_entry_t, key: []const u8, key_len: usize) ?*anyopaque {
    return core.lexbor_bst_map_remove(bst_map, scope, @ptrCast(key.ptr), key_len);
}

pub inline fn mraw(bst_map: ?*core.lexbor_bst_map_t) ?*core.lexbor_mraw_t {
    return core.lexbor_bst_map_mraw(bst_map);
}

pub fn mrawNoi(bst_map: ?*core.lexbor_bst_map_t) ?*core.lexbor_mraw_t {
    return core.lexbor_bst_map_mraw_noi(bst_map);
}
