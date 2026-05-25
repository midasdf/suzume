const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");
const dom_bindings = @import("dom_bindings.zig");

// ── Lexbor functions (from shared dom_bindings) ─────────────────────
const lxb_dom_node_text_content = dom_bindings.lxb_dom_node_text_content;
const lxb_dom_node_text_content_set = dom_bindings.lxb_dom_node_text_content_set;
const lxb_dom_node_insert_child = dom_bindings.lxb_dom_node_insert_child;
const lxb_dom_node_insert_before = dom_bindings.lxb_dom_node_insert_before;
const lxb_dom_node_insert_after = dom_bindings.lxb_dom_node_insert_after;
const lxb_dom_node_remove = dom_bindings.lxb_dom_node_remove;
const lxb_dom_node_destroy = dom_bindings.lxb_dom_node_destroy;
const lxb_dom_document_create_element = dom_bindings.lxb_dom_document_create_element;
const lxb_dom_element_first_attribute_noi = dom_bindings.lxb_dom_element_first_attribute_noi;
const lxb_dom_element_next_attribute_noi = dom_bindings.lxb_dom_element_next_attribute_noi;
const lxb_dom_attr_qualified_name = dom_bindings.lxb_dom_attr_qualified_name;
const lxb_dom_attr_value_noi = dom_bindings.lxb_dom_attr_value_noi;
const lxb_dom_element_set_attribute = dom_bindings.lxb_dom_element_set_attribute;
const lxb_dom_node_last_child_noi = dom_bindings.lxb_dom_node_last_child_noi;
const lxb_dom_node_prev_noi = dom_bindings.lxb_dom_node_prev_noi;
const lxb_dom_element_local_name = dom_bindings.lxb_dom_element_local_name;
const lxb_dom_document_create_text_node = dom_bindings.lxb_dom_document_create_text_node;
const lxb_dom_document_create_comment = dom_bindings.lxb_dom_document_create_comment;

// Lexbor HTML serialization (from shared dom_bindings)
const lxb_html_serialize_cb_f = dom_bindings.lxb_html_serialize_cb_f;
const lxb_html_serialize_tree_cb = dom_bindings.lxb_html_serialize_tree_cb;
const lxb_html_serialize_cb = dom_bindings.lxb_html_serialize_cb;

// Lexbor HTML fragment parsing (from shared dom_bindings)
const lxb_html_document_parse_fragment = dom_bindings.lxb_html_document_parse_fragment;

// Lexbor attribute access (from shared dom_bindings)
const lxb_dom_element_get_attribute = dom_bindings.lxb_dom_element_get_attribute;

// ── Node prototype functions ─────────────────────────────────────────

pub fn elementGetTagName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = api.getElement(c, this_val) orelse return quickjs.JS_NULL();

    // Use __origLocal if set (preserves original case from createElementNS, since lexbor lowercases)
    var js_local_cstr: ?[*]const u8 = null;
    var js_local_slice: ?[]const u8 = null;
    {
        const js_local_val = qjs.JS_GetPropertyStr(c, this_val, "__origLocal");
        defer qjs.JS_FreeValue(c, js_local_val);
        if (!quickjs.JS_IsUndefined(js_local_val) and !quickjs.JS_IsNull(js_local_val)) {
            if (api.jsStringToSlice(c, js_local_val)) |s| {
                js_local_cstr = s.ptr;
                js_local_slice = s.ptr[0..s.len];
            }
        }
    }

    var lxb_len: usize = 0;
    const lxb_name_ptr = lxb_dom_element_local_name(elem, &lxb_len);

    const local = if (js_local_slice) |s| s else if (lxb_name_ptr) |p| p[0..lxb_len] else return quickjs.JS_NULL();
    const name_ptr = local.ptr;
    const len = local.len;
    if (len == 0) {
        if (js_local_cstr) |p| qjs.JS_FreeCString(c, p);
        return quickjs.JS_NULL();
    }

    // Per DOM spec: tagName is uppercase only in HTML documents.
    // In XML/XHTML documents (contentType != "text/html"), preserve original case.
    // Check ownerDocument's type, not element namespace.
    var is_html = true;
    {
        // Check ownerDocument.contentType
        const owner_doc = qjs.JS_GetPropertyStr(c, this_val, "ownerDocument");
        defer qjs.JS_FreeValue(c, owner_doc);
        if (!quickjs.JS_IsUndefined(owner_doc) and !quickjs.JS_IsNull(owner_doc)) {
            const ct_val = qjs.JS_GetPropertyStr(c, owner_doc, "contentType");
            defer qjs.JS_FreeValue(c, ct_val);
            if (!quickjs.JS_IsUndefined(ct_val) and !quickjs.JS_IsNull(ct_val)) {
                if (api.jsStringToSlice(c, ct_val)) |ct_s| {
                    defer qjs.JS_FreeCString(c, ct_s.ptr);
                    // Only "text/html" documents use uppercase tagName
                    if (!std.mem.eql(u8, ct_s.ptr[0..ct_s.len], "text/html")) is_html = false;
                }
            }
        }
        // Also check __xmlCaseSensitive flag and namespaceURI as fallback
        if (is_html) {
            const xml_cs_val = qjs.JS_GetPropertyStr(c, this_val, "__xmlCaseSensitive");
            defer qjs.JS_FreeValue(c, xml_cs_val);
            if (!quickjs.JS_IsUndefined(xml_cs_val) and !quickjs.JS_IsNull(xml_cs_val)) is_html = false;
        }
        if (is_html) {
            const ns_val = qjs.JS_GetPropertyStr(c, this_val, "namespaceURI");
            defer qjs.JS_FreeValue(c, ns_val);
            if (quickjs.JS_IsNull(ns_val)) {
                is_html = false;
            } else if (!quickjs.JS_IsUndefined(ns_val)) {
                if (api.jsStringToSlice(c, ns_val)) |ns_s| {
                    defer qjs.JS_FreeCString(c, ns_s.ptr);
                    if (!std.mem.eql(u8, ns_s.ptr[0..ns_s.len], "http://www.w3.org/1999/xhtml")) is_html = false;
                }
            }
        }
    }

    // Get prefix (if any) for qualifiedName
    const prefix_val = qjs.JS_GetPropertyStr(c, this_val, "prefix");
    defer qjs.JS_FreeValue(c, prefix_val);
    var prefix_slice: ?[]const u8 = null;
    var prefix_cstr: ?[*]const u8 = null;
    if (!quickjs.JS_IsNull(prefix_val) and !quickjs.JS_IsUndefined(prefix_val)) {
        if (api.jsStringToSlice(c, prefix_val)) |ps| {
            if (ps.len > 0) {
                prefix_slice = ps.ptr[0..ps.len];
                prefix_cstr = ps.ptr;
            }
        }
    }
    defer if (prefix_cstr) |p| qjs.JS_FreeCString(c, p);

    const prefix_len = if (prefix_slice) |ps| ps.len else 0;
    const total_len = if (prefix_slice != null) prefix_len + 1 + len else len;

    if (!is_html) {
        // Non-HTML: return prefix:localName with original case
        if (prefix_slice) |ps| {
            var buf2: [512]u8 = undefined;
            const use_heap2 = total_len > buf2.len;
            const out = if (use_heap2)
                (std.heap.c_allocator.alloc(u8, total_len) catch return quickjs.JS_UNDEFINED())
            else
                buf2[0..total_len];
            defer if (use_heap2) std.heap.c_allocator.free(out);
            @memcpy(out[0..ps.len], ps);
            out[ps.len] = ':';
            @memcpy(out[ps.len + 1 ..][0..len], local);
            const result = qjs.JS_NewStringLen(c, out.ptr, total_len);
            if (js_local_cstr) |p| qjs.JS_FreeCString(c, p);
            return result;
        }
        const result = qjs.JS_NewStringLen(c, name_ptr, len);
        if (js_local_cstr) |p| qjs.JS_FreeCString(c, p);
        return result;
    }

    // HTML namespace: convert to uppercase and include prefix
    var stack_buf: [512]u8 = undefined;
    const use_heap = total_len > stack_buf.len;
    const buf = if (use_heap)
        (std.heap.c_allocator.alloc(u8, total_len) catch return quickjs.JS_UNDEFINED())
    else
        stack_buf[0..total_len];
    defer if (use_heap) std.heap.c_allocator.free(buf);

    var offset: usize = 0;
    if (prefix_slice) |ps| {
        for (0..ps.len) |i| {
            const ch = ps[i];
            buf[i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        }
        buf[ps.len] = ':';
        offset = ps.len + 1;
    }
    for (0..len) |i| {
        const ch = name_ptr[i];
        buf[offset + i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
    }
    if (js_local_cstr) |p| qjs.JS_FreeCString(c, p);
    return qjs.JS_NewStringLen(c, buf.ptr, total_len);
}

pub fn elementGetLocalName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Check __origLocal first (preserves case from createElementNS)
    const orig = qjs.JS_GetPropertyStr(c, this_val, "__origLocal");
    if (!quickjs.JS_IsUndefined(orig) and !quickjs.JS_IsNull(orig)) return orig;
    qjs.JS_FreeValue(c, orig);
    const elem = api.getElement(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &len);
    if (name_ptr == null or len == 0) return quickjs.JS_NULL();
    return qjs.JS_NewStringLen(c, name_ptr.?, len);
}

pub fn elementGetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    // DOM spec: textContent is null for Document and DocumentType nodes
    if (node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT or
        node.type == @as(u32, 10)) // LXB_DOM_NODE_TYPE_DOCUMENT_TYPE
        return quickjs.JS_NULL();

    // Check for JS-only children (__jsChildren) — e.g. CDATASection (nodeType 4)
    // These are not in the lexbor tree but need to be included in textContent
    const js_children = qjs.JS_GetPropertyStr(c, this_val, "__jsChildren");
    const has_js_children = !quickjs.JS_IsUndefined(js_children) and !quickjs.JS_IsNull(js_children);

    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);

    if (!has_js_children) {
        qjs.JS_FreeValue(c, js_children);
        if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, ptr.?, len);
    }

    // Has JS-only children — need to collect text from both native and JS children
    // Walk native children and __jsChildren in insertion order
    // __jsChildren are tracked with __jsChildPos (insertion index among all children)
    // Fallback: prepend JS children text, then native text
    var buf: [32768]u8 = undefined;
    var buf_len: usize = 0;

    // Collect JS children text first (they were inserted before native nodes in typical usage)
    // Read each JS child's textContent/data
    const jc_len_val = qjs.JS_GetPropertyStr(c, js_children, "length");
    var jc_len: i32 = 0;
    _ = qjs.JS_ToInt32(c, &jc_len, jc_len_val);
    qjs.JS_FreeValue(c, jc_len_val);

    var ji: u32 = 0;
    while (ji < @as(u32, @intCast(jc_len))) : (ji += 1) {
        const jc_item = qjs.JS_GetPropertyUint32(c, js_children, ji);
        defer qjs.JS_FreeValue(c, jc_item);
        // DOM spec: textContent only includes Text (3) and CDATASection (4) descendants
        // Skip PI (7), Comment (8), etc.
        const nt_val = qjs.JS_GetPropertyStr(c, jc_item, "nodeType");
        defer qjs.JS_FreeValue(c, nt_val);
        var nt: i32 = 0;
        _ = qjs.JS_ToInt32(c, &nt, nt_val);
        if (nt != 3 and nt != 4) continue;
        const tc = qjs.JS_GetPropertyStr(c, jc_item, "data");
        defer qjs.JS_FreeValue(c, tc);
        if (!quickjs.JS_IsUndefined(tc) and !quickjs.JS_IsNull(tc)) {
            if (api.jsStringToSlice(c, tc)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const copy_len = @min(s.len, buf.len - buf_len);
                @memcpy(buf[buf_len..][0..copy_len], s.ptr[0..copy_len]);
                buf_len += copy_len;
            }
        }
    }
    qjs.JS_FreeValue(c, js_children);

    // Append native text content
    if (ptr != null and len > 0) {
        const copy_len = @min(len, buf.len - buf_len);
        @memcpy(buf[buf_len..][0..copy_len], ptr.?[0..copy_len]);
        buf_len += copy_len;
    }

    if (buf_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, &buf, buf_len);
}

