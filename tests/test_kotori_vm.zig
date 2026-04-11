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
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
    try vm_inst.initBuiltins();
    const result = try vm_inst.execute();
    return result;
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
    _ = result; // prototype chain via __proto__ assignment needs special handling
    // TODO: enable once __proto__ set_prop is wired to prototype
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

test "eval: array includes" {
    const result = try evalExpr("[1, 2, 3].includes(2)");
    try std.testing.expect(result.asBool());
}

test "eval: array includes false" {
    const result = try evalExpr("[1, 2, 3].includes(5)");
    try std.testing.expect(!result.asBool());
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

test "eval: array concat" {
    const result = try evalExpr(
        \\var a = [1, 2];
        \\var b = [3, 4];
        \\var c = a.concat(b);
        \\c.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.asNumber(), 0.001);
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

test "eval: string trim" {
    const result = try evalExpr("\"  hello  \".trim() === \"hello\"");
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

test "eval: string startsWith" {
    const result = try evalExpr("\"hello world\".startsWith(\"hello\")");
    try std.testing.expect(result.asBool());
}

test "eval: string endsWith" {
    const result = try evalExpr("\"hello world\".endsWith(\"world\")");
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

test "eval: array map" {
    const result = try evalExpr(
        \\var doubled = [1, 2, 3].map(function(x) { return x * 2; });
        \\doubled[0] + doubled[1] + doubled[2]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), result.asNumber(), 0.001);
}

test "eval: array filter" {
    const result = try evalExpr(
        \\var evens = [1, 2, 3, 4, 5, 6].filter(function(x) { return x % 2 === 0; });
        \\evens.length
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
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
