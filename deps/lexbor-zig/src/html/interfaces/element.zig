pub const html = @import("../../html_ext.zig");

pub fn innerHtmlSet(element: ?*html.lxb_html_element_t, html_: []const u8, size: usize) ?*html.lxb_html_element_t {
    return html.lxb_html_element_inner_html_set(element, @ptrCast(html_.ptr), size);
}
