const std = @import("std");
const HttpClient = @import("http.zig").HttpClient;
const Response = @import("http.zig").Response;
const Document = @import("../dom/tree.zig").Document;
const DomNode = @import("../dom/node.zig").DomNode;

pub const PageContent = struct {
    html: []u8,
    css: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PageContent) void {
        self.allocator.free(self.html);
        if (self.css.len > 0) {
            self.allocator.free(self.css);
        }
    }
};

pub const Loader = struct {
    client: *HttpClient,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, client: *HttpClient) Loader {
        return .{
            .client = client,
            .allocator = allocator,
        };
    }

    /// Fetch a page: download HTML, extract <link rel="stylesheet"> and <style> tags,
    /// fetch external CSS, return combined HTML + CSS.
    pub fn loadPage(self: *Loader, url: [:0]const u8) !PageContent {
        var response = try self.client.get(self.allocator, url);
        defer response.deinit();

        // Copy HTML body (response will be freed)
        const html = try self.allocator.alloc(u8, response.body.len);
        @memcpy(html, response.body);

        // Parse HTML to extract stylesheet links and inline styles
        var doc = Document.parse(html) catch {
            return PageContent{
                .html = html,
                .css = try self.allocator.alloc(u8, 0),
                .allocator = self.allocator,
            };
        };
        defer doc.deinit();

        var css_parts: std.ArrayListUnmanaged(u8) = .empty;
        errdefer css_parts.deinit(self.allocator);

        // Walk <head> children for <link rel="stylesheet"> and <style>
        if (doc.head()) |head_node| {
            var child = head_node.firstChild();
            while (child) |node| {
                defer child = node.nextSibling();

                if (node.nodeType() != .element) continue;
                const tag = node.tagName() orelse continue;

                if (std.mem.eql(u8, tag, "link")) {
                    // Check rel="stylesheet"
                    const rel = node.getAttribute("rel") orelse continue;
                    if (!std.mem.eql(u8, rel, "stylesheet")) continue;

                    const href = node.getAttribute("href") orelse continue;

                    // Resolve URL
                    const resolved = try resolveUrl(self.allocator, url, href);
                    defer self.allocator.free(resolved);

                    // Fetch CSS
                    var css_resp = self.client.get(self.allocator, resolved) catch continue;
                    defer css_resp.deinit();

                    if (css_resp.status_code == 200) {
                        try css_parts.appendSlice(self.allocator, css_resp.body);
                        try css_parts.append(self.allocator, '\n');
                    }
                } else if (std.mem.eql(u8, tag, "style")) {
                    // Inline <style> — get text content
                    if (node.firstChild()) |text_node| {
                        if (text_node.textContent()) |text| {
                            try css_parts.appendSlice(self.allocator, text);
                            try css_parts.append(self.allocator, '\n');
                        }
                    }
                }
            }
        }

        const css = try css_parts.toOwnedSlice(self.allocator);

        return PageContent{
            .html = html,
            .css = css,
            .allocator = self.allocator,
        };
    }

    /// Fetch raw bytes (for images, etc.)
    pub fn loadBytes(self: *Loader, url: [:0]const u8) !Response {
        return try self.client.get(self.allocator, url);
    }
};

/// Resolve a possibly-relative URL against a base URL.
/// Returns a sentinel-terminated owned string.
pub fn resolveUrl(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![:0]const u8 {
    // Absolute URL (has scheme)
    if (std.mem.startsWith(u8, relative, "https://") or std.mem.startsWith(u8, relative, "http://")) {
        const result = try allocator.allocSentinel(u8, relative.len, 0);
        @memcpy(result, relative);
        return result;
    }

    // Protocol-relative: //host/path
    if (std.mem.startsWith(u8, relative, "//")) {
        const scheme = extractScheme(base);
        const result = try allocator.allocSentinel(u8, scheme.len + relative.len, 0);
        @memcpy(result[0..scheme.len], scheme);
        @memcpy(result[scheme.len..][0..relative.len], relative);
        return result;
    }

    // Root-relative: /path
    if (relative.len > 0 and relative[0] == '/') {
        const origin = extractOrigin(base);
        const result = try allocator.allocSentinel(u8, origin.len + relative.len, 0);
        @memcpy(result[0..origin.len], origin);
        @memcpy(result[origin.len..][0..relative.len], relative);
        return result;
    }

    // Relative path: strip last component from base, append relative
    const base_dir = extractBaseDir(base);
    const clean_rel = if (std.mem.startsWith(u8, relative, "./")) relative[2..] else relative;

    // Handle ../ by walking up base_dir
    var dir = base_dir;
    var rel = clean_rel;
    while (std.mem.startsWith(u8, rel, "../")) {
        rel = rel[3..];
        // Walk up one directory
        if (std.mem.lastIndexOf(u8, dir[0 .. dir.len -| 1], "/")) |idx| {
            dir = dir[0 .. idx + 1];
        }
    }

    const result = try allocator.allocSentinel(u8, dir.len + rel.len, 0);
    @memcpy(result[0..dir.len], dir);
    @memcpy(result[dir.len..][0..rel.len], rel);
    return result;
}

fn extractScheme(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "://")) |idx| {
        return url[0 .. idx + 1]; // e.g. "https:"
    }
    return "https:";
}

fn extractOrigin(url: []const u8) []const u8 {
    // Find scheme://
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    // Find next /
    if (std.mem.indexOfPos(u8, url, scheme_end, "/")) |idx| {
        return url[0..idx];
    }
    return url;
}

fn extractBaseDir(url: []const u8) []const u8 {
    // Find the last / after the scheme
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    if (std.mem.lastIndexOf(u8, url, "/")) |idx| {
        if (idx >= scheme_end) {
            return url[0 .. idx + 1];
        }
    }
    // No path component, add trailing /
    return url;
}
