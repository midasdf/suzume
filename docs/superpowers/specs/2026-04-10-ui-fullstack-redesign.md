# suzume UI Full-Stack Redesign

**Date:** 2026-04-10
**Scope:** Platform layer, event handling, hit testing, coordinate system, Chrome UI, render pipeline, main.zig decomposition

## Motivation

The current UI architecture has accumulated technical debt from rapid iteration:

- **main.zig (3,424 LOC)** is a monolithic file handling events, painting, navigation, and initialization
- **hitTestNode vs hitTestLink divergence** — two hit-test functions with incompatible traversal logic cause link clicks to silently fail
- **No coordinate type safety** — screen, content, and layout coordinates are all `f32`, leading to subtle scroll/offset bugs
- **libnsfb dependency** — limits rendering capabilities and adds an unnecessary abstraction over X11
- **Default actions coupled to event dispatch** — link navigation and form submission logic is interleaved with event handling in main.zig instead of being cleanly separated as post-dispatch default actions

Note: `js/events.zig` already implements W3C 3-phase event dispatch (capture/at-target/bubble). The issue is that default actions (navigation, form submit) are handled in main.zig's click handler rather than being triggered after event dispatch completes.

This redesign replaces the platform layer, unifies hit testing, adds type-safe coordinates, splits main.zig into focused modules, and refreshes Chrome UI rendering.

## Target Devices

Responsive design supporting both:
- **HackberryPi Zero**: 720×720 HyperPixel, 512MB RAM, RPi Zero 2W
- **Desktop**: 1080p+ displays, standard memory

Chrome UI scales with screen resolution. Layout engine adapts to viewport.

---

## 1. Platform Layer: libnsfb → XCB

### Why XCB over Xlib
- Async, non-blocking API
- Lower overhead than Xlib
- Direct access to SHM extension for zero-copy display
- Already available on both target platforms

### Surface Replacement

Remove `src/paint/surface.zig` (518 LOC, libnsfb wrapper). Replace with:

**`src/platform/xcb_surface.zig`** (~300 LOC)

```zig
pub const XcbSurface = struct {
    connection: *xcb.Connection,
    xlib_display: *x11.Display,  // Xlib owns the connection (for XIM coexistence)
    window: xcb.Window,
    gc: xcb.GContext,
    shm_seg: ?xcb.ShmSeg,       // null if MIT-SHM unavailable (SSH X-forwarding)
    use_shm: bool,
    pixels: []u32,               // ARGB pixel buffer (mmap'd SHM or heap-allocated)
    width: u32,
    height: u32,
    wm_delete_atom: xcb.Atom,    // WM_DELETE_WINDOW for graceful close
    
    pub fn init(width: u32, height: u32, title: []const u8) !XcbSurface
    pub fn deinit(self: *XcbSurface) void
    pub fn present(self: *XcbSurface) void
    pub fn resize(self: *XcbSurface, w: u32, h: u32) !void
    
    // Primitive drawing (operates on pixel buffer directly)
    pub fn fillRect(self: *XcbSurface, x: i32, y: i32, w: u32, h: u32, color: u32) void
    pub fn blitGlyph(self: *XcbSurface, glyph: GlyphBitmap, x: i32, y: i32, color: u32) void
    pub fn blitImage(self: *XcbSurface, img: ImageData, dst: Rect) void
    pub fn setClip(self: *XcbSurface, rect: ?Rect) void
};
```

### SHM Fallback

At init time, query MIT-SHM extension via `xcb_get_extension_data`. If unavailable (e.g. SSH X-forwarding), fall back to `xcb_put_image` with heap-allocated pixel buffer.

```zig
pub fn present(self: *XcbSurface) void {
    if (self.use_shm) {
        // xcb_shm_put_image — zero-copy, pixels already in shared segment
        xcb.shm_put_image(self.connection, self.window, self.gc, ...);
    } else {
        // xcb_put_image — copy pixel buffer over the X connection (slower but always works)
        xcb.put_image(self.connection, .z_pixmap, self.window, self.gc, ...);
    }
    xcb.flush(self.connection);
}
```

