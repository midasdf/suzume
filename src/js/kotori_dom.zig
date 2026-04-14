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

// ── Shadow DOM Phase 1 — inline scope (no cross-module import needed) ──
// These mirror src/js/shadow_root.zig but use the lxb types already
// available via the @cImport block below. Global state is shared within
// this compilation unit (the kotori test binary).
const sr = struct {
    extern fn lxb_dom_document_create_document_fragment(document: *anyopaque) ?*lxb.lxb_dom_node_t;

    pub const Mode = enum { open, closed };
    pub const SlotAssignment = enum { named, manual };

    pub const ShadowRoot = struct {
        id: u32,
        host: *lxb.lxb_dom_element_t,
        fragment: *lxb.lxb_dom_node_t,
        mode: Mode,
    };

    var g_allocator: std.mem.Allocator = std.heap.c_allocator;
    var g_shadow_roots: ?std.AutoHashMap(u32, *ShadowRoot) = null;
    var g_node_scope: ?std.AutoHashMap(usize, u32) = null;
    var g_host_to_shadow: ?std.AutoHashMap(usize, *ShadowRoot) = null;
    var g_next_id: u32 = 1;

    fn ensureInit() void {
        if (g_shadow_roots == null) g_shadow_roots = std.AutoHashMap(u32, *ShadowRoot).init(g_allocator);
        if (g_node_scope == null) g_node_scope = std.AutoHashMap(usize, u32).init(g_allocator);
        if (g_host_to_shadow == null) g_host_to_shadow = std.AutoHashMap(usize, *ShadowRoot).init(g_allocator);
    }

    pub fn nodeScope(node: *lxb.lxb_dom_node_t) u32 {
        if (g_node_scope) |map| return map.get(@intFromPtr(node)) orelse 0;
        return 0;
    }

    pub fn setNodeScope(node: *lxb.lxb_dom_node_t, id: u32) void {
        ensureInit();
        if (id == 0) { _ = g_node_scope.?.remove(@intFromPtr(node)); return; }
        g_node_scope.?.put(@intFromPtr(node), id) catch {};
    }

    pub fn tagSubtreeScope(node: *lxb.lxb_dom_node_t, id: u32) void {
        setNodeScope(node, id);
        var ch: ?*lxb.lxb_dom_node_t = @ptrCast(node.first_child);
        while (ch) |c| : (ch = @ptrCast(c.next)) tagSubtreeScope(c, id);
    }

    pub fn propagateScopeFromParent(parent: *lxb.lxb_dom_node_t, new_child: *lxb.lxb_dom_node_t) void {
        const sid = nodeScope(parent);
        if (sid == 0) return;
        tagSubtreeScope(new_child, sid);
    }

    pub fn shadowRootForHost(host: *lxb.lxb_dom_element_t) ?*ShadowRoot {
        if (g_host_to_shadow) |map| return map.get(@intFromPtr(host));
        return null;
    }

    pub fn shadowRootById(id: u32) ?*ShadowRoot {
        if (g_shadow_roots) |map| return map.get(id);
        return null;
    }

    pub fn create(document: *anyopaque, host: *lxb.lxb_dom_element_t, mode: Mode) ?*ShadowRoot {
        ensureInit();
        const fragment = lxb_dom_document_create_document_fragment(document) orelse return null;
        const root = g_allocator.create(ShadowRoot) catch return null;
        const id = g_next_id;
        g_next_id += 1;
        root.* = .{ .id = id, .host = host, .fragment = fragment, .mode = mode };
        g_shadow_roots.?.put(id, root) catch { g_allocator.destroy(root); return null; };
        g_host_to_shadow.?.put(@intFromPtr(host), root) catch {};
        setNodeScope(fragment, id);
        return root;
    }

    pub fn isAllowedShadowHost(local_name: []const u8) bool {
        if (std.mem.indexOfScalar(u8, local_name, '-') != null) return true;
        const allow = [_][]const u8{
            "article", "aside", "blockquote", "body", "div", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "header", "main", "nav", "p", "section", "span",
        };
        for (allow) |name| if (std.mem.eql(u8, local_name, name)) return true;
        return false;
    }

    pub fn shadowInclusiveRoot(node: *lxb.lxb_dom_node_t, composed: bool) *lxb.lxb_dom_node_t {
        var current: *lxb.lxb_dom_node_t = node;
        while (true) {
            while (current.parent) |p| : (current = @ptrCast(p)) {}
            const sid = nodeScope(current);
            if (sid == 0) return current;
            const root = shadowRootById(sid) orelse return current;
            if (!composed) return current;
            current = @ptrCast(root.host);
        }
    }

    pub fn isShadowInclusiveConnected(node: *lxb.lxb_dom_node_t) bool {
        const root = shadowInclusiveRoot(node, true);
        return root.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT;
    }

    // ── Phase 2: retargeting + composed path helpers ────────────────
    pub fn shadowRootForFragment(node: *lxb.lxb_dom_node_t) ?*ShadowRoot {
        const sid = nodeScope(node);
        if (sid == 0) return null;
        const r = shadowRootById(sid) orelse return null;
        if (r.fragment != node) return null;
        return r;
    }

    pub fn composedParent(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
        if (shadowRootForFragment(node)) |root| return @ptrCast(root.host);
        const p: ?*lxb.lxb_dom_node_t = @ptrCast(node.parent);
        return p;
    }

    pub fn treeRoot(node: *lxb.lxb_dom_node_t) *lxb.lxb_dom_node_t {
        var cur: *lxb.lxb_dom_node_t = node;
        while (cur.parent) |p| cur = @ptrCast(p);
        return cur;
    }

    pub fn isShadowIncludingInclusiveAncestor(ancestor: *lxb.lxb_dom_node_t, descendant: *lxb.lxb_dom_node_t) bool {
        var cur: ?*lxb.lxb_dom_node_t = descendant;
        while (cur) |c| {
            if (c == ancestor) return true;
            cur = composedParent(c);
        }
        return false;
    }

    pub fn retarget(a_in: *lxb.lxb_dom_node_t, b_in: ?*lxb.lxb_dom_node_t) *lxb.lxb_dom_node_t {
        var a: *lxb.lxb_dom_node_t = a_in;
        while (true) {
            const a_root = treeRoot(a);
            const root = shadowRootForFragment(a_root) orelse return a;
            if (b_in) |b| {
                if (isShadowIncludingInclusiveAncestor(a_root, b)) return a;
            }
            a = @ptrCast(root.host);
        }
    }
};

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
    try vm.registerNativeMethod(ep, "attachShadow", &nativeAttachShadow);
    try vm.registerNativeMethod(ep, "getRootNode", &nativeGetRootNode);
    try vm.registerNativeMethod(ep, "dispatchEvent", &nativeDispatchEvent);

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

    // ── window global (proxy to globals) ──
    const win_obj = try vm.createObj(.{ .obj_type = .window_proxy });
    const window_id = try vm.pool.intern("window");
    try vm.globals.put(vm.allocator, window_id, JsValue.initObject(win_obj));
    const self_id = try vm.pool.intern("self");
    try vm.globals.put(vm.allocator, self_id, JsValue.initObject(win_obj));
    const globalthis_id = try vm.pool.intern("globalThis");
    try vm.globals.put(vm.allocator, globalthis_id, JsValue.initObject(win_obj));

    // ── Property interception ──
    vm.dom_get_prop = &domGetProp;
    vm.dom_set_prop = &domSetProp;
}

