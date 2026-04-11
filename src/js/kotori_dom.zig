//! kotori_dom.zig — DOM bindings for the kotori JS engine.
//!
//! Bridges the kotori VM to the Lexbor DOM tree, enabling JavaScript
//! DOM manipulation in the suzume browser.
//!
//! Phase 2 features:
//!   1. document.getElementById / querySelector
//!   2. element.innerHTML / textContent read/write
//!   3. element.addEventListener
//!   4. element.style read/write
//!   5. document.createElement / element.appendChild

const std = @import("std");

// ── Kotori engine types (via module alias, set in build.zig) ────────
const kotori = @import("kotori");

const VM = kotori.VM;
const JsValue = kotori.JsValue;
const JsObject = kotori.JsObject;
const StringId = kotori.StringId;

// ── Lexbor C types (via @cImport, include path set in build.zig) ────
const lxb = @cImport({
    @cDefine("LEXBOR_STATIC", "");
    @cInclude("lexbor/dom/interfaces/element.h");
    @cInclude("lexbor/dom/interfaces/node.h");
});

// ── Lexbor extern functions ─────────────────────────────────────────
const dom_b = struct {
    // Node operations
    pub extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
    pub extern fn lxb_dom_node_text_content_set(node: *lxb.lxb_dom_node_t, content: [*]const u8, len: usize) lxb.lxb_status_t;
    pub extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
    pub extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
    pub extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
    pub extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
    pub extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
    pub extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
    // Element operations
    pub extern fn lxb_dom_element_set_attribute(element: *lxb.lxb_dom_element_t, qn: [*]const u8, qn_len: usize, value: [*]const u8, value_len: usize) ?*anyopaque;
    pub extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qn: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
    pub extern fn lxb_dom_element_remove_attribute(element: *lxb.lxb_dom_element_t, qn: [*]const u8, qn_len: usize) lxb.lxb_status_t;
    pub extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
    // Document operations
    pub extern fn lxb_dom_document_create_element(document: *anyopaque, local_name: [*]const u8, lname_len: usize, reserved: ?*anyopaque) ?*lxb.lxb_dom_element_t;
    pub extern fn lxb_dom_document_create_text_node(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
    // HTML serialization
    pub const serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
    pub extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
    // HTML fragment parsing
    pub extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;
};

// ── C pointer helpers (convert [*c] to ?* for field access) ─────────
fn nodeParent(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    const p: ?*lxb.lxb_dom_node_t = @ptrCast(node.parent);
    return p;
}
fn nodeFirstChild(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    const c: ?*lxb.lxb_dom_node_t = @ptrCast(node.first_child);
    return c;
}
fn nodeNext(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    const n: ?*lxb.lxb_dom_node_t = @ptrCast(node.next);
    return n;
}
fn nodeType(node: *lxb.lxb_dom_node_t) c_uint {
    return node.type;
}

// ── Module state ────────────────────────────────────────────────────
pub var dom_dirty: bool = false;
var g_alloc: std.mem.Allocator = undefined;
var g_document: ?*anyopaque = null; // lxb_dom_document_t*

fn setDomDirty() void {
    dom_dirty = true;
}

// ── Event listener storage ──────────────────────────────────────────
pub const EventListener = struct {
    node_ptr: *anyopaque,
    event_type: []const u8, // owned copy
    callback: JsValue, // function object ref
    capture: bool,
};

var g_listeners: std.ArrayListUnmanaged(EventListener) = .{};

pub fn getListeners() []const EventListener {
    return g_listeners.items;
}

/// Clean up module-level state. Call when the VM is torn down.
pub fn deinit() void {
    for (g_listeners.items) |entry| {
        g_alloc.free(entry.event_type);
    }
    g_listeners.deinit(g_alloc);
    g_listeners = .{};
    g_document = null;
    dom_dirty = false;
}

// ══════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════

pub fn initDomBuiltins(vm: *VM, document_ptr: *anyopaque) !void {
    g_alloc = vm.allocator;
    g_document = document_ptr;

    // ── Element.prototype ──
    vm.element_proto = try vm.createObj(.{});
    const ep = vm.element_proto.?;
    try vm.registerNativeMethod(ep, "appendChild", &nativeAppendChild);
    try vm.registerNativeMethod(ep, "removeChild", &nativeRemoveChild);
    try vm.registerNativeMethod(ep, "insertBefore", &nativeInsertBefore);
    try vm.registerNativeMethod(ep, "setAttribute", &nativeSetAttribute);
    try vm.registerNativeMethod(ep, "getAttribute", &nativeGetAttribute);
    try vm.registerNativeMethod(ep, "removeAttribute", &nativeRemoveAttribute);
    try vm.registerNativeMethod(ep, "addEventListener", &nativeAddEventListener);
    try vm.registerNativeMethod(ep, "querySelector", &nativeQuerySelector);

    // ── document global ──
    const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
    doc_obj.data = .{ .dom_node = document_ptr };
    doc_obj.prototype = ep;
    try vm.registerNativeMethod(doc_obj, "getElementById", &nativeGetElementById);
    try vm.registerNativeMethod(doc_obj, "querySelector", &nativeDocQuerySelector);
    try vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement);
    try vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode);

    const doc_id = try vm.pool.intern("document");
    try vm.globals.put(vm.allocator, doc_id, JsValue.initObject(doc_obj));

    // ── Property interception ──
    vm.dom_get_prop = &domGetProp;
    vm.dom_set_prop = &domSetProp;
}

