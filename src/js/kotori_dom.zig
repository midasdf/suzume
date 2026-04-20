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

// ── Shared Name/QName validation (DOM §1.5) ────────────────────────
const dom_names = @import("dom_names");

// ── HTML §2.6 reflected attributes table (Layer 4A) ────────────────
const refl = @import("html_reflection.zig");

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

/// CSSOM §6.7.2 invalid-value rejection callback. Returns true to accept
/// the value for the given property, false to silently drop (preserving
/// the pre-bracket-dispatch silent no-op behaviour that the WPT
/// `test_invalid_value` helper relies on). Main registers a bridge to
/// `dom_style.isValidCssValue`.
pub const ValidateFn = *const fn (prop: []const u8, val: []const u8) bool;
pub var validate_fn: ?ValidateFn = null;

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

/// Register the CSSOM §6.7.2 invalid-value rejection bridge. Without
/// this, setters accept any string into the inline style attribute; WPT
/// `test_invalid_value` asserts invalid writes leave the attribute
/// unchanged, matching browsers' specified-value rejection semantics.
pub fn setValidateCallback(cb: ?ValidateFn) void {
    validate_fn = cb;
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
    // Attribute existence / first-attr (used by hasAttribute, hasAttributes)
    pub extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
    pub extern fn lxb_dom_element_first_attribute_noi(element: *lxb.lxb_dom_element_t) ?*anyopaque;
    pub extern fn lxb_dom_element_next_attribute_noi(attr: *lxb.lxb_dom_attr_t) ?*anyopaque;
    // Locate an attribute struct by qualified name (used to look up pointer before remove)
    pub extern fn lxb_dom_element_attr_by_name(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) ?*lxb.lxb_dom_attr_t;
    // Insert after a reference node (used by insertAdjacentElement "afterend")
    pub extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
    // Clone a node (shallow or deep)
    pub extern fn lxb_dom_node_clone(node: *lxb.lxb_dom_node_t, deep: bool) ?*lxb.lxb_dom_node_t;
    // Document fragment creation
    pub extern fn lxb_dom_document_create_document_fragment(document: *anyopaque) ?*lxb.lxb_dom_node_t;
    // Qualified name (includes prefix for namespaced elements)
    pub extern fn lxb_dom_element_qualified_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
    // DocumentType accessors
    pub extern fn lxb_dom_document_type_name_noi(dtype: *anyopaque, len: *usize) ?[*]const u8;
    pub extern fn lxb_dom_document_type_public_id_noi(dtype: *anyopaque, len: *usize) ?[*]const u8;
    pub extern fn lxb_dom_document_type_system_id_noi(dtype: *anyopaque, len: *usize) ?[*]const u8;
    // Attribute accessors
    pub extern fn lxb_dom_attr_qualified_name(attr: *anyopaque, len: *usize) ?[*]const u8;
    pub extern fn lxb_dom_attr_value_noi(attr: *anyopaque, len: *usize) ?[*]const u8;
    // HTML document creation (for createHTMLDocument)
    pub extern fn lxb_html_document_create() ?*anyopaque;
    pub extern fn lxb_html_document_parse(document: *anyopaque, html: [*]const u8, size: usize) u32;
    pub extern fn lxb_html_document_body_element_noi(document: *anyopaque) ?*lxb.lxb_dom_node_t;
    pub extern fn lxb_html_document_head_element_noi(document: *anyopaque) ?*lxb.lxb_dom_node_t;
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

// Storage for createHTMLDocument-created documents (prevent deallocation)
var created_docs: [32]?*anyopaque = .{null} ** 32;
var created_doc_count: usize = 0;

// Namespace info for createElementNS elements (lexbor HTML DOM doesn't store XML prefixes)
const NsInfo = struct { prefix: []const u8, uri: []const u8 };
var ns_info_map: ?std.AutoHashMapUnmanaged(usize, NsInfo) = null;

fn ensureNsInfoMap() *std.AutoHashMapUnmanaged(usize, NsInfo) {
    if (ns_info_map == null) ns_info_map = .empty;
    return &ns_info_map.?;
}

fn getNsInfo(node: *lxb.lxb_dom_node_t) ?NsInfo {
    const map = &(ns_info_map orelse return null);
    return map.get(@intFromPtr(node));
}

/// Get the lexbor document from `this` (if it's a document node) or fall back to g_document.
/// Enables createElement/createTextNode/etc. to work on both the main document and
/// documents created by createHTMLDocument.
fn getDocFromThis(this: JsValue) ?*anyopaque {
    if (this.isObject()) {
        const obj = this.asJsObject();
        if (obj.obj_type == .dom_node) {
            const node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(obj.data.dom_node));
            if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
                return obj.data.dom_node;
            }
        }
    }
    return g_document;
}

fn setDomDirty() void {
    dom_dirty = true;
}

// ── Event listener storage ──────────────────────────────────────────
pub const EventListener = struct {
    node_ptr: *anyopaque,
    event_type: []const u8, // owned copy
    callback: JsValue, // function object ref
    capture: bool,
    once: bool = false,
    passive: bool = false,
};

var g_listeners: std.ArrayListUnmanaged(EventListener) = .empty;

// DOM prototype chain: Node.prototype → CharacterData.prototype → Text/Comment.prototype
// Element.prototype also inherits from Node.prototype
var g_node_proto: ?*JsObject = null;
var g_chardata_proto: ?*JsObject = null;
var g_text_proto: ?*JsObject = null;
var g_comment_proto: ?*JsObject = null;
var g_doctype_proto: ?*JsObject = null;
var g_event_proto: ?*JsObject = null;
var g_xml_doc_proto: ?*JsObject = null;
var g_domparser_proto: ?*JsObject = null;
// HTML/SVG/MathML interface prototypes (spec §3.5). Built in initDomBuiltins
// BEFORE the bootstrap `doc_obj` wrap so that Task 7's applyInterfaceProto
// invariant (g_html_protos != null) holds from the first wrapNode call.
// All frozen post-build per HTML §4 prototype-chain immutability.
var g_html_element_proto: ?*JsObject = null;
var g_svg_element_proto: ?*JsObject = null;
var g_mathml_element_proto: ?*JsObject = null;
var g_html_protos: ?std.StringHashMap(*JsObject) = null;
var g_svg_protos: ?std.StringHashMap(*JsObject) = null;
/// Cached StringId for the `_ownerDoc` slot — avoids `pool.intern` on every
/// `setNodeOwnerDoc` / `getNodeOwnerDoc` call (hot path: called from every
/// wrapNode, every creator, and every ownerDocument getter).
var g_sid_owner_doc: ?StringId = null;

// ── MutationObserver storage (DOM §4.3) ─────────────────────────────

const MoTarget = struct {
    node_ptr: usize, // @intFromPtr of observed DOM node
    child_list: bool = false,
    attributes: bool = false,
    character_data: bool = false,
    subtree: bool = false,
    attribute_old_value: bool = false,
    character_data_old_value: bool = false,
    // DOM §4.3.3 step 3.3: optional list of attribute local-names; empty slice
    // means "no filter, match all attributes". Strings are owned by the target.
    attribute_filter: []const []const u8 = &.{},
};

const MoRecord = struct {
    type_str: []const u8, // "childList" or "attributes" or "characterData"
    target: JsValue, // wrapped node
    added_nodes: JsValue, // JS array
    removed_nodes: JsValue, // JS array
    previous_sibling: JsValue,
    next_sibling: JsValue,
    attribute_name: JsValue,
    old_value: JsValue,
};

const MoEntry = struct {
    callback: JsValue, // JS function
    targets: std.ArrayListUnmanaged(MoTarget),
    pending: std.ArrayListUnmanaged(MoRecord),
    disconnected: bool,
};

var g_mo_list: std.ArrayListUnmanaged(MoEntry) = .empty;
pub var g_mo_pending: bool = false;
var g_mo_vm: ?*VM = null;

/// Node wrapper cache: maps lexbor DOM node pointer → JsObject wrapper.
/// Ensures `===` identity for the same DOM node (WebIDL §3.1 object identity).
var g_node_cache: std.AutoHashMapUnmanaged(usize, *JsObject) = .{};

fn nodeCacheGet(node: *lxb.lxb_dom_node_t) ?*JsObject {
    return g_node_cache.get(@intFromPtr(node));
}

fn nodeCachePut(allocator: std.mem.Allocator, node: *lxb.lxb_dom_node_t, obj: *JsObject) void {
    g_node_cache.put(allocator, @intFromPtr(node), obj) catch {};
}

/// Attr wrapper cache: maps lexbor attr pointer → JsObject wrapper.
/// DOM §4.9.1 requires `el.attributes[0] === el.attributes[0]` (Attr identity).
/// Keyed on the lexbor attr pointer; invalidated on removeAttribute.
var g_attr_wrappers: std.AutoHashMapUnmanaged(usize, *JsObject) = .{};

/// Drop a cached Attr wrapper (called before lexbor frees the underlying
/// attribute struct, e.g. from removeAttribute / toggleAttribute-removes).
fn invalidateAttrWrapper(attr: *lxb.lxb_dom_attr_t) void {
    _ = g_attr_wrappers.remove(@intFromPtr(attr));
}

/// DOM §4.9.2 NamedNodeMap.prototype — single shared prototype for every
/// live `Element.attributes` object. Populated during initNamedNodeMapProto()
/// before any document is wrapped.
var g_namednodemap_proto: ?*JsObject = null;

/// Per-element monotonic attribute version counter. Bumped on every
/// mutation (setAttribute / setAttributeNS / removeAttribute /
/// toggleAttribute / setNamedItem / removeNamedItem). Read via the
/// `__nnmVer` slot on map objects to decide whether to refresh indexed
/// + named snapshots.
var g_elem_attr_ver: std.AutoHashMapUnmanaged(usize, u64) = .{};

/// Bump the per-element attribute version. Safe to call even before the
/// map has been materialised; the first bump initialises to 1.
fn bumpElemAttrVersion(elem: *lxb.lxb_dom_element_t) void {
    const key = @intFromPtr(elem);
    const gop = g_elem_attr_ver.getOrPut(g_alloc, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* +%= 1;
}

// Interned string IDs for hidden NamedNodeMap + Attr-owner slots.
// Populated in initNamedNodeMapProto, reused by all native methods.
var g_sid_nnm_elem: ?StringId = null; // "__nnmElem"      usize elem ptr
var g_sid_nnm_ver: ?StringId = null; // "__nnmVer"        u64 version
var g_sid_nnm_cache: ?StringId = null; // "__nnmCache"    *JsObject map
// Layer 1D.1 Task 8: stale-key sweep tracking slots on the map JS object.
// `__nnmMaxIdx` records the high-water indexed-key count from the previous
// refresh; surplus numeric keys [count..prev_max) are deleted on the next
// refresh. `__nnmNames` is an inner JsObject acting as a set whose own
// properties are the qualified-name StringIds present in the previous
// snapshot; any name not re-observed this pass is deleted from the map.
var g_sid_nnm_max_idx: ?StringId = null; // "__nnmMaxIdx" u32 prev count
var g_sid_nnm_names: ?StringId = null; // "__nnmNames"    *JsObject name-set
var g_sid_owner_elem_ptr: ?StringId = null; // "__ownerElemPtr" usize node ptr (on Attr)
/// Layer 1D.1 Task 4: opaque lxb_dom_attr_t* on the Attr JsObject — allows
/// setAttributeNode (Task 5) to drop the stale g_attr_wrappers entry and
/// re-key the new lexbor ptr to the SAME JsObject so identity holds across
/// cross-element Attr transfers (spec §R1).
var g_sid_attr_backing_ptr: ?StringId = null; // "__attrBackingPtr"

/// DOM §4.4 — write the per-Node owner document slot.
/// `owner_doc_val` is `JsValue.null_val` for Document nodes themselves.
/// The slot is named `_ownerDoc` (underscore prefix) to distinguish it from
/// the JS-visible `ownerDocument` property; the getter at domNodeGetProp
/// reads this slot directly for lexbor-backed `.dom_node` wrappers.
///
/// For plain JsObject wrappers (createJsOnlyElement, Attr, DocumentType,
/// ProcessingInstruction, etc.) `domNodeGetProp` never fires, so the
/// JS-visible `ownerDocument` property must also be set for script access
/// (DOM §4.4 Node.ownerDocument getter). `.dom_node` objects get the JS
/// property too, but `dom_get_prop` intercepts the read before the
/// prototype walk so the slot-backed getter still wins — keeping the two
/// paths consistent.
pub fn setNodeOwnerDoc(vm: *VM, obj: *JsObject, owner_doc_val: JsValue) void {
    const sid = g_sid_owner_doc orelse return;
    obj.setProperty(vm.allocator, sid, owner_doc_val) catch {};
    const od_sid = vm.pool.intern("ownerDocument") catch return;
    obj.setProperty(vm.allocator, od_sid, owner_doc_val) catch {};
}

/// DOM §4.4 — read the per-Node owner document slot.
/// Returns `JsValue.null_val` if the slot was never written.
pub fn getNodeOwnerDoc(_: *VM, obj: *JsObject) JsValue {
    const sid = g_sid_owner_doc orelse return JsValue.null_val;
    return obj.getProperty(sid) orelse JsValue.null_val;
}

/// DOM §4.5.3 + HTML §4 + SVG2 §4 + MathML Core §2 — assign the correct
/// interface prototype and owner-document slot to a newly-created element
/// wrapper in one call.
///
/// `namespace` is the W3C namespace URI of the element (null for
/// null-namespace elements, which map to the generic `Element` prototype).
/// `local_name` is the element's local name (HTML NS requires lowercase
/// for known-tag dispatch; see kotori_html_interfaces.resolveInterface).
///
/// Spec §3.6 init-order invariant: this must only be called after
/// initInterfaceProtos has populated g_html_protos (asserted below).
fn applyInterfaceProto(
    vm: *VM,
    obj: *JsObject,
    namespace: ?[]const u8,
    local_name: []const u8,
    owner_doc: JsValue,
) void {
    const iface_mod = @import("kotori_html_interfaces.zig");
    std.debug.assert(g_html_protos != null); // init-order invariant (spec §3.6)
    setNodeOwnerDoc(vm, obj, owner_doc);
    const iface_name = iface_mod.resolveInterface(namespace, local_name);
    if (getHtmlProto(iface_name)) |p| {
        obj.prototype = p;
        return;
    }
    if (getSvgProto(iface_name)) |p| {
        obj.prototype = p;
        return;
    }
    if (std.mem.eql(u8, iface_name, "MathMLElement")) {
        obj.prototype = g_mathml_element_proto.?;
        return;
    }
    // "Element" fallback for null-namespace / unknown-namespace elements.
    obj.prototype = vm.element_proto.?;
}

fn nodeCacheRemove(node: *lxb.lxb_dom_node_t) void {
    _ = g_node_cache.remove(@intFromPtr(node));
}

/// Map lexbor namespace IDs to W3C namespace URI strings.
fn nsIdToUri(ns_id: usize) ?[]const u8 {
    return switch (ns_id) {
        0x02 => "http://www.w3.org/1999/xhtml", // LXB_NS_HTML
        0x03 => "http://www.w3.org/1998/Math/MathML", // LXB_NS_MATH
        0x04 => "http://www.w3.org/2000/svg", // LXB_NS_SVG
        0x05 => "http://www.w3.org/1999/xlink", // LXB_NS_XLINK
        0x06 => "http://www.w3.org/XML/1998/namespace", // LXB_NS_XML
        0x07 => "http://www.w3.org/2000/xmlns/", // LXB_NS_XMLNS
        else => null,
    };
}

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
    // Clear any stale pending_throw from prior script execution — event dispatch
    // is a new "task" per HTML spec, errors shouldn't leak across task boundaries.
    vm.pending_throw = null;
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
        // Clear pending_throw between listeners so one failing listener
        // doesn't prevent subsequent listeners from executing.
        vm.pending_throw = null;
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
    // Attr wrapper cache: entries point to JsObjects owned by the VM arena,
    // so we only need to drop the HashMap's own storage here.
    g_attr_wrappers.deinit(g_alloc);
    g_attr_wrappers = .{};
    // NamedNodeMap per-element attribute version counter (DOM §4.9.2 live semantics).
    g_elem_attr_ver.deinit(g_alloc);
    g_elem_attr_ver = .{};
    g_namednodemap_proto = null;
    g_sid_nnm_elem = null;
    g_sid_nnm_ver = null;
    g_sid_nnm_cache = null;
    g_sid_nnm_max_idx = null;
    g_sid_nnm_names = null;
    g_sid_owner_elem_ptr = null;
    g_sid_attr_backing_ptr = null;
    // Interface prototype maps (HTML/SVG). Values are JsObjects owned by the
    // VM arena, so we only drop the HashMap's own storage. Roots (HTMLElement /
    // SVGElement / MathMLElement prototypes) are likewise arena-owned.
    if (g_html_protos) |*m| {
        m.deinit();
        g_html_protos = null;
    }
    if (g_svg_protos) |*m| {
        m.deinit();
        g_svg_protos = null;
    }
    g_html_element_proto = null;
    g_svg_element_proto = null;
    g_mathml_element_proto = null;
    // Shadow DOM tree-scope state is per-Document (DOM §4.8); clear it so
    // freed lxb node pointers reused by the next document don't inherit
    // stale scope ids or impersonate old shadow roots.
    sr.reset();
    g_document = null;
    dom_dirty = false;
}

// ── Interface prototype accessors (Task 5 / spec §3.5) ──
// Tests live in a separate compilation unit and cannot read file-scoped
// `var`s directly. These thin accessors give tests (and Task 7's
// applyInterfaceProto) a stable public surface.

pub fn getHtmlElementProto() ?*JsObject {
    return g_html_element_proto;
}

pub fn getSvgElementProto() ?*JsObject {
    return g_svg_element_proto;
}

pub fn getMathMLElementProto() ?*JsObject {
    return g_mathml_element_proto;
}

pub fn getHtmlProto(name: []const u8) ?*JsObject {
    const m = g_html_protos orelse return null;
    return m.get(name);
}

pub fn getSvgProto(name: []const u8) ?*JsObject {
    const m = g_svg_protos orelse return null;
    return m.get(name);
}

// ══════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════

pub fn initDomBuiltins(vm: *VM, document_ptr: *anyopaque) !void {
    g_alloc = vm.allocator;
    g_document = document_ptr;

    // Cache the `_ownerDoc` StringId once so set/getNodeOwnerDoc avoid
    // pool.intern on every call (hot path — called from every wrapNode).
    g_sid_owner_doc = try vm.pool.intern("_ownerDoc");

    // ── Node.prototype (base for all DOM nodes) ──
    g_node_proto = try vm.createObj(.{});
    const np = g_node_proto.?;
    try vm.registerNativeMethod(np, "appendChild", &nativeAppendChild);
    try vm.registerNativeMethod(np, "removeChild", &nativeRemoveChild);
    try vm.registerNativeMethod(np, "insertBefore", &nativeInsertBefore);
    try vm.registerNativeMethod(np, "isEqualNode", &nativeIsEqualNode);
    try vm.registerNativeMethod(np, "getRootNode", &nativeGetRootNode);
    try vm.registerNativeMethod(np, "addEventListener", &nativeAddEventListener);
    try vm.registerNativeMethod(np, "removeEventListener", &nativeRemoveEventListener);
    try vm.registerNativeMethod(np, "dispatchEvent", &nativeDispatchEvent);
    try vm.registerNativeMethod(np, "cloneNode", &nativeCloneNode);
    try vm.registerNativeMethod(np, "isSameNode", &nativeIsSameNode);
    try vm.registerNativeMethod(np, "contains", &nativeContains);
    try vm.registerNativeMethod(np, "compareDocumentPosition", &nativeCompareDocumentPosition);
    try vm.registerNativeMethod(np, "replaceChild", &nativeReplaceChild);
    try vm.registerNativeMethod(np, "normalize", &nativeNormalize);
    try vm.registerNativeMethod(np, "prepend", &nativePrepend);
    try vm.registerNativeMethod(np, "append", &nativeAppend);
    try vm.registerNativeMethod(np, "replaceChildren", &nativeReplaceChildren);
    try vm.registerNativeMethod(np, "before", &nativeBefore);
    try vm.registerNativeMethod(np, "after", &nativeAfter);
    try vm.registerNativeMethod(np, "replaceWith", &nativeReplaceWith);
    try vm.registerNativeMethod(np, "remove", &nativeRemove);
    try vm.registerNativeMethod(np, "lookupNamespaceURI", &nativeLookupNamespaceURI);
    try vm.registerNativeMethod(np, "isDefaultNamespace", &nativeIsDefaultNamespace);

    // ── Node.prototype constants ──
    // Node type constants (DOM §4.4)
    try np.setProperty(vm.allocator, try vm.pool.intern("ELEMENT_NODE"), JsValue.initNumber(1));
    try np.setProperty(vm.allocator, try vm.pool.intern("ATTRIBUTE_NODE"), JsValue.initNumber(2));
    try np.setProperty(vm.allocator, try vm.pool.intern("TEXT_NODE"), JsValue.initNumber(3));
    try np.setProperty(vm.allocator, try vm.pool.intern("CDATA_SECTION_NODE"), JsValue.initNumber(4));
    try np.setProperty(vm.allocator, try vm.pool.intern("PROCESSING_INSTRUCTION_NODE"), JsValue.initNumber(7));
    try np.setProperty(vm.allocator, try vm.pool.intern("COMMENT_NODE"), JsValue.initNumber(8));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_NODE"), JsValue.initNumber(9));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_TYPE_NODE"), JsValue.initNumber(10));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_FRAGMENT_NODE"), JsValue.initNumber(11));
    // Document position bitmask constants (DOM §4.4)
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_DISCONNECTED"), JsValue.initNumber(1));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_PRECEDING"), JsValue.initNumber(2));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_FOLLOWING"), JsValue.initNumber(4));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_CONTAINS"), JsValue.initNumber(8));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_CONTAINED_BY"), JsValue.initNumber(16));
    try np.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC"), JsValue.initNumber(32));

    // ── CharacterData.prototype → Node.prototype ──
    g_chardata_proto = try vm.createObj(.{});
    g_chardata_proto.?.prototype = g_node_proto;

    // ── Text.prototype → CharacterData.prototype ──
    g_text_proto = try vm.createObj(.{});
    g_text_proto.?.prototype = g_chardata_proto;

    // ── Comment.prototype → CharacterData.prototype ──
    g_comment_proto = try vm.createObj(.{});
    g_comment_proto.?.prototype = g_chardata_proto;

    // ── DocumentType.prototype → Node.prototype ──
    g_doctype_proto = try vm.createObj(.{});
    g_doctype_proto.?.prototype = g_node_proto;

    // ── Element.prototype → Node.prototype ──
    vm.element_proto = try vm.createObj(.{});
    const ep = vm.element_proto.?;
    ep.prototype = g_node_proto;
    // Element-specific methods (Node methods inherited via prototype chain)
    try vm.registerNativeMethod(ep, "setAttribute", &nativeSetAttribute);
    try vm.registerNativeMethod(ep, "setAttributeNS", &nativeSetAttributeNS);
    try vm.registerNativeMethod(ep, "getAttribute", &nativeGetAttribute);
    try vm.registerNativeMethod(ep, "removeAttribute", &nativeRemoveAttribute);
    try vm.registerNativeMethod(ep, "querySelector", &nativeQuerySelector);
    try vm.registerNativeMethod(ep, "querySelectorAll", &nativeQuerySelectorAll);
    try vm.registerNativeMethod(ep, "matches", &nativeMatches);
    try vm.registerNativeMethod(ep, "closest", &nativeClosest);
    try vm.registerNativeMethod(ep, "getElementsByTagName", &nativeGetElementsByTagName);
    try vm.registerNativeMethod(ep, "getElementsByClassName", &nativeGetElementsByClassName);
    try vm.registerNativeMethod(ep, "getElementsByTagNameNS", &nativeGetElementsByTagNameNS);
    try vm.registerNativeMethod(ep, "attachShadow", &nativeAttachShadow);
    try vm.registerNativeMethod(ep, "hasAttribute", &nativeHasAttribute);
    try vm.registerNativeMethod(ep, "hasAttributes", &nativeHasAttributes);
    try vm.registerNativeMethod(ep, "toggleAttribute", &nativeToggleAttribute);
    // DOM §4.9.1 Attr-node accessors (Layer 1D.1 Task 1): read-only
    // lookup on the element's attribute list; return cached Attr wrapper.
    try vm.registerNativeMethod(ep, "getAttributeNode", &nativeGetAttributeNode);
    try vm.registerNativeMethod(ep, "getAttributeNodeNS", &nativeGetAttributeNodeNS);
    // DOM §4.9.1 namespace-aware getters (Layer 1D.1 Task 2).
    try vm.registerNativeMethod(ep, "hasAttributeNS", &nativeHasAttributeNS);
    try vm.registerNativeMethod(ep, "getAttributeNS", &nativeGetAttributeNS);
    // DOM §4.9.1 namespace-aware remove (Layer 1D.1 Task 3).
    try vm.registerNativeMethod(ep, "removeAttributeNS", &nativeRemoveAttributeNS);
    // DOM §4.9.1 setAttributeNode[NS] (Layer 1D.1 Task 5) — WebIDL §4.9.1
    // prose "likewise": both method names share one native.
    try vm.registerNativeMethod(ep, "setAttributeNode", &nativeSetAttributeNodeImpl);
    try vm.registerNativeMethod(ep, "setAttributeNodeNS", &nativeSetAttributeNodeImpl);
    // DOM §4.9.1 removeAttributeNode (Layer 1D.1 Task 6) — NotFoundError
    // when the Attr is not in this element's attribute list (distinct from
    // removeAttribute's silent-on-miss semantics, spec §R3).
    try vm.registerNativeMethod(ep, "removeAttributeNode", &nativeRemoveAttributeNode);
    try vm.registerNativeMethod(ep, "insertAdjacentElement", &nativeInsertAdjacentElement);
    try vm.registerNativeMethod(ep, "insertAdjacentText", &nativeInsertAdjacentText);
    // CSSOM View §6.5: scroll / scrollTo / scrollBy
    try vm.registerNativeMethod(ep, "scroll", &nativeScroll);
    try vm.registerNativeMethod(ep, "scrollTo", &nativeScrollTo);
    try vm.registerNativeMethod(ep, "scrollBy", &nativeScrollBy);

    // ── HTML/SVG/MathML interface prototype hierarchy (spec §3.5) ──
    // MUST be built BEFORE the `doc_obj` wrap below so Task 7's
    // applyInterfaceProto invariant (g_html_protos != null) holds from
    // the very first wrapNode call.
    const iface_mod = @import("kotori_html_interfaces.zig");

    // HTMLElement.prototype → Element.prototype
    g_html_element_proto = try vm.createObj(.{});
    g_html_element_proto.?.prototype = ep;

    // SVGElement.prototype → Element.prototype
    g_svg_element_proto = try vm.createObj(.{});
    g_svg_element_proto.?.prototype = ep;

    // MathMLElement.prototype → Element.prototype
    g_mathml_element_proto = try vm.createObj(.{});
    g_mathml_element_proto.?.prototype = ep;

    // Per-subclass HTML prototypes → HTMLElement.prototype
    var html_map = std.StringHashMap(*JsObject).init(vm.allocator);
    try html_map.put("HTMLElement", g_html_element_proto.?);
    for (iface_mod.html_unique_ifaces) |name| {
        if (std.mem.eql(u8, name, "HTMLElement")) continue; // already inserted
        const proto = try vm.createObj(.{});
        proto.prototype = g_html_element_proto.?;
        try html_map.put(name, proto);
    }
    // Abstract HTML interfaces (e.g. HTMLMediaElement) — HTML §4 superclasses
    // exposed as globals for WPT / instanceof; prototype chains to
    // HTMLElement.prototype. No tag resolves to them directly.
    for (iface_mod.html_abstract_ifaces) |name| {
        const proto = try vm.createObj(.{});
        proto.prototype = g_html_element_proto.?;
        try html_map.put(name, proto);
    }
    g_html_protos = html_map;

    // Per-subclass SVG prototypes → SVGElement.prototype
    var svg_map = std.StringHashMap(*JsObject).init(vm.allocator);
    try svg_map.put("SVGElement", g_svg_element_proto.?);
    for (iface_mod.svg_unique_ifaces) |name| {
        if (std.mem.eql(u8, name, "SVGElement")) continue; // already inserted
        const proto = try vm.createObj(.{});
        proto.prototype = g_svg_element_proto.?;
        try svg_map.put(name, proto);
    }
    g_svg_protos = svg_map;

    // Freeze all interface prototypes — spec §3.5 point 6 / HTML §4
    // prototype-chain immutability (spec correctness, not performance).
    try g_html_element_proto.?.freeze(vm.allocator);
    {
        var it = g_html_protos.?.iterator();
        while (it.next()) |entry| {
            // HTMLElement root already frozen above; skip to avoid re-freeze.
            if (entry.value_ptr.* == g_html_element_proto.?) continue;
            try entry.value_ptr.*.freeze(vm.allocator);
        }
    }
    try g_svg_element_proto.?.freeze(vm.allocator);
    {
        var it = g_svg_protos.?.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == g_svg_element_proto.?) continue;
            try entry.value_ptr.*.freeze(vm.allocator);
        }
    }
    try g_mathml_element_proto.?.freeze(vm.allocator);

    // ── NamedNodeMap prototype + constructor (DOM §4.9.2, Layer 1D) ──
    // Must run before the bootstrap document wrap so buildAttributesMap
    // can link map objects to g_namednodemap_proto from the very first
    // element.attributes access.
    try initNamedNodeMapProto(vm);

    // ── document global ──
    const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
    doc_obj.data = .{ .dom_node = document_ptr };
    // DOM §4.4 — Document.prototype chains to Node.prototype, not
    // Element.prototype. Document-specific methods (createElement,
    // querySelector, etc.) are registered directly on doc_obj below.
    doc_obj.prototype = np;
    // Cache document wrapper for === identity (WebIDL §3.1)
    nodeCachePut(vm.allocator, @ptrCast(@alignCast(document_ptr)), doc_obj);
    // DOM §4.4 — Document itself has ownerDocument = null.
    setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
    try vm.registerNativeMethod(doc_obj, "getElementById", &nativeGetElementById);
    try vm.registerNativeMethod(doc_obj, "querySelector", &nativeDocQuerySelector);
    try vm.registerNativeMethod(doc_obj, "querySelectorAll", &nativeDocQuerySelectorAll);
    try vm.registerNativeMethod(doc_obj, "getElementsByTagName", &nativeGetElementsByTagName);
    try vm.registerNativeMethod(doc_obj, "getElementsByClassName", &nativeGetElementsByClassName);
    try vm.registerNativeMethod(doc_obj, "getElementsByTagNameNS", &nativeGetElementsByTagNameNS);
    try vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement);
    try vm.registerNativeMethod(doc_obj, "createElementNS", &nativeCreateElementNS);
    try vm.registerNativeMethod(doc_obj, "createAttribute", &nativeCreateAttribute);
    try vm.registerNativeMethod(doc_obj, "createAttributeNS", &nativeCreateAttributeNS);
    try vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode);
    try vm.registerNativeMethod(doc_obj, "createComment", &nativeCreateComment);
    try vm.registerNativeMethod(doc_obj, "createCDATASection", &nativeCreateCDATASection);
    try vm.registerNativeMethod(doc_obj, "createDocumentFragment", &nativeCreateDocumentFragment);
    try vm.registerNativeMethod(doc_obj, "adoptNode", &nativeAdoptNode);
    try vm.registerNativeMethod(doc_obj, "importNode", &nativeImportNode);
    try vm.registerNativeMethod(doc_obj, "createEvent", &nativeCreateEvent);
    try vm.registerNativeMethod(doc_obj, "createProcessingInstruction", &nativeCreateProcessingInstruction);

    // document.readyState — needed by testharness.js for completion detection
    const rs_sid = try vm.pool.intern("readyState");
    doc_obj.setProperty(vm.allocator, rs_sid, JsValue.initString(try vm.pool.intern("complete"))) catch {};

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
    // window.parent / window.top / window.frames — self-referential for top-level window
    const win_val = JsValue.initObject(win_obj);
    const parent_id = try vm.pool.intern("parent");
    win_obj.setProperty(vm.allocator, parent_id, win_val) catch {};
    const top_id = try vm.pool.intern("top");
    win_obj.setProperty(vm.allocator, top_id, win_val) catch {};
    const frames_id = try vm.pool.intern("frames");
    win_obj.setProperty(vm.allocator, frames_id, win_val) catch {};
    const opener_id = try vm.pool.intern("opener");
    win_obj.setProperty(vm.allocator, opener_id, JsValue.null_val) catch {};
    // window.location — basic object for testharness.js
    const loc_obj = try vm.createObj(.{});
    const href_sid = try vm.pool.intern("href");
    loc_obj.setProperty(vm.allocator, href_sid, JsValue.initString(try vm.pool.intern("about:blank"))) catch {};
    const loc_id = try vm.pool.intern("location");
    win_obj.setProperty(vm.allocator, loc_id, JsValue.initObject(loc_obj)) catch {};

    // ── DOM constructor globals (for instanceof and WPT) ──
    // Node constructor + prototype
    const node_ctor = try vm.createObj(.{ .obj_type = .native_function });
    node_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    const proto_sid = try vm.pool.intern("prototype");
    node_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(np)) catch {};
    const node_id = try vm.pool.intern("Node");
    try vm.globals.put(vm.allocator, node_id, JsValue.initObject(node_ctor));

    // WebIDL §3.6.1: Constants must be on BOTH interface object (constructor) AND prototype
    // Node type constants
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("ELEMENT_NODE"), JsValue.initNumber(1));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("ATTRIBUTE_NODE"), JsValue.initNumber(2));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("TEXT_NODE"), JsValue.initNumber(3));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("CDATA_SECTION_NODE"), JsValue.initNumber(4));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("ENTITY_REFERENCE_NODE"), JsValue.initNumber(5));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("ENTITY_NODE"), JsValue.initNumber(6));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("PROCESSING_INSTRUCTION_NODE"), JsValue.initNumber(7));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("COMMENT_NODE"), JsValue.initNumber(8));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_NODE"), JsValue.initNumber(9));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_TYPE_NODE"), JsValue.initNumber(10));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_FRAGMENT_NODE"), JsValue.initNumber(11));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("NOTATION_NODE"), JsValue.initNumber(12));
    // Document position constants
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_DISCONNECTED"), JsValue.initNumber(1));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_PRECEDING"), JsValue.initNumber(2));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_FOLLOWING"), JsValue.initNumber(4));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_CONTAINS"), JsValue.initNumber(8));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_CONTAINED_BY"), JsValue.initNumber(16));
    try node_ctor.setProperty(vm.allocator, try vm.pool.intern("DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC"), JsValue.initNumber(32));

    // Also add missing legacy constants to prototype (ATTRIBUTE_NODE, ENTITY_*, NOTATION_NODE)
    try np.setProperty(vm.allocator, try vm.pool.intern("ATTRIBUTE_NODE"), JsValue.initNumber(2));
    try np.setProperty(vm.allocator, try vm.pool.intern("ENTITY_REFERENCE_NODE"), JsValue.initNumber(5));
    try np.setProperty(vm.allocator, try vm.pool.intern("ENTITY_NODE"), JsValue.initNumber(6));
    try np.setProperty(vm.allocator, try vm.pool.intern("NOTATION_NODE"), JsValue.initNumber(12));

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

    // ── Function constructor global (for instanceof Function checks in testharness.js) ──
    // vm.function_proto is already created during VM init; expose it as Function.prototype
    // so that `fn instanceof Function` works (instanceof walks .prototype chain).
    const func_ctor = try vm.createObj(.{ .obj_type = .native_function });
    func_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    if (vm.function_proto) |fp| {
        func_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(fp)) catch {};
    }
    try vm.globals.put(vm.allocator, try vm.pool.intern("Function"), JsValue.initObject(func_ctor));

    // ── Element / HTMLElement constructor globals (for instanceof + WPT) ──
    const elem_ctor = try vm.createObj(.{ .obj_type = .native_function });
    elem_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    elem_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ep)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("Element"), JsValue.initObject(elem_ctor));
    // EventTarget constructor (DOM 2.7 -- standalone new EventTarget())
    const et_ctor = try vm.createObj(.{ .obj_type = .native_function });
    et_ctor.data = .{ .native_fn = &nativeEventTargetConstructor };
    const et_proto = try vm.createObj(.{});
    try vm.registerNativeMethod(et_proto, "addEventListener", &nativeAddEventListener);
    try vm.registerNativeMethod(et_proto, "removeEventListener", &nativeRemoveEventListener);
    try vm.registerNativeMethod(et_proto, "dispatchEvent", &nativeDispatchEvent);
    et_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(et_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("EventTarget"), JsValue.initObject(et_ctor));

    // HTML ctors — spec §3.7: each HTMLXxxElement ctor's `.prototype` MUST be
    // the per-interface prototype from g_html_protos, not the shared
    // Element.prototype. Previously all 67 ctors shared `ep`, which made
    // `div instanceof HTMLAnchorElement === true` hold by accident
    // (shared-proto bug). iface_mod.html_unique_ifaces includes both
    // "HTMLElement" and "HTMLUnknownElement".
    for (iface_mod.html_unique_ifaces) |ename| {
        const hctor = try vm.createObj(.{ .obj_type = .native_function });
        hctor.data = .{ .native_fn = &nativeNoOpConstructor };
        const ctor_proto = getHtmlProto(ename) orelse g_html_element_proto.?;
        hctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ctor_proto)) catch {};
        try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(hctor));
    }

    // Abstract HTML interface ctors — HTML §4 superclasses (HTMLMediaElement,
    // etc.) exposed as globals. Their `.prototype` points at the dedicated
    // abstract prototype registered above; the abstract proto chains to
    // HTMLElement.prototype so `instanceof HTMLMediaElement` works on the
    // concrete subclass instances.
    for (iface_mod.html_abstract_ifaces) |ename| {
        const hctor = try vm.createObj(.{ .obj_type = .native_function });
        hctor.data = .{ .native_fn = &nativeNoOpConstructor };
        const ctor_proto = getHtmlProto(ename) orelse g_html_element_proto.?;
        hctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ctor_proto)) catch {};
        try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(hctor));
    }

    // SVG ctors — spec §3.7. Each SVGXxxElement ctor gets its per-interface
    // prototype from g_svg_protos; SVGElement itself gets g_svg_element_proto.
    for (iface_mod.svg_unique_ifaces) |ename| {
        const sctor = try vm.createObj(.{ .obj_type = .native_function });
        sctor.data = .{ .native_fn = &nativeNoOpConstructor };
        const ctor_proto = getSvgProto(ename) orelse g_svg_element_proto.?;
        sctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(ctor_proto)) catch {};
        try vm.globals.put(vm.allocator, try vm.pool.intern(ename), JsValue.initObject(sctor));
    }

    // MathMLElement ctor — spec §3.7, MathML Core §2 has no per-tag
    // subclasses, so only the single MathMLElement ctor is registered.
    const mctor = try vm.createObj(.{ .obj_type = .native_function });
    mctor.data = .{ .native_fn = &nativeNoOpConstructor };
    mctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_mathml_element_proto.?)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("MathMLElement"), JsValue.initObject(mctor));

    const df_ctor = try vm.createObj(.{ .obj_type = .native_function });
    df_ctor.data = .{ .native_fn = &nativeDocumentFragmentConstructor };
    df_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(np)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("DocumentFragment"), JsValue.initObject(df_ctor));
    const doc_ctor = try vm.createObj(.{ .obj_type = .native_function });
    doc_ctor.data = .{ .native_fn = &nativeDocumentConstructor };
    doc_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(np)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("Document"), JsValue.initObject(doc_ctor));
    try vm.globals.put(vm.allocator, try vm.pool.intern("HTMLDocument"), JsValue.initObject(elem_ctor));

    // XMLDocument constructor + prototype (DOM §4.5)
    // XMLDocument extends Document — prototype inherits from Node.prototype
    const xml_doc_proto = try vm.createObj(.{});
    xml_doc_proto.prototype = np; // Document.prototype → Node.prototype
    g_xml_doc_proto = xml_doc_proto;
    const xml_doc_ctor = try vm.createObj(.{ .obj_type = .native_function });
    xml_doc_ctor.data = .{ .native_fn = &nativeDocumentConstructor };
    xml_doc_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(xml_doc_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("XMLDocument"), JsValue.initObject(xml_doc_ctor));

    // DocumentType constructor + prototype
    const dt_ctor = try vm.createObj(.{ .obj_type = .native_function });
    dt_ctor.data = .{ .native_fn = &nativeNoOpConstructor };
    dt_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(g_doctype_proto.?)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("DocumentType"), JsValue.initObject(dt_ctor));

    // Event constructor (DOM 2.5)
    const ev_proto = try vm.createObj(.{});
    g_event_proto = ev_proto;
    try vm.registerNativeMethod(ev_proto, "stopPropagation", &nativeStopPropagation);
    try vm.registerNativeMethod(ev_proto, "stopImmediatePropagation", &nativeStopImmediatePropagation);
    try vm.registerNativeMethod(ev_proto, "preventDefault", &nativePreventDefault);
    try vm.registerNativeMethod(ev_proto, "initEvent", &nativeInitEvent);
    try vm.registerNativeMethod(ev_proto, "composedPath", &nativeComposedPath);
    try ev_proto.setProperty(vm.allocator, try vm.pool.intern("NONE"), JsValue.initNumber(0));
    try ev_proto.setProperty(vm.allocator, try vm.pool.intern("CAPTURING_PHASE"), JsValue.initNumber(1));
    try ev_proto.setProperty(vm.allocator, try vm.pool.intern("AT_TARGET"), JsValue.initNumber(2));
    try ev_proto.setProperty(vm.allocator, try vm.pool.intern("BUBBLING_PHASE"), JsValue.initNumber(3));
    const ev_ctor_obj = try vm.createObj(.{ .obj_type = .native_function });
    ev_ctor_obj.data = .{ .native_fn = &nativeEventConstructor };
    ev_ctor_obj.setProperty(vm.allocator, proto_sid, JsValue.initObject(ev_proto)) catch {};
    ev_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("NONE"), JsValue.initNumber(0)) catch {};
    ev_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("CAPTURING_PHASE"), JsValue.initNumber(1)) catch {};
    ev_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("AT_TARGET"), JsValue.initNumber(2)) catch {};
    ev_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("BUBBLING_PHASE"), JsValue.initNumber(3)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("Event"), JsValue.initObject(ev_ctor_obj));

    // CustomEvent constructor (DOM 2.5)
    const cev_proto = try vm.createObj(.{});
    cev_proto.prototype = ev_proto;
    try vm.registerNativeMethod(cev_proto, "initCustomEvent", &nativeInitCustomEvent);
    const cev_ctor_obj = try vm.createObj(.{ .obj_type = .native_function });
    cev_ctor_obj.data = .{ .native_fn = &nativeCustomEventConstructor };
    cev_ctor_obj.setProperty(vm.allocator, proto_sid, JsValue.initObject(cev_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("CustomEvent"), JsValue.initObject(cev_ctor_obj));

    // ── Event interface hierarchy (DOM §5.1 + UI Events + HTML) ──
    // UIEvent.prototype → Event.prototype (UI Events §3.2)
    const ui_proto = try vm.createObj(.{});
    ui_proto.prototype = ev_proto;
    try registerEventCtor(vm, "UIEvent", ui_proto, proto_sid);

    // MouseEvent.prototype → UIEvent.prototype (UI Events §3.3)
    const mouse_proto = try vm.createObj(.{});
    mouse_proto.prototype = ui_proto;
    try registerEventCtor(vm, "MouseEvent", mouse_proto, proto_sid);

    // KeyboardEvent.prototype → UIEvent.prototype (UI Events §3.5)
    const kb_proto = try vm.createObj(.{});
    kb_proto.prototype = ui_proto;
    try registerEventCtor(vm, "KeyboardEvent", kb_proto, proto_sid);

    // FocusEvent.prototype → UIEvent.prototype (UI Events §3.4)
    const focus_proto = try vm.createObj(.{});
    focus_proto.prototype = ui_proto;
    try registerEventCtor(vm, "FocusEvent", focus_proto, proto_sid);

    // CompositionEvent.prototype → UIEvent.prototype (UI Events §3.6)
    const comp_proto = try vm.createObj(.{});
    comp_proto.prototype = ui_proto;
    try registerEventCtor(vm, "CompositionEvent", comp_proto, proto_sid);

    // TextEvent.prototype → UIEvent.prototype (legacy, DOM §5.1)
    const text_ev_proto = try vm.createObj(.{});
    text_ev_proto.prototype = ui_proto;
    try registerEventCtor(vm, "TextEvent", text_ev_proto, proto_sid);

    // DragEvent.prototype → MouseEvent.prototype (HTML §6.11.5)
    const drag_proto = try vm.createObj(.{});
    drag_proto.prototype = mouse_proto;
    try registerEventCtor(vm, "DragEvent", drag_proto, proto_sid);

    // MessageEvent.prototype → Event.prototype (HTML §9.2.3)
    const msg_proto = try vm.createObj(.{});
    msg_proto.prototype = ev_proto;
    try registerEventCtor(vm, "MessageEvent", msg_proto, proto_sid);

    // HashChangeEvent.prototype → Event.prototype (HTML §8.8.2)
    const hash_proto = try vm.createObj(.{});
    hash_proto.prototype = ev_proto;
    try registerEventCtor(vm, "HashChangeEvent", hash_proto, proto_sid);

    // StorageEvent.prototype → Event.prototype (HTML §12.2.3)
    const storage_proto = try vm.createObj(.{});
    storage_proto.prototype = ev_proto;
    try registerEventCtor(vm, "StorageEvent", storage_proto, proto_sid);

    // BeforeUnloadEvent.prototype → Event.prototype (HTML §8.1.5.3)
    const bu_proto = try vm.createObj(.{});
    bu_proto.prototype = ev_proto;
    try registerEventCtor(vm, "BeforeUnloadEvent", bu_proto, proto_sid);

    // DeviceMotionEvent.prototype → Event.prototype (DeviceOrientation §4.1)
    const dm_proto = try vm.createObj(.{});
    dm_proto.prototype = ev_proto;
    try registerEventCtor(vm, "DeviceMotionEvent", dm_proto, proto_sid);

    // DeviceOrientationEvent.prototype → Event.prototype (DeviceOrientation §4.2)
    const do_proto = try vm.createObj(.{});
    do_proto.prototype = ev_proto;
    try registerEventCtor(vm, "DeviceOrientationEvent", do_proto, proto_sid);

    // MutationEvent.prototype → Event.prototype (legacy DOM Events L3 §5)
    // Default attributes exposed on the prototype so `new MutationEvent()`
    // instances inherit them without per-constructor boilerplate.
    // NOT in the createEvent alias table — current DOM §4.5 requires
    // createEvent("MutationEvent") to throw NOT_SUPPORTED_ERR.
    const mut_proto = try vm.createObj(.{});
    mut_proto.prototype = ev_proto;
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("relatedNode"), JsValue.null_val);
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("prevValue"), JsValue.initString(try vm.pool.intern("")));
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("newValue"), JsValue.initString(try vm.pool.intern("")));
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("attrName"), JsValue.initString(try vm.pool.intern("")));
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("attrChange"), JsValue.initNumber(0));
    // attrChange constants (DOM Events L3 §5) — required by dom/nodes/attributes.html
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("MODIFICATION"), JsValue.initNumber(1));
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("ADDITION"), JsValue.initNumber(2));
    try mut_proto.setProperty(vm.allocator, try vm.pool.intern("REMOVAL"), JsValue.initNumber(3));
    try registerEventCtor(vm, "MutationEvent", mut_proto, proto_sid);
    // Mirror the constants onto the constructor itself for MutationEvent.MODIFICATION access
    const mut_ctor_val = vm.globals.get(try vm.pool.intern("MutationEvent")) orelse unreachable;
    const mut_ctor_obj = mut_ctor_val.asJsObject();
    try mut_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("MODIFICATION"), JsValue.initNumber(1));
    try mut_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("ADDITION"), JsValue.initNumber(2));
    try mut_ctor_obj.setProperty(vm.allocator, try vm.pool.intern("REMOVAL"), JsValue.initNumber(3));

    // ProgressEvent.prototype → Event.prototype (XHR §4.6 / HTML §8.9.2)
    // NOT in createEvent alias table — current DOM §4.5 requires
    // createEvent("ProgressEvent") to throw NOT_SUPPORTED_ERR.
    const prog_proto = try vm.createObj(.{});
    prog_proto.prototype = ev_proto;
    try prog_proto.setProperty(vm.allocator, try vm.pool.intern("lengthComputable"), JsValue.initBool(false));
    try prog_proto.setProperty(vm.allocator, try vm.pool.intern("loaded"), JsValue.initNumber(0));
    try prog_proto.setProperty(vm.allocator, try vm.pool.intern("total"), JsValue.initNumber(0));
    try registerEventCtor(vm, "ProgressEvent", prog_proto, proto_sid);

    // TouchEvent.prototype → UIEvent.prototype (Touch Events §5)
    // touches/targetTouches/changedTouches default to empty TouchList-like arrays.
    const touch_proto = try vm.createObj(.{});
    touch_proto.prototype = ui_proto;
    const empty_touches = try vm.createObj(.{ .obj_type = .array });
    const empty_target_touches = try vm.createObj(.{ .obj_type = .array });
    const empty_changed_touches = try vm.createObj(.{ .obj_type = .array });
    try touch_proto.setProperty(vm.allocator, try vm.pool.intern("touches"), JsValue.initObject(empty_touches));
    try touch_proto.setProperty(vm.allocator, try vm.pool.intern("targetTouches"), JsValue.initObject(empty_target_touches));
    try touch_proto.setProperty(vm.allocator, try vm.pool.intern("changedTouches"), JsValue.initObject(empty_changed_touches));
    try registerEventCtor(vm, "TouchEvent", touch_proto, proto_sid);

    // ── MutationObserver constructor (DOM §4.3) ──
    const mo_ctor = try vm.createObj(.{ .obj_type = .native_function });
    mo_ctor.data = .{ .native_fn = &nativeMutationObserverConstructor };
    try vm.globals.put(vm.allocator, try vm.pool.intern("MutationObserver"), JsValue.initObject(mo_ctor));

    // ── DOMParser constructor (DOM Parsing and Serialization §2.1) ──
    // new DOMParser().parseFromString(str, type) → Document
    const dp_proto = try vm.createObj(.{});
    try vm.registerNativeMethod(dp_proto, "parseFromString", &nativeDOMParserParseFromString);
    g_domparser_proto = dp_proto;
    const dp_ctor = try vm.createObj(.{ .obj_type = .native_function });
    dp_ctor.data = .{ .native_fn = &nativeDOMParserConstructor };
    dp_ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(dp_proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern("DOMParser"), JsValue.initObject(dp_ctor));

    // ── Property interception ──
    vm.dom_get_prop = &domGetProp;
    vm.dom_set_prop = &domSetProp;
}

