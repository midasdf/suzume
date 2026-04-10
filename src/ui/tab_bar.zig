const std = @import("std");
const coords = @import("../coords.zig");
const theme = @import("theme.zig").theme;

pub const TabAction = union(enum) {
    none: void,
    switch_tab: usize,
    close_tab: usize,
    new_tab: void,
};

pub const TabInfo = struct {
    title: []const u8,
    is_active: bool,
};

pub const TabBar = struct {
    height: f32,
    scroll_offset: f32 = 0,

    pub fn hitTest(self: *const TabBar, pos: coords.ScreenPos, tab_count: usize, window_width: u32) TabAction {
        if (pos.y < 0 or pos.y >= self.height) return .{ .none = {} };

        const tab_width: f32 = @min(180, @as(f32, @floatFromInt(window_width)) / @as(f32, @floatFromInt(@max(1, tab_count + 1))));
        const tab_index: usize = @intFromFloat(@max(0, pos.x) / tab_width);

        if (tab_index >= tab_count) {
            return .{ .new_tab = {} };
        }

        // Close button: right 18px of tab
        const tab_right = @as(f32, @floatFromInt(tab_index + 1)) * tab_width;
        if (pos.x > tab_right - 18) {
            return .{ .close_tab = tab_index };
        }

        return .{ .switch_tab = tab_index };
    }
};
