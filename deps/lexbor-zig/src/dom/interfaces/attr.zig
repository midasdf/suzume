const std = @import("std");
const span = std.mem.span;

pub const core = @import("../../core_ext.zig");
pub const dom = @import("../../dom_ext.zig");

pub const Attr = dom.lxb_dom_attr_t;

pub fn qualifiedName(attr: ?*dom.lxb_dom_attr_t, len: ?*usize) ?[]const u8 {
    const qn = dom.lxb_dom_attr_qualified_name(attr, len) orelse return null;
    return span(qn);
}

pub fn value(attr: ?*dom.lxb_dom_attr_t, len: ?*usize) ?[]const u8 {
    const value_ = dom.lxb_dom_attr_value(attr, len) orelse return null;
    return span(value_);
}

pub fn setValue(attr: ?*dom.lxb_dom_attr_t, value_: []const u8, value_len: usize) core.lexbor_status_t {
    const status = dom.lxb_dom_attr_set_value(attr, @ptrCast(value_.ptr), value_len);
    return @enumFromInt(status);
}
