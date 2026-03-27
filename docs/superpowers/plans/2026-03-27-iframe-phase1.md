# iframe Phase 1: FrameState + Global Replacement

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace global singletons (g_document, g_root_box, g_styles) with per-frame FrameState accessed via QuickJS Context opaque pointer, preparing the foundation for iframe support.

**Architecture:** Create a FrameState struct that holds all per-frame state. Attach it to each JSContext via JS_SetContextOpaque. All DOM functions retrieve their document/styles/box from FrameState instead of globals. A fallback ensures zero regression during transition.

**Tech Stack:** Zig, QuickJS-ng (JS_SetContextOpaque/JS_GetContextOpaque), Lexbor

---

## File Structure

| File | Role | Action |
|------|------|--------|
| `src/js/frame_state.zig` | FrameState struct + helpers | **Create** |
| `src/js/dom_api.zig` | Import frame_state, wire up top-level frame | **Modify** |
| `src/js/dom_document.zig` | Replace `api.g_document` → `api.getDocument(c)` | **Modify** |
| `src/js/dom_node.zig` | Replace `api.g_document` → `api.getDocument(c)` | **Modify** |
| `src/js/dom_element.zig` | Replace `api.g_root_box` → `api.getRootBox(c)` | **Modify** |
| `src/js/dom_style.zig` | Replace `api.g_styles` → `api.getStyles(c)` | **Modify** |
| `src/js/dom_serialize.zig` | Replace `api.g_document` → `api.getDocument(c)` | **Modify** |
| `src/js/dom_selector.zig` | No globals used directly | **No change** |
| `src/js/dom_text.zig` | No globals used directly | **No change** |
| `src/main.zig` | Create top-level FrameState, set opaque | **Modify** |

---

### Task 1: Create FrameState struct

**Files:**
- Create: `src/js/frame_state.zig`

- [ ] **Step 1: Create frame_state.zig with FrameState struct**

```zig
// src/js/frame_state.zig
const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const Box = @import("../layout/box.zig").Box;
const cascade_mod = @import("../css/cascade.zig");

pub const MAX_IFRAME_DEPTH = 5;
pub const MAX_IFRAME_COUNT = 10;

pub const ReadyState = enum { loading, interactive, complete };

pub const FrameState = struct {
    document: ?*anyopaque = null,
    root_box: ?*const Box = null,
    styles: ?*const cascade_mod.StyleMap = null,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
    current_url: ?[]const u8 = null,
    parent_frame: ?*FrameState = null,
    ctx: ?*qjs.JSContext = null,
    ready_state: ReadyState = .loading,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    dom_dirty: bool = false,
    depth: u32 = 0,               // Nesting depth (0 = top-level)
};

/// Get FrameState from a JSContext's opaque pointer.
/// Falls back to null if not set.
pub fn getFrameStateFromCtx(ctx: *qjs.JSContext) ?*FrameState {
    const opaque = qjs.JS_GetContextOpaque(ctx);
    if (opaque) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `zig build 2>&1 | tail -3`
Expected: builds (file not yet referenced, but syntax must be valid)

- [ ] **Step 3: Commit**

```bash
git add src/js/frame_state.zig
git commit -m "feat: create FrameState struct for per-frame state management"
```

---

### Task 2: Import FrameState in dom_api.zig + add accessor helpers

**Files:**
- Modify: `src/js/dom_api.zig`

- [ ] **Step 1: Add import and top-level FrameState instance**

In dom_api.zig, add import and global top-level frame:

```zig
pub const frame_state = @import("frame_state.zig");
pub const FrameState = frame_state.FrameState;

/// Top-level frame state (used as fallback during migration)
pub var g_top_frame: FrameState = .{};
```

- [ ] **Step 2: Add getDocument/getRootBox/getStyles helpers**

```zig
/// Get document for current frame (from ctx opaque, fallback to global)
/// NOTE: Falls through to global if FrameState field is null (defensive migration)
pub fn getDocument(ctx: *qjs.JSContext) ?*anyopaque {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.document) |doc| return doc;
    }
    return g_document;
}

