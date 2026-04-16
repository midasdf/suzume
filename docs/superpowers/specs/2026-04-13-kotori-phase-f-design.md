# kotori Phase F: Bug Fixes + Modern JS Features

## Overview

Phase F addresses critical JS correctness bugs and adds two high-impact modern JS features.
Ordered by priority: correctness fixes first, then features.

## Part 1: Bug Fixes

### Task 1: Empty String Falsiness

**Problem**: `JsValue.isTruthy()` returns `true` for all strings including `""`.
Every `if (str)` / `!str` / ternary on empty string is broken.

**Root cause**: `value.zig:158` — `isTruthy` has no StringPool access to check string length.

**Fix**:
1. Reserve `StringId 0` for the empty string `""` by interning it in `StringPool.init()`
2. Export `pub const EMPTY_STRING_ID: StringId = 0;`
3. In `isTruthy`: `if (self.isString()) return self.asStringId() != EMPTY_STRING_ID;`

**Files**: `string_pool.zig`, `value.zig`

**Tests**:
- `"" ? "yes" : "no"` → `"no"`
- `!"" === true`
- `"hello" ? 1 : 0` → `1`
- `if ("") { ... } else { ... }` takes else branch

---

### Task 2: Spread Generator Fix (`[...generator()]`)

**Problem**: `spread_into_array` opcode uses `callJsFunction` for generators, causing re-entrant VM stack corruption. The generator path (vm.zig:858-873) manually calls `.next()` via `callJsFunction` which does a nested `run()`.

**Fix** (two steps):
1. Add `Symbol.iterator` returning `this` to `createGeneratorObject` (vm.zig:5931). This is correct per ES6 — generators are iterables. Use a native function that returns `this`.
2. Remove the dedicated generator branch in `spread_into_array` (vm.zig:858-873). The `findSymbolProp` path (vm.zig:877-881) now handles generators via `drainIteratorIntoArray`.

**Files**: `vm.zig` (createGeneratorObject + spread_into_array opcode handler)

**Tests**:
- `[...function*() { yield 1; yield 2; }()]` → `[1, 2]`
- `let g = function*() { yield "a"; yield "b"; }; [...g()]` → `["a", "b"]`

---

### Task 3: String Iterator UTF-8

**Problem**: String spread and string iterator split by byte, not UTF-8 codepoint. Multi-byte characters (CJK, emoji) are corrupted.

**Current**: `vm.zig` string spread at line ~884 iterates bytes with `for (s) |c|`.
Also affects the iterator object for strings in `resolveIterator`/`nativeIteratorNext`.

**Fix**:
1. String spread in `spread_into_array`: use `std.unicode.Utf8View` to iterate codepoints
2. String `IteratorData.next()`: advance by UTF-8 codepoint, not byte
3. Intern each codepoint as a string slice, not a single byte

**Files**: `vm.zig`

**Tests**:
- `[..."あいう"]` → `["あ", "い", "う"]`
- `for (let c of "🎉ok") ...` yields `"🎉"`, `"o"`, `"k"`
- `[..."hello"]` → `["h", "e", "l", "l", "o"]` (ASCII regression)

---

## Part 2: Features

### Task 4: Destructuring in Function Parameters

**Problem**: `function({a, b}) {}` and `([x, y]) => ...` crash or silently fail because `compileFunctionBody` only handles `identifier`, `assign_pattern`, and `rest_element` params.

**Fix**: In `compileFunctionBody` param handling:
1. For `array_pattern`/`object_pattern` params: allocate a placeholder local (unnamed)
2. After all params are registered as locals, emit destructuring code:
   - `load_local` the placeholder slot
   - Call existing `compileArrayDestructure`/`compileObjectDestructure`
   - `pop` the source value
3. Handle nested: `function({a, b: [x, y]}) {}` — already supported by existing destructure code

**Parser**: No changes needed — already parses patterns in param position.

**Files**: `compiler.zig` (compileFunctionBody)

**Tests**:
- `function f({a, b}) { return a + b; } f({a: 1, b: 2})` → `3`
- `let f = ([x, y]) => x * y; f([3, 4])` → `12`
- `function f({a = 10}) { return a; } f({})` → `10`
- `function f({a: {b}}) { return b; } f({a: {b: 42}})` → `42`

---

### Task 5: Tagged Template Literals

**Syntax**: `` tag`text ${expr} text` `` compiles to `tag(strings, ...exprs)` where `strings` is a frozen array of string parts with a `.raw` property.

**Parser changes**:
- Treat backtick as an infix operator in the Pratt parser (at `call_` precedence level) when it follows an expression
- AST node: `tagged_template: struct { tag: NodeIndex, quasi: NodeList, exprs: NodeList }`

**Compiler changes**:
- Emit: create strings array from quasi parts, add `.raw` property (array of unescaped strings), compile each expression, call tag function with (strings, expr1, expr2, ...)
- Note: `.raw` contains the raw source text without escape processing (e.g. `\n` stays as `\n` not newline)

**VM changes**: None — uses existing array creation + function call opcodes.

**Files**: `ast.zig`, `parser.zig`, `compiler.zig`

**Tests**:
- `` function tag(s, ...v) { return s[0] + v[0] + s[1]; } tag`a${1}b` `` → `"a1b"`
- `` function raw(s) { return s.length; } raw`a${0}b${0}c` `` → `3`

---

## Out of Scope

- `yield* .throw()/.return()` forwarding — rare in practice
- Async generator concurrent `.next()` — spec-level edge case
- Full `Proxy`/`Reflect` — Phase G candidate

## Implementation Order

1. Task 1 (empty string) → 2 (spread fix) → 3 (UTF-8) → 4 (destructuring params) → 5 (tagged templates)

Each task: write failing test → implement fix → verify all 469+ tests still pass.
