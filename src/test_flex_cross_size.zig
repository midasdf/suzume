const std = @import("std");
const Box = @import("layout/box.zig").Box;
const block = @import("layout/block.zig");
const Style = @import("css/computed.zig").ComputedStyle;
const FontCache = @import("paint/painter.zig").FontCache;

fn checkCrossSize(alignment: Style.AlignItems, sizing: Style.BoxSizing, direction: Style.FlexDirection, wrapping: Style.FlexWrap) !void {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var parent = Box{ .style = .{
        .display = .flex,
        .flex_direction = direction,
        .flex_wrap = wrapping,
        .align_items = alignment,
        .align_content = .flex_start,
        .height = .{ .px = 100 },
    } };
    defer parent.children.deinit(allocator);
    var item = Box{
        .parent = &parent,
        .style = .{ .box_sizing = sizing },
        .padding = .{ .left = 4, .right = 4 },
        .border = .{ .left = 2, .right = 2 },
    };
    defer item.children.deinit(allocator);
    var leaf = Box{ .parent = &item, .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 20 } } };
    defer leaf.children.deinit(allocator);
    try item.children.append(allocator, &leaf);
    try parent.children.append(allocator, &item);
    for ([_]f32{ 300, 200, 300 }) |width| {
        block.layoutBlock(&parent, width, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 80), item.content.width);
        const offset: f32 = if (wrapping != .nowrap) 0 else switch (alignment) {
            .center => (width - 92) / 2,
            .flex_end => width - 92,
            else => 0,
        };
        try std.testing.expectEqual(offset + 6, item.content.x);
        try std.testing.expectEqual(item.content.x, leaf.content.x);
        try std.testing.expectEqual(.auto, item.style.width);
        try std.testing.expectEqual(.auto, item.style.min_width);
        try std.testing.expectEqual(.none, item.style.max_width);
        try std.testing.expectEqual(sizing, item.style.box_sizing);
    }
}

test "column flex auto cross size uses content with center alignment" {
    try checkCrossSize(.center, .content_box, .column, .nowrap);
}

test "reverse column auto cross size uses content with end alignment" {
    try checkCrossSize(.flex_end, .border_box, .column_reverse, .nowrap);
}

test "column flex auto cross size uses content with start alignment" {
    try checkCrossSize(.flex_start, .border_box, .column, .nowrap);
}

test "wrapped column auto cross size uses content within a start-aligned line" {
    try checkCrossSize(.center, .content_box, .column, .wrap);
}

test "column auto cross size honors align-self and explicit constraints" {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var parent = Box{ .style = .{ .display = .flex, .flex_direction = .column } };
    defer parent.children.deinit(allocator);
    var item = Box{ .parent = &parent, .style = .{ .align_self = .center, .min_width = .{ .px = 120 }, .max_width = .{ .px = 50 } } };
    defer item.children.deinit(allocator);
    var leaf = Box{ .parent = &item, .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 20 } } };
    defer leaf.children.deinit(allocator);
    try item.children.append(allocator, &leaf);
    try parent.children.append(allocator, &item);
    block.layoutBlock(&parent, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 120), item.content.width);
    try std.testing.expectEqual(@as(f32, 90), item.content.x);
    try std.testing.expectEqual(@as(f32, 120), item.style.min_width.px);
    try std.testing.expectEqual(@as(f32, 50), item.style.max_width.px);
}

test "empty column flex auto cross size is zero rather than container width" {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var parent = Box{ .style = .{ .display = .flex, .flex_direction = .column, .align_items = .center } };
    defer parent.children.deinit(allocator);
    var item = Box{ .parent = &parent };
    defer item.children.deinit(allocator);
    try parent.children.append(allocator, &item);
    block.layoutBlock(&parent, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 0), item.content.width);
    try std.testing.expectEqual(@as(f32, 150), item.content.x);
}

test "column auto cross size allows an unbreakable intrinsic contribution to overflow" {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var parent = Box{ .style = .{ .display = .flex, .flex_direction = .column, .align_items = .center } };
    defer parent.children.deinit(allocator);
    var item = Box{ .parent = &parent };
    defer item.children.deinit(allocator);
    var leaf = Box{ .parent = &item, .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 20 } } };
    defer leaf.children.deinit(allocator);
    try item.children.append(allocator, &leaf);
    try parent.children.append(allocator, &item);
    block.layoutBlock(&parent, 40, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 80), item.content.width);
    try std.testing.expectEqual(@as(f32, -20), item.content.x);
}

test "column stretch and authored widths remain unchanged" {
    const allocator = std.testing.allocator;
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    var parent = Box{ .style = .{ .display = .flex, .flex_direction = .column } };
    defer parent.children.deinit(allocator);
    var item = Box{ .parent = &parent };
    defer item.children.deinit(allocator);
    try parent.children.append(allocator, &item);
    block.layoutBlock(&parent, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 300), item.content.width);
    parent.style.align_items = .center;
    item.style.width = .{ .percent = 50 };
    block.layoutBlock(&parent, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 150), item.content.width);
    try std.testing.expectEqual(@as(f32, 75), item.content.x);
    item.style.width = .{ .px = 60 };
    block.layoutBlock(&parent, 300, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 60), item.content.width);
    try std.testing.expectEqual(@as(f32, 120), item.content.x);
}
