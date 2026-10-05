const std = @import("std");
const priority = @import("css").priority;
const key = priority.key;
const unlayered = 0xFFFF;

test "later rules win beyond 255 without source-order truncation" {
    const orders = [_]u32{ 0, 254, 255, 256, 1024, 65535, std.math.maxInt(u32) };
    for (orders[0 .. orders.len - 1], orders[1..]) |earlier, later| {
        try std.testing.expect(key(false, .author, unlayered, 10, earlier) < key(false, .author, unlayered, 10, later));
        try std.testing.expect(key(true, .author, unlayered, 10, earlier) < key(true, .author, unlayered, 10, later));
    }
}

test "important declarations still prefer higher specificity" {
    try std.testing.expect(key(true, .author, unlayered, 1, 1000) < key(true, .author, unlayered, 1 << 20, 0));
}

test "important layers reverse order but not specificity" {
    try std.testing.expect(key(false, .author, 0, 100, 100) < key(false, .author, 1, 1, 0));
    try std.testing.expect(key(true, .author, 0, 1, 0) > key(true, .author, 1, 100, 100));
    try std.testing.expect(key(false, .author, 1, 100, 100) < key(false, .author, unlayered, 1, 0));
    try std.testing.expect(key(true, .author, 1, 1, 0) > key(true, .author, unlayered, 100, 100));
}

test "important wins regardless of normal specificity and source order" {
    try std.testing.expect(key(true, .author, unlayered, 0, 0) > key(false, .inline_, unlayered, std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "UA important overrides author and inline important" {
    try std.testing.expect(key(true, .ua, unlayered, 0, 0) > key(true, .inline_, 0, std.math.maxInt(u32), std.math.maxInt(u32)));
    try std.testing.expect(key(true, .ua, unlayered, 0, 0) > key(true, .author, 0, std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "normal origin order and inline author priority are preserved" {
    try std.testing.expect(key(false, .ua, unlayered, std.math.maxInt(u32), std.math.maxInt(u32)) < key(false, .author, 0, 0, 0));
    try std.testing.expect(key(false, .author, unlayered, std.math.maxInt(u32), std.math.maxInt(u32)) < key(false, .inline_, unlayered, 0, 0));
    try std.testing.expect(key(true, .author, 0, std.math.maxInt(u32), std.math.maxInt(u32)) < key(true, .inline_, unlayered, 0, 0));
}
