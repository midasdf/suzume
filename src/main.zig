const std = @import("std");
const Surface = @import("paint/surface.zig").Surface;
const TextRenderer = @import("paint/text.zig").TextRenderer;
const GlyphBitmap = @import("paint/text.zig").GlyphBitmap;
const Document = @import("dom/tree.zig").Document;
const cascade_mod = @import("style/cascade.zig");
const box_tree = @import("layout/tree.zig");
const block_layout = @import("layout/block.zig");
const painter_mod = @import("paint/painter.zig");
const nsfb_c = @import("bindings/nsfb.zig").c;

const window_w = 720;
const window_h = 720;

// Default background colour (Catppuccin Mocha base)
const default_bg = 0xFF1e1e2e;

// Font paths — try CJK first, fall back to DejaVu
const font_cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
const font_fallback = "/usr/share/fonts/TTF/DejaVuSans.ttf";

const dom_test = @import("test_dom_style.zig");

fn findFont() [*:0]const u8 {
    // Check if CJK font exists by trying to open it
    const cjk_path: []const u8 = font_cjk[0..font_cjk.len];
    if (std.fs.openFileAbsolute(cjk_path, .{})) |f| {
        f.close();
        return font_cjk;
    } else |_| {}

    return font_fallback;
}

fn fontPathSlice(path: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (path[len] != 0) len += 1;
    return path[0..len];
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse arguments
    var args = std.process.args();
    _ = args.skip(); // skip program name
    var html_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-dom")) {
            return dom_test.main();
        }
        // Treat as HTML file path
        html_path = arg;
    }

    // Default HTML file
    const default_path = "tests/fixtures/japanese.html";
    const file_path = html_path orelse default_path;

    // Read HTML file
    std.debug.print("suzume v0.1.0 — loading {s}...\n", .{file_path});

    const html_content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read {s}: {}\n", .{ file_path, err });
        return err;
    };
    defer allocator.free(html_content);

    // 1. Parse HTML
    var doc = try Document.parse(html_content);
    defer doc.deinit();

    const root_node = doc.root() orelse {
        std.debug.print("FAIL: no root element\n", .{});
        return;
    };
    const body_node = doc.body() orelse {
        std.debug.print("FAIL: no body element\n", .{});
        return;
    };

    // 2. Resolve styles
    var styles = try cascade_mod.cascade(root_node, allocator);
    defer styles.deinit();
    std.debug.print("Resolved {d} element styles\n", .{styles.styles.count()});

    // 3. Build box tree
    const root_box = try box_tree.buildBoxTree(body_node, &styles, allocator);

    // 4. Determine font path
    const font_path = findFont();
    std.debug.print("Using font: {s}\n", .{fontPathSlice(font_path)});

    // 5. Create font cache and layout
    var fonts = painter_mod.FontCache.init(allocator, font_path);
    defer fonts.deinit();

    // Apply default body margin (8px if not set by CSS)
    const body_style = styles.getStyle(body_node) orelse @import("style/computed.zig").ComputedStyle{};
    const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
    root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

    // Layout the root box (layoutBlock handles padding/border, not margin)
    const root_containing_width = @as(f32, window_w) - root_box.margin.left - root_box.margin.right;
    block_layout.layoutBlock(root_box, root_containing_width, 0, &fonts);
    // Offset root box by its margin (root has no parent to do this)
    block_layout.adjustXPositions(root_box, root_box.margin.left);
    block_layout.adjustYPositions(root_box, root_box.margin.top);

    // 6. Open window
    var surface = Surface.init(window_w, window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // 7. Get background colour from body style
    const bg_argb = if (body_style.background_color != 0) body_style.background_color else default_bg;
    const bg_colour = Surface.argbToColour(bg_argb);

    // Clear background
    surface.fillRect(0, 0, window_w, window_h, bg_colour);

    // 8. Paint box tree
    painter_mod.paint(root_box, &surface, &fonts, 0);

    // 9. Update display
    surface.update();

    std.debug.print("Window open. Press Escape or close window to quit.\n", .{});

    // 10. Event loop
    var running = true;
    while (running) {
        if (surface.pollEvent(100)) |event| {
            if (event.type == nsfb_c.NSFB_EVENT_CONTROL and
                event.value.controlcode == nsfb_c.NSFB_CONTROL_QUIT)
            {
                running = false;
            } else if (event.type == nsfb_c.NSFB_EVENT_KEY_DOWN and
                event.value.keycode == nsfb_c.NSFB_KEY_ESCAPE)
            {
                running = false;
            }
        }
    }

    std.debug.print("Bye!\n", .{});
}

// Re-export modules so they are reachable from the build
pub const dom = struct {
    pub const node = @import("dom/node.zig");
    pub const tree = @import("dom/tree.zig");
};

pub const style = struct {
    pub const computed = @import("style/computed.zig");
    pub const select = @import("style/select.zig");
    pub const cascade = @import("style/cascade.zig");
};

pub const layout = struct {
    pub const box = @import("layout/box.zig");
    pub const tree = @import("layout/tree.zig");
    pub const block = @import("layout/block.zig");
};

pub const paint = struct {
    pub const painter = @import("paint/painter.zig");
};
