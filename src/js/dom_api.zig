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
extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;

// Lexbor HTML serialization (for innerHTML/outerHTML)
const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_deep_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;

// Lexbor HTML fragment parsing (for innerHTML setter)
extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;

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

/// Current page URL — set from main when navigating.
var g_current_url: ?[]const u8 = null;

/// Set the current page URL (called from main on navigation).
pub fn setCurrentUrl(url: ?[]const u8) void {
    g_current_url = url;
}

// ── Serialization helper (for innerHTML/outerHTML) ──────────────────

const SerializeAccum = struct {
    buf: []u8,
    pos: usize,
    overflow: bool,
    heap_buf: ?[]u8, // if stack buf overflows, we switch to heap

    fn init(stack_buf: []u8) SerializeAccum {
        return .{ .buf = stack_buf, .pos = 0, .overflow = false, .heap_buf = null };
    }

    fn deinit(self: *SerializeAccum) void {
        if (self.heap_buf) |hb| std.heap.c_allocator.free(hb);
    }

    fn result(self: *SerializeAccum) []const u8 {
        return self.buf[0..self.pos];
    }

    fn append(self: *SerializeAccum, data: []const u8) bool {
        if (self.pos + data.len > self.buf.len) {
            // Need to grow
            const new_size = @max(self.buf.len * 2, self.pos + data.len + 1024);
            const new_buf = std.heap.c_allocator.alloc(u8, new_size) catch return false;
            @memcpy(new_buf[0..self.pos], self.buf[0..self.pos]);
            if (self.heap_buf) |old| std.heap.c_allocator.free(old);
            self.heap_buf = new_buf;
            self.buf = new_buf;
        }
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
        return true;
    }
};

fn serializeCallback(data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    if (len == 0) return 0;
    const accum: *SerializeAccum = @ptrCast(@alignCast(ctx orelse return 1));
    const d = data orelse return 1;
    if (!accum.append(d[0..len])) return 1;
    return 0;
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

// ── innerHTML getter/setter ──────────────────────────────────────────

fn elementGetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    // Serialize all child nodes (innerHTML = deep serialization of children)
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();

    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = lxb_html_serialize_tree_cb(ch, &serializeCallback, @ptrCast(&accum));
        child = ch.next;
    }
    const result = accum.result();
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

fn elementSetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Remove all existing children
    while (node.first_child) |child| {
        lxb_dom_node_remove(child);
        _ = lxb_dom_node_destroy(child);
    }

    // If empty string, just clear
    if (s.len == 0) {
        setDomDirty();
        return quickjs.JS_UNDEFINED();
    }

    // Parse fragment and attach children
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();

    // Move children from fragment to element
    while (frag.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_child(node, child);
    }
    // Destroy the fragment container itself
    _ = lxb_dom_node_destroy(frag);

    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── outerHTML getter ────────────────────────────────────────────────

fn elementGetOuterHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();
    _ = lxb_html_serialize_tree_cb(node, &serializeCallback, @ptrCast(&accum));
    const result = accum.result();
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

// ── element.style (CSSStyleDeclaration) ─────────────────────────────

/// Parse the style attribute string and get a specific property value.
fn getStyleProperty(style_str: []const u8, css_prop: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < style_str.len) {
        // Skip whitespace
        while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == '\t' or style_str[pos] == '\n')) pos += 1;
        if (pos >= style_str.len) break;
        // Find property name
        const prop_start = pos;
        while (pos < style_str.len and style_str[pos] != ':' and style_str[pos] != ';') pos += 1;
        if (pos >= style_str.len or style_str[pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..pos], " \t\n");
        pos += 1; // skip ':'
        // Find value
        const val_start = pos;
        while (pos < style_str.len and style_str[pos] != ';') pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..pos], " \t\n");
        if (pos < style_str.len) pos += 1; // skip ';'

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) return val;
    }
    return null;
}

