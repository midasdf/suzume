//! Layout diagnostic dumper.
//!
//! Rendering bugs on real sites (misplaced logos, zero-height containers,
//! content pushed below the fold) are hard to debug from a PNG alone. This
//! module walks the box tree produced by the layout engine and prints a
//! DOM-shaped outline with each box's geometry and the CSS properties most
//! often responsible for a broken layout.
//!
//! Enabled with `--dump-layout <path>` (or `--dump-layout=-` for stdout);
//! `--dump-layout-verbose <path>` adds CSS detail on every box. The dump runs
//! inside the screenshot path, so it reflects exactly the box tree that would
//! be painted — including post-JS DOM mutations.
//!
//! Output format (one line per box):
//!
//!   <indent>tag#id.class [box_type/display] mb=(x,y wxh) c=(x,y wxh) <style> txt=".."
//!
//! It is intentionally line-oriented so it can be grepped and diffed between
//! runs and between revisions.

const std = @import("std");
const env = @import("../env.zig");
const Box = @import("../layout/box.zig").Box;
const Rect = @import("../layout/box.zig").Rect;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
const DomNode = @import("../dom/node.zig").DomNode;
const lxb = @import("../bindings/lexbor.zig").c;

pub const Options = struct {
    /// Maximum number of boxes to print; guards against pathological pages.
    max_lines: usize = 40000,
    /// Print CSS details for every box. When false, only boxes that look
    /// suspicious (zero size, non-finite, off-canvas) get detail.
    verbose: bool = false,
};

