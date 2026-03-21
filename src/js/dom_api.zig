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
pub var mutation_observers_pending: bool = false;

/// Currently focused element (set from main.zig when input is focused/blurred).
pub var active_element: ?*lxb.lxb_dom_node_t = null;

/// Scroll position, synced from main.zig.
pub var scroll_x: f32 = 0;
pub var scroll_y: f32 = 0;
/// Scroll request from JS (scrollTo/scrollBy). null = no pending request.
pub var pending_scroll_x: ?f32 = null;
pub var pending_scroll_y: ?f32 = null;

fn setDomDirty() void {
    dom_dirty = true;
    mutation_observers_pending = true;
}

/// Global root box pointer — set from main after layout, used for offset/rect queries.
const Box = @import("../layout/box.zig").Box;
const DomNode = @import("../dom/node.zig").DomNode;
const cascade_mod = @import("../css/cascade.zig");
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
var g_root_box: ?*const Box = null;

/// Set the root box pointer (called from main after layout).
pub fn setRootBox(root: ?*const Box) void {
    g_root_box = root;
}

/// Global styles pointer — set from main after cascade, used for getComputedStyle.
var g_styles: ?*const cascade_mod.StyleMap = null;

/// Set the styles pointer (called from main after cascade/restyle).
pub fn setStyles(styles: ?*const cascade_mod.StyleMap) void {
    g_styles = styles;
}

/// Find the Box in the tree that corresponds to a given DOM node pointer.
fn findBoxForNode(root: *const Box, target: *lxb.lxb_dom_node_t) ?*const Box {
    if (root.dom_node) |dn| {
        if (dn.lxb_node == target) return root;
    }
    for (root.children.items) |child| {
        if (findBoxForNode(child, target)) |found| return found;
    }
    return null;
}

/// Ready state for document.readyState
pub var g_ready_state: enum { loading, interactive, complete } = .loading;

pub fn setReadyState(state: @TypeOf(g_ready_state)) void {
    g_ready_state = state;
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
// ── Node identity cache ─────────────────────────────────────────────
// Maps DOM node pointer → JSValue to ensure the same DOM node always
// returns the same JS wrapper object (identity preservation for ===).
const NodeCache = std.AutoHashMap(usize, qjs.JSValue);
var node_cache: ?NodeCache = null;

fn initNodeCache() void {
    if (node_cache == null) {
        node_cache = NodeCache.init(std.heap.c_allocator);
    }
}

/// Clear the node identity cache (called on page navigation).
pub fn clearNodeCache(ctx: *qjs.JSContext) void {
    if (node_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            qjs.JS_FreeValue(ctx, entry.value_ptr.*);
        }
        cache.clearRetainingCapacity();
    }
}

fn wrapNode(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    initNodeCache();
    const key = @intFromPtr(node);

    // Return cached wrapper if it exists
    if (node_cache.?.get(key)) |cached| {
        return qjs.JS_DupValue(ctx, cached);
    }

    // Create new wrapper
    const node_type = node.type;
    const obj = if (node_type == lxb.LXB_DOM_NODE_TYPE_TEXT)
        wrapTextNew(ctx, node)
    else
        wrapElementNew(ctx, node);

    if (!quickjs.JS_IsException(obj)) {
        // Cache with a dup'd reference
        node_cache.?.put(key, qjs.JS_DupValue(ctx, obj)) catch {};
    }
    return obj;
}

fn wrapElementNew(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    const obj = qjs.JS_NewObjectClass(ctx, @intCast(element_class_id));
    if (quickjs.JS_IsException(obj)) return obj;
    _ = qjs.JS_SetOpaque(obj, @ptrCast(node));
    return obj;
}

fn wrapTextNew(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
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

fn elementGetParentElement(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const p: *lxb.lxb_dom_node_t = node.parent orelse return quickjs.JS_NULL();
    if (p.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_NULL();
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

fn elementReplaceChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return qjs.JS_ThrowTypeError(c, "Failed to execute 'replaceChild': 2 arguments required");
    const args = argv orelse return quickjs.JS_NULL();
    _ = getNode(c, this_val) orelse return quickjs.JS_NULL();
    const new_node = getNode(c, args[0]) orelse return quickjs.JS_NULL();
    const old_node = getNode(c, args[1]) orelse return quickjs.JS_NULL();
    // Insert new before old, then remove old
    lxb_dom_node_insert_before(old_node, new_node);
    lxb_dom_node_remove(old_node);
    setDomDirty();
    return qjs.JS_DupValue(c, args[1]); // returns the removed (old) node
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

fn classListReplace(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 2) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);

    const elem_val = qjs.JS_GetPropertyStr(c, this_val, "__element");
    defer qjs.JS_FreeValue(c, elem_val);
    const elem = getElement(c, elem_val) orelse return quickjs.JS_NewBool(false);

    const old_cls = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, old_cls.ptr);
    const new_cls = jsStringToSlice(c, args[1]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, new_cls.ptr);

    var cur_len: usize = 0;
    const cur = lxb_dom_element_get_attribute(elem, "class", 5, &cur_len);
    if (cur == null or cur_len == 0) return quickjs.JS_NewBool(false);

    const cur_str = cur.?[0..cur_len];
    if (!classContains(cur_str, old_cls.ptr[0..old_cls.len])) return quickjs.JS_NewBool(false);

    // Remove old, add new
    _ = classListRemove(ctx, this_val, 1, argv);
    var new_argv = [_]qjs.JSValue{args[1]};
    _ = classListAdd(ctx, this_val, 1, &new_argv);
    return quickjs.JS_NewBool(true);
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
    _ = qjs.JS_SetPropertyStr(ctx, obj, "replace", qjs.JS_NewCFunction(ctx, &classListReplace, "replace", 2));
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

    // Protect <body> from innerHTML overwrites that destroy page content.
    // jQuery Sizzle's feature detection sets body.innerHTML to test forms.
    // Only block writes that would replace content with small test markup;
    // allow legitimate larger innerHTML updates through.
    {
        var name_len: usize = 0;
        const name_ptr = lxb.lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr) |np| {
            const tag = np[0..name_len];
            if (std.mem.eql(u8, tag, "body") and s.len < 200) {
                // Small innerHTML on body = likely feature detection probe, block it
                std.log.info("[DOM] innerHTML SET on <body> blocked (probe, {d} bytes)", .{s.len});
                return quickjs.JS_UNDEFINED();
            }
        }
    }

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

// ── insertAdjacentHTML ──────────────────────────────────────────────

fn elementInsertAdjacentHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);

    const pos_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, pos_s.ptr);
    const position = pos_s.ptr[0..pos_s.len];

    const html_s = jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, html_s.ptr);

    if (html_s.len == 0) return quickjs.JS_UNDEFINED();

    // Parse fragment
    const doc = g_document orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, html_s.ptr, html_s.len) orelse return quickjs.JS_UNDEFINED();

    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        // Insert before this element (as previous sibling)
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_before(node, child);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        // Insert as first child of this element
        // Insert in reverse order to maintain document order
        const last_inserted: ?*lxb.lxb_dom_node_t = node.first_child;
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            if (last_inserted) |ref| {
                lxb_dom_node_insert_before(ref, child);
            } else {
                lxb_dom_node_insert_child(node, child);
            }
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        // Append as last child (same as innerHTML append)
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_child(node, child);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        // Insert after this element (as next sibling)
        var insert_after: *lxb.lxb_dom_node_t = node;
        while (frag.first_child) |child| {
            lxb_dom_node_remove(child);
            lxb_dom_node_insert_after(insert_after, child);
            insert_after = child;
        }
    }

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

// ── element.append(...nodes) / prepend(...nodes) ────────────────────

