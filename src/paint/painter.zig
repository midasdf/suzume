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

/// Simple font cache that creates TextRenderers for different pixel sizes and font families.
pub const FontCache = struct {
    renderers: std.AutoHashMap(u64, *TextRenderer),
    font_path: [*:0]const u8,
    font_path_serif: [*:0]const u8,
    font_path_mono: [*:0]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8) FontCache {
        return .{
            .renderers = std.AutoHashMap(u64, *TextRenderer).init(allocator),
            .font_path = font_path,
            .font_path_serif = font_path, // fallback to same font
            .font_path_mono = font_path,
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
        return self.getRendererForFamily(size_px, .sans_serif);
    }

    const FontFamily = @import("../css/computed.zig").FontFamily;

    pub fn getRendererForFamily(self: *FontCache, size_px: u32, family: FontFamily) ?*TextRenderer {
        const clamped = if (size_px < 6) @as(u32, 6) else if (size_px > 72) @as(u32, 72) else size_px;
        const key: u64 = @as(u64, clamped) | (@as(u64, @intFromEnum(family)) << 32);
        if (self.renderers.get(key)) |tr| return tr;

        // Select font path based on family
        const path = switch (family) {
            .serif => self.font_path_serif,
            .monospace => self.font_path_mono,
            .sans_serif => self.font_path,
        };

        // Create new renderer for this size + family
        const tr = self.allocator.create(TextRenderer) catch return null;
        tr.* = TextRenderer.init(path, clamped) catch {
            self.allocator.destroy(tr);
            return null;
        };
        self.renderers.put(key, tr) catch {
            tr.deinit();
            self.allocator.destroy(tr);
            return null;
        };
        return tr;
    }
};

/// Clip rectangle for overflow clipping.
const ClipRect = struct {
    top: i32,
    bottom: i32,
    left: i32,
    right: i32,

    fn intersect(self: ClipRect, other: ClipRect) ClipRect {
        return .{
            .top = @max(self.top, other.top),
            .bottom = @min(self.bottom, other.bottom),
            .left = @max(self.left, other.left),
            .right = @min(self.right, other.right),
        };
    }

    fn isEmpty(self: ClipRect) bool {
        return self.top >= self.bottom or self.left >= self.right;
    }
};

/// Paint the box tree onto the surface within a clipped region.
/// clip_top/clip_bottom are absolute screen Y coordinates for the visible area.
/// scroll_x is the horizontal scroll offset (content pixels to skip from the left).
pub fn paint(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, scroll_x: f32, clip_top: i32, clip_bottom: i32, image_cache: ?*ImageCache) void {
    const clip = ClipRect{
        .top = clip_top,
        .bottom = clip_bottom,
        .left = -9999,
        .right = 99999,
    };
    paintBox(box, surface, fonts, scroll_y, scroll_x, clip, image_cache, 1.0);
}

