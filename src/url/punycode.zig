const std = @import("std");
const Allocator = std.mem.Allocator;

// RFC 3492 constants
const base: u32 = 36;
const tmin: u32 = 1;
const tmax: u32 = 26;
const skew: u32 = 38;
const damp: u32 = 700;
const initial_bias: u32 = 72;
const initial_n: u32 = 128;

pub const Error = error{
    Overflow,
    InvalidInput,
    OutOfMemory,
};

fn adapt(delta_in: u32, num_points: u32, first_time: bool) u32 {
    var delta = if (first_time) delta_in / damp else delta_in / 2;
    delta += delta / num_points;
    var k: u32 = 0;
    while (delta > ((base - tmin) * tmax) / 2) {
        delta /= base - tmin;
        k += base;
    }
    return k + ((base - tmin + 1) * delta) / (delta + skew);
}

fn digitToBasic(d: u32) u8 {
    if (d < 26) return @intCast(d + 'a') else return @intCast(d - 26 + '0');
}

fn basicToDigit(c: u8) ?u32 {
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= '0' and c <= '9') return @as(u32, c - '0') + 26;
    return null;
}

/// Encode Unicode code points to Punycode ASCII string.
/// Uses checked arithmetic to detect overflow per RFC 3492 Section 6.3.
pub fn encode(allocator: Allocator, input: []const u21) Error![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    // Copy basic code points (ASCII < 128)
    var basic_count: u32 = 0;
    for (input) |cp| {
        if (cp < 128) {
            try output.append(allocator, @intCast(cp));
            basic_count += 1;
        }
    }
    // Delimiter between basic and extended parts
    if (basic_count > 0) try output.append(allocator, '-');

    var n: u32 = initial_n;
    var delta: u32 = 0;
    var bias_val: u32 = initial_bias;
    var handled: u32 = basic_count;
    const input_len: u32 = @intCast(input.len);

    while (handled < input_len) {
        // Find the minimum code point >= n
        var m: u32 = std.math.maxInt(u32);
        for (input) |cp| {
            if (cp >= n and cp < m) m = cp;
        }

        // Checked arithmetic: delta += (m - n) * (handled + 1)
        delta = std.math.add(u32, delta, std.math.mul(u32, m - n, handled + 1) catch return error.Overflow) catch return error.Overflow;
        n = m;

        for (input) |cp| {
            if (cp < n) {
                delta = std.math.add(u32, delta, 1) catch return error.Overflow;
            }
            if (cp == n) {
                var q = delta;
                var k: u32 = base;
                while (true) {
                    const t_val = if (k <= bias_val) tmin else if (k >= bias_val + tmax) tmax else k - bias_val;
                    if (q < t_val) break;
                    try output.append(allocator, digitToBasic(t_val + (q - t_val) % (base - t_val)));
                    q = (q - t_val) / (base - t_val);
                    k += base;
                }
                try output.append(allocator, digitToBasic(q));
                bias_val = adapt(delta, handled + 1, handled == basic_count);
                delta = 0;
                handled += 1;
            }
        }
        delta += 1;
        n += 1;
    }

    return output.toOwnedSlice(allocator);
}

/// Decode Punycode ASCII string to Unicode code points.
/// Uses checked arithmetic to detect overflow per RFC 3492 Section 6.3.
pub fn decode(allocator: Allocator, input: []const u8) Error![]u21 {
    var output: std.ArrayListUnmanaged(u21) = .empty;
    errdefer output.deinit(allocator);

    // Find the last '-' to separate basic from encoded parts
    var basic_end: usize = 0;
    var found_delimiter = false;
    for (input, 0..) |c, idx| {
        if (c == '-') {
            basic_end = idx;
            found_delimiter = true;
        }
    }

    // Copy basic code points (everything before the last '-')
    if (found_delimiter) {
        for (input[0..basic_end]) |c| {
            try output.append(allocator, c);
        }
    }

    var n: u32 = initial_n;
    var i: u32 = 0;
    var bias_val: u32 = initial_bias;
    var pos: usize = if (found_delimiter) basic_end + 1 else 0;

    while (pos < input.len) {
        const old_i = i;
        var w: u32 = 1;
        var k: u32 = base;
        while (pos < input.len) {
            const digit = basicToDigit(input[pos]) orelse return error.InvalidInput;
            pos += 1;
            // Checked arithmetic: i += digit * w
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return error.Overflow) catch return error.Overflow;
            const t_val = if (k <= bias_val) tmin else if (k >= bias_val + tmax) tmax else k - bias_val;
            if (digit < t_val) break;
            w = std.math.mul(u32, w, base - t_val) catch return error.Overflow;
            k += base;
        }
        const out_len: u32 = @intCast(output.items.len + 1);
        bias_val = adapt(i - old_i, out_len, old_i == 0);
        n = std.math.add(u32, n, i / out_len) catch return error.Overflow;
        i = i % out_len;

        try output.insert(allocator, i, @intCast(n));
        i += 1;
    }

    return output.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

test "encode pure ASCII" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 'a', 'b', 'c' };
    const result = try encode(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("abc-", result);
}

test "encode Arabic (Egyptian) — RFC 3492 example" {
    const alloc = std.testing.allocator;
    const input = [_]u21{
        0x0644, 0x064A, 0x0647, 0x0645, 0x0627,
        0x0628, 0x062A, 0x0643, 0x0644, 0x0645,
        0x0648, 0x0634, 0x0639, 0x0631, 0x0628,
        0x064A, 0x061F,
    };
    const result = try encode(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("egbpdaj6bu4bxfgehfvwxn", result);
}

test "encode mixed ASCII and non-ASCII (Muenchen)" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 'M', 0x00FC, 'n', 'c', 'h', 'e', 'n' };
    const result = try encode(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Mnchen-3ya", result);
}

test "encode Japanese — RFC 3492 example" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ '3', 0x5E74, 'B', 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F };
    const result = try encode(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("3B-ww4c5e180e575a65lsy2b", result);
}

test "decode roundtrip (Muenchen)" {
    const alloc = std.testing.allocator;
    const original = [_]u21{ 'M', 0x00FC, 'n', 'c', 'h', 'e', 'n' };
    const encoded = try encode(alloc, &original);
    defer alloc.free(encoded);
    const decoded = try decode(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u21, &original, decoded);
}

test "decode roundtrip (Arabic)" {
    const alloc = std.testing.allocator;
    const original = [_]u21{
        0x0644, 0x064A, 0x0647, 0x0645, 0x0627,
        0x0628, 0x062A, 0x0643, 0x0644, 0x0645,
        0x0648, 0x0634, 0x0639, 0x0631, 0x0628,
        0x064A, 0x061F,
    };
    const encoded = try encode(alloc, &original);
    defer alloc.free(encoded);
    const decoded = try decode(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u21, &original, decoded);
}

test "decode roundtrip (Japanese)" {
    const alloc = std.testing.allocator;
    const original = [_]u21{ '3', 0x5E74, 'B', 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F };
    const encoded = try encode(alloc, &original);
    defer alloc.free(encoded);
    const decoded = try decode(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u21, &original, decoded);
}

test "decode invalid input" {
    const alloc = std.testing.allocator;
    const result = decode(alloc, "abc!def");
    try std.testing.expectError(error.InvalidInput, result);
}

test "encode empty input" {
    const alloc = std.testing.allocator;
    const result = try encode(alloc, &[_]u21{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decode empty input" {
    const alloc = std.testing.allocator;
    const result = try decode(alloc, "");
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
