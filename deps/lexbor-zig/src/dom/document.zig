pub const dom = @import("../dom_ext.zig");

pub fn createElement(dom_document: *dom.lxb_dom_document, local_name: []const u8, lname_len: usize, reserved_for_opt: ?*anyopaque) ?*dom.lxb_dom_element_t {
    return dom.lxb_dom_document_create_element(dom_document, @ptrCast(local_name.ptr), lname_len, reserved_for_opt);
}

pub fn createTextNode(dom_document: *dom.lxb_dom_document, data: []const u8, len: usize) ?*dom.lxb_dom_text_t {
    return dom.lxb_dom_document_create_text_node(dom_document, @ptrCast(data.ptr), len);
}
