const std = @import("std");
const loader = @import("net/loader.zig");

test "fragment-only URL keeps current path and query" {
    const allocator = std.testing.allocator;
    const resolved = try loader.resolveUrl(allocator, "https://example.com/dir/page.html?x=1#old", "#section");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("https://example.com/dir/page.html?x=1#section", resolved);
}

test "query-only URL keeps current path and drops fragment" {
    const allocator = std.testing.allocator;
    const resolved = try loader.resolveUrl(allocator, "https://example.com/dir/page.html?old=1#frag", "?new=2");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("https://example.com/dir/page.html?new=2", resolved);
}

test "suzume internal URLs are absolute" {
    const allocator = std.testing.allocator;
    const resolved = try loader.resolveUrl(allocator, "https://example.com/dir/page.html", "suzume://history");
    defer allocator.free(resolved);

    // URL §4.4: an empty path list serializes as the empty string — no
    // trailing slash gets invented ("foo://" ≠ "foo:///"). This also keeps
    // internal_pages.getPageName's exact-match lookup ("history") working
    // when internal links are resolved through resolveUrl.
    try std.testing.expectEqualStrings("suzume://history", resolved);
}
