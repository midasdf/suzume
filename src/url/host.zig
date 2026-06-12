/// WHATWG URL Standard section 3: Host parsing.
///
/// Parses host strings into domain, IPv4, IPv6, or opaque host representations.
/// Uses IDNA for domain processing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const idna = @import("idna.zig");
const pe = @import("percent_encode.zig");

pub const Host = union(enum) {
    domain: []u8,
    ipv4: u32,
    ipv6: [8]u16,
    opaque_host: []u8,
    // Empty host is represented as domain("").
};

/// Free the memory owned by a Host value.
pub fn freeHost(allocator: Allocator, h: Host) void {
    switch (h) {
        .domain => |d| if (d.len > 0) allocator.free(d),
        .opaque_host => |o| allocator.free(o),
        .ipv4, .ipv6 => {},
    }
}

/// Parse a host string per WHATWG URL Standard section 3.
/// Returns null on parse failure.
pub fn parseHost(allocator: Allocator, input: []const u8, is_not_special: bool) !?Host {
    if (input.len == 0) {
        const empty = try allocator.alloc(u8, 0);
        return Host{ .domain = empty };
    }

    // 1. If input starts with '[', parse IPv6
    if (input[0] == '[') {
        if (input.len < 2 or input[input.len - 1] != ']') return null;
        const inner = input[1 .. input.len - 1];
        const addr = parseIpv6(inner) orelse return null;
        return Host{ .ipv6 = addr };
    }

    // 2. If not special, parse as opaque host
    if (is_not_special) {
        const result = try parseOpaqueHost(allocator, input) orelse return null;
        return Host{ .opaque_host = result };
    }

    // 3. Percent-decode
    const decoded = try pe.percentDecode(allocator, input);
    defer allocator.free(decoded);

    // 4. Domain processing via IDNA
    const ascii_domain = try idna.domainToAscii(allocator, decoded, false) orelse return null;

    // UTS #46 §4.2 / URL §3.5: an empty string out of domain-to-ASCII is a
    // validation error ("https://\u00ad/" — soft hyphen maps to nothing).
    if (ascii_domain.len == 0) {
        allocator.free(ascii_domain);
        return null;
    }

    // 5. Check for forbidden host code points
    for (ascii_domain) |c| {
        if (isForbiddenHostCodePoint(c)) {
            allocator.free(ascii_domain);
            return null;
        }
    }

    // 6. Try IPv4 parse (if ends in a number)
    if (ascii_domain.len > 0 and endsInNumber(ascii_domain)) {
        if (try parseIpv4(ascii_domain)) |addr| {
            allocator.free(ascii_domain);
            return Host{ .ipv4 = addr };
        }
        // If endsInNumber but IPv4 parse fails, it's a failure
        allocator.free(ascii_domain);
        return null;
    }

    // 7. Return as domain
    return Host{ .domain = ascii_domain };
}

/// Parse an opaque host (non-special schemes).
fn parseOpaqueHost(allocator: Allocator, input: []const u8) !?[]u8 {
    // URL Â§3.5 forbidden host code points: NUL, tab, LF, CR, space and the
    // listed delimiters. Other C0 controls are allowed and percent-encoded
    // below ("wpt++://te%1Fst" is a valid opaque host).
    for (input) |c| {
        switch (c) {
            0x00, 0x09, 0x0A, 0x0D, ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|' => return null,
            else => {},
        }
    }
    // Percent-encode C0 controls and non-ASCII
    return try pe.percentEncode(allocator, input, .c0_control);
}

// ── IPv4 ─────────────────────────────────────────────────────────────

/// Parse an IPv4 address per WHATWG URL Standard section 3.5.
/// Supports decimal, octal (0-prefix), and hex (0x-prefix) parts.
/// Returns null on failure.
pub fn parseIpv4(input: []const u8) !?u32 {
    if (input.len == 0) return null;

    var parts_buf: [4]u64 = undefined;
    var part_count: usize = 0;

    var it = std.mem.splitScalar(u8, input, '.');
    while (it.next()) |part| {
        if (part.len == 0) return null; // empty part
        if (part_count >= 4) return null; // too many parts

        const num = parseIpv4Number(part) orelse return null;
        parts_buf[part_count] = num;
        part_count += 1;
    }

    if (part_count == 0) return null;

    // Validate ranges
    // Last part can be up to 256^(5-part_count) - 1
    // All other parts must be <= 255
    for (parts_buf[0 .. part_count - 1]) |p| {
        if (p > 255) return null;
    }

    const max_last: u64 = @as(u64, 1) << @intCast(8 * (5 - part_count));
    if (parts_buf[part_count - 1] >= max_last) return null;

    // Assemble the address
    var addr: u64 = parts_buf[part_count - 1];
    for (parts_buf[0 .. part_count - 1], 0..) |p, i| {
        const shift: u6 = @intCast(8 * (3 - i));
        addr += p << shift;
    }

    return @intCast(addr);
}

