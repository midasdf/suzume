# kotori Builtins Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add missing JS builtins to kotori — instanceof/in operators, Error objects, Number.prototype, Date, Promise aggregation, and console expansion.

**Architecture:** All changes are additive to existing vm.zig + bytecode.zig + compiler.zig. New opcodes for instanceof/in, new obj_type `.date` for Date objects. Each feature is independent and testable in isolation.

**Tech Stack:** Zig, kotori VM (NaN-boxing stack VM), `@cImport` for `<time.h>` (Date only)

**Spec:** `docs/superpowers/specs/2026-04-12-kotori-builtins-design.md`

---

## Task 1: `instanceof` and `in` operators

**Files:**
- Modify: `src/js/kotori/bytecode.zig:9-106` (OpCode enum)
- Modify: `src/js/kotori/compiler.zig:1566-1589` (binaryOpToOpCode)
- Modify: `src/js/kotori/vm.zig:200-510` (run loop, add opcode handlers)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "instanceof with array" {
    const result = try evalExpr(
        \\var a = [1,2,3]; a instanceof Array;
    );
    try std.testing.expect(result.asBool() == true);
}

test "instanceof with non-instance" {
    const result = try evalExpr(
        \\var a = 42; a instanceof Array;
    );
    try std.testing.expect(result.asBool() == false);
}

