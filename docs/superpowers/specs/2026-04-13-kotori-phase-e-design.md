# kotori Phase E — Iterator Protocol + Async Generators Design Spec

## Overview

kotori JS engine (11,350 LOC, 387 tests) に iterator protocol 完全対応と async generators を追加する。
2段階: Stage 1 で iterator 基盤、Stage 2 で async iteration。

## VM Convention

All conditional jump opcodes pop TOS before checking (consistent with Phase D).
`run()` returns `anyerror!JsValue`.
`store_local` peeks TOS (does NOT pop) — value remains on stack after store.
`call_method N` consumes this+func+N args from stack, pushes 1 result.
`get_prop` pops object from TOS, pushes property value (replaces TOS).

## Well-Known Symbol IDs (current)

```
SYMBOL_ITERATOR      = 0
SYMBOL_TO_PRIMITIVE  = 1
SYMBOL_HAS_INSTANCE  = 2
SYMBOL_TO_STRING_TAG = 3
SYMBOL_ASYNC_ITERATOR = 4  // new in Phase E
```

`next_symbol_id` starts at 5.

## Scope

| # | Feature | Stage | New Opcodes |
|---|---------|-------|-------------|
| 1 | for-of iterator protocol | 1 | `get_iterator` |
| 2 | yield* delegation | 1 | `yield_delegate` |
| 3 | Spread iterator support | 1 | none (modify existing) |
| 4 | Array/String Symbol.iterator | 1 | none (builtin registration) |
| 5 | async function* | 2 | none (combine existing) |
| 6 | for-await-of | 2 | `get_async_iterator` |

## Dependencies

```
Stage 1:
  4 (Array/String iterators) ← independent
  1 (for-of iterator) ← 4 (needs iterators for backward compat)
  2 (yield*) ← 1 (uses iterator resolution)
  3 (spread iterator) ← 1 (uses same iterator mechanism)

Stage 2:
  5 (async generators) ← Stage 1 complete
  6 (for-await-of) ← 5
```

---

## Shared: Iterator Resolution Helper

Both `get_iterator` opcode and `spread_into_array` need the same iterator resolution logic.
Extract into a shared VM helper:

```zig
/// Resolve an iterable value to an iterator object.
/// Returns the iterator or null if not iterable.
fn resolveIterator(self: *VM, iterable: JsValue) !?JsValue {
    if (iterable.isObject()) {
        const obj = iterable.asJsObject();
        // 1. Generator objects are their own iterators
        if (obj.obj_type == .generator) return iterable;
        // 2. Check Symbol.iterator on own + prototype chain
        if (self.findSymbolProp(obj, SYMBOL_ITERATOR)) |iter_fn| {
            return try self.callJsFunction(iter_fn, iterable, &.{});
        }
        // 3. Array fallback: create array iterator
        if (obj.obj_type == .array) {
            return JsValue.initObject(try self.createArrayIterator(iterable));
        }
    }
    // 4. String fallback: create string iterator
    if (iterable.isString()) {
        return JsValue.initObject(try self.createStringIterator(iterable));
    }
    return null; // not iterable
}

/// Walk prototype chain looking for a symbol property.
fn findSymbolProp(self: *VM, obj: *JsObject, sym_id: u32) ?JsValue {
    var current: ?*JsObject = obj;
    while (current) |cur| {
        if (cur.symbol_props) |sp| {
            if (sp.get(sym_id)) |val| return val;
        }
        current = cur.prototype;
    }
    return null;
}
```

---

## Stage 1

### Feature 1: for-of Iterator Protocol

#### Current State
- for-of uses index-based iteration: `get_length` + `get_elem` loop (compiler.zig:1249-1343)
- Generators and custom iterables can't be used with for-of
- Symbol.iterator exists (Phase D) but nothing calls it

#### Design

**New opcode**: `get_iterator`
- Stack: `[iterable]` → `[iterator]`
- VM logic: Call `resolveIterator()`. If null, create a "done iterator" (object whose
  `.next()` immediately returns `{done: true}`) — avoids TypeError crash while still
  producing correct behavior (empty loop, no infinite loop).

**Array iterator**: New obj_type `.iterator` with IteratorData:
```zig
pub const IteratorData = struct {
    source: JsValue,   // the array/string being iterated
    index: u32 = 0,
};
```
`.next()` native method: if source is array, check index < array.len. If so, return
`{value: arr[index++], done: false}`. Otherwise `{value: undefined, done: true}`.

**String iterator**: Same IteratorData. Iterate by UTF-8 codepoints using `std.unicode.utf8ByteSequenceLength`
to determine character boundaries. Each `.next()` returns one codepoint as a string.
**Known limitation**: Astral plane characters (4-byte UTF-8) return the full codepoint, not surrogate pairs.

