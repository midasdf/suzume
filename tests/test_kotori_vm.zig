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

// ── Compiler + VM eval tests ─────────────────────────────────────

const Compiler = kotori.Compiler;
const VM = kotori.VM;

fn evalExpr(source: []const u8) !JsValue {
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm = VM.init(&bc);
    return vm.execute();
}

test "eval: 42" {
    const result = try evalExpr("42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: 1 + 2" {
    const result = try evalExpr("1 + 2");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: 1 + 2 * 3" {
    const result = try evalExpr("1 + 2 * 3");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: (1 + 2) * 3" {
    const result = try evalExpr("(1 + 2) * 3");
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: 10 - 3" {
    const result = try evalExpr("10 - 3");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: -5" {
    const result = try evalExpr("-5");
    try std.testing.expectApproxEqAbs(@as(f64, -5.0), result.asNumber(), 0.001);
}

test "eval: !true" {
    const result = try evalExpr("!true");
    try std.testing.expect(!result.asBool());
}

test "eval: 1 < 2" {
    const result = try evalExpr("1 < 2");
    try std.testing.expect(result.asBool());
}

test "eval: 1 === 1" {
    const result = try evalExpr("1 === 1");
    try std.testing.expect(result.asBool());
}

test "eval: true ? 1 : 2" {
    const result = try evalExpr("true ? 1 : 2");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: false ? 1 : 2" {
    const result = try evalExpr("false ? 1 : 2");
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: 2 ** 10" {
    const result = try evalExpr("2 ** 10");
    try std.testing.expectApproxEqAbs(@as(f64, 1024.0), result.asNumber(), 0.001);
}

test "eval: 10 % 3" {
    const result = try evalExpr("10 % 3");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: nested arithmetic" {
    const result = try evalExpr("(10 + 20) * (3 - 1) / 2");
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: comparison chain" {
    const result = try evalExpr("1 < 2 ? 10 + 5 : 0");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: null equality" {
    const result = try evalExpr("null === null");
    try std.testing.expect(result.asBool());
}

test "eval: double negation" {
    const result = try evalExpr("!!1");
    try std.testing.expect(result.asBool());
}

test "eval: false is falsy" {
    const result = try evalExpr("!false");
    try std.testing.expect(result.asBool());
}
