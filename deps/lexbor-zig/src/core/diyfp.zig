const core = @import("../core_ext.zig");

pub const uint64Hl = core.lexbor_uint64_hl;

pub const DBL_SIGNIFICAND_SIZE = core.LEXBOR_DBL_SIGNIFICAND_SIZE;
pub const DBL_EXPONENT_BIAS = core.LEXBOR_DBL_EXPONENT_BIAS;
pub const DBL_EXPONENT_MIN = core.LEXBOR_DBL_EXPONENT_MIN;
pub const DBL_EXPONENT_MAX = core.LEXBOR_DBL_EXPONENT_MAX;
pub const DBL_EXPONENT_DENORMAL = core.LEXBOR_DBL_EXPONENT_DENORMAL;

pub const DBL_SIGNIFICAND_MASK = core.LEXBOR_DBL_SIGNIFICAND_MASK;
pub const DBL_HIDDEN_BIT = core.LEXBOR_DBL_HIDDEN_BIT;
pub const DBL_EXPONENT_MASK = core.LEXBOR_DBL_EXPONENT_MASK;

pub const DIYFP_SIGNIFICAND_SIZE = core.LEXBOR_DIYFP_SIGNIFICAND_SIZE;

pub const SIGNIFICAND_SIZE = core.LEXBOR_SIGNIFICAND_SIZE;
pub const SIGNIFICAND_SHIFT = core.LEXBOR_SIGNIFICAND_SHIFT;

pub const DECIMAL_EXPONENT_OFF = core.LEXBOR_DECIMAL_EXPONENT_OFF;
pub const DECIMAL_EXPONENT_MIN = core.LEXBOR_DECIMAL_EXPONENT_MIN;
pub const DECIMAL_EXPONENT_MAX = core.LEXBOR_DECIMAL_EXPONENT_MAX;

pub const Diyfp = core.lexbor_diyfp_t;

pub fn cachedPowerDec(exp: c_int, dec_exp: ?*c_int) core.lexbor_diyfp_t {
    return core.lexbor_cached_power_dec(exp, dec_exp);
}

pub fn cachedPowerBin(exp: c_int, dec_exp: ?*c_int) core.lexbor_diyfp_t {
    return core.lexbor_cached_power_bin(exp, dec_exp);
}

pub inline fn diyfpLeadingZeros64(x: u64) u64 {
    return core.lexbor_diyfp_leading_zeros64(x);
}

pub inline fn diyfpFromD2(d: u64) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_from_d2(d);
}

pub inline fn diyfp2d(v: core.lexbor_diyfp_t) f64 {
    return core.lexbor_diyfp_2d(v);
}

pub inline fn diyfpShiftLeft(v: core.lexbor_diyfp_t, shift: c_uint) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_shift_left(v, shift);
}

pub inline fn diyfpShiftRight(v: core.lexbor_diyfp_t, shift: c_uint) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_shift_right(v, shift);
}

pub inline fn diyfpSub(lhs: core.lexbor_diyfp_t, rhs: core.lexbor_diyfp_t) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_sub(lhs, rhs);
}

pub inline fn diyfpMul(lhs: core.lexbor_diyfp_t, rhs: core.lexbor_diyfp_t) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_mul(lhs, rhs);
}

pub inline fn diyfpNormalize(v: core.lexbor_diyfp_t) core.lexbor_diyfp_t {
    return core.lexbor_diyfp_normalize(v);
}