test "instanceof with object" {
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

test "in operator missing property" {
    const result = try evalExpr(
        \\var obj = {a: 1}; "b" in obj;
    );
    try std.testing.expect(result.asBool() == false);
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: FAIL (instanceof compiles as add, returns wrong values)

- [ ] **Step 3: Add opcodes to bytecode.zig**

In `OpCode` enum, after `ushr,` (line 43) add:
```zig
    instanceof_,
    in_,
```

- [ ] **Step 4: Add compiler mapping**

In `binaryOpToOpCode` (compiler.zig:1566), change `else => .add,` to:
```zig
        .instanceof => .instanceof_,
        .in_ => .in_,
        else => .add,
```

- [ ] **Step 5: Add VM handlers**

In the run loop's opcode switch (vm.zig), add handlers:

```zig
.instanceof_ => {
    const rhs = self.pop(); // constructor
    const lhs = self.pop(); // instance
    if (!rhs.isObject()) {
        self.push(JsValue.initBool(false));
        continue;
    }
    const ctor = rhs.asJsObject();
    // Get constructor.prototype
    const proto_id = self.pool.intern("prototype") catch {
        self.push(JsValue.initBool(false));
        continue;
    };
    const target_proto_val = ctor.getProperty(proto_id);
    if (target_proto_val == null or !target_proto_val.?.isObject()) {
        self.push(JsValue.initBool(false));
        continue;
    }
    const target_proto = target_proto_val.?.asJsObject();
    // Walk prototype chain of lhs
    if (lhs.isObject()) {
        var cur: ?*JsObject = lhs.asJsObject().prototype;
        while (cur) |p| {
            if (p == target_proto) {
                self.push(JsValue.initBool(true));
                break;
            }
            cur = p.prototype;
        } else {
            self.push(JsValue.initBool(false));
        }
    } else {
        self.push(JsValue.initBool(false));
    }
},

.in_ => {
    const rhs = self.pop(); // object
    const lhs = self.pop(); // key
    if (!rhs.isObject()) {
        self.push(JsValue.initBool(false));
        continue;
    }
    const obj = rhs.asJsObject();
    if (lhs.isString()) {
        self.push(JsValue.initBool(obj.getProperty(lhs.asStringId()) != null));
    } else if (lhs.isInt()) {
        // Numeric index — check array bounds or string key
        var buf: [20]u8 = undefined;
        const key_str = std.fmt.bufPrint(&buf, "{d}", .{lhs.asInt()}) catch "";
        const key_id = self.pool.intern(key_str) catch {
            self.push(JsValue.initBool(false));
            continue;
        };
        self.push(JsValue.initBool(obj.getProperty(key_id) != null));
    } else {
        self.push(JsValue.initBool(false));
    }
},
```

- [ ] **Step 6: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
cd ~/suzume && git add src/js/kotori/bytecode.zig src/js/kotori/compiler.zig src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): instanceof and in operators — new opcodes + prototype chain walk"
```

---

## Task 2: Error objects

**Files:**
- Modify: `src/js/kotori/vm.zig` (initBuiltins section ~line 1143)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "Error constructor" {
    const result = try evalWithMicrotasks(
        \\var e = new Error("oops");
        \\var result = e.message;
    , "result");
    try std.testing.expect(result.isString());
}

test "Error name property" {
    const result = try evalWithMicrotasks(
        \\var e = new TypeError("bad type");
        \\var result = e.name;
    , "result");
    try std.testing.expect(result.isString());
}

test "Error instanceof" {
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
```

- [ ] **Step 2: Run tests, verify fail**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: FAIL

- [ ] **Step 3: Implement Error constructors in initBuiltins**

Add after the Promise section in `initBuiltins`:

```zig
// ── Error constructors ──
{
    // Error.prototype
    const error_proto = try self.createObj(.{});
    const name_sid = try self.pool.intern("name");
    const msg_sid = try self.pool.intern("message");
    const to_string_sid = try self.pool.intern("toString");
    try error_proto.setProperty(self.allocator, name_sid, JsValue.initString(try self.pool.intern("Error")));
    try error_proto.setProperty(self.allocator, msg_sid, JsValue.initString(try self.pool.intern("")));
    try self.registerNativeMethod(error_proto, "toString", &nativeErrorToString);

    // Error constructor (works with and without new)
    const error_ctor = try self.createNativeFn(&nativeErrorConstructor);
    try error_ctor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(error_proto));
    try self.globals.put(self.allocator, try self.pool.intern("Error"), JsValue.initObject(error_ctor));

    // Store error_proto for subclass creation
    self.error_proto = error_proto;

    // Sub-error types: TypeError, ReferenceError, SyntaxError, RangeError, URIError, EvalError
    const error_types = [_][]const u8{ "TypeError", "ReferenceError", "SyntaxError", "RangeError", "URIError", "EvalError" };
    for (error_types) |err_name| {
        const sub_proto = try self.createObj(.{});
        sub_proto.prototype = error_proto; // inherit from Error.prototype
        try sub_proto.setProperty(self.allocator, name_sid, JsValue.initString(try self.pool.intern(err_name)));
        try sub_proto.setProperty(self.allocator, msg_sid, JsValue.initString(try self.pool.intern("")));
        try self.registerNativeMethod(sub_proto, "toString", &nativeErrorToString);

        const sub_ctor = try self.createNativeFn(&nativeErrorConstructor);
        try sub_ctor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(sub_proto));
        try self.globals.put(self.allocator, try self.pool.intern(err_name), JsValue.initObject(sub_ctor));
    }
}
```

Add `error_proto: ?*JsObject = null,` to VM struct fields (around line 53).

Add native functions:

```zig
fn nativeErrorConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const err_obj = try vm.createObj(.{});

    // Get the constructor's prototype to set on the new object
    // The constructor is on the stack as the callee — we get it from the current frame
    // For now, set Error.prototype as default; construct opcode sets the right prototype
    if (vm.error_proto) |ep| {
        err_obj.prototype = ep;
    }

    const msg_sid = try vm.pool.intern("message");
    if (args.len > 0 and args[0].isString()) {
        try err_obj.setProperty(vm.allocator, msg_sid, args[0]);
    } else if (args.len > 0) {
        // Convert to string
        var buf: [64]u8 = undefined;
        const s = formatValue(vm.pool, args[0], &buf);
        try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern(s)));
    } else {
        try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern("")));
    }

    return JsValue.initObject(err_obj);
}

fn nativeErrorToString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    if (!this.isObject()) return JsValue.undefined_val;
    const obj = this.asJsObject();
    const name_sid = try vm.pool.intern("name");
    const msg_sid = try vm.pool.intern("message");
    const name_val = obj.getProperty(name_sid) orelse JsValue.initString(try vm.pool.intern("Error"));
    const msg_val = obj.getProperty(msg_sid) orelse JsValue.initString(try vm.pool.intern(""));
    const name_str = if (name_val.isString()) vm.pool.get(name_val.asStringId()) orelse "Error" else "Error";
    const msg_str = if (msg_val.isString()) vm.pool.get(msg_val.asStringId()) orelse "" else "";
    if (msg_str.len == 0) {
        return JsValue.initString(try vm.pool.intern(name_str));
    }
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(vm.allocator);
    try buf.appendSlice(vm.allocator, name_str);
    try buf.appendSlice(vm.allocator, ": ");
    try buf.appendSlice(vm.allocator, msg_str);
    return JsValue.initString(try vm.pool.intern(buf.items));
}
```

**Note on construct:** The existing `construct` opcode already sets `__proto__` from constructor.prototype. So `new TypeError("x")` will correctly get `TypeError.prototype` as its prototype, which chains to `Error.prototype`. The `nativeErrorConstructor` just needs to create the object and set `message`.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): Error objects — Error, TypeError, ReferenceError, SyntaxError, RangeError, URIError, EvalError"
```

---

## Task 3: Number.prototype and Number constructor

**Files:**
- Modify: `src/js/kotori/vm.zig` (VM struct + initBuiltins + get_prop handler + new native fns)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
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

test "Number.isNaN" {
    const result = try evalExpr(
        \\Number.isNaN(NaN);
    );
    try std.testing.expect(result.asBool() == true);
}

test "Number.isNaN non-NaN" {
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

test "Number.isInteger" {
    const result = try evalExpr(
        \\Number.isInteger(42);
    );
    try std.testing.expect(result.asBool() == true);
}

test "Number.isInteger float" {
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

test "Number toPrecision" {
    const result = try evalWithMicrotasks(
        \\var result = (123.456).toPrecision(5);
    , "result");
    try std.testing.expect(result.isString());
}

test "Number toExponential" {
    const result = try evalWithMicrotasks(
        \\var result = (12345).toExponential(2);
    , "result");
    try std.testing.expect(result.isString());
}

test "Number valueOf" {
    const result = try evalExpr(
        \\(42).valueOf();
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.toNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests, verify fail**

Run: `cd ~/suzume && zig build test-kotori 2>&1`

- [ ] **Step 3: Add `number_proto` to VM struct**

In VM struct (line ~40), add:
```zig
number_proto: ?*JsObject = null,
```

- [ ] **Step 4: Add number_proto lookup in get_prop handler**

In `get_prop` opcode (vm.zig ~line 507), change:
```zig
                    } else {
                        self.push(JsValue.undefined_val);
                    }
