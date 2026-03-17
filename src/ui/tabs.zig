const std = @import("std");

/// A single browser tab.
pub const Tab = struct {
    url: []u8, // owned
    title: []u8, // owned
    scroll_y: f32,
    scroll_x: f32 = 0,
    active: bool, // has live DOM/layout/JS
    is_private: bool = false, // private browsing mode — no history, no session save

    /// Timestamp of last activation (for LRU eviction). Monotonic counter.
    last_used: u64,
};

/// Manages multiple browser tabs with LRU eviction of page state.
pub const TabManager = struct {
    tabs: std.ArrayListUnmanaged(Tab),
    active_index: usize,
    max_active: u32,
    allocator: std.mem.Allocator,
    counter: u64, // monotonic counter for LRU

    pub fn init(allocator: std.mem.Allocator, max_active: u32) TabManager {
        return .{
            .tabs = .empty,
            .active_index = 0,
            .max_active = if (max_active > 0) max_active else 3,
            .allocator = allocator,
            .counter = 0,
        };
    }

    pub fn deinit(self: *TabManager) void {
        for (self.tabs.items) |*tab| {
            self.allocator.free(tab.url);
            self.allocator.free(tab.title);
        }
        self.tabs.deinit(self.allocator);
    }

    /// Create a new tab with the given URL. Returns the index of the new tab.
    pub fn newTab(self: *TabManager, url: []const u8) usize {
        const owned_url = self.allocator.dupe(u8, url) catch return self.active_index;
        const owned_title = self.allocator.dupe(u8, "New Tab") catch {
            self.allocator.free(owned_url);
            return self.active_index;
        };

        self.counter += 1;
        const tab = Tab{
            .url = owned_url,
            .title = owned_title,
            .scroll_y = 0,
            .active = true,
            .last_used = self.counter,
        };

        self.tabs.append(self.allocator, tab) catch {
            self.allocator.free(owned_url);
            self.allocator.free(owned_title);
            return self.active_index;
        };

        const new_index = self.tabs.items.len - 1;
        // Mark old active tab as no longer active for display purposes
        if (self.tabs.items.len > 1) {
            self.tabs.items[self.active_index].active = false;
        }
        self.active_index = new_index;
        self.tabs.items[new_index].active = true;

        return new_index;
    }

    /// Create a new private tab with the given URL. Returns the index of the new tab.
    pub fn newPrivateTab(self: *TabManager, url: []const u8) usize {
        const owned_url = self.allocator.dupe(u8, url) catch return self.active_index;
        const owned_title = self.allocator.dupe(u8, "[Private] New Tab") catch {
            self.allocator.free(owned_url);
            return self.active_index;
        };

        self.counter += 1;
        const tab = Tab{
            .url = owned_url,
            .title = owned_title,
            .scroll_y = 0,
            .active = true,
            .is_private = true,
            .last_used = self.counter,
        };

        self.tabs.append(self.allocator, tab) catch {
            self.allocator.free(owned_url);
            self.allocator.free(owned_title);
            return self.active_index;
        };

        const new_index = self.tabs.items.len - 1;
        if (self.tabs.items.len > 1) {
            self.tabs.items[self.active_index].active = false;
        }
        self.active_index = new_index;
        self.tabs.items[new_index].active = true;

        return new_index;
    }

    /// Close a tab by index.
    pub fn closeTab(self: *TabManager, index: usize) void {
        if (index >= self.tabs.items.len) return;
        if (self.tabs.items.len <= 1) return; // Don't close last tab (caller handles quit)

        const tab = self.tabs.items[index];
        self.allocator.free(tab.url);
        self.allocator.free(tab.title);
        _ = self.tabs.orderedRemove(index);

        // Adjust active index
        if (self.active_index >= self.tabs.items.len) {
            self.active_index = self.tabs.items.len - 1;
        } else if (self.active_index > index) {
            self.active_index -= 1;
        }

        // Mark the new active tab
        for (self.tabs.items, 0..) |*t, i| {
            t.active = (i == self.active_index);
        }
    }

    /// Switch to the tab at the given index. Returns whether the tab changed.
    pub fn switchTo(self: *TabManager, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        if (index == self.active_index) return false;

        // Deactivate old
        self.tabs.items[self.active_index].active = false;

        // Activate new
        self.active_index = index;
        self.counter += 1;
        self.tabs.items[index].active = true;
        self.tabs.items[index].last_used = self.counter;

        return true;
    }

    /// Get the active tab. Returns null if no tabs exist.
    pub fn getActiveTab(self: *TabManager) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_index];
    }

    /// Return the index of the least recently used inactive tab, or null if none.
    pub fn findLruInactive(self: *TabManager) ?usize {
        var lru_index: ?usize = null;
        var lru_time: u64 = std.math.maxInt(u64);

        for (self.tabs.items, 0..) |tab, i| {
            if (i == self.active_index) continue;
            if (tab.last_used < lru_time) {
                lru_time = tab.last_used;
                lru_index = i;
            }
        }

        return lru_index;
    }

    /// Count of all tabs (all loaded tabs consume memory).
    pub fn activeCount(self: *TabManager) u32 {
        return @intCast(self.tabs.items.len);
    }

    /// Update the URL of the active tab.
    pub fn updateActiveUrl(self: *TabManager, url: []const u8) void {
        if (self.tabs.items.len == 0) return;
        var tab = &self.tabs.items[self.active_index];

        const new_url = self.allocator.dupe(u8, url) catch self.allocator.dupe(u8, "") catch return;
        self.allocator.free(tab.url);
        tab.url = new_url;
    }

    pub fn updateActiveTitle(self: *TabManager, title: []const u8) void {
        if (self.tabs.items.len == 0) return;
        var tab = &self.tabs.items[self.active_index];

        const new_title = self.allocator.dupe(u8, title) catch self.allocator.dupe(u8, "") catch return;
        self.allocator.free(tab.title);
        tab.title = new_title;
    }

    /// Save the current scroll position to the active tab.
    pub fn saveScrollPosition(self: *TabManager, scroll_y: f32, scroll_x: f32) void {
        if (self.tabs.items.len == 0) return;
        self.tabs.items[self.active_index].scroll_y = scroll_y;
        self.tabs.items[self.active_index].scroll_x = scroll_x;
    }

    /// Get tab count.
    pub fn tabCount(self: *const TabManager) usize {
        return self.tabs.items.len;
    }

    /// Switch to next tab (wrapping).
    pub fn nextTab(self: *TabManager) bool {
        if (self.tabs.items.len <= 1) return false;
        const next = (self.active_index + 1) % self.tabs.items.len;
        return self.switchTo(next);
    }

    /// Switch to previous tab (wrapping).
    pub fn prevTab(self: *TabManager) bool {
        if (self.tabs.items.len <= 1) return false;
        const prev = if (self.active_index == 0) self.tabs.items.len - 1 else self.active_index - 1;
        return self.switchTo(prev);
    }
};
