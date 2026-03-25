# zt Performance Maximization Design

## Problem

zt is already fast (3.5ms startup, 1,382 MB/s throughput, 4.3MB RSS), but several optimization opportunities remain. This spec covers six targeted optimizations that improve both throughput and latency while maintaining the existing architecture.

## Target Platforms

| Platform | Build | Priority |
|----------|-------|----------|
| PC (x86_64, X11) | ReleaseFast | Throughput, latency |
| HackberryPi (aarch64, fbdev) | ReleaseSmall | Memory, binary size |

Both platforms get all code optimizations. Build optimization level is selectable per platform.

---

## Optimization 1: Scroll Pixel Buffer Scroll

### Problem

`scrollUp()` and `scrollDown()` manipulate `row_map` for O(1) logical-to-physical remapping and mark the **entire scroll region** dirty. This is correct — the pixel buffer still has old content at old positions, so all rows in the region must be re-rendered. However, this means every scroll triggers a full re-render of all cells in the scroll region (typically all 24 rows × 80 columns = 1,920 cells), each requiring glyph lookup and pixel blitting.

For a 80×24 terminal at scale=2, each scroll re-renders 1,920 cells. During `cat bigfile`, hundreds of scrolls occur per render cycle, but the full-region dirty mark forces re-rendering everything even though the pixel content could be shifted with a simple memory move.

### Solution: Pixel Buffer memmove

When scroll occurs, shift the pixel buffer content to match the new logical layout via memmove. Then only mark the recycled (blank) rows dirty instead of the entire scroll region. The moved rows' pixels are already correct after the shift.

**Architecture**:

Add scroll accumulator to `Term`:
```zig
// term.zig — new fields in Term struct
scroll_pixel_shift: i32 = 0,  // pixels to shift (positive = up, negative = down)
scroll_region_top: u32 = 0,   // scroll region bounds at time of scroll
scroll_region_bot: u32 = 0,
```

In `scrollUp(n)`, **replace** the full-region dirty mark with accumulator update:
```zig
// REPLACE: self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
// WITH: accumulate pixel shift + mark only recycled rows dirty
self.scroll_pixel_shift += @as(i32, @intCast(shift)) * @as(i32, @intCast(config.cell_height));
self.scroll_region_top = @intCast(top);
self.scroll_region_bot = @intCast(bot);
for (0..shift) |s| {
    const row = bot + 1 - shift + s;
    self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
}
```

In `scrollDown(n)`, same pattern with negative shift and top rows dirty.

In the main render loop (before cell rendering), apply the accumulated shift:
```zig
if (term.scroll_pixel_shift != 0) {
    const buf = backend.getBuffer();
    const stride = backend.getStride();
    const shift = term.scroll_pixel_shift;
    term.scroll_pixel_shift = 0;

    const region_px_top = @as(usize, term.scroll_region_top) * config.cell_height;
    const region_px_bot = (@as(usize, term.scroll_region_bot) + 1) * config.cell_height;
    const region_byte_top = region_px_top * stride;
    const region_byte_bot = region_px_bot * stride;
    const region_bytes = region_byte_bot - region_byte_top;

    if (shift > 0) {
        // Scroll up: move pixels upward within region
        const byte_shift = @as(usize, @intCast(shift)) * stride;
        if (byte_shift < region_bytes) {
            const src_start = region_byte_top + byte_shift;
            const dest_start = region_byte_top;
            const len = region_bytes - byte_shift;
            std.mem.copyForwards(u8, buf[dest_start..dest_start + len], buf[src_start..src_start + len]);
        }
    } else {
        // Scroll down: move pixels downward within region
        const byte_shift = @as(usize, @intCast(-shift)) * stride;
        if (byte_shift < region_bytes) {
            const src_start = region_byte_top;
            const dest_start = region_byte_top + byte_shift;
            const len = region_bytes - byte_shift;
            std.mem.copyBackwards(u8, buf[dest_start..dest_start + len], buf[src_start..src_start + len]);
        }
    }
    // Mark entire region for backend present (pixels moved, not just cells)
    backend.markDirtyRows(@intCast(region_px_top), @intCast(region_px_bot - 1));
}
```

**Scroll region handling**: When `scroll_top > 0` or `scroll_bottom < rows - 1` (custom scroll region), the memmove must only shift pixels within the scroll region pixel range, not the entire buffer. The shift calculation uses the scroll region bounds:

```zig
const region_px_top = term.scroll_top * config.cell_height;
const region_px_bot = (term.scroll_bottom + 1) * config.cell_height;
// memmove only within [region_px_top, region_px_bot)
```

**Multiple scrolls between renders**: The accumulator handles this naturally. If `scrollUp(1)` is called 5 times before render, `scroll_pixel_shift = 5 * cell_height`. The memmove shifts by the total accumulated amount. Rows that scrolled off the top are lost from the pixel buffer (correct — they were recycled and cleared).

**Saturation**: If `|scroll_pixel_shift| >= scroll_region_height_in_pixels`, the entire region scrolled away. Skip memmove and just clear the region (all rows already marked dirty by scrollUp/scrollDown).

**Dirty bit coordination**: After the pixel memmove, only recycled (blank) rows have their dirty bits set. Moved rows are NOT dirty because their pixel content is already correct (shifted by memmove). The backend dirty rows cover the full region for `present()` (pixels changed position), but the cell-level dirty bitmap only covers recycled rows for the render loop.

**Impact**:
- Eliminates re-rendering of all moved rows on scroll (only recycled rows rendered)
- For 80x24 at scale=2: replaces 1,920-cell render with ~1.8MB memmove + 80-cell render
- memmove uses CPU SIMD instructions, vastly faster than per-cell glyph blitting
- Scroll-heavy workloads (cat, log tailing) benefit most

### Files Changed

| File | Change |
|------|--------|
| `src/term.zig` | Add `scroll_pixel_shift` field, update `scrollUp`/`scrollDown` |
| `src/main.zig` | Add pixel shift application before render loop |

---

## Optimization 2: ReleaseFast Build Option

### Problem

zt builds with `-Doptimize=ReleaseSmall` for HackberryPi's 512MB RAM constraint. On PC, binary size is irrelevant but speed matters.

### Solution

No code changes needed — `build.zig` already supports `standardOptimizeOption()`. Document the recommended build commands:

- **PC**: `zig build -Dbackend=x11 -Doptimize=ReleaseFast`
- **HackberryPi**: `zig build -Doptimize=ReleaseSmall`

Update `README.md` to document both build profiles.

**Expected impact**: 10-30% throughput improvement from:
- Aggressive function inlining (render hot path)
- Loop unrolling (glyph blit, background fill)
- SIMD auto-vectorization (memmove, memset)
- No safety checks in release (bounds checking eliminated)

### Files Changed

| File | Change |
|------|--------|
| `README.md` | Add ReleaseFast build instructions for PC |

---

## Optimization 3: Skip Glyph Lookup for Space Characters

### Problem

The render loop calls `FontType.getGlyph(cell.char)` for every dirty cell. Space (`0x20`) is by far the most common character — typically 70-90% of cells on a terminal screen are spaces. Space glyphs have all-zero bitmaps, so the glyph blit loop iterates 16 rows × 8 columns but writes nothing. This is pure overhead.

### Solution

In the main render loop, check for space before glyph lookup:

```zig
// main.zig render loop, after getting cell:
const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
```

No bold/underline guard needed: underline rendering is independent of the glyph (runs unconditionally after the glyph section), and bold on an all-zero bitmap has no visible effect.

The `renderCell` function currently handles `glyph == null` by drawing a box outline fallback. For spaces, we want it to just fill the background. Modify the null-glyph path in `renderCell` to only draw the box for truly missing glyphs (non-space, non-null characters):

```zig
// render.zig, in the glyph section:
if (glyph) |g| {
    // ... existing glyph blit code ...
} else if (cell.char != ' ' and cell.char != 0) {
    // Missing glyph fallback: box outline
    // ... existing box code ...
}
// else: space or null char — background only, no glyph/box needed
```

**Impact**:
- Eliminates `getGlyph` call for ~70-90% of dirty cells
- Eliminates 128-iteration glyph blit loop (16×8 bit checks) per space cell
- Background fill still runs (needed for correct clearing)

### Files Changed

| File | Change |
|------|--------|
| `src/render.zig` | Change null-glyph fallback to skip box for space/null chars |
| `src/main.zig` | Skip getGlyph for space characters |

---

## Optimization 4: TrueColor Bulk Path