```
to:
```zig
                    } else if (obj_val.isNumber() or obj_val.isInt()) {
                        // Number prototype methods
                        if (self.number_proto) |np| {
                            if (np.getProperty(name_id)) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                        self.push(JsValue.undefined_val);
                    } else {
                        self.push(JsValue.undefined_val);
                    }
```

- [ ] **Step 5: Register Number.prototype methods in initBuiltins**

Add after string_proto setup:

```zig
// ── Number.prototype ──
self.number_proto = try self.createObj(.{});
const np = self.number_proto.?;
try self.registerNativeMethod(np, "toFixed", &nativeNumberToFixed);
try self.registerNativeMethod(np, "toString", &nativeNumberToString);
try self.registerNativeMethod(np, "toPrecision", &nativeNumberToPrecision);
try self.registerNativeMethod(np, "toExponential", &nativeNumberToExponential);
try self.registerNativeMethod(np, "valueOf", &nativeNumberValueOf);

// ── Number constructor ──
const num_constructor = try self.createObj(.{});
try self.registerNativeMethod(num_constructor, "isNaN", &nativeNumberIsNaN);
try self.registerNativeMethod(num_constructor, "isFinite", &nativeNumberIsFinite);
try self.registerNativeMethod(num_constructor, "isInteger", &nativeNumberIsInteger);
// parseInt/parseFloat delegate to globals
try self.registerNativeMethod(num_constructor, "parseInt", &nativeParseInt);
try self.registerNativeMethod(num_constructor, "parseFloat", &nativeParseFloat);
// Constants
try num_constructor.setProperty(self.allocator, try self.pool.intern("MAX_SAFE_INTEGER"), JsValue.initNumber(9007199254740991.0));
try num_constructor.setProperty(self.allocator, try self.pool.intern("MIN_SAFE_INTEGER"), JsValue.initNumber(-9007199254740991.0));
try num_constructor.setProperty(self.allocator, try self.pool.intern("EPSILON"), JsValue.initNumber(2.220446049250313e-16));
try num_constructor.setProperty(self.allocator, try self.pool.intern("NaN"), JsValue.nan_val);
try num_constructor.setProperty(self.allocator, try self.pool.intern("POSITIVE_INFINITY"), JsValue.initNumber(std.math.inf(f64)));
try num_constructor.setProperty(self.allocator, try self.pool.intern("NEGATIVE_INFINITY"), JsValue.initNumber(-std.math.inf(f64)));
try num_constructor.setProperty(self.allocator, try self.pool.intern("MAX_VALUE"), JsValue.initNumber(std.math.floatMax(f64)));
try num_constructor.setProperty(self.allocator, try self.pool.intern("MIN_VALUE"), JsValue.initNumber(std.math.floatMin(f64)));
try num_constructor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(np));
try self.globals.put(self.allocator, try self.pool.intern("Number"), JsValue.initObject(num_constructor));
```

- [ ] **Step 6: Implement native Number methods**

```zig
fn nativeNumberToFixed(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const n = this.toNumber();
    const digits: u8 = if (args.len > 0) @intFromFloat(@max(0, @min(100, args[0].toNumber()))) else 0;
    var buf: [128]u8 = undefined;
    // Use std.fmt to format with decimal places
    const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ n, digits }) catch return JsValue.undefined_val;
    return JsValue.initString(try vm.pool.intern(s));
}

fn nativeNumberToString(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const n = this.toNumber();
    const radix: u8 = if (args.len > 0 and args[0].isNumber())
        @intFromFloat(@max(2, @min(36, args[0].toNumber())))
    else if (args.len > 0 and args[0].isInt())
        @intCast(@max(2, @min(36, args[0].asInt())))
    else
        10;
    if (radix == 10) {
        var buf: [64]u8 = undefined;
        const s = formatValue(vm.pool, this, &buf);
        return JsValue.initString(try vm.pool.intern(s));
    }
    // Integer radix conversion
    const int_val: i64 = @intFromFloat(n);
    var buf: [65]u8 = undefined;
    var pos: usize = buf.len;
    var val = if (int_val < 0) @as(u64, @intCast(-int_val)) else @as(u64, @intCast(int_val));
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    if (val == 0) {
        pos -= 1;
        buf[pos] = '0';
    } else {
        while (val > 0) {
            pos -= 1;
            buf[pos] = digits[@intCast(val % radix)];
            val /= radix;
        }
    }
    if (int_val < 0) {
        pos -= 1;
        buf[pos] = '-';
    }
    return JsValue.initString(try vm.pool.intern(buf[pos..]));
}

fn nativeNumberToPrecision(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const n = this.toNumber();
    if (args.len == 0) {
        var buf: [64]u8 = undefined;
        const s = formatValue(vm.pool, this, &buf);
        return JsValue.initString(try vm.pool.intern(s));
    }
    const prec: u8 = @intFromFloat(@max(1, @min(100, args[0].toNumber())));
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ n, prec }) catch return JsValue.undefined_val;
    return JsValue.initString(try vm.pool.intern(s));
}

fn nativeNumberToExponential(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const n = this.toNumber();
    const frac: u8 = if (args.len > 0) @intFromFloat(@max(0, @min(100, args[0].toNumber()))) else 6;
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e:.[1]}", .{ n, frac }) catch return JsValue.undefined_val;
    return JsValue.initString(try vm.pool.intern(s));
}

fn nativeNumberValueOf(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    return JsValue.initNumber(this.toNumber());
}

fn nativeNumberIsNaN(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.initBool(false);
    const v = args[0];
    // Must be a JS number type AND NaN — not just any NaN-boxing tag
    if (v.isNumber()) return JsValue.initBool(std.math.isNan(v.asNumber()));
    return JsValue.initBool(false);
}

fn nativeNumberIsFinite(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.initBool(false);
    const v = args[0];
    if (v.isNumber()) return JsValue.initBool(std.math.isFinite(v.asNumber()));
    if (v.isInt()) return JsValue.initBool(true);
    return JsValue.initBool(false);
}

fn nativeNumberIsInteger(_: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.initBool(false);
    const v = args[0];
    if (v.isInt()) return JsValue.initBool(true);
    if (v.isNumber()) {
        const n = v.asNumber();
        if (std.math.isNan(n) or std.math.isInf(n)) return JsValue.initBool(false);
        return JsValue.initBool(@floor(n) == n);
    }
    return JsValue.initBool(false);
}
```

- [ ] **Step 7: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): Number.prototype methods + Number constructor statics and constants"
```

