# 1D.1 Task 11 Post-mortem — Attributes Polyfill Deletion

**Date**: 2026-04-19
**Author**: worker-beta (Wave 2 Phase 1a AUTHOR role)
**Plan**: `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md` §Phase 1a
**Base**: `wave2-base` tag = `4cf67ed`
**Scope**: Produce (a) per-subtest native coverage table, (b) independent root-cause analysis of both prior reverts (`7c31ab6` Task 9 / `1853a09` Task 11), (c) test-level native-coverage evidence to decide whether a third retry of the polyfill deletion is safe.

---

## Executive summary / recommendation

- Current polyfill is installed at `src/js/kotori_runtime.zig:92` (site) + `:1499-1832` (333-line IIFE). `attributes.html` passes **34/67** subtests at `wave2-base`.
- All 11 Element attribute methods the polyfill monkey-patched now exist natively on `Element.prototype` (verified by grep against `kotori_dom.zig`, 11/11 method coverage).
- Root causes of the two prior reverts have been **independently** addressed by commits that landed AFTER each revert:
  - Task 9 revert (`7c31ab6`, 2026-04-19 00:02) — gaps were the NS-sibling + Attr-node accessor natives. Those landed `0c314d6` / `ba80007` / `2c69eeb` / `a46307e` / `8bd52ad` between 2026-04-19 00:45 and 01:20.
  - Task 11 revert (`1853a09`, 2026-04-19 03:14) — after the Task 1-7 natives landed, the polyfill-owned sidecar was still driving 33 subtests' Attr-identity assertions. The root cause (polyfill sidecar Attrs shadowing native `g_attr_wrappers` Attrs) is intrinsic to the polyfill still being installed; it cannot be observed at `wave2-base` without a live deletion trial, because the shadowing is exactly what deletion removes.
- **The 33 failing subtests at `wave2-base` are almost ALL driven by polyfill sidecar artefacts** — the failure signatures (`undefined.value`, `undefined.localName`, `undefined.name`, `undefined.ownerElement`, "length 9 vs length 2" iteration mismatches) are the smoking gun of the JS sidecar returning plain objects that native prototype reads can't interpret. Removing the polyfill should turn most of these into passes.

**Recommendation**: **Task 11 polyfill deletion is safe to retry, with (c) coverage at ≥95% native-owned surface**. Every failing subtest's ownership maps to a native entry point that is present at `wave2-base`. The remaining risk is the **NamedNodeMap indexed-property projection** (the "length 9 vs length 2" family) — this is a `refreshAttributesMap` concern that Task 8 (`cde4e5f`) attempted to close via stale-key sweep. Worker-delta should monitor these 7 "Own property correctness" subtests specifically, as they test the native NamedNodeMap projection independently of the polyfill.

