const std = @import("std");
const coords = @import("../coords.zig");
const theme = @import("theme.zig").theme;

pub const UrlBar = struct {
    y_offset: f32,
    height: f32,
    focused: bool = false,
    text: []const u8 = "",

    pub fn hitTest(self: *const UrlBar, pos: coords.ScreenPos) bool {
        return pos.y >= self.y_offset and pos.y < self.y_offset + self.height;
    }

    pub fn setText(self: *UrlBar, new_text: []const u8) void {
        self.text = new_text;
    }
};
