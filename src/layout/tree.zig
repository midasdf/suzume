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
    try buildChildren(root_box, body_node, styles, allocator, null, 0);

    return root_box;
}

fn buildChildren(
    parent_box: *Box,
    dom_node: DomNode,
    styles: *const cascade_mod.CascadeResult,
    allocator: std.mem.Allocator,
    inherited_link: ?[]const u8,
    list_counter_start: u32,
) !void {
    var child_opt = dom_node.firstChild();
    var list_counter: u32 = list_counter_start;
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
                    .block, .list_item, .flex, .grid => .block,
                    .table => .block,
                    .table_row, .table_cell, .table_row_group,
                    .table_header_group, .table_footer_group,
                    .table_column, .table_column_group, .table_caption => .block,
                    .inline_block, .inline_flex => .block,
                    else => .block, // treat everything as block
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
                child_box.border = .{
                    .top = style.border_top_width,
                    .right = style.border_right_width,
                    .bottom = style.border_bottom_width,
                    .left = style.border_left_width,
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

                    // Handle <img> elements as replaced boxes
                    if (std.mem.eql(u8, tag, "img")) {
                        child_box.box_type = .replaced;
                        child_box.image_url = child.getAttribute("src");

                        // Read width/height attributes
                        var img_w: f32 = 300; // default placeholder
                        var img_h: f32 = 150;
                        if (child.getAttribute("width")) |w_str| {
                            img_w = parseFloatAttr(w_str);
                        }
                        if (child.getAttribute("height")) |h_str| {
                            img_h = parseFloatAttr(h_str);
                        }
                        child_box.intrinsic_width = img_w;
                        child_box.intrinsic_height = img_h;
                    }

                    // Handle <hr> as a special replaced element
                    if (std.mem.eql(u8, tag, "hr")) {
                        child_box.is_hr = true;
                    }

                    // Track list item counters
                    if (style.display == .list_item) {
                        list_counter += 1;
                        child_box.list_index = list_counter;
                    }
                }
                child_box.link_url = link_url;

                // Recurse into children (skip for replaced elements)
                if (child_box.box_type != .replaced) {
                    // If this is an ordered/unordered list, start counter at 0
                    const sub_counter: u32 = if (child.tagName()) |tag| blk: {
                        if (std.mem.eql(u8, tag, "ol") or std.mem.eql(u8, tag, "ul")) {
                            break :blk 0;
                        }
                        break :blk list_counter;
                    } else list_counter;
                    try buildChildren(child_box, child, styles, allocator, link_url, sub_counter);
                }

                try parent_box.children.append(allocator, child_box);
            },
            .text => {
                const text = child.textContent() orelse continue;

                // Handle white-space property
                const is_pre = parent_box.style.white_space == .pre or
                    parent_box.style.white_space == .pre_wrap;

                if (is_pre) {
                    // In pre mode, preserve whitespace (but still skip completely empty)
                    if (text.len == 0) continue;

                    const text_box = try allocator.create(Box);
                    text_box.* = .{};
                    text_box.box_type = .inline_text;
                    text_box.text = text;
                    text_box.parent = parent_box;
                    text_box.style = parent_box.style;
                    text_box.link_url = inherited_link;

                    if (inherited_link != null) {
                        text_box.style.color = 0xFF89b4fa;
                    }

                    try parent_box.children.append(allocator, text_box);
                } else {
                    // Normal mode: skip whitespace-only text nodes
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
                }
            },
            else => {},
        }
    }
}

/// Parse a numeric attribute string (e.g. "300" or "150.5") to f32.
fn parseFloatAttr(s: []const u8) f32 {
    // Parse digits and optional decimal point
    var result: f32 = 0;
    var frac: f32 = 0;
    var frac_div: f32 = 1;
    var in_frac = false;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            if (in_frac) {
                frac_div *= 10;
                frac += @as(f32, @floatFromInt(ch - '0')) / frac_div;
            } else {
                result = result * 10 + @as(f32, @floatFromInt(ch - '0'));
            }
        } else if (ch == '.') {
            in_frac = true;
        } else {
            break; // stop at non-numeric (e.g. "px")
        }
    }
    return result + frac;
}
