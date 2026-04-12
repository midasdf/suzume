# kotori Phase D — Modern JS Features Design Spec

## Overview

kotori JS engine (10,496 LOC, 348 tests) にモダンJS機能を追加する。
ブラウザ実用性と言語仕様完成度の両方を目指す。

## VM Convention Note

**All conditional jump opcodes pop TOS before checking.** This is consistent with existing
`jump_if_false` / `jump_if_true` behavior (vm.zig:353-365). New jump opcodes in this spec
(`jump_if_nullish`, `jump_if_not_nullish`) follow the same convention.

## Scope

8つの機能を依存関係順に実装:

| # | Feature | Difficulty | New Opcodes |
|---|---------|-----------|-------------|
| 1 | `??` nullish coalescing | Low | `jump_if_not_nullish` |
| 2 | `?.` optional chaining | Medium | `jump_if_nullish` |
| 3 | Spread in function calls | Medium | `spread_into_array`, `call_spread`, `call_method_spread`, `construct_spread` |
| 4 | Object getter/setter literals | Low | `define_getter`, `define_setter` |
| 5 | `globalThis` | Trivial | none |
| 6 | Symbol | Medium | none (property lookup extension) |
| 7 | Generators + Iterator Protocol | High | `yield_value`, `yield_delegate` |
| 8 | WeakMap / WeakSet | Low | none |

## Dependencies

```
1 (nullish) ← independent
2 (optional chaining) ← independent
3 (spread calls) ← independent
4 (getter/setter) ← independent
5 (globalThis) ← independent
6 (Symbol) ← independent, but needed before 7
7 (generators) ← depends on 6 (Symbol.iterator) + Array/String Symbol.iterator registration
8 (WeakMap/Set) ← independent
```

---

## Feature 1: Nullish Coalescing (`??`)

### Current State
- Lexer: `??` tokenized as `.nullish` / `.question_question`
- Parser: parsed as `binary { op: .nullish }` — working
- Compiler: **not handled** — falls through to `binaryOpToOpCode` which has no mapping

### Design

Add new opcode `jump_if_not_nullish` to bytecode.zig.

**Compiler** (compiler.zig, alongside `logical_and`/`logical_or` handling at ~line 242):
```
// a ?? b
compile(a)                    // [a]
dup                           // [a, a]
jump_if_not_nullish → skip    // pops top → [a]. If not nullish, jump (keep a).
pop                           // [] — discard nullish a
compile(b)                    // [b]
skip:                         // Result: [a] or [b] ✓
```

Stack trace: both paths leave exactly 1 value. Same pattern as `logical_or` but with nullish check.

**VM**: `jump_if_not_nullish` pops TOS, checks `!(isNull() or isUndefined())`. If true (not nullish), jump. If false (is nullish), fall through.

**`??=` (nullish assign)**: Different patterns depending on LHS type:

```
// x ??= 5 (identifier LHS)
load_local x                  // [x]
dup                           // [x, x]
jump_if_not_nullish → skip    // pops → [x]. If not nullish, skip.
pop                           // []
compile(5)                    // [5]
store_local x                 // [5] (store returns value)
skip:                         // Result: [x] or [5]
```

For member LHS (`obj.x ??= 5`): compile obj, dup, get_prop, check nullish, if nullish: compile value, set_prop on the dup'd obj.

### Tests
- `null ?? 42` → 42
- `undefined ?? 42` → 42
- `0 ?? 42` → 0 (not nullish!)
- `"" ?? 42` → "" (not nullish!)
- `false ?? 42` → false (not nullish!)
- `"hello" ?? 42` → "hello"
- `let x = null; x ??= 5; x` → 5
- `let x = 0; x ??= 5; x` → 0
- Chained: `null ?? undefined ?? 42` → 42

---

## Feature 2: Optional Chaining (`?.`)

### Current State
- Lexer: `?.` tokenized as `.optional_chain` / `.question_dot`
- Parser: `parseMember` handles `?.` but produces same `.member` node as `.` — **optional info is lost**
- Compiler: no awareness of optional chaining

### Design

**AST changes** (ast.zig):
Add `optional: bool = false` field to `member` and `computed_member`:
```zig
member: struct { object: NodeIndex, property: StringId, optional: bool = false },
computed_member: struct { object: NodeIndex, property: NodeIndex, optional: bool = false },
```

**Parser changes** (parser.zig):
- `parseMember`: set `optional = true` when token is `.optional_chain` / `.question_dot`
- `parseComputedMember`: similarly for `?.[`

