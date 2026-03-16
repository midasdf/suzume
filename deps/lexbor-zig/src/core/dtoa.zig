const core = @import("../core_ext.zig");

pub fn dtoa(value: f64, begin: [*]u8, len: usize) usize {
    return core.lexbor_dtoa(value, @ptrCast(begin), len);
}
