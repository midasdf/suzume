# zt Pixel Scaling Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add comptime integer pixel scaling (1x/2x/4x) to zt via `-Dscale=N` build flag, enabling PC-friendly display without new font blobs.

**Architecture:** A `comptime scale: u32` parameter is added to `renderCell`/`renderCursor`. Each bitmap pixel is drawn as a scale x scale block. Build system exposes `-Dscale`, config derives `cell_width`/`cell_height`, and main.zig/backends use cell dimensions for layout.

**Tech Stack:** Zig, XCB (X11 backend), Linux framebuffer

**Spec:** `docs/superpowers/specs/2026-03-25-zt-pixel-scaling-design.md`

---

## Chunk 1: Build Foundation + Signature Plumbing

All signature and layout changes first, with scale=1 default so behavior is unchanged and tests pass at every step.

### Task 1: Add -Dscale build option and config values

**Files:**
- Modify: `zt/build.zig`
- Modify: `zt/config.zig`

- [ ] **Step 1: Add scale option to build.zig**

In `zt/build.zig`, after line 11 (`const use_jp_keymap = ...`), add:

```zig
    const scale_opt = b.option(u32, "scale", "Pixel scale factor: 1, 2, or 4 (default: 1)") orelse 1;
```

After line 15 (`options.addOption(bool, "use_jp_keymap", use_jp_keymap);`), add:

```zig
    options.addOption(u32, "scale", scale_opt);
```

- [ ] **Step 2: Add scale and cell dimensions to config.zig**

In `zt/config.zig`, after line 14 (`pub const font_height: u32 = 16;`), add:

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

- [ ] **Step 3: Verify compilation with default scale=1**

Run: `cd /home/midasdf/zt && zig build test 2>&1`
Expected: All tests PASS.

- [ ] **Step 4: Verify invalid scales are rejected**

Run: `cd /home/midasdf/zt && zig build -Dscale=3 2>&1`
Expected: Compile error containing "scale must be 1, 2, or 4"

Run: `cd /home/midasdf/zt && zig build -Dscale=0 2>&1`
Expected: Compile error containing "scale must be 1, 2, or 4"

- [ ] **Step 5: Commit**

```bash
cd /home/midasdf/zt && git add build.zig config.zig && git commit -m "feat: add -Dscale build option with comptime validation"
```

### Task 2: Add scale parameter to render + update all call sites

These changes must happen together so the codebase compiles at every step. The test root module is `src/main.zig` which imports `render.zig`, so renderCell/renderCursor signatures and their call sites in main.zig must be consistent.

**Files:**
- Modify: `zt/src/render.zig` (signatures + existing test)
- Modify: `zt/src/main.zig` (all 4 render call sites + 3 grid calculations + dirty rows)
- Modify: `zt/src/backend/x11.zig` (initial window size)

- [ ] **Step 1: Add `comptime scale: u32` to renderCell signature**

In `zt/src/render.zig`, change the signature at line 89. Add `comptime scale: u32,` as the last parameter:

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

- [ ] **Step 2: Add `comptime scale: u32` to renderCursor and pass through**

In `zt/src/render.zig`, change renderCursor at line 228. Add `comptime scale: u32,` as the last parameter, and pass it in the internal renderCell call at line 248:

```zig
pub fn renderCursor(
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
    var inverted = cell;
    const tmp = inverted.fg;
    inverted.fg = inverted.bg;
    inverted.bg = tmp;
    renderCell(buffer, stride, cell_x, cell_y, inverted, bg_rgb_override, fg_rgb_override, glyph, font_w, font_h, pixel_format, wide, scale);
}
```

- [ ] **Step 3: Update existing renderCell test to pass scale=1**

In `zt/src/render.zig` at line 286, change:

```zig
    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32, false);
```
To:
```zig
    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32, false, 1);
```

- [ ] **Step 4: Update all 4 render call sites in main.zig**

In `zt/src/main.zig`, add `, config.scale` to the end of all four render calls. Each currently ends with `.bgra32, true)` or `.bgra32, false)`:

Line 512: `render.renderCursor(buf, stride, x, y, cell.*, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);`

Line 514: `render.renderCell(buf, stride, x, y, cell.*, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale);`

Line 518: `render.renderCursor(buf, stride, x, y, cell.*, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);`

Line 520: `render.renderCell(buf, stride, x, y, cell.*, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale);`

- [ ] **Step 5: Update 3 grid calculations in main.zig to use cell dimensions**

Line 262-263 (initial grid):
```zig
    const cols: u32 = backend.getWidth() / config.cell_width;
    const rows: u32 = backend.getHeight() / config.cell_height;
```

Line 312-313 (post-init X11 geometry sync):
```zig
            const new_cols = actual.w / config.cell_width;
            const new_rows = actual.h / config.cell_height;
```

Line 416-417 (ConfigureNotify resize):
```zig
                                    const new_cols = rsz.width / config.cell_width;
                                    const new_rows = rsz.height / config.cell_height;
```

- [ ] **Step 6: Update dirty row tracking in main.zig**

Line 524:
```zig
                    backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1);
```

