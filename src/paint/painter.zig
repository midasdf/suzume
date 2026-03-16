const std = @import("std");
const Box = @import("../layout/box.zig").Box;
const BoxType = @import("../layout/box.zig").BoxType;
const Surface = @import("surface.zig").Surface;
const TextRenderer = @import("text.zig").TextRenderer;
const GlyphBitmap = @import("text.zig").GlyphBitmap;

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

/// Paint the box tree onto the surface.
pub fn paint(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32) void {
    paintBox(box, surface, fonts, scroll_y);
}

fn paintBox(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32) void {
    switch (box.box_type) {
        .block, .anonymous_block => {
            // Paint background if not transparent
            const bg = box.style.background_color;
            const alpha = (bg >> 24) & 0xFF;
            if (alpha > 0) {
                const pbox = box.paddingBox();
                surface.fillRect(
                    @intFromFloat(pbox.x),
                    @intFromFloat(pbox.y - scroll_y),
                    @intFromFloat(@max(pbox.width, 0)),
                    @intFromFloat(@max(pbox.height, 0)),
                    Surface.argbToColour(bg),
                );
            }

            // Paint children
            for (box.children.items) |child| {
                paintBox(child, surface, fonts, scroll_y);
            }
        },
        .inline_text => {
            const colour = Surface.argbToColour(box.style.color);
            const size_px: u32 = @intFromFloat(box.style.font_size_px);
            const tr = fonts.getRenderer(size_px) orelse return;

            for (box.lines.items) |line| {
                const draw_y: i32 = @intFromFloat(line.y + line.ascent - scroll_y);
                const draw_x: i32 = @intFromFloat(line.x);

                tr.renderGlyphs(
                    line.text,
                    draw_x,
                    draw_y,
                    BlitCtx,
                    .{ .surface = surface, .colour = colour },
                    blitGlyph,
                );
            }
        },
    }
}
