const std = @import("std");
const DomNode = @import("dom/node.zig").DomNode;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("css/cascade.zig");
const ComputedStyle = @import("css/computed.zig").ComputedStyle;

const styled_html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<style>
    \\body { background-color: #1e1e2e; color: #cdd6f4; }
    \\h1 { color: #f38ba8; font-size: 24px; }
    \\p { color: #a6adc8; font-size: 16px; margin: 8px 0; }
    \\</style>
    \\</head>
    \\<body>
    \\  <h1>Hello</h1>
    \\  <p>World</p>
    \\</body>
    \\</html>
;

const simple_html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head><title>Test</title></head>
    \\<body>
    \\  <h1>Hello</h1>
    \\  <p>World</p>
    \\</body>
    \\</html>
;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Test 1: Simple DOM parsing
    std.debug.print("=== Test 1: DOM Parsing (simple.html) ===\n", .{});
    {
        var doc = try Document.parse(simple_html);
        defer doc.deinit();

        const body_node = doc.body() orelse {
            return error.MissingBody;
        };
        std.debug.print("body tag: {s}\n", .{body_node.tagName() orelse "?"});

        var child = body_node.firstElementChild();
        while (child) |c| {
            std.debug.print("  child: <{s}> text=\"{s}\"\n", .{
                c.tagName() orelse "?",
                c.textContent() orelse "(none)",
            });
            child = blk: {
                var sib = c.nextSibling();
                while (sib) |s| {
                    if (s.nodeType() == .element) break :blk s;
                    sib = s.nextSibling();
                }
                break :blk null;
            };
        }
        std.debug.print("PASS: DOM parsing works\n\n", .{});
    }

    // Test 2: Style cascade
    std.debug.print("=== Test 2: Style Cascade (styled.html) ===\n", .{});
    {
        var doc = try Document.parse(styled_html);
        defer doc.deinit();

        const root_node = doc.root() orelse {
            return error.MissingRoot;
        };

        var result = try cascade_mod.cascade(root_node, allocator, null, 720, 720);
        defer result.deinit();

        std.debug.print("Resolved {d} element styles\n", .{result.styles.count()});

        // Check body style
        if (doc.body()) |body_node| {
            if (result.getStyle(body_node)) |body_style| {
                try std.testing.expectEqual(@as(u32, 0xffcdd6f4), body_style.color);
                try std.testing.expectEqual(@as(u32, 0xff1e1e2e), body_style.background_color);
                std.debug.print("body: color=0x{x:0>8} bg=0x{x:0>8}\n", .{
                    body_style.color,
                    body_style.background_color,
                });
            } else {
                return error.MissingComputedStyle;
            }

            // Check h1 and p children
            var child = body_node.firstElementChild();
            while (child) |c| {
                if (result.getStyle(c)) |s| {
                    std.debug.print("  <{s}>: color=0x{x:0>8} font_size={d:.1}px display={s}\n", .{
                        c.tagName() orelse "?",
                        s.color,
                        s.font_size_px,
                        @tagName(s.display),
                    });
                } else {
                    return error.MissingComputedStyle;
                }
                child = blk: {
                    var sib = c.nextSibling();
                    while (sib) |s2| {
                        if (s2.nodeType() == .element) break :blk s2;
                        sib = s2.nextSibling();
                    }
                    break :blk null;
                };
            }
        }

        std.debug.print("PASS: Style cascade works\n", .{});
    }

    // Exercise the production parser, selector index and cascade together,
    // not just the isolated priority-key helper.
    try expectTargetColor(".a { color: red; &.active { color: blue; } }", 0xff0000ff);
    try expectTargetColor(".a { color: red; & { color: blue; } color: green; }", 0xff008000);
    try expectTargetColor("#target { color: red !important; } .a { color: blue !important; }", 0xffff0000);
    try expectTargetColor(".a, #other { &.active { color: blue; } } .a.active { color: red; }", 0xff0000ff);
    try expectTargetColor(".a { @media (min-width: 0px) { color: blue; } }", 0xff0000ff);
    try expectTargetColor("@media screen { .a { &.active { color: blue; } } }", 0xff0000ff);

    var large_css: std.ArrayList(u8) = .empty;
    defer large_css.deinit(allocator);
    for (0..300) |_| try large_css.appendSlice(allocator, ".a { color: red; }\n");
    try large_css.appendSlice(allocator, ".a { color: blue; }");
    try expectTargetColor(large_css.items, 0xff0000ff);
    try expectTargetLineHeight(".a { font-size: 16px; line-height: 1.6; }", .{ .number = 1.6 });
    try expectTargetLineHeight(".a { font-size: 16px; line-height: 150%; }", .{ .px = 24 });
    try expectTargetLineHeight(".a { line-height: 20px; }", .{ .px = 20 });
    try expectTargetLineHeight(".a { line-height: -2; }", .normal);
    const contexts = "<!doctype html><html><body><div class='left'><p data-theme='left'>one</p></div><div class='right'><p data-theme='right'>two</p></div></body></html>";
    try expectContextColors(contexts, ".left p { color: red; } .right p { color: blue; }", 0xffff0000, 0xff0000ff);
    try expectContextColors(contexts, "p[data-theme=left] { color: red; } p[data-theme=right] { color: blue; }", 0xffff0000, 0xff0000ff);
    try expectContextColors("<!doctype html><html><body><div><div class='scope'><p>one</p></div></div><div><div class='scope'><p>two</p></div></div></body></html>", ".scope { --fg: red; } p { color: var(--fg, blue); }", 0xffff0000, 0xffff0000);
    try expectInheritedFonts(contexts);
    try expectRetainedVariableScopes();
    std.debug.print("PASS: 16 production CSS cascade regressions\n", .{});
    try @import("test_block_layout.zig").run(allocator);
}

fn expectTargetColor(css: []const u8, expected: u32) !void {
    var doc = try Document.parse("<!doctype html><html><body><div id='target' class='a active'>target</div></body></html>");
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    const target = body.firstElementChild() orelse return error.MissingTarget;
    var result = try cascade_mod.cascade(root, std.heap.c_allocator, css, 720, 720);
    defer result.deinit();
    const style = result.getStyle(target) orelse return error.MissingComputedStyle;
    try std.testing.expectEqual(expected, style.color);
}

fn expectTargetLineHeight(css: []const u8, expected: ComputedStyle.LineHeight) !void {
    var doc = try Document.parse("<!doctype html><html><body><div class='a'>target</div></body></html>");
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    const target = body.firstElementChild() orelse return error.MissingTarget;
    var result = try cascade_mod.cascade(root, std.heap.c_allocator, css, 720, 720);
    defer result.deinit();
    const style = result.getStyle(target) orelse return error.MissingComputedStyle;
    try std.testing.expectEqual(expected, style.line_height);
}

fn firstParagraph(node: DomNode) ?DomNode {
    if (node.tagName()) |tag| if (std.mem.eql(u8, tag, "p")) return node;
    var child = node.firstChild();
    while (child) |current| : (child = current.nextSibling()) {
        if (firstParagraph(current)) |paragraph| return paragraph;
    }
    return null;
}

fn expectContextColors(html: []const u8, css: []const u8, left_color: u32, right_color: u32) !void {
    var doc = try Document.parse(html);
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    const left = body.firstElementChild() orelse return error.MissingTarget;
    const right = left.nextSibling() orelse return error.MissingTarget;
    var result = try cascade_mod.cascade(root, std.heap.c_allocator, css, 720, 720);
    defer result.deinit();
    const lp = firstParagraph(left) orelse return error.MissingTarget;
    const rp = firstParagraph(right) orelse return error.MissingTarget;
    const ls = result.getStyle(lp) orelse return error.MissingComputedStyle;
    const rs = result.getStyle(rp) orelse return error.MissingComputedStyle;
    try std.testing.expectEqual(left_color, ls.color);
    try std.testing.expectEqual(right_color, rs.color);
}

fn expectInheritedFonts(html: []const u8) !void {
    var doc = try Document.parse(html);
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    const left = body.firstElementChild() orelse return error.MissingTarget;
    const right = left.nextSibling() orelse return error.MissingTarget;
    var result = try cascade_mod.cascade(root, std.heap.c_allocator, ".left { font-family: monospace; } .right { font-family: serif; }", 720, 720);
    defer result.deinit();
    const lp = firstParagraph(left) orelse return error.MissingTarget;
    const rp = firstParagraph(right) orelse return error.MissingTarget;
    const ls = result.getStyle(lp) orelse return error.MissingComputedStyle;
    const rs = result.getStyle(rp) orelse return error.MissingComputedStyle;
    try std.testing.expectEqual(.monospace, ls.font_family);
    try std.testing.expectEqual(.serif, rs.font_family);
}

fn expectRetainedVariableScopes() !void {
    var doc = try Document.parse("<!doctype html><html><body><div class='scope'><span class='nested'>text</span></div></body></html>");
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const body = doc.body() orelse return error.MissingBody;
    const scope = body.firstElementChild() orelse return error.MissingTarget;
    const nested = scope.firstElementChild() orelse return error.MissingTarget;
    var result = try cascade_mod.cascade(root, std.heap.c_allocator, ".scope { --fg: red; } .nested { --bg: green; color: var(--fg); }", 720, 720);
    defer result.deinit();
    // Query retained maps after cascade returns, as computed-style APIs do.
    const scope_vars = result.getCustomProps(@intFromPtr(scope.lxb_node)) orelse return error.MissingVariableScope;
    const nested_vars = result.getCustomProps(@intFromPtr(nested.lxb_node)) orelse return error.MissingVariableScope;
    try std.testing.expect(nested_vars.parent == scope_vars);
    try std.testing.expectEqualStrings("red", nested_vars.get("--fg") orelse return error.MissingVariable);
    try std.testing.expectEqualStrings("green", nested_vars.get("--bg") orelse return error.MissingVariable);
    try std.testing.expect(nested_vars.get("--missing") == null);
    const root_vars = scope_vars.parent orelse return error.MissingVariableScope;
    try std.testing.expect(root_vars.parent == null);
}
