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

// ── Cascade / computed-style resolution ────────────────────────────
// kotori_dom is its own build module, so it cannot import cascade.zig /
// layout/box.zig directly (those files already belong to the root
// module). Instead, main registers a `resolve_fn` callback that performs
// the actual cascade lookup + CSSOM §6.5/§6.7 serialization using the
// shared helpers, returning the serialized resolved value as a slice.
pub var flush_fn: ?*const fn () void = null;
/// Resolver callback signature. `node` is an opaque `lxb_dom_node_t*` — the
/// main module's lexbor cImport is a distinct type from kotori_dom's, so we
/// use `*anyopaque` across the boundary and let main cast back.
pub const ResolveFn = *const fn (node: *anyopaque, prop: []const u8, buf: []u8) ?[]const u8;
pub var resolve_fn: ?ResolveFn = null;

/// Register a callback invoked by getComputedStyle to flush pending
/// restyle/layout before reading resolved values.
pub fn setFlushCallback(cb: ?*const fn () void) void {
    flush_fn = cb;
}

/// Register the cascade-resolve bridge. Called from main after the first
/// cascade so kotori.getComputedStyle returns the same resolved values as
/// the QuickJS path (CSSOM §6.5 resolved value algorithm).
pub fn setResolveCallback(cb: ?ResolveFn) void {
    resolve_fn = cb;
}

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

    /// Clear all shadow-DOM global state. Must be called on VM teardown to
    /// avoid stale pointer→scope mappings leaking into the next document,
    /// which can cause freed/reused lxb node pointers to appear as shadow
    /// hosts or fragments (DOM Living Standard §4.8 requires tree-scope
    /// state to be tied to the Document).
    pub fn reset() void {
        if (g_shadow_roots) |*map| {
            var it = map.valueIterator();
            while (it.next()) |r_ptr| g_allocator.destroy(r_ptr.*);
            map.deinit();
            g_shadow_roots = null;
        }
        if (g_node_scope) |*map| {
            map.deinit();
            g_node_scope = null;
        }
        if (g_host_to_shadow) |*map| {
            map.deinit();
            g_host_to_shadow = null;
        }
        g_next_id = 1;
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
    pub extern fn lxb_dom_document_create_comment(document: *anyopaque, data: [*]const u8, len: usize) ?*lxb.lxb_dom_node_t;
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

var g_listeners: std.ArrayListUnmanaged(EventListener) = .empty;

// DOM prototype chain: Node.prototype → CharacterData.prototype → Text/Comment.prototype
// Element.prototype also inherits from Node.prototype
var g_node_proto: ?*JsObject = null;
var g_chardata_proto: ?*JsObject = null;
var g_text_proto: ?*JsObject = null;
var g_comment_proto: ?*JsObject = null;

/// Sentinel address used as node_ptr for window-level event listeners.
/// DOM events on elements never match this because it points to a Zig
/// module-level variable, never into the Lexbor DOM heap.
var g_window_sentinel: u8 = 0;

pub fn getListeners() []const EventListener {
    return g_listeners.items;
}

/// Dispatch a window-level event to all registered window listeners.
/// Called from script_executor.zig after page load to fire DOMContentLoaded
/// and window 'load' events (HTML §4.8.5 + §8.2.9).
/// Requires an active VM context (krt.vm must be initialized).
pub fn dispatchWindowEvent(vm: *VM, event_type: []const u8) void {
    const sentinel_ptr = @intFromPtr(&g_window_sentinel);
    // Build a minimal event object with .type set.
    const ev_obj = vm.createObj(.{}) catch return;
    const type_sid = vm.pool.intern("type") catch return;
    const ev_type_sid = vm.pool.intern(event_type) catch return;
    ev_obj.setProperty(vm.allocator, type_sid, JsValue.initString(ev_type_sid)) catch {};
    const global = JsValue.initObject(ev_obj); // used as `this` — harmless
    for (g_listeners.items) |entry| {
        if (@intFromPtr(entry.node_ptr) != sentinel_ptr) continue;
        if (!std.mem.eql(u8, entry.event_type, event_type)) continue;
        _ = vm.callJsFunction(entry.callback, global, &.{JsValue.initObject(ev_obj)}) catch {};
    }
}

// ── Per-element scroll state (CSSOM View §6.5) ──────────────────────
// Keyed on the lxb_dom_element_t pointer as usize.
const ElemScrollPos = struct { top: f64, left: f64 };
var g_scroll_map: ?std.AutoHashMap(usize, ElemScrollPos) = null;

fn ensureScrollMap() *std.AutoHashMap(usize, ElemScrollPos) {
    if (g_scroll_map == null) {
        g_scroll_map = std.AutoHashMap(usize, ElemScrollPos).init(std.heap.page_allocator);
    }
    return &g_scroll_map.?;
}

/// Clean up module-level state. Call when the VM is torn down.
pub fn deinit() void {
    for (g_listeners.items) |entry| {
        g_alloc.free(entry.event_type);
    }
    g_listeners.deinit(g_alloc);
    g_listeners = .empty;
    if (g_scroll_map) |*m| {
        m.deinit();
        g_scroll_map = null;
    }
    // Shadow DOM tree-scope state is per-Document (DOM §4.8); clear it so
    // freed lxb node pointers reused by the next document don't inherit
    // stale scope ids or impersonate old shadow roots.
    sr.reset();
    g_document = null;
    dom_dirty = false;
}

// ══════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════

pub fn initDomBuiltins(vm: *VM, document_ptr: *anyopaque) !void {
    g_alloc = vm.allocator;
    g_document = document_ptr;

    // ── Node.prototype (base for all DOM nodes) ──
    g_node_proto = try vm.createObj(.{});
    const np = g_node_proto.?;
    try vm.registerNativeMethod(np, "appendChild", &nativeAppendChild);
    try vm.registerNativeMethod(np, "removeChild", &nativeRemoveChild);
    try vm.registerNativeMethod(np, "insertBefore", &nativeInsertBefore);
    try vm.registerNativeMethod(np, "isEqualNode", &nativeIsEqualNode);
    try vm.registerNativeMethod(np, "getRootNode", &nativeGetRootNode);
    try vm.registerNativeMethod(np, "addEventListener", &nativeAddEventListener);
    try vm.registerNativeMethod(np, "dispatchEvent", &nativeDispatchEvent);

    // ── CharacterData.prototype → Node.prototype ──
    g_chardata_proto = try vm.createObj(.{});
    g_chardata_proto.?.prototype = g_node_proto;

    // ── Text.prototype → CharacterData.prototype ──
    g_text_proto = try vm.createObj(.{});
    g_text_proto.?.prototype = g_chardata_proto;

    // ── Comment.prototype → CharacterData.prototype ──
    g_comment_proto = try vm.createObj(.{});
    g_comment_proto.?.prototype = g_chardata_proto;

    // ── Element.prototype → Node.prototype ──
    vm.element_proto = try vm.createObj(.{});
    const ep = vm.element_proto.?;
    ep.prototype = g_node_proto;
    // Element-specific methods (Node methods inherited via prototype chain)
    try vm.registerNativeMethod(ep, "setAttribute", &nativeSetAttribute);
    try vm.registerNativeMethod(ep, "getAttribute", &nativeGetAttribute);
    try vm.registerNativeMethod(ep, "removeAttribute", &nativeRemoveAttribute);
    try vm.registerNativeMethod(ep, "querySelector", &nativeQuerySelector);
    try vm.registerNativeMethod(ep, "querySelectorAll", &nativeQuerySelectorAll);
    try vm.registerNativeMethod(ep, "matches", &nativeMatches);
    try vm.registerNativeMethod(ep, "closest", &nativeClosest);
    try vm.registerNativeMethod(ep, "getElementsByTagName", &nativeGetElementsByTagName);
    try vm.registerNativeMethod(ep, "getElementsByClassName", &nativeGetElementsByClassName);
    try vm.registerNativeMethod(ep, "attachShadow", &nativeAttachShadow);
    // CSSOM View §6.5: scroll / scrollTo / scrollBy
    try vm.registerNativeMethod(ep, "scroll", &nativeScroll);
    try vm.registerNativeMethod(ep, "scrollTo", &nativeScrollTo);
    try vm.registerNativeMethod(ep, "scrollBy", &nativeScrollBy);

    // ── document global ──
    const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
    doc_obj.data = .{ .dom_node = document_ptr };
    doc_obj.prototype = ep;
    try vm.registerNativeMethod(doc_obj, "getElementById", &nativeGetElementById);
    try vm.registerNativeMethod(doc_obj, "querySelector", &nativeDocQuerySelector);
    try vm.registerNativeMethod(doc_obj, "querySelectorAll", &nativeDocQuerySelectorAll);
    try vm.registerNativeMethod(doc_obj, "getElementsByTagName", &nativeGetElementsByTagName);
    try vm.registerNativeMethod(doc_obj, "getElementsByClassName", &nativeGetElementsByClassName);
    try vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement);
    try vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode);
    try vm.registerNativeMethod(doc_obj, "createComment", &nativeCreateComment);
    try vm.registerNativeMethod(doc_obj, "createDocumentFragment", &nativeCreateDocumentFragment);

    const doc_id = try vm.pool.intern("document");
    try vm.globals.put(vm.allocator, doc_id, JsValue.initObject(doc_obj));

    // ── window global (proxy to globals) ──
    const win_obj = try vm.createObj(.{ .obj_type = .window_proxy });
    // HTML §8.1.3.1: Window implements EventTarget — register addEventListener and
    // dispatchEvent directly on the window_proxy object so that testharness.js's
    // on_event(window,'load',cb) (= window.addEventListener('load',cb)) works.
    // These methods use the g_window_sentinel to distinguish window listeners from
    // DOM node listeners in g_listeners (HTML §8.1.3, DOM §2.9).
    try vm.registerNativeMethod(win_obj, "addEventListener", &nativeAddEventListener);
    try vm.registerNativeMethod(win_obj, "removeEventListener", &nativeWindowRemoveEventListener);
    try vm.registerNativeMethod(win_obj, "dispatchEvent", &nativeDispatchEvent);
    // CSSOM §6.5: Window.getComputedStyle(element) → CSSStyleDeclaration.
    // MVP: returns a dom_style-backed object whose getPropertyValue() reads
    // the element's inline style attribute. Covers the majority of WPT
    // getComputedStyle tests that assert `style="X:Y"` round-trips.
    try vm.registerNativeMethod(win_obj, "getComputedStyle", &nativeGetComputedStyle);
    // Also expose getComputedStyle as a bare global so that
    // `getComputedStyle(el)` (without `window.`) works the same way.
    const gcs_fn = try vm.createObj(.{ .obj_type = .native_function });
    gcs_fn.data = .{ .native_fn = &nativeGetComputedStyle };
    const gcs_id = try vm.pool.intern("getComputedStyle");
    try vm.globals.put(vm.allocator, gcs_id, JsValue.initObject(gcs_fn));
    const window_id = try vm.pool.intern("window");
    try vm.globals.put(vm.allocator, window_id, JsValue.initObject(win_obj));
    const self_id = try vm.pool.intern("self");
    try vm.globals.put(vm.allocator, self_id, JsValue.initObject(win_obj));
    const globalthis_id = try vm.pool.intern("globalThis");
    try vm.globals.put(vm.allocator, globalthis_id, JsValue.initObject(win_obj));

    // ── DOM constructor globals (for instanceof and WPT) ──
    // Node constructor + prototype
    const node_ctor = try vm.createObj(.{ .obj_type = .native_function });
    node_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    const proto_sid = try vm.pool.intern("prototype");
    node_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(np)) catch {};
    const node_id = try vm.pool.intern("Node");
    try vm.globals.put(vm.allocator, node_id, JsValue.initObject(node_ctor));

    // CharacterData constructor + prototype
    const cd_ctor = try vm.createObj(.{ .obj_type = .native_function });
    cd_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    cd_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_chardata_proto.?)) catch {};
    const cd_id = try vm.pool.intern("CharacterData");
    try vm.globals.put(vm.allocator, cd_id, JsValue.initObject(cd_ctor));

    // Text constructor + prototype
    const text_ctor = try vm.createObj(.{ .obj_type = .native_function });
    text_ctor.data = .{ .native_fn = &nativeTextConstructor };
    text_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_text_proto.?)) catch {};
    const text_id = try vm.pool.intern("Text");
    try vm.globals.put(vm.allocator, text_id, JsValue.initObject(text_ctor));

    // Comment constructor + prototype
    const comment_ctor = try vm.createObj(.{ .obj_type = .native_function });
    comment_ctor.data = .{ .native_fn = &nativeCommentConstructor };
    comment_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_comment_proto.?)) catch {};
    const comment_id = try vm.pool.intern("Comment");
    try vm.globals.put(vm.allocator, comment_id, JsValue.initObject(comment_ctor));

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

    if (eql(name, "tagName")) {
        if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        return tagNameUpper(vm, elem);
    }
    if (eql(name, "nodeName")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            return tagNameUpper(vm, elem);
        }
        const spec_name: []const u8 = switch (nt) {
            lxb.LXB_DOM_NODE_TYPE_TEXT => "#text",
            lxb.LXB_DOM_NODE_TYPE_COMMENT => "#comment",
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT => "#document",
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => "#document-fragment",
            lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION => "#processing-instruction",
            lxb.LXB_DOM_NODE_TYPE_CDATA_SECTION => "#cdata-section",
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE => return getDocTypeName(vm, node),
            else => "#unknown",
        };
        return JsValue.initString(vm.pool.intern(spec_name) catch return JsValue.null_val);
    }
    if (eql(name, "id"))
        return getAttr(vm, node, "id");
    if (eql(name, "className"))
        return getAttr(vm, node, "class");
    if (eql(name, "textContent"))
        return getTextContent(vm, node);
    // CharacterData §4.2.5: data and nodeValue are equivalent to textContent
    // for Text, Comment, and ProcessingInstruction nodes.
    if (eql(name, "data") or eql(name, "nodeValue")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_TEXT or nt == lxb.LXB_DOM_NODE_TYPE_COMMENT or
            nt == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
            return getTextContent(vm, node);
        // For Element/Document, nodeValue is null per DOM spec
        if (eql(name, "nodeValue")) return JsValue.null_val;
    }
    // CharacterData.length — number of code units in data
    if (eql(name, "length")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_TEXT or nt == lxb.LXB_DOM_NODE_TYPE_COMMENT or
            nt == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
        {
            var len: usize = 0;
            if (dom_b.lxb_dom_node_text_content(node, &len)) |_| {
                return JsValue.initNumber(@floatFromInt(len));
            }
            return JsValue.initNumber(0);
        }
    }
    // CharacterData mutation methods (§4.2.5)
    if (eql(name, "appendData") or eql(name, "deleteData") or
        eql(name, "insertData") or eql(name, "replaceData") or eql(name, "substringData"))
    {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_TEXT or nt == lxb.LXB_DOM_NODE_TYPE_COMMENT or
            nt == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
        {
            const fn_ptr: kotori.JsObject.NativeFn = if (eql(name, "appendData"))
                &nativeAppendData
            else if (eql(name, "deleteData"))
                &nativeDeleteData
            else if (eql(name, "insertData"))
                &nativeInsertData
            else if (eql(name, "replaceData"))
                &nativeReplaceData
            else
                &nativeSubstringData;
            const fn_obj = vm.createObj(.{ .obj_type = .native_function }) catch return null;
            fn_obj.data = .{ .native_fn = fn_ptr };
            return JsValue.initObject(fn_obj);
        }
    }
    // Node.hasChildNodes()
    if (eql(name, "hasChildNodes")) {
        const fn_obj = vm.createObj(.{ .obj_type = .native_function }) catch return null;
        fn_obj.data = .{ .native_fn = &nativeHasChildNodes };
        return JsValue.initObject(fn_obj);
    }
    // Node.ownerDocument
    if (eql(name, "ownerDocument")) {
        if (g_document != null) {
            const doc_id = vm.pool.intern("document") catch return JsValue.null_val;
            return vm.globals.get(doc_id) orelse JsValue.null_val;
        }
        return JsValue.null_val;
    }
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

    // CSSOM View §6.5: scrollTop / scrollLeft
    if (eql(name, "scrollTop")) {
        const pos = ensureScrollMap().get(@intFromPtr(node)) orelse return JsValue.initNumber(0);
        return JsValue.initNumber(pos.top);
    }
    if (eql(name, "scrollLeft")) {
        const pos = ensureScrollMap().get(@intFromPtr(node)) orelse return JsValue.initNumber(0);
        return JsValue.initNumber(pos.left);
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

    if (eql(name, "textContent") or eql(name, "data") or eql(name, "nodeValue")) {
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
    // CSSOM View §6.5: scrollTop / scrollLeft setters (clamp to ≥ 0)
    if (eql(name, "scrollTop")) {
        const v = @max(0.0, val.toNumber());
        const key = @intFromPtr(node);
        const cur = ensureScrollMap().get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
        ensureScrollMap().put(key, .{ .top = v, .left = cur.left }) catch {};
        return true;
    }
    if (eql(name, "scrollLeft")) {
        const v = @max(0.0, val.toNumber());
        const key = @intFromPtr(node);
        const cur = ensureScrollMap().get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
        ensureScrollMap().put(key, .{ .top = cur.top, .left = v }) catch {};
        return true;
    }
    return false; // fall through to normal set
}

// ── dom_style get ───────────────────────────────────────────────────

fn domStyleGetProp(vm: *VM, obj: *JsObject, name: []const u8) ?JsValue {
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));

    // Let own properties (methods registered via registerNativeMethod, e.g.
    // getPropertyValue on the computed-style object) resolve before the
    // inline-style fallback. Without this, the style getter would shadow
    // registered methods since it returns "" for anything it doesn't match.
    const name_id = vm.pool.intern(name) catch return null;
    if (obj.getProperty(name_id)) |own| return own;

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

