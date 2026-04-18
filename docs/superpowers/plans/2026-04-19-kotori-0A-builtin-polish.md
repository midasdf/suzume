# kotori Layer 0A — Builtin Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close five small ECMA-262 builtin compliance gaps in `src/js/kotori/vm.zig` so that (1) every native function exposes spec-correct `length` + `name`, (2) `Array.prototype.*` callbacks throw `TypeError` on non-callable and iterate generic array-likes, (3) `new TypeError(...) instanceof TypeError` holds for every sub-error type, (4) `Promise.resolve` honors same-constructor identity plus thenable microtask semantics, and (5) a throwing `.then` getter rejects the promise. Together these unblock an estimated +450–600 WPT subtests across `dom/nodes`, `dom/events`, and `webidl/ecmascript-binding`.

**Architecture:** All edits are confined to `src/js/kotori/vm.zig`. Introduce two new registration helpers (`registerNativeMethodArity`, `createNamedNativeFn`) that install `length` + `name` as non-writable/non-enumerable/configurable own descriptors via the existing `defineOwnProperty` slow-path. Rewrite ~200 call sites to pass declared arity. Fix `nativeErrorConstructor` to introspect the invoked constructor via the pre-existing `getCallerFuncObj` helper. Extend Array callback paths with `IsCallable` validation and a reusable `lengthOfArrayLike` helper. Fix `nativePromiseResolve` to perform the spec's same-constructor check and move thenable-adoption onto the existing microtask queue; invoke accessor getters on `.then` lookup with reject-on-throw.

**Tech Stack:** Zig 0.15.2, kotori JS engine (in-tree at `src/js/kotori/`), WPT (Web Platform Tests).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-0A-builtin-polish-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` § Layer 0A

---

## File Structure

### Files to create
- None. All work lands in existing files.
- (Optional) `src/js/kotori/tests/builtin_polish_test.zig` — may be either a new module or additions to the existing `zig build test` harness; mirror whatever convention is already used by `kotori.zig` tests.

### Files to modify
- `src/js/kotori/vm.zig` — sole implementation file. Ranges by task:
  - L2325-L2903 — global init block; ~200 `registerNativeMethod` call sites rewritten to `registerNativeMethodArity` (Task 1).
  - L2717, L2735, L2740, L2756, L2759, L2779, L2781, L2798, L2800, L2806, L2813, L2838, L2844, L2846, L2852, L2858, L2871, L2888 — `createNativeFn` ctor sites rewritten to `createNamedNativeFn` (Task 1).
  - L2915-L2921 — `registerNativeMethod` helper; kept as thin back-compat wrapper, new `registerNativeMethodArity` added (Task 1).
  - L2740, L2759, L2781 — ad-hoc `.name` setters on Error constructors deleted (Task 1).
  - L3913-L4101 — nine Array callback methods (`forEach`, `map`, `filter`, `find`, `findIndex`, `findLast`, `findLastIndex`, `some`, `every`); add IsCallable + generic iteration (Task 2).
  - L9153-L9172 — `nativeErrorConstructor`; introspect caller fn (Task 3).
  - L4660-L4671 — `nativePromiseResolve`; same-constructor check (Task 4).
  - L4448-L4535 — `resolvePromise` slow-path; microtask-ify thenable adoption (Task 4).
  - L4570-L4631 — `runMicrotasks`; add `.thenable_job` arm (Task 4).
  - L64, L109 — `microtasks` field + `MicrotaskEntry` union; extend with `.thenable_job` variant (Task 4).
  - L4479 — replace `getProperty(then_id)` with accessor-invoking getter path; reject-on-throw (Task 5).
  - L7955-L7960 — `createNativeFn`; kept, new `createNamedNativeFn` added (Task 1).

### Files to NOT modify
- `src/js/kotori/object.zig` — `JsObject`, `PropertyDescriptor`, `defineOwnProperty`, `findAccessorDescriptor` already sufficient.
- `src/js/kotori/parser.zig`, `compiler.zig`, `bytecode.zig`, `lexer.zig`, `ast.zig`, `string_pool.zig`, `value.zig`, `kotori.zig`, `kotori_io.zig` — no changes.
- Any file outside `src/js/kotori/`.

---

## Task 0: P0 Audit — No-Code Gate

**Files:** None modified. Produces a scratch notes file (`/tmp/0a-audit.md`) to reference during later tasks.

**Purpose:** Lock down current-HEAD call-site counts, confirm the spec's cited line ranges still apply, capture WPT baselines, and verify the shared helpers the plan depends on (`getCallerFuncObj`, `defineOwnProperty`, `MicrotaskEntry`) actually exist.

- [ ] **Step 0.1: Enumerate `registerNativeMethod` call sites**

Run:
```bash
cd ~/suzume
grep -n "registerNativeMethod(" src/js/kotori/vm.zig | wc -l
grep -n "registerNativeMethod(" src/js/kotori/vm.zig > /tmp/0a-regsites.txt
```

Expected: ~273 matches (spec quote: "Approximately 200 call sites"). Record the exact number and confirm the highest line is within L2325-L2903.

- [ ] **Step 0.2: Enumerate `createNativeFn` caller sites**

Run:
```bash
grep -n "createNativeFn(" src/js/kotori/vm.zig
```

Expected: ~35 matches including the definition at L7955, the helper at L5530, and ~30 ctor/global-fn sites between L2387 and L2888. Confirm the spec's cited lines (L2717, L2735, L2779, L2798, L2800, L2806, L2813, L2838, L2844, L2846, L2852, L2858, L2871, L2888) all exist and are unmodified since HEAD `beb7a4b`.

- [ ] **Step 0.3: Confirm `getCallerFuncObj` availability**

Run:
```bash
grep -n "fn getCallerFuncObj" src/js/kotori/vm.zig
grep -c "getCallerFuncObj(vm)" src/js/kotori/vm.zig
```

Expected: one definition near L8288 and ≥ 6 existing callers. This proves Option A in the spec's Gap 3 is viable with no additional plumbing. If zero callers found, fall back to Option B (per-type wrapper ctors) during Task 3.

- [ ] **Step 0.4: Confirm `defineOwnProperty` signature**

Run:
```bash
grep -n "pub fn defineOwnProperty" src/js/kotori/object.zig
```

Expected: one match near L342-L350 with signature `pub fn defineOwnProperty(self: *JsObject, allocator: Allocator, name: StringId, desc: PropertyDescriptor) !void`. Record the exact argument order — the length/name installation snippet in Task 1 depends on it.

- [ ] **Step 0.5: Confirm `MicrotaskEntry` union shape**

Run:
```bash
grep -n "pub const MicrotaskEntry" src/js/kotori/vm.zig
grep -n "microtasks:" src/js/kotori/vm.zig | head -3
```

Expected: `MicrotaskEntry` union definition near L109; backing list at L64. Read the existing variants (`.promise_reaction`, `.resume_async`, …) and record them — Task 4 adds `.thenable_job` alongside them.

- [ ] **Step 0.6: Confirm Array callback methods are at the cited lines**

Run:
```bash
grep -n "fn nativeArrayForEach\|fn nativeArrayMap\|fn nativeArrayFilter\|fn nativeArrayFind\|fn nativeArrayFindIndex\|fn nativeArrayFindLast\|fn nativeArrayFindLastIndex\|fn nativeArraySome\|fn nativeArrayEvery" src/js/kotori/vm.zig
```

Expected: nine matches between L3913 and L4088 matching the spec's table at §"Gap 4 / Current state". Record any drift.

- [ ] **Step 0.7: Confirm no pre-existing `lengthOfArrayLike` / `isCallable`**

Run:
```bash
grep -n "lengthOfArrayLike\|fn isCallable\b" src/js/kotori/vm.zig
```

Expected: no matches. Confirms Task 2 must introduce both helpers. If a private `isCallable` exists under a different name, use it.

- [ ] **Step 0.8: Record WPT baselines**

Run (each in its own line for clean timing data):
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes  2>&1 | tee /tmp/0a-dom-nodes-base.txt
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events 2>&1 | tee /tmp/0a-dom-events-base.txt
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 webidl      2>&1 | tee /tmp/0a-webidl-base.txt
```