fn elementAppend(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const child_node = getNode(c, args[i]);
        if (child_node) |cn| {
            _ = lxb.lxb_dom_node_insert_child(parent, cn);
        } else if (qjs.JS_IsString(args[i])) {
            // String argument: create text node and append
            const s = jsStringToSlice(c, args[i]) orelse continue;
            defer qjs.JS_FreeCString(c, s.ptr);
            if (g_document) |doc| {
                const text_node = lxb_dom_document_create_text_node(doc, s.ptr, s.len);
                if (text_node) |tn| {
                    _ = lxb.lxb_dom_node_insert_child(parent, tn);
                }
            }
        }
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn elementPrepend(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const parent = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const first_child = lxb.lxb_dom_node_first_child(parent);
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const child_node = getNode(c, args[i]);
        if (child_node) |cn| {
            if (first_child) |fc| {
                _ = lxb.lxb_dom_node_insert_before(fc, cn);
            } else {
                _ = lxb.lxb_dom_node_insert_child(parent, cn);
            }
        }
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── element.toggleAttribute / getAttributeNames / scrollIntoView ────

fn elementToggleAttribute(
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

    const has = lxb_dom_element_has_attribute(elem, s.ptr, s.len);

    // If force argument provided
    if (argc >= 2) {
        const force = qjs.JS_ToBool(c, args[1]) > 0;
        if (force and !has) {
            _ = lxb_dom_element_set_attribute(elem, s.ptr, s.len, "", 0);
            setDomDirty();
            return quickjs.JS_NewBool(true);
        } else if (!force and has) {
            _ = lxb_dom_element_remove_attribute(elem, s.ptr, s.len);
            setDomDirty();
            return quickjs.JS_NewBool(false);
        }
        return quickjs.JS_NewBool(has);
    }

    if (has) {
        _ = lxb_dom_element_remove_attribute(elem, s.ptr, s.len);
        setDomDirty();
        return quickjs.JS_NewBool(false);
    } else {
        _ = lxb_dom_element_set_attribute(elem, s.ptr, s.len, "", 0);
        setDomDirty();
        return quickjs.JS_NewBool(true);
    }
}

fn elementGetAttributeNames(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Return empty array — full attribute enumeration requires lexbor iteration
    const c = ctx orelse return quickjs.JS_NULL();
    _ = this_val;
    return qjs.JS_NewArray(c);
}

fn elementGetContext(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();

    // Check if this is a canvas element
    const elem = getElement(c, this_val) orelse return quickjs.JS_NULL();
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return quickjs.JS_NULL();
    if (!std.mem.eql(u8, name_ptr.?[0..name_len], "canvas")) return quickjs.JS_NULL();

    // Check context type
    const type_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    if (!std.mem.eql(u8, type_s.ptr[0..type_s.len], "2d")) return quickjs.JS_NULL();

    // Get canvas dimensions from attributes or defaults
    var width: u32 = 300;
    var height: u32 = 150;
    var attr_len: usize = 0;
    const w_attr = lxb_dom_element_get_attribute(elem, "width", 5, &attr_len);
    if (w_attr) |wa| {
        width = std.fmt.parseInt(u32, wa[0..attr_len], 10) catch 300;
    }
    var h_attr_len: usize = 0;
    const h_attr = lxb_dom_element_get_attribute(elem, "height", 6, &h_attr_len);
    if (h_attr) |ha| {
        height = std.fmt.parseInt(u32, ha[0..h_attr_len], 10) catch 150;
    }

    const canvas_mod = @import("canvas.zig");
    return canvas_mod.createContext2D(c, width, height);
}

fn elementScrollIntoView(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Stub — actual scroll-to-element requires layout position lookup
    return quickjs.JS_UNDEFINED();
}

fn documentCreateComment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    // Return a minimal comment-like object
    const obj = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeType", qjs.JS_NewInt32(c, 8));
    _ = qjs.JS_SetPropertyStr(c, obj, "nodeName", qjs.JS_NewString(c, "#comment"));
    return obj;
}

fn documentAdoptNode(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    return qjs.JS_DupValue(c, args[0]);
}

fn documentImportNode(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    return qjs.JS_DupValue(c, args[0]);
}

fn documentCreateRange(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const range = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, range, "startOffset", qjs.JS_NewInt32(c, 0));
    _ = qjs.JS_SetPropertyStr(c, range, "endOffset", qjs.JS_NewInt32(c, 0));
    _ = qjs.JS_SetPropertyStr(c, range, "collapsed", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(c, range, "setStart", qjs.JS_NewCFunction(c, &jsReturnNull, "setStart", 2));
    _ = qjs.JS_SetPropertyStr(c, range, "setEnd", qjs.JS_NewCFunction(c, &jsReturnNull, "setEnd", 2));
    _ = qjs.JS_SetPropertyStr(c, range, "selectNode", qjs.JS_NewCFunction(c, &jsReturnNull, "selectNode", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "selectNodeContents", qjs.JS_NewCFunction(c, &jsReturnNull, "selectNodeContents", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "collapse", qjs.JS_NewCFunction(c, &jsReturnNull, "collapse", 1));
    _ = qjs.JS_SetPropertyStr(c, range, "cloneRange", qjs.JS_NewCFunction(c, &documentCreateRange, "cloneRange", 0));
    _ = qjs.JS_SetPropertyStr(c, range, "getBoundingClientRect", qjs.JS_NewCFunction(c, &elementGetBoundingClientRect, "getBoundingClientRect", 0));
    return range;
}

fn documentCreateTreeWalker(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const walker = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, walker, "currentNode", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, walker, "nextNode", qjs.JS_NewCFunction(c, &jsReturnNull, "nextNode", 0));
    _ = qjs.JS_SetPropertyStr(c, walker, "previousNode", qjs.JS_NewCFunction(c, &jsReturnNull, "previousNode", 0));
    _ = qjs.JS_SetPropertyStr(c, walker, "firstChild", qjs.JS_NewCFunction(c, &jsReturnNull, "firstChild", 0));
    _ = qjs.JS_SetPropertyStr(c, walker, "lastChild", qjs.JS_NewCFunction(c, &jsReturnNull, "lastChild", 0));
    _ = qjs.JS_SetPropertyStr(c, walker, "parentNode", qjs.JS_NewCFunction(c, &jsReturnNull, "parentNode", 0));
    return walker;
}

fn jsReturnNull(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_NULL();
}

fn nodeIsEqualNode(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node_a = getNode(c, this_val);
    const node_b = getNode(c, args[0]);
    return quickjs.JS_NewBool(node_a != null and node_b != null and node_a.? == node_b.?);
}

fn nodeCompareDocumentPosition(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_NewInt32(c, 0);
    const args = argv orelse return qjs.JS_NewInt32(c, 0);
    const node_a = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 1);
    const node_b = getNode(c, args[0]) orelse return qjs.JS_NewInt32(c, 1);
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

fn elementGetElementsByClassName(
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

    // Build CSS selector: ".className"
    const class_name = s.ptr[0..s.len];
    var selector_buf: [256]u8 = undefined;
    if (class_name.len + 1 > selector_buf.len) return quickjs.JS_NULL();
    selector_buf[0] = '.';
    @memcpy(selector_buf[1 .. 1 + class_name.len], class_name);
    const selector = selector_buf[0 .. 1 + class_name.len];

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, node, selector, arr, &idx);
    return arr;
}

fn elementGetElementsByTagName(
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

/// Helper: get Box dimensions for the element attached to this_val.
fn getBoxForThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*const Box {
    const root = g_root_box orelse return null;
    const node = getNodeFromThis(ctx, this_val) orelse return null;
    return findBoxForNode(root, node);
}

fn getNodeFromThis(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    // Try element class first, then text class
    const ptr1 = qjs.JS_GetOpaque2(ctx, this_val, element_class_id);
    if (ptr1) |p| return @ptrCast(@alignCast(p));
    const ptr2 = qjs.JS_GetOpaque2(ctx, this_val, text_class_id);
    if (ptr2) |p| return @ptrCast(@alignCast(p));
    return null;
}

fn elementGetOffsetWidth(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.width));
    }
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetHeight(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.height));
    }
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetTop(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.y));
    }
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetOffsetLeft(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        return qjs.JS_NewInt32(c, @intFromFloat(bbox.x));
    }
    return qjs.JS_NewInt32(c, 0);
}

fn elementGetBoundingClientRect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    if (getBoxForThis(c, this_val)) |box| {
        const bbox = box.borderBox();
        _ = qjs.JS_SetPropertyStr(c, obj, "x", qjs.JS_NewFloat64(c, bbox.x));
        _ = qjs.JS_SetPropertyStr(c, obj, "y", qjs.JS_NewFloat64(c, bbox.y));
        _ = qjs.JS_SetPropertyStr(c, obj, "top", qjs.JS_NewFloat64(c, bbox.y));
        _ = qjs.JS_SetPropertyStr(c, obj, "left", qjs.JS_NewFloat64(c, bbox.x));
        _ = qjs.JS_SetPropertyStr(c, obj, "width", qjs.JS_NewFloat64(c, bbox.width));
        _ = qjs.JS_SetPropertyStr(c, obj, "height", qjs.JS_NewFloat64(c, bbox.height));
        _ = qjs.JS_SetPropertyStr(c, obj, "right", qjs.JS_NewFloat64(c, bbox.x + bbox.width));
        _ = qjs.JS_SetPropertyStr(c, obj, "bottom", qjs.JS_NewFloat64(c, bbox.y + bbox.height));
    } else {
        _ = qjs.JS_SetPropertyStr(c, obj, "x", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "y", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "top", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "left", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "width", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "height", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "right", qjs.JS_NewFloat64(c, 0));
        _ = qjs.JS_SetPropertyStr(c, obj, "bottom", qjs.JS_NewFloat64(c, 0));
    }
    return obj;
}

fn elementGetScrollTop(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(scroll_y));
}

fn elementGetScrollLeft(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intFromFloat(scroll_x));
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
    if (selector.len == 0) return null;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return null;

    // Handle comma-separated selectors (e.g. ".foo, .bar")
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |_| {
        var comma_iter = std.mem.splitScalar(u8, trimmed, ',');
        while (comma_iter.next()) |sub_sel| {
            const sub = std.mem.trim(u8, sub_sel, " \t");
            if (sub.len > 0) {
                if (walkTreeBySelector(node, sub)) |found| return found;
            }
        }
        return null;
    }

    // Parse selector with combinators (>, +, ~, space)
    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return null;
    const parts = parts_buf[0..part_count];

    var current: ?*lxb.lxb_dom_node_t = node;
    while (current) |n| {
        if (nodeMatchesCompound(n, parts)) return n;
        current = nextDfsNode(n, node);
    }
    return null;
}

/// Match a single simple selector: #id, .class, tag, tag.class, tag#id
fn walkTreeBySimpleSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    if (selector.len == 0) return null;

    if (selector[0] == '#') {
        // ID selector
        return walkTreeById(node, selector[1..]);
    } else if (selector[0] == '.') {
        // Class selector
        return walkTreeByClass(node, selector[1..]);
    } else {
        // Check for tag.class or tag#id compound (e.g. "div.special")
        if (std.mem.indexOfScalar(u8, selector, '.')) |dot_idx| {
            // tag.class — find by tag first, then filter by class
            return walkTreeByTagAndClass(node, selector[0..dot_idx], selector[dot_idx + 1 ..]);
        }
        if (std.mem.indexOfScalar(u8, selector, '#')) |hash_idx| {
            // tag#id — find by id (tag is redundant but valid)
            return walkTreeById(node, selector[hash_idx + 1 ..]);
        }
        // Tag name selector
        return walkTreeByTag(node, selector);
    }
}

