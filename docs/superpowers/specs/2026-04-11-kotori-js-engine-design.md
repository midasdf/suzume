# kotori — JS Engine for suzume Browser

Spec-driven JavaScript engine written in Zig, replacing QuickJS-ng dependency.

## Motivation

QuickJS-ng has fundamental issues in suzume:
- Heap corruption on heavy JS pages (google.com shape hash crash)
- GC disabled (SIZE_MAX threshold) to avoid list corruption, causing different corruption
- 5,428 C API call sites across 15 files (26,704 LOC) — brittle integration
- No control over memory model, GC behavior, or crash recovery

kotori gives full control: Zig-native memory management, comptime DOM bindings, spec-driven correctness.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Spec compliance | ECMAScript, Test262-driven | Minimal approach causes rework; spec-driven is correct from start |
| Execution | Bytecode stack-based VM | Tree-walk too slow for real sites; VM matches ES execution model |
| GC | Generational: nursery bump + tenured arena + mark-sweep | Fastest alloc (bump = pointer increment), page navigation = instant free |
| DOM binding | comptime declaration → vtable auto-generation | Combines developer ergonomics (declarative) with runtime speed (vtable) |
| Value repr | NaN-boxing (64-bit) | Cache-efficient, zero-cost double ops, same as V8/SpiderMonkey/JSC |
| Compliance target | Test262 ES5 70% (Phase 1) | Quantitative; prioritized over site-specific hacks |

## Architecture

```
Source Code (UTF-8)
    │
    ▼
┌─────────┐
│  Lexer   │  → Token stream
└────┬─────┘
     ▼
┌─────────┐
│  Parser  │  → AST (spec-compliant)
└────┬─────┘
     ▼
┌──────────┐
│ Compiler │  → Bytecode (per-function)
└────┬─────┘
     ▼
┌─────────┐    ┌──────────────┐
│   VM    │◄──►│ Native Binds │ (DOM, Web APIs)
└────┬────┘    └──────────────┘
     │
     ▼
┌────────────────┐
│ Generational   │
│ GC + Page Arena│
└────────────────┘
```

Components are independent modules. Lexer → Parser → Compiler are pure transformations with no side effects. Only VM is stateful.

## Value Representation (NaN-boxing)

All JS values fit in 64 bits using IEEE 754 NaN space:

```zig
pub const JsValue = packed struct {
    bits: u64,

    // Tag encoding: upper 16 bits of the u64
    // 0x7FF8 is reserved as the canonical NaN — all NaN doubles are
    // canonicalized to 0x7FF8_0000_0000_0000 on input.
    // Tags 0x7FF9-0x7FFF encode non-double types in the NaN payload.
    const TAG_NAN:       u16 = 0x7FF8; // canonical NaN (the JS value NaN)
    const TAG_NULL:      u16 = 0x7FF9;
    const TAG_UNDEFINED: u16 = 0x7FFA;
    const TAG_BOOL:      u16 = 0x7FFB;
    const TAG_INT:       u16 = 0x7FFC; // small integer (avoids boxing)
    const TAG_OBJECT:    u16 = 0x7FFD;
    const TAG_STRING:    u16 = 0x7FFE;
    const TAG_SYMBOL:    u16 = 0x7FFF;

    /// Returns true if this value holds a GC-managed pointer (object or string).
    pub inline fn isGcPtr(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_OBJECT or tag == TAG_STRING;
    }
};
```

- Doubles pass through at zero cost (most frequent numeric ops)
- All NaN doubles are canonicalized to `0x7FF8_0000_0000_0000` on creation. Tags 0x7FF9-0x7FFF are unambiguously non-double.
- Pointers use lower 48 bits (x86_64 virtual address space)
- Fixed 8-byte size: simple stack operations, cache-friendly
- `isGcPtr()`: precise tag check for GC scanning — no ambiguity between doubles and pointers

## Object Model

