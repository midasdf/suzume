/// Unified Lexbor extern declarations for all JS DOM modules.
/// This module centralizes extern function declarations that were previously
/// duplicated across dom_api.zig, dom_element.zig, dom_node.zig, dom_document.zig,
/// and dom_selector.zig.
const lxb = @import("../bindings/lexbor.zig").c;

// ── Node operations ────────────────────────────────────────────────────
pub extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
pub extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
pub extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
pub extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
pub extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
pub extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
pub extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
pub extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;

// ── Element operations ─────────────────────────────────────────────────
pub extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;
pub extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
pub extern fn lxb_dom_element_remove_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) lxb.lxb_status_t;
pub extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
pub extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_element_first_attribute_noi(element: *lxb.lxb_dom_element_t) ?*anyopaque;
pub extern fn lxb_dom_element_next_attribute_noi(attr: *anyopaque) ?*anyopaque;

// ── Attribute access ───────────────────────────────────────────────────
pub extern fn lxb_dom_attr_qualified_name(attr: *anyopaque, len: *usize) ?[*]const u8;
pub extern fn lxb_dom_attr_value_noi(attr: *anyopaque, len: *usize) ?[*]const u8;

// ── Document operations ────────────────────────────────────────────────
pub extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
pub extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
pub extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;

// ── HTML serialization ─────────────────────────────────────────────────
pub const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
pub extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
pub extern fn lxb_html_serialize_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
pub extern fn lxb_html_serialize_deep_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;

// ── HTML fragment parsing ──────────────────────────────────────────────
pub extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;

// ── Helpers ────────────────────────────────────────────────────────────

/// Lowercase an attribute name for HTML elements (DOM spec requirement).
/// Returns a slice into lower_buf if any uppercase chars found, or the original slice.
/// Supports names up to 1024 bytes; longer names are returned as-is (extremely rare).
pub fn lowercaseAttrName(name: []const u8, lower_buf: *[1024]u8) []const u8 {
    var has_upper = false;
    for (name) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            has_upper = true;
            break;
        }
    }
    if (!has_upper) return name;
    if (name.len > lower_buf.len) return name; // Return as-is rather than silently truncating
    for (0..name.len) |i| {
        lower_buf[i] = if (name[i] >= 'A' and name[i] <= 'Z') name[i] + 32 else name[i];
    }
    return lower_buf[0..name.len];
}
