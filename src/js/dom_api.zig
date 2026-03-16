const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;

// ── External Lexbor functions (avoid cImport issues) ────────────────
extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_remove_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) lxb.lxb_status_t;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;

// ── Class IDs (set during init) ─────────────────────────────────────
pub var element_class_id: qjs.JSClassID = 0;
pub var text_class_id: qjs.JSClassID = 0;

// ── Global state ────────────────────────────────────────────────────
/// The lxb_dom_document_t pointer (cast to *anyopaque because of cImport limitations).
/// Set once during registerDomApis.
var g_document: ?*anyopaque = null;

/// DOM dirty flag — set when JS mutates the DOM tree. Checked by the main loop.
pub var dom_dirty: bool = false;

fn setDomDirty() void {
    dom_dirty = true;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Wrap a lxb_dom_node_t pointer into a JS Element object.
fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const node_type = node.type;
    if (node_type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        return wrapElement(ctx, node);
    } else if (node_type == lxb.LXB_DOM_NODE_TYPE_TEXT) {
        return wrapText(ctx, node);
    }
    // For other node types, return a generic Element wrapper
    return wrapElement(ctx, node);
}

fn wrapElement(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(element_class_id));
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    return obj;
}

fn wrapText(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(text_class_id));
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    return obj;
}

/// Get the lxb_dom_node_t* from a JS Element/Text value.
/// Tries both element and text class IDs.
fn getNode(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    // Try element class first
    const ptr1 = qjs.JS_GetOpaque2(ctx, val, element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    // Try text class
    const ptr2 = qjs.JS_GetOpaque2(ctx, val, text_class_id);
    if (ptr2) |p| return @ptrCast(@alignCast(p));
    return null;
}

fn getElement(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_element_t {
    const node = getNode(ctx, val) orelse return null;
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    return @ptrCast(node);
}

pub fn jsStringToSlice(ctx: *qjs.JSContext, val: qjs.JSValue) ?struct { ptr: [*]const u8, len: usize } {
    var len: usize = 0;
    const cstr = qjs.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return null;
    return .{ .ptr = cstr, .len = len };
}

// ── Element prototype methods ───────────────────────────────────────

fn elementGetTagName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
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

fn elementGetId(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
    if (val == null or val_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

fn elementSetId(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "id", 2, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementGetClassName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
    if (val == null or val_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

fn elementSetClassName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "class", 5, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementGetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
}

fn elementSetTextContent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementGetParentNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p = node.parent orelse return quickjs.JS_NULL();
    return wrapNode(c, p);
}

fn elementGetFirstChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const child = node.first_child orelse return quickjs.JS_NULL();
    return wrapNode(c, child);
}

fn elementGetLastChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const child = lxb_dom_node_last_child_noi(node) orelse return quickjs.JS_NULL();
    return wrapNode(c, child);
}

fn elementGetNextSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = node.next orelse return quickjs.JS_NULL();
    return wrapNode(c, sib);
}

fn elementGetPreviousSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const sib = lxb_dom_node_prev_noi(node) orelse return quickjs.JS_NULL();
    return wrapNode(c, sib);
}

fn elementGetChildren(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            _ = qjs.JS_SetPropertyUint32(c, arr, idx, wrapNode(c, ch));
            idx += 1;
        }
        child = ch.next;
    }
    return arr;
}

fn elementGetChildNodes(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, wrapNode(c, ch));
        idx += 1;
        child = ch.next;
    }
    return arr;
}

fn elementGetAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, s.ptr, s.len, &val_len);
    if (val == null) return quickjs.JS_NULL();
    return qjs.JS_NewStringLen(c, val.?, val_len); // empty string when val_len == 0
}

fn elementSetAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, name.ptr);
    const val = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);
    _ = lxb_dom_element_set_attribute(elem, name.ptr, name.len, val.ptr, val.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementRemoveAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, name.ptr);
    _ = lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementAppendChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const child = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_child(parent, child);
    setDomDirty();
    return qjs.JS_DupValue(c, args[0]);
}

fn elementRemoveChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const child = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    // Verify child is actually a child of parent (DOM spec: NotFoundError)
    if (child.parent != parent) return quickjs.JS_UNDEFINED();
    lxb_dom_node_remove(child);
    setDomDirty();
    return qjs.JS_DupValue(c, args[0]);
}

fn elementInsertBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    _ = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) {
        // If reference is null, act like appendChild
        const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_child(parent, new_node);
    } else {
        const ref_node = getNode(c, args[1]) orelse return quickjs.JS_UNDEFINED();
        lxb_dom_node_insert_before(ref_node, new_node);
    }
    setDomDirty();
    return qjs.JS_DupValue(c, args[0]);
}

// ── classList helper ────────────────────────────────────────────────

