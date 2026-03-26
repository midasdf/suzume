# zt Extreme Throughput Maximization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maximize zt terminal emulator dense ASCII throughput on x86_64/X11, targeting significant improvement over the current 84 MB/s baseline.

**Architecture:** Seven independent optimizations applied sequentially to the existing single-threaded epoll architecture. Three reduce rendering cost (direct cell access, global BG fill, scroll memmove), three reduce parse overhead (PTY buffer, frame limiter tier 3, scrollUp RGB skip), and one simplifies timing code (nanoTimestamp dedup). No structural changes — all optimizations are surgical modifications to existing hot paths.

**Tech Stack:** Zig 0.15+, Linux epoll, XCB (X11 backend), fbdev (framebuffer backend)

**Spec:** `docs/superpowers/specs/2026-03-26-zt-throughput-max-design.md`

---

## File Map

| File | Role | Tasks |
|------|------|-------|
| `zt/src/main.zig` | Event loop, render orchestration, PTY buffer | 1, 2, 3, 4, 5, 7 |
| `zt/src/render.zig` | Per-cell pixel rendering | 5 |
| `zt/src/term.zig` | Cell grid, scroll, dirty tracking, RGB | 6, 7 |
| `zt/build.zig` | Build options | 2 |
| `zt/config.zig` | Comptime config | 2 |
| `zt/src/backend/x11.zig` | XCB double-buffered SHM | 7 |
| `zt/src/backend/fbdev.zig` | Framebuffer backend | 7 |

---

## Chunk 1: Quick Wins (Zero Risk)

### Task 1: Tier 3 Frame Limiter

Add a 4th tier to the adaptive frame rate: >1MB buffered → 5fps (200ms intervals). This gives 3× more parse time during extreme output.

**Files:**
- Modify: `zt/src/main.zig:336-347` (frame limiter calculation)

- [ ] **Step 1: Modify frame limiter to add tier 3**

In `zt/src/main.zig`, replace lines 340-347:

```zig
        const effective_frame_ns: i128 = if (config.frame_min_ns == 0)
            0
        else if (bytes_since_render > 262144)
            @as(i128, config.frame_min_ns) * 8
        else if (bytes_since_render > 65536)
            @as(i128, config.frame_min_ns) * 2
        else
            @as(i128, config.frame_min_ns);
```

With:

```zig
        const effective_frame_ns: i128 = if (config.frame_min_ns == 0)
            0
        else if (bytes_since_render > 1_048_576)
            @as(i128, config.frame_min_ns) * 24
        else if (bytes_since_render > 262_144)
            @as(i128, config.frame_min_ns) * 8
        else if (bytes_since_render > 65_536)
            @as(i128, config.frame_min_ns) * 2
        else
            @as(i128, config.frame_min_ns);
```

- [ ] **Step 2: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS (no behavioral change, only timing)

- [ ] **Step 3: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig
git commit -m "perf: add tier 3 frame limiter (5fps at >1MB buffered)

Reduces render frequency during extreme output bursts.
Tier 3: >1MB buffered → frame_min_ns * 24 (~5fps at 120fps base).
Instantly recovers to 120fps when output stops."
```

---

### Task 2: PTY Buffer Build-Time Configuration

Make PTY read buffer size configurable via `-Dpty_buf_kb=N` (default: 1024). Follows existing `-Dscale`, `-Dmax_fps` pattern.

**Files:**
- Modify: `zt/build.zig:13-14` (add option)
- Modify: `zt/config.zig:33-36` (add constant)
- Modify: `zt/src/main.zig:326,509` (use config constant)

- [ ] **Step 1: Add build option to build.zig**

In `zt/build.zig`, after line 14 (`const max_fps_opt = ...`), add:

```zig
    const pty_buf_kb_opt = b.option(u32, "pty_buf_kb", "PTY read buffer size in KB (default: 1024)") orelse 1024;
```

After line 20 (`options.addOption(u32, "max_fps", max_fps_opt);`), add:

```zig
    options.addOption(u32, "pty_buf_kb", pty_buf_kb_opt);
