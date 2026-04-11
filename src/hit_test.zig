const std = @import("std");
const Box = @import("layout/box.zig").Box;
const BoxType = @import("layout/box.zig").BoxType;
const DomNode = @import("dom/node.zig").DomNode;
const LayoutPos = @import("coords.zig").LayoutPos;

pub const HitResult = struct {
    dom_node: ?DomNode = null,
    link_url: ?[]const u8 = null,
    box: ?*const Box = null,
    form_element: ?DomNode = null,

    fn isHit(self: HitResult) bool {
        return self.box != null or self.dom_node != null or self.link_url != null or self.form_element != null;
    }
};

pub fn hitTest(box: *const Box, pos: LayoutPos) HitResult {
    var result = hitTestBox(box, pos);
    if (result.dom_node) |dn| {
        populateAncestorInfo(&result, dn);
    }
    return result;
}

fn hitTestBox(box: *const Box, pos: LayoutPos) HitResult {
    switch (box.box_type) {
        .block, .inline_box, .anonymous_block => {
            // Recurse into children first (reverse z-order) WITHOUT bounds pre-check.
            // Children can overflow parent's margin box, so pre-checking the parent
            // would incorrectly prune valid hits. This matches the old hitTestNode
            // approach which worked correctly.
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const child_result = hitTestBox(box.children.items[i], pos);
                if (child_result.isHit()) return child_result;
            }
            // No child hit — check self bounds before returning own node
            const mbox = box.marginBox();
            if (pos.x >= mbox.x and pos.x <= mbox.x + mbox.width and
                pos.y >= mbox.y and pos.y <= mbox.y + mbox.height)
            {
                if (box.dom_node != null or box.link_url != null) {
                    return resultForBox(box, false);
                }
            }
        },
        .inline_text => {
            for (box.lines.items) |line| {
                if (pos.x >= line.x and pos.x <= line.x + line.width and
                    pos.y >= line.y and pos.y <= line.y + line.height)
                {
                    return resultForBox(box, true);
                }
            }
        },
        .replaced => {
            if (pos.x >= box.content.x and pos.x <= box.content.x + box.content.width and
                pos.y >= box.content.y and pos.y <= box.content.y + box.content.height)
            {
                return resultForBox(box, true);
            }
        },
    }
    return .{};
}

fn resultForBox(box: *const Box, fallback_to_ancestor: bool) HitResult {
    var dom_node = box.dom_node;
    if (dom_node == null and fallback_to_ancestor) {
        dom_node = nearestAncestorDomNode(box);
    }

    return .{
        .dom_node = dom_node,
        .link_url = box.link_url,
        .box = box,
    };
}

fn nearestAncestorDomNode(box: *const Box) ?DomNode {
    var current = box.parent;
    while (current) |b| : (current = b.parent) {
        if (b.dom_node) |dn| return dn;
    }
    return null;
}

fn populateAncestorInfo(result: *HitResult, start: DomNode) void {
    var node = start;
    while (true) {
        const tag = node.tagName() orelse "";
        if (result.link_url == null and std.mem.eql(u8, tag, "a")) {
            if (node.getAttribute("href")) |href| {
                result.link_url = href;
            }
        }
        if (result.form_element == null) {
            if (std.mem.eql(u8, tag, "input") or
                std.mem.eql(u8, tag, "textarea") or
                std.mem.eql(u8, tag, "button") or
                std.mem.eql(u8, tag, "select"))
            {
                result.form_element = node;
            }
        }
        if (result.link_url != null and result.form_element != null) return;
        node = node.parent() orelse return;
    }
}

test "hitTest returns link URL from inline text without DOM node" {
    const allocator = std.testing.allocator;

    var text_box = Box{};
    text_box.box_type = .inline_text;
    text_box.link_url = "https://example.test/";
    defer text_box.lines.deinit(allocator);

    try text_box.lines.append(allocator, .{
        .x = 10,
        .y = 20,
        .width = 120,
        .height = 18,
        .text = "example",
        .ascent = 14,
    });

    const result = hitTest(&text_box, .{ .x = 20, .y = 25 });
    try std.testing.expect(result.box.? == &text_box);
    try std.testing.expectEqualStrings("https://example.test/", result.link_url.?);
}

test "hitTest preserves child link hits through containers" {
    const allocator = std.testing.allocator;

    var root = Box{};
    root.box_type = .anonymous_block;
    defer root.children.deinit(allocator);

    var text_box = Box{};
    text_box.box_type = .inline_text;
    text_box.parent = &root;
    text_box.link_url = "/relative";
    defer text_box.lines.deinit(allocator);

    try text_box.lines.append(allocator, .{
        .x = 0,
        .y = 0,
        .width = 60,
        .height = 16,
        .text = "relative",
        .ascent = 12,
    });
    try root.children.append(allocator, &text_box);

    const result = hitTest(&root, .{ .x = 8, .y = 8 });
    try std.testing.expect(result.box.? == &text_box);
    try std.testing.expectEqualStrings("/relative", result.link_url.?);
}
