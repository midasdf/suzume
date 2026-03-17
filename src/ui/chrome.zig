const std = @import("std");
const Surface = @import("../paint/surface.zig").Surface;
const FontCache = @import("../paint/painter.zig").FontCache;
const TextRenderer = @import("../paint/text.zig").TextRenderer;
const GlyphBitmap = @import("../paint/text.zig").GlyphBitmap;
const TextInput = @import("input.zig").TextInput;
const TabManager = @import("tabs.zig").TabManager;

// Layout constants (fixed chrome heights)
pub const url_bar_height: i32 = 36;
pub const tab_bar_height: i32 = 28;
pub const status_bar_height: i32 = 24;
pub const content_y: i32 = url_bar_height + tab_bar_height;

/// Default initial window size (used at Surface.init time).
pub const default_window_w: i32 = 720;
pub const default_window_h: i32 = 720;

/// Compute the content area height from the actual window height.
pub fn contentHeight(window_h: i32) i32 {
    return window_h - url_bar_height - tab_bar_height - status_bar_height;
}

// Tab bar layout
const tab_max_width: i32 = 160;
const tab_min_width: i32 = 60;
const tab_padding: i32 = 8;
const tab_close_size: i32 = 16;
const new_tab_btn_width: i32 = 28;

// Catppuccin Mocha colours (ARGB)
const url_bar_bg: u32 = 0xFF313244; // Surface0
const url_bar_border: u32 = 0xFF45475a; // Surface1
const url_bar_text_color: u32 = 0xFFcdd6f4; // Text
const url_bar_cursor_color: u32 = 0xFFf5e0dc; // Rosewater
const status_bar_bg: u32 = 0xFF181825; // Mantle
const status_bar_text_color: u32 = 0xFF6c7086; // Overlay0
const content_bg: u32 = 0xFF1e1e2e; // Base

const tab_active_bg: u32 = 0xFF313244; // Surface0
const tab_inactive_bg: u32 = 0xFF1e1e2e; // Base
const tab_private_active_bg: u32 = 0xFF45275a; // Purple-tinted for private tabs
const tab_private_inactive_bg: u32 = 0xFF2a1e3e; // Darker purple for inactive private tabs
const tab_bar_bg: u32 = 0xFF181825; // Mantle
const tab_text_color: u32 = 0xFFcdd6f4; // Text
const tab_inactive_text: u32 = 0xFF6c7086; // Overlay0
const tab_close_color: u32 = 0xFF6c7086; // Overlay0
const tab_border_color: u32 = 0xFF45475a; // Surface1
const new_tab_text_color: u32 = 0xFF6c7086; // Overlay0

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

/// Paint the URL bar at the top of the window.
pub fn paintUrlBar(surface: *Surface, fonts: *FontCache, input: *const TextInput) void {
    // Background
    surface.fillRect(0, 0, surface.width, url_bar_height, Surface.argbToColour(url_bar_bg));

    // Border bottom
    surface.fillRect(0, url_bar_height - 1, surface.width, 1, Surface.argbToColour(url_bar_border));

    // Text
    const text = input.getText();
    if (text.len > 0) {
        const font_size: u32 = 14;
        const tr = fonts.getRenderer(font_size) orelse return;
        const metrics = tr.measure(text);
        const text_y: i32 = @divTrunc(url_bar_height - metrics.height, 2) + metrics.ascent;

        tr.renderGlyphs(
            text,
            8, // left padding
            text_y,
            BlitCtx,
            .{ .surface = surface, .colour = Surface.argbToColour(url_bar_text_color) },
            blitGlyph,
        );

        // Draw cursor if focused
        if (input.focused) {
            // Measure text up to cursor position
            const cursor_text = text[0..input.cursor];
            const cursor_x: i32 = if (cursor_text.len > 0) blk: {
                const cm = tr.measure(cursor_text);
                break :blk 8 + cm.width;
            } else 8;

            surface.fillRect(cursor_x, 6, 1, url_bar_height - 12, Surface.argbToColour(url_bar_cursor_color));
        }
    } else if (input.focused) {
        // Just cursor at start
        surface.fillRect(8, 6, 1, url_bar_height - 12, Surface.argbToColour(url_bar_cursor_color));
    }
}

