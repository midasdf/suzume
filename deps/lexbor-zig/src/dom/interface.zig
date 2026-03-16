pub const dom = @import("../dom_ext.zig");

pub inline fn node(obj: anytype) ?*dom.lxb_dom_node_t {
    return dom.lxb_dom_interface_node(obj);
}

pub inline fn element(obj: anytype) ?*dom.lxb_dom_element_t {
    return dom.lxb_dom_interface_element(obj);
}
