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
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
extern fn lxb_dom_element_first_attribute_noi(element: *lxb.lxb_dom_element_t) ?*anyopaque;
extern fn lxb_dom_element_next_attribute_noi(attr: *anyopaque) ?*anyopaque;
extern fn lxb_dom_attr_qualified_name(attr: *anyopaque, len: *usize) ?[*]const u8;
extern fn lxb_dom_attr_value_noi(attr: *anyopaque, len: *usize) ?[*]const u8;
extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, val_len: usize) ?*anyopaque;
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

    // Check namespace: only uppercase for HTML namespace elements
    // null namespace = NOT HTML; undefined = HTML (default for createElement in HTML doc)
    const ns_val = qjs.JS_GetPropertyStr(c, this_val, "namespaceURI");
    var is_html = true;
    if (quickjs.JS_IsNull(ns_val)) {
        is_html = false; // null namespace = not HTML
    } else if (!quickjs.JS_IsUndefined(ns_val)) {
        if (api.jsStringToSlice(c, ns_val)) |ns_s| {
            defer qjs.JS_FreeCString(c, ns_s.ptr);
            if (!std.mem.eql(u8, ns_s.ptr[0..ns_s.len], "http://www.w3.org/1999/xhtml")) is_html = false;
        }
    }
    qjs.JS_FreeValue(c, ns_val);

    if (!is_html) return qjs.JS_NewStringLen(c, name_ptr.?, len);

    // HTML namespace: convert to uppercase per DOM spec
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
    // DOM spec: setting textContent to null/undefined removes all children
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
        // Remove all child nodes (don't create empty text node)
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
        events.recordMutation(node, "childList", null, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    }
    const s = api.jsStringToSlice(c, args[0]) orelse {
        _ = lxb_dom_node_text_content_set(node, "", 0);
        events.recordMutation(node, "childList", null, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);
    // DOM spec: empty string → remove all children (no text node)
    if (s.len == 0) {
        while (node.first_child) |child| {
            lxb_dom_node_remove(child);
        }
    } else {
        // Use Lexbor for non-empty strings (handles internal cleanup)
        _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    }
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
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, api.wrapNode(c, ch));
        idx += 1;
        child = ch.next;
    }
    return arr;
}

/// Check if `node` is an ancestor of `target` (or the same node).
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
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");
    const child = api.getNode(c, args[0]) orelse
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'appendChild': parameter 1 is not of type 'Node'.");
    // DOM spec step 1: parent must be able to have children
    if (!canHaveChildren(parent))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
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
    if (argc < 2) return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': 2 arguments required.");
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // DOM spec: TypeError if first arg is not a Node
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");
    const new_node = api.getNode(c, args[0]) orelse
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'insertBefore': parameter 1 is not of type 'Node'.");

    // DOM spec pre-insertion validation step 1: parent must be Document, DocumentFragment, or Element
    if (!canHaveChildren(parent))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");

    // DOM spec step 2: node must not be an ancestor of parent
    if (isAncestorOrSelf(new_node, parent))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");

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
        if (ref_check.?.parent != parent)
            return api.throwDOMException(c, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
    }

    // DOM spec step 4: node must be DocumentFragment, DocumentType, Element, Text, ProcessingInstruction, or Comment
    if (!isInsertableNodeType(new_node))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type cannot be inserted.");

    // Remove from old parent if needed
    if (new_node.parent != null) lxb_dom_node_remove(new_node);
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) {
        lxb_dom_node_insert_child(parent, new_node);
    } else {
        const ref_node = api.getNode(c, args[1]).?;
        lxb_dom_node_insert_before(ref_node, new_node);
    }
    const parent_node = api.getNode(c, this_val) orelse new_node;
    events.recordMutation(parent_node, "childList", new_node, null, null);
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
    const parent = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    // DOM spec: TypeError if node is null
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 1 is not of type 'Node'.");
    const new_node = api.getNode(c, args[0]) orelse
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 1 is not of type 'Node'.");
    // DOM spec step 1: parent must be able to have children
    if (!canHaveChildren(parent))
        return api.throwDOMException(c, "HierarchyRequestError", "This node type does not support this method.");
    // DOM spec step 2: node must not be an ancestor of parent
    if (isAncestorOrSelf(new_node, parent))
        return api.throwDOMException(c, "HierarchyRequestError", "The new child element contains the parent.");
    // DOM spec: TypeError if child is null
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1]))
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': parameter 2 is not of type 'Node'.");
    const old_node = api.getNode(c, args[1]) orelse
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    if (old_node.parent != parent)
        return api.throwDOMException(c, "NotFoundError", "The node to be replaced is not a child of this node.");
    // DOM spec: if new_node is the same as old_node, this is a no-op
    if (new_node == old_node) {
        return qjs.JS_DupValue(c, args[1]);
    }
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
    // Handle null argument: spec says return false
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0]))
        return quickjs.JS_NewBool(false);
    const node_a = api.getNode(c, this_val) orelse blk: {
        // Fallback for document object
        const doc = api.getDocument(c) orelse return quickjs.JS_NewBool(false);
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
    const node_b = api.getNode(c, args[0]) orelse blk: {
        const doc = api.getDocument(c) orelse return quickjs.JS_NewBool(false);
        break :blk @as(*lxb.lxb_dom_node_t, @ptrCast(@alignCast(doc)));
    };
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
        // Compare attributes: count and values
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
            // Verify each attribute of a exists with same value in b
            aa = lxb_dom_element_first_attribute_noi(ea);
            while (aa) |a_attr| {
                var an_len: usize = 0;
                const an = lxb_dom_attr_qualified_name(a_attr, &an_len);
                var av_len: usize = 0;
                const av = lxb_dom_attr_value_noi(a_attr, &av_len);
                if (an) |name| {
                    var bv_len: usize = 0;
                    const bv = lxb_dom_element_get_attribute(eb, name, an_len, &bv_len);
                    if (bv == null) return false;
                    if (av_len != bv_len) return false;
                    if (av != null and bv != null) {
                        if (!std.mem.eql(u8, av.?[0..av_len], bv.?[0..bv_len])) return false;
                    }
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
            if (n.parent) |p| { n = p; } else break;
        }
    }
    var chain_b: [64]*lxb.lxb_dom_node_t = undefined;
    var depth_b: usize = 0;
    {
        var n: *lxb.lxb_dom_node_t = node_b;
        while (depth_b < 64) {
            chain_b[depth_b] = n;
            depth_b += 1;
            if (n.parent) |p| { n = p; } else break;
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