pub fn elementSetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();

    // DOM spec: for Text, Comment, ProcessingInstruction — textContent sets data directly
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT or
        node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT or
        node.type == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
    {
        // Capture old text for MutationObserver characterDataOldValue
        // Must copy to local buffer because lxb_dom_node_text_content_set invalidates the pointer
        var old_text_buf: [4096]u8 = undefined;
        var old_text: ?[]const u8 = null;
        {
            var old_len: usize = 0;
            const old_ptr = lxb_dom_node_text_content(node, &old_len);
            if (old_ptr) |p| {
                const copy_len = @min(old_len, old_text_buf.len);
                @memcpy(old_text_buf[0..copy_len], p[0..copy_len]);
                old_text = old_text_buf[0..copy_len];
            }
        }
        if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
            _ = lxb_dom_node_text_content_set(node, "", 0);
        } else {
            const s = api.jsStringToSlice(c, args[0]) orelse {
                _ = lxb_dom_node_text_content_set(node, "", 0);
                events.recordMutationWithOldValue(node, "characterData", null, null, null, old_text);
                api.setDomDirty();
                return quickjs.JS_UNDEFINED();
            };
            defer qjs.JS_FreeCString(c, s.ptr);
            _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
        }
        events.recordMutationWithOldValue(node, "characterData", null, null, null, old_text);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    }

    // DOM §4.2.7 "replace all": the textContent setter replaces all children
    // and emits a single childList MutationRecord whose removedNodes contains
    // EVERY detached descendant (not just the first). Previously only
    // node.first_child was captured, losing N−1 siblings from removedNodes.
    //
    // Collect every child pointer BEFORE the remove loop so we can emit a
    // bulk childList record after. prev/next siblings are null per spec —
    // the synthesized "replace all" record does not populate sibling metadata.
    var removed_buf: [256]*lxb.lxb_dom_node_t = undefined;
    var removed_heap: ?[]*lxb.lxb_dom_node_t = null;
    defer if (removed_heap) |h| std.heap.c_allocator.free(h);
    var removed_len: usize = 0;
    {
        var ch: ?*lxb.lxb_dom_node_t = node.first_child;
        while (ch) |cn| : (ch = cn.next) {
            if (removed_len < removed_buf.len) {
                removed_buf[removed_len] = cn;
                removed_len += 1;
            } else {
                // Spill to heap once the stack buffer overflows.
                if (removed_heap == null) {
                    const new_cap: usize = removed_buf.len * 2;
                    const h = std.heap.c_allocator.alloc(*lxb.lxb_dom_node_t, new_cap) catch {
                        // On OOM fall back to recording what we have.
                        break;
                    };
                    @memcpy(h[0..removed_buf.len], removed_buf[0..removed_buf.len]);
                    removed_heap = h;
                }
                if (removed_heap) |h| {
                    if (removed_len >= h.len) {
                        const grown = std.heap.c_allocator.realloc(h, h.len * 2) catch break;
                        removed_heap = grown;
                    }
                    removed_heap.?[removed_len] = cn;
                    removed_len += 1;
                }
            }
        }
    }
    const removed_slice: []const *lxb.lxb_dom_node_t = if (removed_heap) |h|
        h[0..removed_len]
    else
        removed_buf[0..removed_len];

    // DOM spec: setting textContent to null/undefined removes all children
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
        // Remove all child nodes (don't create empty text node)
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
        // Clear JS-only children (PI, etc.)
        _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
        if (removed_len > 0) {
            events.recordMutationChildListBulk(node, &.{}, removed_slice, null, null);
        }
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    }
    const s = api.jsStringToSlice(c, args[0]) orelse {
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
        _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
        if (removed_len > 0) {
            events.recordMutationChildListBulk(node, &.{}, removed_slice, null, null);
        }
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    // Remove all children (detach, not destroy — preserves subtree)
    while (node.first_child) |child| {
        lxb_dom_node_remove(child);
    }
    // Clear JS-only children (PI, etc.)
    _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
    // DOM spec: 2. If value is not empty, insert a new Text node
    var added_child: ?*lxb.lxb_dom_node_t = null;
    if (s.len > 0) {
        const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
        const text_node = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_child(node, text_node);
        added_child = text_node;
    }
    // DOM spec: only record childList mutation if something actually changed
    if (added_child != null or removed_len > 0) {
        if (added_child) |ac| {
            const added_one = [_]*lxb.lxb_dom_node_t{ac};
            events.recordMutationChildListBulk(node, &added_one, removed_slice, null, null);
        } else {
            events.recordMutationChildListBulk(node, &.{}, removed_slice, null, null);
        }
    }
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementGetParentNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p = node.parent orelse return quickjs.JS_NULL();
    return api.wrapNode(c, p);
}

pub fn elementGetParentElement(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p: *lxb.lxb_dom_node_t = node.parent orelse return quickjs.JS_NULL();
    if (p.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();
    // Check if parent is a DocumentFragment (backed by div but nodeType overridden to 11)
    const parent_js = api.wrapNode(c, p);
    const nt_val = qjs.JS_GetPropertyStr(c, parent_js, "nodeType");
    defer qjs.JS_FreeValue(c, nt_val);
    if (nt_val.tag == qjs.JS_TAG_INT and qjs.JS_VALUE_GET_INT(nt_val) != 1) {
        qjs.JS_FreeValue(c, parent_js);
        return quickjs.JS_NULL(); // Not a real Element (DocumentFragment, Document, etc.)
    }
    return parent_js;
}

pub fn elementGetFirstChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse blk: {
        // Fallback for document object
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    const child = node.first_child orelse return quickjs.JS_NULL();
    return api.wrapNode(c, child);
}

pub fn elementGetLastChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse blk: {
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    const child = lxb_dom_node_last_child_noi(node) orelse return quickjs.JS_NULL();
    return api.wrapNode(c, child);
}

pub fn elementGetNextSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = node.next orelse return quickjs.JS_NULL();
    return api.wrapNode(c, sib);
}

pub fn elementGetPreviousSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = lxb_dom_node_prev_noi(node) orelse return quickjs.JS_NULL();
    return api.wrapNode(c, sib);
}

pub fn elementGetChildren(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            _ = qjs.JS_SetPropertyUint32(c, arr, idx, api.wrapNode(c, ch));
            idx += 1;
        }
        child = ch.next;
    }
    // Wrap as HTMLCollection with namedItem, item, named properties
    const wrap_js =
        \\(function(a){
        \\  var names={};
        \\  for(var i=0;i<a.length;i++){var e=a[i];
        \\    var eid=e.getAttribute&&e.getAttribute('id');
        \\    if(eid&&!names[eid])names[eid]=e;
        \\    var ns=e.namespaceURI;if(ns==='http://www.w3.org/1999/xhtml'){
        \\      var ename=e.getAttribute&&e.getAttribute('name');
        \\      if(ename&&!names[ename])names[ename]=e;
        \\    }
        \\  }
        \\  var h={get:function(t,p,r){
        \\    if(p==='length')return a.length;
        \\    if(p==='item')return function(i){return a[i>>>0]||null;};
        \\    if(p==='namedItem')return function(n){return names[n]||null;};
        \\    if(p===Symbol.iterator)return function*(){for(var i=0;i<a.length;i++)yield a[i];};
        \\    if(p===Symbol.toStringTag)return'HTMLCollection';
        \\    if(typeof p==='string'&&/^\d+$/.test(p))return a[p>>>0];
        \\    if(typeof p==='string'&&names[p])return names[p];
        \\    return undefined;
        \\  },has:function(t,p){
        \\    if(typeof p==='string'&&/^\d+$/.test(p))return(p>>>0)<a.length;
        \\    return p==='length'||p in names;
        \\  },ownKeys:function(){
        \\    var k=[];for(var i=0;i<a.length;i++)k.push(''+i);
        \\    for(var n in names)k.push(n);return k;
        \\  },getOwnPropertyDescriptor:function(t,p){
        \\    if(typeof p==='string'&&/^\d+$/.test(p)&&(p>>>0)<a.length)return{value:a[p>>>0],writable:false,enumerable:true,configurable:true};
        \\    if(typeof p==='string'&&names[p])return{value:names[p],writable:false,enumerable:false,configurable:true};
        \\    return undefined;
        \\  }};
        \\  if(typeof HTMLCollection!=='undefined'){var p=new Proxy({},h);Object.setPrototypeOf(p,HTMLCollection.prototype);return p;}
        \\  return new Proxy({},h);
        \\})
    ;
    const wrap_fn = qjs.JS_Eval(c, wrap_js, wrap_js.len, "<children>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(wrap_fn)) {
        var wrap_args = [1]qjs.JSValue{arr};
        const result = qjs.JS_Call(c, wrap_fn, quickjs.JS_UNDEFINED(), 1, &wrap_args);
        qjs.JS_FreeValue(c, wrap_fn);
        qjs.JS_FreeValue(c, arr);
        return result;
    }
    qjs.JS_FreeValue(c, wrap_fn);
    return arr;
}

pub fn elementGetChildNodes(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Try native node first; fall back to document node for document object
    const node = api.getNode(c, this_val) orelse blk: {
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    // Lexbor-backed children
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, api.wrapNode(c, ch));
        idx += 1;
        child = ch.next;
    }
    // JS-only children (e.g. ProcessingInstruction) tracked in __jsChildren
    const js_children = qjs.JS_GetPropertyStr(c, this_val, "__jsChildren");
    if (!quickjs.JS_IsUndefined(js_children) and !quickjs.JS_IsNull(js_children)) {
        const len_val = qjs.JS_GetPropertyStr(c, js_children, "length");
        var len: i32 = 0;
        _ = qjs.JS_ToInt32(c, &len, len_val);
        qjs.JS_FreeValue(c, len_val);
        var i: u32 = 0;
        while (i < @as(u32, @intCast(len))) : (i += 1) {
            _ = qjs.JS_SetPropertyUint32(c, arr, idx, qjs.JS_GetPropertyUint32(c, js_children, i));
            idx += 1;
        }
    }
    qjs.JS_FreeValue(c, js_children);
    return arr;
}

/// Check if `node` is an ancestor of `target` (or the same node).
/// Handle appendChild for JS-level nodes (like ProcessingInstruction) that aren't backed by lexbor.
/// Sets parentNode on the child and appends to parent's childNodes via JS.
fn appendJsNode(ctx: *qjs.JSContext, parent_js: qjs.JSValue, child_js: qjs.JSValue) qjs.JSValue {
    // Remove from old parent if it has one
    const old_parent = qjs.JS_GetPropertyStr(ctx, child_js, "parentNode");
    if (!quickjs.JS_IsNull(old_parent) and !quickjs.JS_IsUndefined(old_parent)) {
        const remove_fn = qjs.JS_GetPropertyStr(ctx, old_parent, "removeChild");
        if (qjs.JS_IsFunction(ctx, remove_fn)) {
            var rm_args = [1]qjs.JSValue{qjs.JS_DupValue(ctx, child_js)};
            const rm_r = qjs.JS_Call(ctx, remove_fn, old_parent, 1, &rm_args);
            qjs.JS_FreeValue(ctx, rm_r);
            qjs.JS_FreeValue(ctx, rm_args[0]);
        }
        qjs.JS_FreeValue(ctx, remove_fn);
    }
    qjs.JS_FreeValue(ctx, old_parent);

    // Set parentNode on child
    _ = qjs.JS_SetPropertyStr(ctx, child_js, "parentNode", qjs.JS_DupValue(ctx, parent_js));

    // Track JS-only children in __jsChildren array on parent for childNodes getter
    const js_children = qjs.JS_GetPropertyStr(ctx, parent_js, "__jsChildren");
    if (quickjs.JS_IsUndefined(js_children) or quickjs.JS_IsNull(js_children)) {
        const arr = qjs.JS_NewArray(ctx);
        _ = qjs.JS_SetPropertyUint32(ctx, arr, 0, qjs.JS_DupValue(ctx, child_js));
        _ = qjs.JS_SetPropertyStr(ctx, parent_js, "__jsChildren", arr);
    } else {
        // Get current length and append
        const len_val = qjs.JS_GetPropertyStr(ctx, js_children, "length");
        var len: i32 = 0;
        _ = qjs.JS_ToInt32(ctx, &len, len_val);
        qjs.JS_FreeValue(ctx, len_val);
        _ = qjs.JS_SetPropertyUint32(ctx, js_children, @intCast(len), qjs.JS_DupValue(ctx, child_js));
    }
    qjs.JS_FreeValue(ctx, js_children);

    // Set ownerDocument from parent
    const parent_node = api.getNode(ctx, parent_js);
    if (parent_node != null) {
        const global = qjs.JS_GetGlobalObject(ctx);
        const doc = qjs.JS_GetPropertyStr(ctx, global, "document");
        _ = qjs.JS_SetPropertyStr(ctx, child_js, "ownerDocument", doc);
        qjs.JS_FreeValue(ctx, global);
    }

    api.setDomDirty();
    return qjs.JS_DupValue(ctx, child_js);
}

