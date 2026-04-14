# kotori — Property Descriptor Infrastructure Design

**Date:** 2026-04-15
**Scope:** `src/js/kotori/object.zig` + `src/js/kotori/vm.zig` (Object.* natives)
**Target spec:** ECMAScript 2023 §10.1 (Ordinary Object Internal Methods and Internal Slots)
**Status:** Design only. No code changes.

---

## Executive Summary

The Phase C audit (`2026-04-15-suzume-phaseC-kotori-audit.md`) identifies six
ES2023 conformance violations — Object.freeze/seal/preventExtensions stubs,
Object.defineProperty ignoring descriptor flags, getOwnPropertyDescriptor
always reporting `{writable, enumerable, configurable} = true`, Object.keys
vs. getOwnPropertyNames being identical, propertyIsEnumerable always true,
and isPrototypeOf returning false — that all trace to a single missing
primitive: **per-property attribute bits and a per-object `[[Extensible]]`
flag**. This document specifies the minimal storage change, the abstract
operations that must be rewired onto it, the derived built-ins that fall out
for free, and a four-phase rollout that lands user-visible wins early while
keeping the hot path for plain data properties cheap.

The recommended representation is **Option C (hybrid fast/slow path)**:
keep the existing `StringId → JsValue` hash table as the fast path for
plain data properties with default attributes (`writable=true,
enumerable=true, configurable=true`), and spill to a lazily-allocated
side-map of full `PropertyDescriptor` records when a property gets
non-default attributes or becomes an accessor. The overwhelming majority
of JS objects (DOM properties, literal objects, class instance fields)
never leave the fast path, so idiomatic code pays zero additional cost.

---

## 1. Current Storage Model

`src/js/kotori/object.zig:35-130`:

```zig
pub const JsObject = struct {
    obj_type: ObjType = .ordinary,
    properties:  std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    prototype:   ?*JsObject = null,
    data:        ObjData = .none,
    getters:     ?std.AutoArrayHashMapUnmanaged(StringId, JsValue) = null,
    setters:     ?std.AutoArrayHashMapUnmanaged(StringId, JsValue) = null,
    symbol_props:?std.AutoArrayHashMapUnmanaged(u32, JsValue) = null,
    ...
    pub fn getProperty(self, name) ?JsValue { self.properties.get(name) ... }
    pub fn setProperty(self, alloc, name, val) !void { self.properties.put(...) }
};
```

Observations:

- A single flat `AutoArrayHashMap(StringId, JsValue)` is the only store for
  "own" data properties. Insertion order is preserved (good for `for-in`
  and `Object.keys` ordering).
- `getters` / `setters` maps exist but are orthogonal — they are consulted
  by a parallel lookup (audit line 4137) and not merged into the property
  record. `Object.defineProperty` at `vm.zig:4137` currently *invokes* the
  getter immediately and stores the return value, which is how the audit's
  finding #4 manifests.
- No attribute bits anywhere. No `[[Extensible]]` flag on the object.
- `symbol_props` is a secondary map for symbol keys; same defects apply.
- `getProperty` walks the prototype chain but does not distinguish
  data vs. accessor, does not invoke getters, and does not check
  writability.

Downstream callers in `vm.zig`:

| Built-in                       | Line  | Current behavior |
|--------------------------------|-------|------------------|
| `Object.keys`                  | 4076  | Returns all own string keys (no enumerable filter) |
| `Object.getOwnPropertyNames`   | 2070  | Delegates to `nativeObjectKeys` — identical |
| `Object.create`                | 4128  | Ignores `propertiesObject` argument |
| `Object.defineProperty`        | 4137  | Invokes getter eagerly, drops writable/enumerable/configurable |
| `Object.getOwnPropertyDescriptor` | 4199 | Returns `{value, writable:true, enumerable:true, configurable:true}` |
| `Object.isFrozen/isSealed`     | 2075  | `nativeReturnFalse` stub |
| `Object.isExtensible`          | 2077  | `nativeReturnTrue` stub |
| `propertyIsEnumerable`         | 2057  | `nativeReturnTrue` stub |
| `isPrototypeOf`                | 2056  | `nativeReturnFalse` stub |

