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
    offset_x: i32 = 0,
};

fn blitGlyphClipped(ctx: BlitCtx, glyph: GlyphBitmap) void {
    // Skip glyphs entirely outside clip region
    const gy_bottom = glyph.y + @as(i32, @intCast(glyph.height));
    if (gy_bottom <= ctx.clip_top or glyph.y >= ctx.clip_bottom) return;

    ctx.surface.blitGlyph8(
        glyph.x + ctx.offset_x,
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
/// scroll_x is the horizontal scroll offset (content pixels to skip from the left).
pub fn paint(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, scroll_x: f32, clip_top: i32, clip_bottom: i32, image_cache: ?*ImageCache) void {
    paintBox(box, surface, fonts, scroll_y, scroll_x, clip_top, clip_bottom, image_cache);
}

/// Paint borders around a box.
fn paintBorders(box: *const Box, surface: *Surface, scroll_y: f32, scroll_x: f32) void {
    const style = box.style;
    const bbox = box.borderBox();
    const sx: i32 = @intFromFloat(bbox.x - scroll_x);
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

fn paintBox(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, scroll_x: f32, clip_top: i32, clip_bottom: i32, image_cache: ?*ImageCache) void {
    // Skip painting for visibility: hidden (but still recurse for children
    // which may have visibility: visible)
    const is_visible = box.style.visibility == .visible;

    const sx_i: i32 = @intFromFloat(scroll_x);
    switch (box.box_type) {
        .block, .anonymous_block, .inline_box => {
            // Quick culling: skip boxes entirely outside viewport
            const pbox = box.paddingBox();
            const screen_y = @as(i32, @intFromFloat(pbox.y - scroll_y));
            const screen_bottom = screen_y + @as(i32, @intFromFloat(@max(pbox.height, 0)));
            if (screen_bottom < clip_top or screen_y > clip_bottom) return;

            if (is_visible) {
                // Paint background if not transparent
                const bg = box.style.background_color;
                const alpha = (bg >> 24) & 0xFF;
                if (alpha > 0) {
                    const bg_x = @as(i32, @intFromFloat(pbox.x)) - sx_i;
                    const bg_y = screen_y;
                    const bg_w: i32 = @intFromFloat(@max(pbox.width, 0));
                    const bg_h: i32 = @intFromFloat(@max(pbox.height, 0));
                    const bg_colour = Surface.argbToColour(bg);

                    // Use rounded rect if any border-radius is set
                    const avg_radius = (box.style.border_radius_tl +
                        box.style.border_radius_tr +
                        box.style.border_radius_bl +
                        box.style.border_radius_br) / 4.0;
                    if (avg_radius > 0.5) {
                        surface.fillRoundedRect(bg_x, bg_y, bg_w, bg_h, @intFromFloat(avg_radius), bg_colour);
                    } else {
                        surface.fillRect(bg_x, bg_y, bg_w, bg_h, bg_colour);
                    }
                }

                // Paint borders
                paintBorders(box, surface, scroll_y, scroll_x);

                // Paint <hr> line
                if (box.is_hr) {
                    paintHr(box, surface, scroll_y, scroll_x, clip_top, clip_bottom);
                }

                // Paint list item marker
                if (box.style.display == .list_item and box.list_index > 0) {
                    paintListMarker(box, surface, fonts, scroll_y, scroll_x, clip_top, clip_bottom);
                }
            }

            // Paint children (always recurse — children may override visibility)
            for (box.children.items) |child| {
                paintBox(child, surface, fonts, scroll_y, scroll_x, clip_top, clip_bottom, image_cache);
            }
        },
        .replaced => {
            if (!is_visible) return;
            // Replaced element (image)
            const screen_y = @as(i32, @intFromFloat(box.content.y - scroll_y));
            const screen_bottom = screen_y + @as(i32, @intFromFloat(@max(box.content.height, 0)));
            if (screen_bottom < clip_top or screen_y > clip_bottom) return;

            const dst_x: i32 = @as(i32, @intFromFloat(box.content.x)) - sx_i;
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
                    .{ .surface = surface, .colour = Surface.argbToColour(0xFF6c7086), .clip_top = clip_top, .clip_bottom = clip_bottom, .offset_x = 0 },
                    blitGlyphClipped,
                );
            }

            // Paint borders
            paintBorders(box, surface, scroll_y, scroll_x);
        },
        .inline_text => {
            if (!is_visible) return;
            const colour = Surface.argbToColour(box.style.color);
            const size_px: u32 = @intFromFloat(box.style.font_size_px);
            const tr = fonts.getRenderer(size_px) orelse return;

            // Paint background on inline text if set
            const ibg = box.style.background_color;
            const ialpha = (ibg >> 24) & 0xFF;
            if (ialpha > 0) {
                for (box.lines.items) |line| {
                    const lx: i32 = @as(i32, @intFromFloat(line.x)) - sx_i;
                    const ly: i32 = @intFromFloat(line.y - scroll_y);
                    const lw: i32 = @intFromFloat(@max(line.width, 0));
                    const lh: i32 = @intFromFloat(@max(line.height, 0));
                    if (ly + lh >= clip_top and ly <= clip_bottom) {
                        surface.fillRect(lx, ly, lw, lh, Surface.argbToColour(ibg));
                    }
                }
            }

            for (box.lines.items) |line| {
                const draw_y: i32 = @intFromFloat(line.y + line.ascent - scroll_y);
                const draw_x: i32 = @as(i32, @intFromFloat(line.x)) - sx_i;
                const line_bottom = @as(i32, @intFromFloat(line.y + line.height - scroll_y));

                // Skip lines entirely outside clip
                if (line_bottom < clip_top or draw_y - @as(i32, @intFromFloat(line.ascent)) > clip_bottom) continue;

                tr.renderGlyphs(
                    line.text,
                    draw_x,
                    draw_y,
                    BlitCtx,
                    .{ .surface = surface, .colour = colour, .clip_top = clip_top, .clip_bottom = clip_bottom, .offset_x = 0 },
                    blitGlyphClipped,
                );

                // Draw underline for links or text-decoration: underline
                const draw_underline = box.link_url != null or box.style.text_decoration.underline;
                if (draw_underline) {
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

                // Draw line-through
                if (box.style.text_decoration.line_through) {
                    const strike_y = draw_y - @divTrunc(@as(i32, @intFromFloat(line.ascent)), 3);
                    if (strike_y >= clip_top and strike_y < clip_bottom) {
                        surface.fillRect(
                            draw_x,
                            strike_y,
                            @intFromFloat(@max(line.width, 0)),
                            1,
                            colour,
                        );
                    }
                }

                // Draw overline
                if (box.style.text_decoration.overline) {
                    const overline_y = draw_y - @as(i32, @intFromFloat(line.ascent));
                    if (overline_y >= clip_top and overline_y < clip_bottom) {
                        surface.fillRect(
                            draw_x,
                            overline_y,
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

/// Paint an <hr> horizontal rule.
fn paintHr(box: *const Box, surface: *Surface, scroll_y: f32, scroll_x: f32, clip_top: i32, clip_bottom: i32) void {
    const style = box.style;
    const hr_color = Surface.argbToColour(if (style.border_top_color != 0xFF000000) style.border_top_color else 0xFF45475a);
    const hr_thickness: i32 = if (style.border_top_width > 0) @intFromFloat(style.border_top_width) else 1;
    const bbox = box.borderBox();
    const hr_x: i32 = @as(i32, @intFromFloat(bbox.x)) - @as(i32, @intFromFloat(scroll_x));
    const hr_y: i32 = @intFromFloat(bbox.y - scroll_y);
    const hr_w: i32 = @intFromFloat(@max(bbox.width, 0));

    if (hr_y >= clip_top and hr_y < clip_bottom) {
        surface.fillRect(hr_x, hr_y, hr_w, hr_thickness, hr_color);
    }
}

/// Paint a list item bullet or number marker.
fn paintListMarker(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, scroll_x: f32, clip_top: i32, clip_bottom: i32) void {
    const style = box.style;
    const colour = Surface.argbToColour(style.color);
    const size_px: u32 = @intFromFloat(style.font_size_px);
    const tr = fonts.getRenderer(size_px) orelse return;

    // Determine marker text
    var marker_buf: [16]u8 = undefined;
    const marker_text: []const u8 = switch (style.list_style_type) {
        .disc => "\xe2\x80\xa2", // bullet: U+2022
        .circle => "\xe2\x97\x8b", // white circle: U+25CB
        .square => "\xe2\x96\xaa", // small black square: U+25AA
        .decimal => blk: {
            const written = std.fmt.bufPrint(&marker_buf, "{d}.", .{box.list_index}) catch break :blk "?.";
            break :blk written;
        },
        .none => return,
        .other => "\xe2\x80\xa2", // fallback to bullet
    };

    const m = tr.measure(marker_text);
    // Position marker to the left of the content area
    const marker_x: i32 = @as(i32, @intFromFloat(box.content.x)) - @as(i32, @intFromFloat(scroll_x)) - m.width - 4;
    const marker_y: i32 = @as(i32, @intFromFloat(box.content.y - scroll_y)) + m.ascent;

    if (marker_y - m.ascent > clip_bottom or marker_y + m.height - m.ascent < clip_top) return;

    tr.renderGlyphs(
        marker_text,
        marker_x,
        marker_y,
        BlitCtx,
        .{ .surface = surface, .colour = colour, .clip_top = clip_top, .clip_bottom = clip_bottom },
        blitGlyphClipped,
    );
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

/// Compute the total content width of a box tree (for horizontal scroll limits).
pub fn contentWidth(box: *const Box) f32 {
    var max_w: f32 = 0;
    contentWidthRecurse(box, &max_w);
    return max_w;
}

fn contentWidthRecurse(box: *const Box, max_w: *f32) void {
    switch (box.box_type) {
        .block, .anonymous_block, .inline_box => {
            const mbox = box.marginBox();
            const right = mbox.x + mbox.width;
            if (right > max_w.*) max_w.* = right;
            for (box.children.items) |child| {
                contentWidthRecurse(child, max_w);
            }
        },
        .inline_text => {
            for (box.lines.items) |line| {
                const right = line.x + line.width;
                if (right > max_w.*) max_w.* = right;
            }
        },
        .replaced => {
            const right = box.content.x + box.content.width;
            if (right > max_w.*) max_w.* = right;
        },
    }
}

/// Hit-test: find the deepest DOM node at a given point (in layout coordinates).
/// Returns the raw lxb_dom_node_t pointer if found.
pub fn hitTestNode(box: *const Box, x: f32, y: f32) ?*anyopaque {
    switch (box.box_type) {
        .block, .anonymous_block, .inline_box => {
            // Check children in reverse order (later children are on top)
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const result = hitTestNode(box.children.items[i], x, y);
                if (result != null) return result;
            }
            // Check self
            const mbox = box.marginBox();
            if (x >= mbox.x and x <= mbox.x + mbox.width and
                y >= mbox.y and y <= mbox.y + mbox.height)
            {
                if (box.dom_node) |dn| return dn.rawPtr();
            }
        },
        .inline_text => {
            for (box.lines.items) |line| {
                if (x >= line.x and x <= line.x + line.width and
                    y >= line.y and y <= line.y + line.height)
                {
                    if (box.dom_node) |dn| return dn.rawPtr();
                    return null;
                }
            }
        },
        .replaced => {
            if (x >= box.content.x and x <= box.content.x + box.content.width and
                y >= box.content.y and y <= box.content.y + box.content.height)
            {
                if (box.dom_node) |dn| return dn.rawPtr();
            }
        },
    }
    return null;
}

/// Hit-test: find the link URL at a given point (in layout coordinates, i.e. before scroll).
pub fn hitTestLink(box: *const Box, x: f32, y: f32) ?[]const u8 {
    switch (box.box_type) {
        .block, .anonymous_block, .inline_box => {
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
