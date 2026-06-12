const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EncodeSet = enum {
    c0_control,
    fragment,
    query,
    special_query,
    path,
    userinfo,
    component,
    form_urlencoded,
};

/// Returns true if the byte should be percent-encoded for the given set.
/// Each set is a superset of the previous (except form_urlencoded which is independent).
pub fn inEncodeSet(byte: u8, set: EncodeSet) bool {
    // C0 control: 0x00-0x1F and > 0x7E — always encoded in all sets
    if (byte <= 0x1F or byte > 0x7E) return true;

    return switch (set) {
        .c0_control => false,
        .fragment => switch (byte) {
            ' ', '"', '<', '>', '`' => true,
            else => false,
        },
        .query => switch (byte) {
            ' ', '"', '#', '<', '>' => true,
            else => false,
        },
        .special_query => switch (byte) {
            ' ', '"', '#', '<', '>', '\'' => true,
            else => false,
        },
        .path => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '^', '`', '{', '}' => true,
            else => false,
        },
        .userinfo => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '`', '{', '}',
            '/', ':', ';', '=', '@', '[', '\\', ']', '^', '|',
            => true,
            else => false,
        },
        .component => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '`', '{', '}',
            '/', ':', ';', '=', '@', '[', '\\', ']', '^', '|',
            '$', '&', '+', ',',
            => true,
            else => false,
        },
        .form_urlencoded => switch (byte) {
            '*', '-', '.', '0'...'9', 'A'...'Z', '_', 'a'...'z' => false,
            else => true,
        },
    };
}

const hex_upper = "0123456789ABCDEF";

/// Percent-encode a byte string according to the given encode set.
pub fn percentEncode(allocator: Allocator, input: []const u8, set: EncodeSet) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |byte| {
        if (set == .form_urlencoded and byte == ' ') {
            try result.append(allocator, '+');
        } else if (inEncodeSet(byte, set)) {
            try result.append(allocator, '%');
            try result.append(allocator, hex_upper[byte >> 4]);
            try result.append(allocator, hex_upper[byte & 0x0F]);
        } else {
            try result.append(allocator, byte);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Percent-decode a byte string. Replaces %XX sequences with the byte value.
pub fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    return percentDecodeOpts(allocator, input, false);
}

/// Percent-decode with application/x-www-form-urlencoded rules ('+' -> space).
pub fn percentDecodeForm(allocator: Allocator, input: []const u8) ![]u8 {
    return percentDecodeOpts(allocator, input, true);
}

fn percentDecodeOpts(allocator: Allocator, input: []const u8, plus_as_space: bool) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (hexVal(input[i + 1])) |hi| {
                if (hexVal(input[i + 2])) |lo| {
                    try result.append(allocator, (@as(u8, hi) << 4) | lo);
                    i += 3;
                    continue;
                }
            }
            // Not a valid %XX sequence — output the '%' literally
            try result.append(allocator, input[i]);
            i += 1;
        } else if (plus_as_space and input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'F' => @intCast(c - 'A' + 10),
        'a'...'f' => @intCast(c - 'a' + 10),
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "percentEncode c0_control passes ASCII printable" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "hello world", .c0_control);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentEncode c0_control encodes control chars" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "a\x00b\x1Fc", .c0_control);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a%00b%1Fc", result);
}

test "percentEncode fragment set" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "a b<c>d\"e", .fragment);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a%20b%3Cc%3Ed%22e", result);
}

test "percentEncode query set" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "a #b<c>", .query);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a%20%23b%3Cc%3E", result);
}

test "percentEncode special_query encodes apostrophe" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "it's", .special_query);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("it%27s", result);
}

test "percentEncode userinfo set" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "user:pass@host", .userinfo);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("user%3Apass%40host", result);
}

test "percentEncode component set" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "a=1&b=2", .component);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a%3D1%26b%3D2", result);
}

test "percentEncode form_urlencoded" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "hello world&foo=bar", .form_urlencoded);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello+world%26foo%3Dbar", result);
}

test "percentEncode non-ASCII bytes" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "\xc3\xa9", .c0_control);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("%C3%A9", result);
}

test "percentDecode basic" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "hello%20world%3F");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world?", result);
}

test "percentDecode lowercase hex" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "%c3%a9");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("\xc3\xa9", result);
}

test "percentDecodeForm plus as space" {
    const alloc = std.testing.allocator;
    const result = try percentDecodeForm(alloc, "hello+world");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentDecode invalid sequence passthrough" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "100%pure%GGok");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("100%pure%GGok", result);
}

test "percentDecode truncated percent at end" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "abc%");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("abc%", result);
}

test "percentDecode single hex digit only" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "abc%4z");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("abc%4z", result);
}

test "percentDecode empty input" {
    const alloc = std.testing.allocator;
    const result = try percentDecode(alloc, "");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "percentEncode empty input" {
    const alloc = std.testing.allocator;
    const result = try percentEncode(alloc, "", .path);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("", result);
}