```zig
pub const JsObject = struct {
    gc_header: GcHeader,
    prototype: ?*JsObject,
    properties: PropertyStorage,
    native: ?NativeObject = null,
    kind: ObjectKind,
};

pub const GcHeader = struct {
    marked: bool = false,
    generation: u1 = 0,      // 0 = nursery, 1 = tenured
    forwarded: ?*JsObject = null, // forwarding pointer for nursery copy
};

pub const ObjectKind = union(enum) {
    ordinary,
    array: struct { length: u32 },
    function: struct {
        bytecode: *Bytecode,
        closure: ?*Environment,
        is_constructor: bool,
    },
    bound_function: struct { target: *JsObject, this_arg: JsValue, bound_args: []JsValue },
    native_function: struct { func: *const fn (*VM, []JsValue) JsValue, name: []const u8 },
    string_object: struct { value: *JsString },
    regexp: struct { inner: *RegExpInner },
    promise: struct { state: enum { pending, fulfilled, rejected }, result: JsValue },
};

pub const NativeObject = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        get: *const fn (*anyopaque, []const u8) ?JsValue,
        set: *const fn (*anyopaque, []const u8, JsValue) bool,
        call: ?*const fn (*anyopaque, *VM, []JsValue) JsValue,
        finalize: *const fn (*anyopaque) void,
    };
};
```

### PropertyStorage

Two representations, auto-promoting for performance:

```zig
pub const PropertyStorage = union(enum) {
    /// Inline storage for ≤8 properties. No heap allocation.
    /// Linear scan is faster than hashmap for small N due to cache locality.
    inline_: struct {
        entries: [8]PropertyEntry = undefined,
        len: u8 = 0,
    },
    /// HashMap for >8 properties. Open addressing with Robin Hood hashing.
    map: *PropertyMap,
};

pub const PropertyEntry = struct {
    key: u32,           // interned string ID (not a pointer — avoids GC tracing)
    value: JsValue,
    flags: PropertyFlags,
};

pub const PropertyFlags = packed struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    is_accessor: bool = false, // if true, value is getter; setter stored adjacently
};
```

- Property keys are interned string IDs (u32 index), not pointers. No GC overhead for keys.
- Inline array: 8 entries × 16 bytes = 128 bytes. Fits in 2 cache lines.
- Auto-promote to Robin Hood hashmap on 9th property insertion.
- Threshold (8) tunable based on Test262 profiling results.

## String Representation

```zig
pub const JsString = struct {
    gc_header: GcHeader,
    encoding: enum { ascii, utf8 },
    len_utf16: u32,         // ECMAScript string length (UTF-16 code units)
    hash: u32,              // cached hash (0 = not computed)
    bytes: []const u8,      // UTF-8 encoded content
};
```

- **Internal encoding: UTF-8.** Compact storage, efficient for I/O and DOM interaction.
- **Semantic length: UTF-16 code units** per ECMAScript spec. `string.length` returns `len_utf16`, computed at creation.
- **`charCodeAt(i)`**: walks UTF-8 bytes to find the i-th UTF-16 code unit. O(n) worst case, but cached index acceleration for sequential access (common pattern in loops).
- **ASCII fast path**: when all bytes are <0x80, `encoding = .ascii` and `charCodeAt` is O(1) array index. ~90% of web strings are ASCII.
- **Interning**: all property name strings are interned in a global `StringTable` (hashmap from bytes→ID). Strings used as values are NOT interned (too many, would bloat table).
- **No rope**: concat creates new flat strings. Ropes add complexity with minimal benefit for typical web JS. If profiling shows concat-heavy code, revisit.

## Memory Management (Generational GC)

```
Generation 0 (nursery): bump allocator, 512KB heap-allocated
  → On full: copy surviving objects to Gen1, reset bump pointer
  → Alloc = pointer increment (1 instruction)
  → Most JS temporaries die here (functions args, intermediate results)

Generation 1 (tenured): arena allocator
  → Long-lived objects (globals, closures, DOM-bound)
  → Mark-sweep when tenured allocation exceeds threshold
  → Threshold dynamically adjusted (2x surviving bytes)

Page navigation: Gen0 reset + Gen1 arena.deinit() → instant cleanup
```

