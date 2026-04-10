// NaN-boxing stub for JS values.
// All values are packed into 64 bits using IEEE 754 NaN space.
//
// Layout:
//   Normal float: exponent != all-ones
//   NaN box:      bits[63:48] = TAG_xxx (quiet NaN bit 51 must be set)
//
// TAG values occupy the top 16 bits when the value is a NaN.

pub const TAG_NAN: u16 = 0x7FF8;
pub const TAG_NULL: u16 = 0x7FF9;
pub const TAG_UNDEFINED: u16 = 0x7FFA;
pub const TAG_BOOL: u16 = 0x7FFB;
pub const TAG_INT: u16 = 0x7FFC;
pub const TAG_OBJECT: u16 = 0x7FFD;
pub const TAG_STRING: u16 = 0x7FFE;
pub const TAG_SYMBOL: u16 = 0x7FFF;

pub const JsValue = packed struct {
    bits: u64,

    pub fn initNumber(n: f64) JsValue {
        return .{ .bits = @bitCast(n) };
    }

    pub fn initInt(i: i32) JsValue {
        const tag: u64 = @as(u64, TAG_INT) << 48;
        const low: u64 = @as(u64, @bitCast(@as(i64, i))) & 0xFFFFFFFF;
        return .{ .bits = tag | low };
    }

    pub fn initBool(b: bool) JsValue {
        const tag: u64 = @as(u64, TAG_BOOL) << 48;
        return .{ .bits = tag | @intFromBool(b) };
    }

    pub const null_val: JsValue = .{ .bits = @as(u64, TAG_NULL) << 48 };
    pub const undefined_val: JsValue = .{ .bits = @as(u64, TAG_UNDEFINED) << 48 };
    pub const nan_val: JsValue = .{ .bits = @as(u64, TAG_NAN) << 48 };

    pub fn isGcPtr(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_OBJECT or tag == TAG_STRING or tag == TAG_SYMBOL;
    }

    pub fn asNumber(self: JsValue) f64 {
        return @bitCast(self.bits);
    }
};
