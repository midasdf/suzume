const core = @import("../core_ext.zig");

pub const Avl = core.lexbor_avl_t;
pub const Node = core.lexbor_avl_node_t;

pub const NodeF = core.lexbor_avl_node_f;

pub fn create() ?*core.lexbor_avl_t {
    return core.lexbor_avl_create();
}

pub fn init(avl: ?*core.lexbor_avl_t, chunk_len: usize, struct_size: usize) core.lexbor_status_t {
    const status = core.lexbor_avl_init(avl, chunk_len, struct_size);
    return @enumFromInt(status);
}

pub fn clean(avl: ?*core.lexbor_avl_t) void {
    core.lexbor_avl_clean(avl);
}

pub fn destroy(avl: ?*core.lexbor_avl_t, struct_destroy: bool) ?*core.lexbor_avl_t {
    return core.lexbor_avl_destroy(avl, struct_destroy);
}

pub fn nodeMake(avl: ?*core.lexbor_avl_t, type_: usize, value: ?*anyopaque) ?*core.lexbor_avl_node_t {
    return core.lexbor_avl_node_make(avl, type_, value);
}

pub fn nodeClean(node: ?*core.lexbor_avl_node_t) void {
    core.lexbor_avl_node_clean(node);
}

pub fn nodeDestroy(avl: ?*core.lexbor_avl_t, node: ?*core.lexbor_avl_node_t, self_destroy: bool) ?*core.lexbor_avl_node_t {
    return core.lexbor_avl_node_destroy(avl, node, self_destroy);
}

pub fn insert(avl: ?*core.lexbor_avl_t, scope: ?*?*core.lexbor_avl_node_t, type_: usize, value: ?*anyopaque) ?*core.lexbor_avl_node_t {
    return core.lexbor_avl_insert(avl, scope, type_, value);
}

pub fn search(avl: ?*core.lexbor_avl_t, scope: ?*core.lexbor_avl_node_t, type_: usize) ?*core.lexbor_avl_node_t {
    return core.lexbor_avl_search(avl, scope, type_);
}

pub fn remove(avl: ?*core.lexbor_avl_t, scope: ?*?*core.lexbor_avl_node_t, type_: usize) ?*anyopaque {
    return core.lexbor_avl_remove(avl, scope, type_);
}

pub fn removeByNode(avl: ?*core.lexbor_avl_t, root: ?*?*core.lexbor_avl_node_t, node: ?*core.lexbor_avl_node_t) void {
    return core.lexbor_avl_remove_by_node(avl, root, node);
}

pub fn foreach(avl: ?*core.lexbor_avl_t, scope: ?*?*core.lexbor_avl_node_t, cb: core.lexbor_avl_node_f, ctx: ?*anyopaque) core.lexbor_status_t {
    const status = core.lexbor_avl_foreach(avl, scope, cb, ctx);
    return @enumFromInt(status);
}

pub fn foreachRecursion(avl: ?*core.lexbor_avl_t, scope: ?*core.lexbor_avl_node_t, callback: core.lexbor_avl_node_f, ctx: ?*anyopaque) void {
    core.lexbor_avl_foreach_recursion(avl, scope, callback, ctx);
}
