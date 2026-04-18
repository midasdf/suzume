# Layer 0A — kotori Builtin Polish Design Spec

**Date**: 2026-04-19
**Target branch**: `master` (current HEAD `beb7a4b`)
**Master index**: [`2026-04-17-kotori-suzume-wpt-100-roadmap.md`](./2026-04-17-kotori-suzume-wpt-100-roadmap.md) § Layer 0A
**Scope**: Five small, low-risk ECMA-262 builtin compliance gaps in `src/js/kotori/vm.zig` that together unblock WPT assertions spread across `dom/`, `html/`, `webidl/`, and `events/`. Zero changes to any file outside `src/js/kotori/`.

## Context

kotori currently treats every native builtin as a bare `JsObject{.obj_type = .native_function, .data = .{.native_fn = fn_ptr}}` with no built-in `length`, `name`, or callable-function reflection data. See [`object.zig:58-127`](../../src/js/kotori/object.zig) — the `JsObject` struct has `properties`, but nothing populates `length`/`name` on natives. [`vm.zig:2915-2921`](../../src/js/kotori/vm.zig) is the sole helper used to install a native method, and [`vm.zig:7955-7960`](../../src/js/kotori/vm.zig) creates a freestanding native fn; neither sets reflection properties.

The roadmap's session #7 measurements show a shape where *many small ECMA-262 gaps* block *many downstream assertions*. Because WPT tests such as `Event-constructors.any.js` assert `new Event()` throws a real `TypeError` (which must pass `instanceof TypeError`), and WebIDL binding tests enumerate `Reflect.ownKeys(ctor).slice(0, 3)` expecting `["length", "name", "prototype"]` ([`builtin-function-properties.any.js:3-5`](/tmp/wpt/webidl/ecmascript-binding/builtin-function-properties.any.js)), the impact of Layer 0A is multiplicative across the areas that already run Wave-1 infrastructure.

The five gaps:

1. **Native fn `.length`** — §20.2.4.1
2. **Native fn `.name`** — §20.2.4.2
3. **`Error` subclass prototype chain completeness** — §20.5
4. **Array callbacks honor `thisArg`** — §23.1.3.x
5. **`Promise.resolve` thenable detection** — §27.2.4.7 → §27.2.1.4

All fixes live in `src/js/kotori/vm.zig` (with one small field addition in `src/js/kotori/object.zig`). No changes to parser, compiler, AST, or lexer.

### Cross-layer roadmap note