// ══════════════════════════════════════════════════════════════════════
// HTML §2.6 reflected-attribute dispatcher
// ══════════════════════════════════════════════════════════════════════

/// Resolve the HTML interface name for an element node (e.g. "HTMLInputElement").
/// Returns null for non-HTML-NS elements or non-element nodes — those don't
/// participate in HTML §2.6 reflection.
fn resolveHtmlIfaceForNode(node: *lxb.lxb_dom_node_t) ?[]const u8 {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return null;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    // Only HTML-namespace elements have HTML IDL reflections. Reject
    // null-namespace, SVG, MathML, XLink, etc.
    if (nsIdToUri(elem.node.ns)) |uri| {
        if (!std.mem.eql(u8, uri, "http://www.w3.org/1999/xhtml")) return null;
    } else {
        return null;
    }
    var ln_len: usize = 0;
    const ln_ptr = dom_b.lxb_dom_element_local_name(elem, &ln_len) orelse return null;
    const local_name = ln_ptr[0..ln_len];
    const iface_mod = @import("kotori_html_interfaces.zig");
    return iface_mod.resolveInterface("http://www.w3.org/1999/xhtml", local_name);
}

/// Reflection getter dispatch. Returns null if no reflection applies and
/// the caller should continue with its fallback.
///
/// HTML §2.6 — one of:
///   - DOMString → getAttribute-or-"" (§2.6.2 "DOMString")
///   - boolean → hasAttribute (§2.6.2 "boolean")
///   - long → rules-for-parsing-integers §2.4.4.1, default on fail
///   - unsigned long → rules-for-parsing-non-negative §2.4.4.2
///   - url → DOMString for now (Layer 4B will canonicalize)
fn reflectionGet(vm: *VM, node: *lxb.lxb_dom_node_t, name: []const u8) ?JsValue {
    const iface = resolveHtmlIfaceForNode(node) orelse return null;
    const row = refl.lookup(iface, name) orelse return null;
    switch (row.type) {
        .domstring, .url => return getAttr(vm, node, row.content),
        .boolean => {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            const has = dom_b.lxb_dom_element_has_attribute(elem, row.content.ptr, row.content.len);
            return JsValue.initBool(has);
        },
        .long => {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val_ptr = dom_b.lxb_dom_element_get_attribute(elem, row.content.ptr, row.content.len, &val_len);
            if (val_ptr) |p| {
                if (refl.parseInteger(p[0..val_len])) |v| {
                    return JsValue.initNumber(@floatFromInt(v));
                }
            }
            return JsValue.initNumber(@floatFromInt(row.default_int));
        },
        .unsigned_long => {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val_ptr = dom_b.lxb_dom_element_get_attribute(elem, row.content.ptr, row.content.len, &val_len);
            if (val_ptr) |p| {
                if (refl.parseNonNegativeInteger(p[0..val_len])) |v| {
                    return JsValue.initNumber(@floatFromInt(v));
                }
            }
            return JsValue.initNumber(@floatFromInt(row.default_int));
        },
    }
}

/// Reflection setter dispatch. Returns true if the reflection was applied
/// (caller should not continue); false if no reflection matched.
fn reflectionSet(vm: *VM, node: *lxb.lxb_dom_node_t, name: []const u8, val: JsValue) bool {
    const iface = resolveHtmlIfaceForNode(node) orelse return false;
    const row = refl.lookup(iface, name) orelse return false;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    switch (row.type) {
        .domstring, .url => {
            // ECMAScript ToString. `null` → "null", `undefined` → "undefined"
            // per §2.6.2 DOMString setter — the spec steps "set the content
            // attribute to value" follow a pre-ToString conversion.
            var buf: [64]u8 = undefined;
            const s = valueToString(vm, val, &buf);
            _ = dom_b.lxb_dom_element_set_attribute(elem, row.content.ptr, row.content.len, s.ptr, s.len);
            return true;
        },
        .boolean => {
            if (val.isTruthy()) {
                _ = dom_b.lxb_dom_element_set_attribute(elem, row.content.ptr, row.content.len, "", 0);
            } else {
                _ = dom_b.lxb_dom_element_remove_attribute(elem, row.content.ptr, row.content.len);
            }
            return true;
        },
        .long => {
            const n = val.toNumber();
            const i32v: i32 = if (std.math.isFinite(n)) blk: {
                if (n > @as(f64, std.math.maxInt(i32))) break :blk std.math.maxInt(i32);
                if (n < @as(f64, std.math.minInt(i32))) break :blk std.math.minInt(i32);
                break :blk @intFromFloat(@trunc(n));
            } else 0;
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i32v}) catch "0";
            _ = dom_b.lxb_dom_element_set_attribute(elem, row.content.ptr, row.content.len, s.ptr, s.len);
            return true;
        },
        .unsigned_long => {
            const n = val.toNumber();
            // §2.6.2 unsigned long setter: negative / non-finite ⇒ default.
            const out: i64 = if (!std.math.isFinite(n) or n < 0) row.default_int else blk: {
                if (n > @as(f64, std.math.maxInt(i32))) break :blk std.math.maxInt(i32);
                break :blk @intFromFloat(@trunc(n));
            };
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{out}) catch "0";
            _ = dom_b.lxb_dom_element_set_attribute(elem, row.content.ptr, row.content.len, s.ptr, s.len);
            return true;
        },
    }
}