### Nursery (Gen0)

```zig
pub const Nursery = struct {
    buf: []align(8) u8,    // heap-allocated, default 512KB
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Nursery {
        return .{ .buf = try allocator.alignedAlloc(u8, 8, size) };
    }

    pub inline fn alloc(self: *Nursery, size: usize) ?[*]u8 {
        const aligned = std.mem.alignForward(usize, size, 8);
        if (self.pos + aligned > self.buf.len) return null; // full → minor GC
        const ptr = self.buf[self.pos..][0..aligned];
        self.pos += aligned;
        return ptr.ptr;
    }

    pub inline fn reset(self: *Nursery) void {
        self.pos = 0;
    }
};
```

- 512KB default (holds ~4,000-6,000 objects). Configurable via init.
- Heap-allocated (not embedded in struct) so size is adjustable.

### Write Barrier

Generational GC requires tracking pointers from tenured (Gen1) objects to nursery (Gen0) objects. Without this, minor GC would collect live nursery objects referenced only from old-gen.

**Strategy: store buffer (sequential log).** Chosen for minimal overhead on the write path.

```zig
pub const StoreBuffer = struct {
    /// Log of tenured-object slots that point into the nursery.
    entries: std.ArrayListUnmanaged(*JsValue),

    pub inline fn record(self: *StoreBuffer, slot: *JsValue) void {
        self.entries.append(std.heap.c_allocator, slot) catch {};
    }

    pub fn processForMinorGC(self: *StoreBuffer) void {
        // Each logged slot is treated as an additional GC root during minor GC.
        // After minor GC relocates nursery objects, the slots are updated
        // with new tenured addresses, then the buffer is cleared.
        // (implementation details in gc.zig)
    }
};
```

**Where barriers are inserted** (compiler emits barrier calls for):
- `set_prop` / `set_elem`: when setting a property on a tenured object
- `store_upvalue`: when mutating a captured variable in a closure
- Array stores on tenured arrays

**Barrier fast path** (inline, ~3 instructions):
```zig
inline fn writeBarrier(heap: *PageHeap, obj: *JsObject, new_val: JsValue) void {
    // Skip if: object is in nursery, or new value is not a GC pointer
    if (obj.gc_header.generation == 0 or !new_val.isGcPtr()) return;
    // Skip if: new value is also tenured
    const target = new_val.asObject();
    if (target.gc_header.generation == 1) return;
    // Old-gen → young-gen pointer: record in store buffer
    heap.store_buffer.record(&obj.properties.slotOf(new_val));
}
```

Most writes hit the first `return` (nursery objects writing to nursery). The barrier cost is typically one branch.

### Minor GC (Nursery Collection)

Triggered when nursery bump allocator is full.

1. **Root enumeration** (precise, tag-based):
   - VM stack: scan `stack[0..sp]`, check each `JsValue.isGcPtr()`, follow if nursery pointer
   - Call frames: scan `frames[0..fp]` for local variables and saved `this`
   - Global object: scan all property values
   - Store buffer entries: tenured→nursery pointers
2. **Copy surviving objects** to tenured arena:
   - Set `gc_header.forwarded` to new tenured address
   - Walk all fields of copied object, recursively copy referenced nursery objects
3. **Update pointers**:
   - Revisit all roots and store buffer entries
   - Replace nursery pointers with their `.forwarded` address
4. **Reset nursery**: `self.pos = 0`

Forwarding pointer (`gc_header.forwarded`) is set in-place on the old nursery copy. Since nursery is about to be reset, this is safe — no memory leak.

### Major GC (Tenured Mark-Sweep)

Triggered when tenured arena allocation exceeds dynamic threshold.

1. **Mark**: walk from roots (global, stack, native pointers), mark reachable tenured objects
2. **Sweep**: scan all_objects list, unmark or flag unreachable. Call native finalizers on dead objects.
3. Note: tenured arena does not individually free memory. Sweep removes objects from the tracking list. Memory is reclaimed only on page navigation (arena.deinit).
4. **Adjust threshold**: `gc_threshold = max(512KB, bytes_in_use * 2)`

