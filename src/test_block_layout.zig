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
    try verticalMargins(allocator, &fonts);
    try preformattedRelayout(allocator);
    try blockAlignmentAndHeight(allocator, &fonts);
    try wordWrapping(allocator);
    std.debug.print("PASS: 35 production margin/layout regressions\n", .{});
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

fn verticalMargins(allocator: std.mem.Allocator, fonts: *FontCache) !void {
    const cases = [_]struct { bottom: f32, top: f32, gap: f32 }{
        .{ .bottom = 30, .top = 20, .gap = 30 },
        .{ .bottom = -10, .top = -20, .gap = -20 },
        .{ .bottom = 30, .top = -10, .gap = 20 },
    };
    for (cases) |case| {
        var parent = Box{};
        defer parent.children.deinit(allocator);
        var first = Box{ .parent = &parent, .style = .{ .height = .{ .px = 20 }, .margin_bottom = case.bottom } };
        var second = Box{ .parent = &parent, .style = .{ .display = .flex, .height = .{ .px = 20 }, .margin_top = case.top }, .margin = .{ .top = case.top } };
        try parent.children.append(allocator, &first);
        try parent.children.append(allocator, &second);
        block.layoutBlock(&parent, 400, 0, fonts);
        try std.testing.expectEqual(case.gap, second.content.y - first.content.y - first.content.height);
    }
    for ([_]f32{ 24, -4 }) |leaf_margin| {
        var root = Box{};
        defer root.children.deinit(allocator);
        var middle = Box{ .parent = &root, .style = .{ .margin_top = 8 }, .margin = .{ .top = 8 } };
        defer middle.children.deinit(allocator);
        var leaf = Box{ .parent = &middle, .style = .{ .height = .{ .px = 20 }, .margin_top = leaf_margin }, .margin = .{ .top = leaf_margin } };
        try root.children.append(allocator, &middle);
        try middle.children.append(allocator, &leaf);
        const expected: f32 = if (leaf_margin > 0) 24 else 4;
        for (0..10) |_| {
            block.layoutBlock(&root, 400, 0, fonts);
            try std.testing.expectEqual(expected, middle.content.y);
            try std.testing.expectEqual(expected, leaf.content.y);
        }
        // A later style change must not retain the previously collapsed value.
        leaf.style.margin_top = 0;
        block.layoutBlock(&root, 400, 0, fonts);
        try std.testing.expectEqual(@as(f32, 8), middle.content.y);
    }
}

fn blockAlignmentAndHeight(allocator: std.mem.Allocator, fonts: *FontCache) !void {
    for ([_]@import("css/computed.zig").ComputedStyle.TextAlign{ .center, .right }) |text_align| {
        var root = Box{ .style = .{ .text_align = text_align } };
        defer root.children.deinit(allocator);
        var child = Box{ .parent = &root, .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 20 } } };
        try root.children.append(allocator, &child);
        block.layoutBlock(&root, 400, 0, fonts);
        try std.testing.expectEqual(@as(f32, 0), child.content.x);
    }
    var root = Box{};
    defer root.children.deinit(allocator);
    var fixed = Box{ .parent = &root, .style = .{ .height = .{ .px = 100 } } };
    defer fixed.children.deinit(allocator);
    var inside = Box{ .parent = &fixed, .style = .{ .height = .{ .px = 20 }, .margin_bottom = 30 } };
    var after = Box{ .parent = &root, .style = .{ .height = .{ .px = 20 } } };
    try root.children.append(allocator, &fixed);
    try root.children.append(allocator, &after);
    try fixed.children.append(allocator, &inside);
    block.layoutBlock(&root, 400, 0, fonts);
    try std.testing.expectEqual(@as(f32, 100), after.content.y);
    try std.testing.expectEqual(@as(f32, 0), fixed.margin.bottom);
}

