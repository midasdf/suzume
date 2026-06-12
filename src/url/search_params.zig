/// WHATWG URL Standard section 5: URLSearchParams.
///
/// application/x-www-form-urlencoded parsing and serialization.
/// All methods operate on an ordered list of name-value pairs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pe = @import("percent_encode.zig");

pub const Entry = struct {
    name: []u8,
    value: []u8,
};

pub const SearchParams = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: Allocator,

    pub fn init(allocator: Allocator, query: ?[]const u8) !SearchParams {
        var sp = SearchParams{
            .entries = .empty,
            .allocator = allocator,
        };
        if (query) |q| {
            try sp.parseFormUrlEncoded(q);
        }
        return sp;
    }

    pub fn deinit(self: *SearchParams) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.entries.deinit(self.allocator);
    }

    /// Parse application/x-www-form-urlencoded string into entries.
    fn parseFormUrlEncoded(self: *SearchParams, input: []const u8) !void {
        // Strip leading '?' if present
        const q = if (input.len > 0 and input[0] == '?') input[1..] else input;
        if (q.len == 0) return;

        var it = std.mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, pair, '=');
            const raw_name = if (eq_idx) |i| pair[0..i] else pair;
            const raw_value = if (eq_idx) |i| pair[i + 1 ..] else "";

            const name = try pe.percentDecodeForm(self.allocator, raw_name);
            const value = try pe.percentDecodeForm(self.allocator, raw_value);
            try self.entries.append(self.allocator, .{ .name = name, .value = value });
        }
    }

    /// Append a name-value pair.
    pub fn append(self: *SearchParams, name: []const u8, value: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    /// Delete all pairs with the given name. If value is provided, only delete matching pairs.
    pub fn delete(self: *SearchParams, name: []const u8, value: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            const name_match = std.mem.eql(u8, e.name, name);
            const value_match = if (value) |v| std.mem.eql(u8, e.value, v) else true;
            if (name_match and value_match) {
                self.allocator.free(e.name);
                self.allocator.free(e.value);
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get the value of the first pair with the given name.
    pub fn get(self: *const SearchParams, name: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    /// Get all values for pairs with the given name.
    pub fn getAll(self: *const SearchParams, name: []const u8, allocator: Allocator) ![][]const u8 {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer result.deinit(allocator);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                try result.append(allocator, e.value);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Check if any pair has the given name. If value is provided, check for exact match.
    pub fn has(self: *const SearchParams, name: []const u8, value: ?[]const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                if (value) |v| {
                    if (std.mem.eql(u8, e.value, v)) return true;
                } else return true;
            }
        }
        return false;
    }

    /// Set the value of the first pair with the given name, remove all others with that name.
    pub fn set(self: *SearchParams, name: []const u8, value: []const u8) !void {
        var found_first = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].name, name)) {
                if (!found_first) {
                    // Replace value of first match
                    self.allocator.free(self.entries.items[i].value);
                    self.entries.items[i].value = try self.allocator.dupe(u8, value);
                    found_first = true;
                    i += 1;
                } else {
                    // Remove subsequent matches
                    self.allocator.free(self.entries.items[i].name);
                    self.allocator.free(self.entries.items[i].value);
                    _ = self.entries.orderedRemove(i);
                }
            } else {
                i += 1;
            }
        }
        if (!found_first) {
            try self.append(name, value);
        }
    }

    /// Sort entries by name using UTF-16 code unit comparison (stable).
    /// WHATWG spec requires UTF-16 code unit ordering, which differs from UTF-8
    /// byte ordering for code points > U+FFFF.
    pub fn sort(self: *SearchParams) void {
        // Insertion sort (stable) with UTF-16 code unit comparison
        const items = self.entries.items;
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0 and utf16GreaterThan(items[j - 1].name, key.name)) {
                items[j] = items[j - 1];
                j -= 1;
            }
            items[j] = key;
        }
    }

    /// Serialize to application/x-www-form-urlencoded string.
    pub fn serialize(self: *const SearchParams) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        for (self.entries.items, 0..) |e, idx| {
            if (idx > 0) try out.append(self.allocator, '&');
            const enc_name = try pe.percentEncode(self.allocator, e.name, .form_urlencoded);
            defer self.allocator.free(enc_name);
            const enc_value = try pe.percentEncode(self.allocator, e.value, .form_urlencoded);
            defer self.allocator.free(enc_value);
            try out.appendSlice(self.allocator, enc_name);
            try out.append(self.allocator, '=');
            try out.appendSlice(self.allocator, enc_value);
        }

        return out.toOwnedSlice(self.allocator);
    }

    pub fn size(self: *const SearchParams) usize {
        return self.entries.items.len;
    }
};

