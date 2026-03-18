const std = @import("std");
const StringPool = @import("string_pool").StringPool;

test "same string returns same pointer" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("hello");
    const b = pool.intern("hello");
    try std.testing.expectEqual(a.ptr, b.ptr);
}

test "different strings return different pointers" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("foo");
    const b = pool.intern("bar");
    try std.testing.expect(a.ptr != b.ptr);
}

test "empty string works" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("");
    const b = pool.intern("");
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(@as(usize, 0), a.len);
}

test "many strings work without issues" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const s = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        _ = pool.intern(s);
    }

    // Verify deduplication still works after many insertions
    i = 0;
    while (i < 100) : (i += 1) {
        const s = std.fmt.bufPrint(&buf, "string_{d}", .{i}) catch unreachable;
        const first = pool.intern(s);
        const second = pool.intern(s);
        try std.testing.expectEqual(first.ptr, second.ptr);
    }
}