// ══════════════════════════════════════════════════════════════════════
// Property interception handlers
// ══════════════════════════════════════════════════════════════════════

fn domGetProp(vm: *VM, obj: *JsObject, name_id: StringId) ?JsValue {
    const name = vm.pool.get(name_id) orelse return null;
    if (obj.obj_type == .dom_node) return domNodeGetProp(vm, obj, name);
    if (obj.obj_type == .dom_style) return domStyleGetProp(vm, obj, name);
    return null;
}

fn domSetProp(vm: *VM, obj: *JsObject, name_id: StringId, val: JsValue) bool {
    const name = vm.pool.get(name_id) orelse return false;
    if (obj.obj_type == .dom_node) return domNodeSetProp(vm, obj, name, val);
    if (obj.obj_type == .dom_style) return domStyleSetProp(vm, obj, name, val);
    return false;
}

// ── dom_node get ────────────────────────────────────────────────────

fn domNodeGetProp(vm: *VM, obj: *JsObject, name: []const u8) ?JsValue {
    const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(obj.data.dom_node));

    if (eql(name, "nodeType"))
        return JsValue.initNumber(@floatFromInt(nodeType(node)));

    if (eql(name, "tagName") or eql(name, "nodeName")) {
        if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        return tagNameUpper(vm, elem);
    }
    if (eql(name, "id"))
        return getAttr(vm, node, "id");
    if (eql(name, "className"))
        return getAttr(vm, node, "class");
    if (eql(name, "textContent"))
        return getTextContent(vm, node);
    if (eql(name, "innerHTML"))
        return getInnerHTML(vm, node);
    if (eql(name, "outerHTML"))
        return getOuterHTML(vm, node);

    // DOM traversal
    if (eql(name, "parentNode") or eql(name, "parentElement")) {
        if (nodeParent(node)) |p| {
            if (eql(name, "parentElement") and nodeType(p) != lxb.LXB_DOM_NODE_TYPE_ELEMENT)
                return JsValue.null_val;
            return wrapNode(vm, p);
        }
        return JsValue.null_val;
    }
    if (eql(name, "firstChild"))
        return if (nodeFirstChild(node)) |ch| wrapNode(vm, ch) else JsValue.null_val;
    if (eql(name, "firstElementChild"))
        return firstChildOfType(vm, node, true);
    if (eql(name, "lastChild"))
        return lastChild(vm, node, false);
    if (eql(name, "lastElementChild"))
        return lastChild(vm, node, true);
    if (eql(name, "nextSibling"))
        return if (nodeNext(node)) |s| wrapNode(vm, s) else JsValue.null_val;
    if (eql(name, "nextElementSibling"))
        return nextSibling(vm, node, true);
    if (eql(name, "previousSibling"))
        return prevSibling(vm, node, false);
    if (eql(name, "previousElementSibling"))
        return prevSibling(vm, node, true);
    if (eql(name, "children") or eql(name, "childNodes"))
        return getChildrenArray(vm, node, eql(name, "children"));

    if (eql(name, "style")) {
        if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
        return createStyleObj(vm, @ptrCast(node));
    }

    // document-specific: body, head, documentElement
    if (eql(name, "body")) return findByTag(vm, node, "body");
    if (eql(name, "head")) return findByTag(vm, node, "head");
    if (eql(name, "documentElement")) return findByTag(vm, node, "html");

    return null; // fall through to prototype chain (methods live there)
}