```

- [ ] **Step 2: Add config constant**

In `zt/config.zig`, after line 36 (`pub const frame_min_ns: ...`), add:

```zig
pub const pty_buf_size: u32 = build_options.pty_buf_kb * 1024;
```

- [ ] **Step 3: Use config constant in main.zig**

In `zt/src/main.zig`, replace line 326:

```zig
    var pty_buf: [262144]u8 = undefined; // 256KB PTY buffer
```

With:

```zig
    var pty_buf: [config.pty_buf_size]u8 = undefined;
```

Replace line 509 (`while (extra_total < 1_048_576)`):

```zig
            while (extra_total < 1_048_576) {
```

With:

```zig
            while (extra_total < config.pty_buf_size * 4) {
```

- [ ] **Step 4: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
cd /home/midasdf/zt
git add build.zig config.zig src/main.zig
git commit -m "perf: make PTY buffer size build-time configurable

Add -Dpty_buf_kb=N option (default: 1024). Extra drain cap
scales to 4× buffer size. Follows existing -Dscale/-Dmax_fps pattern.

PC: zig build -Dpty_buf_kb=1024 (1MB, fewer syscalls)
HackberryPi: zig build -Dpty_buf_kb=256 (256KB, conserve memory)"
```

---

### Task 3: nanoTimestamp Deduplication

Consolidate up to 3 `nanoTimestamp()` calls per loop iteration into 1 call at loop start.

**Files:**
- Modify: `zt/src/main.zig:335-356,530-533,576` (timestamp call sites)

- [ ] **Step 1: Add loop_now at loop start, replace all timestamp calls**

In `zt/src/main.zig`, at the top of the `while (running)` loop body (after line 335 `while (running) {`), add:

```zig
        const loop_now = std.time.nanoTimestamp();
```

Replace the epoll timeout calculation (lines 350-356). Change:

```zig
        const epoll_timeout: i32 = if (effective_frame_ns > 0 and term.hasDirty()) blk: {
            const now = std.time.nanoTimestamp();
            const elapsed = now - last_render_ns;
            if (elapsed >= effective_frame_ns) break :blk 0;
            const remaining_ms = @divFloor(effective_frame_ns - elapsed, 1_000_000);
            break :blk @intCast(@max(remaining_ms, 1));
        } else -1;
```

To:

```zig
        const epoll_timeout: i32 = if (effective_frame_ns > 0 and term.hasDirty()) blk: {
            const elapsed = loop_now - last_render_ns;
            if (elapsed >= effective_frame_ns) break :blk 0;
            const remaining_ms = @divFloor(effective_frame_ns - elapsed, 1_000_000);
            break :blk @intCast(@max(remaining_ms, 1));
        } else -1;
```

Replace the frame rate check (lines 530-533). Change:

```zig
        if (effective_frame_ns > 0) {
            const now = std.time.nanoTimestamp();
            if (now - last_render_ns < effective_frame_ns) continue;
        }
```

To:

```zig
        if (effective_frame_ns > 0) {
            if (loop_now - last_render_ns < effective_frame_ns) continue;
        }
```

Replace the post-render timestamp (line 576). Change:

```zig
        last_render_ns = std.time.nanoTimestamp();
```

To:

```zig
        last_render_ns = loop_now;
```

- [ ] **Step 2: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig
git commit -m "refactor: deduplicate nanoTimestamp calls in event loop

Consolidate 3 vDSO clock_gettime calls per loop iteration into 1.
Primarily a code simplification — timing accuracy loss is <1ms,
negligible relative to 8-200ms frame intervals."
```

---

## Chunk 2: Render Optimizations

### Task 4: Direct Cell Access in Render Loop

Replace per-cell `getCell`/`getFgRgb`/`getBgRgb` calls with per-row pointer resolution. Eliminates bounds checks, row_map lookups, and multiplications from the inner loop.

**Files:**
- Modify: `zt/src/main.zig:538-574` (render loop)

- [ ] **Step 1: Rewrite render loop with direct cell access**

In `zt/src/main.zig`, replace the render loop (lines 538-574):

```zig
        const skip_dirty_check = term.isAllDirty();
        var y: u32 = 0;
        while (y < term.rows) : (y += 1) {
            if (!skip_dirty_check and !term.isRowDirty(y)) continue;
            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (skip_dirty_check or term.isDirty(x, y)) {
                    const cell = term.getCell(x, y);

                    // Skip wide_dummy cells — rendered by the wide cell to the left
                    if (cell.attrs.wide_dummy) continue;

                    var fg_rgb = term.getFgRgb(x, y);
                    var bg_rgb = term.getBgRgb(x, y);
                    const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
                    const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

                    var render_cell = cell.*;
                    if (is_cursor) {
                        const tmp_idx = render_cell.fg;
                        render_cell.fg = render_cell.bg;
                        render_cell.bg = tmp_idx;
                        const tmp_rgb = fg_rgb;
                        fg_rgb = bg_rgb;
                        bg_rgb = tmp_rgb;
                    }

                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);
                    }

                    backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1);
                }
            }
        }
