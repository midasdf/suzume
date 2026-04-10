# suzume UI Full-Stack Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace libnsfb with direct XCB rendering, unify hit testing, add type-safe coordinates, decompose main.zig monolith, and refresh Chrome UI.

**Architecture:** XCB surface with SHM/non-SHM fallback replaces libnsfb. Single `hitTest()` returns unified `HitResult`. `BrowserContext` struct replaces 18-parameter functions. Callback-based event dispatch with priority handlers. Responsive Chrome UI with Catppuccin Mocha theme.

**Tech Stack:** Zig, XCB (xcb-shm, xcb-cursor), Xlib (XIM coexistence), lexbor (HTML), QuickJS (JS)

**Spec:** `docs/superpowers/specs/2026-04-10-ui-fullstack-redesign.md`

---

## File Map

### New Files
| File | Responsibility | Est. LOC |
|------|---------------|----------|
| `src/coords.zig` | Type-safe ScreenPos/ContentPos/LayoutPos + conversions | ~60 |
| `src/hit_test.zig` | Unified `hitTest()` → `HitResult` | ~150 |
| `src/browser.zig` | `BrowserContext` shared state struct | ~80 |
| `src/platform/xcb_surface.zig` | XCB window + pixel buffer + SHM/fallback present | ~350 |
| `src/platform/xim.zig` | XIM wrapper (extracted from surface.zig) | ~60 |
| `src/event_loop.zig` | XCB event polling + callback dispatch | ~300 |
| `src/input/click.zig` | Click → HitResult → actions | ~200 |
| `src/input/keyboard.zig` | Keyboard input, shortcuts, XIM text | ~200 |
| `src/input/mouse.zig` | Mouse move (hover), scroll | ~150 |
| `src/navigation.zig` | URL resolution, history, page load | ~300 |
| `src/render/pipeline.zig` | Render orchestration | ~200 |
| `src/ui/tab_bar.zig` | Tab strip component | ~120 |
| `src/ui/url_bar.zig` | URL input component | ~120 |
| `src/ui/status_bar.zig` | Status bar component | ~60 |
| `src/ui/theme.zig` | Catppuccin Mocha color constants | ~30 |

### Modified Files
| File | Change |
|------|--------|
| `src/main.zig` | Slim from 3,424 → ~200 LOC (init + main loop shell) |
| `src/paint/painter.zig` | Remove `hitTestNode`/`hitTestLink` (moved to hit_test.zig) |
| `src/ui/chrome.zig` | Rewrite as coordinator using tab_bar/url_bar/status_bar |
| `src/ui/input.zig` | Keep TextInput, used by url_bar.zig |
| `build.zig` | Add xcb-shm, xcb-cursor; remove libnsfb |

### Removed Files (Phase 6)
| File | Reason |
|------|--------|
| `src/paint/surface.zig` | Replaced by platform/xcb_surface.zig |
| `src/bindings/nsfb.zig` | No longer needed |
| `src/nsfb_surface_init.c` | libnsfb bootstrap |
| `build_libnsfb.zig` | libnsfb build script |

---

## Chunk 1: Foundation (Tasks 1-3)

### Task 1: Coordinate Types

**Files:**
- Create: `src/coords.zig`
- Test: `src/coords.zig` (inline tests)

- [ ] **Step 1: Write coords.zig with inline tests**

```zig
// src/coords.zig
const std = @import("std");

/// Position in X11 window (0,0 = top-left of window)
pub const ScreenPos = struct {
    x: f32,
    y: f32,

    pub fn fromInt(x: i32, y: i32) ScreenPos {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }
};

/// Position in content area (0,0 = top-left below Chrome)
pub const ContentPos = struct {
    x: f32,
    y: f32,
};

/// Position in page layout (includes scroll offset)
pub const LayoutPos = struct {
    x: f32,
    y: f32,
};

pub const ScrollOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub fn screenToContent(pos: ScreenPos, chrome_height: f32) ContentPos {
    return .{ .x = pos.x, .y = pos.y - chrome_height };
}

pub fn contentToLayout(pos: ContentPos, scroll: ScrollOffset) LayoutPos {
    return .{ .x = pos.x + scroll.x, .y = pos.y + scroll.y };
}

pub fn screenToLayout(pos: ScreenPos, chrome_height: f32, scroll: ScrollOffset) LayoutPos {
    return contentToLayout(screenToContent(pos, chrome_height), scroll);
}

test "screenToContent subtracts chrome height" {
    const pos = screenToContent(.{ .x = 100, .y = 164 }, 64);
    try std.testing.expectEqual(@as(f32, 100), pos.x);
    try std.testing.expectEqual(@as(f32, 100), pos.y);
}

test "contentToLayout adds scroll offset" {
    const pos = contentToLayout(.{ .x = 50, .y = 50 }, .{ .x = 10, .y = 200 });
    try std.testing.expectEqual(@as(f32, 60), pos.x);
    try std.testing.expectEqual(@as(f32, 250), pos.y);
}

test "screenToLayout composes both transforms" {
    const pos = screenToLayout(.{ .x = 100, .y = 164 }, 64, .{ .x = 0, .y = 300 });
    try std.testing.expectEqual(@as(f32, 100), pos.x);
    try std.testing.expectEqual(@as(f32, 400), pos.y);
}
```

- [ ] **Step 2: Run tests**

Run: `zig test src/coords.zig`
Expected: All 3 tests pass

- [ ] **Step 3: Commit**

```bash
git add src/coords.zig
git commit -m "feat: add type-safe coordinate system (ScreenPos/ContentPos/LayoutPos)"
```

---

### Task 2: Unified Hit Testing

**Files:**
- Create: `src/hit_test.zig`
- Read: `src/paint/painter.zig:1271-1357` (existing hitTestNode/hitTestLink)
- Read: `src/layout/box.zig` (Box struct, marginBox())
- Read: `src/dom/node.zig` (DomNode, tagName, getAttribute, parent)

- [ ] **Step 1: Write hit_test.zig with HitResult struct**