/// Get root box for current frame
pub fn getRootBox(ctx: *qjs.JSContext) ?*const Box {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.root_box) |rb| return rb;
    }
    return g_root_box;
}

/// Get styles for current frame
pub fn getStyles(ctx: *qjs.JSContext) ?*const cascade_mod.StyleMap {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.styles) |s| return s;
    }
    return g_styles;
}

/// Get viewport dimensions for current frame
pub fn getViewport(ctx: *qjs.JSContext) struct { w: f32, h: f32 } {
    if (frame_state.getFrameStateFromCtx(ctx)) |fs| {
        if (fs.viewport_width != 0 or fs.viewport_height != 0)
            return .{ .w = fs.viewport_width, .h = fs.viewport_height };
    }
    return .{ .w = g_viewport_width, .h = g_viewport_height };
}
```

- [ ] **Step 3: Build**

Run: `zig build 2>&1 | tail -3`
Expected: clean build

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_api.zig src/js/frame_state.zig
git commit -m "feat: add FrameState accessors with global fallback"
```

---

### Task 3: Wire up top-level FrameState in main.zig

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: After initPageJs, set FrameState on context**

Find `initPageJs()` call in main.zig. After `dom_api.registerDomApis(...)`, add:

```zig
// Set up top-level FrameState
dom_api.g_top_frame = .{
    .document = document_ptr,
    .ctx = js_rt.ctx,
    .viewport_width = @floatFromInt(surface.width),
    .viewport_height = @floatFromInt(surface.height),
    .current_url = base_url_copy,
};
qjs.JS_SetContextOpaque(js_rt.ctx, @ptrCast(&dom_api.g_top_frame));
```

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | tail -3`
Expected: clean build

- [ ] **Step 3: Run WPT smoke test**

Run: `./tests/wpt/run_wpt.sh dom/nodes 2>&1 | tail -6` (in background)
Expected: Pass rate >= 45% (no regression)

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat: wire up top-level FrameState via JS_SetContextOpaque"
```

---

### Task 3.5: Sync global setters to g_top_frame (MUST come before module replacements)

**Files:**
- Modify: `src/js/dom_api.zig`

**Why before Task 4**: setRootBox/setStyles are called repeatedly during relayout. If they don't sync to g_top_frame, the accessor helpers (getDocument/getRootBox/getStyles) will find a valid FrameState but with null fields, returning null instead of falling through to the global. This would cause regressions.

- [ ] **Step 1: Update all setters to sync g_top_frame**

```zig
pub fn setRootBox(root: ?*const Box) void {
    g_root_box = root;
    g_top_frame.root_box = root;
}

pub fn setStyles(styles: ?*const cascade_mod.StyleMap) void {
    g_styles = styles;
    g_top_frame.styles = styles;
}

pub fn setViewport(w: f32, h: f32) void {
    g_viewport_width = w;
    g_viewport_height = h;
    g_top_frame.viewport_width = w;
    g_top_frame.viewport_height = h;
}

pub fn setCurrentUrl(url: ?[]const u8) void {
    g_current_url = url;
    g_top_frame.current_url = url;
}
```

Also in `registerDomApis`:
```zig
g_document = document_ptr;
g_top_frame.document = document_ptr;
```

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git add src/js/dom_api.zig
git commit -m "feat: sync all global setters to g_top_frame"
```

---

### Task 4: Replace g_document in dom_document.zig

**Files:**
- Modify: `src/js/dom_document.zig`

- [ ] **Step 1: Find all g_document references**

Run: `grep -n "api.g_document" src/js/dom_document.zig`

- [ ] **Step 2: Replace each `api.g_document` with `api.getDocument(c)`**

For each function that takes `ctx: ?*qjs.JSContext`, replace:
```zig
// Before:
const doc = api.g_document orelse return quickjs.JS_NULL();
// After:
const doc = api.getDocument(c) orelse return quickjs.JS_NULL();
```

Note: `c` is the unwrapped context (`const c = ctx orelse return ...`).

- [ ] **Step 3: Build**

Run: `zig build 2>&1 | tail -3`
Expected: clean build

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_document.zig
git commit -m "refactor: dom_document uses getDocument(ctx) instead of g_document"
```

