const std = @import("std");
const Surface = @import("paint/surface.zig").Surface;
const c = @import("bindings/nsfb.zig").c;

test "RAM framebuffer uses little-endian BGRX and preserves RGB channels" {
    var surface = try Surface.initRam(8, 8);
    defer surface.deinit();
    surface.fillRect(0, 0, 8, 8, Surface.argbToColour(0xffffffff));
    var ptr: ?[*]u8 = null;
    var stride: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.nsfb_get_buffer(surface.fb, @ptrCast(&ptr), &stride));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, ptr.?[0..3]);
    surface.fillRect(0, 0, 1, 1, Surface.argbToColour(0xff123456));
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12 }, ptr.?[0..3]);
    try surface.resize(12, 10);
    try std.testing.expectEqual(@as(i32, 12), surface.width);
    try std.testing.expectEqual(@as(i32, 10), surface.height);
}

test "surfaces reject non-positive dimensions before backend allocation" {
    const sizes = [_][2]i32{ .{ 0, 8 }, .{ 8, 0 }, .{ -1, 8 }, .{ 8, -1 } };
    for (sizes) |size| {
        try std.testing.expectError(error.InvalidGeometry, Surface.initRam(size[0], size[1]));
        try std.testing.expectError(error.InvalidGeometry, Surface.init(size[0], size[1]));
    }
}

test "invalid resize preserves the framebuffer" {
    var surface = try Surface.initRam(8, 8);
    defer surface.deinit();
    const sizes = [_][2]i32{ .{ 0, 8 }, .{ 8, 0 }, .{ -1, 8 }, .{ 8, -1 } };
    for (sizes) |size| {
        try std.testing.expectError(error.InvalidGeometry, surface.resize(size[0], size[1]));
        try std.testing.expectEqual(@as(i32, 8), surface.width);
        try std.testing.expectEqual(@as(i32, 8), surface.height);
    }
}

test "RAM screenshot surfaces retain dimensions beyond the screen" {
    var surface = try Surface.initRam(64, 6000);
    defer surface.deinit();
    surface.refreshGeometry();
    try std.testing.expectEqual(@as(i32, 64), surface.width);
    try std.testing.expectEqual(@as(i32, 6000), surface.height);
}
