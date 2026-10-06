//! Production layout geometry assertions; run by `suzume --test-dom`.
const std = @import("std");
const Box = @import("layout/box.zig").Box;
const block = @import("layout/block.zig");
const FontCache = @import("paint/painter.zig").FontCache;
const Display = @import("css/computed.zig").ComputedStyle.Display;

fn boxFor(display: Display) Box {
    return .{
        .style = .{ .display = display, .width = .{ .px = 100 }, .height = .{ .px = 20 } },
        .margin = .{ .left = 10 },
        .padding = .{ .left = 3 },
        .border = .{ .left = 2 },
    };
}

pub fn run(allocator: std.mem.Allocator) !void {
    // These fixtures contain no text and need no system font files.
    var fonts = FontCache.init(allocator, "");
    defer fonts.deinit();
    for ([_]Display{ .block, .flex, .grid, .table }) |display| {
        var box = boxFor(display);
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 15), box.content.x);
        try std.testing.expectEqual(@as(f32, 10), box.borderBox().x);
        try std.testing.expectEqual(@as(f32, 0), box.marginBox().x);

        // Re-layout at a narrower width must not reuse the previous auto
        // margins as fixed sizing constraints or add the offset twice.
        box.margin.left = 0;
        box.style.margin_left_auto = true;
        box.style.margin_right_auto = true;
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 102.5), box.content.x);
        block.layoutBlock(&box, 150, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 27.5), box.content.x);
        try std.testing.expectEqual(@as(f32, 100), box.content.width);
    }

    {
        var box = boxFor(.block);
        box.margin.left = -12;
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, -7), box.content.x);
    }
    {
        var box = boxFor(.block);
        box.style.width = .auto;
        box.style.margin_left = 10;
        box.style.margin_left_is_pct = true;
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 35), box.content.x);
        try std.testing.expectEqual(@as(f32, 265), box.content.width);
    }
    {
        var box = boxFor(.block);
        box.margin.right = 10;
        box.style.margin_left_auto = true;
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 190), box.content.x);
    }
    {
        var box = boxFor(.block);
        box.margin.left = 13;
        box.style.margin_right_auto = true;
        block.layoutBlock(&box, 300, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 18), box.content.x);
    }
    {
        var parent = Box{
            .style = .{ .width = .{ .px = 400 } },
            .margin = .{ .left = 8 },
            .padding = .{ .left = 4 },
            .border = .{ .left = 1 },
        };
        defer parent.children.deinit(allocator);
        var child = Box{
            .parent = &parent,
            .style = .{ .width = .{ .px = 200 } },
            .margin = .{ .left = 12 },
            .padding = .{ .left = 2 },
            .border = .{ .left = 1 },
        };
        defer child.children.deinit(allocator);
        var grandchild = Box{ .parent = &child, .margin = .{ .left = 3 } };
        try parent.children.append(allocator, &child);
        try child.children.append(allocator, &grandchild);
        block.layoutBlock(&parent, 600, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 13), parent.content.x);
        try std.testing.expectEqual(@as(f32, 28), child.content.x);
        try std.testing.expectEqual(@as(f32, 31), grandchild.content.x);
        try std.testing.expectEqual(parent.content.x, child.marginBox().x);
    }
    try textLineMetrics(allocator);
    try anonymousBoxStyles(allocator);
    try rootBoxModel(allocator, &fonts);
    std.debug.print("PASS: 18 production margin/layout regressions\n", .{});
}

fn textLineMetrics(allocator: std.mem.Allocator) !void {
    const Document = @import("dom/tree.zig").Document;
    const cascade = @import("css/cascade.zig");
    const tree = @import("layout/tree.zig");
    const font_resolver = @import("paint/font_resolver.zig");
    const path = font_resolver.resolve(allocator, "sans-serif") orelse return error.MissingTestFont;
    defer allocator.free(path);
    var fonts = FontCache.init(allocator, path);
    defer fonts.deinit();
    var doc = try Document.parse("<!doctype html><html><body><p>one</p><p>two</p></body></html>");
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    var styles = try cascade.cascade(root, allocator, "body { margin: 0; } p { font-size: 16px; line-height: 1.6; margin: 16px 0; }", 400, 400);
    defer styles.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const box = try tree.buildBoxTree(body, &styles, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), box.children.items.len);
    block.layoutBlock(box, 400, 0, &fonts);
    const first = box.children.items[0];
    const second = box.children.items[1];
    try std.testing.expectEqual(@as(f32, 16), first.margin.top);
    try std.testing.expectApproxEqAbs(@as(f32, 25.6), first.content.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 41.6), second.content.y - first.content.y, 0.001);
}

fn anonymousBoxStyles(allocator: std.mem.Allocator) !void {
    const Document = @import("dom/tree.zig").Document;
    const cascade = @import("css/cascade.zig");
    const tree = @import("layout/tree.zig");
    for ([_]Display{ .block, .flex, .grid }) |display| {
        var doc = try Document.parse("<!doctype html><html><body><div class='card'>text<p>paragraph</p></div></body></html>");
        defer doc.deinit();
        const root = doc.root() orelse return error.MissingRoot;
        const body = doc.body() orelse return error.MissingBody;
        const css = try std.fmt.allocPrint(allocator, ".card {{ display: {s}; border: 3px solid red; padding: 10px; position: relative; left: 10px; opacity: 0.5; font-size: 20px; color: #123456; }}", .{@tagName(display)});
        defer allocator.free(css);
        var styles = try cascade.cascade(root, allocator, css, 400, 400);
        defer styles.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const box = try tree.buildBoxTree(body, &styles, arena.allocator());
        const card = box.children.items[0];
        const anon = card.children.items[0];
        try std.testing.expectEqual(.anonymous_block, anon.box_type);
        try std.testing.expectEqual(@as(f32, 20), anon.style.font_size_px);
        try std.testing.expectEqual(@as(u32, 0xff123456), anon.style.color);
        try std.testing.expectEqual(@as(f32, 0), anon.style.border_top_width);
        try std.testing.expectEqual(@as(f32, 0), anon.style.padding_left);
        try std.testing.expectEqual(@as(f32, 1), anon.style.opacity);
        try std.testing.expectEqual(.static_, anon.style.position);
    }
}

fn rootBoxModel(allocator: std.mem.Allocator, fonts: *FontCache) !void {
    const Document = @import("dom/tree.zig").Document;
    const cascade = @import("css/cascade.zig");
    const tree = @import("layout/tree.zig");
    var doc = try Document.parse("<!doctype html><html><body></body></html>");
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    var styles = try cascade.cascade(root, allocator, "html { margin: 6px 0 0 5px; padding: 4px 0 0 3px; border-left: 2px solid red; border-top: 1px solid red; } body { margin: 0; }", 400, 400);
    defer styles.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const box = try tree.buildBoxTree(root, &styles, arena.allocator());
    block.layoutBlock(box, 400, 0, fonts);
    try std.testing.expectEqual(@as(f32, 10), box.content.x);
    try std.testing.expectEqual(@as(f32, 11), box.content.y);
    try std.testing.expectEqual(@as(f32, 0), box.marginBox().x);
    try std.testing.expectEqual(@as(f32, 0), box.marginBox().y);
}
