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
    selection_anchor: ?usize = null,

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
        self.buf.ensureTotalCapacity(self.allocator, text.len) catch return;
        self.buf.clearRetainingCapacity();
        self.buf.appendSliceAssumeCapacity(text);
        self.cursor = text.len;
        self.selection_anchor = null;
    }

    pub fn selectAll(self: *TextInput) void {
        self.selection_anchor = 0;
        self.cursor = self.buf.items.len;
    }

    pub fn selectedText(self: *const TextInput) []const u8 {
        const anchor = self.selection_anchor orelse return "";
        return self.buf.items[@min(anchor, self.cursor)..@max(anchor, self.cursor)];
    }

    fn deleteSelection(self: *TextInput) bool {
        const anchor = self.selection_anchor orelse return false;
        const start = @min(anchor, self.cursor);
        const end = @max(anchor, self.cursor);
        std.mem.copyForwards(u8, self.buf.items[start..], self.buf.items[end..]);
        self.buf.items.len -= end - start;
        self.cursor = start;
        self.selection_anchor = null;
        return start != end;
    }

    fn previousBoundary(self: *const TextInput) usize {
        if (self.cursor == 0) return 0;
        var pos = self.cursor - 1;
        while (pos > 0 and self.buf.items[pos] & 0xc0 == 0x80) pos -= 1;
        return pos;
    }

    fn nextBoundary(self: *const TextInput) usize {
        if (self.cursor >= self.buf.items.len) return self.buf.items.len;
        var pos = self.cursor + 1;
        while (pos < self.buf.items.len and self.buf.items[pos] & 0xc0 == 0x80) pos += 1;
        return pos;
    }

    fn moveCursor(self: *TextInput, pos: usize, selecting: bool) void {
        if (selecting) {
            if (self.selection_anchor == null) self.selection_anchor = self.cursor;
        } else self.selection_anchor = null;
        self.cursor = pos;
    }

    /// Insert arbitrary UTF-8 text at the current cursor position.
    /// Used by XIM to insert composed text (e.g., Japanese characters).
    pub fn insertText(self: *TextInput, text: []const u8) void {
        // Ensure capacity for the new text
        self.buf.ensureUnusedCapacity(self.allocator, text.len) catch return;
        _ = self.deleteSelection();
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
            if (!self.deleteSelection() and self.cursor > 0) {
                const start = self.previousBoundary();
                std.mem.copyForwards(u8, self.buf.items[start..], self.buf.items[self.cursor..]);
                self.buf.items.len -= self.cursor - start;
                self.cursor = start;
            }
            return .consumed;
        }

        // Delete
        if (key == nsfb_c.NSFB_KEY_DELETE) {
            if (!self.deleteSelection() and self.cursor < self.buf.items.len) {
                const end = self.nextBoundary();
                std.mem.copyForwards(u8, self.buf.items[self.cursor..], self.buf.items[end..]);
                self.buf.items.len -= end - self.cursor;
            }
            return .consumed;
        }

        // Left arrow
        if (key == nsfb_c.NSFB_KEY_LEFT) {
            const pos = if (!shift_held and self.selectedText().len > 0)
                @min(self.selection_anchor.?, self.cursor)
            else
                self.previousBoundary();
            self.moveCursor(pos, shift_held);
            return .consumed;
        }

        // Right arrow
        if (key == nsfb_c.NSFB_KEY_RIGHT) {
            const pos = if (!shift_held and self.selectedText().len > 0)
                @max(self.selection_anchor.?, self.cursor)
            else
                self.nextBoundary();
            self.moveCursor(pos, shift_held);
            return .consumed;
        }

        // Home
        if (key == nsfb_c.NSFB_KEY_HOME) {
            self.moveCursor(0, shift_held);
            return .consumed;
        }

        // End
        if (key == nsfb_c.NSFB_KEY_END) {
            self.moveCursor(self.buf.items.len, shift_held);
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

            self.insertText(&.{ch});
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

test "UTF-8 cursor movement and deletion keep complete codepoints" {
    var input = TextInput.init(std.testing.allocator);
    defer input.deinit();
    input.setText("a日本b");
    _ = input.handleKey(nsfb_c.NSFB_KEY_LEFT, false);
    _ = input.handleKey(nsfb_c.NSFB_KEY_BACKSPACE, false);
    try std.testing.expectEqualStrings("a日b", input.getText());
    _ = input.handleKey(nsfb_c.NSFB_KEY_LEFT, false);
    _ = input.handleKey(nsfb_c.NSFB_KEY_DELETE, false);
    try std.testing.expectEqualStrings("ab", input.getText());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
}

test "select-all replaces text on typing or paste without losing the old URL first" {
    var input = TextInput.init(std.testing.allocator);
    defer input.deinit();
    input.setText("https://example.com");
    input.selectAll();
    try std.testing.expectEqualStrings("https://example.com", input.selectedText());
    input.insertText("日本語");
    try std.testing.expectEqualStrings("日本語", input.getText());
    input.selectAll();
    _ = input.handleKey(nsfb_c.NSFB_KEY_a, false);
    try std.testing.expectEqualStrings("a", input.getText());
}

test "shift selection uses UTF-8 boundaries and collapses on an unshifted arrow" {
    var input = TextInput.init(std.testing.allocator);
    defer input.deinit();
    input.setText("a日b");
    _ = input.handleKey(nsfb_c.NSFB_KEY_LEFT, true);
    _ = input.handleKey(nsfb_c.NSFB_KEY_LEFT, true);
    try std.testing.expectEqualStrings("日b", input.selectedText());
    _ = input.handleKey(nsfb_c.NSFB_KEY_RIGHT, false);
    try std.testing.expectEqual(input.getText().len, input.cursor);
    try std.testing.expectEqualStrings("", input.selectedText());
    input.selectAll();
    _ = input.handleKey(nsfb_c.NSFB_KEY_DELETE, false);
    try std.testing.expectEqualStrings("", input.getText());
}

test "setText allocation failure preserves cursor and text" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var input = TextInput.init(failing.allocator());
    defer input.deinit();
    input.setText("https://example.com");
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
    try std.testing.expectEqualStrings("", input.getText());
}