/// Paint borders around a box.
fn paintBorders(box: *const Box, surface: *Surface, scroll_y: f32, scroll_x: f32) void {
    const style = box.style;
    const bbox = box.borderBox();
    const sx: i32 = @intFromFloat(bbox.x - scroll_x);
    const sy: i32 = @intFromFloat(bbox.y - scroll_y);
    const sw: i32 = @intFromFloat(@max(bbox.width, 0));
    const sh: i32 = @intFromFloat(@max(bbox.height, 0));

    const has_radius = style.border_radius_tl > 0.5 or style.border_radius_tr > 0.5 or
        style.border_radius_bl > 0.5 or style.border_radius_br > 0.5;

    if (has_radius) {
        // For rounded borders: draw a filled rounded rect for border, then a slightly
        // smaller filled rounded rect for background on top (creating a border effect).
        // Use the most prominent border color.
        const border_color = if ((style.border_top_color >> 24) > 0) style.border_top_color
            else if ((style.border_left_color >> 24) > 0) style.border_left_color
            else if ((style.border_bottom_color >> 24) > 0) style.border_bottom_color
            else style.border_right_color;
        const bw_top: i32 = @intFromFloat(style.border_top_width);
        const bw_right: i32 = @intFromFloat(style.border_right_width);
        const bw_bottom: i32 = @intFromFloat(style.border_bottom_width);
        const bw_left: i32 = @intFromFloat(style.border_left_width);

        if (bw_top > 0 or bw_right > 0 or bw_bottom > 0 or bw_left > 0) {
            // Outer rounded rect (border)
            surface.fillRoundedRectPerCorner(sx, sy, sw, sh,
                @intFromFloat(style.border_radius_tl),
                @intFromFloat(style.border_radius_tr),
                @intFromFloat(style.border_radius_bl),
                @intFromFloat(style.border_radius_br),
                Surface.argbToColour(border_color));
            // Inner rounded rect (punch out interior with background or parent color)
            const inner_x = sx + bw_left;
            const inner_y = sy + bw_top;
            const inner_w = sw - bw_left - bw_right;
            const inner_h = sh - bw_top - bw_bottom;
            if (inner_w > 0 and inner_h > 0) {
                const inner_r_tl = @max(@as(i32, @intFromFloat(style.border_radius_tl)) - bw_left, 0);
                const inner_r_tr = @max(@as(i32, @intFromFloat(style.border_radius_tr)) - bw_right, 0);
                const inner_r_bl = @max(@as(i32, @intFromFloat(style.border_radius_bl)) - bw_left, 0);
                const inner_r_br = @max(@as(i32, @intFromFloat(style.border_radius_br)) - bw_right, 0);
                // Use background color for inner fill (or transparent/dark for the "hole")
                const bg = if ((style.background_color >> 24) > 0) style.background_color else 0x00000000;
                surface.fillRoundedRectPerCorner(inner_x, inner_y, inner_w, inner_h,
                    inner_r_tl, inner_r_tr, inner_r_bl, inner_r_br,
                    Surface.argbToColour(bg));
            }
        }
    } else {
        // Straight borders (no radius)
        if (style.border_top_width > 0) {
            const bw: i32 = @intFromFloat(style.border_top_width);
            surface.fillRect(sx, sy, sw, bw, Surface.argbToColour(style.border_top_color));
        }
        if (style.border_bottom_width > 0) {
            const bw: i32 = @intFromFloat(style.border_bottom_width);
            surface.fillRect(sx, sy + sh - bw, sw, bw, Surface.argbToColour(style.border_bottom_color));
        }
        if (style.border_left_width > 0) {
            const bw: i32 = @intFromFloat(style.border_left_width);
            surface.fillRect(sx, sy, bw, sh, Surface.argbToColour(style.border_left_color));
        }
        if (style.border_right_width > 0) {
            const bw: i32 = @intFromFloat(style.border_right_width);
            surface.fillRect(sx + sw - bw, sy, bw, sh, Surface.argbToColour(style.border_right_color));
        }
    }
}