Record pass/fail totals. These become the reference deltas in Task 6's acceptance gate (spec §Acceptance — ≥+150 dom/nodes, ≥+40 dom/events, ≥+10 webidl).

- [ ] **Step 0.9: Confirm baseline `zig build test` is green**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -20
```

Expected: 0 failures. Any pre-existing failure must be documented in `/tmp/0a-audit.md` before proceeding; fixing it is out of scope for 0A but is required prior-art for delta measurement.

- [ ] **Step 0.10: Write audit notes (no repo commit)**

Write all Steps 0.1-0.9 findings to `/tmp/0a-audit.md`. No git activity. P0 is a pure read-gate.

---

## Task 1: Gap 1 + Gap 2 — Native fn `.length` and `.name`

**Files:**
- Modify: `src/js/kotori/vm.zig` — new helpers at L2915 / L7955 region, ~200 call-site rewrites at L2325-L2903, ~14 ctor-site rewrites, delete three ad-hoc name setters.

**Purpose:** Give every native function a spec-correct `length` (declared arity per ECMA-262 §10.2.9) and `name` (per §10.2.8) installed as `{writable:false, enumerable:false, configurable:true}` own descriptors. Unblocks `Reflect.ownKeys(ctor).slice(0,3) === ["length","name","prototype"]` and `fn.length`/`fn.name` reads across every WebIDL interface, DOM ctor, Array method, and Promise primitive.

- [ ] **Step 1.1: Add `registerNativeMethodArity` and `createNamedNativeFn` helpers**

Below the existing `registerNativeMethod` at L2915 insert `registerNativeMethodArity`, and below `createNativeFn` at L7955 insert `createNamedNativeFn`. Both delegate to a shared private helper that installs the reflection descriptors:

```zig
/// Install `length` and `name` own-descriptors per §10.2.8/§10.2.9.
/// attrs = { writable:false, enumerable:false, configurable:true }
fn installFnReflection(self: *VM, fn_obj: *JsObject, name: []const u8, length: u16) !void {
    const len_sid = try self.pool.intern("length");
    const name_sid = try self.pool.intern("name");
    const name_str_sid = try self.pool.intern(name);
    try fn_obj.defineOwnProperty(self.allocator, len_sid, .{
        .data = .{
            .value = JsValue.initNumber(@floatFromInt(length)),
            .attrs = .{ .writable = false, .enumerable = false, .configurable = true },
        },
    });
    try fn_obj.defineOwnProperty(self.allocator, name_sid, .{
        .data = .{
            .value = JsValue.initString(name_str_sid),
            .attrs = .{ .writable = false, .enumerable = false, .configurable = true },
        },
    });
}

pub fn registerNativeMethodArity(
    self: *VM, target: *JsObject, name: []const u8, func: NativeFn, length: u16,
) !void {
    const fn_obj = try self.allocator.create(JsObject);
    fn_obj.* = .{ .obj_type = .native_function, .data = .{ .native_fn = func } };
    try self.objects.append(self.allocator, fn_obj);
    try self.installFnReflection(fn_obj, name, length);
    const key = try self.pool.intern(name);
    try target.setProperty(self.allocator, key, JsValue.initObject(fn_obj));
}

