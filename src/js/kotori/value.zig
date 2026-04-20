const std = @import("std");

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

    pub fn initString(id: @import("string_pool.zig").StringId) JsValue {
        const tag: u64 = @as(u64, TAG_STRING) << 48;
        return .{ .bits = tag | @as(u64, id) };
    }

    pub fn isString(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_STRING;
    }

    pub fn asStringId(self: JsValue) @import("string_pool.zig").StringId {
        return @intCast(self.bits & 0x0000FFFFFFFFFFFF);
    }

    pub fn isGcPtr(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_OBJECT or tag == TAG_STRING or tag == TAG_SYMBOL;
    }

    pub fn isObject(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_OBJECT;
    }

    pub fn initObject(ptr: *anyopaque) JsValue {
        const addr: u64 = @intFromPtr(ptr);
        const tag: u64 = @as(u64, TAG_OBJECT) << 48;
        return .{ .bits = tag | (addr & 0x0000FFFFFFFFFFFF) };
    }

    pub fn asObject(self: JsValue) *anyopaque {
        const addr: usize = @intCast(self.bits & 0x0000FFFFFFFFFFFF);
        return @ptrFromInt(addr);
    }

    pub fn asJsObject(self: JsValue) *@import("object.zig").JsObject {
        return @ptrCast(@alignCast(self.asObject()));
    }

    pub fn asNumber(self: JsValue) f64 {
        return @bitCast(self.bits);
    }

    // ── Type checks ──────────────────────────────────────────────────

    pub fn isNumber(self: JsValue) bool {
        // Tagged values use quiet NaN space: exponent all-ones + quiet bit (bits 62:51 = 0xFFF).
        // Normal floats (including negatives, infinity) never have this pattern.
        return (self.bits >> 51) & 0xFFF != 0xFFF;
    }

    pub fn isInt(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_INT;
    }

    pub fn isBool(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_BOOL;
    }

    pub fn isNull(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_NULL;
    }

    pub fn isUndefined(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_UNDEFINED;
    }

    pub fn isSymbol(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_SYMBOL;
    }

    pub fn initSymbol(id: u32) JsValue {
        const tag: u64 = @as(u64, TAG_SYMBOL) << 48;
        return .{ .bits = tag | @as(u64, id) };
    }

    pub fn asSymbolId(self: JsValue) u32 {
        return @intCast(self.bits & 0xFFFFFFFF);
    }

    // ── Extraction ───────────────────────────────────────────────────

    pub fn asInt(self: JsValue) i32 {
        return @truncate(@as(i64, @bitCast(self.bits & 0xFFFFFFFF)));
    }

    pub fn asBool(self: JsValue) bool {
        return (self.bits & 1) != 0;
    }

    pub fn toNumber(self: JsValue) f64 {
        if (self.isNumber()) return self.asNumber();
        if (self.isInt()) return @floatFromInt(self.asInt());
        if (self.isBool()) return if (self.asBool()) 1.0 else 0.0;
        if (self.isNull()) return 0.0;
        // undefined → NaN
        return std.math.nan(f64);
    }

    // ── Truthiness ───────────────────────────────────────────────────

    pub fn isTruthy(self: JsValue) bool {
        if (self.isNull() or self.isUndefined()) return false;
        if (self.isBool()) return self.asBool();
        if (self.isInt()) return self.asInt() != 0;
        if (self.isNumber()) {
            const n = self.asNumber();
            return n != 0.0 and !std.math.isNan(n);
        }
        if (self.isString()) return self.asStringId() != @import("string_pool.zig").EMPTY_STRING_ID;
        // Objects and symbols are always truthy
        return true;
    }

    // ── Arithmetic ───────────────────────────────────────────────────

    pub fn jsAdd(a: JsValue, b: JsValue) JsValue {
        return initNumber(a.toNumber() + b.toNumber());
    }

    pub fn jsSub(a: JsValue, b: JsValue) JsValue {
        return initNumber(a.toNumber() - b.toNumber());
    }

    pub fn jsMul(a: JsValue, b: JsValue) JsValue {
        return initNumber(a.toNumber() * b.toNumber());
    }

    pub fn jsDiv(a: JsValue, b: JsValue) JsValue {
        return initNumber(a.toNumber() / b.toNumber());
    }

    pub fn jsMod(a: JsValue, b: JsValue) JsValue {
        return initNumber(@mod(a.toNumber(), b.toNumber()));
    }

    pub fn jsPow(a: JsValue, b: JsValue) JsValue {
        return initNumber(std.math.pow(f64, a.toNumber(), b.toNumber()));
    }

    pub fn jsNeg(a: JsValue) JsValue {
        return initNumber(-a.toNumber());
    }

    // ── Comparison ───────────────────────────────────────────────────

    pub fn jsLt(a: JsValue, b: JsValue) JsValue {
        return initBool(a.toNumber() < b.toNumber());
    }

    pub fn jsLe(a: JsValue, b: JsValue) JsValue {
        return initBool(a.toNumber() <= b.toNumber());
    }

    pub fn jsGt(a: JsValue, b: JsValue) JsValue {
        return initBool(a.toNumber() > b.toNumber());
    }

    pub fn jsGe(a: JsValue, b: JsValue) JsValue {
        return initBool(a.toNumber() >= b.toNumber());
    }

    pub fn jsStrictEq(a: JsValue, b: JsValue) JsValue {
        // Same bits → always equal (handles null==null, undefined==undefined, bool, int, string by id)
        if (a.bits == b.bits) return initBool(true);
        // Both numbers: compare as f64 (NaN != NaN)
        if (a.isNumber() and b.isNumber()) {
            return initBool(a.asNumber() == b.asNumber());
        }
        // Strings: same StringId means same content (interned)
        if (a.isString() and b.isString()) {
            return initBool(a.asStringId() == b.asStringId());
        }
        return initBool(false);
    }

    pub fn jsEq(a: JsValue, b: JsValue) JsValue {
        // Abstract equality (==) with type coercion per ES spec
        // Same bits → equal
        if (a.bits == b.bits) return initBool(true);
        // Same type comparisons
        if (a.isNumber() and b.isNumber()) return initBool(a.asNumber() == b.asNumber());
        if (a.isInt() and b.isInt()) return initBool(a.asInt() == b.asInt());
        if (a.isString() and b.isString()) return initBool(a.asStringId() == b.asStringId());
        // null == undefined (and vice versa)
        if ((a.isNull() or a.isUndefined()) and (b.isNull() or b.isUndefined())) return initBool(true);
        // number/int == number/int (mixed)
        if ((a.isNumber() or a.isInt()) and (b.isNumber() or b.isInt())) return initBool(a.toNumber() == b.toNumber());
        // boolean == anything → ToNumber(bool) == other
        if (a.isBool()) return jsEq(initNumber(if (a.asBool()) 1.0 else 0.0), b);
        if (b.isBool()) return jsEq(a, initNumber(if (b.asBool()) 1.0 else 0.0));
        // string == number/int → ToNumber(string) == number
        if (a.isString() and (b.isNumber() or b.isInt())) {
            return initBool(a.toNumber() == b.toNumber());
        }
        if ((a.isNumber() or a.isInt()) and b.isString()) {
            return initBool(a.toNumber() == b.toNumber());
        }
        // object == same object pointer
        if (a.isObject() and b.isObject()) return initBool(a.bits == b.bits);
        return initBool(false);
    }

    pub fn jsNe(a: JsValue, b: JsValue) JsValue {
        return initBool(!jsEq(a, b).asBool());
    }

    pub fn jsStrictNe(a: JsValue, b: JsValue) JsValue {
        return initBool(!jsStrictEq(a, b).asBool());
    }

    // ── Logical ──────────────────────────────────────────────────────

    pub fn jsNot(a: JsValue) JsValue {
        return initBool(!a.isTruthy());
    }

    /// ECMA-262 §13.5.4 Unary `+`: returns ToNumber(operand) with no sign flip.
    /// Distinct from `jsNeg` (which negates) — kotori's earlier `.pos` dispatch
    /// silently aliased to `.not`, turning `+"0"` into `false`.
    /// Caller must handle strings (needs string-pool access) — this helper is
    /// used for non-string operands (undefined/null/bool/number/int/object).
    /// NaN is returned as the tagged `nan_val` so `typeof` still reports
    /// "number" (a raw NaN float collides with the NaN-box tag space).
    pub fn jsToNumber(a: JsValue) JsValue {
        const n = a.toNumber();
        if (std.math.isNan(n)) return nan_val;
        return initNumber(n);
    }

    // ── Bitwise ──────────────────────────────────────────────────────

    /// ECMA-262 §7.1.6 ToInt32 (2024).
    /// 1. Let number be ToNumber(argument).
    /// 2. If number is NaN, +0, -0, +∞, or -∞, return +0.
    /// 3. Let int be truncate(number).
    /// 4. Let int32bit be int modulo 2^32.
    /// 5. If int32bit ≥ 2^31, return int32bit - 2^32; otherwise return int32bit.
    ///
    /// Previous implementation used `@intFromFloat` directly which panics on
    /// NaN/Infinity/out-of-i32-range values. This caused `x >>> 0` and related
    /// idioms to crash the VM when called with non-finite inputs (e.g. a Proxy
    /// `get` trap receiving a non-numeric string key). The spec-faithful
    /// modulo-2^32 wrap-around is required for classList Proxy indexed access
    /// and for ECMA-262-conformant bitwise arithmetic in general.
    fn toInt32(a: JsValue) i32 {
        const n = a.toNumber();
        if (std.math.isNan(n) or !std.math.isFinite(n)) return 0;
        // Truncate toward zero, then reduce modulo 2^32 with wraparound.
        const trunc = @trunc(n);
        const two32: f64 = 4294967296.0; // 2^32
        // Reduce to [0, 2^32); use @rem then fix up negatives.
        const rem = @rem(trunc, two32);
        const mod = if (rem < 0) rem + two32 else rem;
        // mod is now in [0, 2^32). Map to signed i32 via wraparound.
        const as_u32: u32 = @intFromFloat(mod);
        return @bitCast(as_u32);
    }

    /// ECMA-262 §7.1.7 ToUint32. Same as ToInt32 but returns u32 without the
    /// final signed conversion. Used by `>>> 0` and for array-index coercion.
    fn toUint32(a: JsValue) u32 {
        const n = a.toNumber();
        if (std.math.isNan(n) or !std.math.isFinite(n)) return 0;
        const trunc = @trunc(n);
        const two32: f64 = 4294967296.0;
        const rem = @rem(trunc, two32);
        const mod = if (rem < 0) rem + two32 else rem;
        return @intFromFloat(mod);
    }

    pub fn jsBitNot(a: JsValue) JsValue {
        return initInt(~toInt32(a));
    }

    pub fn jsBitAnd(a: JsValue, b: JsValue) JsValue {
        return initInt(toInt32(a) & toInt32(b));
    }

    pub fn jsBitOr(a: JsValue, b: JsValue) JsValue {
        return initInt(toInt32(a) | toInt32(b));
    }

    pub fn jsBitXor(a: JsValue, b: JsValue) JsValue {
        return initInt(toInt32(a) ^ toInt32(b));
    }

    pub fn jsShl(a: JsValue, b: JsValue) JsValue {
        const shift: u5 = @truncate(@as(u32, @bitCast(toInt32(b))));
        return initInt(toInt32(a) << shift);
    }

    pub fn jsShr(a: JsValue, b: JsValue) JsValue {
        const shift: u5 = @truncate(@as(u32, @bitCast(toInt32(b))));
        return initInt(toInt32(a) >> shift);
    }

    /// ECMA-262 §13.5.5.1 UnsignedRightShift ( >>> ).
    /// Left operand coerced via ToUint32 (spec-faithful), shift count via
    /// ToUint32 & 0x1f. Result is u32 reinterpreted as i32 so the NaN-box
    /// can store it as a 32-bit signed int (callers that view it as unsigned
    /// use `@bitCast` back to u32).
    pub fn jsUshr(a: JsValue, b: JsValue) JsValue {
        const ua: u32 = toUint32(a);
        const shift: u5 = @truncate(toUint32(b));
        return initInt(@bitCast(ua >> shift));
    }
};
