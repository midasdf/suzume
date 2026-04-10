const std = @import("std");
const coords = @import("coords.zig");

pub const BrowserContext = struct {
    allocator: std.mem.Allocator,
    active_tab: usize = 0,
    scroll: coords.ScrollOffset = .{},
    needs_repaint: bool = true,
    running: bool = true,
};