```zig
// src/hit_test.zig
const std = @import("std");
const Box = @import("layout/box.zig").Box;
const BoxType = @import("layout/box.zig").BoxType;
const DomNode = @import("dom/node.zig").DomNode;
const LayoutPos = @import("coords.zig").LayoutPos;
const ComputedStyle = @import("css/computed.zig").ComputedStyle;

pub const HitResult = struct {
    /// Deepest DOM node at the hit point
    dom_node: ?DomNode = null,
    /// Nearest ancestor <a href> URL (walked up from dom_node)
    link_url: ?[]const u8 = null,
    /// The Box that was hit
    box: ?*const Box = null,
    /// Nearest form element (input/textarea/button/select)
    form_element: ?DomNode = null,
};

/// Single unified hit test. Returns HitResult with all info from one traversal.
/// Replaces the old hitTestNode + hitTestLink dual-function approach.
pub fn hitTest(box: *const Box, pos: LayoutPos) HitResult {
    var result = hitTestBox(box, pos);
    // Walk DOM ancestors to populate link_url and form_element
    if (result.dom_node) |dn| {
        populateAncestorInfo(&result, dn);
    }
    return result;
}

fn hitTestBox(box: *const Box, pos: LayoutPos) HitResult {
    switch (box.box_type) {
        .block, .inline_box => {
            // Bounds pre-check: prune subtree if point is clearly outside (perf critical on RPi)
            const mbox = box.marginBox();
            const tolerance: f32 = if (box.style.text_align == .center or box.style.text_align == .right)
                box.content.width
            else
                0;
            if (pos.x < mbox.x - tolerance or pos.x > mbox.x + mbox.width + tolerance or
                pos.y < mbox.y or pos.y > mbox.y + mbox.height)
                return .{};

            // Check children in reverse z-order
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const child_result = hitTestBox(box.children.items[i], pos);
                if (child_result.dom_node != null) return child_result;
            }
            // Check self
            if (pos.x >= mbox.x and pos.x <= mbox.x + mbox.width and
                pos.y >= mbox.y and pos.y <= mbox.y + mbox.height)
            {
                if (box.dom_node) |dn| {
                    return .{ .dom_node = dn, .box = box };
                }
            }
        },
        .anonymous_block => {
            // Skip bounds pre-check for anonymous blocks (children may overflow)
            var i = box.children.items.len;
            while (i > 0) {
                i -= 1;
                const child_result = hitTestBox(box.children.items[i], pos);
                if (child_result.dom_node != null) return child_result;
            }
        },
        .inline_text => {
            for (box.lines.items) |line| {
                if (pos.x >= line.x and pos.x <= line.x + line.width and
                    pos.y >= line.y and pos.y <= line.y + line.height)
                {
                    if (box.dom_node) |dn| {
                        return .{ .dom_node = dn, .box = box };
                    }
                    return .{};
                }
            }
        },
        .replaced => {
            if (pos.x >= box.content.x and pos.x <= box.content.x + box.content.width and
                pos.y >= box.content.y and pos.y <= box.content.y + box.content.height)
            {
                if (box.dom_node) |dn| {
                    return .{ .dom_node = dn, .box = box };
                }
            }
        },
    }
    return .{};
}

/// Walk DOM ancestors from hit node to populate link_url and form_element.
fn populateAncestorInfo(result: *HitResult, start: DomNode) void {
    var node = start;
    while (true) {
        const tag = node.tagName() orelse "";
        // Check for <a href>
        if (result.link_url == null and std.mem.eql(u8, tag, "a")) {
            if (node.getAttribute("href")) |href| {
                result.link_url = href;
            }
        }
        // Check for form elements
        if (result.form_element == null) {
            if (std.mem.eql(u8, tag, "input") or
                std.mem.eql(u8, tag, "textarea") or
                std.mem.eql(u8, tag, "button") or
                std.mem.eql(u8, tag, "select"))
            {
                result.form_element = node;
            }
        }
        // Early exit if both found
        if (result.link_url != null and result.form_element != null) return;
        node = node.parent() orelse return;
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `zig build 2>&1 | head -20`
Note: `hit_test.zig` won't be compiled yet (not imported anywhere). Use:
Run: `zig test src/hit_test.zig 2>&1 | head -20`
Expected: Compiles (even if no tests yet). May need to adjust import paths.

- [ ] **Step 3: Add unit tests with manually constructed Box trees**

Add to bottom of `src/hit_test.zig`:

```zig
test "hitTest finds deepest node in nested blocks" {
    // Test with manually constructed Box tree
    // (This test verifies the core traversal logic)
    const allocator = std.testing.allocator;

    // Create a simple box tree: root_block > child_block
    var root_children = Box.ChildList{};
    var child = Box{
        .box_type = .block,
        .content = .{ .x = 10, .y = 10, .width = 100, .height = 50 },
        // No dom_node in test (would need lexbor) — just test traversal
    };
    try root_children.append(allocator, &child);
    defer root_children.deinit(allocator);

    var root = Box{
        .box_type = .block,
        .content = .{ .x = 0, .y = 0, .width = 200, .height = 200 },
        .children = root_children,
    };

    // Click inside child — should return empty (no dom_node) but not crash
    const result = hitTest(&root, .{ .x = 50, .y = 30 });
    try std.testing.expect(result.dom_node == null);

    // Click outside all boxes
    const miss = hitTest(&root, .{ .x = 500, .y = 500 });
    try std.testing.expect(miss.dom_node == null);
}

test "hitTest skips bounds check for anonymous_block" {
    const allocator = std.testing.allocator;

    var anon_children = Box.ChildList{};
    // Child that overflows parent anonymous block bounds
    var overflow_child = Box{
        .box_type = .inline_text,
        .content = .{ .x = 200, .y = 200, .width = 50, .height = 20 },
        // line box at overflow position
    };
    try anon_children.append(allocator, &overflow_child);
    defer anon_children.deinit(allocator);

    var anon = Box{
        .box_type = .anonymous_block,
        .content = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .children = anon_children,
    };

    // Click at overflow position — should still be checked (no bounds pre-check)
    // Returns empty because inline_text has no lines, but traversal runs
    const result = hitTest(&anon, .{ .x = 210, .y = 210 });
    try std.testing.expect(result.dom_node == null);
}
```

- [ ] **Step 4: Run tests**

Run: `zig test src/hit_test.zig`
Expected: Tests pass (traversal works even without DOM nodes)

- [ ] **Step 5: Commit**

```bash
git add src/hit_test.zig
git commit -m "feat: add unified hitTest with HitResult — single traversal + ancestor walk"
```

---

### Task 3: Theme Constants

**Files:**
- Create: `src/ui/theme.zig`

- [ ] **Step 1: Extract theme from chrome.zig**

Check current colors in `src/ui/chrome.zig` and centralize:

```zig
// src/ui/theme.zig
pub const theme = struct {
    // Catppuccin Mocha
    pub const base = 0xFF1E1E2E;
    pub const mantle = 0xFF181825;
    pub const crust = 0xFF11111B;
    pub const surface0 = 0xFF313244;
    pub const surface1 = 0xFF45475A;
    pub const surface2 = 0xFF585B70;
    pub const text = 0xFFCDD6F4;
    pub const subtext0 = 0xFFA6ADC8;
    pub const subtext1 = 0xFFBAC2DE;
    pub const blue = 0xFF89B4FA;
    pub const green = 0xFFA6E3A1;
    pub const red = 0xFFF38BA8;
    pub const yellow = 0xFFF9E2AF;
    pub const peach = 0xFFFAB387;
    pub const overlay0 = 0xFF6C7086;
    pub const link = 0xFF89B4FA;
    pub const link_visited = 0xFFCBA6F7; // mauve
    pub const tab_active = surface0;
    pub const tab_inactive = mantle;
    pub const url_bar_bg = surface0;
    pub const status_bar_bg = mantle;
    pub const border = surface2;
};
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/theme.zig
git commit -m "feat: centralize Catppuccin Mocha theme constants"
```

---

## Chunk 2: Platform Layer (Tasks 4-5)

### Task 4: XCB Surface

**Files:**
- Create: `src/platform/xcb_surface.zig`
- Read: `src/paint/surface.zig` (current API to match)
- Modify: `build.zig` (add xcb-shm, xcb-cursor)

This is the largest single task. The XCB surface must provide the same drawing API as the current libnsfb Surface so they can coexist during migration.

- [ ] **Step 1: Create platform directory**

Run: `mkdir -p src/platform src/input src/render`

- [ ] **Step 2: Add xcb-shm and xcb-cursor to build.zig**

In `build.zig`, after the existing `linkSystemLibrary` calls (around line 344), add:

```zig
exe.linkSystemLibrary("xcb-shm");
exe.linkSystemLibrary("xcb-cursor");
```

- [ ] **Step 3: Write xcb_surface.zig — init/deinit/present**

```zig
// src/platform/xcb_surface.zig
const std = @import("std");
const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("xcb/xcb_image.h");
    @cInclude("xcb/xcb_icccm.h");
    @cInclude("xcb/xcb_cursor.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("sys/shm.h");
    @cInclude("sys/ipc.h");
});

pub const CursorShape = enum { arrow, pointer, text };

