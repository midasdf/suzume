const std = @import("std");
const Surface = @import("paint/surface.zig").Surface;
const TextRenderer = @import("paint/text.zig").TextRenderer;
const GlyphBitmap = @import("paint/text.zig").GlyphBitmap;
const nsfb_c = @import("bindings/nsfb.zig").c;

const window_w = 720;
const window_h = 720;

// Catppuccin Mocha colours (in standard 0xAARRGGBB)
const bg_colour = 0xFF1e1e2e;
const text_colour = 0xFFcdd6f4; // text
const title_colour = 0xFFf5c2e7; // pink

// Font paths — try CJK first, fall back to DejaVu
const font_cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
const font_fallback = "/usr/share/fonts/TTF/DejaVuSans.ttf";

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

pub fn main() !void {
    std.debug.print("suzume v0.1.0 — opening window...\n", .{});

    // Init surface
    var surface = Surface.init(window_w, window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // Init text renderer — try CJK font first
    var text = TextRenderer.init(font_cjk, 24) catch blk: {
        std.debug.print("CJK font not found, trying fallback...\n", .{});
        break :blk TextRenderer.init(font_fallback, 24) catch |err| {
            std.debug.print("Failed to init text renderer: {}\n", .{err});
            return err;
        };
    };
    defer text.deinit();

    // Also try a larger size for the title
    var title_text = TextRenderer.init(font_cjk, 36) catch blk: {
        break :blk TextRenderer.init(font_fallback, 36) catch |err| {
            std.debug.print("Failed to init title text renderer: {}\n", .{err});
            return err;
        };
    };
    defer title_text.deinit();

    // Clear background
    const bg = Surface.argbToColour(bg_colour);
    surface.fillRect(0, 0, window_w, window_h, bg);

    // Render title "suzume v0.1.0"
    const title_col = Surface.argbToColour(title_colour);
    const title_str = "suzume v0.1.0";
    const title_metrics = title_text.measure(title_str);
    const title_x = @divTrunc(window_w - title_metrics.width, 2); // center
    title_text.renderGlyphs(title_str, title_x, 60 + title_metrics.ascent, BlitCtx, .{
        .surface = &surface,
        .colour = title_col,
    }, blitGlyph);

    // Render Japanese text
    const jp_col = Surface.argbToColour(text_colour);
    const jp_str = "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}";
    const jp_metrics = text.measure(jp_str);
    const jp_x = @divTrunc(window_w - jp_metrics.width, 2);
    text.renderGlyphs(jp_str, jp_x, 120 + text.measure(title_str).ascent, BlitCtx, .{
        .surface = &surface,
        .colour = jp_col,
    }, blitGlyph);

    // Render additional info line
    const info_str = "LibNSFB + FreeType + HarfBuzz";
    const info_metrics = text.measure(info_str);
    const info_x = @divTrunc(window_w - info_metrics.width, 2);
    text.renderGlyphs(info_str, info_x, 180 + text.measure(title_str).ascent, BlitCtx, .{
        .surface = &surface,
        .colour = jp_col,
    }, blitGlyph);

    // Flip to screen
    surface.update();

    std.debug.print("Window open. Close window or press Escape to quit.\n", .{});

    // Event loop
    var running = true;
    while (running) {
        if (surface.pollEvent(100)) |event| {
            if (event.type == nsfb_c.NSFB_EVENT_CONTROL and
                event.value.controlcode == nsfb_c.NSFB_CONTROL_QUIT)
            {
                running = false;
            } else if (event.type == nsfb_c.NSFB_EVENT_KEY_DOWN and
                event.value.keycode == nsfb_c.NSFB_KEY_ESCAPE)
            {
                running = false;
            }
        }
    }

    std.debug.print("Bye!\n", .{});
}
