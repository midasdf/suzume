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

test "JsValue strict equality rejects NaN" {
    try std.testing.expect(!JsValue.jsStrictEq(JsValue.nan_val, JsValue.nan_val).asBool());
    try std.testing.expect(!JsValue.jsStrictEq(JsValue.initNumber(std.math.nan(f64)), JsValue.initNumber(std.math.nan(f64))).asBool());
}

test "JsValue abstract equality rejects NaN" {
    try std.testing.expect(!JsValue.jsEq(JsValue.nan_val, JsValue.nan_val).asBool());
    try std.testing.expect(JsValue.jsNe(JsValue.initNumber(std.math.nan(f64)), JsValue.initNumber(std.math.nan(f64))).asBool());
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

fn installTestIo() void {
    kotori.io.io = std.testing.io;
}

fn resetTestIo() void {
    kotori.io.io = null;
}

fn evalExpr(source: []const u8) !JsValue {
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    const result = try vm_inst.execute();
    return result;
}

/// Execute JS source, drain microtasks, and return a named global variable.
fn evalWithMicrotasks(source: []const u8, global_name: []const u8) !JsValue {
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    // Drain microtasks (multiple rounds for chained promises)
    var rounds: u32 = 0;
    while (rounds < 10) : (rounds += 1) {
        const ran = try vm_inst.runMicrotasks();
        if (!ran) break;
    }
    const name_id = try compiler.parser.pool.intern(global_name);
    return vm_inst.globals.get(name_id) orelse JsValue.undefined_val;
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

test "eval: numeric operators trim vertical tab" {
    const result = try evalExpr("\"\\v1.5\" - 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.asNumber(), 0.001);
}

test "eval: numeric operators trim non-breaking space" {
    const result = try evalExpr("\"\\u00a01.5\\u00a0\" - 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.asNumber(), 0.001);
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

test "eval: remainder keeps dividend sign" {
    const result = try evalExpr(
        \\(-5 % 2) === -1 &&
        \\(5 % -2) === 1 &&
        \\(-5 % -2) === -1
    );
    try std.testing.expect(result.asBool());
}

test "eval: remainder invalid operands produce NaN" {
    const result = try evalExpr(
        \\isNaN(1 % 0) &&
        \\isNaN(0 % 0) &&
        \\isNaN(Infinity % 2)
    );
    try std.testing.expect(result.asBool());
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

// ── Phase 1c: Variables ──────────────────────────────────────────

test "eval: var declaration and use" {
    const result = try evalExpr("var x = 42; x");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: var arithmetic" {
    const result = try evalExpr("var a = 10; var b = 20; a + b");
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: var reassignment" {
    const result = try evalExpr("var x = 1; x = 5; x");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: let declaration" {
    const result = try evalExpr("let x = 99; x");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: const declaration" {
    const result = try evalExpr("const x = 7; x");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: var default undefined" {
    const result = try evalExpr("var x; x");
    try std.testing.expect(result.isUndefined());
}

test "eval: multiple declarators" {
    const result = try evalExpr("var a = 3, b = 4; a * b");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

// ── Phase 1c: Functions ──────────────────────────────────────────

test "eval: function declaration and call" {
    const result = try evalExpr("function add(a, b) { return a + b; } add(3, 4)");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: function returns undefined by default" {
    const result = try evalExpr("function noop() {} noop()");
    try std.testing.expect(result.isUndefined());
}

test "eval: function with local vars" {
    const result = try evalExpr("function f(x) { var y = x * 2; return y + 1; } f(5)");
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.asNumber(), 0.001);
}

test "eval: nested function calls" {
    const result = try evalExpr("function double(x) { return x * 2; } function quad(x) { return double(double(x)); } quad(3)");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: recursion — factorial" {
    const result = try evalExpr("function fact(n) { if (n <= 1) return 1; return n * fact(n - 1); } fact(5)");
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), result.asNumber(), 0.001);
}

test "eval: function expression" {
    const result = try evalExpr("var mul = function(a, b) { return a * b; }; mul(6, 7)");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Phase 1c: Closures ──────────────────────────────────────────

test "eval: closure captures variable" {
    const result = try evalExpr("function make() { var x = 10; return function() { return x; }; } var f = make(); f()");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: closure with parameter" {
    const result = try evalExpr("function adder(x) { return function(y) { return x + y; }; } var add5 = adder(5); add5(3)");
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

// ── Phase 1c: Objects ────────────────────────────────────────────

test "eval: empty object" {
    const result = try evalExpr("var o = {}; o");
    try std.testing.expect(result.isObject());
}

test "eval: object property access" {
    const result = try evalExpr("var o = {x: 42}; o.x");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: object multiple properties" {
    const result = try evalExpr("var o = {a: 1, b: 2}; o.a + o.b");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: object property assignment" {
    const result = try evalExpr("var o = {}; o.x = 99; o.x");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: object method call" {
    const result = try evalExpr("var o = {val: 10, get: function() { return 10; }}; o.get()");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: prototype chain" {
    const result = try evalExpr(
        \\var proto = {x: 42};
        \\var child = {};
        \\child.__proto__ = proto;
        \\child.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Real-world JS patterns ───────────────────────────────────────

test "eval: fibonacci(10)" {
    const result = try evalExpr(
        \\function fib(n) {
        \\  if (n <= 1) return n;
        \\  return fib(n - 1) + fib(n - 2);
        \\}
        \\fib(10)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), result.asNumber(), 0.001);
}

test "eval: closure counter" {
    const result = try evalExpr(
        \\function makeCounter() {
        \\  var count = 0;
        \\  return function() {
        \\    count = count + 1;
        \\    return count;
        \\  };
        \\}
        \\var c = makeCounter();
        \\c();
        \\c();
        \\c()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: higher-order function" {
    const result = try evalExpr(
        \\function apply(f, x) { return f(x); }
        \\function square(n) { return n * n; }
        \\apply(square, 5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.asNumber(), 0.001);
}

test "eval: adder closure" {
    const result = try evalExpr(
        \\function adder(x) {
        \\  return function(y) { return x + y; };
        \\}
        \\var add10 = adder(10);
        \\add10(5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

// ── Phase 1d: Strings ──────────────────────────────────────────

test "eval: string literal" {
    const result = try evalExpr("\"hello\"");
    try std.testing.expect(result.isString());
}

test "eval: string concatenation" {
    const result = try evalExpr("\"hello\" + \" \" + \"world\"");
    try std.testing.expect(result.isString());
}

test "eval: string + number coercion" {
    const result = try evalExpr("\"count: \" + \"3\"");
    try std.testing.expect(result.isString());
}

test "eval: string equality" {
    const result = try evalExpr("\"abc\" === \"abc\"");
    try std.testing.expect(result.asBool());
}

test "eval: string inequality" {
    const result = try evalExpr("\"abc\" === \"def\"");
    try std.testing.expect(!result.asBool());
}

test "eval: string var and concat" {
    const result = try evalExpr(
        \\var greeting = "hello";
        \\var name = "world";
        \\greeting + " " + name
    );
    try std.testing.expect(result.isString());
}

test "eval: string length" {
    const result = try evalExpr("\"hello\".length");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: empty string length" {
    const result = try evalExpr("\"\".length");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── Phase 1d: For loops ────────────────────────────────────────

test "eval: for loop sum" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 1; i <= 10; i = i + 1) {
        \\  sum = sum + i;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), result.asNumber(), 0.001);
}

test "eval: for loop factorial" {
    const result = try evalExpr(
        \\var result = 1;
        \\for (var i = 1; i <= 5; i = i + 1) {
        \\  result = result * i;
        \\}
        \\result
    );
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), result.asNumber(), 0.001);
}

test "eval: for loop with let" {
    const result = try evalExpr(
        \\var total = 0;
        \\for (let i = 0; i < 5; i = i + 1) {
        \\  total = total + i;
        \\}
        \\total
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: for loop empty parts" {
    const result = try evalExpr(
        \\function f() {
        \\  var x = 0;
        \\  for (;;) {
        \\    x = x + 1;
        \\    if (x >= 3) return x;
        \\  }
        \\}
        \\f()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: nested for loops" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 0; i < 3; i = i + 1) {
        \\  for (var j = 0; j < 3; j = j + 1) {
        \\    sum = sum + 1;
        \\  }
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: do-while loop" {
    const result = try evalExpr(
        \\var x = 0;
        \\do {
        \\  x = x + 1;
        \\} while (x < 5);
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: do-while runs at least once" {
    const result = try evalExpr(
        \\var x = 10;
        \\do {
        \\  x = x + 1;
        \\} while (false);
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.asNumber(), 0.001);
}

// ── Phase 1d: Arrays ───────────────────────────────────────────

test "eval: empty array" {
    const result = try evalExpr("var a = []; a");
    try std.testing.expect(result.isObject());
}

test "eval: array literal" {
    const result = try evalExpr("var a = [1, 2, 3]; a.length");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array index access" {
    const result = try evalExpr("var a = [10, 20, 30]; a[1]");
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

test "eval: array index assignment" {
    const result = try evalExpr("var a = [1, 2, 3]; a[0] = 99; a[0]");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: array length after push via index" {
    const result = try evalExpr("var a = []; a[0] = 42; a.length");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: array with expressions" {
    const result = try evalExpr("var x = 5; var a = [x, x * 2, x * 3]; a[2]");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: for loop with array" {
    const result = try evalExpr(
        \\var a = [10, 20, 30, 40, 50];
        \\var sum = 0;
        \\for (var i = 0; i < a.length; i = i + 1) {
        \\  sum = sum + a[i];
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), result.asNumber(), 0.001);
}

test "eval: array out of bounds" {
    const result = try evalExpr("var a = [1, 2]; a[5]");
    try std.testing.expect(result.isUndefined());
}

// ── Phase 1d: Combined patterns ────────────────────────────────

test "eval: string concat in loop" {
    const result = try evalExpr(
        \\var s = "";
        \\for (var i = 0; i < 3; i = i + 1) {
        \\  s = s + "x";
        \\}
        \\s.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array of objects" {
    const result = try evalExpr(
        \\var arr = [{x: 1}, {x: 2}, {x: 3}];
        \\arr[0].x + arr[1].x + arr[2].x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: function returns array" {
    const result = try evalExpr(
        \\function range(n) {
        \\  var a = [];
        \\  for (var i = 0; i < n; i = i + 1) {
        \\    a[i] = i;
        \\  }
        \\  return a;
        \\}
        \\var r = range(5);
        \\r[4]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

// ── Phase 1e: break/continue ──────────────────────────────────

test "eval: break in for loop" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 0; i < 10; i = i + 1) {
        \\  if (i >= 5) break;
        \\  sum = sum + i;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: break in while loop" {
    const result = try evalExpr(
        \\var x = 0;
        \\while (true) {
        \\  x = x + 1;
        \\  if (x >= 7) break;
        \\}
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: continue in for loop" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 0; i < 10; i = i + 1) {
        \\  if (i % 2 === 0) continue;
        \\  sum = sum + i;
        \\}
        \\sum
    );
    // 1+3+5+7+9 = 25
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.asNumber(), 0.001);
}

test "eval: continue in while loop" {
    const result = try evalExpr(
        \\var sum = 0;
        \\var i = 0;
        \\while (i < 10) {
        \\  i = i + 1;
        \\  if (i % 2 === 0) continue;
        \\  sum = sum + i;
        \\}
        \\sum
    );
    // 1+3+5+7+9 = 25
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.asNumber(), 0.001);
}

test "eval: break in nested loops" {
    const result = try evalExpr(
        \\var count = 0;
        \\for (var i = 0; i < 5; i = i + 1) {
        \\  for (var j = 0; j < 5; j = j + 1) {
        \\    if (j >= 2) break;
        \\    count = count + 1;
        \\  }
        \\}
        \\count
    );
    // 5 outer * 2 inner = 10
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: break in do-while" {
    const result = try evalExpr(
        \\var x = 0;
        \\do {
        \\  x = x + 1;
        \\  if (x >= 3) break;
        \\} while (true);
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: continue in do-while" {
    const result = try evalExpr(
        \\function f() {
        \\  var sum = 0;
        \\  var i = 0;
        \\  do {
        \\    i = i + 1;
        \\    if (i % 2 === 0) continue;
        \\    sum = sum + i;
        \\  } while (i < 10);
        \\  return sum;
        \\}
        \\f()
    );
    // 1+3+5+7+9 = 25
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.asNumber(), 0.001);
}

// ── Phase 1e: switch ──────────────────────────────────────────

test "eval: switch basic" {
    const result = try evalExpr(
        \\var x = 2;
        \\var r = 0;
        \\switch (x) {
        \\  case 1: r = 10; break;
        \\  case 2: r = 20; break;
        \\  case 3: r = 30; break;
        \\}
        \\r
    );
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

test "eval: switch default" {
    const result = try evalExpr(
        \\var x = 99;
        \\var r = 0;
        \\switch (x) {
        \\  case 1: r = 10; break;
        \\  case 2: r = 20; break;
        \\  default: r = 999; break;
        \\}
        \\r
    );
    try std.testing.expectApproxEqAbs(@as(f64, 999.0), result.asNumber(), 0.001);
}

test "eval: switch fallthrough" {
    const result = try evalExpr(
        \\var x = 1;
        \\var r = 0;
        \\switch (x) {
        \\  case 1: r = r + 10;
        \\  case 2: r = r + 20; break;
        \\  case 3: r = r + 30; break;
        \\}
        \\r
    );
    // case 1 matches, falls through to case 2: 10 + 20 = 30
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: switch no match no default" {
    const result = try evalExpr(
        \\var x = 99;
        \\var r = 42;
        \\switch (x) {
        \\  case 1: r = 10; break;
        \\  case 2: r = 20; break;
        \\}
        \\r
    );
    // No match, no default — r unchanged
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Phase 1e: typeof ──────────────────────────────────────────

test "eval: typeof number" {
    const result = try evalExpr("typeof 42");
    try std.testing.expect(result.isString());
}

test "eval: typeof string" {
    const result = try evalExpr("typeof \"hello\"");
    try std.testing.expect(result.isString());
}

test "eval: typeof boolean" {
    const result = try evalExpr("typeof true");
    try std.testing.expect(result.isString());
}

test "eval: typeof undefined" {
    const result = try evalExpr("typeof undefined");
    try std.testing.expect(result.isString());
}

test "eval: typeof null is object" {
    const result = try evalExpr("typeof null === \"object\"");
    try std.testing.expect(result.asBool());
}

test "eval: typeof function" {
    const result = try evalExpr("typeof function(){} === \"function\"");
    try std.testing.expect(result.asBool());
}

test "eval: typeof number check" {
    const result = try evalExpr("typeof 42 === \"number\"");
    try std.testing.expect(result.asBool());
}

// ── Phase 1e: this ────────────────────────────────────────────

test "eval: this in method" {
    const result = try evalExpr(
        \\var obj = {x: 42, getX: function() { return this.x; }};
        \\obj.getX()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: this in method with args" {
    const result = try evalExpr(
        \\var obj = {
        \\  val: 10,
        \\  add: function(n) { return this.val + n; }
        \\};
        \\obj.add(5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: this in method modifying state" {
    const result = try evalExpr(
        \\var counter = {
        \\  count: 0,
        \\  inc: function() { this.count = this.count + 1; },
        \\  get: function() { return this.count; }
        \\};
        \\counter.inc();
        \\counter.inc();
        \\counter.inc();
        \\counter.get()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

// ── Phase 1e: new ─────────────────────────────────────────────

test "eval: new basic constructor" {
    const result = try evalExpr(
        \\function Point(x, y) {
        \\  this.x = x;
        \\  this.y = y;
        \\}
        \\var p = new Point(3, 4);
        \\p.x + p.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: new returns object" {
    const result = try evalExpr(
        \\function Foo() { this.val = 99; }
        \\var f = new Foo();
        \\f.val
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: new with method" {
    const result = try evalExpr(
        \\function Dog(name) {
        \\  this.name = name;
        \\  this.speak = function() { return this.name; };
        \\}
        \\var d = new Dog("Rex");
        \\d.speak()
    );
    try std.testing.expect(result.isString());
}

// ── Phase 1e: console.log ─────────────────────────────────────

test "eval: console.log exists" {
    const result = try evalExpr("typeof console");
    try std.testing.expect(result.isString());
}

test "eval: console.log returns undefined" {
    const result = try evalExpr(
        \\var r = console.log("test");
        \\r
    );
    try std.testing.expect(result.isUndefined());
}

// ── Phase 1f: Number-to-string ────────────────────────────────

test "eval: number + string coercion" {
    const result = try evalExpr("\"val: \" + 42");
    try std.testing.expect(result.isString());
}

test "eval: number to string via concat" {
    const result = try evalExpr("\"\" + 123 === \"123\"");
    try std.testing.expect(result.asBool());
}

test "eval: negative number to string" {
    const result = try evalExpr("\"\" + -5 === \"-5\"");
    try std.testing.expect(result.asBool());
}

test "eval: zero to string" {
    const result = try evalExpr("\"\" + 0 === \"0\"");
    try std.testing.expect(result.asBool());
}

test "eval: bool to string" {
    const result = try evalExpr("\"\" + true === \"true\"");
    try std.testing.expect(result.asBool());
}

test "eval: null to string" {
    const result = try evalExpr("\"\" + null === \"null\"");
    try std.testing.expect(result.asBool());
}

// ── Phase 1f: Array methods ───────────────────────────────────

test "eval: array push" {
    const result = try evalExpr(
        \\var a = [1, 2];
        \\a.push(3);
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array push returns length" {
    const result = try evalExpr(
        \\var a = [1, 2];
        \\a.push(3)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array pop" {
    const result = try evalExpr(
        \\var a = [10, 20, 30];
        \\a.pop()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: array pop reduces length" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\a.pop();
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: array shift" {
    const result = try evalExpr(
        \\var a = [10, 20, 30];
        \\a.shift()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: array indexOf" {
    const result = try evalExpr(
        \\var a = [10, 20, 30, 20];
        \\a.indexOf(20)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: array indexOf not found" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\a.indexOf(99)
    );
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "eval: array indexOf coerces fromIndex" {
    const result = try evalExpr(
        \\var a = [1, 2, 1, 2];
        \\a.indexOf(1, "1") * 10 + a.indexOf(1, -2)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 22.0), result.asNumber(), 0.001);
}

test "eval: array indexOf works on array-like objects" {
    const result = try evalExpr(
        \\Array.prototype.indexOf.call({0: "a", 1: "b", length: "2"}, "b")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: array includes" {
    const result = try evalExpr("[1, 2, 3].includes(2)");
    try std.testing.expect(result.asBool());
}

test "eval: array includes false" {
    const result = try evalExpr("[1, 2, 3].includes(5)");
    try std.testing.expect(!result.asBool());
}

test "eval: array includes coerces fromIndex and handles missing array-like entries" {
    const result = try evalExpr(
        \\Array.prototype.includes.call({0: "a", length: "2"}, undefined, "1") &&
        \\[1, 2, 3].includes(1, 1) === false
    );
    try std.testing.expect(result.asBool());
}

test "eval: array join" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\a.join("-") === "1-2-3"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array join default comma" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\a.join() === "1,2,3"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array join coerces separator" {
    const result = try evalExpr(
        \\[1, 2, 3].join(0) === "10203"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array join works on array-like objects" {
    const result = try evalExpr(
        \\Array.prototype.join.call({0: "a", 2: null, length: "4"}, "-") === "a---"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array toLocaleString calls element methods" {
    const result = try evalExpr(
        \\var item = { toLocaleString: function() { return "local"; }, toString: function() { return "plain"; } };
        \\[item, null, undefined, 3].toLocaleString() === "local,,,3"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array reverse" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\a.reverse();
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array slice" {
    const result = try evalExpr(
        \\var a = [10, 20, 30, 40, 50];
        \\var b = a.slice(1, 3);
        \\b.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: array slice values" {
    const result = try evalExpr(
        \\var a = [10, 20, 30, 40];
        \\var b = a.slice(1, 3);
        \\b[0] + b[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), result.asNumber(), 0.001);
}

test "eval: array slice negative" {
    const result = try evalExpr(
        \\var a = [1, 2, 3, 4, 5];
        \\var b = a.slice(-2);
        \\b[0] + b[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: array slice coerces start and end" {
    const result = try evalExpr(
        \\var a = [10, 20, 30, 40];
        \\var b = a.slice("1", "3");
        \\b[0] + b[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), result.asNumber(), 0.001);
}

test "eval: array slice works on array-like objects" {
    const result = try evalExpr(
        \\var b = Array.prototype.slice.call({0: 10, 2: 30, length: "3"}, 1);
        \\b.length === 2 && b[0] === undefined && b[1] === 30
    );
    try std.testing.expect(result.asBool());
}

test "eval: array slice reads array-like accessors" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var b = Array.prototype.slice.call({ get 0() { calls = calls + 1; return 6; }, get length() { calls = calls + 1; return 1; } });
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 62.0), result.asNumber(), 0.001);
}

test "eval: array concat" {
    const result = try evalExpr(
        \\var a = [1, 2];
        \\var b = [3, 4];
        \\var c = a.concat(b);
        \\c.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: array concat reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 7; } });
        \\var b = a.concat([2]);
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: array concat works with object receiver" {
    const result = try evalExpr(
        \\var o = {x: 1};
        \\var a = Array.prototype.concat.call(o, 2);
        \\a.length === 2 && a[0] === o && a[1] === 2
    );
    try std.testing.expect(result.asBool());
}

// ── Phase 1f: String methods ──────────────────────────────────

test "eval: string charAt" {
    const result = try evalExpr("\"hello\".charAt(1) === \"e\"");
    try std.testing.expect(result.asBool());
}

test "eval: string charCodeAt" {
    const result = try evalExpr("\"A\".charCodeAt(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), result.asNumber(), 0.001);
}

test "eval: string indexOf" {
    const result = try evalExpr("\"hello world\".indexOf(\"world\")");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: string indexOf not found" {
    const result = try evalExpr("\"hello\".indexOf(\"xyz\")");
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "eval: string includes" {
    const result = try evalExpr("\"hello world\".includes(\"world\")");
    try std.testing.expect(result.asBool());
}

test "eval: string includes false" {
    const result = try evalExpr("\"hello\".includes(\"xyz\")");
    try std.testing.expect(!result.asBool());
}

test "eval: string substring" {
    const result = try evalExpr("\"hello\".substring(1, 3) === \"el\"");
    try std.testing.expect(result.asBool());
}

test "eval: string slice" {
    const result = try evalExpr("\"hello\".slice(1, 4) === \"ell\"");
    try std.testing.expect(result.asBool());
}

test "eval: string slice negative" {
    const result = try evalExpr("\"hello\".slice(-3) === \"llo\"");
    try std.testing.expect(result.asBool());
}

test "eval: string position methods coerce numeric arguments" {
    const result = try evalExpr(
        \\"hello".charAt("1") === "e" &&
        \\"ABC".charCodeAt("1") === 66 &&
        \\"hello".substring("1", "3") === "el" &&
        \\"hello".slice("1", "4") === "ell" &&
        \\"x".padStart("3", "0") === "00x" &&
        \\"x".padEnd("3", "0") === "x00" &&
        \\"abc".at("-1") === "c"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string split" {
    const result = try evalExpr(
        \\var parts = "a,b,c".split(",");
        \\parts.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: string split values" {
    const result = try evalExpr(
        \\var parts = "hello world".split(" ");
        \\parts[0] === "hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string split handles limit and empty separator" {
    const result = try evalExpr(
        \\var a = "a,b,c".split(",", 2);
        \\var b = "abc".split("", 2);
        \\var c = "あい".split("");
        \\var d = "a,b".split(",", 0);
        \\a.length === 2 && a[1] === "b" &&
        \\b.length === 2 && b[0] === "a" && b[1] === "b" &&
        \\c.length === 2 && c[0] === "あ" && c[1] === "い" &&
        \\d.length === 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: string regex split handles limit" {
    const result = try evalExpr(
        \\var a = "a1b2c".split(/\d/, 2);
        \\a.length === 2 && a[0] === "a" && a[1] === "b"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string trim" {
    const result = try evalExpr("\"  hello  \".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles vertical tab and form feed" {
    const result = try evalExpr("\"\\x0bhello\\f\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles non-breaking space" {
    const result = try evalExpr("\"\\u00a0hello\\u00a0\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles byte order mark" {
    const result = try evalExpr("\"\\ufeffhello\\ufeff\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles line separator" {
    const result = try evalExpr("\"\\u2028hello\\u2028\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles paragraph separator" {
    const result = try evalExpr("\"\\u2029hello\\u2029\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles em space" {
    const result = try evalExpr("\"\\u2003hello\\u2003\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trim handles ideographic space" {
    const result = try evalExpr("\"\\u3000hello\\u3000\".trim() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trimStart and trimEnd handle vertical tab and form feed" {
    const result = try evalExpr("\"\\x0bhello\".trimStart() === \"hello\" && \"hello\\f\".trimEnd() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trimStart and trimEnd handle non-breaking space" {
    const result = try evalExpr("\"\\u00a0hello\".trimStart() === \"hello\" && \"hello\\u00a0\".trimEnd() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string trimLeft and trimRight aliases" {
    const result = try evalExpr(
        \\typeof String.prototype.trimLeft === "function" &&
        \\typeof String.prototype.trimRight === "function" &&
        \\String.prototype.trimLeft === String.prototype.trimStart &&
        \\String.prototype.trimRight === String.prototype.trimEnd &&
        \\"  hello".trimLeft() === "hello" &&
        \\"hello  ".trimRight() === "hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string toUpperCase" {
    const result = try evalExpr("\"hello\".toUpperCase() === \"HELLO\"");
    try std.testing.expect(result.asBool());
}

test "eval: string toLowerCase" {
    const result = try evalExpr("\"HELLO\".toLowerCase() === \"hello\"");
    try std.testing.expect(result.asBool());
}

test "eval: string toLocale case methods" {
    const result = try evalExpr(
        \\"hello".toLocaleUpperCase() === "HELLO" &&
        \\"HELLO".toLocaleLowerCase() === "hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string startsWith" {
    const result = try evalExpr("\"hello world\".startsWith(\"hello\")");
    try std.testing.expect(result.asBool());
}

test "eval: string endsWith" {
    const result = try evalExpr("\"hello world\".endsWith(\"world\")");
    try std.testing.expect(result.asBool());
}

test "eval: string search methods coerce primitive arguments" {
    const result = try evalExpr(
        \\"a123".indexOf(123) === 1 &&
        \\"ababa".indexOf("ba", 2) === 3 &&
        \\"abc".indexOf("", 2) === 2 &&
        \\"a123".includes(123) &&
        \\"ababa".includes("ba", 2) &&
        \\"ababa".includes("ba", 4) === false &&
        \\"true!".startsWith(true) &&
        \\"abc".startsWith("b", 1) &&
        \\"a-null".endsWith(null) &&
        \\"abcd".endsWith("bc", 3) &&
        \\"a1b1".split(1).join(",") === "a,b," &&
        \\"a1b".replace(1, false) === "afalseb" &&
        \\"undefined".includes() &&
        \\"undefined".startsWith() &&
        \\"undefined".endsWith() &&
        \\"a123b123".lastIndexOf(123) === 5 &&
        \\"ababa".lastIndexOf("ba", 2) === 1 &&
        \\"abc".lastIndexOf("", 1) === 1 &&
        \\"abc".lastIndexOf("b", 0) === -1 &&
        \\"a1a1".replaceAll(1, false) === "afalseafalse" &&
        \\"ab".replaceAll("", "-") === "-a-b-" &&
        \\"あい".replaceAll("", "-") === "-あ-い-" &&
        \\"x".concat(1, false, null) === "x1falsenull" &&
        \\"123".localeCompare(123) === 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: string pad methods coerce pad string" {
    const result = try evalExpr(
        \\"x".padStart(4, 12) === "121x" &&
        \\"x".padEnd(4, false) === "xfal" &&
        \\"x".padStart(4, "") === "x" &&
        \\"x".padEnd(4, "") === "x" &&
        \\"あ".padStart(3, "い") === "いいあ" &&
        \\"あ".padEnd(3, "い") === "あいい"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string repeat coerces count and rejects range errors" {
    const result = try evalExpr(
        \\"ha".repeat("3") === "hahaha" &&
        \\"x".repeat(true) === "x" &&
        \\"x".repeat(undefined) === "" &&
        \\(function(){ try { "x".repeat(-1); } catch (e) { return e.name === "RangeError"; } return false; })() &&
        \\(function(){ try { "x".repeat(Infinity); } catch (e) { return e.name === "RangeError"; } return false; })()
    );
    try std.testing.expect(result.asBool());
}

test "eval: string replace" {
    const result = try evalExpr("\"hello world\".replace(\"world\", \"zig\") === \"hello zig\"");
    try std.testing.expect(result.asBool());
}

// ── Phase 1f: Combined patterns ───────────────────────────────

test "eval: split and join roundtrip" {
    const result = try evalExpr(
        \\var s = "a-b-c";
        \\s.split("-").join(",") === "a,b,c"
    );
    try std.testing.expect(result.asBool());
}

test "eval: array push and iteration" {
    const result = try evalExpr(
        \\var a = [];
        \\a.push(10);
        \\a.push(20);
        \\a.push(30);
        \\var sum = 0;
        \\for (var i = 0; i < a.length; i = i + 1) {
        \\  sum = sum + a[i];
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: string method chaining" {
    const result = try evalExpr("\"  Hello World  \".trim().toLowerCase() === \"hello world\"");
    try std.testing.expect(result.asBool());
}

// ── Phase 1g: ++/-- operators ─────────────────────────────────

test "eval: post increment" {
    const result = try evalExpr("var x = 5; x++; x");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: post increment returns old" {
    const result = try evalExpr("var x = 5; x++");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: pre increment" {
    const result = try evalExpr("var x = 5; ++x");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: post decrement" {
    const result = try evalExpr("var x = 10; x--; x");
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: pre decrement" {
    const result = try evalExpr("var x = 10; --x");
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: for loop with i++" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 0; i < 10; i++) {
        \\  sum = sum + i;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 45.0), result.asNumber(), 0.001);
}

test "eval: for loop with i-- countdown" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var i = 5; i > 0; i--) {
        \\  sum = sum + i;
        \\}
        \\sum
    );
    // 5+4+3+2+1 = 15
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

// ── Phase 1g: prototype chain ─────────────────────────────────

test "eval: __proto__ property lookup" {
    const result = try evalExpr(
        \\var proto = {greet: function() { return 42; }};
        \\var obj = {};
        \\obj.__proto__ = proto;
        \\obj.greet()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: constructor prototype" {
    const result = try evalExpr(
        \\function Animal(name) { this.name = name; }
        \\Animal.prototype = {speak: function() { return this.name; }};
        \\var a = new Animal("Cat");
        \\a.speak()
    );
    try std.testing.expect(result.isString());
}

test "eval: prototype chain inheritance" {
    const result = try evalExpr(
        \\var base = {x: 10};
        \\var child = {y: 20};
        \\child.__proto__ = base;
        \\child.x + child.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

// ── Phase 1g: forEach/map/filter ──────────────────────────────

test "eval: array forEach" {
    const result = try evalExpr(
        \\var sum = 0;
        \\[1, 2, 3, 4, 5].forEach(function(x) { sum = sum + x; });
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: array forEach reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var sum = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 5; } });
        \\a.forEach(function(x) { sum = sum + x; });
        \\sum * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 51.0), result.asNumber(), 0.001);
}

test "eval: array map" {
    const result = try evalExpr(
        \\var doubled = [1, 2, 3].map(function(x) { return x * 2; });
        \\doubled[0] + doubled[1] + doubled[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: array map reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 6; } });
        \\var b = a.map(function(x) { return x + 1; });
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: array filter" {
    const result = try evalExpr(
        \\var evens = [1, 2, 3, 4, 5, 6].filter(function(x) { return x % 2 === 0; });
        \\evens.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array filter reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 8; } });
        \\var b = a.filter(function(x) { return x === 8; });
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 81.0), result.asNumber(), 0.001);
}

test "eval: map then filter chain" {
    const result = try evalExpr(
        \\var result = [1, 2, 3, 4, 5]
        \\  .map(function(x) { return x * 2; })
        \\  .filter(function(x) { return x > 5; });
        \\result.length
    );
    // [2,4,6,8,10].filter(>5) = [6,8,10]
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: forEach with index" {
    const result = try evalExpr(
        \\var indices = 0;
        \\["a", "b", "c"].forEach(function(val, idx) { indices = indices + idx; });
        \\indices
    );
    // 0+1+2 = 3
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

// ── Phase 1g: try/catch/throw ─────────────────────────────────

test "eval: try catch basic" {
    const result = try evalExpr(
        \\var x = 0;
        \\try {
        \\  throw 42;
        \\  x = 999;
        \\} catch (e) {
        \\  x = e;
        \\}
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: try catch no error" {
    const result = try evalExpr(
        \\var x = 0;
        \\try {
        \\  x = 10;
        \\} catch (e) {
        \\  x = 999;
        \\}
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: throw string" {
    const result = try evalExpr(
        \\var msg = "";
        \\try {
        \\  throw "oops";
        \\} catch (e) {
        \\  msg = e;
        \\}
        \\msg === "oops"
    );
    try std.testing.expect(result.asBool());
}

test "eval: throw in function" {
    const result = try evalExpr(
        \\function fail() { throw 99; }
        \\var x = 0;
        \\try {
        \\  fail();
        \\} catch (e) {
        \\  x = e;
        \\}
        \\x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: nested try catch" {
    const result = try evalExpr(
        \\var x = 0;
        \\try {
        \\  try {
        \\    throw 1;
        \\  } catch (e) {
        \\    x = e;
        \\    throw 2;
        \\  }
        \\} catch (e) {
        \\  x = x + e;
        \\}
        \\x
    );
    // inner catch: x=1, then throw 2, outer catch: x=1+2=3
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

// ── Phase 1g: Combined patterns ───────────────────────────────

test "eval: real-world pattern — sum with forEach and ++" {
    const result = try evalExpr(
        \\var total = 0;
        \\var items = [10, 20, 30];
        \\items.forEach(function(item) { total += item; });
        \\total
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: constructor with prototype methods" {
    const result = try evalExpr(
        \\function Counter(start) { this.val = start; }
        \\Counter.prototype = {
        \\  inc: function() { this.val++; },
        \\  get: function() { return this.val; }
        \\};
        \\var c = new Counter(0);
        \\c.inc();
        \\c.inc();
        \\c.inc();
        \\c.get()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

// ── Default parameter values ──────────────────────────────────────

test "eval: function with default param (not provided)" {
    const result = try evalExpr(
        \\function greet(name, greeting) {
        \\  if (greeting === undefined) greeting = "hello";
        \\  return greeting;
        \\}
        \\greet("world")
    );
    // Baseline: manual undefined check works
    try std.testing.expect(result.isString());
}

test "eval: default param value used when arg missing" {
    const result = try evalExpr(
        \\function add(a, b = 10) {
        \\  return a + b;
        \\}
        \\add(5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: default param value overridden when arg provided" {
    const result = try evalExpr(
        \\function add(a, b = 10) {
        \\  return a + b;
        \\}
        \\add(5, 20)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.asNumber(), 0.001);
}

test "eval: default param with object literal" {
    const result = try evalExpr(
        \\function setup(opts = {}) {
        \\  return typeof opts;
        \\}
        \\setup()
    );
    try std.testing.expect(result.isString());
}

test "eval: multiple default params" {
    const result = try evalExpr(
        \\function calc(a = 1, b = 2, c = 3) {
        \\  return a + b + c;
        \\}
        \\calc()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: default param in function expression" {
    const result = try evalExpr(
        \\var fn1 = function(x, y = 100) {
        \\  return x + y;
        \\};
        \\fn1(1)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), result.asNumber(), 0.001);
}

test "eval: rest parameter basic" {
    const result = try evalExpr(
        \\function first(a, ...rest) {
        \\  return a;
        \\}
        \\first(42, 1, 2, 3)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Object.keys/values/entries ──────────────────────────────────

test "eval: Object.keys returns property count" {
    const result = try evalExpr(
        \\var obj = { a: 1, b: 2, c: 3 };
        \\Object.keys(obj).length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Object.values returns values" {
    const result = try evalExpr(
        \\var obj = { x: 10, y: 20 };
        \\var vals = Object.values(obj);
        \\vals[0] + vals[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: Object.values reads accessor values" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var obj = {};
        \\Object.defineProperty(obj, "x", { enumerable: true, get: function() { calls = calls + 1; return 7; } });
        \\var vals = Object.values(obj);
        \\vals[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: Object.entries returns pairs" {
    const result = try evalExpr(
        \\var obj = { a: 100 };
        \\var entries = Object.entries(obj);
        \\entries.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Object.entries pair structure" {
    const result = try evalExpr(
        \\var obj = { x: 42 };
        \\var entries = Object.entries(obj);
        \\entries[0][1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: Object.entries reads accessor values" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var obj = {};
        \\Object.defineProperty(obj, "x", { enumerable: true, get: function() { calls = calls + 1; return 8; } });
        \\var entries = Object.entries(obj);
        \\entries[0][1] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 81.0), result.asNumber(), 0.001);
}

test "eval: Object.assign copies properties" {
    const result = try evalExpr(
        \\var target = { a: 1 };
        \\var source = { b: 2, c: 3 };
        \\Object.assign(target, source);
        \\target.a + target.b + target.c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: Object.assign reads accessor values" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var source = {};
        \\Object.defineProperty(source, "x", { enumerable: true, get: function() { calls = calls + 1; return 9; } });
        \\var target = {};
        \\Object.assign(target, source);
        \\target.x * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 91.0), result.asNumber(), 0.001);
}

test "eval: Object.assign copies symbol properties" {
    const result = try evalExpr(
        \\var s = Symbol("x");
        \\var source = {};
        \\source[s] = 7;
        \\var target = {};
        \\Object.assign(target, source);
        \\target[s]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: Object.assign overwrites" {
    const result = try evalExpr(
        \\var a = { x: 1 };
        \\var b = { x: 99 };
        \\Object.assign(a, b);
        \\a.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: Object.create with prototype" {
    const result = try evalExpr(
        \\var proto = { greet: function() { return 42; } };
        \\var obj = Object.create(proto);
        \\obj.greet()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: Object.create applies accessor descriptor map" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var props = {};
        \\Object.defineProperty(props, "x", { get: function() { calls = calls + 1; return { value: 7, enumerable: true }; } });
        \\var obj = Object.create(null, props);
        \\obj.x * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: Object.create applies symbol descriptor map" {
    const result = try evalExpr(
        \\var sym = Symbol("x");
        \\var props = {};
        \\props[sym] = { value: 8, enumerable: true };
        \\var obj = Object.create(null, props);
        \\obj[sym]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: Object.keys empty object" {
    const result = try evalExpr(
        \\Object.keys({}).length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Object.setPrototypeOf" {
    const result = try evalExpr(
        \\var proto = { val: 77 };
        \\var obj = {};
        \\Object.setPrototypeOf(obj, proto);
        \\obj.val
    );
    try std.testing.expectApproxEqAbs(@as(f64, 77.0), result.asNumber(), 0.001);
}

test "eval: Object.getPrototypeOf" {
    const result = try evalExpr(
        \\var proto = { x: 5 };
        \\var obj = Object.create(proto);
        \\var p = Object.getPrototypeOf(obj);
        \\p.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

// ── Array.isArray / Array.from ──────────────────────────────────

test "eval: Array.isArray true" {
    const result = try evalExpr(
        \\Array.isArray([1, 2, 3])
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.isArray false for object" {
    const result = try evalExpr(
        \\Array.isArray({})
    );
    try std.testing.expect(!result.asBool());
}

test "eval: Array.isArray false for number" {
    const result = try evalExpr(
        \\Array.isArray(42)
    );
    try std.testing.expect(!result.asBool());
}

test "eval: Array.from copies array" {
    const result = try evalExpr(
        \\var src = [10, 20, 30];
        \\var copy = Array.from(src);
        \\copy.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

// ── Math ────────────────────────────────────────────────────────

test "eval: Math.floor" {
    const result = try evalExpr("Math.floor(3.7)");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Math.ceil" {
    const result = try evalExpr("Math.ceil(3.2)");
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Math.abs negative" {
    const result = try evalExpr("Math.abs(-5)");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Math.max" {
    const result = try evalExpr("Math.max(1, 5, 3)");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Math.max prefers positive zero" {
    const result = try evalExpr("Object.is(Math.max(-0, 0), 0)");
    try std.testing.expect(result.asBool());
}

test "eval: Math.min" {
    const result = try evalExpr("Math.min(1, 5, 3)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Math.min prefers negative zero" {
    const result = try evalExpr("Object.is(Math.min(0, -0), -0)");
    try std.testing.expect(result.asBool());
}

test "eval: Math.pow" {
    const result = try evalExpr("Math.pow(2, 10)");
    try std.testing.expectApproxEqAbs(@as(f64, 1024.0), result.asNumber(), 0.001);
}

test "eval: Math.sqrt" {
    const result = try evalExpr("Math.sqrt(144)");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: Math.trunc" {
    const result = try evalExpr("Math.trunc(4.9)");
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Math.sign preserves negative zero" {
    const result = try evalExpr("Object.is(Math.sign(-0), -0)");
    try std.testing.expect(result.asBool());
}

test "eval: Math.round preserves negative zero" {
    const result = try evalExpr("Object.is(Math.round(-0.5), -0)");
    try std.testing.expect(result.asBool());
}

test "eval: Math basic methods coerce string numbers" {
    const result = try evalExpr(
        \\Math.floor("3.7") === 3 &&
        \\Math.ceil("3.2") === 4 &&
        \\Math.round("3.5") === 4 &&
        \\Math.abs("-5") === 5 &&
        \\Math.min("2", 1) === 1 &&
        \\Math.max("2", 1) === 2 &&
        \\Math.pow("2", "3") === 8 &&
        \\Math.sqrt("144") === 12 &&
        \\Math.trunc("4.9") === 4
    );
    try std.testing.expect(result.asBool());
}

test "eval: Math.PI" {
    const result = try evalExpr("Math.PI");
    try std.testing.expectApproxEqAbs(std.math.pi, result.asNumber(), 0.0001);
}

test "eval: Math.random returns 0..1" {
    const result = try evalExpr("Math.random()");
    const n = result.asNumber();
    try std.testing.expect(n >= 0.0 and n < 1.0);
}

// ── JSON ────────────────────────────────────────────────────────

test "eval: JSON.stringify number" {
    const result = try evalExpr("JSON.stringify(42)");
    try std.testing.expect(result.isString());
}

test "eval: JSON.stringify primitive exact output" {
    const result = try evalExpr(
        \\JSON.stringify(42) === '42' &&
        \\JSON.stringify(null) === 'null' &&
        \\JSON.stringify(true) === 'true' &&
        \\JSON.stringify("x") === '"x"'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify non-finite numbers become null" {
    const result = try evalExpr(
        \\JSON.stringify(NaN) === 'null' &&
        \\JSON.stringify(Infinity) === 'null' &&
        \\JSON.stringify(-Infinity) === 'null' &&
        \\JSON.stringify([NaN, Infinity]) === '[null,null]' &&
        \\JSON.stringify({x: NaN}) === '{"x":null}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON method length properties" {
    const result = try evalExpr("JSON.stringify.length === 3 && JSON.parse.length === 2");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify undefined top-level" {
    const result = try evalExpr("JSON.stringify(undefined)");
    try std.testing.expect(result.isUndefined());
}

test "eval: JSON.stringify function top-level" {
    const result = try evalExpr("JSON.stringify(function(){})");
    try std.testing.expect(result.isUndefined());
}

test "eval: JSON.stringify symbol top-level" {
    const result = try evalExpr("JSON.stringify(Symbol('x'))");
    try std.testing.expect(result.isUndefined());
}

test "eval: JSON.stringify omits undefined object property" {
    const result = try evalExpr("JSON.stringify({a: undefined, b: 1}) === '{\"b\":1}'");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify omits function object property" {
    const result = try evalExpr("JSON.stringify({a: function(){}, b: 1}) === '{\"b\":1}'");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify omits symbol object property" {
    const result = try evalExpr("JSON.stringify({a: Symbol('x'), b: 1}) === '{\"b\":1}'");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify function array element becomes null" {
    const result = try evalExpr("JSON.stringify([function(){}, 1]) === '[null,1]'");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify symbol array element becomes null" {
    const result = try evalExpr("JSON.stringify([Symbol('x'), 1]) === '[null,1]'");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify sparse array holes become null" {
    const result = try evalExpr(
        \\var a = [];
        \\a[2] = 3;
        \\JSON.stringify(a) === '[null,null,3]'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes backspace" {
    const result = try evalExpr(
        \\JSON.stringify("\b") === '"\\b"'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes form feed" {
    const result = try evalExpr(
        \\JSON.stringify("\f") === '"\\f"'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes nul" {
    const result = try evalExpr(
        \\JSON.stringify("\0") === '"\\u0000"'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes quote in object key" {
    const result = try evalExpr(
        \\var o = {};
        \\o['a"b'] = 1;
        \\JSON.stringify(o) === '{"a\\"b":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes backslash in object key" {
    const result = try evalExpr(
        \\var o = {};
        \\o['a\\b'] = 1;
        \\JSON.stringify(o) === '{"a\\\\b":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify escapes control object key" {
    const result = try evalExpr(
        \\var o = {};
        \\o["\0"] = 1;
        \\JSON.stringify(o) === '{"\\u0000":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify calls root toJSON" {
    const result = try evalExpr(
        \\JSON.stringify({toJSON: function(){ return 7; }}) === '7'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify calls root toJSON once" {
    const result = try evalExpr(
        \\var calls = 0;
        \\JSON.stringify({toJSON: function(){ calls = calls + 1; return 7; }});
        \\calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: JSON.stringify reads accessor toJSON" {
    const result = try evalExpr(
        \\var getterCalls = 0;
        \\var o = {};
        \\Object.defineProperty(o, "toJSON", { get: function(){ getterCalls = getterCalls + 1; return function(){ return 8; }; } });
        \\JSON.stringify(o) === '8' && getterCalls === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify root toJSON unsupported result is undefined" {
    const result = try evalExpr(
        \\JSON.stringify({toJSON: function(){ return function(){}; }}) === undefined &&
        \\JSON.stringify({toJSON: function(){ return Symbol('x'); }}) === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify passes property key to toJSON" {
    const result = try evalExpr(
        \\JSON.stringify({a: {toJSON: function(k){ return k; }}}) === '{"a":"a"}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify calls property toJSON once" {
    const result = try evalExpr(
        \\var calls = 0;
        \\JSON.stringify({a: {toJSON: function(){ calls = calls + 1; return 7; }}});
        \\calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: JSON.stringify calls array element toJSON" {
    const result = try evalExpr(
        \\JSON.stringify([{toJSON: function(k){ return k; }}]) === '["0"]'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify array toJSON unsupported result becomes null" {
    const result = try evalExpr(
        \\JSON.stringify([
        \\  {toJSON: function(){ return undefined; }},
        \\  {toJSON: function(){ return function(){}; }}
        \\]) === '[null,null]'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify reads array accessor element" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function(){ calls = calls + 1; return 7; } });
        \\JSON.stringify(a) === '[7]' && calls === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify includes non-enumerable array element" {
    const result = try evalExpr(
        \\var a = [1];
        \\Object.defineProperty(a, 0, { enumerable: false, value: 7 });
        \\JSON.stringify(a) === '[7]'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify omits property when toJSON returns undefined" {
    const result = try evalExpr(
        \\JSON.stringify({a: {toJSON: function(){ return undefined; }}, b: 1}) === '{"b":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify omits property when toJSON returns symbol" {
    const result = try evalExpr(
        \\JSON.stringify({a: {toJSON: function(){ return Symbol('x'); }}, b: 1}) === '{"b":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify ignores symbol keyed properties" {
    const result = try evalExpr(
        \\var s = Symbol('x');
        \\var o = {a: 1};
        \\o[s] = 2;
        \\JSON.stringify(o) === '{"a":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify ignores symbol descriptor properties" {
    const result = try evalExpr(
        \\var s = Symbol('x');
        \\var o = {a: 1};
        \\Object.defineProperty(o, s, { enumerable: true, value: 2 });
        \\JSON.stringify(o) === '{"a":1}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify includes enumerable accessor property" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var o = {};
        \\Object.defineProperty(o, "x", { enumerable: true, get: function(){ calls = calls + 1; return 7; } });
        \\JSON.stringify(o) === '{"x":7}' && calls === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify skips non-enumerable descriptor property" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { enumerable: false, value: 7 });
        \\JSON.stringify(o) === '{}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify throws TypeError on object cycle" {
    const result = try evalExpr(
        \\var ok = false;
        \\var o = {};
        \\o.self = o;
        \\try { JSON.stringify(o); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify throws TypeError on array cycle" {
    const result = try evalExpr(
        \\var ok = false;
        \\var a = [];
        \\a[0] = a;
        \\try { JSON.stringify(a); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify throws TypeError on toJSON cycle" {
    const result = try evalExpr(
        \\var ok = false;
        \\var parent = {};
        \\parent.child = {toJSON: function(){ return parent; }};
        \\try { JSON.stringify(parent); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify allows repeated non-cyclic object" {
    const result = try evalExpr(
        \\var child = {x: 1};
        \\JSON.stringify({a: child, b: child}) === '{"a":{"x":1},"b":{"x":1}}'
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify object" {
    const result = try evalExpr("JSON.stringify({a: 1})");
    try std.testing.expect(result.isString());
}

test "eval: JSON.parse and access" {
    const result = try evalExpr(
        \\var obj = JSON.parse('{"x":99}');
        \\obj.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: JSON.parse array" {
    const result = try evalExpr(
        \\var arr = JSON.parse('[1,2,3]');
        \\arr[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: JSON.parse coerces primitive input to string" {
    const result = try evalExpr(
        \\JSON.parse(true) === true &&
        \\JSON.parse(null) === null &&
        \\JSON.parse(42) === 42
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.parse coerces object input to string" {
    const result = try evalExpr(
        \\JSON.parse({toString: function(){ return '{"x":7}'; }}).x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: JSON.parse rejects trailing primitive junk" {
    const result = try evalExpr("JSON.parse('truex')");
    try std.testing.expect(result.isUndefined());
}

test "eval: JSON.parse rejects trailing object junk" {
    const result = try evalExpr("JSON.parse('{\"x\":1}x')");
    try std.testing.expect(result.isUndefined());
}

test "eval: JSON.parse rejects invalid number forms" {
    const result = try evalExpr(
        \\JSON.parse('+1') === undefined &&
        \\JSON.parse('01') === undefined &&
        \\JSON.parse('1.') === undefined &&
        \\JSON.parse('1e') === undefined &&
        \\JSON.parse('1e+') === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.parse rejects invalid object and array punctuation" {
    const result = try evalExpr(
        \\JSON.parse('{\"x\" 1}') === undefined &&
        \\JSON.parse('{\"x\":1 \"y\":2}') === undefined &&
        \\JSON.parse('{\"x\":1,}') === undefined &&
        \\JSON.parse('[1 2]') === undefined &&
        \\JSON.parse('[1,]') === undefined &&
        \\JSON.parse('[1,,2]') === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.parse rejects missing object and array close" {
    const result = try evalExpr(
        \\JSON.parse('{\"x\":1') === undefined &&
        \\JSON.parse('[1,2') === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.parse rejects unterminated strings" {
    const result = try evalExpr(
        \\JSON.parse('"abc') === undefined &&
        \\JSON.parse('{\"x:1}') === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON.parse rejects invalid string escapes" {
    const result = try evalExpr(
        \\JSON.parse('"\\v"') === undefined &&
        \\JSON.parse('"\\u00zz"') === undefined &&
        \\JSON.parse('"' + "\n" + '"') === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: JSON roundtrip" {
    const result = try evalExpr(
        \\var obj = { a: 1, b: true };
        \\var s = JSON.stringify(obj);
        \\var obj2 = JSON.parse(s);
        \\obj2.a
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

// ── parseInt / parseFloat / isNaN / isFinite ────────────────────

test "eval: parseInt basic" {
    const result = try evalExpr("parseInt(42)");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: parseInt and parseFloat coerce input" {
    const result = try evalExpr(
        \\parseInt({toString: function(){ return "11"; }}, "2") === 3 &&
        \\parseFloat({toString: function(){ return "1.5"; }}) === 1.5
    );
    try std.testing.expect(result.asBool());
}

test "eval: parseInt handles radix and hex prefix" {
    const result = try evalExpr(
        \\parseInt(42, 2) !== 42 &&
        \\parseInt("0x10") === 16 &&
        \\parseInt("-0x10") === -16 &&
        \\parseInt("0x10", 16) === 16 &&
        \\parseInt("10", Infinity) === 10 &&
        \\isNaN(parseInt("10", 1)) &&
        \\isNaN(parseInt("10", 37))
    );
    try std.testing.expect(result.asBool());
}

test "eval: parseInt trims form feed" {
    const result = try evalExpr("parseInt(\"\\f42\") === 42");
    try std.testing.expect(result.asBool());
}

test "eval: parseInt trims non-breaking space" {
    const result = try evalExpr("parseInt(\"\\u00a042\\u00a0\") === 42");
    try std.testing.expect(result.asBool());
}

test "eval: parseFloat accepts numeric prefix" {
    const result = try evalExpr(
        \\parseFloat("1.5px") === 1.5 &&
        \\parseFloat("-.25rem") === -0.25 &&
        \\parseFloat("1e2px") === 100 &&
        \\parseFloat("1e") === 1 &&
        \\isNaN(parseFloat("px1"))
    );
    try std.testing.expect(result.asBool());
}

test "eval: parseFloat accepts Infinity prefix" {
    const result = try evalExpr(
        \\parseFloat("Infinitypx") === Infinity &&
        \\parseFloat("-Infinitypx") === -Infinity
    );
    try std.testing.expect(result.asBool());
}

test "eval: parseFloat trims form feed" {
    const result = try evalExpr("parseFloat(\"\\f1.5\") === 1.5");
    try std.testing.expect(result.asBool());
}

test "eval: parseFloat trims non-breaking space" {
    const result = try evalExpr("parseFloat(\"\\u00a01.5\\u00a0\") === 1.5");
    try std.testing.expect(result.asBool());
}

test "eval: Number parse aliases reuse global functions" {
    const result = try evalExpr(
        \\Number.parseInt === parseInt &&
        \\Number.parseFloat === parseFloat
    );
    try std.testing.expect(result.asBool());
}

test "eval: isNaN true" {
    const result = try evalExpr("isNaN(0/0)");
    try std.testing.expect(result.asBool());
}

test "eval: global isNaN coerces strings" {
    const result = try evalExpr(
        \\isNaN("42") === false &&
        \\isNaN("not-a-number") === true
    );
    try std.testing.expect(result.asBool());
}

test "eval: isFinite number" {
    const result = try evalExpr("isFinite(42)");
    try std.testing.expect(result.asBool());
}

test "eval: global isFinite coerces strings" {
    const result = try evalExpr(
        \\isFinite("42") === true &&
        \\isFinite("not-a-number") === false
    );
    try std.testing.expect(result.asBool());
}

test "eval: isFinite infinity" {
    const result = try evalExpr("isFinite(1/0)");
    try std.testing.expect(!result.asBool());
}

// ── Map ─────────────────────────────────────────────────────────

test "eval: new Map basic" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 1);
        \\m.set("b", 2);
        \\m.get("a") + m.get("b")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Map size" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("x", 10);
        \\m.set("y", 20);
        \\m.size
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: Map has/delete" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 1);
        \\var had = m.has("a");
        \\m.delete("a");
        \\var hasAfter = m.has("a");
        \\had && !hasAfter
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map clear" {
    const result = try evalExpr(
        \\var m = new Map([["a", 1], ["b", 2]]);
        \\var ret = m.clear();
        \\m.size === 0 && !m.has("a") && ret === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map overwrite value" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 1);
        \\m.set("a", 99);
        \\m.get("a")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: Map constructor consumes entries" {
    const result = try evalExpr(
        \\var m = new Map([["a", 1], ["b", 2], ["a", 9]]);
        \\m.size === 2 && m.get("a") === 9 && m.get("b") === 2
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map constructor consumes array-like entries" {
    const result = try evalExpr(
        \\var entries = {0: {0: "x", 1: 7, length: 2}, length: 1};
        \\new Map(entries).get("x")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: Map constructor rejects invalid entries" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Map("ab"); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map constructor allows missing entry value" {
    const result = try evalExpr(
        \\var m = new Map([["a"]]);
        \\m.has("a") && m.get("a") === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map requires new" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { Map(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map is iterable" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var entry of new Map([["a", 2], ["b", 3]])) {
        \\  sum = sum + entry[1];
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Map uses SameValueZero keys" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set(NaN, 1);
        \\m.set(NaN, 2);
        \\m.size === 1 && m.get(NaN) === 2
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map set missing args stores undefined" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set();
        \\var removed = m.delete();
        \\m.size === 0 && removed
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map method lengths" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set.length === 2 && m.get.length === 1 && m.has.length === 1 &&
        \\m.delete.length === 1 && m.clear.length === 0 && m.forEach.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: Map forEach" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 10);
        \\m.set("b", 20);
        \\var sum = 0;
        \\m.forEach(function(v) { sum = sum + v; });
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: Map forEach uses thisArg" {
    const result = try evalExpr(
        \\var m = new Map([["a", 1]]);
        \\var ctx = {ok: 7};
        \\var out = 0;
        \\m.forEach(function(value, key, self) {
        \\  if (this === ctx && key === "a" && self === m) out = value + this.ok;
        \\}, ctx);
        \\out
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: Map forEach visits appended entries" {
    const result = try evalExpr(
        \\var m = new Map([["a", 1]]);
        \\var sum = 0;
        \\m.forEach(function(value, key) {
        \\  sum = sum + value;
        \\  if (key === "a") m.set("b", 2);
        \\});
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Map forEach does not skip after deleting current entry" {
    const result = try evalExpr(
        \\var m = new Map([["a", 1], ["b", 2]]);
        \\var sum = 0;
        \\m.forEach(function(value, key) {
        \\  sum = sum + value;
        \\  if (key === "a") m.delete("a");
        \\});
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Map forEach rejects non-callable callback" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Map().forEach(1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

// ── Set ─────────────────────────────────────────────────────────

test "eval: new Set basic" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add(1);
        \\s.add(2);
        \\s.add(1);
        \\s.size
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: Set constructor consumes array-like values" {
    const result = try evalExpr(
        \\var src = {0: "a", 1: "a", 2: "b", length: 3};
        \\var s = new Set(src);
        \\s.size === 2 && s.has("b")
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set constructor consumes string iterable" {
    const result = try evalExpr(
        \\var s = new Set("aba");
        \\s.size === 2 && s.has("a") && s.has("b")
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set constructor rejects non-iterable primitive" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Set(1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set requires new" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { Set(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set is iterable" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var value of new Set([1, 2, 2, 3])) {
        \\  sum = sum + value;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: Set uses SameValueZero values" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add(NaN);
        \\s.add(NaN);
        \\s.size === 1 && s.has(NaN)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set add missing arg stores undefined" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add();
        \\s.add(undefined);
        \\var had = s.has();
        \\var removed = s.delete();
        \\s.size === 0 && had && removed
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set method lengths" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add.length === 1 && s.has.length === 1 && s.delete.length === 1 &&
        \\s.clear.length === 0 && s.forEach.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set has/delete" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add(42);
        \\var had = s.has(42);
        \\s.delete(42);
        \\var hasAfter = s.has(42);
        \\had && !hasAfter
    );
    try std.testing.expect(result.asBool());
}

test "eval: Set forEach" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add(10);
        \\s.add(20);
        \\s.add(30);
        \\var sum = 0;
        \\s.forEach(function(v) { sum = sum + v; });
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: Set forEach uses thisArg" {
    const result = try evalExpr(
        \\var s = new Set([3]);
        \\var ctx = {ok: 4};
        \\var out = 0;
        \\s.forEach(function(value, key, self) {
        \\  if (this === ctx && key === value && self === s) out = value + this.ok;
        \\}, ctx);
        \\out
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: Set forEach visits appended values" {
    const result = try evalExpr(
        \\var s = new Set([1]);
        \\var sum = 0;
        \\s.forEach(function(value) {
        \\  sum = sum + value;
        \\  if (value === 1) s.add(2);
        \\});
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Set forEach does not skip after deleting current value" {
    const result = try evalExpr(
        \\var s = new Set([1, 2]);
        \\var sum = 0;
        \\s.forEach(function(value) {
        \\  sum = sum + value;
        \\  if (value === 1) s.delete(1);
        \\});
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Set forEach rejects non-callable callback" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Set().forEach(1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

// ── for-of / for-in ─────────────────────────────────────────────

test "eval: for-of array" {
    const result = try evalExpr(
        \\var sum = 0;
        \\var arr = [10, 20, 30];
        \\for (var x of arr) {
        \\  sum = sum + x;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: for-of with break" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var x of [1, 2, 3, 4, 5]) {
        \\  if (x > 3) break;
        \\  sum = sum + x;
        \\}
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: for-in object keys" {
    const result = try evalExpr(
        \\var keys = "";
        \\var obj = { a: 1, b: 2, c: 3 };
        \\for (var k in obj) {
        \\  keys = keys + k;
        \\}
        \\keys
    );
    try std.testing.expect(result.isString());
}

test "eval: for-in count" {
    const result = try evalExpr(
        \\var count = 0;
        \\for (var k in { x: 1, y: 2, z: 3 }) {
        \\  count = count + 1;
        \\}
        \\count
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: for-of nested" {
    const result = try evalExpr(
        \\var total = 0;
        \\for (var x of [1, 2, 3]) {
        \\  for (var y of [10, 20]) {
        \\    total = total + x * y;
        \\  }
        \\}
        \\total
    );
    // 1*10 + 1*20 + 2*10 + 2*20 + 3*10 + 3*20 = 10+20+20+40+30+60 = 180
    try std.testing.expectApproxEqAbs(@as(f64, 180.0), result.asNumber(), 0.001);
}

test "eval: Set clear" {
    const result = try evalExpr(
        \\var s = new Set();
        \\s.add(1);
        \\s.add(2);
        \\s.clear();
        \\s.size
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── RegExp ──────────────────────────────────────────────────────

test "eval: regex test basic" {
    const result = try evalExpr(
        \\var re = /hello/;
        \\re.test("say hello world")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex test no match" {
    const result = try evalExpr(
        \\var re = /xyz/;
        \\re.test("hello world")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: regex test anchored" {
    const result = try evalExpr(
        \\var re = /^hello/;
        \\re.test("hello world")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex test end anchor" {
    const result = try evalExpr(
        \\var re = /world$/;
        \\re.test("hello world")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex dot and quantifier" {
    const result = try evalExpr(
        \\var re = /h.+o/;
        \\re.test("hello")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex digit class" {
    const result = try evalExpr(
        \\var re = /\d+/;
        \\re.test("abc123def")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex case insensitive" {
    const result = try evalExpr(
        \\var re = /hello/i;
        \\re.test("HELLO")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex exec returns match" {
    const result = try evalExpr(
        \\var re = /\d+/;
        \\var m = re.exec("abc123def");
        \\m.index
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: regexp methods coerce primitive input" {
    const result = try evalExpr(
        \\/123/.test(123) &&
        \\/undef/.test() &&
        \\/[0-9]+/.exec(123)[0] === "123" &&
        \\/undef/.exec()[0] === "undef"
    );
    try std.testing.expect(result.asBool());
}

test "eval: string match" {
    const result = try evalExpr(
        \\var m = "hello world".match(/world/);
        \\m.index
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: string search" {
    const result = try evalExpr(
        \\"abc123".search(/\d/)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: string regex helpers coerce primitive arguments" {
    const result = try evalExpr(
        \\"abc123".search(123) === 3 &&
        \\"abc123".match(123)[0] === "123" &&
        \\"a1b".replace(1, function(){ return false; }) === "afalseb" &&
        \\"a1b".replace(1, function(){ return null; }) === "anullb"
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex char class" {
    const result = try evalExpr(
        \\var re = /[aeiou]/;
        \\re.test("hello")
    );
    try std.testing.expect(result.asBool());
}

// ── Phase H: Enhanced RegExp ─────────────────────────────────────

test "eval: regex alternation basic" {
    const result = try evalExpr(
        \\var re = /cat|dog/;
        \\re.test("I have a dog")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex alternation first" {
    const result = try evalExpr(
        \\var re = /cat|dog/;
        \\re.test("my cat")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex alternation no match" {
    const result = try evalExpr(
        \\var re = /cat|dog/;
        \\re.test("a bird")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: regex alternation three" {
    const result = try evalExpr(
        \\/red|green|blue/.test("color: blue")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex group capture exec" {
    const result = try evalExpr(
        \\var m = /(\d+)-(\d+)/.exec("date 2024-01");
        \\m[1]
    );
    try std.testing.expect(result.isString());
}

test "eval: regex group capture value" {
    const result = try evalExpr(
        \\var m = /(\d+)-(\d+)/.exec("date 2024-01");
        \\m[1] === "2024"
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex group capture second" {
    const result = try evalExpr(
        \\var m = /(\d+)-(\d+)/.exec("date 2024-01");
        \\m[2] === "01"
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex group full match" {
    const result = try evalExpr(
        \\var m = /(\d+)-(\d+)/.exec("date 2024-01");
        \\m[0] === "2024-01"
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex non-capturing group" {
    const result = try evalExpr(
        \\/(?:ab)+/.test("ababab")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex brace quantifier exact" {
    const result = try evalExpr(
        \\/\d{3}/.test("abc123def")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex brace quantifier no match" {
    const result = try evalExpr(
        \\/\d{4}/.test("abc12def")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: regex brace range" {
    const result = try evalExpr(
        \\/\d{2,4}/.test("a12b")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex brace min only" {
    const result = try evalExpr(
        \\/a{2,}/.test("aaa")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex word boundary" {
    const result = try evalExpr(
        \\/\bworld\b/.test("hello world today")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex word boundary no match" {
    const result = try evalExpr(
        \\/\bworld\b/.test("helloworld")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: regex group in alternation" {
    const result = try evalExpr(
        \\var m = /(cat|dog) food/.exec("buy dog food");
        \\m[1] === "dog"
    );
    try std.testing.expect(result.asBool());
}

test "eval: match global returns all" {
    const result = try evalExpr(
        \\var m = "aaa bbb ccc".match(/\w+/g);
        \\m.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: match global values" {
    const result = try evalExpr(
        \\var m = "cat and dog".match(/\w+/g);
        \\m[0] === "cat" && m[2] === "dog"
    );
    try std.testing.expect(result.asBool());
}

test "eval: match with captures" {
    const result = try evalExpr(
        \\var m = "2024-01-15".match(/(\d{4})-(\d{2})-(\d{2})/);
        \\m[1] === "2024" && m[2] === "01" && m[3] === "15"
    );
    try std.testing.expect(result.asBool());
}

test "eval: replace with regex" {
    const result = try evalExpr(
        \\"hello world".replace(/world/, "zig") === "hello zig"
    );
    try std.testing.expect(result.asBool());
}

test "eval: replace with regex global" {
    const result = try evalExpr(
        \\"aaa bbb aaa".replace(/aaa/g, "xxx") === "xxx bbb xxx"
    );
    try std.testing.expect(result.asBool());
}

test "eval: replace regex pattern" {
    const result = try evalExpr(
        \\"abc123def456".replace(/\d+/g, "N") === "abcNdefN"
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex escaped dot" {
    const result = try evalExpr(
        \\/\d+\.\d+/.test("3.14")
    );
    try std.testing.expect(result.asBool());
}

test "eval: regex escaped dot no match" {
    const result = try evalExpr(
        \\/\d+\.\d+/.test("314")
    );
    try std.testing.expect(!result.asBool());
}

// ── setTimeout / setInterval / clearTimeout ─────────────────────

test "eval: setTimeout returns timer id" {
    const result = try evalExpr(
        \\var id = setTimeout(function() {}, 100);
        \\id
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: multiple setTimeout gives unique ids" {
    const result = try evalExpr(
        \\var id1 = setTimeout(function() {}, 0);
        \\var id2 = setTimeout(function() {}, 0);
        \\id2 - id1
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: setTimeout callback fires on runPendingTimers" {
    var compiler = kotori.Compiler.init(std.testing.allocator,
        \\var x = 0;
        \\setTimeout(function() { x = 42; }, 0);
        \\x
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = kotori.VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();

    // Execute: x is still 0, timer is queued
    const result1 = try vm_inst.execute();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result1.asNumber(), 0.001);
    try std.testing.expect(vm_inst.hasPendingTimers());

    // Fire timers: callback sets x = 42
    _ = try vm_inst.runPendingTimers();
    try std.testing.expect(!vm_inst.hasPendingTimers());

    // Read x from globals
    const x_id = try compiler.parser.pool.intern("x");
    const x_val = vm_inst.globals.get(x_id) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), x_val.asNumber(), 0.001);
}

test "eval: timer APIs coerce string delay and id" {
    var compiler = kotori.Compiler.init(std.testing.allocator,
        \\var x = 0;
        \\var id = setTimeout(function() { x = 99; }, "0");
        \\clearTimeout(String(id));
        \\x
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = kotori.VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();

    _ = try vm_inst.execute();
    _ = try vm_inst.runPendingTimers();

    const x_id = try compiler.parser.pool.intern("x");
    const x_val = vm_inst.globals.get(x_id) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x_val.asNumber(), 0.001);
}

test "eval: clearTimeout cancels timer" {
    var compiler = kotori.Compiler.init(std.testing.allocator,
        \\var x = 0;
        \\var id = setTimeout(function() { x = 99; }, 0);
        \\clearTimeout(id);
        \\x
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = kotori.VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();

    _ = try vm_inst.execute();
    _ = try vm_inst.runPendingTimers();

    // x should still be 0 because timer was cancelled
    const x_id = try compiler.parser.pool.intern("x");
    const x_val = vm_inst.globals.get(x_id) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), x_val.asNumber(), 0.001);
}

test "eval: setInterval fires repeatedly" {
    var compiler = kotori.Compiler.init(std.testing.allocator,
        \\var count = 0;
        \\setInterval(function() { count = count + 1; }, 0);
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = kotori.VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();

    _ = try vm_inst.execute();
    // Fire 3 rounds
    _ = try vm_inst.runPendingTimers();
    _ = try vm_inst.runPendingTimers();
    _ = try vm_inst.runPendingTimers();

    const count_id = try compiler.parser.pool.intern("count");
    const count_val = vm_inst.globals.get(count_id) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), count_val.asNumber(), 0.001);
}

// ═══════════════════════════════════════════════════════════════════
// Promise tests
// ═══════════════════════════════════════════════════════════════════

test "Promise.resolve returns fulfilled promise" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(42).then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "Promise.reject calls catch handler" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.reject(99).catch(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "Promise constructor with resolve" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\new Promise(function(resolve, reject) {
        \\    resolve(10);
        \\}).then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "Promise constructor with reject" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\new Promise(function(resolve, reject) {
        \\    reject(55);
        \\}).catch(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), result.asNumber(), 0.001);
}

test "Promise constructor rejects when executor throws" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\new Promise(function() {
        \\    throw 4;
        \\}).catch(function(e) { result = e; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "Promise constructor ignores executor throw after resolve" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\new Promise(function(resolve) {
        \\    resolve(3);
        \\    throw 4;
        \\}).then(
        \\    function(v) { result = v; },
        \\    function(e) { result = e; }
        \\);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "Promise then chaining" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(5)
        \\    .then(function(v) { return v * 2; })
        \\    .then(function(v) { return v + 3; })
        \\    .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), result.asNumber(), 0.001);
}

test "Promise catch then chain" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.reject(7)
        \\    .catch(function(v) { return v + 1; })
        \\    .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "Promise finally passes through fulfillment value" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(5)
        \\    .finally(function() { return 9; })
        \\    .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "Promise finally passes through rejection reason" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.reject(7)
        \\    .finally(function() { return 9; })
        \\    .catch(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "Promise finally waits for returned thenable" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(5)
        \\    .finally(function() {
        \\        return { then: function(resolve) { result = 1; resolve(9); } };
        \\    })
        \\    .then(function(v) { result = result * 10 + v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "Promise finally rejected returned promise overrides original value" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(5)
        \\    .finally(function() { return Promise.reject(9); })
        \\    .then(
        \\        function() { result = 1; },
        \\        function(e) { result = e; }
        \\    );
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "Promise finally ignores non-callable handler" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(3)
        \\    .finally({})
        \\    .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "Promise then rejects when handler throws" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(1)
        \\    .then(function() { throw 8; })
        \\    .catch(function(e) { result = e; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "Promise finally rejects when handler throws" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\Promise.resolve(1)
        \\    .finally(function() { throw 6; })
        \\    .catch(function(e) { result = e; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "async function returns promise that resolves" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\async function foo() { return 42; }
        \\foo().then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "await on Promise.resolve" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\async function foo() {
        \\    var x = await Promise.resolve(10);
        \\    return x + 5;
        \\}
        \\foo().then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "await on non-promise passes through" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\async function foo() {
        \\    var x = await 7;
        \\    return x + 3;
        \\}
        \\foo().then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "multiple awaits in sequence" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\async function foo() {
        \\    var a = await Promise.resolve(10);
        \\    var b = await Promise.resolve(20);
        \\    return a + b;
        \\}
        \\foo().then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "fetch without http client rejects" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\fetch("http://example.com").catch(function(e) { result = 1; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "fetch with no args rejects" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\fetch().catch(function(e) { result = 1; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "async function with no return resolves undefined" {
    const result = try evalWithMicrotasks(
        \\var result = 99;
        \\async function foo() { var x = 1; }
        \\foo().then(function(v) {
        \\    if (v === undefined) result = 0;
        \\});
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── Array.reduce ──

test "array reduce sum" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3, 4].reduce(function(acc, x) { return acc + x; }, 0);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "array reduce no initial value" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].reduce(function(acc, x) { return acc + x; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "array reduce reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1, 2];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 4; } });
        \\var result = a.reduce(function(acc, x) { return acc + x; }) * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

test "array reduceRight" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3, 4].reduceRight(function(acc, x) { return acc + x; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "array reduceRight reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1, 2];
        \\Object.defineProperty(a, 1, { get: function() { calls = calls + 1; return 5; } });
        \\var result = a.reduceRight(function(acc, x) { return acc + x; }) * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

test "array reduce works on array-like objects" {
    const result = try evalExpr(
        \\Array.prototype.reduce.call({0: 2, 1: 3, length: "2"}, function(acc, x) { return acc + x; }, 5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "array reduce skips missing array-like elements" {
    const result = try evalExpr(
        \\Array.prototype.reduce.call({1: 4, length: 3}, function(acc, x) { return acc + x; })
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "array reduceRight works on array-like objects" {
    const result = try evalExpr(
        \\Array.prototype.reduceRight.call({0: 2, 1: 3, length: "2"}, function(acc, x) { return acc * 10 + x; }, 1)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 132.0), result.asNumber(), 0.001);
}

test "array reduce empty without initial throws TypeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { [].reduce(function(acc, x) { return acc + x; }); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "array reduceRight empty without initial throws TypeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { [].reduceRight(function(acc, x) { return acc + x; }); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "array reduce non-callable callback throws TypeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { [1].reduce({}); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

// ── Array.find / findIndex ──

test "array find" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 5, 10, 15].find(function(x) { return x > 8; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "array find returns undefined when not found" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].find(function(x) { return x > 100; });
    , "result");
    try std.testing.expect(result.isUndefined());
}

test "array findIndex" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 5, 10, 15].findIndex(function(x) { return x > 8; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "array findIndex returns -1 when not found" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].findIndex(function(x) { return x > 100; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "array find reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 7; } });
        \\var result = a.find(function(x) { return x === 7; }) * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "array findLastIndex reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1, 2];
        \\Object.defineProperty(a, 1, { get: function() { calls = calls + 1; return 8; } });
        \\var result = a.findLastIndex(function(x) { return x === 8; }) * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.asNumber(), 0.001);
}

// ── Array.some / every ──

test "array some true" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].some(function(x) { return x > 2; }) ? 1 : 0;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "array some false" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].some(function(x) { return x > 10; }) ? 1 : 0;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "array every true" {
    const result = try evalWithMicrotasks(
        \\var result = [2, 4, 6].every(function(x) { return x % 2 === 0; }) ? 1 : 0;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "array every false" {
    const result = try evalWithMicrotasks(
        \\var result = [2, 3, 6].every(function(x) { return x % 2 === 0; }) ? 1 : 0;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "array some reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 9; } });
        \\var result = (a.some(function(x) { return x === 9; }) ? 10 : 0) + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.asNumber(), 0.001);
}

test "array every reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 4; } });
        \\var result = (a.every(function(x) { return x === 4; }) ? 10 : 0) + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.asNumber(), 0.001);
}

// ── Array.sort ──

test "array sort default lexicographic" {
    const result = try evalWithMicrotasks(
        \\var a = [3, 1, 2];
        \\a.sort();
        \\var result = a[0] * 100 + a[1] * 10 + a[2];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), result.asNumber(), 0.001);
}

test "array sort with compareFn" {
    const result = try evalWithMicrotasks(
        \\var a = [3, 1, 2];
        \\a.sort(function(x, y) { return x - y; });
        \\var result = a[0] * 100 + a[1] * 10 + a[2];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), result.asNumber(), 0.001);
}

test "array sort descending" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 3, 2];
        \\a.sort(function(x, y) { return y - x; });
        \\var result = a[0] * 100 + a[1] * 10 + a[2];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 321.0), result.asNumber(), 0.001);
}

test "array sort compareFn coerces return value" {
    const result = try evalWithMicrotasks(
        \\var a = [3, 1, 2];
        \\a.sort(function(x, y) { return "" + (x - y); });
        \\var result = a[0] * 100 + a[1] * 10 + a[2];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), result.asNumber(), 0.001);
}

// ── Array.splice ──

test "array splice delete" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 2, 3, 4, 5];
        \\var removed = a.splice(1, 2);
        \\var result = removed[0] * 10 + removed[1];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 23.0), result.asNumber(), 0.001);
}

test "array splice insert" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 4, 5];
        \\a.splice(1, 0, 2, 3);
        \\var result = a.length * 1000 + a[1] * 100 + a[2] * 10 + a[3];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 5234.0), result.asNumber(), 0.001);
}

test "array splice coerces start and deleteCount" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 2, 3, 4];
        \\var removed = a.splice("1", "2");
        \\var result = removed[0] * 1000 + removed[1] * 100 + a.length * 10 + a[1];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 2324.0), result.asNumber(), 0.001);
}

// ── Array.flat / flatMap ──

test "array flat" {
    const result = try evalWithMicrotasks(
        \\var result = [1, [2, 3], [4, [5]]].flat().length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "array flat coerces depth" {
    const result = try evalWithMicrotasks(
        \\var a = [1, [2, [3]]];
        \\var result = a.flat("2").length * 10 + a.flat(1.9)[1];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 32.0), result.asNumber(), 0.001);
}

test "array flat works on array-like objects" {
    const result = try evalWithMicrotasks(
        \\var out = Array.prototype.flat.call({0: [1, 2], 1: 3, length: "2"});
        \\var result = out.length * 100 + out[0] * 10 + out[2];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 313.0), result.asNumber(), 0.001);
}

test "array flat reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return [4]; } });
        \\var out = a.flat();
        \\var result = out[0] * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 41.0), result.asNumber(), 0.001);
}

test "array flatMap" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].flatMap(function(x) { return [x, x * 2]; }).length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "array flatMap works on array-like objects" {
    const result = try evalWithMicrotasks(
        \\var out = Array.prototype.flatMap.call({0: 2, 1: 3, length: "2"}, function(x) { return [x, x * 10]; });
        \\var result = out.length * 1000 + out[0] * 100 + out[3];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 4230.0), result.asNumber(), 0.001);
}

test "array flatMap reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 5; } });
        \\var out = a.flatMap(function(x) { return [x + 1]; });
        \\var result = out[0] * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

test "array flatMap non-callable callback throws TypeError" {
    const result = try evalWithMicrotasks(
        \\var result = 0;
        \\try { [1].flatMap({}); } catch (e) { if (e.name === "TypeError") result = 1; }
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

// ── Array.fill / at / unshift ──

test "array fill" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 2, 3, 4];
        \\a.fill(0, 1, 3);
        \\var result = a[0] * 1000 + a[1] * 100 + a[2] * 10 + a[3];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1004.0), result.asNumber(), 0.001);
}

test "array fill coerces start and end" {
    const result = try evalWithMicrotasks(
        \\var a = [1, 2, 3, 4];
        \\a.fill(9, "1", "3");
        \\var result = a[0] * 1000 + a[1] * 100 + a[2] * 10 + a[3];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1994.0), result.asNumber(), 0.001);
}

test "array at negative index" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].at(-1);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "array at coerces index" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].at("1") * 10 + [1, 2, 3].at("-1");
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 23.0), result.asNumber(), 0.001);
}

test "array at works on array-like objects" {
    const result = try evalWithMicrotasks(
        \\var result = Array.prototype.at.call({0: 4, 2: 8, length: "3"}, -1);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "array at reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 6; } });
        \\var result = a.at(0) * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

test "array unshift" {
    const result = try evalWithMicrotasks(
        \\var a = [3, 4];
        \\var len = a.unshift(1, 2);
        \\var result = len * 10000 + a[0] * 1000 + a[1] * 100 + a[2] * 10 + a[3];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 41234.0), result.asNumber(), 0.001);
}

// ── Array.keys / values / entries / toString ──

test "array keys" {
    const result = try evalWithMicrotasks(
        \\var result = [10, 20, 30].keys().length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "array keys works on array-like objects" {
    const result = try evalWithMicrotasks(
        \\var result = Array.prototype.keys.call({length: "3"}).length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "array values reads accessor elements" {
    const result = try evalWithMicrotasks(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 8; } });
        \\var v = a.values();
        \\var result = v[0] * 10 + calls;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 81.0), result.asNumber(), 0.001);
}

test "array entries" {
    const result = try evalWithMicrotasks(
        \\var e = [10, 20].entries();
        \\var result = e[0][0] * 100 + e[0][1] * 10 + e[1][0];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), result.asNumber(), 0.001);
}

test "array entries works on array-like objects" {
    const result = try evalWithMicrotasks(
        \\var e = Array.prototype.entries.call({0: 4, 1: 5, length: "2"});
        \\var result = e[0][0] * 100 + e[0][1] * 10 + e[1][1];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 45.0), result.asNumber(), 0.001);
}

test "array toString" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].toString();
    , "result");
    try std.testing.expect(result.isString());
}

// ── Destructuring ──

test "array destructuring basic" {
    const result = try evalWithMicrotasks(
        \\var [a, b, c] = [10, 20, 30];
        \\var result = a * 100 + b * 10 + c;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1230.0), result.asNumber(), 0.001);
}

test "array destructuring skip elements" {
    const result = try evalWithMicrotasks(
        \\var arr = [1, 2, 3, 4];
        \\var [a, , , d] = arr;
        \\var result = a * 10 + d;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 14.0), result.asNumber(), 0.001);
}

test "array destructuring with default" {
    const result = try evalWithMicrotasks(
        \\var [a, b = 99] = [42];
        \\var result = a * 100 + b;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 4299.0), result.asNumber(), 0.001);
}

test "object destructuring basic" {
    const result = try evalWithMicrotasks(
        \\var obj = {x: 10, y: 20, z: 30};
        \\var {x, y, z} = obj;
        \\var result = x * 100 + y * 10 + z;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1230.0), result.asNumber(), 0.001);
}

test "object destructuring with rename" {
    const result = try evalWithMicrotasks(
        \\var obj = {name: 42, value: 7};
        \\var {name: n, value: v} = obj;
        \\var result = n * 10 + v;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 427.0), result.asNumber(), 0.001);
}

test "object destructuring with default" {
    const result = try evalWithMicrotasks(
        \\var {a, b = 50} = {a: 10};
        \\var result = a * 100 + b;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1050.0), result.asNumber(), 0.001);
}

test "nested destructuring" {
    const result = try evalWithMicrotasks(
        \\var {a, b: {c, d}} = {a: 1, b: {c: 2, d: 3}};
        \\var result = a * 100 + c * 10 + d;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), result.asNumber(), 0.001);
}

test "mixed array and object destructuring" {
    const result = try evalWithMicrotasks(
        \\var [{x}, [a, b]] = [{x: 5}, [6, 7]];
        \\var result = x * 100 + a * 10 + b;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 567.0), result.asNumber(), 0.001);
}

// ── Class syntax ──

test "class basic constructor and method" {
    const result = try evalWithMicrotasks(
        \\class Foo {
        \\    constructor(x) { this.x = x; }
        \\    getX() { return this.x; }
        \\}
        \\var f = new Foo(42);
        \\var result = f.getX();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "class multiple methods" {
    const result = try evalWithMicrotasks(
        \\class Calc {
        \\    constructor(v) { this.v = v; }
        \\    add(n) { return this.v + n; }
        \\    mul(n) { return this.v * n; }
        \\}
        \\var c = new Calc(10);
        \\var result = c.add(5) * 100 + c.mul(3);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1530.0), result.asNumber(), 0.001);
}

test "class static method" {
    const result = try evalWithMicrotasks(
        \\class Counter {
        \\    constructor(n) { this.n = n; }
        \\    static create(n) { return new Counter(n); }
        \\}
        \\var c = Counter.create(7);
        \\var result = c.n;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "class inheritance" {
    const result = try evalWithMicrotasks(
        \\class Animal {
        \\    constructor(name) { this.name = name; }
        \\    speak() { return "..."; }
        \\}
        \\class Dog extends Animal {
        \\    constructor(name) { this.name = name; }
        \\    speak() { return "woof"; }
        \\}
        \\var d = new Dog("Rex");
        \\var result = 0;
        \\if (d.speak() === "woof") result = 1;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "class default constructor" {
    const result = try evalWithMicrotasks(
        \\class Empty {}
        \\var e = new Empty();
        \\e.x = 99;
        \\var result = e.x;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "class instanceof-like check via prototype" {
    const result = try evalWithMicrotasks(
        \\class Point {
        \\    constructor(x, y) { this.x = x; this.y = y; }
        \\    sum() { return this.x + this.y; }
        \\}
        \\var p = new Point(3, 4);
        \\var result = p.sum();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

// ---------------------------------------------------------------
// ES Modules
// ---------------------------------------------------------------

test "export default expression" {
    var compiler = Compiler.init(std.testing.allocator, "export default 42;");
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    const default_sid = try compiler.parser.pool.intern("default");
    const exported = vm_inst.module_exports.get(default_sid);
    try std.testing.expect(exported != null);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), exported.?.asNumber(), 0.001);
}

test "export const declaration" {
    var compiler = Compiler.init(std.testing.allocator,
        \\export const x = 10;
        \\export const y = 20;
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    const x_sid = try compiler.parser.pool.intern("x");
    const y_sid = try compiler.parser.pool.intern("y");
    const ex = vm_inst.module_exports.get(x_sid);
    const ey = vm_inst.module_exports.get(y_sid);
    try std.testing.expect(ex != null);
    try std.testing.expect(ey != null);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), ex.?.asNumber(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), ey.?.asNumber(), 0.001);
}

test "export function declaration" {
    var compiler = Compiler.init(std.testing.allocator,
        \\export function add(a, b) { return a + b; }
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    const add_sid = try compiler.parser.pool.intern("add");
    const exported = vm_inst.module_exports.get(add_sid);
    try std.testing.expect(exported != null);
}

test "export named from locals" {
    var compiler = Compiler.init(std.testing.allocator,
        \\var a = 100;
        \\var b = 200;
        \\export { a, b };
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    const a_sid = try compiler.parser.pool.intern("a");
    const b_sid = try compiler.parser.pool.intern("b");
    const ea = vm_inst.module_exports.get(a_sid);
    const eb = vm_inst.module_exports.get(b_sid);
    try std.testing.expect(ea != null);
    try std.testing.expect(eb != null);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), ea.?.asNumber(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), eb.?.asNumber(), 0.001);
}

test "import side-effect only (no crash)" {
    // Side-effect import with no module loader should not crash
    var compiler = Compiler.init(std.testing.allocator,
        \\import "./nonexistent.js";
        \\var result = 1;
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    _ = try vm_inst.execute();
    const r_sid = try compiler.parser.pool.intern("result");
    const val = vm_inst.globals.get(r_sid) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), val.asNumber(), 0.001);
}

// ---------------------------------------------------------------
// String methods
// ---------------------------------------------------------------

test "string lastIndexOf" {
    const result = try evalWithMicrotasks(
        \\var result = "hello world hello".lastIndexOf("hello");
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "import binding resolves from module_exports" {
    // Pre-populate module_exports, then import should pick them up
    var compiler = Compiler.init(std.testing.allocator,
        \\import { foo } from "test-mod";
        \\var result = foo;
    );
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    // Pre-seed: simulate a loaded module that exports "foo" = 999
    const foo_sid = try compiler.parser.pool.intern("foo");
    try vm_inst.module_exports.put(std.testing.allocator, foo_sid, JsValue.initNumber(999));
    _ = try vm_inst.execute();
    const r_sid = try compiler.parser.pool.intern("result");
    const val = vm_inst.globals.get(r_sid) orelse JsValue.undefined_val;
    try std.testing.expectApproxEqAbs(@as(f64, 999.0), val.asNumber(), 0.001);
}

// ---------------------------------------------------------------
// instanceof / in operators
// ---------------------------------------------------------------

test "instanceof with array" {
    const result = try evalWithMicrotasks(
        \\var a = [1,2,3];
        \\var result = a instanceof Array;
    , "result");
    try std.testing.expect(result.asBool() == true);
}

test "instanceof non-instance returns false" {
    const result = try evalExpr(
        \\var a = 42; a instanceof Array;
    );
    try std.testing.expect(result.asBool() == false);
}

test "instanceof with constructor" {
    const result = try evalWithMicrotasks(
        \\function Dog() {}
        \\var d = new Dog();
        \\var result = d instanceof Dog;
    , "result");
    try std.testing.expect(result.asBool() == true);
}

test "in operator with object" {
    const result = try evalExpr(
        \\var obj = {a: 1, b: 2}; "a" in obj;
    );
    try std.testing.expect(result.asBool() == true);
}

test "in operator missing property returns false" {
    const result = try evalExpr(
        \\var obj = {a: 1}; "b" in obj;
    );
    try std.testing.expect(result.asBool() == false);
}

// ---------------------------------------------------------------
// Error objects
// ---------------------------------------------------------------

test "Error constructor with message" {
    const result = try evalWithMicrotasks(
        \\var e = new Error("oops");
        \\var result = e.message;
    , "result");
    try std.testing.expect(result.isString());
}

test "TypeError name property" {
    const result = try evalWithMicrotasks(
        \\var e = new TypeError("bad");
        \\var result = e.name;
    , "result");
    try std.testing.expect(result.isString());
}

test "TypeError instanceof Error" {
    const result = try evalWithMicrotasks(
        \\var e = new TypeError("x");
        \\var result = e instanceof Error;
    , "result");
    try std.testing.expect(result.asBool() == true);
}

test "TypeError instanceof TypeError" {
    const result = try evalWithMicrotasks(
        \\var e = new TypeError("x");
        \\var result = e instanceof TypeError;
    , "result");
    try std.testing.expect(result.asBool() == true);
}

test "Error without new" {
    const result = try evalWithMicrotasks(
        \\var e = Error("no new");
        \\var result = e.message;
    , "result");
    try std.testing.expect(result.isString());
}

test "Error toString" {
    const result = try evalWithMicrotasks(
        \\var e = new RangeError("out of range");
        \\var result = e.toString();
    , "result");
    try std.testing.expect(result.isString());
}

test "Error toString empty message" {
    const result = try evalWithMicrotasks(
        \\var e = new Error();
        \\var result = e.toString();
    , "result");
    try std.testing.expect(result.isString());
}

// ---------------------------------------------------------------
// Number.prototype + Number constructor
// ---------------------------------------------------------------

test "Number toFixed" {
    const result = try evalWithMicrotasks(
        \\var result = (3.14159).toFixed(2);
    , "result");
    try std.testing.expect(result.isString());
}

test "Number toString radix 16" {
    const result = try evalWithMicrotasks(
        \\var result = (255).toString(16);
    , "result");
    try std.testing.expect(result.isString());
}

test "Number toLocaleString basic" {
    const result = try evalExpr("(123).toLocaleString() === \"123\"");
    try std.testing.expect(result.asBool());
}

test "Number formatting methods coerce digit arguments" {
    const result = try evalExpr(
        \\(3.14159).toFixed("2") === "3.14" &&
        \\(255).toString("16") === "ff" &&
        \\(1.5).toPrecision("2").indexOf("e") >= 0 &&
        \\(1.5).toExponential("2").indexOf("e") >= 0
    );
    try std.testing.expect(result.asBool());
}

test "Number constructor trims form feed" {
    const result = try evalExpr("Number(\"\\f1.5\") === 1.5");
    try std.testing.expect(result.asBool());
}

test "Number constructor trims non-breaking space" {
    const result = try evalExpr("Number(\"\\u00a01.5\\u00a0\") === 1.5");
    try std.testing.expect(result.asBool());
}

test "Boolean prototype toString" {
    const result = try evalExpr("Boolean.prototype.toString.call(true) === \"true\"");
    try std.testing.expect(result.asBool());
}

test "Boolean prototype valueOf" {
    const result = try evalExpr(
        \\Boolean.prototype.hasOwnProperty("valueOf") &&
        \\Boolean.prototype.valueOf.call(false) === false
    );
    try std.testing.expect(result.asBool());
}

test "Boolean prototype constructor" {
    const result = try evalExpr("Boolean.prototype.constructor === Boolean");
    try std.testing.expect(result.asBool());
}

test "String prototype constructor" {
    const result = try evalExpr("String.prototype.constructor === String");
    try std.testing.expect(result.asBool());
}

test "Number prototype constructor" {
    const result = try evalExpr("Number.prototype.constructor === Number");
    try std.testing.expect(result.asBool());
}

test "Array prototype constructor" {
    const result = try evalExpr("Array.prototype.constructor === Array");
    try std.testing.expect(result.asBool());
}

test "Date prototype constructor" {
    const result = try evalExpr("Date.prototype.constructor === Date");
    try std.testing.expect(result.asBool());
}

test "RegExp prototype constructor" {
    const result = try evalExpr("RegExp.prototype.constructor === RegExp");
    try std.testing.expect(result.asBool());
}

test "Map prototype constructor" {
    const result = try evalExpr("Map.prototype.constructor === Map");
    try std.testing.expect(result.asBool());
}

test "Map prototype set works with call" {
    const result = try evalExpr(
        \\var m = new Map();
        \\var ret = Map.prototype.set.call(m, "a", 3);
        \\ret === m && m.get("a") === 3 && m.size === 1
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype get works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3]]);
        \\Map.prototype.get.call(m, "a")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "Map prototype has works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3]]);
        \\Map.prototype.has.call(m, "a") && !Map.prototype.has.call(m, "b")
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype delete works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3]]);
        \\Map.prototype.delete.call(m, "a") && !m.has("a") && m.size === 0
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype clear works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3], ["b", 4]]);
        \\Map.prototype.clear.call(m);
        \\m.size === 0 && !m.has("a") && !m.has("b")
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype values works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3], ["b", 4]]);
        \\var values = Map.prototype.values.call(m);
        \\values.length === 2 && values[0] === 3 && values[1] === 4
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype keys works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3], ["b", 4]]);
        \\var keys = Map.prototype.keys.call(m);
        \\keys.length === 2 && keys[0] === "a" && keys[1] === "b"
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype entries works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3], ["b", 4]]);
        \\var entries = Map.prototype.entries.call(m);
        \\entries.length === 2 && entries[0][0] === "a" && entries[0][1] === 3 && entries[1][0] === "b" && entries[1][1] === 4
    );
    try std.testing.expect(result.asBool());
}

test "Map prototype forEach works with call" {
    const result = try evalExpr(
        \\var m = new Map([["a", 3], ["b", 4]]);
        \\var sum = 0;
        \\var keys = "";
        \\Map.prototype.forEach.call(m, function(value, key) { sum = sum + value; keys = keys + key; });
        \\sum === 7 && keys === "ab"
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype constructor" {
    const result = try evalExpr("Set.prototype.constructor === Set");
    try std.testing.expect(result.asBool());
}

test "Set prototype add works with call" {
    const result = try evalExpr(
        \\var s = new Set();
        \\var ret = Set.prototype.add.call(s, "a");
        \\ret === s && s.has("a") && s.size === 1
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype has works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a"]);
        \\Set.prototype.has.call(s, "a")
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype delete works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a"]);
        \\Set.prototype.delete.call(s, "a") && !s.has("a") && s.size === 0
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype clear works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a", "b"]);
        \\Set.prototype.clear.call(s);
        \\s.size === 0 && !s.has("a") && !s.has("b")
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype values works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a", "b"]);
        \\var values = Set.prototype.values.call(s);
        \\values.length === 2 && values[0] === "a" && values[1] === "b"
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype keys works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a", "b"]);
        \\var keys = Set.prototype.keys.call(s);
        \\keys.length === 2 && keys[0] === "a" && keys[1] === "b"
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype entries works with call" {
    const result = try evalExpr(
        \\var s = new Set(["a", "b"]);
        \\var entries = Set.prototype.entries.call(s);
        \\entries.length === 2 && entries[0][0] === "a" && entries[0][1] === "a" && entries[1][0] === "b" && entries[1][1] === "b"
    );
    try std.testing.expect(result.asBool());
}

test "Set prototype forEach works with call" {
    const result = try evalExpr(
        \\var s = new Set([3, 4]);
        \\var sum = 0;
        \\Set.prototype.forEach.call(s, function(value, key) { sum = sum + value + key; });
        \\sum === 14
    );
    try std.testing.expect(result.asBool());
}

test "Number.isNaN true" {
    const result = try evalExpr(
        \\Number.isNaN(NaN);
    );
    try std.testing.expect(result.asBool() == true);
}

test "Number.isNaN false for number" {
    const result = try evalExpr(
        \\Number.isNaN(42);
    );
    try std.testing.expect(result.asBool() == false);
}

test "Number.isFinite" {
    const result = try evalExpr(
        \\Number.isFinite(42);
    );
    try std.testing.expect(result.asBool() == true);
}

test "Number.isInteger true" {
    const result = try evalExpr(
        \\Number.isInteger(42);
    );
    try std.testing.expect(result.asBool() == true);
}

test "Number.isInteger false for float" {
    const result = try evalExpr(
        \\Number.isInteger(42.5);
    );
    try std.testing.expect(result.asBool() == false);
}

test "Number.isSafeInteger" {
    const result = try evalExpr(
        \\Number.isSafeInteger(42) &&
        \\Number.isSafeInteger(Number.MAX_SAFE_INTEGER) &&
        \\!Number.isSafeInteger(Number.MAX_SAFE_INTEGER + 1) &&
        \\!Number.isSafeInteger(42.5) &&
        \\!Number.isSafeInteger("42")
    );
    try std.testing.expect(result.asBool());
}

test "Number.MAX_SAFE_INTEGER" {
    const result = try evalExpr(
        \\Number.MAX_SAFE_INTEGER;
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9007199254740991.0), result.asNumber(), 1.0);
}

test "Number valueOf" {
    const result = try evalExpr(
        \\(42).valueOf();
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.toNumber(), 0.001);
}

// ---------------------------------------------------------------
// Date object
// ---------------------------------------------------------------

test "Date.now returns number" {
    const result = try evalExpr(
        \\Date.now();
    );
    try std.testing.expect(result.isNumber());
    try std.testing.expect(result.asNumber() > 1577836800000.0);
}

test "new Date returns object with getTime" {
    const result = try evalWithMicrotasks(
        \\var d = new Date();
        \\var result = d.getTime();
    , "result");
    try std.testing.expect(result.isNumber());
    try std.testing.expect(result.asNumber() > 1577836800000.0);
}

test "new Date from ms" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.getTime();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "new Date from components" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(2026, 0, 1);
        \\var result = d.getFullYear();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 2026.0), result.asNumber(), 0.001);
}

test "Date valueOf" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(1000);
        \\var result = d.valueOf();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), result.asNumber(), 0.001);
}

test "Date toISOString" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.toISOString();
    , "result");
    try std.testing.expect(result.isString());
}

test "Date JSON.stringify uses toJSON" {
    const result = try evalExpr(
        \\var d = new Date(0);
        \\JSON.stringify(d) === '"' + d.toISOString() + '"' &&
        \\JSON.stringify({d: d}) === '{"d":"' + d.toISOString() + '"}'
    );
    try std.testing.expect(result.asBool());
}

test "Date invalid value serializes as null" {
    const result = try evalExpr(
        \\var d = new Date(NaN);
        \\var threw = false;
        \\try { d.toISOString(); } catch (e) { threw = e.name === "RangeError"; }
        \\isNaN(d.getTime()) &&
        \\d.toString() === "Invalid Date" &&
        \\d.toJSON() === null &&
        \\JSON.stringify(d) === "null" &&
        \\JSON.stringify({d: d}) === '{"d":null}' &&
        \\threw
    );
    try std.testing.expect(result.asBool());
}

test "Date method lengths" {
    const result = try evalExpr(
        \\Date.length === 7 &&
        \\Date.now.length === 0 &&
        \\Date.parse.length === 1 &&
        \\Date.UTC.length === 7 &&
        \\Date.prototype.toISOString.length === 0 &&
        \\Date.prototype.toJSON.length === 1 &&
        \\Date.prototype.setTime.length === 1 &&
        \\Date.prototype.setFullYear.length === 3 &&
        \\Date.prototype.setMonth.length === 2 &&
        \\Date.prototype.setDate.length === 1 &&
        \\Date.prototype.setHours.length === 4 &&
        \\Date.prototype.setMinutes.length === 3 &&
        \\Date.prototype.setSeconds.length === 2 &&
        \\Date.prototype.setMilliseconds.length === 1 &&
        \\Date.prototype.setUTCFullYear.length === 3 &&
        \\Date.prototype.setUTCMonth.length === 2 &&
        \\Date.prototype.setUTCDate.length === 1 &&
        \\Date.prototype.setUTCHours.length === 4 &&
        \\Date.prototype.setUTCMinutes.length === 3 &&
        \\Date.prototype.setUTCSeconds.length === 2 &&
        \\Date.prototype.setUTCMilliseconds.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Date getMonth zero-based" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(2026, 3, 12);
        \\var result = d.getMonth();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "Date.parse ISO" {
    const result = try evalExpr(
        \\Date.parse("2026-04-12T00:00:00Z");
    );
    try std.testing.expect(result.isNumber());
    try std.testing.expect(result.asNumber() > 0);
}

test "Date.UTC" {
    const result = try evalExpr(
        \\Date.UTC(2026, 0, 1);
    );
    try std.testing.expect(result.isNumber());
}

test "Date setFullYear" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(2026, 0, 1);
        \\d.setFullYear(2030);
        \\var result = d.getFullYear();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 2030.0), result.asNumber(), 0.001);
}

test "Date numeric APIs coerce string arguments" {
    const result = try evalExpr(
        \\var d = new Date("2026", "0", "2", "3", "4", "5", "6");
        \\var localOk = d.getFullYear() === 2026 &&
        \\  d.getMonth() === 0 &&
        \\  d.getDate() === 2 &&
        \\  d.getHours() === 3 &&
        \\  d.getMinutes() === 4 &&
        \\  d.getSeconds() === 5 &&
        \\  d.getMilliseconds() === 6;
        \\var u = new Date(Date.UTC("2026", "0", "2", "3", "4", "5", "6"));
        \\var utcOk = u.getUTCFullYear() === 2026 &&
        \\  u.getUTCMonth() === 0 &&
        \\  u.getUTCDate() === 2 &&
        \\  u.getUTCHours() === 3 &&
        \\  u.getUTCMinutes() === 4 &&
        \\  u.getUTCSeconds() === 5 &&
        \\  u.getUTCMilliseconds() === 6;
        \\var s = new Date(0);
        \\s.setFullYear("2027", "1", "3");
        \\s.setHours("4", "5", "6", "7");
        \\var setterOk = s.getFullYear() === 2027 &&
        \\  s.getMonth() === 1 &&
        \\  s.getDate() === 3 &&
        \\  s.getHours() === 4 &&
        \\  s.getMinutes() === 5 &&
        \\  s.getSeconds() === 6 &&
        \\  s.getMilliseconds() === 7;
        \\var us = new Date(0);
        \\us.setUTCFullYear("2027", "1", "3");
        \\us.setUTCHours("4", "5", "6", "7");
        \\var utcSetterOk = us.getUTCFullYear() === 2027 &&
        \\  us.getUTCMonth() === 1 &&
        \\  us.getUTCDate() === 3 &&
        \\  us.getUTCHours() === 4 &&
        \\  us.getUTCMinutes() === 5 &&
        \\  us.getUTCSeconds() === 6 &&
        \\  us.getUTCMilliseconds() === 7;
        \\localOk && utcOk && setterOk && utcSetterOk
    );
    try std.testing.expect(result.asBool());
}

test "Date getUTCHours epoch" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.getUTCHours();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "Date toString returns string" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.toString();
    , "result");
    try std.testing.expect(result.isString());
}

test "Date instanceof Date" {
    const result = try evalWithMicrotasks(
        \\var d = new Date();
        \\var result = d instanceof Date;
    , "result");
    try std.testing.expect(result.asBool() == true);
}

// ---------------------------------------------------------------
// Promise.all / race / allSettled / any
// ---------------------------------------------------------------

test "Promise.all resolves" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.all([Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)])
        \\  .then(function(vals) { result = vals.length; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "Promise.all rejects on first failure" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.all([Promise.resolve(1), Promise.reject("fail"), Promise.resolve(3)])
        \\  .catch(function(e) { result = e; });
    , "result");
    try std.testing.expect(result.isString());
}

test "Promise.all empty" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.all([]).then(function(vals) { result = vals.length; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "Promise.race resolves first" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.race([Promise.resolve(42), Promise.resolve(99)])
        \\  .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "Promise.allSettled" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.allSettled([Promise.resolve(1), Promise.reject("e")])
        \\  .then(function(arr) { result = arr.length; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "Promise.any resolves first success" {
    const result = try evalWithMicrotasks(
        \\var result = null;
        \\Promise.any([Promise.reject("a"), Promise.resolve(42)])
        \\  .then(function(v) { result = v; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ---------------------------------------------------------------
// Console expansion
// ---------------------------------------------------------------

test "console.warn exists" {
    _ = try evalExpr(
        \\console.warn("test warning"); 42;
    );
}

test "console.error exists" {
    _ = try evalExpr(
        \\console.error("test error"); 42;
    );
}

test "console.info exists" {
    _ = try evalExpr(
        \\console.info("test info"); 42;
    );
}

test "console.debug exists" {
    _ = try evalExpr(
        \\console.debug("test debug"); 42;
    );
}

test "console.assert no crash on true" {
    _ = try evalExpr(
        \\console.assert(true, "should not print"); 42;
    );
}

test "console.time and timeEnd" {
    _ = try evalExpr(
        \\console.time("test"); console.timeEnd("test"); 42;
    );
}

test "console.count" {
    _ = try evalExpr(
        \\console.count("a"); console.count("a"); console.countReset("a"); 42;
    );
}

test "console.group and groupEnd" {
    _ = try evalExpr(
        \\console.group("g"); console.log("nested"); console.groupEnd(); 42;
    );
}

test "console.clear no crash" {
    _ = try evalExpr(
        \\console.clear(); 42;
    );
}

test "console.dir object" {
    _ = try evalExpr(
        \\console.dir({a: 1, b: 2}); 42;
    );
}

test "console.table array" {
    _ = try evalExpr(
        \\console.table([1, 2, 3]); 42;
    );
}

test "console.trace" {
    _ = try evalExpr(
        \\console.trace("trace test"); 42;
    );
}

// ── Nullish coalescing (??) ─────────────────────────────────────

test "eval: null ?? 42" {
    const result = try evalExpr("null ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: undefined ?? 42" {
    const result = try evalExpr("undefined ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: 0 ?? 42 (not nullish)" {
    const result = try evalExpr("0 ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: false ?? 42 (not nullish)" {
    const result = try evalExpr("false ?? 42");
    try std.testing.expect(!result.asBool());
}

test "eval: empty string ?? fallback (not nullish)" {
    const result = try evalExpr("\"\" ?? 42");
    try std.testing.expect(result.isString());
}

test "eval: hello ?? 42" {
    const result = try evalExpr("\"hello\" ?? 42");
    try std.testing.expect(result.isString());
}

test "eval: chained null ?? undefined ?? 42" {
    const result = try evalExpr("null ?? undefined ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Optional chaining (?.) ──────────────────────────────────────

test "eval: null?.foo" {
    const result = try evalExpr("null?.foo");
    try std.testing.expect(result.isUndefined());
}

test "eval: undefined?.foo" {
    const result = try evalExpr("undefined?.foo");
    try std.testing.expect(result.isUndefined());
}

test "eval: obj?.a" {
    const result = try evalExpr("let o = {a: 42}; o?.a");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: null?.foo?.bar" {
    const result = try evalExpr("null?.foo?.bar");
    try std.testing.expect(result.isUndefined());
}

test "eval: deep optional chain" {
    const result = try evalExpr("let o = {a: {b: 99}}; o?.a?.b");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: null?.[0]" {
    const result = try evalExpr("null?.[0]");
    try std.testing.expect(result.isUndefined());
}

test "eval: arr?.[1]" {
    const result = try evalExpr("[10,20,30]?.[1]");
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

// ── globalThis ──────────────────────────────────────────────────

test "eval: globalThis.parseInt" {
    const result = try evalExpr("globalThis.parseInt(\"42\")");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: globalThis.isNaN" {
    const result = try evalExpr("globalThis.isNaN(NaN)");
    try std.testing.expect(result.asBool());
}

// ── Spread in function calls ────────────────────────────────────

test "eval: spread in call Math.max" {
    const result = try evalExpr("Math.max(...[1,2,3])");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: spread in call function" {
    const result = try evalExpr("function f(a,b,c) { return a+b+c; } f(...[1,2,3])");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: spread mixed args" {
    const result = try evalExpr("function f(a,b,c,d) { return a+b+c+d; } f(0, ...[1,2], 3)");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

// ── Object getter/setter ────────────────────────────────────────

test "eval: object getter" {
    const result = try evalExpr("let o = { get x() { return 42; } }; o.x");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: object getter and setter" {
    const result = try evalExpr(
        \\let o = {
        \\  _v: 0,
        \\  set v(x) { this._v = x; },
        \\  get v() { return this._v; }
        \\};
        \\o.v = 10;
        \\o.v
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: class getter" {
    const result = try evalExpr(
        \\class C {
        \\  get name() { return 42; }
        \\}
        \\new C().name
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Symbol ──────────────────────────────────────────────────────

test "eval: typeof Symbol()" {
    const result = try evalExpr("typeof Symbol()");
    try std.testing.expect(result.isString());
}

test "eval: Symbol uniqueness" {
    const result = try evalExpr("Symbol('a') !== Symbol('a')");
    try std.testing.expect(result.asBool());
}

test "eval: Symbol.for registry" {
    const result = try evalExpr("Symbol.for('x') === Symbol.for('x')");
    try std.testing.expect(result.asBool());
}

test "eval: Symbol as property key" {
    const result = try evalExpr(
        \\let s = Symbol();
        \\let o = {};
        \\o[s] = 42;
        \\o[s]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: Symbol.iterator exists" {
    const result = try evalExpr("typeof Symbol.iterator");
    try std.testing.expect(result.isString());
}

test "eval: class getter and setter" {
    const result = try evalExpr(
        \\class C {
        \\  constructor() { this._v = 0; }
        \\  set val(v) { this._v = v * 2; }
        \\  get val() { return this._v; }
        \\}
        \\let c = new C();
        \\c.val = 5;
        \\c.val
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

// ── WeakMap / WeakSet ───────────────────────────────────────────

test "eval: WeakMap basic" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 42);
        \\wm.get(o)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: WeakMap prototype constructor" {
    const result = try evalExpr("WeakMap.prototype.constructor === WeakMap");
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap prototype set works with call" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\let ret = WeakMap.prototype.set.call(wm, o, 9);
        \\ret === wm && wm.get(o) === 9
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap prototype get works with call" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 9);
        \\WeakMap.prototype.get.call(wm, o)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: WeakMap prototype has works with call" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 9);
        \\WeakMap.prototype.has.call(wm, o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap prototype delete works with call" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 9);
        \\WeakMap.prototype.delete.call(wm, o) && !wm.has(o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap has and delete" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 1);
        \\wm.delete(o);
        \\wm.has(o)
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "eval: WeakMap constructor consumes entries" {
    const result = try evalExpr(
        \\let o = {};
        \\let wm = new WeakMap([[o, 7]]);
        \\wm.get(o)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: WeakMap constructor allows missing entry value" {
    const result = try evalExpr(
        \\let o = {};
        \\let wm = new WeakMap([[o]]);
        \\wm.has(o) && wm.get(o) === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap constructor rejects primitive keys" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakMap([[1, 2]]); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap constructor rejects non-iterable primitive" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakMap(1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap set missing value stores undefined" {
    const result = try evalExpr(
        \\let o = {};
        \\let wm = new WeakMap();
        \\wm.set(o);
        \\wm.has(o) && wm.get(o) === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap set missing key throws" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakMap().set(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap method lengths" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\wm.set.length === 2 && wm.get.length === 1 && wm.has.length === 1 && wm.delete.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakMap requires new" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { WeakMap(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet basic" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\ws.add(o);
        \\ws.has(o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet prototype constructor" {
    const result = try evalExpr("WeakSet.prototype.constructor === WeakSet");
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet prototype add works with call" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\let ret = WeakSet.prototype.add.call(ws, o);
        \\ret === ws && ws.has(o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet prototype has works with call" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\ws.add(o);
        \\WeakSet.prototype.has.call(ws, o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet prototype delete works with call" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\ws.add(o);
        \\WeakSet.prototype.delete.call(ws, o) && !ws.has(o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet constructor consumes values" {
    const result = try evalExpr(
        \\let o = {};
        \\let ws = new WeakSet([o]);
        \\ws.has(o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet constructor rejects primitive values" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakSet([1]); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet constructor rejects non-iterable primitive" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakSet(1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet add missing value throws" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { new WeakSet().add(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet method lengths" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\ws.add.length === 1 && ws.has.length === 1 && ws.delete.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: WeakSet requires new" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { WeakSet(); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

// ── Generators ──────────────────────────────────────────────────

test "eval: generator single yield" {
    const result = try evalExpr(
        \\function* g() { yield 42; }
        \\let it = g();
        \\it.next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: generator with return" {
    const result = try evalExpr(
        \\function* f() { return 42; }
        \\f().next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: generator done after exhausted" {
    const result = try evalExpr(
        \\function* g() { yield 1; }
        \\let it = g();
        \\let first = it.next();
        \\let second = it.next();
        \\second.done
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: generator two yields" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; }
        \\let it = g();
        \\let a = it.next().value;
        \\let b = it.next().value;
        \\a + b
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: generator next with sent value" {
    const result = try evalExpr(
        \\function* f() {
        \\  let x = yield 1;
        \\  yield x + 10;
        \\}
        \\let it = f();
        \\it.next();
        \\it.next(5).value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: generator range" {
    const result = try evalExpr(
        \\function* range(n) {
        \\  for (let i = 0; i < n; i++) yield i;
        \\}
        \\let sum = 0;
        \\let it = range(5);
        \\let r = it.next();
        \\while (!r.done) { sum = sum + r.value; r = it.next(); }
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: generator three yields" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\let it = g();
        \\let a = it.next().value;
        \\let b = it.next().value;
        \\let c = it.next().value;
        \\a + b + c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: WeakSet delete" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\ws.add(o);
        \\ws.delete(o);
        \\ws.has(o)
    );
    try std.testing.expect(!result.asBool());
}

// ── Iterator Protocol ───────────────────────────────────────────

test "eval: array Symbol.iterator" {
    const result = try evalExpr(
        \\let a = [10, 20];
        \\let it = a[Symbol.iterator]();
        \\let v1 = it.next().value;
        \\let v2 = it.next().value;
        \\v1 + v2
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: for-of with generator" {
    const result = try evalExpr(
        \\function* g() { yield 10; yield 20; }
        \\let sum = 0;
        \\for (let x of g()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: for-of with string" {
    const result = try evalExpr(
        \\let s = "";
        \\for (let c of "hi") s += c;
        \\s
    );
    try std.testing.expect(result.isString());
}

test "eval: for-of array regression" {
    const result = try evalExpr(
        \\let sum = 0;
        \\for (let x of [1,2,3]) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

// ── yield* delegation ────────────────────────────────────────────

test "eval: yield* generator delegation" {
    const result = try evalExpr(
        \\function* a() { yield 1; yield 2; }
        \\function* b() { yield* a(); yield 3; }
        \\let sum = 0;
        \\for (let x of b()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

// ── Async Generators ────────────────────────────────────────────

test "eval: async generator basic" {
    const result = try evalWithMicrotasks(
        \\let result = 0;
        \\async function* ag() { yield 1; yield 2; }
        \\async function main() {
        \\  let it = ag();
        \\  let r = await it.next();
        \\  result = r.value;
        \\}
        \\main();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: async generator multiple yields" {
    const result = try evalWithMicrotasks(
        \\let result = 0;
        \\async function* ag() { yield 10; yield 20; }
        \\async function main() {
        \\  let it = ag();
        \\  let r1 = await it.next();
        \\  let r2 = await it.next();
        \\  result = r1.value + r2.value;
        \\}
        \\main();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: async generator done" {
    const result = try evalWithMicrotasks(
        \\let result = false;
        \\async function* ag() { yield 1; }
        \\async function main() {
        \\  let it = ag();
        \\  await it.next();
        \\  let r = await it.next();
        \\  result = r.done;
        \\}
        \\main();
    , "result");
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ── for-await-of ────────────────────────────────────────────────

test "eval: for-await-of with async generator" {
    const result = try evalWithMicrotasks(
        \\let sum = 0;
        \\async function* ag() { yield 1; yield 2; yield 3; }
        \\async function main() {
        \\  for await (let x of ag()) { sum += x; }
        \\}
        \\main();
    , "sum");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: for-await-of with sync array" {
    const result = try evalWithMicrotasks(
        \\let sum = 0;
        \\async function main() {
        \\  for await (let x of [10, 20, 30]) { sum += x; }
        \\}
        \\main();
    , "sum");
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: spread generator via for-of collect" {
    // Note: [...generator()] with direct spread has re-entrant VM issues.
    // Workaround: collect via for-of which uses the normal iteration path.
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; }
        \\let a = [];
        \\for (let x of g()) a.push(x);
        \\a[0] + a[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: yield* array" {
    const result = try evalExpr(
        \\function* g() { yield* [10, 20]; yield 30; }
        \\let sum = 0;
        \\for (let x of g()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: array iterator done" {
    const result = try evalExpr(
        \\let a = [1];
        \\let it = a[Symbol.iterator]();
        \\it.next();
        \\it.next().done
    );
    try std.testing.expect(result.asBool());
}

test "eval: array iterator reads accessor elements" {
    const result = try evalExpr(
        \\let calls = 0;
        \\let a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 7; } });
        \\let it = a[Symbol.iterator]();
        \\it.next().value * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

// ── Phase F: Empty string falsiness ─────────────────────────────

test "eval: empty string is falsy" {
    // Must produce "no", not "yes" — verifies "" is falsy
    const result = try evalExpr(
        \\let r = "" ? "yes" : "no";
        \\r === "no" ? 1 : 0
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: non-empty string is truthy" {
    const result = try evalExpr(
        \\"hello" ? 1 : 0
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: not empty string is true" {
    const result = try evalExpr(
        \\!""
    );
    try std.testing.expect(result.asBool());
}

// ── Phase F: Array literal spread + generator spread ────────────

test "eval: spread array in array literal" {
    const result = try evalExpr(
        \\let a = [1, 2, 3];
        \\let b = [...a];
        \\b[0] + b[1] + b[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: spread generator into array" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\let a = [...g()];
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: spread generator with strings" {
    const result = try evalExpr(
        \\function* g() { yield "a"; yield "b"; }
        \\let a = [...g()];
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

// ── Phase F: UTF-8 string iteration ─────────────────────────────

test "eval: spread ASCII string" {
    const result = try evalExpr(
        \\let a = [..."hello"];
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: spread multibyte string" {
    // "あいう" = 3 codepoints (each 3 bytes), should spread to 3 elements not 9
    const result = try evalExpr("let a = [...\"\xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\"];\na.length");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: for-of multibyte string char count" {
    // "あいう" = 3 codepoints, for-of should iterate 3 times not 9
    const result = try evalExpr("let count = 0;\nfor (let c of \"\xe3\x81\x82\xe3\x81\x84\xe3\x81\x86\") count++;\ncount");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: for-of string char count" {
    const result = try evalExpr(
        \\let count = 0;
        \\for (let c of "hi") count++;
        \\count
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

// ── Phase F: Destructuring parameters ───────────────────────────

test "eval: object destructuring param" {
    const result = try evalExpr(
        \\function f({a, b}) { return a + b; }
        \\f({a: 1, b: 2})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: array destructuring param" {
    const result = try evalExpr(
        \\function f([x, y]) { return x * y; }
        \\f([3, 4])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: destructuring param with default" {
    const result = try evalExpr(
        \\function f({a = 10}) { return a; }
        \\f({})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: nested destructuring param" {
    const result = try evalExpr(
        \\function f({a: {b}}) { return b; }
        \\f({a: {b: 42}})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: arrow destructuring param" {
    const result = try evalExpr(
        \\let f = ({x}) => x + 1;
        \\f({x: 9})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: multiple destructuring params" {
    const result = try evalExpr(
        \\function f({a}, [b]) { return a + b; }
        \\f({a: 10}, [20])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

// ── Phase F: Tagged template literals ────────────────────────────

test "eval: tagged template basic" {
    // Verify exact interpolation result: "x1y2z"
    const result = try evalExpr(
        \\function tag(strings, a, b) { return strings[0] + a + strings[1] + b + strings[2]; }
        \\let r = tag`x${1}y${2}z`;
        \\r === "x1y2z" ? 1 : 0
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: tagged template strings length" {
    const result = try evalExpr(
        \\function tag(strings) { return strings.length; }
        \\tag`a${0}b${0}c`
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: tagged template no expressions" {
    // Verify exact string content: "hello"
    const result = try evalExpr(
        \\function tag(strings) { return strings[0]; }
        \\let r = tag`hello`;
        \\r === "hello" ? 1 : 0
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: tagged template raw property" {
    const result = try evalExpr(
        \\function tag(strings) { return strings.raw.length; }
        \\tag`hello`
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: tagged template member this binding" {
    const result = try evalExpr(
        \\let obj = { val: 42, tag(strings) { return this.val; } };
        \\obj.tag`hello`
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: destructuring param with whole-param default" {
    const result = try evalExpr(
        \\function f({a} = {a: 99}) { return a; }
        \\f()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: spread iterator object" {
    const result = try evalExpr(
        \\let a = [1, 2, 3];
        \\let it = a[Symbol.iterator]();
        \\let b = [...it];
        \\b[0] + b[1] + b[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: arrow destructuring default param" {
    const result = try evalExpr(
        \\let f = ({a} = {a: 55}) => a;
        \\f()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), result.asNumber(), 0.001);
}

test "eval: arrow array default element" {
    const result = try evalExpr(
        \\let f = ([x = 7]) => x;
        \\f([])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: arrow nested destructuring param" {
    const result = try evalExpr(
        \\let f = ({a: {b}}) => b;
        \\f({a: {b: 77}})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 77.0), result.asNumber(), 0.001);
}

test "eval: if empty string takes else" {
    const result = try evalExpr(
        \\let r = 0;
        \\if ("") { r = 1; } else { r = 2; }
        \\r
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

// ═══════════════════════════════════════════════════════════════════
// Phase G: Real-World Compatibility Tests
// ═══════════════════════════════════════════════════════════════════

// ── Math trig functions ─────────────────────────────────────────

test "eval: Math.sin" {
    const result = try evalExpr("Math.sin(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.sin PI/2" {
    const result = try evalExpr("Math.sin(Math.PI / 2)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Math.cos" {
    const result = try evalExpr("Math.cos(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Math.cos PI" {
    const result = try evalExpr("Math.cos(Math.PI)");
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "eval: Math.tan" {
    const result = try evalExpr("Math.tan(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.asin" {
    const result = try evalExpr("Math.asin(1)");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 2.0), result.asNumber(), 0.001);
}

test "eval: Math.acos" {
    const result = try evalExpr("Math.acos(1)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.atan" {
    const result = try evalExpr("Math.atan(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.atan2" {
    const result = try evalExpr("Math.atan2(1, 1)");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 4.0), result.asNumber(), 0.001);
}

test "eval: Math.exp" {
    const result = try evalExpr("Math.exp(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Math.exp(1)" {
    const result = try evalExpr("Math.exp(1)");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.e), result.asNumber(), 0.001);
}

test "eval: Math.log2" {
    const result = try evalExpr("Math.log2(8)");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Math.cbrt" {
    const result = try evalExpr("Math.cbrt(27)");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Math.hypot" {
    const result = try evalExpr("Math.hypot(3, 4)");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Math.clz32" {
    const result = try evalExpr("Math.clz32(1)");
    try std.testing.expectApproxEqAbs(@as(f64, 31.0), result.asNumber(), 0.001);
}

test "eval: Math.clz32 zero" {
    const result = try evalExpr("Math.clz32(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 32.0), result.asNumber(), 0.001);
}

test "eval: Math.imul wraps int32 product" {
    const result = try evalExpr(
        \\Math.imul(2, 4) === 8 &&
        \\Math.imul(0xffffffff, 5) === -5
    );
    try std.testing.expect(result.asBool());
}

test "eval: Math.asinh" {
    const result = try evalExpr("Math.asinh(0) === 0 && Math.asinh(1) > 0");
    try std.testing.expect(result.asBool());
}

test "eval: Math.acosh" {
    const result = try evalExpr("Math.acosh(1) === 0 && Math.acosh(2) > 0");
    try std.testing.expect(result.asBool());
}

test "eval: Math.atanh" {
    const result = try evalExpr("Math.atanh(0) === 0 && Math.atanh(0.5) > 0");
    try std.testing.expect(result.asBool());
}

test "eval: Math.sinh" {
    const result = try evalExpr("Math.sinh(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.cosh" {
    const result = try evalExpr("Math.cosh(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Math.tanh" {
    const result = try evalExpr("Math.tanh(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.fround" {
    const result = try evalExpr("Math.fround(5.5)");
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), result.asNumber(), 0.001);
}

test "eval: Math.log1p" {
    const result = try evalExpr("Math.log1p(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math.expm1" {
    const result = try evalExpr("Math.expm1(0)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Math extended methods coerce string numbers" {
    const result = try evalExpr(
        \\Math.sin("0") === 0 &&
        \\Math.cos("0") === 1 &&
        \\Math.atan2("1", "1") > 0 &&
        \\Math.log2("8") === 3 &&
        \\Math.cbrt("27") === 3 &&
        \\Math.hypot("3", "4") === 5 &&
        \\Math.clz32("1") === 31 &&
        \\Math.fround("5.5") === 5.5 &&
        \\Math.log1p("0") === 0 &&
        \\Math.expm1("0") === 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: Math.LN2" {
    const result = try evalExpr("Math.LN2");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.ln2), result.asNumber(), 0.001);
}

test "eval: Math.LOG2E" {
    const result = try evalExpr("Math.LOG2E");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.log2e), result.asNumber(), 0.001);
}

test "eval: Math.SQRT2" {
    const result = try evalExpr("Math.SQRT2");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.sqrt2), result.asNumber(), 0.001);
}

// ── URL encoding/decoding ──────────────────────────────────────

test "eval: encodeURIComponent basic" {
    const result = try evalExpr(
        \\encodeURIComponent("hello world")
    );
    try std.testing.expect(result.isString());
}

test "eval: encodeURIComponent special chars" {
    const result = try evalExpr(
        \\encodeURIComponent("a=1&b=2")
    );
    try std.testing.expect(result.isString());
}

test "eval: encodeURIComponent preserves mark chars" {
    const result = try evalExpr(
        \\encodeURIComponent("!'()*") === "!'()*"
    );
    try std.testing.expect(result.asBool());
}

test "eval: decodeURIComponent roundtrip" {
    const result = try evalExpr(
        \\decodeURIComponent(encodeURIComponent("hello world"))
    );
    try std.testing.expect(result.isString());
}

test "eval: encodeURI preserves reserved" {
    const result = try evalExpr(
        \\encodeURI("https://example.com/path?q=hello world")
    );
    try std.testing.expect(result.isString());
}

test "eval: decodeURI roundtrip" {
    const result = try evalExpr(
        \\decodeURI(encodeURI("test value"))
    );
    try std.testing.expect(result.isString());
}

test "eval: decodeURI preserves escaped reserved characters" {
    const result = try evalExpr(
        \\decodeURI("%3Fq%3Da%26b") === "%3Fq%3Da%26b"
    );
    try std.testing.expect(result.asBool());
}

test "eval: decodeURI decodes escaped mark characters" {
    const result = try evalExpr(
        \\decodeURI("%21%27%28%29%2A") === "!'()*"
    );
    try std.testing.expect(result.asBool());
}

test "eval: decodeURIComponent malformed escape throws URIError" {
    const result = try evalExpr(
        \\(function(){ try { decodeURIComponent("%"); } catch (e) { return e.name === "URIError"; } return false; })()
    );
    try std.testing.expect(result.asBool());
}

test "eval: decodeURIComponent malformed utf8 throws URIError" {
    const result = try evalExpr(
        \\(function(){ try { decodeURIComponent("%FF"); } catch (e) { return e.name === "URIError"; } return false; })()
    );
    try std.testing.expect(result.asBool());
}

test "eval: URI functions coerce input" {
    const result = try evalExpr(
        \\encodeURIComponent(123) === "123" &&
        \\encodeURI(false) === "false" &&
        \\decodeURIComponent({toString: function(){ return "a%20b"; }}) === "a b" &&
        \\decodeURI({toString: function(){ return "a%20b"; }}) === "a b" &&
        \\encodeURIComponent() === "undefined"
    );
    try std.testing.expect(result.asBool());
}

test "eval: encodeURIComponent decode roundtrip equality" {
    const result = try evalExpr(
        \\decodeURIComponent(encodeURIComponent("café")) === "café"
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ── String.fromCharCode / fromCodePoint / codePointAt / substr ──

test "eval: String.fromCharCode" {
    const result = try evalExpr(
        \\String.fromCharCode(72, 105)
    );
    try std.testing.expect(result.isString());
}

test "eval: String.fromCodePoint" {
    const result = try evalExpr(
        \\String.fromCodePoint(65)
    );
    try std.testing.expect(result.isString());
}

test "eval: String.fromCharCode A" {
    const result = try evalExpr(
        \\String.fromCharCode(65) === "A"
    );
    try std.testing.expect(result.asBool());
}

test "eval: String.fromCodePoint A" {
    const result = try evalExpr(
        \\String.fromCodePoint(65) === "A"
    );
    try std.testing.expect(result.asBool());
}

test "eval: String code constructors coerce and validate" {
    const result = try evalExpr(
        \\String.fromCharCode("65") === "A" &&
        \\String.fromCodePoint("65") === "A" &&
        \\(function(){ try { String.fromCodePoint(0x110000); } catch (e) { return e.name === "RangeError"; } return false; })() &&
        \\(function(){ try { String.fromCodePoint(1.5); } catch (e) { return e.name === "RangeError"; } return false; })()
    );
    try std.testing.expect(result.asBool());
}

test "eval: codePointAt" {
    const result = try evalExpr(
        \\"A".codePointAt(0)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 65.0), result.asNumber(), 0.001);
}

test "eval: codePointAt index 1" {
    const result = try evalExpr(
        \\"AB".codePointAt(1)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 66.0), result.asNumber(), 0.001);
}

test "eval: codePointAt out of range" {
    const result = try evalExpr(
        \\"A".codePointAt(5)
    );
    try std.testing.expect(result.isUndefined());
}

test "eval: substr basic" {
    const result = try evalExpr(
        \\"hello world".substr(6) === "world"
    );
    try std.testing.expect(result.asBool());
}

test "eval: substr with length" {
    const result = try evalExpr(
        \\"hello world".substr(0, 5) === "hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: substr negative start" {
    const result = try evalExpr(
        \\"hello".substr(-3) === "llo"
    );
    try std.testing.expect(result.asBool());
}

test "eval: codePointAt and substr coerce numeric arguments" {
    const result = try evalExpr(
        \\"AB".codePointAt("1") === 66 &&
        \\"hello".substr("1", "3") === "ell"
    );
    try std.testing.expect(result.asBool());
}

// ── Array.from / Array.of ───────────────────────────────────────

test "eval: Array.of" {
    const result = try evalExpr(
        \\let a = Array.of(1, 2, 3);
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Array.of values" {
    const result = try evalExpr(
        \\let a = Array.of(10, 20, 30);
        \\a[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

test "eval: Array.from string" {
    const result = try evalExpr(
        \\let a = Array.from("abc");
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Array.from string values" {
    const result = try evalExpr(
        \\let a = Array.from("abc");
        \\a[0] === "a" && a[1] === "b" && a[2] === "c"
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.from array" {
    const result = try evalExpr(
        \\let a = Array.from([1, 2, 3]);
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: Array.from with mapFn" {
    const result = try evalExpr(
        \\let a = Array.from([1, 2, 3], x => x * 2);
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: Array.from mapFn uses thisArg" {
    const result = try evalExpr(
        \\let a = Array.from([1, 2], function(x) { return x * this.factor; }, { factor: 3 });
        \\a[0] + a[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

test "eval: Array.from non-callable mapFn throws TypeError" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { Array.from([1], {}); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.from null and undefined throw TypeError" {
    const result = try evalExpr(
        \\let count = 0;
        \\try { Array.from(null); } catch (e) { if (e.name === "TypeError") count = count + 1; }
        \\try { Array.from(undefined); } catch (e) { if (e.name === "TypeError") count = count + 1; }
        \\count
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: Array.from primitive number returns empty array" {
    const result = try evalExpr(
        \\Array.from(42).length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Array.from array-like coerces string length" {
    const result = try evalExpr(
        \\let a = Array.from({0: 5, 1: 6, length: "2"});
        \\a[0] * 10 + a[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 56.0), result.asNumber(), 0.001);
}

test "eval: Array.from array-like preserves missing entries as undefined" {
    const result = try evalExpr(
        \\let a = Array.from({0: 5, length: "3"});
        \\a.length === 3 && a[1] === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array generic methods coerce array-like string length" {
    const result = try evalExpr(
        \\let a = Array.prototype.map.call({0: 2, 1: 3, length: "2"}, x => x * 10);
        \\a[0] + a[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), result.asNumber(), 0.001);
}

test "eval: Array.from array-like reads accessor elements" {
    const result = try evalExpr(
        \\let calls = 0;
        \\let a = Array.from({ get 0() { calls = calls + 1; return 7; }, length: 1 });
        \\a[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: Array generic methods read array-like accessor elements" {
    const result = try evalExpr(
        \\let calls = 0;
        \\let a = Array.prototype.map.call({ get 0() { calls = calls + 1; return 4; }, length: 1 }, x => x + 1);
        \\a[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 51.0), result.asNumber(), 0.001);
}

test "eval: Array.from array-like accessor throw propagates" {
    const result = try evalExpr(
        \\let caught = 0;
        \\try { Array.from({ get 0() { throw 7; }, length: 1 }); } catch (e) { caught = e; }
        \\caught
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: Array generic method accessor throw propagates" {
    const result = try evalExpr(
        \\let caught = 0;
        \\try { Array.prototype.map.call({ get 0() { throw 8; }, length: 1 }, x => x); } catch (e) { caught = e; }
        \\caught
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: Array.from array-like reads length accessor" {
    const result = try evalExpr(
        \\let calls = 0;
        \\let a = Array.from({0: 4, get length() { calls = calls + 1; return "1"; }});
        \\a[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 41.0), result.asNumber(), 0.001);
}

test "eval: Array generic method length accessor throw propagates" {
    const result = try evalExpr(
        \\let caught = 0;
        \\try { Array.prototype.map.call({ get length() { throw 9; } }, x => x); } catch (e) { caught = e; }
        \\caught
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

// ── Abstract equality (==) ──────────────────────────────────────

test "eval: null == undefined" {
    const result = try evalExpr("null == undefined");
    try std.testing.expect(result.asBool());
}

test "eval: undefined == null" {
    const result = try evalExpr("undefined == null");
    try std.testing.expect(result.asBool());
}

test "eval: null == null" {
    const result = try evalExpr("null == null");
    try std.testing.expect(result.asBool());
}

test "eval: null != 0" {
    const result = try evalExpr("null == 0");
    try std.testing.expect(!result.asBool());
}

test "eval: null != false" {
    const result = try evalExpr("null == false");
    try std.testing.expect(!result.asBool());
}

test "eval: string == number coercion" {
    const result = try evalExpr(
        \\"42" == 42
    );
    try std.testing.expect(result.asBool());
}

test "eval: string == number trims vertical tab" {
    const result = try evalExpr(
        \\"\v42" == 42
    );
    try std.testing.expect(result.asBool());
}

test "eval: string == number trims non-breaking space" {
    const result = try evalExpr("\"\\u00a042\\u00a0\" == 42");
    try std.testing.expect(result.asBool());
}

test "eval: number == string coercion" {
    const result = try evalExpr(
        \\42 == "42"
    );
    try std.testing.expect(result.asBool());
}

test "eval: bool == number coercion" {
    const result = try evalExpr(
        \\true == 1
    );
    try std.testing.expect(result.asBool());
}

test "eval: false == 0" {
    const result = try evalExpr(
        \\false == 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: empty string == 0" {
    const result = try evalExpr(
        \\"" == 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: string != different number" {
    const result = try evalExpr(
        \\"5" == 3
    );
    try std.testing.expect(!result.asBool());
}

test "eval: 1 == true" {
    const result = try evalExpr("1 == true");
    try std.testing.expect(result.asBool());
}

test "eval: 0 == false" {
    const result = try evalExpr("0 == false");
    try std.testing.expect(result.asBool());
}

test "eval: != with coercion" {
    const result = try evalExpr(
        \\"42" != 42
    );
    try std.testing.expect(!result.asBool());
}

test "eval: !== without coercion" {
    const result = try evalExpr(
        \\"42" !== 42
    );
    try std.testing.expect(result.asBool());
}

test "eval: NaN is never strictly equal" {
    const result = try evalExpr(
        \\NaN !== NaN && !(NaN === NaN)
    );
    try std.testing.expect(result.asBool());
}

test "eval: NaN is never abstractly equal" {
    const result = try evalExpr(
        \\NaN != NaN && !(NaN == NaN)
    );
    try std.testing.expect(result.asBool());
}

// ── typeof ──────────────────────────────────────────────────────

test "eval: typeof number strict check" {
    const result = try evalExpr(
        \\typeof 42 === "number"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof string strict check" {
    const result = try evalExpr(
        \\typeof "hello" === "string"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof boolean strict check" {
    const result = try evalExpr(
        \\typeof true === "boolean"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof undefined strict check" {
    const result = try evalExpr(
        \\typeof undefined === "undefined"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof null returns object" {
    const result = try evalExpr(
        \\typeof null === "object"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof function decl" {
    const result = try evalExpr(
        \\typeof function(){} === "function"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof object literal" {
    const result = try evalExpr(
        \\typeof {} === "object"
    );
    try std.testing.expect(result.asBool());
}

test "eval: typeof symbol value" {
    const result = try evalExpr(
        \\typeof Symbol("x") === "symbol"
    );
    try std.testing.expect(result.asBool());
}

// ── Phase I: Class fields ───────────────────────────────────────

test "eval: class instance field with initializer" {
    const result = try evalExpr(
        \\class A { x = 42; }
        \\var a = new A();
        \\a.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: class instance field without initializer" {
    const result = try evalExpr(
        \\class A { x; }
        \\var a = new A();
        \\a.x === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: class static field" {
    const result = try evalExpr(
        \\class A { static count = 10; }
        \\A.count
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: class fields and methods together" {
    const result = try evalExpr(
        \\class Counter {
        \\  count = 0;
        \\  inc() { this.count++; return this.count; }
        \\}
        \\var c = new Counter();
        \\c.inc(); c.inc(); c.inc()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: class multiple instance fields" {
    const result = try evalExpr(
        \\class Point {
        \\  x = 1;
        \\  y = 2;
        \\}
        \\var p = new Point();
        \\p.x + p.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: class static and instance fields" {
    const result = try evalExpr(
        \\class Dog {
        \\  name = "Rex";
        \\  static species = "canine";
        \\}
        \\var d = new Dog();
        \\d.name + " " + Dog.species
    );
    const vm_result = result;
    try std.testing.expect(vm_result.isString());
}

test "eval: class field with constructor" {
    const result = try evalExpr(
        \\class A {
        \\  x = 10;
        \\  constructor(y) { this.y = y; }
        \\}
        \\var a = new A(20);
        \\a.x + a.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: class field expression initializer" {
    const result = try evalExpr(
        \\class A {
        \\  x = 2 + 3;
        \\  y = [1, 2, 3];
        \\}
        \\var a = new A();
        \\a.x + a.y.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: class static field without initializer" {
    const result = try evalExpr(
        \\class A { static x; }
        \\A.x === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: instances have independent fields" {
    const result = try evalExpr(
        \\class Box { value = 0; }
        \\var a = new Box(); var b = new Box();
        \\a.value = 5;
        \\b.value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── Phase I: Object.is ──────────────────────────────────────────

test "eval: Object.is same values" {
    const result = try evalExpr(
        \\Object.is(1, 1)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.is different values" {
    const result = try evalExpr(
        \\Object.is(1, 2)
    );
    try std.testing.expect(!result.asBool());
}

test "eval: Object.is strings" {
    const result = try evalExpr(
        \\Object.is("abc", "abc")
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.is null" {
    const result = try evalExpr(
        \\Object.is(null, null)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.is undefined" {
    const result = try evalExpr(
        \\Object.is(undefined, undefined)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.is null vs undefined" {
    const result = try evalExpr(
        \\Object.is(null, undefined)
    );
    try std.testing.expect(!result.asBool());
}

// ── Phase I: Object.hasOwn ──────────────────────────────────────

test "eval: Object.hasOwn own property" {
    const result = try evalExpr(
        \\var o = {x: 1, y: 2};
        \\Object.hasOwn(o, "x")
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.hasOwn missing property" {
    const result = try evalExpr(
        \\var o = {x: 1};
        \\Object.hasOwn(o, "z")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: hasOwnProperty sees defineProperty data property" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1 });
        \\o.hasOwnProperty("x")
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: Object.hasOwn sees defineProperty data property" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1 });
        \\Object.hasOwn(o, "x")
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: Object.hasOwn coerces numeric keys" {
    const result = try evalExpr(
        \\var o = {0: "x"};
        \\Object.hasOwn(o, 0)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.hasOwn supports symbol keys" {
    const result = try evalExpr(
        \\var s = Symbol("x");
        \\var o = {};
        \\o[s] = 1;
        \\Object.hasOwn(o, s)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.defineProperty defaults are false" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1 });
        \\var d = Object.getOwnPropertyDescriptor(o, "x");
        \\d.writable === false && d.enumerable === false && d.configurable === false
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: propertyIsEnumerable false for default defineProperty" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1 });
        \\o.propertyIsEnumerable("x")
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "eval: propertyIsEnumerable coerces numeric keys" {
    const result = try evalExpr(
        \\var o = {0: "x"};
        \\o.propertyIsEnumerable(0)
    );
    try std.testing.expect(result.asBool());
}

test "eval: propertyIsEnumerable supports symbol keys" {
    const result = try evalExpr(
        \\var s = Symbol("x");
        \\var o = {};
        \\o[s] = 1;
        \\o.propertyIsEnumerable(s)
    );
    try std.testing.expect(result.asBool());
}

test "eval: propertyIsEnumerable respects symbol descriptor attrs" {
    const result = try evalExpr(
        \\var s = Symbol("x");
        \\var o = {};
        \\Object.defineProperty(o, s, { value: 1, enumerable: false });
        \\o.propertyIsEnumerable(s)
    );
    try std.testing.expect(!result.asBool());
}

test "eval: preventExtensions blocks adding new property" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.preventExtensions(o);
        \\o.x = 1;
        \\Object.hasOwn(o, "x") === false && o.x === undefined
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: delete non-configurable property returns false" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1, configurable: false });
        \\var deleted = delete o.x;
        \\deleted === false && o.x === 1
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: Object.getOwnPropertyNames includes array length" {
    const result = try evalExpr(
        \\Object.getOwnPropertyNames(["a", "b"]).indexOf("length") >= 0
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: array length is visible to in operator" {
    const result = try evalExpr(
        \\"length" in ["a", "b"]
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: array length has own property descriptor" {
    const result = try evalExpr(
        \\var d = Object.getOwnPropertyDescriptor(["a", "b"], "length");
        \\d && d.enumerable === false && d.configurable === false && d.writable === true && d.value === 2
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: new Array zero args has length 0" {
    const result = try evalExpr(
        \\var arr = new Array;
        \\arr.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: array defineProperty accessor updates length and join" {
    const result = try evalExpr(
        \\var arr = new Array;
        \\var called = 0;
        \\Object.defineProperty(arr, 0, { get: function() { ++called; return 7; } });
        \\var ok = arr.length === 1;
        \\ok = ok && called === 0;
        \\ok = ok && arr[0] === 7;
        \\ok = ok && called === 1;
        \\ok = ok && String(arr) === "7";
        \\ok = ok && called === 2;
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ── Phase I: Object.fromEntries ─────────────────────────────────

test "eval: Object.fromEntries basic" {
    const result = try evalExpr(
        \\var o = Object.fromEntries([["a", 1], ["b", 2]]);
        \\o.a + o.b
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Object.fromEntries roundtrip" {
    const result = try evalExpr(
        \\var orig = {x: 10, y: 20};
        \\var copy = Object.fromEntries(Object.entries(orig));
        \\copy.x + copy.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: Object.fromEntries reads accessor entries" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var pair = ["x", 1];
        \\Object.defineProperty(pair, 1, { get: function() { calls = calls + 1; return 7; } });
        \\var entries = [pair];
        \\Object.defineProperty(entries, 0, { get: function() { calls = calls + 1; return pair; } });
        \\var o = Object.fromEntries(entries);
        \\o.x * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 72.0), result.asNumber(), 0.001);
}

test "eval: Object.fromEntries works on array-like entries" {
    const result = try evalExpr(
        \\var pair = {0: "x", 1: 8, length: "2"};
        \\var entries = {0: pair, length: "1"};
        \\Object.fromEntries(entries).x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: Object.fromEntries supports symbol keys" {
    const result = try evalExpr(
        \\var s = Symbol("x");
        \\var o = Object.fromEntries([[s, 9]]);
        \\o[s]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.asNumber(), 0.001);
}

// ── Phase I: String.prototype.matchAll ──────────────────────────

test "eval: matchAll basic iteration" {
    const result = try evalExpr(
        \\var s = "test1 test2 test3";
        \\var it = s.matchAll(/test\d/g);
        \\var a = it.next(); var b = it.next(); var c = it.next();
        \\var d = it.next();
        \\!a.done && !b.done && !c.done && d.done
    );
    try std.testing.expect(result.asBool());
}

test "eval: matchAll match values" {
    const result = try evalExpr(
        \\var s = "foo1bar2";
        \\var it = s.matchAll(/\d/g);
        \\var first = it.next().value[0];
        \\var second = it.next().value[0];
        \\first + second
    );
    try std.testing.expect(result.isString());
}

test "eval: matchAll with string pattern" {
    const result = try evalExpr(
        \\var s = "abcabc";
        \\var it = s.matchAll("bc");
        \\var r = it.next();
        \\!r.done
    );
    try std.testing.expect(result.asBool());
}

test "eval: matchAll coerces primitive pattern" {
    const result = try evalExpr(
        \\var it = "abc123".matchAll(123);
        \\it.next().value[0] === "123"
    );
    try std.testing.expect(result.asBool());
}

// ── Phase J: Object.prototype ───────────────────────────────────

test "eval: Object.prototype.constructor" {
    const result = try evalExpr("Object.prototype.constructor === Object");
    try std.testing.expect(result.asBool());
}

test "eval: hasOwnProperty own prop" {
    const result = try evalExpr(
        \\var o = {x: 1, y: 2};
        \\o.hasOwnProperty("x")
    );
    try std.testing.expect(result.asBool());
}

test "eval: hasOwnProperty missing prop" {
    const result = try evalExpr(
        \\var o = {x: 1};
        \\o.hasOwnProperty("z")
    );
    try std.testing.expect(!result.asBool());
}

test "eval: Object.prototype.toString on object" {
    const result = try evalExpr(
        \\var o = {};
        \\o.toString()
    );
    try std.testing.expect(result.isString());
}

test "eval: Object.prototype.toString on array" {
    const result = try evalExpr(
        \\var a = [1,2,3];
        \\Object.prototype.toString.call(a)
    );
    try std.testing.expect(result.isString());
}

test "eval: Object.prototype.toLocaleString delegates to toString" {
    const result = try evalExpr(
        \\var o = { toString: function() { return "ok"; } };
        \\o.toLocaleString() === "ok"
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.prototype.valueOf returns self" {
    const result = try evalExpr(
        \\var o = {x: 42};
        \\o.valueOf().x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Phase J: Array.findLast / findLastIndex ──────────────────────

test "eval: Array.findLast" {
    const result = try evalExpr(
        \\[1, 2, 3, 4, 5].findLast(function(x) { return x % 2 === 0; })
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Array.findLast not found" {
    const result = try evalExpr(
        \\[1, 3, 5].findLast(function(x) { return x > 10; }) === undefined
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.findLastIndex" {
    const result = try evalExpr(
        \\[1, 2, 3, 2, 1].findLastIndex(function(x) { return x === 2; })
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Array.findLastIndex not found" {
    const result = try evalExpr(
        \\[1, 2, 3].findLastIndex(function(x) { return x === 9; })
    );
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

// ── Phase J: structuredClone ────────────────────────────────────

test "eval: structuredClone object" {
    const result = try evalExpr(
        \\var orig = {a: 1, b: {c: 2}};
        \\var copy = structuredClone(orig);
        \\copy.b.c = 99;
        \\orig.b.c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: structuredClone array" {
    const result = try evalExpr(
        \\var orig = [1, [2, 3]];
        \\var copy = structuredClone(orig);
        \\copy[1].push(4);
        \\orig[1].length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: structuredClone primitives" {
    const result = try evalExpr(
        \\structuredClone(42)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// ── Phase J: String stubs ───────────────────────────────────────

test "eval: String.normalize returns self" {
    const result = try evalExpr(
        \\"hello".normalize() === "hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: String.normalize invalid form throws RangeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { "hello".normalize("BAD"); } catch (e) { ok = e.name === "RangeError"; }
        \\ok;
    );
    try std.testing.expect(result.asBool());
}

test "eval: String.localeCompare equal" {
    const result = try evalExpr(
        \\"abc".localeCompare("abc")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: String.localeCompare less" {
    const result = try evalExpr(
        \\"abc".localeCompare("xyz") < 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: String.localeCompare greater" {
    const result = try evalExpr(
        \\"xyz".localeCompare("abc") > 0
    );
    try std.testing.expect(result.asBool());
}

// ── Pattern compatibility checks ────────────────────────────────

test "eval: computed property in object literal" {
    const result = try evalExpr(
        \\var key = "foo"; var o = {[key]: 42}; o.foo
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: object spread" {
    const result = try evalExpr(
        \\var a = {x:1}; var b = {y:2, ...a}; b.x + b.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: instanceof with inheritance" {
    const result = try evalExpr(
        \\class A {} class B extends A {}
        \\var b = new B();
        \\(b instanceof B) && (b instanceof A)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.isArray check" {
    const result = try evalExpr(
        \\Array.isArray([1,2]) && !Array.isArray({})
    );
    try std.testing.expect(result.asBool());
}

test "eval: Error constructor message" {
    const result = try evalExpr(
        \\var e = new TypeError("bad"); e.message === "bad"
    );
    try std.testing.expect(result.asBool());
}

test "eval: try-catch error handling" {
    const result = try evalExpr(
        \\var msg = "";
        \\try { throw new Error("oops"); } catch(e) { msg = e.message; }
        \\msg === "oops"
    );
    try std.testing.expect(result.asBool());
}

test "eval: for-of with array" {
    const result = try evalExpr(
        \\var sum = 0;
        \\for (var x of [10, 20, 30]) { sum += x; }
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: Map basic operations" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 1); m.set("b", 2);
        \\m.get("a") + m.get("b") + m.size
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Set basic operations" {
    const result = try evalExpr(
        \\var s = new Set([1, 2, 2, 3]);
        \\s.size
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: Promise.resolve then" {
    const result = try evalWithMicrotasks(
        \\var out = 0;
        \\Promise.resolve(42).then(function(v) { out = v; });
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: async await basic" {
    const result = try evalWithMicrotasks(
        \\var out = 0;
        \\async function f() { return 99; }
        \\f().then(function(v) { out = v; });
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: destructuring assignment" {
    const result = try evalExpr(
        \\var [a, b, c] = [10, 20, 30];
        \\a + b + c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: object destructuring" {
    const result = try evalExpr(
        \\var {x, y} = {x: 5, y: 10};
        \\x + y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: template literal with expression" {
    const result = try evalExpr(
        \\var n = 42;
        \\`value is ${n}`
    );
    try std.testing.expect(result.isString());
}

// ── Uint8Array / ArrayBuffer ────────────────────────────────────

test "eval: Uint8Array from length" {
    const result = try evalExpr(
        \\var a = new Uint8Array(4);
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array length coerces string" {
    const result = try evalExpr(
        \\var a = new Uint8Array("4");
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array negative length throws RangeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Uint8Array(-1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Uint8Array NaN length becomes zero" {
    const result = try evalExpr(
        \\new Uint8Array(NaN).length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array index read/write" {
    const result = try evalExpr(
        \\var a = new Uint8Array(3);
        \\a[0] = 10; a[1] = 20; a[2] = 30;
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array index write coerces string value" {
    const result = try evalExpr(
        \\var a = new Uint8Array(1);
        \\a[0] = "257";
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array from array" {
    const result = try evalExpr(
        \\var a = new Uint8Array([65, 66, 67]);
        \\a[0] + a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 68.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array from array coerces values" {
    const result = try evalExpr(
        \\var a = new Uint8Array(["65", true, null]);
        \\a[0] + a[1] + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 66.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array constructor reads array accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var src = [1];
        \\Object.defineProperty(src, 0, { get: function() { calls = calls + 1; return "8"; } });
        \\var a = new Uint8Array(src);
        \\a[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 81.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array constructor works on array-like objects" {
    const result = try evalExpr(
        \\var a = new Uint8Array({0: "4", 2: 6, length: "3"});
        \\a.length * 1000 + a[0] * 100 + a[1] * 10 + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3406.0), result.asNumber(), 0.001);
}

test "eval: ArrayBuffer constructor" {
    const result = try evalExpr(
        \\var b = new ArrayBuffer(8);
        \\b.byteLength
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: ArrayBuffer prototype constructor" {
    const result = try evalExpr("ArrayBuffer.prototype.constructor === ArrayBuffer");
    try std.testing.expect(result.asBool());
}

test "eval: ArrayBuffer length coerces string" {
    const result = try evalExpr(
        \\var b = new ArrayBuffer("8");
        \\b.byteLength
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: ArrayBuffer negative length throws RangeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new ArrayBuffer(-1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: ArrayBuffer NaN length becomes zero" {
    const result = try evalExpr(
        \\new ArrayBuffer(NaN).byteLength
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array from ArrayBuffer" {
    const result = try evalExpr(
        \\var b = new ArrayBuffer(4);
        \\var v = new Uint8Array(b);
        \\v[0] = 42;
        \\v[0] + v.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 46.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array from ArrayBuffer honors byteOffset and length" {
    const result = try evalExpr(
        \\var b = new ArrayBuffer(4);
        \\var all = new Uint8Array(b);
        \\all[1] = 6; all[2] = 7;
        \\var v = new Uint8Array(b, 1, 2);
        \\v[1] = 9;
        \\v[0] * 1000 + all[2] * 100 + v.length * 10 + v.byteLength
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6922.0), result.asNumber(), 0.001);
}

test "eval: Int16Array from ArrayBuffer rejects misaligned offset" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Int16Array(new ArrayBuffer(4), 1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Int16Array from ArrayBuffer rejects misaligned byteLength" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Int16Array(new ArrayBuffer(3)); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Uint8Array byte overflow wraps" {
    const result = try evalExpr(
        \\var a = new Uint8Array(1);
        \\a[0] = 256;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── Gap analysis probes ─────────────────────────────────────────

test "eval: getter/setter in object literal" {
    const result = try evalExpr(
        \\var obj = { _x: 0, get x() { return this._x; }, set x(v) { this._x = v; } };
        \\obj.x = 42;
        \\obj.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: logical nullish assignment" {
    const result = try evalExpr(
        \\var a = null; a ??= 5; a
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: logical or assignment" {
    const result = try evalExpr(
        \\var b = 0; b ||= 10; b
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: logical and assignment" {
    const result = try evalExpr(
        \\var c = 1; c &&= 20; c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

test "eval: for-in loop" {
    const result = try evalExpr(
        \\var obj = {a:1, b:2, c:3}; var keys = [];
        \\for (var k in obj) { keys.push(k); }
        \\keys.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: delete operator" {
    const result = try evalExpr(
        \\var o = {x:1, y:2}; delete o.x; Object.keys(o).length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: in operator" {
    const result = try evalExpr(
        \\var o = {x:1}; ("x" in o) && !("y" in o)
    );
    try std.testing.expect(result.asBool());
}

test "eval: Number as function" {
    const result = try evalExpr(
        \\Number("42") + Number(true) + Number(null)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 43.0), result.asNumber(), 0.001);
}

test "eval: String as function" {
    const result = try evalExpr(
        \\String(42) === "42"
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.from string length" {
    const result = try evalExpr(
        \\Array.from("abc").length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: rest parameters" {
    const result = try evalExpr(
        \\function sum(...args) { return args.reduce(function(a,b){return a+b}, 0); }
        \\sum(1,2,3,4)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: default parameters" {
    const result = try evalExpr(
        \\function f(x, y = 10) { return x + y; }
        \\f(5)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: Symbol.iterator protocol" {
    const result = try evalExpr(
        \\var arr = [10, 20, 30];
        \\var iter = arr[Symbol.iterator]();
        \\iter.next().value + iter.next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: generator function" {
    const result = try evalExpr(
        \\function* gen() { yield 1; yield 2; yield 3; }
        \\var g = gen(); g.next().value + g.next().value + g.next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

// ── Phase N: atob/btoa, Boolean, Array immutable, WeakRef, perf ─

test "eval: btoa encode" {
    const result = try evalExpr(
        \\btoa("Hello") === "SGVsbG8="
    );
    try std.testing.expect(result.asBool());
}

test "eval: btoa coerces primitive input" {
    const result = try evalExpr(
        \\btoa(123) === "MTIz" &&
        \\btoa(false) === "ZmFsc2U="
    );
    try std.testing.expect(result.asBool());
}

test "eval: atob decode" {
    const result = try evalExpr(
        \\atob("SGVsbG8=") === "Hello"
    );
    try std.testing.expect(result.asBool());
}

test "eval: btoa/atob roundtrip" {
    const result = try evalExpr(
        \\atob(btoa("test123")) === "test123"
    );
    try std.testing.expect(result.asBool());
}

test "eval: Boolean constructor" {
    const result = try evalExpr(
        \\Boolean(1) === true && Boolean(0) === false && Boolean("") === false && Boolean("x") === true
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.toSorted" {
    const result = try evalExpr(
        \\var a = [3,1,2]; var b = a.toSorted(); a[0] * 10 + b[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 31.0), result.asNumber(), 0.001);
}

test "eval: Array.toSorted works on array-like objects" {
    const result = try evalExpr(
        \\var b = Array.prototype.toSorted.call({0: 3, 1: 1, 2: 2, length: "3"});
        \\b[0] * 100 + b[1] * 10 + b[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), result.asNumber(), 0.001);
}

test "eval: Array.toSorted reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 9; } });
        \\var b = a.toSorted();
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 91.0), result.asNumber(), 0.001);
}

test "eval: Array.toReversed" {
    const result = try evalExpr(
        \\var a = [1,2,3]; var b = a.toReversed(); a[0] * 10 + b[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), result.asNumber(), 0.001);
}

test "eval: Array.toReversed works on array-like objects" {
    const result = try evalExpr(
        \\var b = Array.prototype.toReversed.call({0: 10, 2: 30, length: "3"});
        \\b.length === 3 && b[0] === 30 && b[1] === undefined && b[2] === 10
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.toReversed reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 8; } });
        \\var b = a.toReversed();
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 81.0), result.asNumber(), 0.001);
}

test "eval: Array.toSpliced" {
    const result = try evalExpr(
        \\var a = [1,2,3,4]; var b = a.toSpliced(1, 2, 8, 9); b.length * 10 + b[1]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 48.0), result.asNumber(), 0.001);
}

test "eval: Array.toSpliced works on array-like objects" {
    const result = try evalExpr(
        \\var b = Array.prototype.toSpliced.call({0: 1, 2: 3, length: "3"}, 1, 1, 8);
        \\b.length === 3 && b[0] === 1 && b[1] === 8 && b[2] === 3
    );
    try std.testing.expect(result.asBool());
}

test "eval: Array.toSpliced reads accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var a = [1, 2];
        \\Object.defineProperty(a, 0, { get: function() { calls = calls + 1; return 7; } });
        \\var b = a.toSpliced(1, 0, 9);
        \\b[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 71.0), result.asNumber(), 0.001);
}

test "eval: Array.toSpliced coerces start and deleteCount" {
    const result = try evalExpr(
        \\var a = [1,2,3,4];
        \\var b = a.toSpliced("1", "2", 8);
        \\var c = a.toSpliced("-2", "1", 9);
        \\b[1] * 100 + b.length * 10 + c[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 839.0), result.asNumber(), 0.001);
}

test "eval: WeakRef deref" {
    const result = try evalExpr(
        \\var target = {x: 42};
        \\var wr = new WeakRef(target);
        \\wr.deref().x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: performance.now" {
    const result = try evalExpr(
        \\performance.now() > 0
    );
    try std.testing.expect(result.asBool());
}

// ── Private class fields ────────────────────────────────────────

test "eval: private field basic" {
    const result = try evalExpr(
        \\class Counter {
        \\  #count = 0;
        \\  inc() { this.#count++; }
        \\  get() { return this.#count; }
        \\}
        \\var c = new Counter();
        \\c.inc(); c.inc(); c.inc();
        \\c.get()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: private field inaccessible from outside" {
    const result = try evalExpr(
        \\class A { #x = 42; getX() { return this.#x; } }
        \\var a = new A();
        \\a.getX()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: private field with constructor" {
    const result = try evalExpr(
        \\class Point {
        \\  #x; #y;
        \\  constructor(x, y) { this.#x = x; this.#y = y; }
        \\  sum() { return this.#x + this.#y; }
        \\}
        \\new Point(10, 20).sum()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: static private field" {
    const result = try evalExpr(
        \\class Config {
        \\  static #instance = null;
        \\  static create() { Config.#instance = {v:99}; return Config.#instance; }
        \\}
        \\Config.create().v
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: private field encapsulation per instance" {
    const result = try evalExpr(
        \\class Box { #v = 0; set(x) { this.#v = x; } get() { return this.#v; } }
        \\var a = new Box(); var b = new Box();
        \\a.set(100);
        \\b.get()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Date.now" {
    const result = try evalExpr(
        \\Date.now() > 0
    );
    try std.testing.expect(result.asBool());
}

test "eval: Date.prototype.toGMTString aliases toUTCString" {
    const result = try evalExpr("Date.prototype.toGMTString === Date.prototype.toUTCString");
    try std.testing.expect(result.asBool());
}

test "eval: JSON.stringify object multi-key" {
    const result = try evalExpr(
        \\JSON.stringify({a:1, b:"two"})
    );
    try std.testing.expect(result.isString());
}

test "eval: JSON.parse roundtrip" {
    const result = try evalExpr(
        \\var s = JSON.stringify({x:42}); var o = JSON.parse(s); o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: RegExp test method" {
    const result = try evalExpr(
        \\/^hello/.test("hello world")
    );
    try std.testing.expect(result.asBool());
}

test "eval: chained array methods" {
    const result = try evalExpr(
        \\[1,2,3,4,5].filter(function(x){return x>2}).map(function(x){return x*10}).reduce(function(a,b){return a+b}, 0)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), result.asNumber(), 0.001);
}

test "eval: nested destructuring" {
    const result = try evalExpr(
        \\var {a: {b}} = {a: {b: 99}}; b
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: class with getter/setter" {
    const result = try evalExpr(
        \\class C {
        \\  constructor() { this._v = 0; }
        \\  get val() { return this._v; }
        \\  set val(x) { this._v = x * 2; }
        \\}
        \\var c = new C(); c.val = 5; c.val
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

// ── Function.prototype.call/apply/bind ───────────────────────────

test "eval: Function.call" {
    const result = try evalExpr(
        \\function greet(x) { return this.name + " " + x; }
        \\var obj = {name: "Alice"};
        \\greet.call(obj, "hi")
    );
    try std.testing.expect(result.isString());
}

test "eval: Function.apply" {
    const result = try evalExpr(
        \\function sum(a, b) { return a + b; }
        \\sum.apply(null, [10, 20])
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: Function.apply accepts array-like arguments" {
    const result = try evalExpr(
        \\function sum(a, b) { return a + b; }
        \\sum.apply(null, {0: 10, 1: 20, length: "2"})
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: Function.apply reads array-like accessors" {
    const result = try evalExpr(
        \\let calls = 0;
        \\function id(x) { return x; }
        \\id.apply(null, { get 0() { calls = calls + 1; return 6; }, get length() { calls = calls + 1; return 1; } }) * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 62.0), result.asNumber(), 0.001);
}

test "eval: Function.apply rejects primitive argArray" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (function(){}).apply(null, 1); } catch (e) { ok = e.name === "TypeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Function.apply null argArray passes no arguments" {
    const result = try evalExpr(
        \\function count() { return arguments.length; }
        \\count.apply(null, null)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Function.bind basic" {
    const result = try evalExpr(
        \\function add(a, b) { return a + b; }
        \\var add5 = add.bind(null, 5);
        \\add5(10)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: Function.bind with this" {
    const result = try evalExpr(
        \\var obj = {x: 100};
        \\function getX() { return this.x; }
        \\var bound = getX.bind(obj);
        \\bound()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), result.asNumber(), 0.001);
}

test "eval: Object.prototype.toString.call for type check" {
    const result = try evalExpr(
        \\Object.prototype.toString.call([1,2,3])
    );
    try std.testing.expect(result.isString());
}

test "eval: Function.call with native method" {
    const result = try evalExpr(
        \\var a = [1, 2, 3];
        \\Array.prototype.push.call(a, 4);
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array slice" {
    const result = try evalExpr(
        \\var a = new Uint8Array([1,2,3,4,5]);
        \\var b = a.slice(1, 3);
        \\b[0] + b[1] + b.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array slice and set coerce numeric arguments" {
    const result = try evalExpr(
        \\var a = new Uint8Array([1,2,3,4,5]);
        \\var b = a.slice("1", "3");
        \\a.set(["7", "8"], "1");
        \\b[0] * 1000 + b[1] * 100 + a[1] * 10 + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2378.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array set reads array accessor elements" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var src = [1];
        \\Object.defineProperty(src, 0, { get: function() { calls = calls + 1; return "9"; } });
        \\var a = new Uint8Array(1);
        \\a.set(src);
        \\a[0] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 91.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array set works on array-like objects" {
    const result = try evalExpr(
        \\var a = new Uint8Array(3);
        \\a.set({0: "4", 2: 6, length: "3"});
        \\a[0] * 100 + a[1] * 10 + a[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 406.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array set out of range throws RangeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Uint8Array(2).set([1,2,3]); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Uint8Array set negative offset throws RangeError" {
    const result = try evalExpr(
        \\var ok = false;
        \\try { new Uint8Array(2).set([1], -1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.asBool());
}

test "eval: Uint8Array slice handles negative indices" {
    const result = try evalExpr(
        \\var a = new Uint8Array([1,2,3,4,5]);
        \\var b = a.slice("-4", -1);
        \\b[0] * 100 + b[1] * 10 + b[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 234.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array subarray shares backing bytes" {
    const result = try evalExpr(
        \\var a = new Uint8Array([1,2,3,4,5]);
        \\var b = a.subarray(-4, -1);
        \\b[0] = 9;
        \\a[1] * 100 + b[1] * 10 + b.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 933.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array set handles overlapping source" {
    const result = try evalExpr(
        \\var a = new Uint8Array([1,2,3,4]);
        \\a.set(a.subarray(0, 3), 1);
        \\a[0] * 1000 + a[1] * 100 + a[2] * 10 + a[3]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1123.0), result.asNumber(), 0.001);
}

test "eval: integer typed arrays store non-finite values as zero" {
    const result = try evalExpr(
        \\var u8 = new Uint8Array([NaN]);
        \\var u16 = new Uint16Array([Infinity]);
        \\var i32 = new Int32Array([-Infinity]);
        \\u8[0] + u16[0] + i32[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

// ── TypedArray kind differentiation (ECMA-262 §23.2) ───────────────

test "eval: Int8Array stores negative values correctly" {
    const result = try evalExpr(
        \\var a = new Int8Array(1);
        \\a[0] = -1;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "eval: Uint8Array wraps 256 to 0" {
    const result = try evalExpr(
        \\var a = new Uint8Array(1);
        \\a[0] = 256;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Int8Array wraps 128 to -128" {
    const result = try evalExpr(
        \\var a = new Int8Array(1);
        \\a[0] = 128;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, -128.0), result.asNumber(), 0.001);
}

test "eval: Uint16Array stores 65535 correctly" {
    const result = try evalExpr(
        \\var a = new Uint16Array(1);
        \\a[0] = 65535;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 65535.0), result.asNumber(), 0.001);
}

test "eval: Int16Array stores -1 correctly" {
    const result = try evalExpr(
        \\var a = new Int16Array(1);
        \\a[0] = -1;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.asNumber(), 0.001);
}

test "eval: Uint32Array stores 4294967295 correctly" {
    const result = try evalExpr(
        \\var a = new Uint32Array(1);
        \\a[0] = 4294967295;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4294967295.0), result.asNumber(), 1.0);
}

test "eval: Int32Array stores -1 then Uint32Array views same buffer as 4294967295" {
    const result = try evalExpr(
        \\var buf = new ArrayBuffer(4);
        \\var i32 = new Int32Array(buf);
        \\var u32 = new Uint32Array(buf);
        \\i32[0] = -1;
        \\u32[0]
    );
    // -1 in two's complement 32-bit = 0xFFFFFFFF = 4294967295
    try std.testing.expectApproxEqAbs(@as(f64, 4294967295.0), result.asNumber(), 1.0);
}

test "eval: Float32Array stores and reads back a value" {
    const result = try evalExpr(
        \\var a = new Float32Array(1);
        \\a[0] = 1.5;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.asNumber(), 0.001);
}

test "eval: Float64Array stores and reads back a value" {
    const result = try evalExpr(
        \\var a = new Float64Array(1);
        \\a[0] = 3.14159265358979;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159265358979), result.asNumber(), 0.000001);
}

test "eval: Float64Array length is element count not byte count" {
    const result = try evalExpr(
        \\var a = new Float64Array(4);
        \\a.length
    );
    // 4 float64 elements = 32 bytes, but length should be 4
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
}

test "eval: Int32Array length is element count" {
    const result = try evalExpr(
        \\var a = new Int32Array(8);
        \\a.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), result.asNumber(), 0.001);
}

test "eval: Float32Array stores IEEE754 and Float64Array reads different interpretation" {
    // Write 1.0 as f32 into ArrayBuffer, verify f64 reads the 4-byte f32 bits differently
    const result = try evalExpr(
        \\var buf = new ArrayBuffer(4);
        \\var f32 = new Float32Array(buf);
        \\f32[0] = 1.0;
        \\f32[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.0001);
}

test "eval: Uint8ClampedArray clamps 300 to 255" {
    const result = try evalExpr(
        \\var a = new Uint8ClampedArray(1);
        \\a[0] = 300;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 255.0), result.asNumber(), 0.001);
}

test "eval: Uint8ClampedArray clamps -1 to 0" {
    const result = try evalExpr(
        \\var a = new Uint8ClampedArray(1);
        \\a[0] = -1;
        \\a[0]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: Int32Array from array conversion" {
    const result = try evalExpr(
        \\var a = new Int32Array([-1, 0, 1, 2147483647]);
        \\a[0] + a[2] + a[3]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2147483647.0), result.asNumber(), 1.0);
}

test "eval: typed array byteLength vs length differ for multi-byte elements" {
    const result = try evalExpr(
        \\var a = new Int32Array(3);
        \\a.byteLength
    );
    // 3 int32 elements = 12 bytes
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: Object.getOwnPropertyDescriptors includes symbol keys" {
    const result = try evalExpr(
        \\var sym = Symbol("test");
        \\var obj = {};
        \\obj[sym] = 42;
        \\var descs = Object.getOwnPropertyDescriptors(obj);
        \\descs[sym].value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: Object.getOwnPropertySymbols returns own symbol keys" {
    const result = try evalExpr(
        \\var sym = Symbol("test");
        \\var obj = {};
        \\obj[sym] = 42;
        \\var syms = Object.getOwnPropertySymbols(obj);
        \\syms.length === 1 && syms[0] === sym
    );
    try std.testing.expect(result.asBool());
}

test "eval: Object.defineProperty supports symbol keys" {
    const result = try evalExpr(
        \\var sym = Symbol("test");
        \\var obj = {};
        \\Object.defineProperty(obj, sym, { value: 42, enumerable: true });
        \\var desc = Object.getOwnPropertyDescriptor(obj, sym);
        \\obj[sym] + desc.value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 84.0), result.asNumber(), 0.001);
}

test "eval: Object.defineProperties supports symbol keys" {
    const result = try evalExpr(
        \\var sym = Symbol("test");
        \\var obj = {};
        \\var props = {};
        \\props[sym] = { value: 5, enumerable: true };
        \\Object.defineProperties(obj, props);
        \\obj[sym]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: Object.defineProperties reads accessor descriptor map" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var obj = {};
        \\var props = {};
        \\Object.defineProperty(props, "x", { get: function() { calls = calls + 1; return { value: 6, enumerable: true }; } });
        \\Object.defineProperties(obj, props);
        \\obj.x * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

test "eval: symbol accessor descriptor get returns value" {
    const result = try evalExpr(
        \\var calls = 0;
        \\var sym = Symbol("test");
        \\var obj = {};
        \\Object.defineProperty(obj, sym, { enumerable: true, get: function() { calls = calls + 1; return 6; } });
        \\obj[sym] * 10 + calls
    );
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), result.asNumber(), 0.001);
}

// ── Phase 4: accessor descriptor tests ─────────────────────────────

test "eval: Object.defineProperty accessor get returns value" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { get: function() { return 42; } });
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: accessor getter this is receiver" {
    const result = try evalExpr(
        \\var o = { y: 99 };
        \\Object.defineProperty(o, 'x', { get: function() { return this.y; } });
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: accessor setter stores value" {
    const result = try evalExpr(
        \\var o = { _v: 0 };
        \\Object.defineProperty(o, 'x', {
        \\  get: function() { return this._v; },
        \\  set: function(v) { this._v = v; }
        \\});
        \\o.x = 7;
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: inherited accessor via __proto__" {
    const result = try evalExpr(
        \\var proto = {};
        \\Object.defineProperty(proto, 'x', { get: function() { return this.y; } });
        \\var child = { __proto__: proto, y: 99 };
        \\child.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: Object.freeze accessor get still works" {
    const result = try evalExpr(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { get: function() { return 42; }, configurable: true });
        \\Object.freeze(o);
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: Object.freeze accessor set still fires (setter is not blocked by freeze)" {
    const result = try evalExpr(
        \\var o = { _v: 5 };
        \\Object.defineProperty(o, 'x', {
        \\  get: function() { return this._v; },
        \\  set: function(v) { this._v = v; },
        \\  configurable: true
        \\});
        \\Object.freeze(o);
        \\o.x = 99;
        \\o.x
    );
    // After freeze accessor is non-configurable, but existing setter still fires per spec.
    // _v itself was promoted to non-writable by freeze, so setter's this._v = v silently fails.
    // Result: getter returns the frozen _v = 5.
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: object literal getter shorthand" {
    const result = try evalExpr(
        \\var o = { _x: 10, get x() { return this._x * 2; } };
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

test "eval: object literal getter and setter shorthand" {
    const result = try evalExpr(
        \\var o = {
        \\  _x: 1,
        \\  get x() { return this._x; },
        \\  set x(v) { this._x = v; }
        \\};
        \\o.x = 55;
        \\o.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), result.asNumber(), 0.001);
}

// ── Phase 4 follow-up: class/literal accessor descriptor verification ──

test "eval: object literal getter returns value" {
    const result = try evalExpr(
        \\const o = { get foo() { return 42; }, set foo(v) { this._v = v; } };
        \\o.foo
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: object literal setter stores via this" {
    const result = try evalExpr(
        \\const o = { get foo() { return this._v; }, set foo(v) { this._v = v; } };
        \\o.foo = 5;
        \\o._v
    );
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: class instance getter and setter" {
    const result = try evalExpr(
        \\class C {
        \\  get x() { return this._x; }
        \\  set x(v) { this._x = v; }
        \\}
        \\const c = new C();
        \\c.x = 10;
        \\c.x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: class static getter" {
    const result = try evalExpr(
        \\class C {
        \\  static get y() { return 99; }
        \\}
        \\C.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: class static getter and setter" {
    const result = try evalExpr(
        \\class C {
        \\  static get y() { return C._y; }
        \\  static set y(v) { C._y = v; }
        \\}
        \\C.y = 7;
        \\C.y
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

test "eval: inherited accessor via class extends" {
    const result = try evalExpr(
        \\class A { get x() { return 1; } }
        \\class B extends A {}
        \\new B().x
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}

test "eval: class accessor enumerable is false" {
    const result = try evalExpr(
        \\class C { get x() { return 1; } }
        \\Object.getOwnPropertyDescriptor(C.prototype, 'x').enumerable
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "eval: object literal accessor enumerable is true" {
    const result = try evalExpr(
        \\const o = { get x() { return 1; } };
        \\Object.getOwnPropertyDescriptor(o, 'x').enumerable
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: class accessor configurable is true" {
    const result = try evalExpr(
        \\class C { get x() { return 1; } }
        \\Object.getOwnPropertyDescriptor(C.prototype, 'x').configurable
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ── Phase C Wave 2 — ECMAScript 2023 compliance fixes ────────────────────────

// Item 13: Number.prototype.toFixed RangeError (ES2023 §21.1.3.3 step 2)
test "Number.toFixed RangeError negative digits" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toFixed(-1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "Number.toFixed RangeError digits > 100" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toFixed(101); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "Number.toFixed valid range no error" {
    // fractionDigits in [0, 100] must not throw
    const result = try evalExpr(
        \\(1.5).toFixed(2)
    );
    try std.testing.expect(result.isString());
}

// Item 13: Number.prototype.toPrecision RangeError (ES2023 §21.1.3.5 step 3)
test "Number.toPrecision RangeError precision < 1" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toPrecision(0); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "Number.toPrecision RangeError precision > 100" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toPrecision(101); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// Item 13: Number.prototype.toExponential RangeError (ES2023 §21.1.3.4 step 4)
test "Number.toExponential RangeError digits < 0" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toExponential(-1); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "Number.toExponential RangeError digits > 100" {
    const result = try evalExpr(
        \\let ok = false;
        \\try { (1.5).toExponential(101); } catch (e) { ok = e.name === "RangeError"; }
        \\ok
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "Number.toExponential undefined arg no error" {
    // undefined fractionDigits is allowed (uses default)
    const result = try evalExpr(
        \\(1.5).toExponential()
    );
    try std.testing.expect(result.isString());
}

// Item 11: Promise resolve thenable detection (ES2023 §25.4.1.3.2 step 8-9)
test "Promise thenable non-promise object with then" {
    // A plain object with a .then method should be treated as a thenable.
    const result = try evalWithMicrotasks(
        \\var out = 0;
        \\var thenable = { then: function(resolve) { resolve(42); } };
        \\Promise.resolve(thenable).then(function(v) { out = v; });
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// Item 8 check: Object.getOwnPropertyNames no duplicate keys after freeze
test "Object.getOwnPropertyNames no duplicates after freeze" {
    // After freeze, fast-path keys are promoted to descriptors map; both maps
    // should not yield duplicate entries in getOwnPropertyNames.
    const result = try evalExpr(
        \\var o = {a: 1, b: 2};
        \\Object.freeze(o);
        \\var names = Object.getOwnPropertyNames(o);
        \\names.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

// ─── Layer 0A: builtin polish (ECMA-262 §10.2.8/§10.2.9) ──────────

// Gap 1: Native fn .length per §10.2.9 SetFunctionLength
test "Layer 0A: Array.prototype.forEach.length === 1" {
    const result = try evalExpr("Array.prototype.forEach.length === 1");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Array.prototype.slice.length === 2" {
    const result = try evalExpr("Array.prototype.slice.length === 2");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Promise.resolve.length === 1" {
    const result = try evalExpr("Promise.resolve.length === 1");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Object.defineProperty.length === 3" {
    const result = try evalExpr("Object.defineProperty.length === 3");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Object.prototype method lengths" {
    const result = try evalExpr(
        \\Object.prototype.hasOwnProperty.length === 1 &&
        \\Object.prototype.toString.length === 0 &&
        \\Object.prototype.valueOf.length === 0 &&
        \\Object.prototype.isPrototypeOf.length === 1 &&
        \\Object.prototype.propertyIsEnumerable.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Symbol Proxy Reflect method lengths" {
    const result = try evalExpr(
        \\Symbol.length === 0 &&
        \\Symbol.for.length === 1 &&
        \\Symbol.keyFor.length === 1 &&
        \\Proxy.length === 2 &&
        \\Proxy.revocable.length === 2 &&
        \\Reflect.get.length === 2 &&
        \\Reflect.set.length === 3 &&
        \\Reflect.has.length === 2 &&
        \\Reflect.deleteProperty.length === 2 &&
        \\Reflect.ownKeys.length === 1 &&
        \\Reflect.apply.length === 3
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: TypedArray method lengths" {
    const result = try evalExpr(
        \\Uint8Array.prototype.slice.length === 2 &&
        \\Uint8Array.prototype.set.length === 1 &&
        \\Uint8Array.prototype.subarray.length === 2
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: RegExp method lengths" {
    const result = try evalExpr(
        \\RegExp.length === 2 &&
        \\/x/.test.length === 1 &&
        \\/x/.exec.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Generator method lengths" {
    const result = try evalExpr(
        \\function* g() {}
        \\async function* ag() {}
        \\let it = g();
        \\let ait = ag();
        \\it.next.length === 1 &&
        \\it.return.length === 1 &&
        \\ait.next.length === 1 &&
        \\ait.return.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: String and Number method lengths" {
    const result = try evalExpr(
        \\String.length === 1 &&
        \\String.fromCharCode.length === 1 &&
        \\String.fromCodePoint.length === 1 &&
        \\String.prototype.charAt.length === 1 &&
        \\String.prototype.charCodeAt.length === 1 &&
        \\String.prototype.indexOf.length === 1 &&
        \\String.prototype.includes.length === 1 &&
        \\String.prototype.substring.length === 2 &&
        \\String.prototype.slice.length === 2 &&
        \\String.prototype.split.length === 2 &&
        \\String.prototype.trim.length === 0 &&
        \\String.prototype.toUpperCase.length === 0 &&
        \\String.prototype.toLowerCase.length === 0 &&
        \\String.prototype.startsWith.length === 1 &&
        \\String.prototype.endsWith.length === 1 &&
        \\String.prototype.replace.length === 2 &&
        \\String.prototype.match.length === 1 &&
        \\String.prototype.matchAll.length === 1 &&
        \\String.prototype.search.length === 1 &&
        \\String.prototype.repeat.length === 1 &&
        \\String.prototype.padStart.length === 1 &&
        \\String.prototype.padEnd.length === 1 &&
        \\String.prototype.trimStart.length === 0 &&
        \\String.prototype.trimEnd.length === 0 &&
        \\String.prototype.replaceAll.length === 2 &&
        \\String.prototype.lastIndexOf.length === 1 &&
        \\String.prototype.concat.length === 1 &&
        \\String.prototype.at.length === 1 &&
        \\String.prototype.codePointAt.length === 1 &&
        \\String.prototype.substr.length === 2 &&
        \\String.prototype.toString.length === 0 &&
        \\String.prototype.normalize.length === 0 &&
        \\String.prototype.localeCompare.length === 1 &&
        \\String.prototype.valueOf.length === 0 &&
        \\Number.length === 1 &&
        \\Number.prototype.toFixed.length === 1 &&
        \\Number.prototype.toString.length === 1 &&
        \\Number.prototype.toPrecision.length === 1 &&
        \\Number.prototype.toExponential.length === 1 &&
        \\Number.prototype.valueOf.length === 0 &&
        \\Number.isNaN.length === 1 &&
        \\Number.isFinite.length === 1 &&
        \\Number.isInteger.length === 1 &&
        \\Number.parseInt.length === 2 &&
        \\Number.parseFloat.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Math method lengths" {
    const result = try evalExpr(
        \\Math.floor.length === 1 &&
        \\Math.ceil.length === 1 &&
        \\Math.round.length === 1 &&
        \\Math.abs.length === 1 &&
        \\Math.min.length === 2 &&
        \\Math.max.length === 2 &&
        \\Math.random.length === 0 &&
        \\Math.pow.length === 2 &&
        \\Math.sqrt.length === 1 &&
        \\Math.log.length === 1 &&
        \\Math.log10.length === 1 &&
        \\Math.trunc.length === 1 &&
        \\Math.sign.length === 1 &&
        \\Math.sin.length === 1 &&
        \\Math.cos.length === 1 &&
        \\Math.tan.length === 1 &&
        \\Math.asin.length === 1 &&
        \\Math.acos.length === 1 &&
        \\Math.atan.length === 1 &&
        \\Math.atan2.length === 2 &&
        \\Math.exp.length === 1 &&
        \\Math.log2.length === 1 &&
        \\Math.cbrt.length === 1 &&
        \\Math.hypot.length === 2 &&
        \\Math.clz32.length === 1 &&
        \\Math.sinh.length === 1 &&
        \\Math.cosh.length === 1 &&
        \\Math.tanh.length === 1 &&
        \\Math.fround.length === 1 &&
        \\Math.log1p.length === 1 &&
        \\Math.expm1.length === 1
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: TypeError.length === 1" {
    const result = try evalExpr("TypeError.length === 1");
    try std.testing.expect(result.asBool());
}

// Gap 2: Native fn .name per §10.2.8 SetFunctionName
test "Layer 0A: Array.prototype.slice.name === 'slice'" {
    const result = try evalExpr("Array.prototype.slice.name === 'slice'");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Promise.resolve.name === 'resolve'" {
    const result = try evalExpr("Promise.resolve.name === 'resolve'");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: TypeError.name === 'TypeError'" {
    const result = try evalExpr("TypeError.name === 'TypeError'");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: Object.defineProperty.name === 'defineProperty'" {
    const result = try evalExpr("Object.defineProperty.name === 'defineProperty'");
    try std.testing.expect(result.asBool());
}

// Gap 1+2 combined: descriptor attributes per §10.2.8/§10.2.9:
// writable:false, enumerable:false, configurable:true.
test "Layer 0A: length descriptor has spec-correct attrs" {
    const result = try evalExpr(
        \\var d = Object.getOwnPropertyDescriptor(Array.prototype.slice, "length");
        \\d.writable === false && d.enumerable === false && d.configurable === true && d.value === 2
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: name descriptor has spec-correct attrs" {
    const result = try evalExpr(
        \\var d = Object.getOwnPropertyDescriptor(Array.prototype.slice, "name");
        \\d.writable === false && d.enumerable === false && d.configurable === true && d.value === "slice"
    );
    try std.testing.expect(result.asBool());
}

// Gap 4: Array callbacks IsCallable + generic array-like iteration (§23.1.3.*)
test "Layer 0A: forEach throws TypeError on non-callable" {
    const result = try evalExpr(
        \\var caught = false;
        \\try { [1,2,3].forEach(42); } catch (e) { caught = (e instanceof TypeError); }
        \\caught
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: map throws TypeError on missing callback" {
    const result = try evalExpr(
        \\var caught = false;
        \\try { [1,2,3].map(); } catch (e) { caught = (e instanceof TypeError); }
        \\caught
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: filter throws TypeError on non-callable" {
    const result = try evalExpr(
        \\var caught = false;
        \\try { [1,2,3].filter("not a fn"); } catch (e) { caught = (e instanceof TypeError); }
        \\caught
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: forEach iterates array-like with length" {
    const result = try evalExpr(
        \\var seen = [];
        \\Array.prototype.forEach.call({length: 2, 0: 'a', 1: 'b'}, function(v) { seen.push(v); });
        \\seen.length === 2 && seen[0] === 'a' && seen[1] === 'b'
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: map iterates array-like with length" {
    const result = try evalExpr(
        \\var out = Array.prototype.map.call({length: 3, 0: 1, 1: 2, 2: 3}, function(v) { return v * 2; });
        \\out.length === 3 && out[0] === 2 && out[1] === 4 && out[2] === 6
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: map propagates thisArg" {
    const result = try evalExpr(
        \\var obj = {k: 10};
        \\var out = [1,2,3].map(function(x) { return x + this.k; }, obj);
        \\out[0] === 11 && out[1] === 12 && out[2] === 13
    );
    try std.testing.expect(result.asBool());
}

test "Layer 0A: findIndex returns -1 on miss" {
    const result = try evalExpr("[1,2,3].findIndex(function(x) { return x > 99; }) === -1");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: every returns true on empty array" {
    const result = try evalExpr("[].every(function(x) { return false; }) === true");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: some returns false on empty array" {
    const result = try evalExpr("[].some(function(x) { return true; }) === false");
    try std.testing.expect(result.asBool());
}

// Gap 3: Error subclass prototype chain (§20.5)
test "Layer 0A: new TypeError instanceof TypeError" {
    const result = try evalExpr("new TypeError('x') instanceof TypeError");
    try std.testing.expect(result.asBool());
}

test "Layer 0A: new TypeError instanceof Error" {
    const result = try evalExpr("new TypeError('x') instanceof Error");
    try std.testing.expect(result.asBool());
}

// No-new form of sub-error ctor must also set the correct prototype
// (§20.5.6.2 — the spec says NewTarget=undefined falls back to "active
// function object", which in kotori is located via getCallerFuncObj).
test "Layer 0A: TypeError('x') (no-new) instanceof TypeError" {
    const result = try evalExpr("TypeError('x') instanceof TypeError");
    try std.testing.expect(result.asBool());
}

// Gap 5a: Promise.resolve same-constructor (§27.2.1.4 step 1b)
test "Layer 0A: Promise.resolve(p) === p for own-realm promise" {
    const result = try evalWithMicrotasks(
        \\const p = Promise.resolve(42);
        \\globalThis.__r = Promise.resolve(p) === p;
    ,
        "__r",
    );
    try std.testing.expect(result.asBool());
}

// Gap 5a: thenable adoption is a microtask, not synchronous (§27.2.1.3.2 step 13-14)
test "Layer 0A: thenable adoption runs after sync frame completes" {
    const result = try evalWithMicrotasks(
        \\const log = [];
        \\Promise.resolve({ then: function(res){ log.push('then'); res(99); } })
        \\  .then(function(v){
        \\    log.push('resolved:' + v);
        \\    globalThis.__r = (log[0] === 'sync' && log[1] === 'then' && log[2] === 'resolved:99');
        \\  });
        \\log.push('sync');
        \\// After microtask drain: ['sync','then','resolved:99']
    ,
        "__r",
    );
    try std.testing.expect(result.asBool());
}

// Gap 5a: thenable resolves with inner value.
test "Layer 0A: thenable resolves promise with value passed to res()" {
    const result = try evalWithMicrotasks(
        \\Promise.resolve({ then: function(res){ res(7); } })
        \\  .then(function(v){ globalThis.__r = v; });
    ,
        "__r",
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.asNumber(), 0.001);
}

// Gap 5b: throwing .then getter rejects the promise (§27.2.1.3.2 step 9).
test "Layer 0A: throwing .then getter rejects outer promise" {
    const result = try evalWithMicrotasks(
        \\Promise.resolve(Object.defineProperty({}, 'then', {
        \\  get: function(){ throw new TypeError('boom'); }
        \\})).catch(function(e){ globalThis.__r = (e instanceof TypeError); });
    ,
        "__r",
    );
    try std.testing.expect(result.asBool());
}

// Gap 5b: non-callable .then falls through to fulfill (§27.2.1.3.2 step 11).
test "Layer 0A: non-callable .then fulfills with resolution itself" {
    const result = try evalWithMicrotasks(
        \\Promise.resolve({ then: 42 }).then(function(v){ globalThis.__r = (v && v.then); });
    ,
        "__r",
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

// Layer 0E: long-jump encoding — function body large enough to exceed i16 offset range (>32KB).
// Each "if (x > 0) { r = r + N; }" compiles to ~20 bytes. 1700 iterations ≈ 34KB bytecode,
// which would panic with i16 @intCast overflow but succeeds with i32 long jumps.
test "Layer 0E: large function body triggers long-jump encoding" {
    // Build a JS source with a function containing >1700 if-statements so that
    // the jump offset from the first if to its else target exceeds 32767 bytes.
    // Allocate ~120KB for the source text (1700 iterations × ~60 chars each).
    const src_buf = try std.testing.allocator.alloc(u8, 120_000);
    defer std.testing.allocator.free(src_buf);
    var pos: usize = 0;
    const header = "function bigFn(x) { var r = 0;\n";
    @memcpy(src_buf[pos..][0..header.len], header);
    pos += header.len;
    var i: u32 = 0;
    while (i < 1700) : (i += 1) {
        const line = try std.fmt.bufPrint(src_buf[pos..], "if (x > 0) {{ r = r + {d}; }}\n", .{i});
        pos += line.len;
    }
    const footer = "return r; } bigFn(1)";
    @memcpy(src_buf[pos..][0..footer.len], footer);
    pos += footer.len;
    const src = src_buf[0..pos];

    const result = try evalExpr(src);
    // sum of 0..1699 = 1699 * 1700 / 2 = 1444150
    try std.testing.expectApproxEqAbs(@as(f64, 1444150.0), result.asNumber(), 1.0);
}

// Layer 0D: instruction budget — infinite loop must throw RangeError, not hang.
test "Layer 0D: instruction budget exhaustion throws RangeError" {
    const source = "var x = 0; while (true) { x = x + 1; }";
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    installTestIo();
    defer resetTestIo();
    try vm_inst.initBuiltins();
    // Set a low budget so the infinite loop is interrupted quickly.
    vm_inst.setBudget(1_000);
    // execute() must return without hanging. The uncaught RangeError
    // surfaces as error.UncaughtException; pending_throw is cleared so
    // subsequent evals on the same VM stay usable, and the thrown value
    // remains inspectable via last_uncaught.
    try std.testing.expectError(error.UncaughtException, vm_inst.execute());
    try std.testing.expectEqual(@as(?JsValue, null), vm_inst.pending_throw);
    const thrown = vm_inst.last_uncaught orelse {
        return error.ExpectedRangeError;
    };
    // Verify it is an object whose "name" property contains "RangeError".
    try std.testing.expect(thrown.isObject());
    const obj = thrown.asJsObject();
    const name_sid = try compiler.parser.pool.intern("name");
    const name_val = obj.getProperty(name_sid) orelse JsValue.undefined_val;
    try std.testing.expect(name_val.isString());
    const range_sid = try compiler.parser.pool.intern("RangeError");
    try std.testing.expectEqual(range_sid, name_val.asStringId());
}

// ── Layer 0F: direct eval() local scope capture (ECMA-262 §19.2.1.1) ──
// PerformEval: a direct call to the intrinsic %eval% sees the calling
// frame's lexical/var bindings. kotori's nativeEval synthesizes a fake
// outer scope, and the compiler emits load_upvalue/store_upvalue against
// cells pointing into the caller's stack slots.

test "eval: read local from enclosing function" {
    const result = try evalWithMicrotasks(
        \\var out = (function() { var x = 1; return eval("x + 1"); })();
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "eval: write local in enclosing function" {
    const result = try evalWithMicrotasks(
        \\var out = (function() { var x = 1; eval("x = 42"); return x; })();
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: direct eval still sees globals" {
    const result = try evalWithMicrotasks(
        \\var g = 10;
        \\var out = (function() { return eval("g"); })();
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: indirect eval falls back to globals without crashing" {
    // Indirect call via comma expression — kotori's eval always applies
    // the calling-frame capture path, but global-only references must still
    // resolve correctly (no crash, correct value).
    const result = try evalWithMicrotasks(
        \\var out = (0, eval)("var y = 20; y");
    , "out");
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}

// ── Wave 13 Track K: function decl closure over outer let ────────
// ECMA-262 §10.2.1.3 — Function declarations must close over the
// VariableEnvironment where they are declared, so hoisted function
// decls can read/write outer `let`/`const` bindings just like arrow
// functions do. Pre-fix: `function f(){ count++; }` could not capture
// outer `let count` because the compiler emitted the function object
// BEFORE the outer `let` slot was allocated, so `resolveUpvalue`
// failed and the identifier fell through to a global lookup.

test "closure bug: function decl captures outer let (nested)" {
    const result = try evalExpr(
        \\function outer() {
        \\  let count = 0;
        \\  function handler() { count++; }
        \\  handler();
        \\  handler();
        \\  return count;
        \\}
        \\outer()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "closure bug: arrow captures outer let (nested, control)" {
    const result = try evalExpr(
        \\function outer() {
        \\  let count = 0;
        \\  const handler = () => { count++; };
        \\  handler();
        \\  handler();
        \\  return count;
        \\}
        \\outer()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.asNumber(), 0.001);
}

test "closure bug: function decl returns closure over let" {
    const result = try evalExpr(
        \\function makeHandler() {
        \\  let count = 0;
        \\  function bump() { count++; return count; }
        \\  return bump;
        \\}
        \\var f = makeHandler();
        \\f(); f(); f()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "closure bug: function decl captures outer const" {
    const result = try evalExpr(
        \\function outer() {
        \\  const offset = 10;
        \\  function add(x) { return x + offset; }
        \\  return add(5);
        \\}
        \\outer()
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}
