const std = @import("std");
const theme = @import("theme.zig").theme;

pub const StatusBar = struct {
    height: f32,
    text: []const u8 = "Ready",
    hover_url: ?[]const u8 = null,

    pub fn setStatus(self: *StatusBar, text: []const u8) void {
        self.text = text;
    }

    pub fn setHoverUrl(self: *StatusBar, url: ?[]const u8) void {
        self.hover_url = url;
    }

    /// Returns the display text (hover URL takes priority over status).
    pub fn displayText(self: *const StatusBar) []const u8 {
        return self.hover_url orelse self.text;
    }
};