fn nativeDocQuerySelectorAll(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const root = getThisNode(this) orelse return JsValue.null_val;
    const matches = findAllMatches(root, sel, vm.allocator);
    defer vm.allocator.free(matches);
    // Return a JS Array of wrapped nodes
    const arr_obj = try vm.createObj(.{ .obj_type = .array });
    arr_obj.data = .{ .array = .empty };
    for (matches) |node| {
        const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
        try arr_obj.data.array.append(vm.allocator, wrapped);
    }
    return JsValue.initObject(arr_obj);
}

fn nativeQuerySelectorAll(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const root = getThisNode(this) orelse return JsValue.null_val;
    const matches = findAllMatches(root, sel, vm.allocator);
    defer vm.allocator.free(matches);
    const arr_obj = try vm.createObj(.{ .obj_type = .array });
    arr_obj.data = .{ .array = .empty };
    for (matches) |node| {
        const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
        try arr_obj.data.array.append(vm.allocator, wrapped);
    }
    return JsValue.initObject(arr_obj);
}

fn nativeGetElementsByTagName(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) {
        // Return empty array
        const arr = try vm.createObj(.{ .obj_type = .array });
        arr.data = .{ .array = .empty };
        return JsValue.initObject(arr);
    }
    const tag = vm.pool.get(args[0].asStringId()) orelse {
        const arr = try vm.createObj(.{ .obj_type = .array });
        arr.data = .{ .array = .empty };
        return JsValue.initObject(arr);
    };
    const root = getThisNode(this) orelse {
        const arr = try vm.createObj(.{ .obj_type = .array });
        arr.data = .{ .array = .empty };
        return JsValue.initObject(arr);
    };
    // Walk DOM tree and match by tag name (case-insensitive for HTML)
    const arr_obj = try vm.createObj(.{ .obj_type = .array });
    arr_obj.data = .{ .array = .empty };
    try collectByTagName(vm, root, tag, arr_obj);
    return JsValue.initObject(arr_obj);
}

