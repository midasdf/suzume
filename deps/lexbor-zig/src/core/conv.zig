const core = @import("../core_ext.zig");

pub fn floatToData(num: f64, buf: [*]u8, len: usize) usize {
    return core.lexbor_conv_float_to_data(num, @ptrCast(buf), len);
}

pub fn longToData(num: c_long, buf: [*]u8, len: usize) usize {
    return core.lexbor_conv_long_to_data(num, @ptrCast(buf), len);
}

pub fn int64ToData(num: i64, buf: [*]u8, len: usize) usize {
    return core.lexbor_conv_int64_to_data(num, @ptrCast(buf), len);
}

pub fn dataToDouble(start: []const u8, len: usize) f64 {
    return core.lexbor_conv_data_to_double(&@ptrCast(@constCast(start.ptr)), len);
}

pub fn dataToUlong(data: []const u8, length: usize) c_ulong {
    return core.lexbor_conv_data_to_ulong(&@ptrCast(@constCast(data.ptr)), length);
}

pub fn dataToLong(data: []const u8, length: usize) c_long {
    return core.lexbor_conv_data_to_long(&@ptrCast(@constCast(data.ptr)), length);
}

pub fn dataToUint(data: []const u8, length: usize) c_uint {
    return core.lexbor_conv_data_to_uint(&@ptrCast(@constCast(data.ptr)), length);
}

pub fn decToHex(number: u32, out: [*]u8, length: usize) usize {
    return core.lexbor_conv_dec_to_hex(number, @ptrCast(out), length);
}

pub inline fn doubleToLong(number: f64) c_long {
    return core.lexbor_conv_double_to_long(number);
}