fn parseIpv4Number(input: []const u8) ?u64 {
    if (input.len == 0) return null;

    var radix: u8 = 10;
    var start: usize = 0;

    if (input.len >= 2 and input[0] == '0') {
        if (input[1] == 'x' or input[1] == 'X') {
            radix = 16;
            start = 2;
        } else {
            radix = 8;
            start = 1;
        }
    }

    if (start >= input.len) {
        // "0x" alone or "0" alone
        return 0;
    }

    var result: u64 = 0;
    for (input[start..]) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => if (radix == 16) c - 'a' + 10 else return null,
            'A'...'F' => if (radix == 16) c - 'A' + 10 else return null,
            else => return null,
        };
        if (digit >= radix) return null;
        result = std.math.mul(u64, result, radix) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }

    return result;
}

/// Check if the last label of a host string is numeric (triggers IPv4 parsing).
fn endsInNumber(input: []const u8) bool {
    // Find the last '.' and check the part after it
    const last_dot = std.mem.lastIndexOfScalar(u8, input, '.') orelse 0;
    const last_part = if (last_dot == 0 and input[0] != '.') input else input[last_dot + 1 ..];

    if (last_part.len == 0) return false;

    // If it starts with 0x/0X, it's hex
    if (last_part.len >= 2 and last_part[0] == '0' and (last_part[1] == 'x' or last_part[1] == 'X')) return true;

    // If all digits, it's a number
    for (last_part) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ── IPv6 ────────────────��────────────────────────────────────────────

/// Parse an IPv6 address per WHATWG URL Standard section 3.6.
/// Input should NOT include the surrounding brackets.
pub fn parseIpv6(input: []const u8) ?[8]u16 {
    var addr = [_]u16{0} ** 8;
    var piece_idx: usize = 0;
    var compress_idx: ?usize = null;

    var i: usize = 0;

    // Check for leading "::"
    if (input.len >= 2 and input[0] == ':' and input[1] == ':') {
        i = 2;
        compress_idx = piece_idx;
    } else if (input.len > 0 and input[0] == ':') {
        return null; // single leading ':'
    }

    while (i < input.len) {
        if (piece_idx >= 8) return null;

        // Check for "::" (compression)
        if (i < input.len and input[i] == ':') {
            if (compress_idx != null) return null; // double compression
            i += 1;
            piece_idx += 1;
            compress_idx = piece_idx;
            continue;
        }

        // Parse hex value
        var value: u16 = 0;
        var digits: usize = 0;
        while (i < input.len and digits < 4) {
            const c = input[i];
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => break,
            };
            value = value * 16 + d;
            digits += 1;
            i += 1;
        }

        if (digits == 0) return null;

        // Check for IPv4 embedded address (last two pieces)
        if (i < input.len and input[i] == '.' and piece_idx <= 6) {
            // Backtrack and parse as IPv4
            // Find the start of this number
            const start = i - digits;
            const remaining = input[start..];

            // Parse IPv4
            const ipv4 = (parseIpv4(remaining) catch return null) orelse return null;
            addr[piece_idx] = @intCast((ipv4 >> 16) & 0xFFFF);
            addr[piece_idx + 1] = @intCast(ipv4 & 0xFFFF);
            piece_idx += 2;
            i = input.len;
            break;
        }

        addr[piece_idx] = value;
        piece_idx += 1;

        if (i < input.len) {
            if (input[i] != ':') return null;
            i += 1;

            // Check for "::" after piece
            if (i < input.len and input[i] == ':') {
                if (compress_idx != null) return null;
                i += 1;
                compress_idx = piece_idx;
            }
        }
    }

    // Fill in compressed zeros
    if (compress_idx) |ci| {
        if (piece_idx >= 8) return null;
        const zeros_needed = 8 - piece_idx;
        // Shift pieces after compress_idx to the right
        var j: usize = piece_idx;
        while (j > ci) {
            j -= 1;
            addr[j + zeros_needed] = addr[j];
            addr[j] = 0;
        }
    } else {
        if (piece_idx != 8) return null;
    }

    return addr;
}

// ── Serialization ─────────────��──────────────────────────────────────

/// Serialize a host value to a string.
pub fn serializeHost(allocator: Allocator, h: Host) ![]u8 {
    return switch (h) {
        .domain => |d| try allocator.dupe(u8, d),
        .opaque_host => |o| try allocator.dupe(u8, o),
        .ipv4 => |addr| try serializeIpv4(allocator, addr),
        .ipv6 => |addr| try serializeIpv6(allocator, addr),
    };
}

/// Serialize an IPv4 address to "a.b.c.d" format.
pub fn serializeIpv4(allocator: Allocator, addr: u32) ![]u8 {
    var buf: [15]u8 = undefined; // max "255.255.255.255"
    const s = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
        (addr >> 24) & 0xFF,
        (addr >> 16) & 0xFF,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
    }) catch unreachable;
    return try allocator.dupe(u8, s);
}

