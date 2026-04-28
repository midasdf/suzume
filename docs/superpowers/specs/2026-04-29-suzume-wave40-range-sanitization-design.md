# Wave 40 — type=range value sanitization (kotori)

**Date**: 2026-04-29
**Branch**: `main` (post-Wave 39, commit `a4e6dae`)
**Spec anchor**: HTML §4.10.5.1.13 (range state value sanitization)

## Problem

`html/semantics/forms/the-input-element/range.html` is **15/25 (60%)** under
kotori. The 10 failing subtests all stem from the same gap: input type=range
has **no value sanitizer** registered. Today, `_sanByType` falls through to
`return null;` for `it === 'range'`, so the value getter returns the raw
attribute value verbatim.

This blocks:

- `range.html` 10 subtests (clamping, default value, step alignment).
- `type-change-state.html` 7 "to range" cases (input keeps old text after
  type change instead of snapping to range default).
- Any downstream test that relies on `input.type='range'; input.value=…`
  producing canonical output.

## Goal

Implement `_sanRange(rawValue, el)` per HTML §4.10.5.1.13 and wire it into
`_sanByType`. No type-setter changes — the value getter already invokes
`_sanByType` on each read, so type-change re-sanitization is automatic.

## Design

### Component A — `_sanRange` JS polyfill

Insertion point: `src/js/kotori_runtime.zig`, immediately after `_sanNumber`
(currently around line 3365).

```js
// Per HTML §4.10.5.1.13 (Range): clamp to [min,max], snap to step base.
// Default min=0, max=100, step=1. If value is not a valid floating-point
// number, set to the best representation of the default value.
function _sanRange(v, el) {
  if (typeof v !== 'string') return '';
  // Parse min/max/step attributes, fall back to spec defaults.
  function _f(name, dflt) {
    var a = el && el.getAttribute && el.getAttribute(name);
    if (a == null) return dflt;
    if (!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(a)) return dflt;
    var n = parseFloat(a);
    return isFinite(n) ? n : dflt;
  }
  var min = _f('min', 0);
  var max = _f('max', 100);
  var step = _f('step', 1);
  if (step <= 0) step = 1;

  // Default value: midpoint, or min if max < min.
  function _default() {
    return (max >= min) ? (min + (max - min) / 2) : min;
  }

  // Validate float syntax (HTML's "valid floating-point number" rejects
  // leading whitespace and other forms parseFloat would tolerate).
  var n;
  if (!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v)) {
    n = _default();
  } else {
    n = parseFloat(v);
    if (!isFinite(n)) n = _default();
  }

  // Clamp to [min, max].
  if (max >= min) {
    if (n < min) n = min;
    if (n > max) n = max;
  } else {
    n = min; // max < min: spec says default = min, no upper clamp.
  }

  // Step alignment (snap to nearest min + k*step).
  var diff = n - min;
  var k = Math.round(diff / step);
  var snapped = min + k * step;
  if (max >= min && snapped > max) {
    // Snap down to the largest valid step boundary <= max.
    var k2 = Math.floor((max - min) / step);
    snapped = min + k2 * step;
  }
  n = snapped;

  // FP normalization: round to a safe decimal precision derived from
  // step + min so e.g. 5.3 + 1*0.5 doesn't surface as "5.799999...".
  function _decimals(x) {
    var s = String(x);
    var i = s.indexOf('.');
    return i < 0 ? 0 : (s.length - i - 1);
  }
  var prec = Math.max(_decimals(step), _decimals(min), _decimals(max));
  if (prec > 0) {
    n = parseFloat(n.toFixed(Math.min(prec + 2, 12)));
  }
  return String(n);
}
```

### Component B — Dispatcher wiring

Add one line to `_sanByType` (currently at line ~3391):

```js
if (it === 'range') return _sanRange(raw, el);
```

Insertion order: between `if (it==='number')...` and `if (it==='url')...`,
matching the order types appear in the HTML spec.

### Component C — Type-setter re-sanitization (NO CHANGE)

The existing `value` getter already invokes `_sanByType(currentType, raw, el)`
on every read. When `input.type` changes via the type setter (which only
calls `setAttribute('type', …)`), the next `input.value` read picks up the
new type and re-sanitizes naturally. **No changes needed** to the type
setter at line 3689.

This is the key insight that makes Wave 40 a pure-additive change.

## Spec citations

- **HTML §4.10.5.1.13** (Range state — value sanitization algorithm):
  https://html.spec.whatwg.org/multipage/input.html#range-state-(type=range)
