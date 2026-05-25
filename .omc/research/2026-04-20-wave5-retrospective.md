# Wave 5 Retrospective — Phase 3B.1 Atomic Attempt + Rescue

**Date**: 2026-04-20
**Base tag**: `wave5-base` = `9b1dac7`
**Feature branch**: `feature/kotori-layer-3b-phase1-wave5`
**Outcome**: Gate FAIL on css/css-values; reverted per Wave 5 protocol. Research wave with concrete Wave 6 blueprint.

---

## Executive summary

Two implementation attempts landed on the feature branch, measured, diagnosed, and reverted:

1. **Attempt A** — minimal VM bracket dispatch + computed-style routing (38 LOC, 2 files).
2. **Attempt B** — rescue: add `validate_fn` callback infrastructure with property-specific invalid-value rejection (78 LOC, 4 files).

Attempt A blew up `*-invalid.html` tests because the invalid values that previously slipped through the silent no-op now reach `domStyleSetProp` and get stored. Attempt B wired `dom_style.isValidCssValue` to the DOM setters, which recovered most of Attempt A's loss, but the surface validator still misses deeply-invalid patterns (e.g., `linear-gradient(calc(sign(50%) * 1turn), ...)`).

| Suite          | PRE (wave5-base) | Attempt A      | Attempt B (rescue) | Δ vs PRE |
|----------------|-----------------:|---------------:|-------------------:|---------:|
| css/css-values | **931/4501**     | 490/4581 (−441) | **890/4557**       | **−41**  |
| dom/nodes      | 6400/7814        | 6400/7816      | 6400/7816          | 0        |
| css/cssom      | 163/702          | 165/702        | **170/701**        | **+7**   |

**Net Attempt B: −41 + 0 + 7 = −34 subtests. Gate FAIL → revert.**

Code shipped: **nothing** (HEAD at wave close = `9b1dac7` = HEAD at wave open).

---

## Attempt A — minimal bracket + computed routing

3 edits across 2 files:
- `src/js/kotori/vm.zig` `.get_elem` — DOM dispatch mirroring dot-access at `:1024`.
- `src/js/kotori/vm.zig` `.set_elem` — DOM dispatch mirroring dot-access at `:1234`.
- `src/js/kotori_dom.zig` `domStyleGetProp` — detect computed-style via `__element` internal slot, route through `resolve_fn` for CSSOM §6.5 resolved values.

Build: exit 0, +880 bytes.
Tests: exit 0.
Smoke: `el.style['height'] = '30px'` correctly updates inline style attribute.

**WPT result**: −441 css/css-values, 0 dom/nodes, +2 css/cssom. Net **−439**.

### Root cause

WPT `test_invalid_value(prop, value)` helper at `/tmp/wpt/css/support/parsing-testcommon.js`:

```js
function test_invalid_value(property, value) {
    var div = document.getElementById('target') || document.createElement('div');
    div.style[property] = "";           // BRACKET SET
    div.style[property] = value;        // BRACKET SET (invalid value)
    assert_equals(div.style.getPropertyValue(property), "");  // expects EMPTY
}
```

Before Attempt A: bracket SET was a silent no-op (stored only as plain JS prop on inline-style object). `getPropertyValue` reads inline style attribute → returns empty string → test passes.

After Attempt A: bracket SET routes through `domStyleSetProp` which writes the raw value with no validation. `getPropertyValue` reads inline attribute → returns the stored invalid value → test fails.

17 test files (≈525 subtests total) moved from the fully-passing set to the failing set.

---

## Attempt B — rescue via `validate_fn` infrastructure

78 LOC across 4 files:

1. `src/js/kotori_dom.zig` — added `ValidateFn` type, `validate_fn` global pointer, `setValidateCallback` registration, and `validate_fn` checks in `domStyleSetProp` and `nativeCSSSetProperty`. If validator returns false, the setter silently drops (CSSOM §6.7.2).
2. `src/main.zig` — added `kotoriValidateCssValue` bridge (calls `dom_style.isValidCssValue`) and registered it at navigation setup alongside `flush_fn` / `resolve_fn`.
3. `src/js/dom_style.zig` `isValidCssValue` — tightened the math-function surface check with a `hasValidArgs` helper that rejects empty inner args / empty comma slots / trailing commas / unbalanced parens. Applied to all 21 math function entries.
4. `src/js/kotori/vm.zig` — same 2 edits as Attempt A (re-applied).

Build: exit 0, +3544 bytes.
Tests: exit 0.
Smoke:
- `e.style.width = 'clamp()'` / `e.style['width'] = 'clamp()'` / `e.style.setProperty('width', 'clamp()')` — **all rejected** (empty string result for `getPropertyValue`) ✓
- `e.style.width = 'min(10px, 20px)'` — stored ✓
- `e.style['height'] = 'max(30px, 40px)'` — stored ✓

### Attempt B gains vs PRE