**Compiler change**: Replace the for-of path in `compileForOfIn` (~line 1249).
Uses the same local management pattern as existing code (addLocal + compileStoreVar + compileIdentifierLoad):

```
// for (let x of iterable) { body }
// Locals allocated: x, __iter

compile(iterable)
get_iterator                      // [iterator]
// Store via addLocal pattern (already on stack as local slot)
_ = addLocal(__iter)              // iterator is now local __iter

loop_start:
  compileIdentifierLoad(__iter)   // [iter]
  dup                             // [iter, iter]
  get_prop "next"                 // [iter, next_fn] — get_prop replaces TOS
  call_method 0                   // [result] — consumes iter+next_fn, pushes result
  dup                             // [result, result]
  get_prop "done"                 // [result, done]
  jump_if_true → exit             // pops done → [result]
  get_prop "value"                // [value] — replaces result with value
  compileStoreVar(x)              // [value] — store_local peeks, value stays
  pop                             // [] — discard temporary
  compile(body)
  jump → loop_start

exit:                             // [result]
  pop                             // [] — discard final result
```

**Stack trace verification**:
- Loop body start: `[]` (clean)
- After compileIdentifierLoad: `[iter]` (+1)
- After dup: `[iter, iter]` (+2)
- After get_prop "next": `[iter, next_fn]` (+2, get_prop replaced TOS)
- After call_method 0: `[result]` (+1, consumed iter+next_fn, pushed result)
- After dup: `[result, result]` (+2)
- After get_prop "done": `[result, done]` (+2)
- After jump_if_true (not taken): `[result]` (+1, popped done)
- After get_prop "value": `[value]` (+1, replaced result)
- After compileStoreVar: `[value]` (+1, peek only)
- After pop: `[]` (0, clean for body)
- exit path: `[result]` → pop → `[]` (clean)

Note: `call_method 0` consumes BOTH the this-object and the function from the stack.
The iterator must be reloaded from its local slot each iteration.

Note: for-in (`get_keys`) path is unchanged.

#### Tests
- `let s=0; for (let x of [1,2,3]) s += x; s` → 6 (regression)
- `let s=""; for (let c of "abc") s += c; s` → "abc"
- `function* g() { yield 1; yield 2; } let s=0; for (let x of g()) s += x; s` → 3
- `for (let x of 42) {}` → empty loop (non-iterable, no crash)

---

### Feature 2: yield* Delegation

#### Current State
- Parser: `yield_expr.delegate` field exists, set when `yield*` is parsed
- Compiler: `delegate` flag is ignored, always emits `yield_value`

#### Design

**New opcode**: `yield_delegate`
- Stack: `[iterable]` → `[final_value]`

**Two-site implementation** (opcode + nativeGeneratorNext):

**GeneratorData addition**:
```zig
delegate_iterator: ?JsValue = null,  // active yield* inner iterator
```

**yield_delegate opcode handler** (first call):
1. Pop iterable from stack
2. Call `resolveIterator()` to get inner iterator
3. Store in `gen.delegate_iterator`
4. Call inner `iterator.next(undefined)`
5. If `result.done`: push `result.value` as yield* expression result, continue execution
6. If not done: save generator state (same as yield_value), return `{value: result.value, done: false}`

**nativeGeneratorNext modification** (subsequent calls):
```
fn nativeGeneratorNext(ctx, this, args):
    ...
    if gen.delegate_iterator != null:
        // Forward .next(sent_value) to inner iterator
        result = callJsFunction(delegate.next, delegate, [sent_value])
        if result.done:
            gen.delegate_iterator = null
            // Resume generator body: result.value becomes the yield* expression result
            return executeGenerator(gen, result.value, true)
        else:
            // Yield inner value to outer caller (don't resume generator body)
            return createIterResult(result.value, false)
    else:
        // Normal resume
        ...
```

**Known gap**: `.throw()` and `.return()` are NOT forwarded to the inner iterator during
delegation. This means `gen.return()` during active `yield*` won't close the inner iterator.
Deferred to a future phase — basic yield* delegation covers the common use cases.

#### Tests
- `function* a() { yield 1; yield 2; } function* b() { yield* a(); yield 3; }` → for-of gives [1,2,3]
- `yield* [1, 2, 3]` — delegate to array iterator
- Nested: `function* c() { yield* b(); }` → [1,2,3]
- Return value: `function* d() { return 42; } function* e() { let r = yield* d(); yield r; }` → [42]

---

### Feature 3: Spread Iterator Support

#### Current State
- `spread_into_array` handles Array (data.array.items copy) and String (byte-by-byte)
- Generators and custom iterables are not supported

#### Design

Modify `spread_into_array` VM handler. Use the shared `resolveIterator` helper for
non-array/string values:

