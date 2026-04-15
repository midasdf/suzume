const std = @import("std");
const env = @import("../env.zig");
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

        // Process @import directives in collected CSS
        try self.processImports(&css_parts, url, &css_link_count, max_css_links);

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

    /// Process @import directives in collected CSS text.
    /// Scans for @import at the beginning of the CSS, fetches the URLs,
    /// and prepends the imported CSS content.
    fn processImports(self: *Loader, css_parts: *std.ArrayListUnmanaged(u8), base_url: [:0]const u8, link_count: *usize, max_links: usize) !void {
        const css_text = css_parts.items;
        if (css_text.len == 0) return;

        // Collect imported CSS content
        var imported_css: std.ArrayListUnmanaged(u8) = .empty;
        defer imported_css.deinit(self.allocator);

        var pos: usize = 0;
        var import_count: usize = 0;
        const max_imports: usize = 10; // Limit to prevent infinite loops

        while (pos < css_text.len and import_count < max_imports and link_count.* < max_links) {
            // Skip whitespace and comments
            while (pos < css_text.len and (css_text[pos] == ' ' or css_text[pos] == '\t' or
                css_text[pos] == '\r' or css_text[pos] == '\n'))
            {
                pos += 1;
            }
            if (pos >= css_text.len) break;

            // Check for @import
            if (pos + 7 < css_text.len and std.mem.eql(u8, css_text[pos .. pos + 7], "@import")) {
                pos += 7;
                // Skip whitespace
                while (pos < css_text.len and (css_text[pos] == ' ' or css_text[pos] == '\t')) pos += 1;

                // Extract URL
                var url_start: usize = pos;
                var url_end: usize = pos;

                if (pos < css_text.len and (css_text[pos] == '"' or css_text[pos] == '\'')) {
                    // @import "url"
                    const quote = css_text[pos];
                    pos += 1;
                    url_start = pos;
                    while (pos < css_text.len and css_text[pos] != quote) pos += 1;
                    url_end = pos;
                    if (pos < css_text.len) pos += 1; // skip closing quote
                } else if (pos + 4 < css_text.len and std.mem.eql(u8, css_text[pos .. pos + 4], "url(")) {
                    // @import url("...")
                    pos += 4;
                    // Skip whitespace
                    while (pos < css_text.len and (css_text[pos] == ' ' or css_text[pos] == '\t')) pos += 1;
                    // Check for quote
                    if (pos < css_text.len and (css_text[pos] == '"' or css_text[pos] == '\'')) {
                        const quote = css_text[pos];
                        pos += 1;
                        url_start = pos;
                        while (pos < css_text.len and css_text[pos] != quote) pos += 1;
                        url_end = pos;
                        if (pos < css_text.len) pos += 1; // skip closing quote
                    } else {
                        url_start = pos;
                        while (pos < css_text.len and css_text[pos] != ')') pos += 1;
                        url_end = pos;
                    }
                    // Skip to closing paren
                    while (pos < css_text.len and css_text[pos] != ')') pos += 1;
                    if (pos < css_text.len) pos += 1;
                } else {
                    // Skip to semicolon - unrecognized format
                    while (pos < css_text.len and css_text[pos] != ';') pos += 1;
                    if (pos < css_text.len) pos += 1;
                    continue;
                }

                // Skip to semicolon
                while (pos < css_text.len and css_text[pos] != ';') pos += 1;
                if (pos < css_text.len) pos += 1;

                // Fetch the imported CSS
                const import_url_raw = std.mem.trim(u8, css_text[url_start..url_end], " \t");
                if (import_url_raw.len > 0) {
                    const resolved = resolveUrl(self.allocator, base_url, import_url_raw) catch continue;
                    defer self.allocator.free(resolved);

                    if (self.adblock_enabled and adblock.shouldBlock(resolved)) continue;

                    var css_resp = self.client.getWithTimeout(self.allocator, resolved, 3) catch continue;
                    defer css_resp.deinit();

                    if (css_resp.status_code == 200 and css_resp.body.len > 0) {
                        imported_css.appendSlice(self.allocator, css_resp.body) catch continue;
                        imported_css.append(self.allocator, '\n') catch continue;
                        link_count.* += 1;
                        import_count += 1;
                    }
                }
            } else if (pos + 2 < css_text.len and css_text[pos] == '/' and css_text[pos + 1] == '*') {
                // Skip CSS comment
                pos += 2;
                while (pos + 1 < css_text.len) {
                    if (css_text[pos] == '*' and css_text[pos + 1] == '/') {
                        pos += 2;
                        break;
                    }
                    pos += 1;
                }
            } else {
                // Not an @import — stop processing (CSS spec: @import must come before other rules)
                break;
            }
        }

        // Prepend imported CSS
        if (imported_css.items.len > 0) {
            try css_parts.insertSlice(self.allocator, 0, imported_css.items);
        }
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

        const home = env.get("HOME") orelse "/tmp";
        const downloads_dir = try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home});
        defer allocator.free(downloads_dir);

        // Ensure directory exists
        std.Io.Dir.cwd().createDirPath(env.ioOrPanic(), downloads_dir) catch {};

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
            if (std.Io.Dir.cwd().access(env.ioOrPanic(), filepath, .{})) |_| {
                // File exists, try next suffix
                allocator.free(filepath);
                suffix += 1;
                continue;
            } else |_| {}

            // File does not exist, create it
            const file = try std.Io.Dir.cwd().createFile(env.ioOrPanic(), filepath, .{ .exclusive = true });
            defer file.close(env.ioOrPanic());
            try env.writeAll(file, body);

            return filepath;
        }

        // Fallback: all suffixes exhausted, overwrite original
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ downloads_dir, safe_name });
        errdefer allocator.free(filepath);

        const file = try std.Io.Dir.cwd().createFile(env.ioOrPanic(), filepath, .{});
        defer file.close(env.ioOrPanic());
        try env.writeAll(file, body);

        return filepath;
    }
};

/// Resolve a possibly-relative URL against a base URL.
/// Returns a sentinel-terminated owned string.
/// Uses the WHATWG URL parser for spec-compliant resolution.
pub fn resolveUrl(allocator: std.mem.Allocator, base_str: []const u8, relative: []const u8) ![:0]const u8 {
    const url_parser = @import("../url/parser.zig");

    // Try parsing as absolute URL first (fast path)
    if (relative.len > 0) {
        var base_url = url_parser.parse(allocator, base_str, null) catch {
            // Base parse failed — fall back to treating relative as absolute
            const result = try allocator.allocSentinel(u8, relative.len, 0);
            @memcpy(result, relative);
            return result;
        };
        if (base_url) |*b| {
            defer b.deinit();
            var resolved = url_parser.parse(allocator, relative, b) catch {
                const result = try allocator.allocSentinel(u8, relative.len, 0);
                @memcpy(result, relative);
                return result;
            };
            if (resolved) |*r| {
                defer r.deinit();
                return r.serializeZ(allocator);
            }
        }
    }

    // Fallback: return relative as-is (or base without fragment for empty relative)
    if (relative.len == 0) {
        const hash = std.mem.indexOfScalar(u8, base_str, '#') orelse base_str.len;
        const result = try allocator.allocSentinel(u8, hash, 0);
        @memcpy(result, base_str[0..hash]);
        return result;
    }

    const result = try allocator.allocSentinel(u8, relative.len, 0);
    @memcpy(result, relative);
    return result;
}