/// Paint box-shadow behind an element.
fn paintBoxShadow(box: *const Box, surface: *Surface, scroll_y: f32, scroll_x: f32) void {
    const style = box.style;
    // Check if shadow is set (non-transparent color)
    const shadow_alpha = (style.box_shadow_color >> 24) & 0xFF;
    if (shadow_alpha == 0) return;

    const pbox = box.paddingBox();
    const sx_i: i32 = @intFromFloat(scroll_x);
    const base_x = @as(i32, @intFromFloat(pbox.x)) - sx_i;
    const base_y = @as(i32, @intFromFloat(pbox.y - scroll_y));
    const base_w: i32 = @intFromFloat(@max(pbox.width, 0));
    const base_h: i32 = @intFromFloat(@max(pbox.height, 0));

    const off_x: i32 = @intFromFloat(style.box_shadow_x);
    const off_y: i32 = @intFromFloat(style.box_shadow_y);
    const blur: i32 = @intFromFloat(@max(style.box_shadow_blur, 0));

    const shadow_colour = Surface.argbToColour(style.box_shadow_color);

    if (blur <= 1) {
        // Simple shadow: single offset rectangle
        const has_radius = style.border_radius_tl > 0.5 or style.border_radius_tr > 0.5 or
            style.border_radius_bl > 0.5 or style.border_radius_br > 0.5;
        if (has_radius) {
            surface.fillRoundedRectPerCorner(
                base_x + off_x,
                base_y + off_y,
                base_w,
                base_h,
                @intFromFloat(style.border_radius_tl),
                @intFromFloat(style.border_radius_tr),
                @intFromFloat(style.border_radius_bl),
                @intFromFloat(style.border_radius_br),
                shadow_colour,
            );
        } else {
            surface.fillRectBlend(base_x + off_x, base_y + off_y, base_w, base_h, shadow_colour);
        }
    } else {
        // Approximate blur with multiple expanding semi-transparent rectangles
        const passes: i32 = @min(blur, 4); // limit passes for performance
        const base_alpha = @as(f32, @floatFromInt(shadow_alpha));

        var i: i32 = 0;
        while (i < passes) : (i += 1) {
            const expand = @divTrunc(blur * (i + 1), passes);
            const alpha_fraction = base_alpha / @as(f32, @floatFromInt(passes + 1));
            const pass_alpha: u32 = @intFromFloat(@max(alpha_fraction, 1));
            const pass_colour = (shadow_colour & 0x00FFFFFF) | (pass_alpha << 24);

            surface.fillRectBlend(
                base_x + off_x - expand,
                base_y + off_y - expand,
                base_w + expand * 2,
                base_h + expand * 2,
                pass_colour,
            );
        }
    }
}