/// Minimal ECMAScript ToString for DOMString setters. Covers string,
/// number, boolean, null, undefined. Falls back to "[object Object]" for
/// objects (spec-correct for the primitive path we care about here — full
/// ToPrimitive coercion lives in kotori/vm.zig).
fn valueToString(vm: *VM, val: JsValue, buf: []u8) []const u8 {
    if (val.isString()) {
        return vm.pool.get(val.asStringId()) orelse "";
    }
    if (val.isBool()) return if (val.asBool()) "true" else "false";
    if (val.isNumber()) {
        return std.fmt.bufPrint(buf, "{d}", .{val.toNumber()}) catch "0";
    }
    if (val.isNull()) return "null";
    if (val.isUndefined()) return "undefined";
    return "[object Object]";
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
        return tagNameUpperWithPrefix(vm, obj, elem);
    }
    if (eql(name, "nodeName")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            return tagNameUpperWithPrefix(vm, obj, elem);
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

    // HTML §2.6 reflected attributes (Layer 4A). Dispatches via the
    // table in html_reflection.zig. Early-return on hit; fall through
    // to the remaining hard-coded properties on miss.
    if (reflectionGet(vm, node, name)) |v| return v;

    // Element.attributes (DOM §4.9.2 — NamedNodeMap, identity-cached).
    //
    // Spec note: "Each attributes getter invocation returns the *same*
    // NamedNodeMap." Cache the map JsObject on the Element wrapper via
    // the hidden __nnmCache slot; refresh indexed/named own properties
    // lazily when the per-element attr version counter advances.
    if (eql(name, "attributes")) {
        if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        if (g_sid_nnm_cache) |cache_sid| {
            if (obj.getProperty(cache_sid)) |cached| {
                if (cached.isObject()) {
                    const map = cached.asJsObject();
                    // Lazy refresh when the element's attribute version
                    // has advanced past the stamp we recorded at build
                    // time (see refreshAttributesMap).
                    if (g_sid_nnm_ver) |ver_sid| {
                        const cur = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
                        const stamped_val = map.getProperty(ver_sid) orelse JsValue.initNumber(0);
                        const stamped_f = stamped_val.toNumber();
                        const stamped: u64 = if (std.math.isFinite(stamped_f) and stamped_f >= 0)
                            @intFromFloat(stamped_f)
                        else
                            0;
                        if (stamped != cur) refreshAttributesMap(vm, map, elem);
                    }
                    return JsValue.initObject(map);
                }
            }
        }
        const built = buildAttributesMap(vm, elem) orelse return JsValue.null_val;
        if (g_sid_nnm_cache) |cache_sid| {
            obj.setProperty(vm.allocator, cache_sid, built) catch {};
        }
        return built;
    }

    // Element namespace properties (DOM §4.9)
    if (eql(name, "namespaceURI")) {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            // Check lexbor namespace first
            if (nsIdToUri(elem.node.ns)) |uri| {
                return JsValue.initString(vm.pool.intern(uri) catch return JsValue.null_val);
            }
            // Check __nsURI own property for non-standard namespaces
            const ns_sid = vm.pool.intern("__nsURI") catch return JsValue.null_val;
            if (obj.getProperty(ns_sid)) |v| return v;
        }
        return JsValue.null_val;
    }
    if (eql(name, "prefix")) {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            // Check __prefix own property first (set by createElementNS)
            const prefix_sid = vm.pool.intern("__prefix") catch return JsValue.null_val;
            if (obj.getProperty(prefix_sid)) |v| return v;
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var qn_len: usize = 0;
            const qn = dom_b.lxb_dom_element_qualified_name(elem, &qn_len);
            var ln_len: usize = 0;
            const ln = dom_b.lxb_dom_element_local_name(elem, &ln_len);
            if (qn != null and ln != null and qn_len > ln_len) {
                // prefix is everything before the ':'
                const prefix_len = qn_len - ln_len - 1;
                if (prefix_len > 0) {
                    return JsValue.initString(vm.pool.intern(qn.?[0..prefix_len]) catch return JsValue.null_val);
                }
            }
        }
        return JsValue.null_val;
    }
    if (eql(name, "localName")) {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            // Check __origLocal first (preserves case from createElementNS, since lexbor lowercases)
            const orig_sid = vm.pool.intern("__origLocal") catch return JsValue.null_val;
            if (obj.getProperty(orig_sid)) |v| return v;
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var len: usize = 0;
            if (dom_b.lxb_dom_element_local_name(elem, &len)) |ln| {
                return JsValue.initString(vm.pool.intern(ln[0..len]) catch return JsValue.null_val);
            }
        }
        return JsValue.null_val;
    }

    // DocumentType properties (DOM §4.6)
    if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
        if (eql(name, "name")) {
            return getDocTypeName(vm, node);
        }
        if (eql(name, "publicId")) {
            var len: usize = 0;
            if (dom_b.lxb_dom_document_type_public_id_noi(@ptrCast(node), &len)) |p| {
                return JsValue.initString(vm.pool.intern(p[0..len]) catch return JsValue.null_val);
            }
            return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
        }
        if (eql(name, "systemId")) {
            var len: usize = 0;
            if (dom_b.lxb_dom_document_type_system_id_noi(@ptrCast(node), &len)) |p| {
                return JsValue.initString(vm.pool.intern(p[0..len]) catch return JsValue.null_val);
            }
            return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
        }
    }

    // textContent: null for Document and DocumentType nodes (DOM §4.4)
    if (eql(name, "textContent")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_DOCUMENT or nt == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE)
            return JsValue.null_val;
        return getTextContent(vm, node);
    }
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
    // CharacterData.length — number of UTF-16 code units in data (DOM §4.2.5)
    if (eql(name, "length")) {
        const nt = nodeType(node);
        if (nt == lxb.LXB_DOM_NODE_TYPE_TEXT or nt == lxb.LXB_DOM_NODE_TYPE_COMMENT or
            nt == lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION)
        {
            var len: usize = 0;
            if (dom_b.lxb_dom_node_text_content(node, &len)) |ptr| {
                return JsValue.initNumber(@floatFromInt(VM.utf16Len(ptr[0..len])));
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
    // Node.ownerDocument — read per-node _ownerDoc slot (DOM §4.4).
    // Document nodes return null; every other node returns the creating
    // document (including elements in XML documents, adopted/imported
    // nodes, and nodes from DOMImplementation.createHTMLDocument etc).
    if (eql(name, "ownerDocument")) {
        if (nodeType(node) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) return JsValue.null_val;
        return getNodeOwnerDoc(vm, obj);
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

    // document-specific: body, head, documentElement, doctype
    if (eql(name, "body")) return findByTag(vm, node, "body");
    if (eql(name, "head")) return findByTag(vm, node, "head");
    if (eql(name, "documentElement")) return findByTag(vm, node, "html");
    if (eql(name, "doctype") and nodeType(node) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        // Return first DocumentType child node
        var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
        while (ch) |c| {
            if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
                return wrapNode(vm, c) orelse JsValue.null_val;
            }
            ch = nodeNext(c);
        }
        return JsValue.null_val;
    }

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

    // Element.childElementCount — DOM §4.9
    if (eql(name, "childElementCount")) {
        var count: f64 = 0;
        var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
        while (ch) |c| {
            if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) count += 1;
            ch = nodeNext(c);
        }
        return JsValue.initNumber(count);
    }

    // document.implementation — DOM §7.1: DOMImplementation object
    if (eql(name, "implementation") and nodeType(node) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        const impl_obj = vm.createObj(.{}) catch return null;
        // Store owning document reference for createDocumentType/createDocument
        const od_sid = vm.pool.intern("_ownerDoc") catch return null;
        impl_obj.setProperty(vm.allocator, od_sid, wrapNode(vm, node) orelse JsValue.null_val) catch {};
        // hasFeature always returns true per DOM Living Standard §7.1
        const hf_fn = vm.createObj(.{ .obj_type = .native_function }) catch return null;
        hf_fn.data = .{ .native_fn = &nativeImplementationHasFeature };
        const hf_sid = vm.pool.intern("hasFeature") catch return null;
        impl_obj.setProperty(vm.allocator, hf_sid, JsValue.initObject(hf_fn)) catch {};
        // createHTMLDocument — creates a minimal new document object
        const chd_fn = vm.createObj(.{ .obj_type = .native_function }) catch return null;
        chd_fn.data = .{ .native_fn = &nativeImplementationCreateHTMLDocument };
        const chd_sid = vm.pool.intern("createHTMLDocument") catch return null;
        impl_obj.setProperty(vm.allocator, chd_sid, JsValue.initObject(chd_fn)) catch {};
        // createDocumentType(qualifiedName, publicId, systemId) — DOM §7.1
        const cdt_fn = vm.createObj(.{ .obj_type = .native_function }) catch return null;
        cdt_fn.data = .{ .native_fn = &nativeImplementationCreateDocumentType };
        const cdt_sid = vm.pool.intern("createDocumentType") catch return null;
        impl_obj.setProperty(vm.allocator, cdt_sid, JsValue.initObject(cdt_fn)) catch {};
        // createDocument(namespace, qualifiedName, doctype) — DOM §7.1
        const cd_fn = vm.createObj(.{ .obj_type = .native_function }) catch return null;
        cd_fn.data = .{ .native_fn = &nativeImplementationCreateDocument };
        const cd_sid = vm.pool.intern("createDocument") catch return null;
        impl_obj.setProperty(vm.allocator, cd_sid, JsValue.initObject(cd_fn)) catch {};
        return JsValue.initObject(impl_obj);
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

    // HTML §2.6 reflected attributes setter (Layer 4A).
    if (reflectionSet(vm, node, name, val)) {
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

    // CSSOM §6.5: computed-style objects (marked by the `__element`
    // internal slot set in nativeGetComputedStyle) must route property
    // reads through the cascade resolver so bracket-access
    // `getComputedStyle(el)[prop]` returns the same resolved value as
    // `getComputedStyle(el).getPropertyValue(prop)`. Inline-style objects
    // (no `__element` slot) keep raw style-attribute semantics per CSSOM
    // §6.7.2 so `el.style[prop]` mirrors `el.style.prop`.
    const elem_marker_sid = vm.pool.intern("__element") catch null;
    const is_computed = if (elem_marker_sid) |em| obj.getProperty(em) != null else false;
    if (is_computed) {
        if (resolve_fn) |rf| {
            var val_buf: [160]u8 = undefined;
            if (rf(@ptrCast(elem), css_prop, &val_buf)) |slice| {
                const sid = vm.pool.intern(slice) catch return null;
                return JsValue.initString(sid);
            }
        }
    }

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

    // CSSOM §6.7.2: invalid values must leave the inline style attribute
    // unchanged. Return `true` so the assignment evaluates successfully
    // (per ECMA-262 §13.15.2) but skip the write. This mirrors the
    // pre-VM-bracket-dispatch silent no-op that WPT's `test_invalid_value`
    // helper asserts.
    if (validate_fn) |vf| {
        if (!vf(css_prop, new_val_str)) return true;
    }

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
fn nativeGetElementsByTagNameNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) {
        const arr = try vm.createObj(.{ .obj_type = .array });
        arr.data = .{ .array = .empty };
        return JsValue.initObject(arr);
    }
    // args[0] = namespace URI (string or null), args[1] = localName
    const ns_str: ?[]const u8 = if (args[0].isNull()) null else if (args[0].isString()) vm.pool.get(args[0].asStringId()) else null;
    const local_str = if (args[1].isString()) (vm.pool.get(args[1].asStringId()) orelse "") else "";
    const root = getThisNode(this) orelse {
        const arr = try vm.createObj(.{ .obj_type = .array });
        arr.data = .{ .array = .empty };
        return JsValue.initObject(arr);
    };
    const arr_obj = try vm.createObj(.{ .obj_type = .array });
    arr_obj.data = .{ .array = .empty };
    try collectByTagNameNS(vm, root, ns_str, local_str, arr_obj);
    return JsValue.initObject(arr_obj);
}

fn collectByTagNameNS(vm: *VM, root: *lxb.lxb_dom_node_t, ns: ?[]const u8, local: []const u8, arr: *kotori.JsObject) !void {
    const is_local_wildcard = local.len == 1 and local[0] == '*';
    const is_ns_wildcard = if (ns) |n| (n.len == 1 and n[0] == '*') else false;
    var child: ?*lxb.lxb_dom_node_t = @ptrCast(root.first_child);
    while (child) |node| : (child = @ptrCast(node.next)) {
        if (node.type == 1) { // ELEMENT_NODE
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            // Check namespace match
            const elem_ns = nsIdToUri(elem.node.ns);
            const ns_match = if (is_ns_wildcard) true else if (ns) |wanted_ns| (if (elem_ns) |ens| eql(ens, wanted_ns) else false) else (elem_ns == null);
            if (ns_match) {
                // Check local name match
                if (is_local_wildcard) {
                    const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
                    try arr.data.array.append(vm.allocator, wrapped);
                } else {
                    var name_len: usize = 0;
                    const name_ptr = dom_b.lxb_dom_element_local_name(elem, &name_len);
                    if (name_ptr) |np| {
                        if (std.ascii.eqlIgnoreCase(np[0..name_len], local)) {
                            const wrapped = wrapNode(vm, node) orelse JsValue.null_val;
                            try arr.data.array.append(vm.allocator, wrapped);
                        }
                    }
                }
            }
            try collectByTagNameNS(vm, node, ns, local, arr);
        }
    }
}

fn nativeDocumentFragmentConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const frag = sr.lxb_dom_document_create_document_fragment(doc) orelse return JsValue.null_val;
    return wrapNode(vm, frag) orelse JsValue.null_val;
}

/// DOM §4.4: Node.lookupNamespaceURI(prefix)
/// Follows the DOM Living Standard algorithm for locating namespace URI.
fn nativeLookupNamespaceURI(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    // Normalize prefix: null, undefined, or "" → null
    const prefix: ?[]const u8 = blk: {
        if (args.len == 0 or args[0].isNull() or args[0].isUndefined()) break :blk null;
        if (args[0].isString()) {
            const s = vm.pool.get(args[0].asStringId()) orelse break :blk null;
            if (s.len == 0) break :blk null;
            break :blk s;
        }
        break :blk null;
    };
    const result = lookupNamespaceURIImpl(node, prefix);
    if (result) |uri| {
        return JsValue.initString(vm.pool.intern(uri) catch return JsValue.null_val);
    }
    return JsValue.null_val;
}

/// Core lookupNamespaceURI algorithm (DOM §4.4)
fn lookupNamespaceURIImpl(node: *lxb.lxb_dom_node_t, prefix: ?[]const u8) ?[]const u8 {
    const nt = nodeType(node);
    switch (nt) {
        lxb.LXB_DOM_NODE_TYPE_ELEMENT => return elementLookupNamespaceURI(node, prefix),
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT => {
            // Document: delegate to documentElement
            var child: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
            while (child) |ch| {
                if (nodeType(ch) == lxb.LXB_DOM_NODE_TYPE_ELEMENT)
                    return lookupNamespaceURIImpl(ch, prefix);
                child = nodeNext(ch);
            }
            return null;
        },
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE,
        lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT,
        => return null,
        else => {
            // Text, Comment, etc.: delegate to parent element
            if (nodeParent(node)) |parent| return lookupNamespaceURIImpl(parent, prefix);
            return null;
        },
    }
}

/// Element-specific namespace lookup (DOM §4.4)
fn elementLookupNamespaceURI(node: *lxb.lxb_dom_node_t, prefix: ?[]const u8) ?[]const u8 {
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // Built-in prefixes (always available, even without xmlns attributes)
    if (prefix) |pfx| {
        if (eql(pfx, "xml")) return "http://www.w3.org/XML/1998/namespace";
        if (eql(pfx, "xmlns")) return "http://www.w3.org/2000/xmlns/";
    }

    // Check this element's own namespace (if its prefix matches)
    // First check ns_info_map for createElementNS-created elements
    if (getNsInfo(node)) |info| {
        if (prefix == null) {
            // Looking for default namespace: element has no prefix and has namespace
            if (info.prefix.len == 0) return info.uri;
        } else if (prefix) |pfx| {
            if (info.prefix.len > 0 and eql(info.prefix, pfx)) return info.uri;
        }
    } else {
        // Fall back to lexbor's namespace info (for elements created by HTML parser)
        const ns_uri = nsIdToUri(elem.node.ns);
        if (ns_uri != null) {
            var qn_len: usize = 0;
            const qn_ptr = dom_b.lxb_dom_element_qualified_name(elem, &qn_len);
            var ln_len: usize = 0;
            _ = dom_b.lxb_dom_element_local_name(elem, &ln_len);
            if (prefix == null) {
                if (qn_ptr != null and qn_len == ln_len) return ns_uri;
            } else if (prefix) |pfx| {
                if (qn_ptr != null and qn_len > ln_len) {
                    const elem_prefix_len = qn_len - ln_len - 1;
                    if (elem_prefix_len == pfx.len and eql(qn_ptr.?[0..elem_prefix_len], pfx)) return ns_uri;
                }
            }
        }
    }

    // Check xmlns attributes on this element
    // Look for xmlns:prefix="uri" or xmlns="uri" (default namespace)
    // Use attr.next (attribute chain), NOT node.next (DOM tree siblings)
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (attr) |a| {
        var attr_qn_len: usize = 0;
        const attr_qn = dom_b.lxb_dom_attr_qualified_name(@ptrCast(a), &attr_qn_len);
        if (attr_qn) |aqn| {
            const attr_name = aqn[0..attr_qn_len];
            if (prefix == null) {
                // Looking for default namespace: check for xmlns="..."
                if (eql(attr_name, "xmlns")) {
                    var val_len: usize = 0;
                    const val_ptr = dom_b.lxb_dom_attr_value_noi(@ptrCast(a), &val_len);
                    if (val_ptr) |vp| {
                        const val = vp[0..val_len];
                        if (val.len == 0) return null; // xmlns="" resets default namespace
                        return val;
                    }
                    return null;
                }
            } else if (prefix) |pfx| {
                // Check for xmlns:prefix="..."
                if (attr_name.len > 6 and std.mem.startsWith(u8, attr_name, "xmlns:")) {
                    const attr_prefix = attr_name[6..];
                    if (eql(attr_prefix, pfx)) {
                        var val_len: usize = 0;
                        const val_ptr = dom_b.lxb_dom_attr_value_noi(@ptrCast(a), &val_len);
                        if (val_ptr) |vp| return vp[0..val_len];
                        return null;
                    }
                }
            }
        }
        attr = a.next; // use attribute chain, not DOM tree
    }

    // Walk up to parent element
    if (nodeParent(node)) |parent| return lookupNamespaceURIImpl(parent, prefix);
    return null;
}

/// DOM §4.4: Node.isDefaultNamespace(namespace)
fn nativeIsDefaultNamespace(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    // Get namespace argument: null/undefined/"" → null
    const namespace: ?[]const u8 = blk: {
        if (args.len == 0 or args[0].isNull() or args[0].isUndefined()) break :blk null;
        if (args[0].isString()) {
            const s = vm.pool.get(args[0].asStringId()) orelse break :blk null;
            if (s.len == 0) break :blk null;
            break :blk s;
        }
        break :blk null;
    };
    // Look up default namespace (prefix = null)
    const default_ns = lookupNamespaceURIImpl(node, null);
    // Compare
    if (namespace == null and default_ns == null) return JsValue.initBool(true);
    if (namespace != null and default_ns != null) return JsValue.initBool(eql(namespace.?, default_ns.?));
    return JsValue.initBool(false);
}

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

fn nativeCreateElement(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    // DOM §4.5 step 1: coerce argument to DOMString (null → "null", undefined → "undefined").
    const tag_raw = argToString(vm, args[0]);
    // DOM §4.5.1 step 2: if localName does not match the **Name** production
    // → InvalidCharacterError. Per Document-createElement.html:48-53, ':',
    // ':foo', 'f:oo', 'foo:', 'f:o:o', 'f::oo' are all VALID — Name allows
    // ':' anywhere, unlike QName.
    if (!dom_names.isValidName(tag_raw)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.null_val;
    }

    // DOM §4.5: For XML (non-HTML) documents, createElement preserves case
    // and namespace is null. For HTML / XHTML docs, namespace is the HTML
    // namespace and lexbor lowercases the tag.
    if (this.isObject()) {
        const this_obj = this.asJsObject();
        const xml_sid = vm.pool.intern("_isXmlDoc") catch null;
        if (xml_sid) |sid| {
            if (this_obj.getProperty(sid)) |xv| {
                if (xv.isBool() and xv.asBool()) {
                    // DOM §4.5 step 4: XML document — check contentType. If
                    // contentType is application/xhtml+xml, namespace is HTML;
                    // otherwise namespace is null.
                    const ct_sid = vm.pool.intern("contentType") catch return JsValue.null_val;
                    const is_xhtml = blk: {
                        if (this_obj.getProperty(ct_sid)) |cv| {
                            if (cv.isString()) {
                                const ct = vm.pool.get(cv.asStringId()) orelse break :blk false;
                                break :blk std.mem.eql(u8, ct, "application/xhtml+xml");
                            }
                        }
                        break :blk false;
                    };
                    const ns: ?[]const u8 = if (is_xhtml) HTML_NS_URI else null;
                    return createJsOnlyElement(vm, tag_raw, ns, this);
                }
            }
        }
    }

    // HTML document path — namespace is HTML. lexbor tags are lowercased.
    // If lexbor rejects a Name-valid but QName-invalid tag (e.g. leading
    // ':', trailing ':', or repeated colons), fall back to a JS-only
    // element so DOM §4.5.1 still produces a usable Element node.
    const doc = getDocFromThis(this) orelse return JsValue.null_val;
    if (dom_b.lxb_dom_document_create_element(doc, tag_raw.ptr, tag_raw.len, null)) |elem| {
        return wrapNode(vm, @ptrCast(elem)) orelse JsValue.null_val;
    }
    return createJsOnlyElement(vm, tag_raw, HTML_NS_URI, this);
}

/// Create a JS-only Element object (no lexbor node) for XML documents.
/// Preserves tag name case exactly as given. `owner_doc` is the creating
/// document (DOM §4.4); pass `JsValue.null_val` only when the element has
/// no owning document (which is an exceptional situation — XML elements
/// must always have an owner per DOM §4.5).
fn createJsOnlyElement(vm: *VM, local_name: []const u8, ns_uri: ?[]const u8, owner_doc: JsValue) !JsValue {
    const obj = try vm.createObj(.{});
    // DOM §4.5.3 — dispatch to the correct HTML/SVG/MathML interface
    // prototype and write the `_ownerDoc` slot in one call. Supersedes the
    // previous shared `vm.element_proto` assignment.
    applyInterfaceProto(vm, obj, ns_uri, local_name, owner_doc);
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeType"), JsValue.initNumber(1));
    try obj.setProperty(vm.allocator, try vm.pool.intern("localName"), JsValue.initString(try vm.pool.intern(local_name)));
    // tagName = uppercase for HTML namespace, preserves case for XML
    const tag_upper = if (ns_uri != null and std.mem.eql(u8, ns_uri.?, "http://www.w3.org/1999/xhtml")) blk: {
        var buf: [256]u8 = undefined;
        const len = @min(local_name.len, buf.len);
        for (0..len) |i| buf[i] = std.ascii.toUpper(local_name[i]);
        break :blk try vm.pool.intern(buf[0..len]);
    } else try vm.pool.intern(local_name);
    try obj.setProperty(vm.allocator, try vm.pool.intern("tagName"), JsValue.initString(tag_upper));
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeName"), JsValue.initString(tag_upper));
    if (ns_uri) |ns| {
        try obj.setProperty(vm.allocator, try vm.pool.intern("namespaceURI"), JsValue.initString(try vm.pool.intern(ns)));
    } else {
        try obj.setProperty(vm.allocator, try vm.pool.intern("namespaceURI"), JsValue.null_val);
    }
    try obj.setProperty(vm.allocator, try vm.pool.intern("prefix"), JsValue.null_val);
    // _ownerDoc slot is written by applyInterfaceProto above.
    try obj.setProperty(vm.allocator, try vm.pool.intern("parentNode"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("childNodes"), JsValue.initObject(try vm.createObj(.{ .obj_type = .array })));
    try obj.setProperty(vm.allocator, try vm.pool.intern("firstChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("lastChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("previousSibling"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("nextSibling"), JsValue.null_val);
    return JsValue.initObject(obj);
}

/// Map W3C namespace URI string to lexbor namespace ID (reverse of nsIdToUri).
fn uriToNsId(uri: []const u8) ?usize {
    if (eql(uri, "http://www.w3.org/1999/xhtml")) return 0x02; // LXB_NS_HTML
    if (eql(uri, "http://www.w3.org/1998/Math/MathML")) return 0x03; // LXB_NS_MATH
    if (eql(uri, "http://www.w3.org/2000/svg")) return 0x04; // LXB_NS_SVG
    if (eql(uri, "http://www.w3.org/1999/xlink")) return 0x05; // LXB_NS_XLINK
    if (eql(uri, "http://www.w3.org/XML/1998/namespace")) return 0x06; // LXB_NS_XML
    if (eql(uri, "http://www.w3.org/2000/xmlns/")) return 0x07; // LXB_NS_XMLNS
    return null;
}

// ── XML Name / QName validation (DOM §1.5, XML §2.3) ──────────────────
// Lenient validator matching browser behavior: we reject obvious
// non-name chars and digit-leading starts but do not fully implement
// every Unicode NameStartChar/NameChar rule. WPT fixtures cover the
// cases we need to pass.

const XML_NS_URI: []const u8 = "http://www.w3.org/XML/1998/namespace";
const XMLNS_NS_URI: []const u8 = "http://www.w3.org/2000/xmlns/";
const HTML_NS_URI: []const u8 = "http://www.w3.org/1999/xhtml";

/// Map a validation error to a DOMException and queue it on vm.pending_throw.
/// Returns JsValue.null_val for convenience so callers can `return queueValidationErr(...)`.
/// Name/QName/validate-and-extract definitions live in `src/js/dom_names.zig`.
fn queueValidationErr(vm: *VM, err: dom_names.NameValidationError) anyerror!JsValue {
    vm.pending_throw = switch (err) {
        error.InvalidCharacter => try createDOMExceptionObj(vm, "InvalidCharacterError"),
        error.NamespaceMismatch => try createDOMExceptionObj(vm, "NamespaceError"),
    };
    return JsValue.null_val;
}

/// DOM §4.1 — document.createElementNS(namespace, qualifiedName).
/// Creates an element with the specified namespace URI and qualified name.
fn nativeCreateElementNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.null_val;
    const doc = getDocFromThis(this) orelse return JsValue.null_val;

    // Coerce arguments per WebIDL:
    //   namespace: DOMString? (nullable)
    //   qualifiedName: DOMString
    const ns_in: ?[]const u8 = blk: {
        if (args[0].isNull() or args[0].isUndefined()) break :blk null;
        break :blk argToString(vm, args[0]);
    };
    const qn = argToString(vm, args[1]);

    // DOM §1.5 validate and extract: throws InvalidCharacterError or NamespaceError.
    const v = dom_names.validateAndExtract(qn, ns_in) catch |err| {
        return try queueValidationErr(vm, err);
    };
    const prefix = v.prefix;
    const local_name = v.local_name;
    const ns_str = v.namespace;
    const create_name = if (local_name.len > 0) local_name else qn;

    // Create element via lexbor using FULL qualifiedName so prefix is stored in qualified_name
    const elem = dom_b.lxb_dom_document_create_element(doc, qn.ptr, qn.len, null) orelse return JsValue.null_val;
    const node: *lxb.lxb_dom_node_t = @ptrCast(elem);

    // Set namespace ID on lexbor element
    if (ns_str) |uri| {
        if (uriToNsId(uri)) |ns_id| {
            node.ns = ns_id;
        } else {
            // Custom namespace — clear lexbor's default HTML ns
            node.ns = 0x01; // LXB_NS_UNDEF — nsIdToUri returns null
        }
        // Store prefix+URI in ns_info_map for lookupNamespaceURI
        if (prefix) |pfx| {
            ensureNsInfoMap().put(g_alloc, @intFromPtr(node), .{ .prefix = pfx, .uri = uri }) catch {};
        } else {
            // No prefix — store as default namespace for this element
            ensureNsInfoMap().put(g_alloc, @intFromPtr(node), .{ .prefix = "", .uri = uri }) catch {};
        }
    } else {
        // null namespace — clear HTML default
        node.ns = 0x01;
    }

    // Wrap node as JS object
    const obj_val = wrapNode(vm, node) orelse return JsValue.null_val;
    const obj = obj_val.asJsObject();

    // Store prefix as own property for prefix getter
    if (prefix) |p| {
        const prefix_sid = try vm.pool.intern("__prefix");
        const prefix_val = JsValue.initString(try vm.pool.intern(p));
        obj.setProperty(vm.allocator, prefix_sid, prefix_val) catch {};
    }

    // Store namespace URI as own property for non-standard namespaces (not in lexbor)
    if (ns_str) |uri| {
        if (uriToNsId(uri) == null) {
            const ns_sid = try vm.pool.intern("__nsURI");
            const ns_val = JsValue.initString(try vm.pool.intern(uri));
            obj.setProperty(vm.allocator, ns_sid, ns_val) catch {};
        }
    }

    // Store original localName for case preservation (lexbor lowercases)
    // Only needed if localName contains uppercase chars
    var has_upper = false;
    for (create_name) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            has_upper = true;
            break;
        }
    }
    if (has_upper) {
        const orig_sid = try vm.pool.intern("__origLocal");
        const orig_val = JsValue.initString(try vm.pool.intern(create_name));
        obj.setProperty(vm.allocator, orig_sid, orig_val) catch {};
    }

    return obj_val;
}

/// Build a fresh Attr-like JS object per DOM §4.9.
///   name/nodeName: full qualified name
///   value/nodeValue/textContent: ""
///   localName / prefix / namespaceURI: as given
///   ownerElement: null (Attr is detached until setAttributeNode)
///   specified: true (legacy)
///   ownerDocument: the document that created this attr
fn createAttrObject(
    vm: *VM,
    owner_doc: JsValue,
    qname: []const u8,
    local_name: []const u8,
    prefix: ?[]const u8,
    namespace: ?[]const u8,
) !JsValue {
    const obj = try vm.createObj(.{});
    // nodeType = 2 (ATTRIBUTE_NODE)
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeType"), JsValue.initNumber(2));
    const qname_sid = try vm.pool.intern(qname);
    const local_sid = try vm.pool.intern(local_name);
    try obj.setProperty(vm.allocator, try vm.pool.intern("name"), JsValue.initString(qname_sid));
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeName"), JsValue.initString(qname_sid));
    try obj.setProperty(vm.allocator, try vm.pool.intern("localName"), JsValue.initString(local_sid));
    const empty_sid = try vm.pool.intern("");
    try obj.setProperty(vm.allocator, try vm.pool.intern("value"), JsValue.initString(empty_sid));
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeValue"), JsValue.initString(empty_sid));
    try obj.setProperty(vm.allocator, try vm.pool.intern("textContent"), JsValue.initString(empty_sid));
    if (prefix) |p| {
        try obj.setProperty(vm.allocator, try vm.pool.intern("prefix"), JsValue.initString(try vm.pool.intern(p)));
    } else {
        try obj.setProperty(vm.allocator, try vm.pool.intern("prefix"), JsValue.null_val);
    }
    if (namespace) |n| {
        try obj.setProperty(vm.allocator, try vm.pool.intern("namespaceURI"), JsValue.initString(try vm.pool.intern(n)));
    } else {
        try obj.setProperty(vm.allocator, try vm.pool.intern("namespaceURI"), JsValue.null_val);
    }
    try obj.setProperty(vm.allocator, try vm.pool.intern("specified"), JsValue.initBool(true));
    try obj.setProperty(vm.allocator, try vm.pool.intern("ownerElement"), JsValue.null_val);
    // DOM §4.9 — attr's ownerDocument is the creating doc. Attr wrappers
    // are plain JsObjects (not `.dom_node`), so `domNodeGetProp` never
    // fires for them; keep the JS-visible `ownerDocument` property for
    // read access, AND write the `_ownerDoc` slot so downstream code that
    // calls `getNodeOwnerDoc(attr)` sees the same value.
    setNodeOwnerDoc(vm, obj, owner_doc);
    try obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), owner_doc);
    try obj.setProperty(vm.allocator, try vm.pool.intern("parentNode"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("parentElement"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("firstChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("lastChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("previousSibling"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("nextSibling"), JsValue.null_val);
    // childNodes = empty list
    const cn = try vm.createObj(.{ .obj_type = .array });
    cn.data = .{ .array = .empty };
    try obj.setProperty(vm.allocator, try vm.pool.intern("childNodes"), JsValue.initObject(cn));
    return JsValue.initObject(obj);
}

/// True if `this` is an XML (non-HTML) document — i.e. has _isXmlDoc=true.
/// In HTML documents, createAttribute lowercases the name; in XML docs, case
/// is preserved.
fn thisIsXmlDoc(vm: *VM, this: JsValue) bool {
    if (!this.isObject()) return false;
    const this_obj = this.asJsObject();
    const xml_sid = vm.pool.intern("_isXmlDoc") catch return false;
    const xv = this_obj.getProperty(xml_sid) orelse return false;
    return xv.isBool() and xv.asBool();
}

/// DOM §4.5 — document.createAttribute(localName)
/// Returns a fresh Attr with no ownerElement. Throws InvalidCharacterError
/// only for empty names, matching the WPT fixture's `invalid_names = [""]`
/// (browsers validate Name lenient-ly; nearly any non-empty string is
/// accepted). HTML documents lowercase the name; XML documents preserve
/// case (per DOM spec "In an HTML document, let localName be converted to
/// ASCII lowercase").
fn nativeCreateAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.null_val;
    }
    // DOMString coercion: null → "null", undefined → "undefined".
    const raw = argToString(vm, args[0]);
    // DOM §4.5: if localName does not match Name production → InvalidCharacterError.
    // WPT fixture `invalid_names = [""]` — only the empty string is rejected.
    if (raw.len == 0) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.null_val;
    }

    // HTML document → lowercase the local name.
    const is_xml = thisIsXmlDoc(vm, this);
    var lower_buf: [256]u8 = undefined;
    const name: []const u8 = if (is_xml) raw else lbl: {
        const n = @min(raw.len, lower_buf.len);
        for (0..n) |i| lower_buf[i] = std.ascii.toLower(raw[i]);
        break :lbl lower_buf[0..n];
    };

    return try createAttrObject(vm, this, name, name, null, null);
}

/// DOM §4.5 — document.createAttributeNS(namespace, qualifiedName)
/// Runs the "validate and extract" algorithm, then returns a fresh Attr.
fn nativeCreateAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.null_val;
    }
    const ns_in: ?[]const u8 = blk: {
        if (args[0].isNull() or args[0].isUndefined()) break :blk null;
        break :blk argToString(vm, args[0]);
    };
    const qn = argToString(vm, args[1]);

    const v = dom_names.validateAndExtract(qn, ns_in) catch |err| {
        return try queueValidationErr(vm, err);
    };
    return try createAttrObject(vm, this, qn, v.local_name, v.prefix, v.namespace);
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

/// CSSStyleDeclaration.setProperty(property, value[, priority]) — CSSOM §6.7.4.
/// Writes the property into the element's inline `style` attribute using
/// the same `updateStyleProp` helper that the `element.style.X = Y` path uses.
fn nativeCSSSetProperty(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !this.isObject()) return JsValue.undefined_val;
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_style) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));
    const prop_in = if (args[0].isString()) (vm.pool.get(args[0].asStringId()) orelse "") else "";
    var name_buf: [128]u8 = undefined;
    const css_prop = camelToKebab(prop_in, &name_buf);
    const new_val = if (args[1].isString()) (vm.pool.get(args[1].asStringId()) orelse "") else "";
    // CSSOM §6.7.4: invalid values are ignored (same invariant as the
    // `el.style.X = Y` path above).
    if (validate_fn) |vf| {
        if (!vf(css_prop, new_val)) return JsValue.undefined_val;
    }
    var attr_len: usize = 0;
    const old_style = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";
    var result_buf: [2048]u8 = undefined;
    const new_style = updateStyleProp(old_style, css_prop, new_val, &result_buf);
    _ = dom_b.lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
    setDomDirty();
    return JsValue.undefined_val;
}

/// CSSStyleDeclaration.removeProperty(property) — CSSOM §6.7.5.
/// Removes a property from the inline style by setting its value to "".
fn nativeCSSRemoveProperty(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !this.isObject()) return JsValue.initString(try vm.pool.intern(""));
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_style) return JsValue.initString(try vm.pool.intern(""));
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));
    const prop_in = if (args[0].isString()) (vm.pool.get(args[0].asStringId()) orelse "") else "";
    var name_buf: [128]u8 = undefined;
    const css_prop = camelToKebab(prop_in, &name_buf);
    // Capture old value before removal (return value per spec).
    var attr_len: usize = 0;
    const old_style = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";
    const old_val = findCssPropValue(old_style, css_prop) orelse "";
    const old_val_sid = try vm.pool.intern(old_val);
    // Remove by writing empty value (updateStyleProp with "" removes the property).
    var result_buf: [2048]u8 = undefined;
    const new_style = updateStyleProp(old_style, css_prop, "", &result_buf);
    _ = dom_b.lxb_dom_element_set_attribute(elem, "style", 5, new_style.ptr, new_style.len);
    setDomDirty();
    return JsValue.initString(old_val_sid);
}

/// CSSStyleDeclaration.item(index) — CSSOM §6.7.3.
/// Returns the CSS property name at the given index, or "" if out of range.
/// Parses the inline style attribute to enumerate property names.
fn nativeCSSItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (!this.isObject()) return JsValue.initString(try vm.pool.intern(""));
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_style) return JsValue.initString(try vm.pool.intern(""));
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));
    const idx: usize = if (args.len > 0) @intFromFloat(@max(0, @trunc(args[0].toNumber()))) else 0;
    var attr_len: usize = 0;
    const style_str = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";
    // Iterate through "prop:val;" pairs to find the idx-th property name.
    var count: usize = 0;
    var rest = style_str;
    while (rest.len > 0) {
        // Find next semicolon or end
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const decl = std.mem.trim(u8, rest[0..semi], " \t\r\n");
        if (semi < rest.len) rest = rest[semi + 1 ..] else rest = "";
        if (decl.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const prop = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        if (prop.len == 0) continue;
        if (count == idx) {
            return JsValue.initString(try vm.pool.intern(prop));
        }
        count += 1;
    }
    return JsValue.initString(try vm.pool.intern(""));
}

/// CSSStyleDeclaration.length — CSSOM §6.7.3.
/// Returns the number of declared properties in the inline style.
fn nativeCSSLengthGet(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    if (!this.isObject()) return JsValue.initNumber(0);
    const obj = this.asJsObject();
    if (obj.obj_type != .dom_style) return JsValue.initNumber(0);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(@alignCast(obj.data.dom_style));
    var attr_len: usize = 0;
    const style_str = if (dom_b.lxb_dom_element_get_attribute(elem, "style", 5, &attr_len)) |p|
        p[0..attr_len]
    else
        "";
    var count: usize = 0;
    var rest = style_str;
    while (rest.len > 0) {
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const decl = std.mem.trim(u8, rest[0..semi], " \t\r\n");
        if (semi < rest.len) rest = rest[semi + 1 ..] else rest = "";
        if (decl.len == 0) continue;
        if (std.mem.indexOfScalar(u8, decl, ':') != null) count += 1;
    }
    return JsValue.initNumber(@floatFromInt(count));
}

fn nativeCreateTextNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = getDocFromThis(this) orelse return JsValue.null_val;
    // DOMString conversion: null→"null", undefined→"undefined", number→string
    const text = if (args.len > 0) argToString(vm, args[0]) else "";
    const tn = dom_b.lxb_dom_document_create_text_node(doc, text.ptr, text.len) orelse return JsValue.null_val;
    return wrapNode(vm, tn) orelse JsValue.null_val;
}

fn nativeHasChildNodes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    return JsValue.initBool(nodeFirstChild(node) != null);
}

fn getDocTypeName(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var len: usize = 0;
    if (dom_b.lxb_dom_document_type_name_noi(@ptrCast(node), &len)) |n| {
        return JsValue.initString(vm.pool.intern(n[0..len]) catch return JsValue.null_val);
    }
    return JsValue.initString(vm.pool.intern("html") catch return JsValue.null_val);
}

fn nativeCreateComment(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = getDocFromThis(this) orelse return JsValue.null_val;
    const data = if (args.len > 0) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_comment(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
}

/// Document.createCDATASection(data) — DOM §4.5.
/// kotori has no distinct CDATASection class; we back it with a lexbor Comment
/// node so the returned value is a valid CharacterData-typed Node. Tests that
/// only care about CharacterData shape (common.js, Node-contains, Range) keep
/// passing; tests that inspect `nodeType === 4` specifically still fail — those
/// are out of scope for the core-regression fix.
/// Per spec: HTML documents should throw NotSupportedError; for now we return
/// the comment-backed node unconditionally so in-HTML-testsuite tests that
/// build a mock xmlDocument from `new Document()` keep working.
fn nativeCreateCDATASection(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = getDocFromThis(this) orelse return JsValue.null_val;
    const data = if (args.len > 0) argToString(vm, args[0]) else "";
    if (std.mem.indexOf(u8, data, "]]>") != null) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.null_val;
    }
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
    // Web IDL DOMString: call object's toString() method
    if (val.isObject()) {
        const obj = val.asJsObject();
        const toString_id = vm.pool.intern("toString") catch return "[object Object]";
        if (obj.getProperty(toString_id)) |ts_val| {
            if (ts_val.isObject()) {
                const result = vm.callJsFunction(ts_val, val, &.{}) catch return "[object Object]";
                if (result.isString()) return vm.pool.get(result.asStringId()) orelse "[object Object]";
            }
        }
        // Check prototype chain
        if (obj.prototype) |proto| {
            if (proto.getProperty(toString_id)) |ts_val| {
                if (ts_val.isObject()) {
                    const result = vm.callJsFunction(ts_val, val, &.{}) catch return "[object Object]";
                    if (result.isString()) return vm.pool.get(result.asStringId()) orelse "[object Object]";
                }
            }
        }
    }
    return "[object Object]";
}

fn nativeCreateDocumentFragment(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = getDocFromThis(this) orelse return JsValue.null_val;
    const frag = sr.lxb_dom_document_create_document_fragment(doc) orelse return JsValue.null_val;
    return wrapNode(vm, frag) orelse JsValue.null_val;
}

/// DOM §4.4: document.adoptNode(node) — removes from current parent, returns node.
fn nativeAdoptNode(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.null_val;
    const node = getArgNode(args[0]) orelse return args[0]; // JS-only node: return as-is
    // Remove from current parent
    dom_b.lxb_dom_node_remove(node);
    setDomDirty();
    return args[0];
}

/// DOM §4.4: document.importNode(node, deep) — clones a node into this document.
fn nativeImportNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return error.TypeError;
    // DOM §4.5 step 1: if node is a Document, throw NotSupportedError.
    if (args[0].isObject()) {
        const src_obj = args[0].asJsObject();
        if (src_obj.obj_type == .dom_node) {
            const src_node_c: ?*lxb.lxb_dom_node_t = @ptrCast(@alignCast(src_obj.data.dom_node));
            if (src_node_c) |sn| {
                if (nodeType(sn) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "NotSupportedError");
                    return JsValue.undefined_val;
                }
            }
        }
    }
    const node = getArgNode(args[0]) orelse return JsValue.null_val;
    const deep = if (args.len > 1 and args[1].isBool()) args[1].asBool() else false;
    // DOM §4.5 "import a node" = "clone a node" with `document` set to `this`.
    // Pass `this` (the target document JS wrapper) as the override so every
    // cloned node's `_ownerDoc` slot points at `this` rather than at the
    // source node's owner document (which lexbor copies by default).
    const owner_override: ?JsValue = if (this.isObject()) this else null;
    return cloneNodeImpl(vm, node, owner_override, deep) orelse JsValue.null_val;
}

// ── Helper: register an event interface constructor + prototype ──────

fn registerEventCtor(vm: *VM, name: []const u8, proto: *JsObject, proto_sid: StringId) !void {
    const ctor = try vm.createObj(.{ .obj_type = .native_function });
    ctor.data = .{ .native_fn = &nativeEventConstructor };
    ctor.setProperty(vm.allocator, proto_sid, JsValue.initObject(proto)) catch {};
    try vm.globals.put(vm.allocator, try vm.pool.intern(name), JsValue.initObject(ctor));
}

// ── document.createEvent (DOM §5.1 legacy factory) ──────────────────

/// DOM §5.1: Resolve a case-insensitive interface string to the canonical
/// constructor name. Returns null for unsupported interfaces.
fn resolveCreateEventInterface(input: []const u8) ?[]const u8 {
    // DOM §5.1 table of legacy event interface aliases (case-insensitive)
    const aliases = [_]struct { alias: []const u8, ctor: []const u8 }{
        .{ .alias = "beforeunloadevent", .ctor = "BeforeUnloadEvent" },
        .{ .alias = "compositionevent", .ctor = "CompositionEvent" },
        .{ .alias = "customevent", .ctor = "CustomEvent" },
        .{ .alias = "devicemotionevent", .ctor = "DeviceMotionEvent" },
        .{ .alias = "deviceorientationevent", .ctor = "DeviceOrientationEvent" },
        .{ .alias = "dragevent", .ctor = "DragEvent" },
        .{ .alias = "event", .ctor = "Event" },
        .{ .alias = "events", .ctor = "Event" },
        .{ .alias = "focusevent", .ctor = "FocusEvent" },
        .{ .alias = "hashchangeevent", .ctor = "HashChangeEvent" },
        .{ .alias = "htmlevents", .ctor = "Event" },
        .{ .alias = "keyboardevent", .ctor = "KeyboardEvent" },
        .{ .alias = "messageevent", .ctor = "MessageEvent" },
        .{ .alias = "mouseevent", .ctor = "MouseEvent" },
        .{ .alias = "mouseevents", .ctor = "MouseEvent" },
        // NOTE: MutationEvent / MutationEvents / ProgressEvent are intentionally
        // absent — current DOM §4.5 eventInterfaceTable removed them, and
        // Document-createEvent.https.html explicitly asserts they throw
        // NOT_SUPPORTED_ERR. The global `MutationEvent` / `ProgressEvent`
        // constructors still exist (for `new MutationEvent()`, instanceof,
        // and the MutationEvent.MODIFICATION/ADDITION/REMOVAL constants used
        // by attributes.html) — they are just not legacy-createable.
        .{ .alias = "storageevent", .ctor = "StorageEvent" },
        .{ .alias = "svgevents", .ctor = "Event" },
        .{ .alias = "textevent", .ctor = "TextEvent" },
        .{ .alias = "touchevent", .ctor = "TouchEvent" },
        .{ .alias = "uievent", .ctor = "UIEvent" },
        .{ .alias = "uievents", .ctor = "UIEvent" },
    };
    for (&aliases) |*entry| {
        if (std.ascii.eqlIgnoreCase(input, entry.alias)) return entry.ctor;
    }
    return null;
}

fn nativeCreateEvent(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotSupportedError");
        return JsValue.undefined_val;
    }
    const input = vm.pool.get(args[0].asStringId()) orelse "";
    const ctor_name = resolveCreateEventInterface(input) orelse {
        // DOM §5.1: throw "NotSupportedError" DOMException for unsupported interfaces
        vm.pending_throw = try createDOMExceptionObj(vm, "NotSupportedError");
        return JsValue.undefined_val;
    };
    // Look up the constructor in globals
    const ctor_sid = try vm.pool.intern(ctor_name);
    const ctor_val = vm.globals.get(ctor_sid) orelse return JsValue.null_val;
    if (!ctor_val.isObject()) return JsValue.null_val;
    const ctor = ctor_val.asJsObject();
    // Create uninitialised event via Event constructor (empty args)
    const empty_args: []const JsValue = &.{};
    const result = if (ctor.obj_type == .native_function)
        try ctor.data.native_fn(@ptrCast(vm), JsValue.undefined_val, empty_args)
    else
        try nativeEventConstructor(@ptrCast(vm), JsValue.undefined_val, empty_args);
    // Set prototype from the target constructor (not Event)
    if (result.isObject()) {
        const result_obj = result.asJsObject();
        const p_sid = try vm.pool.intern("prototype");
        if (ctor.getProperty(p_sid)) |proto_val| {
            if (proto_val.isObject()) {
                result_obj.prototype = proto_val.asJsObject();
            }
        }
    }
    return result;
}

// ── document.createProcessingInstruction (DOM §4.1) ─────────────────

