const std = @import("std");
const Box = @import("../layout/box.zig").Box;
const BoxType = @import("../layout/box.zig").BoxType;
const Surface = @import("surface.zig").Surface;
const TextRenderer = @import("text.zig").TextRenderer;
const GlyphBitmap = @import("text.zig").GlyphBitmap;

const BlitCtx = struct {
    surface: *Surface,
    colour: u32,
    clip_top: i32,
    clip_bottom: i32,
};

fn blitGlyphClipped(ctx: BlitCtx, glyph: GlyphBitmap) void {
    // Skip glyphs entirely outside clip region
    const gy_bottom = glyph.y + @as(i32, @intCast(glyph.height));
    if (gy_bottom <= ctx.clip_top or glyph.y >= ctx.clip_bottom) return;

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

/// Simple font cache that creates TextRenderers for different pixel sizes.
pub const FontCache = struct {
    renderers: std.AutoHashMap(u32, *TextRenderer),
    font_path: [*:0]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8) FontCache {
        return .{
            .renderers = std.AutoHashMap(u32, *TextRenderer).init(allocator),
            .font_path = font_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontCache) void {
        var it = self.renderers.valueIterator();
        while (it.next()) |tr_ptr| {
            tr_ptr.*.deinit();
            self.allocator.destroy(tr_ptr.*);
        }
        self.renderers.deinit();
    }

    pub fn getRenderer(self: *FontCache, size_px: u32) ?*TextRenderer {
        const clamped = if (size_px < 6) @as(u32, 6) else if (size_px > 72) @as(u32, 72) else size_px;
        if (self.renderers.get(clamped)) |tr| return tr;

        // Create new renderer for this size
        const tr = self.allocator.create(TextRenderer) catch return null;
        tr.* = TextRenderer.init(self.font_path, clamped) catch {
            self.allocator.destroy(tr);
            return null;
        };
        self.renderers.put(clamped, tr) catch {
            tr.deinit();
            self.allocator.destroy(tr);
            return null;
        };
        return tr;
    }
};

/// Paint the box tree onto the surface within a clipped region.
/// clip_top/clip_bottom are absolute screen Y coordinates for the visible area.
pub fn paint(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, clip_top: i32, clip_bottom: i32) void {
    paintBox(box, surface, fonts, scroll_y, clip_top, clip_bottom);
}

fn paintBox(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, clip_top: i32, clip_bottom: i32) void {
    switch (box.box_type) {
        .block, .anonymous_block => {
            // Quick culling: skip boxes entirely outside viewport
            const pbox = box.paddingBox();
            const screen_y = @as(i32, @intFromFloat(pbox.y - scroll_y));
            const screen_bottom = screen_y + @as(i32, @intFromFloat(@max(pbox.height, 0)));
            if (screen_bottom < clip_top or screen_y > clip_bottom) return;

            // Paint background if not transparent
            const bg = box.style.background_color;
            const alpha = (bg >> 24) & 0xFF;
            if (alpha > 0) {
                surface.fillRect(
                    @intFromFloat(pbox.x),
                    screen_y,
                    @intFromFloat(@max(pbox.width, 0)),
                    @intFromFloat(@max(pbox.height, 0)),
                    Surface.argbToColour(bg),
                );
            }

            // Paint children
            for (box.children.items) |child| {
                paintBox(child, surface, fonts, scroll_y, clip_top, clip_bottom);
            }
        },
        .inline_text => {
            const colour = Surface.argbToColour(box.style.color);
            const size_px: u32 = @intFromFloat(box.style.font_size_px);
            const tr = fonts.getRenderer(size_px) orelse return;

            for (box.lines.items) |line| {
                const draw_y: i32 = @intFromFloat(line.y + line.ascent - scroll_y);
                const draw_x: i32 = @intFromFloat(line.x);
                const line_bottom = @as(i32, @intFromFloat(line.y + line.height - scroll_y));

                // Skip lines entirely outside clip
                if (line_bottom < clip_top or draw_y - @as(i32, @intFromFloat(line.ascent)) > clip_bottom) continue;

                tr.renderGlyphs(
                    line.text,
                    draw_x,
                    draw_y,
                    BlitCtx,
                    .{ .surface = surface, .colour = colour, .clip_top = clip_top, .clip_bottom = clip_bottom },
                    blitGlyphClipped,
                );

                // Draw underline for links
                if (box.link_url != null) {
                    const underline_y = draw_y + 2; // 2px below baseline
                    if (underline_y >= clip_top and underline_y < clip_bottom) {
                        surface.fillRect(
                            draw_x,
                            underline_y,
                            @intFromFloat(@max(line.width, 0)),
                            1,
                            colour,
                        );
                    }
                }
            }
        },
    }
}

/// Compute the total content height of a box tree (for scroll limits).
pub fn contentHeight(box: *const Box) f32 {
    const mbox = box.marginBox();
    return mbox.y + mbox.height;
}

/// Hit-test: find the link URL at a given point (in layout coordinates, i.e. before scroll).
pub fn hitTestLink(box: *const Box, x: f32, y: f32) ?[]const u8 {
    switch (box.box_type) {
        .block, .anonymous_block => {
            // Check children in reverse order (later children are on top)
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const result = hitTestLink(box.children.items[i], x, y);
                if (result != null) return result;
            }
        },
        .inline_text => {
            // Check each line box
            for (box.lines.items) |line| {
                if (x >= line.x and x <= line.x + line.width and
                    y >= line.y and y <= line.y + line.height)
                {
                    return box.link_url;
                }
            }
        },
    }
    return null;
}
