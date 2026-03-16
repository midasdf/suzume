pub const dom = @import("../../dom_ext.zig");

pub const Node = dom.lxb_dom_node_t;
pub const Type = dom.lxb_dom_node_type_t;

pub fn insertChild(to: ?*dom.lxb_dom_node_t, node: ?*dom.lxb_dom_node_t) void {
    dom.lxb_dom_node_insert_child(to, node);
}