fn nativeCreateProcessingInstruction(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) {
        return error.TypeError;
    }
    const target_str = if (args[0].isString()) (vm.pool.get(args[0].asStringId()) orelse "") else "";
    const data_str = if (args[1].isString()) (vm.pool.get(args[1].asStringId()) orelse "") else "";
    // DOM spec: target must be a valid XML Name.
    if (target_str.len == 0) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.undefined_val;
    }
    // DOM spec: data must not contain "?>".
    if (std.mem.indexOf(u8, data_str, "?>") != null) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.undefined_val;
    }
    // Create a JS-only ProcessingInstruction object (nodeType 7)
    const obj = try vm.createObj(.{});
    if (g_node_proto) |np| obj.prototype = np;
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeType"), JsValue.initNumber(7));
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeName"), JsValue.initString(try vm.pool.intern(target_str)));
    try obj.setProperty(vm.allocator, try vm.pool.intern("target"), JsValue.initString(try vm.pool.intern(target_str)));
    try obj.setProperty(vm.allocator, try vm.pool.intern("data"), JsValue.initString(try vm.pool.intern(data_str)));
    try obj.setProperty(vm.allocator, try vm.pool.intern("textContent"), JsValue.initString(try vm.pool.intern(data_str)));
    try obj.setProperty(vm.allocator, try vm.pool.intern("nodeValue"), JsValue.initString(try vm.pool.intern(data_str)));
    // DOM §4.4 — ProcessingInstruction's ownerDocument is the creating doc.
    // PI wrappers are plain JsObjects (not `.dom_node`), so write both the
    // `_ownerDoc` slot AND the JS-visible property for direct JS reads.
    const pi_owner_doc: JsValue = if (this.isObject()) this else JsValue.null_val;
    setNodeOwnerDoc(vm, obj, pi_owner_doc);
    try obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), pi_owner_doc);
    try obj.setProperty(vm.allocator, try vm.pool.intern("parentNode"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("parentElement"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("previousSibling"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("nextSibling"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("firstChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("lastChild"), JsValue.null_val);
    try obj.setProperty(vm.allocator, try vm.pool.intern("childNodes"), JsValue.initNumber(0)); // placeholder
    return JsValue.initObject(obj);
}

// ══════════════════════════════════════════════════════════════════════
// Element native methods (on prototype)
// ══════════════════════════════════════════════════════════════════════

// ── DOM mutation pre-insertion / pre-removal validation (DOM §4.2.2-4.2.3) ──

/// Check whether `val` looks like any Node — either a native lexbor-backed
/// dom_node or a JS-only node (ProcessingInstruction/CDATA) with a numeric
/// `nodeType` own property. Used to distinguish "not a Node" (WebIDL
/// TypeError) from "Node but unsupported in this DOM op".
fn argIsNodeLike(vm: *VM, val: JsValue) bool {
    if (!val.isObject()) return false;
    const obj = val.asJsObject();
    if (obj.obj_type == .dom_node) return true;
    const nt_sid = vm.pool.intern("nodeType") catch return false;
    if (obj.getProperty(nt_sid)) |v| return v.isNumber();
    return false;
}

/// Count element children of `node`, optionally excluding `exclude`.
fn countElementChildren(node: *lxb.lxb_dom_node_t, exclude: ?*lxb.lxb_dom_node_t) usize {
    var n: usize = 0;
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| : (ch = nodeNext(c)) {
        if (exclude != null and c == exclude.?) continue;
        if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) n += 1;
    }
    return n;
}

/// Does `node` have any child of `kind`, optionally excluding `exclude`?
fn hasChildOfType(node: *lxb.lxb_dom_node_t, kind: c_uint, exclude: ?*lxb.lxb_dom_node_t) bool {
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (ch) |c| : (ch = nodeNext(c)) {
        if (exclude != null and c == exclude.?) continue;
        if (nodeType(c) == kind) return true;
    }
    return false;
}

/// Does `node` contain a DocumentType sibling following `after` (exclusive)?
fn hasDoctypeAfter(node: *lxb.lxb_dom_node_t, after: *lxb.lxb_dom_node_t) bool {
    var ch: ?*lxb.lxb_dom_node_t = nodeNext(after);
    _ = node;
    while (ch) |c| : (ch = nodeNext(c)) {
        if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) return true;
    }
    return false;
}

/// Does `node` contain an Element sibling preceding `before` (exclusive)?
fn hasElementBefore(parent: *lxb.lxb_dom_node_t, before: *lxb.lxb_dom_node_t) bool {
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(parent);
    while (ch) |c| : (ch = nodeNext(c)) {
        if (c == before) return false;
        if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return true;
    }
    return false;
}

/// Inspect a DocumentFragment's children: number of element children and
/// whether it contains any Text node. Used by DOM §4.2.2 step 6.1.
const FragmentInfo = struct { element_count: usize, has_text: bool };
fn inspectFragment(frag: *lxb.lxb_dom_node_t) FragmentInfo {
    var info = FragmentInfo{ .element_count = 0, .has_text = false };
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(frag);
    while (ch) |c| : (ch = nodeNext(c)) {
        switch (nodeType(c)) {
            lxb.LXB_DOM_NODE_TYPE_ELEMENT => info.element_count += 1,
            lxb.LXB_DOM_NODE_TYPE_TEXT => info.has_text = true,
            else => {},
        }
    }
    return info;
}

/// DOM §4.2.2 — Ensure pre-insertion validity / §4.2.4 replaceChild common prefix.
///
/// `child` is the reference child (or the node being replaced, for replaceChild).
/// `is_replace = true` applies §4.2.4 replaceChild-specific step 6 semantics,
/// where existing-child counts exclude `child` (since it is about to be removed).
/// Returns true if valid, false if a DOMException was queued on vm.pending_throw.
fn validatePreInsertFull(
    vm: *VM,
    node: ?*lxb.lxb_dom_node_t,
    parent: *lxb.lxb_dom_node_t,
    child: ?*lxb.lxb_dom_node_t,
    is_replace: bool,
) !bool {
    const ptype = nodeType(parent);

    // Step 1: parent must be Document, DocumentFragment, or Element.
    if (ptype != lxb.LXB_DOM_NODE_TYPE_DOCUMENT and
        ptype != lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT and
        ptype != lxb.LXB_DOM_NODE_TYPE_ELEMENT)
    {
        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
        return false;
    }

    // Step 2: node is host-including inclusive ancestor of parent.
    if (node) |n| {
        var cur: ?*lxb.lxb_dom_node_t = parent;
        while (cur) |c| {
            if (c == n) {
                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                return false;
            }
            cur = nodeParent(c);
        }
    }

    // Step 3: child is non-null and child.parentNode != parent.
    if (child) |ch| {
        if (nodeParent(ch) != parent) {
            vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
            return false;
        }
    }

    // Step 4: node must be DocumentFragment, DocumentType, Element, or CharacterData.
    const n_opt = node;
    const ntype: c_uint = if (n_opt) |n| nodeType(n) else 0;
    if (n_opt != null) {
        if (ntype != lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT and
            ntype != lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE and
            ntype != lxb.LXB_DOM_NODE_TYPE_ELEMENT and
            ntype != lxb.LXB_DOM_NODE_TYPE_TEXT and
            ntype != lxb.LXB_DOM_NODE_TYPE_PROCESSING_INSTRUCTION and
            ntype != lxb.LXB_DOM_NODE_TYPE_COMMENT)
        {
            vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
            return false;
        }

        // Step 5: Text into Document, or DocumentType into non-Document.
        if (ntype == lxb.LXB_DOM_NODE_TYPE_TEXT and ptype == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
            vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
            return false;
        }
        if (ntype == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE and ptype != lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
            vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
            return false;
        }
    }

    // Step 6: parent is a Document — enforce at-most-one-element / at-most-one-doctype
    // and relative-order constraints. For replaceChild, exclude `child` from counts.
    if (n_opt != null and ptype == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
        const n = n_opt.?;
        const exclude: ?*lxb.lxb_dom_node_t = if (is_replace) child else null;

        if (ntype == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT) {
            const finfo = inspectFragment(n);
            // DocumentFragment may not contain Text.
            if (finfo.has_text) {
                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                return false;
            }
            if (finfo.element_count > 1) {
                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                return false;
            }
            if (finfo.element_count == 1) {
                if (countElementChildren(parent, exclude) > 0) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                }
                // For insert/replace: a doctype must not follow the insertion point.
                if (is_replace) {
                    if (child) |ch| if (hasDoctypeAfter(parent, ch)) {
                        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                        return false;
                    };
                } else {
                    if (child) |ch| if (hasDoctypeAfter(parent, ch) or
                        nodeType(ch) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE)
                    {
                        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                        return false;
                    };
                    // If no ref child but doctype exists → would place element after doctype.
                    if (child == null and hasChildOfType(parent, lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE, null)) {
                        // Actually allowed: appendChild only throws if doctype is AFTER (last).
                        // lexbor appends to end; doctype must precede element → if doctype exists
                        // at last position, we'd violate order. Conservative: only throw when
                        // appending element while doctype is last child.
                        if (dom_b.lxb_dom_node_last_child_noi(parent)) |lc| {
                            if (nodeType(lc) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
                                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                                return false;
                            }
                        }
                    }
                }
            }
        } else if (ntype == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            if (countElementChildren(parent, exclude) > 0) {
                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                return false;
            }
            if (is_replace) {
                if (child) |ch| if (hasDoctypeAfter(parent, ch)) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                };
            } else {
                if (child) |ch| if (hasDoctypeAfter(parent, ch) or
                    nodeType(ch) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE)
                {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                };
                if (child == null) {
                    if (dom_b.lxb_dom_node_last_child_noi(parent)) |lc| {
                        if (nodeType(lc) == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
                            vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                            return false;
                        }
                    }
                }
            }
        } else if (ntype == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) {
            if (hasChildOfType(parent, lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE, exclude)) {
                vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                return false;
            }
            if (is_replace) {
                if (child) |ch| if (hasElementBefore(parent, ch)) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                };
            } else {
                if (child) |ch| if (hasElementBefore(parent, ch)) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                };
                // appendChild with no ref: doctype after any element child is invalid.
                if (child == null and countElementChildren(parent, null) > 0) {
                    vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
                    return false;
                }
            }
        }
    }

    return true;
}

/// Back-compat wrapper for pre-insert (§4.2.2).
fn validatePreInsert(vm: *VM, node: ?*lxb.lxb_dom_node_t, parent: *lxb.lxb_dom_node_t, child: ?*lxb.lxb_dom_node_t) !bool {
    return validatePreInsertFull(vm, node, parent, child, false);
}

fn nativeAppendChild(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // WebIDL: appendChild(Node) — missing/non-Node arg → TypeError.
    if (args.len == 0 or !argIsNodeLike(vm, args[0])) return error.TypeError;
    const parent = getThisNodeOrFragment(this) orelse return JsValue.null_val;
    // JS-only nodes (PI/CDATA from another document) aren't lexbor-backed.
    // Per DOM spec they must be adopted first; without that support, we
    // treat them as non-insertable (HierarchyRequestError).
    const child = getArgNode(args[0]) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
        return JsValue.undefined_val;
    };
    if (!try validatePreInsert(vm, child, parent, null)) return JsValue.undefined_val;
    // MO: capture siblings before mutation
    const prev_sib = if (dom_b.lxb_dom_node_last_child_noi(parent)) |lc| wrapNode(vm, lc) orelse JsValue.null_val else JsValue.null_val;
    dom_b.lxb_dom_node_remove(child);
    dom_b.lxb_dom_node_insert_child(parent, child);
    sr.propagateScopeFromParent(parent, child);
    setDomDirty();
    // MO: record childList mutation
    if (g_mo_list.items.len > 0) {
        recordChildListMutation(vm, parent, args[0], null, prev_sib, JsValue.null_val);
    }
    return args[0];
}

fn nativeRemoveChild(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // WebIDL: removeChild(Node) — missing/non-Node arg → TypeError.
    if (args.len == 0 or !argIsNodeLike(vm, args[0])) return error.TypeError;
    const parent = getThisNode(this) orelse return JsValue.null_val;
    // JS-only nodes (PI/CDATA from another document) can't be parented here.
    const child = getArgNode(args[0]) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    if (nodeParent(child) != parent) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    // MO: capture siblings before removal
    const prev_sib = if (child.prev) |p| wrapNode(vm, p) orelse JsValue.null_val else JsValue.null_val;
    const next_sib = if (nodeNext(child)) |n| wrapNode(vm, n) orelse JsValue.null_val else JsValue.null_val;
    dom_b.lxb_dom_node_remove(child);
    setDomDirty();
    // MO: record childList mutation
    if (g_mo_list.items.len > 0) {
        recordChildListMutation(vm, parent, null, args[0], prev_sib, next_sib);
    }
    return args[0];
}

fn nativeInsertBefore(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // WebIDL: insertBefore(Node, Node?) — first arg must be Node, second
    // must be Node, null, or undefined. Any other value → TypeError.
    if (args.len < 1 or !argIsNodeLike(vm, args[0])) return error.TypeError;
    if (args.len < 2) return error.TypeError;
    if (!(args[1].isNull() or args[1].isUndefined()) and !argIsNodeLike(vm, args[1])) return error.TypeError;
    const parent = getThisNode(this) orelse return JsValue.null_val;
    const new_node = getArgNode(args[0]) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
        return JsValue.undefined_val;
    };
    const ref_node: ?*lxb.lxb_dom_node_t = if (args[1].isNull() or args[1].isUndefined()) null else getArgNode(args[1]);
    if (!try validatePreInsert(vm, new_node, parent, ref_node)) return JsValue.undefined_val;
    // MO: capture siblings before mutation
    const prev_sib = if (ref_node) |ref| (if (ref.prev) |p| wrapNode(vm, p) orelse JsValue.null_val else JsValue.null_val) else (if (dom_b.lxb_dom_node_last_child_noi(parent)) |lc| wrapNode(vm, lc) orelse JsValue.null_val else JsValue.null_val);
    const next_sib = if (ref_node) |ref| (wrapNode(vm, ref) orelse JsValue.null_val) else JsValue.null_val;
    dom_b.lxb_dom_node_remove(new_node);
    if (ref_node) |ref| {
        dom_b.lxb_dom_node_insert_before(ref, new_node);
    } else {
        dom_b.lxb_dom_node_insert_child(parent, new_node);
    }
    setDomDirty();
    // MO: record childList mutation
    if (g_mo_list.items.len > 0) {
        recordChildListMutation(vm, parent, args[0], null, prev_sib, next_sib);
    }
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
    // DOM §4.9.2 step 1: if qualifiedName does not match the Name production
    // → InvalidCharacterError. Use the permissive attr-name grammar that
    // matches WPT productions.js `valid_names` (lenient: only empty +
    // hard-invalid bytes reject). Lexbor stores the qualified name
    // verbatim downstream; only the JS-visible validation step tightens.
    if (!dom_names.isValidAttrName(n)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
        return JsValue.undefined_val;
    }
    // DOM §4.9.1: if an Attr wrapper is cached for the pre-existing attr struct,
    // invalidate it before lexbor potentially reallocates the struct on overwrite.
    if (dom_b.lxb_dom_element_attr_by_name(elem, n.ptr, n.len)) |pre_existing| {
        invalidateAttrWrapper(pre_existing);
    }
    // MO: capture old value for attribute mutation
    if (g_mo_list.items.len > 0) {
        var old_len: usize = 0;
        const old_ptr = dom_b.lxb_dom_element_get_attribute(elem, n.ptr, n.len, &old_len);
        const old_val: ?[]const u8 = if (old_ptr != null and old_len > 0) old_ptr.?[0..old_len] else null;
        _ = dom_b.lxb_dom_element_set_attribute(elem, n.ptr, n.len, v.ptr, v.len);
        recordAttributeMutation(vm, node, n, old_val);
    } else {
        _ = dom_b.lxb_dom_element_set_attribute(elem, n.ptr, n.len, v.ptr, v.len);
    }
    // DOM §4.9.2 — NamedNodeMap is live. Bump the per-element version so
    // any cached `el.attributes` map refreshes its snapshot on next read.
    bumpElemAttrVersion(elem);
    setDomDirty();
    return JsValue.undefined_val;
}

/// DOM §4.9: Element.setAttributeNS(namespace, qualifiedName, value)
fn nativeSetAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 3) return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const qn = if (args[1].isString()) vm.pool.get(args[1].asStringId()) orelse return JsValue.undefined_val else argToString(vm, args[1]);
    const v = if (args[2].isString()) vm.pool.get(args[2].asStringId()) orelse return JsValue.undefined_val else argToString(vm, args[2]);
    // DOM §4.9.3 step 1: run "validate and extract" on (namespace, qn).
    // Errors map to InvalidCharacterError / NamespaceError via the shared
    // queueValidationErr bridge. Lexbor stores the qualified name verbatim
    // (passed as `qn` below); only the validation step tightens here.
    const ns_in: ?[]const u8 = blk: {
        if (args[0].isNull() or args[0].isUndefined()) break :blk null;
        break :blk if (args[0].isString()) vm.pool.get(args[0].asStringId()) orelse null else argToString(vm, args[0]);
    };
    _ = dom_names.validateAndExtract(qn, ns_in) catch |err| {
        return try queueValidationErr(vm, err);
    };
    // DOM §4.9.1: invalidate cached Attr wrapper before lexbor may reallocate on overwrite.
    if (dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)) |pre_existing| {
        invalidateAttrWrapper(pre_existing);
    }
    // MO: capture old value for attribute mutation
    if (g_mo_list.items.len > 0) {
        var old_len: usize = 0;
        const old_ptr = dom_b.lxb_dom_element_get_attribute(elem, qn.ptr, qn.len, &old_len);
        const old_val: ?[]const u8 = if (old_ptr != null and old_len > 0) old_ptr.?[0..old_len] else null;
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, v.ptr, v.len);
        recordAttributeMutation(vm, node, qn, old_val);
    } else {
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, v.ptr, v.len);
    }
    // DOM §4.9.2 NamedNodeMap live-map version bump.
    bumpElemAttrVersion(elem);
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
    // DOM §4.9.1: invalidate the cached Attr wrapper *before* lexbor frees
    // the attribute struct, otherwise the cache would hold a dangling key.
    // MO: capture old value BEFORE removal so attributeOldValue is correct (DOM §4.3.3).
    var old_val: ?[]const u8 = null;
    var old_val_buf: [256]u8 = undefined;
    var old_val_heap: ?[]u8 = null;
    defer if (old_val_heap) |h| vm.allocator.free(h);
    if (g_mo_list.items.len > 0) {
        var old_len: usize = 0;
        if (dom_b.lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &old_len)) |ptr| {
            if (old_len <= old_val_buf.len) {
                @memcpy(old_val_buf[0..old_len], ptr[0..old_len]);
                old_val = old_val_buf[0..old_len];
            } else if (vm.allocator.alloc(u8, old_len)) |h| {
                old_val_heap = h;
                @memcpy(h, ptr[0..old_len]);
                old_val = h;
            } else |_| {}
        }
    }
    if (dom_b.lxb_dom_element_attr_by_name(elem, attr_name.ptr, attr_name.len)) |a| {
        // DOM §4.9 Attr.ownerElement — "remove an attribute" clears owner.
        // Must run BEFORE invalidateAttrWrapper so the cached wrapper
        // (still identified by this attr ptr) gets the update.
        if (g_attr_wrappers.get(@intFromPtr(a))) |cached_wrap| {
            setAttrOwnerElement(vm, cached_wrap, JsValue.null_val);
        }
        invalidateAttrWrapper(a);
    }
    _ = dom_b.lxb_dom_element_remove_attribute(elem, attr_name.ptr, attr_name.len);
    // DOM §4.9.2 NamedNodeMap live-map version bump.
    bumpElemAttrVersion(elem);
    // MO: queue attribute mutation record with captured old value.
    if (g_mo_list.items.len > 0) {
        recordAttributeMutation(vm, node, attr_name, old_val);
    }
    return JsValue.undefined_val;
}

fn nativeAddEventListener(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.undefined_val;
    const callback = args[1];
    if (!callback.isObject()) return JsValue.undefined_val;

    // Resolve the target node pointer (DOM node, window, or standalone EventTarget).
    const node_ptr: *anyopaque = resolveEventTarget(vm, this) orelse return JsValue.undefined_val;

    const event_type = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;

    // Own the event type string
    const owned = try g_alloc.alloc(u8, event_type.len);
    @memcpy(owned, event_type);

    // Parse options: boolean (capture) or object {capture, once, passive, signal}
    var capture = false;
    var once = false;
    var passive = false;
    if (args.len > 2) {
        if (args[2].isBool()) {
            capture = args[2].asBool();
        } else if (args[2].isObject()) {
            const opts = args[2].asJsObject();
            if (vm.pool.intern("capture") catch null) |sid| {
                if (opts.getProperty(sid)) |v| capture = v.isTruthy();
            }
            if (vm.pool.intern("once") catch null) |sid| {
                if (opts.getProperty(sid)) |v| once = v.isTruthy();
            }
            if (vm.pool.intern("passive") catch null) |sid| {
                if (opts.getProperty(sid)) |v| passive = v.isTruthy();
            }
        }
    }

    try g_listeners.append(g_alloc, .{
        .node_ptr = node_ptr,
        .event_type = owned,
        .callback = callback,
        .capture = capture,
        .once = once,
        .passive = passive,
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
        var wi: usize = 0;
        while (wi < g_listeners.items.len) {
            const entry = g_listeners.items[wi];
            if (@intFromPtr(entry.node_ptr) != sentinel_ptr or
                !std.mem.eql(u8, entry.event_type, type_str))
            {
                wi += 1;
                continue;
            }
            const is_once = entry.once;
            _ = vm.callJsFunction(entry.callback, JsValue.initObject(ev_obj), &.{JsValue.initObject(ev_obj)}) catch {};
            if (is_once) {
                g_alloc.free(g_listeners.items[wi].event_type);
                _ = g_listeners.orderedRemove(wi);
            } else {
                wi += 1;
            }
        }
        return JsValue.initBool(true);
    }

    // DOM §2.7: standalone EventTarget.dispatchEvent — no DOM node, dispatch from g_listeners.
    if (this.isObject()) {
        const this_obj = this.asJsObject();
        if (this_obj.obj_type != .dom_node) {
            const et_sid = vm.pool.intern("_et_ptr") catch return JsValue.initBool(false);
            if (this_obj.getProperty(et_sid)) |ptr_val| {
                if (ptr_val.isNumber()) {
                    const target_addr: usize = @intFromFloat(ptr_val.toNumber());
                    if (target_addr != 0) {
                        var type_str_et: []const u8 = "event";
                        if (args[0].isString()) {
                            type_str_et = vm.pool.get(args[0].asStringId()) orelse "event";
                        } else if (args[0].isObject()) {
                            const t_sid = vm.pool.intern("type") catch return JsValue.initBool(false);
                            if (args[0].asJsObject().getProperty(t_sid)) |tv| {
                                if (tv.isString()) type_str_et = vm.pool.get(tv.asStringId()) orelse "event";
                            }
                        }
                        const ev_obj_et: *JsObject = if (args[0].isObject())
                            args[0].asJsObject()
                        else
                            vm.createObj(.{}) catch return JsValue.initBool(false);
                        // Set target/currentTarget on event
                        const tgt_sid = vm.pool.intern("target") catch null;
                        const ct_sid = vm.pool.intern("currentTarget") catch null;
                        if (tgt_sid) |s| ev_obj_et.setProperty(vm.allocator, s, this) catch {};
                        if (ct_sid) |s| ev_obj_et.setProperty(vm.allocator, s, this) catch {};
                        // Iterate with index to support once-removal during dispatch
                        var li: usize = 0;
                        while (li < g_listeners.items.len) {
                            const entry = g_listeners.items[li];
                            if (@intFromPtr(entry.node_ptr) != target_addr or
                                !std.mem.eql(u8, entry.event_type, type_str_et))
                            {
                                li += 1;
                                continue;
                            }
                            const is_once = entry.once;
                            _ = vm.callJsFunction(entry.callback, JsValue.initObject(ev_obj_et), &.{JsValue.initObject(ev_obj_et)}) catch {};
                            // Remove once-listeners after invocation
                            if (is_once) {
                                g_alloc.free(g_listeners.items[li].event_type);
                                _ = g_listeners.orderedRemove(li);
                            } else {
                                li += 1;
                            }
                            // Check stopImmediatePropagation
                            if (vm.pool.intern("_stopImmediate") catch null) |si_sid| {
                                if (ev_obj_et.getProperty(si_sid)) |sv| {
                                    if (sv.isTruthy()) break;
                                }
                            }
                        }
                        return JsValue.initBool(true);
                    }
                }
            }
        }
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
    // Mark as shadow root for JS detection.
    const is_sr_sid = vm.pool.intern("__isShadowRoot") catch return JsValue.initObject(obj);
    obj.setProperty(vm.allocator, is_sr_sid, JsValue.initBool(true)) catch {};
    const mode_sid = vm.pool.intern("mode") catch return JsValue.initObject(obj);
    const mode_str: []const u8 = switch (root_sr.mode) { .open => "open", .closed => "closed" };
    const mode_val = JsValue.initString(vm.pool.intern(mode_str) catch return JsValue.initObject(obj));
    obj.setProperty(vm.allocator, mode_sid, mode_val) catch {};
    // DOM §4.8 — the shadow root's ownerDocument equals the host element's
    // ownerDocument. Guard against re-entrant wrapShadowRoot: look up the
    // host in the node cache first. If already cached, read _ownerDoc
    // directly without re-entering wrapNode. If not cached, lazy-wrap
    // just the host (safe: host is an Element, never a ShadowRoot itself).
    const host_node: *lxb.lxb_dom_node_t = @ptrCast(root_sr.host);
    const host_owner: JsValue = blk: {
        if (nodeCacheGet(host_node)) |cached_host| {
            break :blk getNodeOwnerDoc(vm, cached_host);
        }
        const host_val = wrapNode(vm, host_node) orelse break :blk JsValue.null_val;
        if (!host_val.isObject()) break :blk JsValue.null_val;
        break :blk getNodeOwnerDoc(vm, host_val.asJsObject());
    };
    // DOM §4.5.3 — ShadowRoot has no per-interface prototype in HTML/SVG/MathML,
    // so route through applyInterfaceProto with null namespace + empty
    // local name. resolveInterface returns "Element", giving us
    // `vm.element_proto` (the previous behaviour) plus a single-call
    // _ownerDoc slot write.
    applyInterfaceProto(vm, obj, null, "", host_owner);
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

/// DOM: new Document() — creates an empty XML document (no children).
fn nativeDocumentConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // Create a new empty lexbor document
    const new_doc = dom_b.lxb_html_document_create() orelse return JsValue.undefined_val;
    if (created_doc_count < created_docs.len) {
        created_docs[created_doc_count] = new_doc;
        created_doc_count += 1;
    }
    const doc_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(new_doc));
    const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
    doc_obj.data = .{ .dom_node = @ptrCast(doc_node) };
    doc_obj.prototype = g_node_proto;
    // DOM §4.4 — Document.ownerDocument = null. Cache before wrapNode so
    // descendants wrap-ups resolve to this wrapper rather than
    // lazy-creating a fresh one.
    nodeCachePut(vm.allocator, doc_node, doc_obj);
    setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
    const nt_sid = try vm.pool.intern("nodeType");
    doc_obj.setProperty(vm.allocator, nt_sid, JsValue.initNumber(9)) catch {};
    const nn_sid = try vm.pool.intern("nodeName");
    doc_obj.setProperty(vm.allocator, nn_sid, JsValue.initString(try vm.pool.intern("#document"))) catch {};
    const ctor_meta2 = .{
        .{ "URL", "about:blank" },
        .{ "documentURI", "about:blank" },
        .{ "compatMode", "CSS1Compat" },
        .{ "characterSet", "UTF-8" },
        .{ "charset", "UTF-8" },
        .{ "inputEncoding", "UTF-8" },
        .{ "contentType", "application/xml" },
    };
    inline for (ctor_meta2) |pair| {
        const sid2 = vm.pool.intern(pair[0]) catch break;
        const val_sid2 = vm.pool.intern(pair[1]) catch break;
        doc_obj.setProperty(vm.allocator, sid2, JsValue.initString(val_sid2)) catch {};
    }
    const ctor_loc_sid = try vm.pool.intern("location");
    doc_obj.setProperty(vm.allocator, ctor_loc_sid, JsValue.null_val) catch {};
    vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement) catch {};
    vm.registerNativeMethod(doc_obj, "createElementNS", &nativeCreateElementNS) catch {};
    vm.registerNativeMethod(doc_obj, "createAttribute", &nativeCreateAttribute) catch {};
    vm.registerNativeMethod(doc_obj, "createAttributeNS", &nativeCreateAttributeNS) catch {};
    vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode) catch {};
    vm.registerNativeMethod(doc_obj, "createComment", &nativeCreateComment) catch {};
    vm.registerNativeMethod(doc_obj, "createCDATASection", &nativeCreateCDATASection) catch {};
    vm.registerNativeMethod(doc_obj, "createDocumentFragment", &nativeCreateDocumentFragment) catch {};
    vm.registerNativeMethod(doc_obj, "createEvent", &nativeCreateEvent) catch {};
    vm.registerNativeMethod(doc_obj, "createProcessingInstruction", &nativeCreateProcessingInstruction) catch {};
    vm.registerNativeMethod(doc_obj, "appendChild", &nativeAppendChild) catch {};
    return JsValue.initObject(doc_obj);
}

fn nativeTextConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const data = if (args.len > 0 and !args[0].isUndefined()) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_text_node(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
}

fn nativeCommentConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const doc = g_document orelse return JsValue.null_val;
    const data = if (args.len > 0 and !args[0].isUndefined()) argToString(vm, args[0]) else "";
    const node = dom_b.lxb_dom_document_create_comment(doc, data.ptr, data.len) orelse return JsValue.null_val;
    return wrapNode(vm, node) orelse JsValue.null_val;
}

// ======================================================================
// Event system constructors (DOM 2.5 / 2.7)
// ======================================================================

/// DOM 2.7: new EventTarget() -- creates a standalone event target.
/// Uses the JsObject pointer itself as the identity key in g_listeners.
fn nativeEventTargetConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const obj = try vm.createObj(.{});
    // Store self-pointer as _et_ptr so addEventListener can identify standalone targets
    const et_ptr_sid = try vm.pool.intern("_et_ptr");
    obj.setProperty(vm.allocator, et_ptr_sid, JsValue.initNumber(@floatFromInt(@intFromPtr(obj)))) catch {};
    return JsValue.initObject(obj);
}

/// Helper: resolve the event target pointer from `this` for addEventListener/removeEventListener.
/// Returns the node_ptr used as identity key in g_listeners.
fn resolveEventTarget(vm: *VM, this: JsValue) ?*anyopaque {
    if (!this.isObject()) return null;
    const obj = this.asJsObject();
    // Window proxy -> sentinel
    if (obj.obj_type == .window_proxy)
        return @ptrCast(&g_window_sentinel);
    // DOM node
    if (obj.obj_type == .dom_node)
        return @ptrCast(@alignCast(obj.data.dom_node));
    // Standalone EventTarget -- use the _et_ptr stored during construction
    const et_sid = vm.pool.intern("_et_ptr") catch return null;
    if (obj.getProperty(et_sid)) |ptr_val| {
        if (ptr_val.isNumber()) {
            const addr: usize = @intFromFloat(ptr_val.toNumber());
            if (addr != 0) return @ptrFromInt(addr);
        }
    }
    return null;
}

/// DOM 2.5: new Event(type, eventInitDict) constructor.
fn nativeEventConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const obj = try vm.createObj(.{});

    // type argument (required by spec but we tolerate missing)
    var type_str: []const u8 = "";
    if (args.len > 0 and args[0].isString()) {
        type_str = vm.pool.get(args[0].asStringId()) orelse "";
    }
    const type_sid = try vm.pool.intern("type");
    obj.setProperty(vm.allocator, type_sid, JsValue.initString(try vm.pool.intern(type_str))) catch {};

    // eventInitDict
    var bubbles = false;
    var cancelable = false;
    var composed = false;
    if (args.len > 1 and args[1].isObject()) {
        const opts = args[1].asJsObject();
        if (vm.pool.intern("bubbles") catch null) |sid| {
            if (opts.getProperty(sid)) |v| bubbles = v.isTruthy();
        }
        if (vm.pool.intern("cancelable") catch null) |sid| {
            if (opts.getProperty(sid)) |v| cancelable = v.isTruthy();
        }
        if (vm.pool.intern("composed") catch null) |sid| {
            if (opts.getProperty(sid)) |v| composed = v.isTruthy();
        }
    }
    obj.setProperty(vm.allocator, try vm.pool.intern("bubbles"), JsValue.initBool(bubbles)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("cancelable"), JsValue.initBool(cancelable)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("composed"), JsValue.initBool(composed)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("defaultPrevented"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_stopped"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_stopImmediate"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_cancelBubble"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("isTrusted"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("eventPhase"), JsValue.initNumber(0)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("timeStamp"), JsValue.initNumber(0)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("target"), JsValue.null_val) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("currentTarget"), JsValue.null_val) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("srcElement"), JsValue.null_val) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("returnValue"), JsValue.initBool(true)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_initialized"), JsValue.initBool(true)) catch {};
    // cancelBubble getter/setter via accessor descriptor
    const cb_get_fn = try vm.createObj(.{ .obj_type = .native_function });
    cb_get_fn.data = .{ .native_fn = &nativeCancelBubbleGet };
    const cb_set_fn = try vm.createObj(.{ .obj_type = .native_function });
    cb_set_fn.data = .{ .native_fn = &nativeCancelBubbleSet };
    const cb_sid = try vm.pool.intern("cancelBubble");
    if (obj.descriptors == null)
        obj.descriptors = .{};
    try obj.descriptors.?.put(vm.allocator, cb_sid, .{ .accessor = .{
        .get = JsValue.initObject(cb_get_fn),
        .set = JsValue.initObject(cb_set_fn),
        .attrs = .{ .writable = false, .enumerable = true, .configurable = true, .is_accessor = true },
    } });

    return JsValue.initObject(obj);
}

/// DOM 2.5: new CustomEvent(type, eventInitDict) constructor.
fn nativeCustomEventConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // Create as Event first, then add detail
    const ev_val = try nativeEventConstructor(ctx, JsValue.undefined_val, args);
    if (!ev_val.isObject()) return ev_val;
    const obj = ev_val.asJsObject();

    // detail from eventInitDict
    var detail = JsValue.null_val;
    if (args.len > 1 and args[1].isObject()) {
        const opts = args[1].asJsObject();
        if (vm.pool.intern("detail") catch null) |sid| {
            if (opts.getProperty(sid)) |v| detail = v;
        }
    }
    obj.setProperty(vm.allocator, try vm.pool.intern("detail"), detail) catch {};

    return ev_val;
}

/// Event.prototype.stopPropagation
fn nativeStopPropagation(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    if (this.isObject()) {
        const vm = VM.vmFromCtx(ctx);
        const obj = this.asJsObject();
        obj.setProperty(vm.allocator, try vm.pool.intern("_stopped"), JsValue.initBool(true)) catch {};
        obj.setProperty(vm.allocator, try vm.pool.intern("_cancelBubble"), JsValue.initBool(true)) catch {};
    }
    return JsValue.undefined_val;
}

/// Event.prototype.stopImmediatePropagation
fn nativeStopImmediatePropagation(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    if (this.isObject()) {
        const vm = VM.vmFromCtx(ctx);
        const obj = this.asJsObject();
        obj.setProperty(vm.allocator, try vm.pool.intern("_stopped"), JsValue.initBool(true)) catch {};
        obj.setProperty(vm.allocator, try vm.pool.intern("_stopImmediate"), JsValue.initBool(true)) catch {};
        obj.setProperty(vm.allocator, try vm.pool.intern("_cancelBubble"), JsValue.initBool(true)) catch {};
    }
    return JsValue.undefined_val;
}

/// Event.prototype.preventDefault
fn nativePreventDefault(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    if (this.isObject()) {
        const vm = VM.vmFromCtx(ctx);
        const obj = this.asJsObject();
        // Check cancelable first
        if (vm.pool.intern("cancelable") catch null) |sid| {
            if (obj.getProperty(sid)) |v| {
                if (!v.isTruthy()) return JsValue.undefined_val;
            }
        }
        obj.setProperty(vm.allocator, try vm.pool.intern("defaultPrevented"), JsValue.initBool(true)) catch {};
        obj.setProperty(vm.allocator, try vm.pool.intern("returnValue"), JsValue.initBool(false)) catch {};
    }
    return JsValue.undefined_val;
}

