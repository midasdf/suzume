const core = @import("../core_ext.zig");

pub const Node = core.lexbor_in_node_t;
pub const OptType = core.lexbor_in_opt_t;

pub const Opt = core.lexbor_in_opt;

pub const In = core.lexbor_in_t;

pub fn create() ?*core.lexbor_in_t {
    return core.lexbor_in_create();
}

pub fn init(incoming: ?*core.lexbor_in_t, chunk_size: usize) core.lexbor_status_t {
    const status = core.lexbor_in_init(incoming, chunk_size);
    return @enumFromInt(status);
}

pub fn clean(incoming: ?*core.lexbor_in_t) void {
    core.lexbor_in_clean(incoming);
}

pub fn destroy(incoming: ?*core.lexbor_in_t, self_destroy: bool) ?*core.lexbor_in_t {
    return core.lexbor_in_destroy(incoming, self_destroy);
}

pub fn nodeMake(incoming: ?*core.lexbor_in_t, last_node: ?*core.lexbor_in_node_t, buf: []const u8, buf_size: usize) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_make(incoming, last_node, @ptrCast(buf.ptr), buf_size);
}

pub fn nodeClean(node: ?*core.lexbor_in_node_t) void {
    core.lexbor_in_node_clean(node);
}

pub fn nodeDestroy(incoming: ?*core.lexbor_in_t, node: ?*core.lexbor_in_node_t, self_destroy: bool) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_destroy(incoming, node, self_destroy);
}

pub fn nodeSplit(node: ?*core.lexbor_in_node_t, pos: []const u8) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_split(node, @ptrCast(pos.ptr));
}

pub fn nodeFind(node: ?*core.lexbor_in_node_t, pos: []const u8) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_find(node, @ptrCast(pos.ptr));
}

pub fn nodePosUp(node: ?*core.lexbor_in_node_t, return_node: ?*?*core.lexbor_in_node_t, pos: []const u8, offset: usize) ?*const core.lxb_char_t {
    return core.lexbor_in_node_pos_up(node, return_node, @ptrCast(pos.ptr), offset);
}

pub fn nodePosDown(node: ?*core.lexbor_in_node_t, return_node: ?*?*core.lexbor_in_node_t, pos: []const u8, offset: usize) ?*const core.lxb_char_t {
    return core.lexbor_in_node_pos_down(node, return_node, @ptrCast(pos.ptr), offset);
}

pub inline fn nodeBegin(node: ?*const core.lexbor_in_node_t) ?[*]const core.lxb_char_t {
    return core.lexbor_in_node_begin(node);
}

pub inline fn nodeEnd(node: ?*const core.lexbor_in_node_t) ?[*]const core.lxb_char_t {
    return core.lexbor_in_node_end(node);
}

pub inline fn nodeOffset(node: ?*const core.lexbor_in_node_t) usize {
    return core.lexbor_in_node_offset(node);
}

pub inline fn nodeNext(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_next(node);
}

pub inline fn nodePrev(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_prev(node);
}

pub inline fn nodeIn(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_t {
    return core.lexbor_in_node_in(node);
}

pub inline fn segment(node: ?*const core.lexbor_in_node_t, data: []const u8) bool {
    return core.lexbor_in_segment(node, @ptrCast(data.ptr));
}

pub fn nodeBeginNoi(node: ?*const core.lexbor_in_node_t) ?*const core.lxb_char_t {
    return core.lexbor_in_node_begin_noi(node);
}

pub fn nodeEndNoi(node: ?*const core.lexbor_in_node_t) ?*const core.lxb_char_t {
    return core.lexbor_in_node_end_noi(node);
}

pub fn nodeOffsetNoi(node: ?*const core.lexbor_in_node_t) usize {
    return core.lexbor_in_node_offset_noi(node);
}

pub fn nodeNextNoi(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_next_noi(node);
}

pub fn nodePrevNoi(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_node_t {
    return core.lexbor_in_node_prev_noi(node);
}

pub fn nodeInNoi(node: ?*const core.lexbor_in_node_t) ?*core.lexbor_in_t {
    return core.lexbor_in_node_in_noi(node);
}

pub fn segmentNoi(node: ?*const core.lexbor_in_node_t, data: []const u8) bool {
    return core.lexbor_in_segment_noi(node, @ptrCast(data.ptr));
}