fn createNamedNativeFn(self: *VM, name: []const u8, func: NativeFn, length: u16) !*JsObject {
    const fn_obj = try self.allocator.create(JsObject);
    fn_obj.* = .{ .obj_type = .native_function, .data = .{ .native_fn = func } };
    try self.objects.append(self.allocator, fn_obj);
    try self.installFnReflection(fn_obj, name, length);
    return fn_obj;
}
```

Keep the existing `registerNativeMethod` and `createNativeFn` as-is; subsequent steps migrate callers gradually so the back-compat shim is never exercised by a moved-ahead caller. After Step 1.6 nothing calls them; they can be deleted or retained for any test-only sites — decide at Step 1.7.

- [ ] **Step 1.2: Write unit test for helper correctness**

Append to the existing test harness (match the file convention revealed by `grep -n "test \"" src/js/kotori/*.zig | head`). Minimum assertions:

```zig
test "installFnReflection sets length/name with spec descriptor attrs" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const d = Object.getOwnPropertyDescriptor(Array.prototype.slice, "length");
        \\ globalThis.__w = d.writable;
        \\ globalThis.__e = d.enumerable;
        \\ globalThis.__c = d.configurable;
        \\ globalThis.__v = d.value;
    );
    // After Step 1.6 these should all be set; during Step 1.2 the test
    // will fail (length is still undefined). Commit the test now, run
    // green after Step 1.6.
}
```

Gate: test stays red until Step 1.6 completes. This is intentional TDD; if it ever goes green before Step 1.6 that means a side-effect changed the behavior and you must investigate.

- [ ] **Step 1.3: Add the canonical arity table as a comptime const**

Immediately above `installFnReflection` add:

```zig
const BuiltinArity = struct { name: []const u8, length: u16 };

/// Declared arity per ECMA-262 section headings (rest-args and defaults
/// excluded). Used as a compile-time sanity check; look up via name
/// equality in tests. Non-exhaustive; callers also pass explicit length
/// numbers.
const builtin_arity_table = [_]BuiltinArity{
    .{ .name = "push", .length = 1 },
    .{ .name = "pop", .length = 0 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "map", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "find", .length = 1 },
    .{ .name = "findIndex", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "reduceRight", .length = 1 },
    .{ .name = "concat", .length = 1 },
    .{ .name = "isArray", .length = 1 },
    .{ .name = "keys", .length = 1 },
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "assign", .length = 2 },
    .{ .name = "create", .length = 2 },
    .{ .name = "replace", .length = 2 },
    .{ .name = "resolve", .length = 1 },
    .{ .name = "all", .length = 1 },
    .{ .name = "then", .length = 2 },
    .{ .name = "catch", .length = 1 },
    .{ .name = "call", .length = 1 },
    .{ .name = "apply", .length = 2 },
    .{ .name = "bind", .length = 1 },
    // ...extend as encountered during the Step 1.4 rewrite
};
```

The table is documentation — it does not drive codegen. During Step 1.4 use the `length` values from the spec's Gap-1 arity table directly.

- [ ] **Step 1.4: Rewrite ~200 `registerNativeMethod` call sites (L2325-L2903)**

This is the bulk of the task. For each line of the form:
```zig
try self.registerNativeMethod(array_proto, "slice", &nativeArraySlice);
```
rewrite to:
```zig
try self.registerNativeMethodArity(array_proto, "slice", &nativeArraySlice, 2);
```

Strategy:
- Process one global-init block at a time (e.g., Array.prototype methods L2325-~L2425, then Object, then String, etc.). Commit-free checkpoints after each block let you `git diff` and re-verify.
- Arity values come from the spec's Gap-1 table plus ECMA-262 section headings for any method not listed. Treat rest params (`...items`) and defaulted params as NOT counting.
- Never guess: for any method where the spec section is unclear, add a `// TODO(layer-0A+1): verify arity` comment and use the value that matches the existing Zig handler's conservative arg usage.

Verification after each block:
```bash
cd ~/suzume && zig build 2>&1 | tail -10
```
Must produce zero errors; `length=0` is the last-resort legal value for a still-migrated method, never a compile error.

- [ ] **Step 1.5: Rewrite `createNativeFn` ctor sites**

For each of the ~14 sites enumerated in Step 0.2 (spec §Gap 2 "Consumer-site cleanup"):
```zig
// Before
const date_ctor = try self.createNativeFn(&nativeDateConstructor);
// After
const date_ctor = try self.createNamedNativeFn("Date", &nativeDateConstructor, 7);
```

Name + arity reference (derive from ECMA-262):

| Line | Name | Arity | Section |
|------|------|-------|---------|
| 2717 | `Date` | 7 | §21.4.2.1 |
| 2735 | `Error` | 1 | §20.5.1 |
| 2756 | `<err_name>` (loop) | 1 | §20.5.6.2 |
| 2779 | `DOMException` | 2 | WebIDL §3.14 |
| 2798 | `WeakMap` | 0 | §24.3.1 |
| 2800 | `WeakSet` | 0 | §24.4.1 |
| 2806 | `ArrayBuffer` | 1 | §25.1.3 |
| 2813 | `Uint8Array` | 3 | §23.2 (TypedArray) |
| 2852 | `Boolean` | 1 | §20.3.1 |
| 2858 | `WeakRef` | 1 | §26.1.1 |
| 2871 | `Symbol` | 0 | §20.4.1 |
| 2888 | `Proxy` | 2 | §28.2.1 |

For helper fns (`atob`, `btoa`, `setTimeout`, `fetch`, `parseInt`, etc.) use `createNamedNativeFn` analogously.

- [ ] **Step 1.6: Delete redundant ad-hoc name setters on Error constructors**

Locate the three ad-hoc setters called out in spec §Gap 2 "Current state":

```bash
grep -n "setProperty(self.allocator, .*\"name\".*, JsValue.initString" src/js/kotori/vm.zig | sed -n '1,10p'
```

At L2740 (`error_ctor` name = "Error"), L2759 (`sub_ctor` name = err_name), and L2781 (`dom_exc_ctor` name = "DOMException") — delete the now-redundant setProperty calls. Step 1.5 already installed these via `createNamedNativeFn`'s descriptor-based path with spec-correct attrs; leaving the ad-hoc sets in place would overwrite with `{writable:true, enumerable:true}` — a regression.

- [ ] **Step 1.7: Decide on legacy helper retention**

Run:
```bash
grep -n "registerNativeMethod(" src/js/kotori/vm.zig
grep -n "createNativeFn(" src/js/kotori/vm.zig
```

If the only remaining callers are the definitions themselves (L2915, L7955) and the bound-call wrapper at L5530, either:
- **Keep** `registerNativeMethod` as a back-compat shim delegating to `registerNativeMethodArity(..., 0)`, same for `createNativeFn` → `createNamedNativeFn("", ..., 0)`.
- **Delete** if zero callers remain outside the definition file.

L5530's `createNativeFn(&nativeBoundCall)` builds a `Function.prototype.bind` wrapper whose spec-correct length (§20.2.3.2 step 7) is "max(0, target.length - bound_args)". Spec §Out of scope defers this to Layer 0A+1; for this task hard-code `length=0` via `createNamedNativeFn("", &nativeBoundCall, 0)` and add a `// TODO(0A+1): bound fn length` comment.

- [ ] **Step 1.8: Full build + test**

Run:
```bash
cd ~/suzume && zig build test 2>&1 | tail -40
```

Expected: Step 1.2's test passes. No existing test regresses. `zig build test -Dcheck-leaks` (if available in the repo's build.zig) also green.

- [ ] **Step 1.9: Extend unit coverage**

Add at least these assertions (Step 1.2 was the probe — now widen):

```zig
test "native fn length is spec-correct arity" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ globalThis.r = [
        \\   Array.prototype.forEach.length === 1,
        \\   Array.prototype.slice.length === 2,
        \\   Promise.resolve.length === 1,
        \\   Event.length === 1,
        \\   Object.defineProperty.length === 3,
        \\   TypeError.length === 1,
        \\ ].every(x => x === true);
    );
    // assert globalThis.r === true
}

test "native fn name is spec-correct" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ globalThis.r = [
        \\   Array.prototype.slice.name === "slice",
        \\   Promise.resolve.name === "resolve",
        \\   TypeError.name === "TypeError",
        \\ ].every(x => x === true);
    );
}

test "Reflect.ownKeys ordering is length, name, prototype" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const keys = Reflect.ownKeys(TypeError).slice(0, 3);
        \\ globalThis.r = keys[0] === "length" && keys[1] === "name" && keys[2] === "prototype";
    );
}
```

All must pass.

- [ ] **Step 1.10: Targeted WPT probe**

Run:
```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 webidl/ecmascript-binding 2>&1 | tee /tmp/0a-task1-webidl.txt
```

Diff `/tmp/0a-task1-webidl.txt` against `/tmp/0a-webidl-base.txt`. Expected: ≥ +10 subtests in `builtin-function-properties.any.js` family. Zero regressions. Record delta.

- [ ] **Step 1.11: Commit**

```bash
cd ~/suzume
git add src/js/kotori/vm.zig
git commit -m "$(cat <<'EOF'
feat(kotori): native fn length/name reflection per ECMA-262 §10.2.8/§10.2.9 (Layer 0A Gap 1+2)

Add registerNativeMethodArity / createNamedNativeFn that install length and
name as own descriptors with attrs {writable:false, enumerable:false,
configurable:true}. Rewrite ~200 registerNativeMethod call sites across the
global init block (L2325-L2903) and ~14 createNativeFn ctor sites to pass
declared arity. Delete ad-hoc ".name" setters at L2740/L2759/L2781 — they
now collide with the spec-correct descriptor-based install.

Unblocks Reflect.ownKeys(ctor).slice(0,3) === ["length","name","prototype"]
across every WebIDL ctor and fn.length/fn.name reads across DOM + Array +
Promise builtins. Measured +N subtests on webidl/ecmascript-binding (see
commit body for delta).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Gap 4 — Array callback IsCallable + generic array-like iteration

**Files:**
- Modify: `src/js/kotori/vm.zig` — add `isCallable` / `lengthOfArrayLike` helpers; rewrite the entry blocks of nine Array callback methods at L3913-L4101.

**Purpose:** Enforce `IsCallable(callbackFn)` per §23.1.3.12 step 3 (throw TypeError on non-callable) and drop the hard `obj_type == .array` gate so `Array.prototype.forEach.call({length:2, 0:'a', 1:'b'}, cb)` iterates correctly per §23.1.3.12 step 1 (`ToObject(this value)` + `LengthOfArrayLike`). `thisArg` propagation is already correct per the spec's audit (all nine methods already use `if (args.len > 1) args[1] else undefined_val`) — no change needed there.

- [ ] **Step 2.1: Add `isCallable` and `lengthOfArrayLike` helpers**

Place near the other VM helpers in vm.zig (below `clampToI64` at L7964 is fine):

```zig
/// ES2023 §7.2.3 IsCallable.
fn isCallable(val: JsValue) bool {
    if (!val.isObject()) return false;
    const o = val.asJsObject();
    return o.obj_type == .function or o.obj_type == .native_function;
}

/// ES2023 §7.3.19 LengthOfArrayLike.
/// Reads .length, ToUint32. Returns 0 on missing/invalid. For .array and
/// .typed_array fast-paths, returns items.len directly to preserve perf.
fn lengthOfArrayLike(self: *VM, this_val: JsValue) !u32 {
    if (!this_val.isObject()) return 0;
    const obj = this_val.asJsObject();
    if (obj.obj_type == .array) return @intCast(obj.data.array.items.len);
    const len_sid = try self.pool.intern("length");
    const len_val = obj.getProperty(len_sid) orelse return 0;
    const n = len_val.toNumber();
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n >= 4294967295.0) return 4294967295;
    return @intFromFloat(n);
}
```

- [ ] **Step 2.2: Rewrite `nativeArrayForEach` at L3913**

Current prologue (reconstructed from spec §Gap 4 "Current state"):
```zig
fn nativeArrayForEach(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    if (!this.isObject() or args.len == 0) return JsValue.undefined_val;
    // ...fast-path array iteration...
}
```

Rewrite to:
```zig
fn nativeArrayForEach(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    // §23.1.3.12 step 3
    const callback = if (args.len > 0) args[0] else JsValue.undefined_val;
    if (!isCallable(callback)) return error.TypeError;
    const thisArg = if (args.len > 1) args[1] else JsValue.undefined_val;

    // Fast-path: true arrays.
    if (this.isObject() and this.asJsObject().obj_type == .array) {
        const items = this.asJsObject().data.array.items;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            _ = try vm.callJsFunction(callback, thisArg, &.{
                items[i], JsValue.initNumber(@floatFromInt(i)), this,
            });
        }
        return JsValue.undefined_val;
    }

    // Generic array-like path (§23.1.3.12 steps 1, 2, 5).
    if (!this.isObject()) return error.TypeError; // ToObject(undefined) → TypeError
    const len = try vm.lengthOfArrayLike(this);
    var k: u32 = 0;
    while (k < len) : (k += 1) {
        // §23.1.3.12 step 5b: HasProperty gate (holes deferred; plain lookup for now)
        var idx_buf: [16]u8 = undefined;
        const idx_str = try std.fmt.bufPrint(&idx_buf, "{d}", .{k});
        const idx_sid = try vm.pool.intern(idx_str);
        if (this.asJsObject().getProperty(idx_sid)) |kv| {
            _ = try vm.callJsFunction(callback, thisArg, &.{
                kv, JsValue.initNumber(@floatFromInt(k)), this,
            });
        }
    }
    return JsValue.undefined_val;
}
```

- [ ] **Step 2.3: Mirror the pattern to the other eight methods**

Apply the same prologue transform (IsCallable check, thisArg extraction, fast-path retention, generic fallback using `lengthOfArrayLike`) to:

| Fn | Line | Return on empty / no-match |
|----|------|----------------------------|
| `nativeArrayMap` | 3927 | new array (accumulated) |
| `nativeArrayFilter` | 3945 | new array (accumulated) |
| `nativeArrayFind` | 4007 | `undefined` |
| `nativeArrayFindIndex` | 4022 | `-1` |
| `nativeArrayFindLast` | 4037 | `undefined` (iterate k = len-1 down) |
| `nativeArrayFindLastIndex` | 4055 | `-1` |
| `nativeArraySome` | 4073 | `false` |
| `nativeArrayEvery` | 4088 | `true` |

For each, keep the existing fast-path body for true arrays; only add IsCallable + thisArg-aware generic iteration when `obj_type != .array`.

Do **not** touch `reduce` / `reduceRight` / `sort` — per spec §23.1.3.22/23.1.3.26 they do NOT take `thisArg` (callback called with undefined), and the current behavior is already correct.

- [ ] **Step 2.4: Unit tests**

Add to harness:

```zig
test "Array.prototype.forEach throws TypeError on non-callable" {
    var vm = try testVm(); defer vm.deinit();
    const res = vm.evaluate(
        \\ try { [1,2,3].forEach(42); globalThis.threw = false; }
        \\ catch (e) { globalThis.threw = (e instanceof TypeError); }
    );
    _ = res catch {};
    // assert globalThis.threw === true
}

test "Array.prototype.forEach iterates array-like with length" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ let seen = [];
        \\ Array.prototype.forEach.call({length: 2, 0: 'a', 1: 'b'}, (v) => seen.push(v));
        \\ globalThis.r = seen.length === 2 && seen[0] === 'a' && seen[1] === 'b';
    );
}

test "Array.prototype.map propagates thisArg" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const obj = {k: 10};
        \\ const out = [1,2,3].map(function(x){ return x + this.k; }, obj);
        \\ globalThis.r = out[0] === 11 && out[1] === 12 && out[2] === 13;
    );
}

test "Array.prototype.findIndex returns -1 on miss" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ globalThis.r = [1,2,3].findIndex(x => x > 99) === -1;
    );
}
```

- [ ] **Step 2.5: Build + full test suite**

```bash
cd ~/suzume && zig build test 2>&1 | tail -40
```

Must be green.

- [ ] **Step 2.6: Targeted WPT probe**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes/Element-classList.html dom/events/EventListener-handleEvent.sub.html 2>&1 | tee /tmp/0a-task2-probe.txt
```

Record any delta. Expected: +5-15 subtests (Array iteration is used in dom/events listener test fixtures).

- [ ] **Step 2.7: Commit**

```bash
cd ~/suzume
git add src/js/kotori/vm.zig
git commit -m "$(cat <<'EOF'
feat(kotori): Array callbacks throw TypeError on non-callable + iterate array-likes (Layer 0A Gap 4)

Add IsCallable check and generic array-like fallback (via new
lengthOfArrayLike helper) to forEach/map/filter/find/findIndex/findLast/
findLastIndex/some/every. True-array fast-path preserved. reduce/
reduceRight/sort untouched (spec: no thisArg, already correct).

Fixes:
- [].forEach(42) now throws TypeError (was: silent undefined)
- Array.prototype.forEach.call({length:2,0:'a',1:'b'}, cb) now iterates
- Non-object receiver throws TypeError per ToObject(this)

Holes/HasProperty semantics deferred per spec §Out of scope.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Gap 3 — Error subclass prototype chain (nativeErrorConstructor)

**Files:**
- Modify: `src/js/kotori/vm.zig` — `nativeErrorConstructor` at L9153-L9172.

**Purpose:** Make `new TypeError("x") instanceof TypeError === true` by replacing the hard-coded `err_obj.prototype = error_proto` fallback with caller-fn introspection. Option A from the spec: use the existing `getCallerFuncObj` helper at L8288 to resolve which constructor invoked the shared `nativeErrorConstructor` function pointer, then read that ctor's `prototype` property.

- [ ] **Step 3.1: Locate the `prototype` lookup pattern**

The existing helpers at L8032-L8240 already call `getCallerFuncObj(vm)` and read properties from the result. Use that pattern.

Grep for the canonical pattern:
```bash
grep -n "getCallerFuncObj" src/js/kotori/vm.zig | head
```

- [ ] **Step 3.2: Rewrite `nativeErrorConstructor`**

Replace L9153-L9172 with:

```zig
fn nativeErrorConstructor(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const err_obj = try vm.createObj(.{});

    // §20.5.6.2 / §20.5.1.1: OrdinaryCreateFromConstructor reads prototype
    // from the active function. getCallerFuncObj returns the JsObject for
    // the `Error`/`TypeError`/... constructor that dispatched to us.
    const proto_sid = try vm.pool.intern("prototype");
    var proto_obj: ?*JsObject = vm.error_proto; // fallback: %Error.prototype%
    if (getCallerFuncObj(vm)) |fn_obj| {
        if (fn_obj.getProperty(proto_sid)) |pv| {
            if (pv.isObject()) proto_obj = pv.asJsObject();
        }
    }
    if (proto_obj) |p| err_obj.prototype = p;

    // §20.5.1.1 step 3: message installation (unchanged behavior, keep).
    const msg_sid = try vm.pool.intern("message");
    if (args.len > 0 and args[0].isString()) {
        try err_obj.setProperty(vm.allocator, msg_sid, args[0]);
    } else if (args.len > 0) {
        var buf: [64]u8 = undefined;
        const s = formatValue(vm.pool, args[0], &buf);
        try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern(s)));
    } else {
        try err_obj.setProperty(vm.allocator, msg_sid, JsValue.initString(try vm.pool.intern("")));
    }
    return JsValue.initObject(err_obj);
}
```

The lookup uses the public `getCallerFuncObj` function already declared at L8288 — no new plumbing needed.

- [ ] **Step 3.3: Verify the `construct` opcode does not overwrite prototype**

Re-read L1648-L1700 (spec §Gap 3 Risk note). If the opcode currently sets `result.prototype` post-native based on the constructor's `prototype` property, this double-set is harmless (same value). If it does NOT overwrite, our fix is load-bearing.

Action: add a comment next to the `err_obj.prototype = p` assignment documenting the order-dependency:
```zig
// NOTE: construct opcode (L~1648) does not currently override .prototype
// on native-ctor returns. If that changes, remove this line and rely on
// the opcode — no double-set issues since values match.
```

- [ ] **Step 3.4: Unit tests**

```zig
test "Error subclass instanceof is true across all native error types" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ globalThis.r = [
        \\   new TypeError("x") instanceof TypeError,
        \\   new TypeError("x") instanceof Error,
        \\   new RangeError("y") instanceof RangeError,
        \\   new SyntaxError("z") instanceof SyntaxError,
        \\   new URIError() instanceof URIError,
        \\   new EvalError() instanceof EvalError,
        \\   new ReferenceError() instanceof ReferenceError,
        \\ ].every(x => x === true);
    );
}

test "Error subclass has spec-correct name and message on instance read" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const e = new RangeError("boom");
        \\ globalThis.r = e.name === "RangeError" && e.message === "boom"
        \\   && Object.getPrototypeOf(e) === RangeError.prototype;
    );
}

test "TypeError called without new still dispatches by caller fn" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const e = TypeError("nope");
        \\ globalThis.r = e instanceof TypeError;
    );
}
```

- [ ] **Step 3.5: Full test + WPT probe**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  dom/events/Event-constructors.any.html \
  webidl/ecmascript-binding/es-exceptions 2>&1 | tee /tmp/0a-task3-probe.txt
```

Expected: +5-15 subtests per Event-constructors file and +5-10 in DOMException tests. Record delta.

- [ ] **Step 3.6: Commit**

```bash
cd ~/suzume
git add src/js/kotori/vm.zig
git commit -m "$(cat <<'EOF'
fix(kotori): Error sub-ctors bind correct prototype via caller-fn introspection (Layer 0A Gap 3)

Replace hard-coded err_obj.prototype = error_proto in nativeErrorConstructor
with getCallerFuncObj-based lookup of the active constructor's prototype
property. Makes `new TypeError("x") instanceof TypeError` true for all six
native error subclasses (TypeError, RangeError, SyntaxError, URIError,
EvalError, ReferenceError, AggregateError) plus no-new call form.

No new plumbing: getCallerFuncObj (L8288) already exists and is used by
getter/setter natives at L8032-L8240.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Gap 5a — Promise same-constructor + thenable microtask

**Files:**
- Modify: `src/js/kotori/vm.zig`:
  - `nativePromiseResolve` at L4660-L4671 (same-constructor check).
  - `MicrotaskEntry` union at L109 (new `.thenable_job` variant).
  - `resolvePromise` at L4448-L4535 (replace sync thenable call with microtask enqueue).
  - `runMicrotasks` at L4570-L4631 (add `.thenable_job` case).

**Purpose:** Make `Promise.resolve(x)` honor §27.2.1.4 step 1b's `SameValue(xConstructor, C)` constraint (don't unconditionally return native promises), and move thenable-adoption onto the microtask queue per §27.2.1.3.2 step 13-14 so ordering is observable-correct.

- [ ] **Step 4.1: Fix `nativePromiseResolve` same-constructor check**

At L4660-L4671 replace with:

```zig
/// Promise.resolve(value) — §27.2.4.7
fn nativePromiseResolve(ctx: *anyopaque, this_val: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = vmFromCtx(ctx);
    const value = if (args.len > 0) args[0] else JsValue.undefined_val;
    // §27.2.1.4 step 1: if IsPromise(x) && SameValue(x.constructor, C) → return x.
    if (value.isObject() and value.asJsObject().obj_type == .promise) {
        const ctor_sid = try vm.pool.intern("constructor");
        const x_ctor = value.asJsObject().getProperty(ctor_sid) orelse JsValue.undefined_val;
        // Object identity (SameValue for object values).
        if (this_val.isObject() and x_ctor.isObject() and
            @intFromPtr(this_val.asJsObject()) == @intFromPtr(x_ctor.asJsObject()))
        {
            return value;
        }
    }
    const promise = try vm.createPromiseObj();
    try vm.resolvePromise(promise, value);
    return JsValue.initObject(promise);
}
```

Note the signature change: `_: JsValue` → `this_val: JsValue` so the `this` receiver is accessible.

- [ ] **Step 4.2: Extend `MicrotaskEntry` union with `.thenable_job`**

At L109 add a new variant alongside `.promise_reaction` / `.resume_async`:

```zig
pub const MicrotaskEntry = union(enum) {
    promise_reaction: struct { /* existing */ },
    resume_async: struct { /* existing */ },
    // §27.2.2.1 NewPromiseResolveThenableJob
    thenable_job: struct {
        target_promise: *JsObject,
        thenable: JsValue,
        then_fn: JsValue,
    },
};
```

Preserve the existing variant bodies verbatim — this is additive.

- [ ] **Step 4.3: Rewrite `resolvePromise` slow-path to enqueue instead of call**

At L4485-L4506 the synchronous block:
```zig
if (is_callable) {
    const resolve_fn = try self.createPromiseSetter(promise, false);
    const reject_fn = try self.createPromiseSetter(promise, true);
    _ = self.callJsFunction(then_val, value, &.{
        JsValue.initObject(resolve_fn), JsValue.initObject(reject_fn),
    }) catch |err| { /* ... */ };
    return;
}
```

Replace with:
```zig
if (is_callable) {
    // §27.2.1.3.2 step 12-14: enqueue NewPromiseResolveThenableJob rather
    // than call synchronously. Preserves microtask ordering invariants.
    try self.microtasks.append(self.allocator, .{ .thenable_job = .{
        .target_promise = promise,
        .thenable = value,
        .then_fn = then_val,
    } });
    return;
}
```

- [ ] **Step 4.4: Handle `.thenable_job` in `runMicrotasks`**

Inside `runMicrotasks` at L4570-L4631 add a new match arm:

```zig
.thenable_job => |job| {
    // §27.2.2.1 body: call then(resolve, reject) with thenable as `this`.
    const resolve_fn = self.createPromiseSetter(job.target_promise, false) catch {
        // If setter creation fails, reject with a generic error.
        _ = self.rejectPromise(job.target_promise, JsValue.undefined_val) catch {};
        continue;
    };
    const reject_fn = self.createPromiseSetter(job.target_promise, true) catch {
        _ = self.rejectPromise(job.target_promise, JsValue.undefined_val) catch {};
        continue;
    };
    _ = self.callJsFunction(job.then_fn, job.thenable, &.{
        JsValue.initObject(resolve_fn), JsValue.initObject(reject_fn),
    }) catch |err| {
        if (err == error.TypeError or err == error.RangeError) {
            _ = self.rejectPromise(job.target_promise, JsValue.undefined_val) catch {};
        } else return err;
    };
},
```

- [ ] **Step 4.5: Unit tests**

```zig
test "Promise.resolve of own-realm promise returns identical instance" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const p = Promise.resolve(42);
        \\ globalThis.r = Promise.resolve(p) === p;
    );
}

