# zt Pixel Scaling Design

## Problem

zt's bitmap font is fixed at 8x16 pixels, optimized for HackberryPi's 720x720 display. On PC monitors (1080p+), this is too small to be usable. Creating separate larger font blobs for each target display is maintenance-heavy and unnecessary.

## Solution

Add comptime integer pixel scaling (1x/2x/4x) via a `-Dscale=N` build flag. Each font bitmap pixel is rendered as an NxN block of screen pixels. The font blob stays the same; only the rendering output changes.

## Design Principles

- Zero runtime overhead: `scale` is comptime, all multiplications become constants
- Minimal code change: localized to render.zig + plumbing in build/config/main
- fbdev: same total pixel writes (4x fewer cells, 4x more per cell = net zero on fixed resolution). X11: window grows with scale, total writes scale with scale^2, but cell count stays the same (80x24 default)

## Build System

### build.zig

Add a `-Dscale` option (default: 1):

```zig
const scale_opt = b.option(u32, "scale", "Pixel scale factor: 1, 2, or 4 (default: 1)") orelse 1;
options.addOption(u32, "scale", scale_opt);
```

### config.zig

Expose scale and derived cell dimensions:

```zig
pub const scale: u32 = build_options.scale;
pub const cell_width: u32 = font_width * scale;
pub const cell_height: u32 = font_height * scale;

comptime {
    if (scale != 1 and scale != 2 and scale != 4) {
        @compileError("scale must be 1, 2, or 4");
    }
}
```

- `font_width` / `font_height` (8/16): bitmap glyph dimensions, unchanged
- `cell_width` / `cell_height`: screen cell dimensions, used for layout

## Rendering

### render.zig

Both `renderCell` and `renderCursor` gain a `comptime scale: u32` parameter. `renderCursor` passes it through to `renderCell`. All four call sites in main.zig (two `renderCell`, two `renderCursor`) must be updated.

#### Pixel offset calculation

The cell-to-pixel coordinate conversion must account for scale:

```zig
const px_x = cell_x * font_w * scale;
const px_y = cell_y * font_h * scale;
```

This ensures cells are positioned at scaled intervals. `font_w` and `font_h` remain the bitmap dimensions (8/16); the multiplication by `scale` produces the screen-space offset.

#### Background fill

Loop range changes from `font_h` to `font_h * scale`, row width from `render_w` to `render_w * scale`:

```zig
for (0..font_h * scale) |row| {
    // @memset render_w * scale pixels
}
```

#### Glyph blit

Bitmap iteration stays at original font dimensions. Each set bit writes a scale x scale block:

```zig
for (0..g.height) |bmp_row| {
    for (0..g.width) |bmp_col| {
        if (bit is set) {
            for (0..scale) |sy| {
                for (0..scale) |sx| {
                    write pixel at (bmp_col*scale+sx, bmp_row*scale+sy)
                }
            }
        }
    }
}
```

BGRA32 fast path optimizations:
- Horizontal: write scale consecutive pixels via direct assignment or small `@memset`
- Vertical: duplicate rows via `@memcpy` (L1 cache-friendly for scale=2/4)

#### Bold

Bold operates at the bitmap level (before scaling): when a bitmap bit is set and bold is active, the adjacent bitmap column also gets a scale x scale block. This means bold shifts by 1 glyph pixel (= `scale` screen pixels), preserving visual weight proportional to scale. At scale=1 this is identical to current behavior (1px shift).

#### Underline

Position is scaled from the original: `(font_h - 2) * scale`, with thickness of `scale` pixels (drawing `scale` consecutive rows). At scale=1: position 14, 1px thick (matches current). At scale=2: position 28, 2px thick.

#### Box fallback (missing glyph)

Box outline drawn at scaled cell dimensions (`render_w * scale` x `font_h * scale`), border thickness = `scale` pixels.

## main.zig Changes

Replace `config.font_width` / `config.font_height` with `config.cell_width` / `config.cell_height` at these specific locations:

1. **Line 262-263**: Initial grid calculation — `cols = width / config.cell_width`, `rows = height / config.cell_height`
2. **Line 312-313**: Post-init X11 geometry sync — same substitution
3. **Line 416-417**: X11 ConfigureNotify resize handler — same substitution
4. **Line 524**: Dirty row tracking — `backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1)`
5. **Lines 512, 514, 518, 520**: All four render calls (two `renderCell`, two `renderCursor`) — pass `config.font_width`, `config.font_height`, `config.scale` as comptime args

## Backend Changes

### x11.zig

Initial window size uses cell dimensions:

```zig
const width: u32 = 80 * config.cell_width;
const height: u32 = 24 * config.cell_height;
```

### fbdev.zig

No changes. Framebuffer size is hardware-fixed. The grid calculation in main.zig using `cell_width`/`cell_height` automatically produces fewer cols/rows at higher scale.

## File Change Summary

| File | Change |
|------|--------|
| `build.zig` | Add `-Dscale` option, pass to build_options |
| `config.zig` | Add `scale`, `cell_width`, `cell_height`, comptime validation |
| `render.zig` | Add `scale` comptime param, scale all pixel writes |
| `main.zig` | Use `cell_width`/`cell_height` for layout, pass `scale` to render |
| `x11.zig` | Use `cell_width`/`cell_height` for initial window size |

## Testing

### Unit tests (render.zig)

- Existing `renderCell writes pixels to buffer` test extended for scale=2: buffer and stride must use `w * scale` dimensions, pixel position assertions updated to scaled coordinates
- Verify cell output buffer is `(font_w * scale) * (font_h * scale)` pixels
- Verify glyph pixels appear as scale x scale blocks

### Comptime validation

- `zig build -Dscale=3` produces a compile error
- `zig build -Dscale=0` produces a compile error

### Manual verification

- `zig build -Dbackend=x11 -Dscale=2`: window opens, text renders at 2x
- CJK (wide), Nerd Fonts icons, bold, underline, cursor all render correctly at 2x
- `zig build -Dscale=1`: unchanged behavior (regression check)

## Usage Examples

```bash
# HackberryPi (default, 8x16 cells)
zig build -Dbackend=fbdev -Dkeymap=jp

# PC with Full HD monitor (16x32 cells)
zig build -Dbackend=x11 -Dscale=2

# PC with 4K monitor (32x64 cells)
zig build -Dbackend=x11 -Dscale=4
```