### Problem

In `feedBulk()` (vt.zig:379-438), the fast ASCII path checks `has_truecolor` and falls back to per-character `handlePrint()` when TrueColor is active:

```zig
if (has_truecolor) {
    handlePrint(@as(u21, data[i]), term);
    i += 1;
    continue;
}
```

This eliminates all bulk-write benefits for TrueColor content. Programs like `bat`, `delta`, `eza --color` use TrueColor extensively.

### Solution

Handle TrueColor in the bulk write loop:

```zig
// After bulk-writing cells to physical row (existing code):
for (0..count) |j| {
    term.cells[phys_start + j] = .{
        .char = @as(u21, data[i + j]),
        .fg = term.current_fg,
        .bg = term.current_bg,
        .attrs = term.current_attrs,
    };
}

// NEW: Set TrueColor for bulk-written cells
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

Also remove the `has_truecolor` early-out check, so the bulk path always runs:

```zig
// REMOVE these lines:
// if (has_truecolor) {
//     handlePrint(@as(u21, data[i]), term);
//     i += 1;
//     continue;
// }
```

We still need to clear stale RGB entries when overwriting cells. The bulk path should clear RGB entries for overwritten positions before setting new ones. Since `setCell` already clears RGB, and we're bypassing `setCell` in the bulk path, we need to handle this:

```zig
// Before writing new RGB values, clear any existing entries
// Check each map independently (one may be empty while other is not)
if (term.fg_rgb_map.count() > 0) {
    for (0..count) |j| _ = term.fg_rgb_map.remove(phys_start + j);
}
if (term.bg_rgb_map.count() > 0) {
    for (0..count) |j| _ = term.bg_rgb_map.remove(phys_start + j);
}
```

**Note**: The existing non-TrueColor bulk path also bypasses `setCell` and does not clear stale RGB entries. This is a pre-existing issue — if TrueColor was previously set for a cell and a non-TrueColor write overwrites it via the bulk path, the stale RGB entry persists. The TrueColor bulk path fix above addresses this for new TrueColor writes. A complete fix would add RGB clearing to the non-TrueColor bulk path as well (low priority since RGB maps are typically empty in non-TrueColor usage).

**Impact**:
- TrueColor content processes at bulk speed instead of per-character
- Estimated 3-5x throughput improvement for TrueColor-heavy output
- No impact on non-TrueColor path (already fast)

### Files Changed

| File | Change |
|------|--------|
| `src/vt.zig` | Remove `has_truecolor` early-out, add RGB handling in bulk path |

---

## Optimization 5: Non-ASCII Glyph Cache

### Problem

ASCII glyphs (0-127) have O(1) lookup via `ascii_cache`. Non-ASCII glyphs (CJK, emoji, Nerd Fonts) require binary search over 59,635 entries — approximately 16 comparisons per lookup.

For Japanese text, characters like の, は, が, い, る repeat frequently. Each occurrence triggers a fresh binary search.

### Solution

Add a runtime direct-mapped cache for non-ASCII glyphs. The cache uses `codepoint % CACHE_SIZE` as the index.

```zig
// font.zig — inside FontBlob type, add runtime cache
const GLYPH_CACHE_SIZE = 256;

var glyph_cache: [GLYPH_CACHE_SIZE]CacheEntry = .{.{}} ** GLYPH_CACHE_SIZE;

const CacheEntry = struct {
    codepoint: u21 = 0,
    glyph: ?GlyphView = null,
    valid: bool = false,
};

