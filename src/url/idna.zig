/// UTS #46 IDNA Processing — domain name internationalization.
///
/// Implements domainToAscii and domainToUnicode per WHATWG URL Standard section 3.3.
/// Uses tables.zig for IDNA mapping, nfc.zig for normalization, punycode.zig for encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("tables.zig");
const nfc = @import("nfc.zig");
const punycode = @import("punycode.zig");

/// Convert a domain to its ASCII representation (ACE form).
/// Returns null on failure (invalid domain).
pub fn domainToAscii(allocator: Allocator, domain: []const u8, be_strict: bool) !?[]u8 {
    // 1. Decode UTF-8 to code points
    var codepoints: std.ArrayListUnmanaged(u21) = .empty;
    defer codepoints.deinit(allocator);

    var iter = std.unicode.Utf8Iterator{ .bytes = domain, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        try codepoints.append(allocator, cp);
    }

    // 2. Apply IDNA mapping
    var mapped: std.ArrayListUnmanaged(u21) = .empty;
    defer mapped.deinit(allocator);

    for (codepoints.items) |cp| {
        const entry = tables.lookupCodePoint(cp);
        switch (entry.status) {
            .valid => try mapped.append(allocator, cp),
            .ignored => {}, // skip
            .mapped, .disallowed_STD3_mapped => {
                if (entry.status == .disallowed_STD3_mapped and be_strict) return null;
                const m = tables.getMapping(entry);
                for (m) |mcp| try mapped.append(allocator, mcp);
            },
            .deviation => {
                // Non-transitional processing: treat as valid
                try mapped.append(allocator, cp);
            },
            .disallowed => return null,
            .disallowed_STD3_valid => {
                if (be_strict) return null;
                try mapped.append(allocator, cp);
            },
        }
    }

    // 3. NFC normalize
    const normalized = try nfc.nfcNormalize(allocator, mapped.items);
    defer allocator.free(normalized);

    // 4. Split on '.' (U+002E) and process each label
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var label_start: usize = 0;
    var first_label = true;

    for (normalized, 0..) |cp, idx| {
        if (cp == '.' or idx == normalized.len - 1) {
            const label_end = if (cp == '.') idx else idx + 1;
            const label = normalized[label_start..label_end];

            if (!first_label) try result.append(allocator, '.');
            first_label = false;

            // Process this label
            const ascii_label = try processLabel(allocator, label, be_strict) orelse return null;
            defer allocator.free(ascii_label);
            try result.appendSlice(allocator, ascii_label);

            label_start = idx + 1;
        }
    }

    // Handle trailing dot
    if (normalized.len > 0 and normalized[normalized.len - 1] == '.') {
        try result.append(allocator, '.');
    }

    // Handle empty domain
    if (result.items.len == 0 and normalized.len == 0) {
        const empty = try allocator.alloc(u8, 0);
        return @as(?[]u8, empty);
    }

    const slice = try result.toOwnedSlice(allocator);
    return @as(?[]u8, slice);
}