/// Set a property in a style string, returning a new string in the provided buffer.
fn setStyleProperty(style_str: []const u8, css_prop: []const u8, css_val: []const u8, buf: []u8) ?[]const u8 {
    var out_pos: usize = 0;
    var found = false;

    // Copy existing properties, replacing the target one
    var iter_pos: usize = 0;
    while (iter_pos < style_str.len) {
        // Skip whitespace
        while (iter_pos < style_str.len and (style_str[iter_pos] == ' ' or style_str[iter_pos] == '\t')) iter_pos += 1;
        if (iter_pos >= style_str.len) break;
        const prop_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ':' and style_str[iter_pos] != ';') iter_pos += 1;
        if (iter_pos >= style_str.len or style_str[iter_pos] != ':') break;
        const prop_name = std.mem.trim(u8, style_str[prop_start..iter_pos], " \t\n");
        iter_pos += 1; // skip ':'
        const val_start = iter_pos;
        while (iter_pos < style_str.len and style_str[iter_pos] != ';') iter_pos += 1;
        const val = std.mem.trim(u8, style_str[val_start..iter_pos], " \t\n");
        if (iter_pos < style_str.len) iter_pos += 1; // skip ';'

        if (std.ascii.eqlIgnoreCase(prop_name, css_prop)) {
            found = true;
            if (css_val.len == 0) continue; // remove property
            // Write replacement
            const needed = prop_name.len + 2 + css_val.len + 2; // "prop: val; "
            if (out_pos + needed > buf.len) return null;
            @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
            out_pos += prop_name.len;
            buf[out_pos] = ':';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
            @memcpy(buf[out_pos..][0..css_val.len], css_val);
            out_pos += css_val.len;
            buf[out_pos] = ';';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
        } else {
            // Copy existing property as-is
            const needed = prop_name.len + 2 + val.len + 2;
            if (out_pos + needed > buf.len) return null;
            @memcpy(buf[out_pos..][0..prop_name.len], prop_name);
            out_pos += prop_name.len;
            buf[out_pos] = ':';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
            @memcpy(buf[out_pos..][0..val.len], val);
            out_pos += val.len;
            buf[out_pos] = ';';
            out_pos += 1;
            buf[out_pos] = ' ';
            out_pos += 1;
        }
    }
    if (!found and css_val.len > 0) {
        // Append new property
        const needed = css_prop.len + 2 + css_val.len + 1;
        if (out_pos + needed > buf.len) return null;
        @memcpy(buf[out_pos..][0..css_prop.len], css_prop);
        out_pos += css_prop.len;
        buf[out_pos] = ':';
        out_pos += 1;
        buf[out_pos] = ' ';
        out_pos += 1;
        @memcpy(buf[out_pos..][0..css_val.len], css_val);
        out_pos += css_val.len;
        buf[out_pos] = ';';
        out_pos += 1;
    }

    // Trim trailing space
    if (out_pos > 0 and buf[out_pos - 1] == ' ') out_pos -= 1;
    return buf[0..out_pos];
}