```

With:

```zig
        const all_dirty = term.isAllDirty();
        var y: u32 = 0;
        while (y < term.rows) : (y += 1) {
            if (!all_dirty and !term.isRowDirty(y)) continue;

            // Resolve physical row once per row — eliminates per-cell
            // bounds checks, row_map lookups, and multiplications
            const phys_row = term.row_map[y];
            const row_base = @as(usize, phys_row) * @as(usize, term.cols);
            const row_cells = term.cells[row_base..][0..term.cols];
            const row_fg = term.fg_rgb[row_base..][0..term.cols];
            const row_bg = term.bg_rgb[row_base..][0..term.cols];
            const dirty_row_base = @as(usize, y) * @as(usize, term.cols);

            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (!all_dirty and !term.dirty.isSet(dirty_row_base + x)) continue;

                const cell = &row_cells[x];
                if (cell.attrs.wide_dummy) continue;

                var fg_rgb = row_fg[x];
                var bg_rgb = row_bg[x];
                const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
                const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

                var render_cell = cell.*;
                if (is_cursor) {
                    const tmp_idx = render_cell.fg;
                    render_cell.fg = render_cell.bg;
                    render_cell.bg = tmp_idx;
                    const tmp_rgb = fg_rgb;
                    fg_rgb = bg_rgb;
                    bg_rgb = tmp_rgb;
                }

                if (cell.attrs.wide) {
                    render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);
                } else {
                    render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);
                }

                backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1);
            }
        }
```

- [ ] **Step 2: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig
git commit -m "perf: direct cell access in render loop

Resolve physical row pointer once per row instead of per cell.
Eliminates 5760 bounds checks, reduces multiplications from
5760 to 48. Dirty check bypasses isDirty method overhead."
```

---

### Task 5: All-Dirty Global Background Fill

When `all_dirty = true`, fill entire pixel buffer with default BG once, then render cells with background fill skipped. Eliminates 30,720 individual memset calls for 80×24 at scale=1.

**Files:**
- Modify: `zt/src/render.zig:89-103` (add `skip_bg` comptime parameter)
- Modify: `zt/src/main.zig` (add global BG fill, pass `skip_bg` to renderCell)

- [ ] **Step 1: Add comptime skip_bg parameter to renderCell**

In `zt/src/render.zig`, modify the `renderCell` function signature (line 89-103). Add `comptime skip_bg: bool` after `comptime scale: u32`:

Replace:

```zig
pub fn renderCell(
    buffer: []u8,
    stride: u32,
    cell_x: u32,
    cell_y: u32,
    cell: Cell,
    fg_rgb_override: ?[3]u8,
    bg_rgb_override: ?[3]u8,
    glyph: ?GlyphView,
    comptime font_w: u32,
    comptime font_h: u32,
    comptime pixel_format: PixelFormat,
    comptime wide: bool,
    comptime scale: u32,
) void {
```

With:

```zig
pub fn renderCell(
    buffer: []u8,
    stride: u32,
    cell_x: u32,
    cell_y: u32,
    cell: Cell,
    fg_rgb_override: ?[3]u8,
    bg_rgb_override: ?[3]u8,
    glyph: ?GlyphView,
    comptime font_w: u32,
    comptime font_h: u32,
    comptime pixel_format: PixelFormat,
    comptime wide: bool,
    comptime scale: u32,
    comptime skip_bg: bool,
) void {
```