pub const XcbSurface = struct {
    xlib_display: *c.Display,
    connection: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    window: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    // SHM fields (null if unavailable)
    use_shm: bool,
    shm_seg: c.xcb_shm_seg_t,
    shm_id: c_int,
    pixels: []u32,
    width: u32,
    height: u32,
    // WM protocol
    wm_delete_atom: c.xcb_atom_t,
    wm_protocols_atom: c.xcb_atom_t,
    // Cursors
    cursor_ctx: ?*c.xcb_cursor_context_t,
    current_cursor: CursorShape,
    // Key symbols
    key_symbols: ?*c.xcb_key_symbols_t,

    pub fn init(width: u32, height: u32, title: []const u8) !XcbSurface {
        // 1. Open Xlib display (needed for XIM coexistence)
        const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        c.XSetEventQueueOwner(display, c.XCBOwnsEventQueue);
        const conn = c.XGetXCBConnection(display) orelse return error.CannotGetXCB;

        // 2. Get screen
        const setup = c.xcb_get_setup(conn);
        const screen_iter = c.xcb_setup_roots_iterator(setup);
        const screen = screen_iter.data;

        // 3. Create window
        const win = c.xcb_generate_id(conn);
        const mask = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK;
        const values = [_]u32{
            screen.*.black_pixel,
            c.XCB_EVENT_MASK_EXPOSURE |
                c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE |
                c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE |
                c.XCB_EVENT_MASK_POINTER_MOTION |
                c.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        };
        _ = c.xcb_create_window(conn, c.XCB_COPY_FROM_PARENT, win, screen.*.root,
            0, 0, @intCast(width), @intCast(height), 0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.*.visual, mask, &values);

        // 4. Set title
        _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, win,
            c.XCB_ATOM_WM_NAME, c.XCB_ATOM_STRING, 8,
            @intCast(title.len), title.ptr);

        // 5. Register WM_DELETE_WINDOW
        const wm_protocols = internAtom(conn, "WM_PROTOCOLS");
        const wm_delete = internAtom(conn, "WM_DELETE_WINDOW");
        _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, win,
            wm_protocols, 4, 32, 1, &wm_delete);

        // 6. Create GC
        const gc_id = c.xcb_generate_id(conn);
        _ = c.xcb_create_gc(conn, gc_id, win, 0, null);

        // 7. Try SHM
        var surface = XcbSurface{
            .xlib_display = display,
            .connection = conn,
            .screen = screen,
            .window = win,
            .gc = gc_id,
            .use_shm = false,
            .shm_seg = 0,
            .shm_id = -1,
            .pixels = undefined,
            .width = width,
            .height = height,
            .wm_delete_atom = wm_delete,
            .wm_protocols_atom = wm_protocols,
            .cursor_ctx = null,
            .current_cursor = .arrow,
            .key_symbols = c.xcb_key_symbols_alloc(conn),
        };

        // Try to init SHM
        surface.initShm() catch {
            // Fallback: heap-allocated pixel buffer
            const alloc = std.heap.page_allocator;
            surface.pixels = try alloc.alloc(u32, width * height);
            @memset(surface.pixels, 0);
        };

        // Init cursor context
        var cursor_ctx: ?*c.xcb_cursor_context_t = null;
        if (c.xcb_cursor_context_new(conn, screen, &cursor_ctx) == 0) {
            surface.cursor_ctx = cursor_ctx;
        }

        // Map window
        _ = c.xcb_map_window(conn, win);
        _ = c.xcb_flush(conn);

        return surface;
    }

    fn initShm(self: *XcbSurface) !void {
        // Check SHM extension
        const ext = c.xcb_get_extension_data(self.connection, &c.xcb_shm_id);
        if (ext == null or ext.*.present == 0) return error.ShmNotAvailable;

        const size = self.width * self.height * 4;
        self.shm_id = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o600);
        if (self.shm_id < 0) return error.ShmGetFailed;

        const ptr = c.shmat(self.shm_id, null, 0);
        if (ptr == @as(*anyopaque, @ptrFromInt(std.math.maxInt(usize))))
            return error.ShmAttachFailed;

        self.pixels.ptr = @ptrCast(@alignCast(ptr));
        self.pixels.len = self.width * self.height;

        self.shm_seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, self.shm_seg, @intCast(self.shm_id), 0);
        _ = c.xcb_flush(self.connection);

        self.use_shm = true;
    }

    pub fn present(self: *XcbSurface) void {
        if (self.use_shm) {
            _ = c.xcb_shm_put_image(self.connection, self.window, self.gc,
                @intCast(self.width), @intCast(self.height),
                0, 0, @intCast(self.width), @intCast(self.height),
                0, 0, self.screen.*.root_depth, c.XCB_IMAGE_FORMAT_Z_PIXMAP,
                0, self.shm_seg, 0);
        } else {
            _ = c.xcb_put_image(self.connection, c.XCB_IMAGE_FORMAT_Z_PIXMAP,
                self.window, self.gc,
                @intCast(self.width), @intCast(self.height),
                0, 0, 0, self.screen.*.root_depth,
                self.width * self.height * 4,
                @ptrCast(self.pixels.ptr));
        }
        _ = c.xcb_flush(self.connection);
    }

    pub fn deinit(self: *XcbSurface) void {
        if (self.key_symbols) |ks| c.xcb_key_symbols_free(ks);
        if (self.cursor_ctx) |ctx| c.xcb_cursor_context_free(ctx);
        if (self.use_shm) {
            _ = c.xcb_shm_detach(self.connection, self.shm_seg);
            _ = c.shmdt(@ptrCast(self.pixels.ptr));
            _ = c.shmctl(self.shm_id, c.IPC_RMID, null);
        } else {
            std.heap.page_allocator.free(self.pixels);
        }
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.XCloseDisplay(self.xlib_display);
    }

    // --- Drawing primitives ---

    pub fn fillRect(self: *XcbSurface, x: i32, y: i32, w: u32, h: u32, color: u32) void {
        const sx: u32 = @intCast(@max(0, x));
        const sy: u32 = @intCast(@max(0, y));
        const ex = @min(sx + w, self.width);
        const ey = @min(sy + h, self.height);
        var py = sy;
        while (py < ey) : (py += 1) {
            var px = sx;
            while (px < ex) : (px += 1) {
                self.pixels[py * self.width + px] = color;
            }
        }
    }

    pub fn clear(self: *XcbSurface, color: u32) void {
        @memset(self.pixels, color);
    }

    pub fn resize(self: *XcbSurface, w: u32, h: u32) !void {
        if (self.use_shm) {
            // Detach old SHM
            _ = c.xcb_shm_detach(self.connection, self.shm_seg);
            _ = c.shmdt(@ptrCast(self.pixels.ptr));
            _ = c.shmctl(self.shm_id, c.IPC_RMID, null);
            // Allocate new SHM at new size
            self.width = w;
            self.height = h;
            self.initShm() catch {
                // Fallback to heap if SHM fails on resize
                self.use_shm = false;
                self.pixels = try std.heap.page_allocator.alloc(u32, w * h);
                @memset(self.pixels, 0);
            };
        } else {
            std.heap.page_allocator.free(self.pixels);
            self.width = w;
            self.height = h;
            self.pixels = try std.heap.page_allocator.alloc(u32, w * h);
            @memset(self.pixels, 0);
        }
    }

    pub fn setCursor(self: *XcbSurface, shape: CursorShape) void {
        if (shape == self.current_cursor) return;
        const ctx = self.cursor_ctx orelse return;
        const name: [*:0]const u8 = switch (shape) {
            .arrow => "default",
            .pointer => "pointer",
            .text => "text",
        };
        const cursor = c.xcb_cursor_load_cursor(ctx, name);
        _ = c.xcb_change_window_attributes(self.connection, self.window,
            c.XCB_CW_CURSOR, &cursor);
        _ = c.xcb_flush(self.connection);
        self.current_cursor = shape;
    }

    fn internAtom(conn: *c.xcb_connection_t, name: []const u8) c.xcb_atom_t {
        const cookie = c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const reply = c.xcb_intern_atom_reply(conn, cookie, null);
        if (reply) |r| {
            defer std.c.free(r);
            return r.*.atom;
        }
        return 0;
    }
};
```

Note: `blitGlyph` and `blitImage` will be ported from the existing surface.zig's logic in a follow-up step within this task. The pixel buffer approach is identical — just writing to `self.pixels[]` instead of through libnsfb.

- [ ] **Step 4: Port blitGlyph8 and blitImage from surface.zig**

Read `src/paint/surface.zig` lines 200-518 for the existing glyph/image blitting. Port the pixel-level logic to operate on `self.pixels[]` directly. The algorithm is identical — alpha blending into the XRGB pixel buffer.

- [ ] **Step 5: Build to verify XCB compilation**

Run: `zig build 2>&1 | head -20`
Note: File not imported yet, just verify it compiles standalone. May need to create a test build step or temporarily import.

- [ ] **Step 6: Commit**

```bash
git add src/platform/xcb_surface.zig build.zig
git commit -m "feat: add XCB surface with SHM/fallback — replaces libnsfb"
```

---

### Task 5: XIM Wrapper Extraction

**Files:**
- Create: `src/platform/xim.zig`
- Read: `src/paint/surface.zig:18-24` (current XIM extern declarations)

- [ ] **Step 1: Extract XIM into standalone module**

```zig
// src/platform/xim.zig
const c = @cImport({
    @cInclude("X11/Xlib.h");
});