/// Remove a JS-only child from parent's __jsChildren tracking array.
fn removeJsChildFromParent(ctx: *qjs.JSContext, parent_js: qjs.JSValue, child_js: qjs.JSValue) void {
    const js_children = qjs.JS_GetPropertyStr(ctx, parent_js, "__jsChildren");
    defer qjs.JS_FreeValue(ctx, js_children);
    if (quickjs.JS_IsUndefined(js_children) or quickjs.JS_IsNull(js_children)) return;

    const len_val = qjs.JS_GetPropertyStr(ctx, js_children, "length");
    var len: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &len, len_val);
    qjs.JS_FreeValue(ctx, len_val);

    // Build a new array without the child
    const new_arr = qjs.JS_NewArray(ctx);
    var new_idx: u32 = 0;
    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const item = qjs.JS_GetPropertyUint32(ctx, js_children, i);
        // Compare by tag + pointer identity
        if (item.tag != child_js.tag or item.u.ptr != child_js.u.ptr) {
            _ = qjs.JS_SetPropertyUint32(ctx, new_arr, new_idx, item);
            new_idx += 1;
        } else {
            qjs.JS_FreeValue(ctx, item);
        }
    }
    _ = qjs.JS_SetPropertyStr(ctx, parent_js, "__jsChildren", new_arr);
}

/// DOM spec: only Document (9), DocumentFragment (11), and Element (1) can have children.
fn canHaveChildren(node: *lxb.lxb_dom_node_t) bool {
    return node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT or
        node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT or
        node.type == 11; // DOCUMENT_FRAGMENT
}

/// DOM spec: only these node types can be inserted as children.
fn isInsertableNodeType(node: *lxb.lxb_dom_node_t) bool {
    return node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT or
        node.type == lxb.LXB_DOM_NODE_TYPE_TEXT or
        node.type == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION or
        node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT or
        node.type == 10 or // DOCUMENT_TYPE
        node.type == 11; // DOCUMENT_FRAGMENT
}

fn isAncestorOrSelf(node: *lxb.lxb_dom_node_t, target: *lxb.lxb_dom_node_t) bool {
    var cur: ?*lxb.lxb_dom_node_t = target;
    while (cur) |c| {
        if (@intFromPtr(c) == @intFromPtr(node)) return true;
        cur = c.parent;
    }
    return false;
}

