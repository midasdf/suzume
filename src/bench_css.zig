//! Fixed headless DOM/cascade workloads, not a browser startup/paint benchmark.
const std = @import("std");
const Document = @import("dom/tree.zig").Document;
const DomNode = @import("dom/node.zig").DomNode;
const cascade = @import("css/cascade.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    try workload(allocator, io, "siblings", 10000, 1);
    try workload(allocator, io, "rows", 1000, 3);
}

fn workload(allocator: std.mem.Allocator, io: std.Io, name: []const u8, count: usize, cells: usize) !void {
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator, "<!doctype html><html><body>");
    for (0..count) |_| {
        if (cells > 1) try html.appendSlice(allocator, "<div class='row'>");
        for (0..cells) |_| try html.appendSlice(allocator, "<span class='cell'>x</span>");
        if (cells > 1) try html.appendSlice(allocator, "</div>");
    }
    try html.appendSlice(allocator, "</body></html>");
    var doc = try Document.parse(html.items);
    defer doc.deinit();
    const root = doc.root() orelse return error.MissingRoot;
    const start = std.Io.Clock.awake.now(io);
    var result = try cascade.cascade(root, allocator, ".cell { color: #12ab34; padding: 2px; font-size: 16px; }", 1200, 800);
    defer result.deinit();
    const elapsed = start.untilNow(io, .awake).nanoseconds;
    const expected = 3 + count * (cells + @intFromBool(cells > 1));
    if (result.styles.count() != expected) return error.IncorrectStyleCount;
    var colored: usize = 0;
    var styles = result.styles.iterator();
    while (styles.next()) |entry| {
        const node = DomNode{ .lxb_node = @ptrFromInt(entry.key_ptr.*) };
        const class = node.getAttribute("class") orelse continue;
        if (std.mem.eql(u8, class, "cell")) {
            if (entry.value_ptr.color != 0xff12ab34) return error.IncorrectComputedColors;
            colored += 1;
        }
    }
    if (colored != count * cells) return error.IncorrectComputedColors;
    std.debug.print("{{\"case\":\"{s}\",\"optimize\":\"{s}\",\"elements\":{d},\"cascade_ns\":{d}}}\n", .{
        name, @tagName(@import("builtin").mode), result.styles.count(), elapsed,
    });
}