### XIM Integration

Keep existing `xim_helper.c` — it uses Xlib for XIM which is standard.

**Xlib/XCB initialization order** (critical for coexistence):

```
1. XOpenDisplay(NULL)                              — Xlib opens the connection
2. XSetEventQueueOwner(display, XCBOwnsEventQueue)  — XCB handles events
3. XGetXCBConnection(display)                       — get XCB handle from Xlib
4. xim_init(window_id)                              — XIM uses the same Xlib display
```

`xcb_surface.zig` accepts an existing Xlib Display pointer rather than calling `xcb_connect()` directly. This ensures XIM and XCB share the same connection.

**`src/platform/xim.zig`** — Zig wrapper around xim_helper.c (unchanged from current).

### Cursor Shapes

Use XCB cursor extension (`xcb_cursor`) instead of libnsfb's cursor functions.

```zig
pub const CursorShape = enum { arrow, pointer, text };
pub fn setCursor(self: *XcbSurface, shape: CursorShape) void;
```

---

## 2. Coordinate System: Type-Safe Positions

### Types

**`src/coords.zig`** (~60 LOC)

```zig
/// Position in X11 window (0,0 = top-left of window)
pub const ScreenPos = struct {
    x: f32,
    y: f32,
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
    x: f32,
    y: f32,
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
```

### Usage

All functions declare which coordinate space they operate in. Passing wrong type = compile error.

- `hitTest(root: *Box, pos: LayoutPos) HitResult` — layout coords
- `chrome.hitTestTabBar(pos: ScreenPos) TabAction` — screen coords
- `paintBoxTree(surface, root, viewport: ContentPos, ...)` — content coords

---

## 3. Unified Hit Testing

### HitResult

**Defined in `src/hit_test.zig`** (~150 LOC)

```zig
pub const HitResult = struct {
    /// Deepest DOM node at the hit point
    dom_node: ?*DomNode = null,
    /// Nearest ancestor <a href> URL (walked up from dom_node)
    link_url: ?[]const u8 = null,
    /// The Box that was hit
    box: ?*const Box = null,
    /// Nearest form element (input/textarea/button/select)
    form_element: ?*DomNode = null,
};

pub fn hitTest(box: *const Box, pos: LayoutPos) HitResult;
```

### Algorithm

Single recursive traversal, depth-first (children in reverse z-order):

1. For `block`, `inline_box`:
   - **Bounds pre-check**: compute margin box, add tolerance for text-align center/right. If point is outside, return empty HitResult (prune subtree — critical for RPi performance)
   - Recurse into children (reverse order)
   - If a child returned a result, return it (child wins over parent)
   - If no child hit, check self bounds → return self if hit
