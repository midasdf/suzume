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

/// Execute JS source, drain microtasks, and return a named global variable.
fn evalWithMicrotasks(source: []const u8, global_name: []const u8) !JsValue {
    var compiler = Compiler.init(std.testing.allocator, source);
    defer compiler.deinit();
    var bc = try compiler.compile();
    defer bc.deinit(std.testing.allocator);
    var vm_inst = VM.init(std.testing.allocator, &bc, compiler.parser.pool);
    defer vm_inst.deinit();
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

test "eval: Object.assign copies properties" {
    const result = try evalExpr(
        \\var target = { a: 1 };
        \\var source = { b: 2, c: 3 };
        \\Object.assign(target, source);
        \\target.a + target.b + target.c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
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

test "eval: Math.min" {
    const result = try evalExpr("Math.min(1, 5, 3)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
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

test "eval: isNaN true" {
    const result = try evalExpr("isNaN(0/0)");
    try std.testing.expect(result.asBool());
}

test "eval: isFinite number" {
    const result = try evalExpr("isFinite(42)");
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

test "eval: Map overwrite value" {
    const result = try evalExpr(
        \\var m = new Map();
        \\m.set("a", 1);
        \\m.set("a", 99);
        \\m.get("a")
    );
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
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

test "eval: regex char class" {
    const result = try evalExpr(
        \\var re = /[aeiou]/;
        \\re.test("hello")
    );
    try std.testing.expect(result.asBool());
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

test "array reduceRight" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3, 4].reduceRight(function(acc, x) { return acc + x; });
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
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

// ── Array.flat / flatMap ──

test "array flat" {
    const result = try evalWithMicrotasks(
        \\var result = [1, [2, 3], [4, [5]]].flat().length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "array flatMap" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].flatMap(function(x) { return [x, x * 2]; }).length;
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
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

test "array at negative index" {
    const result = try evalWithMicrotasks(
        \\var result = [1, 2, 3].at(-1);
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
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

test "array entries" {
    const result = try evalWithMicrotasks(
        \\var e = [10, 20].entries();
        \\var result = e[0][0] * 100 + e[0][1] * 10 + e[1][0];
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), result.asNumber(), 0.001);
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
