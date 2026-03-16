const core = @import("../core_ext.zig");

pub inline fn root(bst: ?*core.lexbor_bst_t) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_root(bst);
}

pub inline fn rootRef(bst: ?*core.lexbor_bst_t) ?*?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_root_ref(bst);
}

pub const Entry = core.lexbor_bst_entry_t;
pub const Bst = core.lexbor_bst_t;

pub const EntryF = core.lexbor_bst_entry_f;

pub fn create() ?*core.lexbor_bst_t {
    return core.lexbor_bst_create();
}

pub fn init(bst: ?*core.lexbor_bst_t, size: usize) core.lexbor_status_t {
    const status = core.lexbor_bst_init(bst, size);
    return @enumFromInt(status);
}

pub fn clean(bst: ?*core.lexbor_bst_t) void {
    core.lexbor_bst_clean(bst);
}

pub fn destroy(bst: ?*core.lexbor_bst_t, self_destroy: bool) ?*core.lexbor_bst_t {
    return core.lexbor_bst_destroy(bst, self_destroy);
}

pub fn entryMake(bst: ?*core.lexbor_bst_t, size: usize) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_entry_make(bst, size);
}

pub fn insert(bst: ?*core.lexbor_bst_t, scope: ?*?*core.lexbor_bst_entry_t, size: usize, value: ?*anyopaque) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_insert(bst, scope, size, value);
}

pub fn insertNotExists(bst: ?*core.lexbor_bst_t, scope: ?*?*core.lexbor_bst_entry_t, size: usize) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_insert_not_exists(bst, scope, size);
}

pub fn search(bst: ?*core.lexbor_bst_t, scope: ?*core.lexbor_bst_entry_t, size: usize) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_search(bst, scope, size);
}

pub fn searchClose(bst: ?*core.lexbor_bst_t, scope: ?*core.lexbor_bst_entry_t, size: usize) ?*core.lexbor_bst_entry_t {
    return core.lexbor_bst_search_close(bst, scope, size);
}

pub fn remove(bst: ?*core.lexbor_bst_t, root_: ?*?*core.lexbor_bst_entry_t, size: usize) ?*anyopaque {
    return core.lexbor_bst_remove(bst, root_, size);
}

pub fn removeClose(bst: ?*core.lexbor_bst_t, root_: ?*?*core.lexbor_bst_entry_t, size: usize, found_size: ?*usize) ?*anyopaque {
    return core.lexbor_bst_remove_close(bst, root_, size, found_size);
}

pub fn removeByPointer(bst: ?*core.lexbor_bst_t, entry: ?*core.lexbor_bst_entry_t, root_: ?*?*core.lexbor_bst_entry_t) ?*anyopaque {
    return core.lexbor_bst_remove_by_pointer(bst, entry, root_);
}

pub fn serialize(bst: ?*core.lexbor_bst_t, callback: core.lexbor_callback_f, ctx: ?*anyopaque) void {
    core.lexbor_bst_serialize(bst, callback, ctx);
}

pub fn serializeEntry(entry: ?*core.lexbor_bst_entry_t, callback: core.lexbor_callback_f, ctx: ?*anyopaque, tabs: usize) void {
    core.lexbor_bst_serialize_entry(entry, callback, ctx, tabs);
}