// ══════════════════════════════════════════════════════════════════════
// Property interception handlers
// ══════════════════════════════════════════════════════════════════════

fn domGetProp(vm: *VM, obj: *JsObject, name_id: StringId) ?JsValue {
    if (obj.obj_type == .window_proxy) {
        // window.x → globals[x]
        return vm.globals.get(name_id);
    }
    const name = vm.pool.get(name_id) orelse return null;
    if (obj.obj_type == .dom_node) return domNodeGetProp(vm, obj, name);
    if (obj.obj_type == .dom_style) return domStyleGetProp(vm, obj, name);
    return null;
}

fn domSetProp(vm: *VM, obj: *JsObject, name_id: StringId, val: JsValue) bool {
    if (obj.obj_type == .window_proxy) {
        // window.x = val → globals[x] = val
        vm.globals.put(vm.allocator, name_id, val) catch {};
        return true;
    }
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

    // Shadow DOM Phase 1
    if (eql(name, "isConnected"))
        return JsValue.initBool(sr.isShadowInclusiveConnected(node));

    if (eql(name, "shadowRoot")) {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            if (sr.shadowRootForHost(elem)) |host_sr| {
                if (host_sr.mode == .open) {
                    return wrapShadowRoot(vm, host_sr) orelse JsValue.null_val;
                }
            }
        }
        return JsValue.null_val;
    }

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
    const parent = getThisNodeOrFragment(this) orelse return JsValue.null_val;
    const child = getArgNode(args[0]) orelse return JsValue.null_val;
    dom_b.lxb_dom_node_remove(child);
    dom_b.lxb_dom_node_insert_child(parent, child);
    // Shadow DOM Phase 1: propagate scope tag if parent is in a shadow tree.
    sr.propagateScopeFromParent(parent, child);
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