/// Compare two UTF-8 strings by UTF-16 code unit order.
/// Returns true if a > b in UTF-16 code unit comparison.
fn utf16GreaterThan(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len and bi < b.len) {
        const a_cp = decodeUtf8(a, &ai);
        const b_cp = decodeUtf8(b, &bi);

        // Compare as UTF-16 code units
        // For BMP (< U+10000), compare directly
        // For supplementary (>= U+10000), compare high surrogate first, then low
        const a_units = codePointToUtf16Units(a_cp);
        const b_units = codePointToUtf16Units(b_cp);

        if (a_units[0] != b_units[0]) return a_units[0] > b_units[0];
        if (a_units[1] != b_units[1]) return a_units[1] > b_units[1];
    }

    // If all compared equal, longer string is "greater"
    return a.len - ai > b.len - bi;
}

fn decodeUtf8(s: []const u8, pos: *usize) u21 {
    if (pos.* >= s.len) return 0;
    const byte = s[pos.*];
    if (byte < 0x80) {
        pos.* += 1;
        return byte;
    }
    // Decode permissively: Utf8Iterator assumes pre-validated bytes and
    // panics on ill-formed sequences (JS callers can hand us WTF-8 lone
    // surrogates). Invalid bytes decode as U+FFFD.
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        pos.* += 1;
        return 0xFFFD;
    };
    if (pos.* + seq_len > s.len) {
        pos.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[pos.* .. pos.* + seq_len]) catch {
        pos.* += 1;
        return 0xFFFD;
    };
    pos.* += seq_len;
    return cp;
}

fn codePointToUtf16Units(cp: u21) [2]u16 {
    if (cp < 0x10000) {
        return .{ @intCast(cp), 0 };
    }
    // Surrogate pair
    const s = cp - 0x10000;
    return .{
        @intCast(0xD800 + (s >> 10)),
        @intCast(0xDC00 + (s & 0x3FF)),
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse query string" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "foo=bar&baz=qux&foo=baz");
    defer sp.deinit();
    try std.testing.expectEqualStrings("bar", sp.get("foo").?);
    try std.testing.expectEqual(@as(usize, 3), sp.size());
}

test "parse with leading ?" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "?a=1&b=2");
    defer sp.deinit();
    try std.testing.expectEqual(@as(usize, 2), sp.size());
    try std.testing.expectEqualStrings("1", sp.get("a").?);
}

test "getAll returns multiple values" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    const all = try sp.getAll("a", alloc);
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("1", all[0]);
    try std.testing.expectEqualStrings("3", all[1]);
}

test "append and serialize" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, null);
    defer sp.deinit();
    try sp.append("key", "value with spaces");
    const result = try sp.serialize();
    defer alloc.free(result);
    try std.testing.expectEqualStrings("key=value+with+spaces", result);
}

test "delete by name" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    sp.delete("a", null);
    try std.testing.expectEqual(@as(usize, 1), sp.size());
    try std.testing.expect(sp.get("a") == null);
}

test "delete by name and value" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    sp.delete("a", "1");
    try std.testing.expectEqual(@as(usize, 2), sp.size());
    try std.testing.expectEqualStrings("3", sp.get("a").?);
}

test "set replaces first, removes rest" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    try sp.set("a", "99");
    try std.testing.expectEqual(@as(usize, 2), sp.size());
    try std.testing.expectEqualStrings("99", sp.get("a").?);
}

test "sort by name" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "z=1&a=2&m=3");
    defer sp.deinit();
    sp.sort();
    const result = try sp.serialize();
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a=2&m=3&z=1", result);
}

test "has with value" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "a=1&a=2");
    defer sp.deinit();
    try std.testing.expect(sp.has("a", "1"));
    try std.testing.expect(sp.has("a", null));
    try std.testing.expect(!sp.has("a", "3"));
}

test "form-urlencoded decode plus" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "name=hello+world");
    defer sp.deinit();
    try std.testing.expectEqualStrings("hello world", sp.get("name").?);
}

test "serialize empty" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, null);
    defer sp.deinit();
    const result = try sp.serialize();
    defer alloc.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "init empty string" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "");
    defer sp.deinit();
    try std.testing.expectEqual(@as(usize, 0), sp.size());
}

test "pair without value" {
    const alloc = std.testing.allocator;
    var sp = try SearchParams.init(alloc, "key1&key2=val");
    defer sp.deinit();
    try std.testing.expectEqualStrings("", sp.get("key1").?);
    try std.testing.expectEqualStrings("val", sp.get("key2").?);
}