---

## 2. Target Storage Model

### 2.1 PropertyDescriptor (full record)

```zig
pub const PropertyAttrs = packed struct(u8) {
    writable:     bool = true,
    enumerable:   bool = true,
    configurable: bool = true,
    is_accessor:  bool = false,   // 0 = data, 1 = accessor
    _pad:         u4 = 0,
};

pub const PropertyDescriptor = union(enum) {
    data:     struct { value: JsValue,       attrs: PropertyAttrs },
    accessor: struct { get: JsValue, set: JsValue, attrs: PropertyAttrs },
};
```

(`get` / `set` are each either a callable `JsValue` or `undefined`.
`is_accessor` in `attrs` is redundant with the union tag but convenient
for one-word attribute queries.)

### 2.2 Representation — Option C (recommended)

```zig
pub const JsObject = struct {
    obj_type: ObjType = .ordinary,
    // Fast path: value-only map. An entry here means
    //   {value, writable:true, enumerable:true, configurable:true, data}.
    properties: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    // Slow path: only allocated when at least one property has non-default
    // attrs or is an accessor. When present, it is authoritative —
    // `properties` must NOT also contain that key.
    descriptors: ?std.AutoArrayHashMapUnmanaged(StringId, PropertyDescriptor) = null,
    extensible: bool = true,
    prototype:  ?*JsObject = null,
    // symbol_props gets the same treatment via a parallel slow map.
    symbol_props:        ?std.AutoArrayHashMapUnmanaged(u32, JsValue) = null,
    symbol_descriptors:  ?std.AutoArrayHashMapUnmanaged(u32, PropertyDescriptor) = null,
    data: ObjData = .none,
};
```

Invariants:

1. A key appears in **exactly one** of `properties` / `descriptors`.
2. Iteration order for `for-in`/`Object.keys`/`getOwnPropertyNames`
   must remain stable across the two maps. Easiest: store an
   **ordered key list** (`std.ArrayListUnmanaged(Slot)`) and use the
   two maps only for O(1) lookup. Alternative (cheaper for now):
   iterate `properties` then `descriptors`; downgrade/upgrade always
   deletes-then-inserts, keeping most tests happy but breaking a few
   esoteric `for-in` ordering edge cases. Pick the ordered-keys
   variant in Phase 2.

Why Option C over A (side-map only) or B (always-tagged union):

- **(A)** side-map alone forces every lookup to do two map probes. Hot
  path slows down for the 99% case.
- **(B)** tagged union for every property doubles the per-slot size
  (JsValue is already NaN-boxed 8 bytes; PropertyDescriptor is ~24) and
  wastes memory on huge DOM trees.
- **(C)** pays zero extra cost until a property is actually special.
  `Object.defineProperty(o, "x", {value: 1})` with defaults stays fast;
  `Object.freeze(o)` promotes *all* slots at once into `descriptors`.

### 2.3 Promotion / demotion rules

- **Promote** (properties → descriptors) when:
  - `defineOwnProperty` installs non-default attrs or an accessor.
  - `preventExtensions`/`seal`/`freeze` is called — bulk promote every
    slot and flip `extensible`, configurable, and (for freeze) writable.
- **Demote** is not permitted. Once in the slow map, stay there;
  configurable→non-configurable is a one-way door per spec anyway.

---

## 3. Abstract Operations to (re-)implement

Map each to an Object method on `JsObject`:

| Spec op (§)                                    | Zig name                         | Notes |
|------------------------------------------------|----------------------------------|-------|
| OrdinaryGetOwnProperty (10.1.5.1)              | `getOwnDescriptor(name) ?PropertyDescriptor` | Consult `descriptors` first, then `properties` synthesizing defaults |
| OrdinaryDefineOwnProperty (10.1.6.1)           | `defineOwnProperty(name, desc) !bool` | Calls ValidateAndApply… |
| ValidateAndApplyPropertyDescriptor (10.1.6.3)  | `validateAndApply(current, incoming)` | Implements the full table: non-configurable invariants, data↔accessor conversion gate, writable-false means value can only change to SameValue |
| IsCompatiblePropertyDescriptor (6.2.5.6)       | `isCompatible(current, incoming)` | Proxy invariant check (audit #10) |
| OrdinaryGet (10.1.8.1)                         | `ordinaryGet(receiver, name)`    | Walks proto chain; for accessor, calls `get` with `receiver` as `this` |
| OrdinarySet (10.1.9.1) + OrdinarySetWithOwnDescriptor | `ordinarySet(receiver, name, v)` | Honors writable; calls setter; creates own data prop on receiver if inherited is data |
| OrdinaryDelete (10.1.10.1)                     | `ordinaryDelete(name) bool`      | Fails on non-configurable |
| OrdinaryPreventExtensions (10.1.4.1)           | `preventExtensions()`            | `extensible = false`; do NOT touch existing descriptors |
| OrdinaryIsExtensible (10.1.3.1)                | `isExtensible() bool`            | Returns `extensible` |
| OrdinaryOwnPropertyKeys (10.1.11.1)            | `ownKeys() []StringId`           | Integer-index-like names first, then string keys in insertion order, then symbols (once ordered key list lands) |

Receivers that matter: `ordinaryGet` must take a `receiver: JsValue`
separate from `self: *JsObject` so that accessor `this` binding is
correct when a getter is inherited from the prototype.

---

## 4. Derived Built-ins Fixed For Free

Once §3 is in place, these native wrappers become thin:

- **Object.defineProperty / defineProperties** — parse descriptor object
  into `PropertyDescriptor`, call `defineOwnProperty`. Throws TypeError
  on invariant failure instead of silently dropping attrs.
- **Object.getOwnPropertyDescriptor / getOwnPropertyDescriptors** —
  `getOwnDescriptor` then serialize to a plain object.
- **Object.preventExtensions / isExtensible** — direct.
- **Object.seal** — bulk-promote all own props to `configurable=false`
  + `preventExtensions`.
- **Object.freeze** — like seal, plus data props get `writable=false`.
- **Object.isSealed / isFrozen** — iterate own keys, check invariants.
- **Object.keys** — `ownKeys` filtered by `enumerable && !symbol`.
- **Object.getOwnPropertyNames** — `ownKeys` filtered by `!symbol`,
  *including* non-enumerable ones (diverges from `keys`).
- **Object.getOwnPropertySymbols** — symbols only.
- **propertyIsEnumerable** — `getOwnDescriptor(name)?.attrs.enumerable
  orelse false`.
- **isPrototypeOf** — walk `this.prototype` chain comparing identity.
  (Does not need descriptor work, but co-lands with the rest.)
- **for-in iteration** — emits only enumerable string keys from
  `ownKeys`, then recurses to prototype, skipping shadowed keys.
- **Object.create(proto, propsObj)** — loop `propsObj`'s enumerable
  own keys, convert each to descriptor, call `defineOwnProperty`.

---

## 5. Performance Notes

**Hot path cost budget: one hash probe per `o.x`.**

- `ordinaryGet` fast path: if `descriptors == null`, fall straight
  through to `properties.get(name)` and walk the proto chain the same
  way as today. This is the existing path and must not regress.
- Slow path cost only hit after a `defineProperty`/`freeze` call. Expect
  essentially zero frozen objects in DOM traffic.
- Accessor invocation on a getter already costs an interpreter
  re-entry; the descriptor check adds one tag comparison.
- **Shapes / hidden classes**: NOT recommended for kotori right now.
  At 13.6K LOC and 622 tests the engine is firmly interpreter-tier, and
  kotori's target workload (suzume browser UI) is dominated by DOM-side
  work. Hidden classes pay off inside a JIT; in a tree-walking or
  tight-bytecode interpreter the hash-map cost is already dwarfed by
  dispatch overhead. Revisit only if a profiler shows property lookup
  is a measurable share of total time.
- Memory: fast-path objects are unchanged. Promoted objects pay
  ~24 bytes per slot plus one additional map header — acceptable given
  promotion is rare.

---

## 6. Phased Rollout

### Phase 1 — Extensibility + attribute storage foundation (2 days)
- Add `extensible: bool` to `JsObject`.
- Add `PropertyAttrs` / `PropertyDescriptor` types and empty
  `descriptors` field. No behavior change yet — getters/setters maps
  remain as-is.
- Wire `Object.preventExtensions`, `Object.isExtensible`.
- Wire `isPrototypeOf` (no descriptor work needed).
- **Exit criteria:** new `isExtensible`/`preventExtensions`/
  `isPrototypeOf` tests green, all existing tests still green.

### Phase 2 — Real defineProperty + getOwnPropertyDescriptor (3 days)
- Implement `defineOwnProperty` + `validateAndApply`.
- Port `Object.defineProperty`, `Object.defineProperties`,
  `Object.getOwnPropertyDescriptor`, `Object.getOwnPropertyDescriptors`,
  `Object.create`'s second arg.
- Implement `propertyIsEnumerable`.
- Add ordered-keys list if `for-in` stability breaks.
- **Exit criteria:** test262 ordinary/defineProperty suite passes core
  table; manual tests for data↔accessor conversion, non-configurable
  invariants.

### Phase 3 — freeze / seal + enumerable filtering (2 days)
- Implement `Object.freeze`, `Object.seal`, `Object.isFrozen`,
  `Object.isSealed` as bulk attribute mutations.
- Fix `Object.keys` to filter by enumerable; keep
  `getOwnPropertyNames` as all-own.
- Fix `for-in` enumeration to skip non-enumerable.
- **Exit criteria:** `Object.freeze(o); o.x = 1; assert(o.x === orig)`
  in strict mode throws, non-strict silently fails.

### Phase 4 — Accessor properties (2 days)
- Merge existing `getters` / `setters` maps into the descriptor store;
  delete the legacy maps.
- Make `ordinaryGet`/`ordinarySet` invoke accessor functions with
  correct receiver binding.
- Wire `get`/`set` method syntax and object-literal accessor shorthand
  through to `defineOwnProperty` with accessor descriptors (if not
  already).
- **Exit criteria:** `Object.defineProperty(o, 'x', {get(){ return 42 }})`
  returns 42 on access; `this` inside getter is `o`.

Total: ~9 engineer-days with test writing. Audit estimated 1 week for
the cluster; this matches.

---

## 7. Open Questions / Risks

- **Insertion-order stability with promotion.** The two-map scheme
  without an explicit order list has edge cases (promotion reorders).
  Need to decide in Phase 2 whether to add the ordered key list or
  accept the rare ordering quirk.
- **Symbol-keyed descriptors.** Parallel slow-map proposed, but no
  built-in currently exercises non-default attrs on symbol keys.
  Ship symmetric but test lightly.
- **Proxy traps.** Audit #10 requires IsCompatiblePropertyDescriptor
  for invariant checks. This design provides the primitive; the Proxy
  caller side is out of scope here.
- **ArrayData special casing.** Arrays store elements in the
  `ObjData.array` list, not `properties`. `length` and numeric index
  attribute semantics (§10.4.2) need a separate audit; this spec
  covers named string/symbol keys only.
- **Strict-mode write failures.** Currently silent; must throw
  TypeError. Coordinate with the existing strict-mode flag on
  bytecode frames.
- **Backward compat of `getters`/`setters` maps.** Callers outside
  `object.zig` may poke these directly; Phase 4 must grep and migrate.

---

## 8. Effort Estimate

| Phase | Work days | Risk | User-visible win |
|-------|-----------|------|------------------|
| 1     | 2         | low  | `preventExtensions`, `isExtensible`, `isPrototypeOf` |
| 2     | 3         | med  | real `defineProperty`, real `getOwnPropertyDescriptor`, `propertyIsEnumerable` |
| 3     | 2         | low  | `freeze`/`seal` + `Object.keys` vs. `getOwnPropertyNames` distinction |
| 4     | 2         | med  | real accessor getters/setters via `defineProperty` |
| **Total** | **~9 days** | | Closes 6 of the 7 HIGH-priority audit findings tagged "descriptor-related" |

Lands the largest single chunk of ES2023 conformance debt in the engine
without disturbing the hot path.
