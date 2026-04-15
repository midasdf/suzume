//! Layout hit-test tests (CSSOM View §7.3).
//!
//! Module root is at src/ so that relative @imports inside
//! src/layout/hittest.zig (which reach into src/bindings, src/dom, etc.)
//! resolve within the module tree. Inline tests here call the public API
//! directly — test blocks in src/layout/hittest.zig itself are not picked up
//! by this aggregator, so we mirror the important cases here.

const std = @import("std");
const hittest = @import("layout/hittest.zig");
const Box = @import("layout/box.zig").Box;

const testing = std.testing;

fn makeBox(x: f32, y: f32, w: f32, h: f32) Box {
    var b = Box{};
    b.box_type = .block;
    b.content = .{ .x = x, .y = y, .width = w, .height = h };
    return b;
}

test "hitBoxTopmost: point over simple box returns that box" {
    var root = makeBox(0, 0, 100, 100);
    const hit = hittest.hitBoxTopmost(&root, 50, 50);
    try testing.expect(hit.? == &root);
}

test "hitTestPoint: outside viewport returns null" {
    var root = makeBox(0, 0, 800, 600);
    const vp = hittest.Viewport{ .width = 800, .height = 600 };
    try testing.expect(hittest.hitTestPoint(&root, vp, -1, 10) == null);
    try testing.expect(hittest.hitTestPoint(&root, vp, 10, -1) == null);
    try testing.expect(hittest.hitTestPoint(&root, vp, 800, 10) == null);
    try testing.expect(hittest.hitTestPoint(&root, vp, 10, 600) == null);
}

test "hitBoxTopmost: nested boxes return innermost" {
    const alloc = testing.allocator;
    var root = makeBox(0, 0, 200, 200);
    defer root.children.deinit(alloc);

    var child = makeBox(50, 50, 100, 100);
    child.parent = &root;
    defer child.children.deinit(alloc);

    var grand = makeBox(60, 60, 20, 20);
    grand.parent = &child;
    defer grand.children.deinit(alloc);

    try child.children.append(alloc, &grand);
    try root.children.append(alloc, &child);

    try testing.expect(hittest.hitBoxTopmost(&root, 65, 65).? == &grand);
    try testing.expect(hittest.hitBoxTopmost(&root, 90, 90).? == &child);
    try testing.expect(hittest.hitBoxTopmost(&root, 10, 10).? == &root);
}

test "hitBoxTopmost: overlapping siblings — later sibling wins (paint order)" {
    const alloc = testing.allocator;
    var root = makeBox(0, 0, 200, 200);
    defer root.children.deinit(alloc);

    var a = makeBox(20, 20, 100, 100);
    a.parent = &root;
    defer a.children.deinit(alloc);

    var b = makeBox(50, 50, 100, 100);
    b.parent = &root;
    defer b.children.deinit(alloc);

    try root.children.append(alloc, &a);
    try root.children.append(alloc, &b);

    try testing.expect(hittest.hitBoxTopmost(&root, 25, 25).? == &a);
    try testing.expect(hittest.hitBoxTopmost(&root, 60, 60).? == &b);
    try testing.expect(hittest.hitBoxTopmost(&root, 140, 140).? == &b);
}

test "hitBoxTopmost: flex-container-like layout — correct child hit" {
    const alloc = testing.allocator;
    var container = makeBox(0, 0, 300, 50);
    defer container.children.deinit(alloc);

    var c1 = makeBox(0, 0, 100, 50);
    c1.parent = &container;
    defer c1.children.deinit(alloc);
    var c2 = makeBox(100, 0, 100, 50);
    c2.parent = &container;
    defer c2.children.deinit(alloc);
    var c3 = makeBox(200, 0, 100, 50);
    c3.parent = &container;
    defer c3.children.deinit(alloc);

    try container.children.append(alloc, &c1);
    try container.children.append(alloc, &c2);
    try container.children.append(alloc, &c3);

    try testing.expect(hittest.hitBoxTopmost(&container, 50, 25).? == &c1);
    try testing.expect(hittest.hitBoxTopmost(&container, 150, 25).? == &c2);
    try testing.expect(hittest.hitBoxTopmost(&container, 250, 25).? == &c3);
    // Exactly on the boundary belongs to the right neighbour (half-open).
    try testing.expect(hittest.hitBoxTopmost(&container, 100, 25).? == &c2);
}
