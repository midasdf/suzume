# Wave 6 Phase 6.2 — Deep Semantic Validator (Atomic with Phase 6.1 Bracket Dispatch)

**Date**: 2026-04-20
**Base**: `main @ 62437b5` (Phase 6.0 shipped, `wave6-phase60` tag)
**Target branch**: `feature/kotori-wave6-phase62` (fresh cut from `main`)
**Prerequisite research**:
- `.omc/research/2026-04-20-wave6-seed.md`
- `.omc/research/2026-04-20-wave5-retrospective.md`
- `.omc/research/2026-04-20-wave6-phase61-css-values.txt` (regression data)
- `.omc/research/2026-04-20-wave6-phase621-css-values.txt` (narrow-keyword attempt)

---

## Goal

Ship Phase 6.1 (VM bracket dispatch + computed-style routing) **atomically** with Phase 6.2 (deep semantic validator extensions) so that `test_invalid_value` helper regressions observed in Wave 5 Attempt A (−441) and Wave 5 Attempt B (−41 residual) are eliminated.

Acceptance:
- `css/css-values` ≥ `wave6-phase60_baseline + 200` (floor) — stretch `+500`
- `dom/nodes` ≥ `wave6-phase60_baseline` (zero regression)
- `css/cssom` ≥ `wave6-phase60_baseline + 5`
- `zig build` + `zig build test` exit 0

---

## Root-cause Recap

1. Bracket SET of invalid values previously silent no-op → WPT `test_invalid_value(prop, val)` helper passed "by accident" because `div.style[prop] = bogus; getPropertyValue(prop)` returned empty.
2. Phase 6.1 wires bracket SET through `domStyleSetProp` → raw writes go through, `getPropertyValue` returns stored garbage → tests fail.
3. Phase 6.0 `validate_fn` infrastructure is in place; `isValidCssValue` catches surface-level math-function malformations (balanced parens, no empty slots). Not enough.
4. Surface-level check **misses**:
   - Math-function arg **type compatibility** — `clamp(none, 1px, 1px)` passes parens check but `none` isn't a length.
   - **Gradient** function arg validation — `linear-gradient(calc(sign(50%) * 1turn), red, blue)` — inner math-in-direction is semantically invalid.
   - **Shorthand** descending validation — `background: linear-gradient(invalid)` doesn't reject.
   - **calc-size** specific grammar.
   - **URL request modifier** function (`url("x.png") request(integrity("..."))`).

Rule 10 (feedback_wave_execution_lessons.md) confirms: surface check covers ~80% of math functions. Deep semantic validator needed for the remaining invariants.

---

## Design: Property-Aware Descending Validator

### Module structure

Single additional module: `src/js/css_validator.zig` (new, ~400 LOC). Exports:

```zig
pub fn isValidPropertyValue(prop: []const u8, val: []const u8) bool
```

This replaces the current `isValidCssValue` in `dom_style.zig` via a thin indirection — `dom_style.zig::isValidCssValue` calls `css_validator.isValidPropertyValue` and keeps the existing public signature for the Phase 6.0 bridge in `main.zig`. No downstream signature break.

### Validation layers (inside new module)

```
isValidPropertyValue(prop, val)
  ↓
  ├─ Layer 0: early-accept — CSS-wide keywords (inherit/initial/unset/revert), var(), empty
  ├─ Layer 1: tokenize top-level — respect string literals, URL parens, comments
  ├─ Layer 2: classify value shape —
  │            * function call (math / color / gradient / image / url / other)
  │            * single ident / dimension / number / percentage / color-hex
  │            * compound (space-separated ident sequence, e.g., "bold 14px Arial")
  ├─ Layer 3: per-category validators (below)
  ├─ Layer 4: per-property grammar switch (existing `isValidCssValue` body moves here)
  └─ Layer 5: shorthand descent — `background` / `transform` / `font` / `border` /
              `animation` / `transition` invoke per-layer parsers
```

### Layer 3: function-call validators

#### A. Math functions — arg-count + arg-type compatibility

For each of the 21 math functions in Phase 6.0, check:

| Function  | Arity | Arg types (AST semantic) |
|-----------|-------|--------------------------|
| `calc(X)` | 1     | `X: <calc-sum>` |
| `min(X+)` / `max(X+)` | ≥1 | all args same **calc-sum** or length/number/percentage; mixed types rejected per §10.2 when not compatible |
| `clamp(A, B, C)` | 3  | A/B/C same type; A≤B≤C not enforced at parse (spec allows) |
| `round(S?, A, B)` | 2 or 3 | S ∈ {nearest, up, down, to-zero} if present |
| `mod(A, B)` / `rem(A, B)` | 2 | A, B same type |
| `abs(X)` / `sign(X)` | 1 | `X: <calc-sum>` |
| `sin(X)` / `cos(X)` / `tan(X)` | 1 | X: angle or number (CSS Values 4 §10.7) |
| `asin(X)` / `acos(X)` / `atan(X)` | 1 | X: number |
| `atan2(A, B)` | 2 | A, B same type, both number or both length |
| `sqrt(X)` / `exp(X)` / `log(X?, Y)` | 1 or 2 | numbers only |
| `pow(A, B)` / `hypot(A+)` | 2 or ≥1 | numbers only (pow) / all same type (hypot) |