fn walkTreeByTagAndClass(root: *lxb.lxb_dom_node_t, tag_name: []const u8, class_name: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            // Check tag name
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len == tag_name.len and
                std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], tag_name))
            {
                // Check class
                var val_len: usize = 0;
                const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
                if (val != null and val_len > 0 and classContains(val.?[0..val_len], class_name)) return node;
            }
        }
        current = nextDfsNode(node, root);
    }
    return null;
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

fn documentGetElementsByClassName(
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

    var selector_buf: [256]u8 = undefined;
    const class_name = s.ptr[0..s.len];
    if (class_name.len + 1 > selector_buf.len) return quickjs.JS_NULL();
    selector_buf[0] = '.';
    @memcpy(selector_buf[1 .. 1 + class_name.len], class_name);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, doc_node, selector_buf[0 .. 1 + class_name.len], arr, &idx);
    return arr;
}

fn documentGetElementsByTagName(
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

fn documentGetElementsByName(
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

    var selector_buf: [270]u8 = undefined;
    const name = s.ptr[0..s.len];
    const prefix = "[name=\"";
    const suffix = "\"]";
    if (prefix.len + name.len + suffix.len > selector_buf.len) return quickjs.JS_NULL();
    @memcpy(selector_buf[0..prefix.len], prefix);
    @memcpy(selector_buf[prefix.len .. prefix.len + name.len], name);
    @memcpy(selector_buf[prefix.len + name.len .. prefix.len + name.len + suffix.len], suffix);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    const doc_node = getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, doc_node, selector_buf[0 .. prefix.len + name.len + suffix.len], arr, &idx);
    return arr;
}

/// Check if an element node matches a single simple selector (#id, .class, tag, tag.class)
fn nodeMatchesSimple(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    if (selector.len == 0) return false;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    if (selector[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        return val != null and val_len == selector.len - 1 and
            std.mem.eql(u8, val.?[0..val_len], selector[1..]);
    } else if (selector[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        return val != null and val_len > 0 and classContains(val.?[0..val_len], selector[1..]);
    } else if (std.mem.indexOfScalar(u8, selector, '.')) |dot_idx| {
        // tag.class
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr == null or name_len != dot_idx or
            !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector[0..dot_idx])) return false;
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        return val != null and val_len > 0 and classContains(val.?[0..val_len], selector[dot_idx + 1 ..]);
    } else if (std.mem.indexOfScalar(u8, selector, '[')) |bracket_idx| {
        // tag[attr="value"] — basic attribute selector
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (bracket_idx > 0) {
            if (name_ptr == null or name_len != bracket_idx or
                !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector[0..bracket_idx])) return false;
        }
        // Parse [attr="value"]
        const attr_sel = selector[bracket_idx + 1 ..];
        const close = std.mem.indexOfScalar(u8, attr_sel, ']') orelse return false;
        const attr_inner = attr_sel[0..close];
        if (std.mem.indexOf(u8, attr_inner, "=\"")) |eq_idx| {
            const attr_name = attr_inner[0..eq_idx];
            const attr_val = std.mem.trim(u8, attr_inner[eq_idx + 2 ..], "\"'");
            var av_len: usize = 0;
            const av = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &av_len);
            return av != null and av_len == attr_val.len and std.mem.eql(u8, av.?[0..av_len], attr_val);
        }
        // [attr] — existence check
        var av_len: usize = 0;
        return lxb_dom_element_get_attribute(elem, attr_inner.ptr, attr_inner.len, &av_len) != null;
    } else {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        return name_ptr != null and name_len == selector.len and
            std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector);
    }
}

/// Combinator type between selector parts
const Combinator = enum { descendant, child, adjacent_sibling, general_sibling };

/// A parsed selector segment: simple selector + combinator to the next part
const SelectorPart = struct {
    selector: []const u8,
    combinator: Combinator, // combinator BEFORE this part (from the previous part to this one)
};

/// Parse a full CSS selector string into parts with combinators.
/// "div > .class + span ~ p" → [{div, descendant}, {.class, child}, {span, adjacent_sibling}, {p, general_sibling}]
fn parseSelectorParts(trimmed: []const u8, out: []SelectorPart) usize {
    var count: usize = 0;
    var i: usize = 0;
    var next_combinator: Combinator = .descendant;

    while (i < trimmed.len and count < out.len) {
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        if (i >= trimmed.len) break;

        // Check for combinator tokens
        if (trimmed[i] == '>') {
            next_combinator = .child;
            i += 1;
            continue;
        } else if (trimmed[i] == '+') {
            next_combinator = .adjacent_sibling;
            i += 1;
            continue;
        } else if (trimmed[i] == '~') {
            next_combinator = .general_sibling;
            i += 1;
            continue;
        }

        // Read selector token (until space or combinator)
        const start = i;
        while (i < trimmed.len) {
            const c = trimmed[i];
            if (c == ' ' or c == '\t' or c == '>' or c == '+' or c == '~') break;
            if (c == '[') {
                // Skip attribute selector brackets
                while (i < trimmed.len and trimmed[i] != ']') i += 1;
                if (i < trimmed.len) i += 1;
            } else {
                i += 1;
            }
        }

        if (i > start) {
            out[count] = .{ .selector = trimmed[start..i], .combinator = next_combinator };
            count += 1;
            next_combinator = .descendant; // default combinator is descendant (space)
        }
    }
    return count;
}

/// Check if a node matches a full compound selector with combinators (>, +, ~, space)
fn nodeMatchesCompound(node: *lxb.lxb_dom_node_t, parts: []const SelectorPart) bool {
    if (parts.len == 0) return false;
    // Last part must match the node itself
    if (!nodeMatchesSimple(node, parts[parts.len - 1].selector)) return false;
    if (parts.len == 1) return true;

    // Walk backwards through parts, checking relationships
    var current: *lxb.lxb_dom_node_t = node;
    var pi: usize = parts.len - 1;
    while (pi > 0) {
        pi -= 1;
        const part = parts[pi];
        const combinator = parts[pi + 1].combinator;

        switch (combinator) {
            .descendant => {
                // Any ancestor must match
                var ancestor: ?*lxb.lxb_dom_node_t = current.parent;
                var found = false;
                while (ancestor) |a| {
                    if (nodeMatchesSimple(a, part.selector)) {
                        current = a;
                        found = true;
                        break;
                    }
                    ancestor = a.parent;
                }
                if (!found) return false;
            },
            .child => {
                // Direct parent must match
                const parent = current.parent orelse return false;
                if (!nodeMatchesSimple(parent, part.selector)) return false;
                current = parent;
            },
            .adjacent_sibling => {
                // Previous element sibling must match
                const prev = prevElementSibling(current) orelse return false;
                if (!nodeMatchesSimple(prev, part.selector)) return false;
                current = prev;
            },
            .general_sibling => {
                // Any preceding element sibling must match
                var sib: ?*lxb.lxb_dom_node_t = prevElementSibling(current);
                var found = false;
                while (sib) |s| {
                    if (nodeMatchesSimple(s, part.selector)) {
                        current = s;
                        found = true;
                        break;
                    }
                    sib = prevElementSibling(s);
                }
                if (!found) return false;
            },
        }
    }
    return true;
}

/// Get previous element sibling (skip text/comment nodes)
fn prevElementSibling(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var cur: ?*lxb.lxb_dom_node_t = node.prev;
    while (cur) |c| {
        if (c.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return c;
        cur = c.prev;
    }
    return null;
}

/// Iterative querySelectorAll collector — supports compound selectors with combinators
fn walkTreeCollect(ctx: *qjs.JSContext, root: *lxb.lxb_dom_node_t, selector: []const u8, arr: qjs.JSValue, idx: *u32) void {
    if (selector.len == 0) return;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return;

    // Handle comma-separated selectors
    if (std.mem.indexOfScalar(u8, trimmed, ',')) |_| {
        var comma_iter = std.mem.splitScalar(u8, trimmed, ',');
        while (comma_iter.next()) |sub_sel| {
            const sub = std.mem.trim(u8, sub_sel, " \t");
            if (sub.len > 0) walkTreeCollect(ctx, root, sub, arr, idx);
        }
        return;
    }

    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return;
    const parts = parts_buf[0..part_count];

    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (nodeMatchesCompound(node, parts)) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, idx.*, wrapNode(ctx, node));
            idx.* += 1;
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

/// Extract domain from a URL (e.g., "https://www.example.com/path" -> "www.example.com")
fn extractDomain(url: []const u8) ?[]const u8 {
    // Skip scheme
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }
    // Take up to first '/' or end
    if (std.mem.indexOf(u8, rest, "/")) |idx| {
        rest = rest[0..idx];
    }
    // Remove port
    if (std.mem.indexOf(u8, rest, ":")) |idx| {
        rest = rest[0..idx];
    }
    if (rest.len == 0) return null;
    return rest;
}

