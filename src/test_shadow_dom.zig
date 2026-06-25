// Shadow DOM Phase 1 unit tests.
//
// These tests exercise the low-level scope tagging / allowlist logic in
// `src/js/shadow_root.zig`. End-to-end JS integration behavior (attachShadow
// return values, querySelector scoping, outerHTML exclusion) is covered by
// `zig build test-kotori-dom` and the `zig build test-dom-js` smoke.

const std = @import("std");
const shadow_root = @import("js/shadow_root.zig");

test "isAllowedShadowHost: allowlisted built-ins" {
    try std.testing.expect(shadow_root.isAllowedShadowHost("div"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("article"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("aside"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("blockquote"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("body"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("header"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("footer"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("main"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("nav"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("p"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("section"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("span"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("h1"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("h6"));
}

test "isAllowedShadowHost: rejects forbidden built-ins" {
    // These elements may NOT host a shadow root (spec §4.8).
    try std.testing.expect(!shadow_root.isAllowedShadowHost("input"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("img"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("br"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("hr"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("meta"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("link"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("script"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("style"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("video"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("audio"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("iframe"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("textarea"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("select"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("button"));
    try std.testing.expect(!shadow_root.isAllowedShadowHost("table"));
}

test "isAllowedShadowHost: accepts custom elements (contain hyphen)" {
    try std.testing.expect(shadow_root.isAllowedShadowHost("x-foo"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("my-component"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("foo-bar-baz"));
    try std.testing.expect(shadow_root.isAllowedShadowHost("a-b"));
}

test "nodeScope returns 0 for untagged node" {
    const lxb = @import("bindings/lexbor.zig").c;
    var fake_node: lxb.lxb_dom_node_t = undefined;
    try std.testing.expectEqual(@as(u32, 0), shadow_root.nodeScope(&fake_node));
}

test "setNodeScope / nodeScope round-trip + removal" {
    const lxb = @import("bindings/lexbor.zig").c;
    var fake_node: lxb.lxb_dom_node_t = undefined;
    shadow_root.setNodeScope(&fake_node, 42);
    try std.testing.expectEqual(@as(u32, 42), shadow_root.nodeScope(&fake_node));
    shadow_root.setNodeScope(&fake_node, 0);
    try std.testing.expectEqual(@as(u32, 0), shadow_root.nodeScope(&fake_node));
}

test "shadowRootById returns null for unknown id" {
    try std.testing.expectEqual(@as(?*shadow_root.ShadowRoot, null), shadow_root.shadowRootById(99999));
}

test "tagSubtreeScope propagates scope to descendants" {
    const lxb = @import("bindings/lexbor.zig").c;
    // Build a tiny fake tree: root → child → grandchild (all linked via first_child/next).
    var root: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    var child_a: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    var child_b: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    var grand: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);

    root.first_child = &child_a;
    child_a.parent = &root;
    child_a.next = &child_b;
    child_b.parent = &root;
    child_a.first_child = &grand;
    grand.parent = &child_a;

    shadow_root.tagSubtreeScope(&root, 7);
    try std.testing.expectEqual(@as(u32, 7), shadow_root.nodeScope(&root));
    try std.testing.expectEqual(@as(u32, 7), shadow_root.nodeScope(&child_a));
    try std.testing.expectEqual(@as(u32, 7), shadow_root.nodeScope(&child_b));
    try std.testing.expectEqual(@as(u32, 7), shadow_root.nodeScope(&grand));

    // Clear tags for cleanliness.
    shadow_root.setNodeScope(&root, 0);
    shadow_root.setNodeScope(&child_a, 0);
    shadow_root.setNodeScope(&child_b, 0);
    shadow_root.setNodeScope(&grand, 0);
}

test "propagateScopeFromParent inherits from tagged parent" {
    const lxb = @import("bindings/lexbor.zig").c;
    var parent: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    var new_child: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    shadow_root.setNodeScope(&parent, 13);
    shadow_root.propagateScopeFromParent(&parent, &new_child);
    try std.testing.expectEqual(@as(u32, 13), shadow_root.nodeScope(&new_child));
    // Clean up.
    shadow_root.setNodeScope(&parent, 0);
    shadow_root.setNodeScope(&new_child, 0);
}

test "propagateScopeFromParent does nothing for light-scope parent" {
    const lxb = @import("bindings/lexbor.zig").c;
    var parent: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    var new_child: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    shadow_root.propagateScopeFromParent(&parent, &new_child);
    try std.testing.expectEqual(@as(u32, 0), shadow_root.nodeScope(&new_child));
}

test "shadowInclusiveRoot: light tree returns topmost parent" {
    const lxb = @import("bindings/lexbor.zig").c;
    var root: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    root.type = lxb.LXB_DOM_NODE_TYPE_DOCUMENT;
    var child: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    child.parent = &root;
    const found = shadow_root.shadowInclusiveRoot(&child, false);
    try std.testing.expectEqual(@as(*lxb.lxb_dom_node_t, &root), found);
    try std.testing.expect(shadow_root.isShadowInclusiveConnected(&child));
}

test "shadowInclusiveRoot: composed=false stops at shadow fragment" {
    const lxb = @import("bindings/lexbor.zig").c;
    var fragment: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    fragment.type = lxb.LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT;
    var child: lxb.lxb_dom_node_t = std.mem.zeroes(lxb.lxb_dom_node_t);
    child.parent = &fragment;
    // Tag the fragment with a non-existent shadow id — composed=false stops here.
    shadow_root.setNodeScope(&fragment, 100);
    const found = shadow_root.shadowInclusiveRoot(&child, false);
    try std.testing.expectEqual(@as(*lxb.lxb_dom_node_t, &fragment), found);
    // Clean up.
    shadow_root.setNodeScope(&fragment, 0);
}