fn collectByTagName(vm: *VM, root: *lxb.lxb_dom_node_t, tag: []const u8, arr: *kotori.JsObject) !void {
    const is_wildcard = tag.len == 1 and tag[0] == '*';
    var child: ?*lxb.lxb_dom_node_t = @ptrCast(root.first_child);
    while (child) |node| : (child = @ptrCast(node.next)) {
        if (node.type == 1) { // ELEMENT_NODE
            if (is_wildcard) {
                const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
                try arr.data.array.append(vm.allocator, wrapped);
            } else {
                const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
                var name_len: usize = 0;
                const name_ptr = dom_b.lxb_dom_element_local_name(elem, &name_len);
                if (name_ptr) |np| {
                    if (std.ascii.eqlIgnoreCase(np[0..name_len], tag)) {
                        const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
                        try arr.data.array.append(vm.allocator, wrapped);
                    }
                }
            }
            // Recurse into children
            try collectByTagName(vm, node, tag, arr);
        }
    }
}

fn nativeGetElementsByClassName(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const arr_obj = try vm.createObj(.{ .obj_type = .array });
    arr_obj.data = .{ .array = .empty };
    if (args.len == 0 or !args[0].isString()) return JsValue.initObject(arr_obj);
    const cls = vm.pool.get(args[0].asStringId()) orelse return JsValue.initObject(arr_obj);
    const root = getThisNode(this) orelse return JsValue.initObject(arr_obj);
    // Delegate to querySelectorAll with "." + className
    var sel_buf: [256]u8 = undefined;
    const sel = std.fmt.bufPrint(&sel_buf, ".{s}", .{cls}) catch return JsValue.initObject(arr_obj);
    const matches = findAllMatches(root, sel, vm.allocator);
    defer vm.allocator.free(matches);
    for (matches) |node| {
        const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
        try arr_obj.data.array.append(vm.allocator, wrapped);
    }
    return JsValue.initObject(arr_obj);
}

