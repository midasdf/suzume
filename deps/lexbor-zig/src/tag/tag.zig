const std = @import("std");
const span = std.mem.span;

const tag = @import("../tag_ext.zig");

pub fn nameById(tag_id: tag.lxb_tag_id_enum_t, len: ?*usize) ?[]const u8 {
    const name = tag.lxb_tag_name_by_id(tag_id, len) orelse return null;
    return span(name);
}
