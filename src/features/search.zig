const std = @import("std");
const Surface = @import("../paint/surface.zig").Surface;
const FontCache = @import("../paint/painter.zig").FontCache;
const GlyphBitmap = @import("../paint/text.zig").GlyphBitmap;
const Box = @import("../layout/box.zig").Box;
const chrome = @import("../ui/chrome.zig");
const nsfb_c = @import("../bindings/nsfb.zig").c;

// Catppuccin Mocha colours
const find_bar_bg: u32 = 0xFF313244; // Surface0
const find_bar_border: u32 = 0xFF45475a; // Surface1
const find_bar_text: u32 = 0xFFcdd6f4; // Text
const find_bar_info: u32 = 0xFF6c7086; // Overlay0
const find_bar_cursor_color: u32 = 0xFFf5e0dc; // Rosewater
const highlight_color: u32 = 0xFFf9e2af; // Yellow

pub const find_bar_height: i32 = 28;

const BlitCtx = struct {
    surface: *Surface,
    colour: u32,
};

fn blitGlyph(ctx: BlitCtx, glyph: GlyphBitmap) void {
    ctx.surface.blitGlyph8(
        glyph.x,
        glyph.y,
        @intCast(glyph.width),
        @intCast(glyph.height),
        glyph.buffer,
        glyph.pitch,
        ctx.colour,
    );
}

/// A text match position within the page content.
pub const Match = struct {
    /// Byte offset into the flattened text.
    offset: usize,
    /// Length of the match.
    length: usize,
    /// Approximate Y position in layout coordinates (for scrolling).
    layout_y: f32,
};