// ── dom_node set ────────────────────────────────────────────────────

fn domNodeSetProp(vm: *VM, obj: *JsObject, name: []const u8, val: JsValue) bool {
    const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(obj.data.dom_node));

    if (eql(name, "textContent")) {
        setTextContent(vm, node, val);
        setDomDirty();
        return true;
    }
    if (eql(name, "innerHTML")) {
        setInnerHTML(vm, node, val);
        setDomDirty();
        return true;
    }
    if (eql(name, "id")) {
        setAttrFromVal(vm, node, "id", val);
        return true;
    }
    if (eql(name, "className")) {
        setAttrFromVal(vm, node, "class", val);
        setDomDirty();
        return true;
    }
    return false; // fall through to normal set
}

// ── dom_style get ───────────────────────────────────────────────────

fn domStyleGetProp(vm: *VM, obj: *JsObject, name: []const u8) ?JsValue {
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));

    if (eql(name, "cssText"))
        return getAttr(vm, @ptrCast(elem), "style");

    // Convert camelCase → kebab-case
    var kebab_buf: [128]u8 = undefined;
    const css_prop = camelToKebab(name, &kebab_buf);

    // Read from style attribute
    var attr_len: usize = 0;
    const style_str = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";

    if (findCssPropValue(style_str, css_prop)) |val| {
        const sid = vm.pool.intern(val) catch return null;
        return JsValue.initString(sid);
    }
    return JsValue.initString(vm.pool.intern("") catch return null);
}

// ── dom_style set ───────────────────────────────────────────────────

fn domStyleSetProp(vm: *VM, obj: *JsObject, name: []const u8, val: JsValue) bool {
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));

    if (eql(name, "cssText")) {
        if (val.isString()) {
            if (vm.pool.get(val.asStringId())) |s| {
                _ = dom_b.lxb_dom_element_set_attribute(elem, "style", 5, s.ptr, s.len);
                setDomDirty();
            }
        }
        return true;
    }

    var kebab_buf: [128]u8 = undefined;
    const css_prop = camelToKebab(name, &kebab_buf);

    const new_val_str: []const u8 = if (val.isString())
        (vm.pool.get(val.asStringId()) orelse "")
    else
        "";

    // Read current, update, write back
    var attr_len: usize = 0;
    const old_style = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";

    var result_buf: [2048]u8 = undefined;
    const new_style = updateStyleProp(old_style, css_prop, new_val_str, &result_buf);
    _ = dom_b.lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
    setDomDirty();
    return true;
}

// ══════════════════════════════════════════════════════════════════════
// Document native methods
// ══════════════════════════════════════════════════════════════════════

fn nativeGetElementById(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const id_str = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const root = getThisNode(this) orelse return JsValue.null_val;
    if (findElementById(root, id_str)) |elem|
        return wrapNode(vm, @ptrCast(elem)) orelse JsValue.null_val;
    return JsValue.null_val;
}

fn nativeDocQuerySelector(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const root = getThisNode(this) orelse return JsValue.null_val;
    if (findFirstMatch(root, sel)) |found|
        return wrapNode(vm, found) orelse JsValue.null_val;
    return JsValue.null_val;
}

fn nativeCreateElement(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const tag = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const doc = g_document orelse return JsValue.null_val;
    const elem = dom_b.lxb_dom_document_create_element(doc, tag.ptr, tag.len, null) orelse return JsValue.null_val;
    return wrapNode(vm, @ptrCast(elem)) orelse JsValue.null_val;
}

fn nativeCreateTextNode(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const text = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const doc = g_document orelse return JsValue.null_val;
    const tn = dom_b.lxb_dom_document_create_text_node(doc, text.ptr, text.len) orelse return JsValue.null_val;
    return wrapNode(vm, tn) orelse JsValue.null_val;
}

// ══════════════════════════════════════════════════════════════════════
// Element native methods (on prototype)
// ══════════════════════════════════════════════════════════════════════