**Compiler changes** (compiler.zig):

All bytecode patterns use the popping jump convention:

```
// a?.b (optional member)
compile(a)                    // [obj]
dup                           // [obj, obj]
jump_if_nullish → null_path   // pops top → [obj]. If nullish, jump.
get_prop "b"                  // pops obj, pushes result → [obj.b] ✓
jump → end
null_path:                    // [obj] (null/undefined)
pop                           // []
load_const undefined          // [undefined]
end:                          // Result: [obj.b] or [undefined] ✓
```

```
// a?.[i] (optional computed member)
compile(a)                    // [obj]
dup                           // [obj, obj]
jump_if_nullish → null_path   // pops → [obj]
compile(i)                    // [obj, i]
get_elem                      // [result] ✓
jump → end
null_path:                    // [obj]
pop                           // []
load_const undefined          // [undefined]
end:
```

```
// a?.() (optional call)
compile(a)                    // [func]
dup                           // [func, func]
jump_if_nullish → null_path   // pops → [func]
call 0                        // [result] ✓
jump → end
null_path:                    // [func]
pop                           // []
load_const undefined          // [undefined]
end:
```

**Chaining**: `a?.b?.c` compiles naturally — each `?.` generates its own nullish guard.

### Tests
- `null?.foo` → undefined
- `undefined?.foo` → undefined
- `({a: 1})?.a` → 1
- `null?.foo?.bar` → undefined
- `({a: {b: 2}})?.a?.b` → 2
- `null?.[0]` → undefined
- `[1,2,3]?.[1]` → 2
- `null?.()` → undefined
- `let f = () => 42; f?.()` → 42
- `({f: () => 1})?.f()` → 1

---

## Feature 3: Spread in Function Calls

### Current State
- Parser: `...expr` creates `.spread` node — working
- Compiler: `compileCall` iterates args with `compileNode(arg)` — spread nodes fall through unhandled

### Design

**New opcodes**:
- `spread_into_array`: stack `[array, iterable]` → `[array]` — pops iterable, iterates it, appends each element to array at TOS. Array stays on stack.
- `call_spread`: stack `[func, args_array]` → `[result]` — pops args array, pops func, calls func with array items as individual arguments
- `call_method_spread`: stack `[this, func, args_array]` → `[result]`
- `construct_spread`: stack `[func, args_array]` → `[result]`

**Compiler strategy**: Detect if any arg in the call is a `.spread` node. If so, switch to spread mode:

```
// foo(a, ...arr, b)
compile(foo)              // [func]
new_array 0               // [func, args[]]
  compile(a)              // [func, args[], a]
  array_push              // [func, args[a]]
  compile(arr)            // [func, args[a], arr]
  spread_into_array       // [func, args[a, ...arr]]
  compile(b)              // [func, args[a,...arr], b]
  array_push              // [func, args[a,...arr,b]]
call_spread               // [result]
```

For method calls:
```
// obj.method(a, ...arr)
compile(obj)              // [obj]
dup                       // [obj, obj]
get_prop "method"         // [obj, func]
new_array 0               // [obj, func, args[]]
  compile(a)              // [obj, func, args[], a]
  array_push              // [obj, func, args[a]]
  compile(arr)            // [obj, func, args[a], arr]
  spread_into_array       // [obj, func, args[a,...arr]]
call_method_spread        // [result]
```

**VM implementation for `spread_into_array`**:
```zig
.spread_into_array => {
    const iterable = self.pop();
    // TOS is now the target array
    const arr_val = self.peek(0);
    const arr = arr_val.asJsObject();
    if (iterable.isObject()) {
        const iter_obj = iterable.asJsObject();
        if (iter_obj.obj_type == .array) {
            for (iter_obj.data.array.items) |item| {
                arr.data.array.append(self.allocator, item);
            }
        }
    }
    // String spread: for (char in str) append each char
},
```

### Tests
- `Math.max(...[1,2,3])` → 3
- `function f(a,b,c) { return a+b+c; } f(...[1,2,3])` → 6
- `function f(a,b,c,d) { return a+b+c+d; } f(0, ...[1,2], 3)` → 6
- `new Date(...[2026, 3, 13])` — construct_spread
- `let a = [1,...[2,3],...[4,5]]` → [1,2,3,4,5] (array spread — already works)
- `console.log(...["a","b"])` — method spread

---

## Feature 4: Object Literal Getters/Setters

### Current State
- AST: `Property.kind` has `get` and `set` variants — working
- Compiler: `compileObjectLiteral` treats all properties as `init` — ignores kind

