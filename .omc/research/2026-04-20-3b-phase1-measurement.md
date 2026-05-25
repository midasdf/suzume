# Layer 3B Phase 3B.1 Retry — Measurement Report

**Date**: 2026-04-20
**Scope**: Math-function parser acceptance (min/max/clamp focus) at `src/css/*` only.
**Outcome**: **REVERTED** — gate P1 fail (0 delta on css-values). No regression elsewhere.

---

## Pre/Post Numbers

| Suite            | Pre     | Post    | Delta |
|------------------|--------:|--------:|------:|
| css/css-values   | 1162/4536 (25.6%) | 1162/4536 (25.6%) | **0** |
| dom/nodes        | (no pre run) | 6392/7813 (81.8%) | N/A (floor 1204, easily met) |

Test files for css-values: pass=74 fail=163 err=0 (unchanged).

---

## Gate Status

| Gate | Criterion                                | Actual             | Result |
|------|------------------------------------------|--------------------|--------|
| P1   | css-values post ≥ pre + 300              | 1162 vs 1162 (+0)  | **FAIL** |
| P2   | css-values post ≥ 1099 floor             | 1162               | PASS   |
| P3   | dom/nodes post ≥ 1204 floor              | 6392               | PASS   |
| P4   | `zig build test` exit 0                  | 0                  | PASS   |
| P5   | Binary size delta ≤ +80 KB               | +11,744 B (+11.5 KB) | PASS   |

Per the task rubric (any gate fail → revert), the implementation has been reverted.

---

## What Was Implemented (now reverted)

Three minimal changes in `src/css/cascade.zig` (only allowed file touched):

1. **`parseDimension` (line ~3361)**: Added math-function acceptance at the tail — if value
   starts with `min(`, `max(`, `clamp(`, `round(`, `mod(`, `rem(`, `abs(`, `sign(`, trig
   functions, `pow(`, `sqrt(`, `hypot(`, `exp(`, `log(`, the value is either preserved as
   `.calc = s` (if `%` present, for layout-time resolution) or resolved to `.px` via the
   full math dispatch in `resolveValueToPxDepth`.
2. **`parseAngle` (line ~2347)**: Added `calc(...)` and math-function branches so
   `rotate(acos(1))` and similar resolve to degrees via `resolveValueToPxDepth`.
3. **Opacity fallback (line ~1430)**: Replaced `resolveCalcWithPct` (which only handles
   `calc(`) with `resolveValueToPxDepth` so opacity accepts all `§10` math functions.

Plus a new private helper `isMathFunctionPrefix` and 4 unit tests for the parseDimension
min/max/clamp/percent-preservation cases.

Diff stat: `src/css/cascade.zig | 71 insertions, 3 deletions`. No other files touched.

---

## Root Cause of Zero-Delta

WPT's `test_math_used` / `test_math_computed` / `test_math_specified` helpers in
`/tmp/wpt/css/support/numeric-testcommon.js` drive all `<length>`/`<angle>`/`<number>`
math-function acceptance tests via **inline-style assignment**:

```js
testEl.style[prop] = testString;          // e.g. testEl.style.rotate = "acos(1)"
const usedValue = getComputedStyle(testEl)[prop];
```

The `getComputedStyle` path for inline-style values in suzume is
`src/js/dom_style.zig::resolveInlineForComputed`. That function receives the raw
string from the `style` attribute and returns it (or a minor serialisation variant).
It never touches the cascade's `ComputedStyle.Dimension` pipeline.

My changes in `src/css/cascade.zig` only affect the path **`<style>` / external stylesheet
→ cascade.applyDeclaration → ComputedStyle.* → dimensionToString`**. The inline-style
read never enters the cascade for computed-value resolution when the element has an
inline `style=""` attribute; it goes directly from attribute bytes to
`resolveInlineForComputed`.

Empirical confirmation:

```
width: min(100px, 200px);   // inline style
getComputedStyle(el).width  // → "min(100px, 200px)"  (raw, unresolved)
```

vs. my unit-test coverage at the cascade level, which correctly produced:

```zig
parseDimension("min(100px, 200px)") → .px = 100.0     // works
parseDimension("min(50%, 100px)")   → .calc = "min(50%, 100px)"  // works
```

Both paths work in isolation; the WPT tests just never hit them because
`src/js/dom_style.zig` is in the **FORBIDDEN** file list for this task.

Additionally, suzume's WPT-mode does not appear to execute `<style>` blocks the same
way it executes inline styles — a separate test of
`<style>#x { width: 100px }</style>` returned empty for `getComputedStyle(x).width`,
suggesting that even stylesheet-path changes have limited exercise under
`--wpt-mode` without rendering the document. Scope-safe investigation stopped there.

---

## Per-File Delta (top 10)

Zero non-trivial deltas. Spot-checks on the math-function test families
(`minmax-length-computed`, `minmax-length-serialize`, `signs-abs-computed`,
`acos-asin-atan-atan2-computed`, `round-mod-rem-computed`) show identical PASS/FAIL
counts before and after.

---

## Remaining Math Functions (deferred — would not land anyway)

Even if I had added every function from §10 (round/mod/rem/abs/sign/trig/pow/sqrt/exp/log/hypot)
to `parseDimension` and `parseAngle`, they would also not surface in WPT results while
`resolveInlineForComputed` remains the canonical inline-style → computed-value path.

**Subtests that would unlock with a follow-up `resolveInlineForComputed` patch
(out of scope for 3B.1)**:

| Suite family                       | Observed failing subtests |
|------------------------------------|--------------------------:|
| `minmax-length-*`                  | ~180 |
| `acos-asin-atan-atan2-*`           | 107  |
| `sin-cos-tan-*`                    | ~120 |
| `exp-log-*`                        | ~60  |
| `pow-sqrt-hypot-*`                 | ~100 |
| `round-mod-rem-*`                  | ~240 |
| `signs-abs-*`                      | ~80  |
| `calc-*` serialisation (§10 tied)  | ~550 |

The +1450 subtest projection in the spec appears to require touching
`src/js/dom_style.zig` for the inline-style computed-value path. This collides with
the present task's FORBIDDEN list.

---

## Recommendation

For the next attempt:

1. Add `resolveInlineForComputed` to the **ALLOWED** files, or delegate Phase 3B.1 as
   a two-part plan:
   - Part A (cascade-side, the reverted work here) — ready to land once verified
     against a WPT test that uses stylesheet-applied math functions.
   - Part B (`dom_style.zig` inline path) — the part that actually unlocks the 1450
     subtests.
2. Alternatively, move `resolveInlineForComputed`'s math-function dispatch **into**
   `src/css/cascade.zig` as a public helper (e.g. `pub fn normalizeMathFunctionForComputed`)
   and call it from the forbidden file — but the call site addition itself requires
   editing `dom_style.zig`.
3. Verify by adding a unit test for the inline-style path directly against
   `getComputedStyle` via a kotori harness test before running WPT.

---

## Files Changed (now reverted)

- `src/css/cascade.zig` (68 add, 3 modify) — **reverted to HEAD**

No other files in the ALLOWED list (`parser.zig`, `properties.zig`, `values.zig`)
were touched. Binary size restored to baseline (53,302,712 B).

Post-revert verification:

```
$ git diff --stat src/css/
(empty)

$ zig build -Doptimize=ReleaseSafe
EXIT=0

$ stat -c "%s" zig-out/bin/suzume
53302712
```