fn nativeCreateElement(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const tag = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const doc = g_document orelse return JsValue.null_val;
    const elem = dom_b.lxb_dom_document_create_element(doc, tag.ptr, tag.len, null) orelse return JsValue.null_val;
    return wrapNode(vm, @ptrCast(elem)) orelse JsValue.null_val;
}

/// CSSOM §6.5 — Window.getComputedStyle(element[, pseudoElt]).
///
/// MVP: returns a CSSStyleDeclaration-like object backed by the element's
/// inline `style` attribute. `getPropertyValue(name)` reads via the same
/// kebab-case lookup that `element.style.X` uses. Unknown properties
/// return the empty string per CSSOM §2.2 "serialize a CSS value".
///
/// Does not (yet) reflect the cascade, user-agent defaults, or computed
/// layout values — callers that need those should use QuickJS
/// (`SUZUME_JS=quickjs`) or we will extend this later.
fn nativeGetComputedStyle(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const node = getArgNode(args[0]) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    // CSSOM §6.5: resolved values require a fresh cascade if DOM was mutated.
    if (flush_fn) |f| f();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const obj = try vm.createObj(.{ .obj_type = .dom_style });
    obj.data = .{ .dom_style = @ptrCast(elem) };
    // Register getPropertyValue as an own property so that domStyleGetProp's
    // own-property check above resolves it before the CSS-name fallback.
    try vm.registerNativeMethod(obj, "getPropertyValue", &nativeCSSGetPropertyValue);
    try vm.registerNativeMethod(obj, "getPropertyPriority", &nativeCSSGetPropertyPriority);
    // __element internal back-reference (matches QuickJS path for debugging).
    const elem_sid = try vm.pool.intern("__element");
    obj.setProperty(vm.allocator, elem_sid, args[0]) catch {};
    return JsValue.initObject(obj);
}