// ── Shadow DOM Phase 1 native methods ───────────────────────────────

fn nativeAttachShadow(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // Parse mode from init dict (required).
    var mode: sr.Mode = .open;
    var has_mode = false;
    if (args.len >= 1 and args[0].isObject()) {
        const init_obj = args[0].asJsObject();
        const mode_sid = vm.pool.intern("mode") catch return JsValue.undefined_val;
        if (init_obj.getProperty(mode_sid)) |mode_val| {
            if (mode_val.isString()) {
                const mode_str = vm.pool.get(mode_val.asStringId()) orelse "";
                if (std.mem.eql(u8, mode_str, "open")) {
                    mode = .open;
                    has_mode = true;
                } else if (std.mem.eql(u8, mode_str, "closed")) {
                    mode = .closed;
                    has_mode = true;
                }
            }
        }
    }
    if (!has_mode) return JsValue.undefined_val;

    // Check allowlist.
    var name_len: usize = 0;
    const name_ptr = dom_b.lxb_dom_element_local_name(elem, &name_len) orelse return JsValue.undefined_val;
    if (!sr.isAllowedShadowHost(name_ptr[0..name_len])) {
        return throwDomError(vm, "NotSupportedError");
    }

    // Second-call guard: throw NotSupportedError.
    if (sr.shadowRootForHost(elem) != null) {
        return throwDomError(vm, "NotSupportedError");
    }

    const doc = g_document orelse return JsValue.undefined_val;
    const shadow = sr.create(doc, elem, mode) orelse return JsValue.undefined_val;

    return wrapShadowRoot(vm, shadow) orelse JsValue.undefined_val;
}

