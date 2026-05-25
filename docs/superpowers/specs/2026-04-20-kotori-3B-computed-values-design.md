# Layer 3B — CSS Computed Values (WHATWG CSS Values 4 §4)

**Date**: 2026-04-20
**Author**: planner (Wave 3 opener)
**Status**: Design spec — awaiting Architect/Critic review
**Wave**: 3
**Layer**: 3B (single-layer focus)
**Spec refs**: CSS Values & Units Module Level 4 — https://www.w3.org/TR/css-values-4/
- §4 Textual Data Types + §4.1 Specified / Computed / Used / Actual
- §5 Numeric Data Types (§5.1.1 Integers, §5.1.2 Numbers, §5.1.3 Percentages)
- §6 Distance Units (lengths) — §6.1 relative lengths
- §8.1 Viewport-percentage lengths (vw, vh, vmin, vmax, svh/dvh/lvh variants)
- §10 Mathematical Expressions — §10.1 calc(), §10.2 min()/max(), §10.3 clamp(), §10.7 round()/mod()/rem(), §10.8 sin()/cos()/tan()/asin()/acos()/atan()/atan2(), §10.9 pow()/sqrt()/exp()/log()/hypot(), §10.10 abs()/sign(), §10.11 infinity/NaN/degenerate values, §10.12 type checking
- CSS Values & Units Module Level 5 — §3 progress(), §7 sibling-index()/sibling-count()

---

## 1. Executive Summary

### 1.1 Scope

**IN SCOPE** (the name of the layer):
1. **Specified-value acceptance** for CSS math functions (`min()`, `max()`, `clamp()`, `round()`, `mod()`, `rem()`, `abs()`, `sign()`, `sin()`, `cos()`, `tan()`, `asin()`, `acos()`, `atan()`, `atan2()`, `pow()`, `sqrt()`, `exp()`, `log()`, `hypot()`) on a broad set of properties: `z-index`, `order`, `opacity`, `scale`, `rotate`, `transition-delay`, `transition-duration`, `animation-duration`, `animation-delay`, `tab-size`, `line-height`, `letter-spacing`, `word-spacing`, `font-size`, `font-weight`, `margin-*`, `padding-*`, `width`/`height`/`min-*`/`max-*`, `top`/`right`/`bottom`/`left`, `flex-basis`, `flex-grow`, `flex-shrink`, `border-*-width`, `border-radius-*`, `background-position-*`, `outline-width`, `outline-offset`.
2. **Computed-value resolution** — producing the correct computed-value string per §4.1: `min(1px)` → computed `1px` (not `min(1px)`), `min(1px + 1%)` → computed `calc(1px + 1%)`, `round(23px, 10px)` → `20px`.
3. **Specified-value serialization** — §10 round-trips: `min(1px)` → specified `calc(1px)`, `min(1px, 2px)` → `calc(1px)`, `calc(calc(100px))` → `calc(100px)`.
4. **Degenerate math values** — §10.11: `NaN` → computed `0` with `calc(NaN * 1px)` serialized form; `infinity` / `-infinity` → clamped to allowable range but serialized as `calc(infinity * 1px)`.
5. **Font-relative unit resolution** (§6.1) — `em`, `ex`, `ch`, `ic`, `cap`, `lh`, `rem`, `rlh` with correct inheritance chain and root-element semantics; existing unit arithmetic (`em → parent.font_size_px`, etc.) is correct but inheritance order is not guaranteed.
6. **Viewport-percentage unit resolution** (§8.1) — `vw`, `vh`, `vmin`, `vmax`, plus `svh/dvh/lvh/svw/dvw/lvw/svmin/dvmin/lvmin/svmax/dvmax/lvmax` and logical `vi`/`vb` equivalents; current code has the 4 classics but no explicit `vi`/`vb`.
7. **Integer rounding** (§5.1.1) — CSS round-half-toward-positive-infinity on `z-index`, `order`, `reading-order`.
8. **calc() serialization normalization** (§10.12 + CSSOM) — pure numeric simplification (`calc(20px + 80px)` → `calc(100px)`), nesting flattening (`calc(calc(100px))` → `calc(100px)`), term sorting (`calc(1vh + 2px + 3%)` → `calc(3% + 2px + 1vh)`).
9. **Integration**: plumb everything through `getComputedStyle()` in `src/js/dom_style.zig` and through `style.setProperty()` / `CSSStyleDeclaration` value validation in `src/css/properties.zig` and `src/css/parser.zig`.

**OUT OF SCOPE** (explicitly deferred to later layers):
- `attr()` / `attr(data-foo type(<length>))` / `attr(data-foo, fallback)` — cross-layer with HTML attributes; deferred to Layer 4C.
- `if()` / `if(style())` / `if(media())` conditional values — deferred to Layer 3E.
- `inherit(--x)` / explicit inherit-function — deferred to Layer 3E.
- `random()` / `random(fixed 0.5, …)` — deferred (pseudo-random infrastructure).
- `sibling-index()` / `sibling-count()` — requires tree-counting infrastructure (§7 L5); deferred to Layer 3F.
- `calc-size(auto, size)` / `calc-size(fit-content, size)` — new CSS Sizing L4 function; deferred.
- `ident(foo)` / `ident("foo" 3)` — deferred.
- `progress(…)` — depends on typed arithmetic completion; deferred.
- URL-request modifiers (`cross-origin()`, `integrity()`, `referrer-policy()`) — deferred.
- Typed-OM (`computedStyleMap()`, `CSSUnitValue`, `CSSMathValue`) — deferred to Layer 3G.
- `@font-face` / web-font `ch` recalc after font load — depends on font-loading infrastructure; out of scope.
- Container queries / `container-type: size` unit recalc — deferred.
- Dynamic viewport resize invalidation (`svh` → `dvh` transition on scroll) — deferred.

### 1.2 Expected WPT delta

**Baseline**: `css/css-values` = 1099/4472 (24.6%).

**Target**: ≥ 3099/4472 (70%+), i.e. **+2000 subtests minimum**, derived as follows:

| Category (in scope) | Passing now | Total | Target after 3B | Δ |
|---|---:|---:|---:|---:|
| min/max/clamp × length,%,integer,number,angle,time (`minmax-*-{computed,serialize}.html` × 10 files) | 0 | 444 | 400 | +400 |
| round/mod/rem (`round-*.html`, `round-mod-rem-*.html`) | 0 | 458 | 380 | +380 |
| abs/sign + signed-zero (`signs-abs-*.html`, `signed-zero.html`) | 0 | 411 | 350 | +350 |
| sin/cos/tan/asin/acos/atan/atan2 (`sin-cos-tan-computed.html`, `acos-asin-atan-atan2-*.html`) | 0 | 133 | 110 | +110 |
| hypot/pow/sqrt/exp/log (`hypot-pow-sqrt-*.html`, `exp-log-*.html`) | 0 | 110 | 90 | +90 |
| calc-*-computed/serialize (`calc-serialization*.html`, `calc-nesting*.html`, `calc-numbers.html`, `calc-unit-analysis.html`, `calc-letter-spacing.html`, `calc-z-index-fractions-001.html`, `calc-background-position-00{2,3}.html`, `calc-infinity-nan-*.html`) | <10 | 500 | 380 | +370 |
| calc-catch-divide-by-0 + calc-in-* (`calc-catch-divide-by-0.html`, `calc-in-color-001.html`, `calc-rgb-percent-001.html`, `calc-complex-unresolved-serialize.html`) | <5 | 35 | 28 | +25 |
| getComputedStyle-calc-mixed-units-00{1,2,3}.html | 0 | 18 | 15 | +15 |
| clamp-length/integer/color-computed + serialize + partial-serialize | 0 | 111 | 90 | +90 |
| minmax-length-percent-* (with cb-width) | 0 | 107 | 80 | +80 |
| lh-rlh-on-root-001, lh-unit-00{3,4,5}, rem-unit-root-element, rlh-on-root-lengths | 0 | 15 | 10 | +10 |
| integer_interpolation_round_half_* (4 files) | 0 | 4 | 4 | +4 |
| typed_arithmetic.html | 0 | 35 | 20 | +20 |
| viewport-units-parsing (parsing part, not resize invalidation) | 0 | 24 | 18 | +18 |
| percentage-without-context (some) | 10 | 12 | 12 | +2 |
| **TOTAL (in-scope)** | | | | **+1964** |

Plus expected spillover:
- `css/cssom` computed-style.html and related sentinels (+20 to +40 subtests)
- `css/css-color` calc-in-color/calc-rgb-percent — color channels accept math functions (+20)

**Conservative projected delta**: **+2000 subtests** → `css/css-values` 3099/4472 ≈ 69.3%.
**Stretch projected delta**: **+2050** → ~70.0%.

### 1.3 Why this layer now

- Single-layer Wave 3 scope (Wave 2 L1 lesson).
- Biggest single headroom in baseline (3373 failing subtests available in `css/css-values`).
- New code, not polyfill-deletion — clean risk profile (Wave 2 L2 lesson).
- Builds on existing foundation: `cascade.zig:resolveCalcWithPct` already handles most math; gaps are (a) parser acceptance of math-functions in non-length property contexts, (b) serialization form at specified/computed time, (c) degenerate-value handling.

---

## 2. WHATWG CSS Values 4 §4 Mapping

### 2.1 §4.1 — Specified / Computed / Used / Actual

The spec defines four stages:
- **Specified value**: the post-parse form per the property grammar. Math functions stay as `calc()` form (with internal simplification but NOT reduced to their final value when unresolved symbols are present).
- **Computed value**: after inheritance and cascade; units are normalized (e.g. absolute lengths to `px`, angles to `deg`, times to `s`, keywords resolved). **Not yet layout-resolved** — percentages and `em`/`ex`/`ch`/`lh`/viewport still may remain, depending on property. §4.1 mandates that for most CSS properties, relative lengths (em etc.) and pure calc() should be resolved to their absolute form at this stage.
- **Used value**: after layout — all percentages resolved, `auto`/`min-content`/`max-content`/`fit-content` resolved.
- **Actual value**: after device constraints (subpixel rounding, scrollbars, etc.).

**suzume mapping**:
- `getComputedStyle()` in CSS spec terms returns the **resolved value** (CSSOM § 6.1), which is per-property either the computed or used value. For lengths on laid-out elements it is the used value; for unlaid-out elements it is the computed value.
- `element.style.X` (`CSSStyleDeclaration` read) returns the **specified value** of the property from inline style (as typed by the author, normalized).
- suzume's layer split: `src/css/cascade.zig` produces the computed value; `src/layout/*.zig` produces used values; `src/js/dom_style.zig` serializes both back to CSS strings for the DOM/CSSOM.

### 2.2 §5 — Numeric Data Types

