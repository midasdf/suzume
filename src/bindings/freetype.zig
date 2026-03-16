// FreeType + HarfBuzz C bindings via a single @cImport
// (Must be in one block so FT_Face type is shared between FreeType and HarfBuzz)
pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