test "thenable adoption is a microtask, not synchronous" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ const log = [];
        \\ Promise.resolve({ then(res) { log.push('then'); res(99); } })
        \\   .then(v => log.push('resolved:' + v));
        \\ log.push('sync');
        \\ // event loop drains microtasks after this script
        \\ globalThis.logref = log;
    );
    try vm.runMicrotasksToEmpty(); // or whatever the harness exposes
    // Assert globalThis.logref === ['sync', 'then', 'resolved:99']
}

test "thenable resolves with inner value" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ let captured;
        \\ Promise.resolve({ then(res){ res(7); } })
        \\   .then(v => { captured = v; });
        \\ globalThis.r = captured; // filled after microtask flush
    );
}
```

- [ ] **Step 4.6: Full test + targeted WPT probe**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
TIMEOUT=60 bash tests/wpt/run_wpt_parallel.sh --jobs 4 \
  html/webappapis/microtask-queuing 2>&1 | tee /tmp/0a-task4-probe.txt
```

Expected: +10-30 subtests from microtask ordering tests. No regressions on already-passing Promise suites.

- [ ] **Step 4.7: Commit**

```bash
cd ~/suzume
git add src/js/kotori/vm.zig
git commit -m "$(cat <<'EOF'
fix(kotori): Promise.resolve same-constructor + microtask thenable adoption (Layer 0A Gap 5a)

Two fixes under §27.2:
1. nativePromiseResolve now reads `this_val` (the receiver) and compares
   identity to value.constructor before returning value unchanged
   (§27.2.1.4 step 1b). Previously, any .promise obj_type was returned
   regardless of SameValue(xConstructor, C).
2. resolvePromise's thenable slow-path (L4485-L4506) previously invoked
   `then` synchronously. Replaced with a microtask enqueue (new
   MicrotaskEntry.thenable_job variant + runMicrotasks arm), preserving
   §27.2.2.1 NewPromiseResolveThenableJob ordering.

Order-observable test:
  Promise.resolve({then(r){log.push('then');r(1)}}).then(v=>log.push(v));
  log.push('sync');
  // Now: ['sync','then',1]. Was: ['then','sync',1].

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Gap 5b — Promise thenable `.then` getter invocation

**Files:**
- Modify: `src/js/kotori/vm.zig` — the `.then` lookup at L4479 inside `resolvePromise`.

**Purpose:** Per §27.2.1.3.2 step 8-9, `Get(resolution, "then")` must invoke an accessor getter if present, and an abrupt completion from the getter must reject the outer promise. kotori currently uses `val_obj.getProperty(then_id)` which returns the data value but bypasses accessor descriptors.

- [ ] **Step 5.1: Identify the accessor-invoking getter path**

Search for existing accessor invocation code:
```bash
grep -n "findAccessorDescriptor\|accessor" src/js/kotori/vm.zig | head -10
```

Expect hits around the `get_property` opcode handler. This code reads a descriptor, detects `.accessor`, and invokes the getter via `callJsFunction`. Extract the core logic into a small helper (if not already exposed) named `getPropertyWithAccessors`:

```zig
/// ES2023 §7.3.1 Get(V, P) — reads a data value OR invokes an accessor
/// getter. Returns JsValue.undefined_val if the property is missing.
/// Propagates abrupt completions from getters.
fn getPropertyWithAccessors(self: *VM, obj: *JsObject, name_sid: StringId, this_val: JsValue) !JsValue {
    if (obj.findAccessorDescriptor(name_sid)) |acc| {
        if (acc.get) |g| {
            return try self.callJsFunction(JsValue.initObject(g), this_val, &.{});
        }
        return JsValue.undefined_val;
    }
    return obj.getProperty(name_sid) orelse JsValue.undefined_val;
}
```

If the accessor path in the existing opcode is inlined with extra frame plumbing that is hard to extract, create the helper as a close copy tailored to this call site — purity is preferable to cleverness.

- [ ] **Step 5.2: Rewrite the `.then` lookup at L4479**

Current:
```zig
const then_id = try self.pool.intern("then");
if (val_obj.getProperty(then_id)) |then_val| { ... }
```

Replace with:
```zig
const then_id = try self.pool.intern("then");
const then_val = self.getPropertyWithAccessors(val_obj, then_id, value) catch |err| {
    // §27.2.1.3.2 step 9: abrupt completion rejects the promise.
    if (err == error.TypeError or err == error.RangeError or err == error.JsException) {
        try self.rejectPromise(promise, JsValue.undefined_val);
        return;
    }
    return err;
};
// Subsequent IsCallable check unchanged; then_val may be undefined (→ fulfill
// with resolution per step 11).
if (then_val.isObject()) {
    const then_obj = then_val.asJsObject();
    const is_callable = then_obj.obj_type == .native_function or then_obj.obj_type == .function;
    if (is_callable) {
        // Task 4's microtask enqueue (unchanged by this task).
        try self.microtasks.append(self.allocator, .{ .thenable_job = .{
            .target_promise = promise,
            .thenable = value,
            .then_fn = then_val,
        } });
        return;
    }
}
// else: falls through to the existing fulfill-with-value path at L4509.
```

Note: the reject-on-throw must preserve the thrown *value*, not merely `undefined_val`. If the error-to-value translation infrastructure exists (e.g., `self.pending_throw`), use it:
```zig
const reason = self.pending_throw orelse JsValue.undefined_val;
try self.rejectPromise(promise, reason);
```

Grep `pending_throw` to confirm the shape before finalizing this line.

- [ ] **Step 5.3: Unit tests**

```zig
test "throwing .then getter rejects the promise with thrown value" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ let caught;
        \\ Promise.resolve({ get then(){ throw new Error('e'); } })
        \\   .catch(e => { caught = e.message; });
        \\ globalThis.capture = () => caught;
    );
    try vm.runMicrotasksToEmpty();
    // assert vm.evaluate("globalThis.capture()") === "e"
}

