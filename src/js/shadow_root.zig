// Shadow DOM v1 — Phase 1: tree scope + attachShadow + scoped traversal
//
// Design: scope-tagged nodes (spec Option B). Each ShadowRoot is a Zig-side
// struct owning a `lxb_dom_document_fragment_t` as its storage root. Nodes
// inside that fragment carry a `shadow_root_id: u32` tag via a side-table
// (AutoHashMap). The fragment itself is NOT linked to the host's light tree
// via lexbor parent/child pointers, which means:
//   - outerHTML(host) naturally excludes shadow tree
//   - querySelector on a light-tree element naturally stays light
//   - querySelector on the shadow root starts at the fragment and naturally
//     stays within the shadow tree
//
// Scope tags exist for:
//   - getRootNode() — walk up, stop at shadow root, jump to host only when
//     {composed: true}
//   - isConnected — shadow-inclusive connectivity
//   - defensive boundary enforcement

const std = @import("std");
const lxb = @import("../bindings/lexbor.zig").c;

pub const Mode = enum { open, closed };
pub const SlotAssignment = enum { named, manual };

pub const ShadowRoot = struct {
    id: u32,
    host: *lxb.lxb_dom_element_t,
    fragment: *lxb.lxb_dom_node_t,
    mode: Mode,
    delegates_focus: bool,
    slot_assignment: SlotAssignment,
    /// Weak JS wrapper reference (not a strong ref — lifetime tied to host).
    js_wrapper_tag: c_int = 0,
    js_wrapper_ptr: ?*anyopaque = null,
};

// ── External lexbor functions ───────────────────────────────────────
extern fn lxb_dom_document_create_document_fragment(document: *anyopaque) ?*lxb.lxb_dom_node_t;

// ── Global state (Phase 1: single shared map; Phase 2+ can move to FrameState) ─

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_shadow_roots: ?std.AutoHashMap(u32, *ShadowRoot) = null;
/// Maps lxb node pointer → shadow_root_id (0 = document scope, not stored).
var g_node_scope: ?std.AutoHashMap(usize, u32) = null;
/// Maps lxb host element pointer → ShadowRoot pointer (fast `element.shadowRoot` lookup
/// regardless of mode — closed-mode access is via Zig only).
var g_host_to_shadow: ?std.AutoHashMap(usize, *ShadowRoot) = null;
var g_next_id: u32 = 1;

fn ensureInit() void {
    if (g_shadow_roots == null) {
        g_shadow_roots = std.AutoHashMap(u32, *ShadowRoot).init(g_allocator);
    }
    if (g_node_scope == null) {
        g_node_scope = std.AutoHashMap(usize, u32).init(g_allocator);
    }
    if (g_host_to_shadow == null) {
        g_host_to_shadow = std.AutoHashMap(usize, *ShadowRoot).init(g_allocator);
    }
}

/// Lookup shadow root for a given host element (regardless of mode).
pub fn shadowRootForHost(host: *lxb.lxb_dom_element_t) ?*ShadowRoot {
    if (g_host_to_shadow) |map| {
        return map.get(@intFromPtr(host));
    }
    return null;
}

/// Lookup shadow root by id.
pub fn shadowRootById(id: u32) ?*ShadowRoot {
    if (g_shadow_roots) |map| {
        return map.get(id);
    }
    return null;
}

/// Return the shadow root scope id for a node (0 = document/light scope).
pub fn nodeScope(node: *lxb.lxb_dom_node_t) u32 {
    if (g_node_scope) |map| {
        return map.get(@intFromPtr(node)) orelse 0;
    }
    return 0;
}

/// Tag a single node with a shadow scope id (0 removes the tag).
pub fn setNodeScope(node: *lxb.lxb_dom_node_t, id: u32) void {
    ensureInit();
    if (id == 0) {
        _ = g_node_scope.?.remove(@intFromPtr(node));
        return;
    }
    g_node_scope.?.put(@intFromPtr(node), id) catch {};
}