/// Create a style object for an element.
/// Uses setProperty/getPropertyValue as native methods, and sets up
/// camelCase property access via a JavaScript Proxy-like wrapper.
fn createStyleObject(ctx: *qjs.JSContext, element_val: qjs.JSValue) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(obj)) return obj;

    // Store element reference
    _ = qjs.JS_SetPropertyStr(ctx, obj, "__element", qjs.JS_DupValue(ctx, element_val));

    // Native methods
    _ = qjs.JS_SetPropertyStr(ctx, obj, "setProperty", qjs.JS_NewCFunction(ctx, &styleSetProperty, "setProperty", 2));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "getPropertyValue", qjs.JS_NewCFunction(ctx, &styleGetPropertyValue, "getPropertyValue", 1));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "removeProperty", qjs.JS_NewCFunction(ctx, &styleRemoveProperty, "removeProperty", 1));

    // cssText getter/setter
    const cssTextAtom = qjs.JS_NewAtom(ctx, "cssText");
    _ = qjs.JS_DefinePropertyGetSet(ctx, obj, cssTextAtom, qjs.JS_NewCFunction(ctx, &styleGetCssText, "get cssText", 0), qjs.JS_NewCFunction(ctx, &styleSetCssText, "set cssText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cssTextAtom);

    // Set up Proxy wrapper via JS eval to intercept camelCase property access.
    // Store the raw object and return a Proxy.
    const global = qjs.JS_GetGlobalObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, global, "__styleTarget", obj);

    const proxy_code =
        \\(function() {
        \\  var t = globalThis.__styleTarget;
        \\  delete globalThis.__styleTarget;
        \\  var map = {
        \\    color:"color",backgroundColor:"background-color",background:"background",
        \\    display:"display",width:"width",height:"height",
        \\    minWidth:"min-width",minHeight:"min-height",maxWidth:"max-width",maxHeight:"max-height",
        \\    margin:"margin",marginTop:"margin-top",marginRight:"margin-right",
        \\    marginBottom:"margin-bottom",marginLeft:"margin-left",
        \\    padding:"padding",paddingTop:"padding-top",paddingRight:"padding-right",
        \\    paddingBottom:"padding-bottom",paddingLeft:"padding-left",
        \\    border:"border",borderTop:"border-top",borderRight:"border-right",
        \\    borderBottom:"border-bottom",borderLeft:"border-left",
        \\    borderRadius:"border-radius",borderColor:"border-color",
        \\    borderWidth:"border-width",borderStyle:"border-style",
        \\    fontSize:"font-size",fontWeight:"font-weight",fontFamily:"font-family",
        \\    fontStyle:"font-style",textAlign:"text-align",textDecoration:"text-decoration",
        \\    textTransform:"text-transform",lineHeight:"line-height",letterSpacing:"letter-spacing",
        \\    position:"position",top:"top",left:"left",right:"right",bottom:"bottom",
        \\    zIndex:"z-index",opacity:"opacity",visibility:"visibility",
        \\    overflow:"overflow",overflowX:"overflow-x",overflowY:"overflow-y",
        \\    cursor:"cursor",float:"float",clear:"clear",
        \\    transform:"transform",transition:"transition",
        \\    boxShadow:"box-shadow",textShadow:"text-shadow",
        \\    whiteSpace:"white-space",wordBreak:"word-break",wordWrap:"word-wrap",
        \\    flexDirection:"flex-direction",flexWrap:"flex-wrap",
        \\    justifyContent:"justify-content",alignItems:"align-items",alignSelf:"align-self",
        \\    flex:"flex",flexGrow:"flex-grow",flexShrink:"flex-shrink",flexBasis:"flex-basis",
        \\    gap:"gap",gridTemplateColumns:"grid-template-columns",gridTemplateRows:"grid-template-rows",
        \\    gridColumn:"grid-column",gridRow:"grid-row",
        \\    listStyle:"list-style",listStyleType:"list-style-type",
        \\    outline:"outline",outlineColor:"outline-color",outlineStyle:"outline-style",
        \\    outlineWidth:"outline-width",content:"content",pointerEvents:"pointer-events",
        \\    userSelect:"user-select",objectFit:"object-fit",verticalAlign:"vertical-align",
        \\    boxSizing:"box-sizing"
        \\  };
        \\  return new Proxy(t, {
        \\    get: function(o,p) {
        \\      if (p in o) return o[p];
        \\      var css = map[p] || p;
        \\      return o.getPropertyValue(css);
        \\    },
        \\    set: function(o,p,v) {
        \\      var css = map[p] || p;
        \\      o.setProperty(css, String(v));
        \\      return true;
        \\    }
        \\  });
        \\})()
    ;

    const result = qjs.JS_Eval(ctx, proxy_code, proxy_code.len, "<style>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(ctx, global);

    if (quickjs.JS_IsException(result)) {
        // Fallback: return raw object without Proxy
        const exc = qjs.JS_GetException(ctx);
        qjs.JS_FreeValue(ctx, exc);
        return qjs.JS_DupValue(ctx, obj);
    }
    return result;
}

fn styleSetProperty(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const prop_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const val_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val_s.ptr);

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    const current_style = if (style_ptr != null and style_len > 0) style_ptr.?[0..style_len] else "";

    var buf: [4096]u8 = undefined;
    if (setStyleProperty(current_style, prop_s.ptr[0..prop_s.len], val_s.ptr[0..val_s.len], &buf)) |new_style| {
        _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
        setDomDirty();
    }
    return quickjs.JS_UNDEFINED();
}

