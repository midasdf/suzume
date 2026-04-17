# Spec 1: kotori WPT Foundations — eval() + Node Constants

**Date**: 2026-04-17
**Scope**: Fix the two biggest WPT blockers: non-functional `eval()` and missing Node interface constants
**Target**: ~3000+ subtests unblocked in dom/nodes alone

## Problem Statement

kotori currently passes 949/5602 subtests (16.9%) in WPT dom/nodes. Investigation reveals two foundational issues blocking thousands of subtests:

1. **`eval()` is not implemented** — Always returns `undefined`. WPT's `common.js` uses `eval(referenceName)` to resolve 38 test node variables (e.g., `eval("paras[0]")`). Without eval, Node-contains (1482 subtests), Node-compareDocumentPosition (1444 subtests), and all other tests using common.js testNodes are broken.

2. **Node interface constants only on prototype** — `Node.ELEMENT_NODE`, `Node.DOCUMENT_POSITION_CONTAINS` etc. are set on `Node.prototype` but NOT on the `Node` constructor. Per DOM §4.4 and WebIDL §3.6.1, these constants must be accessible as `Node.ELEMENT_NODE` (on the interface object).

### Evidence

```
eval("1+1")         → undefined   // eval does nothing at all
eval("paras[0]")    → undefined   // WPT tests use this pattern everywhere
Node.ELEMENT_NODE   → undefined   // should be 1
Node.DOCUMENT_POSITION_CONTAINS → undefined  // should be 8
```

## Fix 1: eval() Implementation

### Spec Reference

ECMA-262 §19.2.1 — `eval(x)`:
1. If `x` is not a String, return `x`
2. Parse `x` as Script. If parse fails, throw SyntaxError
3. Evaluate the parsed script in the current execution context's variable environment
4. Return the completion value

### Direct eval vs Indirect eval

- **Direct eval**: `eval("code")` — executes in caller's scope, can read/write local variables
- **Indirect eval**: `var e = eval; e("code")` or `(0,eval)("code")` — executes in global scope only

WPT primarily uses direct eval. For Phase 1, direct eval with global scope access is sufficient. Full local scope capture is a later optimization.

### Design

**Approach**: Compile-and-run within the current VM instance.

1. Register `eval` as a native function in globals during VM init
2. When called:
   a. Check argument — if not string, return it as-is (spec step 1)
   b. Compile the string as a Script using the existing `compiler.compile()` pipeline (lexer → parser → compiler)
   c. Execute the resulting bytecode using `vm.run()` with the **current global scope** (vm.globals)
   d. Return the completion value (the value left on the stack after execution)

**Key constraint**: kotori's `vm.run()` already supports `run_scope_floor` for nested execution contexts. eval bytecode runs in the same VM instance with access to the same globals.

**What eval can access (Phase 1)**:
- Global variables (`var x = 42; eval("x")` → 42) ✓
- Global functions ✓
- `document`, `window`, etc. ✓
- Object property access (`eval("obj.prop")`) ✓

**What eval cannot access (Phase 1, deferred)**:
- Caller's local variables (requires scope chain capture) — not needed for WPT common.js pattern since all test variables are global `var` declarations

### Implementation Location

- `src/js/kotori/vm.zig` — Register `nativeEval` in globals during `init()`
- Reuse existing `compiler.compile()` + `vm.run()` pipeline

### Error Handling

- Non-string argument → return argument unchanged
- Parse error → throw SyntaxError (use `pending_throw`)
- Runtime error → propagate normally (try/catch in caller works)

## Fix 2: Node Interface Constants on Constructor

### Spec Reference

WebIDL §3.6.1 — Constants: "For each constant defined on the interface, there must be a corresponding property on the interface object (constructor) and on the interface prototype object."

DOM §4.4 — Interface Node defines:
```webidl
interface Node : EventTarget {
  const unsigned short ELEMENT_NODE = 1;
  const unsigned short ATTRIBUTE_NODE = 2;
  const unsigned short TEXT_NODE = 3;
  const unsigned short CDATA_SECTION_NODE = 4;
  // ...
  const unsigned short DOCUMENT_POSITION_DISCONNECTED = 0x01;
  const unsigned short DOCUMENT_POSITION_PRECEDING = 0x02;
  // ...
};
```

These must be on BOTH `Node` (the constructor) AND `Node.prototype`.

### Current State

Constants are only set on `np` (Node.prototype) at lines 471-486 of `kotori_dom.zig`. The constructor `node_ctor` (line 603) does NOT have them.

### Design