### Page Navigation: Instant Cleanup

```zig
pub fn destroyAll(self: *PageHeap) void {
    // Call native finalizers (DOM reference cleanup)
    for (self.all_objects.items) |obj| {
        if (obj.native) |n| n.vtable.finalize(n.ptr);
    }
    // Bulk free — no individual object teardown
    self.nursery.reset();
    self.arena.deinit();
}
```

No per-object free, no reference counting teardown, no cycle detection. This directly solves the QuickJS-ng heap corruption on deinit.

## Bytecode VM

```zig
pub const OpCode = enum(u8) {
    // Stack
    load_const, load_local, store_local, load_global, store_global,
    load_upvalue, store_upvalue, pop, dup, swap,

    // Properties
    get_prop, set_prop, get_elem, set_elem,

    // Arithmetic & comparison
    add, sub, mul, div, mod,
    eq, ne, lt, le, gt, ge, strict_eq, strict_ne,
    neg, not, bit_not, typeof_,
    instanceof_, in_,

    // Bitwise
    bit_and, bit_or, bit_xor, shl, shr, ushr,

    // Control flow
    jump, jump_if_false, jump_if_true,

    // Functions
    call, call_method, return_, return_undefined,

    // Objects
    new_object, new_array, new_function, new_regexp,

    // Special
    this, spread, throw_, enter_try, leave_try,

    // Variable declaration
    decl_var,            // var (function-scoped, hoisted)
    create_arguments,    // create arguments object

    // Iterator (ES6)
    iterator_next, iterator_close,
};

pub const Bytecode = struct {
    code: []const u8,
    constants: []JsValue,
    local_count: u16,
    param_count: u16,
    upvalue_count: u16,
    max_stack: u16,              // computed at compile time
    source_name: []const u8,
    line_map: []const LineEntry,
    exception_table: []const ExceptionEntry, // try/catch/finally handler table
    needs_arguments: bool,       // whether function uses `arguments`
    is_strict: bool,             // strict mode flag
};

pub const VM = struct {
    stack: []JsValue,            // heap-allocated, default 4096 slots
    sp: u32,
    frames: []CallFrame,         // heap-allocated, default 512 frames
    fp: u32,
    heap: *PageHeap,
    global: *JsObject,
    job_queue: JobQueue,         // microtask queue
};
```

- **Stack: 4096 slots**, heap-allocated. Supports deep recursion (DOM traversal, framework code). RangeError on overflow.
- **Frames: 512 call frames**. Sufficient for typical web JS. RangeError on overflow.
- Operands are U16: constant pool up to 65536 entries.
- max_stack: computed at compile time, minimizes runtime bounds checks.

### Exception Handling

Uses an **exception table** (not a handler chain). Each try/catch/finally block is compiled to a table entry mapping PC ranges to handlers. No runtime cost when no exception is thrown.

```zig
pub const ExceptionEntry = struct {
    start_pc: u32,       // try block start
    end_pc: u32,         // try block end (exclusive)
    handler_pc: u32,     // catch block entry point
    finally_pc: u32,     // finally block entry point (0 = no finally)
    stack_depth: u16,    // stack depth to unwind to before entering handler
};
```

**throw_ opcode**:
1. Search `exception_table` for entry where `start_pc <= current_pc < end_pc`
2. Unwind stack to `stack_depth`
3. Push the thrown value onto stack
4. Jump to `handler_pc` (catch) or `finally_pc`

**finally + return interaction**: when `return_` is executed inside a try block that has a finally clause, the return value is saved to a temporary slot and `finally_pc` is jumped to. After finally completes, the saved return value is restored and the function returns. This matches ECMAScript spec §13.15.

**Cross-frame unwinding**: if no handler is found in the current function's exception table, pop the call frame and search the caller's table. Repeat until a handler is found or the top-level frame is reached (→ uncaught exception).

## eval, with, arguments, strict mode

These ES5 features affect compiler and VM design fundamentally. Decisions:

