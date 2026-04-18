# kotori + suzume WPT 100% Roadmap — Spec-Driven Foundations Build-Up

**Date**: 2026-04-17
**Scope**: Master roadmap from current state (~71% dom/nodes) to WPT 100% across dom/, events/, css/, html/
**Approach**: Bottom-up spec-driven, layered. Each layer depends only on layers below it.
**Planning basis**: kotori sessions #6/#7 (2026-04-17) + dom/events/CSS Phase 1-4 (2026-04-15) + exploration agents 2026-04-17

## Strategy: Layered Foundations, Not Horizontal Coverage

The WPT spec defines a **dependency pyramid**, not a flat grid. Event dispatch depends on DOM mutation. CSS computed values depend on element attributes. testharness.js itself uses `eval`, `assert_*`, `Promise`, `try/catch`. Fixing a layer-0 bug (e.g., `eval()` stub) unlocks thousands of downstream tests simultaneously — this is why Session #6's eval() fix took dom/nodes from 16.9% → 71.4% in a single commit.

The roadmap below walks the pyramid from bottom to top. Each layer is its own spec-driven sub-project with its own design doc, audit, and WPT delta target.

```
Layer 4: html/dom reflection (reads from layers 0-3)
Layer 3: css/* engine (depends on DOM tree)
Layer 2: dom/events dispatch (depends on DOM tree + JS)
Layer 1: dom/nodes algorithms (depends on JS engine)
Layer 0: kotori JS engine (ECMA-262 correctness)
```

## Measurement Baseline

**Fresh measurement 2026-04-19** against HEAD `beb7a4b` binary (kotori engine, TIMEOUT=90, jobs=4):

| Area | Baseline (2026-04-16) | **Fresh (2026-04-19)** | Target |
|------|-----------------------|------------------------|--------|
| dom/nodes | 2.8% (118/4183) | **68.2% (5367/7869)** | **100%** |
| dom/events | 6.0% (20/334) | **27.8% (70/252)** | **100%** |
| html/dom | 13.4% (943/7013) | **22.4% (235/1048)** | **100%** |
| css/cssom | 16.4% (93/566) | **19.9% (135/677)** | **100%** |
| css/css-values | 12.2% (570/4677) | *unmeasured (2026-04-19)* | **100%** |
| css/selectors | 6.7% (176/2629) | *unmeasured (2026-04-19)* | **100%** |
| css/css-box | 19.1% (127/665) | *unmeasured (2026-04-19)* | **100%** |
| css/css-display | 13.5% (48/355) | *unmeasured (2026-04-19)* | **100%** |
| css/css-color | 1.3% (70/5348) | *unmeasured (2026-04-19)* | **100%** |

