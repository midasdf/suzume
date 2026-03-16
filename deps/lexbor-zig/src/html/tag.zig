const html = @import("../html_ext.zig");
const tag = @import("../tag_ext.zig");

pub const IdType = usize;
pub const IdEnum = tag.lxb_tag_id_enum_t;

pub fn isVoid(tag_id: tag.lxb_tag_id_enum_t) bool {
    return html.lxb_html_tag_is_void(tag_id);
}