fn styleGetPropertyValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewStringLen(c, "", 0);
    const args = argv orelse return qjs.JS_NewStringLen(c, "", 0);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);

    if (getStyleProperty(style_ptr.?[0..style_len], prop_s.ptr[0..prop_s.len])) |val| {
        return qjs.JS_NewStringLen(c, val.ptr, val.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn styleRemoveProperty(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewStringLen(c, "", 0);
    const args = argv orelse return qjs.JS_NewStringLen(c, "", 0);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);

    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const current_style = style_ptr.?[0..style_len];

    // Get old value first
    const old_val = getStyleProperty(current_style, prop_s.ptr[0..prop_s.len]);

    var buf: [4096]u8 = undefined;
    if (setStyleProperty(current_style, prop_s.ptr[0..prop_s.len], "", &buf)) |new_style| {
        _ = lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
        setDomDirty();
    }

    if (old_val) |ov| {
        return qjs.JS_NewStringLen(c, ov.ptr, ov.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn styleGetCssText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr == null or style_len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, style_ptr.?, style_len);
}

fn styleSetCssText(
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
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);
    _ = lxb_dom_element_set_attribute(elem, "style", 5, s.ptr, s.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementGetStyle(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return createStyleObject(c, this_val);
}

// ── element.hasAttribute ────────────────────────────────────────────

fn elementHasAttribute(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);
    return quickjs.JS_NewBool(lxb_dom_element_has_attribute(elem, s.ptr, s.len));
}

// ── element.remove() ────────────────────────────────────────────────

fn elementRemove(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.parent != null) {
        lxb_dom_node_remove(node);
        setDomDirty();
    }
    return quickjs.JS_UNDEFINED();
}

// ── element.contains(other) ─────────────────────────────────────────

fn elementContains(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const other = getNode(c, args[0]) orelse return quickjs.JS_NewBool(false);

    // Walk up from other to see if we find node
    var cur: ?*lxb.lxb_dom_node_t = other;
    while (cur) |n| {
        if (n == node) return quickjs.JS_NewBool(true);
        cur = n.parent;
    }
    return quickjs.JS_NewBool(false);
}

// ── element.matches(selector) ───────────────────────────────────────

fn elementMatchesSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (selector.len == 0) return false;
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    if (selector[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        if (val != null and val_len == selector.len - 1) {
            return std.mem.eql(u8, val.?[0..val_len], selector[1..]);
        }
        return false;
    } else if (selector[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val != null and val_len > 0) {
            return classContains(val.?[0..val_len], selector[1..]);
        }
        return false;
    } else {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr != null and name_len == selector.len) {
            return std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector);
        }
        return false;
    }
}

fn elementMatches(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node = getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);
    return quickjs.JS_NewBool(elementMatchesSelector(node, s.ptr[0..s.len]));
}

// ── element.closest(selector) ───────────────────────────────────────

fn elementClosest(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);
    const sel = s.ptr[0..s.len];

    // Walk up from this element
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |n| {
        if (elementMatchesSelector(n, sel)) return wrapNode(c, n);
        cur = n.parent;
    }
    return quickjs.JS_NULL();
}

// ── element.cloneNode(deep) ─────────────────────────────────────────

fn elementCloneNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // Determine deep flag (default: shallow clone per DOM spec)
    var deep = false;
    if (argc > 0) {
        if (args[0].tag == qjs.JS_TAG_BOOL) {
            deep = args[0].u.int32 != 0;
        }
    }

    // Clone by serializing and re-parsing
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();

    if (deep) {
        _ = lxb_html_serialize_tree_cb(node, &serializeCallback, @ptrCast(&accum));
    } else {
        _ = lxb_html_serialize_cb(node, &serializeCallback, @ptrCast(&accum));
    }

    const html = accum.result();
    if (html.len == 0) return quickjs.JS_NULL();

    const doc = g_document orelse return quickjs.JS_NULL();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const frag = lxb_html_document_parse_fragment(doc, elem, html.ptr, html.len) orelse return quickjs.JS_NULL();

    // Get the first child from fragment (the cloned element)
    if (frag.first_child) |cloned| {
        lxb_dom_node_remove(cloned);
        _ = lxb_dom_node_destroy(frag);
        return wrapNode(c, cloned);
    }
    _ = lxb_dom_node_destroy(frag);
    return quickjs.JS_NULL();
}

// ── element.replaceWith(newNode) ────────────────────────────────────

