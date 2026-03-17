const std = @import("std");
const nsfb = @import("../bindings/nsfb.zig");
const c = nsfb.c;

/// Manual surface registration (constructor workaround)
extern fn nsfb_surface_init_all() void;

/// Cursor shape change (defined in x.c)
extern fn nsfb_x_set_cursor_shape(fb: *c.nsfb_t, shape: c_int) void;

/// Get the X11 window ID from the xcb backend (defined in x.c)
extern fn nsfb_x_get_window_id(fb: *c.nsfb_t) c_ulong;

/// Raw X11 keycode/state from last key event (defined in x.c)
extern var nsfb_x_last_keycode: c_uint;
extern var nsfb_x_last_keystate: c_uint;

/// XIM helper functions (defined in xim_helper.c)
extern fn xim_init(window_id: c_ulong) c_int;
extern fn xim_process_key(keycode: c_uint, state: c_uint, is_press: c_int, buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_poll_committed(buf: [*]u8, buf_size: c_int) c_int;
extern fn xim_focus_in() void;
extern fn xim_focus_out() void;
extern fn xim_cleanup() void;

pub const CursorShape = enum(c_int) {
    arrow = 0,
    pointer = 1, // hand cursor for links
    text = 2, // I-beam for text inputs
};

pub const Surface = struct {
    fb: *c.nsfb_t,
    width: i32,
    height: i32,
    xim_initialized: bool = false,

    /// Create and initialize an X11 window surface.
    pub fn init(width: i32, height: i32) !Surface {
        // Register surface backends (Zig linker doesn't run C constructors)
        nsfb_surface_init_all();

        const surface_type = c.nsfb_type_from_name("x");
        if (surface_type == c.NSFB_SURFACE_NONE) {
            return error.SurfaceTypeNotFound;
        }

        const fb = c.nsfb_new(surface_type) orelse return error.NsfbNewFailed;

        if (c.nsfb_set_geometry(fb, width, height, c.NSFB_FMT_XRGB8888) != 0) {
            _ = c.nsfb_free(fb);
            return error.SetGeometryFailed;
        }

        if (c.nsfb_init(fb) != 0) {
            _ = c.nsfb_free(fb);
            return error.InitFailed;
        }

        return .{
            .fb = fb,
            .width = width,
            .height = height,
        };
    }

    /// Query the actual framebuffer geometry from libnsfb.
    /// Call this after a resize event to update width/height.
    pub fn refreshGeometry(self: *Surface) void {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.nsfb_get_geometry(self.fb, &w, &h, null);
        self.width = @intCast(w);
        self.height = @intCast(h);
    }

    pub fn deinit(self: *Surface) void {
        _ = c.nsfb_free(self.fb);
    }

    /// Fill a rectangle with an ABGR colour (libnsfb native format).
    /// libnsfb colour layout: bits 0-7=R, 8-15=G, 16-23=B, 24-31=A
    pub fn fillRect(self: *Surface, x: i32, y: i32, w: i32, h: i32, colour: u32) void {
        var bbox = c.nsfb_bbox_t{
            .x0 = x,
            .y0 = y,
            .x1 = x + w,
            .y1 = y + h,
        };
        _ = c.nsfb_plot_rectangle_fill(self.fb, &bbox, colour);
    }

    /// Fill a rectangle with alpha blending.
    /// The colour is in libnsfb ABGR format with alpha in bits 24-31.
    /// If alpha is 255, delegates to fillRect for speed. If 0, does nothing.
    pub fn fillRectBlend(self: *Surface, x: i32, y: i32, w: i32, h: i32, colour: u32) void {
        const alpha = @as(u8, @truncate((colour >> 24) & 0xFF));
        if (alpha == 0) return;
        if (alpha == 255) {
            self.fillRect(x, y, w, h, colour);
            return;
        }

        // Need manual alpha blending — get framebuffer pointer
        const nsfb_c = @import("../bindings/nsfb.zig").c;
        var raw_ptr: ?[*]u8 = null;
        var fb_stride: c_int = 0;
        if (nsfb_c.nsfb_get_buffer(self.fb, @ptrCast(&raw_ptr), &fb_stride) != 0) return;
        const fb_ptr: [*]u8 = raw_ptr orelse return;
        const stride: usize = @intCast(fb_stride);

        // Clip to surface bounds
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, self.width);
        const y1 = @min(y + h, self.height);
        if (x0 >= x1 or y0 >= y1) return;

        // Extract foreground color components from libnsfb colour format:
        // colour = 0xAABBGGRR (R in low bits, B in high bits)
        // Memory layout (XRGB8888, little-endian): byte[0]=B, byte[1]=G, byte[2]=R, byte[3]=X
        const fg_b: u16 = @truncate((colour >> 16) & 0xFF);
        const fg_g: u16 = @truncate((colour >> 8) & 0xFF);
        const fg_r: u16 = @truncate(colour & 0xFF);
        const a: u16 = alpha;
        const inv_a: u16 = 255 - a;

        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            const row_offset: usize = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(x0)) * 4;
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = row_offset + @as(usize, @intCast(px - x0)) * 4;
                fb_ptr[idx + 0] = @intCast((@as(u16, fb_ptr[idx + 0]) * inv_a + fg_b * a) / 255);
                fb_ptr[idx + 1] = @intCast((@as(u16, fb_ptr[idx + 1]) * inv_a + fg_g * a) / 255);
                fb_ptr[idx + 2] = @intCast((@as(u16, fb_ptr[idx + 2]) * inv_a + fg_r * a) / 255);
                fb_ptr[idx + 3] = 0xFF;
            }
        }
    }

    /// Blit an 8-bit grayscale glyph bitmap at (x, y) with the given foreground colour.
    /// Uses libnsfb's built-in glyph8 plotter which handles alpha blending.
    pub fn blitGlyph8(self: *Surface, x: i32, y: i32, w: i32, h: i32, pixels: [*]const u8, pitch: i32, colour: u32) void {
        var bbox = c.nsfb_bbox_t{
            .x0 = x,
            .y0 = y,
            .x1 = x + w,
            .y1 = y + h,
        };
        _ = c.nsfb_plot_glyph8(self.fb, &bbox, pixels, pitch, colour);
    }

    /// Flip buffer to screen (update entire surface).
    pub fn update(self: *Surface) void {
        var bbox = c.nsfb_bbox_t{
            .x0 = 0,
            .y0 = 0,
            .x1 = self.width,
            .y1 = self.height,
        };
        _ = c.nsfb_update(self.fb, &bbox);
    }

    /// Set the mouse cursor shape.
    pub fn setCursor(self: *Surface, shape: CursorShape) void {
        nsfb_x_set_cursor_shape(self.fb, @intFromEnum(shape));
    }

    // ── XIM (X Input Method) support ──────────────────────────────

    /// Initialize XIM for this surface's X11 window.
    /// Call once after the surface is created. Returns true on success.
    pub fn initXim(self: *Surface) bool {
        const win_id = nsfb_x_get_window_id(self.fb);
        if (win_id == 0) return false;
        const result = xim_init(win_id);
        self.xim_initialized = (result == 0);
        return self.xim_initialized;
    }

    /// Process a key event through XIM. Uses the raw X11 keycode/state
    /// stored by the last nsfb key event in x.c.
    /// Returns composed UTF-8 text, or null if the event was filtered
    /// (composing) or produced no text output.
    pub fn processKeyXim(self: *Surface, is_press: bool) ?[]const u8 {
        _ = self;
        var buf: [128]u8 = undefined;
        const len = xim_process_key(
            nsfb_x_last_keycode,
            nsfb_x_last_keystate,
            if (is_press) 1 else 0,
            &buf,
            128,
        );
        if (len > 0) {
            // Copy to a static buffer since the stack buf will be invalidated
            const static = struct {
                var storage: [128]u8 = undefined;
            };
            @memcpy(static.storage[0..@intCast(len)], buf[0..@intCast(len)]);
            return static.storage[0..@intCast(len)];
        }
        return null;
    }

    /// Poll for committed text from XIM (e.g., Mozc confirmed input).
    /// Call this in the main event loop to receive asynchronous commits.
    pub fn pollXimCommitted(_: *Surface) ?[]const u8 {
        const S = struct {
            var storage: [128]u8 = undefined;
        };
        const len = xim_poll_committed(&S.storage, 128);
        if (len > 0) return S.storage[0..@as(usize, @intCast(len))];
        return null;
    }

    /// Notify XIM that the window gained focus.
    pub fn ximFocusIn(_: *Surface) void {
        xim_focus_in();
    }

    /// Notify XIM that the window lost focus.
    pub fn ximFocusOut(_: *Surface) void {
        xim_focus_out();
    }

    /// Clean up XIM resources.
    pub fn deinitXim(self: *Surface) void {
        if (self.xim_initialized) {
            xim_cleanup();
            self.xim_initialized = false;
        }
    }

    /// Poll for input events.
    /// timeout: milliseconds to wait (-1 = forever, 0 = immediate).
    /// Returns null if no event within timeout.
    pub fn pollEvent(self: *Surface, timeout: i32) ?c.nsfb_event_t {
        var event: c.nsfb_event_t = std.mem.zeroes(c.nsfb_event_t);
        if (c.nsfb_event(self.fb, &event, timeout)) {
            return event;
        }
        return null;
    }

    /// Fill a rounded rectangle with per-corner radii, using scanline fills.
    /// Uses the midpoint circle algorithm (same as libnsfb's circlefill) to compute
    /// horizontal spans for each corner, avoiding per-pixel plotPoint calls.
    /// r_tl, r_tr, r_bl, r_br are the radii for each corner.
    pub fn fillRoundedRectPerCorner(self: *Surface, x: i32, y: i32, w: i32, h: i32, r_tl: i32, r_tr: i32, r_bl: i32, r_br: i32, colour: u32) void {
        if (w <= 0 or h <= 0) return;

        const half_w = @divTrunc(w, 2);
        const half_h = @divTrunc(h, 2);
        const max_r = @min(half_w, half_h);

        // Clamp each radius
        const tl = @min(@max(r_tl, 0), max_r);
        const tr = @min(@max(r_tr, 0), max_r);
        const bl = @min(@max(r_bl, 0), max_r);
        const br = @min(@max(r_br, 0), max_r);

        // If all radii are zero, just fill a plain rect
        if (tl == 0 and tr == 0 and bl == 0 and br == 0) {
            self.fillRect(x, y, w, h, colour);
            return;
        }

        // Precompute corner span offsets using the midpoint circle algorithm.
        // For radius r, span_offsets[dy] = the x-extent at row dy from the corner.
        // This is equivalent to libnsfb's circle_midpoint with circlefill callback,
        // but we store spans instead of drawing them immediately.
        // Stack-allocate span table for each corner. Each entry is the
        // horizontal extent of the circle at that row from the corner center.
        var tl_spans: [128]i32 = undefined;
        var tr_spans: [128]i32 = undefined;
        var bl_spans: [128]i32 = undefined;
        var br_spans: [128]i32 = undefined;

        if (tl > 0) computeCornerSpans(tl_spans[0..@intCast(tl)], tl);
        if (tr > 0) computeCornerSpans(tr_spans[0..@intCast(tr)], tr);
        if (bl > 0) computeCornerSpans(bl_spans[0..@intCast(bl)], bl);
        if (br > 0) computeCornerSpans(br_spans[0..@intCast(br)], br);

        // Draw the rectangle row by row using scanline fills.
        // For each row, compute left_inset and right_inset from corners,
        // then fill a single horizontal span.
        var row: i32 = 0;
        while (row < h) : (row += 1) {
            var left_inset: i32 = 0;
            var right_inset: i32 = 0;

            // Top-left corner affects rows 0..tl-1
            if (row < tl) {
                left_inset = @max(left_inset, tl - 1 - tl_spans[@intCast(tl - 1 - row)]);
            }
            // Top-right corner affects rows 0..tr-1
            if (row < tr) {
                right_inset = @max(right_inset, tr - 1 - tr_spans[@intCast(tr - 1 - row)]);
            }
            // Bottom-left corner affects rows (h-bl)..h-1
            if (row >= h - bl) {
                const corner_row = row - (h - bl);
                left_inset = @max(left_inset, bl - 1 - bl_spans[@intCast(corner_row)]);
            }
            // Bottom-right corner affects rows (h-br)..h-1
            if (row >= h - br) {
                const corner_row = row - (h - br);
                right_inset = @max(right_inset, br - 1 - br_spans[@intCast(corner_row)]);
            }

            const span_x = x + left_inset;
            const span_w = w - left_inset - right_inset;
            if (span_w > 0) {
                self.fillRect(span_x, y + row, span_w, 1, colour);
            }
        }
    }

    /// Compute corner span widths using the midpoint circle algorithm.
    /// For a quarter-circle of given radius, spans[i] = max x-extent at row i
    /// where i=0 is the row closest to the flat edge and i=r-1 is the outermost row.
    /// This mirrors libnsfb's circle_midpoint algorithm.
    fn computeCornerSpans(spans: []i32, r: i32) void {
        // Initialize all spans to 0
        for (spans) |*s| s.* = 0;

        // Midpoint circle algorithm (same as libnsfb generic.c circle_midpoint)
        var cx: i32 = 0;
        var cy: i32 = r;
        var p: i32 = 1 - r;

        // Record symmetric spans
        setCornerSpan(spans, r, cx, cy);
        setCornerSpan(spans, r, cy, cx);

        while (cx < cy) {
            cx += 1;
            if (p < 0) {
                p += 2 * cx + 1;
            } else {
                cy -= 1;
                p += 2 * (cx - cy) + 1;
            }
            setCornerSpan(spans, r, cx, cy);
            setCornerSpan(spans, r, cy, cx);
        }
    }

    /// Helper: record that at vertical offset `cy` from center, the circle extends `cx` pixels.
    /// spans are indexed from 0 (flat edge, closest to center) to r-1 (outermost).
    fn setCornerSpan(spans: []i32, r: i32, cx: i32, cy: i32) void {
        // cy is distance from center; row index from flat edge = r - 1 - cy (inverted)
        // But we want: row 0 = closest to the flat edge (near center), row r-1 = outermost
        // In circle coords: cy=0 is center row, cy=r is edge row
        // Our mapping: span_index = cy (0=center/flat, r-1=edge/outermost)
        // span value = cx (how far the circle extends at this row)
        if (cy >= 0 and cy < r) {
            const idx: usize = @intCast(cy);
            if (cx > spans[idx]) spans[idx] = cx;
        }
    }

    /// Fill a rounded rectangle with uniform radius (convenience wrapper).
    pub fn fillRoundedRect(self: *Surface, x: i32, y: i32, w: i32, h: i32, r_raw: i32, colour: u32) void {
        self.fillRoundedRectPerCorner(x, y, w, h, r_raw, r_raw, r_raw, r_raw, colour);
    }

    /// Fill a rectangle with a vertical or horizontal linear gradient (two colors).
    /// color_start and color_end are in libnsfb ABGR format.
    pub fn fillGradientRect(self: *Surface, x: i32, y: i32, w: i32, h: i32, color_start: u32, color_end: u32, horizontal: bool) void {
        if (w <= 0 or h <= 0) return;

        // Clip to surface bounds
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, self.width);
        const y1 = @min(y + h, self.height);
        if (x0 >= x1 or y0 >= y1) return;

        // Get framebuffer pointer
        const nsfb_c = @import("../bindings/nsfb.zig").c;
        var raw_ptr: ?[*]u8 = null;
        var fb_stride: c_int = 0;
        if (nsfb_c.nsfb_get_buffer(self.fb, @ptrCast(&raw_ptr), &fb_stride) != 0) return;
        const fb_ptr: [*]u8 = raw_ptr orelse return;
        const stride: usize = @intCast(fb_stride);

        // Extract ABGR components for start and end colors (use u32 to prevent overflow)
        const s_r: u32 = color_start & 0xFF;
        const s_g: u32 = (color_start >> 8) & 0xFF;
        const s_b: u32 = (color_start >> 16) & 0xFF;
        const s_a: u32 = (color_start >> 24) & 0xFF;
        const e_r: u32 = color_end & 0xFF;
        const e_g: u32 = (color_end >> 8) & 0xFF;
        const e_b: u32 = (color_end >> 16) & 0xFF;
        const e_a: u32 = (color_end >> 24) & 0xFF;

        // Use original dimensions for interpolation (not clipped) to avoid visual shift
        const steps: u32 = @intCast(if (horizontal) w else h);
        if (steps == 0) return;

        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            const row_offset: usize = @as(usize, @intCast(py)) * stride;
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                // t based on original coordinate, not clipped
                const t: u32 = @intCast(if (horizontal) (px - x) else (py - y));
                // Interpolate each channel in u32 to prevent overflow
                const r: u8 = @intCast((s_r * (steps - t) + e_r * t) / steps);
                const g: u8 = @intCast((s_g * (steps - t) + e_g * t) / steps);
                const b: u8 = @intCast((s_b * (steps - t) + e_b * t) / steps);
                const a: u8 = @intCast((s_a * (steps - t) + e_a * t) / steps);

                const idx = row_offset + @as(usize, @intCast(px)) * 4;
                if (a == 255) {
                    // Opaque: write directly (XRGB8888 little-endian: B, G, R, X)
                    fb_ptr[idx + 0] = b;
                    fb_ptr[idx + 1] = g;
                    fb_ptr[idx + 2] = r;
                    fb_ptr[idx + 3] = 0xFF;
                } else if (a > 0) {
                    // Alpha blend
                    const a16: u16 = a;
                    const inv_a: u16 = 255 - a16;
                    fb_ptr[idx + 0] = @intCast((@as(u16, fb_ptr[idx + 0]) * inv_a + @as(u16, b) * a16) / 255);
                    fb_ptr[idx + 1] = @intCast((@as(u16, fb_ptr[idx + 1]) * inv_a + @as(u16, g) * a16) / 255);
                    fb_ptr[idx + 2] = @intCast((@as(u16, fb_ptr[idx + 2]) * inv_a + @as(u16, r) * a16) / 255);
                    fb_ptr[idx + 3] = 0xFF;
                }
            }
        }
    }

    /// Convert 0xAARRGGBB (standard hex) to libnsfb ABGR colour format.
    /// libnsfb stores colours as 0xAABBGGRR in memory.
    pub fn argbToColour(argb: u32) u32 {
        const a: u32 = (argb >> 24) & 0xFF;
        const r: u32 = (argb >> 16) & 0xFF;
        const g: u32 = (argb >> 8) & 0xFF;
        const b: u32 = argb & 0xFF;
        return (a << 24) | (b << 16) | (g << 8) | r;
    }

    /// Apply opacity (0.0-1.0) to a colour by multiplying its alpha channel.
    /// colour is in libnsfb ABGR format (alpha in bits 24-31).
    pub fn applyOpacity(colour: u32, opacity: f32) u32 {
        if (opacity >= 1.0) return colour;
        if (opacity <= 0.0) return colour & 0x00FFFFFF; // zero alpha
        const a = @as(f32, @floatFromInt((colour >> 24) & 0xFF));
        const new_a: u32 = @intFromFloat(a * opacity);
        return (colour & 0x00FFFFFF) | (new_a << 24);
    }
};