test "non-callable .then still fulfills with the resolution" {
    var vm = try testVm(); defer vm.deinit();
    _ = try vm.evaluate(
        \\ let got;
        \\ Promise.resolve({ then: 42 }).then(v => { got = v && v.then; });
        \\ globalThis.capture = () => got;
    );
    try vm.runMicrotasksToEmpty();
    // assert vm.evaluate("globalThis.capture()") === 42
}
```

- [ ] **Step 5.4: Full test**

```bash
cd ~/suzume && zig build test 2>&1 | tail -30
```

Must be green. If Task 4's microtask ordering test regresses, the reject-on-throw path is likely swallowing an unrelated error; review Step 5.2's error filter.

- [ ] **Step 5.5: Commit**

```bash
cd ~/suzume
git add src/js/kotori/vm.zig
git commit -m "$(cat <<'EOF'
fix(kotori): Promise thenable .then getter invocation with reject-on-throw (Layer 0A Gap 5b)

§27.2.1.3.2 step 8-9: Get(resolution, "then") must invoke accessor
getters, and abrupt completions reject the outer promise. kotori used
val_obj.getProperty which only read data values.

Add getPropertyWithAccessors helper that consults findAccessorDescriptor
first, then falls back to direct property read. Wrap the call in resolvePromise
with a catch that routes JS-level exceptions to rejectPromise.

