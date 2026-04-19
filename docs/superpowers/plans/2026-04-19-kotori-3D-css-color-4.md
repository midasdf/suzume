# Layer 3D — CSS Color 4 Implementation Plan

**Spec**: `docs/superpowers/specs/2026-04-19-kotori-3D-css-color-4-design.md`
**Branch**: `feature/kotori-layer-3d-css-color`

## Phase 0 — Audit (done)

Result: CSS Color 4 parser and serialiser in `src/css/properties.zig` +
`src/js/dom_style.zig` are already essentially complete. See spec §1.

## Phase 1 — Blocker Documentation (this layer)

**Deliverables**:
- Design spec capturing audit result and blocker analysis.
- This plan.
- No code changes — the constraint envelope excludes every file that
  would unlock the target tests.

## Phase 2 — Deferred To Future Layers

These tasks would move the WPT needle but touch off-limits files:

### Phase 2A — Layer 4A: wire up inline CSSStyleDeclaration

**File**: `src/js/kotori_dom.zig` (off-limits for Layer 3D)

Change `createStyleObj` to mirror `createComputedStyleObj`:

```zig
fn createStyleObj(vm: *VM, elem: *lxb.lxb_dom_element_t) ?JsValue {
    const obj = vm.createObj(.{ .obj_type = .dom_style }) catch return null;
    obj.data = .{ .dom_style = @ptrCast(elem) };
    vm.registerNativeMethod(obj, "getPropertyValue", &nativeInlineGetPropertyValue) catch {};
    vm.registerNativeMethod(obj, "setProperty", &nativeInlineSetProperty) catch {};
    vm.registerNativeMethod(obj, "removeProperty", &nativeInlineRemoveProperty) catch {};
    vm.registerNativeMethod(obj, "getPropertyPriority", &nativeCSSGetPropertyPriority) catch {};
    vm.registerNativeMethod(obj, "item", &nativeInlineItem) catch {};
    return JsValue.initObject(obj);
}
```

Bodies delegate to the existing `dom_api.zig:styleGetPropertyValue` and
`style_decl.zig` logic already used by the QuickJS path at
`src/js/dom_api.zig:1171`. Expected: most of `css/css-color/parsing/*`
flips from 0% to 70–90% pass.

### Phase 2B — Layer 3A: CSS.supports value validation

**File**: `src/js/web_api.zig` (NOT off-limits, but out of Layer 3D
charter which caps at colour parser work).

Replace the hardcoded allowlist in the `CSS.supports` polyfill with a
native-backed validator that calls into `dom_style.isValidColorValue`
and the existing `dom_style.isSupportedCssProperty` table. Unlocks
`color-computed-*` and `color-invalid-*`.

### Phase 2C — Layer 3D-follow: CSS Color 5/6 parser additions

Only meaningful after Phase 2A/2B land. Candidate work once tests can
reach the parser:

1. `contrast-color(<color>)` — CSS Color 6 (WPT file:
   `color-valid-contrast-color-function.html`, ~30 subtests).
2. Relative colour syntax — CSS Color 5 §4.1
   (`color-valid-relative-color.html`, ~200 subtests). Requires a new
   mini-resolver that maps `r g b alpha` back into their source colour
   space components; large but self-contained in
   `src/css/properties.zig`.
3. Hue interpolation methods — `shorter hue`, `longer hue`,
   `increasing hue`, `decreasing hue` (CSS Color 5 §12.3). Modify
   `interpolateHue` in `src/css/properties.zig`.

## Phase 3 — Exit Criteria for Layer 3D

Because Phase 1 is documentation-only and Phases 2A/2B/2C are out of
scope, Layer 3D is considered complete when:

- [x] Spec filed at `docs/superpowers/specs/2026-04-19-kotori-3D-css-color-4-design.md`
- [x] Plan filed at `docs/superpowers/plans/2026-04-19-kotori-3D-css-color-4.md`
- [x] Branch `feature/kotori-layer-3d-css-color` created
- [x] Baseline `css/css-color/parsing/color-valid-rgb.html` captured
      (0/70 pass — blocker not our parser)
- [x] Root cause identified and escalated to Layer 4A owners

## Phase 4 — Verification Evidence

Single-shot evidence captured on branch head (no `.zig` changes, so
build state matches `master`):

```
$ timeout 30 env SUZUME_JS=kotori ./zig-out/bin/suzume --wpt-mode \
    "http://127.0.0.1:9999/css/css-color/parsing/color-valid.html"
...
WPT_SUMMARY: PASS=0 FAIL=17 TOTAL=17
```

Every failure: `got (undefined) undefined` — confirms blocker is
`style.getPropertyValue()` returning `undefined`, not a parser bug.

Probe confirming root cause:
```
typeof d.style.getPropertyValue = string
d.style.getPropertyValue('color') = null   (should be "red")
d.style.cssText = "color: red;"            (already correct)
```