The roadmap estimates +400 subtests for Layer 0A. My WPT scan (see each gap's "WPT exposure") produces a higher lower bound: createEvent alone carries **~150–180 subtests** (20 aliases × 3 case variants × 2 tests per alias + ~15 plural-throw assertions = ~135, plus +40 direct DOMException / Event-constructor assertions that need real TypeError). Adding the Promise-thenable assertions from testharness.js (which run `assert_equals(typeof promise.then, "function")` style checks *inside* numerous fulfillment-chain paths) plus Array callback `thisArg` tests (Array.prototype iteration across a few dozen dom/ test files), **my estimate is +450 to +600 subtests** — slightly above the roadmap. Confidence: medium. The +400 figure is safe as a floor, and no single gap is load-bearing for this estimate — even if thenable detection contributes only marginally, the createEvent aliases alone clear the original +400 target.

---

## Gap 1: Native fn `.length`

### Spec

ECMA-262 §20.2.4.1 ("Function.prototype.length"):

> This is a data property with a value of 0. This property has the attributes `{ [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }`.

And more critically, §10.2.9 ("SetFunctionLength(F, length)"):

> Every built-in function object, including constructors, has a "length" property whose value is an Integer. Unless otherwise specified, this value is equal to the largest number of named arguments shown in the subclause headings for the function description. … This property has the attributes `{ [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }`.

Rest parameters and optional arguments with defaults do *not* count. `Array.prototype.forEach(callbackFn [, thisArg])` has length **1**; `Array.prototype.slice([start [, end]])` has length **2**; `Event` constructor has length **1**.

### Current state

1. `JsObject.NativeFn` signature ([`object.zig:74`](../../src/js/kotori/object.zig)) is variadic in args count: `fn(ctx, this, args: []const JsValue) !JsValue`. There is no declared-parameter metadata anywhere.
2. `registerNativeMethod` ([`vm.zig:2915-2921`](../../src/js/kotori/vm.zig)) creates the fn object without setting `length`.
3. `createNativeFn` ([`vm.zig:7955-7960`](../../src/js/kotori/vm.zig)) creates the fn object without setting `length`.
4. GET on `native_fn.length` falls through to `Function.prototype` ([`vm.zig:1002-1013`](../../src/js/kotori/vm.zig)), which also has no `length`, returning `undefined`.
5. The only places that synthesize a virtual `length` are `.array` and `.typed_array`/`.array_buffer` ([`vm.zig:966-999`](../../src/js/kotori/vm.zig)) — unrelated to functions.

### Gap

`Function.prototype.call.length === 1` in the spec; kotori returns `undefined`. Same for every `Array.prototype.*`, `Object.*`, `Event`, `CustomEvent`, `TypeError`, `Promise.resolve`, etc.

Failing assertions (explicit):
- `Reflect.ownKeys(Blob).slice(0, 3)` expects `["length", "name", "prototype"]` — fails because neither `length` nor `name` exist ([`webidl/ecmascript-binding/builtin-function-properties.any.js:3-5`](/tmp/wpt/webidl/ecmascript-binding/builtin-function-properties.any.js)).
- `Reflect.ownKeys(Blob.prototype.slice).slice(0, 2)` expects `["length", "name"]` (same file:7-13).
- Any test of the shape `assert_equals(Event.length, 1)` — present in multiple Event constructor conformance tests.

### Proposed change

**Source of truth**: declared-parameter arity becomes an explicit number the caller passes in when registering.

#### Step 1: Extend registration API

In `vm.zig` extend the existing helpers and add variants, *without breaking callers* by keeping the old names but delegating. New signatures:

```zig
pub fn registerNativeMethod(self: *VM, target: *JsObject, name: []const u8, func: NativeFn) !void
    // kept for back-compat — calls registerNativeMethodArity(target, name, func, defaultArityFor(name))

pub fn registerNativeMethodArity(self: *VM, target: *JsObject, name: []const u8,
                                  func: NativeFn, length: u16) !void

fn createNativeFn(self: *VM, func: NativeFn) !*JsObject
    // kept — creates with length=0, name=""

fn createNamedNativeFn(self: *VM, name: []const u8, func: NativeFn, length: u16) !*JsObject
```

Both `registerNativeMethodArity` and `createNamedNativeFn` install `length` and `name` as own descriptors with attrs `{writable=false, enumerable=false, configurable=true}` using the existing `defineOwnProperty` slow-path ([`object.zig:342-350`](../../src/js/kotori/object.zig)).

#### Step 2: Call-site conversion

Every `registerNativeMethod` call in `vm.zig:2325-2903` (the global init block) is rewritten to use `registerNativeMethodArity` with the correct declared arity. Approximately 200 call sites — mechanical but tedious.

Arity reference table (non-exhaustive, derived directly from ECMA-262 section headings):

| Method | Arity | Spec section |
|--------|-------|--------------|
| `Array.prototype.push(...items)` | 1 | §23.1.3.20 |
| `Array.prototype.pop()` | 0 | §23.1.3.19 |
| `Array.prototype.slice(start, end)` | 2 | §23.1.3.24 |
| `Array.prototype.forEach(callbackFn, thisArg)` | 1 | §23.1.3.12 |
| `Array.prototype.map(callbackFn, thisArg)` | 1 | §23.1.3.17 |
| `Array.prototype.reduce(callbackFn, initialValue)` | 1 | §23.1.3.22 |
| `Array.prototype.concat(...items)` | 1 | §23.1.3.1 |
| `Array.isArray(arg)` | 1 | §23.1.2.2 |
| `Object.keys(O)` | 1 | §20.1.2.17 |
| `Object.defineProperty(O, P, Attributes)` | 3 | §20.1.2.4 |
| `Object.assign(target, ...sources)` | 2 | §20.1.2.1 |
| `Object.create(O, Properties)` | 2 | §20.1.2.2 |
| `String.prototype.slice(start, end)` | 2 | §22.1.3.23 |
| `String.prototype.replace(searchValue, replaceValue)` | 2 | §22.1.3.18 |
| `Promise(executor)` | 1 | §27.2.3 |
| `Promise.resolve(x)` | 1 | §27.2.4.7 |
| `Promise.all(iterable)` | 1 | §27.2.4.1 |
| `Promise.prototype.then(onFulfilled, onRejected)` | 2 | §27.2.5.4 |
| `Promise.prototype.catch(onRejected)` | 1 | §27.2.5.1 |
| `Error(message, options)` | 1 | §20.5.1 |
| `DOMException(message, name)` | 2 | WebIDL §3.14 |
| `Function.prototype.call(thisArg, ...args)` | 1 | §20.2.3.3 |
| `Function.prototype.apply(thisArg, argArray)` | 2 | §20.2.3.1 |
| `Function.prototype.bind(thisArg, ...args)` | 1 | §20.2.3.2 |

A canonical table will live as a private `comptime` const inside `vm.zig` rather than a separate file, to keep the change single-file.

#### Step 3: GET path fix

Line [`vm.zig:1000-1023`](../../src/js/kotori/vm.zig) resolves `function.length` via `obj.getProperty(name_id)`. Once Step 1 installs `length` as an own descriptor, the existing descriptor lookup in `getOwnDescriptor` → `findAccessorDescriptor` → `getProperty` path ([`object.zig:153-185`](../../src/js/kotori/object.zig)) delivers the correct value. No code change needed here once the data is there. Verify by reading a native fn's `.length` via the existing property-access opcode.

### Test plan

1. **Unit**: Add `src/js/kotori/tests/` entries (or extend the existing test harness — [`kotori.zig`](../../src/js/kotori/kotori.zig) / `zig build test`) that assert:
   - `Array.prototype.forEach.length === 1`
   - `Array.prototype.slice.length === 2`
   - `Promise.resolve.length === 1`
   - `Event.length === 1`
   - The property descriptor: `Object.getOwnPropertyDescriptor(Array.prototype.slice, "length").configurable === true` AND `.writable === false` AND `.enumerable === false`.
2. **WPT deltas to watch**:
   - `webidl/ecmascript-binding/builtin-function-properties.any.js` — should go from 0 → 3 passing subtests per instance (runs for Blob, URL, Response, etc. — estimated ~10–20 passing subtests).
   - `webidl/ecmascript-binding/attributes-accessors-unique-function-objects.html` — likely passes once getters/setters have distinct function objects (out of scope here but gated by accessor infra).
3. **Command**: `zig build test` then `./tests/wpt/run_wpt.sh webidl`.

### Risk

- **Regression vector**: 200+ call-site rewrites. Any missed site leaves the native fn with `length === undefined`, which is the *current* behavior — not a regression, just an incomplete fix.
- **Rest-arg miscount**: It is easy to accidentally count rest params. Mitigation: the comptime arity table must be derived from *normative* spec section headings, not from the Zig callback's `args.len` handling. Any disagreement is a spec violation.
- **Bound functions**: `Function.prototype.bind` returns a new function whose `length` is `max(0, target.length − bound_args)`. This is currently *not* implemented correctly ([`vm.zig:5528`](../../src/js/kotori/vm.zig), `nativeFunctionBind`). Out of scope for 0A but flagged so it doesn't surprise later phases. The spec-correct implementation lives in §20.2.3.2 step 7; for now the bound wrapper just gets `length = 0`.
- **Property enumeration order**: Tests like `builtin-function-properties.any.js` assert that `length`, `name`, `prototype` appear *in that order* as the first three own keys. kotori's `AutoArrayHashMapUnmanaged` preserves insertion order ([`object.zig:62`](../../src/js/kotori/object.zig) — `std.AutoArrayHashMapUnmanaged`), so inserting `length` first, then `name`, then `prototype` satisfies the invariant.

---

## Gap 2: Native fn `.name`

### Spec

ECMA-262 §20.2.4.2 ("Function.prototype.name"):

> This is a data property with a value of an empty String.

And §10.2.8 ("SetFunctionName(F, name, prefix)"):

> Every built-in function object, including constructors, has a "name" property whose value is a String. Unless otherwise specified, this value is the name that is given to the function in this specification. … This property has the attributes `{ [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }`.

For anonymous natives the value is `""`. For method shorthand like `{foo() {}}` → `"foo"`. For class constructors → the class name.

### Current state

Same as Gap 1 — `registerNativeMethod` ([`vm.zig:2915-2921`](../../src/js/kotori/vm.zig)) knows the name string (passed as the `name` parameter), and *does* intern it as the target-object key, but **does not set `.name` on the function object itself**. The name survives only as the property key on the parent object.

Exceptions already in the code (partial, inconsistent):
- `error_ctor` gets `name = "Error"` ([`vm.zig:2740`](../../src/js/kotori/vm.zig))
- `sub_ctor` (`TypeError` etc.) gets `name = err_name` ([`vm.zig:2759`](../../src/js/kotori/vm.zig))
- `dom_exc_ctor` gets `name = "DOMException"` ([`vm.zig:2781`](../../src/js/kotori/vm.zig))

These ad-hoc fixes already demonstrate the pattern. Everything else — `Array.prototype.slice`, `Promise.resolve`, `console.log`, `JSON.stringify`, hundreds of methods — is missing `name`.

### Gap

Failing assertions:
- `Blob.prototype.slice.name === "slice"` — fails (name is undefined).
- `Reflect.ownKeys(fn).slice(0, 2) === ["length", "name"]` — fails.
- testharness.js's `format_value(fn)` uses `fn.name` to produce diagnostic strings; missing name produces `function () { [native code] }` everywhere, which makes *failure messages* harder to read but does not by itself fail tests.
- DOM event constructors: some tests check `Event.name === "Event"`.

### Proposed change

**Single source of truth**: The name passed to `registerNativeMethodArity` (Gap 1 change) *is* the function name. No extra argument needed. Add the property-set immediately after creating the fn object:

```zig
// Inside registerNativeMethodArity, after fn_obj.* = .{ ... }:
const name_sid = try self.pool.intern(name);
const len_sid  = try self.pool.intern("length");
const namekey  = try self.pool.intern("name");
try fn_obj.defineOwnProperty(self.allocator, len_sid,  .{.data = .{.value = JsValue.initNumber(@floatFromInt(length)),
                                                                   .attrs = .{.writable=false, .enumerable=false, .configurable=true}}});
try fn_obj.defineOwnProperty(self.allocator, namekey, .{.data = .{.value = JsValue.initString(name_sid),
                                                                   .attrs = .{.writable=false, .enumerable=false, .configurable=true}}});
// Then the existing:
try target.setProperty(self.allocator, name_sid, JsValue.initObject(fn_obj));
```

For `createNamedNativeFn` (freestanding, no target), same property installation.

For the existing three ad-hoc name-sets on error constructors, *remove* them — they become redundant once `createNamedNativeFn` handles it. This avoids double-setting with different attrs (the ad-hoc calls use default `{writable=true, enumerable=true}` which is spec-incorrect).

#### Consumer-site cleanup

Wherever `createNativeFn(&f)` is used (constructors like `&nativeDateConstructor`, `&nativeProxyConstructor`, etc. at [`vm.zig:2717, 2735, 2779, 2798, 2800, 2806, 2813, 2838, 2844, 2846, 2852, 2858, 2871, 2888`](../../src/js/kotori/vm.zig)), switch to `createNamedNativeFn("Date", &fn, 7)` etc. The arity for each is looked up in the canonical table.

### Test plan

1. **Unit**:
   - `Array.prototype.slice.name === "slice"`
   - `Promise.resolve.name === "resolve"`
   - `Event.name === "Event"`
   - `TypeError.name === "TypeError"` (currently works via ad-hoc code, verify still works after refactor)
2. **WPT**: Same `builtin-function-properties.any.js` harness plus any test that does `assert_equals(typeof fn.name, "string")`.

### Risk

- **Double-set collision on Error ctors**: If the refactor is imperfect and the ad-hoc `setProperty(..., "name", ...)` calls remain *and* `createNamedNativeFn` also sets `name`, the ad-hoc call would overwrite via the fast-path while `defineOwnProperty` created a slow-path descriptor — ordering determines outcome. Mitigation: delete ad-hoc calls atomically with the switch to `createNamedNativeFn`.
- **String interning cost**: ~200 new interned symbol ids, mostly duplicates of existing method-name interning. Negligible.
- **Attribute mismatch**: WebIDL assertions check `writable=false, enumerable=false, configurable=true`. Using the default fast-path `setProperty` would produce `writable=true, enumerable=true, configurable=true` — wrong. Must go through `defineOwnProperty` with explicit attrs.

---

## Gap 3: Error.prototype chain completeness

### Spec

ECMA-262 §20.5.6 ("Native Error Types Used in This Standard"):

> Each of these objects has the structure described below, differing only in the name used as the constructor name instead of NativeError, and in the "name" property's String value.
> 20.5.6.1 NativeError Constructors — Each NativeError constructor has a `[[Prototype]]` internal slot whose value is the intrinsic object %Error%.
> 20.5.6.2 NativeError( message [, options ] ) — …
> 20.5.6.3 Properties of the NativeError Constructors — Each NativeError constructor has a `prototype` property whose value is the corresponding NativeError prototype object.
> 20.5.6.4 Properties of the NativeError Prototype Objects — Each NativeError prototype object has a `[[Prototype]]` internal slot whose value is %Error.prototype%. Each also has the following properties:
>   - `constructor`: The initial value of `NativeError.prototype.constructor` is the corresponding intrinsic object %NativeError%.
>   - `message`: The initial value of the "message" property of each NativeError prototype object is the empty String.
>   - `name`: The initial value of the "name" property of each NativeError prototype object is a String consisting of the name of the constructor…

And §20.5.1.1 (`Error(message [, options])`):

> 1. If NewTarget is undefined, let newTarget be the active function object; else let newTarget be NewTarget.
> 2. Let O be ? OrdinaryCreateFromConstructor(newTarget, "%Error.prototype%", « [[ErrorData]] »).
> 3. If message is not undefined, … Let msg be ? ToString(message). Perform ! CreateNonEnumerableDataPropertyOrThrow(O, "message", msg).

The key invariants are: `new TypeError("x") instanceof TypeError` AND `instanceof Error`, `.name === "TypeError"`, `.message === "x"`, `Object.getPrototypeOf(TypeError) === Error`, `Object.getPrototypeOf(TypeError.prototype) === Error.prototype`.

### Current state

[`vm.zig:2725-2766`](../../src/js/kotori/vm.zig) implements the `Error` + sub-error bootstrap. Reading carefully:

- `error_proto` created ([`vm.zig:2727`](../../src/js/kotori/vm.zig)), stored on `self.error_proto`, gets `name = "Error"`, `message = ""`, and `toString`. Good.
- `error_ctor` created, gets `prototype = error_proto`, `name = "Error"`, `error_proto.constructor = error_ctor`. `error_ctor.[[Prototype]] = function_proto`. Registered as global `Error`. Good.
- Sub-error loop: for `TypeError, ReferenceError, SyntaxError, RangeError, URIError, EvalError, AggregateError`:
  - `sub_proto = createObj({})`, `sub_proto.prototype = error_proto` ✓ (prototype-side chain)
  - `sub_proto.name = <err_name>`, `.message = ""`, `.toString` installed ✓
  - `sub_ctor.prototype = sub_proto` ✓ (ctor's `prototype` property)
  - `sub_ctor.name = <err_name>` ✓
  - `sub_proto.constructor = sub_ctor` ✓ (self-reference)
  - `sub_ctor.[[Prototype]] = error_ctor` ✓ (class-side chain)
  - Registered as global `<err_name>` ✓

**So the bootstrap is essentially correct.** The gap is **construction-time** behavior:

1. [`vm.zig:9153-9180`](../../src/js/kotori/vm.zig) (`nativeErrorConstructor`) — used for *all* error types (Error, TypeError, etc.) via shared function pointer. Reading it: when called without `new`, it manually sets `err_obj.prototype = vm.error_proto` — **always `Error.prototype`, never the sub-class prototype.** See [`vm.zig:9158`](../../src/js/kotori/vm.zig).
2. Even when called *with* `new`, the `construct` opcode path wires up `prototype` from the constructor's `prototype` property. But the shared `nativeErrorConstructor` pre-sets it, so the order matters. The comment on [`vm.zig:9156-9157`](../../src/js/kotori/vm.zig) says "Prototype is set by construct opcode when called with `new`. When called without `new`, we default to Error.prototype." — but this defaults to `Error.prototype` for *all* sub-types too, so `TypeError("msg") instanceof TypeError === false`.
3. The `name` property is not set at construction — the constructor relies entirely on the instance inheriting `name` from the prototype. That's actually spec-correct for `new TypeError("x")` — `x.name` reads via prototype chain. But it means there's no instance-level `name`, so `assert_false(ex.hasOwnProperty("name"))` should pass. This test *is* what [`DOMException-constructor-behavior.any.js:14-19`](/tmp/wpt/webidl/ecmascript-binding/es-exceptions/DOMException-constructor-behavior.any.js) asserts, and it's correct.
4. **`stack` property**: never set. Spec-wise, `stack` is not in ECMA-262 — it's a de facto standard. WPT does not assert it directly in most DOMException tests. We will *not* add `stack` in 0A; defer to a later layer.
5. `createErrorObj` ([`vm.zig:2987-3006`](../../src/js/kotori/vm.zig)) — used by engine-internal `pending_throw` — already does the right thing (looks up constructor prototype via `self.globals.get(err_name)`). Good.
6. `throwTypeError` ([`vm.zig:2948-2972`](../../src/js/kotori/vm.zig)) also does the right thing. Good.

### Gap

The single remaining gap is: **a JS-level `new TypeError("x")` call goes through `nativeErrorConstructor`, which hardcodes `err_obj.prototype = error_proto`. The construct opcode *may* then fix it, but only if it runs post-native. Need to trace.**

Looking at [`vm.zig:1648`](../../src/js/kotori/vm.zig) (construct opcode path) and the companion at [`vm.zig:710`](../../src/js/kotori/vm.zig) — in both, after the native returns, the code does **not** override `result.asJsObject().prototype`. The native function's self-set `prototype = error_proto` wins.

So: `new TypeError("x").__proto__ === Error.prototype` (wrong) instead of `TypeError.prototype`.

Failing assertions:
- `new TypeError("x") instanceof TypeError` — **false** (should be true)
- `(new RangeError()).constructor === RangeError` — **false** (reads via prototype chain, hits `Error.prototype.constructor === Error`)
- `Object.getPrototypeOf(new SyntaxError()) === SyntaxError.prototype` — **false**

### Proposed change

The cleanest fix: give `nativeErrorConstructor` access to *which* error type it was invoked as. Two options:

**Option A** — one shared function, introspects via `getCallerFuncObj()`:

In `nativeErrorConstructor`, look at the function object being called (available via the stack — see [`vm.zig:3836`](../../src/js/kotori/vm.zig) where `callJsFunction` already pushes `func_val` onto the stack before calling the native, commenting "so getCallerFuncObj can find it"). Read that func_obj's `prototype` property → use as the new error's prototype. If not found, fall back to `error_proto`.

**Option B** — dedicated constructors per type:

Introduce `nativeTypeErrorConstructor`, `nativeRangeErrorConstructor`, etc. Each one is a 3-line wrapper that calls a shared helper with the type name. More code, but zero introspection.

**Recommendation: Option A** — less duplication, and the `getCallerFuncObj` machinery already exists.

Pseudocode for the fix at [`vm.zig:9153-9160`](../../src/js/kotori/vm.zig):

```zig
fn nativeErrorConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const err_obj = try vm.createObj(.{});

    // Look up the actual constructor being invoked — the caller func obj was
    // pushed onto the stack by callJsFunction immediately before this call.
    // See getCallerFuncObj in vm.zig.
    const caller_fn = vm.getCallerFuncObj();  // existing helper
    if (caller_fn) |fn_obj| {
        if (fn_obj.getProperty(vm.pool.intern("prototype") catch error_proto_sid)) |proto_val| {
            if (proto_val.isObject()) err_obj.prototype = proto_val.asJsObject();
        }
    }
    if (err_obj.prototype == null and vm.error_proto != null) {
        err_obj.prototype = vm.error_proto;
    }
    // ... rest unchanged (message handling) ...
}
```

If `getCallerFuncObj` doesn't exist or returns null in this path, fall back to Option B.

#### Error.isError (Error-as-error membership test)

[`DOMException-is-error.any.js:6-9`](/tmp/wpt/webidl/ecmascript-binding/es-exceptions/DOMException-is-error.any.js) asserts `Error.isError(new DOMException())`. This is a Stage-3/4 TC39 addition (proposal-is-error). Out of scope for 0A — flag for a future layer.

### Test plan

1. **Unit**:
   - `new TypeError("x") instanceof TypeError` ✓
   - `new TypeError("x") instanceof Error` ✓
   - `(new RangeError("y")).name === "RangeError"` ✓
   - `(new RangeError("y")).message === "y"` ✓
   - `Object.getPrototypeOf(new URIError()) === URIError.prototype` ✓
2. **WPT**:
   - `webidl/ecmascript-binding/es-exceptions/DOMException-constructor-behavior.any.js` — ~20 subtests, many already passing via prototype inheritance but some may now pass cleanly.
   - `webidl/ecmascript-binding/es-exceptions/DOMException-custom-bindings.any.js` — asserts `Object.getPrototypeOf(DOMException.prototype) === Error.prototype` (already works per current code).
   - `dom/events/Event-constructors.any.js` — `assert_throws_js(TypeError, () => Event(""))` requires a real `TypeError`. Currently the `Event(...)` without-`new` path throws but produces an ordinary error with `name="TypeError"` that *does not pass `instanceof TypeError`*. Expected delta: +5–15 per Event-constructors file, across 20+ Event types.

### Risk

- **Getting `getCallerFuncObj` wrong**: If the helper returns null unexpectedly, all sub-error `new` calls fall back to `Error.prototype` — same as current bug. Not a regression; must verify.
- **No-new call path**: `TypeError("x")` (without `new`) per spec §20.5.6.2 also creates a sub-error instance (same as with `new`). My proposed code handles both because it always consults the caller fn object.
- **`construct` opcode post-fix**: After this change, if the generic construct opcode also sets `prototype` based on the constructor, double-set is fine because it sets the same value. Verify by reading [`vm.zig:1648-1700`](../../src/js/kotori/vm.zig).
- **Shared function pointer collision**: Multiple sub-ctors share `&nativeErrorConstructor`. That is exactly why introspection matters. Alternative Option B is safer if Option A has any subtle frame-pointer issue.

---

## Gap 4: Array callbacks honor `thisArg`

### Spec

ECMA-262 §23.1.3.12 (`Array.prototype.forEach(callbackFn [, thisArg])`):

> 1. Let O be ? ToObject(this value).
> 2. Let len be ? LengthOfArrayLike(O).
> 3. If IsCallable(callbackFn) is false, throw a TypeError exception.
> 4. Let k be 0.
> 5. Repeat, while k < len,
>    a. Let Pk be ! ToString(𝔽(k)).
>    b. Let kPresent be ? HasProperty(O, Pk).
>    c. If kPresent is true, then
>       i. Let kValue be ? Get(O, Pk).
>       ii. **Perform ? Call(callbackFn, thisArg, « kValue, 𝔽(k), O »).**
>    d. Set k to k + 1.

The call is made with `thisArg` as the `thisValue`, *not* `undefined`. Same pattern for `map`, `filter`, `find`, `findIndex`, `findLast`, `findLastIndex`, `some`, `every`. `reduce`/`reduceRight`/`sort` do *not* take `thisArg` (callback is invoked with `undefined`).

### Current state

Already mostly correct. [`vm.zig:3913-4101`](../../src/js/kotori/vm.zig):

- `nativeArrayForEach` (line 3913): `const thisArg = if (args.len > 1) args[1] else JsValue.undefined_val;` then `callJsFunction(callback, thisArg, &cb_args)` — **correct**.
- `nativeArrayMap` (line 3927): same pattern — **correct**.
- `nativeArrayFilter` (line 3945): same — **correct**.
- `nativeArrayFind` (line 4007): same — **correct**.
- `nativeArrayFindIndex` (line 4022): same — **correct**.
- `nativeArrayFindLast` (line 4037): same — **correct**.
- `nativeArrayFindLastIndex` (line 4055): same — **correct**.
- `nativeArraySome` (line 4073): same — **correct**.
- `nativeArrayEvery` (line 4088): same — **correct**.

These nine are all already correct.

**Anti-patterns** (spec-correct but worth flagging):
- `nativeArrayReduce` (line 3965): passes `JsValue.undefined_val` as `thisArg` — **correct** (reduce doesn't take thisArg).
- `nativeArrayReduceRight` (line 3988): ditto — **correct**.
- `nativeArraySort` (line 4103): passes `JsValue.undefined_val` for compareFn — **correct**.

### Gap

**Surprise finding**: The roadmap flags "audit forEach/map/filter/find/findIndex/findLast/findLastIndex/some/every" for `thisArg`, but all nine already propagate `thisArg`. The actual gap appears to be:

1. **No IsCallable check**: §23.1.3.12 step 3 says "If IsCallable(callbackFn) is false, throw a TypeError." Current code at [`vm.zig:3914`](../../src/js/kotori/vm.zig) says `if (!this.isObject() or args.len == 0) return JsValue.undefined_val;` — returns silently instead of throwing. If `callback` is not callable (e.g., a plain object), it goes into `callJsFunction` which at [`vm.zig:3849`](../../src/js/kotori/vm.zig) returns `JsValue.undefined_val` silently.
2. **Wrong early-return values**: If `args.len == 0`, spec says throw TypeError. `some`/`every`/`findIndex` etc. return `false`/`-1` instead.
3. **Non-array receivers**: §23.1.3.12 step 1 says `ToObject(this value)`, not "if this is an Array object". Current code at [`vm.zig:3916`](../../src/js/kotori/vm.zig) gates on `obj.obj_type == .array`. For generic array-likes (objects with `length` + integer-indexed properties) this returns `undefined` silently. Per spec, these should iterate.

These three behaviors *do* fail real WPT assertions. The most common one: `[1,2,3].forEach.call({length:2, 0:'a', 1:'b'}, cb)` — spec says iterate on the plain object using `length` lookup; kotori returns undefined without iterating.

### Proposed change

For each of the nine callback-taking methods:

1. **Throw TypeError on missing/non-callable callback**:
```zig
if (args.len == 0 or !isCallable(args[0])) return error.TypeError;
```
where `isCallable` checks `obj_type == .function or obj_type == .native_function`.

2. **Generic array-like iteration** (larger surgery): replace the `obj.obj_type == .array` check with a `ToObject` + `LengthOfArrayLike` pattern:
```zig
const len = try vm.lengthOfArrayLike(this); // reads .length property, ToUint32
var k: u32 = 0;
while (k < len) : (k += 1) {
    const k_sid = // index → string id
    const has = try vm.hasProperty(this, k_sid);
    if (has) {
        const kv = try vm.getProperty(this, k_sid);
        const cb_args = [_]JsValue{ kv, JsValue.initNumber(@floatFromInt(k)), this };
        _ = try vm.callJsFunction(callback, thisArg, &cb_args);
    }
}
```

`lengthOfArrayLike` and generic indexed access already exist internally for `Array.from` ([`vm.zig:4260-4290`](../../src/js/kotori/vm.zig) area) — extract into a shared helper.

3. **Keep thisArg propagation as-is** — no change needed; it's already spec-correct.

### Test plan

1. **Unit**:
   - `[1,2,3].forEach(cb, {tag: 'a'})` — verify callback's `this` is `{tag: 'a'}`.
   - `[].forEach(42)` — must throw `TypeError` (42 is not callable).
   - `Array.prototype.forEach.call({length: 2, 0: 'a', 1: 'b'}, cb)` — must iterate twice.
   - `[1,2,3].map(x => x*2)` — returns `[2,4,6]` (unchanged).
2. **WPT**:
   - WPT has `javascript/builtins/Array/forEach*` etc. in test262 fork — though not a direct WPT area, it's imported.
   - DOM tests that use `NodeList.forEach.call(...)` with thisArg — several in `dom/nodes/Element-*.html`.
   - `dom/events/EventListener-handleEvent.sub.html` exercises thisArg semantics on listener iteration.
   - Expected delta: +20–50 subtests across dom/ from the TypeError throw + generic iteration fixes. Much smaller than the roadmap's implicit share of the +400 because thisArg was already correct.

### Risk

- **Generic iteration regression**: switching from the array fast-path to the spec's generic form is ~4× slower for true arrays (property lookup per index vs. direct items[i] access). Mitigation: keep the fast-path for `.array` receivers, fall back to generic for array-likes.
- **TypeError for `args.len == 0`**: Some existing test fixtures may rely on the current silent-undefined behavior. Low risk because silent-undefined is clearly buggy; failing tests that relied on it were never spec-correct.
- **Holes vs. undefined**: §23.1.3.12 step 5c gates callback invocation on `HasProperty`, not just index < length. Dense arrays have all indices present, so the fast-path is fine; sparse arrays are rare in WPT. Explicit doc note: holes are deferred.

---

## Gap 5: Promise thenable detection

### Spec

ECMA-262 §27.2.4.7 (`Promise.resolve(x)`):

> 1. Let C be the this value.
> 2. If C is not an Object, throw a TypeError exception.
> 3. Return ? PromiseResolve(C, x).

And §27.2.1.4 (`PromiseResolve(C, x)`):

> 1. If IsPromise(x) is true, then
>    a. Let xConstructor be ? Get(x, "constructor").
>    b. If SameValue(xConstructor, C) is true, return x.
> 2. Let promiseCapability be ? NewPromiseCapability(C).
> 3. Perform ? Call(promiseCapability.[[Resolve]], undefined, « x »).
> 4. Return promiseCapability.[[Promise]].

And §27.2.1.3.2 (Promise Resolve Functions, body when `resolution` is passed):

> 7. If Type(resolution) is not Object, then
>    a. Perform FulfillPromise(promise, resolution).
>    b. Return undefined.
> 8. Let then be Completion(Get(resolution, "then")).
> 9. If then is an abrupt completion, then
>    a. Perform RejectPromise(promise, then.[[Value]]).
>    b. Return undefined.
> 10. Let thenAction be then.[[Value]].
> 11. **If IsCallable(thenAction) is false, then**
>     a. **Perform FulfillPromise(promise, resolution).**
>     b. **Return undefined.**
> 12. Let thenJobCallback be HostMakeJobCallback(thenAction).
> 13. Let job be NewPromiseResolveThenableJob(promise, resolution, thenJobCallback).
> 14. Perform HostEnqueuePromiseJob(job.[[Job]], job.[[Realm]]).

Three branches, in order: **(a) IsPromise same-constructor → return x identically. (b) thenable → schedule thenable-adoption job. (c) not-object OR object with non-callable `then` → fulfill with the value itself.**

### Current state

[`vm.zig:4660-4671`](../../src/js/kotori/vm.zig) — `nativePromiseResolve`:

```zig
fn nativePromiseResolve(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const value = if (args.len > 0) args[0] else JsValue.undefined_val;
    if (value.isObject()) {
        if (value.asJsObject().obj_type == .promise) return value;
    }
    const promise = try vm.createPromiseObj();
    try vm.resolvePromise(promise, value);
    return JsValue.initObject(promise);
}
```

Then `resolvePromise` ([`vm.zig:4448-4535`](../../src/js/kotori/vm.zig)) already has **correct** thenable handling:
- fast-path for `.obj_type == .promise` (lines 4459-4474)
- slow-path for any object with callable `.then` (lines 4475-4506)
- else fulfill with value (lines 4509-4535)

**The fast-path in `nativePromiseResolve` is the bug**: `if (value is native promise) return value` — spec requires `SameValue(xConstructor, C)` (i.e., the constructor check). Without the check, a promise *subclass* instance or a promise from a different realm would short-circuit incorrectly.

**Bigger bug: the `resolvePromise` slow-path delegates thenable invocation to `callJsFunction` *synchronously***, not via a microtask. Spec §27.2.1.3.2 step 13-14 requires scheduling `NewPromiseResolveThenableJob` as a *job*, not an immediate call.

### Gap

Observable differences:

1. `Promise.resolve(nativePromise)` where the promise has a `.constructor` set to a subclass — current code returns the original promise; spec says only return identically if same constructor.
2. `Promise.resolve({then: fn})` — current code calls `fn` synchronously during `resolvePromise`. Spec requires it to run as a microtask. This is observable:
   ```js
   let order = [];
   Promise.resolve({then(resolve) { order.push('then'); resolve('x'); }})
     .then(v => order.push('resolved: ' + v));
   order.push('sync');
   // Spec: order === ['sync', 'then', 'resolved: x']
   // kotori current: order === ['then', 'sync', 'resolved: x']
   ```
3. `Promise.resolve({then: 42})` — current code silently fulfills with the object (the IsCallable check at [`vm.zig:4482-4485`](../../src/js/kotori/vm.zig) correctly falls through). ✓
4. `Promise.resolve({get then() { throw new Error("x"); }})` — per spec §27.2.1.3.2 step 8-9 this must *reject* the promise with the thrown error. Current code at [`vm.zig:4479`](../../src/js/kotori/vm.zig) uses plain `getProperty` which does not invoke getters; the thrown error is never produced. Separate gap — accessors on `.then` are not honored.

### Proposed change

**Change 1**: Fix `nativePromiseResolve` same-constructor check.

```zig
fn nativePromiseResolve(ctx: *anyopaque, this_val: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const value = if (args.len > 0) args[0] else JsValue.undefined_val;
    // §27.2.1.4 step 1: IsPromise(x) && SameValue(x.constructor, this) → return x.
    if (value.isObject() and value.asJsObject().obj_type == .promise) {
        const ctor_id = try vm.pool.intern("constructor");
        const x_ctor = value.asJsObject().getProperty(ctor_id) orelse JsValue.undefined_val;
        if (x_ctor.bits == this_val.bits) return value;
    }
    const promise = try vm.createPromiseObj();
    try vm.resolvePromise(promise, value);
    return JsValue.initObject(promise);
}
```

Note: the current signature at [`vm.zig:4661`](../../src/js/kotori/vm.zig) is `fn nativePromiseResolve(ctx, _: JsValue, args)` — the `this` is explicitly ignored. Change to `this_val` to access the constructor.

**Change 2**: Make thenable adoption a microtask.

Currently [`vm.zig:4492-4506`](../../src/js/kotori/vm.zig) calls `then.call(value, resolve, reject)` synchronously inside `resolvePromise`. The fix: enqueue a microtask that does the call.

Implementation:

a. Add a new microtask variant in the existing `microtasks` queue (type at [`vm.zig`, search `microtasks` append sites for the union definition]). Add:
```zig
.thenable_job = struct { target_promise: *JsObject, thenable: JsValue, then_fn: JsValue },
```

b. In `resolvePromise`, replace the synchronous call at [`vm.zig:4492-4502`](../../src/js/kotori/vm.zig) with:
```zig
try self.microtasks.append(self.allocator, .{ .thenable_job = .{
    .target_promise = promise,
    .thenable = value,
    .then_fn = then_val,
}});
return;
```

c. In the microtask pump (search for `switch (task)` — part of the event loop in vm.zig), handle `.thenable_job` by doing what the synchronous block currently does: create resolve/reject functions and call `then_fn.call(thenable, resolve, reject)`.

**Change 3**: Honor getters on `.then` lookup.

Replace [`vm.zig:4479`](../../src/js/kotori/vm.zig) `val_obj.getProperty(then_id)` with the getter-invoking equivalent (the accessor-descriptor path at [`object.zig:153-168`](../../src/js/kotori/object.zig) `findAccessorDescriptor` exists; wrap invocation in a try/catch and route abrupt completions to `rejectPromise`).

This is a slightly bigger change because getter invocation goes through the VM call path; safest to pull the existing property-get opcode's accessor-invocation code into a helper and reuse it here.

### Test plan

1. **Unit**:
   - `let p = Promise.resolve(42); Promise.resolve(p) === p` ✓
   - `let t = {then(res) { res(99); }}; Promise.resolve(t).then(v => assert(v === 99))`
   - Thenable microtask ordering: `let log = []; Promise.resolve({then(r) { log.push('then'); r(1); }}).then(v => log.push(v)); log.push('sync'); // log === ['sync', 'then', 1]`
   - Throwing getter: `Promise.resolve({get then() { throw 'e'; }}).catch(e => assert(e === 'e'))`
2. **WPT**:
   - `promises/promise-resolve-thenable.html` — does not exist as a file in /tmp/wpt; the coverage is inside `streams/`, `html/` and various testharness-embedded tests.
   - `html/webappapis/microtask-queuing/queue-microtask-*` — exercise microtask ordering.
   - `service-workers/cache-storage/*` — heavy Promise chains with thenable adoption.
   - Expected delta: harder to quantify because most WPT Promise tests assume spec-correct microtask ordering and *currently fail in confusing ways*. Conservative estimate: +30–80 subtests, with some cascading (once a thenable resolves correctly, downstream `.then` chains now reach their assertions).

### Risk

- **Microtask-queue reentrancy**: Thenable `.then` calls can trigger synchronous resolve, which enqueues more microtasks, which may include more thenables. The existing microtask pump must already handle this; verify by re-reading the event loop loop-body.
- **Constructor comparison**: Using `bits == bits` for SameValue is correct for object identity but doesn't handle the `NaN !== NaN` case. Since we're comparing constructor functions (objects), `bits` equality suffices — this is object identity by design.
- **Accessor-on-`then` regression**: If the existing synchronous call path is relied upon by any already-passing test, moving it to a microtask could reorder side effects. Mitigation: run the full WPT suite pre/post change and diff.
- **The `callJsFunction` error-swallowing at [`vm.zig:4497-4501`](../../src/js/kotori/vm.zig)**: Currently only `TypeError`/`RangeError` reject the promise; all other Zig errors propagate. This is already mildly wrong (should reject on *any* completion), but fixing it is a larger touch. Flag for Layer 0A+1.

---

## Implementation ordering

Each gap is independent; they can be done in any order. But a sensible progression minimizes rework:

1. **Gap 1 + Gap 2 together** (same refactor): introduce `registerNativeMethodArity` / `createNamedNativeFn`, rewrite all ~200 call sites, remove ad-hoc `name` setters on error ctors. One commit. Low-risk.
2. **Gap 4** (Array callback polish): add `IsCallable` check + generic iteration helper. One commit. Touches only the array method implementations.
3. **Gap 3** (Error chain): fix `nativeErrorConstructor` to introspect caller fn. One commit. Touches one function (and possibly `construct` opcode, if Option A needs a helper).
4. **Gap 5** (Promise thenable): same-constructor check + microtask-ify thenable adoption + accessor-on-then getter. Two commits — (a) same-constructor + microtask, (b) accessor-on-then. Highest risk, do last.

All five fit in a single PR if desired, but four commits make bisection easier.

### File touch summary

- `src/js/kotori/vm.zig` — all five gaps.
- `src/js/kotori/object.zig` — zero (no struct changes required; `defineOwnProperty` + `PropertyDescriptor` already exist).
- No changes to `parser.zig`, `compiler.zig`, `bytecode.zig`, `lexer.zig`, `ast.zig`, `string_pool.zig`, `value.zig`, `kotori.zig`, `kotori_io.zig`.

Single-file parallelism constraint from the master roadmap: Layer 0A uses `vm.zig` exclusively, which means Layer 0A must run as a single-agent sequential work item — no parallel splitting within 0A. Parallel with other layers (1A on `dom_document.zig`, 1B on `events.zig`) is fine.

---

## Acceptance criteria

Layer 0A is complete when all of the following are true:

1. **Unit tests pass**:
   - `zig build test` — existing suite + new cases from each gap's test plan.
   - New test module `src/js/kotori/tests/builtin_polish_test.zig` (or embedded in existing harness) asserts:
     - `Array.prototype.forEach.length === 1` and `.name === "forEach"` — and ditto for 15+ representative methods.
     - `new TypeError("x") instanceof TypeError` and ditto for all six sub-error types.
     - `[].forEach(42)` throws `TypeError`.
     - `Promise.resolve(p) === p` (identity for same-constructor promise).
     - Thenable microtask ordering test.
2. **WPT deltas (measured against `tests/wpt/baseline_results.txt`)**:
   - `dom/nodes` subtests increase by ≥ +150 (primarily from Document-createEvent aliases plus Event constructor TypeError assertions).
   - `dom/events` subtests increase by ≥ +40 (Event-constructors.any.js block).
   - `webidl/ecmascript-binding` area gains ≥ +10 (builtin-function-properties across Blob/URL/etc.).
   - No regressions in any area.
3. **Spec traceability**: every changed function has a code comment citing the ECMA-262 section number (e.g., `// §27.2.1.4 step 1: IsPromise same-constructor fast path`).
4. **No new allocations leaked**: `zig build test -Dcheck-leaks` passes.
5. **Binary size**: `zig-out/bin/suzume` size increase is ≤ 50 KB (budget: builtins metadata is static data).

If any acceptance criterion fails, the root cause is investigated before committing — per master roadmap principle 5 ("Zero regressions: a fix in layer N that drops subtests in layer <N is rejected; root cause is analyzed before resuming").

---

## Out of scope

Explicitly deferred to other layers:

- `Function.prototype.bind` length-correction (§20.2.3.2 step 7) — roadmap Layer 0 follow-up.
- `Error.isError` method (proposal-is-error Stage 3) — roadmap Layer 0 follow-up; `DOMException-is-error.any.js` will remain failing.
- Stack trace (`error.stack`) — not in ECMA-262 baseline; Layer 4 or later.
- `Object.getOwnPropertyDescriptor(Blob.prototype, "size").get` returning a getter with `length === 0, name === "get size"` — requires the accessor getter/setter distinct-identity infrastructure, which is a separate spec (WebIDL §3.7 reflection). Layer 4A.
- Array sparse-hole `HasProperty` semantics in callback methods — deferred; holes are rare in WPT fixtures.
- `thisArg` for `.flat`/`.flatMap` callback — `.flatMap` *does* take a thisArg per §23.1.3.11 and is currently ignored; bundled with Gap 4 during implementation if trivial, else flagged.
- Promise subclass realm-aware constructor lookup — Layer 0 follow-up; single-realm assumption is safe for 0A.
- Revamping native function reflection to a first-class struct (adding `length`/`name` as native fields on `JsObject.ObjData.native_fn` rather than properties) — would speed up `fn.length` reads but breaks the "properties are the source of truth" invariant needed for writable/configurable semantics. Reject: use descriptors.

---

## References

- `src/js/kotori/vm.zig:2325-2903` — global init block with all `registerNativeMethod` call sites (Gap 1/2).
- `src/js/kotori/vm.zig:2463-2469` — Function.prototype creation (Gap 1/2).
- `src/js/kotori/vm.zig:2725-2766` — Error + sub-error ctor bootstrap (Gap 3).
- `src/js/kotori/vm.zig:2915-2921` — `registerNativeMethod` helper (Gap 1/2 refactor target).
- `src/js/kotori/vm.zig:2946-2972` — `throwTypeError` (correctly chained — reference for Gap 3 pattern).
- `src/js/kotori/vm.zig:2987-3006` — `createErrorObj` (correctly chained).
- `src/js/kotori/vm.zig:3913-4101` — Array callback methods (Gap 4).
- `src/js/kotori/vm.zig:4448-4535` — `resolvePromise` (Gap 5 thenable path).
- `src/js/kotori/vm.zig:4660-4671` — `nativePromiseResolve` (Gap 5 fix site).
- `src/js/kotori/vm.zig:7955-7960` — `createNativeFn` helper (Gap 1/2 refactor target).
- `src/js/kotori/vm.zig:9153-9180` — `nativeErrorConstructor` (Gap 3 fix site).
- `src/js/kotori/object.zig:58-127` — `JsObject` struct + `ObjType` enum.
- `src/js/kotori/object.zig:153-168` — `findAccessorDescriptor` (Gap 5 helper).
- `src/js/kotori/object.zig:342-350` — `defineOwnProperty` (Gap 1/2 helper).
- `/tmp/wpt/webidl/ecmascript-binding/builtin-function-properties.any.js` — primary WPT witness for Gap 1/2.
- `/tmp/wpt/webidl/ecmascript-binding/es-exceptions/DOMException-constructor-and-prototype.any.js` — Gap 3 witness.
- `/tmp/wpt/webidl/ecmascript-binding/es-exceptions/DOMException-constructor-behavior.any.js` — Gap 3 witness.
- `/tmp/wpt/webidl/ecmascript-binding/es-exceptions/DOMException-custom-bindings.any.js` — Gap 3 witness (Error.prototype inheritance).
- `/tmp/wpt/dom/nodes/Document-createEvent.js` + `Document-createEvent.https.html` — Gap 3 witness (assert_throws for plural aliases).
- `/tmp/wpt/dom/events/Event-constructors.any.js` — Gap 3 witness (real TypeError).
- ECMA-262 2023, §10.2.8 SetFunctionName, §10.2.9 SetFunctionLength, §20.2.4.1-2, §20.5, §23.1.3, §27.2.