fn wordWrapping(allocator: std.mem.Allocator) !void {
    const resolver = @import("paint/font_resolver.zig");
    const path = resolver.resolve(allocator, "sans-serif") orelse return error.MissingTestFont;
    defer allocator.free(path);
    var fonts = FontCache.init(allocator, path);
    defer fonts.deinit();
    const Style = @import("css/computed.zig").ComputedStyle;
    const cases = [_]struct { word: Style.WordBreak, overflow: Style.OverflowWrap, wrap: bool }{
        .{ .word = .normal, .overflow = .normal, .wrap = false },
        .{ .word = .keep_all, .overflow = .normal, .wrap = false },
        .{ .word = .normal, .overflow = .break_word, .wrap = true },
        .{ .word = .normal, .overflow = .anywhere, .wrap = true },
        .{ .word = .break_all, .overflow = .normal, .wrap = true },
    };
    for (cases) |case| {
        var root = Box{};
        defer root.children.deinit(allocator);
        var child = Box{ .parent = &root, .box_type = .inline_text, .text = "Supercalifragilisticexpialidocious", .style = .{
            .font_size_px = 16,
            .line_height = .{ .px = 20 },
            .word_break = case.word,
            .overflow_wrap = case.overflow,
        } };
        defer child.lines.deinit(allocator);
        try root.children.append(allocator, &child);
        block.layoutBlock(&root, 60, 0, &fonts);
        try std.testing.expectEqual(case.wrap, child.lines.items.len > 1);
        if (!case.wrap) try std.testing.expectEqualStrings(child.text.?, child.lines.items[0].text);
        if (case.wrap) for (child.lines.items) |line| try std.testing.expect(line.width <= 60);
    }
    for ([_]Style.OverflowWrap{ .normal, .anywhere }) |overflow| {
        var parent = Box{};
        defer parent.children.deinit(allocator);
        var prefix = Box{ .parent = &parent, .box_type = .inline_text, .text = "prefix", .style = .{ .font_size_px = 16, .line_height = .{ .px = 20 } } };
        defer prefix.lines.deinit(allocator);
        var word = Box{ .parent = &parent, .box_type = .inline_text, .text = "example", .style = .{ .font_size_px = 16, .line_height = .{ .px = 20 }, .overflow_wrap = overflow } };
        defer word.lines.deinit(allocator);
        try parent.children.append(allocator, &prefix);
        try parent.children.append(allocator, &word);
        const renderer = fonts.getRendererForFamily(16, .sans_serif) orelse return error.MissingTestFont;
        const line_width: f32 = @floatFromInt(@max(renderer.measure("prefix").width, renderer.measure("example").width) + 2);
        block.layoutBlock(&parent, line_width, 0, &fonts);
        try std.testing.expectEqual(@as(usize, 1), word.lines.items.len);
        try std.testing.expectEqualStrings("example", word.lines.items[0].text);
        try std.testing.expectEqual(@as(f32, 0), word.lines.items[0].x);
        try std.testing.expectEqual(@as(f32, 20), word.lines.items[0].y);
        try std.testing.expectEqual(@as(f32, 40), parent.content.height);
    }
    var root = Box{};
    defer root.children.deinit(allocator);
    var child = Box{ .parent = &root, .box_type = .inline_text, .text = "a 日本語日本語", .style = .{ .font_size_px = 16 } };
    defer child.lines.deinit(allocator);
    try root.children.append(allocator, &child);
    const renderer = fonts.getRendererForFamily(16, .sans_serif) orelse return error.MissingTestFont;
    const width: f32 = @floatFromInt(renderer.measure("a 日本語").width);
    block.layoutBlock(&root, width + 1, 0, &fonts);
    try std.testing.expect(child.lines.items.len > 1);
    // A later CJK boundary wins over an earlier Latin space.
    try std.testing.expectEqualStrings("a 日本語", child.lines.items[0].text);
}

fn preformattedRelayout(allocator: std.mem.Allocator) !void {
    const resolver = @import("paint/font_resolver.zig");
    const path = resolver.resolve(allocator, "sans-serif") orelse return error.MissingTestFont;
    defer allocator.free(path);
    var fonts = FontCache.init(allocator, path);
    defer fonts.deinit();
    var root = Box{};
    defer root.children.deinit(allocator);
    var child = Box{ .parent = &root, .box_type = .inline_text, .text = "one\ntwo", .style = .{
        .font_size_px = 16,
        .line_height = .{ .px = 20 },
        .white_space = .pre,
    } };
    defer child.lines.deinit(allocator);
    try root.children.append(allocator, &child);
    block.layoutBlock(&root, 400, 0, &fonts);
    try std.testing.expectEqual(@as(f32, 40), root.content.height);
    try std.testing.expectEqual(@as(usize, 2), child.lines.items.len);
    const storage = child.lines.items.ptr;
    for (0..100) |_| {
        block.layoutBlock(&root, 200, 0, &fonts);
        try std.testing.expectEqual(@as(f32, 40), root.content.height);
        try std.testing.expect(child.lines.items.ptr == storage);
        try std.testing.expectEqualStrings("two", child.lines.items[1].text);
    }
}