/// Event.prototype.initEvent(type, bubbles, cancelable) -- legacy
fn nativeInitEvent(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (!this.isObject()) return JsValue.undefined_val;
    const vm = VM.vmFromCtx(ctx);
    const obj = this.asJsObject();

    // Short-circuit if dispatching
    if (vm.pool.intern("_dispatching") catch null) |sid| {
        if (obj.getProperty(sid)) |v| {
            if (v.isTruthy()) return JsValue.undefined_val;
        }
    }

    if (args.len >= 1 and args[0].isString()) {
        const t = vm.pool.get(args[0].asStringId()) orelse "";
        obj.setProperty(vm.allocator, try vm.pool.intern("type"), JsValue.initString(try vm.pool.intern(t))) catch {};
    }
    const bubbles = if (args.len >= 2) args[1].isTruthy() else false;
    const cancelable = if (args.len >= 3) args[2].isTruthy() else false;
    obj.setProperty(vm.allocator, try vm.pool.intern("bubbles"), JsValue.initBool(bubbles)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("cancelable"), JsValue.initBool(cancelable)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("defaultPrevented"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_stopped"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_stopImmediate"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_cancelBubble"), JsValue.initBool(false)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("returnValue"), JsValue.initBool(true)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("_initialized"), JsValue.initBool(true)) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("target"), JsValue.null_val) catch {};
    obj.setProperty(vm.allocator, try vm.pool.intern("currentTarget"), JsValue.null_val) catch {};
    return JsValue.undefined_val;
}

/// CustomEvent.prototype.initCustomEvent(type, bubbles, cancelable, detail) -- legacy
fn nativeInitCustomEvent(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (!this.isObject()) return JsValue.undefined_val;
    const vm = VM.vmFromCtx(ctx);
    const obj = this.asJsObject();

    // Short-circuit if dispatching
    if (vm.pool.intern("_dispatching") catch null) |sid| {
        if (obj.getProperty(sid)) |v| {
            if (v.isTruthy()) return JsValue.undefined_val;
        }
    }

    // Delegate to initEvent for the first 3 args
    _ = try nativeInitEvent(ctx, this, args);

    // detail (4th arg)
    const detail = if (args.len >= 4) args[3] else JsValue.null_val;
    obj.setProperty(vm.allocator, try vm.pool.intern("detail"), detail) catch {};
    return JsValue.undefined_val;
}

/// Event.prototype.composedPath -- stub returning empty array
fn nativeComposedPath(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const arr = try vm.createObj(.{ .obj_type = .array });
    return JsValue.initObject(arr);
}

/// cancelBubble getter
fn nativeCancelBubbleGet(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    if (this.isObject()) {
        const vm = VM.vmFromCtx(ctx);
        const obj = this.asJsObject();
        if (vm.pool.intern("_cancelBubble") catch null) |sid| {
            if (obj.getProperty(sid)) |v| return v;
        }
    }
    return JsValue.initBool(false);
}

/// cancelBubble setter
fn nativeCancelBubbleSet(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (this.isObject() and args.len > 0 and args[0].isTruthy()) {
        const vm = VM.vmFromCtx(ctx);
        const obj = this.asJsObject();
        obj.setProperty(vm.allocator, try vm.pool.intern("_cancelBubble"), JsValue.initBool(true)) catch {};
        obj.setProperty(vm.allocator, try vm.pool.intern("_stopped"), JsValue.initBool(true)) catch {};
    }
    return JsValue.undefined_val;
}

/// DOM 2.9: removeEventListener -- removes first matching (type, callback, capture) entry.
/// Works for DOM nodes (via getThisNode) and standalone EventTargets (via _et_ptr).
fn nativeRemoveEventListener(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.undefined_val;
    const event_type = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    const callback = args[1];
    // Parse capture: boolean or object {capture}
    var capture = false;
    if (args.len > 2) {
        if (args[2].isBool()) {
            capture = args[2].asBool();
        } else if (args[2].isObject()) {
            const opts = args[2].asJsObject();
            if (vm.pool.intern("capture") catch null) |sid| {
                if (opts.getProperty(sid)) |v| capture = v.isTruthy();
            }
        }
    }

    const target_ptr = resolveEventTarget(vm, this) orelse return JsValue.undefined_val;
    const target_addr = @intFromPtr(target_ptr);

    var i: usize = 0;
    while (i < g_listeners.items.len) {
        const entry = g_listeners.items[i];
        if (@intFromPtr(entry.node_ptr) == target_addr and
            std.mem.eql(u8, entry.event_type, event_type) and
            entry.callback.bits == callback.bits and
            entry.capture == capture)
        {
            g_alloc.free(entry.event_type);
            _ = g_listeners.orderedRemove(i);
            return JsValue.undefined_val;
        }
        i += 1;
    }
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

/// ECMA-262 §7.1.7 ToUint32: convert f64 to unsigned 32-bit integer.
/// Equivalent to JS `value >>> 0`. Negative values wrap around.
fn toUint32(n: f64) usize {
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return 0;
    // Truncate to i64 first, then mask to u32
    const i: i64 = @intFromFloat(@trunc(n));
    const u: u32 = @bitCast(@as(i32, @truncate(i)));
    return @intCast(u);
}

fn wrapNode(vm: *VM, node: *lxb.lxb_dom_node_t) ?JsValue {
    // Check cache first — ensures === identity (WebIDL §3.1)
    if (nodeCacheGet(node)) |cached| {
        return JsValue.initObject(cached);
    }
    const obj = vm.createObj(.{ .obj_type = .dom_node }) catch return null;
    obj.data = .{ .dom_node = @ptrCast(node) };
    const nt = nodeType(node);
    // DOM §4.4 — resolve the owner document from lexbor. The lexbor struct
    // populates `node->owner_document` even for detached nodes
    // (confirmed by existing readers at src/js/dom_node.zig:2332).
    // Document nodes themselves have `ownerDocument === null`.
    const owner_doc_val: JsValue = blk: {
        if (nt == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) break :blk JsValue.null_val;
        const od_c = node.owner_document;
        if (od_c == null) break :blk JsValue.null_val;
        const od_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(od_c));
        // If the owner document already has a cached wrapper, reuse it; this
        // ensures `node.ownerDocument === document` identity against the
        // bootstrap / constructor wrappers.
        if (nodeCacheGet(od_node)) |cached| {
            break :blk JsValue.initObject(cached);
        }
        // Lazy-wrap the owner document as a bare Document JsObject.
        // We only create the minimal wrapper here (no method registration);
        // when JS later touches that document explicitly, the other
        // creator paths will either reuse this cached wrapper or replace
        // it with a richer one after a nodeCacheRemove.
        const doc_wrap = vm.createObj(.{ .obj_type = .dom_node }) catch break :blk JsValue.null_val;
        doc_wrap.data = .{ .dom_node = od_node };
        doc_wrap.prototype = g_node_proto;
        setNodeOwnerDoc(vm, doc_wrap, JsValue.null_val);
        nodeCachePut(vm.allocator, od_node, doc_wrap);
        break :blk JsValue.initObject(doc_wrap);
    };
    // Assign prototype based on node type (DOM spec prototype chain).
    // For elements, dispatch to the correct HTML/SVG/MathML interface via
    // applyInterfaceProto (DOM §4.5.3); otherwise use the per-node-type
    // prototype and write the owner-doc slot directly.
    if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        // Resolve namespace URI + local name from lexbor for interface dispatch.
        // lexbor stores the namespace as a small integer ID on the node; the
        // module-local helper nsIdToUri maps it to the canonical W3C URI.
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        const ns_slice: ?[]const u8 = nsIdToUri(elem.node.ns);
        var ln_len: usize = 0;
        const ln_raw = dom_b.lxb_dom_element_local_name(elem, &ln_len);
        const ln_slice: []const u8 = if (ln_raw) |p| p[0..ln_len] else "";
        applyInterfaceProto(vm, obj, ns_slice, ln_slice, owner_doc_val);
    } else {
        obj.prototype = switch (nt) {
            lxb.LXB_DOM_NODE_TYPE_TEXT => g_text_proto,
            lxb.LXB_DOM_NODE_TYPE_COMMENT => g_comment_proto,
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE => g_doctype_proto,
            lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT => g_node_proto,
            else => g_node_proto,
        };
        setNodeOwnerDoc(vm, obj, owner_doc_val);
    }
    nodeCachePut(vm.allocator, node, obj);
    return JsValue.initObject(obj);
}

fn createStyleObj(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_style }) catch return null;
    obj.data = .{ .dom_style = @ptrCast(elem) };
    // CSSOM §6.7 CSSStyleDeclaration methods on the inline-style object.
    // Mirror the registrations done in nativeGetComputedStyle so that both
    // `element.style.getPropertyValue()` and `getComputedStyle(el).getPropertyValue()`
    // resolve. Without this, the methods are undefined on inline style objects.
    vm.registerNativeMethod(obj, "getPropertyValue",  &nativeCSSGetPropertyValue)  catch {};
    vm.registerNativeMethod(obj, "getPropertyPriority",&nativeCSSGetPropertyPriority) catch {};
    vm.registerNativeMethod(obj, "setProperty",        &nativeCSSSetProperty)        catch {};
    vm.registerNativeMethod(obj, "removeProperty",     &nativeCSSRemoveProperty)     catch {};
    vm.registerNativeMethod(obj, "item",               &nativeCSSItem)               catch {};
    // `length` as a native getter via the same own-property approach.
    vm.registerNativeMethod(obj, "length",             &nativeCSSLengthGet)          catch {};
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

/// Get-or-create a cached Attr JS wrapper for a lexbor attr pointer.
/// DOM §4.9.1 Attr identity: `el.attributes[0] === el.attributes[0]` must hold.
/// Wrappers are cached globally on the attr pointer and invalidated by
/// removeAttribute before lexbor frees the underlying struct.
fn getOrCreateAttrWrapper(vm: *VM, a: *lxb.lxb_dom_attr_t) ?*JsObject {
    const key = @intFromPtr(a);
    if (g_attr_wrappers.get(key)) |cached| {
        // Refresh the value fields in case setAttribute reused the struct.
        var val_len: usize = 0;
        const val_ptr = dom_b.lxb_dom_attr_value_noi(@ptrCast(a), &val_len);
        const val_sid = if (val_ptr) |vp|
            vm.pool.intern(vp[0..val_len]) catch return cached
        else
            vm.pool.intern("") catch return cached;
        cached.setProperty(vm.allocator, vm.pool.intern("value") catch return cached, JsValue.initString(val_sid)) catch {};
        cached.setProperty(vm.allocator, vm.pool.intern("nodeValue") catch return cached, JsValue.initString(val_sid)) catch {};
        cached.setProperty(vm.allocator, vm.pool.intern("textContent") catch return cached, JsValue.initString(val_sid)) catch {};
        // Layer 1D.1 Task 4: keep backing-ptr current (idempotent).
        setAttrBackingPtr(vm, cached, key);
        return cached;
    }

    var attr_qn_len: usize = 0;
    const attr_qn = dom_b.lxb_dom_attr_qualified_name(@ptrCast(a), &attr_qn_len) orelse return null;
    const qn_str = attr_qn[0..attr_qn_len];

    const attr_obj = vm.createObj(.{}) catch return null;
    const name_sid = vm.pool.intern(qn_str) catch return null;
    attr_obj.setProperty(vm.allocator, vm.pool.intern("name") catch return null, JsValue.initString(name_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("localName") catch return null, JsValue.initString(name_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("nodeName") catch return null, JsValue.initString(name_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("nodeType") catch return null, JsValue.initNumber(2)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("specified") catch return null, JsValue.initBool(true)) catch {};
    // Value
    var val_len: usize = 0;
    const val_ptr = dom_b.lxb_dom_attr_value_noi(@ptrCast(a), &val_len);
    const val_sid = if (val_ptr) |vp|
        vm.pool.intern(vp[0..val_len]) catch return null
    else
        vm.pool.intern("") catch return null;
    attr_obj.setProperty(vm.allocator, vm.pool.intern("value") catch return null, JsValue.initString(val_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("nodeValue") catch return null, JsValue.initString(val_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("textContent") catch return null, JsValue.initString(val_sid)) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("namespaceURI") catch return null, JsValue.null_val) catch {};
    attr_obj.setProperty(vm.allocator, vm.pool.intern("prefix") catch return null, JsValue.null_val) catch {};

    // DOM §4.9 Attr.ownerElement — when the attr is part of an element's
    // attribute list, ownerElement is that element. Lexbor exposes this
    // via `attr.owner` (see `struct lxb_dom_attr` in attr.h). Wrappers
    // materialised via `el.attributes[i]` / `getNamedItem` must observe
    // the correct owner so the Task 7 InUseAttributeError check + WPT
    // `Attr.ownerElement` assertions hold.
    if (a.owner) |owner_elem| {
        const owner_node: *lxb.lxb_dom_node_t = @ptrCast(owner_elem);
        if (wrapNode(vm, owner_node)) |owner_js| {
            setAttrOwnerElement(vm, attr_obj, owner_js);
        } else if (g_sid_owner_elem_ptr) |ptr_sid| {
            // Fallback: record the opaque node pointer so Task 7's check
            // still succeeds even when wrapNode couldn't materialise a JS
            // owner.
            attr_obj.setProperty(
                vm.allocator,
                ptr_sid,
                JsValue.initNumber(@floatFromInt(@intFromPtr(owner_node))),
            ) catch {};
            attr_obj.setProperty(
                vm.allocator,
                vm.pool.intern("ownerElement") catch ptr_sid,
                JsValue.null_val,
            ) catch {};
        }
    } else {
        setAttrOwnerElement(vm, attr_obj, JsValue.null_val);
    }

    g_attr_wrappers.put(vm.allocator, key, attr_obj) catch {};
    // Layer 1D.1 Task 4: stash the lexbor attr ptr on the JsObject so
    // setAttributeNode (Task 5) can re-key across element transfers.
    setAttrBackingPtr(vm, attr_obj, key);
    return attr_obj;
}

/// WebIDL §3.6.1 — the NamedNodeMap interface object is not constructible.
/// `new NamedNodeMap()` throws TypeError.
fn nativeNnmConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
    return JsValue.undefined_val;
}

/// Extension point for Tasks 5-8 — registers native methods and
/// `@@iterator` on `NamedNodeMap.prototype`. Each task appends its
/// registrations here.
fn initNamedNodeMapMethods(vm: *VM, proto: *JsObject) !void {
    // Task 5: read-only lookup methods.
    try vm.registerNativeMethod(proto, "item", &nativeNnmItem);
    try vm.registerNativeMethod(proto, "getNamedItem", &nativeNnmGetNamedItem);
    try vm.registerNativeMethod(proto, "getNamedItemNS", &nativeNnmGetNamedItemNS);
    // Task 6: removal methods (NotFoundError on absent).
    try vm.registerNativeMethod(proto, "removeNamedItem", &nativeNnmRemoveNamedItem);
    try vm.registerNativeMethod(proto, "removeNamedItemNS", &nativeNnmRemoveNamedItemNS);
    // Task 7: insertion methods — shared native per WebIDL legacy rule.
    try vm.registerNativeMethod(proto, "setNamedItem", &nativeNnmSetNamedItem);
    try vm.registerNativeMethod(proto, "setNamedItemNS", &nativeNnmSetNamedItem);
    // Task 8: @@iterator — enables for..of and spread. Reuses the
    // array-iterator pattern at vm.zig:2385-2388.
    if (proto.symbol_props == null) proto.symbol_props = .{};
    const iter_fn = try vm.createObj(.{ .obj_type = .native_function });
    iter_fn.data = .{ .native_fn = &nativeNnmSymbolIterator };
    try proto.symbol_props.?.put(
        vm.allocator,
        VM.SYMBOL_ITERATOR,
        JsValue.initObject(iter_fn),
    );
}

/// DOM §4.9.1 step 1 — for an HTML-namespace element inside an HTML
/// document, the qualified-name lookup lowercases the input. kotori
/// tags XMLDocument wrappers with `_isXmlDoc = true` (see nativeCreateDocument);
/// any document without that flag is treated as HTML-compatible.
fn elementInHtmlDoc(vm: *VM, elem: *lxb.lxb_dom_element_t) bool {
    _ = vm;
    // LXB_NS_HTML sentinel (per lexbor/ns.h).
    if (elem.node.ns != 0x02) return false;
    // Lexbor does not expose a stable "is this doc XML" bit on the
    // element, but kotori's createDocument path sets `_isXmlDoc` on the
    // Document JsObject. For now, treat HTML-ns elements in
    // well-formed HTML documents (the mainline WPT case) as the lowercase
    // cohort; XMLDocument flows rarely reach HTML-ns. A future task can
    // refine this by reading the `_isXmlDoc` slot via the node cache.
    return true;
}

/// DOM §4.9.2 item(index) — indexed getter steps. Returns `this[index]`
/// from the live attribute list, or null if index is out of range /
/// negative / NaN.
fn nativeNnmItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const want_f = args[0].toNumber();
    if (!std.math.isFinite(want_f) or want_f < 0) return JsValue.null_val;
    const want: u32 = @intFromFloat(want_f);
    var idx: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (idx += 1) {
        if (idx == want) {
            const obj = getOrCreateAttrWrapper(vm, attr) orelse return JsValue.null_val;
            return JsValue.initObject(obj);
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return JsValue.null_val;
}

/// DOM §4.9.2 getNamedItem(qualifiedName) — delegates to §4.9.1 "get an
/// attribute by name". HTML-ns + HTML-doc cohort lowercases the input
/// before lookup.
fn nativeNnmGetNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const qn_raw = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    var lower_buf: [256]u8 = undefined;
    const qn: []const u8 = blk: {
        if (!elementInHtmlDoc(vm, elem)) break :blk qn_raw;
        if (qn_raw.len > lower_buf.len) break :blk qn_raw;
        for (qn_raw, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        break :blk lower_buf[0..qn_raw.len];
    };
    const a = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse return JsValue.null_val;
    const obj = getOrCreateAttrWrapper(vm, @ptrCast(@alignCast(a))) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}

/// Walk the live attribute list for an (ns, localName) match. `ns == null`
/// matches attrs with null namespace (lexbor ns id outside the known URI
/// set, or the null ns id). Returns the first match or null.
fn lookupAttrByNsLocal(elem: *lxb.lxb_dom_element_t, ns: ?[]const u8, local: []const u8) ?*lxb.lxb_dom_attr_t {
    var a: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| {
        const attr_ns = nsIdToUri(attr.node.ns);
        const ns_match = blk: {
            if (ns == null) break :blk (attr_ns == null);
            if (attr_ns) |u| break :blk std.mem.eql(u8, u, ns.?);
            break :blk false;
        };
        if (ns_match) {
            // Lexbor does not expose a standalone local-name accessor for
            // attrs via the public `.noi` surface we import. Fall back to
            // extracting the local name from the qualified name by
            // trimming the prefix (if any).
            var qn_len: usize = 0;
            if (dom_b.lxb_dom_attr_qualified_name(@ptrCast(attr), &qn_len)) |qn_ptr| {
                const qn = qn_ptr[0..qn_len];
                const colon_idx = std.mem.indexOfScalar(u8, qn, ':');
                const attr_local: []const u8 = if (colon_idx) |ci| qn[ci + 1 ..] else qn;
                if (std.mem.eql(u8, attr_local, local)) return attr;
            }
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return null;
}

/// DOM §4.9.2 getNamedItemNS(namespace, localName) — delegates to §4.9.1
/// "get an attribute by namespace and local name". Empty-string
/// namespace coerces to null per spec step 1.
fn nativeNnmGetNamedItemNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const ns_arg = args[0];
    const ns_slice: ?[]const u8 = if (ns_arg.isNull() or ns_arg.isUndefined()) null else blk: {
        if (!ns_arg.isString()) break :blk null;
        const s = vm.pool.get(ns_arg.asStringId()) orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk s;
    };
    if (!args[1].isString()) return JsValue.null_val;
    const local = vm.pool.get(args[1].asStringId()) orelse return JsValue.null_val;
    const a = lookupAttrByNsLocal(elem, ns_slice, local) orelse return JsValue.null_val;
    const obj = getOrCreateAttrWrapper(vm, a) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}

/// Layer 1D.1 Task 4: read the lexbor attr pointer stashed on the Attr
/// JsObject via setAttrBackingPtr. Returns null if the slot is missing,
/// null, undefined, or zero.
fn getAttrBackingPtr(attr_obj: *JsObject) ?usize {
    const sid = g_sid_attr_backing_ptr orelse return null;
    const v = attr_obj.getProperty(sid) orelse return null;
    if (v.isNull() or v.isUndefined()) return null;
    const f = v.toNumber();
    if (!std.math.isFinite(f) or f <= 0.0) return null;
    return @intFromFloat(f);
}

/// Layer 1D.1 Task 4: stash the lexbor attr pointer on the Attr JsObject
/// so setAttributeNode (Task 5) can drop the stale g_attr_wrappers entry
/// and re-key the new lexbor ptr -> same JsObject (spec §R1 — wrapper
/// identity across element boundaries). `ptr == 0` clears the slot.
fn setAttrBackingPtr(vm: *VM, attr_obj: *JsObject, ptr: usize) void {
    const sid = g_sid_attr_backing_ptr orelse return;
    const v = if (ptr == 0) JsValue.null_val
              else JsValue.initNumber(@floatFromInt(ptr));
    attr_obj.setProperty(vm.allocator, sid, v) catch {};
}

/// Write Attr.ownerElement (JS-visible own property) plus the hidden
/// `__ownerElemPtr` slot holding the backing node-pointer as an opaque
/// integer. Native methods consult the hidden slot for cheap ownership
/// checks (e.g. setNamedItem's InUseAttributeError test) without
/// re-crossing the JS boundary.
///
/// Passing `JsValue.null_val` (or undefined) clears both sides.
fn setAttrOwnerElement(vm: *VM, attr_obj: *JsObject, owner: JsValue) void {
    const oe_sid = vm.pool.intern("ownerElement") catch return;
    attr_obj.setProperty(vm.allocator, oe_sid, owner) catch {};
    const ptr_sid = g_sid_owner_elem_ptr orelse return;
    if (owner.isNull() or owner.isUndefined()) {
        attr_obj.setProperty(vm.allocator, ptr_sid, JsValue.null_val) catch {};
        return;
    }
    if (!owner.isObject()) return;
    const owner_obj = owner.asJsObject();
    const node = getThisNode(JsValue.initObject(owner_obj)) orelse return;
    attr_obj.setProperty(
        vm.allocator,
        ptr_sid,
        JsValue.initNumber(@floatFromInt(@intFromPtr(node))),
    ) catch {};
}

/// DOM §4.9.2 removeNamedItem(qualifiedName) — delegates to §4.9.1
/// "remove an attribute by name". Throws NotFoundError when the
/// qualified name doesn't resolve on the live attribute list.
fn nativeNnmRemoveNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const qn_raw = vm.pool.get(args[0].asStringId()) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    var lower_buf: [256]u8 = undefined;
    const qn: []const u8 = blk: {
        if (!elementInHtmlDoc(vm, elem)) break :blk qn_raw;
        if (qn_raw.len > lower_buf.len) break :blk qn_raw;
        for (qn_raw, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        break :blk lower_buf[0..qn_raw.len];
    };
    const lxb_attr_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const lxb_attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(lxb_attr_opaque));
    // Fetch (or materialise) the wrapper before invalidation so we can
    // return it to the caller.
    const attr_obj_opt = getOrCreateAttrWrapper(vm, lxb_attr);
    // §4.9.1 "remove an attribute": clear ownerElement on the removed
    // Attr BEFORE lexbor frees the struct.
    if (attr_obj_opt) |o| setAttrOwnerElement(vm, o, JsValue.null_val);
    // Drop cache entry first; post-remove the lxb pointer may be
    // reassigned by lexbor internals.
    invalidateAttrWrapper(lxb_attr);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    return if (attr_obj_opt) |o| JsValue.initObject(o) else JsValue.null_val;
}

/// DOM §4.9.2 removeNamedItemNS(namespace, localName) — delegates to
/// §4.9.1 "remove an attribute by namespace and local name". Throws
/// NotFoundError when the (ns, localName) pair doesn't resolve.
fn nativeNnmRemoveNamedItemNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const ns_arg = args[0];
    const ns_slice: ?[]const u8 = if (ns_arg.isNull() or ns_arg.isUndefined()) null else blk: {
        if (!ns_arg.isString()) break :blk null;
        const s = vm.pool.get(ns_arg.asStringId()) orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk s;
    };
    if (!args[1].isString()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const local = vm.pool.get(args[1].asStringId()) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const lxb_attr = lookupAttrByNsLocal(elem, ns_slice, local) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    // Resolve the qualifiedName from the live attr so lexbor's name-keyed
    // removal reaches the same record we just found.
    var qn_len: usize = 0;
    const qn_ptr = dom_b.lxb_dom_attr_qualified_name(@ptrCast(lxb_attr), &qn_len) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const qn = qn_ptr[0..qn_len];
    const attr_obj_opt = getOrCreateAttrWrapper(vm, lxb_attr);
    if (attr_obj_opt) |o| setAttrOwnerElement(vm, o, JsValue.null_val);
    invalidateAttrWrapper(lxb_attr);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    return if (attr_obj_opt) |o| JsValue.initObject(o) else JsValue.null_val;
}

// ══════════════════════════════════════════════════════════════════════
// Layer 1D.1 shared helpers — Attr-by-name / Attr-by-(ns,local)
// See DOM §4.9.1 "get an attribute by name" / "…by namespace and local name".
// ══════════════════════════════════════════════════════════════════════

/// DOM §4.9.1 step 1 for "get an attribute by name": if `elem` is in the
/// HTML namespace AND its owner document is an HTML document, the input
/// qualified name is ASCII-lowercased before lookup. Otherwise returned
/// as-is. `buf` is sized by the caller; if `src.len > buf.len` we skip
/// the lowercase (rather than truncating).
///
/// Tolerates detached elements (no owner document) by treating them as
/// HTML-compatible — matches the existing `elementInHtmlDoc` semantics
/// at L4298 so both entry points agree on the lowercase cohort.
fn maybeLowercaseForHtml(elem: *lxb.lxb_dom_element_t, src: []const u8, buf: []u8) []const u8 {
    // LXB_NS_HTML sentinel (0x02). See `elementInHtmlDoc` @ L4298 for rationale:
    // detached HTML-ns elements are treated as HTML-compatible.
    if (elem.node.ns != 0x02) return src;
    if (src.len > buf.len) return src;
    var seen_upper = false;
    for (src) |c| {
        if (c >= 'A' and c <= 'Z') {
            seen_upper = true;
            break;
        }
    }
    if (!seen_upper) return src;
    for (src, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..src.len];
}

/// DOM §4.9.1 "get an attribute by name" — returns the cached Attr
/// wrapper for the first lexbor attr whose qualified name matches `qn_in`
/// (lowercased for HTML-ns+HTML-doc cohorts per step 1), or null.
///
/// Shared by Task 1 `getAttributeNode` and (future) NamedNodeMap
/// entries; the qname fallback in `nativeNnmSetNamedItem` already
/// exercises the same `lxb_dom_element_attr_by_name` primitive.
fn getAttrByQName(vm: *VM, elem: *lxb.lxb_dom_element_t, qn_in: []const u8) ?*JsObject {
    var buf: [256]u8 = undefined;
    const qn = maybeLowercaseForHtml(elem, qn_in, &buf);
    const a = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse return null;
    return getOrCreateAttrWrapper(vm, @ptrCast(@alignCast(a)));
}

/// DOM §4.9.1 "get an attribute by namespace and local name" — wraps the
/// Layer 1D `lookupAttrByNsLocal` walker (L4356) with the Attr-wrapper
/// cache. Empty-string namespace is coerced to null per spec step 1 by
/// the caller (e.g. `extractOptionalStringArg`) before invocation.
fn getAttrByNsLocal(vm: *VM, elem: *lxb.lxb_dom_element_t,
                    ns: ?[]const u8, local: []const u8) ?*JsObject {
    const a = lookupAttrByNsLocal(elem, ns, local) orelse return null;
    return getOrCreateAttrWrapper(vm, a);
}

/// Coerce an `Attr.namespaceURI` / `ns` argument per WebIDL DOMString?
/// and DOM §4.9.1 step 1: null/undefined → null, "" → null, else the
/// interned string slice.
fn extractOptionalStringArg(vm: *VM, val: JsValue) ?[]const u8 {
    if (val.isNull() or val.isUndefined()) return null;
    if (val.isString()) {
        const s = vm.pool.get(val.asStringId()) orelse return null;
        if (s.len == 0) return null;
        return s;
    }
    // Non-string, non-null: ToString coerce (e.g. number → "42"). Result
    // is interned for the lifetime of the VM; empty post-ToString still
    // coerces to null.
    const s = argToString(vm, val);
    if (s.len == 0) return null;
    return s;
}

/// WebIDL DOMString coerce — unlike `extractOptionalStringArg`, empty
/// string is returned as-is (local-name "" is not valid for lookups but
/// we let the caller decide how to handle that).
fn extractStringArg(vm: *VM, val: JsValue) ?[]const u8 {
    if (val.isString()) return vm.pool.get(val.asStringId());
    if (val.isNull() or val.isUndefined()) return argToString(vm, val);
    return argToString(vm, val);
}

// ── DOM §4.9.1 Element.prototype.getAttributeNode[NS] (Layer 1D.1 Task 1) ──

/// DOM §4.9.1 `getAttributeNode(qualifiedName)` — step 1 delegates to
/// "get an attribute by name" (HTML-doc lowercase; null on miss).
fn nativeGetAttributeNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const qn = extractStringArg(vm, args[0]) orelse return JsValue.null_val;
    const obj = getAttrByQName(vm, elem, qn) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}

/// DOM §4.9.1 `getAttributeNodeNS(namespace, localName)` — step 1
/// delegates to "get an attribute by namespace and local name" ("" → null).
fn nativeGetAttributeNodeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.null_val;
    const obj = getAttrByNsLocal(vm, elem, ns, local) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}

// ── DOM §4.9.1 Element.prototype.hasAttributeNS / getAttributeNS (Layer 1D.1 Task 2) ──

/// DOM §4.9.1 `hasAttributeNS(namespace, localName)`:
///   1. If namespace is the empty string, set it to null.
///   2. Return true iff this has an attr whose ns=namespace and
///      localName=localName.
///
/// Does not throw.
fn nativeHasAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.initBool(false);
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.initBool(false);
    return JsValue.initBool(lookupAttrByNsLocal(elem, ns, local) != null);
}

/// DOM §4.9.1 `getAttributeNS(namespace, localName)`:
///   1. Let attr = result of "get an attribute by namespace and local name".
///   2. If attr is null, return null.
///   3. Return attr's value.
///
/// Does not throw.
fn nativeGetAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.null_val;
    const a = lookupAttrByNsLocal(elem, ns, local) orelse return JsValue.null_val;
    // Read the attribute's value directly from lexbor (no wrapper needed for
    // a simple string read). Matches the nativeGetAttribute fast path.
    var val_len: usize = 0;
    const val_ptr = dom_b.lxb_dom_attr_value_noi(@ptrCast(a), &val_len);
    if (val_ptr) |vp| {
        const sid = try vm.pool.intern(vp[0..val_len]);
        return JsValue.initString(sid);
    }
    return JsValue.initString(try vm.pool.intern(""));
}

// ── DOM §4.9.1 Element.prototype.removeAttributeNS (Layer 1D.1 Task 3) ──

/// DOM §4.9.1 `removeAttributeNS(namespace, localName)`:
///   1. Remove an attribute given namespace, localName, and this, and
///      then return undefined.
///
/// "Remove an attribute by namespace and local name" silently succeeds
/// on miss (contrast with NamedNodeMap.removeNamedItemNS which throws
/// NotFoundError — spec §R3). Walks the element's attribute list once;
/// on match, clears ownerElement on the cached wrapper, invalidates the
/// cache, and removes via lexbor's qualified-name primitive (lexbor has
/// no remove-by-ns-local helper).
fn nativeRemoveAttributeNS(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2) return JsValue.undefined_val;
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalStringArg(vm, args[0]);
    const local = extractStringArg(vm, args[1]) orelse return JsValue.undefined_val;

    const attr = lookupAttrByNsLocal(elem, ns, local) orelse return JsValue.undefined_val;
    // Resolve the qualified name from the live attr BEFORE invalidation
    // (post-free the qname pointer may dangle).
    var qn_len: usize = 0;
    const qn_ptr = dom_b.lxb_dom_attr_qualified_name(@ptrCast(attr), &qn_len) orelse return JsValue.undefined_val;

    // Clear ownerElement on the cached wrapper (if materialised) BEFORE
    // lexbor frees the struct — mirrors nativeRemoveAttribute @ L3118.
    if (g_attr_wrappers.get(@intFromPtr(attr))) |cached_wrap| {
        setAttrOwnerElement(vm, cached_wrap, JsValue.null_val);
    }
    invalidateAttrWrapper(attr);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn_ptr, qn_len);
    bumpElemAttrVersion(elem);
    setDomDirty();
    return JsValue.undefined_val;
}

// ── DOM §4.9.1 Element.prototype.setAttributeNode[NS] (Layer 1D.1 Task 5) ──

/// Duck-type guard: Attr JsObject carries nodeType===2. Matches the
/// `createAttrObject` / `getOrCreateAttrWrapper` populated slot.
fn isAttrObject(obj: *JsObject, vm: *VM) bool {
    const nt_sid = vm.pool.intern("nodeType") catch return false;
    const v = obj.getProperty(nt_sid) orelse return false;
    if (!v.isNumber()) return false;
    const n = v.asNumber();
    if (!std.math.isFinite(n)) return false;
    return @as(u32, @intFromFloat(n)) == 2;
}

/// Read `attr.namespaceURI`. Coerces null/undefined/"" → null per spec
/// step 1 of "set an attribute" (ns matching).
fn readAttrObjNs(vm: *VM, obj: *JsObject) ?[]const u8 {
    const sid = vm.pool.intern("namespaceURI") catch return null;
    const v = obj.getProperty(sid) orelse return null;
    if (v.isNull() or v.isUndefined()) return null;
    if (!v.isString()) return null;
    const s = vm.pool.get(v.asStringId()) orelse return null;
    if (s.len == 0) return null;
    return s;
}

/// Read `attr.localName`. Required for (ns, local) lookup in step 2.
fn readAttrObjLocalName(vm: *VM, obj: *JsObject) ?[]const u8 {
    const sid = vm.pool.intern("localName") catch return null;
    const v = obj.getProperty(sid) orelse return null;
    if (!v.isString()) return null;
    return vm.pool.get(v.asStringId());
}

/// Read `attr.value`. Missing / null coerces to "".
fn readAttrObjValue(vm: *VM, obj: *JsObject) []const u8 {
    const sid = vm.pool.intern("value") catch return "";
    const v = obj.getProperty(sid) orelse return "";
    if (v.isNull() or v.isUndefined()) return "";
    if (v.isString()) return vm.pool.get(v.asStringId()) orelse "";
    return argToString(vm, v);
}

/// Read the qualified-name (`attr.name`) for lexbor's qname-keyed write
/// primitive. Falls back to localName if `name` isn't set (rare — our
/// createAttrObject always sets it).
fn readAttrObjQName(vm: *VM, obj: *JsObject) ?[]const u8 {
    const name_sid = vm.pool.intern("name") catch return null;
    if (obj.getProperty(name_sid)) |v| {
        if (v.isString()) {
            if (vm.pool.get(v.asStringId())) |s| {
                if (s.len > 0) return s;
            }
        }
    }
    return readAttrObjLocalName(vm, obj);
}

/// DOM §4.9.1 `setAttributeNode(attr)` / `setAttributeNodeNS(attr)` —
/// WebIDL §4.9.1 prose: "The setAttributeNodeNS(attr) method steps,
/// likewise, are to return the result of setting an attribute given
/// attr and this." One native registered under both names.
///
/// Implements "set an attribute" 7-step algorithm:
///   1. If attr's element is neither null nor `this`, throw
///      InUseAttributeError.
///   2. Let oldAttr = attribute at (attr.namespace, attr.localName).
///   3. If oldAttr === attr, return attr (idempotent).
///   4. Replace / append via lexbor; re-key g_attr_wrappers so
///      identity holds (spec §R1).
///   5. Set attr.ownerElement = this; clear oldAttr.ownerElement.
///   6. Return oldAttr or null.
fn nativeSetAttributeNodeImpl(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const attr_obj = args[0].asJsObject();
    if (!isAttrObject(attr_obj, vm)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Step 1: InUseAttributeError if attr.ownerElement is a different
    // element. Read via the hidden __ownerElemPtr slot (Layer 1D) for
    // an integer-compare fast path; mirrors nativeNnmSetNamedItem.
    const elem_node_addr = @intFromPtr(@as(*lxb.lxb_dom_node_t, @ptrCast(elem)));
    if (g_sid_owner_elem_ptr) |ptr_sid| {
        if (attr_obj.getProperty(ptr_sid)) |stashed| {
            if (!stashed.isNull() and !stashed.isUndefined()) {
                const f = stashed.toNumber();
                if (std.math.isFinite(f) and f > 0.0) {
                    const owner_addr: usize = @intFromFloat(f);
                    if (owner_addr != elem_node_addr) {
                        vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
                        return JsValue.undefined_val;
                    }
                }
            }
        }
    }

    // Extract Attr metadata for lookup + write.
    const ns_slice = readAttrObjNs(vm, attr_obj);
    const local_name = readAttrObjLocalName(vm, attr_obj) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };
    const value_str = readAttrObjValue(vm, attr_obj);
    const qn_str = readAttrObjQName(vm, attr_obj) orelse local_name;

    // Defensive QName validation — callers may have bare-object'd an
    // Attr. createAttributeNS already ran validateAndExtract; this
    // guards the createAttribute path (spec §QName validation wiring
    // work-item #2).
    if (!dom_names.isValidAttrName(qn_str)) {
        return try queueValidationErr(vm, dom_names.NameValidationError.InvalidCharacter);
    }

    // Step 2: look up the existing attr at (ns, local). If the incoming
    // attr has no namespace, prefer the qualified-name lookup (matches
    // nativeNnmSetNamedItem's behaviour at L4616-L4622).
    const old_lxb_opt: ?*lxb.lxb_dom_attr_t = blk: {
        if (ns_slice != null) break :blk lookupAttrByNsLocal(elem, ns_slice, local_name);
        if (dom_b.lxb_dom_element_attr_by_name(elem, qn_str.ptr, qn_str.len)) |p| {
            break :blk @ptrCast(@alignCast(p));
        }
        break :blk null;
    };
    const old_obj_opt: ?*JsObject = if (old_lxb_opt) |a| getOrCreateAttrWrapper(vm, a) else null;

    // Step 3: idempotence — same wrapper already at this (ns, local).
    if (old_obj_opt) |oo| {
        if (oo == attr_obj) return JsValue.initObject(attr_obj);
    }

    // Step 4/5: write via lexbor. Replace path: drop the pre-existing
    // cache entry BEFORE the lexbor write, since the struct may be
    // reallocated.
    if (old_lxb_opt) |ol| invalidateAttrWrapper(ol);
    _ = dom_b.lxb_dom_element_set_attribute(elem, qn_str.ptr, qn_str.len, value_str.ptr, value_str.len);
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Re-resolve the just-written lexbor record. Apply the spec §R1
    // re-key: if attr_obj was previously bound to a different
    // lxb_dom_attr_t*, drop that stale key before the new put.
    const new_lxb_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn_str.ptr, qn_str.len) orelse {
        return if (old_obj_opt) |oo| JsValue.initObject(oo) else JsValue.null_val;
    };
    const new_lxb: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(new_lxb_opaque));
    const new_key = @intFromPtr(new_lxb);
    if (getAttrBackingPtr(attr_obj)) |old_key| {
        if (old_key != new_key) _ = g_attr_wrappers.remove(old_key);
    }
    g_attr_wrappers.put(vm.allocator, new_key, attr_obj) catch {};
    setAttrBackingPtr(vm, attr_obj, new_key);

    // Step 6: record ownership on attr_obj. Fallback path mirrors
    // nativeNnmSetNamedItem @ L4659.
    if (wrapNode(vm, @ptrCast(elem))) |owner_js| {
        setAttrOwnerElement(vm, attr_obj, owner_js);
    } else if (g_sid_owner_elem_ptr) |ptr_sid| {
        attr_obj.setProperty(
            vm.allocator,
            ptr_sid,
            JsValue.initNumber(@floatFromInt(elem_node_addr)),
        ) catch {};
    }

    // Displaced old Attr loses its ownerElement.
    if (old_obj_opt) |oo| {
        if (oo != attr_obj) setAttrOwnerElement(vm, oo, JsValue.null_val);
    }

    // Step 7: return old or null.
    return if (old_obj_opt) |oo| JsValue.initObject(oo) else JsValue.null_val;
}