fn classListAdd(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get the element from classList.__element
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const cls_to_add = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, cls_to_add.ptr);

    // Get current class
    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);

    if (cur != null and cur_len > 0) {
        // Check if already present
        const current = cur.?[0..cur_len];
        if (classContains(current, cls_to_add.ptr[0..cls_to_add.len])) return quickjs.JS_UNDEFINED();
        // Compute required length and use heap allocation if needed
        const required_len = cur_len + 1 + cls_to_add.len;
        var stack_buf: [1024]u8 = undefined;
        const use_heap = required_len > stack_buf.len;
        const buf = if (use_heap)
            (std.heap.c_allocator.alloc(u8, required_len) catch return quickjs.JS_EXCEPTION())
        else
            stack_buf[0..required_len];
        defer if (use_heap) std.heap.c_allocator.free(buf);
        @memcpy(buf[0..cur_len], cur.?[0..cur_len]);
        buf[cur_len] = ' ';
        @memcpy(buf[cur_len + 1 ..][0..cls_to_add.len], cls_to_add.ptr[0..cls_to_add.len]);
        _ = lxb_dom_element_set_attribute(elem, "class", 5, buf.ptr, required_len);
    } else {
        _ = lxb_dom_element_set_attribute(elem, "class", 5, cls_to_add.ptr, cls_to_add.len);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn classListRemove(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const cls_to_remove = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, cls_to_remove.ptr);

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_UNDEFINED();

    const current = cur.?[0..cur_len];
    const remove_str = cls_to_remove.ptr[0..cls_to_remove.len];

    // Rebuild class string without the removed class
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var iter = std.mem.splitSequence(u8, current, " ");
    var first = true;
    while (iter.next()) |cls| {
        if (cls.len == 0) continue;
        if (std.mem.eql(u8, cls, remove_str)) continue;
        if (!first and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        const copy_len = @min(cls.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], cls[0..copy_len]);
        pos += copy_len;
        first = false;
    }
    _ = lxb_dom_element_set_attribute(elem, "class", 5, &buf, pos);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn classListContains(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const cls_name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, cls_name.ptr);

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);
    return quickjs.JS_NewBool(classContains(cur.?[0..cur_len], cls_name.ptr[0..cls_name.len]));
}

fn classListToggle(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const cls_name = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, cls_name.ptr);

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    const has = if (cur != null and cur_len > 0)
        classContains(cur.?[0..cur_len], cls_name.ptr[0..cls_name.len])
    else
        false;

    if (has) {
        // Remove
        _ = classListRemove(ctx, this_val, argc, argv);
        return quickjs.JS_NewBool(false);
    } else {
        // Add
        _ = classListAdd(ctx, this_val, argc, argv);
        return quickjs.JS_NewBool(true);
    }
}

fn classContains(class_str: []const u8, needle: []const u8) bool {
    var iter = std.mem.splitSequence(u8, class_str, " ");
    while (iter.next()) |cls| {
        if (std.mem.eql(u8, cls, needle)) return true;
    }
    return false;
}

/// Create a classList object for the given element JS value.
fn createClassList(ctx: *qjs.JSContext, element_val: qjs.JSValue) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetPropertyStr(ctx, obj, "__element", qjs.JS_DupValue(ctx, element_val));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "add", qjs.JS_NewCFunction(ctx, &classListAdd, "add", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "remove", qjs.JS_NewCFunction(ctx, &classListRemove, "remove", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "contains", qjs.JS_NewCFunction(ctx, &classListContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "toggle", qjs.JS_NewCFunction(ctx, &classListToggle, "toggle", 1));
    return obj;
}

fn elementGetClassList(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return createClassList(c, this_val);
}

// ── document methods ────────────────────────────────────────────────

/// Iterative depth-first tree walk to find element by id (stack-safe)
fn walkTreeById(root: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
            if (val != null and val_len == id.len) {
                if (std.mem.eql(u8, val.?[0..val_len], id)) return node;
            }
        }
        // Depth-first: try first child, then next sibling, then backtrack
        if (node.first_child) |child| {
            current = child;
        } else {
            var backtrack: ?*lxb.lxb_dom_node_t = node;
            current = null;
            while (backtrack) |bt| {
                if (bt == root) break;
                if (bt.next) |sibling| {
                    current = sibling;
                    break;
                }
                backtrack = bt.parent;
            }
        }
    }
    return null;
}