- [ ] **Step 2: Guard background fill with skip_bg**

In `zt/src/render.zig`, wrap the background fill section (lines 139-156) with a comptime guard:

Replace:

```zig
    // 6. Fill background rect (scaled dimensions)
    if (pixel_format == .bgra32) {
```

With:

```zig
    // 6. Fill background rect (scaled dimensions)
    if (!skip_bg and pixel_format == .bgra32) {
```

Also guard the non-BGRA32 fallback. Replace:

```zig
    } else {
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            for (0..scaled_w) |col| {
```

With:

```zig
    } else if (!skip_bg) {
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            for (0..scaled_w) |col| {
```

- [ ] **Step 3: Update renderCursor to pass skip_bg=false**

In `zt/src/render.zig`, update the `renderCursor` call at line 281:

Replace:

```zig
    renderCell(buffer, stride, cell_x, cell_y, inverted, bg_rgb_override, fg_rgb_override, glyph, font_w, font_h, pixel_format, wide, scale);
```

With:

```zig
    renderCell(buffer, stride, cell_x, cell_y, inverted, bg_rgb_override, fg_rgb_override, glyph, font_w, font_h, pixel_format, wide, scale, false);
```

- [ ] **Step 4: Update all renderCell calls in tests**

In `zt/src/render.zig`, all test calls to `renderCell` need the extra `false` argument. There are 3 test callsites. Add `, false` as the last argument to each `renderCell(...)` call in the tests at approximately lines 319, 347, 383.

- [ ] **Step 5: Update renderCell calls in main.zig with two-path rendering**

In `zt/src/main.zig`, replace the `const skip_dirty_check = term.isAllDirty();` line with `const all_dirty = term.isAllDirty();` (unifying two identical calls). Then add the global BG fill:

```zig
        // Global background fill when all cells are dirty — one memset
        // replaces 30,720 individual per-cell memsets (80×24×16 rows)
        const all_dirty = term.isAllDirty();
        if (all_dirty) {
            const default_bg = render.palette[config.default_bg];
            const bg_packed = [4]u8{ default_bg.b, default_bg.g, default_bg.r, 0xFF };
            const total_pixels = @as(usize, backend.getWidth()) * @as(usize, backend.getHeight());
            const pixel_buf: [*][4]u8 = @ptrCast(buf.ptr);
            @memset(pixel_buf[0..total_pixels], bg_packed);
            backend.markDirtyRows(0, backend.getHeight() - 1);
        }
```

Also update the render loop to use `all_dirty` instead of `skip_dirty_check`, and pass the skip_bg flag. Replace:

```zig
                if (cell.attrs.wide) {
                    render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);
                } else {
                    render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);
                }
```

With:

```zig
                // Skip per-cell bg fill when global fill was applied, UNLESS:
                // - cell has non-default bg color (palette index != default)
                // - cell has TrueColor bg override
                // - cell has reverse attribute (swaps fg/bg, so bg won't match default)
                const skip_bg = all_dirty and (render_cell.bg == config.default_bg) and (bg_rgb == null) and !render_cell.attrs.reverse;
                if (skip_bg) {
                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, true);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, true);
                    }
                } else {
                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, false);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, false);
                    }
                }
```

- [ ] **Step 6: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS (existing render tests pass skip_bg=false, same behavior)

- [ ] **Step 7: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig src/render.zig
git commit -m "perf: global background fill when all cells dirty

