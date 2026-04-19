# Kotori Layer 4A — HTML Reflected Attributes (Plan)

Status: in-progress
Owner: kotori
Spec: `docs/superpowers/specs/2026-04-19-kotori-4A-html-reflection-design.md`
Branch: `feature/kotori-layer-4a-reflection`
Target: +3000 WPT subtests in `html/dom`.

## File scope

* **New**: `src/js/html_reflection.zig`
* **Touched**: `src/js/kotori_dom.zig` (prototype wiring + dispatch hook)

Off-limits (locked by other active waves):
`src/js/events.zig`, `src/js/dom_element.zig`, `src/js/dom_document.zig`,
`src/js/dom_selector.zig`, `src/js/dom_style.zig`, `src/css/*`,
`src/js/kotori/*.zig`.

## Implementation phases (each = one commit, build + test green)

### Phase 1 — Scaffold `html_reflection.zig`

* Create `src/js/html_reflection.zig` with `ReflType`, `ReflectedAttr`,
  `table` (empty for now), and a `pub fn lookup(iface, idl) ?*const
  ReflectedAttr`.
* Add `const refl = @import("html_reflection.zig");` to `kotori_dom.zig`
  (unused — zero behavior change).
* `zig build` green.

### Phase 2 — Dispatcher hook

* In `kotori_dom.zig` add a `resolveHtmlIfaceForNode` helper that reads
  the element's qualified name + namespace and calls
  `kotori_html_interfaces.resolveInterface`. Cache result per wrapper
  object via a hidden slot.
* In `domNodeGetProp` / `domNodeSetProp`, after the existing `id` and
  `className` inline rules, call `refl.lookup`; on hit dispatch per
  `ReflType`.
* Implement the five type paths plus an integer parser conforming to
  HTML §2.4.4.1 / §2.4.4.2 (ASCII digits, optional leading sign for
  signed, clamped to i32).
* Still zero reflections in the table, so behavior unchanged; `zig
  build test` green.

### Phase 3 — HTMLElement core reflections

Add rows: `id` (kept for parity — the inline fast-path remains as a
short-circuit), `className`, `title`, `lang`, `dir`, `hidden`, `tabIndex`,
`accessKey`, `draggable`, `contentEditable`, `spellcheck`, `translate`,
`autocapitalize`, `slot`, `nonce`. Spec cites: HTML §3.2.6 (global attrs),
§6.6 (`tabIndex`: long, default -1 when focusable, else -1 per HTML 2023
clarification).

### Phase 4 — Link / navigation / media URL attributes

HTMLAnchorElement (8), HTMLAreaElement (9), HTMLBaseElement (2),
HTMLLinkElement (10), HTMLIFrameElement (11), HTMLObjectElement (6),
HTMLEmbedElement (4), HTMLSourceElement (7), HTMLTrackElement (5).

### Phase 5 — Form control reflections

HTMLFormElement (10), HTMLInputElement (~28), HTMLButtonElement (9),
HTMLSelectElement (7), HTMLOptionElement (4), HTMLTextAreaElement (12),
HTMLOutputElement (2), HTMLFieldSetElement (2), HTMLLabelElement (1),
HTMLOptGroupElement (2).

### Phase 6 — Media / metadata / misc reflections

HTMLImageElement (12), HTMLScriptElement (9), HTMLStyleElement (3),
HTMLMetaElement (4), HTMLMediaElement (7), HTMLVideoElement (4),
HTMLTableElement+cells+rows+cols (~10), HTMLDetailsElement (2),
HTMLDialogElement (1), HTMLMapElement (1), HTMLParamElement (4),
HTMLQuoteElement/ModElement (3).

### Phase 7 — WPT sweep + merge

Run the final baseline and diff before/after numbers; record in this
plan. Merge `feature/kotori-layer-4a-reflection` → `main`.

## Verification

Each phase:
1. `zig build`
2. `zig build test`
3. `git commit -m "..."`

Final:
4. `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9884 html/dom`

## Results (to fill in)

* Baseline (main): TBD pass / TBD subtests
* Post Layer 4A: TBD pass / TBD subtests
* Delta: TBD subtests
