const std = @import("std");
const HttpClient = @import("http.zig").HttpClient;
const Response = @import("http.zig").Response;
const Document = @import("../dom/tree.zig").Document;
const DomNode = @import("../dom/node.zig").DomNode;
const adblock = @import("../features/adblock.zig");

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
    adblock_enabled: bool = true,
    download_status: ?[]const u8 = null,

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

        // Walk entire document for <link rel="stylesheet"> and <style>
        // (not just <head> — many sites put CSS links in <body>)
        var css_link_count: usize = 0;
        const max_css_links: usize = 40; // Allow more CSS for complex sites like GitHub
        if (doc.root()) |root_node| {
            try self.walkForCssLinks(root_node, url, &css_parts, &css_link_count, max_css_links);
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
        // Ad block check
        if (self.adblock_enabled and adblock.shouldBlock(url)) {
            std.debug.print("[AdBlock] Blocked: {s}\n", .{url});
            return error.AdBlocked;
        }
        return try self.client.get(self.allocator, url);
    }

    /// Fetch raw bytes with a custom timeout (for images: shorter timeout).
    pub fn loadBytesWithTimeout(self: *Loader, url: [:0]const u8, timeout_secs: c_long) !Response {
        if (self.adblock_enabled and adblock.shouldBlock(url)) {
            std.debug.print("[AdBlock] Blocked: {s}\n", .{url});
            return error.AdBlocked;
        }
        return try self.client.getWithTimeout(self.allocator, url, timeout_secs);
    }

    /// Recursively walk DOM to find <link rel="stylesheet"> and <style> tags.
    fn walkForCssLinks(self: *Loader, node: DomNode, base_url: [:0]const u8, css_parts: *std.ArrayListUnmanaged(u8), link_count: *usize, max_links: usize) !void {
        if (node.nodeType() == .element) {
            const tag = node.tagName() orelse "";

            if (std.mem.eql(u8, tag, "link")) {
                const rel = node.getAttribute("rel") orelse "";
                if (std.mem.eql(u8, rel, "stylesheet") and link_count.* < max_links) {
                    const href = node.getAttribute("href") orelse "";
                    if (href.len > 0) {
                        const resolved = resolveUrl(self.allocator, base_url, href) catch return;
                        defer self.allocator.free(resolved);

                        if (self.adblock_enabled and adblock.shouldBlock(resolved)) return;

                        var css_resp = self.client.getWithTimeout(self.allocator, resolved, 3) catch return;
                        defer css_resp.deinit();

                        if (css_resp.status_code == 200 and css_resp.body.len > 0) {
                            css_parts.appendSlice(self.allocator, css_resp.body) catch return;
                            css_parts.append(self.allocator, '\n') catch return;
                            link_count.* += 1;
                        }
                    }
                }
                return; // <link> has no children
            } else if (std.mem.eql(u8, tag, "style")) {
                if (node.firstChild()) |text_node| {
                    if (text_node.textContent()) |text| {
                        css_parts.appendSlice(self.allocator, text) catch return;
                        css_parts.append(self.allocator, '\n') catch return;
                    }
                }
                return; // Don't recurse into <style>
            } else if (std.mem.eql(u8, tag, "script")) {
                return; // Skip script content
            }
        }

        // Recurse into children
        var child = node.firstChild();
        while (child) |c| {
            try self.walkForCssLinks(c, base_url, css_parts, link_count, max_links);
            child = c.nextSibling();
        }
    }

    /// Check if a response should be downloaded (non-renderable content type).
    pub fn isDownloadable(content_type: []const u8) bool {
        // Renderable types that the browser handles
        if (std.mem.startsWith(u8, content_type, "text/html")) return false;
        if (std.mem.startsWith(u8, content_type, "text/css")) return false;
        if (std.mem.startsWith(u8, content_type, "image/")) return false;
        if (std.mem.startsWith(u8, content_type, "text/plain")) return false;
        // Everything else is a download
        if (content_type.len == 0) return false; // unknown, try to render
        return true;
    }

    /// Extract filename from a URL.
    pub fn filenameFromUrl(url: []const u8) []const u8 {
        // Find the last path component
        const path_end = std.mem.indexOf(u8, url, "?") orelse url.len;
        const path = url[0..path_end];
        if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
            const name = path[idx + 1 ..];
            if (name.len > 0) return name;
        }
        return "download";
    }

    /// Sanitize a filename by stripping path separators and ".." segments.
    fn sanitizeFilename(filename: []const u8) []const u8 {
        var name = filename;
        // Strip everything up to and including the last path separator
        if (std.mem.lastIndexOfAny(u8, name, "/\\")) |idx| {
            name = name[idx + 1 ..];
        }
        // Reject ".." as a filename
        if (std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".")) {
            return "download";
        }
        if (name.len == 0) return "download";
        return name;
    }

    /// Save a download to ~/Downloads/, avoiding overwrites by appending (1), (2), etc.
    pub fn saveDownload(allocator: std.mem.Allocator, filename: []const u8, body: []const u8) ![]const u8 {
        const safe_name = sanitizeFilename(filename);

        const home = std.posix.getenv("HOME") orelse "/tmp";
        const downloads_dir = try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home});
        defer allocator.free(downloads_dir);

        // Ensure directory exists
        std.fs.cwd().makePath(downloads_dir) catch {};

        // Split filename into base and extension for suffix insertion
        const dot_idx = std.mem.lastIndexOf(u8, safe_name, ".");
        const base = if (dot_idx) |d| safe_name[0..d] else safe_name;
        const ext = if (dot_idx) |d| safe_name[d..] else "";

        // Try the original name first, then append (1), (2), etc.
        var suffix: u32 = 0;
        while (suffix < 1000) {
            const filepath = if (suffix == 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ downloads_dir, safe_name })
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}({d}){s}", .{ downloads_dir, base, suffix, ext });
            errdefer allocator.free(filepath);

            // Check if file already exists
            if (std.fs.cwd().access(filepath, .{})) |_| {
                // File exists, try next suffix
                allocator.free(filepath);
                suffix += 1;
                continue;
            } else |_| {}

            // File does not exist, create it
            const file = try std.fs.cwd().createFile(filepath, .{ .exclusive = true });
            defer file.close();
            try file.writeAll(body);

            return filepath;
        }

        // Fallback: all suffixes exhausted, overwrite original
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ downloads_dir, safe_name });
        errdefer allocator.free(filepath);

        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        try file.writeAll(body);

        return filepath;
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

    // Check if dir needs a trailing / (origin-only URL like "https://example.com")
    const needs_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const slash_len: usize = if (needs_slash) 1 else 0;
    const result = try allocator.allocSentinel(u8, dir.len + slash_len + rel.len, 0);
    @memcpy(result[0..dir.len], dir);
    if (needs_slash) result[dir.len] = '/';
    @memcpy(result[dir.len + slash_len ..][0..rel.len], rel);
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
    // No path component — origin-only URL like "https://example.com"
    // The last / is inside the scheme "://", so we need to treat the whole URL as the base
    // and append "/" for proper relative resolution
    // We can't allocate here, so return the full URL — resolveUrl handles this case
    // by checking if scheme_end == url.len (no path after host)
    return url;
}
