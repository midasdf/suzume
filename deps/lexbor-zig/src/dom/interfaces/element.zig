const std = @import("std");
const span = std.mem.span;

pub const core = @import("../../core_ext.zig");
pub const dom = @import("../../dom_ext.zig");

pub const Element = dom.lxb_dom_element_t;

pub fn setAttribute(element: ?*dom.lxb_dom_element_t, qualified_name: []const u8, qn_len: usize, value: []const u8, value_len: usize) ?*dom.lxb_dom_attr_t {
    return dom.lxb_dom_element_set_attribute(element, @ptrCast(qualified_name.ptr), qn_len, @ptrCast(value.ptr), value_len);
}

pub fn hasAttribute(element: ?*dom.lxb_dom_element_t, qualified_name: []const u8, qn_len: usize) bool {
    return dom.lxb_dom_element_has_attribute(element, @ptrCast(qualified_name.ptr), qn_len);
}

pub fn getAttribute(element: ?*dom.lxb_dom_element_t, qualified_name: []const u8, qn_len: usize, value_len: ?*usize) ?[]const u8 {
    const attr = dom.lxb_dom_element_get_attribute(element, @ptrCast(qualified_name.ptr), qn_len, value_len) orelse return null;
    return span(attr);
}

pub fn firstAttribute(element: ?*dom.lxb_dom_element_t) ?*dom.lxb_dom_attr_t {
    return dom.lxb_dom_element_first_attribute(element);
}

pub fn prevAttribute(attr: ?*dom.lxb_dom_attr_t) ?*dom.lxb_dom_attr_t {
    return dom.lxb_dom_element_prev_attribute(attr);
}

pub fn nextAttribute(attr: ?*dom.lxb_dom_attr_t) ?*dom.lxb_dom_attr_t {
    return dom.lxb_dom_element_next_attribute(attr);
}

pub fn attrByName(element: ?*dom.lxb_dom_element_t, qualified_name: []const u8, length: usize) ?*dom.lxb_dom_attr_t {
    return dom.lxb_dom_element_attr_by_name(element, @ptrCast(qualified_name.ptr), length);
}

pub fn removeAttribute(element: ?*dom.lxb_dom_element_t, qualified_name: []const u8, qn_len: usize) core.lxb_status_t {
    return dom.lxb_dom_element_remove_attribute(element, @ptrCast(qualified_name.ptr), qn_len);
}

pub fn qualifiedName(element: ?*dom.lxb_dom_element_t, len: ?*usize) ?[]const u8 {
    const qn = dom.lxb_dom_element_qualified_name(element, len) orelse return null;
    return span(qn);
}