/// Tag `node` and all its descendants with the given scope id (recursive).
pub fn tagSubtreeScope(node: *lxb.lxb_dom_node_t, id: u32) void {
    ensureInit();
    setNodeScope(node, id);
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| : (child = ch.next) {
        tagSubtreeScope(ch, id);
    }
}

/// If `parent` is inside a shadow scope, tag `new_child` (and its subtree)
/// with the same scope. Called from insertion chokepoints so any subtree
/// brought into a shadow tree inherits the scope.
pub fn propagateScopeFromParent(parent: *lxb.lxb_dom_node_t, new_child: *lxb.lxb_dom_node_t) void {
    const sid = nodeScope(parent);
    if (sid == 0) return;
    tagSubtreeScope(new_child, sid);
}

/// Host element lookup: if `node` is within a shadow tree, return its shadow root.
pub fn enclosingShadowRoot(node: *lxb.lxb_dom_node_t) ?*ShadowRoot {
    const sid = nodeScope(node);
    if (sid == 0) return null;
    return shadowRootById(sid);
}

/// Spec §4.8: elements disallowed from hosting a shadow root.
/// The list here matches the HTML spec "valid shadow host name" list
/// (https://dom.spec.whatwg.org/#dom-element-attachshadow).
pub fn isAllowedShadowHost(local_name: []const u8) bool {
    // Allow custom elements (contain a hyphen).
    if (std.mem.indexOfScalar(u8, local_name, '-') != null) return true;

    // Allowlist of built-ins that MAY host a shadow root.
    const allow = [_][]const u8{
        "article", "aside", "blockquote", "body",     "div",    "footer",
        "h1",      "h2",    "h3",         "h4",       "h5",     "h6",
        "header",  "main",  "nav",        "p",        "section", "span",
    };
    for (allow) |name| {
        if (std.mem.eql(u8, local_name, name)) return true;
    }
    return false;
}

/// Create a new ShadowRoot for the given host. `document` is the lexbor
/// document (opaque) — needed to create the fragment.
pub fn create(
    document: *anyopaque,
    host: *lxb.lxb_dom_element_t,
    mode: Mode,
    delegates_focus: bool,
    slot_assignment: SlotAssignment,
) ?*ShadowRoot {
    ensureInit();
    const fragment = lxb_dom_document_create_document_fragment(document) orelse return null;

    const sr = g_allocator.create(ShadowRoot) catch {
        return null;
    };
    const id = g_next_id;
    g_next_id += 1;
    sr.* = .{
        .id = id,
        .host = host,
        .fragment = fragment,
        .mode = mode,
        .delegates_focus = delegates_focus,
        .slot_assignment = slot_assignment,
    };

    g_shadow_roots.?.put(id, sr) catch {
        g_allocator.destroy(sr);
        return null;
    };
    g_host_to_shadow.?.put(@intFromPtr(host), sr) catch {};

    // Tag the fragment node itself so descendants can inherit via propagation.
    setNodeScope(fragment, id);
    return sr;
}

/// Walk up through shadow boundaries to find the shadow-inclusive root.
/// If `composed` is true, we cross through hosts to reach document.
pub fn shadowInclusiveRoot(node: *lxb.lxb_dom_node_t, composed: bool) *lxb.lxb_dom_node_t {
    var current: *lxb.lxb_dom_node_t = node;
    while (true) {
        // Walk normal parent chain.
        while (current.parent) |p| : (current = p) {}
        // current has no parent. Check if it is a shadow fragment.
        const sid = nodeScope(current);
        if (sid == 0) return current; // document or detached root
        const sr = shadowRootById(sid) orelse return current;
        if (!composed) return current; // stop at shadow root
        // Jump to host and continue.
        current = @ptrCast(sr.host);
    }
}

/// Is `node`'s shadow-inclusive root the document?
pub fn isShadowInclusiveConnected(node: *lxb.lxb_dom_node_t) bool {
    const root = shadowInclusiveRoot(node, true);
    return root.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT;
}

/// Clear all state — called on page navigation to avoid stale mappings.
pub fn reset() void {
    if (g_shadow_roots) |*map| {
        var it = map.valueIterator();
        while (it.next()) |sr_ptr| {
            g_allocator.destroy(sr_ptr.*);
        }
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
