const tag_const = @import("tag/const.zig");
pub const CONST_VERSION = tag_const.CONST_VERSION;
pub const IdType = tag_const.IdType;
pub const IdEnum = tag_const.IdEnum;

const tag_tag = @import("tag/tag.zig");
pub const nameById = tag_tag.nameById;

const tag_base = @import("tag/base.zig");
pub const VERSION_MAJOR = tag_base.VERSION_MAJOR;
pub const VERSION_MINOR = tag_base.VERSION_MINOR;
pub const VERSION_PATCH = tag_base.VERSION_PATCH;
pub const VERSION_STRING = tag_base.VERSION_STRING;