```zig
.spread_into_array => {
    const iterable = self.pop();
    const arr = self.peek().asJsObject();

    if (iterable.isObject()) {
        const obj = iterable.asJsObject();
        // Fast path: array (existing)
        if (obj.obj_type == .array) {
            for (obj.data.array.items) |item| {
                try arr.data.array.append(self.allocator, item);
            }
            continue;
        }
    }
    // String fast path (existing)
    if (iterable.isString()) {
        // ... existing byte-by-byte spread ...
        continue;
    }
    // Iterator protocol fallback (new)
    if (try self.resolveIterator(iterable)) |iterator_val| {
        try self.drainIteratorIntoArray(iterator_val, arr);
    }
},
```

**New helper** `drainIteratorIntoArray(iterator, array)`:
```zig
fn drainIteratorIntoArray(self: *VM, iterator_val: JsValue, arr: *JsObject) !void {
    const next_id = try self.pool.intern("next");
    const done_id = try self.pool.intern("done");
    const value_id = try self.pool.intern("value");
    while (true) {
        if (!iterator_val.isObject()) break;
        const iter_obj = iterator_val.asJsObject();
        const next_fn = iter_obj.getProperty(next_id) orelse break;
        const result = try self.callJsFunction(next_fn, iterator_val, &.{});
        if (!result.isObject()) break;
        const result_obj = result.asJsObject();
        const done = result_obj.getProperty(done_id) orelse JsValue.initBool(true);
        if (done.isTruthy()) break;
        const value = result_obj.getProperty(value_id) orelse JsValue.undefined_val;
        try arr.data.array.append(self.allocator, value);
    }
}
```

#### Tests
- `function* range(n) { for(let i=0;i<n;i++) yield i; } [...range(3)]` → [0,1,2]
- `[...new Map()]` → (future, when Map has Symbol.iterator)

---

### Feature 4: Array/String Symbol.iterator Registration

#### Current State
- Symbol.iterator well-known symbol exists (ID=0)
- No built-in type registers it

#### Design

In `initBuiltins`, register `Symbol.iterator` on Array.prototype:

```zig
if (self.array_proto) |ap| {
    if (ap.symbol_props == null) ap.symbol_props = .{};
    const iter_fn = try self.createNativeFn(&nativeArraySymbolIterator);
    try ap.symbol_props.?.put(self.allocator, SYMBOL_ITERATOR, JsValue.initObject(iter_fn));
}
```

`nativeArraySymbolIterator` returns `createArrayIterator(this)`.

**String**: Handled directly by `get_iterator` / `resolveIterator` — strings are primitives,
can't have symbol_props. The iterator fallback branch creates a string iterator.

**Prototype chain**: `resolveIterator` calls `findSymbolProp` which walks the prototype chain.
This ensures `[1,2,3]` (prototype = array_proto) finds Symbol.iterator from array_proto.

#### Tests
- `let a = [1,2]; let it = a[Symbol.iterator](); it.next().value` → 1
- Implicit via for-of: covered in Feature 1 tests

---

## Stage 2

### Feature 5: Async Generators

#### Current State
- `async` functions use Continuation (vm.zig:110-118) for suspend/resume on await
- Generators use GeneratorData with saved_ip/saved_stack for suspend/resume on yield
- No `async function*` support

#### Design

**Parser**: Verify `async function*` already parses (sets both `is_async` and `is_generator`
on Function AST node). Add `kw_yield` handling in async function bodies if not present.

**FunctionObj**: Already has `is_async` and `is_generator` fields.

**Initial implementation: one-at-a-time processing** (no request queue).
Concurrent `.next()` calls on an executing/await_pending async generator return
a rejected Promise. Full queue support deferred.

**AsyncGeneratorObject**: New obj_type `.async_generator`:
```zig
pub const AsyncGeneratorData = struct {
    gen: GeneratorData,                    // reuse generator state machine
    pending_promise: ?*JsObject = null,    // Promise returned by current .next()
};
```

**State machine** (extends GeneratorState):
```
suspended_start → executing → suspended_yield → executing → ...
                      ↓               ↑
                 await_pending    (microtask resolves, resumes)
```

Add `.await_pending` to GeneratorState enum.

**`.next(value)` flow**:
1. Create a new Promise
2. If `suspended_start` or `suspended_yield`:
   - Store Promise as `pending_promise`
   - Call `executeGenerator(gen, value, is_resume)`
   - If execution hits `yield`: `yield_value` handler resolves `pending_promise` with `{value, false}`
   - If execution hits `return`: resolve with `{value, true}`, set completed
   - If execution hits `await`: save generator state (saved_ip/saved_stack), set `await_pending`
     - When the awaited Promise resolves via microtask, restore generator state, continue run loop
     - If run then hits yield/return, resolve `pending_promise` accordingly