// DOM §3.2.4 step 5: helpers for Document child constraints.
fn documentHasElementChild(doc: *lxb.lxb_dom_node_t) bool {
    var c: ?*lxb.lxb_dom_node_t = doc.first_child;
    while (c) |cn| : (c = cn.next) {
        if (cn.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return true;
    }
    return false;
}

fn documentHasDoctypeChild(doc: *lxb.lxb_dom_node_t) bool {
    var c: ?*lxb.lxb_dom_node_t = doc.first_child;
    while (c) |cn| : (c = cn.next) {
        if (cn.type == @as(u32, 10)) return true;
    }
    return false;
}

fn documentHasElementChildExcluding(doc: *lxb.lxb_dom_node_t, exclude: *lxb.lxb_dom_node_t) bool {
    var c: ?*lxb.lxb_dom_node_t = doc.first_child;
    while (c) |cn| : (c = cn.next) {
        if (cn.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT and @intFromPtr(cn) != @intFromPtr(exclude)) return true;
    }
    return false;
}

fn documentHasDoctypeChildExcluding(doc: *lxb.lxb_dom_node_t, exclude: *lxb.lxb_dom_node_t) bool {
    var c: ?*lxb.lxb_dom_node_t = doc.first_child;
    while (c) |cn| : (c = cn.next) {
        if (cn.type == @as(u32, 10) and @intFromPtr(cn) != @intFromPtr(exclude)) return true;
    }
    return false;
}

pub fn elementAppendChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get parent — may be lexbor-backed or JS-level (e.g. DocumentType)
    const parent = api.getNode(c, this_val);
    if (parent == null) {
        // JS-level parent — check if it's a Node at all
        const pnt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
        defer qjs.JS_FreeValue(c, pnt);
        if (pnt.tag == qjs.JS_TAG_UNDEFINED) return quickjs.JS_UNDEFINED();
        var pt: i32 = 0;
        _ = qjs.JS_ToInt32(c, &pt, pnt);

        // WebIDL: TypeError for null/non-Node argument (before DOM validation)
        if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");
        const cnt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, cnt);
        if (cnt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");

        // DOM spec step 1: parent must be Document(9), DocumentFragment(11), or Element(1)
        if (pt != 1 and pt != 9 and pt != 11)
            return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");

        // JS-level container parent — delegate to JS manipulation
        return appendJsNode(c, this_val, args[0]);
    }

    // Lexbor-backed parent
    // WebIDL: TypeError for null/non-Node argument
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");
    const child = api.getNode(c, args[0]) orelse {
        // Check if it's a JS-level Node (like PI) with nodeType property
        const nt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, nt);
        if (nt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");
        // DOM spec step 1: parent must be able to have children
        if (!canHaveChildren(parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
        // DOM spec: DocType in non-Document parent → HierarchyRequestError
        var js_nt: i32 = 0;
        _ = qjs.JS_ToInt32(c, &js_nt, nt);
        // DOM spec: Document node cannot be a child of anything
        if (js_nt == 9)
            return api.throwDOMException(c, "HierarchyRequestError", "The new child element is a Document node, which may not be inserted here.");
        if (js_nt == 10 and parent.?.type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT)
            return api.throwDOMException(c, "HierarchyRequestError", "DocumentType can only be a child of a Document.");

        // CDATASection (nodeType 4): convert to native text node for proper textContent
        // CDATASection inherits from Text in DOM spec, so it behaves like a text node
        if (js_nt == 4) {
            const data_val = qjs.JS_GetPropertyStr(c, args[0], "data");
            defer qjs.JS_FreeValue(c, data_val);
            var data_ptr: [*]const u8 = "";
            var data_len: usize = 0;
            var data_cstr: ?[*]const u8 = null;
            if (api.jsStringToSlice(c, data_val)) |s| {
                data_ptr = s.ptr;
                data_len = s.len;
                data_cstr = s.ptr;
            }
            const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
            const text_node = lxb_dom_document_create_text_node(doc, data_ptr, data_len) orelse {
                if (data_cstr) |p| qjs.JS_FreeCString(c, p);
                return quickjs.JS_NULL();
            };
            lxb_dom_node_insert_child(parent.?, text_node);
            const result = api.wrapNode(c, text_node);
            // Override nodeType to 4 (CDATASection) and nodeName to #cdata-section
            _ = qjs.JS_SetPropertyStr(c, result, "__nodeTypeOverride", qjs.JS_NewInt32(c, 4));
            _ = qjs.JS_SetPropertyStr(c, result, "__nodeNameOverride", qjs.JS_NewString(c, "#cdata-section"));
            if (data_cstr) |p| qjs.JS_FreeCString(c, p);
            api.setDomDirty();
            return result;
        }

        // JS-level node (PI, etc.) — delegate to JS parentNode/childNodes manipulation
        return appendJsNode(c, this_val, args[0]);
    };
    // DOM spec step 1: parent must be able to have children
    if (!canHaveChildren(parent.?))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
    // DOM spec step 2: If node is a host-including inclusive ancestor of parent, throw
    if (isAncestorOrSelf(child, parent.?))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    // DOM spec step 4: node must be insertable type
    if (!isInsertableNodeType(child))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");
    // DOM spec step 5: Text node in Document parent, or DocType in non-Document parent
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and child.type == lxb.LXB_DOM_NODE_TYPE_TEXT)
        return api.throwDOMException(c, "HierarchyRequestError", "Cannot insert a Text node as a child of a Document.");
    if (child.type == @as(u32, 10) and parent.?.type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT)
        return api.throwDOMException(c, "HierarchyRequestError", "DocumentType can only be a child of a Document.");
    // DOM §3.2.4 step 5: Document can have at most one Element child.
    // Also: appending an Element to a Document with an existing Element child throws.
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and child.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        if (documentHasElementChild(parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has an Element child.");
    }
    // DOM §3.2.4 step 5: Document can have at most one DocumentType child, and only as a child.
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and child.type == @as(u32, 10)) {
        if (documentHasDoctypeChild(parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has a DocumentType child.");
    }
    // DOM spec: DocumentFragment — collect children, then insert them individually
    // Note: our fragments are lexbor divs with JS nodeType overridden to 11, so check JS property
    var is_fragment = child.type == 11;
    if (!is_fragment) {
        const js_nt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, js_nt);
        var nt_val: i32 = 0;
        _ = qjs.JS_ToInt32(c, &nt_val, js_nt);
        is_fragment = nt_val == 11;
    }
    if (is_fragment) {
        // Collect fragment's children before they're moved (dynamic alloc — no child limit)
        var frag_count: usize = 0;
        {
            var fc_count: ?*lxb.lxb_dom_node_t = child.first_child;
            while (fc_count) |f| {
                frag_count += 1;
                fc_count = f.next;
            }
        }
        if (frag_count == 0) return qjs.JS_DupValue(c, args[0]);
        const frag_children = std.heap.c_allocator.alloc(*lxb.lxb_dom_node_t, frag_count) catch return quickjs.JS_UNDEFINED();
        defer std.heap.c_allocator.free(frag_children);
        {
            var fc_fill: ?*lxb.lxb_dom_node_t = child.first_child;
            var fi: usize = 0;
            while (fc_fill) |f| {
                frag_children[fi] = f;
                fi += 1;
                fc_fill = f.next;
            }
        }
        const ins_prev = lxb_dom_node_last_child_noi(parent.?);
        // Manually move each child from fragment to parent (lexbor doesn't auto-move fragment children)
        for (frag_children) |fnode| {
            lxb_dom_node_remove(fnode);
            lxb_dom_node_insert_child(parent.?, fnode);
        }
        // Shadow DOM Phase 1: propagate scope tag to each inserted subtree.
        {
            const shadow_root = @import("shadow_root.zig");
            for (frag_children) |fnode| shadow_root.propagateScopeFromParent(parent.?, fnode);
        }
        // Record mutation on parent with addedNodes
        events.recordMutationChildListMulti(parent.?, frag_children, ins_prev, null);
        // DOM spec: also record removal mutation on the fragment itself (removedNodes)
        events.recordMutationChildListRemovedMulti(child, frag_children);
        api.setDomDirty();
        for (frag_children) |fc_node| {
            api.maybeExecuteDynamicScriptPublic(c, fc_node, args[0]);
            upgradeSubtreeCustomElements(c, fc_node);
        }
        return qjs.JS_DupValue(c, args[0]);
    }
    // DOM spec: remove from old parent first, record removal mutation
    const old_parent = child.parent;
    if (old_parent != null) {
        const rm_prev = child.prev;
        const rm_next = child.next;
        lxb_dom_node_remove(child);
        events.recordMutationChildList(old_parent.?, null, child, rm_prev, rm_next);
    }
    // Capture siblings at insertion point (append = after last child)
    const ins_prev = lxb_dom_node_last_child_noi(parent.?);
    lxb_dom_node_insert_child(parent.?, child);
    // Shadow DOM Phase 1: propagate scope tag if parent is in a shadow tree.
    {
        const shadow_root = @import("shadow_root.zig");
        shadow_root.propagateScopeFromParent(parent.?, child);
    }
    events.recordMutationChildList(parent.?, child, null, ins_prev, null);
    api.setDomDirty();
    // Dynamic script execution: if a <script> is appended, fetch and execute it
    api.maybeExecuteDynamicScriptPublic(c, child, args[0]);
    // Dynamic iframe setup: if an <iframe> is appended, create contentDocument/contentWindow
    maybeSetupDynamicIframe(c, child);
    // Upgrade custom elements in the inserted subtree
    upgradeSubtreeCustomElements(c, child);
    return qjs.JS_DupValue(c, args[0]);
}

/// If the inserted node is an <iframe>, set up contentDocument/contentWindow.
fn maybeSetupDynamicIframe(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) void {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    var name_len: usize = 0;
    const name = lxb_dom_element_local_name(elem, &name_len);
    if (name == null or name_len != 6) return;
    if (!std.mem.eql(u8, name.?[0..6], "iframe")) return;
    // Check if contentDocument is already set (avoid double setup)
    const js_elem = api.wrapNode(ctx, node);
    defer qjs.JS_FreeValue(ctx, js_elem);
    const cd = qjs.JS_GetPropertyStr(ctx, js_elem, "contentDocument");
    const has_cd = !quickjs.JS_IsNull(cd) and !quickjs.JS_IsUndefined(cd);
    qjs.JS_FreeValue(ctx, cd);
    if (has_cd) return;
    api.iframe.setupDynamicIframe(ctx, elem);
}

pub fn elementRemoveChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // DOM spec: TypeError if argument is not a Node
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'removeChild': parameter 1 is not of type 'Node'.");
    const child = api.getNode(c, args[0]) orelse {
        // JS-level node (PI, etc.) — check nodeType
        const nt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, nt);
        if (nt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'removeChild': parameter 1 is not of type 'Node'.");
        // Verify child's parentNode matches this parent (DOM spec: NotFoundError)
        const pn = qjs.JS_GetPropertyStr(c, args[0], "parentNode");
        defer qjs.JS_FreeValue(c, pn);
        const is_child = pn.tag == this_val.tag and pn.u.ptr == this_val.u.ptr;
        if (!is_child) return api.throwDOMException(c, "NotFoundError", "The node to be removed is not a child of this node.");
        // Remove from __jsChildren tracking on parent
        removeJsChildFromParent(c, this_val, args[0]);
        // Remove parentNode reference on JS-level node
        _ = qjs.JS_SetPropertyStr(c, args[0], "parentNode", quickjs.JS_NULL());
        api.setDomDirty();
        return qjs.JS_DupValue(c, args[0]);
    };
    // Verify child is actually a child of parent (DOM spec: NotFoundError)
    if (child.parent != parent) return api.throwDOMException(c, "NotFoundError", "The node to be removed is not a child of this node.");
    // NodeIterator pre-removing steps (DOM spec §6.1): update all active iterators before removal
    {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        const pre_remove_fn = qjs.JS_GetPropertyStr(c, global, "__niPreRemove");
        defer qjs.JS_FreeValue(c, pre_remove_fn);
        if (qjs.JS_IsFunction(c, pre_remove_fn)) {
            var call_args = [1]qjs.JSValue{args[0]};
            const r = qjs.JS_Call(c, pre_remove_fn, global, 1, &call_args);
            qjs.JS_FreeValue(c, r);
        }
    }
    const rm_prev = child.prev;
    const rm_next = child.next;
    lxb_dom_node_remove(child);
    events.recordMutationChildList(parent, null, child, rm_prev, rm_next);
    api.setDomDirty();
    return qjs.JS_DupValue(c, args[0]);
}

pub fn elementInsertBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': 2 arguments required.");
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get parent — may be lexbor-backed or JS-level
    const parent = api.getNode(c, this_val);
    if (parent == null) {
        // JS-level parent (DocumentType, PI, etc.) — check nodeType
        const pnt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
        defer qjs.JS_FreeValue(c, pnt);
        if (pnt.tag == qjs.JS_TAG_UNDEFINED) return quickjs.JS_UNDEFINED();
        var pt: i32 = 0;
        _ = qjs.JS_ToInt32(c, &pt, pnt);

        // WebIDL: TypeError if first arg is not a Node
        if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");
        const cnt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, cnt);
        if (cnt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");

        // DOM spec step 1: parent must be Document(9), DocumentFragment(11), or Element(1)
        if (pt != 1 and pt != 9 and pt != 11)
            return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");

        // Step 3: if child is given, verify it's a child of this JS-level parent
        if (!quickjs.JS_IsNull(args[1]) and !quickjs.JS_IsUndefined(args[1])) {
            const ref_parent = qjs.JS_GetPropertyStr(c, args[1], "parentNode");
            defer qjs.JS_FreeValue(c, ref_parent);
            if (ref_parent.tag != this_val.tag or ref_parent.u.ptr != this_val.u.ptr)
                return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
        }

        // JS-level container parent — delegate
        return appendJsNode(c, this_val, args[0]);
    }

    // Lexbor-backed parent
    // DOM spec: TypeError if first arg is not a Node
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");

    // Get node — may be lexbor-backed or JS-level
    const new_node_opt = api.getNode(c, args[0]);
    const new_node_type: i32 = if (new_node_opt) |n| @as(i32, @intCast(n.type)) else blk: {
        const nt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, nt);
        if (nt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");
        var val: i32 = 0;
        _ = qjs.JS_ToInt32(c, &val, nt);
        break :blk val;
    };

    // DOM spec pre-insertion validation step 1: parent must be Document, DocumentFragment, or Element
    if (!canHaveChildren(parent.?))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");

    // DOM spec step 2: node must not be an ancestor of parent (only for lexbor nodes)
    if (new_node_opt) |nn| {
        if (isAncestorOrSelf(nn, parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    }

    // DOM spec step 3: if child is given, verify it's a child of parent
    if (!quickjs.JS_IsNull(args[1]) and !quickjs.JS_IsUndefined(args[1])) {
        const ref_check = api.getNode(c, args[1]);
        if (ref_check == null) {
            const nt = qjs.JS_GetPropertyStr(c, args[1], "nodeType");
            defer qjs.JS_FreeValue(c, nt);
            if (nt.tag == qjs.JS_TAG_UNDEFINED) {
                return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 2 is not of type 'Node'.");
            }
            return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
        }
        if (ref_check.?.parent != parent.?)
            return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
    }

    // DOM spec step 4: node must be DocumentFragment, DocumentType, Element, Text, ProcessingInstruction, or Comment
    if (new_node_opt) |nn| {
        if (!isInsertableNodeType(nn))
            return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");
    } else {
        // JS-level node type check
        if (new_node_type != 1 and new_node_type != 3 and new_node_type != 7 and
            new_node_type != 8 and new_node_type != 10 and new_node_type != 11)
            return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");
    }

    // DOM spec step 5: Text in Document / DocType in non-Document
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 3)
        return api.throwDOMException(c, "HierarchyRequestError", "Cannot insert a Text node as a child of a Document.");
    if (new_node_type == 10 and parent.?.type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT)
        return api.throwDOMException(c, "HierarchyRequestError", "DocumentType can only be a child of a Document.");
    // DOM §3.2.4 step 5: Document can have at most one Element child / one DocumentType child.
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 1) {
        if (documentHasElementChild(parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has an Element child.");
    }
    if (parent.?.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 10) {
        if (documentHasDoctypeChild(parent.?))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has a DocumentType child.");
    }

    // JS-level node — delegate to appendJsNode
    if (new_node_opt == null)
        return appendJsNode(c, this_val, args[0]);

    const new_node = new_node_opt.?;

    // DOM spec: DocumentFragment — insert individual children
    var is_frag = new_node.type == 11;
    if (!is_frag) {
        const js_fnt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, js_fnt);
        var fnt_val: i32 = 0;
        _ = qjs.JS_ToInt32(c, &fnt_val, js_fnt);
        is_frag = fnt_val == 11;
    }
    if (is_frag) {
        // Dynamic alloc — no child limit
        var fc_count: usize = 0;
        {
            var fc_cnt_iter: ?*lxb.lxb_dom_node_t = new_node.first_child;
            while (fc_cnt_iter) |f| {
                fc_count += 1;
                fc_cnt_iter = f.next;
            }
        }
        if (fc_count == 0) return qjs.JS_DupValue(c, args[0]);
        const frag_ch = std.heap.c_allocator.alloc(*lxb.lxb_dom_node_t, fc_count) catch return quickjs.JS_UNDEFINED();
        defer std.heap.c_allocator.free(frag_ch);
        {
            var fc_fill: ?*lxb.lxb_dom_node_t = new_node.first_child;
            var fi: usize = 0;
            while (fc_fill) |f| {
                frag_ch[fi] = f;
                fi += 1;
                fc_fill = f.next;
            }
        }
        const ref_is_null2 = quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]);
        const eff_ref2: ?*lxb.lxb_dom_node_t = if (!ref_is_null2) api.getNode(c, args[1]) else null;
        const frag_prev = if (eff_ref2) |er| er.prev else lxb_dom_node_last_child_noi(parent.?);
        for (frag_ch) |fnode| {
            lxb_dom_node_remove(fnode);
            if (eff_ref2) |er| lxb_dom_node_insert_before(er, fnode) else lxb_dom_node_insert_child(parent.?, fnode);
        }
        // Shadow DOM Phase 1: propagate scope tag to each inserted subtree.
        {
            const shadow_root = @import("shadow_root.zig");
            for (frag_ch) |fnode| shadow_root.propagateScopeFromParent(parent.?, fnode);
        }
        events.recordMutationChildListMulti(parent.?, frag_ch, frag_prev, eff_ref2);
        // DOM spec: record removal mutation on the fragment itself
        events.recordMutationChildListRemovedMulti(new_node, frag_ch);
        api.setDomDirty();
        for (frag_ch) |fnode| {
            api.maybeExecuteDynamicScriptPublic(c, fnode, args[0]);
            upgradeSubtreeCustomElements(c, fnode);
        }
        return qjs.JS_DupValue(c, args[0]);
    }

    // DOM spec step 7: if node is child (ref), set ref to node's next sibling
    var effective_ref: ?*lxb.lxb_dom_node_t = null;
    var ref_is_null = quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]);
    if (!ref_is_null) {
        const ref_node = api.getNode(c, args[1]).?;
        if (ref_node == new_node) {
            effective_ref = ref_node.next;
            ref_is_null = (effective_ref == null);
        } else {
            effective_ref = ref_node;
        }
    }
    const old_parent = new_node.parent;
    if (old_parent != null) {
        const rem_prev = new_node.prev;
        const rem_next = new_node.next;
        lxb_dom_node_remove(new_node);
        events.recordMutationChildList(old_parent.?, null, new_node, rem_prev, rem_next);
    }
    const ins_prev = if (!ref_is_null) effective_ref.?.prev else lxb_dom_node_last_child_noi(parent.?);
    const ins_next = if (!ref_is_null) effective_ref else null;
    if (ref_is_null) {
        lxb_dom_node_insert_child(parent.?, new_node);
    } else {
        lxb_dom_node_insert_before(effective_ref.?, new_node);
    }
    // Shadow DOM Phase 1: propagate scope tag if parent is in a shadow tree.
    {
        const shadow_root = @import("shadow_root.zig");
        shadow_root.propagateScopeFromParent(parent.?, new_node);
    }
    events.recordMutationChildList(parent.?, new_node, null, ins_prev, ins_next);
    api.setDomDirty();
    api.maybeExecuteDynamicScriptPublic(c, new_node, args[0]);
    maybeSetupDynamicIframe(c, new_node);
    upgradeSubtreeCustomElements(c, new_node);
    return qjs.JS_DupValue(c, args[0]);
}

