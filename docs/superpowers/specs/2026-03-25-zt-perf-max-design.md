# zt Performance Maximization Design

## Problem

zt is already fast (3.5ms startup, 1,382 MB/s throughput, 4.3MB RSS), but several optimization opportunities remain — including a correctness bug that masks a major performance win. This spec covers six targeted optimizations that improve both throughput and latency while maintaining the existing architecture.

## Target Platforms

| Platform | Build | Priority |
|----------|-------|----------|
| PC (x86_64, X11) | ReleaseFast | Throughput, latency |
| HackberryPi (aarch64, fbdev) | ReleaseSmall | Memory, binary size |

Both platforms get all code optimizations. Build optimization level is selectable per platform.

---

## Optimization 1: Scroll Pixel Buffer Scroll (Bug Fix + Perf)

### Problem

`scrollUp()` and `scrollDown()` manipulate `row_map` for O(1) logical-to-physical remapping and only mark recycled (blank) rows dirty. However, the pixel buffer (backend shadow/SHM) still contains pixels from the previous frame at the old screen positions. Since moved rows are not marked dirty, they are never re-rendered, causing stale pixels on screen.

**Example**: Screen shows A,B,C,D. After `scrollUp(1)`:
- row_map correctly maps logical row 0 → physical "B"
- But pixel row 0 still shows "A" (from previous frame)
- Only the new blank row at bottom is re-rendered
- Result: screen shows A,B,C,blank instead of B,C,D,blank

This bug is masked during high-throughput output (e.g., `cat bigfile`) because subsequent writes mark all cells dirty. It is visible during interactive use with line-by-line scrolling.

### Solution: Pixel Buffer memmove

When scroll occurs, shift the pixel buffer content to match the new logical layout. Only the recycled rows need cell-level re-rendering.

**Architecture**:

Add scroll accumulator to `Term`:
```zig
// term.zig — new fields in Term struct
scroll_pixel_shift: i32 = 0,  // pixels to shift (positive = up, negative = down)
```

In `scrollUp(n)` (after existing row_map manipulation):
```zig
self.scroll_pixel_shift += @as(i32, @intCast(n)) * @as(i32, @intCast(config.cell_height));
```

In `scrollDown(n)`:
```zig
self.scroll_pixel_shift -= @as(i32, @intCast(n)) * @as(i32, @intCast(config.cell_height));
```

In the main render loop (before cell rendering), apply the accumulated shift:
```zig
if (term.scroll_pixel_shift != 0) {
    const buf = backend.getBuffer();
    const stride = backend.getStride();
    const height = backend.getHeight();
    const shift = term.scroll_pixel_shift;
    term.scroll_pixel_shift = 0;

    if (shift > 0) {
        // Scroll up: move pixels upward
        const byte_shift = @as(usize, @intCast(shift)) * stride;
        const total = @as(usize, height) * stride;
        if (byte_shift < total) {
            std.mem.copyForwards(u8, buf[0 .. total - byte_shift], buf[byte_shift..total]);
        }
    } else {
        // Scroll down: move pixels downward
        const byte_shift = @as(usize, @intCast(-shift)) * stride;
        const total = @as(usize, height) * stride;
        if (byte_shift < total) {
            std.mem.copyBackwards(u8, buf[byte_shift..total], buf[0 .. total - byte_shift]);
        }
    }
    // Backend needs to present the entire shifted region
    backend.markDirtyRows(0, height - 1);
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

**Impact**:
- Fixes visual correctness bug
- Eliminates re-rendering of all moved rows on scroll
- For 80x24 at scale=2: replaces 1840-cell render with ~1.8MB memmove
- memmove uses CPU SIMD instructions, vastly faster than per-cell glyph blitting

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
const is_space = cell.char == ' ' and !cell.attrs.bold and !cell.attrs.underline;
const glyph = if (is_space) null else FontType.getGlyph(cell.char);
```

The `renderCell` function already handles `glyph == null` by drawing a box outline fallback. For spaces, we want it to just fill the background. Modify the `null` glyph path:

Since space IS a valid glyph (exists in font), we need to distinguish "space = skip glyph blit" from "missing glyph = draw box". The simplest approach: pass `glyph` as-is but skip the glyph blit loop when the character is space.

Actually, simpler: just skip the getGlyph call and pass null. The render function's null-glyph path draws a box outline — we need to change that. Add a character parameter or handle space specially:

**Best approach**: In `renderCell`, skip the glyph blit section entirely when `glyph` is null AND `cell.char == ' '`. The existing box-outline fallback only triggers for truly missing glyphs (non-space null).

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
if (term.fg_rgb_map.count() > 0 or term.bg_rgb_map.count() > 0) {
    for (0..count) |j| {
        _ = term.fg_rgb_map.remove(phys_start + j);
        _ = term.bg_rgb_map.remove(phys_start + j);
    }
}
```

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

**Memory**: 256 × (4 + 24 + 1) = ~7.4KB. Negligible even on HackberryPi.

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

Additionally, `wide_dummy` cells are checked AFTER `getCell` and glyph lookup, wasting work.

### Solution

**6a: Early wide_dummy skip**

Move the `wide_dummy` check before `getFgRgb`/`getBgRgb`/`getGlyph`:

```zig
if (term.isDirty(x, y)) {
    const cell = term.getCell(x, y);
    if (cell.attrs.wide_dummy) continue;  // EARLY: before expensive lookups

    const fg_rgb = term.getFgRgb(x, y);
    const bg_rgb = term.getBgRgb(x, y);
    // ...
}
```

**6b: Inline cursor fg/bg swap**

Eliminate the 4-branch pattern:

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
- Eliminates getFgRgb/getBgRgb/getGlyph calls for wide_dummy cells
- Removes renderCursor function (dead code elimination)
- Reduces branch count from 4 to 2 in hot render loop

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
| 1 | Scroll pixel buffer | Medium (correctness fix) | High |
| 2 | Space glyph skip | Low | High |
| 3 | Render loop simplification | Low | Medium |
| 4 | TrueColor bulk path | Low | Medium (TrueColor content) |
| 5 | Non-ASCII glyph cache | Low | Medium (CJK content) |
| 6 | ReleaseFast docs | None | High (PC only) |

Scroll fix first because it's a correctness bug. Space skip and render loop next because they're low-risk high-reward. TrueColor and glyph cache improve specific workloads. ReleaseFast docs last (no code change).

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