Implementation: recursive descent over comma-split top-level args, each arg classified as `number | length | percentage | angle | time | unknown`. Reject when:
- arg count out of spec range
- arg type incompatible with function's type allow-list
- any arg is a bare ident not in {inherit, initial, unset, revert, var()} — `none`, `auto`, `max-content` etc. reject

**~150 LOC.**

#### B. Gradient functions

`linear-gradient(...)`, `radial-gradient(...)`, `conic-gradient(...)` and their `-repeating-` variants.

Args structure (CSS Images 3 §3.1):
- First arg: optional `<line>` for linear, optional `<position>`/`<shape>` for radial, optional `<angle>/from <angle>/at <position>` for conic
- Subsequent args: 2+ `<color-stop-list>` entries

Validation:
- First arg: if it contains `calc(sign(...))` or any bare `<percentage>` in a direction context → reject
- Each color stop: `<color> <length-percentage>?` with color validated via existing `isValidColorValue`
- At least 2 color stops required

**~80 LOC.**

#### C. `calc-size(...)`

Spec (CSS Box Sizing 4 §7): `calc-size(<calc-size-basis>, <calc-sum>)` where basis ∈ {any, auto, size, content, min-content, max-content, fit-content, stretch} or nested calc-size.

Surface check rejected all because bare `auto`/`content` were in inner arg; Wave 6 Phase 6.2.1 narrow-keyword rejection over-rejected. Correct: descend into calc-size and allow basis keywords **only** in the first arg.

**~40 LOC.**

#### D. URL request modifier

`url("x.png") request(integrity("..."))` — the `request(...)` modifier follows url(). Validator checks: modifier is immediately after url(), contains recognized sub-functions (`integrity()`, `referrer-policy()`, `crossorigin()`).

**~30 LOC.**

#### E. Image/resource functions

`image()`, `image-set()`, `cross-fade()`, `element()`, `paint()`. Mostly structural (parens + comma semantics).

**~30 LOC.**

### Layer 5: Shorthand descent

For each shorthand in `known_shorthands` (or the existing `isValidShorthandValue` map), split top-level by separator per property-specific grammar:

| Shorthand     | Separator | Per-component validator |
|---------------|-----------|-------------------------|
| `background`  | `,` (layers), space (within layer) | component by position → color / image / position / size / repeat / attachment / origin / clip |
| `transform`   | space    | each is a transform-function (matrix, translate, rotate, scale, skew, …) |
| `font`        | space    | shorthand mini-grammar |
| `border`      | space    | border-style, border-width, border-color in any order |
| `animation`   | `,` (multi), space (within) | per CSS Animations §4.3 shorthand order |

Existing `isValidShorthandValue` handles box-style shorthands (margin/padding). Extend to descend into each layer of `background` etc.

**~100 LOC.**

---

## Atomic Landing Plan

All files below land in a **single commit** on `feature/kotori-wave6-phase62`. Rule 3 (atomic landing) + Rule 9 (VM interception paired with setter validation).

### Files & edits

1. **NEW** `src/js/css_validator.zig` — new module, ~400 LOC (Layers 0-5 above).
2. **EDIT** `src/js/dom_style.zig::isValidCssValue` — delegate body to `css_validator.isValidPropertyValue`, keep public signature.
3. **EDIT** `src/js/kotori/vm.zig::.get_elem` — insert after symbol-block `continue` (existing line ~1308, post-`key.isSymbol()` block):
   ```zig
   if (key.isString() and (obj.obj_type == .dom_node or obj.obj_type == .dom_style) and self.dom_get_prop != null) {
       if (self.dom_get_prop.?(self, obj, key.asStringId())) |val_hit| {
           self.push(val_hit);
           continue;
       }
   }
   ```
4. **EDIT** `src/js/kotori/vm.zig::.set_elem` — analogous dispatch at line ~1398:
   ```zig
   if (key.isString() and (obj.obj_type == .dom_node or obj.obj_type == .dom_style) and self.dom_set_prop != null) {
       if (self.dom_set_prop.?(self, obj, key.asStringId(), val)) {
           self.push(val);
           continue;
       }
   }
   ```
5. **EDIT** `src/js/kotori_dom.zig::domStyleGetProp` — add computed-style detection after `cssText` branch, before inline-style attribute read (per Wave 6 seed Edit 8). ~15 LOC.
6. **EDIT** `src/js/kotori_dom.zig` — ensure `dom_get_prop` / `dom_set_prop` function pointers on VM point to the existing DOM dispatch functions if not already wired.
7. **EDIT** `tests/test_kotori_dom.zig` — add ~20 unit tests for `css_validator`:
   - `clamp(none, 1px, 1px)` rejected
   - `linear-gradient(calc(sign(50%) * 1turn), red, blue)` rejected
   - `calc-size(auto, 100px + 10%)` accepted, `calc-size(100px, auto)` rejected
   - `url("x") request(integrity("sha256-abc"))` accepted
   - `transform: translateX(50%) rotate(45deg)` accepted
   - `transform: translateX(invalid)` rejected
   - `background: linear-gradient(red, blue), url("x.png") center/cover` accepted
   - `background: linear-gradient()` rejected (empty)
   - shorthand round-trips: existing margin/padding tests preserved