fn elementReplaceWith(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_before(node, new_node);
    lxb_dom_node_remove(node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.before(node) / element.after(node) ─────────────────────

fn elementBefore(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_before(node, new_node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementAfter(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    if (node.parent == null) return quickjs.JS_UNDEFINED();
    lxb_dom_node_insert_after(node, new_node);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.dataset ─────────────────────────────────────────────────
// Minimal implementation: returns an object whose properties map to data-* attributes.
// We use a getter that creates a Proxy-like object with get/set traps via JS eval.

fn elementGetDataset(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetPropertyStr(c, obj, "__element", qjs.JS_DupValue(c, this_val));
    _ = qjs.JS_SetPropertyStr(c, obj, "get", qjs.JS_NewCFunction(c, &datasetGet, "get", 1));
    _ = qjs.JS_SetPropertyStr(c, obj, "set", qjs.JS_NewCFunction(c, &datasetSet, "set", 2));
    return obj;
}

fn datasetGet(
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

    const key = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, key.ptr);

    // Convert camelCase key to data-kebab-case attribute name
    var attr_buf: [256]u8 = undefined;
    const attr_name = camelToDataAttr(key.ptr[0..key.len], &attr_buf) orelse return quickjs.JS_UNDEFINED();

    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len);
    if (val == null) return quickjs.JS_UNDEFINED();
    return qjs.JS_NewStringLen(c, val.?, val_len);
}

fn datasetSet(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_UNDEFINED();

    const key = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, key.ptr);
    const val = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, val.ptr);

    var attr_buf: [256]u8 = undefined;
    const attr_name = camelToDataAttr(key.ptr[0..key.len], &attr_buf) orelse return quickjs.JS_UNDEFINED();
    _ = lxb_dom_element_set_attribute(elem, attr_name.ptr, attr_name.len, val.ptr, val.len);
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn camelToDataAttr(key: []const u8, buf: []u8) ?[]const u8 {
    // "data-" prefix
    if (buf.len < 5 + key.len * 2) return null;
    @memcpy(buf[0..5], "data-");
    var pos: usize = 5;
    for (key) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            if (pos + 2 > buf.len) return null;
            buf[pos] = '-';
            pos += 1;
            buf[pos] = ch + 32; // lowercase
            pos += 1;
        } else {
            if (pos + 1 > buf.len) return null;
            buf[pos] = ch;
            pos += 1;
        }
    }
    return buf[0..pos];
}

// ── Element querySelector/querySelectorAll on element scope ─────────