/// Serialize an IPv6 address with :: compression, wrapped in brackets.
pub fn serializeIpv6(allocator: Allocator, addr: [8]u16) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.append(allocator, '[');

    // Find the longest run of zeros for :: compression
    var best_start: usize = 8;
    var best_len: usize = 0;
    var cur_start: usize = 0;
    var cur_len: usize = 0;

    for (addr, 0..) |piece, idx| {
        if (piece == 0) {
            if (cur_len == 0) cur_start = idx;
            cur_len += 1;
            if (cur_len > best_len and cur_len >= 2) {
                best_start = cur_start;
                best_len = cur_len;
            }
        } else {
            cur_len = 0;
        }
    }

    var i: usize = 0;
    var after_compress = false;
    while (i < 8) {
        if (best_start < 8 and i == best_start) {
            try result.appendSlice(allocator, "::");
            i += best_len;
            after_compress = true;
            continue;
        }

        if (i > 0 and !after_compress) {
            try result.append(allocator, ':');
        }
        after_compress = false;

        // Write hex without leading zeros
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x}", .{addr[i]}) catch unreachable;
        try result.appendSlice(allocator, s);

        i += 1;
    }

    try result.append(allocator, ']');
    return result.toOwnedSlice(allocator);
}

fn isForbiddenHostCodePoint(c: u8) bool {
    return switch (c) {
        0x00, 0x09, 0x0A, 0x0D, ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|' => true,
        else => false,
    };
}

// ── Tests ────────────────────────────────────────��───────────────────

test "parseIpv4 basic" {
    const result = (try parseIpv4("192.168.1.1")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 loopback" {
    const result = (try parseIpv4("127.0.0.1")).?;
    try std.testing.expectEqual(@as(u32, 0x7F000001), result);
}

test "parseIpv4 single number" {
    // 3232235777 = 192.168.1.1
    const result = (try parseIpv4("3232235777")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 two parts" {
    // 192.11010305 = 192 + (168*65536 + 1*256 + 1) = 192.168.1.1
    const result = (try parseIpv4("192.11010305")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 hex parts" {
    const result = (try parseIpv4("0xC0.0xA8.0x01.0x01")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv6 loopback" {
    const result = parseIpv6("::1").?;
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 1), result[7]);
}

test "parseIpv6 full" {
    const result = parseIpv6("2001:db8:85a3:0:0:8a2e:370:7334").?;
    try std.testing.expectEqual(@as(u16, 0x2001), result[0]);
    try std.testing.expectEqual(@as(u16, 0x0db8), result[1]);
    try std.testing.expectEqual(@as(u16, 0x7334), result[7]);
}

test "parseIpv6 compression" {
    const result = parseIpv6("2001:db8::1").?;
    try std.testing.expectEqual(@as(u16, 0x2001), result[0]);
    try std.testing.expectEqual(@as(u16, 0x0db8), result[1]);
    for (result[2..7]) |p| try std.testing.expectEqual(@as(u16, 0), p);
    try std.testing.expectEqual(@as(u16, 1), result[7]);
}

test "parseIpv6 all zeros" {
    const result = parseIpv6("::").?;
    for (result) |p| try std.testing.expectEqual(@as(u16, 0), p);
}

test "parseIpv6 invalid single colon" {
    try std.testing.expect(parseIpv6(":1") == null);
}

test "serializeIpv4" {
    const alloc = std.testing.allocator;
    const result = try serializeIpv4(alloc, 0xC0A80101);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("192.168.1.1", result);
}

test "serializeIpv6 compression" {
    const alloc = std.testing.allocator;
    const addr = [8]u16{ 0x2001, 0x0db8, 0, 0, 0, 0, 0, 1 };
    const result = try serializeIpv6(alloc, addr);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[2001:db8::1]", result);
}

test "serializeIpv6 loopback" {
    const alloc = std.testing.allocator;
    const addr = [8]u16{ 0, 0, 0, 0, 0, 0, 0, 1 };
    const result = try serializeIpv6(alloc, addr);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[::1]", result);
}

test "parseHost domain" {
    const alloc = std.testing.allocator;
    const result = (try parseHost(alloc, "EXAMPLE.COM", false)).?;
    defer freeHost(alloc, result);
    try std.testing.expectEqualStrings("example.com", result.domain);
}

test "parseHost IPv4" {
    const alloc = std.testing.allocator;
    const result = (try parseHost(alloc, "192.168.1.1", false)).?;
    defer freeHost(alloc, result);
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result.ipv4);
}

test "parseHost IPv6" {
    const alloc = std.testing.allocator;
    const result = (try parseHost(alloc, "[::1]", false)).?;
    defer freeHost(alloc, result);
    try std.testing.expectEqual(@as(u16, 1), result.ipv6[7]);
}

test "parseHost opaque for non-special" {
    const alloc = std.testing.allocator;
    const result = (try parseHost(alloc, "hello-world", true)).?;
    defer freeHost(alloc, result);
    try std.testing.expectEqualStrings("hello-world", result.opaque_host);
}

test "parseHost empty" {
    const alloc = std.testing.allocator;
    const result = (try parseHost(alloc, "", false)).?;
    defer freeHost(alloc, result);
    try std.testing.expectEqualStrings("", result.domain);
}