fn nativeAppendChild(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    _ = ctx;
    if (args.len == 0) return JsValue.null_val;
    const parent = getThisNode(this) orelse return JsValue.null_val;
    const child = getArgNode(args[0]) orelse return JsValue.null_val;
    dom_b.lxb_dom_node_remove(child);
    dom_b.lxb_dom_node_insert_child(parent, child);
    setDomDirty();
    return args[0];
}

fn nativeRemoveChild(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.null_val;
    const child = getArgNode(args[0]) orelse return JsValue.null_val;
    dom_b.lxb_dom_node_remove(child);
    setDomDirty();
    return args[0];
}

fn nativeInsertBefore(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len < 2) return JsValue.null_val;
    const new_node = getArgNode(args[0]) orelse return JsValue.null_val;
    dom_b.lxb_dom_node_remove(new_node);
    if (args[1].isNull() or args[1].isUndefined()) {
        const parent = getThisNode(this) orelse return JsValue.null_val;
        dom_b.lxb_dom_node_insert_child(parent, new_node);
    } else {
        const ref = getArgNode(args[1]) orelse return JsValue.null_val;
        dom_b.lxb_dom_node_insert_before(ref, new_node);
    }
    setDomDirty();
    return args[0];
}

fn nativeSetAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString() or !args[1].isString()) return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const n = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    const v = vm.pool.get(args[1].asStringId()) orelse return JsValue.undefined_val;
    _ = dom_b.lxb_dom_element_set_attribute(elem, n.ptr, n.len, v.ptr, v.len);
    setDomDirty();
    return JsValue.undefined_val;
}

fn nativeGetAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const attr_name = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    var val_len: usize = 0;
    if (dom_b.lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len)) |ptr| {
        const sid = try vm.pool.intern(ptr[0..val_len]);
        return JsValue.initString(sid);
    }
    return JsValue.null_val;
}

fn nativeRemoveAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const attr_name = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    _ = dom_b.lxb_dom_element_remove_attribute(elem, attr_name.ptr, attr_name.len);
    return JsValue.undefined_val;
}

fn nativeAddEventListener(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    const event_type = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    const callback = args[1];
    if (!callback.isObject()) return JsValue.undefined_val;

    // Own the event type string
    const owned = try g_alloc.alloc(u8, event_type.len);
    @memcpy(owned, event_type);

    const capture = if (args.len > 2 and args[2].isBool()) args[2].asBool() else false;

    try g_listeners.append(g_alloc, .{
        .node_ptr = @ptrCast(node),
        .event_type = owned,
        .callback = callback,
        .capture = capture,
    });
    return JsValue.undefined_val;
}

fn nativeQuerySelector(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (findFirstMatch(node, sel)) |found|
        return wrapNode(vm, found) orelse JsValue.null_val;
    return JsValue.null_val;
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — value extraction
// ══════════════════════════════════════════════════════════════════════

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn getThisNode(this: JsValue) ?*lxb.lxb_dom_node_t {
    if (!this.isObject()) return null;
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_node) return null;
    return @ptrCast(@alignCast(obj.data.dom_node));
}

fn getArgNode(val: JsValue) ?*lxb.lxb_dom_node_t {
    return getThisNode(val);
}

fn wrapNode(vm: *VM, node: *lxb.lxb_dom_node_t) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_node }) catch return null;
    obj.data = .{ .dom_node = @ptrCast(node) };
    obj.prototype = vm.element_proto;
    return JsValue.initObject(obj);
}

fn createStyleObj(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_style }) catch return null;
    obj.data = .{ .dom_style = @ptrCast(elem) };
    return JsValue.initObject(obj);
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — attribute access
// ══════════════════════════════════════════════════════════════════════

fn getAttr(vm: *VM, node: *lxb.lxb_dom_node_t, attr_name: []const u8) JsValue {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT)
        return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    var val_len: usize = 0;
    if (dom_b.lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len)) |ptr|
        return JsValue.initString(vm.pool.intern(ptr[0..val_len]) catch return JsValue.null_val);
    return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
}

fn setAttrFromVal(vm: *VM, node: *lxb.lxb_dom_node_t, attr_name: []const u8, val: JsValue) void {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    if (val.isString()) {
        if (vm.pool.get(val.asStringId())) |s|
            _ = dom_b.lxb_dom_element_set_attribute(elem, attr_name.ptr, attr_name.len, s.ptr, s.len);
    }
}

