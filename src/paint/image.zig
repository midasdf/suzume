const std = @import("std");
const stb = @cImport({
    @cInclude("stb_image.h");
});
const Surface = @import("surface.zig").Surface;

pub const DecodedImage = struct {
    pixels: [*]u8, // RGBA, 4 bytes per pixel
    width: u32,
    height: u32,

    pub fn byteSize(self: DecodedImage) usize {
        return @as(usize, self.width) * @as(usize, self.height) * 4;
    }

    pub fn deinit(self: *DecodedImage) void {
        stb.stbi_image_free(self.pixels);
    }
};

pub const ImageError = error{
    DecodeFailed,
};

const svg_decoder = @import("../svg/decoder.zig");

/// Decode image data (PNG, JPEG, GIF, BMP, SVG) from memory into RGBA pixels.
pub fn decodeImage(data: []const u8) ImageError!DecodedImage {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;

    const pixels = stb.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &w,
        &h,
        &channels,
        4, // force RGBA
    );

    if (pixels == null) {
        // STB failed — try SVG decoder (handles .svg files)
        if (svg_decoder.decodeSvg(data, 0, 0)) |svg_img| {
            return svg_img;
        }
        return ImageError.DecodeFailed;
    }

    return DecodedImage{
        .pixels = pixels,
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

/// Simple image cache keyed by URL string.
pub const ImageCache = struct {
    const Entry = struct {
        image: DecodedImage,
        url_owned: []const u8,
    };

    entries: std.StringHashMap(DecodedImage),
    urls_owned: std.ArrayListUnmanaged([]const u8),
    total_bytes: usize,
    max_bytes: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ImageCache {
        return .{
            .entries = std.StringHashMap(DecodedImage).init(allocator),
            .urls_owned = .empty,
            .total_bytes = 0,
            .max_bytes = 20 * 1024 * 1024, // 20MB
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ImageCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            var img = entry.value_ptr.*;
            img.deinit();
        }
        self.entries.deinit();
        for (self.urls_owned.items) |url| {
            self.allocator.free(url);
        }
        self.urls_owned.deinit(self.allocator);
    }

    /// Look up a cached image by URL.
    pub fn get(self: *ImageCache, url: []const u8) ?DecodedImage {
        return self.entries.get(url);
    }

    /// Insert a decoded image into the cache. Evicts old entries if over budget.
    pub fn put(self: *ImageCache, url: []const u8, image: DecodedImage) !void {
        const img_size = image.byteSize();

        // Evict entries if adding this would exceed max
        while (self.total_bytes + img_size > self.max_bytes and self.urls_owned.items.len > 0) {
            const oldest_url = self.urls_owned.orderedRemove(0);
            if (self.entries.fetchRemove(oldest_url)) |kv| {
                self.total_bytes -= kv.value.byteSize();
                var removed = kv.value;
                removed.deinit();
            }
            self.allocator.free(oldest_url);
        }

        const url_copy = try self.allocator.alloc(u8, url.len);
        @memcpy(url_copy, url);

        try self.entries.put(url_copy, image);
        try self.urls_owned.append(self.allocator, url_copy);
        self.total_bytes += img_size;
    }
};

/// Blit an RGBA image onto a libnsfb surface.
/// Handles clipping to surface bounds. Converts RGBA to libnsfb's ABGR format.
pub fn blitImage(surface: *Surface, dst_x: i32, dst_y: i32, img_w: u32, img_h: u32, pixels: [*]const u8) void {
    const surf_w = surface.width;
    const surf_h = surface.height;

    // Compute clipped region
    const x0 = @max(dst_x, 0);
    const y0 = @max(dst_y, 0);
    const x1 = @min(dst_x + @as(i32, @intCast(img_w)), surf_w);
    const y1 = @min(dst_y + @as(i32, @intCast(img_h)), surf_h);

    if (x0 >= x1 or y0 >= y1) return;

    // Get framebuffer pointer via libnsfb
    const nsfb = @import("../bindings/nsfb.zig").c;
    var raw_ptr: ?[*]u8 = null;
    var fb_stride: c_int = 0;
    if (nsfb.nsfb_get_buffer(surface.fb, @ptrCast(&raw_ptr), &fb_stride) != 0) return;
    const fb_ptr: [*]u8 = raw_ptr orelse return;

    const stride: usize = @intCast(fb_stride);

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const src_y: usize = @intCast(y - dst_y);
        const src_row_offset = src_y * @as(usize, img_w) * 4;

        const dst_row_offset: usize = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x0)) * 4;

        var x: i32 = x0;
        while (x < x1) : (x += 1) {
            const src_x: usize = @intCast(x - dst_x);
            const src_idx = src_row_offset + src_x * 4;

            const src_r = pixels[src_idx + 0];
            const src_g = pixels[src_idx + 1];
            const src_b = pixels[src_idx + 2];
            const src_a = pixels[src_idx + 3];

            const dst_idx = dst_row_offset + @as(usize, @intCast(x - x0)) * 4;

            if (src_a == 255) {
                // Opaque: write directly in XRGB8888 (libnsfb native: B, G, R, X in memory)
                fb_ptr[dst_idx + 0] = src_b;
                fb_ptr[dst_idx + 1] = src_g;
                fb_ptr[dst_idx + 2] = src_r;
                fb_ptr[dst_idx + 3] = 0xFF;
            } else if (src_a > 0) {
                // Alpha blend
                const a: u16 = src_a;
                const inv_a: u16 = 255 - a;
                fb_ptr[dst_idx + 0] = @intCast((@as(u16, src_b) * a + @as(u16, fb_ptr[dst_idx + 0]) * inv_a) / 255);
                fb_ptr[dst_idx + 1] = @intCast((@as(u16, src_g) * a + @as(u16, fb_ptr[dst_idx + 1]) * inv_a) / 255);
                fb_ptr[dst_idx + 2] = @intCast((@as(u16, src_r) * a + @as(u16, fb_ptr[dst_idx + 2]) * inv_a) / 255);
                fb_ptr[dst_idx + 3] = 0xFF;
            }
            // src_a == 0: fully transparent, skip
        }
    }
}