3. If `executing` or `await_pending`: return `Promise.reject(TypeError)` (one-at-a-time)
4. If `completed`: return `Promise.resolve({undefined, true})`
5. Return the pending Promise

**`await_` opcode in async generator context**:
When `active_generator` is set AND the function is async:
- Save generator state (like yield_value but don't resolve any promise)
- Set state to `await_pending`
- Create a Continuation that will:
  - Restore generator state
  - Set state to `executing`
  - Resume `run()` from saved_ip
  - If run hits yield/return, resolve pending_promise
- Attach Continuation as handler on the awaited Promise
- Return from run() (let microtask queue handle resolution)

**Key**: The async generator body uses the SAME `yield_value` and `await_` opcodes as
sync generators and async functions. The difference is only in how the VM handles
suspend/resume — checking both `active_generator` and `is_async`.

#### Tests
```js
// Basic async generator (no await in body)
async function* asyncCount() { yield 1; yield 2; }
let it = asyncCount();
let r1 = await it.next(); // {value: 1, done: false}
let r2 = await it.next(); // {value: 2, done: false}
let r3 = await it.next(); // {value: undefined, done: true}

// Async generator with await
async function* asyncWithAwait() {
    let x = await Promise.resolve(42);
    yield x;
}
let it2 = asyncWithAwait();
let r = await it2.next(); // {value: 42, done: false}
```

---

### Feature 6: for-await-of

#### Current State
- Parser does not recognize `for await`
- No `get_async_iterator` opcode

#### Design

**AST**: Add `is_await: bool = false` to `for_of_stmt` struct. Reuse existing struct
rather than creating a new node type.

**Parser**: In `parseStatement`, after matching `kw_for`:
```zig
// Check for "for await ("
if (self.current.type == .kw_await) {
    self.advance(); // consume 'await'
    // parse as for-of with is_await = true
    ...
}
```

**New opcode**: `get_async_iterator`
- Stack: `[iterable]` → `[iterator]`
- VM logic:
  1. Check `Symbol.asyncIterator` (ID=4) via `findSymbolProp` → call it
  2. Fallback: call `resolveIterator()` (sync iterator used as async)

**Compiler**: for-await-of compiles like for-of but inserts `await_` after `call_method`:

```
// for await (let x of iterable) { body }

compile(iterable)
get_async_iterator                // [async_iterator]
_ = addLocal(__iter)

loop_start:
  compileIdentifierLoad(__iter)   // [iter]
  dup                             // [iter, iter]
  get_prop "next"                 // [iter, next_fn]
  call_method 0                   // [promise_or_result]
  await_                          // [result] — await the .next() return
  dup                             // [result, result]
  get_prop "done"                 // [result, done]
  jump_if_true → exit             // pops done → [result]
  get_prop "value"                // [value]
  compileStoreVar(x)              // [value]
  pop                             // []
  compile(body)
  jump → loop_start

exit:                             // [result]
  pop                             // []
```

Stack pattern is identical to for-of (Feature 1) except for the `await_` after `call_method`.

#### Tests
```js
// for-await-of with async generator
async function main() {
    let sum = 0;
    for await (let x of asyncCount()) { sum += x; }
    return sum; // 3
}

// for-await-of with sync iterable (auto-wraps)
async function main2() {
    let sum = 0;
    for await (let x of [1,2,3]) { sum += x; }
    return sum; // 6
}
```

---

## Files Modified

| File | Changes |
|------|---------|
| `bytecode.zig` | New opcodes: `get_iterator`, `yield_delegate`, `get_async_iterator` |
| `ast.zig` | Add `is_await: bool = false` to `for_of_stmt` |
| `object.zig` | Add `iterator`, `async_generator` to ObjType. Add IteratorData, AsyncGeneratorData. Extend GeneratorData with `delegate_iterator`. Add `await_pending` to GeneratorState |
| `parser.zig` | `for await (` parsing, verify `async function*` works |
| `compiler.zig` | Rewrite for-of to use get_iterator, yield* → yield_delegate, for-await-of compilation |
| `vm.zig` | resolveIterator/findSymbolProp helpers, get_iterator handler, yield_delegate handler, spread_into_array iterator support, Array Symbol.iterator registration, async generator machinery, get_async_iterator handler, createArrayIterator/createStringIterator, drainIteratorIntoArray |
| `value.zig` | No changes needed |

## Non-Goals
- `Symbol.asyncIterator` on built-in types (only user-defined for now)
- yield* `.throw()` / `.return()` forwarding (documented known gap)
- Async generator request queue (one-at-a-time only)
- Full TC39 async iteration edge cases
- Surrogate pair handling in string iterator