fn tagNameUpper(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    var len: usize = 0;
    const raw = dom_b.lxb_dom_element_local_name(elem, &len) orelse return JsValue.null_val;
    var buf: [128]u8 = undefined;
    const n = @min(len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toUpper(raw[i]);
    return JsValue.initString(vm.pool.intern(buf[0..n]) catch return JsValue.null_val);
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — DOM traversal
// ══════════════════════════════════════════════════════════════════════

fn firstChildOfType(vm: *VM, node: *lxb.lxb_dom_node_t, elements_only: bool) JsValue {
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| {
        if (!elements_only or nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
            return wrapNode(vm, c) orelse JsValue.null_val;
        ch = nodeNext(c);
    }
    return JsValue.null_val;
}

fn lastChild(vm: *VM, node: *lxb.lxb_dom_node_t, elements_only: bool) JsValue {
    var ch: ?*lxb.lxb_dom_node_t = dom_b.lxb_dom_node_last_child_noi(node);
    while (ch) |c| {
        if (!elements_only or nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
            return wrapNode(vm, c) orelse JsValue.null_val;
        ch = dom_b.lxb_dom_node_prev_noi(c);
    }
    return JsValue.null_val;
}

fn nextSibling(vm: *VM, node: *lxb.lxb_dom_node_t, elements_only: bool) JsValue {
    var s: ?*lxb.lxb_dom_node_t = nodeNext(node);
    while (s) |sib| {
        if (!elements_only or nodeType(sib) == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
            return wrapNode(vm, sib) orelse JsValue.null_val;
        s = nodeNext(sib);
    }
    return JsValue.null_val;
}

fn prevSibling(vm: *VM, node: *lxb.lxb_dom_node_t, elements_only: bool) JsValue {
    var s: ?*lxb.lxb_dom_node_t = dom_b.lxb_dom_node_prev_noi(node);
    while (s) |sib| {
        if (!elements_only or nodeType(sib) == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
            return wrapNode(vm, sib) orelse JsValue.null_val;
        s = dom_b.lxb_dom_node_prev_noi(sib);
    }
    return JsValue.null_val;
}

fn getChildrenArray(vm: *VM, node: *lxb.lxb_dom_node_t, elements_only: bool) ?JsValue {
    const arr = vm.createObj(.{ .obj_type = .array }) catch return null;
    arr.data = .{ .array = .{} };
    arr.prototype = vm.array_proto;
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| {
        if (!elements_only or nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (wrapNode(vm, c)) |w|
                arr.data.array.append(g_alloc, w) catch return null;
        }
        ch = nodeNext(c);
    }
    return JsValue.initObject(arr);
}

fn findByTag(vm: *VM, root: *lxb.lxb_dom_node_t, tag: []const u8) ?JsValue {
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(root);
    while (ch) |c| {
        if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(c);
            var len: usize = 0;
            if (dom_b.lxb_dom_element_local_name(elem, &len)) |n| {
                if (std.ascii.eqlIgnoreCase(n[0..len], tag))
                    return wrapNode(vm, c);
            }
            if (nodeFirstChild(c) != null) {
                if (findByTag(vm, c, tag)) |found| return found;
            }
        }
        ch = nodeNext(c);
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — textContent / innerHTML
// ══════════════════════════════════════════════════════════════════════

fn getTextContent(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var len: usize = 0;
    if (dom_b.lxb_dom_node_text_content(node, &len)) |ptr|
        return JsValue.initString(vm.pool.intern(ptr[0..len]) catch return JsValue.null_val);
    return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
}

fn setTextContent(vm: *VM, node: *lxb.lxb_dom_node_t, val: JsValue) void {
    if (val.isString()) {
        if (vm.pool.get(val.asStringId())) |s|
            _ = dom_b.lxb_dom_node_text_content_set(node, s.ptr, s.len);
    } else {
        _ = dom_b.lxb_dom_node_text_content_set(node, "", 0);
    }
}

fn getInnerHTML(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(g_alloc);
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| {
        _ = dom_b.lxb_html_serialize_tree_cb(c, &serializeCb, @ptrCast(&buf));
        ch = nodeNext(c);
    }
    return JsValue.initString(vm.pool.intern(buf.items) catch return JsValue.null_val);
}

fn getOuterHTML(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(g_alloc);
    _ = dom_b.lxb_html_serialize_tree_cb(node, &serializeCb, @ptrCast(&buf));
    return JsValue.initString(vm.pool.intern(buf.items) catch return JsValue.null_val);
}

fn serializeCb(data: ?[*]const u8, len: usize, ctx_ptr: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    if (data == null or len == 0) return 0;
    const buf: *std.ArrayListUnmanaged(u8) = @ptrCast(@alignCast(ctx_ptr));
    buf.appendSlice(g_alloc, data.?[0..len]) catch return 1;
    return 0;
}

fn setInnerHTML(vm: *VM, node: *lxb.lxb_dom_node_t, val: JsValue) void {
    // Clear existing children
    while (nodeFirstChild(node)) |child| {
        dom_b.lxb_dom_node_remove(child);
        _ = dom_b.lxb_dom_node_destroy(child);
    }
    if (!val.isString()) return;
    const html = vm.pool.get(val.asStringId()) orelse return;
    if (html.len == 0) return;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const doc = g_document orelse return;

    const frag = dom_b.lxb_html_document_parse_fragment(doc, elem, html.ptr, html.len) orelse return;
    // Move parsed nodes into target
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(frag);
    while (ch) |c| {
        const next = nodeNext(c);
        dom_b.lxb_dom_node_remove(c);
        dom_b.lxb_dom_node_insert_child(node, c);
        ch = next;
    }
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — tree search
// ══════════════════════════════════════════════════════════════════════

fn findElementById(root: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_element_t {
    var stack: [256]?*lxb.lxb_dom_node_t = undefined;
    var depth: usize = 0;
    if (nodeFirstChild(root)) |fc| {
        stack[0] = fc;
        depth = 1;
    }
    while (depth > 0) {
        depth -= 1;
        const node = stack[depth].?;

        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var attr_len: usize = 0;
            if (dom_b.lxb_dom_element_get_attribute(elem, "id", 2, &attr_len)) |ptr| {
                if (eql(ptr[0..attr_len], id)) return elem;
            }
        }
        if (nodeNext(node)) |nx| {
            if (depth < stack.len) { stack[depth] = nx; depth += 1; }
        }
        if (nodeFirstChild(node)) |fc| {
            if (depth < stack.len) { stack[depth] = fc; depth += 1; }
        }
    }
    return null;
}

/// Walk descendants depth-first. Return first element matching selector.
fn findFirstMatch(root: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    const sel = std.mem.trim(u8, selector, " \t\r\n");
    if (sel.len == 0) return null;

    var cur: ?*lxb.lxb_dom_node_t = nodeFirstChild(root);
    while (cur) |node| {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (matchSimpleSelector(@ptrCast(node), sel)) return node;
        }
        if (nodeFirstChild(node)) |child| {
            cur = child;
        } else {
            var n = node;
            cur = null;
            while (true) {
                if (nodeNext(n)) |nx| { cur = nx; break; }
                if (nodeParent(n)) |p| {
                    if (@intFromPtr(p) == @intFromPtr(root)) break;
                    n = p;
                } else break;
            }
        }
    }
    return null;
}

/// Match a simple CSS selector: tag, #id, .class, tag.class, tag#id, .a.b
fn matchSimpleSelector(elem: *lxb.lxb_dom_element_t, sel: []const u8) bool {
    if (sel.len == 0) return false;

    var tag_part: ?[]const u8 = null;
    var id_part: ?[]const u8 = null;
    var classes: [8][]const u8 = undefined;
    var class_count: usize = 0;

    var i: usize = 0;
    var seg_start: usize = 0;
    var seg_type: enum { tag, id, class } = .tag;

    if (sel[0] == '#') { seg_type = .id; seg_start = 1; i = 1; } else if (sel[0] == '.') { seg_type = .class; seg_start = 1; i = 1; }

    while (i <= sel.len) {
        const at_end = i == sel.len;
        const is_sep = !at_end and (sel[i] == '#' or sel[i] == '.');
        if (at_end or is_sep) {
            const seg = sel[seg_start..i];
            if (seg.len > 0) switch (seg_type) {
                .tag => tag_part = seg,
                .id => id_part = seg,
                .class => {
                    if (class_count < classes.len) { classes[class_count] = seg; class_count += 1; }
                },
            };
            if (!at_end) {
                seg_type = if (sel[i] == '#') .id else .class;
                seg_start = i + 1;
            }
        }
        i += 1;
    }

    // Match tag
    if (tag_part) |tag| {
        var len: usize = 0;
        if (dom_b.lxb_dom_element_local_name(elem, &len)) |n| {
            if (!std.ascii.eqlIgnoreCase(n[0..len], tag)) return false;
        } else return false;
    }
    // Match id
    if (id_part) |id| {
        var al: usize = 0;
        if (dom_b.lxb_dom_element_get_attribute(elem, "id", 2, &al)) |p| {
            if (!eql(p[0..al], id)) return false;
        } else return false;
    }
    // Match classes
    if (class_count > 0) {
        var al: usize = 0;
        const cls_str = if (dom_b.lxb_dom_element_get_attribute(elem, "class", 5, &al)) |p| p[0..al] else return false;
        for (classes[0..class_count]) |cls| {
            if (!classContains(cls_str, cls)) return false;
        }
    }
    return true;
}

fn classContains(class_str: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, class_str, ' ');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (eql(t, needle)) return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════════════════
// Helpers — CSS style property manipulation
// ══════════════════════════════════════════════════════════════════════

fn camelToKebab(input: []const u8, buf: *[128]u8) []const u8 {
    var out: usize = 0;
    for (input) |ch| {
        if (std.ascii.isUpper(ch)) {
            if (out < buf.len) { buf[out] = '-'; out += 1; }
            if (out < buf.len) { buf[out] = std.ascii.toLower(ch); out += 1; }
        } else {
            if (out < buf.len) { buf[out] = ch; out += 1; }
        }
    }
    return buf[0..out];
}

fn findCssPropValue(style_str: []const u8, css_prop: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos < style_str.len) {
        while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == '\t')) pos += 1;
        if (pos >= style_str.len) break;
        const ps = pos;
        while (pos < style_str.len and style_str[pos] != ':' and style_str[pos] != ';') pos += 1;
        if (pos >= style_str.len or style_str[pos] != ':') break;
        const prop = std.mem.trim(u8, style_str[ps..pos], " \t");
        pos += 1;
        const vs = pos;
        while (pos < style_str.len and style_str[pos] != ';') pos += 1;
        const val = std.mem.trim(u8, style_str[vs..pos], " \t");
        if (pos < style_str.len) pos += 1;
        if (eql(prop, css_prop)) result = val;
    }
    return result;
}

fn updateStyleProp(old: []const u8, css_prop: []const u8, new_val: []const u8, buf: *[2048]u8) []const u8 {
    var out: usize = 0;
    var found = false;
    var pos: usize = 0;

    while (pos < old.len) {
        while (pos < old.len and (old[pos] == ' ' or old[pos] == '\t')) pos += 1;
        if (pos >= old.len) break;
        const ps = pos;
        while (pos < old.len and old[pos] != ':' and old[pos] != ';') pos += 1;
        if (pos >= old.len or old[pos] != ':') break;
        const prop = std.mem.trim(u8, old[ps..pos], " \t");
        pos += 1;
        const vs = pos;
        while (pos < old.len and old[pos] != ';') pos += 1;
        const val = std.mem.trim(u8, old[vs..pos], " \t");
        if (pos < old.len) pos += 1;

        if (eql(prop, css_prop)) {
            found = true;
            if (new_val.len > 0) out += writeDecl(buf, out, css_prop, new_val);
        } else {
            out += writeDecl(buf, out, prop, val);
        }
    }
    if (!found and new_val.len > 0)
        out += writeDecl(buf, out, css_prop, new_val);

    return buf[0..out];
}

fn writeDecl(buf: *[2048]u8, off: usize, prop: []const u8, val: []const u8) usize {
    var p = off;
    if (p > 0 and p < buf.len) { buf[p] = ' '; p += 1; }
    const pe = @min(p + prop.len, buf.len);
    @memcpy(buf[p..pe], prop[0 .. pe - p]);
    p = pe;
    if (p + 1 < buf.len) { buf[p] = ':'; buf[p + 1] = ' '; p += 2; } else if (p < buf.len) { buf[p] = ':'; p += 1; }
    const ve = @min(p + val.len, buf.len);
    @memcpy(buf[p..ve], val[0 .. ve - p]);
    p = ve;
    if (p < buf.len) { buf[p] = ';'; p += 1; }
    return p - off;
}
