pub const dom = @import("../dom_ext.zig");

pub const Collection = dom.lxb_dom_collection_t;

pub fn make(document: ?*dom.lxb_dom_document_t, start_list_size: usize) ?*dom.lxb_dom_collection_t {
    return dom.lxb_dom_collection_make(document, start_list_size);
}

pub fn length(col: ?*dom.lxb_dom_collection_t) usize {
    return dom.lxb_dom_collection_length(col);
}

pub fn element(col: ?*dom.lxb_dom_collection_t, idx: usize) ?*dom.lxb_dom_element_t {
    return dom.lxb_dom_collection_element(col, idx);
}

pub fn destroy(col: ?*dom.lxb_dom_collection_t, self_destroy: bool) ?*dom.lxb_dom_collection_t {
    return dom.lxb_dom_collection_destroy(col, self_destroy);
}

pub fn clean(col: ?*dom.lxb_dom_collection_t) void {
    dom.lxb_dom_collection_clean(col);
}
