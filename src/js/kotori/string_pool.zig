const std = @import("std");

pub const StringId = u32;
pub const EMPTY_STRING_ID: StringId = 0;

pub const StringPool = struct {
    strings: std.StringArrayHashMapUnmanaged(StringId),
    allocator: std.mem.Allocator,
    next_id: StringId,

    pub fn init(allocator: std.mem.Allocator) StringPool {
        var pool: StringPool = .{
            .strings = .{},
            .allocator = allocator,
            .next_id = 0,
        };
        // EMPTY_STRING_ID invariant: "" must be StringId 0
        const id = pool.intern("") catch unreachable;
        std.debug.assert(id == EMPTY_STRING_ID);
        return pool;
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit(self.allocator);
    }

    /// Intern a string and return its stable StringId.
    pub fn intern(self: *StringPool, str: []const u8) !StringId {
        const result = try self.strings.getOrPut(self.allocator, str);
        if (result.found_existing) return result.value_ptr.*;
        const owned = try self.allocator.dupe(u8, str);
        result.key_ptr.* = owned;
        result.value_ptr.* = self.next_id;
        self.next_id += 1;
        return result.value_ptr.*;
    }

    /// Return the string for a given id, or null if not found.
    pub fn get(self: *const StringPool, id: StringId) ?[]const u8 {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == id) return entry.key_ptr.*;
        }
        return null;
    }
};