/// CSSStyleDeclaration.getPropertyValue(propertyName) for the computed-style
/// object. MVP: looks up the (already kebab-case) property name in the
/// element's inline style attribute, returning the trimmed value or "".
fn nativeCSSGetPropertyValue(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString() or !this.isObject()) {
        return JsValue.initString(try vm.pool.intern(""));
    }
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_style) return JsValue.initString(try vm.pool.intern(""));
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));
    const prop_in = vm.pool.get(args[0].asStringId()) orelse "";

    // Normalize to lowercase kebab-case. getPropertyValue takes the CSS
    // property name (already kebab per CSSOM), but accept camelCase too for
    // leniency (some callers pass "backgroundColor").
    var name_buf: [128]u8 = undefined;
    const css_prop = camelToKebab(prop_in, &name_buf);

    // CSSOM §6.5 (resolved value) / §6.7 (getPropertyValue): query the
    // cascade-resolved ComputedStyle (which already folds in inline style at
    // highest specificity), preferring layout box used values where
    // available. Falls back to raw inline-style lookup only when no cascade
    // entry exists (e.g. disconnected element, tests without layout).
    if (resolve_fn) |rf| {
        var val_buf: [160]u8 = undefined;
        if (rf(@ptrCast(elem), css_prop, &val_buf)) |slice| {
            return JsValue.initString(try vm.pool.intern(slice));
        }
    }

    // Fall back to inline style attribute (covers unmapped properties and
    // the pre-cascade state used by simple unit tests).
    var attr_len: usize = 0;
    const style_str = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";
    if (findCssPropValue(style_str, css_prop)) |val| {
        return JsValue.initString(try vm.pool.intern(val));
    }
    return JsValue.initString(try vm.pool.intern(""));
}

/// CSSStyleDeclaration.getPropertyPriority — returns "important" if the
/// property is marked !important in the inline style, else "". MVP does not
/// parse !important (inline parser above strips everything at ';'), so
/// always returns "". This avoids `undefined` when scripts call it.
fn nativeCSSGetPropertyPriority(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    return JsValue.initString(try vm.pool.intern(""));
}

fn nativeCreateTextNode(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const text = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    const doc = g_document orelse return JsValue.null_val;
    const tn = dom_b.lxb_dom_document_create_text_node(doc, text.ptr, text.len) orelse return JsValue.null_val;
    return wrapNode(vm, tn) orelse JsValue.null_val;
}

fn nativeHasChildNodes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    return JsValue.initBool(nodeFirstChild(node) != null);
}

fn getDocTypeName(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    // DocumentType.name is stored as the local_name in lexbor
    var len: usize = 0;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    if (dom_b.lxb_dom_element_local_name(elem, &len)) |n| {
        return JsValue.initString(vm.pool.intern(n[0..len]) catch return JsValue.null_val);
    }
    return JsValue.initString(vm.pool.intern("html") catch return JsValue.null_val);
}

fn nativeCreateComment(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const data = if (args.len > 0) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_comment(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
}

/// Convert a JS argument to string (String(x) semantics for DOM APIs).
fn argToString(vm: *VM, val: JsValue) []const u8 {
    if (val.isString()) return vm.pool.get(val.asStringId()) orelse "";
    if (val.isNull()) return "null";
    if (val.isUndefined()) return "undefined";
    if (val.isNumber()) {
        var buf: [32]u8 = undefined;
        const n = val.asNumber();
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return "";
        return vm.pool.get(vm.pool.intern(s) catch return "") orelse "";
    }
    if (val.isInt()) {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{val.asInt()}) catch return "";
        return vm.pool.get(vm.pool.intern(s) catch return "") orelse "";
    }
    if (val.isBool()) return if (val.asBool()) "true" else "false";
    return "[object Object]";
}