pub const FindBar = struct {
    visible: bool = false,
    search_buf: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,
    matches: std.ArrayListUnmanaged(Match) = .empty,
    current_match: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FindBar {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FindBar) void {
        self.search_buf.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn open(self: *FindBar) void {
        self.visible = true;
        // Select all existing text
        self.cursor = self.search_buf.items.len;
    }

    pub fn close(self: *FindBar) void {
        self.visible = false;
        self.matches.clearRetainingCapacity();
        self.current_match = 0;
    }

    pub fn getSearchText(self: *const FindBar) []const u8 {
        return self.search_buf.items;
    }

    /// Handle a key event in the find bar.
    /// Returns: .consumed if handled, .close if should close, .search if text changed.
    pub const FindResult = enum {
        consumed,
        close,
        search,
        next_match,
        prev_match,
        ignored,
    };

    pub fn handleKey(self: *FindBar, keycode: c_uint, shift_held: bool) FindResult {
        const key: u32 = @intCast(keycode);

        // Escape: close
        if (key == nsfb_c.NSFB_KEY_ESCAPE) {
            return .close;
        }

        // Enter: next/prev match
        if (key == nsfb_c.NSFB_KEY_RETURN or key == nsfb_c.NSFB_KEY_KP_ENTER) {
            if (shift_held) return .prev_match;
            return .next_match;
        }

        // Backspace
        if (key == nsfb_c.NSFB_KEY_BACKSPACE) {
            if (self.cursor > 0) {
                _ = self.search_buf.orderedRemove(self.cursor - 1);
                self.cursor -= 1;
                return .search;
            }
            return .consumed;
        }

        // Delete
        if (key == nsfb_c.NSFB_KEY_DELETE) {
            if (self.cursor < self.search_buf.items.len) {
                _ = self.search_buf.orderedRemove(self.cursor);
                return .search;
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
            if (self.cursor < self.search_buf.items.len) self.cursor += 1;
            return .consumed;
        }

        // Home
        if (key == nsfb_c.NSFB_KEY_HOME) {
            self.cursor = 0;
            return .consumed;
        }

        // End
        if (key == nsfb_c.NSFB_KEY_END) {
            self.cursor = self.search_buf.items.len;
            return .consumed;
        }

        // Printable ASCII
        if (key >= 32 and key <= 126) {
            var ch: u8 = @intCast(key);
            if (shift_held) {
                if (ch >= 'a' and ch <= 'z') {
                    ch -= 32;
                } else {
                    ch = shiftedChar(ch);
                }
            }
            self.search_buf.insert(self.allocator, self.cursor, ch) catch return .ignored;
            self.cursor += 1;
            return .search;
        }

        return .ignored;
    }

    /// Move to the next match.
    pub fn nextMatch(self: *FindBar) void {
        if (self.matches.items.len == 0) return;
        self.current_match = (self.current_match + 1) % self.matches.items.len;
    }

    /// Move to the previous match.
    pub fn prevMatch(self: *FindBar) void {
        if (self.matches.items.len == 0) return;
        if (self.current_match == 0) {
            self.current_match = self.matches.items.len - 1;
        } else {
            self.current_match -= 1;
        }
    }

    /// Get the layout Y position of the current match (for scrolling).
    pub fn currentMatchY(self: *const FindBar) ?f32 {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[self.current_match].layout_y;
    }

    /// Perform text search on the box tree. Finds all matches (case-insensitive).
    pub fn performSearch(self: *FindBar, root_box: ?*const Box) void {
        self.matches.clearRetainingCapacity();
        self.current_match = 0;

        const query = self.search_buf.items;
        if (query.len == 0) return;
        if (root_box == null) return;

        // Walk the box tree and search text content
        self.searchBoxTree(root_box.?, query);
    }

    fn searchBoxTree(self: *FindBar, box: *const Box, query: []const u8) void {
        // Check text in inline_text boxes (line fragments)
        if (box.box_type == .inline_text) {
            for (box.lines.items) |line| {
                self.searchInText(line.text, query, line.y);
            }
            // Also check the box's own text
            if (box.text) |text| {
                self.searchInText(text, query, box.content.y);
            }
        }

        // Recurse into children
        for (box.children.items) |child| {
            self.searchBoxTree(child, query);
        }
    }

    fn searchInText(self: *FindBar, text: []const u8, query: []const u8, layout_y: f32) void {
        if (text.len < query.len) return;

        var i: usize = 0;
        while (i + query.len <= text.len) : (i += 1) {
            if (caseInsensitiveMatch(text[i..][0..query.len], query)) {
                self.matches.append(self.allocator, .{
                    .offset = i,
                    .length = query.len,
                    .layout_y = layout_y,
                }) catch return;
            }
        }
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

fn caseInsensitiveMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

/// Paint the find bar above the status bar.
pub fn paintFindBar(surface: *Surface, fonts: *FontCache, find_bar: *const FindBar) void {
    if (!find_bar.visible) return;

    const y = chrome.window_h - chrome.status_bar_height - find_bar_height;

    // Background
    surface.fillRect(0, y, chrome.window_w, find_bar_height, Surface.argbToColour(find_bar_bg));

    // Top border
    surface.fillRect(0, y, chrome.window_w, 1, Surface.argbToColour(find_bar_border));

    const font_size: u32 = 12;
    const tr = fonts.getRenderer(font_size) orelse return;

    // "Find: " label
    const label = "Find: ";
    const label_m = tr.measure(label);
    const text_y = y + @divTrunc(find_bar_height - label_m.height, 2) + label_m.ascent;
    tr.renderGlyphs(
        label,
        8,
        text_y,
        BlitCtx,
        .{ .surface = surface, .colour = Surface.argbToColour(find_bar_info) },
        blitGlyph,
    );

    const text_x_offset: i32 = 8 + label_m.width + 4;

    // Search text
    const search_text = find_bar.search_buf.items;
    if (search_text.len > 0) {
        tr.renderGlyphs(
            search_text,
            text_x_offset,
            text_y,
            BlitCtx,
            .{ .surface = surface, .colour = Surface.argbToColour(find_bar_text) },
            blitGlyph,
        );
    }

    // Cursor
    {
        const cursor_text = search_text[0..find_bar.cursor];
        const cursor_x: i32 = if (cursor_text.len > 0) blk: {
            const cm = tr.measure(cursor_text);
            break :blk text_x_offset + cm.width;
        } else text_x_offset;
        surface.fillRect(cursor_x, y + 6, 1, find_bar_height - 12, Surface.argbToColour(find_bar_cursor_color));
    }

    // Match count info (right side)
    var info_buf: [64]u8 = undefined;
    const match_count = find_bar.matches.items.len;
    const info = if (search_text.len == 0)
        ""
    else if (match_count == 0)
        "No matches"
    else blk: {
        const current = find_bar.current_match + 1;
        break :blk std.fmt.bufPrint(&info_buf, "{d} of {d}", .{ current, match_count }) catch "";
    };

    if (info.len > 0) {
        const info_m = tr.measure(info);
        tr.renderGlyphs(
            info,
            chrome.window_w - info_m.width - 12,
            text_y,
            BlitCtx,
            .{ .surface = surface, .colour = Surface.argbToColour(find_bar_info) },
            blitGlyph,
        );
    }
}