2. For `anonymous_block`:
   - **Skip bounds pre-check** (children may overflow the anonymous block's rect)
   - Recurse into children (reverse order)
   - If a child returned a result, return it
3. For `inline_text`:
   - Check each line box for point containment
   - If hit, return this box's info
4. For `replaced`:
   - Check content rect bounds

After finding the deepest box:
- Walk DOM ancestors upward from `box.dom_node` to populate `link_url` (first `<a href>`) and `form_element` (first `input`/`textarea`/`button`/`select`)

This eliminates the hitTestNode vs hitTestLink divergence by doing one traversal and one ancestor walk.

---

## 4. Event Architecture

### Overview

Two independent event systems:

1. **Platform events** (X11 → Zig) — callback-based, for Chrome UI and page interaction
2. **DOM events** (JS layer) — capture/bubble phases, for web content

### Platform Event Dispatch

**`src/event_loop.zig`** (~300 LOC)

```zig
/// All callbacks receive a context pointer so handlers can access their owning struct's state.
pub const EventHandler = struct {
    ctx: *anyopaque,
    onMouseDown: ?*const fn (*anyopaque, ScreenPos, MouseButton) bool = null,
    onMouseUp: ?*const fn (*anyopaque, ScreenPos, MouseButton) bool = null,
    onClick: ?*const fn (*anyopaque, ScreenPos, MouseButton) bool = null,
    onMouseMove: ?*const fn (*anyopaque, ScreenPos) void = null,
    onScroll: ?*const fn (*anyopaque, ScreenPos, ScrollDelta) void = null,
    onKeyDown: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onKeyUp: ?*const fn (*anyopaque, KeyEvent) bool = null,
    onResize: ?*const fn (*anyopaque, u32, u32) void = null,
};

pub const EventLoop = struct {
    surface: *XcbSurface,
    handlers: std.BoundedArray(EventHandler, 8),  // ordered by priority
    running: bool,

    pub fn registerHandler(self: *EventLoop, handler: EventHandler) void;
    pub fn run(self: *EventLoop) void;  // blocking main loop
    pub fn requestQuit(self: *EventLoop) void;
};
```

Handler return value: `true` = event consumed, stop dispatching. `false` = pass to next handler.

The event loop handles these XCB protocol concerns:
- **WM_DELETE_WINDOW**: registered via `xcb_intern_atom` at init. `XCB_CLIENT_MESSAGE` with this atom calls `requestQuit()`
- **ConfigureNotify**: calls `onResize` handler with new dimensions
- **Connection errors**: checks `xcb_connection_has_error()` each iteration, exits gracefully

Priority order:
1. Modal dialogs (if any)
2. Chrome UI (tab bar, URL bar)
3. Page content (click/scroll/keyboard)

### DOM Event Phases (existing)

`src/js/events.zig` (2,729 LOC) already implements full W3C 3-phase dispatch:
- Capture phase (top-down), at-target, bubble phase (bottom-up)
- `ListenerRecord` stores capture flag, `callListenersOnNode` filters by phase
- `dispatchMouseEvent` and `dispatchKeyboardEvent` build ancestor paths

**No reimplementation needed.** The integration task is:
1. Verify existing capture/bubble dispatch works correctly with the new unified `hitTest` (which provides `dom_node` for event targeting)
2. Move default action execution out of `main.zig`'s click handler into a clean post-dispatch hook (~50 LOC change in events.zig)

### Default Actions

Separate default actions from event dispatch. After event completes without preventDefault:

| Element | Action |
|---------|--------|
| `<a href>` | Navigate to URL |
| `<input type=submit>` | Submit form |
| `<button>` | Submit form (if in form) |
| `<input type=text>` | Focus + show cursor |
| `<textarea>` | Focus + show cursor |

---

## 5. Chrome UI Redesign

### Components

**`src/ui/chrome.zig`** (~300 LOC) — coordinator

```zig
pub const Chrome = struct {
    tab_bar: TabBar,
    url_bar: UrlBar,
    status_bar: StatusBar,
    
    pub fn height(self: Chrome) f32;  // total chrome height (responsive)
    pub fn paint(self: *Chrome, surface: *XcbSurface) void;
    pub fn handleClick(self: *Chrome, pos: ScreenPos) ?ChromeAction;
    pub fn handleKey(self: *Chrome, key: KeyEvent) bool;
};

pub const ChromeAction = union(enum) {
    navigate: []const u8,
    new_tab: void,
    close_tab: usize,
    switch_tab: usize,
    go_back: void,
    go_forward: void,
};
```

### Responsive Sizing

```zig
fn chromeMetrics(window_width: u32, window_height: u32) struct {
    tab_height: f32,
    url_height: f32,
    status_height: f32,
    font_size: f32,
} {
    // Override via SUZUME_CHROME_SIZE=compact|desktop (useful when window width
    // is not a reliable proxy for physical screen size, e.g. low-DPI desktop at 800x600)
    const override = std.posix.getenv("SUZUME_CHROME_SIZE");
    const compact = if (override) |v|
        std.mem.eql(u8, v, "compact")
    else
        window_width <= 800;

    if (compact) {
        // HackberryPi: compact
        return .{ .tab_height = 22, .url_height = 28, .status_height = 18, .font_size = 12 };
    } else {
        // Desktop: comfortable
        return .{ .tab_height = 28, .url_height = 36, .status_height = 24, .font_size = 14 };
    }
}
```

### Tab Bar

**`src/ui/tab_bar.zig`** (~120 LOC)

- Horizontal tab strip with scroll if tabs overflow
- Each tab: favicon area + title (truncated) + close button
- Active tab visually distinct (brighter background)
- New tab button (+) at end

### URL Bar

**`src/ui/url_bar.zig`** (~120 LOC)

- Text input with cursor, selection
- Domain highlighted (bold or different color)
- Loading indicator (left side color bar or spinner animation)

### Status Bar

**`src/ui/status_bar.zig`** (~60 LOC)

- Left: hover link URL preview
- Right: page load status, search result count

### Theme

Keep Catppuccin Mocha (current), defined as constants:

```zig
pub const theme = struct {
    pub const bg = 0xFF1E1E2E;
    pub const surface0 = 0xFF313244;
    pub const surface1 = 0xFF45475A;
    pub const text = 0xFFCDD6F4;
    pub const subtext = 0xFFA6ADC8;
    pub const blue = 0xFF89B4FA;
    pub const green = 0xFFA6E3A1;
    pub const red = 0xFFF38BA8;
    pub const link = 0xFF89B4FA;
};
```

---

## 6. Render Pipeline

### Flow

```
DOM mutation detected (dom_dirty flag)
  → buildBoxTree(document, viewport_width)     // layout/tree.zig
  → layoutBoxTree(root_box, viewport)          // layout/block.zig + flex/grid/table
  → page.root_box = root_box

Repaint needed (needs_repaint flag)
  → surface.clear(theme.bg)
  → chrome.paint(surface)
  → paintBoxTree(surface, root_box, content_viewport, scroll)  // render/painter.zig
  → surface.present()                          // XCB SHM PutImage
```

### render/pipeline.zig (~200 LOC)

Orchestrates the full render cycle:

```zig
pub const RenderPipeline = struct {
    surface: *XcbSurface,
    chrome: *Chrome,

    pub fn render(self: *RenderPipeline, page: *Page, scroll: ScrollOffset) void {
        self.surface.clear(theme.bg);
        self.chrome.paint(self.surface);
        if (page.root_box) |root| {
            const viewport = ContentRect{
                .x = 0,
                .y = self.chrome.height(),
                .width = @floatFromInt(self.surface.width),
                .height = @floatFromInt(self.surface.height) - self.chrome.height(),
            };
            paintBoxTree(self.surface, root, viewport, scroll);
        }
        self.surface.present();
    }
};
```

### painter.zig Changes

- Remove `hitTestNode` and `hitTestLink` (moved to `hit_test.zig`)
- `paintBoxTree` takes `ContentRect` viewport + `ScrollOffset` instead of raw floats
- Clip painting to viewport bounds

---

## 7. main.zig Decomposition

### Current: 3,424 LOC monolith

### New Structure

| File | Responsibility | Est. LOC |
|------|---------------|----------|
| `src/browser.zig` | BrowserContext shared state struct | ~80 |
| `src/main.zig` | Initialization, page/tab state, main loop shell | ~200 |
| `src/event_loop.zig` | XCB event polling, handler dispatch | ~300 |
| `src/input/click.zig` | Click handling, HitResult → actions | ~200 |
| `src/input/keyboard.zig` | Keyboard input, shortcuts, XIM | ~200 |
| `src/input/mouse.zig` | Mouse move (hover), scroll | ~150 |
| `src/navigation.zig` | URL resolution, history, page loading | ~300 |
| `src/render/pipeline.zig` | Render orchestration | ~200 |
| `src/ui/chrome.zig` | Chrome coordinator | ~300 |
| `src/coords.zig` | Coordinate types + conversions | ~60 |
| `src/hit_test.zig` | Unified hit testing | ~150 |

**Total: ~2,140 LOC** (down from 3,424 for main.zig alone + 518 for surface.zig + 295 for old chrome.zig = 4,237)

### BrowserContext: Shared State

Replaces the 18-parameter `handleClick` and similar functions. All input/render modules take `*BrowserContext`:

```zig
/// src/browser.zig (~80 LOC)
pub const BrowserContext = struct {
    surface: *XcbSurface,
    chrome: *Chrome,
    pages: std.ArrayList(PageState),
    active_tab: usize,
    scroll: ScrollOffset,
    loader: *Loader,
    history: *History,
    fonts: *FontCache,
    focused_input: ?*lxb.lxb_dom_node_t,
    form_input: *TextInput,
    needs_repaint: bool,
    allocator: std.mem.Allocator,
};
```

`click.zig`, `keyboard.zig`, `mouse.zig`, and `navigation.zig` all receive `*BrowserContext` as their primary parameter instead of 10+ individual arguments.

### Dependency Graph

```
main.zig
  ├── event_loop.zig ← platform/xcb_surface.zig
  ├── render/pipeline.zig ← ui/chrome.zig, paint/painter.zig
  ├── input/click.zig ← hit_test.zig, navigation.zig
  ├── input/keyboard.zig ← platform/xim.zig, ui/url_bar.zig
  ├── input/mouse.zig ← hit_test.zig
  ├── navigation.zig ← net/loader.zig
  └── coords.zig (used everywhere)
```

---

## 8. Migration Strategy

### Phase 1: Foundation
1. Add `coords.zig` (new, no breaking changes)
2. Add `hit_test.zig` with unified `hitTest()` (new, parallel to old)
3. Write tests for `hitTest` with known box trees

### Phase 2: Platform Swap
4. Implement `platform/xcb_surface.zig` with the same public API as current `Surface`
5. Adapt XIM wrapper for XCB coexistence (Xlib init order)
6. Add compile-time backend switch: `const Surface = if (use_xcb) XcbSurface else NsfbSurface;` — allows A/B comparison and easy rollback
7. Validate rendering matches, then remove the switch and NsfbSurface

### Phase 3: Event System
8. Implement `event_loop.zig`
9. Extract `input/click.zig`, `input/keyboard.zig`, `input/mouse.zig` (all take `*BrowserContext`)
10. Wire up callback-based dispatch
11. Verify existing DOM event phases integrate with unified hitTest; move default actions out of click handler (~50 LOC)

### Phase 4: Chrome UI
11. Implement responsive `ui/chrome.zig` + sub-components
12. Replace old chrome drawing

### Phase 5: Pipeline Integration
13. Implement `render/pipeline.zig`
14. Extract `navigation.zig`
15. Slim down `main.zig` to initialization + main loop

### Phase 6: Cleanup
16. Remove libnsfb dependency from build.zig
17. Remove old surface.zig, old hitTestNode/hitTestLink
18. Update tests

---

## 9. Build Changes

### deps to remove
- `libnsfb` (C library, currently in deps/)

### deps to add
- `xcb` — Debian: `libxcb-dev`, Arch: `libxcb`
- `xcb-shm` — SHM extension (part of libxcb)
- `xcb-cursor` — cursor shapes. Debian: `libxcb-cursor-dev`, Arch: `xcb-util-cursor`
- `xcb-keysyms` — key symbol lookup. Debian: `libxcb-keysyms-dev`, Arch: `xcb-util-keysyms`

### build.zig changes
- Remove libnsfb compile step
- Add XCB system library linking: `-lxcb -lxcb-shm -lxcb-cursor -lxcb-keysyms`
- Keep Xlib link for XIM: `-lX11`

---

## 10. Testing Strategy

### Unit Tests
- `hit_test.zig`: construct Box trees manually, verify HitResult for known positions
- `coords.zig`: coordinate conversion round-trips
- `event_loop.zig`: handler registration, priority, consume behavior

### Integration Tests
- Click on `<a>` element → verify navigation triggered
- Click on `<input>` → verify focus
- `preventDefault()` in JS → verify default action skipped
- Resize window → verify Chrome scales correctly

### WPT
- Existing WPT scores must not regress (DOM events already have capture/bubble)
- Unified hitTest should fix interaction-dependent WPT tests that rely on click → navigation
- Default action separation may improve event dispatch spec compliance