---

### Task 5: Replace g_document in dom_node.zig

**Files:**
- Modify: `src/js/dom_node.zig`

- [ ] **Step 1: Replace all `api.g_document` with `api.getDocument(c)`**

Same pattern as Task 4. Functions like `elementCloneNode`, `elementBefore`, `elementAfter` use g_document.

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git add src/js/dom_node.zig
git commit -m "refactor: dom_node uses getDocument(ctx) instead of g_document"
```

---

### Task 6: Replace g_document in dom_serialize.zig

**Files:**
- Modify: `src/js/dom_serialize.zig`

- [ ] **Step 1: Replace all `api.g_document` with `api.getDocument(c)`**

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git add src/js/dom_serialize.zig
git commit -m "refactor: dom_serialize uses getDocument(ctx) instead of g_document"
```

---

### Task 7: Replace g_root_box and g_styles in dom_element.zig and dom_style.zig

**Files:**
- Modify: `src/js/dom_element.zig`
- Modify: `src/js/dom_style.zig`

- [ ] **Step 1: In dom_element.zig, replace `api.g_root_box` with `api.getRootBox(c)`**

The `getBoxForThis` function (or equivalent) uses g_root_box. Replace with getRootBox.

- [ ] **Step 2: In dom_style.zig, replace `api.g_styles` with `api.getStyles(c)` and `api.g_viewport_*` with `api.getViewport(c)`**

- [ ] **Step 3: Build**

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_element.zig src/js/dom_style.zig
git commit -m "refactor: dom_element/dom_style use FrameState accessors"
```

---

### Task 8: Replace remaining globals in dom_api.zig

**Files:**
- Modify: `src/js/dom_api.zig`

- [ ] **Step 1: Replace any remaining g_document/g_root_box/g_styles references in dom_api.zig itself**

Some may exist in registerDomApis or style creation code.

- [ ] **Step 2: Keep g_document/g_root_box/g_styles as pub vars for backward compatibility**

They still need to be set by main.zig for the transition period. The setters (setRootBox, setStyles, etc.) should also update g_top_frame:

```zig
pub fn setRootBox(root: ?*const Box) void {
    g_root_box = root;
    g_top_frame.root_box = root;
}

pub fn setStyles(styles: ?*const cascade_mod.StyleMap) void {
    g_styles = styles;
    g_top_frame.styles = styles;
}
```

- [ ] **Step 3: Build**

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_api.zig
git commit -m "refactor: sync g_top_frame with global setters"
```

---

### Task 9: Full regression test

**Files:** None (test only)

- [ ] **Step 1: Clean build**

```bash
rm -rf zig-out .zig-cache ~/.cache/zig && zig build
```

- [ ] **Step 2: Run WPT dom/nodes**

```bash
./tests/wpt/run_wpt.sh dom/nodes
```

Expected: Pass rate >= 45.5% (2168+ subtests, no regression)

- [ ] **Step 3: Run WPT dom/events**

```bash
./tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events
```

Expected: Pass rate >= 58% (297+ subtests, no regression)

- [ ] **Step 4: Quick smoke test**

```bash
cd /tmp/wpt && DISPLAY=:98 timeout 10 suzume "http://127.0.0.1:9876/dom/nodes/CharacterData-data.html"
```

Expected: 16/16 PASS

- [ ] **Step 5: Push**

```bash
git push origin main
```
