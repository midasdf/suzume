// src/coords.zig
const std = @import("std");

/// Position in X11 window (0,0 = top-left of window)
pub const ScreenPos = struct {
    x: f32,
    y: f32,

    pub fn fromInt(x: i32, y: i32) ScreenPos {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }
};

/// Position in content area (0,0 = top-left below Chrome)
pub const ContentPos = struct {
    x: f32,
    y: f32,
};

/// Position in page layout (includes scroll offset)
pub const LayoutPos = struct {
    x: f32,
    y: f32,
};

pub const ScrollOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub fn screenToContent(pos: ScreenPos, chrome_height: f32) ContentPos {
    return .{ .x = pos.x, .y = pos.y - chrome_height };
}

pub fn contentToLayout(pos: ContentPos, scroll: ScrollOffset) LayoutPos {
    return .{ .x = pos.x + scroll.x, .y = pos.y + scroll.y };
}

pub fn screenToLayout(pos: ScreenPos, chrome_height: f32, scroll: ScrollOffset) LayoutPos {
    return contentToLayout(screenToContent(pos, chrome_height), scroll);
}

test "screenToContent subtracts chrome height" {
    const pos = screenToContent(.{ .x = 100, .y = 164 }, 64);
    try std.testing.expectEqual(@as(f32, 100), pos.x);
    try std.testing.expectEqual(@as(f32, 100), pos.y);
}

test "contentToLayout adds scroll offset" {
    const pos = contentToLayout(.{ .x = 50, .y = 50 }, .{ .x = 10, .y = 200 });
    try std.testing.expectEqual(@as(f32, 60), pos.x);
    try std.testing.expectEqual(@as(f32, 250), pos.y);
}

test "screenToLayout composes both transforms" {
    const pos = screenToLayout(.{ .x = 100, .y = 164 }, 64, .{ .x = 0, .y = 300 });
    try std.testing.expectEqual(@as(f32, 100), pos.x);
    try std.testing.expectEqual(@as(f32, 400), pos.y);
}
