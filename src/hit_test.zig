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
                if (child_result.dom_node != null) return child_result;
            }
            // No child hit — check self bounds before returning own node
            const mbox = box.marginBox();
            if (pos.x >= mbox.x and pos.x <= mbox.x + mbox.width and
                pos.y >= mbox.y and pos.y <= mbox.y + mbox.height)
            {
                if (box.dom_node) |dn| {
                    return .{ .dom_node = dn, .box = box };
                }
            }
        },
        .inline_text => {
            for (box.lines.items) |line| {
                if (pos.x >= line.x and pos.x <= line.x + line.width and
                    pos.y >= line.y and pos.y <= line.y + line.height)
                {
                    if (box.dom_node) |dn| {
                        return .{ .dom_node = dn, .box = box };
                    }
                    return .{};
                }
            }
        },
        .replaced => {
            if (pos.x >= box.content.x and pos.x <= box.content.x + box.content.width and
                pos.y >= box.content.y and pos.y <= box.content.y + box.content.height)
            {
                if (box.dom_node) |dn| {
                    return .{ .dom_node = dn, .box = box };
                }
            }
        },
    }
    return .{};
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