---

## Task 4: Date object

This is the largest task. Split into sub-steps.

**Files:**
- Modify: `src/js/kotori/object.zig` (add `.date` obj_type + ObjData)
- Modify: `src/js/kotori/vm.zig` (Date constructor + all methods + time.h cImport)
- Test: `tests/test_kotori_vm.zig`

### 4a: Object model + Date.now() + constructor

- [ ] **Step 1: Write failing tests**

```zig
test "Date.now returns number" {
    const result = try evalExpr(
        \\Date.now();
    );
    try std.testing.expect(result.isNumber());
    // Should be a reasonable timestamp (after 2020)
    try std.testing.expect(result.asNumber() > 1577836800000.0);
}

test "new Date returns object" {
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
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Add `.date` to object.zig**

In `ObjType` enum:
```zig
    date,
```

In `ObjData` union:
```zig
    date_ms: i64,  // Unix milliseconds
```

In `deinit` switch, add:
```zig
    .date_ms => {},
```

- [ ] **Step 4: Add cImport for time.h in vm.zig**

At top of vm.zig:
```zig
const c = @cImport({
    @cInclude("time.h");
});
```

Add helper functions for calendar decomposition:

```zig
fn msToLocalTm(ms: i64) c.struct_tm {
    const secs = @divTrunc(ms, 1000);
    var time_val: c.time_t = @intCast(secs);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&time_val, &tm);
    return tm;
}

fn msToUtcTm(ms: i64) c.struct_tm {
    const secs = @divTrunc(ms, 1000);
    var time_val: c.time_t = @intCast(secs);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&time_val, &tm);
    return tm;
}

fn tmToLocalMs(tm: *c.struct_tm, orig_ms: i64) i64 {
    const secs = c.mktime(tm);
    return @as(i64, secs) * 1000 + @rem(orig_ms, 1000);
}
```

- [ ] **Step 5: Implement Date constructor + Date.now() + basic getters**

```zig
// In initBuiltins:
{
    const date_proto = try self.createObj(.{});
    self.date_proto = date_proto;

    // Getters (local)
    try self.registerNativeMethod(date_proto, "getTime", &nativeDateGetTime);
    try self.registerNativeMethod(date_proto, "getFullYear", &nativeDateGetFullYear);
    try self.registerNativeMethod(date_proto, "getMonth", &nativeDateGetMonth);
    try self.registerNativeMethod(date_proto, "getDate", &nativeDateGetDate);
    try self.registerNativeMethod(date_proto, "getDay", &nativeDateGetDay);
    try self.registerNativeMethod(date_proto, "getHours", &nativeDateGetHours);
    try self.registerNativeMethod(date_proto, "getMinutes", &nativeDateGetMinutes);
    try self.registerNativeMethod(date_proto, "getSeconds", &nativeDateGetSeconds);
    try self.registerNativeMethod(date_proto, "getMilliseconds", &nativeDateGetMilliseconds);
    try self.registerNativeMethod(date_proto, "getTimezoneOffset", &nativeDateGetTimezoneOffset);

    // Getters (UTC)
    try self.registerNativeMethod(date_proto, "getUTCFullYear", &nativeDateGetUTCFullYear);
    try self.registerNativeMethod(date_proto, "getUTCMonth", &nativeDateGetUTCMonth);
    try self.registerNativeMethod(date_proto, "getUTCDate", &nativeDateGetUTCDate);
    try self.registerNativeMethod(date_proto, "getUTCDay", &nativeDateGetUTCDay);
    try self.registerNativeMethod(date_proto, "getUTCHours", &nativeDateGetUTCHours);
    try self.registerNativeMethod(date_proto, "getUTCMinutes", &nativeDateGetUTCMinutes);
    try self.registerNativeMethod(date_proto, "getUTCSeconds", &nativeDateGetUTCSeconds);
    try self.registerNativeMethod(date_proto, "getUTCMilliseconds", &nativeDateGetUTCMilliseconds);

    // Setters (local)
    try self.registerNativeMethod(date_proto, "setTime", &nativeDateSetTime);
    try self.registerNativeMethod(date_proto, "setFullYear", &nativeDateSetFullYear);
    try self.registerNativeMethod(date_proto, "setMonth", &nativeDateSetMonth);
    try self.registerNativeMethod(date_proto, "setDate", &nativeDateSetDate);
    try self.registerNativeMethod(date_proto, "setHours", &nativeDateSetHours);
    try self.registerNativeMethod(date_proto, "setMinutes", &nativeDateSetMinutes);
    try self.registerNativeMethod(date_proto, "setSeconds", &nativeDateSetSeconds);
    try self.registerNativeMethod(date_proto, "setMilliseconds", &nativeDateSetMilliseconds);

    // Setters (UTC)
    try self.registerNativeMethod(date_proto, "setUTCFullYear", &nativeDateSetUTCFullYear);
    try self.registerNativeMethod(date_proto, "setUTCMonth", &nativeDateSetUTCMonth);
    try self.registerNativeMethod(date_proto, "setUTCDate", &nativeDateSetUTCDate);
    try self.registerNativeMethod(date_proto, "setUTCHours", &nativeDateSetUTCHours);
    try self.registerNativeMethod(date_proto, "setUTCMinutes", &nativeDateSetUTCMinutes);
    try self.registerNativeMethod(date_proto, "setUTCSeconds", &nativeDateSetUTCSeconds);
    try self.registerNativeMethod(date_proto, "setUTCMilliseconds", &nativeDateSetUTCMilliseconds);

    // Conversion
    try self.registerNativeMethod(date_proto, "toString", &nativeDateToString);
    try self.registerNativeMethod(date_proto, "toDateString", &nativeDateToDateString);
    try self.registerNativeMethod(date_proto, "toTimeString", &nativeDateToTimeString);
    try self.registerNativeMethod(date_proto, "toISOString", &nativeDateToISOString);
    try self.registerNativeMethod(date_proto, "toUTCString", &nativeDateToUTCString);
    try self.registerNativeMethod(date_proto, "toJSON", &nativeDateToISOString);
    try self.registerNativeMethod(date_proto, "toLocaleDateString", &nativeDateToLocaleDateString);
    try self.registerNativeMethod(date_proto, "toLocaleTimeString", &nativeDateToLocaleTimeString);
    try self.registerNativeMethod(date_proto, "toLocaleString", &nativeDateToLocaleString);
    try self.registerNativeMethod(date_proto, "valueOf", &nativeDateValueOf);

    // Constructor
    const date_ctor = try self.createNativeFn(&nativeDateConstructor);
    try date_ctor.setProperty(self.allocator, try self.pool.intern("prototype"), JsValue.initObject(date_proto));
    try self.registerNativeMethod(date_ctor, "now", &nativeDateNow);
    try self.registerNativeMethod(date_ctor, "parse", &nativeDateParse);
    try self.registerNativeMethod(date_ctor, "UTC", &nativeDateUTC);
    try self.globals.put(self.allocator, try self.pool.intern("Date"), JsValue.initObject(date_ctor));
}
```

Add `date_proto: ?*JsObject = null,` to VM struct.

Date constructor logic:
```zig
fn nativeDateConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const obj = try vm.allocator.create(JsObject);
    obj.* = .{ .obj_type = .date, .data = .{ .date_ms = 0 }, .prototype = vm.date_proto };
    try vm.objects.append(vm.allocator, obj);

    if (args.len == 0) {
        // new Date() — current time
        obj.data.date_ms = std.time.milliTimestamp();
    } else if (args.len == 1) {
        if (args[0].isNumber()) {
            obj.data.date_ms = @intFromFloat(args[0].asNumber());
        } else if (args[0].isInt()) {
            obj.data.date_ms = args[0].asInt();
        } else if (args[0].isString()) {
            // Date.parse
            obj.data.date_ms = parseDateString(vm.pool.get(args[0].asStringId()) orelse "") orelse
                @as(i64, @bitCast(@as(u64, @bitCast(std.math.nan(f64)))));
        }
    } else {
        // new Date(y, m, d?, h?, min?, s?, ms?)
        var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
        const y = args[0].toNumber();
        tm.tm_year = @intFromFloat(y) - 1900;
        tm.tm_mon = if (args.len > 1) @intFromFloat(args[1].toNumber()) else 0;
        tm.tm_mday = if (args.len > 2) @intFromFloat(args[2].toNumber()) else 1;
        tm.tm_hour = if (args.len > 3) @intFromFloat(args[3].toNumber()) else 0;
        tm.tm_min = if (args.len > 4) @intFromFloat(args[4].toNumber()) else 0;
        tm.tm_sec = if (args.len > 5) @intFromFloat(args[5].toNumber()) else 0;
        tm.tm_isdst = -1;
        const secs = c.mktime(&tm);
        const extra_ms: i64 = if (args.len > 6) @intFromFloat(args[6].toNumber()) else 0;
        obj.data.date_ms = @as(i64, secs) * 1000 + extra_ms;
    }
    return JsValue.initObject(obj);
}