When all_dirty=true, fill entire pixel buffer with default bg
color in one memset (~1MB), then render cells with bg fill
skipped. Cells with non-default bg still get individual fill.
Eliminates 30720 individual memset calls for 80x24 at scale=1."
```

---

## Chunk 3: Scroll Optimizations

### Task 6: scrollUp RGB Clear Skip

Skip `clearRgbRow` when TrueColor has never been used. Track via `has_truecolor_cells` flag in Term.

**Files:**
- Modify: `zt/src/term.zig:25-73` (add flag to Term struct)
- Modify: `zt/src/term.zig:217-246` (scrollUp conditional clear)
- Modify: `zt/src/term.zig:248-268` (scrollDown conditional clear)
- Modify: `zt/src/term.zig:449-456` (eraseDisplay resets flag)
- Modify: `zt/src/term.zig:676-685` (setFgRgb/setBgRgb set flag)
- Modify: `zt/src/vt.zig:461-465,553-554` (feedBulk direct RGB writes set flag)

- [ ] **Step 1: Add has_truecolor_cells flag to Term**

In `zt/src/term.zig`, after line 72 (`bracketed_paste: bool = false,`), add:

```zig
    has_truecolor_cells: bool = false,
```

- [ ] **Step 2: Set flag in setFgRgb and setBgRgb**

In `zt/src/term.zig`, modify `setFgRgb` (line 676-678):

Replace:

```zig
    pub fn setFgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.fg_rgb[self.cellIndex(x, y)] = rgb;
    }
```

With:

```zig
    pub fn setFgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.fg_rgb[self.cellIndex(x, y)] = rgb;
        self.has_truecolor_cells = true;
    }
```

Modify `setBgRgb` (line 684-686):

Replace:

```zig
    pub fn setBgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.bg_rgb[self.cellIndex(x, y)] = rgb;
    }
```

With:

```zig
    pub fn setBgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.bg_rgb[self.cellIndex(x, y)] = rgb;
        self.has_truecolor_cells = true;
    }
```

- [ ] **Step 3: Reset flag on eraseDisplay(2/3)**

In `zt/src/term.zig`, in `eraseDisplay` mode 2/3 (line 449-456), after `self.clearAllRgb();` (line 455), add:

```zig
                self.has_truecolor_cells = false;
```

- [ ] **Step 4: Set flag in vt.zig feedBulk direct RGB writes**

In `zt/src/vt.zig`, after the bulk RGB memset (lines 464-465):

```zig
                @memset(term.fg_rgb[phys_start .. phys_start + count], fg_val);
                @memset(term.bg_rgb[phys_start .. phys_start + count], bg_val);
```

Add:

```zig
                if (fg_val != null or bg_val != null) term.has_truecolor_cells = true;
```

Also in the UTF-8 single-char path, after lines 553-554:

```zig
                term.fg_rgb[phys_idx] = term.current_fg_rgb;
                term.bg_rgb[phys_idx] = term.current_bg_rgb;
```

Add:

```zig
                if (term.current_fg_rgb != null or term.current_bg_rgb != null) term.has_truecolor_cells = true;