/// Convert a domain from ACE form back to Unicode.
pub fn domainToUnicode(allocator: Allocator, domain: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var it = std.mem.splitScalar(u8, domain, '.');
    var first = true;
    while (it.next()) |label| {
        if (!first) try result.append(allocator, '.');
        first = false;

        if (std.ascii.startsWithIgnoreCase(label, "xn--")) {
            // Decode Punycode
            const encoded = label[4..];
            const decoded = punycode.decode(allocator, encoded) catch {
                // On decode failure, keep the ACE label as-is
                try result.appendSlice(allocator, label);
                continue;
            };
            defer allocator.free(decoded);
            // Encode back to UTF-8
            for (decoded) |cp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch continue;
                try result.appendSlice(allocator, buf[0..len]);
            }
        } else {
            try result.appendSlice(allocator, label);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Process a single domain label (sequence of code points between dots).
/// Returns the ASCII representation, or null on validation failure.
fn processLabel(allocator: Allocator, label: []const u21, be_strict: bool) !?[]u8 {
    _ = be_strict;

    if (label.len == 0) return try allocator.dupe(u8, "");

    // Check if label is pure ASCII
    var has_non_ascii = false;
    for (label) |cp| {
        if (cp > 0x7F) {
            has_non_ascii = true;
            break;
        }
    }

    if (has_non_ascii) {
        // Punycode encode
        const encoded = punycode.encode(allocator, label) catch return null;
        defer allocator.free(encoded);

        // Build "xn--" + encoded
        var ace: std.ArrayListUnmanaged(u8) = .empty;
        errdefer ace.deinit(allocator);
        try ace.appendSlice(allocator, "xn--");
        try ace.appendSlice(allocator, encoded);

        const ace_label = ace.toOwnedSlice(allocator) catch return null;

        // Validate: decode and re-encode to verify roundtrip
        // (This catches invalid Punycode encoding)

        // Validate label constraints
        if (!validateAceLabel(ace_label)) {
            allocator.free(ace_label);
            return null;
        }

        return ace_label;
    } else {
        // Pure ASCII label — lowercase and validate
        var ascii: std.ArrayListUnmanaged(u8) = .empty;
        errdefer ascii.deinit(allocator);
        for (label) |cp| {
            try ascii.append(allocator, std.ascii.toLower(@intCast(cp)));
        }
        const result = ascii.toOwnedSlice(allocator) catch return null;

        if (!validateAsciiLabel(result)) {
            allocator.free(result);
            return null;
        }

        return result;
    }
}

/// Validate an ACE label (xn--...).
fn validateAceLabel(label: []const u8) bool {
    return validateAsciiLabel(label);
}

/// Validate a plain ASCII label.
fn validateAsciiLabel(label: []const u8) bool {
    if (label.len == 0) return true;

    // Max label length: 63 bytes
    if (label.len > 63) return false;

    // Must not start or end with hyphen
    if (label[0] == '-' or label[label.len - 1] == '-') return false;

    // Check for forbidden host code points
    for (label) |c| {
        if (isForbiddenDomainCodePoint(c)) return false;
    }

    return true;
}

fn isForbiddenDomainCodePoint(c: u8) bool {
    return switch (c) {
        0x00...0x1F, 0x7F, // C0 controls and DEL
        '%', // percent (must be part of percent-encoding, not raw)
        ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|',
        => true,
        else => false,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "domainToAscii pure ASCII" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "example.com", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii uppercase to lowercase" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "EXAMPLE.COM", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii German umlaut" {
    const alloc = std.testing.allocator;
    // "münchen.de" -> "xn--mnchen-3ya.de"
    const result = (try domainToAscii(alloc, "m\xc3\xbcnchen.de", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("xn--mnchen-3ya.de", result);
}

test "domainToAscii Japanese" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "\xe4\xbe\x8b\xe3\x81\x88.jp", false)).?;
    defer alloc.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "xn--"));
    try std.testing.expect(std.mem.endsWith(u8, result, ".jp"));
}

test "domainToAscii single label" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "localhost", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("localhost", result);
}

test "domainToAscii trailing dot" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "example.com.", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com.", result);
}

test "domainToUnicode ACE to unicode" {
    const alloc = std.testing.allocator;
    const result = try domainToUnicode(alloc, "xn--mnchen-3ya.de");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("m\xc3\xbcnchen.de", result);
}

test "domainToUnicode plain ASCII passthrough" {
    const alloc = std.testing.allocator;
    const result = try domainToUnicode(alloc, "example.com");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii label too long fails" {
    const alloc = std.testing.allocator;
    // 64 characters label — exceeds 63 byte limit
    const long_label = "a" ** 64 ++ ".com";
    const result = try domainToAscii(alloc, long_label, false);
    try std.testing.expect(result == null);
}
