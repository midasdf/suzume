/// URL utility functions — extracted from main.zig.
/// Handles URL input processing, tracking pixel detection, and SVG detection.
const std = @import("std");
const form_handler = @import("form_handler.zig");

/// Process URL bar input: detect search queries vs URLs.
/// - If input starts with http:// or https://, use as-is.
/// - If input contains a dot (e.g. "example.com"), prepend https://
/// - Otherwise, treat as a search query and redirect to Brave Search.
/// Returns an owned sentinel-terminated string.
pub fn processUrlInput(allocator: std.mem.Allocator, input: []const u8) ![:0]const u8 {
    // Already a full URL
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        const result = try allocator.allocSentinel(u8, input.len, 0);
        @memcpy(result, input);
        return result;
    }

    // Internal pages
    if (std.mem.startsWith(u8, input, "suzume://")) {
        const result = try allocator.allocSentinel(u8, input.len, 0);
        @memcpy(result, input);
        return result;
    }

    // Contains a dot — likely a domain name, prepend https://
    if (std.mem.indexOf(u8, input, ".") != null) {
        const prefix = "https://";
        const result = try allocator.allocSentinel(u8, prefix.len + input.len, 0);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..][0..input.len], input);
        return result;
    }

    // Otherwise, treat as a search query
    const base = "https://search.brave.com/search?q=";
    const source = "&source=web";

    var encoded_len: usize = 0;
    for (input) |ch| {
        if (form_handler.isUrlSafe(ch)) {
            encoded_len += 1;
        } else if (ch == ' ') {
            encoded_len += 1;
        } else {
            encoded_len += 3;
        }
    }

    const total_len = base.len + encoded_len + source.len;
    const result = try allocator.allocSentinel(u8, total_len, 0);

    @memcpy(result[0..base.len], base);

    var pos: usize = base.len;
    for (input) |ch| {
        if (form_handler.isUrlSafe(ch)) {
            result[pos] = ch;
            pos += 1;
        } else if (ch == ' ') {
            result[pos] = '+';
            pos += 1;
        } else {
            const hex = "0123456789ABCDEF";
            result[pos] = '%';
            result[pos + 1] = hex[(ch >> 4) & 0x0f];
            result[pos + 2] = hex[ch & 0x0f];
            pos += 3;
        }
    }

    @memcpy(result[pos..][0..source.len], source);
    return result;
}

/// Check if a URL is likely a tracking pixel or beacon image.
pub fn isTrackingPixel(url: []const u8, intrinsic_w: f32, intrinsic_h: f32) bool {
    if (url.len == 0) return false;
    const is_tiny = intrinsic_w > 0 and intrinsic_h > 0 and intrinsic_w <= 2 and intrinsic_h <= 2;
    if (is_tiny) {
        return true;
    }

    if (intrinsic_w == 0 and intrinsic_h == 0) {
        var lower_buf: [512]u8 = undefined;
        const check_len = @min(url.len, lower_buf.len);
        for (url[0..check_len], 0..) |ch, idx| {
            lower_buf[idx] = std.ascii.toLower(ch);
        }
        const lower_url = lower_buf[0..check_len];
        const tracking_patterns = [_][]const u8{ "/pixel.", "/beacon", "/1x1", "/spacer." };
        for (tracking_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_url, pattern) != null) {
                return true;
            }
        }
    }

    return false;
}

/// Check if a URL points to an SVG image (by file extension).
pub fn isSvgUrl(url: []const u8) bool {
    const path_end = std.mem.indexOf(u8, url, "?") orelse std.mem.indexOf(u8, url, "#") orelse url.len;
    const path = url[0..path_end];
    if (path.len < 4) return false;

    const ext = path[path.len - 4 ..];
    return std.mem.eql(u8, ext, ".svg");
}

/// Check if content-type indicates SVG.
pub fn isSvgContentType(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "image/svg");
}