### Design

**New opcodes**: `define_getter`, `define_setter`
- Operand: u16 constant index → StringId (property name)
- Stack: `[object, function]` → `[object]` — pops function, registers it as getter/setter on object, leaves object on stack

**Compiler** (in `compileObjectLiteral`):
```zig
switch (prop.kind) {
    .init => {
        // existing: dup, compile value, set_prop, pop
    },
    .get => {
        try self.emitOp(.dup);          // keep object ref
        try self.compileNode(prop.value); // compile getter function
        const ci = try self.current.bc.addConstant(...);
        try self.emitOpU16(.define_getter, ci);
    },
    .set => {
        try self.emitOp(.dup);          // keep object ref
        try self.compileNode(prop.value); // compile setter function
        const ci = try self.current.bc.addConstant(...);
        try self.emitOpU16(.define_setter, ci);
    },
}
```

**VM property model**: Add getter/setter storage to JsObject:
```zig
// In JsObject, add:
getters: ?std.AutoHashMapUnmanaged(StringId, JsValue) = null,
setters: ?std.AutoHashMapUnmanaged(StringId, JsValue) = null,
```

**VM getter invocation strategy** (addressing reentrancy concern):
When `get_prop` encounters a getter, use the existing `callJsFunction` mechanism
which pushes a new call frame. The VM already supports re-entrant function calls
(used by Promise handlers, Array.sort comparators, etc.):

```zig
// In get_prop handler, after normal property lookup fails:
if (obj.getters) |getters| {
    if (getters.get(name_id)) |getter_fn| {
        const result = try self.callJsFunction(getter_fn, obj_val, &.{});
        self.push(result);
        continue;
    }
}
```

Same approach for `set_prop` with setter functions.

**Class getter/setter**: Already parsed with `Property.kind`. Same opcode emission in `compileClassDecl`.

### Tests
- `let o = { get x() { return 42; } }; o.x` → 42
- `let o = { _v: 0, set v(x) { this._v = x; }, get v() { return this._v; } }; o.v = 10; o.v` → 10
- `class C { get name() { return "test"; } } new C().name` → "test"
- `class C { set val(v) { this._v = v * 2; } get val() { return this._v; } } let c = new C(); c.val = 5; c.val` → 10
- `let o = { get x() { return 42; } }; o.x = 99; o.x` → 42 (no setter → set ignored)

---

## Feature 5: `globalThis`

### Design

In VM initialization, register the global object as `globalThis`:
```zig
try self.globals.put(self.pool.intern("globalThis"), self.global_object);
```

**`structuredClone`**: Deferred. JSON round-trip approach loses undefined, Date, RegExp, Map, Set,
functions, and circular references. Not worth implementing incorrectly — better to add when
we have proper deep-clone infrastructure.

### Tests
- `typeof globalThis` → "object"
- `globalThis.parseInt("42")` → 42

---

## Feature 6: Symbol

### Design

**Value representation**: Use a dedicated tag in NaN-boxing. Symbols are identified by a u32 ID.

```zig
// In value.zig — new tag for Symbol
// Symbol value: NaN-boxed with symbol tag + u32 symbol_id in payload
pub fn initSymbol(id: u32) JsValue { ... }
pub fn isSymbol(self: JsValue) bool { ... }
pub fn asSymbolId(self: JsValue) u32 { ... }
```

**`typeof` update**: Add Symbol branch to `typeof_` opcode handler in VM:
```zig
.typeof_ => {
    const val = self.pop();
    if (val.isSymbol()) {
        self.push(JsValue.initString(self.pool.intern("symbol")));
    } else if ...
}
```

**Equality semantics**: `jsStrictEq` uses bit comparison (`a.bits == b.bits`) which works
correctly — each Symbol has a unique ID, so unique NaN-boxed bits. No changes needed.

**Symbol registry** (in VM):
```zig
next_symbol_id: u32 = 4,  // 0-3 reserved for well-known symbols
symbol_descriptions: std.AutoHashMapUnmanaged(u32, ?StringId),  // id → description
global_symbol_registry: std.StringHashMapUnmanaged(u32),         // name → id for Symbol.for()
```

**Well-known symbols** (pre-allocated IDs):
```
SYMBOL_ITERATOR      = 0
SYMBOL_TO_PRIMITIVE  = 1
SYMBOL_HAS_INSTANCE  = 2
SYMBOL_TO_STRING_TAG = 3
```

