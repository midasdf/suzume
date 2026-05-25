# Wave 6 Phase 6.2 Post-Merge Report

**Date**: 2026-04-20
**Merge result**: FF merge to `main`
**New HEAD**: `b6cbaa5`
**Tag**: `wave6-phase62`
**Base**: `62437b5` (`wave6-phase60`)

---

## Commits merged (2)

1. `4285bb5` feat(kotori): Wave 6 Phase 6.1+6.2 — VM bracket dispatch + deep semantic validator (atomic)
2. `b6cbaa5` fix(kotori): narrow Wave 6 Phase 6.2 — keep computed-style routing, drop bracket SET dispatch and deep validator delegation

Net diff main→HEAD: **+1179 lines** (css_validator.zig 1006 LOC orphaned for future phases + vm.zig get_elem dispatch + kotori_dom.zig computed-style routing + tests).

## Implementation journey

### Attempt 1: Full atomic landing (4285bb5)

- Added deep validator at `src/js/css_validator.zig` (1006 LOC, 5 layers)
- Delegated `dom_style.zig::isValidCssValue` to css_validator
- Added `.get_elem` + `.set_elem` bracket dispatch in VM
- Added computed-style routing in `domStyleGetProp`
- **Result**: −382 css/css-values, −0 dom/nodes, +2 css/cssom → GATE FAIL

### Root-cause: over-rejection in deep validator

- `rotate: acos(1)` valid per CSS Values 4 §10.7 (trig returns angle, unary result) but rejected
- `transform: translateX(calc(50%))` rejected by shorthand descent
- `attr()` function not recognized → blanket rejection
- `*-invalid.html` WPT tests newly enumerate via bracket dispatch but then fail because validator accepts some invalid and rejects some valid

### Attempt 2: Narrow (b6cbaa5)

Removed risky layers:
- Reverted `dom_style.zig::isValidCssValue` to Phase 6.0 body (surface check only)
- Removed `.set_elem` bracket dispatch (preserves Phase 6.0 silent no-op for `test_invalid_value`)
- Kept `.get_elem` bracket dispatch (routes computed-style reads)
- Kept `domStyleGetProp` computed-style routing
- Kept `css_validator.zig` as orphaned infra for future phases

## WPT delta (kotori engine, TIMEOUT=90, jobs=2)

| Area | Baseline (phase60) | HEAD (phase62) | Δ |
|------|--------------------|-----------------|---|
| css/css-values | 1203/4536 | **1273/4640** | **+70** |
| dom/nodes | 6394/7818 | **6444/7894** | **+50** |
| css/cssom | 168/701 | **170/701** | **+2** |

**Net: +122 subtests, zero regression.**

## Why narrow won

`.get_elem` alone gives bracket GET routing which unlocks `*-computed.html` tests:
- `calc-complex-unresolved-serialize.html`
- `calc-infinity-nan-computed.html`
- `calc-nesting-002.html`
- `clamp-length-computed.html`
- `hypot-pow-sqrt-computed.html`
- `signs-abs-computed.html`
- `sin-cos-tan-computed.html`

These require `getComputedStyle(el)[prop]` to resolve math functions. Previously bracket SET was silent no-op, so reading back was always empty. Now `.get_elem` routes through `resolve_fn` for computed-style objects.

## Orphaned infrastructure

`src/js/css_validator.zig` remains compiled and unit-tested (18 passing tests) but unused. When wiring back:

1. Deep arg-type compatibility (`round(1, 1%)` reject — number vs percentage mismatch)
2. Calc arithmetic validation (`abs(1 + )` reject — trailing operator)
3. `attr()` function support (currently blanket-rejected, needs type-query + pass-through)
4. `calc-size()` basis-keyword placement (basis in first arg only)
5. Shorthand descent (`background: linear-gradient(invalid)` → reject)

Estimated residual work: 400-600 LOC additional in `css_validator.zig`.

## Phase 6.3 recommendations (not this wave)

- Specified-value serialization normalization (term-sort, nested-calc flatten, NaN/infinity) — ~300 subtests on `*-serialize.html` tests
- Grid fr unit computed serialization
- `attr()` evaluator + type-query
- `random()` function
- `if()` conditional per CSS Values 5

## Session-level lessons

- **Rule 9 paired validation** requirement confirmed by attempt 1 regression
- **Rule 5 FORBIDDEN lists** prevented scope creep (agent stayed on spec)
- **Narrow-fallback pattern** saved the merge: when atomic fails, remove risky layers and ship minimal
- **Scientist forecast** was helpful but used wrong baseline (Phase 6.1 attempt data) — actual Phase 6.0 baseline gave different predictions

## Next steps

1. Push `main` + tag `wave6-phase62` to origin
2. Dispatch Wave 7 parallel layers:
   - Layer 1B MutationObserver subtree (+44 subtests)
   - Layer 0F eval local scope (~50 subtests)
   - Layer 4B Form controls (pending analyst open-questions resolution)
3. Phase 6.3 serialize normalization as follow-up

## Files changed

- `src/js/css_validator.zig` (new, 1006 LOC, orphaned)
- `src/js/kotori/vm.zig` (+14: `.get_elem` dispatch + `.set_elem` narrow comment)
- `src/js/kotori_dom.zig` (+19: computed-style routing)
- `tests/test_kotori_dom.zig` (+112)
- `build.zig` (+18: css_validator module registration)