---

## Gate protocol

### Pre-measurement (Rule 2 — spec baselines get stale)

```bash
cd /home/midasdf/suzume
TIMEOUT=90 SUZUME_JS=kotori ./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9876 css/css-values \
  > .omc/research/2026-04-20-wave7-pre-css-values.txt 2>&1
TIMEOUT=90 SUZUME_JS=kotori ./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9877 dom/nodes \
  > .omc/research/2026-04-20-wave7-pre-dom-nodes.txt 2>&1
TIMEOUT=90 SUZUME_JS=kotori ./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9878 css/cssom \
  > .omc/research/2026-04-20-wave7-pre-css-cssom.txt 2>&1
```

Compute pre-values for `wave6-phase60-pre-{css-values,dom-nodes,css-cssom}` floors.

### Post-measurement (after atomic landing)

Same 3 runs, written to `2026-04-20-wave7-post-*.txt`.

### Acceptance gate (Gate B)

- css/css-values post ≥ pre + 200 (floor)
- css/css-values post ≥ pre + 500 (stretch — ship)
- dom/nodes post ≥ pre − 5 (noise tolerance)
- css/cssom post ≥ pre + 5
- All 20 new unit tests pass
- Build + full test exit 0

If stretch missed but floor met → ship, follow-up Phase 6.3 for serialize normalization.
If floor missed → revert branch, diagnose residuals per file (Rule 10 residual categorization).

---

## FORBIDDEN files (Rule 5)

Executor agents implementing this spec **MUST NOT** touch:
- `src/js/kotori/compiler.zig` (bytecode emission — Phase 6.2 scope is runtime dispatch only)
- `src/js/kotori/bytecode.zig` (opcode definitions)
- `src/js/kotori/object.zig` (object model)
- `src/js/dom_api.zig` (separate subsystem)
- `src/js/events.zig` (Layer 2 scope)
- `src/css/cssom/*` (Phase 6.3 scope)
- `src/main.zig` (already wired in Phase 6.0)

**ALLOWED** files:
- `src/js/css_validator.zig` (new)
- `src/js/dom_style.zig` (delegation + existing helpers)
- `src/js/kotori/vm.zig` (the 2 interception inserts only — Rule 3)
- `src/js/kotori_dom.zig` (computed-style routing only)
- `tests/test_kotori_dom.zig` (new tests)

Any deviation from this list → revert + restart.

---

## Risk table

| Risk | Mitigation |
|------|-----------|
| Deep validator over-rejects valid values (false positive) → regress pre tests | Layer 0 early-accept keeps CSS-wide keywords + var() safe; 20 unit tests cover boundary cases |
| Gradient inner-direction check too strict | Only reject the specific patterns Wave 5 Attempt B missed (see retrospective residuals) |
| VM bracket dispatch introduces new WPT coverage → previously-green tests now red | Paired with deep validator per Rule 9 — silent-drop semantics preserved on invalid |
| calc-size narrow attempt showed −333 residual (Phase 6.2.1 measurement) | This spec distinguishes basis-keyword (first arg) from regular-arg contexts, avoiding blanket reject |
| Shorthand descent recursion depth / parse complexity | Bounded by top-level token count; no recursion below function-call layer |

---

## Anti-patterns (from Wave 5/6 lessons)

- ❌ Do **not** land Phase 6.1 without Phase 6.2 deep validator (Rule 9 — paired interception).
- ❌ Do **not** attempt narrow keyword rejection alone (Phase 6.2.1 failed, −333 residual).
- ❌ Do **not** touch FORBIDDEN files — VM compiler/bytecode changes carry regression contagion.
- ❌ Do **not** skip pre-measurement — baselines drift; spec numbers are stale within hours.
- ❌ Do **not** rely on `hasValidMathArgs` for gradient direction — surface check is 80%-complete.

---

## Success criteria

1. ✅ `css_validator.zig` module authored with 5 layers per spec.
2. ✅ VM bracket dispatch wired.
3. ✅ Computed-style routing in `domStyleGetProp`.
4. ✅ 20 unit tests added, all pass.
5. ✅ `zig build` + `zig build test` exit 0.
6. ✅ WPT post-measurement on 3 areas within gate.
7. ✅ Net gain ≥ +200 css-values subtests.
8. ✅ Commit message references this spec + research files.
9. ✅ Tag `wave6-phase62` on merge to main.

---

## Follow-up (out of Phase 6.2 scope)

- Phase 6.3: specified-value serialization normalization (term-sort, nested-calc flatten, NaN/infinity). Est +300 serialize tests.
- Phase 6.4: grid-template-columns fr + minmax() computed-value paths.
- Phase 7.x: Layer 4B Form controls, Layer 0F eval local scope — independent from Phase 6 chain.