fn nativeDateNow(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    return JsValue.initNumber(@floatFromInt(std.time.milliTimestamp()));
}
```

Helper to extract date ms from `this`:
```zig
fn getDateMs(this: JsValue) ?i64 {
    if (!this.isObject()) return null;
    const obj = this.asJsObject();
    if (obj.obj_type != .date) return null;
    return obj.data.date_ms;
}

fn setDateMs(this: JsValue, ms: i64) void {
    if (!this.isObject()) return;
    const obj = this.asJsObject();
    if (obj.obj_type != .date) return;
    obj.data = .{ .date_ms = ms };
}
```

- [ ] **Step 6: Implement all getter methods**

Local getters all follow same pattern — decompose with `localtime_r`, extract field:
```zig
fn nativeDateGetTime(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    return JsValue.initNumber(@floatFromInt(getDateMs(this) orelse return JsValue.nan_val));
}

fn nativeDateGetFullYear(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_year + 1900));
}

fn nativeDateGetMonth(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_mon));
}

fn nativeDateGetDate(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_mday));
}

fn nativeDateGetDay(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_wday));
}

fn nativeDateGetHours(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_hour));
}

fn nativeDateGetMinutes(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_min));
}

fn nativeDateGetSeconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToLocalTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_sec));
}

fn nativeDateGetMilliseconds(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const remainder = @rem(ms, 1000);
    return JsValue.initNumber(@floatFromInt(if (remainder < 0) remainder + 1000 else remainder));
}

fn nativeDateGetTimezoneOffset(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const local_tm = msToLocalTm(ms);
    const utc_tm = msToUtcTm(ms);
    // Offset in minutes = UTC - local
    const local_min = @as(i64, local_tm.tm_hour) * 60 + local_tm.tm_min;
    const utc_min = @as(i64, utc_tm.tm_hour) * 60 + utc_tm.tm_min;
    var diff = utc_min - local_min;
    // Handle day boundary
    if (utc_tm.tm_mday != local_tm.tm_mday) {
        if (utc_tm.tm_mday > local_tm.tm_mday or (utc_tm.tm_mon > local_tm.tm_mon)) {
            diff += 24 * 60;
        } else {
            diff -= 24 * 60;
        }
    }
    return JsValue.initNumber(@floatFromInt(diff));
}
```

UTC getters use `msToUtcTm` — same pattern but with `gmtime_r`:
```zig
fn nativeDateGetUTCFullYear(_: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const ms = getDateMs(this) orelse return JsValue.nan_val;
    const tm = msToUtcTm(ms);
    return JsValue.initNumber(@floatFromInt(tm.tm_year + 1900));
}
// ... (getUTCMonth, getUTCDate, getUTCDay, getUTCHours, getUTCMinutes, getUTCSeconds, getUTCMilliseconds follow identical pattern with msToUtcTm)
```

- [ ] **Step 7: Implement setter methods**

Local setters decompose, modify field, recompose:
```zig
fn nativeDateSetTime(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.nan_val;
    const ms: i64 = @intFromFloat(args[0].toNumber());
    setDateMs(this, ms);
    return JsValue.initNumber(@floatFromInt(ms));
}