**Object property extension**: Add symbol-keyed properties alongside string-keyed:
```zig
// In JsObject:
symbol_props: ?std.AutoHashMapUnmanaged(u32, JsValue) = null,
```

**Property access for Symbols**: `get_elem` / `set_elem` already handle computed keys.
When the key is a Symbol value, route to `symbol_props`:
```zig
// In get_elem handler:
if (key.isSymbol()) {
    const sym_id = key.asSymbolId();
    if (obj.symbol_props) |sp| {
        if (sp.get(sym_id)) |val| { self.push(val); continue; }
    }
    self.push(JsValue.undefined_val);
    continue;
}
```

**Symbol constructor** (registered as global):
- `Symbol("desc")` — create new unique symbol with next_symbol_id++
- `Symbol.for("key")` — global registry lookup/create
- `Symbol.keyFor(sym)` — reverse lookup
- `Symbol.iterator` — well-known symbol constant (read-only property)
- `symbol.toString()` → `"Symbol(description)"`
- `symbol.description` getter

### Tests
- `typeof Symbol()` → "symbol"
- `Symbol("a") !== Symbol("a")` → true (unique)
- `Symbol.for("x") === Symbol.for("x")` → true (registry)
- `Symbol("test").toString()` → "Symbol(test)"
- `Symbol("test").description` → "test"
- `let s = Symbol(); let o = {}; o[s] = 42; o[s]` → 42
- `Symbol() == null` → false
- `Symbol() == undefined` → false

---

## Feature 7: Generators + Iterator Protocol

### Current State
- Parser: `function*` and `yield` are parsed (AST has `yield_expr`, `Function.is_generator`)
- Compiler: `yield_expr` is **not compiled** — ignored entirely
- VM: No generator state management, but has Continuation struct for async/await

### Design

**Generator architecture**: Reuse async/await's `Continuation` struct pattern (vm.zig:110-117).

**New opcodes**:
- `yield_value`: Save current frame state, return `{ value: X, done: false }` to caller
- `yield_delegate`: `yield* iterable` — forward to sub-iterator

**GeneratorObject** (new obj_type in object.zig):
```zig
.generator => struct {
    state: enum { suspended_start, suspended_yield, executing, completed },
    // Reuse Continuation for saved state:
    continuation: ?*Continuation,  // null when suspended_start or completed
    function: *FunctionObj,
    upvalues: []?*UpvalueCell,     // captured variables (reviewer fix)
},
```

Note: `saved_stack` in Continuation is a **shallow copy** (pointer values, not deep clones).
This is correct JS semantics — object mutations between `.next()` calls are visible to the generator.

**Compiler changes**:
- When `Function.is_generator`, emit `yield_value` for `yield expr` nodes
- Generator function body compiled normally
- `return expr` in generator context emits: compile(expr), `yield_value` with done=true flag
- `new_function` carries the `is_generator` flag to FunctionObj

**VM changes**:

1. **Calling a generator function**: Detect `is_generator` flag. Don't execute body. Create GeneratorObject in `suspended_start` state. Register `.next()`, `.return()`, `.throw()` as native methods. Register `Symbol.iterator` → returns self.

2. **`.next(value)`**:
   - `suspended_start`: Push new call frame for generator function, execute until first yield/return
   - `suspended_yield`: Restore continuation (IP, stack, locals, upvalues), push `value` onto stack (as yield expression result), continue execution
   - `completed`: Return `{ value: undefined, done: true }`

3. **`yield_value` opcode**:
   - Pop value from stack
   - Save IP, stack, locals, upvalues to Continuation
   - Set state to `suspended_yield`
   - Return `{ value: popped_value, done: false }` to `.next()` caller via callJsFunction return

4. **`.return(value)`**: Set state to `completed`, return `{ value, done: true }`

5. **`.throw(error)`**: Restore continuation, throw error at yield point (push to exception handling)

### Iterator Protocol Integration

**Critical: Array/String Symbol.iterator registration** (prevents for-of regression):

When Symbol support is added, MUST register `Symbol.iterator` on built-in prototypes:

```zig
// Array.prototype[Symbol.iterator] — returns index-based iterator
fn nativeArrayIterator(vm: *VM, this: JsValue, args: []const JsValue) !JsValue {
    // Return iterator object with .next() that walks array by index
    const iter = try vm.createIteratorObject(this, 0); // start index
    return JsValue.initObject(iter);
}

// String.prototype[Symbol.iterator] — returns char-based iterator
fn nativeStringIterator(vm: *VM, this: JsValue, args: []const JsValue) !JsValue {
    // Return iterator object with .next() that walks string chars
    ...
}
```

