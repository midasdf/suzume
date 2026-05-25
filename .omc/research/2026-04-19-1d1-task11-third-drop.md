# Task 11 Third Drop — Wave 2 Phase 1b Result

**Date**: 2026-04-20 07:29 JST
**Decision**: Task 11 polyfill deletion DROPPED from Wave 2 after third revert
**Authority**: plan §Phase 1a drop path (no re-review loop in-wave)

---

## Hard Gate Result Summary

| Gate | Requirement | Measurement | Verdict |
|------|-------------|-------------|---------|
| D1 | attributes.html PASS ≥ 34/67 | **21/67** (−13) | **FAIL** |
| D2 | dom/nodes PASS ≥ 1204/2110 | not measured | — |
| D3 | html/dom PASS ≥ 35/571 | not measured | — |
| D4 | binary delta ≤ −5 KB | −13 KB (53302200 → 53288128) | PASS |
| D5 | `zig build -Doptimize=ReleaseSafe` + `zig build test` | both exit 0 | PASS |
| D6 (advisory) | subtest 17/31/32/33 regression | all 4 residual-risk FAILED post-deletion | **MATERIALIZED** |

D1 hard gate failed: 34/67 → 21/67 (**−13 passing subtests**). Per plan §Phase 1a drop path: immediate revert, no retry in-wave.

## Regression Evidence

Post-deletion failures not present in pre-deletion baseline include:

- `Basic functionality of removeAttributeNode` — `assert_equals: expected (object) object "[object Object]" but got (undefined) undefined`
- `getAttributeNames tests` — `Cannot read properties of undefined (reading 'length')`
- `Own property correctness with basic attributes` — `assert_array_equals: lengths differ, expected array [] length 2, got [] length 9`
- `Own property correctness with non-namespaced attribute before same-name namespaced one` — `expected length 3, got length 9`
- `Own property correctness with namespaced attribute before same-name non-namespaced one` — `expected length 3, got length 9`
- `Own property correctness with two namespaced attributes with the same name-with-prefix` — `expected length 3, got length 9`
- `Own property names should only include all-lowercase qualified names for an HTML element in an HTML document` — `expected length 8, got length 17`
- `Own property names should include all qualified names for a non-HTML element in an HTML document` — `expected length 12, got length 17`
- `Own property names should include all qualified names for an HTML element in a non-HTML document` — `expected length 12, got length 17`

## Root Cause (post-failure analysis)

Two distinct failure classes observed:

### Failure class A: `getAttributeNames` / `removeAttributeNode` — native implementation returns `undefined`

- `getAttributeNames tests` fails with `Cannot read properties of undefined (reading 'length')`. This suggests `Element.prototype.getAttributeNames` native returns `undefined` or the method is not reachable on the Element prototype post-deletion. The polyfill was apparently doing more than just polyfilling — it may have been registering `getAttributeNames` as an own property or extending prototype reach.
- `removeAttributeNode` — returns `undefined` instead of the removed Attr node. Native exists (per post-mortem §(c)) but apparently doesn't return the right value OR isn't reachable.

**Hypothesis**: polyfill was registering native methods onto Element.prototype or a dispatch table that native code alone doesn't populate for some tags. Deletion broke the registration.

### Failure class B: Own property enumeration — length 9/17 where expected 2/3/8/12

- Native `Object.getOwnPropertyNames(elem)` returns 9 items for an element with 2 attributes. Expected 2.
- For an HTML element with 8 attrs, returns 17. Expected 8.
- For an element with 3 attrs, returns 9. Expected 3.

**Hypothesis**: native element is exposing non-attribute "own properties" (likely internal methods/fields) that WebIDL requires to be hidden. The polyfill was probably redefining the element's property descriptors to hide these internals. Deletion exposed them.

## Post-mortem accuracy audit

The Phase 1a post-mortem claimed:
- 11/11 native methods present (TRUE structurally)
- 33 failing subtests all map to native entry points (TRUE structurally)
- 4 residual-risk subtests (17/31/32/33) — flagged but dismissed as "already failing, no regression risk"

**What the post-mortem missed**:
- Native methods being present ≠ native methods being properly dispatched
- The polyfill was actually holding together prototype registration and WebIDL own-property masking — not just providing missing methods
- Subtests 17/31-33 weren't the only at-risk ones — `getAttributeNames` / `removeAttributeNode` / own-property tests regressed unexpectedly
- The post-mortem was a structural audit, not a functional one

The **third revert is the data** proving the native coverage claim was unsound. Future retries (Wave 3+) must:
1. Build an exhaustive diff between polyfill-provided behavior and native behavior (runtime instrumentation, not source inspection)
2. Fix native property-descriptor hygiene BEFORE attempting deletion
3. Include `getAttributeNames` + `removeAttributeNode` return-value correctness as preconditions
4. Address `Object.getOwnPropertyNames` masking of internal Element slots (WebIDL §3.7 `[LegacyUnenumerableNamedProperties]` etc.)

## Revert Action

- `git checkout -- src/js/kotori_runtime.zig` (restores polyfill)
- `zig build -Doptimize=ReleaseSafe` (rebuilds with polyfill in place)
- Binary: 53,302,200 bytes (exact match to wave2-base pre-build)
- Attributes.html measurement: **34/67** (exact match to baseline)
- `git status` clean (no dirty files in src/)

No commit made on HEAD. No tag `wave2-layer-1d1-task11` created. Main branch unchanged at `4cf67ed`.

## Plan ADR Amendment

Update `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md` §Phase 5 ADR:

> **Decision amendment (2026-04-20)**: Task 11 polyfill deletion DROPPED after third failed attempt. Gate D1 failed (−13 subtests). Revert executed cleanly, baseline restored. Native coverage claim (11/11 methods) was structurally accurate but functionally insufficient — polyfill also held prototype registration and WebIDL own-property masking that native alone does not replicate. Task 11 deferred to a future wave with more rigorous functional diff (runtime instrumentation required, not source inspection).

## Reality-Reconciliation Drift Ledger entry

Wave 2 iteration-3 plan assumed Task 11 had a ≥95% safety margin based on post-mortem static analysis. Third revert proves static analysis alone is insufficient for polyfill-to-native migrations; **runtime behavioral equivalence testing is required**. This is the most important wave-close learning: the polyfill-deletion pattern cannot be approved on structural coverage alone; functional equivalence must be demonstrated first.

## Follow-ups (Wave 3+ candidates)

1. **Property-descriptor hygiene task**: audit all Element.prototype own-property leakage (9 items exposed where 2 expected). Likely requires WebIDL `[LegacyUnenumerableNamedProperties]` or similar mechanism in kotori_dom.zig wrapper generation.
2. **Return-value correctness task**: ensure `removeAttributeNode` returns the removed Attr, `getAttributeNames` returns the array. Audit via unit tests before next polyfill-deletion attempt.
3. **Runtime behavioral diff tool**: build a tool that runs a fixture set with and without the polyfill loaded, compares observable JS-level behavior, and emits a diff report. Required precondition for future Task 11 retries.
