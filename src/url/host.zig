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

    // WHATWG URL §3.5: empty labels (leading dot, consecutive dots) are
    // validation errors, NOT failures. The host parser returns the domain
    // as-is. Tests: `http://./` → host=".", `http://../` → host="..",
    // `http://foo.09..` → host="foo.09..". The previous Wave 211b rejection
    // of these was spec-incorrect and caused false failures.
    // (endsInNumber + parseIpv4 still correctly reject genuinely invalid IPv4
    // forms like "192.168.1.1.." where parseIpv4 returns failure.)

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

    // WHATWG URL §3.5.2: strip at most ONE trailing dot from the input
    // before splitting. Multiple trailing dots ("192.168.1.1..") should fail.
    var trimmed = input;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    var parts_buf: [4]u64 = undefined;
    var part_count: usize = 0;

    var it = std.mem.splitScalar(u8, trimmed, '.');
    while (it.next()) |part| {
        if (part.len == 0) return null; // empty part (leading dot or double dot)
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

/// Parse an IPv4 address embedded in an IPv6 address per WHATWG URL §4.4.5.
/// Unlike the standalone `parseIpv4`, this does NOT strip a trailing dot —
/// a trailing dot makes the IPv4 (and thus the IPv6) invalid. Also requires
/// exactly 4 dot-separated parts (no short forms like "1.2.3" → 1.2.3.0).
/// Returns null on failure.
fn parseIpv4ForIpv6(input: []const u8) ?u32 {
    if (input.len == 0) return null;

    // Reject trailing dot — IPv4 embedded in IPv6 must not have one.
    if (input[input.len - 1] == '.') return null;

    var parts_buf: [4]u64 = undefined;
    var part_count: usize = 0;

    var it = std.mem.splitScalar(u8, input, '.');
    while (it.next()) |part| {
        if (part.len == 0) return null; // empty part (leading/double/trailing dot)
        if (part_count >= 4) return null; // too many parts

        const num = parseIpv4Number(part) orelse return null;
        parts_buf[part_count] = num;
        part_count += 1;
    }

    if (part_count != 4) return null; // must be exactly 4 parts

    // All parts must be <= 255 (no short-form last-part expansion in IPv6)
    for (parts_buf) |p| {
        if (p > 255) return null;
    }

    var addr: u64 = 0;
    for (parts_buf, 0..) |p, i| {
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

    // WHATWG URL §3.5.2 IPv4 number parser: return failure only on syntax
    // errors (non-radix digits). The "mathematical integer value" can exceed
    // u64 — we saturate to u64 max so endsInNumber still reports true for
    // valid-syntax numbers like "0xFfFfFfFfFfFfFfFfFfAcE123" (which parseIpv4
    // then rejects via the final range check).
    var result: u64 = 0;
    var saturated = false;
    for (input[start..]) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => if (radix == 16) c - 'a' + 10 else return null,
            'A'...'F' => if (radix == 16) c - 'A' + 10 else return null,
            else => return null,
        };
        if (digit >= radix) return null;
        if (!saturated) {
            const mul_res = std.math.mul(u64, result, radix) catch {
                saturated = true;
                continue;
            };
            const add_res = std.math.add(u64, mul_res, digit) catch {
                saturated = true;
                continue;
            };
            result = add_res;
        }
    }

    return result;
}

