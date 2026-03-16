const std = @import("std");
const nsfb = @import("../bindings/nsfb.zig");
const c = nsfb.c;

/// Manual surface registration (constructor workaround)
extern fn nsfb_surface_init_all() void;

pub const Surface = struct {
    fb: *c.nsfb_t,
    width: i32,
    height: i32,

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

    /// Convert 0xAARRGGBB (standard hex) to libnsfb ABGR colour format.
    /// libnsfb stores colours as 0xAABBGGRR in memory.
    pub fn argbToColour(argb: u32) u32 {
        const a: u32 = (argb >> 24) & 0xFF;
        const r: u32 = (argb >> 16) & 0xFF;
        const g: u32 = (argb >> 8) & 0xFF;
        const b: u32 = argb & 0xFF;
        return (a << 24) | (b << 16) | (g << 8) | r;
    }
};
