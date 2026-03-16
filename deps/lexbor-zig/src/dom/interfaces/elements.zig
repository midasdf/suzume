pub const core = @import("../../core_ext.zig");
pub const dom = @import("../../dom_ext.zig");

pub fn byTagName(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, qualified_name: []const u8, len: usize) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_tag_name(root, collection, @ptrCast(qualified_name.ptr), len);
}

pub fn byClassName(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, class_name: []const u8, len: usize) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_class_name(root, collection, @ptrCast(class_name.ptr), len);
}

pub fn byAttr(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, qualified_name: []const u8, qname_len: usize, value: []const u8, value_len: usize, case_insensitive: bool) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_attr(root, collection, @ptrCast(qualified_name.ptr), qname_len, @ptrCast(value.ptr), value_len, case_insensitive);
}

pub fn byAttrBegin(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, qualified_name: []const u8, qname_len: usize, value: []const u8, value_len: usize, case_insensitive: bool) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_attr_begin(root, collection, @ptrCast(qualified_name.ptr), qname_len, @ptrCast(value.ptr), value_len, case_insensitive);
}

pub fn byAttrEnd(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, qualified_name: []const u8, qname_len: usize, value: []const u8, value_len: usize, case_insensitive: bool) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_attr_end(root, collection, @ptrCast(qualified_name.ptr), qname_len, @ptrCast(value.ptr), value_len, case_insensitive);
}

pub fn byAttrContain(root: ?*dom.lxb_dom_element_t, collection: ?*dom.lxb_dom_collection_t, qualified_name: []const u8, qname_len: usize, value: []const u8, value_len: usize, case_insensitive: bool) core.lexbor_status_t {
    return dom.lxb_dom_elements_by_attr_contain(root, collection, @ptrCast(qualified_name.ptr), qname_len, @ptrCast(value.ptr), value_len, case_insensitive);
}
