// const std = @import("std");

// ns/const.h

pub const LXB_NS_CONST_VERSION = "253D4AFDA959234B48A478B956C3C777";

pub const lxb_ns_id_t = usize;
pub const lxb_ns_prefix_id_t = usize;

pub const lxb_ns_id_enum_t = enum(c_int) {
    LXB_NS__UNDEF = 0x00,
    LXB_NS__ANY = 0x01,
    LXB_NS_HTML = 0x02,
    LXB_NS_MATH = 0x03,
    LXB_NS_SVG = 0x04,
    LXB_NS_XLINK = 0x05,
    LXB_NS_XML = 0x06,
    LXB_NS_XMLNS = 0x07,
    LXB_NS__LAST_ENTRY = 0x08,
};
