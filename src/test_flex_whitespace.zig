const std = @import("std");
const Document = @import("dom/tree.zig").Document;
const cascade = @import("css/cascade.zig");
const tree = @import("layout/tree.zig");

fn checkItems(html: []const u8, css: []const u8, expected: []const ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var doc = try Document.parse(html);
    defer doc.deinit();
    var styles = try cascade.cascade(doc.root().?, allocator, css, 400, 400);
    defer styles.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body = try tree.buildBoxTree(doc.body().?, &styles, arena.allocator());
    const card = body.children.items[0];
    try std.testing.expectEqual(expected.len, card.children.items.len);
    for (card.children.items, expected) |item, text| {
        if (text) |wanted| {
            try std.testing.expectEqual(.anonymous_block, item.box_type);
            try std.testing.expectEqual(@as(usize, 1), item.children.items.len);
            try std.testing.expectEqualStrings(wanted, item.children.items[0].text.?);
        } else {
            try std.testing.expect(item.dom_node != null);
        }
    }
}

test "flex and grid skip whitespace-only DOM text items including preformatted whitespace" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "flex", "inline-flex", "grid", "inline-grid" }) |display| {
        for ([_][]const u8{ "normal", "pre", "pre-wrap" }) |white_space| {
            const css = try std.fmt.allocPrint(allocator, ".card {{ display: {s}; white-space: {s}; }}", .{ display, white_space });
            defer allocator.free(css);
            try checkItems("<!doctype html><body><div class=card>\n<span>a</span>\t\n\x0c<span>b</span>\r\n</div>", css, &.{ null, null });
        }
    }
}

test "flex and grid retain nonempty anonymous text and nonbreaking spaces" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "flex", "inline-flex", "grid", "inline-grid" }) |display| {
        const css = try std.fmt.allocPrint(allocator, ".card {{ display: {s}; }}", .{display});
        defer allocator.free(css);
        try checkItems("<!doctype html><body><div class=card>label<span>a</span>&nbsp;<span>b</span></div>", css, &.{ "label", null, "\xc2\xa0", null });
    }
}

test "ordinary block inline siblings retain their separating space" {
    const allocator = std.testing.allocator;
    var doc = try Document.parse("<!doctype html><body><div><span>a</span> <span>b</span></div>");
    defer doc.deinit();
    var styles = try cascade.cascade(doc.root().?, allocator, "", 400, 400);
    defer styles.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body = try tree.buildBoxTree(doc.body().?, &styles, arena.allocator());
    const items = body.children.items[0].children.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(.inline_text, items[1].box_type);
    try std.testing.expectEqualStrings(" ", items[1].text.?);
}