Behavior change:
- Promise.resolve({ get then(){ throw ...; } }).catch(e=>...) now captures
  the thrown error. Previously the throw was silently swallowed.
- Promise.resolve({ then: 42 }) still fulfills with the object itself
  (IsCallable(42) === false; step 11 fallthrough preserved).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: WPT Verification + Delta Commit

**Files:**
- Modify: None (measurement only). Produces final delta report committed to the kotori notes.

**Purpose:** Confirm the cumulative Task 1-5 effect against the baselines captured in Task 0. Gate on the acceptance criteria from the spec §Acceptance:
- `dom/nodes` ≥ +150 subtests
- `dom/events` ≥ +40 subtests
- `webidl/ecmascript-binding` ≥ +10 subtests
- No regressions in any area
- `zig build test` green

- [ ] **Step 6.1: Run the full WPT sweep matching the baseline areas**

```bash
cd ~/suzume
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes  2>&1 | tee /tmp/0a-dom-nodes-post.txt
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 dom/events 2>&1 | tee /tmp/0a-dom-events-post.txt
TIMEOUT=30 bash tests/wpt/run_wpt_parallel.sh --jobs 4 webidl     2>&1 | tee /tmp/0a-webidl-post.txt
```

- [ ] **Step 6.2: Diff against baselines**

