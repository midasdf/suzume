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

    // Check namespace: only uppercase for HTML namespace elements
    const ns_val = qjs.JS_GetPropertyStr(c, this_val, "namespaceURI");
    var is_html = true;
    if (quickjs.JS_IsNull(ns_val)) {
        is_html = false;
    } else if (!quickjs.JS_IsUndefined(ns_val)) {
        if (api.jsStringToSlice(c, ns_val)) |ns_s| {
            defer qjs.JS_FreeCString(c, ns_s.ptr);
            if (!std.mem.eql(u8, ns_s.ptr[0..ns_s.len], "http://www.w3.org/1999/xhtml")) is_html = false;
        }
    }
    qjs.JS_FreeValue(c, ns_val);

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
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
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

    // DOM spec: setting textContent to null/undefined removes all children
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
        // Remove all child nodes (don't create empty text node)
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
        // Clear JS-only children (PI, etc.)
        _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
        events.recordMutation(node, "childList", null, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    }
    const s = api.jsStringToSlice(c, args[0]) orelse {
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
        _ = qjs.JS_SetPropertyStr(c, this_val, "__jsChildren", qjs.JS_NewArray(c));
        events.recordMutation(node, "childList", null, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    // DOM spec: 1. Capture first removed child for MutationObserver
    const removed_child = node.first_child;
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
    if (added_child != null or removed_child != null) {
        events.recordMutation(node, "childList", added_child, removed_child, null);
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
        if (js_nt == 10 and parent.?.type != lxb.LXB_DOM_NODE_TYPE_DOCUMENT)
            return api.throwDOMException(c, "HierarchyRequestError", "DocumentType can only be a child of a Document.");
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
    events.recordMutationChildList(parent.?, child, null, ins_prev, null);
    api.setDomDirty();
    // Dynamic script execution: if a <script> is appended, fetch and execute it
    api.maybeExecuteDynamicScriptPublic(c, child, args[0]);
    // Upgrade custom elements in the inserted subtree
    upgradeSubtreeCustomElements(c, child);
    return qjs.JS_DupValue(c, args[0]);
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

    // JS-level node — delegate to appendJsNode
    if (new_node_opt == null)
        return appendJsNode(c, this_val, args[0]);

    const new_node = new_node_opt.?;
    // DOM spec step 7: if node is child (ref), set ref to node's next sibling
    var effective_ref: ?*lxb.lxb_dom_node_t = null;
    var ref_is_null = quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]);
    if (!ref_is_null) {
        const ref_node = api.getNode(c, args[1]).?;
        if (ref_node == new_node) {
            // Inserting before itself — use next sibling as reference
            effective_ref = ref_node.next;
            ref_is_null = (effective_ref == null);
        } else {
            effective_ref = ref_node;
        }
    }
    // Remove from old parent if needed (must happen BEFORE sibling calculation
    // so same-parent moves don't include the moved node in prev/next)
    const old_parent = new_node.parent;
    if (old_parent != null) {
        const rem_prev = new_node.prev;
        const rem_next = new_node.next;
        lxb_dom_node_remove(new_node);
        events.recordMutationChildList(old_parent.?, null, new_node, rem_prev, rem_next);
    }
    // Capture siblings at insertion point AFTER detach
    const ins_prev = if (!ref_is_null) effective_ref.?.prev else lxb_dom_node_last_child_noi(parent.?);
    const ins_next = if (!ref_is_null) effective_ref else null;
    if (ref_is_null) {
        lxb_dom_node_insert_child(parent.?, new_node);
    } else {
        lxb_dom_node_insert_before(effective_ref.?, new_node);
    }
    events.recordMutationChildList(parent.?, new_node, null, ins_prev, ins_next);
    api.setDomDirty();
    api.maybeExecuteDynamicScriptPublic(c, new_node, args[0]);
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

    // JS-level node — cannot insert into lexbor tree
    if (new_node_opt == null)
        return appendJsNode(c, this_val, args[0]);

    const new_node = new_node_opt.?;
    // DOM spec: if new_node is the same as old_node, this is a no-op
    if (new_node == old_node) {
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
    // Dynamic script execution and custom element upgrade
    api.maybeExecuteDynamicScriptPublic(c, new_node, args[0]);
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

pub fn elementCloneNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();

    // Determine deep flag (default: shallow clone per DOM spec)
    var deep = false;
    if (argc > 0) {
        if (argv) |args| {
            deep = qjs.JS_ToBool(c, args[0]) > 0;
        }
    }

    // Check if this is a DocumentFragment (JS nodeType override = 11)
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

    // Create new element with same tag
    const new_elem = lxb_dom_document_create_element(doc, tag_ptr.?, tag_len, null) orelse return quickjs.JS_NULL();
    const new_node: *lxb.lxb_dom_node_t = @ptrCast(new_elem);

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
    // Preserve namespace-related JS properties from source
    const ns_val = qjs.JS_GetPropertyStr(c, this_val, "namespaceURI");
    if (!quickjs.JS_IsUndefined(ns_val)) {
        _ = qjs.JS_SetPropertyStr(c, result, "namespaceURI", ns_val);
    } else {
        qjs.JS_FreeValue(c, ns_val);
    }
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

    normalizeNode(node);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// Internal normalize helper that works directly on DOM nodes (no JS context needed).
pub fn normalizeNode(node: *lxb.lxb_dom_node_t) void {
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
            var text_len: usize = 0;
            _ = lxb_dom_node_text_content(ch, &text_len);

            if (text_len == 0) {
                const next_sib: ?*lxb.lxb_dom_node_t = ch.next;
                lxb_dom_node_remove(ch);
                _ = lxb_dom_node_destroy(ch);
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
                    _ = lxb_dom_node_destroy(next);
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
                    _ = lxb_dom_node_destroy(next);
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

    // For elements, also compare namespaceURI and prefix via JS properties
    const node_a = api.getNode(c, this_val) orelse blk: {
        const doc = api.getDocument(c) orelse return quickjs.JS_NewBool(false);
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    const node_b = api.getNode(c, args[0]) orelse blk: {
        const doc = api.getDocument(c) orelse return quickjs.JS_NewBool(false);
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    if (!nodesAreEqual(node_a, node_b)) return quickjs.JS_NewBool(false);

    // Additional JS-level checks for elements: namespaceURI and prefix
    if (node_a.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        if (!jsPropsEqual(c, this_val, args[0], "namespaceURI")) return quickjs.JS_NewBool(false);
        if (!jsPropsEqual(c, this_val, args[0], "prefix")) return quickjs.JS_NewBool(false);
    }
    return quickjs.JS_NewBool(true);
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
        // Compare attributes: count and values (case-sensitive, namespace-aware)
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
            // Verify each attribute of a exists with same qualified name and value in b
            aa = lxb_dom_element_first_attribute_noi(ea);
            while (aa) |a_attr| {
                var an_len: usize = 0;
                const an = lxb_dom_attr_qualified_name(a_attr, &an_len);
                var av_len: usize = 0;
                const av = lxb_dom_attr_value_noi(a_attr, &av_len);
                if (an) |a_name| {
                    const a_qname = a_name[0..an_len];
                    // Find matching attribute in b by exact (case-sensitive) qualified name
                    var found = false;
                    var bb: ?*anyopaque = lxb_dom_element_first_attribute_noi(eb);
                    while (bb) |b_attr| {
                        var bn_len: usize = 0;
                        if (lxb_dom_attr_qualified_name(b_attr, &bn_len)) |b_name| {
                            if (std.mem.eql(u8, a_qname, b_name[0..bn_len])) {
                                // Name matches, compare values
                                var bv_len: usize = 0;
                                const bv = lxb_dom_attr_value_noi(b_attr, &bv_len);
                                if (av_len != bv_len) return false;
                                if (av != null and bv != null) {
                                    if (!std.mem.eql(u8, av.?[0..av_len], bv.?[0..bv_len])) return false;
                                }
                                found = true;
                                break;
                            }
                        }
                        bb = lxb_dom_element_next_attribute_noi(b_attr);
                    }
                    if (!found) return false;
                }
                aa = lxb_dom_element_next_attribute_noi(a_attr);
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

pub fn nodeCompareDocumentPosition(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewInt32(c, 0);
    const args = argv orelse return qjs.JS_NewInt32(c, 0);
    const DISCONNECTED: i32 = 1;
    const PRECEDING: i32 = 2;
    const FOLLOWING: i32 = 4;
    const CONTAINS: i32 = 8;
    const CONTAINED_BY: i32 = 16;
    const IMPL_SPECIFIC: i32 = 32;

    // JS-level identity check first (handles JS-only nodes like new Document(), PI, etc.)
    if (this_val.tag == args[0].tag and this_val.u.ptr == args[0].u.ptr) return qjs.JS_NewInt32(c, 0);

    const node_a = api.getNode(c, this_val) orelse return qjs.JS_NewInt32(c, DISCONNECTED | IMPL_SPECIFIC | PRECEDING);
    const node_b = api.getNode(c, args[0]) orelse return qjs.JS_NewInt32(c, DISCONNECTED | IMPL_SPECIFIC | PRECEDING);
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

    // Different trees → disconnected
    if (root_a != root_b) return qjs.JS_NewInt32(c, DISCONNECTED | IMPL_SPECIFIC | FOLLOWING);

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
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse {
        // Document object: return itself (document is its own root)
        return qjs.JS_DupValue(c, this_val);
    };
    // Walk up to root (document node)
    var current: *lxb.lxb_dom_node_t = node;
    while (current.parent) |p| {
        current = p;
    }
    // If root is document node, return the JS document object
    if (current.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        const global = qjs.JS_GetGlobalObject(c);
        defer qjs.JS_FreeValue(c, global);
        return qjs.JS_GetPropertyStr(c, global, "document");
    }
    // Otherwise return the root element
    return api.wrapNode(c, current);
}

pub fn nodeGetOwnerDocument(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Return the global document object
    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);
    return qjs.JS_GetPropertyStr(c, global, "document");
}

pub fn nodeGetIsConnected(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    // Walk up to root — if root is document, node is connected
    var current: *lxb.lxb_dom_node_t = node;
    while (current.parent) |p| {
        current = p;
    }
    return quickjs.JS_NewBool(current.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT);
}

pub fn elementGetNodeType(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
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