/// Check if the last label of a host string is numeric (triggers IPv4 parsing).
/// WHATWG URL §3.5.2: a label is numeric if it's a decimal number, OR starts
/// with 0x/0X (hex), OR starts with 0 followed by octal digits. This covers
/// forms like "0300", "0xF0", "192", "0" that appear in url-constructor WPT
/// tests (e.g. http://0300.168.0xF0 → 192.168.0.240).
/// Wave 210b fix: strip one trailing dot before checking, so hosts like
/// "192.168.1.1." correctly trigger IPv4 parsing instead of being treated
/// as domains with an empty last label.
fn endsInNumber(input: []const u8) bool {
    // WHATWG URL §3.5.2 ends-in-a-number checker:
    // 1. parts = strictly split input on '.'
    // 2. If last item is the empty string:
    //    - If parts.size == 1, return false.
    //    - Otherwise, remove the last item from parts.
    // 3. last = last item of parts.
    // 4. If last is non-empty and contains only ASCII digits, return true.
    // 5. If parsing last as IPv4 number does not return failure, return true.
    // 6. Return false.

    // Strictly split input on '.': produces N+1 parts for N dots.
    // "." → ["", ""], ".." → ["", "", ""], "a.b" → ["a", "b"].
    if (input.len == 0) return false;

    // Count dots to determine parts count (parts = dots + 1).
    var dot_count: usize = 0;
    for (input) |c| {
        if (c == '.') dot_count += 1;
    }
    const parts_count = dot_count + 1;

    // Find the last part start (after the last '.'), but the "last item" in
    // the spec's parts list is the substring after the final '.'.
    const last_dot_idx: ?usize = std.mem.lastIndexOfScalar(u8, input, '.');

    // Determine the "last item" of parts, applying step 2 (strip empty last).
    var last_item_start: usize = 0;
    var last_item_end: usize = input.len;
    if (last_dot_idx) |ldi| {
        last_item_start = ldi + 1;
    }

    // If last item is empty, apply step 2 (strip it, look at the prior part).
    if (last_item_start == last_item_end) {
        if (parts_count == 1) return false; // input was empty (shouldn't reach)
        // Move to the prior part: find the '.' before last_dot_idx.
        if (last_dot_idx) |ldi| {
            // Empty last → remove; if parts now has size 1 (no more dots), the
            // single remaining part is input[0..ldi]. Otherwise find prev dot.
            const prev_dot_idx: ?usize = if (ldi == 0) null else std.mem.lastIndexOfScalar(u8, input[0..ldi], '.');
            if (prev_dot_idx) |pdi| {
                last_item_start = pdi + 1;
                last_item_end = ldi;
            } else {
                last_item_start = 0;
                last_item_end = ldi;
            }
        } else {
            return false;
        }
    }

    const last = input[last_item_start..last_item_end];
    if (last.len == 0) return false;

    // Step 4: non-empty and contains only ASCII digits → true.
    var all_digits = true;
    for (last) |c| {
        if (c < '0' or c > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return true;

    // Step 5: parse as IPv4 number — failure → false; success → true.
    if (parseIpv4Number(last) != null) return true;

    return false;
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
            // Backtrack and parse as IPv4 embedded in IPv6 (WHATWG §4.4.5).
            // Unlike standalone parseIpv4, the IPv6-embedded variant does NOT
            // strip a trailing dot and requires exactly 4 parts, so
            // `[::1.2.3.]` and `[::1.2.3]` are correctly rejected.
            const start = i - digits;
            const remaining = input[start..];

            const ipv4 = parseIpv4ForIpv6(remaining) orelse return null;
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

test "parseIpv4 octal parts" {
    // 0300 = 192, 0250 = 168, 01 = 1, 01 = 1
    const result = (try parseIpv4("0300.0250.01.01")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 mixed octal hex decimal" {
    // 0300 (octal=192) . 168 (decimal) . 0xF0 (hex=240) . 1 (decimal)
    const result = (try parseIpv4("0300.168.0xF0.1")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A8F001), result);
}

test "parseIpv4 trailing dot" {
    // WHATWG URL §3.5.2: trailing dot is valid (one trailing dot stripped)
    const result = (try parseIpv4("192.168.1.1.")).?;
    try std.testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 double trailing dot fails" {
    // WHATWG URL §3.5.2: only ONE trailing dot is stripped; ".." should fail
    // because after stripping one dot, the remaining "192.168.1.1." still has
    // an empty part when split.
    const result = try parseIpv4("192.168.1.1..");
    // After stripping one trailing dot → "192.168.1.1." → split produces
    // ["192","168","1","1",""] → empty part → null.
    try std.testing.expect(result == null);
}

test "parseHost trailing dot IPv4 end-to-end" {
    // Wave 210b: endsInNumber must strip trailing dot so parseHost recognizes
    // "192.168.1.1." as IPv4, not a domain with empty last label.
    const result = try parseHost(std.testing.allocator, "192.168.1.1.", false);
    try std.testing.expect(result != null);
    switch (result.?) {
        .ipv4 => |addr| try std.testing.expectEqual(@as(u32, 0xC0A80101), addr),
        else => return error.UnexpectedHostType,
    }
    freeHost(std.testing.allocator, result.?);
}

test "parseHost consecutive dots is validation error (WHATWG §3.5)" {
    // WHATWG URL §3.5: empty labels are validation errors, NOT failures.
    // `http://192.168.1.1..` would have endsInNumber=true (after stripping one
    // trailing dot, last part "09"-ish numeric), then parseIpv4 fails on the
    // empty part — that path still returns failure. But a pure domain with
    // consecutive dots like "example..com" has no numeric last label, so it
    // is returned as a domain (validation error only).
    // Here we verify the non-numeric consecutive-dot case succeeds.
    const result = try parseHost(std.testing.allocator, "example..com", false);
    try std.testing.expect(result != null);
    switch (result.?) {
        .domain => |d| try std.testing.expectEqualStrings("example..com", d),
        else => return error.UnexpectedHostType,
    }
    freeHost(std.testing.allocator, result.?);
}

test "parseHost leading dot is validation error (WHATWG §3.5)" {
    // WHATWG URL §3.5: leading dot is a validation error, not failure.
    // `http://./` → host="." (per urltestdata.json "Domains with empty labels").
    const result = try parseHost(std.testing.allocator, ".", false);
    try std.testing.expect(result != null);
    switch (result.?) {
        .domain => |d| try std.testing.expectEqualStrings(".", d),
        else => return error.UnexpectedHostType,
    }
    freeHost(std.testing.allocator, result.?);
}

test "parseHost double dot is validation error (WHATWG §3.5)" {
    // WHATWG URL §3.5: `http://../` → host=".." (per urltestdata.json).
    const result = try parseHost(std.testing.allocator, "..", false);
    try std.testing.expect(result != null);
    switch (result.?) {
        .domain => |d| try std.testing.expectEqualStrings("..", d),
        else => return error.UnexpectedHostType,
    }
    freeHost(std.testing.allocator, result.?);
}

test "endsInNumber detects octal" {
    // Wave 210b: endsInNumber must detect octal numbers (starting with 0)
    try std.testing.expect(endsInNumber("192.168.1.0300"));
    try std.testing.expect(endsInNumber("192.168.1.0"));
    try std.testing.expect(endsInNumber("192.168.1.0xF0"));
    try std.testing.expect(endsInNumber("192.168.1.255"));
    // Trailing dot should be stripped before checking
    try std.testing.expect(endsInNumber("192.168.1.1."));
    try std.testing.expect(endsInNumber("192.168.1.0300."));
    // Non-numeric last label should NOT trigger
    try std.testing.expect(!endsInNumber("example.com"));
    try std.testing.expect(!endsInNumber("192.168.1.abc"));
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