// XIM helper functions (defined in xim_helper.c)
extern fn xim_init(window_id: c_ulong) c_int;
extern fn xim_process_key(keycode: c_uint, state: c_uint, is_press: c_int, buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_poll_committed(buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_focus_in() void;
extern fn xim_focus_out() void;
extern fn xim_cleanup() void;

pub const Xim = struct {
    initialized: bool = false,

    pub fn init(window_id: c_ulong) Xim {
        const result = xim_init(window_id);
        return .{ .initialized = result == 0 };
    }

    pub fn processKey(self: Xim, keycode: c_uint, state: c_uint, is_press: bool, buf: []u8) ?[]const u8 {
        if (!self.initialized) return null;
        const len = xim_process_key(keycode, state, @intFromBool(is_press), buf.ptr, @intCast(buf.len));
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }

    pub fn pollCommitted(self: Xim, buf: []u8) ?[]const u8 {
        if (!self.initialized) return null;
        const len = xim_poll_committed(buf.ptr, @intCast(buf.len));
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }

    pub fn focusIn(self: Xim) void {
        if (self.initialized) xim_focus_in();
    }

    pub fn focusOut(self: Xim) void {
        if (self.initialized) xim_focus_out();
    }

    pub fn deinit(self: Xim) void {
        if (self.initialized) xim_cleanup();
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/platform/xim.zig
git commit -m "feat: extract XIM wrapper into platform/xim.zig"
```

---

## Chunk 3: Event System + Browser Context (Tasks 6-8)

### Task 6: BrowserContext Struct

**Files:**
- Create: `src/browser.zig`
- Read: `src/main.zig:2668` (handleClick's 18 parameters)

- [ ] **Step 1: Write browser.zig**

```zig
// src/browser.zig
//
// During migration, PageState is re-exported from main.zig rather than
// redefined. The real PageState has 15 fields (doc, styles, root_box,
// image_cache, js_rt, external_css, pending_images, anim_state, etc.)
// plus a complex deinit() that manages QuickJS teardown. Reimplementing
// it would break page loading, CSS cascade, image loading, and JS.
// After full decomposition (Task 16+), PageState can be moved here.

const std = @import("std");
const coords = @import("coords.zig");
const lxb = @import("bindings/lexbor.zig").c;

const XcbSurface = @import("platform/xcb_surface.zig").XcbSurface;

// Re-export from main.zig during migration. After Task 16, move here.
pub const PageState = @import("main.zig").PageState;

pub const BrowserContext = struct {
    allocator: std.mem.Allocator,
    surface: *XcbSurface,
    pages: std.ArrayListUnmanaged(PageState),
    active_tab: usize = 0,
    scroll: coords.ScrollOffset = .{},
    focused_input: ?*lxb.lxb_dom_node_t = null,
    needs_repaint: bool = true,
    running: bool = true,

    pub fn activePage(self: *BrowserContext) ?*PageState {
        if (self.active_tab < self.pages.items.len) {
            return &self.pages.items[self.active_tab];
        }
        return null;
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/browser.zig
git commit -m "feat: add BrowserContext shared state struct"
```

---

### Task 7: Event Loop

**Files:**
- Create: `src/event_loop.zig`
- Read: `src/main.zig:892` (current event loop)

- [ ] **Step 1: Write event_loop.zig**

```zig
// src/event_loop.zig
const std = @import("std");
const coords = @import("coords.zig");
const XcbSurface = @import("platform/xcb_surface.zig").XcbSurface;
const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_keysyms.h");
});

pub const MouseButton = enum { left, middle, right };

pub const KeyEvent = struct {
    keysym: u32,
    keycode: u8,
    state: u16, // modifier mask
    pub fn ctrlHeld(self: KeyEvent) bool { return self.state & c.XCB_MOD_MASK_CONTROL != 0; }
    pub fn shiftHeld(self: KeyEvent) bool { return self.state & c.XCB_MOD_MASK_SHIFT != 0; }
    pub fn altHeld(self: KeyEvent) bool { return self.state & c.XCB_MOD_MASK_1 != 0; }
};

pub const ScrollDelta = struct { dx: f32, dy: f32 };

pub const EventHandler = struct {
    ctx: *anyopaque,
    onClick: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseDown: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseUp: ?*const fn (*anyopaque, coords.ScreenPos, MouseButton) bool = null,
    onMouseMove: ?*const fn (*anyopaque, coords.ScreenPos) void = null,
    onScroll: ?*const fn (*anyopaque, coords.ScreenPos, ScrollDelta) void = null,
    onKeyDown: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onKeyUp: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onResize: ?*const fn (*anyopaque, u32, u32) void = null,
};

pub const EventLoop = struct {
    surface: *XcbSurface,
    handlers: std.BoundedArray(EventHandler, 8) = .{},
    running: bool = true,
    // Track press position for click synthesis
    press_pos: ?coords.ScreenPos = null,

    pub fn registerHandler(self: *EventLoop, handler: EventHandler) void {
        self.handlers.append(handler) catch {
            std.debug.print("[EventLoop] handler overflow, max 8\n", .{});
        };
    }

    pub fn requestQuit(self: *EventLoop) void {
        self.running = false;
    }

    pub fn run(self: *EventLoop, repaint_callback: *const fn () void) void {
        while (self.running) {
            // Check connection health
            if (c.xcb_connection_has_error(self.surface.connection) != 0) {
                self.running = false;
                break;
            }

            // Poll events (non-blocking)
            while (c.xcb_poll_for_event(self.surface.connection)) |event| {
                defer std.c.free(event);
                self.dispatchEvent(event);
            }

            // Repaint if needed
            repaint_callback();

            // Block on XCB fd when no repaint pending (avoids busy-loop on RPi)
            if (!self.needs_repaint) {
                const fd = c.xcb_get_file_descriptor(self.surface.connection);
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&pfd, 16); // 16ms timeout (~60fps cap)
            }
        }
    }

    fn dispatchEvent(self: *EventLoop, raw_event: *c.xcb_generic_event_t) void {
        const event_type = raw_event.response_type & 0x7F;
        switch (event_type) {
            c.XCB_BUTTON_PRESS => {
                const ev: *c.xcb_button_press_event_t = @ptrCast(raw_event);
                const pos = coords.ScreenPos.fromInt(ev.event_x, ev.event_y);
                switch (ev.detail) {
                    1, 2, 3 => {
                        self.press_pos = pos;
                        const btn = buttonFromDetail(ev.detail);
                        for (self.handlers.constSlice()) |h| {
                            if (h.onMouseDown) |cb| {
                                if (cb(h.ctx, pos, btn)) break;
                            }
                        }
                    },
                    4 => self.dispatchScroll(pos, .{ .dx = 0, .dy = -40 }),
                    5 => self.dispatchScroll(pos, .{ .dx = 0, .dy = 40 }),
                    else => {},
                }
            },
            c.XCB_BUTTON_RELEASE => {
                const ev: *c.xcb_button_release_event_t = @ptrCast(raw_event);
                const pos = coords.ScreenPos.fromInt(ev.event_x, ev.event_y);
                if (ev.detail >= 1 and ev.detail <= 3) {
                    const btn = buttonFromDetail(ev.detail);
                    for (self.handlers.constSlice()) |h| {
                        if (h.onMouseUp) |cb| {
                            if (cb(h.ctx, pos, btn)) break;
                        }
                    }
                    // Synthesize click
                    for (self.handlers.constSlice()) |h| {
                        if (h.onClick) |cb| {
                            if (cb(h.ctx, pos, btn)) break;
                        }
                    }
                    self.press_pos = null;
                }
            },
            c.XCB_MOTION_NOTIFY => {
                const ev: *c.xcb_motion_notify_event_t = @ptrCast(raw_event);
                const pos = coords.ScreenPos.fromInt(ev.event_x, ev.event_y);
                for (self.handlers.constSlice()) |h| {
                    if (h.onMouseMove) |cb| cb(h.ctx, pos);
                }
            },
            c.XCB_KEY_PRESS => {
                const ev: *c.xcb_key_press_event_t = @ptrCast(raw_event);
                const key = self.makeKeyEvent(ev.detail, ev.state);
                for (self.handlers.constSlice()) |h| {
                    if (h.onKeyDown) |cb| {
                        if (cb(h.ctx, key)) break;
                    }
                }
            },
            c.XCB_KEY_RELEASE => {
                const ev: *c.xcb_key_release_event_t = @ptrCast(raw_event);
                const key = self.makeKeyEvent(ev.detail, ev.state);
                for (self.handlers.constSlice()) |h| {
                    if (h.onKeyUp) |cb| {
                        if (cb(h.ctx, key)) break;
                    }
                }
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const ev: *c.xcb_configure_notify_event_t = @ptrCast(raw_event);
                const w: u32 = @intCast(ev.width);
                const h: u32 = @intCast(ev.height);
                if (w != self.surface.width or h != self.surface.height) {
                    self.surface.resize(w, h) catch {};
                    for (self.handlers.constSlice()) |handler| {
                        if (handler.onResize) |cb| cb(handler.ctx, w, h);
                    }
                }
            },
            c.XCB_CLIENT_MESSAGE => {
                const ev: *c.xcb_client_message_event_t = @ptrCast(raw_event);
                if (ev.data.data32[0] == self.surface.wm_delete_atom) {
                    self.requestQuit();
                }
            },
            else => {},
        }
    }

    fn dispatchScroll(self: *EventLoop, pos: coords.ScreenPos, delta: ScrollDelta) void {
        for (self.handlers.constSlice()) |h| {
            if (h.onScroll) |cb| cb(h.ctx, pos, delta);
        }
    }

    fn makeKeyEvent(self: *EventLoop, keycode: u8, state: u16) KeyEvent {
        var keysym: u32 = 0;
        if (self.surface.key_symbols) |ks| {
            keysym = c.xcb_key_symbols_get_keysym(ks, keycode, 0);
        }
        return .{ .keysym = keysym, .keycode = keycode, .state = state };
    }

    fn buttonFromDetail(detail: u8) MouseButton {
        return switch (detail) {
            1 => .left,
            2 => .middle,
            3 => .right,
            else => .left,
        };
    }
};
```

- [ ] **Step 2: Build to verify compilation**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/event_loop.zig
git commit -m "feat: add XCB event loop with callback dispatch + WM_DELETE_WINDOW"
```

---

### Task 8: Render Pipeline

**Files:**
- Create: `src/render/pipeline.zig`

- [ ] **Step 1: Write pipeline.zig**

```zig
// src/render/pipeline.zig
const std = @import("std");
const coords = @import("../coords.zig");
const XcbSurface = @import("../platform/xcb_surface.zig").XcbSurface;
const painter_mod = @import("../paint/painter.zig");
const Box = @import("../layout/box.zig").Box;
const FontCache = painter_mod.FontCache;
const ImageCache = @import("../paint/image.zig").ImageCache;
const theme = @import("../ui/theme.zig").theme;

pub const RenderPipeline = struct {
    surface: *XcbSurface,
    fonts: *FontCache,
    chrome_height: f32,

    pub fn render(
        self: *RenderPipeline,
        root_box: ?*Box,
        scroll: coords.ScrollOffset,
        image_cache: ?*ImageCache,
        paint_chrome_fn: *const fn (*XcbSurface) void,
    ) void {
        // 1. Clear
        self.surface.clear(theme.base);

        // 2. Paint chrome
        paint_chrome_fn(self.surface);

        // 3. Paint page content
        if (root_box) |root| {
            const chrome_y: i32 = @intFromFloat(self.chrome_height);
            const win_h: i32 = @intCast(self.surface.height);

            // The actual painter.paint() signature is:
            //   paint(box, surface, fonts, scroll_y, scroll_x, clip_top, clip_bottom, image_cache)
            painter_mod.paint(
                root,
                self.surface,
                self.fonts,
                scroll.y,
                scroll.x,
                chrome_y,      // clip_top: content starts below chrome
                win_h,         // clip_bottom: window bottom
                image_cache,
            );
        }

        // 4. Present
        self.surface.present();
    }
};
```

**Important:** The existing `painter.paint()` takes `*Surface` (libnsfb). During migration with the compile-time backend switch, `Surface` will be either the old or new type. To make this work, the new `XcbSurface` must provide the same drawing methods called by `painter.paint()` (`fillRect`, `blitGlyph8`, etc.). Additionally, add a no-op `argbToColour` method to XcbSurface that returns the color unchanged (XCB pixel buffer is native ARGB, unlike libnsfb which may swap bytes):

```zig
// Add to XcbSurface for API compatibility during migration
pub fn argbToColour(colour: u32) u32 { return colour; }
```

- [ ] **Step 2: Commit**

```bash
git add src/render/pipeline.zig
git commit -m "feat: add render pipeline orchestrator"
```

---

## Chunk 4: Chrome UI (Tasks 9-12)

### Task 9: Tab Bar Component

**Files:**
- Create: `src/ui/tab_bar.zig`
- Read: `src/ui/chrome.zig:124-232` (current tab painting)
- Read: `src/ui/tabs.zig` (tab state)

- [ ] **Step 1: Write tab_bar.zig**

Extract tab bar rendering from chrome.zig into a standalone component. Use theme constants. Add responsive sizing support.

The tab bar should:
- Paint tab backgrounds with active/inactive distinction
- Render tab titles (truncated to fit)
- Close button per tab (X)
- New tab button (+) at the end
- Return `TabAction` from hit test

```zig
// src/ui/tab_bar.zig
const std = @import("std");
const coords = @import("../coords.zig");
const theme = @import("theme.zig").theme;

pub const TabAction = union(enum) {
    none: void,
    switch_tab: usize,
    close_tab: usize,
    new_tab: void,
};

pub const TabInfo = struct {
    title: []const u8,
    is_active: bool,
};

pub const TabBar = struct {
    height: f32,
    scroll_offset: f32 = 0,

    /// `anytype` for surface during migration (supports both NsfbSurface and XcbSurface).
    /// Replace with `*XcbSurface` in Task 17 cleanup.
    pub fn paint(self: *TabBar, surface: anytype, tabs: []const TabInfo, width: u32) void {
        const y: i32 = 0;
        const h: u32 = @intFromFloat(self.height);

        // Background
        surface.fillRect(0, y, width, h, theme.mantle);

        // Draw tabs
        var x_offset: i32 = 4;
        const tab_width: i32 = @min(180, @as(i32, @intCast(width)) / @max(1, @as(i32, @intCast(tabs.len + 1))));

        for (tabs, 0..) |tab, _| {
            const bg = if (tab.is_active) theme.tab_active else theme.tab_inactive;
            surface.fillRect(x_offset, y + 2, @intCast(tab_width - 2), h - 2, bg);
            // Title text would be rendered here via font system
            // Close button area: right 16px of tab
            x_offset += tab_width;
        }

        // New tab button (+)
        surface.fillRect(x_offset + 2, y + 4, h - 8, h - 8, theme.surface1);

        // Bottom border
        surface.fillRect(0, @intCast(h - 1), width, 1, theme.border);
    }

    pub fn hitTest(self: *TabBar, pos: coords.ScreenPos, tab_count: usize, window_width: u32) TabAction {
        if (pos.y < 0 or pos.y >= self.height) return .{ .none = {} };

        const tab_width: f32 = @min(180, @as(f32, @floatFromInt(window_width)) / @as(f32, @floatFromInt(@max(1, tab_count + 1))));

        const tab_index: usize = @intFromFloat(pos.x / tab_width);

        if (tab_index >= tab_count) {
            // New tab button area
            return .{ .new_tab = {} };
        }

        // Check close button (right 16px of tab)
        const tab_right = @as(f32, @floatFromInt(tab_index + 1)) * tab_width;
        if (pos.x > tab_right - 18) {
            return .{ .close_tab = tab_index };
        }

        return .{ .switch_tab = tab_index };
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/tab_bar.zig
git commit -m "feat: add tab bar component with hit testing"
```

---

### Task 10: URL Bar Component

**Files:**
- Create: `src/ui/url_bar.zig`
- Read: `src/ui/chrome.zig:82-122` (current URL bar painting)
- Read: `src/ui/input.zig` (TextInput)

- [ ] **Step 1: Write url_bar.zig**

```zig
// src/ui/url_bar.zig
const std = @import("std");
const coords = @import("../coords.zig");
const theme = @import("theme.zig").theme;
const TextInput = @import("input.zig").TextInput;

pub const UrlBarAction = union(enum) {
    none: void,
    navigate: []const u8,
    focus: void,
};

pub const UrlBar = struct {
    input: TextInput,
    y_offset: f32,  // top of URL bar in screen coords
    height: f32,
    focused: bool = false,

    pub fn paint(self: *UrlBar, surface: anytype, width: u32) void {
        const y: i32 = @intFromFloat(self.y_offset);
        const h: u32 = @intFromFloat(self.height);

        // Background
        surface.fillRect(0, y, width, h, theme.url_bar_bg);

        // Input field area (with margin)
        const margin: i32 = 4;
        const input_w = @as(u32, @intCast(@as(i32, @intCast(width)) - margin * 2));
        surface.fillRect(margin, y + 2, input_w, h - 4, theme.base);

        // Border if focused
        if (self.focused) {
            surface.fillRect(margin, y + 2, input_w, 1, theme.blue);
            surface.fillRect(margin, @intCast(@as(i32, @intCast(h)) + y - 3), input_w, 1, theme.blue);
        }

        // Text and cursor rendered via font system
        // Bottom border
        surface.fillRect(0, y + @as(i32, @intCast(h)) - 1, width, 1, theme.border);
    }

    pub fn hitTest(self: *UrlBar, pos: coords.ScreenPos) bool {
        return pos.y >= self.y_offset and pos.y < self.y_offset + self.height;
    }

    pub fn setText(self: *UrlBar, text: []const u8) void {
        self.input.setText(text);
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/url_bar.zig
git commit -m "feat: add URL bar component"
```

---

### Task 11: Status Bar Component

**Files:**
- Create: `src/ui/status_bar.zig`

- [ ] **Step 1: Write status_bar.zig**

```zig
// src/ui/status_bar.zig
const std = @import("std");
const theme = @import("theme.zig").theme;

pub const StatusBar = struct {
    height: f32,
    text: []const u8 = "Ready",
    hover_url: ?[]const u8 = null,

    pub fn paint(self: *StatusBar, surface: anytype, window_width: u32, window_height: u32) void {
        const y: i32 = @intCast(window_height - @as(u32, @intFromFloat(self.height)));
        const h: u32 = @intFromFloat(self.height);

        // Background
        surface.fillRect(0, y, window_width, h, theme.status_bar_bg);

        // Top border
        surface.fillRect(0, y, window_width, 1, theme.surface1);

        // Text rendered via font system
        // Left: hover_url or status text
        // Right: could show page load progress
    }

    pub fn setStatus(self: *StatusBar, text: []const u8) void {
        self.text = text;
    }

    pub fn setHoverUrl(self: *StatusBar, url: ?[]const u8) void {
        self.hover_url = url;
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/ui/status_bar.zig
git commit -m "feat: add status bar component"
```

---

### Task 12: Chrome Coordinator Rewrite

**Files:**
- Modify: `src/ui/chrome.zig`
- Read: current `src/ui/chrome.zig` (295 LOC)

- [ ] **Step 1: Rewrite chrome.zig as coordinator**

```zig
// src/ui/chrome.zig — rewritten as coordinator
const std = @import("std");
const coords = @import("../coords.zig");
const TabBar = @import("tab_bar.zig").TabBar;
const TabAction = @import("tab_bar.zig").TabAction;
const TabInfo = @import("tab_bar.zig").TabInfo;
const UrlBar = @import("url_bar.zig").UrlBar;
const StatusBar = @import("status_bar.zig").StatusBar;
const TextInput = @import("input.zig").TextInput;

pub const ChromeAction = union(enum) {
    navigate: []const u8,
    new_tab: void,
    close_tab: usize,
    switch_tab: usize,
    go_back: void,
    go_forward: void,
    focus_url: void,
};

pub const Chrome = struct {
    tab_bar: TabBar,
    url_bar: UrlBar,
    status_bar: StatusBar,

    pub fn init(allocator: std.mem.Allocator, window_width: u32, window_height: u32) Chrome {
        const m = chromeMetrics(window_width, window_height);
        return .{
            .tab_bar = .{ .height = m.tab_height },
            .url_bar = .{
                .input = TextInput.init(allocator),
                .y_offset = m.tab_height,
                .height = m.url_height,
            },
            .status_bar = .{ .height = m.status_height },
        };
    }

    pub fn totalHeight(self: *const Chrome) f32 {
        return self.tab_bar.height + self.url_bar.height;
    }

    pub fn paint(self: *Chrome, surface: anytype, tabs: []const TabInfo, width: u32, height: u32) void {
        self.tab_bar.paint(surface, tabs, width);
        self.url_bar.paint(surface, width);
        self.status_bar.paint(surface, width, height);
    }

    pub fn handleClick(self: *Chrome, pos: coords.ScreenPos, tab_count: usize, window_width: u32) ?ChromeAction {
        // Tab bar
        const tab_action = self.tab_bar.hitTest(pos, tab_count, window_width);
        switch (tab_action) {
            .switch_tab => |idx| return .{ .switch_tab = idx },
            .close_tab => |idx| return .{ .close_tab = idx },
            .new_tab => return .{ .new_tab = {} },
            .none => {},
        }

        // URL bar
        if (self.url_bar.hitTest(pos)) {
            self.url_bar.focused = true;
            return .{ .focus_url = {} };
        }

        return null;
    }

    pub fn isInChrome(self: *const Chrome, pos: coords.ScreenPos) bool {
        return pos.y < self.totalHeight();
    }

    fn chromeMetrics(window_width: u32, _: u32) struct {
        tab_height: f32,
        url_height: f32,
        status_height: f32,
        font_size: f32,
    } {
        const override = std.posix.getenv("SUZUME_CHROME_SIZE");
        const compact = if (override) |v|
            std.mem.eql(u8, v, "compact")
        else
            window_width <= 800;

        if (compact) {
            return .{ .tab_height = 22, .url_height = 28, .status_height = 18, .font_size = 12 };
        } else {
            return .{ .tab_height = 28, .url_height = 36, .status_height = 24, .font_size = 14 };
        }
    }
};
```

- [ ] **Step 2: Build to verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/ui/chrome.zig
git commit -m "refactor: rewrite chrome.zig as coordinator using tab_bar/url_bar/status_bar"
```

---

## Chunk 5: Integration + main.zig Decomposition (Tasks 13-16)

### Task 13: Input Handlers

**Files:**
- Create: `src/input/click.zig`
- Create: `src/input/keyboard.zig`
- Create: `src/input/mouse.zig`
- Read: `src/main.zig:2668-2870` (handleClick)
- Read: `src/main.zig:1625-1920` (keyboard handling)

These files extract logic from main.zig. Each takes `*BrowserContext` and operates on it.

- [ ] **Step 1: Write click.zig**

Extract click handling logic. Uses unified `hitTest` and delegates to Chrome or page content:

```zig
// src/input/click.zig
const std = @import("std");
const coords = @import("../coords.zig");
const BrowserContext = @import("../browser.zig").BrowserContext;
const hit_test = @import("../hit_test.zig");
const Chrome = @import("../ui/chrome.zig").Chrome;

pub fn handleClick(ctx: *BrowserContext, chrome: *Chrome, pos: coords.ScreenPos) bool {
    // 1. Chrome click?
    if (chrome.isInChrome(pos)) {
        if (chrome.handleClick(pos, ctx.pages.items.len, ctx.surface.width)) |action| {
            return executeChomeAction(ctx, action);
        }
        return false;
    }

    // 2. Content click
    const page = ctx.activePage() orelse return false;
    const root = page.root_box orelse return false;
    const layout_pos = coords.screenToLayout(pos, chrome.totalHeight(), ctx.scroll);

    // 3. Unified hit test
    const result = hit_test.hitTest(root, layout_pos);

    // 4. JS event dispatch (mousedown → mouseup → click)
    // If preventDefault() called, skip default actions
    // (integrate with existing events.zig dispatch)

    // 5. Default actions (if not prevented)
    if (result.form_element != null) {
        // Focus form element
        ctx.focused_input = if (result.form_element) |fe| fe.lxb_node else null;
        ctx.needs_repaint = true;
        return false;
    }

    if (result.link_url) |href| {
        // Navigate
        _ = href;
        // navigation.navigate(ctx, href);
        ctx.needs_repaint = true;
        return true;
    }

    // Unfocus if clicked elsewhere
    ctx.focused_input = null;
    return false;
}

fn executeChomeAction(ctx: *BrowserContext, action: Chrome.ChromeAction) bool {
    switch (action) {
        .new_tab => { /* add new tab */ },
        .close_tab => |idx| { _ = idx; /* close tab */ },
        .switch_tab => |idx| { ctx.active_tab = idx; ctx.needs_repaint = true; },
        .navigate => |url| { _ = url; /* navigate */ },
        .go_back => { /* history back */ },
        .go_forward => { /* history forward */ },
        .focus_url => {},
    }
    return false;
}
```

- [ ] **Step 2: Write keyboard.zig**

```zig
// src/input/keyboard.zig
const std = @import("std");
const BrowserContext = @import("../browser.zig").BrowserContext;
const EventLoop = @import("../event_loop.zig");
const Chrome = @import("../ui/chrome.zig").Chrome;

pub fn handleKeyDown(ctx: *BrowserContext, chrome: *Chrome, key: EventLoop.KeyEvent) bool {
    // Ctrl+L: focus URL bar
    if (key.ctrlHeld() and key.keysym == 'l') {
        chrome.url_bar.focused = true;
        ctx.needs_repaint = true;
        return true;
    }

    // Ctrl+T: new tab
    if (key.ctrlHeld() and key.keysym == 't') {
        // new tab logic
        return true;
    }

    // Ctrl+W: close tab
    if (key.ctrlHeld() and key.keysym == 'w') {
        // close tab logic
        return true;
    }

    // Ctrl+Q: quit
    if (key.ctrlHeld() and key.keysym == 'q') {
        ctx.running = false;
        return true;
    }

    // URL bar focused: send to input
    if (chrome.url_bar.focused) {
        // Forward to TextInput
        return true;
    }

    // Page content keyboard events
    // Forward to JS runtime
    return false;
}
```

- [ ] **Step 3: Write mouse.zig**

```zig
// src/input/mouse.zig
const std = @import("std");
const coords = @import("../coords.zig");
const BrowserContext = @import("../browser.zig").BrowserContext;
const hit_test = @import("../hit_test.zig");
const Chrome = @import("../ui/chrome.zig").Chrome;
const XcbSurface = @import("../platform/xcb_surface.zig").XcbSurface;
const EventLoop = @import("../event_loop.zig");

pub fn handleMouseMove(ctx: *BrowserContext, chrome: *Chrome, pos: coords.ScreenPos) void {
    // Update cursor shape
    if (chrome.isInChrome(pos)) {
        if (chrome.url_bar.hitTest(pos)) {
            ctx.surface.setCursor(.text);
        } else {
            ctx.surface.setCursor(.arrow);
        }
        chrome.status_bar.setHoverUrl(null);
        return;
    }

    // Content area: hit test for hover
    const page = ctx.activePage() orelse return;
    const root = page.root_box orelse return;
    const layout_pos = coords.screenToLayout(pos, chrome.totalHeight(), ctx.scroll);
    const result = hit_test.hitTest(root, layout_pos);

    if (result.link_url != null) {
        ctx.surface.setCursor(.pointer);
        chrome.status_bar.setHoverUrl(result.link_url);
    } else if (result.form_element != null) {
        ctx.surface.setCursor(.text);
        chrome.status_bar.setHoverUrl(null);
    } else {
        ctx.surface.setCursor(.arrow);
        chrome.status_bar.setHoverUrl(null);
    }
}

pub fn handleScroll(ctx: *BrowserContext, _: coords.ScreenPos, delta: EventLoop.ScrollDelta) void {
    ctx.scroll.y = @max(0, ctx.scroll.y + delta.dy);
    ctx.needs_repaint = true;
}
```

- [ ] **Step 4: Commit**

```bash
git add src/input/click.zig src/input/keyboard.zig src/input/mouse.zig
git commit -m "feat: extract click/keyboard/mouse handlers from main.zig"
```

---

### Task 14: Navigation Module

**Files:**
- Create: `src/navigation.zig`
- Read: `src/main.zig` (URL resolution, history management)
- Read: `src/core/url_utils.zig`

- [ ] **Step 1: Write navigation.zig**

Extract URL resolution, history push/pop, and page loading orchestration:

```zig
// src/navigation.zig
const std = @import("std");
const BrowserContext = @import("browser.zig").BrowserContext;
const url_utils = @import("core/url_utils.zig");

pub const History = struct {
    entries: std.ArrayList([]const u8),
    position: usize = 0,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .entries = std.ArrayList([]const u8).init(allocator) };
    }

    pub fn push(self: *History, url: []const u8) !void {
        // Truncate forward history
        while (self.entries.items.len > self.position + 1) {
            const old = self.entries.pop();
            self.entries.allocator.free(old);
        }
        try self.entries.append(try self.entries.allocator.dupe(u8, url));
        self.position = self.entries.items.len - 1;
    }

    pub fn back(self: *History) ?[]const u8 {
        if (self.position == 0) return null;
        self.position -= 1;
        return self.entries.items[self.position];
    }

    pub fn forward(self: *History) ?[]const u8 {
        if (self.position + 1 >= self.entries.items.len) return null;
        self.position += 1;
        return self.entries.items[self.position];
    }

    pub fn current(self: *const History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.position];
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.entries.allocator.free(entry);
        }
        self.entries.deinit();
    }
};