- [ ] **Step 7: Update X11 initial window size**

In `zt/src/backend/x11.zig` line 117-118:
```zig
        const width: u32 = 80 * config.cell_width;
        const height: u32 = 24 * config.cell_height;
```

- [ ] **Step 8: Run tests — all should pass with scale=1 default**

Run: `cd /home/midasdf/zt && zig build test 2>&1`
Expected: ALL tests PASS. Behavior identical to before (scale=1 is a no-op).

- [ ] **Step 9: Commit**

```bash
cd /home/midasdf/zt && git add src/render.zig src/main.zig src/backend/x11.zig && git commit -m "feat: plumb scale parameter through render pipeline and layout"
```

## Chunk 2: Scaled Rendering Implementation

### Task 3: Write failing scale=2 test, then implement scaled rendering

**Files:**
- Modify: `zt/src/render.zig` (test + renderCell body)

- [ ] **Step 1: Write failing test for scale=2**

Add at end of `zt/src/render.zig`, after the `writePixel RGB565 format` test:

```zig
test "Render: renderCell scale=2 writes 2x2 pixel blocks" {
    const w = 8;
    const h = 16;
    const scale = 2;
    const bpp = 4;
    const stride = w * scale * bpp; // 64 bytes per row (16 pixels wide)
    var buffer: [stride * h * scale]u8 = [_]u8{0} ** (stride * h * scale);

    // Bitmap row 2 = 0x18 = 00011000 (bits 3 and 4 set)
    const bitmap = [_]u8{ 0x00, 0x00, 0x18, 0x24, 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00 };
    const glyph = GlyphView{ .codepoint = 'A', .width = 8, .height = 16, .bitmap = &bitmap };

    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32, false, scale);

    // Bitmap pixel (3, 2) at scale=2 → screen pixels (6, 4), (7, 4), (6, 5), (7, 5)
    // Check top-left of 2x2 block: screen row 4, col 6
    const row4_start = 4 * stride;
    const col6_offset = row4_start + 6 * bpp;
    try testing.expect(buffer[col6_offset + 2] > 0); // R channel at (6, 4)

    // Check bottom-right of 2x2 block: screen row 5, col 7
    const row5_start = 5 * stride;
    const col7_offset = row5_start + 7 * bpp;
    try testing.expect(buffer[col7_offset + 2] > 0); // R channel at (7, 5)

    // Bitmap row 1 = 0x00, so screen row 2 (second sub-row of bitmap row 1) is background
    const screen_row2 = 2 * stride;
    const screen_col3 = screen_row2 + 3 * bpp;
    try testing.expectEqual(@as(u8, 0), buffer[screen_col3 + 2]); // must be background
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/midasdf/zt && zig build test 2>&1`
Expected: FAIL — the scale=2 test fails because renderCell body still uses unscaled coordinates (pixels end up in wrong locations).

- [ ] **Step 3: Implement scaled rendering in renderCell body**

Replace the entire renderCell function body (everything between the opening `{` after the parameter list and the closing `}` before `renderCursor`) with the scaled implementation. The full replacement for `zt/src/render.zig` renderCell body:

```zig
    const render_w: u32 = if (wide) font_w * 2 else font_w;
    const scaled_w: u32 = render_w * scale;
    const scaled_h: u32 = font_h * scale;

    // 1. Determine fg/bg colors
    var fg_color = if (fg_rgb_override) |rgb| Color{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } else palette[cell.fg];
    var bg_color = if (bg_rgb_override) |rgb| Color{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } else palette[cell.bg];

    // 2. Handle reverse
    if (cell.attrs.reverse) {
        const tmp = fg_color;
        fg_color = bg_color;
        bg_color = tmp;
    }

    // 3. Handle dim
    if (cell.attrs.dim) {
        fg_color.r = @intCast(@as(u16, fg_color.r) * 3 / 5);
        fg_color.g = @intCast(@as(u16, fg_color.g) * 3 / 5);
        fg_color.b = @intCast(@as(u16, fg_color.b) * 3 / 5);
    }

    // 4. Bytes per pixel
    const bpp: u32 = switch (pixel_format) {
        .bgra32 => 4,
        .rgb565 => 2,
        .rgb24 => 3,
    };

    // 5. Bounds + scaled pixel offset
    const max_offset = buffer.len;
    const px_x = cell_x * font_w * scale;
    const px_y = cell_y * font_h * scale;

    // 6. Fill background rect (scaled dimensions)
    if (pixel_format == .bgra32) {
        const bg_packed = [4]u8{ bg_color.b, bg_color.g, bg_color.r, 0xFF };
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            if (row_offset + scaled_w * 4 > max_offset) continue;
            const pixels: [*][4]u8 = @ptrCast(buffer.ptr + row_offset);
            @memset(pixels[0..scaled_w], bg_packed);
        }
    } else {
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            for (0..scaled_w) |col| {
                const offset = row_offset + @as(u32, @intCast(col)) * bpp;
                if (offset + bpp > max_offset) continue;
                writePixel(buffer, offset, bg_color, pixel_format);
            }
        }
    }

    // 7. Draw glyph bitmap (iterate at original size, write scale x scale blocks)
    if (glyph) |g| {
        const bytes_per_row = (g.width + 7) / 8;
        if (pixel_format == .bgra32) {
            const fg_packed = [4]u8{ fg_color.b, fg_color.g, fg_color.r, 0xFF };
            for (0..@min(g.height, font_h)) |bmp_row| {
                for (0..@min(g.width, render_w)) |bmp_col| {
                    const byte_idx = bmp_row * bytes_per_row + bmp_col / 8;
                    const bit = @as(u8, 0x80) >> @intCast(bmp_col % 8);
                    if (byte_idx < g.bitmap.len and g.bitmap[byte_idx] & bit != 0) {
                        const screen_x = @as(u32, @intCast(bmp_col)) * scale;
                        for (0..scale) |sy| {
                            const screen_y = px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy));
                            const row_base = screen_y * stride + px_x * 4;
                            if (row_base + (screen_x + scale) * 4 > max_offset) continue;
                            for (0..scale) |sx| {
                                const px_off = row_base + (screen_x + @as(u32, @intCast(sx))) * 4;
                                @as(*[4]u8, @ptrCast(buffer.ptr + px_off)).* = fg_packed;
                            }
                        }
                        // Bold: adjacent bitmap column gets a scale x scale block
                        if (cell.attrs.bold and bmp_col + 1 < render_w) {
                            const bold_x = (@as(u32, @intCast(bmp_col)) + 1) * scale;
                            for (0..scale) |sy| {
                                const screen_y = px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy));
                                const row_base = screen_y * stride + px_x * 4;
                                if (row_base + (bold_x + scale) * 4 > max_offset) continue;
                                for (0..scale) |sx| {
                                    const px_off = row_base + (bold_x + @as(u32, @intCast(sx))) * 4;
                                    @as(*[4]u8, @ptrCast(buffer.ptr + px_off)).* = fg_packed;
                                }
                            }
                        }
                    }
                }
            }
        } else {
            for (0..@min(g.height, font_h)) |bmp_row| {
                for (0..@min(g.width, render_w)) |bmp_col| {
                    const byte_idx = bmp_row * bytes_per_row + bmp_col / 8;
                    const bit = @as(u8, 0x80) >> @intCast(bmp_col % 8);
                    if (byte_idx < g.bitmap.len and g.bitmap[byte_idx] & bit != 0) {
                        for (0..scale) |sy| {
                            for (0..scale) |sx| {
                                const offset = (px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy))) * stride + (px_x + @as(u32, @intCast(bmp_col)) * scale + @as(u32, @intCast(sx))) * bpp;
                                if (offset + bpp > max_offset) continue;
                                writePixel(buffer, offset, fg_color, pixel_format);
                            }
                        }
                        if (cell.attrs.bold and bmp_col + 1 < render_w) {
                            for (0..scale) |sy| {
                                for (0..scale) |sx| {
                                    const bold_offset = (px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy))) * stride + (px_x + (@as(u32, @intCast(bmp_col)) + 1) * scale + @as(u32, @intCast(sx))) * bpp;
                                    if (bold_offset + bpp > max_offset) continue;
                                    writePixel(buffer, bold_offset, fg_color, pixel_format);
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        // Missing glyph fallback: box outline with scale-pixel border
        for (0..scaled_h) |row| {
            for (0..scaled_w) |col| {
                if (row < scale or row >= scaled_h - scale or col < scale or col >= scaled_w - scale) {
                    const offset = (px_y + @as(u32, @intCast(row))) * stride + (px_x + @as(u32, @intCast(col))) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                }
            }
        }
    }

    // 8. Underline: at (font_h - 2) * scale with scale-pixel thickness
    if (cell.attrs.underline) {
        const ul_start = (font_h - 2) * scale;
        if (pixel_format == .bgra32) {
            const fg_packed = [4]u8{ fg_color.b, fg_color.g, fg_color.r, 0xFF };
            for (0..scale) |s| {
                const row_offset = (px_y + ul_start + @as(u32, @intCast(s))) * stride + px_x * bpp;
                if (row_offset + scaled_w * 4 <= max_offset) {
                    const pixels: [*][4]u8 = @ptrCast(buffer.ptr + row_offset);
                    @memset(pixels[0..scaled_w], fg_packed);
                }
            }
        } else {
            for (0..scale) |s| {
                const row_offset = (px_y + ul_start + @as(u32, @intCast(s))) * stride + px_x * bpp;
                for (0..scaled_w) |col| {
                    const offset = row_offset + @as(u32, @intCast(col)) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                }
            }
        }
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd /home/midasdf/zt && zig build test 2>&1`
Expected: ALL tests PASS, including the new scale=2 test and the existing scale=1 test.

- [ ] **Step 5: Verify scale=2 X11 build compiles**

Run: `cd /home/midasdf/zt && zig build -Dbackend=x11 -Dscale=2 2>&1`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /home/midasdf/zt && git add src/render.zig && git commit -m "feat: implement scaled pixel rendering for 2x/4x display"
```