fn nativeDateSetFullYear(_: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len == 0) return JsValue.nan_val;
    const orig_ms = getDateMs(this) orelse return JsValue.nan_val;
    var tm = msToLocalTm(orig_ms);
    tm.tm_year = @intFromFloat(args[0].toNumber()) - 1900;
    if (args.len > 1) tm.tm_mon = @intFromFloat(args[1].toNumber());
    if (args.len > 2) tm.tm_mday = @intFromFloat(args[2].toNumber());
    tm.tm_isdst = -1;
    const new_ms = tmToLocalMs(&tm, orig_ms);
    setDateMs(this, new_ms);
    return JsValue.initNumber(@floatFromInt(new_ms));
}
// ... (setMonth, setDate, setHours, setMinutes, setSeconds, setMilliseconds follow same decompose-modify-recompose pattern)
// UTC setters use gmtime_r + timegm (or manual epoch calc)
```

- [ ] **Step 8: Implement toString/toISOString/toLocaleString methods**

```zig
fn nativeDateToISOString(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const ms = getDateMs(this) orelse return JsValue.undefined_val;
    const tm = msToUtcTm(ms);
    const millis = @rem(ms, 1000);
    const abs_millis: u32 = @intCast(if (millis < 0) millis + 1000 else millis);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(i32, tm.tm_year) + 1900,
        @as(u32, @intCast(tm.tm_mon)) + 1,
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
        abs_millis,
    }) catch return JsValue.undefined_val;
    return JsValue.initString(try vm.pool.intern(s));
}
// toString, toDateString, toTimeString, toUTCString, toLocaleDateString, toLocaleTimeString, toLocaleString
// all follow similar bufPrint patterns with different format strings
```

- [ ] **Step 9: Implement Date.parse() and Date.UTC()**

```zig
fn parseDateString(s: []const u8) ?i64 {
    // Try ISO 8601 first: YYYY-MM-DDTHH:MM:SS.sssZ
    if (parseISO8601(s)) |ms| return ms;
    // Try RFC 2822: "Sat, 12 Apr 2026 06:30:00 GMT"
    if (parseRFC2822(s)) |ms| return ms;
    // Try casual: "Apr 12, 2026"
    if (parseCasual(s)) |ms| return ms;
    return null;
}

fn parseISO8601(s: []const u8) ?i64 {
    // Parse YYYY-MM-DD[THH:MM[:SS[.sss]]][Z|+HH:MM|-HH:MM]
    // Minimum: YYYY-MM-DD (10 chars)
    if (s.len < 10) return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    // ... parse time part if present
    // Build via gmtime/mktime
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = @as(c_int, month) - 1;
    tm.tm_mday = day;
    // ... parse T, hours, minutes, seconds, milliseconds, timezone offset
    // Return epoch ms
}
// parseRFC2822 and parseCasual follow similar parsing logic
```

- [ ] **Step 10: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 11: Write additional Date tests**

```zig
test "Date toISOString" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.toISOString();
    , "result");
    try std.testing.expect(result.isString());
}

test "Date getMonth zero-based" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(2026, 3, 12); // April
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

test "Date getUTCHours" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0); // epoch = midnight UTC
        \\var result = d.getUTCHours();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "Date toString" {
    const result = try evalWithMicrotasks(
        \\var d = new Date(0);
        \\var result = d.toString();
    , "result");
    try std.testing.expect(result.isString());
}
```

- [ ] **Step 12: Run full test suite**

Run: `cd ~/suzume && zig build test-kotori 2>&1`

- [ ] **Step 13: Commit**

```bash
cd ~/suzume && git add src/js/kotori/object.zig src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): Date object — full constructor, getters, setters, toString, toISOString, Date.parse, Date.UTC"
```

---

## Task 5: Promise.all / race / allSettled / any

**Files:**
- Modify: `src/js/kotori/vm.zig` (add static methods to Promise constructor in initBuiltins)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
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
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Implement Promise.all**

In `initBuiltins`, after existing `Promise.reject`, add:
```zig
try self.registerNativeMethod(promise_ctor, "all", &nativePromiseAll);
try self.registerNativeMethod(promise_ctor, "race", &nativePromiseRace);
try self.registerNativeMethod(promise_ctor, "allSettled", &nativePromiseAllSettled);
try self.registerNativeMethod(promise_ctor, "any", &nativePromiseAny);
```

Implementation pattern for Promise.all:
```zig
fn nativePromiseAll(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    // Create result promise
    const result_promise = try vm.createPromise();

    if (args.len == 0 or !args[0].isObject()) {
        // Resolve with empty array
        const arr = try vm.createArray();
        vm.resolvePromise(result_promise, JsValue.initObject(arr));
        return JsValue.initObject(result_promise);
    }

    const input_obj = args[0].asJsObject();
    if (input_obj.obj_type != .array) {
        const arr = try vm.createArray();
        vm.resolvePromise(result_promise, JsValue.initObject(arr));
        return JsValue.initObject(result_promise);
    }

    const items = input_obj.data.array.items;
    if (items.len == 0) {
        const arr = try vm.createArray();
        vm.resolvePromise(result_promise, JsValue.initObject(arr));
        return JsValue.initObject(result_promise);
    }

    // Create results array and counter object (shared state via closure)
    const results = try vm.createArray();
    // Pre-fill with undefined
    for (0..items.len) |_| {
        try results.data.array.append(vm.allocator, JsValue.undefined_val);
    }

    // For each item: Promise.resolve(item).then(onFulfilled, onRejected)
    // Use index capture via object property
    for (items, 0..) |item, idx| {
        // Wrap with Promise.resolve
        const wrapped = try vm.promiseResolveValue(item);
        // Create then handlers that capture index and shared state
        // ... attach via nativePromiseThen with closure-captured state
        // On fulfill: results[idx] = value; count++; if count == len → resolve(results)
        // On reject: reject(reason)
    }

    return JsValue.initObject(result_promise);
}
```

**Note**: The exact closure mechanism depends on how native callbacks can capture state. Use the existing pattern of creating native function objects with captured context via object properties.

- [ ] **Step 4: Implement Promise.race, Promise.allSettled, Promise.any**

Same pattern as Promise.all but with different completion logic:
- `race`: first to settle wins
- `allSettled`: count all settlements, build `{status, value/reason}` objects
- `any`: first fulfillment wins, all reject → AggregateError

- [ ] **Step 5: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): Promise.all, Promise.race, Promise.allSettled, Promise.any"
```