fn elementQuerySelector(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const found = walkTreeBySelector(node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

fn elementQuerySelectorAll(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, node, s.ptr[0..s.len], arr, &idx);
    return arr;
}

// ── Element geometry (stub — returns 0 without layout) ──────────────

fn elementGetOffsetWidth(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetHeight(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetTop(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetLeft(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetBoundingClientRect(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetPropertyStr(c, obj, "top", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "left", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "width", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "height", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "right", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "bottom", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "x", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "y", qjs.JS_NewFloat64(c, 0));
    return obj;
}

fn elementGetScrollTop(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetScrollLeft(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 0);
}

// ── element.nodeType ────────────────────────────────────────────────

fn elementGetNodeType(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
    return switch (node.type) {
        lxb.LXB_DOM_NODE_TYPE_ELEMENT => qjs.JS_NewInt32(c, 1),
        lxb.LXB_DOM_NODE_TYPE_TEXT => qjs.JS_NewInt32(c, 3),
        lxb.LXB_DOM_NODE_TYPE_COMMENT => qjs.JS_NewInt32(c, 8),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT => qjs.JS_NewInt32(c, 9),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => qjs.JS_NewInt32(c, 11),
        else => qjs.JS_NewInt32(c, 1),
    };
}

// ── element.nodeName ────────────────────────────────────────────────

fn elementGetNodeName(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_TEXT) return qjs.JS_NewStringLen(c, "#text", 5);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_COMMENT) return qjs.JS_NewStringLen(c, "#comment", 8);
    if (node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) return qjs.JS_NewStringLen(c, "#document", 9);
    // For elements, return tagName (uppercase)
    return elementGetTagName(ctx, this_val, argc, argv);
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
                    if (std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector)) matches = true;
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

fn documentGetHead(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const doc_node = getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeByTag(doc_node, "head") orelse return quickjs.JS_NULL();
    return wrapNode(c, found);
}

// ── document.cookie ─────────────────────────────────────────────────

var g_cookies: ?[]u8 = null;

fn documentGetCookie(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_cookies) |cookies| {
        return qjs.JS_NewStringLen(c, cookies.ptr, cookies.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn documentSetCookie(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Append cookie (real cookie parsing is complex; this appends per Set-Cookie behavior)
    if (g_cookies) |old| {
        const sep = "; ";
        const new_len = old.len + sep.len + s.len;
        const new_cookies = std.heap.c_allocator.alloc(u8, new_len) catch return quickjs.JS_UNDEFINED();
        @memcpy(new_cookies[0..old.len], old);
        @memcpy(new_cookies[old.len..][0..sep.len], sep);
        @memcpy(new_cookies[old.len + sep.len ..][0..s.len], s.ptr[0..s.len]);
        std.heap.c_allocator.free(old);
        g_cookies = new_cookies;
    } else {
        const new_cookies = std.heap.c_allocator.alloc(u8, s.len) catch return quickjs.JS_UNDEFINED();
        @memcpy(new_cookies, s.ptr[0..s.len]);
        g_cookies = new_cookies;
    }
    return quickjs.JS_UNDEFINED();
}

// ── window.location ─────────────────────────────────────────────────

fn windowLocationGetHref(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        return qjs.JS_NewStringLen(c, url.ptr, url.len);
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetProtocol(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            return qjs.JS_NewStringLen(c, url.ptr, idx + 1); // includes the ':'
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHostname(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfAny(u8, after, ":/") orelse after.len;
            return qjs.JS_NewStringLen(c, after.ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHost(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            return qjs.JS_NewStringLen(c, after.ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetPathname(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            if (std.mem.indexOfScalar(u8, after, '/')) |slash| {
                const path_start = after[slash..];
                // Path is up to ? or #
                const end = std.mem.indexOfAny(u8, path_start, "?#") orelse path_start.len;
                return qjs.JS_NewStringLen(c, path_start.ptr, end);
            }
        }
    }
    return qjs.JS_NewStringLen(c, "/", 1);
}

fn windowLocationGetSearch(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            const end = std.mem.indexOfScalar(u8, url[q..], '#') orelse url.len - q;
            return qjs.JS_NewStringLen(c, url[q..].ptr, end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetHash(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOfScalar(u8, url, '#')) |h| {
            return qjs.JS_NewStringLen(c, url[h..].ptr, url.len - h);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationGetOrigin(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (g_current_url) |url| {
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            const after = url[idx + 3 ..];
            const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            return qjs.JS_NewStringLen(c, url.ptr, idx + 3 + end);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

fn windowLocationToString(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return windowLocationGetHref(ctx, quickjs.JS_UNDEFINED(), 0, null);
}

fn windowLocationReload(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual reload requires main loop integration
    return quickjs.JS_UNDEFINED();
}

fn windowLocationAssign(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual navigation requires main loop integration
    return quickjs.JS_UNDEFINED();
}

fn createLocationObject(ctx: *qjs.JSContext) qjs.JSValue {
    const loc = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(loc)) return loc;

    // href getter
    const hrefAtom = qjs.JS_NewAtom(ctx, "href");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hrefAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHref, "get href", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hrefAtom);

    const protocolAtom = qjs.JS_NewAtom(ctx, "protocol");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, protocolAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetProtocol, "get protocol", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, protocolAtom);

    const hostnameAtom = qjs.JS_NewAtom(ctx, "hostname");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hostnameAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHostname, "get hostname", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hostnameAtom);

    const hostAtom = qjs.JS_NewAtom(ctx, "host");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hostAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHost, "get host", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hostAtom);

    const pathnameAtom = qjs.JS_NewAtom(ctx, "pathname");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, pathnameAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetPathname, "get pathname", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, pathnameAtom);

    const searchAtom = qjs.JS_NewAtom(ctx, "search");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, searchAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetSearch, "get search", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, searchAtom);

    const hashAtom = qjs.JS_NewAtom(ctx, "hash");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, hashAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetHash, "get hash", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, hashAtom);

    const originAtom = qjs.JS_NewAtom(ctx, "origin");
    _ = qjs.JS_DefinePropertyGetSet(ctx, loc, originAtom, qjs.JS_NewCFunction(ctx, &windowLocationGetOrigin, "get origin", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, originAtom);

    _ = qjs.JS_SetPropertyStr(ctx, loc, "reload", qjs.JS_NewCFunction(ctx, &windowLocationReload, "reload", 0));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "assign", qjs.JS_NewCFunction(ctx, &windowLocationAssign, "assign", 1));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "toString", qjs.JS_NewCFunction(ctx, &windowLocationToString, "toString", 0));

    return loc;
}

// ── window.scrollTo / window.scrollBy (stubs) ───────────────────────

fn windowScrollTo(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_UNDEFINED();
}

fn windowScrollBy(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_UNDEFINED();
}

fn windowGetInnerWidth(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 800); // Default; could be made configurable
}

fn windowGetInnerHeight(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 600); // Default; could be made configurable
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

    // Methods
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttribute", qjs.JS_NewCFunction(ctx, &elementGetAttribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttribute", qjs.JS_NewCFunction(ctx, &elementSetAttribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttribute", qjs.JS_NewCFunction(ctx, &elementRemoveAttribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hasAttribute", qjs.JS_NewCFunction(ctx, &elementHasAttribute, "hasAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "appendChild", qjs.JS_NewCFunction(ctx, &elementAppendChild, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeChild", qjs.JS_NewCFunction(ctx, &elementRemoveChild, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertBefore", qjs.JS_NewCFunction(ctx, &elementInsertBefore, "insertBefore", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "remove", qjs.JS_NewCFunction(ctx, &elementRemove, "remove", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "contains", qjs.JS_NewCFunction(ctx, &elementContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "matches", qjs.JS_NewCFunction(ctx, &elementMatches, "matches", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "closest", qjs.JS_NewCFunction(ctx, &elementClosest, "closest", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "cloneNode", qjs.JS_NewCFunction(ctx, &elementCloneNode, "cloneNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "replaceWith", qjs.JS_NewCFunction(ctx, &elementReplaceWith, "replaceWith", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "before", qjs.JS_NewCFunction(ctx, &elementBefore, "before", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "after", qjs.JS_NewCFunction(ctx, &elementAfter, "after", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getBoundingClientRect", qjs.JS_NewCFunction(ctx, &elementGetBoundingClientRect, "getBoundingClientRect", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelector", qjs.JS_NewCFunction(ctx, &elementQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &elementQuerySelectorAll, "querySelectorAll", 1));

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

    // innerHTML getter/setter
    const innerHTMLAtom = qjs.JS_NewAtom(ctx, "innerHTML");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, innerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerHTML, "get innerHTML", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerHTML, "set innerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, innerHTMLAtom);

    // outerHTML getter
    const outerHTMLAtom = qjs.JS_NewAtom(ctx, "outerHTML");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, outerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetOuterHTML, "get outerHTML", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, outerHTMLAtom);

    // style getter
    const styleAtom = qjs.JS_NewAtom(ctx, "style");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, styleAtom, qjs.JS_NewCFunction(ctx, &elementGetStyle, "get style", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, styleAtom);

    // dataset getter
    const datasetAtom = qjs.JS_NewAtom(ctx, "dataset");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, datasetAtom, qjs.JS_NewCFunction(ctx, &elementGetDataset, "get dataset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, datasetAtom);

    // Element geometry (stubs without layout info)
    const offsetWidthAtom = qjs.JS_NewAtom(ctx, "offsetWidth");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, offsetWidthAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetWidth, "get offsetWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, offsetWidthAtom);

    const offsetHeightAtom = qjs.JS_NewAtom(ctx, "offsetHeight");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, offsetHeightAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetHeight, "get offsetHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, offsetHeightAtom);

    const offsetTopAtom = qjs.JS_NewAtom(ctx, "offsetTop");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, offsetTopAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetTop, "get offsetTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, offsetTopAtom);

    const offsetLeftAtom = qjs.JS_NewAtom(ctx, "offsetLeft");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, offsetLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetLeft, "get offsetLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, offsetLeftAtom);

    const scrollTopAtom = qjs.JS_NewAtom(ctx, "scrollTop");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, scrollTopAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollTop, "get scrollTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, scrollTopAtom);

    const scrollLeftAtom = qjs.JS_NewAtom(ctx, "scrollLeft");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, scrollLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollLeft, "get scrollLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, scrollLeftAtom);

    // nodeType getter
    const nodeTypeAtom = qjs.JS_NewAtom(ctx, "nodeType");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, nodeTypeAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeType, "get nodeType", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, nodeTypeAtom);

    // nodeName getter
    const nodeNameAtom = qjs.JS_NewAtom(ctx, "nodeName");
    _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, nodeNameAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeName, "get nodeName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, nodeNameAtom);

    // Set prototype for Element class
    qjs.JS_SetClassProto(ctx, element_class_id, qjs.JS_DupValue(ctx, elem_proto));
    qjs.JS_FreeValue(ctx, elem_proto);

    // Create minimal Text prototype (text-relevant properties)
    const text_proto = qjs.JS_NewObject(ctx);
    const text_tcAtom = qjs.JS_NewAtom(ctx, "textContent");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_tcAtom, qjs.JS_NewCFunction(ctx, &elementGetTextContent, "get textContent", 0), qjs.JS_NewCFunction(ctx, &elementSetTextContent, "set textContent", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_tcAtom);
    const text_parentAtom = qjs.JS_NewAtom(ctx, "parentNode");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_parentAtom, qjs.JS_NewCFunction(ctx, &elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_parentAtom);
    const text_nextAtom = qjs.JS_NewAtom(ctx, "nextSibling");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_nextAtom, qjs.JS_NewCFunction(ctx, &elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_nextAtom);
    const text_prevAtom = qjs.JS_NewAtom(ctx, "previousSibling");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_prevAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousSibling, "get previousSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_prevAtom);
    const text_nodeTypeAtom = qjs.JS_NewAtom(ctx, "nodeType");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_nodeTypeAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeType, "get nodeType", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_nodeTypeAtom);
    const text_nodeNameAtom = qjs.JS_NewAtom(ctx, "nodeName");
    _ = qjs.JS_DefinePropertyGetSet(ctx, text_proto, text_nodeNameAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeName, "get nodeName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, text_nodeNameAtom);
    _ = qjs.JS_SetPropertyStr(ctx, text_proto, "remove", qjs.JS_NewCFunction(ctx, &elementRemove, "remove", 0));
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

    // document.head (getter)
    const headAtom = qjs.JS_NewAtom(ctx, "head");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, headAtom, qjs.JS_NewCFunction(ctx, &documentGetHead, "get head", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, headAtom);

    // document.cookie (getter/setter)
    const cookieAtom = qjs.JS_NewAtom(ctx, "cookie");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, cookieAtom, qjs.JS_NewCFunction(ctx, &documentGetCookie, "get cookie", 0), qjs.JS_NewCFunction(ctx, &documentSetCookie, "set cookie", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cookieAtom);

    // Set document global
    const global = qjs.JS_GetGlobalObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);

    // window.location
    _ = qjs.JS_SetPropertyStr(ctx, global, "location", createLocationObject(ctx));

    // window.scrollTo / window.scrollBy
    _ = qjs.JS_SetPropertyStr(ctx, global, "scrollTo", qjs.JS_NewCFunction(ctx, &windowScrollTo, "scrollTo", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "scrollBy", qjs.JS_NewCFunction(ctx, &windowScrollBy, "scrollBy", 2));

    // window.innerWidth / window.innerHeight
    const innerWidthAtom = qjs.JS_NewAtom(ctx, "innerWidth");
    _ = qjs.JS_DefinePropertyGetSet(ctx, global, innerWidthAtom, qjs.JS_NewCFunction(ctx, &windowGetInnerWidth, "get innerWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, innerWidthAtom);

    const innerHeightAtom = qjs.JS_NewAtom(ctx, "innerHeight");
    _ = qjs.JS_DefinePropertyGetSet(ctx, global, innerHeightAtom, qjs.JS_NewCFunction(ctx, &windowGetInnerHeight, "get innerHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, innerHeightAtom);

    // navigator object (minimal)
    const nav_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "userAgent", qjs.JS_NewStringLen(ctx, "Mozilla/5.0 Suzume/1.0", 22));
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "language", qjs.JS_NewStringLen(ctx, "en", 2));
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "platform", qjs.JS_NewStringLen(ctx, "Linux", 5));
    _ = qjs.JS_SetPropertyStr(ctx, global, "navigator", nav_obj);

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