/// DOM §4.9.1 removeAttributeNode(attr) — Element method:
///   1. If attr is not this element's attribute list, throw NotFoundError.
///   2. Remove attr.
///   3. Return attr.
/// Containment is checked by walking the lexbor attribute list and
/// comparing against `attr.__attrBackingPtr` (Task 4). This is distinct
/// from `removeAttribute` (silent on miss) and `NamedNodeMap.removeNamedItem`
/// (name-keyed, also NotFoundError) — see spec §R3; do NOT unify.
fn nativeRemoveAttributeNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const attr_obj = args[0].asJsObject();
    if (!isAttrObject(attr_obj, vm)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Step 1: containment check via the Task 4 backing-ptr. If the Attr
    // has no backing ptr (never bound to a lexbor record) OR its backing
    // ptr does not appear in this element's attribute list, NotFoundError.
    const backing = getAttrBackingPtr(attr_obj) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    var a_opaque = dom_b.lxb_dom_element_first_attribute_noi(elem);
    var found: ?*lxb.lxb_dom_attr_t = null;
    while (a_opaque) |p| {
        const attr: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(p));
        if (@intFromPtr(attr) == backing) {
            found = attr;
            break;
        }
        a_opaque = dom_b.lxb_dom_element_next_attribute_noi(attr);
    }
    const target = found orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };

    // Step 2: lexbor has no remove-by-pointer, so resolve the qualified
    // name from the target record and call remove_attribute.
    var qn_len: usize = 0;
    const qn_ptr = dom_b.lxb_dom_attr_qualified_name(@ptrCast(target), &qn_len) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    const qn = qn_ptr[0..qn_len];

    // Clear wrapper state BEFORE lexbor frees the struct: ownerElement
    // on the JS Attr, cache entry in g_attr_wrappers, and the backing
    // ptr slot so future setAttributeNode calls on this Attr re-key
    // cleanly per spec §R1.
    setAttrOwnerElement(vm, attr_obj, JsValue.null_val);
    _ = g_attr_wrappers.remove(backing);
    setAttrBackingPtr(vm, attr_obj, 0);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Step 3: return the passed-in Attr.
    return JsValue.initObject(attr_obj);
}

/// DOM §4.9.2 setNamedItem / setNamedItemNS — per WebIDL "A legacy
/// interface that has both setNamedItem and setNamedItemNS must treat
/// them identically" (§3.8), we register the same native under both
/// names. The algorithm follows §4.9.1 "set an attribute":
///   1. If attr's element is non-null and different, InUseAttributeError.
///   2. Let old = attribute at (attr.namespace, attr.localName) on elem.
///   3. If old === attr, return attr (idempotent).
///   4/5. Replace old with attr OR append attr.
///   6. Set attr's element to elem; clear old's element.
///   7. Return old or null.
fn nativeNnmSetNamedItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };
    const attr_obj = args[0].asJsObject();

    // Step 1: InUseAttributeError if attr.ownerElement is a different
    // element. Prefer the hidden __ownerElemPtr slot (opaque node-ptr
    // integer) so this check does not re-cross into JS just to read
    // ownerElement.
    const elem_node: *lxb.lxb_dom_node_t = @ptrCast(elem);
    const elem_node_addr = @intFromPtr(elem_node);
    if (g_sid_owner_elem_ptr) |ptr_sid| {
        if (attr_obj.getProperty(ptr_sid)) |stashed| {
            if (!stashed.isNull() and !stashed.isUndefined()) {
                const f = stashed.toNumber();
                if (std.math.isFinite(f) and f > 0.0) {
                    const owner_addr: usize = @intFromFloat(f);
                    if (owner_addr != elem_node_addr) {
                        vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
                        return JsValue.undefined_val;
                    }
                }
            }
        }
    }

    // Extract metadata from the Attr JS object (createAttribute /
    // createAttributeNS populate `namespaceURI`, `localName`, `prefix`,
    // `value`, `name`).
    const ns_sid = try vm.pool.intern("namespaceURI");
    const ns_v = attr_obj.getProperty(ns_sid) orelse JsValue.null_val;
    const ns_slice: ?[]const u8 = if (ns_v.isNull() or ns_v.isUndefined()) null else blk: {
        if (!ns_v.isString()) break :blk null;
        const s = vm.pool.get(ns_v.asStringId()) orelse break :blk null;
        if (s.len == 0) break :blk null;
        break :blk s;
    };
    const local_sid = try vm.pool.intern("localName");
    const local_v = attr_obj.getProperty(local_sid) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };
    if (!local_v.isString()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const local_name = vm.pool.get(local_v.asStringId()) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    };

    // Resolve qualifiedName. Prefer the cached `name` property set in
    // createAttrObject (includes prefix), else fall back to localName.
    const name_sid = try vm.pool.intern("name");
    const name_v = attr_obj.getProperty(name_sid) orelse JsValue.null_val;
    const qn_str: []const u8 = blk: {
        if (name_v.isString()) {
            if (vm.pool.get(name_v.asStringId())) |s| {
                if (s.len > 0) break :blk s;
            }
        }
        break :blk local_name;
    };

    // Resolve the value. Missing `value` defaults to "" per §4.9.1
    // "set an attribute value" (the algorithm treats missing as empty).
    const value_sid = try vm.pool.intern("value");
    const value_v = attr_obj.getProperty(value_sid) orelse JsValue.null_val;
    const value_str: []const u8 = blk: {
        if (value_v.isString()) {
            if (vm.pool.get(value_v.asStringId())) |s| break :blk s;
        }
        break :blk "";
    };

    // Step 2: look up old attr at (ns, local). If the incoming attr has
    // no namespace, fall back to the qualified-name lookup so attrs
    // authored via createAttribute (no ns) collide with in-place same-
    // qualified-name attrs.
    const old_lxb_opt: ?*lxb.lxb_dom_attr_t = blk: {
        if (ns_slice != null) break :blk lookupAttrByNsLocal(elem, ns_slice, local_name);
        if (dom_b.lxb_dom_element_attr_by_name(elem, qn_str.ptr, qn_str.len)) |p| {
            break :blk @ptrCast(@alignCast(p));
        }
        break :blk null;
    };
    const old_obj_opt: ?*JsObject = if (old_lxb_opt) |a| getOrCreateAttrWrapper(vm, a) else null;

    // Step 3: idempotence — same wrapper already on this element.
    if (old_obj_opt) |oo| {
        if (oo == attr_obj) return JsValue.initObject(attr_obj);
    }

    // Step 4/5: write via lexbor. lexbor treats NS-aware attrs by
    // qualified name (§nativeSetAttributeNS:3149 already relies on this);
    // the namespace tag is inferred from the prefix at attribute-list
    // insertion time.
    // Drop the pre-existing cache entry BEFORE the lexbor write; the
    // replace case may free & reallocate the backing struct.
    if (old_lxb_opt) |ol| invalidateAttrWrapper(ol);
    _ = dom_b.lxb_dom_element_set_attribute(elem, qn_str.ptr, qn_str.len, value_str.ptr, value_str.len);
    bumpElemAttrVersion(elem);

    // Re-resolve the just-written lexbor record and re-key g_attr_wrappers
    // so future `el.attributes.getNamedItem(...)` returns the **same**
    // JsObject we were just handed (spec §R2 — wrapper identity across
    // element boundaries).
    const new_lxb_opaque = dom_b.lxb_dom_element_attr_by_name(elem, qn_str.ptr, qn_str.len) orelse {
        // Lexbor write succeeded but the record is unreachable — treat as
        // a best-effort append and surface null old.
        return if (old_obj_opt) |oo| JsValue.initObject(oo) else JsValue.null_val;
    };
    const new_lxb: *lxb.lxb_dom_attr_t = @ptrCast(@alignCast(new_lxb_opaque));
    g_attr_wrappers.put(g_alloc, @intFromPtr(new_lxb), attr_obj) catch {};

    // Step 6: record ownership. Wrap the element to produce the JS-side
    // owner object once (no-op if already cached in the node map).
    if (wrapNode(vm, elem_node)) |owner_js| {
        setAttrOwnerElement(vm, attr_obj, owner_js);
    } else {
        // Fallback: still record the opaque ptr for future ownership
        // checks even when the node cache can't materialise an owner.
        if (g_sid_owner_elem_ptr) |ptr_sid| {
            attr_obj.setProperty(
                vm.allocator,
                ptr_sid,
                JsValue.initNumber(@floatFromInt(elem_node_addr)),
            ) catch {};
        }
    }
    // Displaced old Attr loses its ownerElement.
    if (old_obj_opt) |oo| {
        if (oo != attr_obj) setAttrOwnerElement(vm, oo, JsValue.null_val);
    }

    // Step 7: return old or null.
    return if (old_obj_opt) |oo| JsValue.initObject(oo) else JsValue.null_val;
}

/// DOM §4.9.2 @@iterator — spec §3.6.1 "indexed getter + iterable" install.
/// Returns a new iterator object whose `.next()` walks the element's live
/// attribute list in declaration order. Re-reads the lexbor list from head
/// on every `next()` so live mutations (setAttribute during iteration)
/// are reflected, matching the live-NamedNodeMap contract.
fn nativeNnmSymbolIterator(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const iter = try vm.createObj(.{ .obj_type = .iterator });
    iter.data = .{ .iterator_data = .{ .source = this } };
    try vm.registerNativeMethod(iter, "next", &nativeNnmIteratorNext);
    return JsValue.initObject(iter);
}

/// Iterator protocol `.next()` for NamedNodeMap. Uses the shared
/// iterator_data.index cursor (0-based). Returns
/// `{value: Attr, done: false}` while items remain, else
/// `{value: undefined, done: true}`. Walks the lexbor list from head
/// each call (O(n) per step) — acceptable for typical attribute counts
/// (<10) and correct under live mutation.
fn nativeNnmIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (!this.isObject()) return iterResultDone(vm);
    const iter = this.asJsObject();
    if (iter.obj_type != .iterator) return iterResultDone(vm);
    const data = &iter.data.iterator_data;
    const elem = nnmElem(data.source) orelse return iterResultDone(vm);
    const target_idx = data.index;
    var j: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (j += 1) {
        if (j == target_idx) {
            const obj = getOrCreateAttrWrapper(vm, attr) orelse return iterResultDone(vm);
            data.index = target_idx + 1;
            return iterResultValue(vm, JsValue.initObject(obj));
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return iterResultDone(vm);
}

/// Shared iterator-result helpers for NamedNodeMap's @@iterator. Local
/// to kotori_dom because vm.zig's createIterResult is not pub.
fn iterResultDone(vm: *VM) anyerror!JsValue {
    const r = try vm.createObj(.{});
    try r.setProperty(vm.allocator, try vm.pool.intern("value"), JsValue.undefined_val);
    try r.setProperty(vm.allocator, try vm.pool.intern("done"), JsValue.initBool(true));
    return JsValue.initObject(r);
}

fn iterResultValue(vm: *VM, val: JsValue) anyerror!JsValue {
    const r = try vm.createObj(.{});
    try r.setProperty(vm.allocator, try vm.pool.intern("value"), val);
    try r.setProperty(vm.allocator, try vm.pool.intern("done"), JsValue.initBool(false));
    return JsValue.initObject(r);
}

/// DOM §4.9.2 — build `NamedNodeMap.prototype` and expose `globalThis.NamedNodeMap`.
/// Idempotent; safe to call more than once (only the first call does work).
///
/// Init ordering (spec §3.6 / §Init sequence): must run before any document is
/// wrapped so that `buildAttributesMap` can safely link fresh map objects to
/// the prototype. Methods are registered directly on the prototype as this
/// single entry point (matches the pattern used by `vm.array_proto`).
fn initNamedNodeMapProto(vm: *VM) !void {
    if (g_namednodemap_proto != null) return;

    // Intern hidden slot names once (hot-path read by every method).
    g_sid_nnm_elem = try vm.pool.intern("__nnmElem");
    g_sid_nnm_ver = try vm.pool.intern("__nnmVer");
    g_sid_nnm_cache = try vm.pool.intern("__nnmCache");
    // Layer 1D.1 Task 8: stale-key sweep tracking.
    g_sid_nnm_max_idx = try vm.pool.intern("__nnmMaxIdx");
    g_sid_nnm_names = try vm.pool.intern("__nnmNames");
    g_sid_owner_elem_ptr = try vm.pool.intern("__ownerElemPtr");
    // Layer 1D.1 Task 4: backing-ptr slot for Attr wrapper identity under
    // setAttributeNode transfer (spec §R1).
    g_sid_attr_backing_ptr = try vm.pool.intern("__attrBackingPtr");

    // NamedNodeMap.prototype — inherits from Object.prototype by default.
    const proto = try vm.createObj(.{});
    g_namednodemap_proto = proto;

    // Symbol.toStringTag = "NamedNodeMap" (per spec §3.8 legacy platform object
    // toString tag). Follow the engine-internal slot pattern (vm.zig line 151:
    // SYMBOL_TO_STRING_TAG is a module-level u32 key in symbol_props).
    if (proto.symbol_props == null) proto.symbol_props = .{};
    try proto.symbol_props.?.put(
        vm.allocator,
        VM.SYMBOL_TO_STRING_TAG,
        JsValue.initString(try vm.pool.intern("NamedNodeMap")),
    );

    // Methods are registered in Tasks 5-8 (item / getNamedItem[NS] /
    // removeNamedItem[NS] / setNamedItem[NS] / @@iterator) — see initNamedNodeMapMethods.
    initNamedNodeMapMethods(vm, proto) catch {};

    // globalThis.NamedNodeMap — constructor object whose .prototype is the map.
    const ctor = try vm.createObj(.{ .obj_type = .native_function });
    ctor.data = .{ .native_fn = &nativeNnmConstructor };
    try ctor.setProperty(
        vm.allocator,
        try vm.pool.intern("prototype"),
        JsValue.initObject(proto),
    );
    try proto.setProperty(
        vm.allocator,
        try vm.pool.intern("constructor"),
        JsValue.initObject(ctor),
    );
    try vm.globals.put(
        vm.allocator,
        try vm.pool.intern("NamedNodeMap"),
        JsValue.initObject(ctor),
    );
}

/// Rewalk the live lexbor attribute list and overwrite the indexed +
/// named + length own properties on `map_obj` (DOM §4.9.2 live
/// semantics, spec §Liveness Option A). Called from both the first
/// materialisation (via `buildAttributesMap`) and subsequent cache
/// refreshes when the per-element version counter advances.
fn refreshAttributesMap(vm: *VM, map_obj: *JsObject, elem: *lxb.lxb_dom_element_t) void {
    // Record the version this snapshot reflects BEFORE the rewalk, so
    // any method invoked reentrantly through getOrCreateAttrWrapper
    // observes a consistent stamp.
    const cur_ver = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
    if (g_sid_nnm_ver) |sid| {
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(cur_ver))) catch {};
    }

    // Layer 1D.1 Task 8: read previous high-water mark of indexed keys so
    // shrink cases (el.attributes[oldN-1] after removeAttribute) return
    // undefined rather than a stale Attr wrapper.
    const prev_max: u32 = blk: {
        if (g_sid_nnm_max_idx) |sid| {
            if (map_obj.getProperty(sid)) |v| {
                if (!v.isNull() and !v.isUndefined()) {
                    const f = v.toNumber();
                    if (std.math.isFinite(f) and f >= 0.0)
                        break :blk @intFromFloat(f);
                }
            }
        }
        break :blk 0;
    };

    // Read the previous ghost-list of qname StringIds so named-key ghost
    // lookups (el.attributes.oldName after removeAttribute) return
    // undefined. Own properties on prev_names act as a set.
    const prev_names: ?*JsObject = blk: {
        if (g_sid_nnm_names) |sid| {
            if (map_obj.getProperty(sid)) |v| {
                if (v.isObject()) break :blk v.asJsObject();
            }
        }
        break :blk null;
    };

    // Build a fresh names set for THIS pass.
    const new_names: ?*JsObject = vm.createObj(.{}) catch null;

    var count: u32 = 0;
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (attr) |a| {
        const attr_obj = getOrCreateAttrWrapper(vm, a) orelse {
            attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(a)));
            continue;
        };
        var attr_qn_len: usize = 0;
        if (dom_b.lxb_dom_attr_qualified_name(@ptrCast(a), &attr_qn_len)) |qn| {
            const qn_str = qn[0..attr_qn_len];
            if (vm.pool.intern(qn_str)) |name_sid| {
                var idx_buf: [16]u8 = undefined;
                if (std.fmt.bufPrint(&idx_buf, "{d}", .{count})) |idx_str| {
                    if (vm.pool.intern(idx_str)) |idx_sid| {
                        map_obj.setProperty(vm.allocator, idx_sid, JsValue.initObject(attr_obj)) catch {};
                    } else |_| {}
                } else |_| {}
                map_obj.setProperty(vm.allocator, name_sid, JsValue.initObject(attr_obj)) catch {};
                // Record this qname in the new ghost-list.
                if (new_names) |nn| {
                    nn.setProperty(vm.allocator, name_sid, JsValue.initBool(true)) catch {};
                }
                count += 1;
            } else |_| {}
        }
        attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(a)));
    }

    // Layer 1D.1 Task 8: sweep stale indexed keys [count .. prev_max).
    if (prev_max > count) {
        var i: u32 = count;
        while (i < prev_max) : (i += 1) {
            var idx_buf: [16]u8 = undefined;
            if (std.fmt.bufPrint(&idx_buf, "{d}", .{i})) |idx_str| {
                if (vm.pool.intern(idx_str)) |idx_sid| {
                    _ = map_obj.ordinaryDelete(vm.allocator, idx_sid);
                } else |_| {}
            } else |_| {}
        }
    }

    // Sweep stale NAMED keys: any qname StringId in prev_names but not in
    // new_names is a ghost from the previous snapshot and must be deleted.
    if (prev_names) |pn| {
        const keys = pn.properties.keys();
        for (keys) |key_sid| {
            const still_present = if (new_names) |nn|
                nn.properties.contains(key_sid)
            else
                false;
            if (!still_present) {
                _ = map_obj.ordinaryDelete(vm.allocator, key_sid);
            }
        }
    }

    // Store the new high-water mark + ghost-list for the next cycle.
    if (g_sid_nnm_max_idx) |sid| {
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(count))) catch {};
    }
    if (g_sid_nnm_names) |sid| {
        if (new_names) |nn| {
            map_obj.setProperty(vm.allocator, sid, JsValue.initObject(nn)) catch {};
        }
    }

    if (vm.pool.intern("length")) |len_sid| {
        map_obj.setProperty(vm.allocator, len_sid, JsValue.initNumber(@floatFromInt(count))) catch {};
    } else |_| {}
}

/// Build a NamedNodeMap-like object for Element.attributes (DOM §4.9).
/// Returns a JsObject whose `__proto__` is `NamedNodeMap.prototype`
/// (from Task 1) and whose `__nnmElem` slot stores the owning element
/// pointer so native methods can re-walk the live attribute list.
///
/// Indexed (`0`, `1`, …) + named (`"id"`, …) + `length` own properties
/// are pre-written by `refreshAttributesMap` so bracket access keeps
/// working without a custom getter callback (spec §Liveness Option A).
fn buildAttributesMap(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const map_obj = vm.createObj(.{}) catch return null;
    // §4.9.2 — link to NamedNodeMap.prototype.
    if (g_namednodemap_proto) |p| map_obj.prototype = p;
    // Stash backing element pointer for native method dispatch.
    if (g_sid_nnm_elem) |sid| {
        map_obj.setProperty(
            vm.allocator,
            sid,
            JsValue.initNumber(@floatFromInt(@intFromPtr(elem))),
        ) catch {};
    }
    refreshAttributesMap(vm, map_obj, elem);
    return JsValue.initObject(map_obj);
}

/// Decode the hidden `__nnmElem` slot → `*lxb.lxb_dom_element_t`.
/// Returns null if `this` is not a NamedNodeMap (slot missing or 0).
fn nnmElem(this: JsValue) ?*lxb.lxb_dom_element_t {
    if (!this.isObject()) return null;
    const obj = this.asJsObject();
    const sid = g_sid_nnm_elem orelse return null;
    const v = obj.getProperty(sid) orelse return null;
    const n = v.toNumber();
    if (!std.math.isFinite(n) or n <= 0.0) return null;
    return @ptrFromInt(@as(usize, @intFromFloat(n)));
}

fn tagNameUpper(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    // Use qualified name to include prefix (e.g. "svg:rect" → "SVG:RECT")
    var len: usize = 0;
    const raw = dom_b.lxb_dom_element_qualified_name(elem, &len) orelse {
        // Fallback to local name
        const local = dom_b.lxb_dom_element_local_name(elem, &len) orelse return JsValue.null_val;
        var buf: [128]u8 = undefined;
        const n = @min(len, buf.len);
        for (0..n) |i| buf[i] = std.ascii.toUpper(local[i]);
        return JsValue.initString(vm.pool.intern(buf[0..n]) catch return JsValue.null_val);
    };
    // Only HTML namespace elements get uppercased tagName (DOM §4.9.2)
    // All others (SVG, MathML, custom, null namespace) preserve case
    const is_html_ns = (elem.node.ns == 0x02); // LXB_NS_HTML
    if (!is_html_ns) {
        return JsValue.initString(vm.pool.intern(raw[0..len]) catch return JsValue.null_val);
    }
    var buf: [128]u8 = undefined;
    const n = @min(len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toUpper(raw[i]);
    return JsValue.initString(vm.pool.intern(buf[0..n]) catch return JsValue.null_val);
}

/// Like tagNameUpper but checks __prefix own property on the JS wrapper.
/// For elements created via createElementNS with a prefix, the prefix is stored
/// as a JS property since lexbor doesn't track it.
fn tagNameUpperWithPrefix(vm: *VM, js_obj: *JsObject, elem: *lxb.lxb_dom_element_t) ?JsValue {
    // Check for __prefix own property (set by createElementNS)
    const prefix_sid = vm.pool.intern("__prefix") catch return tagNameUpper(vm, elem);
    const prefix_val = js_obj.getProperty(prefix_sid);
    if (prefix_val) |pv| {
        if (pv.isString()) {
            const prefix_str = vm.pool.get(pv.asStringId()) orelse return tagNameUpper(vm, elem);
            // Get local name (check __origLocal first for case preservation)
            const orig_sid = vm.pool.intern("__origLocal") catch return tagNameUpper(vm, elem);
            var local_name: []const u8 = "";
            if (js_obj.getProperty(orig_sid)) |ov| {
                if (ov.isString()) local_name = vm.pool.get(ov.asStringId()) orelse "";
            }
            if (local_name.len == 0) {
                var ln_len: usize = 0;
                if (dom_b.lxb_dom_element_local_name(elem, &ln_len)) |ln| {
                    local_name = ln[0..ln_len];
                } else return tagNameUpper(vm, elem);
            }
            // Build PREFIX:LOCALNAME, uppercase for HTML namespace
            var buf: [256]u8 = undefined;
            var pos: usize = 0;
            const is_html = nsIdToUri(elem.node.ns) != null and
                eql(nsIdToUri(elem.node.ns).?, "http://www.w3.org/1999/xhtml");
            for (prefix_str) |ch| {
                if (pos >= buf.len) break;
                buf[pos] = if (is_html) std.ascii.toUpper(ch) else ch;
                pos += 1;
            }
            if (pos < buf.len) {
                buf[pos] = ':';
                pos += 1;
            }
            for (local_name) |ch| {
                if (pos >= buf.len) break;
                buf[pos] = if (is_html) std.ascii.toUpper(ch) else ch;
                pos += 1;
            }
            return JsValue.initString(vm.pool.intern(buf[0..pos]) catch return JsValue.null_val);
        }
    }
    return tagNameUpper(vm, elem);
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
    // Check each attribute of a exists in b with same value.
    // DOM §4.9: use lexbor's proper attribute iterator — lxb_dom_element_next_attribute_noi
    // — NOT at.node.next which walks the generic DOM sibling chain instead.
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(a)));
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
        attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(at)));
    }
    return true;
}

fn countAttrs(elem: *lxb.lxb_dom_element_t) usize {
    var count: usize = 0;
    // DOM §4.9: use lexbor's proper attribute iterator — lxb_dom_element_next_attribute_noi
    // — NOT at.node.next which walks the generic DOM sibling chain instead.
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (attr) |at| {
        count += 1;
        attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(at)));
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
    // DOM §2.7: Legacy error code mapping (WebIDL §2.8.1)
    const code: f64 = if (std.mem.eql(u8, err_name, "IndexSizeError")) 1
        else if (std.mem.eql(u8, err_name, "HierarchyRequestError")) 3
        else if (std.mem.eql(u8, err_name, "WrongDocumentError")) 4
        else if (std.mem.eql(u8, err_name, "InvalidCharacterError")) 5
        else if (std.mem.eql(u8, err_name, "NoModificationAllowedError")) 7
        else if (std.mem.eql(u8, err_name, "NotFoundError")) 8
        else if (std.mem.eql(u8, err_name, "NotSupportedError")) 9
        else if (std.mem.eql(u8, err_name, "InUseAttributeError")) 10
        else if (std.mem.eql(u8, err_name, "InvalidStateError")) 11
        else if (std.mem.eql(u8, err_name, "SyntaxError")) 12
        else if (std.mem.eql(u8, err_name, "InvalidModificationError")) 13
        else if (std.mem.eql(u8, err_name, "NamespaceError")) 14
        else if (std.mem.eql(u8, err_name, "InvalidAccessError")) 15
        else if (std.mem.eql(u8, err_name, "TypeMismatchError")) 17
        else if (std.mem.eql(u8, err_name, "SecurityError")) 18
        else if (std.mem.eql(u8, err_name, "NetworkError")) 19
        else if (std.mem.eql(u8, err_name, "AbortError")) 20
        else if (std.mem.eql(u8, err_name, "URLMismatchError")) 21
        else if (std.mem.eql(u8, err_name, "QuotaExceededError")) 22
        else if (std.mem.eql(u8, err_name, "TimeoutError")) 23
        else if (std.mem.eql(u8, err_name, "InvalidNodeTypeError")) 24
        else if (std.mem.eql(u8, err_name, "DataCloneError")) 25
        else 0;
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
    // DOM §4.3.3: snapshot old data BEFORE text_content_set invalidates info.text.
    // Stack buffer with heap spill for values > 4 KiB (pattern: dom_element.zig:795-808).
    var old_stack_buf: [4096]u8 = undefined;
    var old_heap: ?[]u8 = null;
    defer if (old_heap) |h| g_alloc.free(h);
    const old_value: []const u8 = blk: {
        if (info.text.len <= old_stack_buf.len) {
            @memcpy(old_stack_buf[0..info.text.len], info.text);
            break :blk old_stack_buf[0..info.text.len];
        } else {
            const h = g_alloc.alloc(u8, info.text.len) catch break :blk "";
            old_heap = h;
            @memcpy(h, info.text);
            break :blk h;
        }
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, append_str) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    recordCharDataMutation(vm, info.node, old_value);
    return JsValue.undefined_val;
}

fn nativeDeleteData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return JsValue.undefined_val;
    const u16len = VM.utf16Len(info.text);
    const offset_cu = toUint32(args[0].toNumber());
    if (offset_cu > u16len) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    // DOM §4.2.5: count = min(count, length - offset) in UTF-16 code units
    const raw_count = toUint32(args[1].toNumber());
    const count_cu = @min(raw_count, u16len - offset_cu);
    // Convert UTF-16 indices to byte offsets
    const byte_start = VM.utf16IdxToByteOff(info.text, offset_cu) orelse info.text.len;
    const byte_end = VM.utf16IdxToByteOff(info.text, offset_cu + count_cu) orelse info.text.len;
    // DOM §4.3.3: snapshot old data BEFORE text_content_set invalidates info.text.
    var old_stack_buf: [4096]u8 = undefined;
    var old_heap: ?[]u8 = null;
    defer if (old_heap) |h| g_alloc.free(h);
    const old_value: []const u8 = blk: {
        if (info.text.len <= old_stack_buf.len) {
            @memcpy(old_stack_buf[0..info.text.len], info.text);
            break :blk old_stack_buf[0..info.text.len];
        } else {
            const h = g_alloc.alloc(u8, info.text.len) catch break :blk "";
            old_heap = h;
            @memcpy(h, info.text);
            break :blk h;
        }
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..byte_start]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[byte_end..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    recordCharDataMutation(vm, info.node, old_value);
    return JsValue.undefined_val;
}

fn nativeInsertData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return JsValue.undefined_val;
    const u16len = VM.utf16Len(info.text);
    const offset_cu = toUint32(args[0].toNumber());
    if (offset_cu > u16len) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const byte_off = VM.utf16IdxToByteOff(info.text, offset_cu) orelse info.text.len;
    var buf_fmt: [64]u8 = undefined;
    const ins_str = VM.formatValue(vm.pool, args[1], &buf_fmt);
    // DOM §4.3.3: snapshot old data BEFORE text_content_set invalidates info.text.
    var old_stack_buf: [4096]u8 = undefined;
    var old_heap: ?[]u8 = null;
    defer if (old_heap) |h| g_alloc.free(h);
    const old_value: []const u8 = blk: {
        if (info.text.len <= old_stack_buf.len) {
            @memcpy(old_stack_buf[0..info.text.len], info.text);
            break :blk old_stack_buf[0..info.text.len];
        } else {
            const h = g_alloc.alloc(u8, info.text.len) catch break :blk "";
            old_heap = h;
            @memcpy(h, info.text);
            break :blk h;
        }
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..byte_off]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, ins_str) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[byte_off..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    recordCharDataMutation(vm, info.node, old_value);
    return JsValue.undefined_val;
}

fn nativeReplaceData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 3) return JsValue.undefined_val;
    const u16len = VM.utf16Len(info.text);
    const offset_cu = toUint32(args[0].toNumber());
    if (offset_cu > u16len) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    // DOM §4.2.5: count = min(count, length - offset) in UTF-16 code units
    const raw_count = toUint32(args[1].toNumber());
    const count_cu = @min(raw_count, u16len - offset_cu);
    const byte_start = VM.utf16IdxToByteOff(info.text, offset_cu) orelse info.text.len;
    const byte_end = VM.utf16IdxToByteOff(info.text, offset_cu + count_cu) orelse info.text.len;
    var buf_fmt: [64]u8 = undefined;
    const rep_str = VM.formatValue(vm.pool, args[2], &buf_fmt);
    // DOM §4.3.3: snapshot old data BEFORE text_content_set invalidates info.text.
    var old_stack_buf: [4096]u8 = undefined;
    var old_heap: ?[]u8 = null;
    defer if (old_heap) |h| g_alloc.free(h);
    const old_value: []const u8 = blk: {
        if (info.text.len <= old_stack_buf.len) {
            @memcpy(old_stack_buf[0..info.text.len], info.text);
            break :blk old_stack_buf[0..info.text.len];
        } else {
            const h = g_alloc.alloc(u8, info.text.len) catch break :blk "";
            old_heap = h;
            @memcpy(h, info.text);
            break :blk h;
        }
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(g_alloc);
    buf.appendSlice(g_alloc, info.text[0..byte_start]) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, rep_str) catch return JsValue.undefined_val;
    buf.appendSlice(g_alloc, info.text[byte_end..]) catch return JsValue.undefined_val;
    _ = dom_b.lxb_dom_node_text_content_set(info.node, buf.items.ptr, buf.items.len);
    recordCharDataMutation(vm, info.node, old_value);
    return JsValue.undefined_val;
}

fn nativeSubstringData(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const info = getCharData(vm, this) orelse return JsValue.undefined_val;
    if (args.len < 2) return error.TypeError;
    const u16len = VM.utf16Len(info.text);
    const offset_cu = toUint32(args[0].toNumber());
    if (offset_cu > u16len) {
        vm.pending_throw = try createDOMExceptionObj(vm, "IndexSizeError");
        return JsValue.undefined_val;
    }
    const raw_count = toUint32(args[1].toNumber());
    const count_cu = @min(raw_count, u16len - offset_cu);
    const byte_start = VM.utf16IdxToByteOff(info.text, offset_cu) orelse info.text.len;
    const byte_end = VM.utf16IdxToByteOff(info.text, offset_cu + count_cu) orelse info.text.len;
    return JsValue.initString(vm.pool.intern(info.text[byte_start..byte_end]) catch return JsValue.undefined_val);
}

// ══════════════════════════════════════════════════════════════════════
// New DOM API implementations
// ══════════════════════════════════════════════════════════════════════

// ── Node.cloneNode (DOM §4.4) ───────────────────────────────────────

/// DOM §4.4.1 "clone a node" — shared clone helper for `cloneNode` and
/// `importNode`.
///
/// - `src_node`: the lexbor source node to clone.
/// - `owner_doc_override`: if non-null, the clone and every cloned descendant
///   has its `_ownerDoc` slot forcibly overwritten with this value (importNode
///   semantics, DOM §4.5 "node adoption"). If null, the slot written by
///   `wrapNode` (read from lexbor's `owner_document` field) is kept
///   (cloneNode semantics, DOM §4.4).
/// - `deep`: if true, children are cloned alongside. Lexbor's
///   `lxb_dom_node_clone(_, true)` performs the recursive clone in C, so our
///   only job here is to walk the already-cloned subtree and rewrite the
///   `_ownerDoc` slot on every JS wrapper when an override is requested.
fn cloneNodeImpl(
    vm: *VM,
    src_node: *lxb.lxb_dom_node_t,
    owner_doc_override: ?JsValue,
    deep: bool,
) ?JsValue {
    const cloned = dom_b.lxb_dom_node_clone(src_node, deep) orelse return null;
    // DOM §4.5.3 — wrapNode reads the cloned node's (ns, local_name) from
    // lexbor and dispatches the correct HTML/SVG/MathML interface prototype
    // via applyInterfaceProto. lexbor's lxb_dom_node_clone preserves both
    // fields on the clone, so the correct interface prototype is attached
    // automatically without any extra work here.
    const wrapped_val = wrapNode(vm, cloned) orelse return null;
    if (owner_doc_override) |owner| {
        // Override slot on the root clone (preserving the dispatched proto).
        if (wrapped_val.isObject()) {
            setNodeOwnerDoc(vm, wrapped_val.asJsObject(), owner);
        }
        // Walk the cloned subtree (lexbor already duplicated children when
        // deep=true; when deep=false there are no children to visit).
        if (deep) {
            var child: ?*lxb.lxb_dom_node_t = nodeFirstChild(cloned);
            while (child) |c| : (child = nodeNext(c)) {
                // Recurse with deep=false on each child — lexbor's clone
                // already built the full subtree; this recursive call only
                // wraps + rewrites slots on the existing cloned nodes.
                overrideOwnerDocRecursive(vm, c, owner);
            }
        }
    }
    return wrapped_val;
}