fn nativeCreateDocumentFragment(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const frag = sr.lxb_dom_document_create_document_fragment(doc) orelse return JsValue.null_val;
    return wrapNode(vm, frag) orelse JsValue.null_val;
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
    const callback = args[1];
    if (!callback.isObject()) return JsValue.undefined_val;

    // Resolve the target node pointer.
    // HTML §8.1.3.1: window.addEventListener routes to the Window object.
    // We use g_window_sentinel as a stable identity for window-level listeners
    // so they can be matched in dispatchEvent without a DOM node reference.
    const node_ptr: *anyopaque = blk: {
        if (this.isObject() and this.asJsObject().obj_type == .window_proxy) {
            // Window listener — use sentinel instead of a DOM node pointer.
            break :blk @ptrCast(&g_window_sentinel);
        }
        const n = getThisNode(this) orelse return JsValue.undefined_val;
        break :blk @ptrCast(n);
    };

    const event_type = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;

    // Own the event type string
    const owned = try g_alloc.alloc(u8, event_type.len);
    @memcpy(owned, event_type);

    const capture = if (args.len > 2 and args[2].isBool()) args[2].asBool() else false;

    try g_listeners.append(g_alloc, .{
        .node_ptr = node_ptr,
        .event_type = owned,
        .callback = callback,
        .capture = capture,
    });
    return JsValue.undefined_val;
}

