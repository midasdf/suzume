const std = @import("std");
const Box = @import("../layout/box.zig").Box;
const BoxType = @import("../layout/box.zig").BoxType;
const Surface = @import("surface.zig").Surface;
const TextRenderer = @import("text.zig").TextRenderer;
const GlyphBitmap = @import("text.zig").GlyphBitmap;
const ImageCache = @import("image.zig").ImageCache;
const blitImage = @import("image.zig").blitImage;

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
pub fn paint(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, clip_top: i32, clip_bottom: i32, image_cache: ?*ImageCache) void {
    paintBox(box, surface, fonts, scroll_y, clip_top, clip_bottom, image_cache);
}

/// Paint borders around a box.
fn paintBorders(box: *const Box, surface: *Surface, scroll_y: f32) void {
    const style = box.style;
    const bbox = box.borderBox();
    const sx: i32 = @intFromFloat(bbox.x);
    const sy: i32 = @intFromFloat(bbox.y - scroll_y);
    const sw: i32 = @intFromFloat(@max(bbox.width, 0));
    const sh: i32 = @intFromFloat(@max(bbox.height, 0));

    // Top border
    if (style.border_top_width > 0) {
        const bw: i32 = @intFromFloat(style.border_top_width);
        surface.fillRect(sx, sy, sw, bw, Surface.argbToColour(style.border_top_color));
    }
    // Bottom border
    if (style.border_bottom_width > 0) {
        const bw: i32 = @intFromFloat(style.border_bottom_width);
        surface.fillRect(sx, sy + sh - bw, sw, bw, Surface.argbToColour(style.border_bottom_color));
    }
    // Left border
    if (style.border_left_width > 0) {
        const bw: i32 = @intFromFloat(style.border_left_width);
        surface.fillRect(sx, sy, bw, sh, Surface.argbToColour(style.border_left_color));
    }
    // Right border
    if (style.border_right_width > 0) {
        const bw: i32 = @intFromFloat(style.border_right_width);
        surface.fillRect(sx + sw - bw, sy, bw, sh, Surface.argbToColour(style.border_right_color));
    }
}

fn paintBox(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, clip_top: i32, clip_bottom: i32, image_cache: ?*ImageCache) void {
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

            // Paint borders
            paintBorders(box, surface, scroll_y);

            // Paint children
            for (box.children.items) |child| {
                paintBox(child, surface, fonts, scroll_y, clip_top, clip_bottom, image_cache);
            }
        },
        .replaced => {
            // Replaced element (image)
            const screen_y = @as(i32, @intFromFloat(box.content.y - scroll_y));
            const screen_bottom = screen_y + @as(i32, @intFromFloat(@max(box.content.height, 0)));
            if (screen_bottom < clip_top or screen_y > clip_bottom) return;

            const dst_x: i32 = @intFromFloat(box.content.x);
            const dst_w: u32 = @intFromFloat(@max(box.content.width, 0));
            const dst_h: u32 = @intFromFloat(@max(box.content.height, 0));

            var painted = false;
            if (image_cache) |cache| {
                if (box.image_url) |url| {
                    if (cache.get(url)) |img| {
                        // Scale: use blitImageScaled
                        blitImageScaled(surface, dst_x, screen_y, dst_w, dst_h, img.pixels, img.width, img.height);
                        painted = true;
                    }
                }
            }

            if (!painted) {
                // Draw placeholder rectangle
                const border_color = Surface.argbToColour(0xFF585b70); // Overlay2
                surface.fillRect(dst_x, screen_y, @intCast(dst_w), 1, border_color);
                surface.fillRect(dst_x, screen_y + @as(i32, @intCast(dst_h)) - 1, @intCast(dst_w), 1, border_color);
                surface.fillRect(dst_x, screen_y, 1, @intCast(dst_h), border_color);
                surface.fillRect(dst_x + @as(i32, @intCast(dst_w)) - 1, screen_y, 1, @intCast(dst_h), border_color);

                // Draw alt text or "[image]" in center
                const alt_text = if (box.dom_node) |node| (node.getAttribute("alt") orelse "[image]") else "[image]";
                const tr = fonts.getRenderer(12) orelse return;
                const m = tr.measure(alt_text);
                const text_x = dst_x + @divTrunc(@as(i32, @intCast(dst_w)) - m.width, 2);
                const text_y = screen_y + @divTrunc(@as(i32, @intCast(dst_h)) - m.height, 2) + m.ascent;
                tr.renderGlyphs(
                    alt_text,
                    text_x,
                    text_y,
                    BlitCtx,
                    .{ .surface = surface, .colour = Surface.argbToColour(0xFF6c7086), .clip_top = clip_top, .clip_bottom = clip_bottom },
                    blitGlyphClipped,
                );
            }

            // Paint borders
            paintBorders(box, surface, scroll_y);
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

/// Blit an RGBA image scaled to a destination rectangle.
fn blitImageScaled(surface: *Surface, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src_pixels: [*]const u8, src_w: u32, src_h: u32) void {
    if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return;

    // If source matches destination, use direct blit
    if (src_w == dst_w and src_h == dst_h) {
        blitImage(surface, dst_x, dst_y, src_w, src_h, src_pixels);
        return;
    }

    // Nearest-neighbor scaling via temporary buffer
    const buf_size = @as(usize, dst_w) * @as(usize, dst_h) * 4;
    const buf = std.heap.c_allocator.alloc(u8, buf_size) catch return;
    defer std.heap.c_allocator.free(buf);

    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const src_y = @min(dy * src_h / dst_h, src_h - 1);
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const src_x_val = @min(dx * src_w / dst_w, src_w - 1);
            const src_idx = (@as(usize, src_y) * @as(usize, src_w) + @as(usize, src_x_val)) * 4;
            const dst_idx = (@as(usize, dy) * @as(usize, dst_w) + @as(usize, dx)) * 4;
            buf[dst_idx + 0] = src_pixels[src_idx + 0];
            buf[dst_idx + 1] = src_pixels[src_idx + 1];
            buf[dst_idx + 2] = src_pixels[src_idx + 2];
            buf[dst_idx + 3] = src_pixels[src_idx + 3];
        }
    }

    blitImage(surface, dst_x, dst_y, dst_w, dst_h, buf.ptr);
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
        .replaced => {
            // Check content rect
            if (x >= box.content.x and x <= box.content.x + box.content.width and
                y >= box.content.y and y <= box.content.y + box.content.height)
            {
                return box.link_url;
            }
        },
    }
    return null;
}
