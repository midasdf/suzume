# kotori JS Engine — Builtins & Missing Features Design

**Date**: 2026-04-12
**Scope**: instanceof fix, Error objects, Number.prototype, Date, Promise aggregation, console expansion

---

## 1. `instanceof` / `in` Operator Fix

### Problem
Parser recognizes `instanceof` and `in_` as AST nodes, but `binaryOpToOpCode()` falls through to `else => .add`. `x instanceof Array` compiles as `x + Array`.

### Design

**bytecode.zig**: Add two opcodes:
- `instanceof_` — prototype chain walk
- `in_` — property existence check

**compiler.zig**: Add to `binaryOpToOpCode`:
```
.instanceof => .instanceof_,
.in_ => .in_,
```

**vm.zig execution** (compiler pushes lhs then rhs, so pop yields rhs first):
```
// instanceof:
constructor = pop()  // right operand (pushed second)
obj = pop()          // left operand (pushed first)
target_proto = constructor.prototype
walk obj.__proto__ chain:
  if current == target_proto → push true, done
push false

// in:
obj = pop()   // right operand (pushed second)
key = pop()   // left operand (string, pushed first)
push obj.hasProperty(key)  // includes prototype chain
```

> **Note**: `Symbol.hasInstance` override for `instanceof` is deferred until Symbol support is implemented.

---

## 2. Error Objects

### Constructors
`Error`, `TypeError`, `ReferenceError`, `SyntaxError`, `RangeError`, `URIError`, `EvalError`, `AggregateError`

### Prototype Chain
```
TypeError.prototype.__proto__ = Error.prototype
Error.prototype = { name: "Error", message: "", toString(), constructor }
```

### Properties
- `name` — Error type name (e.g. "TypeError")
- `message` — User-provided message string
- `stack` — **Deferred to future session** (requires call frame tracking)

### `toString()`
Returns `"${name}: ${message}"` or just `"${name}"` if message is empty.

### Construction Behavior
Both `new Error("msg")` and `Error("msg")` (without new) return an Error object (per JS spec).

### AggregateError
- `new AggregateError(errors, message)`
- `errors` property: array of rejection reasons
- Used by `Promise.any` when all promises reject

---

## 3. Number.prototype Methods

### VM Changes
- Add `number_proto: ?*JsObject = null` to VM struct
- In property access path: when value is number/int, look up method on `number_proto`

### Instance Methods (on number_proto)

| Method | Behavior |
|--------|----------|
| `toFixed(digits)` | Format with `digits` decimal places → string. `digits` defaults to 0, range 0-100 |
| `toString(radix)` | Convert to string in base `radix` (2-36, default 10) |
| `toPrecision(precision)` | Format with `precision` significant digits → string |
| `toExponential(fractionDigits)` | Exponential notation → string |
| `valueOf()` | Return the numeric value itself |

### Number Constructor (static methods)

| Method | Behavior |
|--------|----------|
| `Number.isNaN(v)` | `true` only if v is the JS NaN value (not any NaN-boxing tag pattern; check via `value.isNan()` not raw bit test) |
| `Number.isFinite(v)` | `true` if number and finite (no coercion) |
| `Number.isInteger(v)` | `true` if number and has no fractional part |
| `Number.parseInt(s, radix)` | Delegates to global `parseInt` |
| `Number.parseFloat(s)` | Delegates to global `parseFloat` |

### Number Constants

| Constant | Value |
|----------|-------|
| `Number.MAX_SAFE_INTEGER` | 2^53 - 1 |
| `Number.MIN_SAFE_INTEGER` | -(2^53 - 1) |
| `Number.EPSILON` | 2^-52 |
| `Number.NaN` | NaN |
| `Number.POSITIVE_INFINITY` | +Infinity |
| `Number.NEGATIVE_INFINITY` | -Infinity |
| `Number.MAX_VALUE` | ~1.7976931348623157e+308 |
| `Number.MIN_VALUE` | ~5e-324 |

---

## 4. Date Object