/// window.removeEventListener — removes a previously registered window listener.
/// DOM §2.9: removeEventListener removes the first matching (type, callback, capture) entry.
fn nativeWindowRemoveEventListener(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    _ = this;
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.undefined_val;
    const event_type = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    const callback = args[1];
    const sentinel_ptr = @intFromPtr(&g_window_sentinel);
    var i: usize = 0;
    while (i < g_listeners.items.len) {
        const entry = g_listeners.items[i];
        if (@intFromPtr(entry.node_ptr) == sentinel_ptr and
            std.mem.eql(u8, entry.event_type, event_type) and
            entry.callback.bits == callback.bits)
        {
            g_alloc.free(entry.event_type);
            _ = g_listeners.orderedRemove(i);
            return JsValue.undefined_val;
        }
        i += 1;
    }
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

// ── Element.matches() / closest() — DOM Selectors API §4.1/§4.2 ────

/// C-ABI bridge to dom_selector.zig's full selector matching engine
extern fn suzume_element_matches(node: *lxb.lxb_dom_node_t, sel_ptr: [*]const u8, sel_len: usize) bool;

fn nativeMatches(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.undefined_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    return JsValue.initBool(suzume_element_matches(node, sel.ptr, sel.len));
}

fn nativeClosest(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const sel = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    var cur: ?*lxb.lxb_dom_node_t = getThisNode(this);
    while (cur) |n| {
        if (nodeType(n) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (suzume_element_matches(n, sel.ptr, sel.len))
                return wrapNode(vm, n) orelse JsValue.null_val;
        }
        cur = nodeParent(n);
    }
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
    if (args.len == 0) return JsValue.initBool(false);

    // HTML §8.1.3.1: window.dispatchEvent dispatches to window-level listeners.
    // The window_proxy object has no DOM node, so handle it separately.
    if (this.isObject() and this.asJsObject().obj_type == .window_proxy) {
        // Parse event type from the argument (string or Event object with .type).
        var type_str: []const u8 = "event";
        if (args[0].isString()) {
            type_str = vm.pool.get(args[0].asStringId()) orelse "event";
        } else if (args[0].isObject()) {
            const t_sid = vm.pool.intern("type") catch return JsValue.initBool(false);
            if (args[0].asJsObject().getProperty(t_sid)) |tv| {
                if (tv.isString()) type_str = vm.pool.get(tv.asStringId()) orelse "event";
            }
        }
        const ev_obj: *JsObject = if (args[0].isObject())
            args[0].asJsObject()
        else
            vm.createObj(.{}) catch return JsValue.initBool(false);
        const sentinel_ptr = @intFromPtr(&g_window_sentinel);
        for (g_listeners.items) |entry| {
            if (@intFromPtr(entry.node_ptr) != sentinel_ptr) continue;
            if (!std.mem.eql(u8, entry.event_type, type_str)) continue;
            _ = vm.callJsFunction(entry.callback, JsValue.initObject(ev_obj), &.{JsValue.initObject(ev_obj)}) catch {};
        }
        return JsValue.initBool(true);
    }

    const target = getThisNode(this) orelse return JsValue.initBool(false);

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
    raw_arr.data = .{ .array = .empty };
    raw_arr.prototype = vm.array_proto;
    const raw_ids = try vm.createObj(.{ .obj_type = .array });
    raw_ids.data = .{ .array = .empty };
    raw_ids.prototype = vm.array_proto;
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
    out.data = .{ .array = .empty };
    out.prototype = vm.array_proto;
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

// ── Element.scroll / scrollTo / scrollBy (CSSOM View §6.5) ──────────
//
// Inline style overflow is not tracked by the kotori VM; these methods
// accept any element and store scroll position unconditionally. A real
// implementation would skip non-scrollable elements once layout provides
// overflow information.

/// Parse (x, y) or ({top?, left?}) args into {top, left} floats.
/// CSSOM View §6.5: scroll()/scrollTo() accept either two numbers or a
/// ScrollToOptions dictionary {top?, left?, behavior?}.
fn parseScrollArgs(vm: *VM, args: []const JsValue) struct { top: f64, left: f64 } {
    if (args.len >= 2) {
        return .{ .top = args[1].toNumber(), .left = args[0].toNumber() };
    }
    if (args.len == 1 and args[0].isObject()) {
        const opts = args[0].asJsObject();
        var top: f64 = 0;
        var left: f64 = 0;
        if (vm.pool.intern("top") catch null) |top_sid| {
            if (opts.getProperty(top_sid)) |tv| top = tv.toNumber();
        }
        if (vm.pool.intern("left") catch null) |left_sid| {
            if (opts.getProperty(left_sid)) |lv| left = lv.toNumber();
        }
        return .{ .top = top, .left = left };
    }
    return .{ .top = 0, .left = 0 };
}

fn nativeScrollTo(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    const parsed = parseScrollArgs(vm, args);
    const key = @intFromPtr(node);
    ensureScrollMap().put(key, .{
        .top = @max(0.0, parsed.top),
        .left = @max(0.0, parsed.left),
    }) catch {};
    return JsValue.undefined_val;
}

fn nativeScroll(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    return nativeScrollTo(ctx, this, args);
}

fn nativeScrollBy(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    const delta = parseScrollArgs(vm, args);
    const key = @intFromPtr(node);
    const cur = ensureScrollMap().get(key) orelse ElemScrollPos{ .top = 0, .left = 0 };
    ensureScrollMap().put(key, .{
        .top = @max(0.0, cur.top + delta.top),
        .left = @max(0.0, cur.left + delta.left),
    }) catch {};
    return JsValue.undefined_val;
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

// ── DOM constructors ────────────────────────────────────────────────

fn nativeNoOpConstructor(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    return JsValue.undefined_val;
}

fn nativeTextConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const data = if (args.len > 0) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_text_node(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
}

fn nativeCommentConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const data = if (args.len > 0) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_comment(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
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
    // Assign prototype based on node type (DOM spec prototype chain)
    obj.prototype = switch (nodeType(node)) {
        lxb.LXB_DOM_NODE_TYPE_ELEMENT => vm.element_proto,
        lxb.LXB_DOM_NODE_TYPE_TEXT => g_text_proto,
        lxb.LXB_DOM_NODE_TYPE_COMMENT => g_comment_proto,
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => g_node_proto,
        else => g_node_proto,
    };
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
    arr.data = .{ .array = .empty };
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
// ── isEqualNode (DOM §4.4) ──────────────────────────────────────────

fn nativeIsEqualNode(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const a = getThisNode(this) orelse return JsValue.initBool(false);
    if (args.len == 0 or args[0].isNull() or args[0].isUndefined()) return JsValue.initBool(false);
    const b = getArgNode(args[0]) orelse return JsValue.initBool(false);
    return JsValue.initBool(nodesEqual(a, b));
}

fn nodesEqual(a: *lxb.lxb_dom_node_t, b: *lxb.lxb_dom_node_t) bool {
    // Step 1: same nodeType
    if (nodeType(a) != nodeType(b)) return false;

    const nt = nodeType(a);

    // Step 2: type-specific checks
    if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        // Compare local name
        const a_elem: *lxb.lxb_dom_element_t = @ptrCast(a);
        const b_elem: *lxb.lxb_dom_element_t = @ptrCast(b);
        var a_len: usize = 0;
        var b_len: usize = 0;
        const a_name = dom_b.lxb_dom_element_local_name(a_elem, &a_len);
        const b_name = dom_b.lxb_dom_element_local_name(b_elem, &b_len);
        if (a_len != b_len) return false;
        if (a_name != null and b_name != null) {
            if (!std.mem.eql(u8, a_name.?[0..a_len], b_name.?[0..b_len])) return false;
        }
        // Compare attribute count and values
        if (!attrsEqual(a_elem, b_elem)) return false;
    } else if (nt == lxb.LXB_DOM_NODE_TYPE_TEXT or nt == lxb.LXB_DOM_NODE_TYPE_COMMENT) {
        // Compare text data
        var a_len: usize = 0;
        var b_len: usize = 0;
        const a_txt = dom_b.lxb_dom_node_text_content(a, &a_len);
        const b_txt = dom_b.lxb_dom_node_text_content(b, &b_len);
        if (a_len != b_len) return false;
        if (a_txt != null and b_txt != null) {
            if (!std.mem.eql(u8, a_txt.?[0..a_len], b_txt.?[0..b_len])) return false;
        } else if (a_txt != b_txt) return false;
    }
    // DocumentType, PI: skip for now (handled as equal if same nodeType)

    // Step 3: compare children recursively
    var a_child = nodeFirstChild(a);
    var b_child = nodeFirstChild(b);
    while (a_child != null and b_child != null) {
        if (!nodesEqual(a_child.?, b_child.?)) return false;
        a_child = nodeNext(a_child.?);
        b_child = nodeNext(b_child.?);
    }
    // Both must be null (same number of children)
    return a_child == null and b_child == null;
}

fn attrsEqual(a: *lxb.lxb_dom_element_t, b: *lxb.lxb_dom_element_t) bool {
    // Count attributes
    const a_count = countAttrs(a);
    const b_count = countAttrs(b);
    if (a_count != b_count) return false;
    // Check each attribute of a exists in b with same value
    const a_node: *lxb.lxb_dom_node_t = @ptrCast(a);
    _ = a_node;
    // Use lexbor attribute iteration
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(a.first_attr);
    while (attr) |at| {
        var name_len: usize = 0;
        const name_ptr = lxb.lxb_dom_attr_qualified_name(at, &name_len);
        if (name_ptr) |np| {
            var val_len: usize = 0;
            const val_ptr = dom_b.lxb_dom_element_get_attribute(a, np, name_len, &val_len);
            // Check b has same attribute with same value
            var b_val_len: usize = 0;
            const b_val_ptr = dom_b.lxb_dom_element_get_attribute(b, np, name_len, &b_val_len);
            if (val_ptr == null and b_val_ptr == null) {
                // both null — equal
            } else if (val_ptr != null and b_val_ptr != null) {
                if (val_len != b_val_len) return false;
                if (!std.mem.eql(u8, val_ptr.?[0..val_len], b_val_ptr.?[0..b_val_len])) return false;
            } else return false;
        }
        attr = @ptrCast(at.node.next);
    }
    return true;
}

fn countAttrs(elem: *lxb.lxb_dom_element_t) usize {
    var count: usize = 0;
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(elem.first_attr);
    while (attr) |at| {
        count += 1;
        attr = @ptrCast(at.node.next);
    }
    return count;
}

// Helpers — textContent / innerHTML
// ══════════════════════════════════════════════════════════════════════

// ── CharacterData mutation methods ──────────────────────────────────

fn createDOMExceptionObj(vm: *VM, err_name: []const u8) !JsValue {
    const err = try vm.createObj(.{});
    if (vm.error_proto) |ep| err.prototype = ep;
    try err.setProperty(vm.allocator, try vm.pool.intern("name"), JsValue.initString(try vm.pool.intern(err_name)));
    try err.setProperty(vm.allocator, try vm.pool.intern("message"), JsValue.initString(try vm.pool.intern(err_name)));
    const code: f64 = if (std.mem.eql(u8, err_name, "IndexSizeError")) 1 else if (std.mem.eql(u8, err_name, "NotFoundError")) 8 else if (std.mem.eql(u8, err_name, "HierarchyRequestError")) 3 else 0;
    try err.setProperty(vm.allocator, try vm.pool.intern("code"), JsValue.initNumber(code));
    // Set constructor to DOMException
    const de_sid = try vm.pool.intern("DOMException");
    if (vm.globals.get(de_sid)) |de_ctor| {
        try err.setProperty(vm.allocator, try vm.pool.intern("constructor"), de_ctor);
        // Set prototype to DOMException.prototype for instanceof
        if (de_ctor.isObject()) {
            if (de_ctor.asJsObject().getProperty(try vm.pool.intern("prototype"))) |pv| {
                if (pv.isObject()) err.prototype = pv.asJsObject();
            }
        }
    }
    return JsValue.initObject(err);
}

fn getCharData(vm: *VM, this: JsValue) ?struct { node: *lxb.lxb_dom_node_t, text: []const u8 } {
    const node = getThisNode(this) orelse return null;
    var len: usize = 0;
    const ptr = dom_b.lxb_dom_node_text_content(node, &len);
    const text = if (ptr) |p| p[0..len] else "";
    _ = vm;
    return .{ .node = node, .text = text };
}

fn nativeAppendData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len == 0) return error.TypeError;
    const append_str = if (args[0].isString()) (vm.pool.get(args[0].asStringId()) orelse "") else if (args[0].isNull()) "null" else if (args[0].isUndefined()) "undefined" else "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, append_str) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    return JsValue.undefined_val;
}

fn nativeDeleteData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return JsValue.undefined_val;
    const off_f = args[0].toNumber();
    if (off_f < 0 or off_f > @as(f64, @floatFromInt(info.text.len))) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const offset: usize = @intFromFloat(@max(0, off_f));
    const count: usize = @intFromFloat(@max(0, args[1].toNumber()));
    if (offset > info.text.len) return JsValue.undefined_val;
    const end = @min(offset + count, info.text.len);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..offset]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[end..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    return JsValue.undefined_val;
}

