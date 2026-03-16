const std = @import("std");
const DomNode = @import("../dom/node.zig").DomNode;
const NodeType = @import("../dom/node.zig").NodeType;
const ComputedStyle = @import("../style/computed.zig").ComputedStyle;
const cascade_mod = @import("../style/cascade.zig");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;

/// Build a box tree from a DOM node and its resolved styles.
/// Returns the root Box for the body element.
pub fn buildBoxTree(
    body_node: DomNode,
    styles: *const cascade_mod.CascadeResult,
    allocator: std.mem.Allocator,
) !*Box {
    const root_box = try allocator.create(Box);
    root_box.* = .{};
    root_box.box_type = .block;
    root_box.dom_node = body_node;

    // Apply body style
    if (styles.getStyle(body_node)) |s| {
        root_box.style = s;
    }

    // Build children
    try buildChildren(root_box, body_node, styles, allocator, null);

    return root_box;
}

fn buildChildren(
    parent_box: *Box,
    dom_node: DomNode,
    styles: *const cascade_mod.CascadeResult,
    allocator: std.mem.Allocator,
    inherited_link: ?[]const u8,
) !void {
    var child_opt = dom_node.firstChild();
    while (child_opt) |child| {
        defer child_opt = child.nextSibling();

        switch (child.nodeType()) {
            .element => {
                // Get style; skip display:none elements
                const style = styles.getStyle(child) orelse ComputedStyle{};
                if (style.display == .none) continue;

                const child_box = try allocator.create(Box);
                child_box.* = .{};
                child_box.dom_node = child;
                child_box.style = style;
                child_box.parent = parent_box;

                // Determine box type from display
                child_box.box_type = switch (style.display) {
                    .block, .list_item, .table, .flex, .grid => .block,
                    else => .block, // treat everything as block for Phase 1
                };

                // Apply margin/padding from style
                child_box.margin = .{
                    .top = style.margin_top,
                    .right = style.margin_right,
                    .bottom = style.margin_bottom,
                    .left = style.margin_left,
                };
                child_box.padding = .{
                    .top = style.padding_top,
                    .right = style.padding_right,
                    .bottom = style.padding_bottom,
                    .left = style.padding_left,
                };

                // Check if this is an <a> element with href
                var link_url = inherited_link;
                if (child.tagName()) |tag| {
                    if (std.mem.eql(u8, tag, "a")) {
                        if (child.getAttribute("href")) |href| {
                            link_url = href;
                            // Override text color to link blue
                            child_box.style.color = 0xFF89b4fa;
                        }
                    }
                }
                child_box.link_url = link_url;

                // Recurse into children
                try buildChildren(child_box, child, styles, allocator, link_url);

                try parent_box.children.append(allocator, child_box);
            },
            .text => {
                const text = child.textContent() orelse continue;
                // Skip whitespace-only text nodes
                const trimmed = std.mem.trim(u8, text, " \t\n\r");
                if (trimmed.len == 0) continue;

                const text_box = try allocator.create(Box);
                text_box.* = .{};
                text_box.box_type = .inline_text;
                text_box.text = trimmed;
                text_box.parent = parent_box;
                // Inherit style from parent
                text_box.style = parent_box.style;
                text_box.link_url = inherited_link;

                // If inside a link, override color to link blue
                if (inherited_link != null) {
                    text_box.style.color = 0xFF89b4fa;
                }

                try parent_box.children.append(allocator, text_box);
            },
            else => {},
        }
    }
}