**for-of compilation update** (compiler.zig):

Dual-path approach to avoid breaking existing array for-of:

```
// for (let x of iterable) { body }
compile(iterable)
// Try iterator protocol first, fall back to index-based for arrays
get_iterator                  // new opcode: calls Symbol.iterator, or falls back to array indexing
loop:
  dup                         // [iter, iter]
  call_method "next" 0        // [iter, {value, done}]
  dup                         // [iter, result, result]
  get_prop "done"             // [iter, result, done]
  jump_if_true → cleanup      // pops done → [iter, result]
  get_prop "value"            // [iter, value]  (get_prop replaces TOS)
  store_local x               // [iter, value] — store to x
  pop                         // [iter]
  compile(body)
  jump → loop
cleanup:                      // [iter, result]
  pop                         // [iter]
  pop                         // []
end:
```

The `get_iterator` opcode:
1. Check if object has `Symbol.iterator` property → call it to get iterator
2. If no `Symbol.iterator` but is array → create default array iterator
3. If no `Symbol.iterator` but is string → create default string iterator
4. Otherwise → throw TypeError "X is not iterable"

This ensures backward compatibility: existing for-of on arrays still works even before
all prototypes get `Symbol.iterator`.

### Tests
- `function* g() { yield 1; yield 2; } let it = g(); it.next().value` → 1
- `it.next().value` → 2
- `it.next().done` → true
- `function* range(n) { for(let i=0;i<n;i++) yield i; } [...range(3)]` → [0,1,2]
- `for (let x of [1,2,3]) {}` → still works (regression test!)
- `for (let c of "abc") {}` → still works
- `function* f() { return 42; } f().next()` → { value: 42, done: true }
- `function* f() { let x = yield 1; yield x + 10; } let it=f(); it.next(); it.next(5).value` → 15
- Generator as iterator: `for (let x of g()) { ... }`
- `yield*` delegation: `function* a() { yield 1; } function* b() { yield* a(); yield 2; }`

---

## Feature 8: WeakMap / WeakSet

### Design

Since kotori has no GC, implement as thin wrappers using object pointer as key for API compatibility.

**Note**: If a GC or memory compactor is ever added, the pointer-based identity will break.
This is acceptable for now — WeakMap/WeakSet will need to be revisited alongside GC design.

**WeakMap methods**: `get(key)`, `set(key, value)`, `has(key)`, `delete(key)`
**WeakSet methods**: `add(value)`, `has(value)`, `delete(value)`

Key constraint: only objects as keys (throw TypeError for primitives).

Internal storage: `std.AutoHashMapUnmanaged(usize, JsValue)` keyed by `@intFromPtr(obj)`.

### Tests
- `let wm = new WeakMap(); let o = {}; wm.set(o, 42); wm.get(o)` → 42
- `new WeakMap().set(1, 2)` → TypeError
- `let ws = new WeakSet(); let o = {}; ws.add(o); ws.has(o)` → true
- `new WeakSet().add("string")` → TypeError
- `let wm = new WeakMap(); let o = {}; wm.set(o, 1); wm.delete(o); wm.has(o)` → false

---

## Files Modified

| File | Changes |
|------|---------|
| `ast.zig` | `member.optional`, `computed_member.optional` fields |
| `bytecode.zig` | New opcodes: `jump_if_nullish`, `jump_if_not_nullish`, `spread_into_array`, `call_spread`, `call_method_spread`, `construct_spread`, `define_getter`, `define_setter`, `yield_value`, `yield_delegate`, `get_iterator` |
| `parser.zig` | Optional flag propagation in `parseMember`/`parseComputedMember` |
| `compiler.zig` | Nullish, optional chaining, spread, getter/setter, generator, for-of iterator compilation |
| `vm.zig` | New opcode handlers, Symbol runtime, Generator runtime, WeakMap/Set builtins, typeof update |
| `value.zig` | Symbol value tag + helpers |
| `object.zig` | `symbol_props`, `getters`/`setters` maps, GeneratorObject data |

## Non-Goals
- `Proxy` / `Reflect` — complex metaprogramming, deferred
- `BigInt` — requires arbitrary precision math, deferred
- `ArrayBuffer` / TypedArrays — binary data, deferred
- Async generators (`async function*`) — deferred until generators stable
- Full `Symbol` spec (Symbol.species, Symbol.match etc.) — only core symbols
- `structuredClone` — JSON round-trip too lossy, deferred until proper deep-clone
