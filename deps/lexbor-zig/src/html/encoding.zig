const std = @import("std");
const span = std.mem.span;

pub const core = @import("../core_ext.zig");
pub const html = @import("../html_ext.zig");
pub const dom = @import("../dom_ext.zig");

pub const Entry = html.lxb_html_encoding_entry_t;
pub const Encoding = html.lxb_html_encoding_t;

pub fn init(em: ?*html.lxb_html_encoding_t) core.lexbor_status_t {
    const status = html.lxb_html_encoding_init(em);
    return @enumFromInt(status);
}

pub fn destroy(em: ?*html.lxb_html_encoding_t, self_destroy: bool) ?*html.lxb_html_encoding_t {
    return html.lxb_html_encoding_destroy(em, self_destroy);
}

pub fn determine(em: ?*html.lxb_html_encoding_t, data: []const u8, end: ?*const core.lxb_char_t) core.lexbor_status_t {
    const status = html.lxb_html_encoding_determine(em, @ptrCast(data.ptr), end);
    return @enumFromInt(status);
}

pub fn content(data: []const u8, end: []const u8, name_end: [][]const u8) ?[]const u8 {
    const content_ = html.lxb_html_encoding_content(@ptrCast(data.ptr), @ptrCast(end.ptr), @ptrCast(name_end.ptr)) orelse return null;
    return span(content_);
}

pub fn metaEntry(em: ?*html.lxb_html_encoding_t, idx: usize) ?*html.lxb_html_encoding_entry_t {
    return html.lxb_html_encoding_meta_entry(em, idx);
}