pub fn resolveUrl(allocator: std.mem.Allocator, base: []const u8, href: []const u8) ![]const u8 {
    // Delegate to existing url_utils or implement resolution
    _ = allocator;
    _ = base;
    _ = href;
    // TODO: wire up to existing resolveUrl in main.zig
    return error.NotImplemented;
}
```

- [ ] **Step 2: Commit**

```bash
git add src/navigation.zig
git commit -m "feat: add navigation module with History struct"
```

---

### Task 15: Compile-Time Backend Switch

**Files:**
- Modify: `src/main.zig` (add compile-time switch)
- Modify: `build.zig` (add build option)

This task enables the XCB surface alongside libnsfb for A/B testing before full switchover.

- [ ] **Step 1: Add build option in build.zig**

After the existing options, add:

```zig
const use_xcb = b.option(bool, "xcb", "Use XCB surface instead of libnsfb") orelse false;
```

Pass to exe as a build option:

```zig
const options = b.addOptions();
options.addOption(bool, "use_xcb", use_xcb);
exe.addOptions("build_options", options);
```

- [ ] **Step 2: Add compile-time surface selection in main.zig**

At the top of main.zig, add:

```zig
const build_options = @import("build_options");
const Surface = if (build_options.use_xcb)
    @import("platform/xcb_surface.zig").XcbSurface