### Object Model
- New `obj_type`: `.date` in JsObject
- Internal data: `i64` (Unix milliseconds since epoch)
- Invalid dates store a sentinel value that causes all getters to return NaN

### Constructor

| Form | Behavior |
|------|----------|
| `new Date()` | Current time (`std.time.milliTimestamp()`) |
| `new Date(milliseconds)` | From Unix ms |
| `new Date(dateString)` | Parse ISO 8601 / RFC 2822 / casual formats |
| `new Date(y, m, d, h, min, s, ms)` | Component construction (month is 0-based) |
| `Date()` (no new) | Returns current time as string |

### Static Methods

| Method | Behavior |
|--------|----------|
| `Date.now()` | Current Unix ms as number |
| `Date.parse(string)` | Parse → Unix ms (or NaN) |
| `Date.UTC(y, m, d, h, min, s, ms)` | Components → Unix ms (UTC) |

### Prototype Methods — Getters (Local)

`getFullYear`, `getMonth`, `getDate`, `getDay`, `getHours`, `getMinutes`, `getSeconds`, `getMilliseconds`, `getTime`

### Prototype Methods — Getters (UTC)

`getUTCFullYear`, `getUTCMonth`, `getUTCDate`, `getUTCDay`, `getUTCHours`, `getUTCMinutes`, `getUTCSeconds`, `getUTCMilliseconds`

### Prototype Methods — Setters (Local)

`setFullYear`, `setMonth`, `setDate`, `setHours`, `setMinutes`, `setSeconds`, `setMilliseconds`, `setTime`

### Prototype Methods — Setters (UTC)

`setUTCFullYear`, `setUTCMonth`, `setUTCDate`, `setUTCHours`, `setUTCMinutes`, `setUTCSeconds`, `setUTCMilliseconds`

### Prototype Methods — Conversion

| Method | Output |
|--------|--------|
| `toString()` | `"Sat Apr 12 2026 15:30:00 GMT+0900"` |
| `toDateString()` | `"Sat Apr 12 2026"` |
| `toTimeString()` | `"15:30:00 GMT+0900"` |
| `toISOString()` | `"2026-04-12T06:30:00.000Z"` |
| `toUTCString()` | `"Sat, 12 Apr 2026 06:30:00 GMT"` |
| `toJSON()` | Same as `toISOString()` |
| `toLocaleDateString()` | `"4/12/2026"` (en-US default) |
| `toLocaleTimeString()` | `"3:30:00 PM"` (en-US default) |
| `toLocaleString()` | `"4/12/2026, 3:30:00 PM"` (en-US default) |
| `valueOf()` | Unix ms as number |

### `getTimezoneOffset()`
Returns minutes difference between UTC and local.

### Timezone / Calendar Decomposition Strategy
Zig's `std.time` provides epoch timestamps but not calendar decomposition with TZ awareness. Implementation uses `@cImport` of `<time.h>` for:
- `localtime_r(&time_t, &tm)` — epoch → local calendar fields (DST-aware)
- `gmtime_r(&time_t, &tm)` — epoch → UTC calendar fields
- `mktime(&tm)` — local calendar fields → epoch (for setters)
- `timegm(&tm)` or manual calculation — UTC calendar fields → epoch

All 14 local getters/setters need `localtime_r` → decompose → extract field. All UTC getters/setters use `gmtime_r` or direct arithmetic (simpler). Setters decompose current time, modify field(s), recompose via `mktime`/`timegm`.

DST transitions: `localtime_r` handles DST automatically via system tzdata. Edge cases (ambiguous/skipped hours) follow C library behavior — this is what V8 and SpiderMonkey do too.

### Date.parse() Format Support
1. **ISO 8601** (primary): `2026-04-12T10:30:00.000Z`, `2026-04-12`, `2026-04-12T10:30:00+09:00`
2. **RFC 2822**: `Sat, 12 Apr 2026 06:30:00 GMT` — month name lookup + field extraction
3. **Casual**: `"Apr 12, 2026"`, `"April 12 2026"` — month name + numeric fields heuristic
4. **Ambiguous numeric**: `"12/04/2026"` — treat as MM/DD/YYYY (US convention, matches V8 behavior)
5. Returns `NaN` for unparseable strings

