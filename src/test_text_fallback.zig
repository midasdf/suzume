const std = @import("std");
const text = @import("paint/text.zig");
const c = @import("bindings/freetype.zig").c;

test "CJK fallback resolves codepoints, not HarfBuzz cluster byte offsets" {
    const macos = @import("builtin").os.tag == .macos;
    const latin = if (macos) "/System/Library/Fonts/Helvetica.ttc" else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
    const cjk = if (macos) "/System/Library/Fonts/Hiragino Sans GB.ttc" else "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
    var renderer = try text.TextRenderer.init(latin, 20);
    defer renderer.deinit();
    renderer.loadFallback(cjk);
    try std.testing.expect(renderer.fallback_face != null);
    const face = renderer.fallback_face.?;
    // The primary font lacks these glyphs; the fallback must determine advance.
    try std.testing.expectEqual(@as(c_uint, 0), c.FT_Get_Char_Index(renderer.ft_face, '日'));
    const glyph = c.FT_Get_Char_Index(face, '日');
    try std.testing.expect(glyph != 0);
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Load_Glyph(face, glyph, c.FT_LOAD_DEFAULT));
    const expected_advance = @divTrunc(@as(i32, @intCast(face.*.glyph.*.advance.x)), 64);
    try std.testing.expectEqual(expected_advance * 2, renderer.measure("日日").width);
    const Capture = struct {
        count: usize = 0,
        last_x: i32 = 0,
        advance: i32 = 0,
        fn captureGlyph(self: *@This(), bitmap: text.GlyphBitmap) void {
            if (self.count > 0) self.advance = bitmap.x - self.last_x;
            self.last_x = bitmap.x;
            self.count += 1;
        }
    };
    var capture = Capture{};
    renderer.renderGlyphs("日日", 0, 24, *Capture, &capture, Capture.captureGlyph);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(expected_advance, capture.advance);
    // Replacing the fallback must release the previous face.
    renderer.loadFallback(cjk);
}