pub fn elementReplaceChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': 2 arguments required");
    const args = argv orelse return quickjs.JS_NULL();
    const parent = api.getNode(c, this_val) orelse {
        // JS-level parent — check nodeType for step 1 validation
        if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 1 is not of type 'Node'.");
        if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]))
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 2 is not of type 'Node'.");
        const pnt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
        defer qjs.JS_FreeValue(c, pnt);
        var pt: i32 = 0;
        _ = qjs.JS_ToInt32(c, &pt, pnt);
        if (pt != 1 and pt != 9 and pt != 11)
            return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    };
    // DOM spec step 1: parent must be Document(9), DocumentFragment(11), or Element(1)
    {
        const parent_type = parent.type;
        if (parent_type != lxb.LXB_DOM_NODE_TYPE_ELEMENT and
            parent_type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT and
            parent_type != @as(u32, 11))
        {
            // Check JS-level nodeType override (e.g., DocumentFragment backed by div)
            const js_nt2 = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
            defer qjs.JS_FreeValue(c, js_nt2);
            var pt2: i32 = 0;
            _ = qjs.JS_ToInt32(c, &pt2, js_nt2);
            if (pt2 != 1 and pt2 != 9 and pt2 != 11)
                return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
        }
    }

    // DOM spec: TypeError if node is null
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 1 is not of type 'Node'.");

    // Get node — may be lexbor-backed or JS-level
    const new_node_opt = api.getNode(c, args[0]);
    const new_node_type: i32 = if (new_node_opt) |n| @as(i32, @intCast(n.type)) else blk: {
        const nt = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, nt);
        if (nt.tag == qjs.JS_TAG_UNDEFINED)
            return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 1 is not of type 'Node'.");
        var val: i32 = 0;
        _ = qjs.JS_ToInt32(c, &val, nt);
        break :blk val;
    };

    // DOM spec step 1: parent must be able to have children
    if (!canHaveChildren(parent))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
    // DOM spec step 2: node must not be an ancestor of parent (only for lexbor nodes)
    if (new_node_opt) |nn| {
        if (isAncestorOrSelf(nn, parent))
            return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    }
    // DOM spec: TypeError if child is null
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 2 is not of type 'Node'.");
    const old_node = api.getNode(c, args[1]) orelse
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    if (old_node.parent != parent)
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");

    // DOM spec step 4: node must be insertable type
    if (new_node_opt) |nn| {
        if (!isInsertableNodeType(nn))
            return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");
    } else {
        if (new_node_type != 1 and new_node_type != 3 and new_node_type != 7 and
            new_node_type != 8 and new_node_type != 10 and new_node_type != 11)
            return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");
    }

    // DOM spec step 5: Text in Document / DocType in non-Document
    if (parent.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 3)
        return api.throwDOMException(c, "HierarchyRequestError", "Cannot insert a Text node as a child of a Document.");
    if (new_node_type == 10 and parent.type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT)
        return api.throwDOMException(c, "HierarchyRequestError", "DocumentType can only be a child of a Document.");
    // DOM §3.2.4 (replace) step 6: Document can have at most one Element / DocumentType child,
    // excluding the node being replaced.
    if (parent.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 1) {
        if (documentHasElementChildExcluding(parent, old_node))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has an Element child.");
    }
    if (parent.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT and new_node_type == 10) {
        if (documentHasDoctypeChildExcluding(parent, old_node))
            return api.throwDOMException(c, "HierarchyRequestError", "Document already has a DocumentType child.");
    }

    // JS-level node — cannot insert into lexbor tree
    if (new_node_opt == null)
        return appendJsNode(c, this_val, args[0]);

    const new_node = new_node_opt.?;
    // DOM spec: if new_node is the same as old_node, this is a no-op
    if (new_node == old_node) {
        return qjs.JS_DupValue(c, args[1]);
    }

    // DOM spec: DocumentFragment — replace old_node with fragment's children
    var is_frag_rc = new_node.type == 11;
    if (!is_frag_rc) {
        const js_fnt_rc = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, js_fnt_rc);
        var fnt_rc: i32 = 0;
        _ = qjs.JS_ToInt32(c, &fnt_rc, js_fnt_rc);
        is_frag_rc = fnt_rc == 11;
    }
    if (is_frag_rc) {
        // Dynamic alloc — no child limit
        var fc_cnt: usize = 0;
        {
            var fc_cnt_iter: ?*lxb.lxb_dom_node_t = new_node.first_child;
            while (fc_cnt_iter) |f| {
                fc_cnt += 1;
                fc_cnt_iter = f.next;
            }
        }
        if (fc_cnt == 0) return qjs.JS_DupValue(c, args[1]);
        const frag_ch_rc = std.heap.c_allocator.alloc(*lxb.lxb_dom_node_t, fc_cnt) catch return quickjs.JS_UNDEFINED();
        defer std.heap.c_allocator.free(frag_ch_rc);
        {
            var fc_fill: ?*lxb.lxb_dom_node_t = new_node.first_child;
            var fi: usize = 0;
            while (fc_fill) |f| {
                frag_ch_rc[fi] = f;
                fi += 1;
                fc_fill = f.next;
            }
        }
        const rep_prev_f = old_node.prev;
        const rep_next_f = old_node.next;
        // Insert fragment children before old_node
        for (frag_ch_rc) |fnode| {
            lxb_dom_node_remove(fnode);
            lxb_dom_node_insert_before(old_node, fnode);
        }
        lxb_dom_node_remove(old_node);
        events.recordMutationChildListMulti(parent, frag_ch_rc, rep_prev_f, rep_next_f);
        events.recordMutationChildList(parent, null, old_node, rep_prev_f, rep_next_f);
        // DOM spec: record removal mutation on the fragment itself
        events.recordMutationChildListRemovedMulti(new_node, frag_ch_rc);
        api.setDomDirty();
        return qjs.JS_DupValue(c, args[1]);
    }

    // Remove new_node from its old parent first (handles internal replacement)
    if (new_node.parent) |old_p| {
        const rm_prev = new_node.prev;
        const rm_next = new_node.next;
        lxb_dom_node_remove(new_node);
        events.recordMutationChildList(old_p, null, new_node, rm_prev, rm_next);
    }
    // Capture siblings AFTER new_node removal (correct for internal replacement)
    const rep_prev = old_node.prev;
    const rep_next = old_node.next;
    lxb_dom_node_insert_before(old_node, new_node);
    lxb_dom_node_remove(old_node);
    events.recordMutationChildList(parent, new_node, old_node, rep_prev, rep_next);
    api.setDomDirty();
    // Dynamic script execution, iframe setup, and custom element upgrade
    api.maybeExecuteDynamicScriptPublic(c, new_node, args[0]);
    maybeSetupDynamicIframe(c, new_node);
    upgradeSubtreeCustomElements(c, new_node);
    return qjs.JS_DupValue(c, args[1]); // returns the removed (old) node
}

pub fn elementRemove(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.parent != null) {
        lxb_dom_node_remove(node);
        api.setDomDirty();
    }
    return quickjs.JS_UNDEFINED();
}


// ── Namespace helpers for cloneNode ──────────────────────────────────

/// Map Lexbor namespace ID → W3C namespace URI string.
/// Lexbor HTML-document ns IDs (observed in dom_selector.zig):
/// 1=HTML, 2=MATH, 3=SVG, 4=XLINK, 5=XML, 6=XMLNS
fn nsIdToUriStr(ns_id: usize) ?[]const u8 {
    return switch (ns_id) {
        1 => "http://www.w3.org/1999/xhtml",
        2 => "http://www.w3.org/1998/Math/MathML",
        3 => "http://www.w3.org/2000/svg",
        4 => "http://www.w3.org/1999/xlink",
        5 => "http://www.w3.org/XML/1998/namespace",
        6 => "http://www.w3.org/2000/xmlns/",
        else => null,
    };
}

/// Map a JS namespaceURI value → Lexbor ns ID.
/// Used when createElementNS sets JS namespaceURI but not the Lexbor ns field.
fn nsValToNsId(c: *qjs.JSContext, ns_val: qjs.JSValue) usize {
    const ns_str = qjs.JS_ToCString(c, ns_val);
    if (ns_str == null) return 0;
    defer qjs.JS_FreeCString(c, ns_str);
    const ns_slice = std.mem.span(ns_str.?);
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/1999/xhtml")) return 1;
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/1998/Math/MathML")) return 2;
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/2000/svg")) return 3;
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/1999/xlink")) return 4;
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/XML/1998/namespace")) return 5;
    if (std.mem.eql(u8, ns_slice, "http://www.w3.org/2000/xmlns/")) return 6;
    return 0;
}

pub fn elementCloneNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();

    // Determine deep flag (default: shallow clone per DOM spec)
    var deep = false;
    if (argc > 0) {
        if (argv) |args| {
            deep = qjs.JS_ToBool(c, args[0]) > 0;
        }
    }

    // Check JS-level nodeType first (for JS-only objects like DocumentFragment, Document)
    const js_nt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
    var js_node_type: i32 = 0;
    _ = qjs.JS_ToInt32(c, &js_node_type, js_nt);
    qjs.JS_FreeValue(c, js_nt);
    if (js_node_type == 11) {
        // Clone as DocumentFragment via JS
        const clone_js = if (deep)
            \\(function(src){var f=document.createDocumentFragment();for(var i=0;i<src.childNodes.length;i++)f.appendChild(src.childNodes[i].cloneNode(true));return f;})
        else
            \\(function(){return document.createDocumentFragment();})
        ;
        const clone_fn = qjs.JS_Eval(c, clone_js, clone_js.len, "<frag-clone>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(clone_fn)) {
            var clone_args = [1]qjs.JSValue{this_val};
            const result = qjs.JS_Call(c, clone_fn, quickjs.JS_UNDEFINED(), if (deep) @as(c_int, 1) else 0, &clone_args);
            qjs.JS_FreeValue(c, clone_fn);
            return result;
        }
        qjs.JS_FreeValue(c, clone_fn);
    }

    // JS-only Document (nodeType 9 without lxb node, e.g. createDocument/createHTMLDocument)
    if (js_node_type == 9) {
        const clone_doc_js =
            \\(function(src, deep){
            \\  var ct=src.contentType||'text/html';
            \\  var d;
            \\  if(ct==='text/html'){
            \\    d=document.implementation.createHTMLDocument('');
            \\  }else{
            \\    d=document.implementation.createDocument(null,'',null);
            \\  }
            \\  /* Remove default children for clean slate */
            \\  while(d.firstChild)d.removeChild(d.firstChild);
            \\  /* Deep clone: copy children from source */
            \\  if(deep&&src.childNodes){for(var i=0;i<src.childNodes.length;i++)d.appendChild(src.childNodes[i].cloneNode(true));}
            \\  d.contentType=ct;
            \\  d.URL=src.URL||'about:blank';
            \\  d.documentURI=src.documentURI||'about:blank';
            \\  return d;
            \\})
        ;
        const clone_fn2 = qjs.JS_Eval(c, clone_doc_js, clone_doc_js.len, "<doc-clone>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(clone_fn2)) {
            var clone_args2 = [2]qjs.JSValue{ this_val, quickjs.JS_NewBool(deep) };
            const result = qjs.JS_Call(c, clone_fn2, quickjs.JS_UNDEFINED(), 2, &clone_args2);
            qjs.JS_FreeValue(c, clone_fn2);
            return result;
        }
        qjs.JS_FreeValue(c, clone_fn2);
    }

    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();

    // Text/Comment/PI nodes: create new node with same data
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        var len: usize = 0;
        const txt = lxb_dom_node_text_content(node, &len);
        const new_text = lxb_dom_document_create_text_node(doc, if (txt) |t| t else "", if (txt != null) len else 0) orelse return quickjs.JS_NULL();
        return api.wrapNode(c, new_text);
    }
    if (node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) {
        const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
        var len: usize = 0;
        const txt = lxb_dom_node_text_content(node, &len);
        const new_comment = lxb_dom_document_create_comment(doc, if (txt) |t| t else "", if (txt != null) len else 0) orelse return quickjs.JS_NULL();
        return api.wrapNode(c, new_comment);
    }

    // Element nodes: clone via createElement + attribute copy
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();
    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    const src_elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // Get tag name
    var tag_len: usize = 0;
    const tag_ptr = lxb_dom_element_local_name(src_elem, &tag_len);
    if (tag_ptr == null) return quickjs.JS_NULL();

    // Preserve source namespace (critical for SVG/MathML cloning).
    // lxb_dom_document_create_element always creates in the HTML namespace
    // for HTML-type documents.  We copy the source's Lexbor ns ID so the
    // clone inherits the correct namespace for serialization / selection.
    const src_ns: usize = src_elem.node.ns;

    // Create new element with same tag
    const new_elem = lxb_dom_document_create_element(doc, tag_ptr.?, tag_len, null) orelse return quickjs.JS_NULL();
    const new_node: *lxb.lxb_dom_node_t = @ptrCast(new_elem);

    // Restore namespace on the clone (fix: SVG/MathML elements clone to correct ns)
    new_elem.node.ns = src_ns;

    // Copy all attributes
    var attr: ?*anyopaque = lxb_dom_element_first_attribute_noi(src_elem);
    while (attr) |a| {
        var an_len: usize = 0;
        const an = lxb_dom_attr_qualified_name(a, &an_len);
        var av_len: usize = 0;
        const av = lxb_dom_attr_value_noi(a, &av_len);
        if (an) |name| {
            _ = lxb_dom_element_set_attribute(new_elem, name, an_len, if (av) |v| v else "", if (av != null) av_len else 0);
        }
        attr = lxb_dom_element_next_attribute_noi(a);
    }

    // Deep clone: recursively clone all children
    if (deep) {
        var child: ?*lxb.lxb_dom_node_t = node.first_child;
        while (child) |ch| {
            const child_js = api.wrapNode(c, ch);
            // Recursively call cloneNode on child
            const clone_fn = qjs.JS_GetPropertyStr(c, child_js, "cloneNode");
            if (qjs.JS_IsFunction(c, clone_fn)) {
                var clone_args = [1]qjs.JSValue{quickjs.JS_NewBool(true)};
                const cloned_child = qjs.JS_Call(c, clone_fn, child_js, 1, &clone_args);
                // Append cloned child to new element
                if (api.getNode(c, cloned_child)) |cloned_node| {
                    lxb_dom_node_insert_child(new_node, cloned_node);
                }
                qjs.JS_FreeValue(c, cloned_child);
            }
            qjs.JS_FreeValue(c, clone_fn);
            qjs.JS_FreeValue(c, child_js);
            child = ch.next;
        }
    }

    const result = api.wrapNode(c, new_node);

    // Preserve namespaceURI (fix: SVG/MathML cloning).
    // The JS prototype default is always "http://www.w3.org/1999/xhtml", which is
    // wrong for SVG/MathML elements.  Two sources of truth exist:
    //   1. Lexbor node.ns field (parser-created elements — always correct)
    //   2. JS per-instance namespaceURI override (createElementNS — may differ
    //      from Lexbor ns when QJS createElementNS sets JS property but not ns field)
    // Prefer explicit JS override when it differs from the HTML default; otherwise
    // compute from the Lexbor ns field.
    const ns_val = qjs.JS_GetPropertyStr(c, this_val, "namespaceURI");
    const html_ns_str = "http://www.w3.org/1999/xhtml";

    // Compare as C strings to detect explicit namespaceURI overrides
    const ns_cstr = if (!quickjs.JS_IsUndefined(ns_val)) qjs.JS_ToCString(c, ns_val) else null;
    defer if (ns_cstr) |s| qjs.JS_FreeCString(c, s);
    defer qjs.JS_FreeValue(c, ns_val);

    var ns_was_set = false;
    if (ns_cstr) |ns_s| {
        const ns_slice = std.mem.span(ns_s);
        // If source has an explicit per-instance namespaceURI override
        // (e.g. createElementNS-created SVG), use it directly.
        if (!std.mem.eql(u8, ns_slice, html_ns_str)) {
            _ = qjs.JS_SetPropertyStr(c, result, "namespaceURI", ns_val);
            ns_was_set = true;

            // Also fix the Lexbor ns field: createElementNS in QJS sets the JS
            // property but leaves node.ns as HTML (1).  Map the explicit NS URI
            // back to the correct ns ID so serialization/selection is correct.
            const ns_from_js = nsValToNsId(c, ns_val);
            if (ns_from_js > 0) {
                new_elem.node.ns = ns_from_js;
            }
        }
    }

    // Fallback: compute namespaceURI from Lexbor ns ID (for parser-created elements)
    if (!ns_was_set) {
        const uri = nsIdToUriStr(src_ns);
        if (uri) |u| {
            _ = qjs.JS_SetPropertyStr(c, result, "namespaceURI", qjs.JS_NewStringLen(c, u.ptr, u.len));
        }
    }

    // Preserve prefix from source
    const prefix_val = qjs.JS_GetPropertyStr(c, this_val, "prefix");
    if (!quickjs.JS_IsNull(prefix_val) and !quickjs.JS_IsUndefined(prefix_val)) {
        _ = qjs.JS_SetPropertyStr(c, result, "prefix", prefix_val);
    } else {
        qjs.JS_FreeValue(c, prefix_val);
    }
    return result;
}