---

## Task 6: Console expansion

**Files:**
- Modify: `src/js/kotori/vm.zig` (VM struct + initBuiltins + native functions)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "console.warn exists" {
    // Should not crash
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

test "console.assert no output on true" {
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
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Add console state to VM struct**

```zig
// Console state
console_timers: std.StringHashMapUnmanaged(i64) = .{},
console_counts: std.StringHashMapUnmanaged(u32) = .{},
console_indent: u32 = 0,
```

Add cleanup in VM `deinit`:
```zig
self.console_timers.deinit(self.allocator);
self.console_counts.deinit(self.allocator);
```

- [ ] **Step 4: Register console methods in initBuiltins**

After existing `console.log` registration:
```zig
try self.registerNativeMethod(console_obj, "warn", &nativeConsoleWarn);
try self.registerNativeMethod(console_obj, "error", &nativeConsoleError);
try self.registerNativeMethod(console_obj, "info", &nativeConsoleInfo);
try self.registerNativeMethod(console_obj, "debug", &nativeConsoleDebug);
try self.registerNativeMethod(console_obj, "dir", &nativeConsoleDir);
try self.registerNativeMethod(console_obj, "assert", &nativeConsoleAssert);
try self.registerNativeMethod(console_obj, "time", &nativeConsoleTime);
try self.registerNativeMethod(console_obj, "timeEnd", &nativeConsoleTimeEnd);
try self.registerNativeMethod(console_obj, "timeLog", &nativeConsoleTimeLog);
try self.registerNativeMethod(console_obj, "count", &nativeConsoleCount);
try self.registerNativeMethod(console_obj, "countReset", &nativeConsoleCountReset);
try self.registerNativeMethod(console_obj, "clear", &nativeConsoleNoOp);
try self.registerNativeMethod(console_obj, "trace", &nativeConsoleTrace);
try self.registerNativeMethod(console_obj, "group", &nativeConsoleGroup);
try self.registerNativeMethod(console_obj, "groupCollapsed", &nativeConsoleGroup);
try self.registerNativeMethod(console_obj, "groupEnd", &nativeConsoleGroupEnd);
try self.registerNativeMethod(console_obj, "table", &nativeConsoleTable);
```

- [ ] **Step 5: Implement native console functions**

```zig
fn consoleWriteWithPrefix(vm: *VM, prefix: []const u8, args: []const JsValue) void {
    const stderr = std.fs.File.stderr();
    // Write indent
    for (0..vm.console_indent) |_| _ = stderr.write("  ") catch 0;
    if (prefix.len > 0) {
        _ = stderr.write(prefix) catch 0;
        _ = stderr.write(" ") catch 0;
    }
    for (args, 0..) |arg, i| {
        if (i > 0) _ = stderr.write(" ") catch 0;
        var buf: [64]u8 = undefined;
        _ = stderr.write(formatValue(vm.pool, arg, &buf)) catch 0;
    }
    _ = stderr.write("\n") catch 0;
}

fn nativeConsoleWarn(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "[WARN]", args);
    return JsValue.undefined_val;
}

fn nativeConsoleError(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "[ERROR]", args);
    return JsValue.undefined_val;
}

fn nativeConsoleInfo(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "[INFO]", args);
    return JsValue.undefined_val;
}

fn nativeConsoleDebug(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "[DEBUG]", args);
    return JsValue.undefined_val;
}

fn nativeConsoleAssert(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    if (args.len > 0 and args[0].isTruthy()) return JsValue.undefined_val;
    consoleWriteWithPrefix(vmFromCtx(ctx), "[ASSERT]", if (args.len > 1) args[1..] else &.{});
    return JsValue.undefined_val;
}

fn nativeConsoleTime(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const label = if (args.len > 0 and args[0].isString())
        vm.pool.get(args[0].asStringId()) orelse "default"
    else
        "default";
    if (vm.console_timers.count() < 1024) {
        vm.console_timers.put(vm.allocator, label, std.time.milliTimestamp()) catch {};
    }
    return JsValue.undefined_val;
}

fn nativeConsoleTimeEnd(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const label = if (args.len > 0 and args[0].isString())
        vm.pool.get(args[0].asStringId()) orelse "default"
    else
        "default";
    if (vm.console_timers.get(label)) |start| {
        const elapsed = std.time.milliTimestamp() - start;
        const stderr = std.fs.File.stderr();
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}: {d}ms\n", .{ label, elapsed }) catch return JsValue.undefined_val;
        _ = stderr.write(s) catch 0;
        _ = vm.console_timers.remove(label);
    }
    return JsValue.undefined_val;
}

fn nativeConsoleTimeLog(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const label = if (args.len > 0 and args[0].isString())
        vm.pool.get(args[0].asStringId()) orelse "default"
    else
        "default";
    if (vm.console_timers.get(label)) |start| {
        const elapsed = std.time.milliTimestamp() - start;
        const stderr = std.fs.File.stderr();
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}: {d}ms", .{ label, elapsed }) catch return JsValue.undefined_val;
        _ = stderr.write(s) catch 0;
        if (args.len > 1) {
            for (args[1..]) |arg| {
                _ = stderr.write(" ") catch 0;
                var vbuf: [64]u8 = undefined;
                _ = stderr.write(formatValue(vm.pool, arg, &vbuf)) catch 0;
            }
        }
        _ = stderr.write("\n") catch 0;
    }
    return JsValue.undefined_val;
}

fn nativeConsoleCount(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const label = if (args.len > 0 and args[0].isString())
        vm.pool.get(args[0].asStringId()) orelse "default"
    else
        "default";
    const entry = vm.console_counts.getOrPut(vm.allocator, label) catch return JsValue.undefined_val;
    if (!entry.found_existing) {
        if (vm.console_counts.count() > 1024) {
            _ = vm.console_counts.remove(label);
            return JsValue.undefined_val;
        }
        entry.value_ptr.* = 0;
    }
    entry.value_ptr.* += 1;
    const stderr = std.fs.File.stderr();
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}: {d}\n", .{ label, entry.value_ptr.* }) catch return JsValue.undefined_val;
    _ = stderr.write(s) catch 0;
    return JsValue.undefined_val;
}

fn nativeConsoleCountReset(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const label = if (args.len > 0 and args[0].isString())
        vm.pool.get(args[0].asStringId()) orelse "default"
    else
        "default";
    _ = vm.console_counts.remove(label);
    return JsValue.undefined_val;
}

fn nativeConsoleNoOp(_: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    return JsValue.undefined_val;
}

fn nativeConsoleTrace(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "Trace:", args);
    return JsValue.undefined_val;
}

fn nativeConsoleGroup(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    if (args.len > 0) consoleWriteWithPrefix(vm, "", args);
    if (vm.console_indent < 16) vm.console_indent += 1;
    return JsValue.undefined_val;
}

fn nativeConsoleGroupEnd(ctx: *anyopaque, _: JsValue, _: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    if (vm.console_indent > 0) vm.console_indent -= 1;
    return JsValue.undefined_val;
}

fn nativeConsoleDir(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    if (args.len == 0) return JsValue.undefined_val;
    const val = args[0];
    const stderr = std.fs.File.stderr();
    if (val.isObject()) {
        const obj = val.asJsObject();
        _ = stderr.write("{ ") catch 0;
        var first = true;
        var it = obj.properties.iterator();
        while (it.next()) |entry| {
            if (!first) _ = stderr.write(", ") catch 0;
            first = false;
            if (vm.pool.get(entry.key_ptr.*)) |key_str| {
                _ = stderr.write(key_str) catch 0;
            }
            _ = stderr.write(": ") catch 0;
            var buf: [64]u8 = undefined;
            _ = stderr.write(formatValue(vm.pool, entry.value_ptr.*, &buf)) catch 0;
        }
        _ = stderr.write(" }\n") catch 0;
    } else {
        var buf: [64]u8 = undefined;
        _ = stderr.write(formatValue(vm.pool, val, &buf)) catch 0;
        _ = stderr.write("\n") catch 0;
    }
    return JsValue.undefined_val;
}

fn nativeConsoleTable(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    // Simple implementation: just log each item
    const vm = vmFromCtx(ctx);
    if (args.len == 0) return JsValue.undefined_val;
    const val = args[0];
    const stderr = std.fs.File.stderr();
    if (val.isObject()) {
        const obj = val.asJsObject();
        if (obj.obj_type == .array) {
            for (obj.data.array.items, 0..) |item, i| {
                var ibuf: [20]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&ibuf, "{d}\t", .{i}) catch continue;
                _ = stderr.write(idx_str) catch 0;
                var buf: [64]u8 = undefined;
                _ = stderr.write(formatValue(vm.pool, item, &buf)) catch 0;
                _ = stderr.write("\n") catch 0;
            }
        } else {
            // Fall back to dir
            return nativeConsoleDir(ctx, JsValue.undefined_val, args);
        }
    }
    return JsValue.undefined_val;
}
```

- [ ] **Step 6: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig
git commit -m "feat(kotori): console expansion — warn, error, info, debug, dir, assert, time, count, group, table"
```

---

## Task 7: Final integration test + update console.log for indent

- [ ] **Step 1: Update existing `nativeConsoleLog` to respect indent**

Change existing `nativeConsoleLog` to use `consoleWriteWithPrefix`:
```zig
fn nativeConsoleLog(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    consoleWriteWithPrefix(vmFromCtx(ctx), "", args);
    return JsValue.undefined_val;
}
```

- [ ] **Step 2: Run full test suite**

Run: `cd ~/suzume && zig build test-kotori 2>&1`
Expected: ALL PASS

- [ ] **Step 3: Run full browser build to check no regressions**

Run: `cd ~/suzume && zig build 2>&1`
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig
git commit -m "refactor(kotori): console.log uses shared indent-aware writer"
```
