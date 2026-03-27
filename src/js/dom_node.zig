const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;

// Lexbor HTML serialization
const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;

// Lexbor HTML fragment parsing
extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;

// Lexbor attribute access (needed by nodesAreEqual)
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;

// ── Node prototype functions ─────────────────────────────────────────

pub fn elementGetTagName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = api.getElement(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &len);
    if (name_ptr == null or len == 0) return quickjs.JS_NULL();

    // Convert to uppercase (DOM spec: tagName is uppercase for HTML elements)
    var stack_buf: [256]u8 = undefined;
    const use_heap = len > stack_buf.len;
    const buf = if (use_heap)
        (std.heap.c_allocator.alloc(u8, len) catch return quickjs.JS_UNDEFINED())
    else
        stack_buf[0..len];
    defer if (use_heap) std.heap.c_allocator.free(buf);
    for (0..len) |i| {
        const ch = name_ptr.?[i];
        buf[i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
    }
    return qjs.JS_NewStringLen(c, buf.ptr, len);
}

pub fn elementGetLocalName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = api.getElement(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &len);
    if (name_ptr == null or len == 0) return quickjs.JS_NULL();
    // localName is lowercase (as stored by lexbor HTML parser)
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
    // DOM spec: setting textContent to null is treated as empty string
    const s = api.jsStringToSlice(c, args[0]) orelse {
        _ = lxb_dom_node_text_content_set(node, "", 0);
        events.recordMutation(node, "childList", null, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    events.recordMutation(node, "childList", null, null, null);
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
    return api.wrapNode(c, p);
}

pub fn elementGetFirstChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
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
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
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
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, api.wrapNode(c, ch));
        idx += 1;
        child = ch.next;
    }
    return arr;
}

