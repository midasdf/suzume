const std = @import("std");
const c = @import("../bindings/freetype.zig").c;

pub const GlyphBitmap = struct {
    /// Glyph bitmap pixels (8-bit grayscale alpha).
    buffer: [*]const u8,
    /// Width of the bitmap in pixels.
    width: u32,
    /// Height of the bitmap in pixels (rows).
    height: u32,
    /// Pitch (bytes per row, may be negative).
    pitch: i32,
    /// X position to draw at (pen_x + bitmap_left).
    x: i32,
    /// Y position to draw at (pen_y - bitmap_top).
    y: i32,
};

pub const TextMetrics = struct {
    width: i32,
    height: i32,
    ascent: i32,
    descent: i32,
};

pub const TextRenderer = struct {
    ft_library: c.FT_Library,
    ft_face: c.FT_Face,
    hb_font: *c.hb_font_t,
    font_size_px: u32,

    pub fn init(font_path: [*:0]const u8, font_size_px: u32) !TextRenderer {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) {
            return error.FreeTypeInitFailed;
        }
        errdefer _ = c.FT_Done_FreeType(library);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library, font_path, 0, &face) != 0) {
            return error.FontLoadFailed;
        }
        errdefer _ = c.FT_Done_Face(face);

        // Set pixel size (0 for width means auto from height)
        if (c.FT_Set_Pixel_Sizes(face, 0, font_size_px) != 0) {
            return error.SetSizeFailed;
        }

        const hb_font = c.hb_ft_font_create_referenced(face) orelse return error.HarfBuzzFontFailed;

        return .{
            .ft_library = library,
            .ft_face = face,
            .hb_font = hb_font,
            .font_size_px = font_size_px,
        };
    }

    /// Initialize from raw font data in memory (for @font-face web fonts).
    /// The caller must keep `font_data` alive for the lifetime of this TextRenderer.
    pub fn initFromMemory(font_data: []const u8, font_size_px: u32) !TextRenderer {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) {
            return error.FreeTypeInitFailed;
        }
        errdefer _ = c.FT_Done_FreeType(library);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(library, font_data.ptr, @intCast(font_data.len), 0, &face) != 0) {
            return error.FontLoadFailed;
        }
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, font_size_px) != 0) {
            return error.SetSizeFailed;
        }

        const hb_font = c.hb_ft_font_create_referenced(face) orelse return error.HarfBuzzFontFailed;

        return .{
            .ft_library = library,
            .ft_face = face,
            .hb_font = hb_font,
            .font_size_px = font_size_px,
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_library);
    }

    /// Measure text dimensions using HarfBuzz shaping.
    pub fn measure(self: *TextRenderer, text: []const u8) TextMetrics {
        const buf = c.hb_buffer_create() orelse return .{ .width = 0, .height = 0, .ascent = 0, .descent = 0 };
        defer c.hb_buffer_destroy(buf);

        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);
        c.hb_buffer_set_script(buf, c.HB_SCRIPT_COMMON);
        c.hb_buffer_guess_segment_properties(buf);

        c.hb_shape(self.hb_font, buf, null, 0);

        var glyph_count: u32 = 0;
        const positions = c.hb_buffer_get_glyph_positions(buf, &glyph_count);

        var total_advance: i32 = 0;
        for (0..glyph_count) |i| {
            // HarfBuzz positions are in 26.6 fixed point
            total_advance += @divTrunc(positions[i].x_advance, 64);
        }

        // Get font metrics from FreeType (in 26.6 fixed point)
        const metrics = self.ft_face.*.size.*.metrics;
        const ascent = @divTrunc(@as(i32, @intCast(metrics.ascender)), 64);
        const descent = @divTrunc(@as(i32, @intCast(metrics.descender)), 64);

        return .{
            .width = total_advance,
            .height = ascent - descent,
            .ascent = ascent,
            .descent = descent,
        };
    }

    /// Shape text and render each glyph, calling a callback with bitmap data.
    /// The callback receives positional info so the caller can blit to a surface.
    pub fn renderGlyphs(
        self: *TextRenderer,
        text: []const u8,
        base_x: i32,
        base_y: i32,
        comptime Context: type,
        ctx: Context,
        comptime callback: fn (Context, GlyphBitmap) void,
    ) void {
        const buf = c.hb_buffer_create() orelse return;
        defer c.hb_buffer_destroy(buf);

        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);
        c.hb_buffer_set_script(buf, c.HB_SCRIPT_COMMON);
        c.hb_buffer_guess_segment_properties(buf);

        c.hb_shape(self.hb_font, buf, null, 0);

        var glyph_count: u32 = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
        const positions = c.hb_buffer_get_glyph_positions(buf, &glyph_count);

        var pen_x: i32 = base_x;
        var pen_y: i32 = base_y;

        for (0..glyph_count) |i| {
            const glyph_index = infos[i].codepoint;
            const x_offset = @divTrunc(positions[i].x_offset, 64);
            const y_offset = @divTrunc(positions[i].y_offset, 64);
            const x_advance = @divTrunc(positions[i].x_advance, 64);
            const y_advance = @divTrunc(positions[i].y_advance, 64);

            // Load and render the glyph
            if (c.FT_Load_Glyph(self.ft_face, glyph_index, c.FT_LOAD_RENDER) != 0) {
                pen_x += x_advance;
                pen_y += y_advance;
                continue;
            }

            const glyph = self.ft_face.*.glyph;
            const bitmap = glyph.*.bitmap;

            if (bitmap.buffer != null and bitmap.width > 0 and bitmap.rows > 0) {
                callback(ctx, .{
                    .buffer = bitmap.buffer,
                    .width = bitmap.width,
                    .height = bitmap.rows,
                    .pitch = bitmap.pitch,
                    .x = pen_x + x_offset + glyph.*.bitmap_left,
                    .y = pen_y + y_offset - glyph.*.bitmap_top,
                });
            }

            pen_x += x_advance;
            pen_y += y_advance;
        }
    }
};