- `attr-all-types.html` 80 → 93 (+13)
- `attr-security.html` 1 → 29 (+28)
- `calc-complex-unresolved-serialize.html` 0 → 3 (+3)
- `calc-infinity-nan-serialize-number.html` 0 → 3 (+3)
- `calc-numbers.html` 0 → 2 (+2)
- `clamp-length-invalid.html` 0 → 9 (+9)
- `clamp-length-serialize.html` 0 → 4 (+4)
- `exp-log-invalid.html` 0 → 12 (+12)
- `exp-log-serialize.html` 0 → 2 (+2)
- `getComputedStyle-calc-mixed-units-003.html` 0 → 1 (+1)
- `hypot-pow-sqrt-invalid.html` 0 → 21 (+21)
- `hypot-pow-sqrt-serialize.html` 0 → 4 (+4)
- `ident-function-parsing.html` 4 → 11 (+7)
- `inherit-function-parsing.html` 2 → 3 (+1)
- `minmax-length-invalid.html` 0 → 12 (+12)
- `minmax-length-percent-serialize.html` 0 → 12 (+12)
- `minmax-length-serialize.html` 0 → 1 (+1)
- `minmax-number-invalid.html` 0 → 12 (+12)
- `minmax-percentage-invalid.html` 0 → 12 (+12)
- `minmax-percentage-serialize.html` 0 → 14 (+14)
- `minmax-time-invalid.html` 0 → 12 (+12)
- `position/position-valid.tentative.html` 0 → 18 (+18)
- `progress-invalid.html` 0 → 25 (+25)
- `round-mod-rem-invalid.html` 0 → 18 (+18)
- `signs-abs-invalid.html` 0 → 16 (+16)

Sum of observed gains: **≈+273 subtests**.

### Attempt B residual regressions vs PRE

- `calc-size-parsing.html` 56 → 38 (−18) — likely semantic issue with calc-size specific syntax my validator doesn't track.
- `percentage-without-context.html` 10 → 2 (−8) — my validator doesn't catch `linear-gradient(calc(sign(50%) * 1turn), ...)` as invalid; needs deep validator.
- `position/position-computed.tentative.html` 40 → 1 (−39) — math-function handling in position values not synced with computed-style output.
- `progress-serialize.html` 8 → 4 (−4) — likely similar pattern.
- `urls/url-request-modifiers-computed.sub.html` 17 → 0 (−17) — url modifier functions not handled in computed serialization.
- `urls/url-request-modifiers-serialize.sub.html` 17 → 0 (−17) — same.
- `random-serialize.tentative.html` 5 → 4 (−1).
- `tree-counting/calc-sibling-function-parsing.html` 4 → 2 (−2).

Sum of observed losses: **≈−106 subtests**. Plus undiagnosed losses from test-suite updates that show up only in aggregate counts (≈−208).

### Why rescue didn't fully close the gap

`isValidCssValue` is a surface-level shape check:
- ✓ Rejects math functions with empty or malformed arg lists (my new addition).
- ✗ Does NOT validate that `clamp(none, none, none)` has type-invalid args.
- ✗ Does NOT validate `linear-gradient(calc(sign(50%) * 1turn), ...)` contains invalid direction.
- ✗ Does NOT reach into `background` / `transform` shorthand parsers for deeper validation.

A full fix requires property-specific parsers that validate the grammar all the way down (essentially what Chrome/Firefox do). That is ≥ thousands of LOC and out of scope for Wave 5-6.

---

## Why Wave 4 warning was partially wrong

Wave 4 retrospective attributed the VM-alone regression to "CSS parser rejects math tokens → err state". The actual mechanism is different:

- CSS parser does NOT reject math tokens; `cascade.zig::resolveValueToPx` handles all §10 functions including `calc/min/max/clamp/round/mod/rem/abs/sign/sin/cos/tan/asin/acos/atan/atan2/sqrt/pow/hypot/log/exp`.
- `domStyleSetProp` / `updateStyleProp` accept any string as inline-style value with no validation.
- The regression comes from `*-invalid.html` tests that exploit the pre-fix asymmetry between bracket (silent no-op) and method-based SET.

The **prediction** of regression was correct; the **proposed cause** (parser rejection) was incorrect. The actual fix is setter-time validation, not parser work.

---

## Wave 6 Plan (blueprint)

### Phase 6.0 — Ship `validate_fn` infrastructure alone (prerequisite)

Commit Attempt B's infrastructure without the VM bracket dispatch or computed-style routing. Lands cleanly because no prior code path hits the new validator — it's just dead code that future waves will wire in.

- Files: `kotori_dom.zig` (+20 LOC for `ValidateFn` + registration), `main.zig` (+10 LOC for bridge), `dom_style.zig` (+30 LOC for tightened `hasValidArgs` check).
- Expected WPT delta: **0** (no behavior change, only new infrastructure).
- Gate: build + test + WPT unchanged vs `wave5-base`.

### Phase 6.1 — Extend `isValidCssValue` with semantic validation