/// Paint the tab bar below the URL bar.
pub fn paintTabBar(surface: *Surface, fonts: *FontCache, tab_mgr: *const TabManager) void {
    const y = url_bar_height;

    // Background
    surface.fillRect(0, y, surface.width, tab_bar_height, Surface.argbToColour(tab_bar_bg));

    // Border bottom
    surface.fillRect(0, y + tab_bar_height - 1, surface.width, 1, Surface.argbToColour(tab_border_color));

    const tab_count = tab_mgr.tabCount();
    if (tab_count == 0) return;

    // Calculate tab width
    const available_w = surface.width - new_tab_btn_width;
    var tab_w: i32 = @divTrunc(available_w, @as(i32, @intCast(tab_count)));
    tab_w = @min(tab_w, tab_max_width);
    tab_w = @max(tab_w, tab_min_width);

    const font_size: u32 = 12;
    const tr = fonts.getRenderer(font_size) orelse return;

    for (tab_mgr.tabs.items, 0..) |tab, i| {
        const tx: i32 = @as(i32, @intCast(i)) * tab_w;
        if (tx >= available_w) break;

        const is_active = (i == tab_mgr.active_index);
        const bg = if (tab.is_private)
            (if (is_active) tab_private_active_bg else tab_private_inactive_bg)
        else
            (if (is_active) tab_active_bg else tab_inactive_bg);
        const text_col = if (is_active) tab_text_color else tab_inactive_text;

        // Tab background
        surface.fillRect(tx, y, tab_w, tab_bar_height - 1, Surface.argbToColour(bg));

        // Right border
        surface.fillRect(tx + tab_w - 1, y + 4, 1, tab_bar_height - 8, Surface.argbToColour(tab_border_color));

        // Tab title (truncated)
        const max_text_w = tab_w - tab_padding * 2 - tab_close_size;
        if (max_text_w > 0) {
            const title = tab.title;
            if (title.len > 0) {
                // Truncate title to fit
                var display_len = title.len;
                while (display_len > 0) {
                    const m = tr.measure(title[0..display_len]);
                    if (m.width <= max_text_w) break;
                    display_len -= 1;
                }
                if (display_len > 0) {
                    const m = tr.measure(title[0..display_len]);
                    const text_y_pos = y + @divTrunc(tab_bar_height - 1 - m.height, 2) + m.ascent;
                    tr.renderGlyphs(
                        title[0..display_len],
                        tx + tab_padding,
                        text_y_pos,
                        BlitCtx,
                        .{ .surface = surface, .colour = Surface.argbToColour(text_col) },
                        blitGlyph,
                    );
                }
            }
        }

        // Close button (x) - diagonal cross
        const close_x = tx + tab_w - tab_close_size - 2;
        const close_y = y + @divTrunc(tab_bar_height - 1 - 8, 2);
        const close_colour = Surface.argbToColour(tab_close_color);
        // Draw X using two diagonal lines (top-left to bottom-right, top-right to bottom-left)
        var di: i32 = 0;
        while (di < 8) : (di += 1) {
            // Top-left to bottom-right diagonal
            surface.fillRect(close_x + 2 + di, close_y + di, 1, 1, close_colour);
            // Top-right to bottom-left diagonal
            surface.fillRect(close_x + 9 - di, close_y + di, 1, 1, close_colour);
        }
    }

    // New tab (+) button
    const plus_x = @as(i32, @intCast(tab_count)) * tab_w;
    if (plus_x < surface.width) {
        const plus_text = "+";
        const m = tr.measure(plus_text);
        const text_y_pos = y + @divTrunc(tab_bar_height - 1 - m.height, 2) + m.ascent;
        tr.renderGlyphs(
            plus_text,
            plus_x + @divTrunc(new_tab_btn_width - m.width, 2),
            text_y_pos,
            BlitCtx,
            .{ .surface = surface, .colour = Surface.argbToColour(new_tab_text_color) },
            blitGlyph,
        );
    }
}

/// Result of a click in the tab bar area.
pub const TabClickResult = enum {
    none,
    switch_tab,
    close_tab,
    new_tab,
};

pub const TabClickInfo = struct {
    action: TabClickResult,
    index: usize,
};

/// Test if a click at (mx, my) hits the tab bar and what action to take.
pub fn hitTestTabBar(mx: i32, my: i32, tab_mgr: *const TabManager, win_w: i32) TabClickInfo {
    const y = url_bar_height;
    if (my < y or my >= y + tab_bar_height) return .{ .action = .none, .index = 0 };

    const tab_count = tab_mgr.tabCount();
    if (tab_count == 0) return .{ .action = .none, .index = 0 };

    const available_w = win_w - new_tab_btn_width;
    var tab_w: i32 = @divTrunc(available_w, @as(i32, @intCast(tab_count)));
    tab_w = @min(tab_w, tab_max_width);
    tab_w = @max(tab_w, tab_min_width);

    // Check new tab button
    const plus_x = @as(i32, @intCast(tab_count)) * tab_w;
    if (mx >= plus_x and mx < plus_x + new_tab_btn_width) {
        return .{ .action = .new_tab, .index = 0 };
    }

    // Check individual tabs
    for (0..tab_count) |i| {
        const tx = @as(i32, @intCast(i)) * tab_w;
        if (mx >= tx and mx < tx + tab_w) {
            // Check if clicking on close button area
            const close_x = tx + tab_w - tab_close_size - 2;
            if (mx >= close_x and mx < close_x + tab_close_size) {
                return .{ .action = .close_tab, .index = i };
            }
            return .{ .action = .switch_tab, .index = i };
        }
    }

    return .{ .action = .none, .index = 0 };
}

/// Paint the status bar at the bottom of the window.
pub fn paintStatusBar(surface: *Surface, fonts: *FontCache, status: []const u8) void {
    const y = surface.height - status_bar_height;
    // Background
    surface.fillRect(0, y, surface.width, status_bar_height, Surface.argbToColour(status_bar_bg));

    if (status.len > 0) {
        const font_size: u32 = 12;
        const tr = fonts.getRenderer(font_size) orelse return;
        const metrics = tr.measure(status);
        const text_y = y + @divTrunc(status_bar_height - metrics.height, 2) + metrics.ascent;

        tr.renderGlyphs(
            status,
            8,
            text_y,
            BlitCtx,
            .{ .surface = surface, .colour = Surface.argbToColour(status_bar_text_color) },
            blitGlyph,
        );
    }
}

/// Clear the content area with the default background.
pub fn clearContentArea(surface: *Surface) void {
    surface.fillRect(0, content_y, surface.width, contentHeight(surface.height), Surface.argbToColour(content_bg));
}