fn nativeInsertData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return JsValue.undefined_val;
    const off_f = args[0].toNumber();
    if (off_f < 0 or off_f > @as(f64, @floatFromInt(info.text.len))) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const offset: usize = @intFromFloat(@max(0, off_f));
    const ins_str = if (args[1].isString()) (vm.pool.get(args[1].asStringId()) orelse "") else "";
    const clamped = @min(offset, info.text.len);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..clamped]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, ins_str) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[clamped..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    return JsValue.undefined_val;
}

fn nativeReplaceData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 3) return JsValue.undefined_val;
    const off_f = args[0].toNumber();
    if (off_f < 0 or off_f > @as(f64, @floatFromInt(info.text.len))) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const offset: usize = @intFromFloat(@max(0, off_f));
    const count: usize = @intFromFloat(@max(0, args[1].toNumber()));
    const rep_str = if (args[2].isString()) (vm.pool.get(args[2].asStringId()) orelse "") else "";
    if (offset > info.text.len) return JsValue.undefined_val;
    const end = @min(offset + count, info.text.len);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..offset]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, rep_str) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[end..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    return JsValue.undefined_val;
}

fn nativeSubstringData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return JsValue.undefined_val;
    const off_f = args[0].toNumber();
    if (off_f < 0 or off_f > @as(f64, @floatFromInt(info.text.len))) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const offset: usize = @intFromFloat(@max(0, off_f));
    const count: usize = @intFromFloat(@max(0, args[1].toNumber()));
    if (offset > info.text.len) return JsValue.initString(vm.pool.intern("") catch return JsValue.undefined_val);
    const end = @min(offset + count, info.text.len);
    return JsValue.initString(vm.pool.intern(info.text[offset..end]) catch return JsValue.undefined_val);
}

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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| {
        _ = dom_b.lxb_html_serialize_tree_cb(c, &serializeCb, @ptrCast(&buf));
        ch = nodeNext(c);
    }
    return JsValue.initString(vm.pool.intern(buf.items) catch return JsValue.null_val);
}

fn getOuterHTML(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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

/// Collect all elements under `root` matching `selector`.
/// Caller owns the returned slice (allocated with `alloc`).
fn findAllMatches(root: *lxb.lxb_dom_node_t, selector: []const u8, alloc: std.mem.Allocator) []const *lxb.lxb_dom_node_t {
    const sel = std.mem.trim(u8, selector, " \t\r\n");
    if (sel.len == 0) return &.{};

    var results: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t) = .empty;
    var cur: ?*lxb.lxb_dom_node_t = nodeFirstChild(root);
    while (cur) |node| {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (matchSimpleSelector(@ptrCast(node), sel)) {
                results.append(alloc, node) catch {};
            }
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
    return results.toOwnedSlice(alloc) catch &.{};
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
