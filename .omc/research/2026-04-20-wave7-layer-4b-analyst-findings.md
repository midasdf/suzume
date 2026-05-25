# Wave 7 Layer 4B Analyst Findings (pre-spec gating)

**Date**: 2026-04-20
**Source**: Analyst agent (opus)
**Status**: READ-ONLY findings — spec authorship deferred until open questions resolved

---

## Critical Discovery

Layer 4B is **NOT greenfield** — substantial form-control infrastructure already exists and is scattered across existing modules. Writing the spec as greenfield is the single largest risk.

### Pre-existing form infrastructure

| Location | Lines | What | Engine |
|----------|-------|------|--------|
| `src/js/dom_element.zig` | 2567-2787 | formSubmit, formRequestSubmit, formCheckValidity, formReportValidity, formControlCheckValidity, formControlReportValidity, formControlSetCustomValidity — **native C functions** | **QuickJS** |
| `src/js/kotori_dom.zig` | 3889-3918 | Prototype wiring for form control validation methods | kotori |
| `src/js/kotori_dom.zig` | 3924-4232 | **Huge JS polyfill**: willValidate, ValidityState (8 flags), validationMessage, form.elements, disabled/checked/selected/autofocus reflection | kotori (JS polyfill) |
| `src/js/html_reflection.zig` | 108-469 | HTMLInputElement 29 attrs, HTMLFormElement 9, HTMLSelectElement 6, HTMLTextAreaElement, HTMLButtonElement 11, HTMLOptionElement 4, HTMLOptGroupElement 2, HTMLFieldSetElement 2, HTMLLabelElement, HTMLOutputElement | Layer 4A (done) |
| `src/js/kotori_html_interfaces.zig` | 33, 57, 74, 93, 110, 124 | tag→interface mapping for button/form/input/option/select/textarea | complete |

## Engine duality issue

Existing form natives are **QuickJS-flavored** (`qjs.JS_NewCFunction`, `quickjs.JS_UNDEFINED()`) but kotori uses a different dispatch model (`domNodeGetProp`). Must resolve which engine hosts Layer 4B before writing spec.

## Open Questions (blockers for spec authorship)

1. **Which JS engine backs Layer 4B?** kotori vs QuickJS — reshapes file layout, calling conventions, prototype wiring.
2. **Pre-work WPT baseline for `html/semantics/forms/*`?** Brief cites html/dom 22.4% but target area is html/semantics/forms (different path).
3. **Does Layer 4B own `html/semantics/forms/*` or `html/dom/reflection-forms-*`?** 4A already targets the latter.
4. **How to treat existing QuickJS-based formSubmit/formCheckValidity/ValidityState polyfill?** Rewrite, keep, or port?
5. **Base commit/tag?** Must pin to post-Phase-6.2 merge to main.
6. **Is FormData in scope?** References HTML §4.10.21.4, used by many WPT tests.
7. **Form submission navigation?** Existing formSubmit commented "Navigation / network layer is not yet wired".
8. **`value` IDL attribute strategy?** §4.10.5.3 has value/defaultValue/dirty-value-flag — not simple reflection. 4A spec explicitly excluded.
9. **Which `<input>` types tier-1?** text/password/hidden trivial; checkbox/radio need `checked`/`defaultChecked`; file/color/date/number/range/email/url need sanitization + per-type validity.
10. **Focus management delegate?** How is focus plumbed through kotori for headless WPT?

## Recommended re-slicing (post-question-answers)

Proposed sub-layers avoiding duplication with 4A:

- **4B.1**: `<input>` value/checked state machine (dirty-value-flag, defaultValue/defaultChecked split, type-change reset) — NEW WORK ONLY.
- **4B.2**: ValidityState native-ization — migrate polyfill `kotori_dom.zig:3924-4007` to `html_form.zig`, preserving slot names.
- **4B.3**: HTMLFormElement.elements live collection (replacing polyfill snapshot `4007-4022`) + form-attribute cross-association.
- **4B.4**: HTMLSelectElement.options / selectedIndex / selectedOptions + HTMLOptionElement defaultSelected.
- **4B.5**: HTMLTextAreaElement value/defaultValue + textLength getter.
- **4B.6**: submit/reset/change/input event semantics — confirm SubmitEvent constructor registration; wire reset event cancellation.

**First shippable cut**: 4B.2 + 4B.4 (highest WPT ROI in `constraints/` + `the-select-element/`). Target ~1200 LOC for the cut.

## Merge-conflict risk with Wave 6 Phase 6.2

- Wave 6.2 edits `kotori_dom.zig::domStyleGetProp` (lines ~3780)
- 4B touches prototype registration lines 3889-3918 + polyfill 3924-4232
- **Overlap low-to-moderate**, but 4B MUST land AFTER Wave 6.2 merges to main, then rebase-verify.

## Sentinel WPT files (candidate — must be confirmed to exist)

- `html/semantics/forms/the-input-element/input-type-attribute.html`
- `html/semantics/forms/the-input-element/input-value.html`
- `html/semantics/forms/the-select-element/select-options.html`
- `html/semantics/forms/the-select-element/selectedIndex.html`
- `html/semantics/forms/the-textarea-element/textarea-type.html`
- `html/semantics/forms/the-form-element/form-elements-nameditem.html`
- `html/semantics/forms/constraints/form-validation-checkValidity.html`
- `html/semantics/forms/constraints/form-validation-validity-valueMissing.html`
- `html/semantics/forms/constraints/form-validation-setCustomValidity.html`
- `html/semantics/forms/resetting-a-form/reset-form.html`

## Proposed ALLOWED/FORBIDDEN (Wave 6 Phase 6.2 rubric)

**ALLOWED NEW**:
- `src/js/html_form.zig`
- `tests/test_kotori_form.zig`

**ALLOWED EDIT**:
- `src/js/kotori_dom.zig` (prototype-registration section only, lines 3889-3920; polyfill block 3924-4232 for REPLACEMENT only)
- `src/js/kotori_html_interfaces.zig` (no new rows expected)
- `src/js/html_reflection.zig` (only to split dirty-value-flag attributes out of pure-reflection table)
- `tests/test_kotori_dom.zig` for existing-test extension

**FORBIDDEN**:
- `src/js/kotori/compiler.zig`
- `src/js/kotori/bytecode.zig`
- `src/js/kotori/vm.zig`
- `src/js/kotori/object.zig`
- `src/js/events.zig`
- `src/js/shadow_root.zig`
- `src/js/dom_node.zig`
- `src/js/dom_document.zig`
- `src/js/dom_style.zig`
- `src/css/**`
- `src/main.zig`
- `src/js/dom_api.zig`
- `src/js/dom_element.zig` (existing form natives — port intent lives in `html_form.zig`)

## Action items before 4B spec authorship

1. Resolve kotori vs QuickJS engine question (block #1)
2. Measure `html/semantics/forms/*` baseline under `SUZUME_JS=kotori`
3. Decide FormData scope
4. Wait for Wave 6 Phase 6.2 to merge to main, pin spec base tag
5. Re-dispatch spec author with filled-in answers