fn documentGetElementById(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeById(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn getDocumentNode() ?*lxb.lxb_dom_node_t {
    const doc = g_document orelse return null;
    return @ptrCast(@alignCast(doc));
}

fn walkTreeBySelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    // Simple selector matching: #id, .class, tagname
    if (selector.len == 0) return null;

    if (selector[0] == '#') {
        // ID selector
        return walkTreeById(node, selector[1..]);
    } else if (selector[0] == '.') {
        // Class selector
        return walkTreeByClass(node, selector[1..]);
    } else {
        // Tag name selector
        return walkTreeByTag(node, selector);
    }
}

/// Iterative depth-first next node (stack-safe tree traversal helper)
fn nextDfsNode(node: *lxb.lxb_dom_node_t, root: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    if (node.first_child) |child| return child;
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |c| {
        if (c == root) return null;
        if (c.next) |sibling| return sibling;
        cur = c.parent;
    }
    return null;
}

fn walkTreeByClass(root: *lxb.lxb_dom_node_t, class_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
            if (val != null and val_len > 0) {
                if (classContains(val.?[0..val_len], class_name)) return node;
            }
        }
        current = nextDfsNode(node, root);
    }
    return null;
}

fn walkTreeByTag(root: *lxb.lxb_dom_node_t, tag_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len == tag_name.len) {
                // Case-insensitive comparison (DOM tags may be upper or lowercase)
                if (std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], tag_name)) return node;
            }
        }
        current = nextDfsNode(node, root);
    }
    return null;
}

fn documentQuerySelector(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeBySelector(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn documentQuerySelectorAll(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, doc_node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

/// Iterative querySelectorAll collector (stack-safe)
fn walkTreeCollect(ctx: *qjs.JSContext, root: *lxb.lxb_dom_node_t, selector: []const u8, arr: qjs.JSValue, idx: *u32) void {
    if (selector.len == 0) return;
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var matches = false;
            if (selector[0] == '#') {
                const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
                var val_len: usize = 0;
                const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
                if (val != null and val_len == selector.len - 1) {
                    if (std.mem.eql(u8, val.?[0..val_len], selector[1..])) matches = true;
                }
            } else if (selector[0] == '.') {
                const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
                var val_len: usize = 0;
                const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
                if (val != null and val_len > 0) {
                    if (classContains(val.?[0..val_len], selector[1..])) matches = true;
                }
            } else {
                const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
                var name_len: usize = 0;
                const name_ptr = lxb_dom_element_local_name(elem, &name_len);
                if (name_ptr != null and name_len == selector.len) {
                    if (std.mem.eql(u8, name_ptr.?[0..name_len], selector)) matches = true;
                }
            }
            if (matches) {
                _ = qjs.JS_SetPropertyUint32(ctx, arr, idx.*, wrapNode(ctx, node));
                idx.* += 1;
            }
        }
        current = nextDfsNode(node, root);
    }
}

fn documentCreateElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc = g_document orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, s.ptr, s.len, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    return wrapNode(c, node);
}

fn documentCreateTextNode(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc = g_document orelse return quickjs.JS_NULL();
    const text = lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse return quickjs.JS_NULL();
    return wrapNode(c, text);
}