Parsing is implemented as a chain: try ISO 8601 first, then RFC 2822, then casual heuristic. Each parser is a separate function for testability.

### Locale Handling
`toLocaleXxx` methods produce en-US format by default. Structure allows future replacement when Intl support is added.

---

## 5. Promise Aggregation Methods

All added as static methods on the Promise constructor.

### Promise.all(iterable)
- Wraps each element with `Promise.resolve()`
- Internal counter tracks fulfilled count
- On all fulfilled → resolve with results array (preserving order)
- On any reject → immediately reject with that reason
- Empty array → resolve with `[]`

### Promise.race(iterable)
- First promise to settle (resolve or reject) determines result
- Empty array → never settles (pending forever, per JS spec)
- **Memory note**: on 512MB device, orphaned pending promises from `Promise.race([])` are a leak risk. Acceptable for now since this pattern is rare in real code; revisit if GC/weak-ref support is added later

### Promise.allSettled(iterable)
- Waits for all to settle
- Result array of `{ status: "fulfilled", value }` or `{ status: "rejected", reason }`
- Empty array → resolve with `[]`

### Promise.any(iterable)
- First promise to fulfill → resolve with that value
- All reject → reject with `AggregateError(errors)`
- Empty array → reject with `AggregateError([])`

### Implementation Pattern
Each method creates a result promise, iterates the input array, and attaches `then` handlers that update shared state (counter, results array). When the completion condition is met, the result promise is resolved/rejected.

---

## 6. Console Expansion

### New Methods

| Method | Prefix | Behavior |
|--------|--------|----------|
| `console.log` | (none) | Existing — unchanged |
| `console.warn` | `[WARN]` | Same format as log |
| `console.error` | `[ERROR]` | Same format as log |
| `console.info` | `[INFO]` | Same format as log |
| `console.debug` | `[DEBUG]` | Same format as log |
| `console.dir` | (none) | Object property listing |
| `console.assert` | `[ASSERT]` | Print if first arg is falsy |
| `console.time(label)` | (none) | Start named timer |
| `console.timeEnd(label)` | (none) | Print elapsed ms |
| `console.timeLog(label)` | (none) | Print elapsed without stopping |
| `console.count(label)` | (none) | Print call count |
| `console.countReset(label)` | (none) | Reset counter |
| `console.clear` | (none) | No-op |
| `console.trace` | `Trace:` | Print args + stack (basic until stack trace impl) |
| `console.group(label)` | (none) | Increase indent |
| `console.groupEnd` | (none) | Decrease indent |
| `console.table` | (none) | Simple tabular format for arrays/objects |

### VM Additions
- `console_timers: std.StringHashMapUnmanaged(i64)` — for time/timeEnd/timeLog (capped at 1024 entries)
- `console_counts: std.StringHashMapUnmanaged(u32)` — for count/countReset (capped at 1024 entries)
- `console_indent: u32 = 0` — for group/groupEnd (capped at 16 levels)

All output goes to stderr. Timer/counter maps silently ignore new entries once cap is reached to prevent unbounded growth from pathological JS.

---

## Implementation Order

1. **instanceof + in** — bytecode + compiler + VM (smallest change, unblocks Error instanceof checks)
2. **Error objects** — constructors + prototypes (needed by Promise.any's AggregateError)
3. **Number.prototype** — number_proto + static methods + constants
4. **Date** — obj_type + constructor + full method set + parsing
5. **Promise.all/race/allSettled/any** — static methods on Promise constructor
6. **console expansion** — methods + timer/counter state

Each step: implement → add tests → verify → next.

---

## Future Work (deferred)
- `Error.prototype.stack` — requires call frame source mapping
- `console.trace` full stack — same dependency
- `Intl.DateTimeFormat` — locale-aware formatting
- `Date` edge cases: leap seconds, DST transitions
