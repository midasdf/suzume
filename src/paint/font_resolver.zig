const std = @import("std");
const fc = @import("../bindings/fontconfig.zig").c;

/// Resolve a CSS font-family name to a system font file path using fontconfig.
/// Returns a heap-allocated null-terminated path, or null if not found.
/// Caller must free the returned slice with the allocator.
pub fn resolve(allocator: std.mem.Allocator, family: []const u8) ?[:0]const u8 {
    // Create a fontconfig pattern for the family name
    const family_z = allocator.allocSentinel(u8, family.len, 0) catch return null;
    defer allocator.free(family_z);
    @memcpy(family_z, family);

    const pattern = fc.FcNameParse(family_z.ptr) orelse return null;
    defer fc.FcPatternDestroy(pattern);

    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);

    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return null;
    defer fc.FcPatternDestroy(match);

    var file: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file) != fc.FcResultMatch) return null;

    const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    const owned = allocator.allocSentinel(u8, path_slice.len, 0) catch return null;
    @memcpy(owned, path_slice);
    return owned;
}

/// Resolve a CSS font-family list (comma-separated) to a system font path.
/// Tries each name in order, returns the first match.
pub fn resolveList(allocator: std.mem.Allocator, font_family_css: []const u8) ?[:0]const u8 {
    var iter = std.mem.splitScalar(u8, font_family_css, ',');
    while (iter.next()) |raw| {
        var family = std.mem.trim(u8, raw, " \t\r\n");
        // Strip quotes
        if (family.len >= 2 and (family[0] == '\'' or family[0] == '"')) {
            family = family[1 .. family.len - 1];
        }
        if (family.len == 0) continue;
        if (resolve(allocator, family)) |path| return path;
    }
    return null;
}
