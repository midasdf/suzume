const std = @import("std");
const Box = @import("layout/box.zig").Box;
const block = @import("layout/block.zig");
const ComputedStyle = @import("css/computed.zig").ComputedStyle;
const FontCache = @import("paint/painter.zig").FontCache;

fn checkNestedFlex(direction: ComputedStyle.FlexDirection, sizing: ComputedStyle.BoxSizing) !void {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var outer = Box{
        .style = .{ .display = .flex, .flex_direction = .column, .width = .{ .px = 300 }, .height = .{ .px = 200 } },
        .padding = .{ .left = 10, .top = 10 },
        .border = .{ .left = 2, .top = 2 },
    };
    defer outer.children.deinit(allocator);
    var inner = Box{
        .parent = &outer,
        .style = .{
            .display = .flex,
            .flex_direction = direction,
            .flex_grow = 1,
            .align_items = .center,
            .justify_content = .center,
            .box_sizing = sizing,
        },
        .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        .border = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
    };
    defer inner.children.deinit(allocator);
    var leaf = Box{
        .parent = &inner,
        .style = .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .flex_shrink = 0 },
    };
    defer leaf.children.deinit(allocator);
    try inner.children.append(allocator, &leaf);
    try outer.children.append(allocator, &inner);

    for ([_]f32{ 200, 120, 200 }) |height| {
        outer.style.height = .{ .px = height };
        block.layoutBlock(&outer, 400, 0, &fonts);
        try std.testing.expectEqual(height - 12, inner.content.height);
        try std.testing.expectEqual(@as(f32, 288), inner.content.width);
        try std.testing.expectEqual(outer.content.y + 6, inner.content.y);
        try std.testing.expectEqual(inner.content.y + (inner.content.height - 40) / 2, leaf.content.y);
        try std.testing.expectEqual(inner.content.x + (inner.content.width - 40) / 2, leaf.content.x);
        try std.testing.expectEqual(.auto, inner.style.height);
        try std.testing.expectEqual(.auto, inner.style.width);
        try std.testing.expectEqual(sizing, inner.style.box_sizing);
    }
}

fn checkPercentInsets(sizing: ComputedStyle.BoxSizing) !void {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var outer = Box{ .style = .{ .display = .flex, .flex_direction = .column, .height = .{ .px = 200 } } };
    defer outer.children.deinit(allocator);
    var inner = Box{
        .parent = &outer,
        .style = .{
            .display = .flex,
            .flex_direction = .column,
            .width = .{ .px = 150 },
            .flex_grow = 1,
            .justify_content = .center,
            .box_sizing = sizing,
            .padding_left = 5,
            .padding_left_is_pct = true,
            .padding_right = 5,
            .padding_right_is_pct = true,
        },
    };
    defer inner.children.deinit(allocator);
    var leaf = Box{ .parent = &inner, .style = .{ .height = .{ .px = 40 }, .flex_shrink = 0 } };
    defer leaf.children.deinit(allocator);
    try inner.children.append(allocator, &leaf);
    try outer.children.append(allocator, &inner);
    block.layoutBlock(&outer, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 15), inner.padding.left);
    try std.testing.expectEqual(@as(f32, 15), inner.padding.right);
    try std.testing.expectEqual(inner.content.y + 80, leaf.content.y);
}

test "nested flex reflow preserves parent-relative percentage insets in content-box" {
    try checkPercentInsets(.content_box);
}

test "nested flex reflow preserves parent-relative percentage insets in border-box" {
    try checkPercentInsets(.border_box);
}

test "nested flex column reflow retains used content-box height and origin" {
    try checkNestedFlex(.column, .content_box);
}

test "nested flex row reflow retains used content-box height and origin" {
    try checkNestedFlex(.row, .content_box);
}

test "nested flex column reflow retains used border-box height and origin" {
    try checkNestedFlex(.column, .border_box);
}

test "nested flex row reflow retains used border-box height and origin" {
    try checkNestedFlex(.row, .border_box);
}