/// Accumulates dump text and writes it out in one go.
pub const Dumper = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    opts: Options,
    lines: usize = 0,
    truncated: bool = false,

    // Running statistics to help spot page-wide problems.
    max_bottom: f32 = 0,
    max_right: f32 = 0,
    box_count: usize = 0,
    zero_size_boxes: usize = 0,
    no_line_text: usize = 0,

    pub fn init(allocator: std.mem.Allocator, opts: Options) Dumper {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn deinit(self: *Dumper) void {
        self.out.deinit(self.allocator);
    }

    pub fn text(self: *const Dumper) []const u8 {
        return self.out.items;
    }

    /// Walk `root` and append a line per box, then a summary line.
    pub fn dump(self: *Dumper, root: *const Box) void {
        self.walk(root, 0);
        var tail: [256]u8 = undefined;
        const tail_str = std.fmt.bufPrint(&tail, "# summary: boxes={d} max_bottom={d:.1} max_right={d:.1} zero_size={d} no_line_text={d} truncated={}\n", .{
            self.box_count, self.max_bottom, self.max_right, self.zero_size_boxes, self.no_line_text, self.truncated,
        }) catch "# summary: <overflow>\n";
        self.out.appendSlice(self.allocator, tail_str) catch {};
    }

    fn walk(self: *Dumper, box: *const Box, depth: usize) void {
        if (self.lines >= self.opts.max_lines) {
            self.truncated = true;
            return;
        }
        const mbox = box.marginBox();
        const bottom = mbox.y + mbox.height;
        const right = mbox.x + mbox.width;
        if (std.math.isFinite(bottom)) self.max_bottom = @max(self.max_bottom, bottom);
        if (std.math.isFinite(right)) self.max_right = @max(self.max_right, right);
        self.box_count += 1;

        if (box.box_type == .inline_text) {
            self.dumpInlineText(box, depth);
            return;
        }

        if (mbox.width <= 0.01 or mbox.height <= 0.01) self.zero_size_boxes += 1;

        self.appendLine(box, depth, mbox);
        for (box.children.items) |child| self.walk(child, depth + 1);
    }

    fn dumpInlineText(self: *Dumper, box: *const Box, depth: usize) void {
        if (box.lines.items.len == 0) {
            self.no_line_text += 1;
            if (self.lines >= self.opts.max_lines) return;
            self.fmtLine("{s}[inline_text] NO-LINES ws={s} txt=\"{s}\"\n", .{
                indentFor(depth),
                @tagName(box.style.white_space),
                truncate(box.text orelse "", 60),
            });
            self.lines += 1;
            return;
        }
        for (box.lines.items) |line| {
            if (self.lines >= self.opts.max_lines) {
                self.truncated = true;
                return;
            }
            const bottom = line.y + line.height;
            if (std.math.isFinite(bottom)) self.max_bottom = @max(self.max_bottom, bottom);
            self.fmtLine("{s}[text] x={d:.1} y={d:.1} w={d:.1} h={d:.1} ellipsis={} align={s} txt=\"{s}\"\n", .{
                indentFor(depth),
                line.x,
                line.y,
                line.width,
                line.height,
                line.ellipsis,
                @tagName(box.style.text_align),
                truncate(line.text, 70),
            });
            self.lines += 1;
        }
    }

    fn appendLine(self: *Dumper, box: *const Box, depth: usize, mbox: Rect) void {
        var tag_buf: [200]u8 = undefined;
        const desc = describeDom(box.dom_node, &tag_buf);
        const c = box.content;

        var display_buf: [48]u8 = undefined;
        const display_suffix = if (box.box_type == .block and box.style.display != .block)
            std.fmt.bufPrint(&display_buf, "/{s}", .{@tagName(box.style.display)}) catch ""
        else
            "";

        var detail_buf: [512]u8 = undefined;
        const detail_str = if (self.opts.verbose or isSuspicious(box, mbox))
            formatStyleDetail(box.style, &detail_buf)
        else
            "";

        var text_buf: [80]u8 = undefined;
        const text_str = if (box.text) |t| blk: {
            const cut = truncate(t, 60);
            break :blk std.fmt.bufPrint(&text_buf, " txt=\"{s}\"", .{cut}) catch "";
        } else "";

        var marker_buf: [32]u8 = undefined;
        const marker_str = std.fmt.bufPrint(&marker_buf, "{s}{s}", .{
            if (box.is_hr) " hr" else "",
            if (box.list_index > 0) " li" else "",
        }) catch "";

        self.fmtLine("{s}{s} [{s}{s}] mb=({d:.0},{d:.0} {d:.0}x{d:.0}) c=({d:.0},{d:.0} {d:.0}x{d:.0}){s}{s}{s}\n", .{
            indentFor(depth),
            desc,
            @tagName(box.box_type),
            display_suffix,
            mbox.x,
            mbox.y,
            mbox.width,
            mbox.height,
            c.x,
            c.y,
            c.width,
            c.height,
            detail_str,
            text_str,
            marker_str,
        });
        self.lines += 1;
    }

    /// Append a formatted line. Lines longer than the scratch buffer are
    /// truncated (dump output is diagnostic text, never a correctness input).
    fn fmtLine(self: *Dumper, comptime fmt: []const u8, args: anytype) void {
        var buf: [1536]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            // Retry with a shorter body so we still record the box exists.
            break :blk std.fmt.bufPrint(&buf, "<line-too-long>\n", .{}) catch unreachable;
        };
        self.out.appendSlice(self.allocator, line) catch {};
    }
};

fn formatStyleDetail(s: ComputedStyle, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeStyleDetail(&w, s) catch return w.buffered();
    return w.buffered();
}

fn writeStyleDetail(w: *std.Io.Writer, s: ComputedStyle) !void {
    try w.print(" disp={s}", .{@tagName(s.display)});
    if (s.position != .static_) try w.print(" pos={s}", .{@tagName(s.position)});
    if (s.width != .auto) try w.print(" w={d:.0}", .{dimVal(s.width)});
    if (s.height != .auto) try w.print(" h={d:.0}", .{dimVal(s.height)});
    if (s.min_height != .auto) try w.print(" minh={d:.0}", .{dimVal(s.min_height)});
    if (s.max_height != .none) try w.print(" maxh={d:.0}", .{dimVal(s.max_height)});
    if (s.display == .flex or s.display == .inline_flex) {
        try w.print(" flexdir={s}", .{@tagName(s.flex_direction)});
        if (s.flex_grow != 0) try w.print(" grow={d:.2}", .{s.flex_grow});
        if (s.flex_shrink != 1) try w.print(" shrink={d:.2}", .{s.flex_shrink});
        if (s.flex_basis != .auto) try w.print(" basis={d:.0}", .{dimVal(s.flex_basis)});
        if (s.justify_content != .normal) try w.print(" justify={s}", .{@tagName(s.justify_content)});
        if (s.align_items != .auto) try w.print(" align={s}", .{@tagName(s.align_items)});
    }
    if (s.overflow_y != .visible) try w.print(" ovf-y={s}", .{@tagName(s.overflow_y)});
    if (s.overflow_x != .visible) try w.print(" ovf-x={s}", .{@tagName(s.overflow_x)});
    if (s.float_ != .none) try w.print(" float={s}", .{@tagName(s.float_)});
    if (s.visibility != .visible) try w.print(" vis={s}", .{@tagName(s.visibility)});
    if (s.opacity < 0.999) try w.print(" opacity={d:.2}", .{s.opacity});
}