// ── Phase 2: dispatchEvent with retargeting + composedPath filtering ──
//
// Builds a composed path by walking `composedParent` from target up through
// shadow hosts. For non-composed events, stops at the target's shadow-root
// fragment (does not cross into the host's tree).
//
// For each listener invocation at node N, sets:
//   event.target = retarget(original_target, N)
//   event.currentTarget = wrap(N)
//   event.composedPath() returns the path filtered to nodes visible from N's
//   tree root (closed-tree filtering).
fn nativeDispatchEvent(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const target = getThisNode(this) orelse return JsValue.initBool(false);
    if (args.len == 0) return JsValue.initBool(false);

    // Parse event: accept either a string type or an object with { type, composed, bubbles }
    var type_str: []const u8 = "event";
    var event_composed: bool = false;
    var event_obj_in: ?*JsObject = null;
    if (args[0].isString()) {
        type_str = vm.pool.get(args[0].asStringId()) orelse "event";
    } else if (args[0].isObject()) {
        event_obj_in = args[0].asJsObject();
        const t_sid = vm.pool.intern("type") catch return JsValue.initBool(false);
        if (event_obj_in.?.getProperty(t_sid)) |tv| {
            if (tv.isString()) type_str = vm.pool.get(tv.asStringId()) orelse "event";
        }
        const comp_sid = vm.pool.intern("composed") catch return JsValue.initBool(false);
        if (event_obj_in.?.getProperty(comp_sid)) |cv| {
            event_composed = cv.isTruthy();
        }
    }

    // Build composed path: path[0] = target, walking up via composedParent.
    var path_buf: [64]*lxb.lxb_dom_node_t = undefined;
    var path_len: usize = 0;
    var cur: ?*lxb.lxb_dom_node_t = target;
    const target_scope = sr.nodeScope(target);
    while (cur) |n| {
        if (path_len >= path_buf.len) break;
        path_buf[path_len] = n;
        path_len += 1;
        // If non-composed and n is the shadow-root fragment of the target's own
        // scope, stop here (don't cross into host).
        if (!event_composed) {
            if (sr.shadowRootForFragment(n)) |_| {
                if (sr.nodeScope(n) == target_scope and target_scope != 0) break;
            }
        }
        cur = sr.composedParent(n);
    }

    // Get-or-create event object passed to listeners.
    const ev_obj: *JsObject = blk: {
        if (event_obj_in) |e| break :blk e;
        break :blk vm.createObj(.{}) catch return JsValue.initBool(false);
    };
    const type_sid = vm.pool.intern("type") catch return JsValue.initBool(false);
    ev_obj.setProperty(vm.allocator, type_sid, JsValue.initString(vm.pool.intern(type_str) catch return JsValue.initBool(false))) catch {};
    const composed_sid = vm.pool.intern("composed") catch return JsValue.initBool(false);
    ev_obj.setProperty(vm.allocator, composed_sid, JsValue.initBool(event_composed)) catch {};

    // Install composedPath() method returning the filtered path relative to currentTarget.
    // We do this by storing the raw path on the event object and a native getter
    // "composedPath" that reads currentTarget at call time.
    const cp_fn = try vm.createObj(.{ .obj_type = .native_function });
    cp_fn.data = .{ .native_fn = &nativeEventComposedPath };
    const cp_sid = vm.pool.intern("composedPath") catch return JsValue.initBool(false);
    ev_obj.setProperty(vm.allocator, cp_sid, JsValue.initObject(cp_fn)) catch {};

    // Stash raw path as a JS array on the event as __rawPath (wrappers)
    // and __rawPathIds as matching numeric pointers.
    const raw_arr = try vm.createObj(.{ .obj_type = .array });
    const raw_ids = try vm.createObj(.{ .obj_type = .array });
    var pi: usize = 0;
    while (pi < path_len) : (pi += 1) {
        const w = wrapNode(vm, path_buf[pi]) orelse continue;
        try raw_arr.data.array.append(vm.allocator, w);
        try raw_ids.data.array.append(vm.allocator, JsValue.initNumber(@floatFromInt(@intFromPtr(path_buf[pi]))));
    }
    const rp_sid = vm.pool.intern("__rawPath") catch return JsValue.initBool(false);
    ev_obj.setProperty(vm.allocator, rp_sid, JsValue.initObject(raw_arr)) catch {};
    const rpi_sid = vm.pool.intern("__rawPathIds") catch return JsValue.initBool(false);
    ev_obj.setProperty(vm.allocator, rpi_sid, JsValue.initObject(raw_ids)) catch {};

    // Dispatch: simple bubble-phase walk from target up the path. For each
    // node N, call all listeners whose node_ptr == N and event_type == type.
    // Retarget event.target = retarget(original_target, N).
    const target_sid = vm.pool.intern("target") catch return JsValue.initBool(false);
    const ct_sid = vm.pool.intern("currentTarget") catch return JsValue.initBool(false);
    var i: usize = 0;
    while (i < path_len) : (i += 1) {
        const node = path_buf[i];
        const retargeted = sr.retarget(target, node);
        ev_obj.setProperty(vm.allocator, target_sid, wrapNode(vm, retargeted) orelse JsValue.null_val) catch {};
        ev_obj.setProperty(vm.allocator, ct_sid, wrapNode(vm, node) orelse JsValue.null_val) catch {};
        // Find matching listeners
        for (g_listeners.items) |entry| {
            if (@intFromPtr(entry.node_ptr) != @intFromPtr(node)) continue;
            if (!std.mem.eql(u8, entry.event_type, type_str)) continue;
            _ = vm.callJsFunction(entry.callback, JsValue.initObject(ev_obj), &.{JsValue.initObject(ev_obj)}) catch {};
        }
    }

    return JsValue.initBool(true);
}

/// Event.composedPath() — reads currentTarget from `this`, then filters the
/// stashed raw path to exclude nodes hidden by closed shadow trees from
/// currentTarget's root.
fn nativeEventComposedPath(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (!this.isObject()) return JsValue.null_val;
    const ev_obj = this.asJsObject();
    const rp_sid = vm.pool.intern("__rawPath") catch return JsValue.null_val;
    const rpi_sid = vm.pool.intern("__rawPathIds") catch return JsValue.null_val;
    const raw = ev_obj.getProperty(rp_sid) orelse return JsValue.null_val;
    const raw_ids = ev_obj.getProperty(rpi_sid) orelse return JsValue.null_val;
    if (!raw.isObject() or !raw_ids.isObject()) return JsValue.null_val;
    const raw_arr = raw.asJsObject();
    const raw_id_arr = raw_ids.asJsObject();

    // Find current target node ptr.
    const ct_sid = vm.pool.intern("currentTarget") catch return JsValue.null_val;
    const ct_val = ev_obj.getProperty(ct_sid) orelse return JsValue.null_val;
    const ct_node = getThisNode(ct_val) orelse return JsValue.null_val;
    const ct_root = sr.treeRoot(ct_node);

    const out = try vm.createObj(.{ .obj_type = .array });
    var i: usize = 0;
    while (i < raw_id_arr.data.array.items.len) : (i += 1) {
        const id_val = raw_id_arr.data.array.items[i];
        const ptr_num: usize = @intFromFloat(id_val.asNumber());
        const item_ptr: *lxb.lxb_dom_node_t = @ptrFromInt(ptr_num);
        if (nodeVisibleFromRoot(item_ptr, ct_root)) {
            try out.data.array.append(vm.allocator, raw_arr.data.array.items[i]);
        }
    }
    return JsValue.initObject(out);
}

