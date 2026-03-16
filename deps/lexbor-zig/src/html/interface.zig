pub const html = @import("../html_ext.zig");

pub inline fn element(obj: anytype) *html.lxb_html_element_t {
    return html.lxb_html_interface_element(obj);
}

pub inline fn template(obj: anytype) *html.lxb_html_template_element_t {
    return html.lxb_html_interface_template(obj);
}
