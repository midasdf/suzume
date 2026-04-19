# Layer 3D — CSS Color 4 Design Spec

**Date**: 2026-04-19
**Branch**: `feature/kotori-layer-3d-css-color`
**Target**: `tests/wpt css/css-color` — baseline 1.3% (70/5348)
**Spec**: CSS Color Module Level 4 — https://www.w3.org/TR/css-color-4/

---

## 1. Audit Finding: Parser Is Already Complete

A thorough audit of `src/css/properties.zig` found that CSS Color 4 parsing
is **already comprehensively implemented**. Coverage includes:

### 1.1 Color Functions (CSS Color 4 §4 — §8)

| Function | Legacy (comma) | Modern (space + `/`) | `none` keyword | calc() args |
| -------- | -------------- | -------------------- | -------------- | ----------- |
| `rgb()` / `rgba()` | ✅ `parseRgbFunc` | ✅ (via `tokenizeColorArgs`) | ✅ modern only | ✅ `resolveColorComponent` |
| `hsl()` / `hsla()` | ✅ `parseHslFunc` | ✅ | ✅ modern only | ✅ |
| `hwb()` | n/a | ✅ `parseHwbFunc` | ✅ | partial |
| `lab()` / `lch()` | n/a | ✅ `parseLabFunc` / `parseLchFunc` | ✅ | ✅ (via `formatModernColorImpl`) |
| `oklab()` / `oklch()` | n/a | ✅ `parseOklabFunc` / `parseOklchFunc` | ✅ | ✅ |
| `color()` | n/a | ✅ `parseColorFunc` | ✅ (via `formatColorFuncComputed`) | ✅ |
| `color-mix()` | ✅ (comma syntax) | n/a | n/a | n/a |
| `light-dark()` | ✅ `parseLightDarkFunc` | n/a | n/a | n/a |

### 1.2 Color Spaces (CSS Color 4 §6)

`color()` function dispatches on the colour space name at
`src/css/properties.zig:624`:

- `srgb` — pass-through (already gamma-corrected)
- `srgb-linear` — linear→gamma
- `display-p3` — matrix P3→sRGB linear, then gamma
- `a98-rgb` — Adobe RGB gamma conversion
- `prophoto-rgb` — simplified transfer
- `rec2020` — simplified transfer
- `xyz` / `xyz-d65` — matrix XYZ D65→sRGB linear
- `xyz-d50` — matrix XYZ D50→sRGB linear (Bradford-combined)

### 1.3 Named Colors (CSS Color 4 §9)

`named_color_table` at `src/css/properties.zig:1002` includes:

- 148 named colors (CSS Color 4 Appendix) including `rebeccapurple`
- `aqua`/`cyan`, `fuchsia`/`magenta`, `gray`/`grey` aliases
- 19 CSS system colors (light-mode defaults): `canvas`, `canvastext`,
  `linktext`, `visitedtext`, `buttonface`, `buttontext`, `buttonborder`,
  `field`, `fieldtext`, `highlight`, `highlighttext`, `selecteditem`,
  `selecteditemtext`, `mark`, `marktext`, `graytext`, `accentcolor`,
  `accentcolortext`, `activetext`
- 22 deprecated CSS 2 system color aliases per CSS Color 4 Appendix A
  (`activeborder`, `captiontext`, `menu`, `menutext`, `window`,
  `windowtext`, `threedface`, etc.) — each mapped to its CSS 4 equivalent

### 1.4 Hex Colors (CSS Color 4 §4.1)

`parseHexColor` handles 3/4/6/8 digit forms with proper alpha expansion.

### 1.5 Serialization (CSS Color 4 §15)

`src/js/dom_style.zig` implements canonical computed-value serialization:

- `argbToCssColor` — `rgb(r, g, b)` vs `rgba(r, g, b, a)` with alpha precision
  normalization (1/2/3 decimal places).
- `formatColorFuncComputed` — `color(space R G B)` and `color(space R G B / A)`
  with `none` preservation.
- `formatModernColorComputed` / `formatModernColorSpecified` —
  `lab()/lch()/oklab()/oklch()` with `none`, clamped L/C, normalized H,
  trimmed-decimal component formatting.
- `formatAsColorSrgb` — `color-mix()` serializes as `color(srgb ...)` per
  CSS Color 5 §2.1.

### 1.6 Legacy-Syntax Validation (CSS Color 4 §4.2)

`isValidColorValue` in `src/js/dom_style.zig:4936` enforces:

- `none` keyword forbidden in legacy comma syntax for `rgb/rgba/hsl/hsla`
- RGB legacy: all-% or all-number (no mixing)
- HSL legacy: S and L **must** be percentages
- `hwb()` **requires** modern syntax (no commas permitted)
- Max 4 arguments (rejects `rgb(0,0,0,0,0)`)
- Comments `/* ... */` stripped before reparse

### 1.7 Calc() Inside Color Functions

`isColorFuncWithCalc` (referenced in `dom_style.zig:4941`) accepts
`rgb(calc(50 + (sign(1em - 10px) * 10)), 0, 0)` and similar, deferring
resolution to computed-value time where font-relative units are known.

## 2. Baseline Measurement

Target subset: `css/css-color/parsing/color-valid-rgb.html` (70 subtests,
modern `none`, negative/out-of-range clamping, calc+sign).

Single-test run (kotori engine, `--wpt-mode`):
```
WPT_SUMMARY: PASS=0 FAIL=70 TOTAL=70
```