/// Closed-tree filter: is `item` visible to a listener whose tree root is `ct_root`?
fn nodeVisibleFromRoot(item: *lxb.lxb_dom_node_t, ct_root: *lxb.lxb_dom_node_t) bool {
    const item_root = sr.treeRoot(item);
    if (item_root == ct_root) return true;
    // If the listener is inside the item's subtree (item_root is ancestor of ct_root), visible.
    if (sr.isShadowIncludingInclusiveAncestor(item_root, ct_root)) return true;
    // Otherwise: item is in some tree whose ancestor chain of shadow roots
    // must all be non-closed (or we must be inside one of the closed ones).
    var cur: *lxb.lxb_dom_node_t = item_root;
    while (true) {
        if (sr.shadowRootForFragment(cur)) |root| {
            if (root.mode == .closed) {
                if (!sr.isShadowIncludingInclusiveAncestor(cur, ct_root)) return false;
            }
            cur = @ptrCast(root.host);
            cur = sr.treeRoot(cur);
            if (cur == ct_root) return true;
            continue;
        }
        return true;
    }
}

fn nativeGetRootNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNodeOrFragment(this) orelse return JsValue.undefined_val;

    var composed: bool = false;
    if (args.len >= 1 and args[0].isObject()) {
        const opts = args[0].asJsObject();
        const composed_sid = vm.pool.intern("composed") catch return JsValue.undefined_val;
        if (opts.getProperty(composed_sid)) |cv| {
            composed = cv.isTruthy();
        }
    }

    const root = sr.shadowInclusiveRoot(node, composed);

    // If the root is the document, return the JS document object.
    if (root.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        return vm.globals.get(vm.pool.intern("document") catch return JsValue.undefined_val) orelse JsValue.undefined_val;
    }

    // If root is a shadow fragment, return the ShadowRoot wrapper.
    const sid = sr.nodeScope(root);
    if (sid != 0) {
        if (sr.shadowRootById(sid)) |root_sr| {
            if (root_sr.mode == .open) {
                return wrapShadowRoot(vm, root_sr) orelse JsValue.undefined_val;
            }
            // Closed: return a wrapper of the fragment itself.
            return wrapNode(vm, root) orelse JsValue.undefined_val;
        }
    }

    return wrapNode(vm, root) orelse JsValue.undefined_val;
}

/// Wrap a ShadowRoot as a kotori JsObject (dom_node backed by the fragment).
/// Sets __isShadowRoot = true on the object so JS can detect it.
fn wrapShadowRoot(vm: *VM, root_sr: *sr.ShadowRoot) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_node }) catch return null;
    obj.data = .{ .dom_node = @ptrCast(root_sr.fragment) };
    obj.prototype = vm.element_proto;
    // Mark as shadow root for JS detection.
    const is_sr_sid = vm.pool.intern("__isShadowRoot") catch return JsValue.initObject(obj);
    obj.setProperty(vm.allocator, is_sr_sid, JsValue.initBool(true)) catch {};
    const mode_sid = vm.pool.intern("mode") catch return JsValue.initObject(obj);
    const mode_str: []const u8 = switch (root_sr.mode) { .open => "open", .closed => "closed" };
    const mode_val = JsValue.initString(vm.pool.intern(mode_str) catch return JsValue.initObject(obj));
    obj.setProperty(vm.allocator, mode_sid, mode_val) catch {};
    return JsValue.initObject(obj);
}

/// Set a pending JS throw on the VM so JS try/catch can catch it.
/// The VM checks pending_throw after each native call and executes a JS throw.
fn throwDomError(vm: *VM, name: []const u8) JsValue {
    // Build a plain object with .name = name so `e.name` works in catch.
    const err_obj = vm.createObj(.{}) catch return JsValue.undefined_val;
    const name_sid = vm.pool.intern("name") catch return JsValue.undefined_val;
    const msg_sid = vm.pool.intern(name) catch return JsValue.undefined_val;
    err_obj.setProperty(vm.allocator, name_sid, JsValue.initString(msg_sid)) catch {};
    vm.pending_throw = JsValue.initObject(err_obj);
    return JsValue.undefined_val;
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

/// Like getThisNode but also accepts ShadowRoot wrappers (dom_node backed
/// by a document fragment). Used for appendChild/getRootNode on shadow roots.
fn getThisNodeOrFragment(this: JsValue) ?*lxb.lxb_dom_node_t {
    return getThisNode(this);
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