else
    @import("paint/surface.zig").Surface;
```

- [ ] **Step 3: Build with both backends**

Run: `zig build` (libnsfb, should work as before)
Run: `zig build -Dxcb=true 2>&1 | head -20` (XCB, verify compiles)

- [ ] **Step 4: Commit**

```bash
git add build.zig src/main.zig
git commit -m "feat: add compile-time backend switch (libnsfb/XCB)"
```

---

### Task 16: Wire It All Together — Slim main.zig

**Files:**
- Modify: `src/main.zig` (major rewrite to use new modules)
- Modify: `src/paint/painter.zig` (remove old hitTest functions)

This is the final integration task. It rewires main.zig to use:
- `BrowserContext` instead of scattered state variables
- `EventLoop` instead of inline event polling
- `Chrome` coordinator instead of direct chrome calls
- Unified `hitTest` instead of dual hitTestNode/hitTestLink
- `RenderPipeline` for paint orchestration

- [ ] **Step 1: Remove old hitTestNode and hitTestLink from painter.zig**

Delete `hitTestNode` (lines ~1271-1308) and `hitTestLink` (lines ~1311-1357) from `src/paint/painter.zig`. These are replaced by `src/hit_test.zig`.

- [ ] **Step 2: Integrate unified hitTest into main.zig**

Replace all hitTestNode/hitTestLink calls in `handleClick` (~line 2737):

```zig
// OLD
const hit_link = painter_mod.hitTestLink(current_root, layout_x, layout_y);
const hit_node = painter_mod.hitTestNode(current_root, layout_x, layout_y);
```

```zig
// NEW
const hit_test_mod = @import("hit_test.zig");
const layout_pos = coords.screenToLayout(
    coords.ScreenPos.fromInt(mx, my),
    @floatFromInt(chrome.content_y),
    .{ .x = scroll_x.*, .y = scroll_y.* },
);
const hit_result = hit_test_mod.hitTest(current_root, layout_pos);
```

**Caller adaptation:** Existing code uses raw `*lxb.lxb_dom_node_t` pointers. Access via:
```zig
// Where you previously had: const hn: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(np));
// Now use:
const hn = if (hit_result.dom_node) |dn| dn.lxb_node else null;
// For link URL:
const link_href = hit_result.link_url;  // was: hit_link
// For form elements:
const form_node = if (hit_result.form_element) |fe| fe.lxb_node else null;
```

Also update hover handler (~line 2362) to use `hitTest` instead of `hitTestNode`.

- [ ] **Step 2a: Separate default actions from click handler**

This is the core fix for the link-click bug. Move default actions out of main.zig's `handleClick` into a post-dispatch pattern:

In `handleClick`, after JS event dispatch (`clickJsMouseSequencePrevented`), check whether preventDefault was called. If not, execute default actions based on `hit_result`:

```zig
// After JS dispatch:
if (click_prevented) return false;