```bash
diff /tmp/0a-dom-nodes-base.txt /tmp/0a-dom-nodes-post.txt | head -80
diff /tmp/0a-dom-events-base.txt /tmp/0a-dom-events-post.txt | head -80
diff /tmp/0a-webidl-base.txt /tmp/0a-webidl-post.txt | head -80
```

Record pass-count deltas per area. Any PASS → FAIL flip must be investigated before committing (spec principle 5: zero regressions).

- [ ] **Step 6.3: Write the WPT delta summary**

Update the project WPT progress doc (referenced in `~/.claude/projects/-home-midasdf/memory/MEMORY.md` as `project_suzume_wpt_progress.md` — locate the file via `find ~/.openclaw/workspace/memory/ -name 'project_suzume_wpt_progress.md' 2>/dev/null || find ~ -name 'project_suzume_wpt_progress.md' 2>/dev/null`). Append a new session entry with shape:

```markdown
### 2026-04-19 Session #N — Layer 0A builtin polish

- vm.zig: Gap 1+2 (fn length/name), Gap 3 (error chain), Gap 4 (array callbacks), Gap 5a/b (Promise thenable).
- dom/nodes: +X
- dom/events: +Y
- webidl/ecmascript-binding: +Z
- Cumulative: N subtests / M total ≈ P%
```

