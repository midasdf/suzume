const std = @import("std");
const event_loop = @import("../event_loop.zig");

/// Common keyboard shortcuts. Returns true if shortcut was handled.
pub fn handleShortcut(key: event_loop.KeyEvent) ?ShortcutAction {
    if (key.ctrlHeld()) {
        return switch (key.keysym) {
            'l' => .focus_url,
            't' => .new_tab,
            'w' => .close_tab,
            'q' => .quit,
            else => null,
        };
    }
    return null;
}

pub const ShortcutAction = enum {
    focus_url,
    new_tab,
    close_tab,
    quit,
};