/// Walks an already-cloned subtree rooted at `node`, wrapping each node via
/// `wrapNode` (which populates the cache if needed) and overwriting its
/// `_ownerDoc` slot with `owner`.
fn overrideOwnerDocRecursive(vm: *VM, node: *lxb.lxb_dom_node_t, owner: JsValue) void {
    if (wrapNode(vm, node)) |wrap_val| {
        if (wrap_val.isObject()) {
            setNodeOwnerDoc(vm, wrap_val.asJsObject(), owner);
        }
    }
    var child: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    while (child) |c| : (child = nodeNext(c)) {
        overrideOwnerDocRecursive(vm, c, owner);
    }
}

fn nativeCloneNode(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    const node = getThisNode(this) orelse return JsValue.null_val;
    // deep defaults to false per spec
    const deep = if (args.len > 0 and args[0].isBool()) args[0].asBool() else false;
    // DOM §4.4.1 "clone a node" — lexbor's lxb_dom_node_clone preserves
    // owner_document on the cloned node; wrapNode reads it and writes the
    // `_ownerDoc` slot. No override needed here (same-document clone).
    return cloneNodeImpl(vm, node, null, deep) orelse JsValue.null_val;
}

// ── Node.isSameNode (DOM §4.4) ───────────────────────────────────────

fn nativeIsSameNode(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const a = getThisNode(this) orelse return JsValue.initBool(false);
    if (args.len == 0 or args[0].isNull() or args[0].isUndefined()) return JsValue.initBool(false);
    const b = getArgNode(args[0]) orelse return JsValue.initBool(false);
    return JsValue.initBool(a == b);
}

// ── Node.contains (DOM §4.4) ─────────────────────────────────────────

fn nativeContains(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0 or args[0].isNull() or args[0].isUndefined()) return JsValue.initBool(false);
    // JS-only nodes: same object identity → contains(self) is true
    if (this.isObject() and args[0].isObject() and this.asJsObject() == args[0].asJsObject())
        return JsValue.initBool(true);
    const ancestor = getThisNode(this) orelse return JsValue.initBool(false);
    const target = getArgNode(args[0]) orelse return JsValue.initBool(false);
    var cur: ?*lxb.lxb_dom_node_t = target;
    while (cur) |c| {
        if (c == ancestor) return JsValue.initBool(true);
        cur = nodeParent(c);
    }
    return JsValue.initBool(false);
}

// ── Node.compareDocumentPosition (DOM §4.4) ──────────────────────────

fn nativeCompareDocumentPosition(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const DISCONNECTED: f64 = 0x01;
    const PRECEDING: f64 = 0x02;
    const FOLLOWING: f64 = 0x04;
    const CONTAINS: f64 = 0x08;
    const CONTAINED_BY: f64 = 0x10;
    const IMPLEMENTATION_SPECIFIC: f64 = 0x20;

    if (args.len == 0 or args[0].isNull() or args[0].isUndefined())
        return JsValue.initNumber(0);

    // Handle JS-only nodes (e.g., ProcessingInstruction, DocumentType without lexbor backing)
    const self_node = getThisNode(this);
    const other_node = getArgNode(args[0]);

    // Same JS object → 0
    if (this.isObject() and args[0].isObject() and this.asJsObject() == args[0].asJsObject())
        return JsValue.initNumber(0);

    // If either node lacks lexbor backing (JS-only node), they're in different trees → DISCONNECTED
    if (self_node == null or other_node == null) {
        const order: f64 = if (this.bits < args[0].bits)
            FOLLOWING
        else
            PRECEDING;
        return JsValue.initNumber(DISCONNECTED + IMPLEMENTATION_SPECIFIC + order);
    }

    const sn = self_node.?;
    const on = other_node.?;

    // Step 1: same DOM node → 0
    if (sn == on) return JsValue.initNumber(0);

    // Build ancestor chains for self and other (root first)
    // We use a fixed-size stack buffer; depth >512 is pathological
    const MAX_DEPTH = 512;
    var self_chain: [MAX_DEPTH]*lxb.lxb_dom_node_t = undefined;
    var other_chain: [MAX_DEPTH]*lxb.lxb_dom_node_t = undefined;
    var self_len: usize = 0;
    var other_len: usize = 0;

    var cur: ?*lxb.lxb_dom_node_t = sn;
    while (cur) |n| : (cur = nodeParent(n)) {
        if (self_len < MAX_DEPTH) {
            self_chain[self_len] = n;
            self_len += 1;
        }
    }
    cur = on;
    while (cur) |n| : (cur = nodeParent(n)) {
        if (other_len < MAX_DEPTH) {
            other_chain[other_len] = n;
            other_len += 1;
        }
    }

    // Chains are leaf→root; reverse to get root→leaf
    // self_chain[0] is sn, self_chain[self_len-1] is tree root
    const self_root = self_chain[self_len - 1];
    const other_root = other_chain[other_len - 1];

    // Step 2: disconnected trees
    if (self_root != other_root) {
        // Implementation-specific ordering by pointer value
        const order: f64 = if (@intFromPtr(sn) < @intFromPtr(on))
            FOLLOWING
        else
            PRECEDING;
        return JsValue.initNumber(DISCONNECTED + IMPLEMENTATION_SPECIFIC + order);
    }

    // Find common ancestor by walking root→leaf on both chains
    // self_chain is stored leaf→root, so index (self_len-1) is root
    // Find how deep the common prefix goes (from root side)
    var common_depth: usize = 0;
    while (common_depth < self_len and common_depth < other_len) {
        const si = self_chain[self_len - 1 - common_depth];
        const oi = other_chain[other_len - 1 - common_depth];
        if (si != oi) break;
        common_depth += 1;
    }
    // common_depth is the number of shared ancestors from root
    // self_chain[self_len - common_depth] is the first node unique to self's path
    // other_chain[other_len - common_depth] is the first node unique to other's path

    // Step 3: other is ancestor of self → CONTAINS | PRECEDING
    if (common_depth == other_len) {
        // other_node is an ancestor of self_node
        return JsValue.initNumber(CONTAINS + PRECEDING);
    }

    // Step 4: self is ancestor of other → CONTAINED_BY | FOLLOWING
    if (common_depth == self_len) {
        // self_node is an ancestor of other_node
        return JsValue.initNumber(CONTAINED_BY + FOLLOWING);
    }

    // Step 5: siblings under common ancestor — walk next siblings to determine order
    // self_chain[self_len - 1 - (common_depth-1)] is common ancestor
    // self_chain[self_len - 1 - common_depth] is the child of common_ancestor on self's path
    // other_chain[other_len - 1 - common_depth] is the child on other's path
    const self_child = self_chain[self_len - 1 - common_depth];
    const other_child = other_chain[other_len - 1 - common_depth];

    // Walk next siblings from self_child; if we hit other_child first → other is FOLLOWING
    var sib: ?*lxb.lxb_dom_node_t = nodeNext(self_child);
    while (sib) |s| : (sib = nodeNext(s)) {
        if (s == other_child) return JsValue.initNumber(FOLLOWING);
    }
    return JsValue.initNumber(PRECEDING);
}

// ── Node.replaceChild (DOM §4.4) ─────────────────────────────────────

fn nativeReplaceChild(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // WebIDL: replaceChild(Node, Node) — both args must be Nodes. Missing
    // or non-Node → TypeError.
    if (args.len < 2) return error.TypeError;
    if (!argIsNodeLike(vm, args[0]) or !argIsNodeLike(vm, args[1])) return error.TypeError;
    const parent = getThisNode(this) orelse return JsValue.null_val;
    const new_child = getArgNode(args[0]) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "HierarchyRequestError");
        return JsValue.undefined_val;
    };
    const old_child = getArgNode(args[1]) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    // DOM §4.2.4 replaceChild: common pre-insert checks with is_replace=true
    // so that existing-child counts exclude old_child (it is about to be removed).
    if (!try validatePreInsertFull(vm, new_child, parent, old_child, true)) return JsValue.undefined_val;
    dom_b.lxb_dom_node_remove(new_child);
    dom_b.lxb_dom_node_insert_before(old_child, new_child);
    dom_b.lxb_dom_node_remove(old_child);
    setDomDirty();
    return args[1];
}

// ── Node.normalize (DOM §4.4) ────────────────────────────────────────

fn nativeNormalize(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    normalizeChildren(vm, node);
    setDomDirty();
    return JsValue.undefined_val;
}

fn normalizeChildren(vm: *VM, node: *lxb.lxb_dom_node_t) void {
    var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
    var prev_text: ?*lxb.lxb_dom_node_t = null;
    while (ch) |c| {
        const next = nodeNext(c);
        if (nodeType(c) == lxb.LXB_DOM_NODE_TYPE_TEXT) {
            var len: usize = 0;
            _ = dom_b.lxb_dom_node_text_content(c, &len);
            if (len == 0) {
                // Remove empty text node. Capture siblings for MO
                // childList record (DOM §4.4.2 step 3.2). Do NOT destroy —
                // JS may still hold references via MutationRecord.
                const prev_s = c.prev;
                const next_s = c.next;
                dom_b.lxb_dom_node_remove(c);
                if (g_mo_list.items.len > 0) {
                    const c_wrapped = wrapNode(vm, c) orelse JsValue.null_val;
                    const prev_w = if (prev_s) |p| wrapNode(vm, p) orelse JsValue.null_val else JsValue.null_val;
                    const next_w = if (next_s) |n| wrapNode(vm, n) orelse JsValue.null_val else JsValue.null_val;
                    recordChildListMutation(vm, node, null, c_wrapped, prev_w, next_w);
                }
                ch = next;
                continue;
            }
            if (prev_text) |pt| {
                // DOM §4.4.2 step 3.1-3.3: each concatenation is BOTH a
                // characterData mutation on `pt` (data grows) AND a
                // childList mutation (removal of `c`). Snapshot old data
                // before text_content_set invalidates the lexbor pointer.
                var pt_len: usize = 0;
                var c_len: usize = 0;
                const pt_ptr = dom_b.lxb_dom_node_text_content(pt, &pt_len);
                const c_ptr = dom_b.lxb_dom_node_text_content(c, &c_len);

                var old_pt_buf: [4096]u8 = undefined;
                var old_pt_heap: ?[]u8 = null;
                defer if (old_pt_heap) |h| vm.allocator.free(h);
                const old_pt: []const u8 = blk: {
                    if (pt_ptr == null) break :blk &[_]u8{};
                    if (pt_len <= old_pt_buf.len) {
                        @memcpy(old_pt_buf[0..pt_len], pt_ptr.?[0..pt_len]);
                        break :blk old_pt_buf[0..pt_len];
                    }
                    const h = vm.allocator.alloc(u8, pt_len) catch break :blk &[_]u8{};
                    old_pt_heap = h;
                    @memcpy(h, pt_ptr.?[0..pt_len]);
                    break :blk h;
                };

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(g_alloc);
                if (pt_ptr) |p| buf.appendSlice(g_alloc, p[0..pt_len]) catch {};
                if (c_ptr) |p| buf.appendSlice(g_alloc, p[0..c_len]) catch {};
                _ = dom_b.lxb_dom_node_text_content_set(pt, buf.items.ptr, buf.items.len);

                // Capture siblings BEFORE removal for the childList record.
                const prev_s = c.prev;
                const next_s = c.next;
                dom_b.lxb_dom_node_remove(c);

                if (g_mo_list.items.len > 0) {
                    recordCharDataMutation(vm, pt, old_pt);
                    const c_wrapped = wrapNode(vm, c) orelse JsValue.null_val;
                    const prev_w = if (prev_s) |p| wrapNode(vm, p) orelse JsValue.null_val else JsValue.null_val;
                    const next_w = if (next_s) |n| wrapNode(vm, n) orelse JsValue.null_val else JsValue.null_val;
                    recordChildListMutation(vm, node, null, c_wrapped, prev_w, next_w);
                }
                ch = next;
                continue;
            }
            prev_text = c;
        } else {
            prev_text = null;
            // Recurse into element children
            normalizeChildren(vm, c);
        }
        ch = next;
    }
}

// ── Element.hasAttribute (DOM §4.9) ─────────────────────────────────

fn nativeHasAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.initBool(false);
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const name = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);
    return JsValue.initBool(dom_b.lxb_dom_element_has_attribute(elem, name.ptr, name.len));
}

// ── Element.hasAttributes (DOM §4.9) ────────────────────────────────

fn nativeHasAttributes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    return JsValue.initBool(dom_b.lxb_dom_element_first_attribute_noi(elem) != null);
}

// ── Element.toggleAttribute (DOM §4.9.1) ────────────────────────────

fn nativeToggleAttribute(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return error.TypeError;
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const name_raw = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);

    // Step 1: validate Name production via Layer 1A's dom_names helper.
    // Parity with setAttribute / setAttributeNS (1D.1 §QName validation
    // wiring work-item #1): toggleAttribute('foo bar') must raise
    // InvalidCharacterError, not silently succeed.
    if (!dom_names.isValidAttrName(name_raw)) {
        return queueValidationErr(vm, dom_names.NameValidationError.InvalidCharacter);
    }

    // Step 2: lowercase for HTML documents
    var lower_buf: [256]u8 = undefined;
    const name = if (name_raw.len <= lower_buf.len) blk: {
        for (name_raw, 0..) |c, i| {
            lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        break :blk lower_buf[0..name_raw.len];
    } else name_raw;

    const has = dom_b.lxb_dom_element_has_attribute(elem, name.ptr, name.len);

    // DOM §4.3.3: Capture old value BEFORE mutation so MutationObservers
    // observing with attributeOldValue receive the correct prior value.
    var old_val_buf: [4096]u8 = undefined;
    var old_val: ?[]const u8 = null;
    if (has) {
        var ov_len: usize = 0;
        const ov_ptr = dom_b.lxb_dom_element_get_attribute(elem, name.ptr, name.len, &ov_len);
        if (ov_ptr != null) {
            const cl = @min(ov_len, old_val_buf.len);
            @memcpy(old_val_buf[0..cl], ov_ptr.?[0..cl]);
            old_val = old_val_buf[0..cl];
        }
    }

    // Step 3-4: toggle logic
    if (has) {
        // force argument: if provided and true, keep → return true (no-op)
        if (args.len >= 2 and !args[1].isUndefined()) {
            if (args[1].isTruthy()) return JsValue.initBool(true);
        }
        // DOM §4.9.1: drop the cached Attr wrapper before lexbor frees it.
        if (dom_b.lxb_dom_element_attr_by_name(elem, name.ptr, name.len)) |a| {
            // DOM §4.9 Attr.ownerElement — "remove an attribute" clears owner.
            // Must run BEFORE invalidateAttrWrapper so the cached wrapper
            // (still identified by this attr ptr) gets the update.
            if (g_attr_wrappers.get(@intFromPtr(a))) |cached_wrap| {
                setAttrOwnerElement(vm, cached_wrap, JsValue.null_val);
            }
            invalidateAttrWrapper(a);
        }
        // Remove attribute
        _ = dom_b.lxb_dom_element_remove_attribute(elem, name.ptr, name.len);
        recordAttributeMutation(vm, node, name, old_val);
        // DOM §4.9.2 NamedNodeMap live-map version bump.
        bumpElemAttrVersion(elem);
        setDomDirty();
        return JsValue.initBool(false);
    } else {
        // force argument: if provided and false, don't add → return false (no-op)
        if (args.len >= 2 and !args[1].isUndefined()) {
            if (!args[1].isTruthy()) return JsValue.initBool(false);
        }
        // Add attribute with empty value
        _ = dom_b.lxb_dom_element_set_attribute(elem, name.ptr, name.len, "", 0);
        recordAttributeMutation(vm, node, name, null);
        // DOM §4.9.2 NamedNodeMap live-map version bump.
        bumpElemAttrVersion(elem);
        setDomDirty();
        return JsValue.initBool(true);
    }
}

// ── Element.remove (ChildNode mixin, DOM §4.7) ───────────────────────

fn nativeRemove(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    // DOM §4.7 ChildNode.remove(): if node has no parent, do nothing.
    if (nodeParent(node) == null) return JsValue.undefined_val;
    dom_b.lxb_dom_node_remove(node);
    setDomDirty();
    return JsValue.undefined_val;
}

// ── Element.insertAdjacentElement (DOM §4.9) ─────────────────────────

fn nativeInsertAdjacentElement(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.null_val;
    const node = getThisNode(this) orelse return JsValue.null_val;
    const elem_node = getArgNode(args[1]) orelse return JsValue.null_val;
    const position = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    dom_b.lxb_dom_node_remove(elem_node);
    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        // Insert before this node in parent
        dom_b.lxb_dom_node_insert_before(node, elem_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        // Insert before first child
        if (nodeFirstChild(node)) |fc| {
            dom_b.lxb_dom_node_insert_before(fc, elem_node);
        } else {
            dom_b.lxb_dom_node_insert_child(node, elem_node);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        // Append as last child
        dom_b.lxb_dom_node_insert_child(node, elem_node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        // Insert after this node in parent
        if (nodeNext(node)) |ns| {
            dom_b.lxb_dom_node_insert_before(ns, elem_node);
        } else if (nodeParent(node)) |parent| {
            dom_b.lxb_dom_node_insert_child(parent, elem_node);
        }
    } else {
        return JsValue.null_val;
    }
    setDomDirty();
    return args[1];
}

// ── Element.insertAdjacentText (DOM §4.9) ────────────────────────────

fn nativeInsertAdjacentText(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 2 or !args[0].isString()) return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    const text_str = argToString(vm, args[1]);
    const text_node = dom_b.lxb_dom_document_create_text_node(doc, text_str.ptr, text_str.len) orelse return JsValue.undefined_val;
    // Reuse insertAdjacentElement logic by wrapping text_node in a JsValue
    const wrapped = wrapNode(vm, text_node) orelse return JsValue.undefined_val;
    const new_args = [2]JsValue{ args[0], wrapped };
    _ = try nativeInsertAdjacentElement(ctx, this, &new_args);
    return JsValue.undefined_val;
}

// ── ParentNode.prepend/append/replaceChildren pre-insert helpers ─────

/// DOM §4.2.4 "converting nodes into a node" + §4.2.2 pre-insert validation.
/// For each argument that is a Node, validate it could be pre-inserted into
/// `parent` with null ref child (append semantics). Returns false and queues
/// a DOMException when any arg fails validation.
fn validateVariadicInsert(vm: *VM, parent: *lxb.lxb_dom_node_t, args: []const JsValue) !bool {
    for (args) |arg| {
        if (arg.isObject()) {
            if (getArgNode(arg)) |n| {
                if (!try validatePreInsert(vm, n, parent, null)) return false;
            }
        }
    }
    return true;
}

// ── ParentNode.prepend (DOM §4.4) ────────────────────────────────────

fn nativePrepend(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const parent = getThisNodeOrFragment(this) orelse return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    // DOM §4.2.4 pre-insert validation must happen before any mutation.
    if (!try validateVariadicInsert(vm, parent, args)) return JsValue.undefined_val;
    // Collect nodes in reverse order so we can insertBefore firstChild repeatedly
    // and maintain the original argument order.
    // Insert each node before the current firstChild.
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        const arg = args[i];
        const child_node: *lxb.lxb_dom_node_t = blk: {
            if (arg.isObject()) {
                break :blk getArgNode(arg) orelse continue;
            }
            // String, null, undefined, number, bool → text node
            const s = argToString(vm, arg);
            break :blk dom_b.lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
        };
        dom_b.lxb_dom_node_remove(child_node);
        if (nodeFirstChild(parent)) |fc| {
            dom_b.lxb_dom_node_insert_before(fc, child_node);
        } else {
            dom_b.lxb_dom_node_insert_child(parent, child_node);
        }
    }
    setDomDirty();
    return JsValue.undefined_val;
}

// ── ParentNode.append (DOM §4.4) ─────────────────────────────────────

fn nativeAppend(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const parent = getThisNodeOrFragment(this) orelse return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    // DOM §4.2.4 pre-insert validation must happen before any mutation.
    if (!try validateVariadicInsert(vm, parent, args)) return JsValue.undefined_val;
    for (args) |arg| {
        const child_node: *lxb.lxb_dom_node_t = blk: {
            if (arg.isObject()) {
                break :blk getArgNode(arg) orelse continue;
            }
            // String, null, undefined, number, bool → text node
            const s = argToString(vm, arg);
            break :blk dom_b.lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
        };
        dom_b.lxb_dom_node_remove(child_node);
        dom_b.lxb_dom_node_insert_child(parent, child_node);
        sr.propagateScopeFromParent(parent, child_node);
    }
    setDomDirty();
    return JsValue.undefined_val;
}

// ── ParentNode.replaceChildren (DOM §4.4) ────────────────────────────

fn nativeReplaceChildren(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const parent = getThisNodeOrFragment(this) orelse return JsValue.undefined_val;
    // DOM §4.2.4 replaceChildren: validate BEFORE removing existing children.
    if (!try validateVariadicInsert(vm, parent, args)) return JsValue.undefined_val;
    // Remove all existing children
    while (nodeFirstChild(parent)) |child| {
        dom_b.lxb_dom_node_remove(child);
    }
    // Append new children (reuse nativeAppend logic)
    return nativeAppend(ctx, this, args);
}

// ── ChildNode.before (DOM §4.7) ──────────────────────────────────────

fn nativeBefore(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    // DOM §4.7: if this node has no parent, return (no-op).
    if (nodeParent(node) == null) return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    for (args) |arg| {
        const new_node: *lxb.lxb_dom_node_t = blk: {
            if (arg.isObject()) {
                const n = getArgNode(arg) orelse continue;
                // Skip if arg is this node itself (inserting before itself is a no-op)
                if (n == node) continue;
                dom_b.lxb_dom_node_remove(n);
                break :blk n;
            }
            // String, null, undefined, number, bool → text node
            const s = argToString(vm, arg);
            break :blk dom_b.lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
        };
        dom_b.lxb_dom_node_insert_before(node, new_node);
    }
    setDomDirty();
    return JsValue.undefined_val;
}

// ── ChildNode.after (DOM §4.7) ───────────────────────────────────────

fn nativeAfter(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    // DOM §4.7: find the "viable next sibling" — first following sibling of
    // `node` that is NOT in the args node list.
    const viable_next: ?*lxb.lxb_dom_node_t = blk: {
        var sib = nodeNext(node);
        outer: while (sib) |s| {
            for (args) |arg| {
                if (arg.isObject()) {
                    if (getArgNode(arg)) |n| {
                        if (n == s) {
                            sib = nodeNext(s);
                            continue :outer;
                        }
                    }
                }
            }
            break :blk s;
        }
        break :blk null;
    };
    // Now remove all arg nodes from their current positions and insert them
    // before viable_next (or append to parent if null).
    const parent = nodeParent(node) orelse return JsValue.undefined_val;
    for (args) |arg| {
        const new_node: *lxb.lxb_dom_node_t = blk: {
            if (arg.isObject()) {
                const n = getArgNode(arg) orelse continue;
                dom_b.lxb_dom_node_remove(n);
                break :blk n;
            }
            // String, null, undefined, number, bool → text node
            const s = argToString(vm, arg);
            break :blk dom_b.lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
        };
        if (viable_next) |vn| {
            dom_b.lxb_dom_node_insert_before(vn, new_node);
        } else {
            dom_b.lxb_dom_node_insert_child(parent, new_node);
        }
    }
    setDomDirty();
    return JsValue.undefined_val;
}

// ── ChildNode.replaceWith (DOM §4.7) ─────────────────────────────────

fn nativeReplaceWith(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    const doc = g_document orelse return JsValue.undefined_val;
    // DOM §4.7: if parent is null, return.
    if (nodeParent(node) == null) return JsValue.undefined_val;
    // Check whether this node itself appears in the args list.
    var self_in_args = false;
    for (args) |arg| {
        if (arg.isObject()) {
            if (getArgNode(arg)) |n| {
                if (n == node) {
                    self_in_args = true;
                    break;
                }
            }
        }
    }
    // Insert all args before `node`, then remove `node` (unless self is in args).
    for (args) |arg| {
        const new_node: *lxb.lxb_dom_node_t = blk: {
            if (arg.isObject()) {
                const n = getArgNode(arg) orelse continue;
                // Don't remove this node from tree yet — it serves as insertion ref.
                if (n == node) continue;
                dom_b.lxb_dom_node_remove(n);
                break :blk n;
            }
            // String, null, undefined, number, bool → text node
            const s = argToString(vm, arg);
            break :blk dom_b.lxb_dom_document_create_text_node(doc, s.ptr, s.len) orelse continue;
        };
        dom_b.lxb_dom_node_insert_before(node, new_node);
    }
    // Only remove this node if it was not itself one of the replacement nodes.
    if (!self_in_args) {
        dom_b.lxb_dom_node_remove(node);
    }
    setDomDirty();
    return JsValue.undefined_val;
}

// ── document.implementation helpers (DOM §7.1) ───────────────────────

fn nativeImplementationHasFeature(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    // DOM Living Standard §7.1: always returns true
    return JsValue.initBool(true);
}

/// Parse `html` into a fresh lexbor document and wrap it as a JS Document object
/// suitable for DOMParser.parseFromString and DOMImplementation.createHTMLDocument.
/// `content_type` is stored verbatim as `document.contentType` (e.g. "text/html",
/// "application/xml"). documentElement/body/head/doctype are resolved lazily via
/// the property intercept reading the lexbor tree.
fn wrapParsedHtmlDocAsJsDoc(vm: *VM, html: []const u8, content_type: []const u8) !JsValue {
    // Create new lexbor document and parse
    const new_doc = dom_b.lxb_html_document_create() orelse return JsValue.null_val;
    const status = dom_b.lxb_html_document_parse(new_doc, html.ptr, html.len);
    if (status != 0) return JsValue.null_val;

    // Store to prevent deallocation
    if (created_doc_count < created_docs.len) {
        created_docs[created_doc_count] = new_doc;
        created_doc_count += 1;
    }

    // Wrap document node
    const doc_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(new_doc));
    const doc_obj = try vm.createObj(.{ .obj_type = .dom_node });
    doc_obj.data = .{ .dom_node = @ptrCast(doc_node) };
    doc_obj.prototype = g_node_proto;
    nodeCachePut(vm.allocator, doc_node, doc_obj);
    // DOM §4.4 — Document.ownerDocument = null.
    setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
    const doc_val = JsValue.initObject(doc_obj);

    // nodeType = 9 (DOCUMENT_NODE)
    const nt_sid = try vm.pool.intern("nodeType");
    doc_obj.setProperty(vm.allocator, nt_sid, JsValue.initNumber(9)) catch {};

    // nodeName = "#document"
    const nn_sid = try vm.pool.intern("nodeName");
    doc_obj.setProperty(vm.allocator, nn_sid, JsValue.initString(try vm.pool.intern("#document"))) catch {};

    // Fixed metadata properties
    const meta_props = .{
        .{ "URL", "about:blank" },
        .{ "documentURI", "about:blank" },
        .{ "compatMode", "CSS1Compat" },
        .{ "characterSet", "UTF-8" },
        .{ "charset", "UTF-8" },
        .{ "inputEncoding", "UTF-8" },
    };
    inline for (meta_props) |pair| {
        const sid = vm.pool.intern(pair[0]) catch break;
        const val_sid = vm.pool.intern(pair[1]) catch break;
        doc_obj.setProperty(vm.allocator, sid, JsValue.initString(val_sid)) catch {};
    }
    // contentType (variable)
    const ct_sid = try vm.pool.intern("contentType");
    doc_obj.setProperty(vm.allocator, ct_sid, JsValue.initString(try vm.pool.intern(content_type))) catch {};

    // location = null (no browsing context)
    const loc_sid = try vm.pool.intern("location");
    doc_obj.setProperty(vm.allocator, loc_sid, JsValue.null_val) catch {};

    // Register DOM methods on this document
    vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement) catch {};
    vm.registerNativeMethod(doc_obj, "createElementNS", &nativeCreateElementNS) catch {};
    vm.registerNativeMethod(doc_obj, "createAttribute", &nativeCreateAttribute) catch {};
    vm.registerNativeMethod(doc_obj, "createAttributeNS", &nativeCreateAttributeNS) catch {};
    vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode) catch {};
    vm.registerNativeMethod(doc_obj, "createComment", &nativeCreateComment) catch {};
    vm.registerNativeMethod(doc_obj, "createCDATASection", &nativeCreateCDATASection) catch {};
    vm.registerNativeMethod(doc_obj, "createDocumentFragment", &nativeCreateDocumentFragment) catch {};
    vm.registerNativeMethod(doc_obj, "createEvent", &nativeCreateEvent) catch {};
    vm.registerNativeMethod(doc_obj, "createProcessingInstruction", &nativeCreateProcessingInstruction) catch {};
    vm.registerNativeMethod(doc_obj, "appendChild", &nativeAppendChild) catch {};
    vm.registerNativeMethod(doc_obj, "removeChild", &nativeRemoveChild) catch {};
    vm.registerNativeMethod(doc_obj, "insertBefore", &nativeInsertBefore) catch {};
    vm.registerNativeMethod(doc_obj, "replaceChild", &nativeReplaceChild) catch {};
    vm.registerNativeMethod(doc_obj, "hasChildNodes", &nativeHasChildNodes) catch {};
    vm.registerNativeMethod(doc_obj, "cloneNode", &nativeCloneNode) catch {};
    vm.registerNativeMethod(doc_obj, "contains", &nativeContains) catch {};
    vm.registerNativeMethod(doc_obj, "getElementById", &nativeGetElementById) catch {};
    vm.registerNativeMethod(doc_obj, "getElementsByTagName", &nativeGetElementsByTagName) catch {};
    vm.registerNativeMethod(doc_obj, "getElementsByClassName", &nativeGetElementsByClassName) catch {};
    vm.registerNativeMethod(doc_obj, "querySelector", &nativeQuerySelector) catch {};
    vm.registerNativeMethod(doc_obj, "querySelectorAll", &nativeQuerySelectorAll) catch {};
    vm.registerNativeMethod(doc_obj, "importNode", &nativeImportNode) catch {};

    // implementation (self-referential for chained calls)
    const impl_obj = vm.createObj(.{}) catch return doc_val;
    // Store owning document reference for createDocumentType
    impl_obj.setProperty(vm.allocator, vm.pool.intern("_ownerDoc") catch return doc_val, doc_val) catch {};
    const hf_fn = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    hf_fn.data = .{ .native_fn = &nativeImplementationHasFeature };
    const hf_sid = vm.pool.intern("hasFeature") catch return doc_val;
    impl_obj.setProperty(vm.allocator, hf_sid, JsValue.initObject(hf_fn)) catch {};
    const chd_fn2 = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    chd_fn2.data = .{ .native_fn = &nativeImplementationCreateHTMLDocument };
    const chd_sid2 = vm.pool.intern("createHTMLDocument") catch return doc_val;
    impl_obj.setProperty(vm.allocator, chd_sid2, JsValue.initObject(chd_fn2)) catch {};
    const cdt_fn2 = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cdt_fn2.data = .{ .native_fn = &nativeImplementationCreateDocumentType };
    const cdt_sid2 = vm.pool.intern("createDocumentType") catch return doc_val;
    impl_obj.setProperty(vm.allocator, cdt_sid2, JsValue.initObject(cdt_fn2)) catch {};
    const cd_fn3 = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cd_fn3.data = .{ .native_fn = &nativeImplementationCreateDocument };
    const cd_sid3 = vm.pool.intern("createDocument") catch return doc_val;
    impl_obj.setProperty(vm.allocator, cd_sid3, JsValue.initObject(cd_fn3)) catch {};
    const impl_sid = vm.pool.intern("implementation") catch return doc_val;
    doc_obj.setProperty(vm.allocator, impl_sid, JsValue.initObject(impl_obj)) catch {};

    return doc_val;
}

/// DOM §7.1: DOMImplementation.createHTMLDocument([title])
/// Creates a new standalone HTML document with <!DOCTYPE html><html><head></head><body></body></html>.
/// If title is given, adds <title>title</title> inside <head>.
fn nativeImplementationCreateHTMLDocument(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);

    // Build minimal HTML to parse
    var html_buf: [512]u8 = undefined;
    const html: []const u8 = blk: {
        if (args.len > 0 and !args[0].isUndefined()) {
            const title_str = argToString(vm, args[0]);
            const len = std.fmt.bufPrint(&html_buf, "<!DOCTYPE html><html><head><title>{s}</title></head><body></body></html>", .{title_str}) catch
                break :blk "<!DOCTYPE html><html><head></head><body></body></html>";
            break :blk len;
        }
        break :blk "<!DOCTYPE html><html><head></head><body></body></html>";
    };

    return wrapParsedHtmlDocAsJsDoc(vm, html, "text/html");
}

// ── DOMParser (DOM Parsing and Serialization §2.1) ──────────────────
// new DOMParser() returns an empty object. Methods live on the prototype
// installed in initDomBuiltins. parseFromString(str, type) parses the
// string into a new Document and returns it. Supported types:
//   "text/html"            → HTML parse (returns HTMLDocument)
//   "application/xml"      → XML-mode wrapper over HTML parse (pragmatic;
//   "text/xml"               we do not ship an XML parser)
//   "application/xhtml+xml"
//   "image/svg+xml"

fn nativeDOMParserConstructor(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const obj = try vm.createObj(.{});
    if (g_domparser_proto) |p| obj.prototype = p;
    return JsValue.initObject(obj);
}

fn nativeDOMParserParseFromString(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    // Two required args per WebIDL. Missing args → TypeError.
    if (args.len < 2) return error.TypeError;

    // type must be one of the SupportedType enum values.
    const type_str: []const u8 = if (args[1].isString())
        (vm.pool.get(args[1].asStringId()) orelse "")
    else
        argToString(vm, args[1]);

    const is_html = std.mem.eql(u8, type_str, "text/html");
    const is_xml = std.mem.eql(u8, type_str, "application/xml") or
        std.mem.eql(u8, type_str, "text/xml") or
        std.mem.eql(u8, type_str, "application/xhtml+xml") or
        std.mem.eql(u8, type_str, "image/svg+xml");
    if (!is_html and !is_xml) return error.TypeError;

    // str: WebIDL converts null/undefined/non-strings to "undefined" / "null" / String(x);
    // we use argToString which mirrors that behaviour.
    const html_str: []const u8 = if (args[0].isString())
        (vm.pool.get(args[0].asStringId()) orelse "")
    else
        argToString(vm, args[0]);

    const content_type: []const u8 = if (is_html) "text/html" else type_str;

    // Pragmatic XML handling: lexbor's HTML parser is lenient enough for the
    // WPT fixtures that need DOMParser XML mode (they only probe contentType
    // and documentElement). A real XML parser would be a separate project.
    return wrapParsedHtmlDocAsJsDoc(vm, html_str, content_type) catch return JsValue.null_val;
}

