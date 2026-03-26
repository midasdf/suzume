# zt Extreme Throughput Maximization Design

## Problem

zt achieves 84 MB/s throughput (dense ASCII, 80×24, x86_64/X11), already 2× foot and 3× st/xterm. The goal is to push throughput significantly further, primarily targeting x86_64/X11 benchmarks while maintaining aarch64/fbdev compatibility.

## Target Workload

Dense ASCII throughput (`cat bigfile`, `seq 1 1000000`). This is the standard terminal throughput benchmark: large volumes of printable ASCII with frequent newlines, causing continuous scrolling.

## Bottleneck Analysis

During dense ASCII output at 15fps (tier 2):
- **66ms** between frames
- **~5.6MB** parsed per frame interval
- **1,920 cells** (80×24) rendered per frame (scroll saturation makes entire screen dirty)
- Throughput = parse_speed × (frame_interval - render_time) / frame_interval

Two levers: **make rendering faster** (reduce render_time) and **render less often** (increase frame_interval). Both directly increase throughput.

## Target Platforms

| Platform | Build | Priority |
|----------|-------|----------|
| PC (x86_64, X11) | ReleaseFast | Primary — maximize throughput |
| HackberryPi (aarch64, fbdev) | ReleaseSmall | Secondary — maintain compatibility |

All code changes apply to both platforms. Memory increase (+768KB PTY buffer) is acceptable on both.

---

## Optimization 1: Scroll Pixel Buffer memmove

### Problem

`scrollUp`/`scrollDown` mark the entire scroll region dirty, forcing re-render of all cells. For 80×24, that's 1,920 cells per scroll event, even though most pixels just shifted position.

### Solution

Accumulate scroll shifts in `Term`, apply as pixel buffer memmove before the render loop. Only mark recycled (blank) rows dirty.

Add to `Term`:
```zig
scroll_row_shift: i32 = 0,
scroll_shift_top: u32 = 0,
scroll_shift_bot: u32 = 0,
```

In `scrollUp(n)`: replace full-region `markDirtyRange` with shift accumulation + per-recycled-row dirty.
In `scrollDown(n)`: same with negative shift.

In `main.zig`, before the render loop: apply accumulated memmove via `std.mem.copyForwards`/`copyBackwards`, then reset accumulator.

**Saturation**: When `|shift| >= region_height`, skip memmove — all rows already dirty from per-row marking. This is the `cat bigfile` case.

**Impact**: Interactive scrolling (git log, man, moderate output): 24× render reduction. Dense ASCII saturated: no effect (degrades gracefully to full re-render).

### Files Changed

| File | Change |
|------|--------|
| `src/term.zig` | Add scroll accumulator fields, modify `scrollUp`/`scrollDown` dirty strategy |
| `src/main.zig` | Add pixel buffer memmove before render loop |

---

## Optimization 2: Direct Cell Access in Render Loop

### Problem

The render loop calls `term.getCell(x, y)`, `term.getFgRgb(x, y)`, `term.getBgRgb(x, y)` per cell. Each call performs: bounds check + `row_map[y] * cols + x` (multiplication + array index). For 1,920 cells: 5,760 bounds checks, 5,760 multiplications, 5,760 row_map lookups.

### Solution

Resolve the physical row pointer once per row, then iterate columns with direct array access:

```zig
while (y < term.rows) : (y += 1) {
    if (!skip_dirty_check and !term.isRowDirty(y)) continue;
    const phys_row = term.row_map[y];
    const row_base = @as(usize, phys_row) * @as(usize, term.cols);
    const row_cells = term.cells[row_base..][0..term.cols];
    const row_fg = term.fg_rgb[row_base..][0..term.cols];
    const row_bg = term.bg_rgb[row_base..][0..term.cols];

    var x: u32 = 0;
    while (x < term.cols) : (x += 1) {
        if (skip_dirty_check or term.isDirty(x, y)) {
            const cell = &row_cells[x];
            if (cell.attrs.wide_dummy) continue;
            const fg_rgb = row_fg[x];
            const bg_rgb = row_bg[x];
            // ... glyph lookup, renderCell ...
        }
    }
}
```