/// Check if `node` is an ancestor of `target` (or the same node).
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
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const child = api.getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    // DOM spec step 2: If node is a host-including inclusive ancestor of parent, throw
    if (isAncestorOrSelf(child, parent))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    // DOM spec: remove from old parent first
    if (child.parent != null) lxb_dom_node_remove(child);
    lxb_dom_node_insert_child(parent, child);
    events.recordMutation(parent, "childList", child, null, null);
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
    const child = api.getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    // Verify child is actually a child of parent (DOM spec: NotFoundError)
    if (child.parent != parent) return api.throwDOMException(c, "NotFoundError", "The node to be removed is not a child of this node.");
    lxb_dom_node_remove(child);
    events.recordMutation(parent, "childList", null, child, null);
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
    if (argc < 2) return api.throwDOMException(c, "TypeError", "Failed to execute 'insertBefore': 2 arguments required.");
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = api.getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    // DOM spec step 2: If node is a host-including inclusive ancestor of parent, throw
    if (isAncestorOrSelf(new_node, parent))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    // Remove from old parent if needed
    if (new_node.parent != null) lxb_dom_node_remove(new_node);
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) {
        // If reference is null, act like appendChild
        lxb_dom_node_insert_child(parent, new_node);
    } else {
        const ref_node = api.getNode(c, args[1]) orelse
            return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
        // Verify ref_node is a child of parent
        if (ref_node.parent != parent)
            return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
        lxb_dom_node_insert_before(ref_node, new_node);
    }
    const parent_node = api.getNode(c, this_val) orelse new_node;
    events.recordMutation(parent_node, "childList", new_node, null, null);
    api.setDomDirty();
    // Dynamic script execution: if a <script> is inserted, fetch and execute it
    api.maybeExecuteDynamicScriptPublic(c, new_node, args[0]);
    // Upgrade custom elements in the inserted subtree
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
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const new_node = api.getNode(c, args[0]) orelse return quickjs.JS_NULL();
    if (isAncestorOrSelf(new_node, parent))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    const old_node = api.getNode(c, args[1]) orelse
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    if (old_node.parent != parent)
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    if (new_node.parent != null) lxb_dom_node_remove(new_node);
    lxb_dom_node_insert_before(old_node, new_node);
    lxb_dom_node_remove(old_node);
    api.setDomDirty();
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

    // Element nodes: clone by serializing and re-parsing
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();

    var stack_buf: [8192]u8 = undefined;
    var accum = api.serialize.SerializeAccum.init(&stack_buf);
    defer accum.deinit();

    if (deep) {
        _ = lxb_html_serialize_tree_cb(node, &api.serialize.serializeCallback, @ptrCast(&accum));
    } else {
        _ = lxb_html_serialize_cb(node, &api.serialize.serializeCallback, @ptrCast(&accum));
    }

    const html = accum.result();
    if (html.len == 0) return quickjs.JS_NULL();

    const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const frag = lxb_html_document_parse_fragment(doc, elem, html.ptr, html.len) orelse return quickjs.JS_NULL();

    // Get the first child from fragment (the cloned element)
    if (frag.first_child) |cloned| {
        lxb_dom_node_remove(cloned);
        _ = lxb_dom_node_destroy(frag);
        return api.wrapNode(c, cloned);
    }
    _ = lxb_dom_node_destroy(frag);
    return quickjs.JS_NULL();
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
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    // Insert all args before this node, then remove this node
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (api.getNode(c, arg)) |new_node| {
            if (new_node.parent != null) lxb_dom_node_remove(new_node);
            lxb_dom_node_insert_before(node, new_node);
        } else {
            if (api.jsStringToSlice(c, arg)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const doc = api.getDocument(c) orelse continue;
                const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
                lxb_dom_node_insert_before(node, text);
            }
        }
    }
    lxb_dom_node_remove(node);
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
    // DOM spec: viable next sibling = node's next sibling not in args
    // For simplicity: save next sibling before any mutations
    const next_sib = node.next;
    // Support multiple args, each can be Node or String
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (api.getNode(c, arg)) |new_node| {
            if (new_node.parent != null) lxb_dom_node_remove(new_node);
            // If node was removed (self-reference), use saved next_sib
            if (node.parent == null) {
                if (next_sib) |ns| {
                    lxb_dom_node_insert_before(ns, new_node);
                } else {
                    lxb_dom_node_insert_child(parent, new_node);
                }
            } else {
                lxb_dom_node_insert_before(node, new_node);
            }
        } else {
            if (api.jsStringToSlice(c, arg)) |s| {
                defer qjs.JS_FreeCString(c, s.ptr);
                const doc = api.getDocument(c) orelse continue;
                const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
                if (node.parent == null) {
                    if (next_sib) |ns| lxb_dom_node_insert_before(ns, text) else lxb_dom_node_insert_child(parent, text);
                } else {
                    lxb_dom_node_insert_before(node, text);
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
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const other = api.getNode(c, args[0]) orelse return quickjs.JS_NewBool(false);

    // Walk up from other to see if we find node
    var cur: ?*lxb.lxb_dom_node_t = other;
    while (cur) |n| {
        if (n == node) return quickjs.JS_NewBool(true);
        cur = n.parent;
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
            const text_ptr = lxb_dom_node_text_content(ch, &text_len);

            if (text_len == 0 or text_ptr == null) {
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
                var merge_buf: [16384]u8 = undefined;
                const total = text_len + next_len;
                if (total <= merge_buf.len) {
                    @memcpy(merge_buf[0..text_len], text_ptr.?[0..text_len]);
                    @memcpy(merge_buf[text_len..][0..next_len], next_ptr.?[0..next_len]);
                    _ = lxb_dom_node_text_content_set(ch, &merge_buf, total);
                    text_len = total;
                    lxb_dom_node_remove(next);
                    _ = lxb_dom_node_destroy(next);
                } else {
                    // Buffer too small — stop merging this run to avoid data loss
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
    const node_a = api.getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const node_b = api.getNode(c, args[0]) orelse return quickjs.JS_NewBool(false);
    return quickjs.JS_NewBool(nodesAreEqual(node_a, node_b));
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
        // Compare number of attributes (simplified — count via walking)
        var attr_count_a: usize = 0;
        var attr_count_b: usize = 0;
        {
            // Count attributes of a
            const style_a_ptr = lxb_dom_element_get_attribute(ea, "id", 2, &la_len);
            _ = style_a_ptr;
            // Simplified: use attribute count from lexbor (not directly available)
            // For now, skip attribute count check (partial isEqualNode)
            _ = &attr_count_a;
            _ = &attr_count_b;
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
    const node_a = api.getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
    const node_b = api.getNode(c, args[0]) orelse return qjs.JS_NewInt32(c, 1);
    if (node_a == node_b) return qjs.JS_NewInt32(c, 0);
    // Simplified: check if b is descendant of a, or vice versa
    var walk: ?*lxb.lxb_dom_node_t = node_b;
    while (walk) |w| {
        if (w == node_a) return qjs.JS_NewInt32(c, 16 | 4); // CONTAINS | FOLLOWING
        walk = w.parent;
    }
    walk = node_a;
    while (walk) |w| {
        if (w == node_b) return qjs.JS_NewInt32(c, 8 | 2); // CONTAINED_BY | PRECEDING
        walk = w.parent;
    }
    return qjs.JS_NewInt32(c, 1); // DISCONNECTED
}

pub fn nodeGetRootNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
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