Every subtest fails with the same error shape:
```
expected (string) "rgb(0, 0, 0)" but got (undefined) undefined
```

The simpler `color-valid.html` (17 subtests) shows identical failures:
```
e.style['color'] = "red" should set the property value —
assert_equals: serialization should be canonical
  expected (string) "red" but got (undefined) undefined
```

## 3. Root-Cause Diagnosis

WPT `test_valid_value` (from `/css/support/parsing-testcommon.js`) runs:

```js
div.style[property] = value;
var readValue = div.style.getPropertyValue(property);
assert_not_equals(readValue, "");
assert_equals(readValue, serializedValue);
```

Running a minimal probe against our engine:

```js
d.style.color = 'red';
typeof d.style.getPropertyValue      // → "string"   (!)
d.style.getPropertyValue('color')    // → undefined  (!)
d.style.cssText                       // → "color: red;"  ✓
d.getAttribute('style')               // → "color: red;"  ✓
```

### 3.1 Cause

`element.style` is the `dom_style` kotori object built by
`createStyleObj` at `src/js/kotori_dom.zig:4337`. That factory:

```zig
fn createStyleObj(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_style }) catch return null;
    obj.data = .{ .dom_style = @ptrCast(elem) };
    return JsValue.initObject(obj);
}
```

It does **not** register any native methods. The sibling factory used for
`getComputedStyle` (line 2534) does call
`registerNativeMethod(obj, "getPropertyValue", &nativeCSSGetPropertyValue)` —
but the inline-style object is created separately without that wiring.

When JS evaluates `d.style.getPropertyValue`, `domStyleGetProp`
(src/js/kotori_dom.zig:1777) first checks own properties, then falls
through to `camelToKebab("getPropertyValue") → "get-property-value"`, a
CSS property lookup on the style attribute, which returns `""`. That
empty string is then **called as a function** — since `""` is not
callable, the call returns `undefined` (kotori's non-throwing call
semantics rather than raising TypeError like spec-compliant engines).

### 3.2 Why The Polyfill Doesn't Rescue

`src/js/web_api.zig:2503` defines:
```js
if (typeof CSSStyleDeclaration === 'undefined') {
  globalThis.CSSStyleDeclaration = function(){};
  CSSStyleDeclaration.prototype.getPropertyValue = function(n){ return this[n] || ''; };
  ...
}
```

The dom_style kotori object is **not** `instanceof CSSStyleDeclaration`
and its prototype chain does not include `CSSStyleDeclaration.prototype`,
so the polyfill never applies. `dom_api.zig:6068` defines a richer
CSSStyleDeclaration polyfill, but again only for JS-constructed decls
(rule-level), not for element.style.

### 3.3 Impact On CSS Color 4 WPT Layer

Every parsing test in `tests/wpt/css/css-color/parsing/` uses
`div.style[prop] = value; div.style.getPropertyValue(prop)`. Every
computed-value test uses `getComputedStyle(target)[property]` but first
gates on `CSS.supports(property, specified)` which returns `false` for
most CSS Color 4 grammar (our polyfill hardcodes a ~100-entry property
name allowlist and ignores the value argument).

Net effect: the **parser and serialiser are correct**, but the tests
never reach the code paths under test because they cannot round-trip
through `element.style.getPropertyValue()`.

## 4. Scope Resolution

The fix is a **one-line change** inside `src/js/kotori_dom.zig`
`createStyleObj` — register `getPropertyValue`, `setProperty`,
`removeProperty`, `getPropertyPriority` and `item()` native methods on
the inline style object the same way `createComputedStyleObj` already
does.

However, `src/js/kotori_dom.zig` is explicitly excluded from this
layer's scope per the task brief:

> DO NOT touch … `src/js/kotori_dom.zig` (Layer 4A)

`src/css/cssom/style_decl.zig` (where a structured
CSSStyleDeclaration lives) is also excluded (Layer 3A).

Therefore Layer 3D **cannot** realise the headline +5000 subtests
advertised in the master roadmap. The parser work is already done; the
blocker is entirely in DOM ↔ JS plumbing that belongs to a different
layer.

## 5. Recommended Next Steps

1. **Layer 4A follow-up task** — register
   `getPropertyValue/setProperty/removeProperty/getPropertyPriority/item`
   on the inline style object in `createStyleObj`. Expected to unlock
   the bulk of the `css/css-color/parsing/*` suite in a single commit.
2. **Layer 3A follow-up task** — replace the `web_api.zig`
   property-name allowlist for `CSS.supports(prop, val)` with a genuine
   value validation path that delegates to `dom_style.isValidColorValue`
   for colour properties. Unlocks the `css/css-color/parsing/color-computed-*`
   suite which currently dies at `CSS.supports`.
3. **CSS Color 5/6 extensions** once the above blockers clear:
   - `contrast-color()` (CSS Color 6)
   - Relative colour syntax: `rgb(from red r g b)`, `oklch(from X calc(l + 10%) c h)`
   - Additional hue interpolation modes for `color-mix`: `shorter`, `longer`, `increasing`, `decreasing`

## 6. Spec References

- CSS Color 4 §4 (sRGB colour functions)
- CSS Color 4 §5 (Interpolation)
- CSS Color 4 §6 (Predefined colour spaces)
- CSS Color 4 §9 (Named colours)
- CSS Color 4 §15 (Serialisation)
- CSS Color 4 Appendix A (Deprecated system colours)
- CSSOM §6.7 (CSSStyleDeclaration interface)
