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
const HttpClient = @import("net/http.zig").HttpClient;
const Loader = @import("net/loader.zig").Loader;
const resolveUrl = @import("net/loader.zig").resolveUrl;
const chrome = @import("ui/chrome.zig");
const TextInput = @import("ui/input.zig").TextInput;
const InputResult = @import("ui/input.zig").InputResult;
const Box = @import("layout/box.zig").Box;

const window_w = chrome.window_w;
const window_h = chrome.window_h;

// Default background colour (Catppuccin Mocha base)
const default_bg = 0xFF1e1e2e;

// Font paths
const font_cjk = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc";
const font_fallback = "/usr/share/fonts/TTF/DejaVuSans.ttf";

const dom_test = @import("test_dom_style.zig");

fn findFont() [*:0]const u8 {
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

fn testHttp(allocator: std.mem.Allocator) !void {
    std.debug.print("=== HTTP Client Test ===\n", .{});
    var client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer client.deinit();
    std.debug.print("Fetching http://example.com ...\n", .{});
    var response = client.get(allocator, "http://example.com") catch |err| {
        std.debug.print("Failed to fetch: {}\n", .{err});
        return err;
    };
    defer response.deinit();
    std.debug.print("Status: {d}\n", .{response.status_code});
    std.debug.print("Content-Type: {s}\n", .{response.content_type});
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
    const preview_len = @min(response.body.len, 200);
    std.debug.print("Body preview:\n{s}\n", .{response.body[0..preview_len]});
    std.debug.print("=== Test complete ===\n", .{});
}

/// Browser state holding the current page's data.
const PageState = struct {
    doc: ?Document = null,
    styles: ?cascade_mod.CascadeResult = null,
    root_box: ?*Box = null,
    total_height: f32 = 0,

    fn deinit(self: *PageState) void {
        if (self.styles) |*s| s.deinit();
        if (self.doc) |*d| d.deinit();
        self.* = .{};
    }
};

/// Navigate to a URL: fetch, parse, style, layout.
/// Returns true on success, false on failure.
fn navigateTo(
    allocator: std.mem.Allocator,
    loader: *Loader,
    url_z: [:0]const u8,
    fonts: *painter_mod.FontCache,
    page: *PageState,
) bool {
    // Clean up old page
    page.deinit();

    // Fetch
    var content = loader.loadPage(url_z) catch |err| {
        std.debug.print("Failed to load {s}: {}\n", .{ url_z, err });
        return false;
    };
    defer content.deinit();

    // Parse
    var doc = Document.parse(content.html) catch {
        std.debug.print("Failed to parse HTML\n", .{});
        return false;
    };

    const root_node = doc.root() orelse {
        doc.deinit();
        return false;
    };
    const body_node = doc.body() orelse {
        doc.deinit();
        return false;
    };

    // Style
    var styles = cascade_mod.cascade(root_node, allocator) catch {
        doc.deinit();
        return false;
    };

    // Build box tree
    const root_box = box_tree.buildBoxTree(body_node, &styles, allocator) catch {
        styles.deinit();
        doc.deinit();
        return false;
    };

    // Apply body margin
    const body_style = styles.getStyle(body_node) orelse @import("style/computed.zig").ComputedStyle{};
    const body_margin: f32 = if (body_style.margin_top == 0 and body_style.margin_left == 0) 8.0 else body_style.margin_left;
    root_box.margin = .{ .top = body_margin, .right = body_margin, .bottom = body_margin, .left = body_margin };

    // Layout
    const content_w: f32 = @floatFromInt(chrome.window_w);
    const root_containing_width = content_w - root_box.margin.left - root_box.margin.right;
    block_layout.layoutBlock(root_box, root_containing_width, 0, fonts);
    block_layout.adjustXPositions(root_box, root_box.margin.left);
    block_layout.adjustYPositions(root_box, root_box.margin.top);

    const total_h = painter_mod.contentHeight(root_box);

    page.* = .{
        .doc = doc,
        .styles = styles,
        .root_box = root_box,
        .total_height = total_h,
    };

    return true;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse arguments
    var args = std.process.args();
    _ = args.skip();
    var initial_url: ?[]const u8 = null;
    var run_test_dom = false;
    var run_test_http = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test-dom")) {
            run_test_dom = true;
        } else if (std.mem.eql(u8, arg, "--test-http")) {
            run_test_http = true;
        } else {
            initial_url = arg;
        }
    }

    if (run_test_dom) return dom_test.main();
    if (run_test_http) return testHttp(allocator);

    std.debug.print("suzume v0.2.0 — browser mode\n", .{});

    // Init HTTP client
    var http_client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer http_client.deinit();

    var loader = Loader.init(allocator, &http_client);

    // Font
    const font_path = findFont();
    std.debug.print("Using font: {s}\n", .{fontPathSlice(font_path)});

    var fonts = painter_mod.FontCache.init(allocator, font_path);
    defer fonts.deinit();

    // Surface
    var surface = Surface.init(window_w, window_h) catch |err| {
        std.debug.print("Failed to create surface: {}\n", .{err});
        return err;
    };
    defer surface.deinit();

    // URL bar input
    var url_input = TextInput.init(allocator);
    defer url_input.deinit();
    url_input.focused = true;

    // Status
    var status_text: []const u8 = "Ready";

    // Page state
    var page = PageState{};
    defer page.deinit();

    // Scroll
    var scroll_y: f32 = 0;

    // History
    var history: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (history.items) |item| allocator.free(item);
        history.deinit(allocator);
    }
    var history_pos: usize = 0;

    // Current URL (owned)
    var current_url: ?[]u8 = null;
    defer if (current_url) |u| allocator.free(u);

    // Modifier key state
    var shift_held = false;
    var ctrl_held = false;
    var alt_held = false;

    // Mouse position tracking (for move events)
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;

    // If initial URL provided, navigate to it
    if (initial_url) |url| {
        url_input.setText(url);
        url_input.focused = false;

        // Make sentinel-terminated copy
        const url_z = allocator.allocSentinel(u8, url.len, 0) catch null;
        if (url_z) |uz| {
            defer allocator.free(uz);
            @memcpy(uz, url);
            status_text = "Loading...";

            if (navigateTo(allocator, &loader, uz, &fonts, &page)) {
                status_text = "Done";
                scroll_y = 0;
                // Store in history
                const owned = allocator.alloc(u8, url.len) catch null;
                if (owned) |o| {
                    @memcpy(o, url);
                    history.append(allocator, o) catch {};
                    history_pos = history.items.len - 1;
                    if (current_url) |old| allocator.free(old);
                    const cu = allocator.alloc(u8, url.len) catch null;
                    if (cu) |c| {
                        @memcpy(c, url);
                        current_url = c;
                    }
                }
            } else {
                status_text = "Failed to load page";
            }
        }
    }

    // Initial paint
    var needs_repaint = true;

    // Event loop
    var running = true;
    while (running) {
        // Repaint if needed
        if (needs_repaint) {
            // Clear content area
            chrome.clearContentArea(&surface);

            // Paint page content
            if (page.root_box) |root_box| {
                // scroll_y is in layout coords; we offset by content_y for screen position
                const adjusted_scroll = scroll_y - @as(f32, @floatFromInt(chrome.content_y));
                painter_mod.paint(
                    root_box,
                    &surface,
                    &fonts,
                    adjusted_scroll,
                    chrome.content_y,
                    chrome.content_y + chrome.content_height,
                );
            }

            // Paint chrome on top
            chrome.paintUrlBar(&surface, &fonts, &url_input);
            chrome.paintStatusBar(&surface, &fonts, status_text);

            surface.update();
            needs_repaint = false;
        }

        if (surface.pollEvent(50)) |event| {
            switch (event.type) {
                nsfb_c.NSFB_EVENT_CONTROL => {
                    if (event.value.controlcode == nsfb_c.NSFB_CONTROL_QUIT) {
                        running = false;
                    }
                },

                nsfb_c.NSFB_EVENT_KEY_DOWN => {
                    const key = event.value.keycode;

                    // Track modifier state
                    if (key == nsfb_c.NSFB_KEY_LSHIFT or key == nsfb_c.NSFB_KEY_RSHIFT) {
                        shift_held = true;
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_LCTRL or key == nsfb_c.NSFB_KEY_RCTRL) {
                        ctrl_held = true;
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_LALT or key == nsfb_c.NSFB_KEY_RALT) {
                        alt_held = true;
                        continue;
                    }

                    // Ctrl+Q: quit
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_q) {
                        running = false;
                        continue;
                    }

                    // Ctrl+L: focus URL bar
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_l) {
                        url_input.focused = true;
                        // Select all (move cursor to end)
                        url_input.cursor = url_input.buf.items.len;
                        needs_repaint = true;
                        continue;
                    }

                    // Ctrl+R: reload
                    if (ctrl_held and key == nsfb_c.NSFB_KEY_r) {
                        if (current_url) |url| {
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                            } else {
                                status_text = "Failed to load page";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Alt+Left: back
                    if (alt_held and key == nsfb_c.NSFB_KEY_LEFT) {
                        if (history_pos > 0) {
                            history_pos -= 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                            } else {
                                status_text = "Failed to load page";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Alt+Right: forward
                    if (alt_held and key == nsfb_c.NSFB_KEY_RIGHT) {
                        if (history_pos + 1 < history.items.len) {
                            history_pos += 1;
                            const url = history.items[history_pos];
                            const url_z = allocator.allocSentinel(u8, url.len, 0) catch continue;
                            defer allocator.free(url_z);
                            @memcpy(url_z, url);
                            url_input.setText(url);
                            status_text = "Loading...";
                            needs_repaint = true;
                            if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                status_text = "Done";
                                scroll_y = 0;
                                if (current_url) |old| allocator.free(old);
                                const cu = allocator.alloc(u8, url.len) catch null;
                                if (cu) |c| {
                                    @memcpy(c, url);
                                    current_url = c;
                                }
                            } else {
                                status_text = "Failed to load page";
                            }
                            needs_repaint = true;
                        }
                        continue;
                    }

                    // Handle mouse events regardless of focus
                    if (key == nsfb_c.NSFB_KEY_MOUSE_1) {
                        handleClick(
                            allocator,
                            mouse_x,
                            mouse_y,
                            &url_input,
                            &scroll_y,
                            &page,
                            &fonts,
                            &loader,
                            &history,
                            &history_pos,
                            &current_url,
                            &status_text,
                            &needs_repaint,
                        );
                        continue;
                    }
                    if (key == nsfb_c.NSFB_KEY_MOUSE_4 or key == nsfb_c.NSFB_KEY_MOUSE_5) {
                        const ch = @as(f32, @floatFromInt(chrome.content_height));
                        var new_scroll = scroll_y;
                        if (key == nsfb_c.NSFB_KEY_MOUSE_4) {
                            new_scroll -= 40;
                        } else {
                            new_scroll += 40;
                        }
                        const max_scroll = @max(page.total_height - ch, 0);
                        new_scroll = @max(0, @min(new_scroll, max_scroll));
                        if (new_scroll != scroll_y) {
                            scroll_y = new_scroll;
                            needs_repaint = true;
                        }
                        continue;
                    }

                    if (url_input.focused) {
                        // Route to text input
                        const result = url_input.handleKey(key, shift_held);
                        switch (result) {
                            .submit => {
                                // Navigate to URL
                                const url_text = url_input.getText();
                                if (url_text.len > 0) {
                                    const url_z = allocator.allocSentinel(u8, url_text.len, 0) catch continue;
                                    defer allocator.free(url_z);
                                    @memcpy(url_z, url_text);

                                    status_text = "Loading...";
                                    needs_repaint = true;

                                    if (navigateTo(allocator, &loader, url_z, &fonts, &page)) {
                                        status_text = "Done";
                                        scroll_y = 0;
                                        url_input.focused = false;

                                        // Truncate forward history if we navigated from middle
                                        if (history_pos + 1 < history.items.len) {
                                            for (history.items[history_pos + 1 ..]) |item| {
                                                allocator.free(item);
                                            }
                                            history.shrinkRetainingCapacity(history_pos + 1);
                                        }

                                        // Add to history
                                        const owned = allocator.alloc(u8, url_text.len) catch null;
                                        if (owned) |o| {
                                            @memcpy(o, url_text);
                                            history.append(allocator, o) catch {};
                                            history_pos = history.items.len - 1;
                                        }
                                        if (current_url) |old| allocator.free(old);
                                        const cu = allocator.alloc(u8, url_text.len) catch null;
                                        if (cu) |c| {
                                            @memcpy(c, url_text);
                                            current_url = c;
                                        }
                                    } else {
                                        status_text = "Failed to load page";
                                    }
                                }
                                needs_repaint = true;
                            },
                            .cancel => {
                                url_input.focused = false;
                                // Restore URL from current
                                if (current_url) |url| {
                                    url_input.setText(url);
                                }
                                needs_repaint = true;
                            },
                            .consumed => {
                                needs_repaint = true;
                            },
                            .ignored => {},
                        }
                    } else {
                        // Content area: handle scroll keys
                        {
                            const ch = @as(f32, @floatFromInt(chrome.content_height));
                            var new_scroll = scroll_y;

                            if (key == nsfb_c.NSFB_KEY_UP) {
                                new_scroll -= 40;
                            } else if (key == nsfb_c.NSFB_KEY_DOWN) {
                                new_scroll += 40;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEUP) {
                                new_scroll -= ch;
                            } else if (key == nsfb_c.NSFB_KEY_PAGEDOWN) {
                                new_scroll += ch;
                            } else if (key == nsfb_c.NSFB_KEY_HOME) {
                                new_scroll = 0;
                            } else if (key == nsfb_c.NSFB_KEY_END) {
                                if (page.total_height > ch) {
                                    new_scroll = page.total_height - ch;
                                }
                            } else if (key == nsfb_c.NSFB_KEY_ESCAPE) {
                                running = false;
                                continue;
                            }

                            // Clamp
                            const max_scroll = @max(page.total_height - ch, 0);
                            new_scroll = @max(0, @min(new_scroll, max_scroll));
                            if (new_scroll != scroll_y) {
                                scroll_y = new_scroll;
                                needs_repaint = true;
                            }
                        }
                    }
                },

                nsfb_c.NSFB_EVENT_KEY_UP => {
                    const key = event.value.keycode;
                    if (key == nsfb_c.NSFB_KEY_LSHIFT or key == nsfb_c.NSFB_KEY_RSHIFT) {
                        shift_held = false;
                    }
                    if (key == nsfb_c.NSFB_KEY_LCTRL or key == nsfb_c.NSFB_KEY_RCTRL) {
                        ctrl_held = false;
                    }
                    if (key == nsfb_c.NSFB_KEY_LALT or key == nsfb_c.NSFB_KEY_RALT) {
                        alt_held = false;
                    }
                },

                nsfb_c.NSFB_EVENT_MOVE_ABSOLUTE => {
                    mouse_x = event.value.vector.x;
                    mouse_y = event.value.vector.y;
                },

                else => {},
            }
        }
    }

    std.debug.print("Bye!\n", .{});
}