fn documentGetCookie(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const web_api = @import("web_api.zig");
    const client = web_api.getHttpClient() orelse {
        return qjs.JS_NewStringLen(c, "", 0);
    };

    const domain = if (g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return qjs.JS_NewStringLen(c, "", 0);

    const cookies = client.getCookiesForDomain(std.heap.c_allocator, domain) orelse {
        return qjs.JS_NewStringLen(c, "", 0);
    };
    defer std.heap.c_allocator.free(cookies);
    return qjs.JS_NewStringLen(c, cookies.ptr, cookies.len);
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

    const web_api = @import("web_api.zig");
    const client = web_api.getHttpClient() orelse return quickjs.JS_UNDEFINED();

    const domain = if (g_current_url) |url| extractDomain(url) orelse "" else "";
    if (domain.len == 0) return quickjs.JS_UNDEFINED();

    client.setJsCookie(domain, s.ptr[0..s.len]);
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
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const url_s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, url_s.ptr);
    // Delegate to web_api for actual navigation
    const web_api = @import("web_api.zig");
    web_api.requestNavigation(url_s.ptr[0..url_s.len]);
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
    _ = qjs.JS_SetPropertyStr(ctx, loc, "replace", qjs.JS_NewCFunction(ctx, &windowLocationAssign, "replace", 1));
    _ = qjs.JS_SetPropertyStr(ctx, loc, "toString", qjs.JS_NewCFunction(ctx, &windowLocationToString, "toString", 0));

    return loc;
}

fn jsGetScrollX(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewFloat64(c, scroll_x);
}

fn jsGetScrollY(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewFloat64(c, scroll_y);
}

// ── window.scrollTo / window.scrollBy ───────────────────────────────

fn windowScrollTo(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // scrollTo(x, y) or scrollTo({top, left})
    if (argc >= 2) {
        var x_val: f64 = 0;
        var y_val: f64 = 0;
        _ = qjs.JS_ToFloat64(c, &x_val, args[0]);
        _ = qjs.JS_ToFloat64(c, &y_val, args[1]);
        pending_scroll_x = @floatCast(x_val);
        pending_scroll_y = @floatCast(y_val);
    } else {
        // Options object: {top, left, behavior}
        const opts = args[0];
        const top_val = qjs.JS_GetPropertyStr(c, opts, "top");
        const left_val = qjs.JS_GetPropertyStr(c, opts, "left");
        defer qjs.JS_FreeValue(c, top_val);
        defer qjs.JS_FreeValue(c, left_val);
        if (!quickjs.JS_IsUndefined(top_val)) {
            var y_val: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &y_val, top_val);
            pending_scroll_y = @floatCast(y_val);
        }
        if (!quickjs.JS_IsUndefined(left_val)) {
            var x_val: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &x_val, left_val);
            pending_scroll_x = @floatCast(x_val);
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn windowScrollBy(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    if (argc >= 2) {
        var dx: f64 = 0;
        var dy: f64 = 0;
        _ = qjs.JS_ToFloat64(c, &dx, args[0]);
        _ = qjs.JS_ToFloat64(c, &dy, args[1]);
        pending_scroll_x = scroll_x + @as(f32, @floatCast(dx));
        pending_scroll_y = scroll_y + @as(f32, @floatCast(dy));
    } else {
        const opts = args[0];
        const top_val = qjs.JS_GetPropertyStr(c, opts, "top");
        const left_val = qjs.JS_GetPropertyStr(c, opts, "left");
        defer qjs.JS_FreeValue(c, top_val);
        defer qjs.JS_FreeValue(c, left_val);
        if (!quickjs.JS_IsUndefined(top_val)) {
            var dy: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &dy, top_val);
            pending_scroll_y = scroll_y + @as(f32, @floatCast(dy));
        }
        if (!quickjs.JS_IsUndefined(left_val)) {
            var dx: f64 = 0;
            _ = qjs.JS_ToFloat64(c, &dx, left_val);
            pending_scroll_x = scroll_x + @as(f32, @floatCast(dx));
        }
    }
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

// ── innerText (getter/setter) ───────────────────────────────────────

fn elementGetInnerText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Simplified: return same as textContent (full CSS-aware version is too complex)
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var len: usize = 0;
    const ptr = lxb_dom_node_text_content(node, &len);
    if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
    return qjs.JS_NewStringLen(c, ptr.?, len);
}

fn elementSetInnerText(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Same as textContent setter: replace all children with a text node
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

// ── Element navigation properties ───────────────────────────────────

fn elementGetFirstElementChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, ch);
        child = ch.next;
    }
    return quickjs.JS_NULL();
}

fn elementGetLastElementChild(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var child: ?*lxb.lxb_dom_node_t = lxb_dom_node_last_child_noi(node);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, ch);
        child = lxb_dom_node_prev_noi(ch);
    }
    return quickjs.JS_NULL();
}

fn elementGetNextElementSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var sib: ?*lxb.lxb_dom_node_t = node.next;
    while (sib) |s| {
        if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, s);
        sib = s.next;
    }
    return quickjs.JS_NULL();
}

fn elementGetPreviousElementSibling(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return quickjs.JS_NULL();
    var sib: ?*lxb.lxb_dom_node_t = lxb_dom_node_prev_noi(node);
    while (sib) |s| {
        if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return wrapNode(c, s);
        sib = lxb_dom_node_prev_noi(s);
    }
    return quickjs.JS_NULL();
}

fn elementGetChildElementCount(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = getNode(c, this_val) orelse return qjs.JS_NewInt32(c, 0);
    var count: i32 = 0;
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) count += 1;
        child = ch.next;
    }
    return qjs.JS_NewInt32(c, count);
}

// ── HTMLElement.hidden getter/setter ─────────────────────────────────

fn elementGetHidden(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_NewBool(false);
    var attr_len: usize = 0;
    const attr_ptr = lxb_dom_element_get_attribute(elem, "hidden", 6, &attr_len);
    // hidden attribute exists = true (even if empty string)
    return quickjs.JS_NewBool(attr_ptr != null);
}

fn elementSetHidden(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return quickjs.JS_UNDEFINED();

    const val = qjs.JS_ToBool(c, args[0]);
    if (val > 0) {
        // Set hidden attribute
        _ = lxb.lxb_dom_element_set_attribute(elem, "hidden", 6, "", 0);
    } else {
        // Remove hidden attribute
        _ = lxb.lxb_dom_element_remove_attribute(elem, "hidden", 6);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── input.value / textarea.value / select.value ─────────────────────

fn elementGetValue(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const elem = getElement(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);

    // Check tag name
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return qjs.JS_NewStringLen(c, "", 0);
    const tag = name_ptr.?[0..name_len];

    if (std.mem.eql(u8, tag, "textarea")) {
        // textarea: value = textContent
        const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
        var len: usize = 0;
        const ptr = lxb_dom_node_text_content(node, &len);
        if (ptr == null or len == 0) return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, ptr.?, len);
    } else if (std.mem.eql(u8, tag, "select")) {
        // select: find selected option's value
        return getSelectedOptionValue(c, @ptrCast(elem));
    } else {
        // input and other elements: use "value" attribute
        var attr_len: usize = 0;
        const attr_ptr = lxb_dom_element_get_attribute(elem, "value", 5, &attr_len);
        if (attr_ptr == null) return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, attr_ptr.?, attr_len);
    }
}

fn elementSetValue(
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

    // Check tag name
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr == null) return quickjs.JS_UNDEFINED();
    const tag = name_ptr.?[0..name_len];

    if (std.mem.eql(u8, tag, "textarea")) {
        // textarea: set textContent
        const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
        _ = lxb_dom_node_text_content_set(node, s.ptr, s.len);
    } else {
        // input, select, etc.: set "value" attribute
        _ = lxb_dom_element_set_attribute(elem, "value", 5, s.ptr, s.len);
    }
    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

fn getSelectedOptionValue(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    // Walk children to find first <option> with "selected" attribute, or first <option>
    var first_option_value: ?struct { ptr: [*]const u8, len: usize } = null;
    var child = lxb.lxb_dom_node_first_child(node);
    while (child) |ch| : (child = lxb.lxb_dom_node_next(ch)) {
        if (ch.*.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) continue;
        const ch_elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
        var ch_name_len: usize = 0;
        const ch_name = lxb_dom_element_local_name(ch_elem, &ch_name_len);
        if (ch_name == null) continue;
        if (!std.mem.eql(u8, ch_name.?[0..ch_name_len], "option")) continue;

        var val_len: usize = 0;
        const val_ptr = lxb_dom_element_get_attribute(ch_elem, "value", 5, &val_len);

        // Check if this option has "selected" attribute (boolean attribute)
        if (lxb_dom_element_has_attribute(ch_elem, "selected", 8)) {
            // This is the selected option
            if (val_ptr) |vp| {
                return qjs.JS_NewStringLen(ctx, vp, val_len);
            }
            // No value attribute, use textContent
            var tc_len: usize = 0;
            const tc = lxb_dom_node_text_content(ch, &tc_len);
            if (tc) |t| return qjs.JS_NewStringLen(ctx, t, tc_len);
            return qjs.JS_NewStringLen(ctx, "", 0);
        }

        // Track first option as default
        if (first_option_value == null) {
            if (val_ptr) |vp| {
                first_option_value = .{ .ptr = vp, .len = val_len };
            } else {
                var tc_len: usize = 0;
                const tc = lxb_dom_node_text_content(ch, &tc_len);
                if (tc) |t| {
                    first_option_value = .{ .ptr = t, .len = tc_len };
                }
            }
        }
    }

    // No selected attribute found, return first option's value
    if (first_option_value) |v| {
        return qjs.JS_NewStringLen(ctx, v.ptr, v.len);
    }
    return qjs.JS_NewStringLen(ctx, "", 0);
}

// ── getComputedStyle() ──────────────────────────────────────────────

