const std = @import("std");
const kotori = @import("kotori");
const JsValue = kotori.JsValue;

test "JsValue number roundtrip" {
    const v = JsValue.initNumber(3.14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), v.asNumber(), 0.001);
}

test "JsValue int roundtrip" {
    const v = JsValue.initInt(42);
    try std.testing.expectEqual(@as(i32, 42), v.asInt());
}

test "JsValue bool" {
    try std.testing.expect(JsValue.initBool(true).asBool());
    try std.testing.expect(!JsValue.initBool(false).asBool());
}

test "JsValue add numbers" {
    const result = JsValue.jsAdd(JsValue.initNumber(10), JsValue.initNumber(20));
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "JsValue subtract" {
    const result = JsValue.jsSub(JsValue.initNumber(10), JsValue.initNumber(3));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "JsValue multiply" {
    const result = JsValue.jsMul(JsValue.initNumber(6), JsValue.initNumber(7));
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "JsValue comparison" {
    try std.testing.expect(JsValue.jsLt(JsValue.initNumber(1), JsValue.initNumber(2)).asBool());
    try std.testing.expect(!JsValue.jsLt(JsValue.initNumber(2), JsValue.initNumber(1)).asBool());
}

test "JsValue strict equality" {
    try std.testing.expect(JsValue.jsStrictEq(JsValue.initNumber(42), JsValue.initNumber(42)).asBool());
    try std.testing.expect(!JsValue.jsStrictEq(JsValue.initNumber(42), JsValue.initNumber(43)).asBool());
}

test "JsValue isTruthy" {
    try std.testing.expect(JsValue.initNumber(1).isTruthy());
    try std.testing.expect(!JsValue.initNumber(0).isTruthy());
    try std.testing.expect(JsValue.initBool(true).isTruthy());
    try std.testing.expect(!JsValue.initBool(false).isTruthy());
    try std.testing.expect(!JsValue.null_val.isTruthy());
    try std.testing.expect(!JsValue.undefined_val.isTruthy());
}