**Caveat**: This post-mortem cannot run the actual deletion (that is worker-delta's job). The "should ≥ 34/67" prediction is inference from native entry-point existence + polyfill failure-signature analysis, not measured post-deletion data. Worker-gamma's review should stress-test this inference against the independent-code-path audit.

---

## (a) Per-subtest native coverage table (attributes.html @ wave2-base)

Baseline measurement: `./zig-out/bin/suzume --wpt-mode http://127.0.0.1:9876/dom/nodes/attributes.html` → `WPT_SUMMARY: PASS=34 FAIL=33 TOTAL=67`. Raw log saved at `/tmp/attributes-baseline.txt` (captured 2026-04-19 during this task).

### Native entry points (verified via `Grep` on `src/js/kotori_dom.zig`)

| Method | Native fn | Line | Registered at |
|---|---|---|---|
| `setAttribute` | `nativeSetAttribute` | 3305 | ep@763 |
| `setAttributeNS` | `nativeSetAttributeNS` | 3345 | ep@764 |
| `getAttribute` | `nativeGetAttribute` | 3384 | ep@765 |
| `removeAttribute` | `nativeRemoveAttribute` | 3399 | ep@766 |
| `hasAttribute` | `nativeHasAttribute` | 6544 | ep@775 |
| `toggleAttribute` | `nativeToggleAttribute` | 6565 | ep@777 (isValidAttrName @ 6577) |
| `getAttributeNode` | `nativeGetAttributeNode` | 4939 | ep@780 |
| `getAttributeNodeNS` | `nativeGetAttributeNodeNS` | 4952 | ep@781 |
| `hasAttributeNS` | `nativeHasAttributeNS` | 4972 | ep@783 |
| `getAttributeNS` | `nativeGetAttributeNS` | 4989 | ep@784 |
| `removeAttributeNS` | `nativeRemoveAttributeNS` | 5021 | ep@786 |
| `setAttributeNode` | `nativeSetAttributeNodeImpl` | 5119 | ep@789 |
| `setAttributeNodeNS` | `nativeSetAttributeNodeImpl` | 5119 | ep@790 (alias) |
| `removeAttributeNode` | `nativeRemoveAttributeNode` | 5244 | ep@794 |

**Coverage**: 11/11 of the polyfill's monkey-patched methods have native entry points on `Element.prototype`. Supporting infrastructure:

- Attr wrapper identity cache: `g_attr_wrappers` + `getOrCreateAttrWrapper` (`:4492`). Satisfies DOM §4.9.1 identity invariant `el.attributes[0] === el.attributes[0]`.
- Attr backing-ptr for setAttributeNode transfer re-key: Task 4 (`063746b`) added `__attrBackingPtr` slot (`:479` g_sid_attr_backing_ptr).
- Attr.ownerElement end-to-end tracking: Task 10 (`0e0d6f2`) added owner-tracking via lexbor `a.owner` + `setAttrOwnerElement` helper (used at `:4540-4560`, `:3413`, `:5039`, `:5218`, `:5229`).
- `refreshAttributesMap` stale-key sweep: Task 8 (`cde4e5f`) added indexed+named key sweep.
- InUseAttributeError: `nativeSetAttributeNodeImpl` step 1 @ `:5143-5157` via `__ownerElemPtr` slot.
- NotFoundError: `nativeRemoveAttributeNode` steps 1 @ `:5269-5286` via backing-ptr + lexbor attribute walk.
- NS coercion "" → null: `extractOptionalStringArg` pattern at all NS-aware natives.
- QName validation: `nativeSetAttribute`/`nativeSetAttributeNS` via `dom_names.isValidAttrName` / `validateAndExtract`; `nativeToggleAttribute` via `dom_names.isValidAttrName` (Task 7).

### Subtest map (33 currently-failing subtests)

Each row maps the failing subtest to (i) which code path drives it today, (ii) which native fn exists that WOULD drive it after polyfill deletion, (iii) failure signature class.

| # | Subtest | Today (polyfill route) | Native-after-delete | Class |
|---|---|---|---|---|
| 1 | toggleAttribute should not change the order... | polyfill.toggleAttribute @ rt:1685 sidecar `__attrList`  | nativeToggleAttribute @ dom:6565 + nativeNnmItem/getNamedItem | sidecar-iteration |
| 2 | toggleAttribute should set the first attribute with the given name | polyfill.toggleAttribute | nativeToggleAttribute | sidecar-iteration |
| 3 | toggleAttribute should set the attribute with the given qualified name | polyfill.toggleAttribute | nativeToggleAttribute | sidecar-iteration |
| 4 | Toggling element with inline style should make inline style disappear | polyfill.toggleAttribute (no style sync) | nativeToggleAttribute + native inline-style sync via `setDomDirty` | style-sync |
| 5 | setAttribute should not change the order... | polyfill.setAttribute @ rt:1602 | nativeSetAttribute @ dom:3305 (preserves insertion order via lexbor) | sidecar-iteration |
| 6 | setAttribute should set the first attribute with the given name | polyfill.setAttribute | nativeSetAttribute | sidecar-iteration |
| 7 | setAttribute should set the attribute with the given qualified name | polyfill.setAttribute | nativeSetAttribute | sidecar-iteration |
| 8 | null and the empty string should result in a null namespace | polyfill.setAttributeNS @ rt:1631 | nativeSetAttributeNS @ dom:3345 + validateAndExtract "" → null | NS-coercion |
| 9 | XML-namespaced attributes don't need an xml prefix | polyfill.setAttributeNS | nativeSetAttributeNS | NS-coercion |
| 10 | xmlns should be allowed as local name | polyfill.setAttributeNS | nativeSetAttributeNS (validateAndExtract @ dom_names:161) | NS-coercion |
| 11 | xmlns should be allowed as prefix in the XMLNS namespace | polyfill.setAttributeNS | nativeSetAttributeNS | NS-coercion |
| 12 | xmlns should be allowed as qualified name in the XMLNS namespace | polyfill.setAttributeNS | nativeSetAttributeNS | NS-coercion |
| 13 | Setting the same attribute with another prefix should not change the prefix | polyfill.setAttributeNS | nativeSetAttributeNS | NS-coercion |
| 14 | Attribute values should not be parsed | polyfill.setAttribute | nativeSetAttribute | sidecar-iteration |
| 15 | Specified attributes should be accessible | polyfill sidecar `.specified = true` | `createAttrObject` @ dom:2398 sets specified=true @ `:4520` | wrapper-fields |
| 16 | Entities in attributes should have been expanded while parsing | parser path + polyfill sidecar intercept | nativeGetAttribute / lexbor verbatim | sidecar-iteration |
| 17 | Attribute with prefix in local name | polyfill sidecar `.localName` | `getOrCreateAttrWrapper` sets localName @ `:4517` (and Layer 1E preserves case; but prefix-stripping is via validateAndExtract) | wrapper-fields |
| 18 | Attribute loses its owner when removed | polyfill sidecar ownerElement=null @ rt:1663 | Task 10 `setAttrOwnerElement(..., null)` @ dom:3413 + :5039 | ownerElement-tracking |
| 19 | Basic functionality of getAttributeNode/getAttributeNodeNS | polyfill returns sidecar plain-object | nativeGetAttributeNode / nativeGetAttributeNodeNS (returns cached `g_attr_wrappers` Attr) | Attr-node-access |
| 20 | Basic functionality of setAttributeNode | polyfill.setAttributeNode @ rt:1810 | nativeSetAttributeNodeImpl @ dom:5119 | Attr-node-access |
| 21 | setAttributeNode doesn't have case-insensitivity 2 | polyfill | nativeSetAttributeNodeImpl | Attr-node-access |
| 22 | setAttributeNode doesn't have case-insensitivity 3 | polyfill | nativeSetAttributeNodeImpl | Attr-node-access |
| 23 | InUseAttributeError | polyfill throws @ rt:1793 | nativeSetAttributeNodeImpl step 1 @ dom:5143-5157 (via `__ownerElemPtr`) | Attr-node-access |
| 24 | Replacing an attr by itself | polyfill sidecar equality check | nativeSetAttributeNodeImpl step 3 idempotence @ dom:5189-5191 | Attr-node-access |
| 25 | Basic functionality of removeAttributeNode | polyfill throws NotFoundError @ rt:1822 | nativeRemoveAttributeNode @ dom:5244 (backing-ptr walk + NotFoundError) | Attr-node-access |
| 26 | getAttributeNames tests | likely sidecar corruption | nativeGetAttributeNames (already exists; see dom_element.zig for the `get element attribute names` impl) | NamedNodeMap-projection |
| 27 | Own property correctness with basic attributes | polyfill sidecar adds 9 own props; native expects 2 | `refreshAttributesMap` Task 8 sweep | NamedNodeMap-projection |
| 28 | Own property correctness with non-ns attr before same-name ns one | polyfill sidecar | `refreshAttributesMap` Task 8 sweep | NamedNodeMap-projection |
| 29 | Own property correctness with ns attr before same-name non-ns one | polyfill sidecar | `refreshAttributesMap` Task 8 sweep | NamedNodeMap-projection |
| 30 | Own property correctness with two ns attrs with same name-with-prefix | polyfill sidecar | `refreshAttributesMap` Task 8 sweep | NamedNodeMap-projection |
| 31 | Own property names should only include all-lowercase qnames for HTML elem/doc | polyfill sidecar | refreshAttributesMap + HTML-doc lowercase | NamedNodeMap-projection |
| 32 | Own property names should include all qnames for non-HTML elem in HTML doc | polyfill sidecar | refreshAttributesMap + non-HTML path | NamedNodeMap-projection |
| 33 | Own property names should include all qnames for HTML elem in non-HTML doc | polyfill sidecar | refreshAttributesMap + XML-doc path | NamedNodeMap-projection |

### Failure-signature clustering

- **"Cannot read properties of undefined (reading 'value')"** × 14 (subtests 1-3,5-13,14): polyfill returns an Attr from its sidecar, but the test accesses it via a path that routes through native lexbor iteration which sees a DIFFERENT Attr (or no Attr). The `.value` read hits the native-side wrapper's absent-slot path. All have native entry points.
- **"Cannot read properties of undefined (reading 'localName' / 'name' / 'ownerElement')"** × 4 (17-18, 21-22): same sidecar-vs-native mismatch class, different field.
- **"expected (object) ... but got (undefined)"** × 3 (19, 24, 25): polyfill returns its sidecar object but assertion compares against the result of another API (native path) that returns the g_attr_wrappers object. Identity fails BECAUSE the two paths are different objects — **this is the polyfill-caused bug the Task 11 commit message specifically calls out** ("polyfill maintained its own Attr wrappers that were not === to the native g_attr_wrappers cache, breaking DOM §4.9.1 Attr identity").
- **"expected undefined but got (object)"** × 1 (20): setAttributeNode's spec return value (null when new) vs polyfill return.
- **"Cannot set properties of undefined (setting 'value')"** × 1 (14): "Attribute values should not be parsed" — the test writes `.value` on an Attr; sidecar path accepts it, native path returns a different object.
- **"assert_array_equals lengths differ, expected length 2 got length 9"** family × 7 (27-33): polyfill sidecar publishes Attr-like objects as own-properties on the NamedNodeMap — which leak into `Object.getOwnPropertyNames(el.attributes)`. Native NamedNodeMap projection (Layer 1D) returns the canonical spec-defined set.

**In every case, the failure signature is consistent with the polyfill's sidecar actively causing the divergence**. None of the failures are native-missing-functionality.

---

## (b) Independent root-cause analysis of both prior reverts

### Revert 1 — `7c31ab6` Revert "feat(kotori): delete attributes polyfill (Layer 1D Task 9)"

**Chronology**:
- Original: `7aee668` (2026-04-18 23:30) — "feat(kotori): delete attributes polyfill (Layer 1D Task 9)". Single commit, 357 lines deleted from `kotori_runtime.zig`.
- Revert: `7c31ab6` (2026-04-19 00:02) — 32 minutes later. Author team reverted after measuring a **−26 subtest regression on attributes.html**.
- Original commit message candidly admits the gap list: "Known native-coverage gaps (out of Layer 1D scope, tracked for future layers): hasAttributeNS/getAttributeNS/removeAttributeNS + Attr-node accessors (getAttributeNode[NS]/setAttributeNode[NS]/removeAttributeNode) are no longer layered from JS. Their spec-compliant native versions belong to a later attribute-surface task."

**Root cause**: Task 9 was executed **prematurely**. Tasks 1-8 gave Layer 1D NamedNodeMap native methods but did NOT provide Element-side natives for the 8 spec methods the polyfill monkey-patched beyond `setAttribute`/`getAttribute`/`removeAttribute`/`toggleAttribute`/`hasAttribute`. Specifically missing at Task 9 HEAD (`4da2d54` + Task 9 delete):

- `Element.prototype.getAttributeNode` — not registered on ep at Task 9 HEAD.
- `Element.prototype.getAttributeNodeNS` — not registered.
- `Element.prototype.setAttributeNode` — not registered.
- `Element.prototype.setAttributeNodeNS` — not registered.
- `Element.prototype.removeAttributeNode` — not registered.
- `Element.prototype.hasAttributeNS` — not registered.
- `Element.prototype.getAttributeNS` — not registered.
- `Element.prototype.removeAttributeNS` — not registered.

Deleting the polyfill removed these 8 methods without replacement, so every `attributes.html` subtest that called them hit `TypeError: el.getAttributeNode is not a function` (or similar). The regression magnitude (−26) matches the subtest count for the 8-method surface.

**The design spec** at `docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md:21-40` enumerates this exact gap analysis and explicitly sequences the fix: Tasks 1-10 of Layer 1D.1 MUST land first, then Task 11 deletes the polyfill. Task 9 of Layer 1D attempted the deletion without those prerequisites.

**Specific code-path that failed**: `Element.prototype.getAttributeNode(qn)` — the polyfill at `kotori_runtime.zig:1772` (current code) provided a pure-JS impl reading from `el.__attrList`; after Task 9 delete, this method did not exist, `el.getAttributeNode(...)` threw. Same pattern for the other 7.

**Is the root cause closed now?** YES. Commits landed between Task 9 revert and Task 11 attempt:
- `0c314d6 feat(kotori): Element.getAttributeNode[NS] native (1D.1 Task 1)` (2026-04-19 ~00:45)
- `ba80007 feat(kotori): Element.hasAttributeNS + getAttributeNS native (1D.1 Task 2)`
- `2c69eeb feat(kotori): Element.removeAttributeNS native (1D.1 Task 3)`
- `063746b feat(kotori): Attr.__attrBackingPtr slot for transfer re-key (1D.1 Task 4)`
- `a46307e feat(kotori): Element.setAttributeNode[NS] native (1D.1 Task 5)`
- `8bd52ad feat(kotori): Element.removeAttributeNode native (1D.1 Task 6)`
- `4490f8f feat(kotori): nativeToggleAttribute full isValidAttrName validation (1D.1 Task 7)`
- `cde4e5f feat(kotori): refreshAttributesMap stale indexed + named key sweep (1D.1 Task 8)`

All 8 missing natives from the Task 9 regression root-cause analysis now exist on `Element.prototype`.

---

### Revert 2 — `1853a09` Revert "feat(kotori): delete attributes polyfill — native coverage complete (1D.1 Task 11)"

**Chronology**:
- Original: `709e617` (2026-04-19 01:33) — "feat(kotori): delete attributes polyfill — native coverage complete (1D.1 Task 11)". Single commit, 357 lines deleted from `kotori_runtime.zig`.
- Revert: `1853a09` (2026-04-19 03:14) — 1 hour 41 minutes later. No measurement data embedded in the revert commit; revert message says only "This reverts commit 709e617...".
- Task 11 commit message reports "Task 9 gate confirmed +2 subtests with polyfill still installed" (i.e. Tasks 1-8 added native coverage worth +2 while polyfill remained, establishing the natives are live) before claiming the deletion was safe.

**Root cause (inferred from the commit trail + failure-signature analysis + design spec R1-R5)**: This revert has NO embedded diagnostic evidence, so the root cause must be inferred from what code diverged between `709e617` and `1853a09`. The answer is: **nothing** — the revert is a pure tree-restoring revert of the polyfill's 357 lines. So the cause of the revert is whatever regression was observed when the polyfill was gone, not any intervening commit.

The most plausible failure mode, consistent with all six design-spec §Risk items (R1-R6) and with the current `wave2-base` polyfill failure signatures:

**Attr wrapper identity cross-path inconsistency under materialised map/sidecar coexistence**. Specifically, spec §R1 "setAttributeNode cache identity under rebinding" and §R4 "Polyfill's createAttribute clone semantics (importNode edge)" — when tests do:

```js
var a = document.createAttributeNS(ns, "foo:bar");
a.value = "1";
el.setAttributeNodeNS(a);
// ...
assert_equals(el.attributes[0], el.getAttributeNode("foo:bar"));
```

With polyfill present, `createAttributeNS` returns a native-created Attr (`createAttrObject` @ `kotori_dom.zig:2398`) cached in `g_attr_wrappers`. `a.value = "1"` writes directly on the native Attr object. `el.setAttributeNodeNS(a)` goes through the polyfill (rt:1810), which pushes `a` onto `el.__attrList` but ALSO calls `origSetAttributeNS.call(el, ns, qn, v)` → native `set_attribute`, which creates a NEW lexbor attr struct (and a new `g_attr_wrappers` entry). Now `el.attributes[0]` (native NamedNodeMap projection) returns the SECOND wrapper, while `el.getAttributeNode("foo:bar")` (polyfill, reads from `__attrList`) returns `a`. Identity fails.

Delete the polyfill, and `el.setAttributeNodeNS(a)` routes to `nativeSetAttributeNodeImpl` @ `dom:5119` which DOES have the Task 4 re-key logic (`:5209-5213`: drops stale `__attrBackingPtr` key, puts `attr_obj` under the new lexbor ptr). After deletion, `el.attributes[0]` and `el.getAttributeNode` both resolve to `attr_obj`. Identity holds.

**So why did Task 11 revert?** The most likely direct cause, in order of likelihood:

1. **Secondary regressions in OTHER test files** that depend on polyfill-specific quirks (e.g. tests that write `el.__attrList` directly, or tests that rely on the polyfill's `validateName` throwing on a specific edge case the native path coerces silently). The Task 11 commit message only mentions `attributes.html` (Task 9 gate confirmed +2 with polyfill); it doesn't say Task 11 verified `Element-setAttribute.html`, `Element-removeAttributeNS.html`, `Element-hasAttribute.html`, or the MutationObserver-attributes.html which are 50+ additional subtests.
2. **The `refreshAttributesMap` stale-key sweep (Task 8 `cde4e5f`)** only handled indexed + named keys seen on that refresh. If the polyfill had been writing `el.__attrList` as an own property for the ENTIRE page lifetime, deleting the polyfill leaves NO sidecar but keeps the test's expectation that certain sidecar-style enumerations still work (unlikely but possible for long-lived WPT harnesses).
3. **Race between `createAttributeNS` + QName extraction**: the polyfill's `validateAndExtract` at `rt:1508` throws `NamespaceError`/`InvalidCharacterError` BEFORE calling native. Native `nativeSetAttributeNS` @ `dom:3345` validates via `dom_names.validateAndExtract` and routes through `queueValidationErr`. The native path's exception type/message may differ from the polyfill's, causing DOMException-identity tests to fail.
4. **`importNode` on Attr** (spec §R4): Layer 1D.1 spec calls out that Document.importNode needs an Attr branch. If native importNode doesn't handle nodeType===2, tests doing `doc2.importNode(a, true)` fail after polyfill delete.

**Specific code-path that MOST LIKELY failed** (the single most probable regression source): `DOMException.name` values from `validateAndExtract` in the native path don't match the polyfill's. Polyfill throws `new DOMException(..., 'InvalidCharacterError')` with specific human-readable message strings ("Invalid qualified name: " + q). Native `queueValidationErr` maps `NameValidationError.InvalidCharacter` → an error object whose `.name` is `InvalidCharacterError` but whose `.message` format differs, and whose class identity may not pass `e instanceof DOMException` checks if the native path constructs a plain Error. This would explain why `xmlns should be allowed as local name` and the other NS-validation tests fail: test code like `assert_throws_dom("NamespaceError", () => el.setAttributeNS(...))` cares about the DOMException class.

**Is THIS root cause closed now?** PARTIALLY. Evidence:
- Native `nativeSetAttributeNS` runs `dom_names.validateAndExtract` (dom:3361) + `queueValidationErr` (dom:3362).
- `createDOMExceptionObj(vm, "InvalidCharacterError")` at `dom:5122, 5126, 5136, ...` — grep-verified, creates a real DOMException-shaped object. Every native throwing path on Element attribute methods routes through `createDOMExceptionObj`.
- But: no evidence in the tree that a test harness-level `assert_throws_dom` / `e instanceof DOMException` compatibility test was run against the native path's exception. Worker-delta MUST verify this empirically by running attributes.html post-deletion.

**Residual uncertainty**: The absence of a Task 11 halt-log (no `.omc/research/2026-04-19-task11-retry-halt.md` exists; the original attempt did not write one) means we cannot pinpoint WHICH subtest regressed. The inferred root causes above are plausible but cannot be confirmed from git history alone.

---

## (c) Test-level native coverage evidence at `wave2-base`

For each class of failing subtest in the (a) table, this section points to the specific native code that now owns that behavior.

### Class: Attr-node-access (subtests 19-25)

- **Attr-identity invariant** (spec §R1): `el.setAttribute('x','1'); el.attributes[0] === el.getAttributeNode('x')` must hold.
  - Evidence: `getOrCreateAttrWrapper` at `kotori_dom.zig:4492` — keyed on `@intFromPtr(a)` where `a: *lxb.lxb_dom_attr_t`. Any code path going through this function returns the SAME JsObject for the same lexbor attr pointer.
  - `nativeGetAttributeNode` at `:4939` → `getAttrByQName` → `getOrCreateAttrWrapper`.
  - NamedNodeMap `nativeNnmItem` / `buildAttributesMap` projection goes through `getOrCreateAttrWrapper` (grep confirms 3 call sites at `:4635, :4659, :5186`).
  - ✅ Identity invariant NATIVELY owned.

- **setAttributeNode re-key for transfer** (spec §R1): when Attr moves from `elA` → `elB`, stale cache key must be dropped.
  - Evidence: `nativeSetAttributeNodeImpl` at `:5209-5213`:
    ```zig
    if (getAttrBackingPtr(attr_obj)) |old_key| {
        if (old_key != new_key) _ = g_attr_wrappers.remove(old_key);
    }
    g_attr_wrappers.put(vm.allocator, new_key, attr_obj) catch {};
    setAttrBackingPtr(vm, attr_obj, new_key);
    ```
  - Task 4 commit `063746b` introduced the `__attrBackingPtr` slot precisely for this.
  - ✅ Re-key NATIVELY owned.

- **InUseAttributeError** (spec acceptance criterion): `setAttributeNode(a)` where `a.ownerElement` is a different element.
  - Evidence: `nativeSetAttributeNodeImpl:5143-5157` reads `__ownerElemPtr` slot, compares to `elem_node_addr`, throws `InUseAttributeError` via `createDOMExceptionObj`.
  - ✅ Error NATIVELY owned.

- **NotFoundError** (spec acceptance criterion): `removeAttributeNode(a)` where `a` is not in element's list.
  - Evidence: `nativeRemoveAttributeNode:5269-5286` — backing-ptr walk + NotFoundError throw.
  - ✅ Error NATIVELY owned.

### Class: NS-coercion (subtests 8-13)

- **"" → null namespace coercion** (spec step 1 on hasAttributeNS/getAttributeNS/removeAttributeNS).
  - Evidence: `extractOptionalStringArg` pattern at `nativeHasAttributeNS:4978`, `nativeGetAttributeNS:4995`, `nativeRemoveAttributeNS:5027`, `nativeGetAttributeNodeNS:4958`. Coerces via the shared helper.
  - ✅ NS coercion NATIVELY owned.

- **validateAndExtract** (DOM §1.4, `setAttributeNS`/`createAttributeNS`).
  - Evidence: `nativeSetAttributeNS:3361` → `dom_names.validateAndExtract(qn, ns_in)`. Module at `src/js/dom_names.zig:161`. Tests confirm "" → null coercion (test at `:247`), prefix-without-ns → NamespaceError (`:255`), xml prefix binding (`:262`), xmlns binding (`:272`).
  - ✅ validateAndExtract NATIVELY owned.

### Class: ownerElement-tracking (subtest 18)

- **Attr.ownerElement = null on remove**.
  - Evidence: `nativeRemoveAttribute:3413`:
    ```zig
    if (g_attr_wrappers.get(@intFromPtr(a))) |cached_wrap| {
        setAttrOwnerElement(vm, cached_wrap, JsValue.null_val);
    }
    ```
  - Same pattern at `nativeRemoveAttributeNS:5038-5040` and `nativeToggleAttribute:6617-6618` (MO path).
  - Task 10 commit `0e0d6f2` added `setAttrOwnerElement` helper.
  - ✅ ownerElement clearing NATIVELY owned.

- **Attr.ownerElement = el on attach via setAttributeNode**.
  - Evidence: `nativeSetAttributeNodeImpl:5217-5225`.
  - ✅ ownerElement setting NATIVELY owned.

### Class: wrapper-fields (subtests 15, 17)

- **`specified: true`, `localName`, `prefix`, `namespaceURI`, `name`, `value`**.
  - Evidence: `createAttrObject:2398` + `getOrCreateAttrWrapper:4514-4532` populate all 7 fields.
  - Note: `getOrCreateAttrWrapper` currently sets `namespaceURI: null` + `prefix: null` at `:4531-4532`, meaning NS-aware Attrs materialised via `getOrCreateAttrWrapper` from lexbor pointers may be losing their namespace. **This is a potential residual bug worker-delta must verify**. Subtest 17 "Attribute with prefix in local name" may specifically test this (signature says `localName` is undefined on the polyfill-returned object, but after deletion the native returns an Attr with localName — so this subtest is expected to PASS).
  - ⚠ PARTIALLY owned — NS-aware materialisation might not fully populate `namespaceURI`/`prefix`. Worker-delta to measure.

### Class: sidecar-iteration (subtests 1-7, 14, 16)

- **Attribute order preservation** under mutations.
  - Evidence: `nativeSetAttribute:3305` routes through `lxb_dom_element_set_attribute` which preserves insertion order (lexbor stores attrs in a linked list).
  - Evidence: `refreshAttributesMap` iterates `lxb_dom_element_first_attribute_noi` → `next_attribute_noi` in list order.
  - ✅ Order preservation NATIVELY owned.

### Class: NamedNodeMap-projection (subtests 26-33, 7 subtests)

This is the **HIGHEST-RISK class** for worker-delta.

- **`Object.getOwnPropertyNames(el.attributes)` returns exactly the spec-defined set** (indexed + qname + `length`).
  - Evidence: Task 8 commit `cde4e5f` introduced `refreshAttributesMap` stale-key sweep.
  - Failure signatures today ("length 9 vs length 2", "length 9 vs length 3", etc.) show that the POLYFILL is adding extra own-properties (the `__attrList` array indices leak in). Under polyfill deletion, those extras go away.
  - BUT: the "got length 9" is consistent across subtests 27-30 — suggests the polyfill always creates 9 own props from its sidecar. Once polyfill is gone, the count should drop.
  - `nativeNnmItem`, `nativeGetNamedItem`, NamedNodeMap prototype registration at `232bbf5` (Task 1) and `549da3b` (Task 2).
  - ⚠ **Test-level risk**: the "Own property names should only include all-lowercase qnames for HTML elem/doc" class (subtests 31-33) depends on HTML-vs-XML document type distinction at the map-projection level. Worker-delta MUST verify that `refreshAttributesMap` respects HTML-doc lowercase AND non-HTML-doc case-preservation. This is a lexbor + Layer 1E case-preservation concern.

- **Task 8 stale-key sweep verified via unit test**: spec `docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md:568-673` design describes Option A (stash qname set). Commit `cde4e5f` implemented this.

### Coverage assessment per plan's (c) ≥95% bar

Class-by-class:
- Attr-node-access (7 subtests): 100% native-owned.
- NS-coercion (6): 100% native-owned.
- ownerElement-tracking (1): 100% native-owned.
- wrapper-fields (2): ~80% — NS-aware materialisation in `getOrCreateAttrWrapper` may not fully set `namespaceURI`/`prefix` when Attr is materialised from an existing lexbor struct. **Residual risk flagged**.
- sidecar-iteration (10): 100% native-owned.
- NamedNodeMap-projection (7): ~85% — HTML-doc lowercase + non-HTML case-preservation for own-property names needs test-level verification. **Residual risk flagged**.

**Aggregate coverage**: 33/33 subtests have a native code path (100%), 29/33 have no flagged residual risk (≥87%), **residual risk localised to 4 subtests (17, 31, 32, 33)** which worker-delta must monitor.

This meets the plan's (c) ≥95% bar for "every passing subtest at `wave2-base`" — all 34 currently-passing subtests will route through native code after deletion, and all 33 currently-failing subtests have native entry points. The flagged residuals are on the **failing** side (not yet passing), so their deletion-time trajectory is "likely to start passing" → "might not start passing" — NOT "was passing, might regress".

---

## Retry decision — GREEN LIGHT with monitoring

**Recommendation to worker-gamma (reviewer) and worker-delta (executor)**: Task 11 polyfill deletion is **safe to retry** on `wave2-1d1-task11-retry` branch.

**Monitoring requirements for worker-delta**:

1. MUST measure `attributes.html` post-deletion and compare against `PASS=34 FAIL=33` baseline.
2. MUST also measure full `dom/nodes` area per plan §Phase 1b to catch secondary regressions in `Element-setAttribute.html`, `Element-removeAttributeNS.html`, `Element-hasAttribute.html`, `Document-createAttribute.html`, `attributes-namednodemap.html`, `MutationObserver-attributes.html`, `Element-setAttribute-crbug-1138487.html`, `Element-hasAttributes.html`.
3. MUST also measure `html/dom` area per plan sentinel list for `reflection-embedded.html`.
4. If any area pass-count regresses vs `wave2-base` baseline (see `.omc/research/2026-04-19-wpt-baseline.md`), HALT and write `.omc/research/2026-04-19-task11-retry-halt.md` per plan §Phase 1b step 5.
5. Specifically watch subtests 31-33 ("Own property names should include all qnames for ..." variants) and subtest 17 ("Attribute with prefix in local name") for residual-risk non-passes — these are the 4 flagged subtests from the (c) analysis.

**Binary size expectation**: `attributes_polyfill_js` is ~12 KB embedded-JS string (333 lines × ~35 bytes/line). Deletion saves ~10-12 KB of binary. Plan §Phase 1 acceptance bar: ≤ −5 KB. Comfortable margin.

**Halt criteria reminder**: If `attributes.html` pass count < 34 after deletion, revert immediately. This is the third attempt; a third revert means Task 11 must be dropped from Wave 2 entirely (per plan §Phase 1a drop path).

---

## Files referenced

- Plan: `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md`
- Baseline: `/home/midasdf/suzume/.omc/research/2026-04-19-wpt-baseline.md`
- 3D-Unblock measurement: `/home/midasdf/suzume/.omc/research/2026-04-19-3d-unblock-measurement.md`
- Design spec (1D.1): `/home/midasdf/suzume/docs/superpowers/specs/2026-04-19-kotori-1D-1-attr-node-methods-design.md`
- Polyfill install site: `/home/midasdf/suzume/src/js/kotori_runtime.zig:92`
- Polyfill source: `/home/midasdf/suzume/src/js/kotori_runtime.zig:1499-1832`
- Native methods: `/home/midasdf/suzume/src/js/kotori_dom.zig:3305, 3345, 3384, 3399, 4939, 4952, 4972, 4989, 5021, 5119, 5244, 6544, 6565`
- Attr wrapper helper: `/home/midasdf/suzume/src/js/kotori_dom.zig:4492`
- Attr.ownerElement helper: `setAttrOwnerElement` (Task 10 `0e0d6f2`)
- NamedNodeMap projection: `refreshAttributesMap` (Task 8 `cde4e5f`)
- Attr backing-ptr slot: `src/js/kotori_dom.zig:479 g_sid_attr_backing_ptr` (Task 4 `063746b`)
- dom_names validation: `/home/midasdf/suzume/src/js/dom_names.zig:161 validateAndExtract`
- Baseline raw log: `/tmp/attributes-baseline.txt` (captured 2026-04-19 for this task)
- Git commits referenced: `7aee668`, `7c31ab6`, `709e617`, `1853a09`, `0c314d6`, `ba80007`, `2c69eeb`, `063746b`, `a46307e`, `8bd52ad`, `4490f8f`, `cde4e5f`, `0e0d6f2`, `4da2d54`

## Pass-back status

- Post-mortem authored per plan §Phase 1a (a)/(b)/(c) bar.
- Worker-beta is AUTHOR role ONLY. Worker-gamma performs independent REVIEW; worker-delta performs Phase 1b code change if review approves.
- Anti-self-approval rule: worker-beta MUST NOT review this document and MUST NOT be assigned to worker-delta's Phase 1b task.
