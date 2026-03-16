const std = @import("std");
const css = @import("../bindings/css.zig").c;
const lxb = @import("../bindings/lexbor.zig").c;

// ── Helpers ──────────────────────────────────────────────────────────

/// Cast a void* node to lxb_dom_node_t.
inline fn toNode(node: ?*anyopaque) ?*lxb.lxb_dom_node_t {
    const ptr = node orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Get node type (safe for null).
inline fn nodeType(n: *lxb.lxb_dom_node_t) lxb.lxb_dom_node_type_t {
    return n.type;
}

/// Navigation helpers that convert [*c] to ?*.
inline fn nodeParent(n: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    return if (n.parent != null) @ptrCast(n.parent) else null;
}
inline fn nodePrev(n: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    return if (n.prev != null) @ptrCast(n.prev) else null;
}
inline fn nodeNext(n: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    return if (n.next != null) @ptrCast(n.next) else null;
}
inline fn nodeFirstChild(n: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    return if (n.first_child != null) @ptrCast(n.first_child) else null;
}

/// Cast a void* node to lxb_dom_element_t (only valid for element nodes).
inline fn toElement(node: ?*anyopaque) ?*lxb.lxb_dom_element_t {
    const n = toNode(node) orelse return null;
    if (nodeType(n) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    return @ptrCast(n);
}

/// Get the local tag name for an element node (lowercase).
fn getElementLocalName(node: ?*anyopaque) ?[]const u8 {
    const elem = toElement(node) orelse return null;
    var len: usize = 0;
    const ptr = lxb.lxb_dom_element_local_name(elem, &len);
    if (ptr == null or len == 0) return null;
    return ptr[0..len];
}

/// Get the class attribute value for an element.
fn getElementClass(node: ?*anyopaque) ?[]const u8 {
    const elem = toElement(node) orelse return null;
    var len: usize = 0;
    const ptr = lxb.lxb_dom_element_class_noi(elem, &len);
    if (ptr == null or len == 0) return null;
    return ptr[0..len];
}

/// Get the id attribute value for an element.
fn getElementId(node: ?*anyopaque) ?[]const u8 {
    const elem = toElement(node) orelse return null;
    var len: usize = 0;
    const ptr = lxb.lxb_dom_element_id_noi(elem, &len);
    if (ptr == null or len == 0) return null;
    return ptr[0..len];
}

/// Get an attribute value by name.
fn getAttributeValue(node: ?*anyopaque, name: [*c]const u8, name_len: usize) ?[]const u8 {
    const elem = toElement(node) orelse return null;
    var value_len: usize = 0;
    const val = lxb.lxb_dom_element_get_attribute(elem, name, name_len, &value_len);
    if (val == null or value_len == 0) return null;
    return val[0..value_len];
}

/// Get the data and length from an lwc_string.
fn lwcData(str: ?*css.lwc_string) ?[]const u8 {
    const s = str orelse return null;
    // lwc_string_data: (const char *)((str)+1)
    const data_ptr: [*]const u8 = @ptrCast(@as([*]const css.lwc_string, @ptrCast(s)) + 1);
    const len = s.len;
    if (len == 0) return null;
    return data_ptr[0..len];
}

/// Check if a Zig string equals lwc_string content (case-insensitive).
fn strEqCaseless(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Check if a Zig string equals lwc_string content.
fn strEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── Handler Callbacks ────────────────────────────────────────────────

fn handler_node_name(_: ?*anyopaque, node: ?*anyopaque, qname: ?*css.css_qname) callconv(.c) css.css_error {
    const q = qname orelse return css.CSS_BADPARM;
    const name = getElementLocalName(node) orelse {
        q.name = null;
        return css.CSS_OK;
    };
    var interned: ?*css.lwc_string = null;
    const err = css.lwc_intern_string(name.ptr, name.len, &interned);
    if (err != css.lwc_error_ok) return css.CSS_NOMEM;
    q.name = interned;
    q.ns = null;
    return css.CSS_OK;
}

fn handler_node_classes(_: ?*anyopaque, node: ?*anyopaque, classes: ?*?[*]?*css.lwc_string, n_classes: ?*u32) callconv(.c) css.css_error {
    const nc = n_classes orelse return css.CSS_BADPARM;
    const cls = classes orelse return css.CSS_BADPARM;
    nc.* = 0;
    cls.* = null;

    const class_str = getElementClass(node) orelse return css.CSS_OK;

    // Count number of space-separated tokens
    var count: u32 = 0;
    var in_word = false;
    for (class_str) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0C) {
            in_word = false;
        } else {
            if (!in_word) count += 1;
            in_word = true;
        }
    }
    if (count == 0) return css.CSS_OK;

    // Allocate array of lwc_string pointers using C allocator
    const alloc_size = count * @sizeOf(?*css.lwc_string);
    const raw_ptr = std.c.malloc(alloc_size) orelse return css.CSS_NOMEM;
    const arr: [*]?*css.lwc_string = @ptrCast(@alignCast(raw_ptr));

    // Fill array
    var idx: u32 = 0;
    var start: usize = 0;
    var in_word2 = false;
    for (class_str, 0..) |ch, i| {
        const is_ws = (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0C);
        if (is_ws) {
            if (in_word2) {
                var interned: ?*css.lwc_string = null;
                const err = css.lwc_intern_string(class_str.ptr + start, i - start, &interned);
                if (err != css.lwc_error_ok) {
                    // Free already interned strings
                    freeClassArray(arr, idx);
                    return css.CSS_NOMEM;
                }
                arr[idx] = interned;
                idx += 1;
                in_word2 = false;
            }
        } else {
            if (!in_word2) {
                start = i;
                in_word2 = true;
            }
        }
    }
    // Handle last word
    if (in_word2) {
        var interned: ?*css.lwc_string = null;
        const err = css.lwc_intern_string(class_str.ptr + start, class_str.len - start, &interned);
        if (err != css.lwc_error_ok) {
            freeClassArray(arr, idx);
            return css.CSS_NOMEM;
        }
        arr[idx] = interned;
        idx += 1;
    }

    cls.* = arr;
    nc.* = idx;
    return css.CSS_OK;
}

fn freeClassArray(arr: [*]?*css.lwc_string, count: u32) void {
    for (0..count) |i| {
        if (arr[i]) |s| {
            css.lwc_string_destroy(s);
        }
    }
    std.c.free(@ptrCast(arr));
}

fn handler_node_id(_: ?*anyopaque, node: ?*anyopaque, id: ?*?*css.lwc_string) callconv(.c) css.css_error {
    const id_out = id orelse return css.CSS_BADPARM;
    id_out.* = null;
    const id_str = getElementId(node) orelse return css.CSS_OK;
    var interned: ?*css.lwc_string = null;
    const err = css.lwc_intern_string(id_str.ptr, id_str.len, &interned);
    if (err != css.lwc_error_ok) return css.CSS_NOMEM;
    id_out.* = interned;
    return css.CSS_OK;
}

fn handler_named_ancestor_node(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, ancestor: ?*?*anyopaque) callconv(.c) css.css_error {
    const anc = ancestor orelse return css.CSS_BADPARM;
    anc.* = null;
    const q = qname orelse return css.CSS_OK;
    const target = lwcData(q.name) orelse return css.CSS_OK;
    const n = toNode(node) orelse return css.CSS_OK;
    var cur = nodeParent(n);
    while (cur) |p| {
        if (nodeType(p) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const name = getElementLocalName(@ptrCast(p));
            if (name) |nm| {
                if (strEqCaseless(nm, target)) {
                    anc.* = @ptrCast(p);
                    return css.CSS_OK;
                }
            }
        }
        cur = nodeParent(p);
    }
    return css.CSS_OK;
}

fn handler_named_parent_node(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, parent_out: ?*?*anyopaque) callconv(.c) css.css_error {
    const po = parent_out orelse return css.CSS_BADPARM;
    po.* = null;
    const q = qname orelse return css.CSS_OK;
    const target = lwcData(q.name) orelse return css.CSS_OK;
    const n = toNode(node) orelse return css.CSS_OK;
    const p = nodeParent(n) orelse return css.CSS_OK;
    if (nodeType(p) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const name = getElementLocalName(@ptrCast(p));
        if (name) |nm| {
            if (strEqCaseless(nm, target)) {
                po.* = @ptrCast(p);
            }
        }
    }
    return css.CSS_OK;
}

fn handler_named_sibling_node(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, sibling_out: ?*?*anyopaque) callconv(.c) css.css_error {
    const so = sibling_out orelse return css.CSS_BADPARM;
    so.* = null;
    const q = qname orelse return css.CSS_OK;
    const target = lwcData(q.name) orelse return css.CSS_OK;
    const n = toNode(node) orelse return css.CSS_OK;
    var sib = nodePrev(n);
    while (sib) |s| {
        if (nodeType(s) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const name = getElementLocalName(@ptrCast(s));
            if (name) |nm| {
                if (strEqCaseless(nm, target)) {
                    so.* = @ptrCast(s);
                    return css.CSS_OK;
                }
            }
            return css.CSS_OK;
        }
        sib = nodePrev(s);
    }
    return css.CSS_OK;
}

fn handler_named_generic_sibling_node(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, sibling_out: ?*?*anyopaque) callconv(.c) css.css_error {
    const so = sibling_out orelse return css.CSS_BADPARM;
    so.* = null;
    const q = qname orelse return css.CSS_OK;
    const target = lwcData(q.name) orelse return css.CSS_OK;
    const n = toNode(node) orelse return css.CSS_OK;
    var sib = nodePrev(n);
    while (sib) |s| {
        if (nodeType(s) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const name = getElementLocalName(@ptrCast(s));
            if (name) |nm| {
                if (strEqCaseless(nm, target)) {
                    so.* = @ptrCast(s);
                    return css.CSS_OK;
                }
            }
        }
        sib = nodePrev(s);
    }
    return css.CSS_OK;
}

fn handler_parent_node(_: ?*anyopaque, node: ?*anyopaque, parent_out: ?*?*anyopaque) callconv(.c) css.css_error {
    const po = parent_out orelse return css.CSS_BADPARM;
    po.* = null;
    const n = toNode(node) orelse return css.CSS_OK;
    const p = nodeParent(n) orelse return css.CSS_OK;
    if (nodeType(p) == lxb.LXB_DOM_NODE_TYPE_ELEMENT or nodeType(p) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        po.* = @ptrCast(p);
    }
    return css.CSS_OK;
}

fn handler_sibling_node(_: ?*anyopaque, node: ?*anyopaque, sibling_out: ?*?*anyopaque) callconv(.c) css.css_error {
    const so = sibling_out orelse return css.CSS_BADPARM;
    so.* = null;
    const n = toNode(node) orelse return css.CSS_OK;
    var sib = nodePrev(n);
    while (sib) |s| {
        if (nodeType(s) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            so.* = @ptrCast(s);
            return css.CSS_OK;
        }
        sib = nodePrev(s);
    }
    return css.CSS_OK;
}

fn handler_node_has_name(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const target = lwcData(q.name) orelse return css.CSS_OK;
    const name = getElementLocalName(node) orelse return css.CSS_OK;
    m.* = strEqCaseless(name, target);
    return css.CSS_OK;
}

fn handler_node_has_class(_: ?*anyopaque, node: ?*anyopaque, name: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const target = lwcData(name) orelse return css.CSS_OK;
    const class_str = getElementClass(node) orelse return css.CSS_OK;

    // Check each space-separated class token
    var start: usize = 0;
    var in_word = false;
    for (class_str, 0..) |ch, i| {
        const is_ws = (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r');
        if (is_ws) {
            if (in_word) {
                if (strEq(class_str[start..i], target)) {
                    m.* = true;
                    return css.CSS_OK;
                }
                in_word = false;
            }
        } else {
            if (!in_word) {
                start = i;
                in_word = true;
            }
        }
    }
    if (in_word) {
        if (strEq(class_str[start..], target)) {
            m.* = true;
        }
    }
    return css.CSS_OK;
}

fn handler_node_has_id(_: ?*anyopaque, node: ?*anyopaque, name: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const target = lwcData(name) orelse return css.CSS_OK;
    const id_str = getElementId(node) orelse return css.CSS_OK;
    m.* = strEq(id_str, target);
    return css.CSS_OK;
}

fn handler_node_has_attribute(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const elem = toElement(node) orelse return css.CSS_OK;
    m.* = lxb.lxb_dom_element_has_attribute(elem, attr_name.ptr, attr_name.len);
    return css.CSS_OK;
}

fn handler_node_has_attribute_equal(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    m.* = strEq(attr_val, val_str);
    return css.CSS_OK;
}

fn handler_node_has_attribute_dashmatch(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    // [attr|=value]: exact match or starts with value followed by '-'
    if (strEq(attr_val, val_str)) {
        m.* = true;
    } else if (attr_val.len > val_str.len and attr_val[val_str.len] == '-') {
        m.* = strEq(attr_val[0..val_str.len], val_str);
    }
    return css.CSS_OK;
}

fn handler_node_has_attribute_includes(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    // [attr~=value]: space-separated token match
    var it = std.mem.splitScalar(u8, attr_val, ' ');
    while (it.next()) |token| {
        if (strEq(token, val_str)) {
            m.* = true;
            return css.CSS_OK;
        }
    }
    return css.CSS_OK;
}

fn handler_node_has_attribute_prefix(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    m.* = std.mem.startsWith(u8, attr_val, val_str);
    return css.CSS_OK;
}

fn handler_node_has_attribute_suffix(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    m.* = std.mem.endsWith(u8, attr_val, val_str);
    return css.CSS_OK;
}

fn handler_node_has_attribute_substring(_: ?*anyopaque, node: ?*anyopaque, qname: ?*const css.css_qname, value: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const q = qname orelse return css.CSS_OK;
    const attr_name = lwcData(q.name) orelse return css.CSS_OK;
    const val_str = lwcData(value) orelse return css.CSS_OK;
    const attr_val = getAttributeValue(node, attr_name.ptr, attr_name.len) orelse return css.CSS_OK;
    m.* = (std.mem.indexOf(u8, attr_val, val_str) != null);
    return css.CSS_OK;
}

fn handler_node_is_root(_: ?*anyopaque, node: ?*anyopaque, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const n = toNode(node) orelse return css.CSS_OK;
    const p = nodeParent(n) orelse return css.CSS_OK;
    m.* = (nodeType(p) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT);
    return css.CSS_OK;
}

fn handler_node_count_siblings(_: ?*anyopaque, node: ?*anyopaque, same_name: bool, after: bool, count: ?*i32) callconv(.c) css.css_error {
    const cnt = count orelse return css.CSS_BADPARM;
    cnt.* = 0;
    const n = toNode(node) orelse return css.CSS_OK;
    const my_name = if (same_name) getElementLocalName(@ptrCast(n)) else null;
    var c: i32 = 0;
    if (after) {
        var sib = nodeNext(n);
        while (sib) |s| {
            if (nodeType(s) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                if (same_name) {
                    const sname = getElementLocalName(@ptrCast(s));
                    if (my_name != null and sname != null and strEqCaseless(my_name.?, sname.?)) {
                        c += 1;
                    }
                } else {
                    c += 1;
                }
            }
            sib = nodeNext(s);
        }
    } else {
        var sib = nodePrev(n);
        while (sib) |s| {
            if (nodeType(s) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                if (same_name) {
                    const sname = getElementLocalName(@ptrCast(s));
                    if (my_name != null and sname != null and strEqCaseless(my_name.?, sname.?)) {
                        c += 1;
                    }
                } else {
                    c += 1;
                }
            }
            sib = nodePrev(s);
        }
    }
    cnt.* = c;
    return css.CSS_OK;
}

fn handler_node_is_empty(_: ?*anyopaque, node: ?*anyopaque, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    const n = toNode(node) orelse return css.CSS_OK;
    m.* = (nodeFirstChild(n) == null);
    return css.CSS_OK;
}

// Pseudo-class stubs — return false
fn handler_false_stub(_: ?*anyopaque, _: ?*anyopaque, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    return css.CSS_OK;
}

fn handler_node_is_link(_: ?*anyopaque, node: ?*anyopaque, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    // <a> elements with href are links
    const name = getElementLocalName(node) orelse return css.CSS_OK;
    if (strEqCaseless(name, "a")) {
        const elem = toElement(node) orelse return css.CSS_OK;
        m.* = lxb.lxb_dom_element_has_attribute(elem, "href", 4);
    }
    return css.CSS_OK;
}

fn handler_node_is_lang(_: ?*anyopaque, _: ?*anyopaque, _: ?*css.lwc_string, match: ?*bool) callconv(.c) css.css_error {
    const m = match orelse return css.CSS_BADPARM;
    m.* = false;
    return css.CSS_OK;
}

fn handler_node_presentational_hint(_: ?*anyopaque, _: ?*anyopaque, nhints: ?*u32, _: ?*?*css.css_hint) callconv(.c) css.css_error {
    if (nhints) |nh| nh.* = 0;
    return css.CSS_OK;
}

fn handler_ua_default_for_property(_: ?*anyopaque, property: u32, hint: ?*css.css_hint) callconv(.c) css.css_error {
    const h = hint orelse return css.CSS_BADPARM;
    switch (property) {
        css.CSS_PROP_COLOR => {
            h.data = .{ .color = 0xFF000000 }; // black
            h.status = @intCast(css.CSS_COLOR_COLOR);
        },
        css.CSS_PROP_FONT_FAMILY => {
            h.data = .{ .strings = null };
            h.status = @intCast(css.CSS_FONT_FAMILY_SANS_SERIF);
        },
        css.CSS_PROP_QUOTES => {
            h.data = .{ .strings = null };
            h.status = @intCast(css.CSS_QUOTES_NONE);
        },
        css.CSS_PROP_VOICE_FAMILY => {
            h.data = .{ .strings = null };
            h.status = 0;
        },
        else => return css.CSS_INVALID,
    }
    return css.CSS_OK;
}

fn handler_set_libcss_node_data(_: ?*anyopaque, node: ?*anyopaque, libcss_node_data: ?*anyopaque) callconv(.c) css.css_error {
    const n = toNode(node) orelse return css.CSS_BADPARM;
    // user field is [*c]anyopaque = ?*anyopaque
    n.user = libcss_node_data;
    return css.CSS_OK;
}

fn handler_get_libcss_node_data(_: ?*anyopaque, node: ?*anyopaque, libcss_node_data: ?*?*anyopaque) callconv(.c) css.css_error {
    const out = libcss_node_data orelse return css.CSS_BADPARM;
    const n = toNode(node) orelse {
        out.* = null;
        return css.CSS_OK;
    };
    // n.user is [*c]anyopaque, convert to ?*anyopaque
    out.* = if (n.user != null) @as(?*anyopaque, @ptrCast(n.user)) else null;
    return css.CSS_OK;
}

// ── Public Handler ───────────────────────────────────────────────────

/// Returns a css_select_handler populated with our Lexbor-bridging callbacks.
pub fn getHandler() css.css_select_handler {
    return css.css_select_handler{
        .handler_version = css.CSS_SELECT_HANDLER_VERSION_1,
        .node_name = handler_node_name,
        .node_classes = handler_node_classes,
        .node_id = handler_node_id,
        .named_ancestor_node = handler_named_ancestor_node,
        .named_parent_node = handler_named_parent_node,
        .named_sibling_node = handler_named_sibling_node,
        .named_generic_sibling_node = handler_named_generic_sibling_node,
        .parent_node = handler_parent_node,
        .sibling_node = handler_sibling_node,
        .node_has_name = handler_node_has_name,
        .node_has_class = handler_node_has_class,
        .node_has_id = handler_node_has_id,
        .node_has_attribute = handler_node_has_attribute,
        .node_has_attribute_equal = handler_node_has_attribute_equal,
        .node_has_attribute_dashmatch = handler_node_has_attribute_dashmatch,
        .node_has_attribute_includes = handler_node_has_attribute_includes,
        .node_has_attribute_prefix = handler_node_has_attribute_prefix,
        .node_has_attribute_suffix = handler_node_has_attribute_suffix,
        .node_has_attribute_substring = handler_node_has_attribute_substring,
        .node_is_root = handler_node_is_root,
        .node_count_siblings = handler_node_count_siblings,
        .node_is_empty = handler_node_is_empty,
        .node_is_link = handler_node_is_link,
        .node_is_visited = handler_false_stub,
        .node_is_hover = handler_false_stub,
        .node_is_active = handler_false_stub,
        .node_is_focus = handler_false_stub,
        .node_is_enabled = handler_false_stub,
        .node_is_disabled = handler_false_stub,
        .node_is_checked = handler_false_stub,
        .node_is_target = handler_false_stub,
        .node_is_lang = handler_node_is_lang,
        .node_presentational_hint = handler_node_presentational_hint,
        .ua_default_for_property = handler_ua_default_for_property,
        .set_libcss_node_data = handler_set_libcss_node_data,
        .get_libcss_node_data = handler_get_libcss_node_data,
    };
}