### eval()
- **Direct eval** (`eval(...)`) prevents static scoping. Compiler marks containing functions as `needs_eval = true`. These functions use a dynamic environment (hashmap-based, not fixed-slot locals) for variable lookup.
- **Indirect eval** (`(0, eval)(...)`) runs in global scope. No impact on enclosing scopes.
- This is the simplest correct approach. If profiling shows overhead from dynamic environments, optimize later with a scope analysis pass.

### with statement
- **Supported in non-strict mode.** Compiled to a `push_with_scope` / `pop_with_scope` opcode pair that pushes/pops an object onto the scope chain.
- Variable lookup in `with` scope uses runtime hashmap lookup (slower than static locals). This is acceptable — `with` is rare in practice and banned in strict mode.

### arguments object
- `create_arguments` opcode creates the arguments object when `needs_arguments` flag is set.
- In **sloppy mode**: creates a mapped arguments object that aliases named parameters. Parameter mutation reflects in `arguments[i]` and vice versa. Uses property accessors internally.
- In **strict mode**: creates an unmapped copy (simple array-like object). Cheaper than mapped.
- Compiler detects `arguments` usage during parsing and sets the flag. Functions that don't reference `arguments` skip creation entirely.

### Strict mode
- Compiler detects `"use strict"` directive in function/script prologue.
- `is_strict` flag on Bytecode affects: `this` default (undefined vs global), `eval` scoping, `arguments` mapping, duplicate parameter names (error), `delete` on variables (error).
- VM checks `is_strict` in relevant opcodes (minimal runtime cost — single branch in affected paths).

## Event Loop Integration

kotori does NOT own the event loop. suzume's existing XCB event loop drives execution.

```
suzume main loop (XCB poll)
    │
    ├── Input events → JS event dispatch → vm.execute()
    ├── Timer tick → check timer heap → vm.execute(callback)
    ├── Microtask drain → vm.drainJobQueue()
    ├── restyle/repaint if dom_dirty
    └── sleep/poll until next event
```

### Job Queue (Microtasks)

```zig
pub const JobQueue = struct {
    /// FIFO queue of pending microtask callbacks (Promise reactions, queueMicrotask)
    queue: std.ArrayListUnmanaged(JsValue),

    pub fn enqueue(self: *JobQueue, callback: JsValue) void {
        self.queue.append(std.heap.c_allocator, callback) catch {};
    }

    /// Drain all microtasks. Called after each JS execution turn.
    pub fn drain(self: *JobQueue, vm: *VM) void {
        while (self.queue.items.len > 0) {
            const cb = self.queue.orderedRemove(0);
            _ = vm.callFunction(cb, &.{});
            // New microtasks enqueued during execution are drained in this same loop
        }
    }
};
```

### Timer Management

```zig
pub const TimerHeap = struct {
    timers: std.PriorityQueue(TimerEntry, void, compareFireTime),

    pub const TimerEntry = struct {
        id: u32,
        callback: JsValue,
        fire_at: i64,       // millisecond timestamp
        interval: ?i64,     // null = setTimeout, Some = setInterval
    };

    /// Returns next fire time (for suzume's poll timeout calculation)
    pub fn nextFireTime(self: *TimerHeap) ?i64 { ... }

    /// Fire all due timers. Called from suzume's main loop.
    pub fn tick(self: *TimerHeap, vm: *VM, now: i64) void { ... }
};
```

Integration with suzume's poll timeout:
```zig
const poll_timeout = if (needs_repaint) 0
    else if (vm.timer_heap.nextFireTime()) |t| @max(0, t - now)
    else 50; // idle
```

### Script Execution Limits

Interrupt handler via instruction counter (not wall-clock timer — more deterministic):

```zig
/// VM checks this counter every N instructions (e.g. every 10,000)
pub var instruction_budget: u32 = 10_000_000; // ~10M instructions per execution turn

// In VM dispatch loop:
instruction_count += 1;
if (instruction_count >= instruction_budget) return error.ExecutionTimeout;
```