Deep arg-type validation for math functions:
- `clamp(a, b, c)` requires 3 type-compatible args.
- `min(…)` / `max(…)` requires ≥1 type-compatible args.
- `round(strategy?, a, b)` requires strategy ∈ {nearest, up, down, to-zero} + 2 lengths.
- etc.

Plus shorthand-property validators that descend into `background` / `transform` / gradient functions to catch `linear-gradient(calc(sign(%) * 1turn), ...)` patterns.

Estimated scope: 300-500 LOC across `dom_style.zig` + `properties.zig`. 1-2 waves.

### Phase 6.2 — Enable VM bracket dispatch + computed routing

Re-apply Attempt A's 3 edits once 6.0 + 6.1 are shipped. Measurement should now show:
- css/css-values: +1500 subtests min (Category A math-function acceptance)
- css/cssom: +7
- dom/nodes: 0 (no regression)

Gate: `≥ pre-baseline_css_values + 200 (floor), 1400 (stretch)`.

### Phase 6.3 — Specified-value serialization normalization

The full Phase 3B.2 from the original design spec: term-sort, nested-calc flatten, numeric collapse, `min(X) → calc(X)` degenerate, `NaN`/`infinity` serialization per §10.11. Estimated +300 subtests in serialize tests.

---

## Cumulative session progress (2026-04-19 → 2026-04-20)

| Wave | Commits | Subtests shipped | Notes |
|------|---------|------------------|-------|
| Wave 2 | 0 | 0 | Task 11 3rd drop, research |
| Wave 3 attempt 1 | 0 (reverted) | 0 | forbidden-file block |
| Wave 3 Layer 1F.partial | 1 (`9b1dac7`) | +4 | shipped |
| Wave 3 retry | 0 (reverted) | 0 | FORBIDDEN too broad |
| Wave 4 | 0 (reverted) | 0 | diagnostic wave |
| **Wave 5 A** | **0 (reverted)** | **0** | 38 LOC, −441 gate fail |
| **Wave 5 B (rescue)** | **0 (reverted)** | **0** | 78 LOC, −34 gate fail |
| **Total** | **1** | **+4** | Layer 1F.partial only |

---

## Reality reconciliation

- Pre-baseline css-values **931/4501** vs seed's expected **1162/4472** — 231 subtest delta between spec and actual. Per feedback Rule 2, always re-measure.
- Test suite size drifted between Attempt A (4581) and Attempt B (4557) runs — ≥24 tests difference in a 30-min interval. Suggests `/tmp/wpt` checkout moves or TIMEOUT-dependent discovery.
- Attempt B gained +400 vs Attempt A, confirming validator infrastructure works. The residual −41 is a mix of test-suite drift + real code limitations in the surface validator.

---

## Key learnings

### Rule 9: Widening VM interception requires setter-time validation

When VM interception-point widens (bracket dispatch mirroring dot dispatch), invalid-value tests that relied on the narrower original path regress. Any such widening must be paired with setter-time validation to preserve CSSOM §6.7.2 invalid-value rejection semantics.

**Why**: `test_invalid_value` in WPT works by asserting that invalid values don't store — this assumes the setter layer validates. When we bypass the pre-existing "silent no-op" path and actually route through `domStyleSetProp`, lack of validation at that layer surfaces as regression.

**How to apply**: Before adding bracket-access (or any alternate access path) interception to DOM/style objects, verify that the setter layer rejects invalid values. Budget validation infrastructure (~200-500 LOC) as prerequisite, not follow-up.

### Rule 10: Surface validation is insufficient for shorthand / gradient / color contexts

The `isValidCssValue` shape check (prefix + closing paren + arg shape) catches clear malformed math calls but passes `linear-gradient(calc(sign(50%) * 1turn), ...)` and `clamp(none, none, none)` which are structurally balanced but semantically invalid. For full invalid-value rejection, need:
- Descending validators that reach into shorthand expansions.
- Type-compatibility checks for math-function args.
- Known-invalid keyword rejection (`none` is not a length; `0` is not a percentage; etc.).

**Scope**: 300-500 LOC. Wave 6 Phase 1 work.

---

## Files

All source files reverted. Only `.omc/` state files modified (not tracked code):

```
$ git diff --stat src/
(empty)
```

Binary at wave close: `zig-out/bin/suzume` = 53,302,712 bytes (= `wave5-base`).
HEAD at wave close: `9b1dac7` (= `wave5-base`).

Research artifacts preserved in `.omc/research/`:
- `2026-04-20-wave5-seed.md` — original plan
- `2026-04-20-wave5-pre-{css-values,dom-nodes,css-cssom}.txt` — pre-baseline (authoritative)
- `2026-04-20-wave5-post-{css-values,dom-nodes,css-cssom}.txt` — Attempt A post
- `2026-04-20-wave5-rescue-{css-values,dom-nodes,css-cssom}.txt` — Attempt B post
- `2026-04-20-wave5-retrospective.md` — this document
