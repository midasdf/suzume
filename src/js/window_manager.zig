const std = @import("std");

pub const WindowEntry = struct {
    handle: []const u8,
    tab_index: usize,
    opener_handle: ?[]const u8 = null,
    name: []const u8 = "",
    closed: bool = false,
};

pub const WindowManager = struct {
    windows: std.ArrayListUnmanaged(WindowEntry) = .empty,
    next_id: u32 = 0,
    active_index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WindowManager {
        return .{ .allocator = allocator };
    }

    /// Create the initial window (window-0) for a new session.
    pub fn createInitialWindow(self: *WindowManager) ![]const u8 {
        const handle = try self.makeHandle();
        try self.windows.append(self.allocator, .{
            .handle = handle,
            .tab_index = 0,
        });
        return handle;
    }

    /// Create a new window. Returns the new handle.
    pub fn createWindow(self: *WindowManager, opener_handle: ?[]const u8, name: []const u8, tab_index: usize) ![]const u8 {
        const handle = try self.makeHandle();
        try self.windows.append(self.allocator, .{
            .handle = handle,
            .tab_index = tab_index,
            .opener_handle = opener_handle,
            .name = name,
        });
        return handle;
    }

    /// Find window by handle.
    pub fn findByHandle(self: *const WindowManager, handle: []const u8) ?*WindowEntry {
        for (self.windows.items) |*w| {
            if (!w.closed and std.mem.eql(u8, w.handle, handle)) return w;
        }
        return null;
    }

    /// Find window by name.
    pub fn findByName(self: *const WindowManager, name: []const u8) ?*WindowEntry {
        if (name.len == 0) return null;
        for (self.windows.items) |*w| {
            if (!w.closed and std.mem.eql(u8, w.name, name)) return w;
        }
        return null;
    }

    /// Get the active window's handle.
    pub fn getActiveHandle(self: *const WindowManager) ?[]const u8 {
        if (self.active_index < self.windows.items.len) {
            return self.windows.items[self.active_index].handle;
        }
        return null;
    }

    /// Get the active window's tab index.
    pub fn getActiveTabIndex(self: *const WindowManager) usize {
        if (self.active_index < self.windows.items.len) {
            return self.windows.items[self.active_index].tab_index;
        }
        return 0;
    }

    /// Switch to window by handle. Returns true if successful.
    pub fn switchTo(self: *WindowManager, handle: []const u8) bool {
        for (self.windows.items, 0..) |w, i| {
            if (!w.closed and std.mem.eql(u8, w.handle, handle)) {
                self.active_index = i;
                return true;
            }
        }
        return false;
    }

    /// Close a window by handle.
    pub fn closeWindow(self: *WindowManager, handle: []const u8) void {
        for (self.windows.items) |*w| {
            if (std.mem.eql(u8, w.handle, handle)) {
                w.closed = true;
                break;
            }
        }
    }

    /// Get all live window handles.
    pub fn getHandles(self: *const WindowManager, buf: *[16][]const u8) usize {
        var count: usize = 0;
        for (self.windows.items) |w| {
            if (!w.closed and count < 16) {
                buf[count] = w.handle;
                count += 1;
            }
        }
        return count;
    }

    /// Number of live (non-closed) windows.
    pub fn liveCount(self: *const WindowManager) usize {
        var count: usize = 0;
        for (self.windows.items) |w| {
            if (!w.closed) count += 1;
        }
        return count;
    }

    fn makeHandle(self: *WindowManager) ![]const u8 {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "window-{d}", .{self.next_id}) catch return error.OutOfMemory;
        self.next_id += 1;
        return self.allocator.dupe(u8, s) catch return error.OutOfMemory;
    }
};