**Impact**: Per-cell overhead reduced by ~40%. 5,760 multiplications → 24. 5,760 bounds checks eliminated.

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Restructure render loop with per-row pointer resolution |

---

## Optimization 3: All-Dirty Global Background Fill

### Problem

When `all_dirty = true` (every frame during dense ASCII output), every cell gets individual background fill via `renderCell` — 1,920 separate `@memset` calls of `cell_width × 4` bytes each per pixel row (30,720 memset calls total for 80×24 at scale=1).

### Solution

When `all_dirty` is true, replace per-cell background fill with a two-phase render:

**Phase 1**: Fill entire pixel buffer with default background color in one pass.
```zig
const default_bg = render.palette[0]; // color index 0 = black
const bg_packed = [4]u8{ default_bg.b, default_bg.g, default_bg.r, 0xFF };
const pixel_buf: [*][4]u8 = @ptrCast(buf.ptr);
@memset(pixel_buf[0..total_pixels], bg_packed);
```

**Phase 2**: For cells with non-default background, fill individual cell rects.

**Phase 3**: Blit glyphs for non-space cells only (skip renderCell, call a glyph-only blit).

For plain text output (default bg on all cells): Phase 2 does zero work. Phase 3 processes only ~50% of cells (spaces skipped). Combined with Phase 1 being a single ~1MB memset (CPU SIMD optimized), this is dramatically faster than 30,720 individual memsets.

When `all_dirty = false` (interactive use, cursor blink): use the existing per-cell `renderCell` path unchanged. No regression for partial updates.

**Implementation detail**: To avoid duplicating render logic, call `renderCell` normally but pass a flag or use a wrapper that skips the background fill step when global fill was already applied. Alternatively, split `renderCell` internals so background fill and glyph blit are independently callable.

The simplest approach: add a comptime `skip_bg: bool` parameter to `renderCell`. When true, skip the background fill loop (section 6 in renderCell). Since it's comptime, the unused code path is eliminated entirely.

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Add global BG fill before render loop when `all_dirty` |
| `src/render.zig` | Add comptime `skip_bg` parameter to `renderCell` |

---

## Optimization 4: PTY Read Buffer Enlargement

### Problem

PTY read buffer is 256KB. During dense ASCII at 15fps, ~5.6MB is parsed per 66ms frame interval, requiring ~22 `read()` syscalls.

### Solution

Increase PTY read buffer to 1MB:
```zig
var pty_buf: [1_048_576]u8 = undefined;
```

Also increase extra drain cap from 1MB to 4MB to allow more parsing between frames:
```zig
while (extra_total < 4_194_304) {
```

**Impact**: Read syscalls per frame: 22 → ~6. Extra drain processes more data per frame interval.

**Memory**: +768KB stack. Single-threaded, no concern.

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Change `pty_buf` size to 1MB, extra drain cap to 4MB |

---

## Optimization 5: Tier 3 Frame Limiter

### Problem

At tier 2 (>256KB buffered), zt renders at 15fps (66ms intervals). During `cat bigfile`, the screen scrolls too fast to read anyway. Spending 66ms intervals (with render overhead) limits parse throughput.

### Solution

Add tier 3 for extreme output bursts:

| Tier | Trigger | FPS | Frame interval |
|------|---------|-----|----------------|
| 0 | < 64KB | 120 | 8ms |
| 1 | 64KB+ | 60 | 16ms |
| 2 | 256KB+ | 15 | 66ms |
| **3** | **1MB+** | **5** | **200ms** |

```zig
const effective_frame_ns: i128 = if (config.frame_min_ns == 0) 0
    else if (bytes_since_render > 1_048_576) @as(i128, config.frame_min_ns) * 24
    else if (bytes_since_render > 262_144) @as(i128, config.frame_min_ns) * 8
    else if (bytes_since_render > 65_536) @as(i128, config.frame_min_ns) * 2
    else @as(i128, config.frame_min_ns);
```