After creating `node_ctor` and setting its `.prototype` to `np`, copy ALL constants to `node_ctor`:

```
Node type constants:
  ELEMENT_NODE = 1
  ATTRIBUTE_NODE = 2
  TEXT_NODE = 3
  CDATA_SECTION_NODE = 4
  ENTITY_REFERENCE_NODE = 5  (legacy)
  ENTITY_NODE = 6  (legacy)
  PROCESSING_INSTRUCTION_NODE = 7
  COMMENT_NODE = 8
  DOCUMENT_NODE = 9
  DOCUMENT_TYPE_NODE = 10
  DOCUMENT_FRAGMENT_NODE = 11
  NOTATION_NODE = 12  (legacy)

Document position constants:
  DOCUMENT_POSITION_DISCONNECTED = 0x01
  DOCUMENT_POSITION_PRECEDING = 0x02
  DOCUMENT_POSITION_FOLLOWING = 0x04
  DOCUMENT_POSITION_CONTAINS = 0x08
  DOCUMENT_POSITION_CONTAINED_BY = 0x10
  DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = 0x20
```

### Implementation Location

- `src/js/kotori_dom.zig` — After line 608, add the same `setProperty` calls on `node_ctor`

### Missing Legacy Constants

Current code is missing `ATTRIBUTE_NODE = 2`, `ENTITY_REFERENCE_NODE = 5`, `ENTITY_NODE = 6`, `NOTATION_NODE = 12`. Add these for spec compliance.

## Fix 3: compareDocumentPosition Edge Cases

### Current State

The implementation at line 3383 of `kotori_dom.zig` looks correct for the main algorithm. However, with eval and Node constants fixed, we need to verify edge cases:

### Spec Edge Cases to Verify

1. **null/undefined argument**: Per DOM §4.4, `compareDocumentPosition(null)` should throw TypeError, not return 0
2. **Cross-document nodes**: Nodes in different documents should return DISCONNECTED | IMPLEMENTATION_SPECIFIC | (PRECEDING or FOLLOWING). Current code does this.
3. **DocumentType nodes**: These are special — a DocumentType's `parentNode` is the Document, and it participates in tree order normally
4. **ProcessingInstruction nodes**: JS-only PI nodes (not in lexbor DOM tree) need special handling for compareDocumentPosition

### Design

After eval + Node constants are fixed, run the WPT tests and analyze remaining failures to determine which edge cases need fixing. This is a verification step, not a speculative fix.

## Fix 4: contains() Spec Compliance

### Current State

Implementation at line 3369 looks correct: walks parentNode chain from target to ancestor.

### Spec Edge Case

- `contains(null)` should return `false` (currently returns `false` ✓)
- `contains(this)` should return `true` — "inclusive descendant" (currently returns `true` ✓)

Main issue was eval preventing tests from running. After eval fix, verify remaining edge cases from WPT results.

## Verification Plan

1. Build and run unit tests (`zig build test`)
2. Run targeted WPT: `TIMEOUT=30 tests/wpt/run_wpt.sh dom/nodes`
3. Compare before/after subtest counts
4. Run `Node-contains.html` and `Node-compareDocumentPosition.html` individually
5. Analyze remaining failures for Spec 2 planning

## Expected Impact

| Fix | Subtests Unblocked (estimated) |
|-----|-------------------------------|
| eval() | ~3000+ (all tests using common.js eval pattern) |
| Node constants on constructor | ~500+ (all tests checking Node.ELEMENT_NODE etc.) |
| compareDocumentPosition edge cases | ~100-200 (after eval+constants fix) |
| **Total estimated** | **~3000-4000 new passing subtests** |

## Implementation Order

1. `eval()` native function — highest impact, unblocks everything
2. Node constants on constructor — quick win, 10 lines
3. Build + test + WPT run
4. Analyze compareDocumentPosition/contains failures from WPT results
5. Fix edge cases as needed

## Files Modified

| File | Changes |
|------|---------|
| `src/js/kotori/vm.zig` | Register `nativeEval` global, implement compile+run for eval strings |
| `src/js/kotori_dom.zig` | Copy Node constants to `node_ctor`, add missing legacy constants |
| `src/js/kotori_dom.zig` | compareDocumentPosition: throw TypeError on null arg (if WPT requires) |

## Out of Scope (deferred to Spec 2+)

- eval local scope capture (direct eval seeing caller's `var`/`let`)
- `new Function("code")` body compilation
- MutationObserver callback dispatch
- native function `.length` property
- Node-insertBefore pre-insert validation
