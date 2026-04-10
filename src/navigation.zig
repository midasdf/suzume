const std = @import("std");

pub const History = struct {
    entries: std.ArrayList([]const u8),
    position: usize = 0,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .entries = std.ArrayList([]const u8).init(allocator) };
    }

    pub fn push(self: *History, url: []const u8) !void {
        // Truncate forward history
        while (self.entries.items.len > self.position + 1) {
            const old = self.entries.pop();
            self.entries.allocator.free(old);
        }
        try self.entries.append(try self.entries.allocator.dupe(u8, url));
        self.position = self.entries.items.len - 1;
    }

    pub fn back(self: *History) ?[]const u8 {
        if (self.position == 0) return null;
        self.position -= 1;
        return self.entries.items[self.position];
    }

    pub fn forward(self: *History) ?[]const u8 {
        if (self.position + 1 >= self.entries.items.len) return null;
        self.position += 1;
        return self.entries.items[self.position];
    }

    pub fn current(self: *const History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.position];
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.entries.allocator.free(entry);
        }
        self.entries.deinit();
    }
};
