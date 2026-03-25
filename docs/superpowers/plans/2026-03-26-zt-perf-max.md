# zt Performance Maximization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maximize zt terminal emulator throughput and reduce per-frame rendering cost across all workloads (ASCII, TrueColor, CJK, scroll-heavy).

**Architecture:** Six independent optimizations applied sequentially to the existing single-threaded epoll architecture. Each optimization targets a specific hot path: render loop cell processing, VT parser bulk write, font glyph lookup, and pixel buffer management on scroll. No structural changes — all optimizations are surgical modifications to existing functions.

**Tech Stack:** Zig 0.15+, Linux epoll, XCB (X11 backend), fbdev (framebuffer backend)

**Spec:** `docs/superpowers/specs/2026-03-25-zt-perf-max-design.md`

---

## File Map

| File | Role | Tasks |
|------|------|-------|
| `zt/src/main.zig` | Event loop, render orchestration | 1, 3, 5 |
| `zt/src/render.zig` | Per-cell pixel rendering | 1, 3 |
| `zt/src/vt.zig` | VT parser, bulk ASCII path | 2 |
| `zt/src/font.zig` | Glyph lookup, binary blob | 4 |
| `zt/src/term.zig` | Cell grid, scroll, dirty tracking | 5 |
| `zt/README.md` | Build instructions, benchmarks | 6 |

---

## Chunk 1: Render Path Optimizations

### Task 1: Skip Glyph Lookup for Space Characters

Space (`0x20`) is the most common cell character (~70-90% of a typical screen). Currently every dirty space cell triggers `FontType.getGlyph(' ')` → ASCII cache lookup → `GlyphView` construction → glyph blit loop that iterates 128 bits of all-zero bitmap. This task skips all of that.

**Files:**
- Modify: `zt/src/main.zig:498-527` (render loop)
- Modify: `zt/src/render.zig:224-235` (null-glyph fallback path)

- [ ] **Step 1: Write failing test for render with null glyph on space**

Add a test to `zt/src/render.zig` that verifies rendering a space cell with `glyph=null` produces only background pixels (no box outline):

