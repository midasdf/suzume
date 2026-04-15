const std = @import("std");
const env = @import("../env.zig");
const coords = @import("../coords.zig");
const TabBar = @import("tab_bar.zig").TabBar;
const TabAction = @import("tab_bar.zig").TabAction;
const TabInfo = @import("tab_bar.zig").TabInfo;
const UrlBar = @import("url_bar.zig").UrlBar;
const StatusBar = @import("status_bar.zig").StatusBar;

pub const ChromeAction = union(enum) {
    navigate: []const u8,
    new_tab: void,
    close_tab: usize,
    switch_tab: usize,
    go_back: void,
    go_forward: void,
    focus_url: void,
};

pub const Chrome = struct {
    tab_bar: TabBar,
    url_bar: UrlBar,
    status_bar: StatusBar,

    pub fn init(window_width: u32, _: u32) Chrome {
        const m = chromeMetrics(window_width);
        return .{
            .tab_bar = .{ .height = m.tab_height },
            .url_bar = .{
                .y_offset = m.tab_height,
                .height = m.url_height,
            },
            .status_bar = .{ .height = m.status_height },
        };
    }

    pub fn totalHeight(self: *const Chrome) f32 {
        return self.tab_bar.height + self.url_bar.height;
    }

    pub fn handleClick(self: *Chrome, pos: coords.ScreenPos, tab_count: usize, window_width: u32) ?ChromeAction {
        // Tab bar
        const tab_action = self.tab_bar.hitTest(pos, tab_count, window_width);
        switch (tab_action) {
            .switch_tab => |idx| return .{ .switch_tab = idx },
            .close_tab => |idx| return .{ .close_tab = idx },
            .new_tab => return .{ .new_tab = {} },
            .none => {},
        }

        // URL bar
        if (self.url_bar.hitTest(pos)) {
            self.url_bar.focused = true;
            return .{ .focus_url = {} };
        }

        return null;
    }

    pub fn isInChrome(self: *const Chrome, pos: coords.ScreenPos) bool {
        return pos.y < self.totalHeight();
    }

    fn chromeMetrics(window_width: u32) struct {
        tab_height: f32,
        url_height: f32,
        status_height: f32,
    } {
        const override = env.get("SUZUME_CHROME_SIZE");
        const compact = if (override) |v|
            std.mem.eql(u8, v, "compact")
        else
            window_width <= 800;

        if (compact) {
            return .{ .tab_height = 22, .url_height = 28, .status_height = 18 };
        } else {
            return .{ .tab_height = 28, .url_height = 36, .status_height = 24 };
        }
    }
};