## Error Recovery and Crash Isolation

### Isolation Model

Each page gets its own `PageHeap` (nursery + tenured arena + store buffer). A JS crash (OOM, stack overflow, timeout) is contained to that page:

1. **OOM in nursery**: minor GC is triggered. If GC cannot free enough, promote to major GC. If still OOM, throw JS `RangeError`.
2. **OOM in tenured**: throw JS `RangeError`. If allocation is critical (e.g. during GC itself), call `destroyAll()` and show error page.
3. **Stack overflow**: detected by `sp >= stack.len` check. Throw JS `RangeError`.
4. **Execution timeout**: instruction counter exceeded. Return error to suzume, which shows "Script not responding" UI.
5. **Unrecoverable error**: `destroyAll()` on the page heap. This is always safe because arena.deinit() has no per-object teardown. Browser continues running.

No Zig panic or segfault can originate from JS code — all memory access is through typed Zig pointers within the arena. Unlike QuickJS-ng's C code, there are no raw pointer arithmetic paths.

## RegExp

Phase 1 includes basic RegExp support. Implementation strategy:

- **Use Zig's `std.regex`** if available, otherwise a **minimal NFA engine** (~500-800 LOC).
- Phase 1 scope: character classes, quantifiers, alternation, groups, anchors. No lookahead/lookbehind.
- Phase 2 adds: backreferences, lookahead, named groups, Unicode property escapes.
- Test262 RegExp tests are counted separately; 70% target is for non-RegExp ES5 tests. RegExp compliance measured independently.

## comptime DOM Binding

```zig
// Declaration (DOM implementor writes this)
pub const ElementDef = JsClass(.{
    .name = "HTMLElement",
    .parent = "Node",
    .properties = &.{
        .{ .name = "tagName",   .get = Element.getTagName },
        .{ .name = "className", .get = Element.getClassName, .set = Element.setClassName },
        .{ .name = "innerHTML", .get = Element.getInnerHTML, .set = Element.setInnerHTML },
    },
    .methods = &.{
        .{ .name = "getAttribute",    .func = Element.getAttribute,    .argc = 1 },
        .{ .name = "querySelector",   .func = Element.querySelector,   .argc = 1 },
        .{ .name = "addEventListener", .func = Element.addEventListener, .argc = 2 },
    },
});

// Usage (VM init — one line per class)
ElementDef.installPrototype(vm);
DocumentDef.installPrototype(vm);
EventDef.installPrototype(vm);
```

- comptime generates VTable + dispatch functions. Zero runtime cost.
- `inline for` over properties optimizes to jump table at compile time.
- Replaces 5,428 manual `JS_SetPropertyStr` calls with declarative definitions.

## File Layout

```
suzume/src/js/
├── kotori/
│   ├── value.zig          # JsValue (NaN-boxing)
│   ├── object.zig         # JsObject, PropertyStorage, ObjectKind
│   ├── string.zig         # JsString (interning, UTF-8/UTF-16 bridge)
│   ├── lexer.zig          # Tokenizer
│   ├── parser.zig         # AST generation
│   ├── ast.zig            # AST node definitions
│   ├── compiler.zig       # AST → Bytecode
│   ├── bytecode.zig       # OpCode, Bytecode definitions
│   ├── vm.zig             # VM execution loop
│   ├── gc.zig             # Nursery + Tenured + StoreBuffer + PageHeap
│   ├── builtins/
│   │   ├── object.zig     # Object.keys, Object.assign, etc.
│   │   ├── array.zig      # Array.prototype.*
│   │   ├── string.zig     # String.prototype.*
│   │   ├── number.zig     # Number, Math
│   │   ├── function.zig   # Function.prototype.*
│   │   ├── json.zig       # JSON.parse, JSON.stringify
│   │   ├── regexp.zig     # RegExp (minimal NFA, Phase 1)
│   │   ├── date.zig       # Date (Phase 1, low priority)
│   │   ├── error.zig      # Error, TypeError, RangeError, etc.
│   │   ├── promise.zig    # Promise (Phase 2)
│   │   └── symbol.zig     # Symbol (Phase 2)
│   ├── binding.zig        # JsClass comptime framework
│   └── test_harness.zig   # Test262 runner
├── dom_bindings/
│   ├── element.zig        # HTMLElement binding
│   ├── document.zig       # Document binding
│   ├── node.zig           # Node binding
│   ├── event.zig          # Event, EventTarget binding
│   ├── style.zig          # CSSStyleDeclaration binding
│   ├── window.zig         # Window / globalThis binding
│   └── web_api.zig        # setTimeout, fetch, console etc.
├── runtime.zig            # Entry: JSRuntime (VM + GC + bindings init)
└── legacy/                # Migration: old QuickJS-ng code (deleted after full migration)
```

