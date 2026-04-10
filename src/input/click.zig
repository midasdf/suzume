const std = @import("std");
const coords = @import("../coords.zig");
const hit_test = @import("../hit_test.zig");

/// Process a content-area click. Returns true if navigation was triggered.
pub fn handleContentClick(
    root_box: anytype,
    layout_pos: coords.LayoutPos,
) hit_test.HitResult {
    return hit_test.hitTest(root_box, layout_pos);
}
