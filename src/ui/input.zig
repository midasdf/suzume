const std = @import("std");
const nsfb_c = @import("../bindings/nsfb.zig").c;

/// Result of handling a key event in the text input.
pub const InputResult = enum {
    /// Key was consumed, text may have changed.
    consumed,
    /// User pressed Enter — submit the current text.
    submit,
    /// User pressed Escape — cancel editing.
    cancel,
    /// Key was not handled by the input (pass to other handlers).
    ignored,
};

/// Simple single-line text input buffer with cursor.
pub const TextInput = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    cursor: usize = 0,
    focused: bool = false,

    pub fn init(allocator: std.mem.Allocator) TextInput {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextInput) void {
        self.buf.deinit(self.allocator);
    }

    pub fn getText(self: *const TextInput) []const u8 {
        return self.buf.items;
    }

    pub fn setText(self: *TextInput, text: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.allocator, text) catch {};
        self.cursor = text.len;
    }

    /// Insert arbitrary UTF-8 text at the current cursor position.
    /// Used by XIM to insert composed text (e.g., Japanese characters).
    pub fn insertText(self: *TextInput, text: []const u8) void {
        // Ensure capacity for the new text
        self.buf.ensureUnusedCapacity(self.allocator, text.len) catch return;
        // Shift existing content right to make room
        const old_len = self.buf.items.len;
        self.buf.items.len += text.len;
        // Move bytes from cursor position to the right
        if (self.cursor < old_len) {
            std.mem.copyBackwards(u8, self.buf.items[self.cursor + text.len ..], self.buf.items[self.cursor..old_len]);
        }
        // Copy new text into the gap
        @memcpy(self.buf.items[self.cursor .. self.cursor + text.len], text);
        self.cursor += text.len;
    }

    /// Handle a KEY_DOWN event. Returns what happened.
    pub fn handleKey(self: *TextInput, keycode: c_uint, shift_held: bool) InputResult {
        const key: u32 = @intCast(keycode);

        // Enter / Return
        if (key == nsfb_c.NSFB_KEY_RETURN or key == nsfb_c.NSFB_KEY_KP_ENTER) {
            return .submit;
        }

        // Escape
        if (key == nsfb_c.NSFB_KEY_ESCAPE) {
            return .cancel;
        }

        // Backspace
        if (key == nsfb_c.NSFB_KEY_BACKSPACE) {
            if (self.cursor > 0) {
                _ = self.buf.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
            }
            return .consumed;
        }

        // Delete
        if (key == nsfb_c.NSFB_KEY_DELETE) {
            if (self.cursor < self.buf.items.len) {
                _ = self.buf.orderedRemove(self.cursor);
            }
            return .consumed;
        }

        // Left arrow
        if (key == nsfb_c.NSFB_KEY_LEFT) {
            if (self.cursor > 0) self.cursor -= 1;
            return .consumed;
        }

        // Right arrow
        if (key == nsfb_c.NSFB_KEY_RIGHT) {
            if (self.cursor < self.buf.items.len) self.cursor += 1;
            return .consumed;
        }

        // Home
        if (key == nsfb_c.NSFB_KEY_HOME) {
            self.cursor = 0;
            return .consumed;
        }

        // End
        if (key == nsfb_c.NSFB_KEY_END) {
            self.cursor = self.buf.items.len;
            return .consumed;
        }

        // Printable ASCII characters (space through tilde)
        if (key >= 32 and key <= 126) {
            var ch: u8 = @intCast(key);

            // LibNSFB key codes for letters are lowercase (a=97..z=122).
            // Apply shift to get uppercase and shifted symbols.
            if (shift_held) {
                if (ch >= 'a' and ch <= 'z') {
                    ch -= 32; // uppercase
                } else {
                    ch = shiftedChar(ch);
                }
            }

            self.buf.insert(self.allocator, self.cursor, ch) catch return .ignored;
            self.cursor += 1;
            return .consumed;
        }

        return .ignored;
    }

    fn shiftedChar(ch: u8) u8 {
        return switch (ch) {
            '1' => '!',
            '2' => '@',
            '3' => '#',
            '4' => '$',
            '5' => '%',
            '6' => '^',
            '7' => '&',
            '8' => '*',
            '9' => '(',
            '0' => ')',
            '-' => '_',
            '=' => '+',
            '[' => '{',
            ']' => '}',
            '\\' => '|',
            ';' => ':',
            '\'' => '"',
            ',' => '<',
            '.' => '>',
            '/' => '?',
            '`' => '~',
            else => ch,
        };
    }
};
