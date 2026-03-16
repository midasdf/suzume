// HarfBuzz C bindings — re-exports from the combined FreeType+HarfBuzz import.
// FreeType and HarfBuzz must share a single @cImport to avoid incompatible
// FT_Face types between the two. Use freetype.zig for the combined namespace.
pub const c = @import("freetype.zig").c;
