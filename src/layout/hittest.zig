//! Spec-compliant hit-testing for document.elementFromPoint / elementsFromPoint.
//!
//! Reference: CSSOM View Module §7.3 (elementFromPoint, elementsFromPoint).
//! https://www.w3.org/TR/cssom-view-1/#dom-document-elementfrompoint
//!
//! The algorithm takes viewport-relative CSS pixel coordinates (x, y) and returns
//! the topmost element whose border box contains the point, with all descendants
//! considered first in paint order. Points outside the viewport yield null.
//!
//! Phase 1 simplification: paint order == reverse document order (children before
//! parents, last-child before first-child). Stacking contexts and z-index are not
//! honored yet — tracked separately.

const std = @import("std");
const lxb = @import("../bindings/lexbor.zig").c;
const Box = @import("box.zig").Box;

/// Viewport dimensions in CSS pixels. Points must satisfy
/// `0 <= x < width` and `0 <= y < height`, else hit-test returns null per spec.
pub const Viewport = struct {
    width: f32,
    height: f32,
};

/// Walks the layout tree and returns the topmost element whose border box
/// contains (x, y), or null if the point is outside the viewport or no
/// element is hit. Coordinates are viewport-relative (already scroll-adjusted
/// by the caller — Box rects in this tree are in the same coordinate space).
pub fn hitTestPoint(root: *const Box, viewport: Viewport, x: f32, y: f32) ?*lxb.lxb_dom_node_t {
    if (!inViewport(viewport, x, y)) return null;
    const box = hitBoxTopmost(root, x, y) orelse return null;
    return elementNode(box);
}

/// Fills `out` with all elements whose border box contains (x, y), in paint
/// order from topmost to root. Returns nothing if the point is outside the
/// viewport (per CSSOM View §7.3 elementsFromPoint algorithm).
pub fn hitTestPointAll(
    root: *const Box,
    viewport: Viewport,
    x: f32,
    y: f32,
    out: *std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    allocator: std.mem.Allocator,
) !void {
    if (!inViewport(viewport, x, y)) return;
    try collectBoxes(root, x, y, out, allocator);
}

fn inViewport(v: Viewport, x: f32, y: f32) bool {
    return x >= 0 and y >= 0 and x < v.width and y < v.height;
}

/// Returns the topmost box whose border box contains the point. Exposed for
/// tests — the JS-facing API maps this back to a DOM element.
/// Walks children in reverse document order to approximate paint order.
/// TODO(phase1): does not honor stacking contexts / z-index yet.
pub fn hitBoxTopmost(box: *const Box, x: f32, y: f32) ?*const Box {
    // Reverse document order: later siblings paint on top.
    var i = box.children.items.len;
    while (i > 0) {
        i -= 1;
        if (hitBoxTopmost(box.children.items[i], x, y)) |found| return found;
    }
    if (containsBorderBox(box, x, y)) return box;
    return null;
}

fn collectBoxes(
    box: *const Box,
    x: f32,
    y: f32,
    out: *std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    allocator: std.mem.Allocator,
) !void {
    var i = box.children.items.len;
    while (i > 0) {
        i -= 1;
        try collectBoxes(box.children.items[i], x, y, out, allocator);
    }
    if (containsBorderBox(box, x, y)) {
        if (elementNode(box)) |node| try out.append(allocator, node);
    }
}

fn containsBorderBox(box: *const Box, x: f32, y: f32) bool {
    // Per CSSOM View §7.3 the hit shape is the border box. Use half-open
    // intervals on the right/bottom edges so adjacent non-overlapping boxes
    // don't both claim a shared edge pixel.
    const r = box.borderBox();
    return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
}

/// Only boxes backed by Element nodes are returned by elementFromPoint
/// (CSSOM View §7.3). Anonymous boxes, line boxes and text boxes surface
/// their nearest element ancestor.
fn elementNode(box: *const Box) ?*lxb.lxb_dom_node_t {
    if (box.dom_node) |dn| {
        if (dn.lxb_node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return dn.lxb_node;
    }
    var cur = box.parent;
    while (cur) |p| : (cur = p.parent) {
        if (p.dom_node) |dn| {
            if (dn.lxb_node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return dn.lxb_node;
        }
    }
    return null;
}

// Tests live in src/test_hittest.zig (module-root-at-src/ required for
// relative imports).