/// Numeric value of a Dimension for diagnostics; non-numeric kinds print 0.
fn dimVal(d: ComputedStyle.Dimension) f32 {
    return switch (d) {
        .px => |v| v,
        .percent => |v| v,
        else => 0,
    };
}

fn indentFor(depth: usize) []const u8 {
    const spaces = "                                                                ";
    const n = @min(depth * 2, spaces.len);
    return spaces[0..n];
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    // Do not split a UTF-8 sequence: back off to a lead byte.
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// True for geometry that usually means a layout bug rather than a design.
fn isSuspicious(box: *const Box, mbox: Rect) bool {
    if (!std.math.isFinite(mbox.x) or !std.math.isFinite(mbox.y) or
        !std.math.isFinite(mbox.width) or !std.math.isFinite(mbox.height)) return true;
    if (mbox.width <= 0.01 or mbox.height <= 0.01) return true;
    if (mbox.x + mbox.width < -0.5 or mbox.y + mbox.height < -0.5) return true;
    if (mbox.x > 20000) return true;
    if (mbox.y > 100000) return true;
    if (box.style.overflow_y == .hidden and box.content.height < 1 and box.children.items.len > 0) return true;
    return false;
}

/// Build a `tag#id.class1.class2` description of the box's DOM element.
fn describeDom(node_opt: ?DomNode, buf: []u8) []const u8 {
    const node = node_opt orelse return "(anon)";
    if (node.nodeType() != .element) return "(non-element)";
    const element: *lxb.lxb_dom_element_t = @ptrCast(node.lxb_node);

    var w = std.Io.Writer.fixed(buf);
    const tag = node.tagName() orelse "?";
    w.writeAll(tag) catch return "(err)";

    var id_len: usize = 0;
    const id = lxb.lxb_dom_element_get_attribute(element, "id", 2, &id_len);
    if (id != null and id_len > 0) {
        w.writeByte('#') catch {};
        w.writeAll(truncate(id[0..id_len], 24)) catch {};
    }

    var class_len: usize = 0;
    const cls = lxb.lxb_dom_element_get_attribute(element, "class", 5, &class_len);
    if (cls != null and class_len > 0) {
        var it = std.mem.tokenizeScalar(u8, cls[0..class_len], ' ');
        var count: usize = 0;
        while (it.next()) |tok| {
            if (count >= 3) break;
            w.writeByte('.') catch {};
            w.writeAll(truncate(tok, 20)) catch {};
            count += 1;
        }
    }
    return w.buffered();
}

/// Write the dump for `root` to `path`, or stdout when `path` is "-".
pub fn writeTo(
    allocator: std.mem.Allocator,
    root: *const Box,
    path: []const u8,
    opts: Options,
) !void {
    var dumper = Dumper.init(allocator, opts);
    defer dumper.deinit();
    dumper.dump(root);

    if (std.mem.eql(u8, path, "-")) {
        std.debug.print("{s}", .{dumper.text()});
        return;
    }
    const file = try std.Io.Dir.cwd().createFile(env.ioOrPanic(), path, .{});
    defer file.close(env.ioOrPanic());
    try env.writeAll(file, dumper.text());
}