fn computedStyleGetPropertyValue(
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

    const prop_s = jsStringToSlice(c, args[0]) orelse return qjs.JS_NewStringLen(c, "", 0);
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const prop = prop_s.ptr[0..prop_s.len];

    // Try cascade computed style first
    const node = getNode(c, elem_val);
    if (node != null and g_styles != null) {
        if (g_styles.?.get(@intFromPtr(node.?))) |style| {
            return computedStyleToString(c, &style, prop);
        }
    }

    // Fallback: read from inline style attribute
    const elem = getElement(c, elem_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var style_len: usize = 0;
    const style_ptr = lxb_dom_element_get_attribute(elem, "style", 5, &style_len);
    if (style_ptr != null and style_len > 0) {
        if (getStyleProperty(style_ptr.?[0..style_len], prop)) |val| {
            return qjs.JS_NewStringLen(c, val.ptr, val.len);
        }
    }
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Convert a ComputedStyle field to a CSS string for getComputedStyle.
fn computedStyleToString(c: *qjs.JSContext, style: *const ComputedStyle, prop: []const u8) qjs.JSValue {
    // Format buffer for numeric values
    var buf: [128]u8 = undefined;

    if (std.mem.eql(u8, prop, "display")) {
        const s = switch (style.display) {
            .block => "block",
            .inline_ => "inline",
            .none => "none",
            .flex => "flex",
            .inline_block => "inline-block",
            .inline_flex => "inline-flex",
            .grid => "grid",
            .inline_grid => "inline-grid",
            .table => "table",
            .table_row => "table-row",
            .table_cell => "table-cell",
            .list_item => "list-item",
            else => "block",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "position")) {
        const s = switch (style.position) {
            .static_ => "static",
            .relative => "relative",
            .absolute => "absolute",
            .fixed => "fixed",
            .sticky => "sticky",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "visibility")) {
        const s = switch (style.visibility) {
            .visible => "visible",
            .hidden => "hidden",
            .collapse => "collapse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "color")) {
        return argbToCssColor(c, style.color, &buf);
    } else if (std.mem.eql(u8, prop, "background-color")) {
        return argbToCssColor(c, style.background_color, &buf);
    } else if (std.mem.eql(u8, prop, "font-size")) {
        return fmtPx(c, style.font_size_px, &buf);
    } else if (std.mem.eql(u8, prop, "font-weight")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.font_weight}) catch return qjs.JS_NewStringLen(c, "400", 3);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "font-family")) {
        const s = switch (style.font_family) {
            .sans_serif => "sans-serif",
            .serif => "serif",
            .monospace => "monospace",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "text-align")) {
        const s = switch (style.text_align) {
            .left => "left",
            .right => "right",
            .center => "center",
            .justify => "justify",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "width")) {
        return dimensionToString(c, style.width, &buf);
    } else if (std.mem.eql(u8, prop, "height")) {
        return dimensionToString(c, style.height, &buf);
    } else if (std.mem.eql(u8, prop, "margin-top")) {
        return fmtPx(c, style.margin_top, &buf);
    } else if (std.mem.eql(u8, prop, "margin-right")) {
        return fmtPx(c, style.margin_right, &buf);
    } else if (std.mem.eql(u8, prop, "margin-bottom")) {
        return fmtPx(c, style.margin_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "margin-left")) {
        return fmtPx(c, style.margin_left, &buf);
    } else if (std.mem.eql(u8, prop, "padding-top")) {
        return fmtPx(c, style.padding_top, &buf);
    } else if (std.mem.eql(u8, prop, "padding-right")) {
        return fmtPx(c, style.padding_right, &buf);
    } else if (std.mem.eql(u8, prop, "padding-bottom")) {
        return fmtPx(c, style.padding_bottom, &buf);
    } else if (std.mem.eql(u8, prop, "padding-left")) {
        return fmtPx(c, style.padding_left, &buf);
    } else if (std.mem.eql(u8, prop, "border-top-width")) {
        return fmtPx(c, style.border_top_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-right-width")) {
        return fmtPx(c, style.border_right_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-bottom-width")) {
        return fmtPx(c, style.border_bottom_width, &buf);
    } else if (std.mem.eql(u8, prop, "border-left-width")) {
        return fmtPx(c, style.border_left_width, &buf);
    } else if (std.mem.eql(u8, prop, "opacity")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.opacity}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "z-index")) {
        if (style.z_index == 0 and style.position == .static_) {
            return qjs.JS_NewStringLen(c, "auto", 4);
        }
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.z_index}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "overflow-x")) {
        return overflowToString(c, style.overflow_x);
    } else if (std.mem.eql(u8, prop, "overflow-y")) {
        return overflowToString(c, style.overflow_y);
    } else if (std.mem.eql(u8, prop, "flex-direction")) {
        const s = switch (style.flex_direction) {
            .row => "row",
            .row_reverse => "row-reverse",
            .column => "column",
            .column_reverse => "column-reverse",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "flex-grow")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_grow}) catch return qjs.JS_NewStringLen(c, "0", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "flex-shrink")) {
        const result = std.fmt.bufPrint(&buf, "{d}", .{style.flex_shrink}) catch return qjs.JS_NewStringLen(c, "1", 1);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (std.mem.eql(u8, prop, "box-sizing")) {
        const s = switch (style.box_sizing) {
            .content_box => "content-box",
            .border_box => "border-box",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else if (std.mem.eql(u8, prop, "float")) {
        const s = switch (style.float_) {
            .none => "none",
            .left => "left",
            .right => "right",
        };
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    }

    // Unknown property
    return qjs.JS_NewStringLen(c, "", 0);
}

/// Format an ARGB u32 as "rgb(r, g, b)" or "rgba(r, g, b, a)" string.
fn argbToCssColor(c: *qjs.JSContext, argb: u32, buf: *[128]u8) qjs.JSValue {
    const a = (argb >> 24) & 0xFF;
    const r = (argb >> 16) & 0xFF;
    const g_val = (argb >> 8) & 0xFF;
    const b_val = argb & 0xFF;
    if (a == 255) {
        const result = std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ r, g_val, b_val }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    } else if (a == 0 and r == 0 and g_val == 0 and b_val == 0) {
        const s = "rgba(0, 0, 0, 0)";
        return qjs.JS_NewStringLen(c, s.ptr, s.len);
    } else {
        const alpha: f32 = @as(f32, @floatFromInt(a)) / 255.0;
        const result = std.fmt.bufPrint(buf, "rgba({d}, {d}, {d}, {d:.2})", .{ r, g_val, b_val, alpha }) catch return qjs.JS_NewStringLen(c, "", 0);
        return qjs.JS_NewStringLen(c, result.ptr, result.len);
    }
}

/// Format a px value as "Npx" string.
fn fmtPx(c: *qjs.JSContext, val: f32, buf: *[128]u8) qjs.JSValue {
    const result = std.fmt.bufPrint(buf, "{d}px", .{val}) catch return qjs.JS_NewStringLen(c, "0px", 3);
    return qjs.JS_NewStringLen(c, result.ptr, result.len);
}

/// Format a Dimension value.
fn dimensionToString(c: *qjs.JSContext, dim: ComputedStyle.Dimension, buf: *[128]u8) qjs.JSValue {
    return switch (dim) {
        .auto => qjs.JS_NewStringLen(c, "auto", 4),
        .none => qjs.JS_NewStringLen(c, "none", 4),
        .px => |v| fmtPx(c, v, buf),
        .percent => |v| blk: {
            const pct = std.fmt.bufPrint(buf, "{d}%", .{v}) catch break :blk qjs.JS_NewStringLen(c, "0%", 2);
            break :blk qjs.JS_NewStringLen(c, pct.ptr, pct.len);
        },
    };
}

/// Format Overflow enum.
fn overflowToString(c: *qjs.JSContext, overflow: ComputedStyle.Overflow) qjs.JSValue {
    const s = switch (overflow) {
        .visible => "visible",
        .hidden => "hidden",
        .scroll => "scroll",
        .auto_ => "auto",
    };
    return qjs.JS_NewStringLen(c, s.ptr, s.len);
}

fn windowGetComputedStyle(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Verify the argument is a valid element
    _ = getElement(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    // Build a CSSStyleDeclaration-like object backed by the element's inline style
    const obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(obj)) return obj;

    // Store element reference
    _ = qjs.JS_SetPropertyStr(c, obj, "__element", qjs.JS_DupValue(c, args[0]));

    // getPropertyValue method
    _ = qjs.JS_SetPropertyStr(c, obj, "getPropertyValue", qjs.JS_NewCFunction(c, &computedStyleGetPropertyValue, "getPropertyValue", 1));

    // Set up Proxy to allow reading common properties directly (e.g., cs.display)
    const global = qjs.JS_GetGlobalObject(c);
    _ = qjs.JS_SetPropertyStr(c, global, "__csTarget", obj);

    const proxy_code =
        \\(function() {
        \\  var t = globalThis.__csTarget;
        \\  delete globalThis.__csTarget;
        \\  return new Proxy(t, {
        \\    get: function(o,p) {
        \\      if (p in o) return o[p];
        \\      var map = {
        \\        backgroundColor:"background-color",fontSize:"font-size",
        \\        fontWeight:"font-weight",fontFamily:"font-family",
        \\        textAlign:"text-align",textDecoration:"text-decoration",
        \\        zIndex:"z-index",pointerEvents:"pointer-events"
        \\      };
        \\      var css = map[p] || p;
        \\      return o.getPropertyValue(css);
        \\    }
        \\  });
        \\})()
    ;

    const result = qjs.JS_Eval(c, proxy_code, proxy_code.len, "<computedStyle>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(c, global);

    if (quickjs.JS_IsException(result)) {
        const exc = qjs.JS_GetException(c);
        qjs.JS_FreeValue(c, exc);
        return qjs.JS_DupValue(c, obj);
    }
    return result;
}

// ── document.createDocumentFragment() ───────────────────────────────

fn documentCreateDocumentFragment(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // Simplified: create a div element (fragments are complex to implement properly)
    const c = ctx orelse return quickjs.JS_NULL();
    const doc = g_document orelse return quickjs.JS_NULL();
    const elem = lxb_dom_document_create_element(doc, "div", 3, null) orelse return quickjs.JS_NULL();
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    return wrapNode(c, node);
}

// ── document.readyState getter ──────────────────────────────────────

fn documentGetReadyState(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const state_str: []const u8 = switch (g_ready_state) {
        .loading => "loading",
        .interactive => "interactive",
        .complete => "complete",
    };
    return qjs.JS_NewString(c, state_str.ptr);
}

fn documentGetActiveElement(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (active_element) |node| {
        return wrapNode(c, node);
    }
    // Default: return document.body
    return documentGetBody(ctx, quickjs.JS_UNDEFINED(), 0, null);
}

// ── document.createEvent ────────────────────────────────────────────

fn documentCreateEvent(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    // Return an Event-like object with initEvent() method
    const js_code =
        \\(function(){var e={type:'',bubbles:false,cancelable:false,
        \\defaultPrevented:false,_stopped:false,isTrusted:false,eventPhase:0,
        \\preventDefault:function(){this.defaultPrevented=true;},
        \\stopPropagation:function(){this._stopped=true;},
        \\stopImmediatePropagation:function(){this._stopped=true;},
        \\initEvent:function(t,b,c){this.type=t;this.bubbles=b!==false;this.cancelable=c!==false;}
        \\};return e;})()
    ;
    return qjs.JS_Eval(c, js_code, js_code.len, "<createEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
}

// ── document.write ─────────────────────────────────────────────────

fn documentWrite(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Only works during loading phase
    if (g_ready_state != .loading) {
        std.log.warn("[JS] document.write called after page load, ignoring", .{});
        return quickjs.JS_UNDEFINED();
    }

    const str = qjs.JS_ToCString(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);
    const html = std.mem.span(str);

    if (html.len == 0) return quickjs.JS_UNDEFINED();

    std.log.info("[JS] document.write: {d} bytes", .{html.len});

    // Parse HTML fragment and append to body
    const doc_ptr = g_document orelse return quickjs.JS_UNDEFINED();
    const doc_node = getDocumentNode() orelse return quickjs.JS_UNDEFINED();
    const body_node = walkTreeByTag(doc_node, "body") orelse return quickjs.JS_UNDEFINED();
    const body_elem: *lxb.lxb_dom_element_t = @ptrCast(body_node);

    // Parse HTML fragment using lexbor
    const frag = lxb_html_document_parse_fragment(doc_ptr, body_elem, html.ptr, html.len) orelse return quickjs.JS_UNDEFINED();

    // Move children from fragment to body
    while (frag.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_child(body_node, child);
    }
    _ = lxb_dom_node_destroy(frag);

    // Check if <script> was injected (case-insensitive)
    {
        var has_script = false;
        var si: usize = 0;
        while (si + 7 < html.len) : (si += 1) {
            if (html[si] == '<' and
                (html[si + 1] == 's' or html[si + 1] == 'S') and
                (html[si + 2] == 'c' or html[si + 2] == 'C') and
                (html[si + 3] == 'r' or html[si + 3] == 'R') and
                (html[si + 4] == 'i' or html[si + 4] == 'I') and
                (html[si + 5] == 'p' or html[si + 5] == 'P') and
                (html[si + 6] == 't' or html[si + 6] == 'T'))
            {
                has_script = true;
                break;
            }
        }
        if (has_script) {
            std.log.warn("[JS] document.write injected <script> — execution not supported", .{});
        }
    }

    setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── No-op constructor for DOM interface globals ─────────────────────

fn jsNoOpConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewObject(c);
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

    // ── DOM Prototype Chain ──────────────────────────────────────────
    // EventTarget.prototype → Node.prototype → Element.prototype → HTMLElement.prototype
    // This mirrors the browser's prototype chain so instanceof checks work.

    const events = @import("events.zig");

    // ── EventTarget.prototype ──────────────────────────────────────
    const event_target_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, event_target_proto, "addEventListener", qjs.JS_NewCFunction(ctx, &events.jsAddEventListener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, event_target_proto, "removeEventListener", qjs.JS_NewCFunction(ctx, &events.jsRemoveEventListener, "removeEventListener", 2));

    // ── Node.prototype (inherits EventTarget.prototype) ────────────
    const node_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, node_proto, event_target_proto);

    // Node methods
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "appendChild", qjs.JS_NewCFunction(ctx, &elementAppendChild, "appendChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "removeChild", qjs.JS_NewCFunction(ctx, &elementRemoveChild, "removeChild", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "insertBefore", qjs.JS_NewCFunction(ctx, &elementInsertBefore, "insertBefore", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "contains", qjs.JS_NewCFunction(ctx, &elementContains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "cloneNode", qjs.JS_NewCFunction(ctx, &elementCloneNode, "cloneNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceWith", qjs.JS_NewCFunction(ctx, &elementReplaceWith, "replaceWith", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "replaceChild", qjs.JS_NewCFunction(ctx, &elementReplaceChild, "replaceChild", 2));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "before", qjs.JS_NewCFunction(ctx, &elementBefore, "before", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "after", qjs.JS_NewCFunction(ctx, &elementAfter, "after", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "remove", qjs.JS_NewCFunction(ctx, &elementRemove, "remove", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "append", qjs.JS_NewCFunction(ctx, &elementAppend, "append", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "prepend", qjs.JS_NewCFunction(ctx, &elementPrepend, "prepend", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "isEqualNode", qjs.JS_NewCFunction(ctx, &nodeIsEqualNode, "isEqualNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "normalize", qjs.JS_NewCFunction(ctx, &jsReturnNull, "normalize", 0));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "compareDocumentPosition", qjs.JS_NewCFunction(ctx, &nodeCompareDocumentPosition, "compareDocumentPosition", 1));

    // Node constants
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_proto, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));

    // Node getters
    {
        const textContentAtom = qjs.JS_NewAtom(ctx, "textContent");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, textContentAtom, qjs.JS_NewCFunction(ctx, &elementGetTextContent, "get textContent", 0), qjs.JS_NewCFunction(ctx, &elementSetTextContent, "set textContent", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, textContentAtom);
    }
    {
        const innerTextAtom = qjs.JS_NewAtom(ctx, "innerText");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, innerTextAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerText, "get innerText", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerText, "set innerText", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerTextAtom);
    }
    {
        const parentNodeAtom = qjs.JS_NewAtom(ctx, "parentNode");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentNodeAtom, qjs.JS_NewCFunction(ctx, &elementGetParentNode, "get parentNode", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentNodeAtom);
    }
    {
        const parentElementAtom = qjs.JS_NewAtom(ctx, "parentElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, parentElementAtom, qjs.JS_NewCFunction(ctx, &elementGetParentElement, "get parentElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, parentElementAtom);
    }
    {
        const firstChildAtom = qjs.JS_NewAtom(ctx, "firstChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, firstChildAtom, qjs.JS_NewCFunction(ctx, &elementGetFirstChild, "get firstChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, firstChildAtom);
    }
    {
        const lastChildAtom = qjs.JS_NewAtom(ctx, "lastChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, lastChildAtom, qjs.JS_NewCFunction(ctx, &elementGetLastChild, "get lastChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lastChildAtom);
    }
    {
        const nextSiblingAtom = qjs.JS_NewAtom(ctx, "nextSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nextSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetNextSibling, "get nextSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nextSiblingAtom);
    }
    {
        const prevSiblingAtom = qjs.JS_NewAtom(ctx, "previousSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, prevSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousSibling, "get previousSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, prevSiblingAtom);
    }
    {
        const childNodesAtom = qjs.JS_NewAtom(ctx, "childNodes");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, childNodesAtom, qjs.JS_NewCFunction(ctx, &elementGetChildNodes, "get childNodes", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childNodesAtom);
    }
    {
        const firstElementChildAtom = qjs.JS_NewAtom(ctx, "firstElementChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, firstElementChildAtom, qjs.JS_NewCFunction(ctx, &elementGetFirstElementChild, "get firstElementChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, firstElementChildAtom);
    }
    {
        const lastElementChildAtom = qjs.JS_NewAtom(ctx, "lastElementChild");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, lastElementChildAtom, qjs.JS_NewCFunction(ctx, &elementGetLastElementChild, "get lastElementChild", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, lastElementChildAtom);
    }
    {
        const nextElementSiblingAtom = qjs.JS_NewAtom(ctx, "nextElementSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nextElementSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetNextElementSibling, "get nextElementSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nextElementSiblingAtom);
    }
    {
        const previousElementSiblingAtom = qjs.JS_NewAtom(ctx, "previousElementSibling");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, previousElementSiblingAtom, qjs.JS_NewCFunction(ctx, &elementGetPreviousElementSibling, "get previousElementSibling", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, previousElementSiblingAtom);
    }
    {
        const childElementCountAtom = qjs.JS_NewAtom(ctx, "childElementCount");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, childElementCountAtom, qjs.JS_NewCFunction(ctx, &elementGetChildElementCount, "get childElementCount", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childElementCountAtom);
    }
    {
        const nodeTypeAtom = qjs.JS_NewAtom(ctx, "nodeType");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeTypeAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeType, "get nodeType", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeTypeAtom);
    }
    {
        const nodeNameAtom = qjs.JS_NewAtom(ctx, "nodeName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, node_proto, nodeNameAtom, qjs.JS_NewCFunction(ctx, &elementGetNodeName, "get nodeName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, nodeNameAtom);
    }

    // ── Element.prototype (inherits Node.prototype) ────────────────
    const elem_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, elem_proto, node_proto);

    // Element methods
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttribute", qjs.JS_NewCFunction(ctx, &elementGetAttribute, "getAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "setAttribute", qjs.JS_NewCFunction(ctx, &elementSetAttribute, "setAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "removeAttribute", qjs.JS_NewCFunction(ctx, &elementRemoveAttribute, "removeAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "hasAttribute", qjs.JS_NewCFunction(ctx, &elementHasAttribute, "hasAttribute", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "matches", qjs.JS_NewCFunction(ctx, &elementMatches, "matches", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "closest", qjs.JS_NewCFunction(ctx, &elementClosest, "closest", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getBoundingClientRect", qjs.JS_NewCFunction(ctx, &elementGetBoundingClientRect, "getBoundingClientRect", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelector", qjs.JS_NewCFunction(ctx, &elementQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "querySelectorAll", qjs.JS_NewCFunction(ctx, &elementQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &elementGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &elementGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "toggleAttribute", qjs.JS_NewCFunction(ctx, &elementToggleAttribute, "toggleAttribute", 2));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getAttributeNames", qjs.JS_NewCFunction(ctx, &elementGetAttributeNames, "getAttributeNames", 0));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "scrollIntoView", qjs.JS_NewCFunction(ctx, &elementScrollIntoView, "scrollIntoView", 1));
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "getContext", qjs.JS_NewCFunction(ctx, &elementGetContext, "getContext", 1));

    // Element getters
    {
        const tagNameAtom = qjs.JS_NewAtom(ctx, "tagName");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, tagNameAtom, qjs.JS_NewCFunction(ctx, &elementGetTagName, "get tagName", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, tagNameAtom);
    }
    {
        const idAtom = qjs.JS_NewAtom(ctx, "id");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, idAtom, qjs.JS_NewCFunction(ctx, &elementGetId, "get id", 0), qjs.JS_NewCFunction(ctx, &elementSetId, "set id", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, idAtom);
    }
    {
        const classNameAtom = qjs.JS_NewAtom(ctx, "className");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classNameAtom, qjs.JS_NewCFunction(ctx, &elementGetClassName, "get className", 0), qjs.JS_NewCFunction(ctx, &elementSetClassName, "set className", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classNameAtom);
    }
    {
        const classListAtom = qjs.JS_NewAtom(ctx, "classList");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, classListAtom, qjs.JS_NewCFunction(ctx, &elementGetClassList, "get classList", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, classListAtom);
    }
    {
        const innerHTMLAtom = qjs.JS_NewAtom(ctx, "innerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, innerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetInnerHTML, "get innerHTML", 0), qjs.JS_NewCFunction(ctx, &elementSetInnerHTML, "set innerHTML", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, innerHTMLAtom);
    }
    {
        const outerHTMLAtom = qjs.JS_NewAtom(ctx, "outerHTML");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, outerHTMLAtom, qjs.JS_NewCFunction(ctx, &elementGetOuterHTML, "get outerHTML", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, outerHTMLAtom);
    }
    {
        const childrenAtom = qjs.JS_NewAtom(ctx, "children");
        _ = qjs.JS_DefinePropertyGetSet(ctx, elem_proto, childrenAtom, qjs.JS_NewCFunction(ctx, &elementGetChildren, "get children", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, childrenAtom);
    }

    // insertAdjacentHTML
    _ = qjs.JS_SetPropertyStr(ctx, elem_proto, "insertAdjacentHTML", qjs.JS_NewCFunction(ctx, &elementInsertAdjacentHTML, "insertAdjacentHTML", 2));

    // ── HTMLElement.prototype (inherits Element.prototype) ──────────
    const html_element_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, html_element_proto, elem_proto);

    // HTMLElement getters
    {
        const styleAtom = qjs.JS_NewAtom(ctx, "style");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, styleAtom, qjs.JS_NewCFunction(ctx, &elementGetStyle, "get style", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, styleAtom);
    }
    {
        const datasetAtom = qjs.JS_NewAtom(ctx, "dataset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, datasetAtom, qjs.JS_NewCFunction(ctx, &elementGetDataset, "get dataset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, datasetAtom);
    }
    {
        const offsetWidthAtom = qjs.JS_NewAtom(ctx, "offsetWidth");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetWidthAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetWidth, "get offsetWidth", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetWidthAtom);
    }
    {
        const offsetHeightAtom = qjs.JS_NewAtom(ctx, "offsetHeight");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetHeightAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetHeight, "get offsetHeight", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetHeightAtom);
    }
    {
        const offsetTopAtom = qjs.JS_NewAtom(ctx, "offsetTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetTopAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetTop, "get offsetTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetTopAtom);
    }
    {
        const offsetLeftAtom = qjs.JS_NewAtom(ctx, "offsetLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, offsetLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetOffsetLeft, "get offsetLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, offsetLeftAtom);
    }
    {
        const scrollTopAtom = qjs.JS_NewAtom(ctx, "scrollTop");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollTopAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollTop, "get scrollTop", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollTopAtom);
    }
    {
        const scrollLeftAtom = qjs.JS_NewAtom(ctx, "scrollLeft");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, scrollLeftAtom, qjs.JS_NewCFunction(ctx, &elementGetScrollLeft, "get scrollLeft", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollLeftAtom);
    }
    {
        const hiddenAtom = qjs.JS_NewAtom(ctx, "hidden");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, hiddenAtom, qjs.JS_NewCFunction(ctx, &elementGetHidden, "get hidden", 0), qjs.JS_NewCFunction(ctx, &elementSetHidden, "set hidden", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, hiddenAtom);
    }

    // input.value / textarea.value / select.value
    {
        const valueAtom = qjs.JS_NewAtom(ctx, "value");
        _ = qjs.JS_DefinePropertyGetSet(ctx, html_element_proto, valueAtom, qjs.JS_NewCFunction(ctx, &elementGetValue, "get value", 0), qjs.JS_NewCFunction(ctx, &elementSetValue, "set value", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, valueAtom);
    }

    // Set HTMLElement.prototype as the class prototype (elements get this as their __proto__)
    qjs.JS_SetClassProto(ctx, element_class_id, qjs.JS_DupValue(ctx, html_element_proto));

    // ── Expose constructors as globals for instanceof ──────────────
    const global = qjs.JS_GetGlobalObject(ctx);

    const event_target_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "EventTarget", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, event_target_ctor, "prototype", qjs.JS_DupValue(ctx, event_target_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "EventTarget", event_target_ctor);

    const node_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Node", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "prototype", qjs.JS_DupValue(ctx, node_proto));
    // Node constants on the constructor too
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "ELEMENT_NODE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "TEXT_NODE", qjs.JS_NewInt32(ctx, 3));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "COMMENT_NODE", qjs.JS_NewInt32(ctx, 8));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_NODE", qjs.JS_NewInt32(ctx, 9));
    _ = qjs.JS_SetPropertyStr(ctx, node_ctor, "DOCUMENT_FRAGMENT_NODE", qjs.JS_NewInt32(ctx, 11));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Node", node_ctor);

    const element_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Element", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, element_ctor, "prototype", qjs.JS_DupValue(ctx, elem_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "Element", element_ctor);

    const html_element_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "HTMLElement", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, html_element_ctor, "prototype", qjs.JS_DupValue(ctx, html_element_proto));
    _ = qjs.JS_SetPropertyStr(ctx, global, "HTMLElement", html_element_ctor);

    // HTML element subclass constructors (for instanceof checks)
    const html_subclasses = [_][]const u8{
        "HTMLDivElement",       "HTMLSpanElement",      "HTMLParagraphElement",
        "HTMLImageElement",     "HTMLAnchorElement",    "HTMLFormElement",
        "HTMLInputElement",     "HTMLTextAreaElement",  "HTMLSelectElement",
        "HTMLButtonElement",    "HTMLTableElement",     "HTMLTableRowElement",
        "HTMLTableCellElement", "HTMLLIElement",        "HTMLUListElement",
        "HTMLOListElement",     "HTMLHeadingElement",   "HTMLPreElement",
        "HTMLCanvasElement",    "HTMLVideoElement",     "HTMLAudioElement",
        "HTMLIFrameElement",    "HTMLLabelElement",     "HTMLScriptElement",
        "HTMLStyleElement",     "HTMLLinkElement",      "HTMLMetaElement",
        "HTMLBRElement",        "HTMLHRElement",        "HTMLBodyElement",
        "HTMLHeadElement",      "HTMLHtmlElement",      "HTMLOptionElement",
        "HTMLTemplateElement",  "HTMLDialogElement",    "HTMLDetailsElement",
        "HTMLSummaryElement",   "HTMLFieldSetElement",  "HTMLLegendElement",
    };
    for (html_subclasses) |name| {
        const ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, name.ptr, 0, qjs.JS_CFUNC_constructor, 0);
        _ = qjs.JS_SetPropertyStr(ctx, ctor, "prototype", qjs.JS_DupValue(ctx, html_element_proto));
        _ = qjs.JS_SetPropertyStr(ctx, global, name.ptr, ctor);
    }

    // DOM interface constructors (for instanceof checks in frameworks)
    const window_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Window", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Window", window_ctor);

    const document_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Document", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Document", document_ctor);

    const doc_frag_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "DocumentFragment", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "DocumentFragment", doc_frag_ctor);

    const nodelist_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "NodeList", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "NodeList", nodelist_ctor);

    const htmlcol_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "HTMLCollection", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "HTMLCollection", htmlcol_ctor);

    const range_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Range", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Range", range_ctor);

    const comment_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Comment", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Comment", comment_ctor);

    const text_ctor = qjs.JS_NewCFunction2(ctx, &jsNoOpConstructor, "Text", 0, qjs.JS_CFUNC_constructor, 0);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Text", text_ctor);

    // window.top / window.parent / window.self / window.frames
    _ = qjs.JS_SetPropertyStr(ctx, global, "top", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "parent", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "frames", qjs.JS_DupValue(ctx, global));
    _ = qjs.JS_SetPropertyStr(ctx, global, "frameElement", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, global, "length", qjs.JS_NewInt32(ctx, 0)); // frames.length

    // Reflected HTML attributes (src, href, etc.) as property getters/setters
    {
        const reflected_js =
            \\(function(){
            \\  var EP=Element.prototype;
            \\  ['src','href','action','type','name','alt','title','rel','target','placeholder','method','enctype','lang','dir','for'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.getAttribute(a)||'';},set:function(v){this.setAttribute(a,v);},configurable:true});}
            \\  });
            \\  ['disabled','checked','selected'].forEach(function(a){
            \\    if(!(a in EP)){Object.defineProperty(EP,a,{get:function(){return this.hasAttribute(a);},set:function(v){if(v)this.setAttribute(a,'');else this.removeAttribute(a);},configurable:true});}
            \\  });
            \\})();
        ;
        const r = qjs.JS_Eval(ctx, reflected_js, reflected_js.len, "<reflected-attrs>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

    // ── Text prototype (inherits Node.prototype) ─────────────────────
    // Text nodes get Node methods (textContent, parentNode, etc.) via prototype chain.
    // No need to duplicate them — just set Node.prototype as the text proto's prototype.
    const text_proto = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPrototype(ctx, text_proto, node_proto);
    qjs.JS_SetClassProto(ctx, text_class_id, text_proto);

    // Free local proto references (class proto + constructors hold refs)
    qjs.JS_FreeValue(ctx, event_target_proto);
    qjs.JS_FreeValue(ctx, node_proto);
    qjs.JS_FreeValue(ctx, elem_proto);
    qjs.JS_FreeValue(ctx, html_element_proto);

    // Build document global
    const doc_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementById", qjs.JS_NewCFunction(ctx, &documentGetElementById, "getElementById", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", qjs.JS_NewCFunction(ctx, &documentQuerySelector, "querySelector", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", qjs.JS_NewCFunction(ctx, &documentQuerySelectorAll, "querySelectorAll", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", qjs.JS_NewCFunction(ctx, &documentCreateElement, "createElement", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", qjs.JS_NewCFunction(ctx, &documentCreateTextNode, "createTextNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createDocumentFragment", qjs.JS_NewCFunction(ctx, &documentCreateDocumentFragment, "createDocumentFragment", 0));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createEvent", qjs.JS_NewCFunction(ctx, &documentCreateEvent, "createEvent", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "write", qjs.JS_NewCFunction(ctx, &documentWrite, "write", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "writeln", qjs.JS_NewCFunction(ctx, &documentWrite, "writeln", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByClassName", qjs.JS_NewCFunction(ctx, &documentGetElementsByClassName, "getElementsByClassName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByTagName", qjs.JS_NewCFunction(ctx, &documentGetElementsByTagName, "getElementsByTagName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "getElementsByName", qjs.JS_NewCFunction(ctx, &documentGetElementsByName, "getElementsByName", 1));

    // document.adoptNode / importNode (stub — return the node as-is)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "adoptNode", qjs.JS_NewCFunction(ctx, &documentAdoptNode, "adoptNode", 1));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "importNode", qjs.JS_NewCFunction(ctx, &documentImportNode, "importNode", 2));
    // document.createRange (stub)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createRange", qjs.JS_NewCFunction(ctx, &documentCreateRange, "createRange", 0));
    // document.createTreeWalker (stub)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTreeWalker", qjs.JS_NewCFunction(ctx, &documentCreateTreeWalker, "createTreeWalker", 3));
    // document.createNodeIterator (stub)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createNodeIterator", qjs.JS_NewCFunction(ctx, &documentCreateTreeWalker, "createNodeIterator", 3));

    // document.readyState (getter)
    const readyStateAtom = qjs.JS_NewAtom(ctx, "readyState");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, readyStateAtom, qjs.JS_NewCFunction(ctx, &documentGetReadyState, "get readyState", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, readyStateAtom);

    // document.activeElement (getter)
    {
        const activeElementAtom = qjs.JS_NewAtom(ctx, "activeElement");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, activeElementAtom, qjs.JS_NewCFunction(ctx, &documentGetActiveElement, "get activeElement", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, activeElementAtom);
    }

    // document.location (alias to window.location)
    {
        const loc = qjs.JS_GetPropertyStr(ctx, global, "location");
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "location", loc);
    }

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

    // document.currentScript (null when not in script execution)
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "currentScript", quickjs.JS_NULL());

    // document.head (getter)
    const headAtom = qjs.JS_NewAtom(ctx, "head");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, headAtom, qjs.JS_NewCFunction(ctx, &documentGetHead, "get head", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, headAtom);

    // document.cookie (getter/setter)
    const cookieAtom = qjs.JS_NewAtom(ctx, "cookie");
    _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, cookieAtom, qjs.JS_NewCFunction(ctx, &documentGetCookie, "get cookie", 0), qjs.JS_NewCFunction(ctx, &documentSetCookie, "set cookie", 1), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    qjs.JS_FreeAtom(ctx, cookieAtom);

    // document.URL / referrer / domain
    if (g_current_url) |url| {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "URL", qjs.JS_NewStringLen(ctx, url.ptr, url.len));
        const domain = extractDomain(url) orelse "";
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "domain", qjs.JS_NewStringLen(ctx, domain.ptr, domain.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "URL", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "domain", qjs.JS_NewString(ctx, ""));
    }
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "referrer", qjs.JS_NewString(ctx, ""));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createComment", qjs.JS_NewCFunction(ctx, &documentCreateComment, "createComment", 1));

    // Document properties required by jQuery/Sizzle
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "nodeType", qjs.JS_NewInt32(ctx, 9)); // DOCUMENT_NODE
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "defaultView", qjs.JS_DupValue(ctx, global)); // window
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "ownerDocument", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "compatMode", qjs.JS_NewString(ctx, "CSS1Compat"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "contentType", qjs.JS_NewString(ctx, "text/html"));
    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "characterSet", qjs.JS_NewString(ctx, "UTF-8"));

    // document.forms / links / images (query-based getters)
    {
        const forms_js = "(function(){return document.querySelectorAll('form');})";
        const formsAtom = qjs.JS_NewAtom(ctx, "forms");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, formsAtom, qjs.JS_Eval(ctx, forms_js, forms_js.len, "<forms>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, formsAtom);
    }
    {
        const links_js = "(function(){return document.querySelectorAll('a[href],area[href]');})";
        const linksAtom = qjs.JS_NewAtom(ctx, "links");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, linksAtom, qjs.JS_Eval(ctx, links_js, links_js.len, "<links>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, linksAtom);
    }
    {
        const images_js = "(function(){return document.querySelectorAll('img');})";
        const imagesAtom = qjs.JS_NewAtom(ctx, "images");
        _ = qjs.JS_DefinePropertyGetSet(ctx, doc_obj, imagesAtom, qjs.JS_Eval(ctx, images_js, images_js.len, "<images>", qjs.JS_EVAL_TYPE_GLOBAL), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, imagesAtom);
    }

    // document.implementation (jQuery feature detection uses createHTMLDocument)
    {
        const impl = qjs.JS_NewObject(ctx);
        const create_html_doc_js = "(function(title) { return document; })";
        _ = qjs.JS_SetPropertyStr(ctx, impl, "createHTMLDocument", qjs.JS_Eval(ctx,
            create_html_doc_js, create_html_doc_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        const has_feature_js = "(function() { return true; })";
        _ = qjs.JS_SetPropertyStr(ctx, impl, "hasFeature", qjs.JS_Eval(ctx,
            has_feature_js, has_feature_js.len, "<impl>", qjs.JS_EVAL_TYPE_GLOBAL));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "implementation", impl);
    }

    // Set document global (reuses `global` from constructor registration above)
    _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);

    // window.location
    _ = qjs.JS_SetPropertyStr(ctx, global, "location", createLocationObject(ctx));

    // window.getComputedStyle
    _ = qjs.JS_SetPropertyStr(ctx, global, "getComputedStyle", qjs.JS_NewCFunction(ctx, &windowGetComputedStyle, "getComputedStyle", 1));

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

    // window.scrollX / scrollY / pageXOffset / pageYOffset
    {
        const scrollXAtom = qjs.JS_NewAtom(ctx, "scrollX");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, scrollXAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollX, "get scrollX", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollXAtom);
    }
    {
        const scrollYAtom = qjs.JS_NewAtom(ctx, "scrollY");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, scrollYAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollY, "get scrollY", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, scrollYAtom);
    }
    {
        const pageXOffsetAtom = qjs.JS_NewAtom(ctx, "pageXOffset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, pageXOffsetAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollX, "get pageXOffset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, pageXOffsetAtom);
    }
    {
        const pageYOffsetAtom = qjs.JS_NewAtom(ctx, "pageYOffset");
        _ = qjs.JS_DefinePropertyGetSet(ctx, global, pageYOffsetAtom, qjs.JS_NewCFunction(ctx, &jsGetScrollY, "get pageYOffset", 0), quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx, pageYOffsetAtom);
    }

    // navigator object (minimal)
    const nav_obj = qjs.JS_NewObject(ctx);
    const nav_ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    _ = qjs.JS_SetPropertyStr(ctx, nav_obj, "userAgent", qjs.JS_NewStringLen(ctx, nav_ua, nav_ua.len));
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