fn handleClick(
    allocator: std.mem.Allocator,
    mx: i32,
    my: i32,
    url_input: *TextInput,
    scroll_y: *f32,
    page: *PageState,
    fonts: *painter_mod.FontCache,
    loader: *Loader,
    history: *std.ArrayListUnmanaged([]u8),
    history_pos: *usize,
    current_url: *?[]u8,
    status_text: *[]const u8,
    needs_repaint: *bool,
) void {
    // Click in URL bar?
    if (my < chrome.url_bar_height) {
        url_input.focused = true;
        needs_repaint.* = true;
        return;
    }

    // Click in status bar? (ignore)
    if (my >= chrome.window_h - chrome.status_bar_height) return;

    // Click in content area — unfocus URL bar
    url_input.focused = false;

    // Hit test for links
    if (page.root_box) |root_box| {
        // Convert screen coords to layout coords
        const layout_x: f32 = @floatFromInt(mx);
        const layout_y: f32 = @as(f32, @floatFromInt(my - chrome.content_y)) + scroll_y.*;

        if (painter_mod.hitTestLink(root_box, layout_x, layout_y)) |link_href| {
            // Resolve URL
            const base = if (current_url.*) |u| u else "";
            const resolved = resolveUrl(allocator, base, link_href) catch return;
            defer allocator.free(resolved);

            std.debug.print("Navigating to: {s}\n", .{resolved});

            url_input.setText(resolved);
            status_text.* = "Loading...";
            needs_repaint.* = true;

            if (navigateTo(allocator, loader, resolved, fonts, page)) {
                status_text.* = "Done";
                scroll_y.* = 0;

                // Truncate forward history
                if (history_pos.* + 1 < history.items.len) {
                    for (history.items[history_pos.* + 1 ..]) |item| {
                        allocator.free(item);
                    }
                    history.shrinkRetainingCapacity(history_pos.* + 1);
                }

                // Add to history
                const owned = allocator.alloc(u8, resolved.len) catch return;
                @memcpy(owned, resolved);
                history.append(allocator, owned) catch {
                    allocator.free(owned);
                    return;
                };
                history_pos.* = history.items.len - 1;

                if (current_url.*) |old| allocator.free(old);
                const cu = allocator.alloc(u8, resolved.len) catch null;
                if (cu) |c| {
                    @memcpy(c, resolved);
                    current_url.* = c;
                }
            } else {
                status_text.* = "Failed to load page";
            }
            needs_repaint.* = true;
        } else {
            needs_repaint.* = true; // repaint to show unfocused URL bar
        }
    } else {
        needs_repaint.* = true;
    }
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
    pub const image = @import("paint/image.zig");
};

pub const net = struct {
    pub const http = @import("net/http.zig");
    pub const loader = @import("net/loader.zig");
};

pub const ui = struct {
    pub const chrome_mod = @import("ui/chrome.zig");
    pub const input = @import("ui/input.zig");
};