- **kotori/**: Pure JS engine, no suzume dependency. Reusable in other projects.
- **dom_bindings/**: suzume-specific DOM integration via JsClass declarations.
- **legacy/**: Old code preserved during migration, deleted when all bindings are ported.

## Migration Plan

### Strategy: Incremental, Parallel Runtime

During migration, kotori and QuickJS-ng coexist. A `runtime.zig` shim layer selects the engine:

```zig
pub const JsBackend = enum { quickjs, kotori };
pub var active_backend: JsBackend = .quickjs; // flip to .kotori per milestone
```

### Migration Order (smallest/simplest first)

| Step | Files | LOC | Notes |
|------|-------|-----|-------|
| M1 | runtime.zig | 425 | New runtime wrapping kotori VM |
| M2 | web_api.zig | 1,471 | setTimeout, console — uses TimerHeap/JobQueue |
| M3 | events.zig | 1,766 | Event dispatch — uses JsClass binding |
| M4 | dom_document.zig | 1,396 | Document binding |
| M5 | dom_element.zig | 1,650 | Element binding (largest DOM surface) |
| M6 | dom_node.zig | 1,516 | Node binding |
| M7 | dom_style.zig | 1,442 | CSSStyleDeclaration |
| M8 | dom_selector.zig, dom_text.zig, dom_serialize.zig | 478 | Small utilities |
| M9 | canvas.zig, iframe.zig, worker.zig | 802 | Optional features |
| M10 | Remove legacy/, delete QuickJS-ng dep | — | Final cleanup |

Each step is independently testable. After M5, example.com should render with kotori backend.

### Testing During Migration

- Each ported file gets unit tests against the new API
- Integration test: flip `active_backend = .kotori`, load example.com
- Test262 runs against kotori standalone (no browser dependency)
- Regression: existing WPT tests continue running against QuickJS until full switchover

## Implementation Phases

### Phase 1: ES5 Core (Target: Test262 ES5 70%)

| Step | Scope | Verification |
|------|-------|-------------|
| 1a | Lexer + Parser + AST | ECMAScript syntax tests |
| 1b | Compiler + VM basics | `1+1` evaluates to `2` |
| 1c | Object model + prototype chain | `{}.toString()` works |
| 1d | Functions + closures + scoping + arguments | Closure counter pattern works |
| 1e | GC (Nursery + Tenured + write barrier) | Mass object creation doesn't OOM |
| 1f | Exception handling (try/catch/finally) | Test262 exception tests |
| 1g | eval, with, strict mode | Test262 strict mode tests |
| 1h | ES5 builtins (Object, Array, String, Number, Math, JSON, Error, RegExp, Date, Function.prototype) | Test262 ES5 suite |
| 1i | DOM binding framework + suzume integration | example.com renders |

### Phase 2: ES6 Key Features

- let/const (TDZ), arrow functions, class syntax
- Promise + microtask queue
- Symbol, Iterator, for-of
- Template literals, destructuring
- Map, Set, WeakMap, WeakRef
- Verification: Test262 ES6 + jQuery 3.x works

### Phase 3: ES2020+

- async/await, optional chaining, nullish coalescing
- ES modules (import/export)
- Proxy, Reflect
- Verification: Real sites (iana.org, ietf.org, etc.)
