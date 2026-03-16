const std = @import("std");
const span = std.mem.span;

pub const core = @import("../core_ext.zig");
pub const html = @import("../html_ext.zig");

pub fn create(dobj: ?*core.lexbor_dobject_t) ?*html.lxb_html_token_attr_t {
    return html.lxb_html_token_attr_create(dobj);
}

pub fn clean(attr: ?*html.lxb_html_token_attr_t) void {
    html.lxb_html_token_attr_clean(attr);
}

pub fn destroy(attr: ?*html.lxb_html_token_attr_t, dobj: ?*core.lexbor_dobject_t) ?*html.lxb_html_token_attr_t {
    return html.lxb_html_token_attr_destroy(attr, dobj);
}

pub fn name(attr: ?*html.lxb_html_token_attr_t, length: ?*usize) ?[]const u8 {
    const name_ = html.lxb_html_token_attr_name(attr, length) orelse return null;
    return span(name_);
}