- **HTML §2.4.4.3** (rules for parsing floating-point number values).
- **HTML §4.10.5.5.4** (default minimum/maximum: 0 / 100 for range).
- **HTML §4.10.5.5.7** (default step / step base for range = 1 / min).

## WPT impact

| File | Before | After (target) | Δ |
|------|--------|----------------|---|
| `the-input-element/range.html` | 15/25 | **25/25** | +10 |
| `the-input-element/type-change-state.html` | 262/380 | **269/380** | +7 |
| `the-input-element` (area pass rate) | 79.8% | **~80.5%** | +0.7pt |

### Specific range.html tests fixed

1. `value_smaller_than_min` — clamp `-10` → `0`
2. `value_larger_than_max` — clamp `7` → `5`
3. `value_not_specified` — default `(2+6)/2 = 4`
4. `control_step_mismatch` — default `(0+7)/2=3.5`, step=2 base=0 → `4`
5. `max_smaller_than_min` — `min > max` → default = min = `2`
6. `default_step_scale_factor_1` — step=1, base=5, 6.7 → `7`
7. `default_step_scale_factor_2` — step=1, base=5.3, 6.7 → `6.3`
8. `float_step_scale_factor` — step=0.5, base=5.3, 6.7 → `6.8`
9. `should_skip_whitespace` — `" 123"` invalid → default = `50`
10. `illegal_value_and_step` — min=0, max=5, value=`"ppp"`, step=`"xyz"`: invalid step → default 1, invalid value → default `(0+5)/2 = 2.5`, snap 2.5/1 → `"3"`

### type-change-state.html "to range" cases

For each `from_type → to_type=range` pair where the source produced any
value, the value should sanitize to `"50"` after the type change. This
relies on the value getter re-evaluating `_sanByType` after the type
changes — already wired up.

## Risks

| Risk | Mitigation |
|------|-----------|
| FP precision drift (`5.3 + 1*0.5` → `5.799999...`) | `toFixed(prec+2)` → `parseFloat` round-trip caps display precision |
| `step="any"` behavior | `parseFloat("any")` = NaN → falls through `_f` default = 1, snap still works (no-op for typical values) |
| Edit-tool LF corruption (Wave 36 lesson #74) | Write LF/CR Unicode escapes (12 ASCII bytes, no raw control chars) inside Zig multi-line strings; verify `command grep -n` does not report "binary file matches" after edit |
| Canary regression (Node-contains, compareDocumentPosition) | Re-run after build, pre-commit gate |
| Other `_sanByType` types regress | Pure additive change; existing branches untouched |
| Build break | `zig build --libc /tmp/libc.txt` REQUIRED on this host |

## Implementation order

1. Read `_sanNumber` (lines 3359-3365) for reference structure.
2. Insert `_sanRange` block in `kotori_runtime.zig` after `_sanNumber`.
3. Add dispatcher line in `_sanByType`.
4. `zig build --libc /tmp/libc.txt 2>&1 | tail -3` — must be clean.
5. Smoke test: `range.html` (target 25/25).
6. Smoke test: `type-change-state.html` (target +7).
7. Canary: `Node-contains.html`, `Node-compareDocumentPosition.html`.
8. Area run: `the-input-element` (target ≥80% pass rate).
9. Commit as `feat(forms|kotori): type=range value sanitization (Wave 40)`.
10. Tag `wave40-final` (local-only, do not push per project convention).

## Out of scope (deferred to later waves)

- type=file value=null short-circuit → Wave 41
- selectionStart=0 after type change → Wave 42
- valueMode.html investigation → measure with longer timeout first
- input-type-change-submit.html (0/20) → form-state preservation, separate scope
- defaultValue-clobbering.html → setAttribute('value') vs `.value=` timing investigation

## Smoke command snippets

```bash
# Build (libc.txt is REQUIRED on this host)
cd /home/midasdf/suzume
zig build --libc /tmp/libc.txt 2>&1 | tail -3

# Single-file smoke
DISPLAY=:98 SUZUME_JS=kotori timeout 25 \
    /home/midasdf/suzume/zig-out/bin/suzume \
    --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/range.html" \
    2>&1 | grep WPT

# Type-change cross-product
DISPLAY=:98 SUZUME_JS=kotori timeout 60 \
    /home/midasdf/suzume/zig-out/bin/suzume \
    --wpt-mode "http://127.0.0.1:9876/html/semantics/forms/the-input-element/type-change-state.html" \
    2>&1 | grep WPT_SUMMARY

# Area pass rate
TIMEOUT=90 bash tests/wpt/run_wpt_parallel.sh --jobs 2 \
    html/semantics/forms/the-input-element \
    2>&1 | grep -E "Test files|Subtests|Pass rate"
```
