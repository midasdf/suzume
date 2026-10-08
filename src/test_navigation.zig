const std = @import("std");
const History = @import("navigation.zig").History;
const TabManager = @import("ui/tabs.zig").TabManager;
const a = std.testing.allocator;

test "empty history and navigation boundaries" {
    var h: History = .{};
    defer h.deinit(a);
    try std.testing.expect(h.current() == null);
    try std.testing.expect(h.backTarget() == null);
    try std.testing.expect(h.forwardTarget() == null);
    try h.push(a, "first");
    try std.testing.expect(h.backTarget() == null);
    try std.testing.expect(h.forwardTarget() == null);
    try h.push(a, "second");
    try std.testing.expectEqualStrings("first", h.backTarget().?);
    // Inspecting a target (including a failed load) must not advance history.
    try std.testing.expectEqual(@as(usize, 1), h.position);
    h.position -= 1;
    try std.testing.expectEqualStrings("second", h.forwardTarget().?);
    try h.push(a, "third");
    try std.testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try std.testing.expectEqualStrings("third", h.current().?);
    try std.testing.expect(h.forwardTarget() == null);
}

test "navigation can alias discarded forward entry" {
    var h: History = .{};
    defer h.deinit(a);
    try h.push(a, "first");
    try h.push(a, "second");
    h.position = 0;
    try h.push(a, h.forwardTarget().?);
    try std.testing.expectEqualStrings("second", h.current().?);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var h: History = .{};
    defer h.deinit(allocator);
    try h.push(allocator, "first");
    try h.push(allocator, "second");
    h.position = 0;
    h.push(allocator, "replacement") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), h.position);
        try std.testing.expectEqual(@as(usize, 2), h.entries.items.len);
        try std.testing.expectEqualStrings("first", h.current().?);
        try std.testing.expectEqualStrings("second", h.forwardTarget().?);
        return err;
    };
}

test "allocation failure preserves forward history without leaking" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}

test "restoring session replaces startup history" {
    var tabs = TabManager.init(a, 3);
    defer tabs.deinit();
    _ = tabs.newTab("suzume://home");
    var page_count: usize = 1;
    const Noop = struct {
        fn run() void {}
    };
    @import("core/session.zig").restoreSession(a, "[{\"url\":\"https://example.test/restored\",\"title\":\"Restored\"}]", &tabs, &page_count, &Noop.run);
    try std.testing.expectEqualStrings("https://example.test/restored", tabs.getActiveTab().?.history.current().?);
    try std.testing.expect(tabs.getActiveTab().?.history.backTarget() == null);
}

test "tabs own isolated histories including private tabs and survive closing" {
    var tabs = TabManager.init(a, 3);
    defer tabs.deinit();
    _ = tabs.newTab("A1");
    try tabs.getActiveTab().?.history.push(a, "A2");
    _ = tabs.newTab("B1");
    try tabs.getActiveTab().?.history.push(a, "B2");
    try std.testing.expectEqualStrings("B1", tabs.getActiveTab().?.history.backTarget().?);
    try std.testing.expect(tabs.switchTo(0));
    try std.testing.expectEqualStrings("A1", tabs.getActiveTab().?.history.backTarget().?);
    tabs.getActiveTab().?.history.position = 0;
    _ = tabs.newPrivateTab("P1");
    try tabs.getActiveTab().?.history.push(a, "P2");
    try std.testing.expectEqualStrings("P1", tabs.getActiveTab().?.history.backTarget().?);
    tabs.closeTab(1);
    try std.testing.expectEqualStrings("P2", tabs.getActiveTab().?.history.current().?);
    try std.testing.expect(tabs.switchTo(0));
    try std.testing.expectEqualStrings("A1", tabs.getActiveTab().?.history.current().?);
    try std.testing.expectEqualStrings("A2", tabs.getActiveTab().?.history.forwardTarget().?);
}
