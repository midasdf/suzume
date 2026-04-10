// src/render/pipeline.zig
const std = @import("std");
const coords = @import("../coords.zig");
const theme = @import("../ui/theme.zig").theme;

/// Orchestrates the full render cycle: clear → chrome → content → present.
/// Concrete surface/painter types will be wired during integration (Task 15-16).
pub const RenderPipeline = struct {
    chrome_height: f32 = 64,

    /// Compute the content area viewport.
    pub fn contentViewport(self: *const RenderPipeline, win_w: u32, win_h: u32) struct {
        clip_top: i32,
        clip_bottom: i32,
        width: u32,
        height: u32,
    } {
        const chrome_y: i32 = @intFromFloat(self.chrome_height);
        return .{
            .clip_top = chrome_y,
            .clip_bottom = @intCast(win_h),
            .width = win_w,
            .height = win_h - @as(u32, @intFromFloat(self.chrome_height)),
        };
    }
};