pub fn getGlyph(codepoint: u21) ?GlyphView {
    // Fast path: ASCII
    if (codepoint < 128) return ascii_cache[codepoint];

    // Check runtime cache
    const idx = codepoint % GLYPH_CACHE_SIZE;
    if (glyph_cache[idx].valid and glyph_cache[idx].codepoint == codepoint) {
        return glyph_cache[idx].glyph;
    }

    // Cache miss: binary search
    const result = getGlyphSlow(codepoint);
    glyph_cache[idx] = .{ .codepoint = codepoint, .glyph = result, .valid = true };
    return result;
}
```

**Memory**: 256 × sizeof(CacheEntry) ≈ ~9KB. `GlyphView` is 28 bytes (u21 + u32 + u32 + slice), `CacheEntry` wraps it with codepoint + valid flag ≈ 34 bytes. Negligible even on HackberryPi.

**Cache effectiveness**: Japanese text uses ~2,000 unique kanji but a much smaller working set in typical content. The 256-entry cache captures the hot working set with minimal collision.

**Thread safety**: zt is single-threaded. No synchronization needed.

**Note**: `FontBlob` is a comptime type, so the runtime cache must use `var` fields. In Zig, comptime types CAN have mutable runtime state via `var` declarations inside the struct. The `glyph_cache` is initialized at startup (all-zero = all invalid) and populated on first access.

**Impact**:
- O(1) glyph lookup for repeated non-ASCII characters
- 16 comparisons → 1 array access + 1 equality check for cache hits
- Most beneficial for CJK-heavy content (日本語, 中文, 한국어)

### Files Changed

| File | Change |
|------|--------|
| `src/font.zig` | Add `glyph_cache` array and cache logic to `getGlyph` |

---

## Optimization 6: Render Loop Simplification

### Problem

The render loop in `main.zig:498-527` has four branches for wide × cursor combinations. Each branch calls either `renderCell` or `renderCursor` with slightly different parameters. `renderCursor` just swaps fg/bg and calls `renderCell`.

Note: `wide_dummy` is already checked before glyph lookup (line 503), so no change needed there.

### Solution

**Inline cursor fg/bg swap** — eliminate the 4-branch pattern:

```zig
const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

var eff_fg = fg_rgb;
var eff_bg = bg_rgb;
if (is_cursor) {
    eff_fg = bg_rgb;
    eff_bg = fg_rgb;
}

const wide = cell.attrs.wide;
if (wide) {
    render.renderCell(buf, stride, x, y, cell.*, eff_fg, eff_bg, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);
} else {
    render.renderCell(buf, stride, x, y, cell.*, eff_fg, eff_bg, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);
}
```

This reduces 4 branches to 2 (wide true/false only) and eliminates `renderCursor` entirely.

Wait — `renderCursor` also swaps `cell.fg` and `cell.bg` (the 256-color indices), not just the RGB overrides. We need to handle this correctly:

```zig
var render_cell = cell.*;
if (is_cursor) {
    const tmp = render_cell.fg;
    render_cell.fg = render_cell.bg;
    render_cell.bg = tmp;
    // Swap RGB overrides too
    eff_fg = bg_rgb;
    eff_bg = fg_rgb;
}
```

**Impact**:
- Removes renderCursor function (dead code elimination)
- Reduces branch count from 4 to 2 in hot render loop
- Simpler code, easier to reason about

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Restructure render loop: early wide_dummy skip, inline cursor swap |
| `src/render.zig` | `renderCursor` becomes unused (can be removed or kept for tests) |

---

## Implementation Order

Each optimization is independent and can be verified separately:

| Order | Optimization | Risk | Impact |
|-------|-------------|------|--------|
| 1 | Space glyph skip | Low | High |
| 2 | Render loop simplification | Low | Medium |
| 3 | TrueColor bulk path | Low | Medium (TrueColor content) |
| 4 | Non-ASCII glyph cache | Low | Medium (CJK content) |
| 5 | Scroll pixel buffer memmove | Medium | High (scroll-heavy) |
| 6 | ReleaseFast docs | None | High (PC only) |

Low-risk changes first (space skip, render loop, TrueColor, glyph cache). Scroll pixel memmove last among code changes because it requires careful dirty-bit coordination and has the highest risk of rendering artifacts if implemented incorrectly. ReleaseFast docs is a no-code-change item.

## Verification

After each optimization, run:
1. `zig build test` — all 70 unit tests pass
2. Manual visual test: `cat` a large file, verify no rendering artifacts
3. Throughput benchmark: `time cat /dev/urandom | head -c 5M | ./zt -e cat` (or equivalent)
4. Interactive test: shell usage, vim, scroll behavior

After all optimizations:
1. Full benchmark suite (startup, throughput, RSS) on both x86_64 and aarch64
2. Compare before/after numbers
3. 24-hour stability test on HackberryPi

## Non-Goals

- No new features (scrollback, mouse support, etc.)
- No architecture changes (single-threaded epoll stays)
- No allocator changes (page_allocator for fbdev, c_allocator for X11)
- No font format changes (binary blob stays)