// Default actions (only if JS didn't preventDefault)
if (hit_result.link_url) |href| {
    // Navigate
    const resolved = resolveUrl(allocator, base, href) catch return false;
    // ... navigation logic
    return true;
}
if (hit_result.form_element) |fe| {
    // Focus form element
    focused_input_node.* = fe.lxb_node;
    // ... form focus logic
    return false;
}
```

This replaces the current split where `hitTestLink` and `hitTestNode` are called separately and can disagree.

- [ ] **Step 3: Build and test**

Run: `zig build`
Run: `./zig-out/bin/suzume` — verify links work, hover cursor changes, form elements focus

- [ ] **Step 4: Commit**

```bash
git add src/main.zig src/paint/painter.zig
git commit -m "refactor: integrate unified hitTest, remove old hitTestNode/hitTestLink"
```

---

## Chunk 6: Cleanup (Tasks 17-18)

### Task 17: Full XCB Switchover

**Files:**
- Modify: `build.zig` (remove libnsfb, default to XCB)
- Modify: `src/main.zig` (remove compile-time switch)
- Delete: `src/paint/surface.zig`
- Delete: `src/bindings/nsfb.zig`
- Delete: `src/nsfb_surface_init.c`

Only do this after XCB backend is validated!

- [ ] **Step 1: Make XCB the default, remove libnsfb code**

In build.zig:
- Remove `const build_libnsfb = @import("build_libnsfb.zig");`
- Remove `const libnsfb = build_libnsfb.buildLibNsfb(...)` 
- Remove `exe.linkLibrary(libnsfb)`
- Remove `exe.addIncludePath(b.path("deps/libnsfb/include"))`
- Remove nsfb_surface_init.c source file
- Add `exe.linkSystemLibrary("xcb-shm")` and `exe.linkSystemLibrary("xcb-cursor")` if not already

In main.zig:
- Remove build_options import and compile-time switch
- Import XcbSurface directly

- [ ] **Step 2: Delete removed files**

```bash
rm src/paint/surface.zig src/bindings/nsfb.zig src/nsfb_surface_init.c build_libnsfb.zig
rm -rf deps/libnsfb/
```

- [ ] **Step 3: Build and full test**

Run: `zig build`
Run: `./zig-out/bin/suzume` — full regression test

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove libnsfb dependency, XCB is now the only backend"
```

---

### Task 18: Final Verification

- [ ] **Step 1: Verify link clicks work**

Open `https://example.com`, click "More information..." link. Should navigate.

- [ ] **Step 2: Verify form input**

Navigate to a page with text inputs. Click to focus, type text.

- [ ] **Step 3: Verify keyboard shortcuts**

- Ctrl+L → focus URL bar
- Ctrl+T → new tab
- Ctrl+W → close tab
- Ctrl+Q → quit

- [ ] **Step 4: Verify responsive Chrome**

- Desktop: tab/URL/status bars at normal size
- `SUZUME_CHROME_SIZE=compact ./zig-out/bin/suzume` → compact sizes

- [ ] **Step 5: Verify hover and cursor**

- Mouse over link → pointer cursor + URL in status bar
- Mouse over input → text cursor
- Mouse elsewhere → arrow cursor

- [ ] **Step 6: WPT regression check**

Run existing WPT test suite, verify scores don't regress.