| Type | Computed-time rules | Serialization |
|---|---|---|
| `<integer>` | Math functions resolve and round. CSS Values 4 §10.11 + Values 5: half-values round toward positive infinity (NOT banker's). | Decimal, no fractional part. |
| `<number>` | Math functions resolve fully. Pure `calc()` at computed time simplifies to a bare number (no `calc()` wrapper). | Shortest decimal. |
| `<percentage>` | Stays percentage at computed time if the property allows either length or %. Math functions with % + px stay as `calc()`. | `NN%` or `calc(NN%)` or `calc(Npx + M%)`. |

**Example** (round to integer, `z-index: calc(2.5 / 2)`):
- Specified: `calc(1.25)` — but the property grammar requires `<integer>`; §10 says the math function is still accepted but the **computed** integer is produced via §10.11 rule: round(half toward +∞) of the unwrapped numeric result. `1.25` → `1`. Serialized `1`.
- Currently: `undefined` — suzume's parser rejects `calc(…)` on `z-index` at specified time. **This layer fixes.**

### 2.3 §6.1 — Font-Relative Lengths

Per §6.1:

| Unit | Relative to |
|---|---|
| `em` | The **element's own** `font-size`. |
| `ex` | `x-height` of the element's first available font. Fallback: `0.5em`. |
| `cap` | `cap-height` (capital-letter height) of the element's first available font. Fallback: `0.7em` (approx). |
| `ch` | Advance measure of "0" glyph. Fallback: `0.5em` (per spec, assume 0.5em if glyph metric unknown). |
| `ic` | Full-width advance measure of "水" (U+6C34) glyph. Fallback: `1em`. |
| `lh` | The **element's own** computed `line-height`. `normal` resolves to `1.2em`. |
| `rem` | Root element (`:root`) computed `font-size`. Default `16px`. |
| `rlh` | Root element computed `line-height`. |

**Special rules (§6.1)**:
- On the **root element**, `rem` uses the initial value of `font-size` (the UA default, 16px), NOT the author-set root font-size when computing `font-size` itself. But `rem` in other properties on root uses the computed `font-size`. (This is what `rem-unit-root-element.html` and `update-subpixel-rem-unit.html` check.)
- `lh` on `font-size` itself: uses the **inherited** `line-height` (parent's, or `normal` on root).
- `rlh` on root properties: uses root's computed `line-height`.

**Current code (cascade.zig:2616)**:
```zig
.em => value * font_size,
.rem => value * 16.0,            // BUG: hardcoded, not root font-size
.ch => value * font_size * 0.5,  // approximation, OK for now
.ex => value * font_size * 0.5,  // approximation, OK
.lh => value * font_size * 1.2,  // BUG: uses own font-size, not line-height
```
- `.rem` must use the document root computed font-size, not the literal `16.0`.
- `.lh` must use `style.line_height` resolved to px, not `font_size * 1.2`.
- `.rlh` missing — add.
- `.ic`, `.cap` missing — add with safe fallbacks (`1em`, `0.7em`).

### 2.4 §8.1 — Viewport-Percentage Lengths

| Unit | Resolves to |
|---|---|
| `vw` / `vh` | 1% of current viewport width/height. |
| `vmin` / `vmax` | 1% of `min(vw_px, vh_px)` / `max(...)`. |
| `svw` / `svh` / `svmin` / `svmax` | Small viewport (when UA chrome maximally extended). |
| `dvw` / `dvh` / `dvmin` / `dvmax` | Dynamic viewport (current state). |
| `lvw` / `lvh` / `lvmin` / `lvmax` | Large viewport (UA chrome minimally extended). |
| `vi` / `vb` | Inline-axis / block-axis viewport percentages (logical). In horizontal-tb, `vi` = `vw`, `vb` = `vh`. |

**suzume model**: no UA chrome retracting on scroll, so `sv* = dv* = lv* = v*` (all four map to the same value). `vi`/`vb` map to `vw`/`vh` (horizontal-tb only). Globals `api.g_viewport_width` / `api.g_viewport_height` already supply the base. Missing: `vi`/`vb` in the `values.Unit` enum and parser; and parser acceptance of these units in all property contexts.

### 2.5 §10 — Mathematical Expressions

Per §10 for each math function:

| Function | Specified serialization | Computed serialization |
|---|---|---|
| `calc(X)` | `calc(X)` with X normalized (numeric collapse, flatten, term-sort) | Resolved value if fully numeric; else `calc(…)` with units unified |
| `min(X)` | `calc(X)` (single-arg degenerates to calc) | Resolved value; multi-arg stays as `calc()` if any arg still has %+length |
| `min(X, Y, …)` | `min(X, Y, …)` (sort not required; preserve author order) | Resolved scalar if fully numeric |
| `max(...)` | Same as min |
| `clamp(MIN, VAL, MAX)` | `clamp(MIN, VAL, MAX)` | Resolved scalar if fully numeric |
| `round(S, A, B)` with strategy nearest/up/down/to-zero | `round(S?, A, B)` | Resolved per §10.7 step rules |
| `mod(A, B)` | `mod(A, B)` | Resolved; sign follows divisor |
| `rem(A, B)` | `rem(A, B)` | Resolved; sign follows dividend |
| `abs(X)` | `abs(X)` | Resolved scalar |
| `sign(X)` | `sign(X)` | Resolved scalar in {-1, 0, 1}; signed zero: `sign(-0)` = 0 per §10.11 |
| `sin`/`cos`/`tan` | unchanged | Resolved scalar (unitless; angle inputs converted to rad internally) |
| `asin`/`acos`/`atan`/`atan2` | unchanged | Resolved angle in `deg` |
| `pow(B, E)` | `pow(B, E)` | Resolved scalar |
| `sqrt(X)` | `sqrt(X)` | Resolved scalar |
| `hypot(A, B, …)` | `hypot(…)` | Resolved scalar |
| `exp(X)` / `log(X[, B])` | `exp(X)` / `log(X[, B])` | Resolved scalar |

**Key spec rules for serialization**:
- **§10.12 type checking**: operands must reduce to a single type per CSS type-system rules; `1px + 1` is invalid (length + number).
- **Single-argument degenerate**: `min(1px)` / `max(1px)` serialize at specified time as `calc(1px)`, NOT as `min(1px)`. **Currently suzume returns `undefined`.**
- **Nested calc flattening**: `calc(calc(X))` → `calc(X)` at specified time. Currently suzume returns the input unchanged.
- **Term sorting in calc at specified time**: `calc(1vh + 2px + 3%)` → `calc(3% + 2px + 1vh)`. Order: percentages first, then absolute lengths, then font-relative, then viewport-relative (alphabetical per unit). **Currently no sort.**
- **Fully-numeric computed simplification**: `calc(20px + 80px)` at computed time → `100px` (no `calc()` wrapper). Currently returns `calc(20px + 80px)`.
- **Infinity/NaN preservation at serialization**: `calc(1px / 0)` → computed is `calc(infinity * 1px)` not plain number. `calc(0 / 0 * 1px)` → `calc(NaN * 1px)`. Currently returns `undefined`.
- **Signed zero**: IEEE -0 detection for `sign(calc(-0))`; tricky but needed for `signed-zero.html` (162 subtests).

### 2.6 Inheritance model

Per CSS Cascade 5 §4.2:
- Inherited properties (`font-*`, `color`, `line-height`, `letter-spacing`, `word-spacing`, `visibility`, `text-*`, etc.) use the **parent's computed value** as default.
- Non-inherited properties start at their initial value.
- `inherit` keyword forces inheritance.
- `initial` keyword forces initial value.
- `unset` = inherit if inheritable else initial.
- `revert` = revert to UA stylesheet.
- `revert-layer` = revert to previous cascade layer.

**Current suzume model** (cascade.zig:1224):
```zig
style.font_size_px = parent.font_size_px;  // initialize from parent
```
…then per-element styles override. This is correct **in aggregate**, but the parent must be fully computed before the child. Current code appears to traverse depth-first, but I could not verify ordering guarantees in 2 min; architect should confirm.

---

## 3. Current Implementation Audit

### 3.1 File inventory

| File | LOC | Purpose | Layer 3B touchpoint |
|---|---:|---|---|
| `src/css/values.zig` | 217 | `Unit`, `Length`, `Color`, `Keyword`, `Value` | Add `.ic`, `.cap`, `.rlh`, `.vi`, `.vb` to `Unit` enum |
| `src/css/computed.zig` | 578 | `ComputedStyle` struct + enums | No schema change needed; possibly add `cap_height_px_cached`/`ch_width_px_cached` fields if font-metric lookup is expensive |
| `src/css/parser.zig` | 926 | Rule/declaration parser | Ensure math functions pass through for all value types |
| `src/css/properties.zig` | 2755 | Per-property value parsers/validators | **CRITICAL**: currently rejects math functions on `z-index`, `scale`, `rotate`, `opacity`, etc. — add math-function fallthrough |
| `src/css/cascade.zig` | 3971 | Selector matching + cascade + computed-value resolution; also `resolveCalcWithPct`, `resolveLengthToPx*`, `resolveValueToPx` | Extend unit handler; add `rlh`/`ic`/`cap`/`vi`/`vb`; fix `rem`/`lh` context bugs; add numeric-fully-resolved simplification |
| `src/css/cssom/style_decl.zig` | ? | `CSSStyleDeclaration` API | Pass math-function strings to property validators |
| `src/css/cssom/computed_slice.zig` | ? | Computed value slicing | May need serialization path updates |
| `src/js/dom_style.zig` | 5464 | `getComputedStyle` object construction + `computedStyleToString*` | **CRITICAL**: extend `computedStyleToStringWithBoxInner` to serialize math functions correctly; extend `resolveInlineForComputed` to produce computed-time form |
| `src/js/web_api.zig` | — | `window.innerWidth`/`innerHeight` + viewport globals | Already good |
| `src/js/frame_state.zig` | — | `viewport_width`/`viewport_height` per frame | Already good |
| `src/layout/block.zig`, `src/layout/flex.zig` | — | Layout uses `cascade_mod.resolveCalcPct` directly | No change — layout stays on `used-value` path |

### 3.2 What works today

- `calc(100px + 50%)` parses and resolves correctly for `width`/`height`/`margin-*`/`padding-*` when given a containing-block reference via `getComputedStyle`.
- `calc(10px + 0.5em)` resolves with font-size context (memo confirmed: flex-basis 30px for 16px parent font-size).
- `min()` / `max()` / `clamp()` parse and resolve **inside calc()** via `resolveMinMaxWithPct`, `resolveClampWithPct` in cascade.zig.
- `round()` / `mod()` / `rem()` parse via `resolveRoundWithPct`, `resolveModRemWithPct`.
- `sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`atan2`/`sqrt`/`pow`/`hypot`/`log`/`exp` parse via `resolveTrigFunc`, `resolveUnaryMathFunc`, etc.
- Viewport units `vw`/`vh`/`vmin`/`vmax` and `svh/dvh/lvh/svw/dvw/lvw` resolve correctly in length contexts.
- NaN → 0 at computed time in `resolveCalcWithPct` (cascade.zig:2777).
- `getComputedStyle(el).getPropertyValue(prop)` exists and dispatches to `computedStyleToStringWithBoxInner`.

### 3.3 Gap analysis (what breaks)

**G1: Property-value parsers reject bare math functions.**
Evidence: `e.style['width'] = "random(0px, 100px)"` → `"auto"`; `e.style['left'] = "inherit(--x)"` → `""`; `e.style['z-index'] = "sibling-index()"` → `""`. But also `e.style['scale'] = "min(1)"` and `e.style['rotate'] = "min(90deg)"` → `""`. The parser in `src/css/properties.zig` only accepts math functions for the subset of properties `dom_style.zig` happens to already forward. Hundreds of WPT subtests fail at **setProperty time**, not at read time.

**Scope**: per the failure log, all `minmax-*-computed.html`, `round-function.html`, `round-mod-rem-computed.html`, `signs-abs-computed.html`, `signed-zero.html`, `sin-cos-tan-computed.html`, `hypot-pow-sqrt-*.html`, `exp-log-*.html` fail because the setter returns `""`/`"undefined"` and the getter sees the initial value instead.

**G2: Missing specified-value serialization for math functions.**
Evidence: `'min(1px)' as a specified value should serialize as 'calc(1px)'` expects `calc(1px)`, we return `undefined`. Also `'rotate(min(90deg))' as a specified value should serialize as 'rotate(calc(90deg))'`. The CSSOM serializer does not recognize math functions.

**Scope**: every `*-serialize.html` file.

**G3: Missing computed-value serialization for math functions.**
Evidence: `'pow(1,1)' as a computed value should serialize as '1'`, `'calc(20px + 80px)' → '100px'`, `'calc(1s * NaN)' → 'calc(NaN * 1s)'`. Currently we leave the author string verbatim or return `undefined`.

**Scope**: every `*-computed.html` file with math-function cases.

**G4: calc() normalization missing.**
Evidence: `calc(20px + calc(80px)) → calc(100px)` expected; we return the input unchanged. `calc(1vh + 2px + 3%) → calc(3% + 2px + 1vh)` expected (sort). `calc(calc(100px)) → calc(100px)` expected (flatten). `calc(calc(2) * calc(50px)) → calc(100px)` expected (multiply-through).

**Scope**: `calc-nesting*.html`, `calc-serialization*.html`, `calc-complex-unresolved-serialize.html`, `calc-numbers.html`.

**G5: `rem` unit uses literal 16.0 instead of root computed font-size.**
Evidence: `rem-unit-root-element.html`: `:root { font-size: 10px }` → `1rem` should be 10px, we return `""` because calculating against 16px then the root override doesn't propagate. Same bug in `update-subpixel-rem-unit.html`.

**Scope**: `rem-unit-root-element.html`, `update-subpixel-rem-unit.html`, plus any test that sets non-default root font-size.

**G6: `lh` / `rlh` use `font_size * 1.2` instead of actual line-height.**
Evidence: `lh-rlh-on-root-001.html`, `lh-unit-00{3,4,5}.html` expect `lh` = computed `line-height` in px. Current code `value * font_size * 1.2` is wrong when `line-height` is `1.5` or `20px`.

**Scope**: 12 subtests minimum; some need font-load infrastructure which is out of scope.

**G7: `vi`, `vb`, `ic`, `cap` units not recognized.**
Evidence: `viewport-units-parsing.html`: `e.style['width'] = "1vi"` → `""`. Also `ic`, `cap` in length contexts.

**Scope**: ~18 subtests in `viewport-units-parsing.html`.

**G8: Integer rounding follows f32-default, not round-half-toward-positive-infinity.**
Evidence: `integer_interpolation_round_half_001.html`: `-0.5` should round to `0` (toward +∞), not `-1`.

**Scope**: 4 subtests + possibly several in `calc-z-index-fractions-001.html`.

**G9: Pure-numeric calc simplification at computed time.**
Evidence: `calc(2px + 3px)` as computed value for `background-position` should be `5px`. Currently returns `calc(2px + 3px)`. `resolveValueToPx` already computes the numeric result — the gap is in the **serialization** code path in `dom_style.zig` which returns the author string verbatim for non-length properties.

**Scope**: `calc-background-position-00{2,3}.html`, `getComputedStyle-calc-mixed-units-00{1,2,3}.html`.

**G10: `NaN`/`infinity` round-trip at specified time.**
Evidence: `calc(1s * NaN)` specified should serialize as `calc(NaN * 1s)` (normalized order: NaN first, unit last). Currently we return `undefined`.

**Scope**: `calc-infinity-nan-serialize-{angle,length,number,resolution,time}.html` (200 subtests).

**G11: Signed zero.**
Evidence: `sign(calc(-0)) = 0` (IEEE -0 is still sign 0 for CSS); `1 / sign(calc(-0)) = -∞` (not +∞). Requires f32-bit-level distinction of -0 vs +0 during evaluation.

**Scope**: `signed-zero.html` (162 subtests).

**G12: calc() dividing by zero produces `infinity` / `-infinity`, not error.**
Evidence: `calc(100px / 0) → calc(infinity * 1px)`. Current code does the float math (yields inf) but the serializer drops it.

**Scope**: `calc-catch-divide-by-0.html` (21 subtests).

---

## 4. Target Areas

### 4.1 Category A — Specified-value acceptance of math functions (largest ROI)

**Test files (17, sum ~1500 subtests)**:
- `minmax-{length,length-percent,number,integer,percentage,angle,time}-{computed,serialize}.html` (~440 subtests)
- `round-function.html`, `round-mod-rem-{computed,serialize}.html` (~458)
- `signs-abs-{computed,serialize}.html`, `signed-zero.html` (~411)
- `sin-cos-tan-computed.html`, `acos-asin-atan-atan2-{computed,serialize}.html` (~133)
- `hypot-pow-sqrt-{computed,serialize}.html`, `exp-log-{compute,serialize}.html` (~110)

**Failure pattern (G1+G2+G3)**: parser rejects the value at setProperty time; setter returns empty string; getter reads initial value; WPT compares strings and fails.

**Expected delta**: +1450 subtests.

### 4.2 Category B — calc() normalization + serialization

**Test files (~12, sum ~500 subtests)**:
- `calc-serialization.html`, `calc-serialization-002.html` (25)
- `calc-nesting.html`, `calc-nesting-002.html` (19)
- `calc-numbers.html` (12)
- `calc-unit-analysis.html` (10)
- `calc-letter-spacing.html` (6)
- `calc-z-index-fractions-001.html` (6)
- `calc-background-position-00{2,3}.html` (12)
- `calc-complex-unresolved-serialize.html` (12)
- `calc-infinity-nan-serialize-{angle,length,number,resolution,time}.html` (160)
- `calc-infinity-nan-computed.html` (48)
- `calc-catch-divide-by-0.html` (21)
- `getComputedStyle-calc-mixed-units-00{1,2,3}.html` (18)
- `typed_arithmetic.html` (35)

**Failure pattern (G4+G9+G10+G12)**: correct numeric resolution exists but serializer doesn't normalize form.

**Expected delta**: +380 subtests.

### 4.3 Category C — Font-relative and viewport-relative unit fidelity

**Test files (~8, sum ~80 subtests)**:
- `rem-unit-root-element.html` (4)
- `update-subpixel-rem-unit.html` (1)
- `rlh-on-root-lengths.html` (1)
- `lh-rlh-on-root-001.html` (8)
- `lh-unit-00{3,4,5}.html` (3)
- `viewport-units-parsing.html` (24)
- `various-values-important.html` (4)
- `percentage-without-context.html` last 2 failing subtests

**Failure pattern (G5+G6+G7)**: wrong base for `rem`/`lh`/`rlh`; missing `vi`/`vb`/`ic`/`cap` in parser.

**Expected delta**: +40 subtests (many subtests need font-load or navigation which is out of scope).

### 4.4 Category D — Integer interpolation rounding

**Test files (4, sum 4 subtests)**:
- `integer_interpolation_round_half_001.html`, `_002.html`, `_towards_positive_infinity_order.html`, `_towards_positive_infinity_z_index.html`

**Failure pattern (G8)**: CSS requires round-half-toward-positive-infinity, we use f32 `@round` which is half-away-from-zero.

**Expected delta**: +4 subtests.

### 4.5 Category E — Degenerate-value handling

**Test files (2, sum 183 subtests)**:
- `calc-infinity-nan-computed.html` (48)
- `signed-zero.html` (162; overlap with A counted above — 135 uniquely here)

**Failure pattern (G11+G12)**: signed zero and inf/NaN passthrough.

**Expected delta**: +130 subtests.

### 4.6 Category F — (out-of-scope for 3B) attr() / if() / inherit() / random() / sibling-* / calc-size / ident

Listed for completeness. Deferred to Waves 4-5.
`css/css-values` failing subtests in this group (`attr-*.html`, `if-*.html`, `inherit-function-*.html`, `random-*.tentative.html`, `tree-counting/*.html`, `calc-size/**`, `ident-function-*.html`, `progress-*.html`, `position/*.html`) total roughly 800 subtests. **Explicitly excluded from 3B** to keep scope.

**Total in-scope delta projection**: 1450 + 380 + 40 + 4 + 130 = **+2004 subtests**. Matches seed estimate.

---

## 5. Implementation Plan

### 5.1 Phase breakdown (ordered for risk control)

**Phase 3B.1 — Math-function parser acceptance (Category A)**
- File: `src/css/properties.zig` — for every per-property validator that takes a `<length>`, `<integer>`, `<number>`, `<angle>`, `<time>`, `<percentage>`, or `<length-percentage>`, add a front-door check: if `value` starts with one of `calc(`, `min(`, `max(`, `clamp(`, `round(`, `mod(`, `rem(`, `abs(`, `sign(`, `sin(`, `cos(`, `tan(`, `asin(`, `acos(`, `atan(`, `atan2(`, `pow(`, `sqrt(`, `hypot(`, `exp(`, `log(`, delegate to a shared `acceptMathFunction(value, expected_type)` helper that returns true if the function call is syntactically well-formed (matching parens, typed args).
- File: `src/css/cssom/style_decl.zig` — `setProperty` surface must pass through unparsed math-function strings to the per-property validator above.
- File: `src/css/parser.zig` — inline `<declaration>` grammar must accept math functions (already does for some properties via `parseLength` → `parseLengthValue` → `resolveValueToPxDepth` path; verify completeness).
- Unit tests (in `tests/test_properties.zig`): per property, assert `acceptMathFunction` true for representative math expressions of each return type.

**Gate**: `zig build test` passes; WPT `minmax-length-computed.html` passing > 0 (sentinel).

**Phase 3B.2 — Specified-value serialization (calc normalization)**
- New file: `src/css/computed_values.zig` — `pub fn normalizeSpecifiedCalc(input: []const u8, out: *std.ArrayList(u8)) !void`. Implements:
  - Parse math-function call into AST (reuse or extract from `cascade.zig:resolveCalcExprWithPct`).
  - Flatten nested `calc()`: `calc(calc(X)) → calc(X)`.
  - Collapse pure-numeric operations: `calc(20px + 80px) → calc(100px)`, `calc(2 * 50px) → calc(100px)`.
  - Sort terms: percentages, then absolute lengths (grouped), then font-relative (em, rem, ch, ex, ic, cap, lh, rlh), then viewport (vw, vh, vmin, vmax, svh, …). Alphabetical within group.
  - Render back to `calc(...)` string.
  - Special: single-arg `min(X)`/`max(X)` → `calc(X)`.
  - Special: preserve `NaN`, `infinity` as keywords in output: `calc(NaN * 1px)`.
- Integration: `src/css/cssom/style_decl.zig` — on set, store both the **author input** and the **normalized specified form** (for round-trip serialization).
- Integration: `src/js/dom_style.zig::resolveInlineForComputed` — if input is a math function, return the normalized specified form.
- Unit tests: 30+ cases covering every rule.

**Gate**: `calc-serialization.html`, `calc-nesting-002.html`, `calc-complex-unresolved-serialize.html` pass rate > 70%.

**Phase 3B.3 — Computed-value resolution + serialization**
- File: `src/js/dom_style.zig::computedStyleToStringWithBoxInner` — extend every property branch (z-index, scale, rotate, opacity, tab-size, width, height, margin-*, padding-*, etc.) so that if the value is a math function:
  1. Call `cascade_mod.resolveValueToPx(trimmed, font_size, vw, vh, pct_base)`.
  2. If fully numeric and unit-matched: serialize as a plain `<type>` value (e.g. `5px`, `1`, `0.5`, `1s`, `90deg`).
  3. If contains unresolved `%` + non-`%` terms: return normalized `calc(1px + 1%)` form via `normalizeSpecifiedCalc`.
  4. If `NaN`: return `0` (computed) for z-index/integer; `0px` for length; but `calc(NaN * 1px)` at specified time per §10.11.
  5. If `infinity`: clamp to property's allowable range (e.g. z-index max i32); for length, `3.4028235e+38`; for specified serialization, `calc(infinity * 1px)`.
- New helper: `fn serializeComputedMath(prop: []const u8, input: []const u8, ctx: ResolveCtx) ?[]const u8`.
- Update `src/css/cascade.zig` — in the cascade computed-style builder, for each property that stores as string (e.g. `flex-basis`, `transform`), call `normalizeSpecifiedCalc` once so subsequent reads don't re-normalize.
- Unit tests: known input → expected computed string, covering one test from each of the 17 WPT math files.

**Gate**: `minmax-length-serialize.html`, `round-mod-rem-serialize.html`, `signs-abs-serialize.html` pass > 70%.

**Phase 3B.4 — Unit fidelity: rem, lh, rlh, vi, vb, ic, cap**
- File: `src/css/values.zig` — add `ic`, `cap`, `rlh`, `vi`, `vb` to `Unit` enum.
- File: `src/css/cascade.zig::resolveLengthToPx` and `resolveLengthToPxWithPct` — extend switch:
  - `.rem` → root_font_size (new param; plumb from cascade builder)
  - `.rlh` → root_line_height_px (new param; plumb)
  - `.lh` → own line-height-px (new param; computed from `style.line_height` union)
  - `.ic` → own_font_size (1em approximation — good enough for T1 compliance)
  - `.cap` → own_font_size × 0.7
  - `.vi` → vw (horizontal-tb) or vh (vertical writing-mode; defer)
  - `.vb` → vh (horizontal-tb) or vw (vertical; defer)
- File: `src/css/cascade.zig::cascade` — thread `root_font_size_px` and `root_line_height_px` through recursion. These come from `root_style` which is known first in document-order cascade. Use a `ResolveContext` struct:
  ```zig
  pub const ResolveContext = struct {
      font_size_px: f32,
      line_height_px: f32,
      root_font_size_px: f32,
      root_line_height_px: f32,
      viewport_w: f32,
      viewport_h: f32,
      pct_base: f32,
  };
  ```
  Replace the 5-arg `resolveLengthToPxWithPct(value, unit, font_size, vw, vh, pct_base)` with `resolveLengthToPxCtx(value, unit, &ctx)`.
- File: `src/css/properties.zig::parseLength` — accept `ic`, `cap`, `rlh`, `vi`, `vb`.
- Unit tests: each new unit with known parent/root/viewport.

**Gate**: `rem-unit-root-element.html`, `lh-rlh-on-root-001.html`, `viewport-units-parsing.html` pass > 70%.

**Phase 3B.5 — Degenerate values and integer rounding**
- File: `src/css/cascade.zig::resolveCalcWithPct` — at IEEE-level, do not collapse `-0` to `+0`. Pass `@bitCast(f32, 0x80000000)` through `sign()`.
- File: `src/css/cascade.zig` — new helper `fn cssRoundToInteger(v: f32) i32`: if `v - floor(v) == 0.5`, result is `ceil(v)` (toward +∞); else `@round(v)` with ties-to-even replaced by ties-to-+∞.
- File: `src/js/dom_style.zig` — use `cssRoundToInteger` in all `z-index`, `order`, `reading-order` branches (lines 1360-1380).
- File: `src/css/cascade.zig::resolveCalcWithPct` — preserve `infinity`/`-infinity`/`NaN` through the computation; only at the final serialize step do we emit `calc(infinity * 1unit)` / `calc(-infinity * 1unit)` / `calc(NaN * 1unit)` form.
- File: `src/js/dom_style.zig::serializeComputedMath` — when resolving to degenerate values:
  - `NaN`: emit `0` for integer, `0px` for length at computed; `calc(NaN * 1px)` at specified time.
  - `±infinity`: emit clamped max/min for integer; `3.4028235e+38px` for length at used-value time; `calc(infinity * 1px)` at specified time.
- Unit tests: `sign(-0) = 0`, `1 / sign(calc(-0)) = -infinity`, `calc(0.5)` on z-index = 1 (toward +∞), `calc(-0.5)` = 0.

**Gate**: `integer_interpolation_round_half_001.html` passes; `signed-zero.html` passes > 50%; `calc-infinity-nan-computed.html` passes > 70%.

### 5.2 File-level change map

| File | Lines changed (est) | Kind |
|---|---:|---|
| `src/css/values.zig` | +30 | Add 5 units to enum |
| `src/css/computed_values.zig` | +600 | New module: calc AST, normalizer, serializer |
| `src/css/cascade.zig` | +150, -50 | Add unit cases; plumb ResolveContext; degenerate preservation |
| `src/css/properties.zig` | +200, -0 | Math-function front door per property validator; new units in `parseLength` |
| `src/css/parser.zig` | +30 | Math-function acceptance in declaration grammar |
| `src/css/cssom/style_decl.zig` | +50 | Plumb normalized specified form |
| `src/js/dom_style.zig` | +400, -50 | Math-function serialization per property; cssRoundToInteger; degenerate handling |
| `tests/test_properties.zig` | +400 | 60+ new property × math-function cases |
| `tests/test_css_all.zig` | +200 | 30+ normalizer round-trip cases |
| **Net LOC** | **+2060 add, ~-100 modify** | |

Binary growth estimate: ReleaseSafe ~55 MB today, `+2000 LOC pure Zig` ≈ +80 KB binary → within `<200KB` budget.

### 5.3 API surface additions

```zig
// In src/css/computed_values.zig
pub const MathNode = union(enum) {
    number: f32,
    length: Length,
    percentage: f32,
    operation: struct { op: enum { add, sub, mul, div }, lhs: *MathNode, rhs: *MathNode },
    func: struct { name: MathFuncName, args: []MathNode },
    degenerate: enum { nan, pos_inf, neg_inf },
};

pub const MathFuncName = enum { calc, min, max, clamp, round, mod, rem, abs, sign,
                                sin, cos, tan, asin, acos, atan, atan2,
                                pow, sqrt, hypot, exp, log };

pub const SerializeMode = enum { specified, computed };

pub fn parseMathFunction(input: []const u8, arena: std.mem.Allocator) !?*MathNode;
pub fn simplify(root: *MathNode, ctx: *const ResolveContext) void;
pub fn serialize(root: *const MathNode, mode: SerializeMode, out: *std.ArrayList(u8)) !void;
```

Integration points:
- `src/css/cssom/style_decl.zig::setProperty(prop, value)` → `parseMathFunction` on input; store normalized specified string alongside the raw AST.
- `src/js/dom_style.zig::computedStyleToStringWithBoxInner` → when the stored value is a math function, `simplify` with current cascade context, then `serialize(.computed)`.
- `src/js/dom_style.zig::resolveInlineForComputed` → `simplify(.., .{only_specified_time = true})` + `serialize(.specified)`.

---

## 6. Risks & Mitigations

**R1: 512MB RAM budget.**
MathNode AST allocates per `setProperty`. Mitigation: use per-declaration arena in `CSSStyleDeclaration` owned by the declaration; bulk-free on replace. Estimate: 100 bytes/AST node × 50 properties × 100 elements = 500 KB steady state — negligible vs 512 MB. No cache/pool needed yet.

**R2: Existing `resolveCalcWithPct` already works for length contexts; dual implementations could drift.**
Mitigation: `cascade.zig::resolveValueToPx` becomes a **thin wrapper** around the new `MathNode` AST path — parse once, evaluate once, discard AST. Single source of truth.

**R3: Inheritance chain for `rem`/`rlh` requires root-element computed style to exist before children.**
Mitigation: confirm via `src/css/cascade.zig::cascade` trace that root is always cascaded first. If not, two-pass cascade: pass 1 = root only; pass 2 = full tree with root font-size+line-height pinned into ResolveContext. Empirically already works (suzume serves main pages correctly with `:root { font-size: 14px }` → child `rem` correct) but the unit path hardcodes 16.0, so the bug is in `resolveLengthToPx` not in ordering. Fix is local.

**R4: CSS round-half-to-+∞ for integer interpolation.**
Mitigation: replace `@intFromFloat(@round(v))` with helper. Single file (`dom_style.zig`). Unit test against all 4 WPT subtests.

**R5: Term-sort order in calc() serialization might not match Chrome's exactly.**
WPT tests compare against Chrome's canonical serialization. Mitigation: prototype the sort in Phase 3B.2 and run `calc-serialization.html` locally; adjust sort key to match. Spec wording is loose here — "implementation-defined canonical form" — but Chrome's is the de-facto standard: percentages first, then absolute lengths, then relative lengths in alphabetical unit order.

**R6: Signed-zero (`sign(calc(-0)) = 0` but `1 / sign(calc(-0)) = -∞`).**
Requires distinguishing `+0` and `-0` in AST. Mitigation: keep f32 representation throughout; use `std.math.signbit` only; only collapse `-0 == 0` at final stringify time. Test against `signed-zero.html` first 10 subtests to validate approach.

**R7: Binary size.**
Estimate +80 KB of Zig code. Mitigation: compile with `-Doptimize=ReleaseSafe` and measure before commit; abort if > +200 KB. Most new code is data-driven (property-to-type table) which compresses.

**R8: Breaking existing sentinels.**
Wave 2 sentinels include `computed-style.html`, `basic-inheritance.html`, `all-properties.html`. Mitigation: Phase 3B.1 (parser acceptance) is purely additive — math functions that were rejected before are now accepted, but values that parsed before are unchanged. Phase 3B.2 changes specified-value serialization: existing CSS like `calc(20px)` already round-trips as `calc(20px)`. Risk cluster is at Phase 3B.3 (computed serialization) — add sentinel check there.

---

## 7. Acceptance Criteria

### 7.1 Gate 1 (plan-reviewable now — pre-implementation)

- [ ] Spec reviewed by Architect and Critic agents; sign-off recorded in plan.
- [ ] File-level change map (§5.2) reviewed.
- [ ] No architectural objection to `ResolveContext` struct replacing the 5-arg length resolver.
- [ ] `src/css/computed_values.zig` module boundary agreed (new file, not in cascade.zig).
- [ ] Phase order (§5.1) agreed: parser acceptance **first** (unlocks 1450 subtests with no serialization changes).
- [ ] Integration point list in §5.3 is exhaustive (no missed call sites).
- [ ] Unit test matrix in §5.1 covers: each math function × each return type × each property category.

### 7.2 Gate 2 (post-implementation, pre-commit)

- [ ] `zig build -Doptimize=ReleaseSafe` exits 0.
- [ ] `zig build test` exits 0 with all new unit tests passing.
- [ ] Binary size growth < 200 KB (measure: `stat -c %s zig-out/bin/suzume`).
- [ ] WPT `css/css-values` re-run with same config as Wave 2 Phase 0b (`TIMEOUT=90 --jobs 2 --port 9876`):
  - [ ] Subtest pass count ≥ 3099 (baseline 1099 + 2000 floor).
  - [ ] Per-category deltas documented in `.omc/research/2026-MM-DD-3b-measurement.md`:
    - [ ] Category A (math-function acceptance) ≥ +1400
    - [ ] Category B (calc normalization) ≥ +350
    - [ ] Category C (unit fidelity) ≥ +40
    - [ ] Category D (integer rounding) = +4
    - [ ] Category E (degenerate values) ≥ +130
  - [ ] No regression in any other area in the Wave 2 8-area baseline (`dom/nodes`, `css/css-color`, `css/cssom`, `css/selectors`, `dom/events`, `html/dom`, `webidl`).
  - [ ] `css/cssom/computed-style.html` Wave 2 sentinel — maintain or improve.
- [ ] 10 Wave 2 sentinel regression check: all maintain or improve.
- [ ] ADR authored with Decision, Drivers, Alternatives, Consequences.

---

## 8. Verification Steps

### 8.1 Unit tests (pre-WPT)

File: `tests/test_computed_values.zig` (new).

Cases (minimum 60, one per line):
```
// Specified-time serialization
normalize("min(1px)") == "calc(1px)"
normalize("min(1px, 2px)") == "min(1px, 2px)"
normalize("calc(calc(100px))") == "calc(100px)"
normalize("calc(20px + 80px)") == "calc(100px)"
normalize("calc(1vh + 2px + 3%)") == "calc(3% + 2px + 1vh)"
normalize("calc(1px * NaN)") == "calc(NaN * 1px)"
normalize("calc(100px / 0)") == "calc(infinity * 1px)"
normalize("calc(-100px / 0)") == "calc(-infinity * 1px)"

// Computed-time resolution (for z-index, scale, etc.)
compute("z-index", "calc(2.5 / 2)") == "1"
compute("z-index", "calc(-0.5)") == "0"
compute("z-index", "round(23, 10)") == "20"
compute("scale", "min(2, 3)") == "2"
compute("rotate", "min(90deg)") == "90deg"
compute("transition-delay", "min(1s)") == "1s"
compute("margin-left", "min(1px, 2px)") == "1px"
compute("margin-left", "min(1px + 1%, 2px)") == "calc(1px + 1%)"  // cb unknown
compute("margin-left", "sign(calc(-0))") == "0px"
compute("z-index", "sign(calc(-0))") == "0"
compute("scale", "pow(2, 3)") == "8"

// Font-relative with root override
compute_with_root_fs(":root { font-size: 10px }", "width", "2rem") == "20px"
compute_with_fs(20, "width", "1em") == "20px"
compute_with_lh(30, "height", "1lh") == "30px"

// Degenerate
compute("width", "calc(NaN * 1px)") == "0px"                // clamped at computed
specified("width", "calc(NaN * 1px)") == "calc(NaN * 1px)"  // preserved at specified
```

### 8.2 WPT measurement

Commands (matches Wave 2 Phase 0b):
```bash
cd /home/midasdf/suzume
export TIMEOUT=90
export SUZUME_JS=kotori
./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9876 css/css-values \
  > .omc/research/2026-MM-DD-wave3-3b-css-values.txt

# Spillover check
./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9877 css/cssom \
  > .omc/research/2026-MM-DD-wave3-3b-css-cssom.txt
./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9878 css/css-color \
  > .omc/research/2026-MM-DD-wave3-3b-css-color.txt

# Regression guard — 5 bellwether areas (non-CSS)
./tests/wpt/run_wpt_parallel.sh --jobs 2 --port 9880 dom/nodes \
  > .omc/research/2026-MM-DD-wave3-3b-dom-nodes.txt
```

### 8.3 Sentinel regression check

10 Wave 2 sentinels (from `/home/midasdf/suzume/.omc/research/2026-04-19-wave2-sentinel.txt`):
- `dom/nodes/Document-createElement.html`
- `dom/nodes/Document-createTextNode.html`
- `dom/nodes/MutationObserver-characterData.html`
- `css/cssom/computed-style.html`
- `css/cssom/getComputedStyle-pseudo.html`
- `css/css-color/parsing/color-computed-rgb.html`
- `css/css-values/calc-background-position-002.html` (target to flip)
- `css/selectors/selectors-attr-white-space-001.html`
- `dom/events/Event-dispatchEvent.html`
- `html/dom/interfaces.html`

Expected: 9 unchanged (pass or fail), 1 (`calc-background-position-002.html`) flipped to pass.

### 8.4 Binary-size check

```bash
stat -c %s zig-out/bin/suzume > /tmp/3b-post-size
# Compare to baseline 53302200
```

---

## 9. Open Questions

Persisted to `/home/midasdf/suzume/.omc/plans/open-questions.md`:

- [ ] **Q1**: Is the existing cascade pass guaranteed to process `:root` before children so `root_font_size_px` is stable when a child computes? (Architect to verify by tracing `src/css/cascade.zig::cascade`.)
- [ ] **Q2**: Should `normalizeSpecifiedCalc` preserve authoring precision (e.g. `calc(0.5 + 0.5)` → `calc(1)` or keep as is)? Chrome collapses; Firefox preserves. Pick Chrome for WPT match.
- [ ] **Q3**: `ic` / `cap` — stub with `1em` / `0.7em` for T1 compliance, or wire to font-cache glyph metrics? T1 stub is sufficient for every Category-C test file except `ch-*` (out of scope anyway).
- [ ] **Q4**: `vi` / `vb` — stub to `vw` / `vh` (horizontal-tb) or full writing-mode support? Stub is sufficient for the 18 parsing subtests; full support is follow-up layer.
- [ ] **Q5**: Signed-zero implementation — full IEEE -0 path or stub-match Chrome's output (may require matching their specific edge cases)? Start with full IEEE -0; if `signed-zero.html` < 50% pass rate, switch to Chrome-output-match mode.

---

## 10. References for Executor

Files to read before starting implementation:

- `src/css/computed.zig:1-200` — ComputedStyle struct, inheritance grouping comment
- `src/css/values.zig:1-217` — Unit enum (extend), Length struct, Value union
- `src/css/cascade.zig:2616-2759` — `resolveLengthToPx`, `resolveLengthToPxWithPct` (extend)
- `src/css/cascade.zig:2651-2728` — `resolveValueToPx`, `resolveValueToPxDepth` (wrap with AST)
- `src/css/cascade.zig:2770-2820` — `resolveCalcWithPct`, `resolveCalcExprWithPct` (refactor to AST)
- `src/css/cascade.zig:1224` — `style.font_size_px = parent.font_size_px;` (verify root handling)
- `src/css/cascade.zig:1430` — existing math-function dispatch in `font-size` resolver (pattern to extend)
- `src/css/properties.zig:1-200` — parseLength, parseLengthPercentage (add math-function front door)
- `src/css/parser.zig:1-200` — declaration grammar (verify math-function acceptance)
- `src/js/dom_style.zig:315-400` — `computedStyleToString*` entry points
- `src/js/dom_style.zig:1245-1490` — property-specific math-function handling in `resolveInlineForComputed`
- `src/js/dom_style.zig:1360-1380` — z-index / order / reading-order integer rounding (fix to round-half-toward-+∞)
- `src/js/dom_style.zig:2087-2130` — `getContainingBlockWidth`/`Height` (reuse for pct_base)
- `src/js/dom_style.zig:2762-2950` — `windowGetComputedStyle` (extend property table if needed)
- `src/js/web_api.zig:384-397` — viewport globals
- `tests/test_properties.zig` — existing property test pattern (follow for new tests)
- `.omc/research/wave2-baseline-css-css-values.txt:1-570` — failure inventory (primary reference)
- `.omc/research/2026-04-20-wave3-state-survey.md` — Wave 3 scope rationale
- `.omc/research/2026-04-19-wpt-baseline.md` — Wave 2 baseline figures
- WHATWG CSS Values 4 §4, §5, §6, §8, §10 — https://www.w3.org/TR/css-values-4/
- CSSOM § 6.1 (resolved value) — https://www.w3.org/TR/cssom-1/#resolved-values
