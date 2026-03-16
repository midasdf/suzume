const std = @import("std");
const Surface = @import("../paint/surface.zig").Surface;
const FontCache = @import("../paint/painter.zig").FontCache;
const TextRenderer = @import("../paint/text.zig").TextRenderer;
const GlyphBitmap = @import("../paint/text.zig").GlyphBitmap;
const TextInput = @import("input.zig").TextInput;

// Layout constants
pub const url_bar_height: i32 = 36;
pub const status_bar_height: i32 = 24;
pub const window_w: i32 = 720;
pub const window_h: i32 = 720;
pub const content_y: i32 = url_bar_height;
pub const content_height: i32 = window_h - url_bar_height - status_bar_height;

// Catppuccin Mocha colours (ARGB)
const url_bar_bg: u32 = 0xFF313244; // Surface0
const url_bar_border: u32 = 0xFF45475a; // Surface1
const url_bar_text_color: u32 = 0xFFcdd6f4; // Text
const url_bar_cursor_color: u32 = 0xFFf5e0dc; // Rosewater
const status_bar_bg: u32 = 0xFF181825; // Mantle
const status_bar_text_color: u32 = 0xFF6c7086; // Overlay0
const content_bg: u32 = 0xFF1e1e2e; // Base

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
    surface.fillRect(0, 0, window_w, url_bar_height, Surface.argbToColour(url_bar_bg));

    // Border bottom
    surface.fillRect(0, url_bar_height - 1, window_w, 1, Surface.argbToColour(url_bar_border));

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

/// Paint the status bar at the bottom of the window.
pub fn paintStatusBar(surface: *Surface, fonts: *FontCache, status: []const u8) void {
    const y = window_h - status_bar_height;
    // Background
    surface.fillRect(0, y, window_w, status_bar_height, Surface.argbToColour(status_bar_bg));

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
    surface.fillRect(0, content_y, window_w, content_height, Surface.argbToColour(content_bg));
}