**Impact**: 3× more parse time per frame interval during extreme output. Visual impact: none — content scrolls too fast to read at these data rates.

**Recovery**: Once output stops, `bytes_since_render` resets to 0 after the next render, immediately restoring 120fps responsiveness.

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Add tier 3 threshold to frame limiter |

---

## Optimization 6: scrollUp RGB Clear Skip

### Problem

`scrollUp` calls `clearRgbRow(phys)` on every recycled row — `@memset` of `cols × sizeof(?[3]u8)` for both fg_rgb and bg_rgb arrays (~640 bytes per scroll). During `cat bigfile`, thousands of scrolls occur per frame. When `all_dirty` is already true and no TrueColor is active, the RGB arrays will be overwritten by incoming data before the next render.

### Solution

Skip RGB clear when conditions guarantee overwrite:

```zig
if (!self.all_dirty or self.current_fg_rgb != null or self.current_bg_rgb != null) {
    self.clearRgbRow(phys);
}
```

When `all_dirty = true` AND no TrueColor is active (the common dense ASCII case), skip the clear entirely. The bulk write path in `feedBulk` (vt.zig:461-465) already sets rgb values via `@memset` for the entire written range, and the cell write overwrites the recycled row's content.

**Safety**: When TrueColor IS active (`current_fg_rgb != null` or `current_bg_rgb != null`), always clear to prevent stale RGB values from appearing. When `all_dirty = false`, always clear because partial renders might expose stale data.

**Impact**: ~640 bytes × thousands of scrolls per frame = several MB of memset eliminated per frame interval.

### Files Changed

| File | Change |
|------|--------|
| `src/term.zig` | Conditional `clearRgbRow` in `scrollUp`/`scrollDown` |

---

## Optimization 7: nanoTimestamp Deduplication

### Problem

`std.time.nanoTimestamp()` (maps to `clock_gettime(CLOCK_MONOTONIC)`) is called twice per main loop iteration: once for epoll timeout calculation, once for `last_render_ns` update after render. Each is a syscall.

### Solution

Call once at loop start, reuse the value:

```zig
const loop_now = std.time.nanoTimestamp();
// Use loop_now for epoll timeout calculation
// Use loop_now for last_render_ns after render
```

The timing inaccuracy (loop processing time between the two uses) is <1ms, negligible relative to 8-200ms frame intervals.

### Files Changed

| File | Change |
|------|--------|
| `src/main.zig` | Single `nanoTimestamp` call per loop iteration |

---

## Implementation Order

| Order | Optimization | Risk | Impact on Dense ASCII |
|-------|-------------|------|----------------------|
| 1 | Tier 3 frame limiter | None | High — 3× more parse time |
| 2 | PTY buffer 1MB | None | Medium — fewer syscalls |
| 3 | nanoTimestamp dedup | None | Low — minor syscall reduction |
| 4 | Direct cell access | Low | Medium — ~40% per-cell overhead reduction |
| 5 | All-dirty global BG fill | Low | High — 30K memsets → 1 memset |
| 6 | scrollUp RGB clear skip | Low | Medium — MB of memset eliminated |
| 7 | Scroll pixel buffer memmove | Medium | Low for saturated, High for interactive |

Zero/no-risk changes first. Scroll memmove last (most complex, least benefit for target workload).

## Verification

After each optimization:
1. `zig build test` — all unit tests pass
2. Visual test: `cat` a large file, verify no rendering artifacts
3. Throughput benchmark: `time cat /dev/urandom | base64 | head -c 10000000` in zt

After all optimizations:
1. Full benchmark comparison: startup, throughput, RSS
2. Compare against foot, st, xterm, alacritty, kitty
3. Interactive test: fish shell, vim, btop — verify no regressions
4. 24-hour stability test on HackberryPi

## Non-Goals

- No architecture changes (single-threaded epoll stays)
- No new features (scrollback, mouse, etc.)
- No font format changes
- No SIMD glyph blit (complexity vs gain ratio too high for bitmap fonts)
- No io_uring (x86_64 only, kernel version dependency)
