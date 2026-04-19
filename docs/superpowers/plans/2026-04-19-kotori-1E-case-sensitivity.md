# Layer 1E Plan — Case Sensitivity in `setAttribute` / `getAttribute`

**Spec**: `docs/superpowers/specs/2026-04-19-kotori-1E-case-sensitivity-design.md`
**Branch**: `feature/kotori-layer-1e-case` (off `main`)
**File scope**: `src/js/dom_element.zig` only.
**Off-limits (parallel branches)**:
`src/js/dom_document.zig`, `src/js/dom_selector.zig`, `src/js/events.zig`,
`src/js/kotori_dom.zig`, `src/js/kotori/regex.zig`.

## Phase-0 — Branch & Baseline

- [x] `git checkout -b feature/kotori-layer-1e-case main`
- [x] Run baseline against `dom/nodes/case.html` → `PASS=135 FAIL=150 TOTAL=285`
- [x] Confirmed all 150 failures live in off-limits files (see spec §3)

## Phase-1 — Helper

Commit 1: `feat(kotori-1E): add isXmlDocumentForElement helper`

- [ ] Add `isXmlDocumentForElement(ctx, this_val) bool` near top of
      `dom_element.zig` (after the existing `StringSlice` helpers).
- [ ] Reads `this.ownerDocument._isXmlDoc`; returns `false` on null/undefined.
- [ ] `zig build` green.

## Phase-2 — setAttribute

Commit 2: `feat(kotori-1E): preserve case in XML documents for setAttribute`

- [ ] In `elementSetAttribute`, gate `lowercaseAttrName` on the helper.
- [ ] `zig build` green.

## Phase-3 — getAttribute / hasAttribute

Commit 3: `feat(kotori-1E): case-sensitive getAttribute/hasAttribute in XML`

- [ ] Same gating for `elementGetAttribute` and `elementHasAttribute`.
- [ ] `zig build` green.

## Phase-4 — removeAttribute / toggleAttribute

Commit 4: `feat(kotori-1E): case-sensitive removeAttribute/toggleAttribute in XML`

- [ ] Apply the gating to `elementRemoveAttribute` and
      `elementToggleAttribute` so set / remove / query are symmetric.
- [ ] `zig build && zig build test` green.

## Phase-5 — Verification

- [ ] Re-run baseline against `dom/nodes/case.html` — must not regress HTML
      subtests.
- [ ] Optionally sample `Document-getElementsByTagName-xhtml.xhtml` for upside.

## Phase-6 — Merge

- [ ] Fast-forward merge into `main` once all branches in Layer 1 land.

## Notes

- DO NOT touch `dom_api.zig`’s `__buildAttr` closure — it already gates on
  `_isXmlDoc`; duplicating the gate in native would regress XML-document
  attribute creation.
- DO NOT rewrite `lowercaseAttrName` — other callers outside this file
  rely on the unconditional form.
