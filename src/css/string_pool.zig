const std = @import("std");

pub const StringPool = struct {
    strings: std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{ .strings = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn intern(self: *StringPool, str: []const u8) []const u8 {
        if (self.strings.getKey(str)) |existing| return existing;
        const owned = self.allocator.dupe(u8, str) catch return str;
        self.strings.put(self.allocator, owned, {}) catch return str;
        return owned;
    }
};