pub fn elementReplaceWith(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const parent = node.parent orelse return quickjs.JS_UNDEFINED();

    // DOM spec: find viable next sibling (not in args list)
    var viable_next: ?*lxb.lxb_dom_node_t = node.next;
    outer: while (viable_next) |vn| {
        var j: c_int = 0;
        while (j < argc) : (j += 1) {
            if (api.getNode(c, args[@intCast(j)])) |arg_node| {
                if (@intFromPtr(arg_node) == @intFromPtr(vn)) {
                    viable_next = vn.next;
                    continue :outer;
                }
            }
        }
        break;
    }

    // Remove this node first
    lxb_dom_node_remove(node);

    // Insert all args before viable_next (or append to parent)
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (api.getNode(c, arg)) |new_node| {
            if (new_node.parent != null) lxb_dom_node_remove(new_node);
            if (viable_next) |vn| {
                lxb_dom_node_insert_before(vn, new_node);
            } else {
                lxb_dom_node_insert_child(parent, new_node);
            }
        } else {
            if (api.jsStringToSlice(c, arg)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const doc = api.getDocument(c) orelse continue;
                const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
                if (viable_next) |vn| {
                    lxb_dom_node_insert_before(vn, text);
                } else {
                    lxb_dom_node_insert_child(parent, text);
                }
            }
        }
    }
    // node already removed above
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return quickjs.JS_UNDEFINED();

    // Simple approach: insert all before this node, handling self-reference
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (api.getNode(c, arg)) |new_node| {
            if (new_node.parent != null) lxb_dom_node_remove(new_node);
            if (node.parent != null) {
                lxb_dom_node_insert_before(node, new_node);
            } else {
                // Self was removed (self-reference case) — use parent + position
                lxb_dom_node_insert_child(parent, new_node);
            }
        } else {
            if (api.jsStringToSlice(c, arg)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const doc = api.getDocument(c) orelse continue;
                const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
                if (node.parent != null) {
                    lxb_dom_node_insert_before(node, text);
                } else {
                    lxb_dom_node_insert_child(parent, text);
                }
            }
        }
    }
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementAfter(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return quickjs.JS_UNDEFINED();
    // Save previous sibling as anchor in case node gets removed (self-reference)
    const prev_sib = lxb_dom_node_prev_noi(node);
    var anchor: *lxb.lxb_dom_node_t = node;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (api.getNode(c, arg)) |new_node| {
            if (new_node.parent != null) lxb_dom_node_remove(new_node);
            // If anchor was removed (self-reference), use prev_sib or prepend
            if (anchor.parent == null) {
                if (prev_sib) |ps| {
                    lxb_dom_node_insert_after(ps, new_node);
                } else {
                    // Insert at start of parent
                    if (parent.first_child) |fc| lxb_dom_node_insert_before(fc, new_node) else lxb_dom_node_insert_child(parent, new_node);
                }
            } else {
                lxb_dom_node_insert_after(anchor, new_node);
            }
            anchor = new_node;
        } else {
            if (api.jsStringToSlice(c, arg)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const doc = api.getDocument(c) orelse continue;
                const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
                if (anchor.parent == null) {
                    if (prev_sib) |ps| lxb_dom_node_insert_after(ps, text) else {
                        if (parent.first_child) |fc| lxb_dom_node_insert_before(fc, text) else lxb_dom_node_insert_child(parent, text);
                    }
                } else {
                    lxb_dom_node_insert_after(anchor, text);
                }
                anchor = text;
            }
        }
    }
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

pub fn elementContains(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) return quickjs.JS_NewBool(false);

    // DOM spec: "contains" returns true if other is an inclusive descendant
    // Self-containment check (works for any JS object)
    if (this_val.tag == args[0].tag and this_val.u.ptr == args[0].u.ptr) {
        return quickjs.JS_NewBool(true);
    }

    // Try lexbor node path
    const node = api.getNode(c, this_val);
    const other = api.getNode(c, args[0]);

    if (node != null and other != null) {
        var cur: ?*lxb.lxb_dom_node_t = other;
        while (cur) |n| {
            if (n == node.?) return quickjs.JS_NewBool(true);
            cur = n.parent;
        }
        return quickjs.JS_NewBool(false);
    }

    // Fallback: JS-level parentNode traversal (for doctype, processing instructions, etc.)
    var cur_val = qjs.JS_DupValue(c, args[0]);
    defer qjs.JS_FreeValue(c, cur_val);
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        if (cur_val.tag == this_val.tag and cur_val.u.ptr == this_val.u.ptr) {
            return quickjs.JS_NewBool(true);
        }
        const parent = qjs.JS_GetPropertyStr(c, cur_val, "parentNode");
        if (quickjs.JS_IsNull(parent) or quickjs.JS_IsUndefined(parent)) {
            qjs.JS_FreeValue(c, parent);
            break;
        }
        qjs.JS_FreeValue(c, cur_val);
        cur_val = parent;
    }
    return quickjs.JS_NewBool(false);
}

pub fn nodeNormalize(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();

    normalizeNodeWithMutations(node);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// Normalize with mutation recording for MutationObserver spec compliance.
fn normalizeNodeWithMutations(node: *lxb.lxb_dom_node_t) void {
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
            var text_len: usize = 0;
            _ = lxb_dom_node_text_content(ch, &text_len);

            if (text_len == 0) {
                const next_sib: ?*lxb.lxb_dom_node_t = ch.next;
                const prev_sib: ?*lxb.lxb_dom_node_t = ch.prev;
                lxb_dom_node_remove(ch);
                events.recordMutationChildList(node, null, ch, prev_sib, next_sib);
                child = next_sib;
                continue;
            }

            var next_node: ?*lxb.lxb_dom_node_t = ch.next;
            while (next_node) |next| {
                if (next.type != lxb.LXB_DOM_NODE_TYPE_TEXT) break;
                var next_len: usize = 0;
                const next_ptr = lxb_dom_node_text_content(next, &next_len);
                const after: ?*lxb.lxb_dom_node_t = next.next;
                if (next_len == 0 or next_ptr == null) {
                    const prev_s: ?*lxb.lxb_dom_node_t = next.prev;
                    lxb_dom_node_remove(next);
                    events.recordMutationChildList(node, null, next, prev_s, after);
                    next_node = after;
                    continue;
                }
                var cur_len: usize = 0;
                const cur_ptr = lxb_dom_node_text_content(ch, &cur_len);
                var merge_buf: [16384]u8 = undefined;
                const total = cur_len + next_len;
                if (total <= merge_buf.len and cur_ptr != null) {
                    // DOM §4.4.2 "normalize" step 3.1-3.3: each concatenation
                    // is BOTH a childList mutation (removal of the merged
                    // sibling from `node`) AND a characterData mutation on
                    // the surviving text node (its `data` changes from e.g.
                    // "foo" to "foobar"). Snapshot pre-merge text before
                    // text_content_set invalidates the lexbor pointer.
                    var old_cur_buf: [4096]u8 = undefined;
                    const oc_len = @min(cur_len, old_cur_buf.len);
                    @memcpy(old_cur_buf[0..oc_len], cur_ptr.?[0..oc_len]);
                    const old_cur = old_cur_buf[0..oc_len];

                    @memcpy(merge_buf[0..cur_len], cur_ptr.?[0..cur_len]);
                    @memcpy(merge_buf[cur_len..][0..next_len], next_ptr.?[0..next_len]);
                    _ = lxb_dom_node_text_content_set(ch, &merge_buf, total);
                    text_len = total;

                    // characterData record on the surviving text node.
                    events.recordMutationWithOldValue(ch, "characterData", null, null, null, old_cur);

                    const prev_s: ?*lxb.lxb_dom_node_t = next.prev;
                    lxb_dom_node_remove(next);
                    events.recordMutationChildList(node, null, next, prev_s, after);
                } else {
                    break;
                }
                next_node = after;
            }
            child = ch.next;
        } else {
            if (ch.first_child != null) normalizeNodeWithMutations(ch);
            child = ch.next;
        }
    }
}

/// Internal normalize helper that works directly on DOM nodes (no JS context needed).
/// Note: removed nodes are NOT destroyed because JS wrappers may still reference them.
/// The DOM spec requires that removed text nodes retain their original data.
pub fn normalizeNode(node: *lxb.lxb_dom_node_t) void {
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
            var text_len: usize = 0;
            _ = lxb_dom_node_text_content(ch, &text_len);

            if (text_len == 0) {
                const next_sib: ?*lxb.lxb_dom_node_t = ch.next;
                lxb_dom_node_remove(ch);
                // Don't destroy — JS may still reference this node
                child = next_sib;
                continue;
            }

            var next_node: ?*lxb.lxb_dom_node_t = ch.next;
            while (next_node) |next| {
                if (next.type != lxb.LXB_DOM_NODE_TYPE_TEXT) break;
                var next_len: usize = 0;
                const next_ptr = lxb_dom_node_text_content(next, &next_len);
                const after: ?*lxb.lxb_dom_node_t = next.next;
                if (next_len == 0 or next_ptr == null) {
                    lxb_dom_node_remove(next);
                    next_node = after;
                    continue;
                }
                // Re-read the current text content each iteration (may have changed)
                var cur_len: usize = 0;
                const cur_ptr = lxb_dom_node_text_content(ch, &cur_len);
                var merge_buf: [16384]u8 = undefined;
                const total = cur_len + next_len;
                if (total <= merge_buf.len and cur_ptr != null) {
                    @memcpy(merge_buf[0..cur_len], cur_ptr.?[0..cur_len]);
                    @memcpy(merge_buf[cur_len..][0..next_len], next_ptr.?[0..next_len]);
                    _ = lxb_dom_node_text_content_set(ch, &merge_buf, total);
                    text_len = total;
                    lxb_dom_node_remove(next);
                    // Don't destroy — JS may still reference this node
                } else {
                    break;
                }
                next_node = after;
            }
            child = ch.next;
        } else {
            if (ch.first_child != null) normalizeNode(ch);
            child = ch.next;
        }
    }
}