Gap to 100% in measured areas: ~2502 dom/nodes + ~182 dom/events + ~813 html/dom + ~542 css/cssom = **~4039 subtests in these 4 areas alone**. Remaining css/* + other areas bring total ~15,000 subtests gap estimate unchanged.

Note: dom/nodes total subtests grew 4183→7869 between 2026-04-16 and 2026-04-19 — previously-erroring tests now enumerate their subtests after kotori timer/eval/common.js fixes. Pass rate delta (2.8%→68.2%) understates gain; absolute subtests +5249.

---

## Layer 0: kotori JS Engine (ECMA-262 Correctness)

**Goal**: kotori passes 100% of WPT ecmascript-level assertions without requiring testharness polyfills beyond those that WPT itself ships.

### 0A — Builtin Polish (Target: ~400 subtests unblocked)

Small, low-risk fixes that remove specific assert-level failures across all areas.

| Gap | Spec | Complexity | File(s) |
|-----|------|------------|---------|
| Native function `.length` property | ECMA-262 §20.2.4.1 | S (1d) | `src/js/kotori/vm.zig` (createNativeFn) |
| Native function `.name` property | ECMA-262 §20.2.4.2 | S (0.5d) | `src/js/kotori/vm.zig` |
| Error.prototype chain completeness (TypeError/RangeError/SyntaxError/URIError inherit) | ECMA-262 §20.5 | S (1d) | `src/js/kotori/vm.zig` (init globals) |
| Array callbacks honor `thisArg` everywhere | ECMA-262 §23.1.3.x | S (1d) | `src/js/kotori/vm.zig` (array methods) |
| Promise thenable detection (`obj.then` duck-typing) | ECMA-262 §27.2.3.1.2 | S (1d) | `src/js/kotori/vm.zig` (Promise.resolve) |

### 0B — TypedArray Type Differentiation (Target: ~300 subtests)

All typed arrays currently map to the `typed_array` ObjectKind with Uint8-like storage. Per ECMA-262 §23.2, Int32Array[0]=−1 must read as 0xFFFFFFFF, Float64Array[0] must use IEEE754, etc.

**Design**: Add a variant tag on `TypedArrayData` with element size + interpretation (int8/uint8/int16/uint16/int32/uint32/float32/float64/biguint64/bigint64). Rewrite indexed get/set in vm.zig to switch on the tag.

**File**: `src/js/kotori/object.zig` (add `TypedArrayKind` enum), `src/js/kotori/vm.zig` (indexed access).

### 0C — RegExp Upgrade (Target: ~500 subtests)

**Missing features**: lookahead `(?=X)`, negative lookahead `(?!X)`, lookbehind `(?<=X)`, negative lookbehind `(?<!X)`, backreferences `\1..\9` and `\k<name>`, named capture groups `(?<name>X)`.

**Design**: Replace current regex (minimal NFA) with a proper backtracking engine supporting ECMA-262 §22.2. Either port a known-good implementation or use Zig's upcoming `std.regex` (not stable yet — port is likely).

**File**: `src/js/kotori/regex.zig` (new), `src/js/kotori/vm.zig` (RegExp.prototype.exec/test bindings).

### 0D — Execution Timeout / Instruction Budget (Target: testharness stability)

WPT tests set internal timeouts. Without an instruction counter in the VM dispatch loop, infinite loops freeze the runner instead of returning `Test timed out`.

**Design**: Add `instruction_budget: u64` to `Vm`, decrement per opcode, throw when it hits zero. Expose `vm.setBudget()` from native code. The suzume main loop sets budget per script execution.

**File**: `src/js/kotori/vm.zig` (dispatch loop).

### 0E — Bytecode i16 → i32 Jump Offsets (Target: ~10 tests on large JS)

Known bug: `patchJumpTo` uses `i16` offsets, panics on bytecode >32KB. Blocks Google.com-scale JS.

**Design**: Introduce dual opcodes — `jump`/`jump_long`, `jump_if_false`/`jump_if_false_long`. Compiler emits long variant when offset doesn't fit i16. Backward-compatible with existing bytecode.

**File**: `src/js/kotori/bytecode.zig`, `src/js/kotori/compiler.zig`, `src/js/kotori/vm.zig`.

### 0F — eval() Local Scope Capture (Target: ~50 subtests, Quality-of-life)

Current eval() runs in global scope. Full spec (ECMA-262 §19.2.1.1) requires direct eval to read/write caller's lexical environment.

**Design**: At compile time, mark direct `eval(...)` call sites. At runtime, compile the eval'd string with the caller's scope chain spliced in. Deferred from Session #6 because WPT's common.js uses only `var` (global) references.

**File**: `src/js/kotori/compiler.zig`, `src/js/kotori/vm.zig`.

---

## Layer 1: DOM Core Algorithms (dom/nodes 100%)

**Goal**: dom/nodes 100% with spec-exact mutation/query/namespace algorithms.

### 1A — Namespace/QName Spec Completeness (Target: ~101 subtests)

Known gap: `createDocument`/`createElementNS`/`setAttributeNS` accept invalid QNames/namespaces and fail silently instead of throwing.

**Spec**: DOM §1.5 "validate and extract", Infra §5 "namespaces". Reserved prefix rules:
- Prefix `xml` requires namespace `http://www.w3.org/XML/1998/namespace`
- Prefix `xmlns` requires namespace `http://www.w3.org/2000/xmlns/` AND qualifiedName must be `xmlns` or `xmlns:*`
- `http://www.w3.org/2000/xmlns/` namespace requires prefix `xmlns` or qualifiedName `xmlns`

**Design**: Central `validateAndExtract(namespace, qualifiedName)` function returning `{namespace, prefix, localName}` or DOM exception. Called from every NS-taking DOM method.

**File**: `src/js/dom_document.zig` (already has `isValidQName`, extend with reserved prefix checks), `src/js/kotori_dom.zig` (dispatch).

### 1B — MutationObserver Completion (Target: ~44 subtests)

Known gaps:
- `subtree` option not honored (records all mutations regardless)
- `textContent` setter doesn't record childList mutations
- `normalize()` doesn't record mutations
- `characterData` setter doesn't record
- `attributeFilter` partial
- `attributeOldValue` partial in removeAttribute

**Spec**: DOM §4.3 MutationObserver, §4.3.3 "queue a mutation record".

**Design**: Create a single `recordMutation()` helper taking `{type, target, options}`, call it from every mutation site (insertBefore/removeChild/setAttribute/removeAttribute/textContent setter/CharacterData.data setter/normalize). Walk from target to each observer, apply `subtree` + `attributeFilter` filters before enqueuing.

**File**: `src/js/events.zig` (MutationObserver), `src/js/dom_node.zig` (normalize), `src/js/kotori_dom.zig` (textContent/data setters).

### 1C — createEvent testharness Compat (Target: ~60 subtests)

Known gap: createEvent returns a valid Event, but testharness.js alias display or format_value doesn't recognize it.

**Investigation first**: run a single createEvent WPT test with verbose output to identify the exact assertion. Likely fix: add `[object Xxx]` toString or instanceof chain.

**File**: `src/js/kotori_dom.zig` (Event constructors prototype chain).

### 1D — NamedNodeMap Methods (Target: ~18-59 subtests)

Missing: `.item(index)`, `.getNamedItem(name)`, `.setNamedItem(attr)`, `.removeNamedItem(name)`, `.removeNamedItemNS(ns, name)`, `.getNamedItemNS(ns, name)`, `.setNamedItemNS(attr)`, iterator protocol.

**Spec**: DOM §4.9.2 NamedNodeMap.

**Design**: Full native implementation attaching a NamedNodeMap prototype. Index getter already works; add named properties for attribute names.

**File**: `src/js/kotori_dom.zig`, `src/js/dom_api.zig` (Element.attributes getter).

### 1E — Case Sensitivity (Target: ~44 subtests)

`case.html` expects HTML document attribute/tag names to be case-insensitive in lookup (ASCII-lowercased on set), case-preserving in XML documents.

**Spec**: DOM §4.9 "An Attr's qualified name".

**Design**: At setAttribute/getAttribute, consult document's type flag. HTML documents lowercase non-namespaced names; XML documents keep case.

**File**: `src/js/dom_element.zig` (already has some handling, extend).

### 1F — Range + TreeWalker/NodeIterator Polish (Target: ~50 subtests)

- Range updates on DOM mutations (DOM §5.5 "Boundary point")
- TreeWalker filter-returns-FILTER_REJECT handling
- NodeIterator pre-order traversal detach behavior

**File**: `src/js/dom_document.zig`.

---

## Layer 2: dom/events 100%

**Goal**: Every event dispatch path matches DOM §2.9 exactly.

### 2A — AbortSignal Listener Integration (Target: ~15 subtests)

`addEventListener(type, listener, {signal})` must auto-remove when signal aborts. Currently accepted but not enforced.

**Spec**: DOM §2.7.1 step 1.3.

**Design**: When listener is registered with signal, also register an "abort" listener on the signal that removes the listener. Store listener handle for efficient removal.

**File**: `src/js/events.zig`.

### 2B — createEvent / Event Interface Compat Polish (Target: ~60 subtests)

See 1C above; overlaps.

### 2C — Composed Path / Shadow DOM Retargeting Verification

Phase 2 was implemented 2026-04-15. Verify WPT compliance and close gaps if any surface.

**File**: `src/js/events.zig`, `src/js/shadow_root.zig`.

---

## Layer 3: css/* 100%

**Goal**: CSS parsing, computed values, selectors, CSSOM all match W3C specs.

### 3A — CSSOM Completeness (css/cssom target: ~300 subtests)

- `!important` flag preservation in `.cssText` getter
- CSS shorthand expansion via `element.style.margin = "10px"` → margin-top/right/bottom/left
- Invalid rule recovery (don't fail whole stylesheet on one bad rule)
- `CSSStyleDeclaration.setProperty(name, value, priority)` returns correct values per spec

**Spec**: CSSOM §6, CSS Syntax §5.

**File**: `src/css/cssom/style_decl.zig`, `src/css/cssom/shorthand_serialize.zig`, `src/css/parser.zig`.

### 3B — Computed Values (css/css-values target: ~2000 subtests)

- Font-relative units (em/rem/ch/ex) resolve to px in getComputedStyle
- Grid computed values (fr units preserved per spec)
- Pseudo-element computed styles
- calc() result normalization

**Spec**: CSS Values 4 §4, CSS Cascade 4 §4.5, CSSOM §6.5.

**File**: `src/js/dom_style.zig`, `src/css/computed.zig` (if exists).

### 3C — Selector Engine Correctness (css/selectors target: ~1500 subtests)

- `Element.matches()` throws SyntaxError on invalid selectors
- Namespace selectors (`|*`, `ns|*`, `*|*`)
- `:is()/:where()/:has()/:not()` specificity edge cases
- Complex combinator paths

**Spec**: Selectors Level 4.

**File**: `src/js/dom_selector.zig`.

### 3D — Color Parsing (css/css-color target: ~5000 subtests)

Currently 1.3%. Likely needs:
- `color()` function with color spaces
- `hsl()/hwb()/lab()/lch()/oklab()/oklch()` new syntax (comma-less)
- `color-mix()` per spec
- System color keywords

**Spec**: CSS Color 4.

**File**: `src/css/color.zig` (if exists), `src/js/dom_style.zig`.

---

## Layer 4: html/dom 100%

**Goal**: HTML reflected attributes, form controls, HTMLCollection specifics.

### 4A — Reflected Attributes (Target: ~3000 subtests)

Every HTML element interface defines IDL attributes that reflect content attributes (`HTMLElement.id`, `HTMLInputElement.type`, etc.). WPT html/dom tests enumerate every reflection.

**Spec**: HTML §2.6.

**Design**: Table-driven — a `reflected_attrs.zig` table listing `{interface, attr, content_name, type}` tuples. Each entry generates getter/setter.

**File**: `src/js/html_reflection.zig` (new), `src/js/kotori_dom.zig`.

### 4B — Form Controls (Target: ~500 subtests)

Input/select/textarea/form interfaces, validation, focus management.

**File**: `src/js/html_form.zig` (new).

---

## Execution Plan: Parallel Dispatch Strategy

### Wave 1 (parallel, low-risk, independent files)
- **Layer 0A**: builtin polish — single file, single agent
- **Layer 1A**: namespace validation — dom_document.zig focus
- **Layer 1B**: MutationObserver completion — events.zig focus
- **Layer 1D**: NamedNodeMap methods — kotori_dom.zig focus
- **Layer 2A**: AbortSignal integration — events.zig overlap with 1B (serialize)

Runs concurrently except 1B↔2A (same file).

### Wave 2 (parallel)
- **Layer 0B**: TypedArray differentiation — kotori core
- **Layer 0C**: RegExp upgrade — kotori core (isolated new file)
- **Layer 1E**: Case sensitivity — dom_element.zig
- **Layer 3A**: CSSOM !important + shorthand — cssom/
- **Layer 3C**: Selector validation — dom_selector.zig

### Wave 3 (harder, mostly sequential)
- **Layer 0D**: execution timeout — VM dispatch loop (careful)
- **Layer 0E**: i16→i32 jumps — bytecode change (careful)
- **Layer 3B**: CSS computed values — cross-cutting
- **Layer 3D**: Color parsing — new/existing color.zig
- **Layer 4A**: Reflected attributes — new html_reflection.zig

### Wave 4 (polish + final)
- **Layer 0F**: eval local scope — only after 0A-E stable
- **Layer 1C/2B**: createEvent compat — after 1D/2A surface issues
- **Layer 4B**: Form controls
- **Layer 1F**: Range/TreeWalker polish

### Gating
Each wave is verified by re-running the relevant WPT area with the latest binary. Wave N+1 does not begin until Wave N shows green WPT delta. Regressions get root-cause fixes, not reverted.

---

## Per-Layer Acceptance Criteria

| Layer | Subtest Target | Area Target |
|-------|----------------|-------------|
| 0A | +400 | Across all areas |
| 0B | +300 | dom/nodes, encoding |
| 0C | +500 | dom/nodes, misc |
| 0D | — | testharness stability |
| 0E | +10 | html/* (large JS sites) |
| 0F | +50 | dom/nodes |
| 1A | +101 | dom/nodes createDocument |
| 1B | +44 | dom/nodes MutationObserver |
| 1C | +60 | dom/nodes createEvent |
| 1D | +59 | dom/nodes attributes |
| 1E | +44 | dom/nodes case |
| 1F | +50 | dom/nodes Range/Tree |
| 2A | +15 | dom/events AbortSignal |
| 2B | overlap 1C | — |
| 3A | +300 | css/cssom |
| 3B | +2000 | css/css-values |
| 3C | +1500 | css/selectors |
| 3D | +5000 | css/css-color |
| 4A | +3000 | html/dom |
| 4B | +500 | html/dom |

Total estimated subtests unlocked: ~14,000+ across all areas. Current deficit from 100%: ~15,000+.

---

## Principles

1. **Spec-first**: every sub-spec quotes the authoritative W3C/WHATWG/ECMA-262 section and reasons from it. No test-hack patches.
2. **Independent files for parallelism**: waves are designed so no two agents touch the same file.
3. **Root-cause fixes**: if a test reveals a deeper gap than expected, the spec is updated before implementation proceeds.
4. **Verification before completion**: each sub-spec lists the exact WPT files and subtests used as its acceptance test. `zig build test` + WPT delta both green.
5. **Zero regressions**: a fix in layer N that drops subtests in layer <N is rejected; root cause is analyzed before resuming.
6. **Memory-aware**: suzume targets RPi Zero 2W (512MB RAM). Implementations must respect the binary-size / runtime-memory budget from `project_suzume.md`.

---

## Next Steps

1. **Finalize measurement** — fresh WPT run on current binary, paste actual post-session-#7 numbers into the Measurement Baseline table.
2. **Per-sub-spec write-ups** — each layer item (0A–4B) gets its own design doc at `docs/superpowers/specs/YYYY-MM-DD-<layer>-<topic>-design.md` before implementation. Use this master as the index.
3. **Wave 1 dispatch** — once specs 0A, 1A, 1B, 1D, 2A are written and reviewed, dispatch as parallel executors per the wave plan above.
4. **Incremental commits** — each sub-layer is one commit minimum, one PR optional. Rebuild + WPT re-run between sub-layers.
