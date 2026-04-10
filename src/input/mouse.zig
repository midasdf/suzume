const std = @import("std");
const coords = @import("../coords.zig");
const hit_test = @import("../hit_test.zig");

pub const CursorHint = enum {
    arrow,
    pointer,
    text,
};

/// Determine cursor shape from hit test result.
pub fn cursorForHitResult(result: hit_test.HitResult) CursorHint {
    if (result.link_url != null) return .pointer;
    if (result.form_element != null) return .text;
    return .arrow;
}