```

- [ ] **Step 5: Conditional clearRgbRow in scrollUp**

In `zt/src/term.zig`, in `scrollUp` (lines 226-229), replace:

```zig
        for (0..shift) |s| {
            const phys = self.row_map[top + s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            self.clearRgbRow(phys);
        }
```

With:

```zig
        for (0..shift) |s| {
            const phys = self.row_map[top + s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            if (self.has_truecolor_cells) self.clearRgbRow(phys);
        }
```

- [ ] **Step 6: Conditional clearRgbRow in scrollDown**

In `zt/src/term.zig`, in `scrollDown` (lines 257-260), replace:

```zig
        for (0..shift) |s| {
            const phys = self.row_map[bot - s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            self.clearRgbRow(phys);
        }
```

With:

```zig
        for (0..shift) |s| {
            const phys = self.row_map[bot - s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            if (self.has_truecolor_cells) self.clearRgbRow(phys);
        }
```

- [ ] **Step 7: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
cd /home/midasdf/zt
git add src/term.zig src/vt.zig
git commit -m "perf: skip RGB clear in scrollUp/scrollDown when no TrueColor

Track has_truecolor_cells flag in Term. Set on setFgRgb/setBgRgb,
reset on eraseDisplay(2/3). When false (dense ASCII workload),
skip ~640 bytes of memset per scroll — saves MB per frame interval."
```

---

### Task 7: Scroll Pixel Buffer memmove

Accumulate scroll shifts in Term, apply as pixel buffer memmove before render. Add `syncBuffer` to backends for double-buffer safety.

**Files:**
- Modify: `zt/src/term.zig:25-73,217-246,248-268,270-329` (scroll accumulator, scrollUp/scrollDown, resize)
- Modify: `zt/src/main.zig` (memmove before render loop)
- Modify: `zt/src/backend/x11.zig` (add syncBuffer)
- Modify: `zt/src/backend/fbdev.zig` (add syncBuffer no-op)

- [ ] **Step 1: Add scroll accumulator fields to Term**

In `zt/src/term.zig`, after `scroll_bottom: u32 = 0,` (line 52), add:

```zig
    scroll_row_shift: i32 = 0,
    scroll_shift_top: u32 = 0,
    scroll_shift_bot: u32 = 0,
```

- [ ] **Step 2: Reset scroll accumulator in resize(), switchScreen(), eraseDisplay()**

In `zt/src/term.zig`, in `resize()`, after `self.scroll_bottom = new_rows -| 1;` (line 300), add:

```zig
        self.scroll_row_shift = 0;
```

In `switchScreen()`, after the early return `if (alt == self.is_alt_screen) return;` (line 332), add:

```zig
        self.scroll_row_shift = 0;
```

In `eraseDisplay()`, in the `2, 3 =>` branch (line 449), after `self.clearAllRgb();` (line 455), add:

```zig
                self.scroll_row_shift = 0;
```

- [ ] **Step 4: Modify scrollUp to accumulate shift with saturation fallback**

In `zt/src/term.zig`, in `scrollUp`, replace the dirty marking section (lines 236-245):

```zig
        // Mark entire scroll region dirty — row_map pointers rotated but
        // the pixel buffer still has old content at old positions
        if (top == 0 and bot + 1 == self.rows) {
            // Full-screen scroll: set all_dirty flag to skip future markDirtyRange calls
            if (!self.all_dirty) {
                self.markDirtyRange(.{ .start = 0, .end = (bot + 1) * cols });
                self.all_dirty = true;
            }
        } else {
            self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
        }
```

With:

```zig
        // Accumulate scroll shift for pixel buffer memmove.
        if (self.scroll_shift_top != @as(u32, @intCast(top)) or self.scroll_shift_bot != @as(u32, @intCast(bot))) {
            // Scroll region changed — reset accumulator to avoid incorrect memmove
            self.scroll_row_shift = 0;
        }
        self.scroll_row_shift += @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);

        // Check saturation: if accumulated shift >= region height, use all_dirty
        const abs_shift: u32 = @intCast(if (self.scroll_row_shift >= 0) self.scroll_row_shift else -self.scroll_row_shift);
        if (abs_shift >= region_height) {
            if (top == 0 and bot + 1 == self.rows) {
                if (!self.all_dirty) {
                    self.markDirtyRange(.{ .start = 0, .end = (bot + 1) * cols });
                    self.all_dirty = true;
                }
            } else {
                self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
            }
        } else {
            // Non-saturated: only mark recycled rows dirty
            for (0..shift) |s| {
                const row = bot + 1 - shift + s;
                self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
            }
        }
```

- [ ] **Step 5: Modify scrollDown to accumulate shift with saturation fallback**

In `zt/src/term.zig`, in `scrollDown`, replace the dirty marking (line 267):

```zig
        // Mark entire scroll region dirty
        self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
```

With:

```zig
        // Accumulate scroll shift (negative = scroll down)
        if (self.scroll_shift_top != @as(u32, @intCast(top)) or self.scroll_shift_bot != @as(u32, @intCast(bot))) {
            self.scroll_row_shift = 0;
        }
        self.scroll_row_shift -= @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);

        const abs_shift: u32 = @intCast(if (self.scroll_row_shift >= 0) self.scroll_row_shift else -self.scroll_row_shift);
        if (abs_shift >= region_height) {
            self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
        } else {
            for (0..shift) |s| {
                const row = top + s;
                self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
            }
        }
```

- [ ] **Step 6: Add syncBuffer to X11 backend**

In `zt/src/backend/x11.zig`, after the `present()` function (after the closing brace around line 604), add:

```zig
    /// Sync a pixel region from the other buffer to the current buffer.
    /// Ensures memmove source pixels are current in double-buffered mode.
    pub fn syncBuffer(self: *Self, y_start: u32, y_end: u32) void {
        const other: u1 = self.buf_idx ^ 1;
        if (self.buffers[other].len == 0) return; // second buffer not yet allocated
        const byte_start = y_start * self.stride;
        const byte_end = @min(y_end, self.height) * self.stride;
        if (byte_start >= byte_end) return;
        @memcpy(self.buffers[self.buf_idx][byte_start..byte_end], self.buffers[other][byte_start..byte_end]);
    }
```

- [ ] **Step 7: Add syncBuffer no-op to fbdev backend**

In `zt/src/backend/fbdev.zig`, after the `present()` function (after line 246), add:

```zig
    pub fn syncBuffer(_: *Self, _: u32, _: u32) void {}
```

- [ ] **Step 8: Apply memmove in main.zig render loop**

In `zt/src/main.zig`, before the global BG fill / render loop (before the `const do_skip_bg = ...` line added in Task 5), add:

```zig
        // Apply accumulated scroll shift via pixel buffer memmove
        if (term.scroll_row_shift != 0) {
            const row_shift = term.scroll_row_shift;
            term.scroll_row_shift = 0;

            const ch = config.cell_height;
            const region_px_top = @as(usize, term.scroll_shift_top) * ch;
            const region_px_bot = (@as(usize, term.scroll_shift_bot) + 1) * ch;
            const region_byte_top = region_px_top * stride;
            const region_byte_bot = region_px_bot * stride;
            const region_bytes = region_byte_bot - region_byte_top;

            if (row_shift > 0) {
                const pixel_shift = @as(usize, @intCast(row_shift)) * ch;
                const byte_shift = pixel_shift * stride;
                if (byte_shift < region_bytes) {
                    // Sync from other buffer to ensure memmove source is current
                    backend.syncBuffer(@intCast(region_px_top), @intCast(region_px_bot));
                    std.mem.copyForwards(u8, buf[region_byte_top .. region_byte_bot - byte_shift], buf[region_byte_top + byte_shift .. region_byte_bot]);
                    backend.markDirtyRows(@intCast(region_px_top), @intCast(region_px_bot -| 1));
                }
                // else: saturation — all rows already dirty via all_dirty, render loop handles it
            } else {
                const pixel_shift = @as(usize, @intCast(-row_shift)) * ch;
                const byte_shift = pixel_shift * stride;
                if (byte_shift < region_bytes) {
                    backend.syncBuffer(@intCast(region_px_top), @intCast(region_px_bot));
                    std.mem.copyBackwards(u8, buf[region_byte_top + byte_shift .. region_byte_bot], buf[region_byte_top .. region_byte_bot - byte_shift]);
                    backend.markDirtyRows(@intCast(region_px_top), @intCast(region_px_bot -| 1));
                }
            }
        }
```

- [ ] **Step 9: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS (unit tests don't exercise pixel buffer, but scroll logic tests verify row_map and cell correctness)

- [ ] **Step 10: Build and manual test**

Build: `cd /home/midasdf/zt && zig build -Dbackend=x11 -Doptimize=ReleaseFast`

Manual tests:
1. `seq 1 100` — lines scroll correctly, no stale pixels
2. `vim` a file, scroll up/down — no rendering artifacts
3. `cat /dev/urandom | base64 | head -c 5000000` — high-throughput scroll looks correct
4. Type shell commands producing 1-2 lines — line-by-line scroll correct
5. Run a program with scroll region (e.g. `less`) — verify partial scroll region works

- [ ] **Step 11: Commit**

```bash
cd /home/midasdf/zt
git add src/term.zig src/main.zig src/backend/x11.zig src/backend/fbdev.zig
git commit -m "perf: pixel buffer memmove on scroll

Accumulate scroll shifts in Term, apply as memmove before render.
Only recycled (blank) rows need cell-level re-rendering. Includes
syncBuffer for X11 double-buffer safety. Saturated scrolls (shift
>= screen height) skip memmove and fall back to full re-render.

For 80x24 at scale=2: 1920-cell render → 1.8MB memmove + 80 cells."
```
