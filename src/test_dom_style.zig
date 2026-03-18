const std = @import("std");
const DomNode = @import("dom/node.zig").DomNode;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("css/cascade.zig");
const ComputedStyle = @import("style/computed.zig").ComputedStyle;

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
            std.debug.print("FAIL: no body\n", .{});
            return;
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
            std.debug.print("FAIL: no root\n", .{});
            return;
        };

        var result = try cascade_mod.cascade(root_node, allocator, null, 720, 720);
        defer result.deinit();

        std.debug.print("Resolved {d} element styles\n", .{result.styles.count()});

        // Check body style
        if (doc.body()) |body_node| {
            if (result.getStyle(body_node)) |body_style| {
                std.debug.print("body: color=0x{x:0>8} bg=0x{x:0>8}\n", .{
                    body_style.color,
                    body_style.background_color,
                });
            } else {
                std.debug.print("body: no style computed\n", .{});
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
                    std.debug.print("  <{s}>: no style\n", .{c.tagName() orelse "?"});
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
}