pub fn nodeIsEqualNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    // Handle null argument: spec says return false
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return quickjs.JS_NewBool(false);

    // Check if either node is JS-level only (no lexbor backing)
    const node_a_opt = api.getNode(c, this_val);
    const node_b_opt = api.getNode(c, args[0]);

    // If either node is JS-level (e.g. createHTMLDocument, createDocument)
    if (node_a_opt == null or node_b_opt == null) {
        // Compare nodeTypes
        const nt_a = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
        defer qjs.JS_FreeValue(c, nt_a);
        const nt_b = qjs.JS_GetPropertyStr(c, args[0], "nodeType");
        defer qjs.JS_FreeValue(c, nt_b);
        var nta: i32 = -1;
        var ntb: i32 = -2;
        _ = qjs.JS_ToInt32(c, &nta, nt_a);
        _ = qjs.JS_ToInt32(c, &ntb, nt_b);
        if (nta != ntb) return quickjs.JS_NewBool(false);

        // For documents (nodeType 9), compare children count and recursively
        if (nta == 9) {
            const ch_a = qjs.JS_GetPropertyStr(c, this_val, "childNodes");
            defer qjs.JS_FreeValue(c, ch_a);
            const ch_b = qjs.JS_GetPropertyStr(c, args[0], "childNodes");
            defer qjs.JS_FreeValue(c, ch_b);
            const la = qjs.JS_GetPropertyStr(c, ch_a, "length");
            defer qjs.JS_FreeValue(c, la);
            const lb = qjs.JS_GetPropertyStr(c, ch_b, "length");
            defer qjs.JS_FreeValue(c, lb);
            var len_a: i32 = 0;
            var len_b: i32 = 0;
            _ = qjs.JS_ToInt32(c, &len_a, la);
            _ = qjs.JS_ToInt32(c, &len_b, lb);
            if (len_a != len_b) return quickjs.JS_NewBool(false);
            // Compare each child recursively
            var i: u32 = 0;
            while (i < @as(u32, @intCast(len_a))) : (i += 1) {
                const ca = qjs.JS_GetPropertyUint32(c, ch_a, i);
                defer qjs.JS_FreeValue(c, ca);
                const cb = qjs.JS_GetPropertyUint32(c, ch_b, i);
                defer qjs.JS_FreeValue(c, cb);
                // Use native comparison if both have lexbor backing
                const na = api.getNode(c, ca);
                const nb = api.getNode(c, cb);
                if (na != null and nb != null) {
                    if (!nodesAreEqual(na.?, nb.?)) return quickjs.JS_NewBool(false);
                } else {
                    // JS-level child comparison by nodeType and key properties
                    const cnt_a = qjs.JS_GetPropertyStr(c, ca, "nodeType");
                    defer qjs.JS_FreeValue(c, cnt_a);
                    const cnt_b = qjs.JS_GetPropertyStr(c, cb, "nodeType");
                    defer qjs.JS_FreeValue(c, cnt_b);
                    var cta: i32 = -1;
                    var ctb: i32 = -2;
                    _ = qjs.JS_ToInt32(c, &cta, cnt_a);
                    _ = qjs.JS_ToInt32(c, &ctb, cnt_b);
                    if (cta != ctb) return quickjs.JS_NewBool(false);
                    if (!jsPropsEqual(c, ca, cb, "nodeName")) return quickjs.JS_NewBool(false);
                    if (!jsPropsEqual(c, ca, cb, "nodeValue")) return quickjs.JS_NewBool(false);
                }
            }
            return quickjs.JS_NewBool(true);
        }
        // Non-document JS nodes: compare nodeName and nodeValue
        if (!jsPropsEqual(c, this_val, args[0], "nodeName")) return quickjs.JS_NewBool(false);
        if (!jsPropsEqual(c, this_val, args[0], "nodeValue")) return quickjs.JS_NewBool(false);
        return quickjs.JS_NewBool(true);
    }

    const node_a = node_a_opt.?;
    const node_b = node_b_opt.?;
    if (!nodesAreEqual(node_a, node_b)) return quickjs.JS_NewBool(false);

    // Additional JS-level checks for elements: namespaceURI and prefix
    if (node_a.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        if (!jsPropsEqual(c, this_val, args[0], "namespaceURI")) return quickjs.JS_NewBool(false);
        if (!jsPropsEqual(c, this_val, args[0], "prefix")) return quickjs.JS_NewBool(false);
        // Compare attributes by namespace + localName using JS-level __attrNS map
        if (!attrsEqualByNS(c, this_val, args[0])) return quickjs.JS_NewBool(false);
    }
    return quickjs.JS_NewBool(true);
}

