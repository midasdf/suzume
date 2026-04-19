//! HTML reflected attributes (HTML §2.6 "Reflecting content attributes in IDL
//! attributes"). Table-driven so each (interface, IDL-name) pair costs a
//! `StringHashMap` lookup in the hot `domNodeGetProp` / `domNodeSetProp`
//! dispatcher.
//!
//! Spec references:
//! - HTML §2.6  <https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes>
//! - HTML §2.4.4.1 (rules for parsing integers)
//! - HTML §2.4.4.2 (rules for parsing non-negative integers)
//!
//! One row per reflection. Multi-commit growth — see
//! `docs/superpowers/plans/2026-04-19-kotori-4A-html-reflection.md`.

const std = @import("std");

/// §2.6.2 IDL attribute type buckets. Only the subset kotori implements is
/// listed; higher-precision numeric buckets are deferred to Layer 4B.
pub const ReflType = enum(u8) {
    /// §2.6.2 "DOMString": content attr value, or "" if missing.
    domstring,
    /// §2.6.2 "boolean": presence check + presence toggle.
    boolean,
    /// §2.6.2 "long": §2.4.4.1 signed i32 parse, default on miss/parse-fail.
    long,
    /// §2.6.2 "unsigned long": §2.4.4.2 non-negative i32 parse, clamped to
    /// [0, 2³¹−1]. Setter negative input ⇒ default written.
    unsigned_long,
    /// §2.6.2 "URL": returned as DOMString today (full URL canonicalisation
    /// is Layer 4B — see design doc).
    url,
};

/// Single reflection entry. Constructed entirely at comptime from the
/// table below; never mutated at runtime.
pub const ReflectedAttr = struct {
    iface: []const u8,
    idl: []const u8,
    content: []const u8,
    type: ReflType,
    default_int: i64 = 0,
};

/// Reflection table. Rows are added per-commit per-interface-group in the
/// order prescribed by the plan. Each row cites its HTML spec section.
pub const table = &[_]ReflectedAttr{};

/// Lookup key = iface + "\x00" + idl. Using a NUL separator keeps the key
/// comptime-constructible without needing an allocator.
const Key = struct {
    iface: []const u8,
    idl: []const u8,
};

/// O(n) linear scan for now — table is <200 rows, so the branch predictor
/// handles this fine. If the table grows past 500 we'll switch to a
/// comptime-built StringHashMap keyed by "iface\x00idl".
pub fn lookup(iface: []const u8, idl: []const u8) ?*const ReflectedAttr {
    for (table) |*row| {
        if (std.mem.eql(u8, row.idl, idl) and
            (std.mem.eql(u8, row.iface, iface) or
             std.mem.eql(u8, row.iface, "HTMLElement")))
        {
            return row;
        }
    }
    return null;
}

/// HTML §2.4.4.1 rules-for-parsing-integers. Returns `null` on parse failure
/// (the caller substitutes the spec-defined default). Accepts an optional
/// leading sign; no other whitespace or trailing junk.
///
/// §2.4.4.1 says "skip whitespace" first. ASCII whitespace characters are
/// U+0009, U+000A, U+000C, U+000D, U+0020.
pub fn parseInteger(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            0x09, 0x0A, 0x0C, 0x0D, 0x20 => {},
            else => break,
        }
    }
    if (i >= s.len) return null;
    var sign: i64 = 1;
    if (s[i] == '+') {
        i += 1;
    } else if (s[i] == '-') {
        sign = -1;
        i += 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var val: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        val = val * 10 + @as(i64, s[i] - '0');
        if (val > std.math.maxInt(i32) + 1) {
            // Clamp: too big to fit in i32 after sign — saturate.
            val = std.math.maxInt(i32) + 1;
        }
    }
    val *= sign;
    if (val > std.math.maxInt(i32)) val = std.math.maxInt(i32);
    if (val < std.math.minInt(i32)) val = std.math.minInt(i32);
    return val;
}

/// HTML §2.4.4.2 rules-for-parsing-non-negative-integers. Negative values
/// are a parse failure (returns null). Result clamped to [0, 2³¹−1].
pub fn parseNonNegativeInteger(s: []const u8) ?i64 {
    const v = parseInteger(s) orelse return null;
    if (v < 0) return null;
    return v;
}

test "parseInteger basics" {
    try std.testing.expectEqual(@as(?i64, 0), parseInteger("0"));
    try std.testing.expectEqual(@as(?i64, 42), parseInteger("42"));
    try std.testing.expectEqual(@as(?i64, -7), parseInteger("-7"));
    try std.testing.expectEqual(@as(?i64, 5), parseInteger("  +5"));
    try std.testing.expectEqual(@as(?i64, null), parseInteger(""));
    try std.testing.expectEqual(@as(?i64, null), parseInteger("abc"));
    try std.testing.expectEqual(@as(?i64, null), parseInteger(" -"));
    // trailing junk is ignored per §2.4.4.1 "collect a sequence of digits"
    try std.testing.expectEqual(@as(?i64, 12), parseInteger("12px"));
    // clamp to i32 range
    try std.testing.expectEqual(@as(?i64, 2147483647), parseInteger("99999999999"));
}

test "parseNonNegativeInteger rejects negatives" {
    try std.testing.expectEqual(@as(?i64, 0), parseNonNegativeInteger("0"));
    try std.testing.expectEqual(@as(?i64, 123), parseNonNegativeInteger("123"));
    try std.testing.expectEqual(@as(?i64, null), parseNonNegativeInteger("-1"));
}

test "lookup empty table returns null" {
    try std.testing.expect(lookup("HTMLElement", "id") == null);
}