Use the real numbers from Step 6.2. If that file is outside the repo, write the summary to `/tmp/0a-wpt-delta.md` instead.

- [ ] **Step 6.4: Run `zig build test -Dcheck-leaks` if supported**

```bash
cd ~/suzume && zig build test -Dcheck-leaks 2>&1 | tail -20 || zig build test 2>&1 | tail -20
```

Green required.

- [ ] **Step 6.5: Binary size check**

```bash
stat -c %s zig-out/bin/suzume 2>/dev/null || stat -f %z zig-out/bin/suzume
```

Compare against the pre-Layer-0A size (record the pre-size at Task 0 if not already captured). Acceptance: ≤ 50 KB increase (spec §Acceptance). If over budget, investigate — builtins metadata should be static data.

- [ ] **Step 6.6: Final commit (verification artifacts + any tiny fixups)**

```bash
cd ~/suzume
git add -A  # likely nothing to add if Task 1-5 committed cleanly; verify with git status first
git status
# If there are staged changes (e.g., typo fixes from WPT debugging):
git commit -m "$(cat <<'EOF'
chore(kotori): Layer 0A WPT verification + delta record

WPT deltas (baseline → post Layer 0A):
- dom/nodes:   +X subtests  (target ≥ +150)
- dom/events:  +Y subtests  (target ≥ +40)
- webidl/ecb:  +Z subtests  (target ≥ +10)
- Regressions: 0

Binary size: +K bytes (budget 50 KB).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If `git status` is clean, skip this commit — the five task commits stand alone. Instead, paste the delta table into the final summary message reported back to the user.

---

## Open Questions

Any questions or decisions deferred during execution should be appended to `.omc/plans/open-questions.md` under a section header `## Layer 0A builtin polish — 2026-04-19`. Known candidates at plan-time:

- Legacy `registerNativeMethod` / `createNativeFn` retention policy (Task 1 Step 1.7): keep as back-compat shims or delete?
- `Function.prototype.bind` length-correction (§20.2.3.2 step 7) — explicitly out of scope per spec, but an executor encountering bound-fn WPT failures should know to append a note rather than fix inline.
- `pending_throw`-based reject value in Task 5 Step 5.2 — depends on existing exception-value plumbing; if the helper doesn't exist, the reject uses `undefined_val` and a follow-up note is appended.

---

## Acceptance Criteria (summary)

1. Six commits landed (Task 1-5 each + optional Task 6 verification).
2. `zig build test` green, including ≥ 15 new unit tests across gaps.
3. WPT deltas meet or exceed spec §Acceptance floors: dom/nodes +150, dom/events +40, webidl +10, zero regressions.
4. No files outside `src/js/kotori/vm.zig` modified (tests may extend the existing harness).
5. Every modified function carries an ECMA-262 section comment citation.
6. Binary size growth ≤ 50 KB.
7. Open questions appended to `.omc/plans/open-questions.md`.