/// Compare attributes by namespace+localName+value using JS-level __attrNS map.
/// Implemented in JS for reliable string handling.
fn attrsEqualByNS(c: *qjs.JSContext, a: qjs.JSValue, b: qjs.JSValue) bool {
    // Use a JS-level comparison function for reliable property access
    const js_code =
        \\(function(a,b){
        \\  var nsA=a.__attrNS, nsB=b.__attrNS;
        \\  if(!nsA && !nsB) return true;
        \\  // Build map of namespace+localName+value for each element's attributes
        \\  function attrMap(el, nsMap) {
        \\    var m={};
        \\    for(var i=0;i<el.attributes.length;i++){
        \\      var attr=el.attributes[i];
        \\      var qn=attr.name;
        \\      var ns=null;
        \\      if(nsMap){ns=nsMap[qn]||null;if(!ns){for(var k in nsMap){if(k.toLowerCase()===qn.toLowerCase()){ns=nsMap[k];break;}}}}
        \\      var ln=qn.indexOf(':')>=0?qn.slice(qn.indexOf(':')+1):qn;
        \\      var key=(ns||'')+'|'+ln;
        \\      m[key]=attr.value;
        \\    }
        \\    return m;
        \\  }
        \\  var mA=attrMap(a,nsA), mB=attrMap(b,nsB);
        \\  var keysA=Object.keys(mA), keysB=Object.keys(mB);
        \\  if(keysA.length!==keysB.length) return false;
        \\  for(var i=0;i<keysA.length;i++){
        \\    if(mA[keysA[i]]!==mB[keysA[i]]) return false;
        \\  }
        \\  return true;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<attrNS>", qjs.JS_EVAL_TYPE_GLOBAL);
    defer qjs.JS_FreeValue(c, fn_val);
    if (quickjs.JS_IsException(fn_val)) return false;
    var fn_args = [2]qjs.JSValue{ qjs.JS_DupValue(c, a), qjs.JS_DupValue(c, b) };
    const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 2, &fn_args);
    qjs.JS_FreeValue(c, fn_args[0]);
    qjs.JS_FreeValue(c, fn_args[1]);
    defer qjs.JS_FreeValue(c, result);
    if (quickjs.JS_IsException(result)) return false;
    return qjs.JS_ToBool(c, result) != 0;
}

/// Compare a JS string property on two objects for equality (including both null/undefined).
fn jsPropsEqual(c: *qjs.JSContext, a: qjs.JSValue, b: qjs.JSValue, prop: [*:0]const u8) bool {
    const va = qjs.JS_GetPropertyStr(c, a, prop);
    defer qjs.JS_FreeValue(c, va);
    const vb = qjs.JS_GetPropertyStr(c, b, prop);
    defer qjs.JS_FreeValue(c, vb);
    // Both null/undefined = equal
    if ((quickjs.JS_IsNull(va) or quickjs.JS_IsUndefined(va)) and
        (quickjs.JS_IsNull(vb) or quickjs.JS_IsUndefined(vb)))
        return true;
    // One is null/undefined but not the other
    if (quickjs.JS_IsNull(va) or quickjs.JS_IsUndefined(va) or
        quickjs.JS_IsNull(vb) or quickjs.JS_IsUndefined(vb))
        return false;
    // Compare as strings
    const sa = api.jsStringToSlice(c, va) orelse return false;
    defer qjs.JS_FreeCString(c, sa.ptr);
    const sb = api.jsStringToSlice(c, vb) orelse return false;
    defer qjs.JS_FreeCString(c, sb.ptr);
    return std.mem.eql(u8, sa.ptr[0..sa.len], sb.ptr[0..sb.len]);
}

/// DOM Standard §4.4: Structural equality check for isEqualNode
pub fn nodesAreEqual(a: *lxb.lxb_dom_node_t, b: *lxb.lxb_dom_node_t) bool {
    // Same pointer = trivially equal
    if (a == b) return true;
    // nodeType must match
    if (a.type != b.type) return false;

    if (a.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const ea: *lxb.lxb_dom_element_t = @ptrCast(a);
        const eb: *lxb.lxb_dom_element_t = @ptrCast(b);
        // Compare localName
        var la_len: usize = 0;
        var lb_len: usize = 0;
        const la = lxb_dom_element_local_name(ea, &la_len);
        const lb = lxb_dom_element_local_name(eb, &lb_len);
        if (la_len != lb_len) return false;
        if (la != null and lb != null) {
            if (!std.mem.eql(u8, la.?[0..la_len], lb.?[0..lb_len])) return false;
        }
        // Attribute count must match
        {
            var count_a: usize = 0;
            var count_b: usize = 0;
            var aa: ?*anyopaque = lxb_dom_element_first_attribute_noi(ea);
            while (aa) |a_attr| {
                count_a += 1;
                aa = lxb_dom_element_next_attribute_noi(a_attr);
            }
            var ab: ?*anyopaque = lxb_dom_element_first_attribute_noi(eb);
            while (ab) |b_attr| {
                count_b += 1;
                ab = lxb_dom_element_next_attribute_noi(b_attr);
            }
            if (count_a != count_b) return false;
        }
        // Compare attribute values by local name
        // (namespace-aware comparison done separately in attrsEqualByNS)
        {
            var aa2: ?*anyopaque = lxb_dom_element_first_attribute_noi(ea);
            while (aa2) |a_attr| {
                var an_len2: usize = 0;
                const an2 = lxb_dom_attr_qualified_name(a_attr, &an_len2);
                var av_len2: usize = 0;
                const av2 = lxb_dom_attr_value_noi(a_attr, &av_len2);
                if (an2) |a_name| {
                    // Extract local name (after ':')
                    const a_qn = a_name[0..an_len2];
                    const a_local2 = if (std.mem.indexOfScalar(u8, a_qn, ':')) |colon| a_qn[colon + 1 ..] else a_qn;
                    var found2 = false;
                    var bb2: ?*anyopaque = lxb_dom_element_first_attribute_noi(eb);
                    while (bb2) |b_attr| {
                        var bn_len2: usize = 0;
                        if (lxb_dom_attr_qualified_name(b_attr, &bn_len2)) |b_name| {
                            const b_qn = b_name[0..bn_len2];
                            const b_local2 = if (std.mem.indexOfScalar(u8, b_qn, ':')) |colon| b_qn[colon + 1 ..] else b_qn;
                            if (std.mem.eql(u8, a_local2, b_local2)) {
                                var bv_len2: usize = 0;
                                const bv2 = lxb_dom_attr_value_noi(b_attr, &bv_len2);
                                if (av_len2 != bv_len2) return false;
                                if (av2 != null and bv2 != null) {
                                    if (!std.mem.eql(u8, av2.?[0..av_len2], bv2.?[0..bv_len2])) return false;
                                }
                                found2 = true;
                                break;
                            }
                        }
                        bb2 = lxb_dom_element_next_attribute_noi(b_attr);
                    }
                    if (!found2) return false;
                }
                aa2 = lxb_dom_element_next_attribute_noi(a_attr);
            }
        }
    } else if (a.type == lxb.LXB_DOM_NODE_TYPE_TEXT or a.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) {
        // Compare text content
        var ta_len: usize = 0;
        var tb_len: usize = 0;
        const ta = lxb_dom_node_text_content(a, &ta_len);
        const tb = lxb_dom_node_text_content(b, &tb_len);
        if (ta_len != tb_len) return false;
        if (ta != null and tb != null) {
            if (!std.mem.eql(u8, ta.?[0..ta_len], tb.?[0..tb_len])) return false;
        }
    }

    // Compare children recursively using DOM node wrapper
    const dom_node = @import("../dom/node.zig");
    const da = dom_node.DomNode{ .lxb_node = a };
    const db = dom_node.DomNode{ .lxb_node = b };
    var child_a = da.firstChild();
    var child_b = db.firstChild();
    while (child_a != null and child_b != null) {
        if (!nodesAreEqual(child_a.?.lxb_node, child_b.?.lxb_node)) return false;
        child_a = child_a.?.nextSibling();
        child_b = child_b.?.nextSibling();
    }
    return child_a == null and child_b == null;
}

/// JS-level compareDocumentPosition for when one or both nodes lack lexbor backing.
/// Walks JS parentNode chains to determine document position.
fn jsCompareDocumentPosition(c: *qjs.JSContext, a: qjs.JSValue, b: qjs.JSValue) qjs.JSValue {

    // Use a JS function to walk parentNode chains — handles mixed native/JS trees
    const js_code =
        \\(function(a,b){
        \\  if(a===b) return 0;
        \\  // Build ancestor chains
        \\  function chain(n){var c=[];var x=n;while(x){c.unshift(x);x=x.parentNode;}return c;}
        \\  var ca=chain(a), cb=chain(b);
        \\  // Check if roots are the same
        \\  if(ca[0]!==cb[0]) return 35;
        \\  // Find divergence point
        \\  var i=0;
        \\  while(i<ca.length&&i<cb.length&&ca[i]===cb[i]) i++;
        \\  // One is ancestor of the other
        \\  if(i===ca.length) return 20;
        \\  if(i===cb.length) return 10;
        \\  // Same parent: compare sibling order
        \\  var parent=ca[i-1];
        \\  var sa=ca[i], sb=cb[i];
        \\  // Walk children of parent to find order
        \\  var cn=parent.childNodes||[];
        \\  if(cn.length){
        \\    for(var j=0;j<cn.length;j++){
        \\      if(cn[j]===sa) return 4;
        \\      if(cn[j]===sb) return 2;
        \\    }
        \\  }
        \\  // Walk native siblings
        \\  var n=parent.firstChild;
        \\  while(n){if(n===sa)return 4;if(n===sb)return 2;n=n.nextSibling;}
        \\  return 35;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<cdp>", qjs.JS_EVAL_TYPE_GLOBAL);
    defer qjs.JS_FreeValue(c, fn_val);
    if (quickjs.JS_IsException(fn_val)) return qjs.JS_NewInt32(c, 35);
    var fn_args = [2]qjs.JSValue{ qjs.JS_DupValue(c, a), qjs.JS_DupValue(c, b) };
    const result = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 2, &fn_args);
    qjs.JS_FreeValue(c, fn_args[0]);
    qjs.JS_FreeValue(c, fn_args[1]);
    defer qjs.JS_FreeValue(c, result);
    if (quickjs.JS_IsException(result)) return qjs.JS_NewInt32(c, 35);
    var val: i32 = 0;
    _ = qjs.JS_ToInt32(c, &val, result);
    return qjs.JS_NewInt32(c, val);
}

pub fn nodeCompareDocumentPosition(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewInt32(c, 0);
    const args = argv orelse return qjs.JS_NewInt32(c, 0);
    const PRECEDING: i32 = 2;
    const FOLLOWING: i32 = 4;
    const CONTAINS: i32 = 8;
    const CONTAINED_BY: i32 = 16;

    // JS-level identity check first (handles JS-only nodes like new Document(), PI, etc.)
    if (this_val.tag == args[0].tag and this_val.u.ptr == args[0].u.ptr) return qjs.JS_NewInt32(c, 0);

    const node_a = api.getNode(c, this_val) orelse {
        // JS-only node (doctype, foreignDoc, PI, etc.) — use JS-level comparison
        return jsCompareDocumentPosition(c, this_val, args[0]);
    };
    const node_b_opt = api.getNode(c, args[0]);
    if (node_b_opt == null) {
        // B is JS-only — use JS-level comparison
        return jsCompareDocumentPosition(c, this_val, args[0]);
    }
    const node_b = node_b_opt.?;
    if (node_a == node_b) return qjs.JS_NewInt32(c, 0);

    // Check if b is descendant of a (a contains b)
    {
        var walk: ?*lxb.lxb_dom_node_t = node_b.parent;
        while (walk) |w| {
            if (w == node_a) return qjs.JS_NewInt32(c, CONTAINED_BY | FOLLOWING);
            walk = w.parent;
        }
    }
    // Check if a is descendant of b (b contains a)
    {
        var walk: ?*lxb.lxb_dom_node_t = node_a.parent;
        while (walk) |w| {
            if (w == node_b) return qjs.JS_NewInt32(c, CONTAINS | PRECEDING);
            walk = w.parent;
        }
    }

    // Find root of each node
    var root_a: *lxb.lxb_dom_node_t = node_a;
    while (root_a.parent) |p| root_a = p;
    var root_b: *lxb.lxb_dom_node_t = node_b;
    while (root_b.parent) |p| root_b = p;

    // Different lexbor trees → check if connected via JS parentNode chains
    if (root_a != root_b) return jsCompareDocumentPosition(c, this_val, args[0]);

    // Same tree, neither is ancestor: determine document order
    // Walk both ancestor chains to find common ancestor, then compare sibling order
    // Build ancestor chain for a
    var chain_a: [64]*lxb.lxb_dom_node_t = undefined;
    var depth_a: usize = 0;
    {
        var n: *lxb.lxb_dom_node_t = node_a;
        while (depth_a < 64) {
            chain_a[depth_a] = n;
            depth_a += 1;
            if (n.parent) |p| {
                n = p;
            } else break;
        }
    }
    var chain_b: [64]*lxb.lxb_dom_node_t = undefined;
    var depth_b: usize = 0;
    {
        var n: *lxb.lxb_dom_node_t = node_b;
        while (depth_b < 64) {
            chain_b[depth_b] = n;
            depth_b += 1;
            if (n.parent) |p| {
                n = p;
            } else break;
        }
    }

    // Find divergence point (walk from root, which is at the END of chain arrays)
    var ia = depth_a;
    var ib = depth_b;
    while (ia > 0 and ib > 0) {
        ia -= 1;
        ib -= 1;
        if (chain_a[ia] != chain_b[ib]) {
            // chain_a[ia] and chain_b[ib] are siblings under chain_a[ia+1] (== chain_b[ib+1])
            // Compare their order among siblings
            const sib_a = chain_a[ia];
            const sib_b = chain_b[ib];
            // Walk from sib_a forward to see if sib_b comes after
            var sibling: ?*lxb.lxb_dom_node_t = sib_a.next;
            while (sibling) |s| {
                if (s == sib_b) return qjs.JS_NewInt32(c, FOLLOWING);
                sibling = s.next;
            }
            return qjs.JS_NewInt32(c, PRECEDING);
        }
    }
    // Should not reach here if nodes aren't equal and one isn't ancestor
    return qjs.JS_NewInt32(c, FOLLOWING);
}

pub fn nodeGetRootNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Parse `options.composed` (defaults to false).
    var composed: bool = false;
    if (argc >= 1) {
        if (argv) |a| {
            const opts = a[0];
            if (!quickjs.JS_IsUndefined(opts) and !quickjs.JS_IsNull(opts)) {
                const cv = qjs.JS_GetPropertyStr(c, opts, "composed");
                defer qjs.JS_FreeValue(c, cv);
                if (!quickjs.JS_IsUndefined(cv)) {
                    composed = qjs.JS_ToBool(c, cv) != 0;
                }
            }
        }
    }

    const shadow_root = @import("shadow_root.zig");
    const node = api.getNode(c, this_val) orelse {
        // Document object: return itself (document is its own root)
        return qjs.JS_DupValue(c, this_val);
    };
    // Shadow-aware root walk.
    const root = shadow_root.shadowInclusiveRoot(node, composed);
    // If root is document node, return the JS document object.
    if (root.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        return qjs.JS_GetPropertyStr(c, global, "document");
    }
    // If root is a shadow fragment, return its JS ShadowRoot wrapper
    // (exposed on the host as __shadowWrapper) when possible.
    const sid = shadow_root.nodeScope(root);
    if (sid != 0) {
        if (shadow_root.shadowRootById(sid)) |sr| {
            const host_val = api.wrapNode(c, @ptrCast(sr.host));
            defer qjs.JS_FreeValue(c, host_val);
            const exposed = qjs.JS_GetPropertyStr(c, host_val, "shadowRoot");
            if (!quickjs.JS_IsNull(exposed) and !quickjs.JS_IsUndefined(exposed)) {
                return exposed;
            }
            qjs.JS_FreeValue(c, exposed);
            // closed mode — fall through to wrapping the fragment directly.
        }
    }
    // Otherwise return the root element/fragment.
    return api.wrapNode(c, root);
}

pub fn nodeGetOwnerDocument(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Determine which context to use based on the node's lexbor document owner.
    // When iframes exist, the passed-in ctx can differ from the top frame's ctx,
    // causing JS_GetGlobalObject to return a different wrapper (breaks === identity).
    // Use the top frame's ctx if the node belongs to the main document.
    var use_ctx = c;
    if (api.g_top_frame.ctx) |main_ctx| {
        if (api.getNode(c, this_val)) |node| {
            // Walk to the root's document
            var cur: *lxb.lxb_dom_node_t = node;
            while (cur.parent) |p| cur = p;
            // If the root is the main document, use main context for identity
            if (api.g_top_frame.document) |main_doc| {
                if (@intFromPtr(cur) == @intFromPtr(main_doc) or
                    @intFromPtr(cur.owner_document) == @intFromPtr(main_doc))
                {
                    use_ctx = main_ctx;
                }
            }
        }
    }
    const global = qjs.JS_GetGlobalObject(use_ctx);
    defer qjs.JS_FreeValue(use_ctx, global);
    return qjs.JS_GetPropertyStr(use_ctx, global, "document");
}

pub fn nodeGetIsConnected(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    // Shadow-inclusive connectivity: walk up, jump through shadow boundaries.
    const shadow_root = @import("shadow_root.zig");
    return quickjs.JS_NewBool(shadow_root.isShadowInclusiveConnected(node));
}

pub fn elementGetNodeType(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Check for nodeType override (e.g. CDATASection backed by native text node)
    const override = qjs.JS_GetPropertyStr(c, this_val, "__nodeTypeOverride");
    if (!quickjs.JS_IsUndefined(override)) {
        return override;
    }
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    return switch (node.type) {
        lxb.LXB_DOM_NODE_TYPE_ELEMENT => qjs.JS_NewInt32(c, 1),
        lxb.LXB_DOM_NODE_TYPE_TEXT => qjs.JS_NewInt32(c, 3),
        lxb.LXB_DOM_NODE_TYPE_COMMENT => qjs.JS_NewInt32(c, 8),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT => qjs.JS_NewInt32(c, 9),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => qjs.JS_NewInt32(c, 11),
        else => qjs.JS_NewInt32(c, 1),
    };
}

pub fn elementGetNodeName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Check for nodeName override (e.g. CDATASection backed by native text node)
    const override = qjs.JS_GetPropertyStr(c, this_val, "__nodeNameOverride");
    if (!quickjs.JS_IsUndefined(override) and !quickjs.JS_IsNull(override)) {
        return override;
    }
    qjs.JS_FreeValue(c, override);
    const node = api.getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT) return qjs.JS_NewStringLen(c, "#text", 5);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) return qjs.JS_NewStringLen(c, "#comment", 8);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) return qjs.JS_NewStringLen(c, "#document", 9);
    // For elements, return tagName (uppercase)
    return elementGetTagName(ctx, this_val, argc, argv);
}

/// Walk a DOM subtree and upgrade any custom elements (elements with '-' in tag name).
pub fn upgradeSubtreeCustomElements(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) void {
    // Check if this node is an element with a custom tag name (contains '-')
    if (node.*.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var name_len: usize = 0;
        const name_ptr: ?[*]const u8 = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len > 0) {
            const tag = name_ptr.?[0..name_len];
            // Custom elements must contain a hyphen
            if (std.mem.indexOfScalar(u8, tag, '-') != null) {
                const js_elem = api.wrapNode(ctx, node);
                api.upgradeCustomElement(ctx, js_elem, tag.ptr, tag.len);
                qjs.JS_FreeValue(ctx, js_elem);
            }
        }
    }

    // Recurse into children
    var child: ?*lxb.lxb_dom_node_t = node.*.first_child;
    while (child) |ch| {
        upgradeSubtreeCustomElements(ctx, ch);
        child = ch.*.next;
    }
}

// ── Mutation suppression for replaceChildren batching ───────────────

pub fn jsBeginMutSuppress(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    events.beginSuppressChildList(node);
    return quickjs.JS_UNDEFINED();
}

pub fn jsEndMutSuppress(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    events.endSuppressChildList();
    return quickjs.JS_UNDEFINED();
}