fn documentGetBody(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    // Walk to find <body> element
    const found = walkTreeByTag(doc_node, "body") orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn documentGetTitle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return qjs.JS_NewStringLen(c, "", 0);
    const title_node = walkTreeByTag(doc_node, "title") orelse return qjs.JS_NewStringLen(c, "", 0);
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(title_node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
}

fn documentGetDocumentElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeByTag(doc_node, "html") orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

// ── Registration ────────────────────────────────────────────────────

/// Register DOM API classes and the `document` global.
/// Must be called after page parse and before script execution.
pub fn registerDomApis(rt: *qjs.JSRuntime, ctx: *qjs.JSContext, document_ptr: *anyopaque) void {
    g_document = document_ptr;
    dom_dirty = false;

    // Register Element class
    _ = qjs.JS_NewClassID(rt, &element_class_id);
    const elem_class_def = qjs.JSClassDef{
        .class_name = "Element",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, element_class_id, &elem_class_def);

    // Register Text class
    _ = qjs.JS_NewClassID(rt, &text_class_id);
    const text_class_def = qjs.JSClassDef{
        .class_name = "Text",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    _ = qjs.JS_NewClass(rt, text_class_id, &text_class_def);

    // Build Element prototype
    const elem_proto = qjs.JS_NewObject(ctx);

    // Properties via getter methods
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttribute", qjs.JS_NewCFunction(ctx, &elementGetAttribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttribute", qjs.JS_NewCFunction(ctx, &elementSetAttribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttribute", qjs.JS_NewCFunction(ctx, &elementRemoveAttribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "appendChild", qjs.JS_NewCFunction(ctx, &elementAppendChild, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeChild", qjs.JS_NewCFunction(ctx, &elementRemoveChild, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertBefore", qjs.JS_NewCFunction(ctx, &elementInsertBefore, "insertBefore", 2));

    // Define getter/setter properties using JS_DefinePropertyGetSet
    const tagNameAtom = qjs.JS_NewAtom(ctx, "tagName");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, tagNameAtom, qjs.JS_NewCFunction(ctx, &elementGetTagName, "get tagName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, tagNameAtom);

    const idAtom = qjs.JS_NewAtom(ctx, "id");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, idAtom, qjs.JS_NewCFunction(ctx, &elementGetId, "get id", 0), qjs.JS_NewCFunction(ctx, &elementSetId, "set id", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, idAtom);

    const classNameAtom = qjs.JS_NewAtom(ctx, "className");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classNameAtom, qjs.JS_NewCFunction(ctx, &elementGetClassName, "get className", 0), qjs.JS_NewCFunction(ctx, &elementSetClassName, "set className", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, classNameAtom);

    const textContentAtom = qjs.JS_NewAtom(ctx, "textContent");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, textContentAtom, qjs.JS_NewCFunction(ctx, &elementGetTextContent, "get textContent", 0), qjs.JS_NewCFunction(ctx, &elementSetTextContent, "set textContent", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, textContentAtom);

    const parentNodeAtom = qjs.JS_NewAtom(ctx, "parentNode");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, parentNodeAtom, qjs.JS_NewCFunction(ctx, &elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, parentNodeAtom);

    const firstChildAtom = qjs.JS_NewAtom(ctx, "firstChild");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, firstChildAtom, qjs.JS_NewCFunction(ctx, &elementGetFirstChild, "get firstChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, firstChildAtom);

    const lastChildAtom = qjs.JS_NewAtom(ctx, "lastChild");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, lastChildAtom, qjs.JS_NewCFunction(ctx, &elementGetLastChild, "get lastChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, lastChildAtom);

    const nextSiblingAtom = qjs.JS_NewAtom(ctx, "nextSibling");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, nextSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, nextSiblingAtom);

    const prevSiblingAtom = qjs.JS_NewAtom(ctx, "previousSibling");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, prevSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousSibling, "get previousSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, prevSiblingAtom);

    const childrenAtom = qjs.JS_NewAtom(ctx, "children");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, childrenAtom, qjs.JS_NewCFunction(ctx, &elementGetChildren, "get children", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, childrenAtom);

    const childNodesAtom = qjs.JS_NewAtom(ctx, "childNodes");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, childNodesAtom, qjs.JS_NewCFunction(ctx, &elementGetChildNodes, "get childNodes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, childNodesAtom);

    const classListAtom = qjs.JS_NewAtom(ctx, "classList");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classListAtom, qjs.JS_NewCFunction(ctx, &elementGetClassList, "get classList", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, classListAtom);

    // Set prototype for Element class
    qjs.JS_SetClassProto(ctx, element_class_id, qjs.JS_DupValue(ctx, elem_proto));
    qjs.JS_FreeValue(ctx, elem_proto);

    // Create minimal Text prototype (only text-relevant properties)
    const text_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "textContent", qjs.JS_NewCFunction(ctx, &elementGetTextContent, "get textContent", 0));
    const text_parentAtom = qjs.JS_NewAtom(ctx, "parentNode");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_parentAtom, qjs.JS_NewCFunction(ctx, &elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_parentAtom);
    const text_nextAtom = qjs.JS_NewAtom(ctx, "nextSibling");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_nextAtom, qjs.JS_NewCFunction(ctx, &elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_nextAtom);
    qjs.JS_SetClassProto(ctx, text_class_id, text_proto);

    // Build document global
    const doc_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementById", qjs.JS_NewCFunction(ctx, &documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", qjs.JS_NewCFunction(ctx, &documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", qjs.JS_NewCFunction(ctx, &documentCreateElement, "createElement", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", qjs.JS_NewCFunction(ctx, &documentCreateTextNode, "createTextNode", 1));

    // document.body (getter)
    const bodyAtom = qjs.JS_NewAtom(ctx, "body");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, bodyAtom, qjs.JS_NewCFunction(ctx, &documentGetBody, "get body", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, bodyAtom);

    // document.title (getter)
    const titleAtom = qjs.JS_NewAtom(ctx, "title");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, titleAtom, qjs.JS_NewCFunction(ctx, &documentGetTitle, "get title", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, titleAtom);

    // document.documentElement (getter)
    const docElemAtom = qjs.JS_NewAtom(ctx, "documentElement");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, docElemAtom, qjs.JS_NewCFunction(ctx, &documentGetDocumentElement, "get documentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, docElemAtom);

    // Set document global
    const global = qjs.JS_GetGlobalObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);
    qjs.JS_FreeValue(ctx, global);
}

/// Wraps a raw lxb_dom_node_t pointer into a JS value.
/// Used by the event system to wrap target elements.
pub fn wrapNodePublic(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    return wrapNode(ctx, node);
}

/// Gets a raw lxb_dom_node_t pointer from a JS value.
/// Used by the event system to identify elements.
pub fn getNodePublic(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    return getNode(ctx, val);
}