```zig
test "Render: space with null glyph produces background only" {
    const w = 8;
    const h = 16;
    const bpp = 4;
    const stride = w * bpp;
    var buffer: [stride * h]u8 = [_]u8{0} ** (stride * h);

    // Render space with null glyph — should produce background only, no box
    renderCell(&buffer, stride, 0, 0, .{ .char = ' ', .fg = 7, .bg = 0 }, null, null, null, w, h, .bgra32, false, 1);

    // Row 0, col 0 should be background (black = 0,0,0)
    // NOT the foreground color (which box outline would produce)
    try testing.expectEqual(@as(u8, 0), buffer[2]); // R channel at (0,0)

    // Interior pixel (row 4, col 4) should also be background
    const interior = 4 * stride + 4 * bpp;
    try testing.expectEqual(@as(u8, 0), buffer[interior + 2]); // R channel
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: FAIL — the current null-glyph path draws a box outline, so border pixels will have foreground color (R > 0 for palette color 7).

- [ ] **Step 3: Modify render.zig null-glyph fallback**

In `zt/src/render.zig`, change the `else` branch (null glyph fallback) at line 224 from unconditional box outline to conditional:

Replace:
```zig
    } else {
        // Missing glyph fallback: box outline with scale-pixel border
        for (0..scaled_h) |row| {
```

With:
```zig
    } else if (cell.char != ' ' and cell.char != 0) {
        // Missing glyph fallback: box outline with scale-pixel border
        for (0..scaled_h) |row| {
```

This makes space and null characters skip the box outline — only background fill applies.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS (including new test)

- [ ] **Step 5: Skip getGlyph for space in render loop**

In `zt/src/main.zig`, in the render loop (around line 507), change:

```zig
                    const glyph = FontType.getGlyph(cell.char);
```

To:

```zig
                    const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
```

- [ ] **Step 6: Run full test suite**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig src/render.zig
git commit -m "perf: skip glyph lookup for space characters

Space is ~70-90% of cells on a typical terminal screen. Skip
getGlyph call and glyph blit loop entirely — just fill background."
```

---

### Task 2: TrueColor Bulk Path

The VT parser's `feedBulk` fast path falls back to per-character `handlePrint` when TrueColor is active. This task extends the bulk write path to handle TrueColor, keeping full bulk speed for programs like `bat`, `delta`, and `eza --color`.

**Files:**
- Modify: `zt/src/vt.zig:379-438` (feedBulk fast path)

- [ ] **Step 1: Write failing test for TrueColor bulk write**

Add a test to `zt/src/vt.zig` that verifies TrueColor attributes are applied during bulk writes:

```zig
test "Executor: TrueColor bulk ASCII preserves RGB" {
    var t = try Term.init(testing.allocator, 80, 24);
    defer t.deinit();
    var parser = Parser{};

    // Set TrueColor foreground via SGR 38;2;r;g;b then bulk ASCII
    const input = "\x1b[38;2;255;128;0mABCDE";
    feedBulk(&parser, input, &t, null);

    // All 5 cells should have TrueColor fg
    for (0..5) |x| {
        const rgb = t.getFgRgb(@intCast(x), 0);
        try testing.expect(rgb != null);
        try testing.expectEqual([3]u8{ 255, 128, 0 }, rgb.?);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: FAIL — the bulk path currently skips TrueColor handling, so `getFgRgb` returns null for cells written via the bulk path when `has_truecolor` causes fallback to per-char `handlePrint`. Actually — the current code falls back to `handlePrint` which DOES set RGB. So this test might pass already. Let's verify. If it passes, the optimization is about speed, not correctness, and the test confirms we don't regress.

- [ ] **Step 3: Modify feedBulk to handle TrueColor in bulk path**

In `zt/src/vt.zig`, in the `feedBulk` function, replace the TrueColor early-out and add RGB handling to the bulk write section.

Remove these lines (around line 400-405):
```zig
                if (has_truecolor) {
                    // Rare case: TrueColor active, use full path
                    handlePrint(@as(u21, data[i]), term);
                    i += 1;
                    continue;
                }
```

After the bulk cell write loop (after the `for (0..count)` that writes `term.cells[phys_start + j]`), add RGB handling:

```zig
                // Clear stale RGB entries for overwritten cells
                if (term.fg_rgb_map.count() > 0) {
                    for (0..count) |j| _ = term.fg_rgb_map.remove(phys_start + j);
                }
                if (term.bg_rgb_map.count() > 0) {
                    for (0..count) |j| _ = term.bg_rgb_map.remove(phys_start + j);
                }
                // Set TrueColor for bulk-written cells
                if (term.current_fg_rgb) |rgb| {
                    for (0..count) |j| {
                        term.fg_rgb_map.put(phys_start + j, rgb) catch {};
                    }
                }
                if (term.current_bg_rgb) |rgb| {
                    for (0..count) |j| {
                        term.bg_rgb_map.put(phys_start + j, rgb) catch {};
                    }
                }
```

Also remove the `has_truecolor` variable declaration (around line 389) since it's no longer used:
```zig
            const has_truecolor = term.current_fg_rgb != null or term.current_bg_rgb != null;
```

- [ ] **Step 4: Run tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
cd /home/midasdf/zt
git add src/vt.zig
git commit -m "perf: handle TrueColor in bulk ASCII path

Remove per-char handlePrint fallback when TrueColor is active.
Set RGB entries directly in bulk write loop, maintaining full
bulk speed for TrueColor-heavy programs (bat, delta, eza)."
```

---

### Task 3: Render Loop Cursor Branch Consolidation

The render loop has 4 branches (wide × cursor). `renderCursor` just swaps fg/bg and delegates to `renderCell`. This task inlines the swap, reducing 4 branches to 2.

**Files:**
- Modify: `zt/src/main.zig:498-527` (render loop)

- [ ] **Step 1: Refactor render loop to inline cursor handling**

In `zt/src/main.zig`, replace the render section (from `const fg_rgb = ...` through the 4-branch if/else, around lines 505-522) with:

```zig
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
```

Note: `fg_rgb` and `bg_rgb` must now be `var` instead of `const` (they were `const` before). The `glyph` line already includes the space-skip from Task 1.

- [ ] **Step 2: Run full test suite**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
cd /home/midasdf/zt
git add src/main.zig
git commit -m "perf: inline cursor fg/bg swap in render loop

Replace 4-branch wide×cursor pattern with inline swap.
Reduces to 2 branches (wide true/false only).
renderCursor is no longer called from the hot path."
```

---

## Chunk 2: Font & Scroll Optimizations

### Task 4: Non-ASCII Glyph Cache

ASCII glyphs have O(1) lookup via comptime `ascii_cache`. Non-ASCII (CJK, emoji, Nerd Fonts) does binary search over 59,635 entries (~16 comparisons). This task adds a 256-entry runtime direct-mapped cache for repeated non-ASCII codepoints.

**Files:**
- Modify: `zt/src/font.zig:62-112` (FontBlob type)

- [ ] **Step 1: Write test for glyph cache behavior**

Add a test to `zt/src/font.zig` that verifies repeated non-ASCII lookups return the same result. We use the test font's CJK glyph (codepoint 0x3042 = あ):

```zig
test "FontBlob: repeated non-ASCII lookup returns same glyph" {
    const FontType = FontBlob(@embedFile("fonts/ufo-nf.bin"));

    // First lookup (cache miss → binary search)
    const g1 = FontType.getGlyph(0x3042);
    try std.testing.expect(g1 != null);

    // Second lookup (cache hit)
    const g2 = FontType.getGlyph(0x3042);
    try std.testing.expect(g2 != null);

    // Same glyph data
    try std.testing.expectEqual(g1.?.codepoint, g2.?.codepoint);
    try std.testing.expectEqual(g1.?.width, g2.?.width);
    try std.testing.expectEqual(g1.?.height, g2.?.height);
    try std.testing.expectEqual(g1.?.bitmap.len, g2.?.bitmap.len);
}
```

- [ ] **Step 2: Run test — should pass already (same results regardless of cache)**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: PASS (binary search returns same result both times)

- [ ] **Step 3: Add runtime glyph cache to FontBlob**

In `zt/src/font.zig`, modify the `getGlyph` function inside the `FontBlob` returned struct.

Replace:
```zig
        pub fn getGlyph(codepoint: u21) ?GlyphView {
            // Fast path: ASCII
            if (codepoint < 128) return ascii_cache[codepoint];
            return getGlyphSlow(codepoint);
        }
```

With:
```zig
        const CACHE_SIZE = 256;
        const CacheEntry = struct {
            codepoint: u21 = 0,
            result: ?GlyphView = null,
            valid: bool = false,
        };

        pub fn getGlyph(codepoint: u21) ?GlyphView {
            // Fast path: ASCII (comptime cache)
            if (codepoint < 128) return ascii_cache[codepoint];

            // Runtime cache for non-ASCII (function-local static via struct pattern)
            const S = struct {
                var cache: [CACHE_SIZE]CacheEntry = .{.{}} ** CACHE_SIZE;
            };

            const idx = codepoint % CACHE_SIZE;
            if (S.cache[idx].valid and S.cache[idx].codepoint == codepoint) {
                return S.cache[idx].result;
            }

            // Cache miss: binary search
            const result = getGlyphSlow(codepoint);
            S.cache[idx] = .{ .codepoint = codepoint, .result = result, .valid = true };
            return result;
        }
```

Note: The `const S = struct { var cache = ...; };` pattern is the idiomatic Zig way to create function-local mutable state. This avoids container-level `var` which was restricted in newer Zig versions.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS (including existing font tests and new cache test)

- [ ] **Step 5: Commit**

```bash
cd /home/midasdf/zt
git add src/font.zig
git commit -m "perf: add runtime glyph cache for non-ASCII codepoints

256-entry direct-mapped cache reduces O(log 59635) binary search
to O(1) for repeated CJK/emoji/Nerd Font characters. ~9KB memory.
ASCII still uses comptime cache."
```

---

### Task 5: Scroll Pixel Buffer memmove

Currently `scrollUp`/`scrollDown` mark the entire scroll region dirty, forcing re-rendering of all cells. This task shifts the pixel buffer via memmove and only re-renders recycled (blank) rows.

This is the highest-risk optimization. The pixel buffer shift must exactly match the row_map manipulation, and the dirty bit coordination must be precise.

**Files:**
- Modify: `zt/src/term.zig` (add scroll_pixel_shift, update scrollUp/scrollDown)
- Modify: `zt/src/main.zig` (apply pixel shift before render loop)

- [ ] **Step 1: Add scroll_pixel_shift field to Term**

In `zt/src/term.zig`, add new fields to the `Term` struct (after `scroll_bottom`):

```zig
    // Scroll accumulator: number of rows shifted (positive = up, negative = down)
    // Applied as pixel buffer memmove in main.zig render loop
    scroll_row_shift: i32 = 0,
    scroll_shift_top: u32 = 0,   // scroll region top row at time of scroll
    scroll_shift_bot: u32 = 0,   // scroll region bottom row at time of scroll
```

Reset in `resize()` (add after `self.scroll_bottom = new_rows -| 1;`):
```zig
        self.scroll_row_shift = 0;
```

Reset in `switchScreen()` (add at the start, before the `if (alt == self.is_alt_screen) return;` check):
```zig
        self.scroll_row_shift = 0;
```

- [ ] **Step 2: Modify scrollUp to use accumulator instead of full-region dirty**

In `zt/src/term.zig`, in `scrollUp()`, replace the full-region dirty mark:

Replace:
```zig
        // Mark entire scroll region dirty — row_map pointers rotated but
        // the pixel buffer still has old content at old positions
        self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
```

With:
```zig
        // Accumulate scroll shift for pixel buffer memmove in render loop.
        // Only mark recycled (cleared) rows dirty — moved rows will be
        // corrected by pixel buffer memmove before cell rendering.
        self.scroll_row_shift += @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);
        for (0..shift) |s| {
            const row = bot + 1 - shift + s;
            self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
        }
```

No `config` import needed — row indices are stored, pixel multiplication happens in `main.zig`.

- [ ] **Step 3: Modify scrollDown to use accumulator**

In `zt/src/term.zig`, in `scrollDown()`, replace the full-region dirty mark:

Replace:
```zig
        // Mark entire scroll region dirty
        self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
```

With:
```zig
        // Accumulate scroll shift (negative = scroll down)
        self.scroll_row_shift -= @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);
        for (0..shift) |s| {
            const row = top + s;
            self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
        }
```

- [ ] **Step 4: Apply pixel shift in main.zig render loop**

In `zt/src/main.zig`, BEFORE the render loop (before `const buf = backend.getBuffer();`, around line 492), add:

```zig
        // Apply accumulated scroll shift via pixel buffer memmove
        if (term.scroll_row_shift != 0) {
            const pbuf = backend.getBuffer();
            const pstride = backend.getStride();
            const row_shift = term.scroll_row_shift;
            term.scroll_row_shift = 0;

            // Convert row indices to pixel byte offsets
            const ch = config.cell_height;
            const region_px_top = @as(usize, term.scroll_shift_top) * ch;
            const region_px_bot = (@as(usize, term.scroll_shift_bot) + 1) * ch;
            const region_byte_top = region_px_top * pstride;
            const region_byte_bot = region_px_bot * pstride;
            const region_bytes = region_byte_bot - region_byte_top;
            const pixel_shift = @as(i32, row_shift) * @as(i32, @intCast(ch));

            if (pixel_shift > 0) {
                const byte_shift = @as(usize, @intCast(pixel_shift)) * pstride;
                if (byte_shift < region_bytes) {
                    // Normal scroll up
                    const src = pbuf[region_byte_top + byte_shift .. region_byte_bot];
                    const dst = pbuf[region_byte_top .. region_byte_bot - byte_shift];
                    std.mem.copyForwards(u8, dst, src);
                }
                // else: saturation — entire region scrolled away.
                // All rows already dirty from scrollUp's per-row markDirtyRange,
                // so they'll be re-rendered. No memmove needed.
            } else {
                const byte_shift = @as(usize, @intCast(-pixel_shift)) * pstride;
                if (byte_shift < region_bytes) {
                    // Normal scroll down
                    const src = pbuf[region_byte_top .. region_byte_bot - byte_shift];
                    const dst = pbuf[region_byte_top + byte_shift .. region_byte_bot];
                    std.mem.copyBackwards(u8, dst, src);
                }
                // else: saturation — same as above
            }
            // Backend must present the shifted pixel region
            backend.markDirtyRows(@intCast(region_px_top), @intCast(region_px_bot -| 1));
        }
```

**Saturation handling**: When `byte_shift >= region_bytes` (entire region scrolled away), the memmove is skipped. In this case, every row in the scroll region has been recycled and cleared by `scrollUp`/`scrollDown`, so every row is already marked dirty via `markDirtyRange`. All cells will be re-rendered naturally. No special fallback needed.

**Cursor handling**: The existing cursor dirty-marking at lines 479-485 (before this memmove code) ensures cursor cells are always dirty when cursor position changes. After memmove, dirty cursor cells are re-rendered correctly at their logical positions.

- [ ] **Step 5: Run full test suite**

Run: `cd /home/midasdf/zt && zig build test 2>&1 | tail -20`
Expected: ALL PASS. Note: unit tests don't exercise the pixel buffer (no backend in tests), but the scroll logic tests verify row_map and cell content correctness.

- [ ] **Step 6: Build and manual test**

Build: `cd /home/midasdf/zt && zig build -Dbackend=x11 -Doptimize=ReleaseFast`

Manual tests:
1. Open zt, run `seq 1 100` — verify lines scroll correctly, no stale pixels
2. Run `vim`, scroll up/down in a file — verify no rendering artifacts
3. Run `cat /dev/urandom | base64 | head -c 5000000` — verify high-throughput scroll looks correct
4. In a shell, type commands that produce 1-2 lines of output — verify line-by-line scroll is correct

- [ ] **Step 7: Commit**

```bash
cd /home/midasdf/zt
git add src/term.zig src/main.zig
git commit -m "perf: pixel buffer memmove on scroll

Replace full scroll-region re-render with memmove + recycled-row-only
render. For 80x24 at scale=2: 1920-cell render → 1.8MB memmove + 80 cells.
memmove uses CPU SIMD, vastly faster than per-cell glyph blitting."
```

---

### Task 6: Document ReleaseFast Build

**Files:**
- Modify: `zt/README.md`

- [ ] **Step 1: Add build profile documentation to README**

In `zt/README.md`, find the build section and add platform-specific build commands. Add after existing build instructions:

```markdown
### Build Profiles

**PC (maximum speed):**
```bash
zig build -Dbackend=x11 -Doptimize=ReleaseFast
```

**HackberryPi (minimum size):**
```bash
zig build -Doptimize=ReleaseSmall
```

ReleaseFast enables aggressive inlining, loop unrolling, and SIMD auto-vectorization.
ReleaseSmall minimizes binary size for constrained devices (512MB RAM).
```

- [ ] **Step 2: Commit**

```bash
cd /home/midasdf/zt
git add README.md
git commit -m "docs: add ReleaseFast build instructions for PC"
```
