const std = @import("std");
const Storage = @import("storage.zig").Storage;

/// HTML-escape a string to prevent XSS when inserting user content into generated HTML.
fn escapeHtml(allocator: std.mem.Allocator, html: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '&' => try html.appendSlice(allocator, "&amp;"),
            '<' => try html.appendSlice(allocator, "&lt;"),
            '>' => try html.appendSlice(allocator, "&gt;"),
            '"' => try html.appendSlice(allocator, "&quot;"),
            else => try html.append(allocator, ch),
        }
    }
}

/// Check if a URL is an internal suzume:// page.
pub fn isInternalUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "suzume://");
}

/// Get the page name from a suzume:// URL (e.g., "history" from "suzume://history").
pub fn getPageName(url: []const u8) ?[]const u8 {
    if (!isInternalUrl(url)) return null;
    const name = url["suzume://".len..];
    if (name.len == 0) return null;
    return name;
}

/// Generate HTML content for suzume://history.
pub fn generateHistoryPage(allocator: std.mem.Allocator, storage: *Storage) ?[]u8 {
    const entries = storage.getHistory(100);
    defer storage.freeHistory(entries);

    var html: std.ArrayListUnmanaged(u8) = .empty;
    errdefer html.deinit(allocator);

    html.appendSlice(allocator,
        \\<html><head><style>
        \\body { background: #1e1e2e; color: #cdd6f4; font-family: sans-serif; font-size: 14px; padding: 16px; }
        \\h1 { color: #cba6f7; font-size: 20px; margin-bottom: 16px; }
        \\a { color: #89b4fa; text-decoration: none; }
        \\a:hover { text-decoration: underline; }
        \\.entry { margin-bottom: 8px; }
        \\.time { color: #6c7086; font-size: 12px; margin-left: 8px; }
        \\.empty { color: #6c7086; font-style: italic; }
        \\</style></head><body>
        \\<h1>History</h1>
    ) catch return null;

    if (entries.len == 0) {
        html.appendSlice(allocator, "<p class=\"empty\">No history yet.</p>") catch return null;
    } else {
        for (entries) |entry| {
            html.appendSlice(allocator, "<div class=\"entry\"><a href=\"") catch return null;
            escapeHtml(allocator, &html, entry.url) catch return null;
            html.appendSlice(allocator, "\">") catch return null;
            // Use title if available, otherwise URL
            const display = if (entry.title.len > 0) entry.title else entry.url;
            escapeHtml(allocator, &html, display) catch return null;
            html.appendSlice(allocator, "</a><span class=\"time\">") catch return null;
            escapeHtml(allocator, &html, entry.visited_at) catch return null;
            html.appendSlice(allocator, "</span></div>\n") catch return null;
        }
    }

    html.appendSlice(allocator, "</body></html>") catch return null;
    return html.toOwnedSlice(allocator) catch null;
}

/// Generate HTML content for suzume://bookmarks.
pub fn generateBookmarksPage(allocator: std.mem.Allocator, storage: *Storage) ?[]u8 {
    const entries = storage.getBookmarks();
    defer storage.freeBookmarks(entries);

    var html: std.ArrayListUnmanaged(u8) = .empty;
    errdefer html.deinit(allocator);

    html.appendSlice(allocator,
        \\<html><head><style>
        \\body { background: #1e1e2e; color: #cdd6f4; font-family: sans-serif; font-size: 14px; padding: 16px; }
        \\h1 { color: #cba6f7; font-size: 20px; margin-bottom: 16px; }
        \\a { color: #89b4fa; text-decoration: none; }
        \\a:hover { text-decoration: underline; }
        \\.entry { margin-bottom: 8px; }
        \\.time { color: #6c7086; font-size: 12px; margin-left: 8px; }
        \\.empty { color: #6c7086; font-style: italic; }
        \\</style></head><body>
        \\<h1>Bookmarks</h1>
    ) catch return null;

    if (entries.len == 0) {
        html.appendSlice(allocator, "<p class=\"empty\">No bookmarks yet. Press Ctrl+D to bookmark a page.</p>") catch return null;
    } else {
        for (entries) |entry| {
            html.appendSlice(allocator, "<div class=\"entry\"><a href=\"") catch return null;
            escapeHtml(allocator, &html, entry.url) catch return null;
            html.appendSlice(allocator, "\">") catch return null;
            const display = if (entry.title.len > 0) entry.title else entry.url;
            escapeHtml(allocator, &html, display) catch return null;
            html.appendSlice(allocator, "</a><span class=\"time\">") catch return null;
            escapeHtml(allocator, &html, entry.created_at) catch return null;
            html.appendSlice(allocator, "</span></div>\n") catch return null;
        }
    }

    html.appendSlice(allocator, "</body></html>") catch return null;
    return html.toOwnedSlice(allocator) catch null;
}

/// Generate HTML for an internal page by URL. Returns owned HTML slice or null.
pub fn generatePage(allocator: std.mem.Allocator, url: []const u8, storage: ?*Storage) ?[]u8 {
    const page_name = getPageName(url) orelse return null;
    const store = storage orelse return generateErrorPage(allocator, "Storage not available");

    if (std.mem.eql(u8, page_name, "history")) {
        return generateHistoryPage(allocator, store);
    } else if (std.mem.eql(u8, page_name, "bookmarks")) {
        return generateBookmarksPage(allocator, store);
    } else {
        return generateErrorPage(allocator, "Unknown internal page");
    }
}

fn generateErrorPage(allocator: std.mem.Allocator, message: []const u8) ?[]u8 {
    var html: std.ArrayListUnmanaged(u8) = .empty;
    errdefer html.deinit(allocator);

    html.appendSlice(allocator,
        \\<html><head><style>
        \\body { background: #1e1e2e; color: #f38ba8; font-family: sans-serif; font-size: 14px; padding: 16px; }
        \\</style></head><body><h1>Error</h1><p>
    ) catch return null;
    html.appendSlice(allocator, message) catch return null;
    html.appendSlice(allocator, "</p></body></html>") catch return null;
    return html.toOwnedSlice(allocator) catch null;
}