fn paintBox(box: *const Box, surface: *Surface, fonts: *FontCache, scroll_y: f32, scroll_x: f32, clip: ClipRect, image_cache: ?*ImageCache, accumulated_opacity: f32) void {
    if (clip.isEmpty()) return;

    // Accumulate opacity through the tree (CSS compositing group behavior).
    // Enforce minimum opacity — many modern sites set opacity:0 and rely on
    // JS animations to reveal content. Without full animation support, we
    // clamp opacity so content remains visible.
    const clamped_opacity = if (box.style.opacity < 0.01) @as(f32, 1.0) else box.style.opacity;
    const effective_opacity = accumulated_opacity * clamped_opacity;

    // Respect visibility:hidden — skip painting this element's own content
    // but still recurse into children (which may have visibility:visible).
    const is_visible = box.style.visibility == .visible;

    const clip_top = clip.top;
    const clip_bottom = clip.bottom;
    const sx_i: i32 = @intFromFloat(scroll_x);
    switch (box.box_type) {
        .block, .anonymous_block, .inline_box => {
            // Quick culling: skip boxes entirely outside viewport
            const pbox = box.paddingBox();
            const screen_y = @as(i32, @intFromFloat(pbox.y - scroll_y));
            const screen_x = @as(i32, @intFromFloat(pbox.x - scroll_x));
            const screen_bottom = screen_y + @as(i32, @intFromFloat(@max(pbox.height, 0)));
            const screen_right = screen_x + @as(i32, @intFromFloat(@max(pbox.width, 0)));
            if (screen_bottom < clip.top or screen_y > clip.bottom) return;
            if (screen_right < clip.left or screen_x > clip.right) return;

            if (is_visible) {
                // Paint box-shadow behind the element
                paintBoxShadow(box, surface, scroll_y, scroll_x);

                // Paint background — gradient or solid color
                const has_gradient = (box.style.gradient_color_start >> 24) > 0 or
                    (box.style.gradient_color_end >> 24) > 0;

                const bg = box.style.background_color;
                const alpha = (bg >> 24) & 0xFF;
                if (has_gradient) {
                    const bg_x = @as(i32, @intFromFloat(pbox.x)) - sx_i;
                    const bg_y = screen_y;
                    const bg_w: i32 = @intFromFloat(@max(pbox.width, 0));
                    const bg_h: i32 = @intFromFloat(@max(pbox.height, 0));
                    const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
                    const horizontal = (box.style.gradient_direction == ComputedStyle.GradientDirection.to_right or
                        box.style.gradient_direction == ComputedStyle.GradientDirection.to_left);
                    var start_color = Surface.argbToColour(box.style.gradient_color_start);
                    var end_color = Surface.argbToColour(box.style.gradient_color_end);
                    // Reverse for to_top and to_left
                    if (box.style.gradient_direction == ComputedStyle.GradientDirection.to_top or
                        box.style.gradient_direction == ComputedStyle.GradientDirection.to_left)
                    {
                        const tmp = start_color;
                        start_color = end_color;
                        end_color = tmp;
                    }
                    surface.fillGradientRect(bg_x, bg_y, bg_w, bg_h, start_color, end_color, horizontal);
                } else if (alpha > 0) {
                    const bg_x = @as(i32, @intFromFloat(pbox.x)) - sx_i;
                    const bg_y = screen_y;
                    const bg_w: i32 = @intFromFloat(@max(pbox.width, 0));
                    const bg_h: i32 = @intFromFloat(@max(pbox.height, 0));
                    const raw_colour = Surface.argbToColour(bg);
                    const bg_colour = Surface.applyOpacity(raw_colour, effective_opacity);

                    // Use rounded rect if any border-radius is set (per-corner)
                    const has_radius = box.style.border_radius_tl > 0.5 or
                        box.style.border_radius_tr > 0.5 or
                        box.style.border_radius_bl > 0.5 or
                        box.style.border_radius_br > 0.5;
                    if (has_radius) {
                        surface.fillRoundedRectPerCorner(
                            bg_x,
                            bg_y,
                            bg_w,
                            bg_h,
                            @intFromFloat(box.style.border_radius_tl),
                            @intFromFloat(box.style.border_radius_tr),
                            @intFromFloat(box.style.border_radius_bl),
                            @intFromFloat(box.style.border_radius_br),
                            bg_colour,
                        );
                    } else {
                        const effective_alpha = (bg_colour >> 24) & 0xFF;
                        if (effective_alpha < 255) {
                            surface.fillRectBlend(bg_x, bg_y, bg_w, bg_h, bg_colour);
                        } else {
                            surface.fillRect(bg_x, bg_y, bg_w, bg_h, bg_colour);
                        }
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

            // Paint children with overflow clipping
            var child_clip = clip;
            const has_overflow_clip_x = box.style.overflow_x == .hidden or box.style.overflow_x == .scroll or box.style.overflow_x == .auto_;
            const has_overflow_clip_y = box.style.overflow_y == .hidden or box.style.overflow_y == .scroll or box.style.overflow_y == .auto_;
            const has_overflow_clip = has_overflow_clip_x or has_overflow_clip_y;
            if (has_overflow_clip) {
                // Restrict child clip to this box's padding box
                const box_clip = ClipRect{
                    .top = screen_y,
                    .bottom = screen_bottom,
                    .left = screen_x,
                    .right = screen_right,
                };
                child_clip = clip.intersect(box_clip);
            }
            // Paint children sorted by z-index: negative first, then zero, then positive
            const has_nonzero_z = blk: {
                for (box.children.items) |child| {
                    if (child.style.z_index != 0) break :blk true;
                }
                break :blk false;
            };
            if (has_nonzero_z) {
                // Pass 1: negative z-index
                for (box.children.items) |child| {
                    if (child.style.z_index < 0) paintBox(child, surface, fonts, scroll_y, scroll_x, child_clip, image_cache, effective_opacity);
                }
                // Pass 2: zero z-index (normal flow)
                for (box.children.items) |child| {
                    if (child.style.z_index == 0) paintBox(child, surface, fonts, scroll_y, scroll_x, child_clip, image_cache, effective_opacity);
                }
                // Pass 3: positive z-index
                for (box.children.items) |child| {
                    if (child.style.z_index > 0) paintBox(child, surface, fonts, scroll_y, scroll_x, child_clip, image_cache, effective_opacity);
                }
            } else {
                for (box.children.items) |child| {
                    paintBox(child, surface, fonts, scroll_y, scroll_x, child_clip, image_cache, effective_opacity);
                }
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
            const tr = fonts.getRendererForFamily(size_px, box.style.font_family) orelse return;

            // Paint background on inline text if set
            const ibg = box.style.background_color;
            const ialpha = (ibg >> 24) & 0xFF;
            if (ialpha > 0) {
                const ibg_colour = Surface.applyOpacity(Surface.argbToColour(ibg), effective_opacity);
                for (box.lines.items) |line| {
                    const lx: i32 = @as(i32, @intFromFloat(line.x)) - sx_i;
                    const ly: i32 = @intFromFloat(line.y - scroll_y);
                    const lw: i32 = @intFromFloat(@max(line.width, 0));
                    const lh: i32 = @intFromFloat(@max(line.height, 0));
                    if (ly + lh >= clip_top and ly <= clip_bottom) {
                        const eff_alpha = (ibg_colour >> 24) & 0xFF;
                        if (eff_alpha < 255) {
                            surface.fillRectBlend(lx, ly, lw, lh, ibg_colour);
                        } else {
                            surface.fillRect(lx, ly, lw, lh, ibg_colour);
                        }
                    }
                }
            }

            // Check if text-shadow is set
            const has_text_shadow = ((box.style.text_shadow_color >> 24) & 0xFF) > 0;

            for (box.lines.items) |line| {
                const draw_y: i32 = @intFromFloat(line.y + line.ascent - scroll_y);
                const draw_x: i32 = @as(i32, @intFromFloat(line.x)) - sx_i;
                const line_bottom = @as(i32, @intFromFloat(line.y + line.height - scroll_y));

                // Skip lines entirely outside clip (vertical and horizontal)
                if (line_bottom < clip_top or draw_y - @as(i32, @intFromFloat(line.ascent)) > clip_bottom) continue;
                const line_right = draw_x + @as(i32, @intFromFloat(@max(line.width, 0)));
                if (line_right < clip.left or draw_x > clip.right) continue;

                // Paint text-shadow first (rendered behind the text)
                if (has_text_shadow) {
                    const shadow_colour = Surface.argbToColour(box.style.text_shadow_color);
                    const shadow_off_x: i32 = @intFromFloat(box.style.text_shadow_x);
                    const shadow_off_y: i32 = @intFromFloat(box.style.text_shadow_y);
                    tr.renderGlyphs(
                        line.text,
                        draw_x + shadow_off_x,
                        draw_y + shadow_off_y,
                        BlitCtx,
                        .{ .surface = surface, .colour = shadow_colour, .clip_top = clip_top, .clip_bottom = clip_bottom, .offset_x = 0 },
                        blitGlyphClipped,
                    );
                }

                tr.renderGlyphs(
                    line.text,
                    draw_x,
                    draw_y,
                    BlitCtx,
                    .{ .surface = surface, .colour = colour, .clip_top = clip_top, .clip_bottom = clip_bottom, .offset_x = 0 },
                    blitGlyphClipped,
                );

                // Draw underline based on CSS text-decoration only
                const draw_underline = box.style.text_decoration.underline;
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
        .disc => "\xe2\x97\x8f", // black circle: U+25CF (closer to Firefox's disc)
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
            // Bounds check: skip if point is outside this box.
            // Use a generous check for blocks (children may be shifted by text-align)
            // and skip bounds check entirely for anonymous blocks (they wrap inline
            // content whose positions may differ from the anonymous block's own rect).
            if (box.box_type != .anonymous_block) {
                const mbox = box.marginBox();
                // Add tolerance for text-align shifts
                const tolerance: f32 = if (box.style.text_align == .center or box.style.text_align == .right) box.content.width else 0;
                if (x < mbox.x - tolerance or x > mbox.x + mbox.width + tolerance or
                    y < mbox.y or y > mbox.y + mbox.height)
                    return null;
            }

            // Check children in reverse order (later children are on top)
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const result = hitTestLink(box.children.items[i], x, y);
                if (result != null) return result;
            }
            // No child matched — return this box's own link_url (e.g. <a> as inline_box)
            return box.link_url;
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
