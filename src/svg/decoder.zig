const std = @import("std");
const DecodedImage = @import("../paint/image.zig").DecodedImage;

const c = @cImport({
    @cInclude("svg_wrapper.h");
});

/// Decode SVG data into RGBA pixels via lunasvg.
/// target_w/target_h: desired size, 0 = use SVG intrinsic dimensions.
/// Returns DecodedImage on success. Pixels are malloc'd and must be freed via free().
pub fn decodeSvg(data: []const u8, target_w: u32, target_h: u32) ?DecodedImage {
    if (data.len == 0) return null;

    var result: c.svg_result_t = undefined;
    if (c.svg_render(
        @ptrCast(data.ptr),
        @intCast(data.len),
        @intCast(target_w),
        @intCast(target_h),
        &result,
    ) != 1) {
        return null;
    }

    const px: ?[*]u8 = @ptrCast(result.pixels);
    if (px == null or result.width <= 0 or result.height <= 0) return null;

    return DecodedImage{
        .pixels = px.?,
        .width = @intCast(result.width),
        .height = @intCast(result.height),
    };
}
