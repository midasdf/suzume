/// Session management module — extracted from main.zig.
/// Handles serializing/restoring browser tabs for session persistence.
const std = @import("std");
const TabManager = @import("../ui/tabs.zig").TabManager;

/// Append a JSON-escaped string to the list, handling control characters.
pub fn appendJsonEscaped(json: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |ch| {
        switch (ch) {
            '"' => try json.appendSlice(allocator, "\\\""),
            '\\' => try json.appendSlice(allocator, "\\\\"),
            '\n' => try json.appendSlice(allocator, "\\n"),
            '\r' => try json.appendSlice(allocator, "\\r"),
            '\t' => try json.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try json.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try json.append(allocator, hex[(ch >> 4) & 0x0f]);
                    try json.append(allocator, hex[ch & 0x0f]);
                } else {
                    try json.append(allocator, ch);
                }
            },
        }
    }
}

/// Serialize open tabs to JSON for session persistence. Excludes private tabs.
pub fn serializeSession(allocator: std.mem.Allocator, tab_mgr: *const TabManager) ?[]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    json.appendSlice(allocator, "[") catch return null;
    var first = true;
    for (tab_mgr.tabs.items) |tab| {
        if (tab.is_private) continue;
        if (tab.url.len == 0) continue;

        if (!first) {
            json.appendSlice(allocator, ",") catch return null;
        }
        first = false;

        json.appendSlice(allocator, "{\"url\":\"") catch return null;
        appendJsonEscaped(&json, allocator, tab.url) catch return null;
        json.appendSlice(allocator, "\",\"title\":\"") catch return null;
        appendJsonEscaped(&json, allocator, tab.title) catch return null;
        // Write scroll_y as integer
        var scroll_buf: [32]u8 = undefined;
        const scroll_str = std.fmt.bufPrint(&scroll_buf, "{d}", .{@as(i32, @intFromFloat(tab.scroll_y))}) catch "0";
        json.appendSlice(allocator, "\",\"scroll_y\":") catch return null;
        json.appendSlice(allocator, scroll_str) catch return null;
        // Write scroll_x as integer
        var scroll_x_buf: [32]u8 = undefined;
        const scroll_x_str = std.fmt.bufPrint(&scroll_x_buf, "{d}", .{@as(i32, @intFromFloat(tab.scroll_x))}) catch "0";
        json.appendSlice(allocator, ",\"scroll_x\":") catch return null;
        json.appendSlice(allocator, scroll_x_str) catch return null;
        json.appendSlice(allocator, "}") catch return null;
    }
    json.appendSlice(allocator, "]") catch return null;

    return json.toOwnedSlice(allocator) catch null;
}

/// Restore tabs from session JSON.
/// Tabs are restored with URLs and titles but pages are NOT loaded (lazy loading).
pub fn restoreSession(
    allocator: std.mem.Allocator,
    json: []const u8,
    tab_mgr: *TabManager,
    page_states_len: *usize,
    add_page_state_fn: *const fn () void,
) void {
    var pos: usize = 0;
    var tab_count: usize = 0;
    _ = add_page_state_fn;
    _ = page_states_len;

    while (pos < json.len) {
        const url_key = std.mem.indexOfPos(u8, json, pos, "\"url\":\"") orelse break;
        const url_start = url_key + 7;
        const url_end = std.mem.indexOfPos(u8, json, url_start, "\"") orelse break;
        const url = json[url_start..url_end];

        var title: []const u8 = url;
        const title_key = std.mem.indexOfPos(u8, json, url_end, "\"title\":\"");
        if (title_key) |tk| {
            const title_start = tk + 9;
            if (std.mem.indexOfPos(u8, json, title_start, "\"")) |title_end| {
                title = json[title_start..title_end];
            }
        }

        if (url.len > 0) {
            if (tab_count == 0 and tab_mgr.tabCount() == 1) {
                tab_mgr.updateActiveUrl(url);
                tab_mgr.updateActiveTitle(if (title.len > 0) title else url);
            } else {
                _ = tab_mgr.newTab(url);
                tab_mgr.updateActiveTitle(if (title.len > 0) title else url);
            }
            tab_count += 1;
        }

        pos = url_end + 1;
    }

    if (tab_count > 0) {
        _ = tab_mgr.switchTo(0);
        std.debug.print("[Session] Restored {d} tabs (lazy loading)\n", .{tab_count});
    }
}
