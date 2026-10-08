const std = @import("std");

/// Session navigation history. Owned by a single tab, including private tabs;
/// this is distinct from the persistent, profile-wide visited-page database.
pub const History = struct {
    entries: std.ArrayListUnmanaged([]u8) = .empty,
    position: usize = 0,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Prepare both allocations before discarding forward entries. `url` may
    /// alias an existing entry, and allocation failure must leave history intact.
    pub fn push(self: *History, allocator: std.mem.Allocator, url: []const u8) !void {
        const owned = try allocator.dupe(u8, url);
        errdefer allocator.free(owned);
        try self.entries.ensureUnusedCapacity(allocator, 1);
        const keep = if (self.entries.items.len == 0) 0 else self.position + 1;
        for (self.entries.items[keep..]) |entry| allocator.free(entry);
        self.entries.shrinkRetainingCapacity(keep);
        self.entries.appendAssumeCapacity(owned);
        self.position = self.entries.items.len - 1;
    }

    pub fn current(self: *const History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.position];
    }

    pub fn backTarget(self: *const History) ?[]const u8 {
        if (self.position == 0) return null;
        return self.entries.items[self.position - 1];
    }

    pub fn forwardTarget(self: *const History) ?[]const u8 {
        if (self.position + 1 >= self.entries.items.len) return null;
        return self.entries.items[self.position + 1];
    }
};