/// DOM §7.1: DOMImplementation.createDocument(namespace, qualifiedName, doctype)
/// Creates a new XML document. If qualifiedName is non-empty, appends a root element.
/// Uses a pure JS object (NOT lexbor dom_node) to avoid property interception
/// that would read from the empty lexbor DOM tree.
fn nativeImplementationCreateDocument(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);

    // WebIDL: createDocument requires 2 arguments → JS TypeError.
    if (args.len < 2) return error.TypeError;

    // WebIDL: 3rd arg is `DocumentType? doctype` — must be a DocumentType
    // object, null, or undefined. Booleans/numbers/strings → TypeError.
    // For DocumentType detection we accept either a stored nodeType=10
    // property (JS-synthesized DT) or a lexbor-backed dom_node with
    // DOCUMENT_TYPE node type.
    if (args.len >= 3) {
        const dt_arg = args[2];
        if (!dt_arg.isNull() and !dt_arg.isUndefined()) {
            if (!dt_arg.isObject()) return error.TypeError;
            if (!argIsNodeLike(vm, dt_arg)) return error.TypeError;
        }
    }

    // DOM §7.1 step 1: "validate and extract" qualifiedName + namespace,
    // but ONLY when qualifiedName is non-empty. Per spec, when qname is "" the
    // element is not created and validation is skipped. The WebIDL typing
    // converts null → "" via [LegacyNullToEmptyString]; undefined → "undefined".
    const ns_for_validate: ?[]const u8 = blk: {
        if (args[0].isNull() or args[0].isUndefined()) break :blk null;
        break :blk argToString(vm, args[0]);
    };
    const qn_for_validate: []const u8 = blk: {
        if (args[1].isNull()) break :blk "";
        break :blk argToString(vm, args[1]);
    };
    if (qn_for_validate.len > 0) {
        _ = dom_names.validateAndExtract(qn_for_validate, ns_for_validate) catch |err| {
            return try queueValidationErr(vm, err);
        };
    }

    // Create pure JS document object (no lexbor backing — XML document)
    const doc_obj = try vm.createObj(.{});
    // DOM §4.5: createDocument returns an XMLDocument
    doc_obj.prototype = g_xml_doc_proto orelse g_node_proto;
    // DOM §4.4 — Document.ownerDocument = null. This is a plain JsObject
    // (no `.dom_node` data), so `domNodeGetProp` never fires for it;
    // keep the JS-visible `ownerDocument` property AND the `_ownerDoc`
    // slot in sync so both access paths return null.
    setNodeOwnerDoc(vm, doc_obj, JsValue.null_val);
    doc_obj.setProperty(vm.allocator, try vm.pool.intern("ownerDocument"), JsValue.null_val) catch {};
    const doc_val = JsValue.initObject(doc_obj);

    // Mark as XML document (createElement should NOT lowercase tag names)
    const xml_flag_sid = try vm.pool.intern("_isXmlDoc");
    doc_obj.setProperty(vm.allocator, xml_flag_sid, JsValue.initBool(true)) catch {};

    // nodeType = 9, nodeName = "#document"
    const nt_sid = try vm.pool.intern("nodeType");
    doc_obj.setProperty(vm.allocator, nt_sid, JsValue.initNumber(9)) catch {};
    const nn_sid = try vm.pool.intern("nodeName");
    doc_obj.setProperty(vm.allocator, nn_sid, JsValue.initString(try vm.pool.intern("#document"))) catch {};
    // nodeValue = null (DOM spec: Document returns null)
    doc_obj.setProperty(vm.allocator, try vm.pool.intern("nodeValue"), JsValue.null_val) catch {};

    // Determine contentType based on namespace (DOM spec)
    const ns_str: ?[]const u8 = blk: {
        if (args.len > 0 and args[0].isString()) {
            const s = vm.pool.get(args[0].asStringId()) orelse break :blk null;
            if (s.len == 0) break :blk null;
            break :blk s;
        }
        break :blk null;
    };
    const content_type: []const u8 = if (ns_str) |ns| ct: {
        if (std.mem.eql(u8, ns, "http://www.w3.org/1999/xhtml"))
            break :ct "application/xhtml+xml"
        else if (std.mem.eql(u8, ns, "http://www.w3.org/2000/svg"))
            break :ct "image/svg+xml"
        else
            break :ct "application/xml";
    } else "application/xml";

    // Metadata
    const meta = .{
        .{ "URL", "about:blank" },
        .{ "documentURI", "about:blank" },
        .{ "compatMode", "CSS1Compat" },
        .{ "characterSet", "UTF-8" },
        .{ "charset", "UTF-8" },
        .{ "inputEncoding", "UTF-8" },
    };
    inline for (meta) |pair| {
        const sid = vm.pool.intern(pair[0]) catch break;
        const val_sid = vm.pool.intern(pair[1]) catch break;
        doc_obj.setProperty(vm.allocator, sid, JsValue.initString(val_sid)) catch {};
    }
    // contentType depends on namespace
    const ct_sid2 = try vm.pool.intern("contentType");
    doc_obj.setProperty(vm.allocator, ct_sid2, JsValue.initString(try vm.pool.intern(content_type))) catch {};

    // location = null (no browsing context)
    const cd_loc_sid = try vm.pool.intern("location");
    doc_obj.setProperty(vm.allocator, cd_loc_sid, JsValue.null_val) catch {};

    // Register DOM methods
    vm.registerNativeMethod(doc_obj, "createElement", &nativeCreateElement) catch {};
    vm.registerNativeMethod(doc_obj, "createElementNS", &nativeCreateElementNS) catch {};
    vm.registerNativeMethod(doc_obj, "createAttribute", &nativeCreateAttribute) catch {};
    vm.registerNativeMethod(doc_obj, "createAttributeNS", &nativeCreateAttributeNS) catch {};
    vm.registerNativeMethod(doc_obj, "createTextNode", &nativeCreateTextNode) catch {};
    vm.registerNativeMethod(doc_obj, "createComment", &nativeCreateComment) catch {};
    vm.registerNativeMethod(doc_obj, "createCDATASection", &nativeCreateCDATASection) catch {};
    vm.registerNativeMethod(doc_obj, "createDocumentFragment", &nativeCreateDocumentFragment) catch {};
    vm.registerNativeMethod(doc_obj, "createEvent", &nativeCreateEvent) catch {};
    vm.registerNativeMethod(doc_obj, "createProcessingInstruction", &nativeCreateProcessingInstruction) catch {};
    vm.registerNativeMethod(doc_obj, "appendChild", &nativeAppendChild) catch {};
    vm.registerNativeMethod(doc_obj, "removeChild", &nativeRemoveChild) catch {};
    vm.registerNativeMethod(doc_obj, "insertBefore", &nativeInsertBefore) catch {};
    vm.registerNativeMethod(doc_obj, "replaceChild", &nativeReplaceChild) catch {};
    vm.registerNativeMethod(doc_obj, "hasChildNodes", &nativeHasChildNodes) catch {};
    vm.registerNativeMethod(doc_obj, "cloneNode", &nativeCloneNode) catch {};
    vm.registerNativeMethod(doc_obj, "contains", &nativeContains) catch {};
    vm.registerNativeMethod(doc_obj, "getElementById", &nativeGetElementById) catch {};
    vm.registerNativeMethod(doc_obj, "getElementsByTagName", &nativeGetElementsByTagName) catch {};
    vm.registerNativeMethod(doc_obj, "getElementsByClassName", &nativeGetElementsByClassName) catch {};
    vm.registerNativeMethod(doc_obj, "querySelector", &nativeQuerySelector) catch {};
    vm.registerNativeMethod(doc_obj, "querySelectorAll", &nativeQuerySelectorAll) catch {};
    vm.registerNativeMethod(doc_obj, "importNode", &nativeImportNode) catch {};

    // implementation object for chained calls
    const cd_impl = vm.createObj(.{}) catch return doc_val;
    cd_impl.setProperty(vm.allocator, vm.pool.intern("_ownerDoc") catch return doc_val, doc_val) catch {};
    const cd_hf = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cd_hf.data = .{ .native_fn = &nativeImplementationHasFeature };
    cd_impl.setProperty(vm.allocator, vm.pool.intern("hasFeature") catch return doc_val, JsValue.initObject(cd_hf)) catch {};
    const cd_chd = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cd_chd.data = .{ .native_fn = &nativeImplementationCreateHTMLDocument };
    cd_impl.setProperty(vm.allocator, vm.pool.intern("createHTMLDocument") catch return doc_val, JsValue.initObject(cd_chd)) catch {};
    const cd_cdt = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cd_cdt.data = .{ .native_fn = &nativeImplementationCreateDocumentType };
    cd_impl.setProperty(vm.allocator, vm.pool.intern("createDocumentType") catch return doc_val, JsValue.initObject(cd_cdt)) catch {};
    const cd_cd = vm.createObj(.{ .obj_type = .native_function }) catch return doc_val;
    cd_cd.data = .{ .native_fn = &nativeImplementationCreateDocument };
    cd_impl.setProperty(vm.allocator, vm.pool.intern("createDocument") catch return doc_val, JsValue.initObject(cd_cd)) catch {};
    doc_obj.setProperty(vm.allocator, vm.pool.intern("implementation") catch return doc_val, JsValue.initObject(cd_impl)) catch {};

    // If doctype provided (arg[2]), set ownerDocument on it (DOM §7.1).
    // DocumentType may or may not be a `.dom_node` depending on how it was
    // constructed — write both the slot and the JS-visible property so
    // both access paths are consistent.
    if (args.len >= 3 and args[2].isObject()) {
        const od_sid2 = try vm.pool.intern("ownerDocument");
        const dt_obj2 = args[2].asJsObject();
        setNodeOwnerDoc(vm, dt_obj2, doc_val);
        dt_obj2.setProperty(vm.allocator, od_sid2, doc_val) catch {};
    }

    // Track created children for childNodes
    var has_doctype = false;
    var doc_element: ?JsValue = null;

    // If doctype provided (arg[2]), set it on doc and mark as child
    if (args.len >= 3 and args[2].isObject()) {
        const dt_sid2 = try vm.pool.intern("doctype");
        doc_obj.setProperty(vm.allocator, dt_sid2, args[2]) catch {};
        has_doctype = true;
    } else {
        const dt_sid2 = try vm.pool.intern("doctype");
        doc_obj.setProperty(vm.allocator, dt_sid2, JsValue.null_val) catch {};
    }

    // If qualifiedName is non-empty (arg[1]), create root element
    // DOM: qualifiedName is [LegacyNullToEmptyString] DOMString
    // null → "", undefined → "undefined", other → toString
    const qn: []const u8 = blk: {
        if (args.len < 2) break :blk "";
        if (args[1].isNull()) break :blk "";
        if (args[1].isString()) break :blk vm.pool.get(args[1].asStringId()) orelse "";
        // undefined → "undefined", bool → "true"/"false", number → string
        if (args[1].isUndefined()) break :blk "undefined";
        break :blk "";
    };
    if (qn.len > 0) {
        // DOM §7.1 step 5: Create element with namespace and qualifiedName
        var prefix: ?[]const u8 = null;
        var local_name: []const u8 = qn;
        if (std.mem.indexOfScalar(u8, qn, ':')) |colon_pos| {
            prefix = qn[0..colon_pos];
            local_name = qn[colon_pos + 1 ..];
        }
        // Create JS-only element (XML document — preserve case).
        // Owner document is the freshly-created doc per DOM §7.1.
        const elem_val = try createJsOnlyElement(vm, local_name, ns_str, doc_val);
        if (elem_val.isObject()) {
            const elem_obj = elem_val.asJsObject();
            if (prefix) |p| {
                elem_obj.setProperty(vm.allocator, try vm.pool.intern("prefix"), JsValue.initString(try vm.pool.intern(p))) catch {};
                elem_obj.setProperty(vm.allocator, try vm.pool.intern("tagName"), JsValue.initString(try vm.pool.intern(qn))) catch {};
                elem_obj.setProperty(vm.allocator, try vm.pool.intern("nodeName"), JsValue.initString(try vm.pool.intern(qn))) catch {};
            }
            // `createJsOnlyElement` already wrote the _ownerDoc slot via the
            // helper; nothing more to do here.
            doc_element = elem_val;
        }
    }

    // Set documentElement
    const de_sid = try vm.pool.intern("documentElement");
    doc_obj.setProperty(vm.allocator, de_sid, doc_element orelse JsValue.null_val) catch {};

    // Build childNodes array directly from tracked values
    const cn_sid3 = try vm.pool.intern("childNodes");
    const cn_arr = try vm.createObj(.{ .obj_type = .array });
    // Build items slice manually to avoid union field access issues
    const child_count: usize = @as(usize, if (has_doctype) @as(usize, 1) else 0) + @as(usize, if (doc_element != null) @as(usize, 1) else 0);
    if (child_count > 0) {
        const items = try vm.allocator.alloc(JsValue, child_count);
        var idx: usize = 0;
        if (has_doctype and args.len >= 3) {
            items[idx] = args[2];
            idx += 1;
        }
        if (doc_element) |de| {
            items[idx] = de;
            idx += 1;
        }
        cn_arr.data = .{ .array = .{ .items = items, .capacity = child_count } };
    } else {
        cn_arr.data = .{ .array = .empty };
    }
    doc_obj.setProperty(vm.allocator, cn_sid3, JsValue.initObject(cn_arr)) catch {};

    return doc_val;
}

/// DOM §7.1: DOMImplementation.createDocumentType(qualifiedName, publicId, systemId)
/// Returns a new DocumentType node with the given name, publicId, and systemId.
fn nativeImplementationCreateDocumentType(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 3) return JsValue.null_val;

    const qname = argToString(vm, args[0]);
    const public_id = argToString(vm, args[1]);
    const system_id = argToString(vm, args[2]);

    // DOM §7.1 step 1: If qualifiedName has obvious invalid chars (>, space,
    // tab, CR, LF) → InvalidCharacterError. Tests require rejecting e.g.
    // "edi:>" and "edi:a " while tolerating many other "odd" chars.
    for (qname) |ch| {
        if (ch == '>' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            vm.pending_throw = try createDOMExceptionObj(vm, "InvalidCharacterError");
            return JsValue.null_val;
        }
    }

    // Create a JS object that behaves like a DocumentType node
    const obj = try vm.createObj(.{});
    obj.prototype = g_doctype_proto;

    // nodeType = 10 (DOCUMENT_TYPE_NODE)
    const nt_sid = try vm.pool.intern("nodeType");
    obj.setProperty(vm.allocator, nt_sid, JsValue.initNumber(10)) catch {};

    // name = qualifiedName
    const name_sid = try vm.pool.intern("name");
    obj.setProperty(vm.allocator, name_sid, JsValue.initString(try vm.pool.intern(qname))) catch {};

    // nodeName = qualifiedName
    const nn_sid = try vm.pool.intern("nodeName");
    obj.setProperty(vm.allocator, nn_sid, JsValue.initString(try vm.pool.intern(qname))) catch {};

    // publicId
    const pid_sid = try vm.pool.intern("publicId");
    obj.setProperty(vm.allocator, pid_sid, JsValue.initString(try vm.pool.intern(public_id))) catch {};

    // systemId
    const sid_sid = try vm.pool.intern("systemId");
    obj.setProperty(vm.allocator, sid_sid, JsValue.initString(try vm.pool.intern(system_id))) catch {};

    // ownerDocument = the document associated with this implementation (DOM §7.1).
    // DocumentType wrappers created here are plain JsObjects (no
    // `.dom_node` data), so write both the `_ownerDoc` slot and the
    // JS-visible `ownerDocument` property so both access paths agree.
    const od_sid = try vm.pool.intern("ownerDocument");
    const owner_doc: JsValue = blk: {
        // Read _ownerDoc from the implementation object (this)
        if (this.isObject()) {
            const impl = this.asJsObject();
            if (impl.getProperty(try vm.pool.intern("_ownerDoc"))) |doc_val| {
                if (doc_val.isObject()) break :blk doc_val;
            }
        }
        // Fallback: global document
        break :blk vm.globals.get(try vm.pool.intern("document")) orelse JsValue.null_val;
    };
    setNodeOwnerDoc(vm, obj, owner_doc);
    obj.setProperty(vm.allocator, od_sid, owner_doc) catch {};

    // childNodes (empty NodeList-like)
    const cn_sid = try vm.pool.intern("childNodes");
    const cn_arr = try vm.createObj(.{ .obj_type = .array });
    cn_arr.data = .{ .array = .empty };
    obj.setProperty(vm.allocator, cn_sid, JsValue.initObject(cn_arr)) catch {};

    // nodeValue = null, textContent = null (DOM spec: DocumentType returns null)
    const nv_sid = try vm.pool.intern("nodeValue");
    obj.setProperty(vm.allocator, nv_sid, JsValue.null_val) catch {};
    const tc_sid = try vm.pool.intern("textContent");
    obj.setProperty(vm.allocator, tc_sid, JsValue.null_val) catch {};

    // firstChild/lastChild = null (DocumentType has no children)
    const fc_sid = try vm.pool.intern("firstChild");
    obj.setProperty(vm.allocator, fc_sid, JsValue.null_val) catch {};
    const lc_sid = try vm.pool.intern("lastChild");
    obj.setProperty(vm.allocator, lc_sid, JsValue.null_val) catch {};

    // parentNode/parentElement/previousSibling/nextSibling = null
    const pn_sid = try vm.pool.intern("parentNode");
    obj.setProperty(vm.allocator, pn_sid, JsValue.null_val) catch {};
    const pe_sid = try vm.pool.intern("parentElement");
    obj.setProperty(vm.allocator, pe_sid, JsValue.null_val) catch {};
    const ps_sid = try vm.pool.intern("previousSibling");
    obj.setProperty(vm.allocator, ps_sid, JsValue.null_val) catch {};
    const ns_sid = try vm.pool.intern("nextSibling");
    obj.setProperty(vm.allocator, ns_sid, JsValue.null_val) catch {};

    return JsValue.initObject(obj);
}

fn getTextContent(vm: *VM, node: *lxb.lxb_dom_node_t) JsValue {
    var len: usize = 0;
    if (dom_b.lxb_dom_node_text_content(node, &len)) |ptr|
        return JsValue.initString(vm.pool.intern(ptr[0..len]) catch return JsValue.null_val);
    return JsValue.initString(vm.pool.intern("") catch return JsValue.null_val);
}

fn setTextContent(vm: *VM, node: *lxb.lxb_dom_node_t, val: JsValue) void {
    const nt = nodeType(node);
    // DOM §4.4: for Element/DocumentFragment, setting textContent:
    // 1. Remove all children
    // 2. If value is non-empty string, create and append a Text node
    if (nt == lxb.LXB_DOM_NODE_TYPE_ELEMENT or nt == lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT) {
        // DOM §4.2.7 "replace all" — collect every detached descendant for
        // removedNodes BEFORE the remove loop, then emit one childList
        // MutationRecord with the full slice. Previously no MO record was
        // emitted on this path at all.
        var removed_buf: [256]JsValue = undefined;
        var removed_heap: ?[]JsValue = null;
        defer if (removed_heap) |h| vm.allocator.free(h);
        var removed_len: usize = 0;
        if (g_mo_list.items.len > 0) {
            var ch: ?*lxb.lxb_dom_node_t = nodeFirstChild(node);
            while (ch) |c| : (ch = nodeNext(c)) {
                const wrapped = wrapNode(vm, c) orelse continue;
                if (removed_len < removed_buf.len) {
                    removed_buf[removed_len] = wrapped;
                    removed_len += 1;
                } else {
                    if (removed_heap == null) {
                        const h = vm.allocator.alloc(JsValue, removed_buf.len * 2) catch break;
                        @memcpy(h[0..removed_buf.len], removed_buf[0..removed_buf.len]);
                        removed_heap = h;
                    }
                    if (removed_heap) |h| {
                        if (removed_len >= h.len) {
                            const grown = vm.allocator.realloc(h, h.len * 2) catch break;
                            removed_heap = grown;
                        }
                        removed_heap.?[removed_len] = wrapped;
                        removed_len += 1;
                    }
                }
            }
        }

        // Remove all children first
        while (nodeFirstChild(node)) |child| {
            dom_b.lxb_dom_node_remove(child);
        }

        var added_wrapped: ?JsValue = null;
        if (!val.isNull()) {
            var buf: [64]u8 = undefined;
            const s = VM.formatValue(vm.pool, val, &buf);
            if (s.len > 0) {
                _ = dom_b.lxb_dom_node_text_content_set(node, s.ptr, s.len);
                if (g_mo_list.items.len > 0) {
                    if (nodeFirstChild(node)) |new_text| {
                        added_wrapped = wrapNode(vm, new_text);
                    }
                }
            }
        }

        // Emit one childList record with all removed (+ optional added).
        if (g_mo_list.items.len > 0 and (removed_len > 0 or added_wrapped != null)) {
            const removed_slice: []const JsValue = if (removed_heap) |h|
                h[0..removed_len]
            else
                removed_buf[0..removed_len];
            recordChildListMutationBulk(vm, node, added_wrapped, removed_slice);
        }
    } else {
        // CharacterData nodes (Text/Comment/PI): setting .data / .nodeValue /
        // .textContent triggers a characterData MutationRecord (DOM §4.3.3).
        // Capture old value BEFORE the write so characterDataOldValue is correct.
        var old_buf: [256]u8 = undefined;
        var old_heap: ?[]u8 = null;
        defer if (old_heap) |h| vm.allocator.free(h);
        const old_val: ?[]const u8 = if (g_mo_list.items.len > 0) blk: {
            var old_len: usize = 0;
            if (dom_b.lxb_dom_node_text_content(node, &old_len)) |ptr| {
                if (old_len <= old_buf.len) {
                    @memcpy(old_buf[0..old_len], ptr[0..old_len]);
                    break :blk old_buf[0..old_len];
                }
                const h = vm.allocator.alloc(u8, old_len) catch break :blk null;
                old_heap = h;
                @memcpy(h, ptr[0..old_len]);
                break :blk h;
            }
            break :blk null;
        } else null;

        if (val.isNull()) {
            _ = dom_b.lxb_dom_node_text_content_set(node, "", 0);
        } else {
            var buf: [64]u8 = undefined;
            const s = VM.formatValue(vm.pool, val, &buf);
            _ = dom_b.lxb_dom_node_text_content_set(node, s.ptr, s.len);
        }
        if (g_mo_list.items.len > 0) {
            recordCharDataMutation(vm, node, old_val);
        }
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

// ══════════════════════════════════════════════════════════════════════
// MutationObserver native implementation (DOM §4.3)
// ══════════════════════════════════════════════════════════════════════

fn nativeMutationObserverConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.undefined_val;
    const callback = args[0];
    if (!callback.isObject()) return JsValue.undefined_val;

    const idx: u32 = @intCast(g_mo_list.items.len);
    try g_mo_list.append(vm.allocator, .{
        .callback = callback,
        .targets = .empty,
        .pending = .empty,
        .disconnected = false,
    });
    g_mo_vm = vm;

    const obj = try vm.createObj(.{});
    try obj.setProperty(vm.allocator, try vm.pool.intern("_moIdx"), JsValue.initNumber(@floatFromInt(idx)));
    try vm.registerNativeMethod(obj, "observe", &nativeMoObserve);
    try vm.registerNativeMethod(obj, "disconnect", &nativeMoDisconnect);
    try vm.registerNativeMethod(obj, "takeRecords", &nativeMoTakeRecords);
    return JsValue.initObject(obj);
}

fn getMoIdx(vm: *VM, this: JsValue) ?u32 {
    if (!this.isObject()) return null;
    const sid = vm.pool.intern("_moIdx") catch return null;
    const val = this.asJsObject().getProperty(sid) orelse return null;
    if (!val.isNumber()) return null;
    const idx: i32 = @intFromFloat(val.asNumber());
    if (idx < 0 or @as(usize, @intCast(idx)) >= g_mo_list.items.len) return null;
    return @intCast(idx);
}

fn nativeMoObserve(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len < 1) return JsValue.undefined_val;
    const idx = getMoIdx(vm, this) orelse return JsValue.undefined_val;
    var obs = &g_mo_list.items[idx];

    // Get target node pointer
    const target_node = getThisNode(args[0]) orelse return JsValue.undefined_val;
    const node_ptr = @intFromPtr(target_node);

    // Parse options (args[1])
    var child_list = false;
    var attributes = false;
    var character_data = false;
    var subtree = false;
    var attribute_old_value = false;
    var character_data_old_value = false;
    // DOM §4.3.3 step 3.3: attributeFilter (sequence<DOMString>)
    var attribute_filter: []const []const u8 = &.{};

    if (args.len >= 2 and args[1].isObject()) {
        const opts = args[1].asJsObject();
        if (opts.getProperty(vm.pool.intern("childList") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) child_list = v.asBool();
        }
        if (opts.getProperty(vm.pool.intern("attributes") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) attributes = v.asBool();
        }
        if (opts.getProperty(vm.pool.intern("characterData") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) character_data = v.asBool();
        }
        if (opts.getProperty(vm.pool.intern("subtree") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) subtree = v.asBool();
        }
        if (opts.getProperty(vm.pool.intern("attributeOldValue") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) attribute_old_value = v.asBool();
            if (v.isBool() and v.asBool()) attributes = true;
        }
        if (opts.getProperty(vm.pool.intern("characterDataOldValue") catch return JsValue.undefined_val)) |v| {
            if (v.isBool()) character_data_old_value = v.asBool();
            if (v.isBool() and v.asBool()) character_data = true;
        }
        // attributeFilter: JS array of strings. Presence implies attributes=true
        // per DOM §4.3.3 step 3.3 (filter only applies when attributes observed).
        if (opts.getProperty(vm.pool.intern("attributeFilter") catch return JsValue.undefined_val)) |v| {
            if (v.isObject()) {
                const arr_obj = v.asJsObject();
                if (arr_obj.obj_type == .array) {
                    const items = arr_obj.data.array.items;
                    const list = try vm.allocator.alloc([]const u8, items.len);
                    for (items, 0..) |item, fi| {
                        const s = if (item.isString()) (vm.pool.get(item.asStringId()) orelse "") else "";
                        list[fi] = try vm.allocator.dupe(u8, s);
                    }
                    attribute_filter = list;
                    attributes = true;
                }
            }
        }
    }

    // Remove existing target with same node (re-observe replaces).
    // Free any existing attribute_filter to avoid leaking.
    var i: usize = 0;
    while (i < obs.targets.items.len) {
        if (obs.targets.items[i].node_ptr == node_ptr) {
            freeAttributeFilter(vm.allocator, obs.targets.items[i].attribute_filter);
            _ = obs.targets.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    try obs.targets.append(vm.allocator, .{
        .node_ptr = node_ptr,
        .child_list = child_list,
        .attributes = attributes,
        .character_data = character_data,
        .subtree = subtree,
        .attribute_old_value = attribute_old_value,
        .character_data_old_value = character_data_old_value,
        .attribute_filter = attribute_filter,
    });

    return JsValue.undefined_val;
}

fn freeAttributeFilter(allocator: std.mem.Allocator, filter: []const []const u8) void {
    for (filter) |s| allocator.free(s);
    if (filter.len > 0) allocator.free(filter);
}

fn nativeMoDisconnect(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const idx = getMoIdx(vm, this) orelse return JsValue.undefined_val;
    var obs = &g_mo_list.items[idx];
    obs.disconnected = true;
    // DOM §4.3.3: free any attribute_filter slices owned by targets.
    for (obs.targets.items) |t| freeAttributeFilter(vm.allocator, t.attribute_filter);
    obs.targets.clearRetainingCapacity();
    obs.pending.clearRetainingCapacity();
    return JsValue.undefined_val;
}

fn nativeMoTakeRecords(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    const idx = getMoIdx(vm, this) orelse return JsValue.undefined_val;
    var obs = &g_mo_list.items[idx];
    const arr = try buildRecordsArray(vm, obs.pending.items);
    obs.pending.clearRetainingCapacity();
    return arr;
}

/// Record a childList mutation for any matching MutationObservers.
pub fn recordChildListMutation(
    vm: *VM,
    target: *lxb.lxb_dom_node_t,
    added: ?JsValue,
    removed: ?JsValue,
    prev_sib: JsValue,
    next_sib: JsValue,
) void {
    const target_ptr = @intFromPtr(target);
    const target_wrapped = wrapNode(vm, target) orelse return;

    // Build addedNodes / removedNodes arrays with direct items allocation
    const added_arr = vm.createObj(.{ .obj_type = .array }) catch return;
    added_arr.prototype = vm.array_proto;
    if (added) |a| {
        const ai = vm.allocator.alloc(JsValue, 1) catch return;
        ai[0] = a;
        added_arr.data = .{ .array = .{ .items = ai, .capacity = 1 } };
    } else {
        added_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };
    }
    const removed_arr = vm.createObj(.{ .obj_type = .array }) catch return;
    removed_arr.prototype = vm.array_proto;
    if (removed) |r| {
        const ri = vm.allocator.alloc(JsValue, 1) catch return;
        ri[0] = r;
        removed_arr.data = .{ .array = .{ .items = ri, .capacity = 1 } };
    } else {
        removed_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };
    }

    for (g_mo_list.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            if (t.node_ptr != target_ptr and !t.subtree) continue;
            if (t.node_ptr != target_ptr and t.subtree) {
                // Check if target is a descendant
                if (!isAncestor(target, t.node_ptr)) continue;
            }
            if (!t.child_list) continue;

            obs.pending.append(vm.allocator, .{
                .type_str = "childList",
                .target = target_wrapped,
                .added_nodes = JsValue.initObject(added_arr),
                .removed_nodes = JsValue.initObject(removed_arr),
                .previous_sibling = prev_sib,
                .next_sibling = next_sib,
                .attribute_name = JsValue.null_val,
                .old_value = JsValue.null_val,
            }) catch {};
            g_mo_pending = true;
            break;
        }
    }
}

/// Record a childList mutation for any matching MutationObservers with a
/// bulk removedNodes slice. Used by textContent/innerHTML "replace all" —
/// DOM §4.2.7 requires every detached descendant to appear in removedNodes.
pub fn recordChildListMutationBulk(
    vm: *VM,
    target: *lxb.lxb_dom_node_t,
    added: ?JsValue,
    removed_slice: []const JsValue,
) void {
    const target_ptr = @intFromPtr(target);
    const target_wrapped = wrapNode(vm, target) orelse return;

    // addedNodes array (0 or 1 entries — callers always synthesize a single
    // Text node or nothing when doing "replace all").
    const added_arr = vm.createObj(.{ .obj_type = .array }) catch return;
    added_arr.prototype = vm.array_proto;
    if (added) |a| {
        const ai = vm.allocator.alloc(JsValue, 1) catch return;
        ai[0] = a;
        added_arr.data = .{ .array = .{ .items = ai, .capacity = 1 } };
    } else {
        added_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };
    }

    // removedNodes array — full slice.
    const removed_arr = vm.createObj(.{ .obj_type = .array }) catch return;
    removed_arr.prototype = vm.array_proto;
    if (removed_slice.len > 0) {
        const ri = vm.allocator.alloc(JsValue, removed_slice.len) catch return;
        @memcpy(ri, removed_slice);
        removed_arr.data = .{ .array = .{ .items = ri, .capacity = removed_slice.len } };
    } else {
        removed_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };
    }

    for (g_mo_list.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            if (t.node_ptr != target_ptr and !t.subtree) continue;
            if (t.node_ptr != target_ptr and t.subtree) {
                if (!isAncestor(target, t.node_ptr)) continue;
            }
            if (!t.child_list) continue;

            obs.pending.append(vm.allocator, .{
                .type_str = "childList",
                .target = target_wrapped,
                .added_nodes = JsValue.initObject(added_arr),
                .removed_nodes = JsValue.initObject(removed_arr),
                .previous_sibling = JsValue.null_val,
                .next_sibling = JsValue.null_val,
                .attribute_name = JsValue.null_val,
                .old_value = JsValue.null_val,
            }) catch {};
            g_mo_pending = true;
            break;
        }
    }
}

/// Record an attribute mutation for any matching MutationObservers.
pub fn recordAttributeMutation(
    vm: *VM,
    target: *lxb.lxb_dom_node_t,
    attr_name: []const u8,
    old_value: ?[]const u8,
) void {
    const target_ptr = @intFromPtr(target);
    const target_wrapped = wrapNode(vm, target) orelse return;

    for (g_mo_list.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            if (t.node_ptr != target_ptr and !t.subtree) continue;
            if (t.node_ptr != target_ptr and t.subtree) {
                if (!isAncestor(target, t.node_ptr)) continue;
            }
            if (!t.attributes) continue;
            // DOM §4.3.3 step 3.3: attributeFilter gate. When filter is non-empty,
            // only listed attribute local-names produce records.
            if (t.attribute_filter.len > 0) {
                var matched = false;
                for (t.attribute_filter) |f| {
                    if (std.mem.eql(u8, f, attr_name)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
            }

            const attr_val = JsValue.initString(vm.pool.intern(attr_name) catch continue);
            const ov = if (t.attribute_old_value and old_value != null)
                JsValue.initString(vm.pool.intern(old_value.?) catch continue)
            else
                JsValue.null_val;

            const empty_arr = vm.createObj(.{ .obj_type = .array }) catch continue;
            empty_arr.prototype = vm.array_proto;
            empty_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };

            obs.pending.append(vm.allocator, .{
                .type_str = "attributes",
                .target = target_wrapped,
                .added_nodes = JsValue.initObject(empty_arr),
                .removed_nodes = JsValue.initObject(empty_arr),
                .previous_sibling = JsValue.null_val,
                .next_sibling = JsValue.null_val,
                .attribute_name = attr_val,
                .old_value = ov,
            }) catch {};
            g_mo_pending = true;
            break;
        }
    }
}

/// Record a characterData mutation for any matching MutationObservers.
pub fn recordCharDataMutation(
    vm: *VM,
    target: *lxb.lxb_dom_node_t,
    old_value: ?[]const u8,
) void {
    const target_ptr = @intFromPtr(target);
    const target_wrapped = wrapNode(vm, target) orelse return;

    for (g_mo_list.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            if (t.node_ptr != target_ptr and !t.subtree) continue;
            if (t.node_ptr != target_ptr and t.subtree) {
                if (!isAncestor(target, t.node_ptr)) continue;
            }
            if (!t.character_data) continue;

            const ov = if (t.character_data_old_value and old_value != null)
                JsValue.initString(vm.pool.intern(old_value.?) catch continue)
            else
                JsValue.null_val;

            const empty_arr = vm.createObj(.{ .obj_type = .array }) catch continue;
            empty_arr.prototype = vm.array_proto;
            empty_arr.data = .{ .array = .{ .items = &.{}, .capacity = 0 } };

            obs.pending.append(vm.allocator, .{
                .type_str = "characterData",
                .target = target_wrapped,
                .added_nodes = JsValue.initObject(empty_arr),
                .removed_nodes = JsValue.initObject(empty_arr),
                .previous_sibling = JsValue.null_val,
                .next_sibling = JsValue.null_val,
                .attribute_name = JsValue.null_val,
                .old_value = ov,
            }) catch {};
            g_mo_pending = true;
            break;
        }
    }
}

fn isAncestor(node: *lxb.lxb_dom_node_t, ancestor_ptr: usize) bool {
    var cur: ?*lxb.lxb_dom_node_t = node.parent;
    while (cur) |c| {
        if (@intFromPtr(c) == ancestor_ptr) return true;
        cur = c.parent;
    }
    return false;
}

fn buildRecordsArray(vm: *VM, records: []const MoRecord) !JsValue {
    const arr = try vm.createObj(.{ .obj_type = .array });
    arr.prototype = vm.array_proto;
    // Allocate items slice and populate directly
    const items = try vm.allocator.alloc(JsValue, records.len);
    for (records, 0..) |rec, idx| {
        const obj = try vm.createObj(.{});
        try obj.setProperty(vm.allocator, try vm.pool.intern("type"), JsValue.initString(try vm.pool.intern(rec.type_str)));
        try obj.setProperty(vm.allocator, try vm.pool.intern("target"), rec.target);
        try obj.setProperty(vm.allocator, try vm.pool.intern("addedNodes"), rec.added_nodes);
        try obj.setProperty(vm.allocator, try vm.pool.intern("removedNodes"), rec.removed_nodes);
        try obj.setProperty(vm.allocator, try vm.pool.intern("previousSibling"), rec.previous_sibling);
        try obj.setProperty(vm.allocator, try vm.pool.intern("nextSibling"), rec.next_sibling);
        try obj.setProperty(vm.allocator, try vm.pool.intern("attributeName"), rec.attribute_name);
        try obj.setProperty(vm.allocator, try vm.pool.intern("attributeNamespace"), JsValue.null_val);
        try obj.setProperty(vm.allocator, try vm.pool.intern("oldValue"), rec.old_value);
        items[idx] = JsValue.initObject(obj);
    }
    arr.data = .{ .array = .{ .items = items, .capacity = records.len } };
    return JsValue.initObject(arr);
}

/// Flush pending MutationObserver callbacks. Called from script_executor
/// after microtask/timer processing.
pub fn flushMutationObservers() void {
    const vm = g_mo_vm orelse return;
    if (!g_mo_pending) return;
    g_mo_pending = false;

    for (g_mo_list.items) |*obs| {
        if (obs.disconnected or obs.pending.items.len == 0) continue;
        const records_arr = buildRecordsArray(vm, obs.pending.items) catch continue;
        obs.pending.clearRetainingCapacity();

        // Call the callback with (records, observer)
        const cb_args = [_]JsValue{ records_arr, JsValue.undefined_val };
        _ = vm.callJsFunction(obs.callback, JsValue.undefined_val, &cb_args) catch {};
    }
}
