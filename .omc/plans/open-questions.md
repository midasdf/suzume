## Layer 1B MutationObserver Completion - 2026-04-19

- [ ] **[1B-Q1]** Does the kotori-VM `data=` setter route through `recordCharDataMutation`? — Gate answer from P0 Step 0.5 before Task 3; blocks whether Task 3 scope is 4 natives only or 4 natives + setter.
  - **Resolution (P0 audit)**: No direct kotori `data=` setter exists in `kotori_dom.zig`. CharacterData.data is handled only via the 4 native methods (`nativeAppendData`/`nativeDeleteData`/`nativeInsertData`/`nativeReplaceData`) and via the JS polyfill in `dom_api.zig` (which routes through the QJS `dom_text.zig:57,63` setter that already records). Task 3 scope = 4 natives only.

- [ ] **[1B-Q2]** `insertAdjacentHTML` (audit matrix #27) — is this in scope for Layer 1B or deferred? — Needs a grep of WPT `MutationObserver-childList.html` source for `insertAdjacentHTML` invocation. If the test exercises it, in scope; otherwise defer to Layer 1F.
  - **Resolution (deferred)**: Per plan §Files NOT to modify and §Audit matrix notes "Open Q 1B-Q2 (likely deferred)". Not in plan's enumerated 7 tasks. Deferred to Layer 1F.

- [ ] **[1B-Q3]** Old-value buffer truncation at 4 KiB — acceptable for Layer 1B, or promote to heap-backed ArrayList now? — Current spec defers; confirm with critic before shipping Task 7.
  - **Resolution (stack 4 KiB + heap spill)**: Follow `dom_element.zig:795-808` pattern — stack buffer primary, heap fallback for values exceeding 4 KiB. Matches spec recommendation.

## WPT 100% Wave 2 — 2026-04-19

- [ ] **[W2-Q1]** 0A Gap 3 (Error prototype chain) uses `getCallerFuncObj` introspection. If that helper returns null in the sub-error `new` path, fall back to per-type dedicated constructors (Option B of design §Gap 3). — Confirm path exists before executor starts; determines whether 0A delivers full sub-error `instanceof` wins or only partial.

- [ ] **[W2-Q2]** 1B kotori-VM `data=` setter — re-confirm resolution from 1B-Q1 during executor's first pass on fresh main. — Cheap (5-min grep), but prerequisite to Task 3 scope lock-in.

- [ ] **[W2-Q3]** 1D.1 Task 11 polyfill deletion gate: what is the exact pre-deletion pass threshold? Spec says "≥35/67 with polyfill installed". — Reconfirm after Tasks 1–10 merged to main that the number still holds; if lower, abort Task 11 and audit which native path regressed.

- [ ] **[W2-Q4]** 3D-Unblock commit `c155016` on `feature/kotori-layer-3d-css-color` — verify the commit content against current `createStyleObj` body on main before cherry-picking. — If `createComputedStyleObj` has drifted since c155016 was authored, mirror its current signature.

- [ ] **[W2-Q5]** 2A Risk 4 — JS-level listener path (`__el_<type>`) mid-dispatch abort behavior. — Empirical verification required: probe test with `new EventTarget()`, abort mid-dispatch, assert later listeners do not fire. Result determines whether 2A merge criteria include a JS-path patch.

- [ ] **[W2-Q6]** Phase 0 baseline stability — if any layer lands between Phase 0 measurement and Tick 1 dispatch, rebaseline before dispatch. — Gate for wave-end ADR honesty (deltas must be against a single baseline).

## Layer 3B CSS Computed Values - 2026-04-20

- [ ] **[3B-Q1]** Is the existing cascade pass guaranteed to process `:root` before children so `root_font_size_px` is stable when a child resolves `rem`? — Architect to verify by tracing `src/css/cascade.zig::cascade`. If ordering is not guaranteed, switch to explicit two-pass cascade (root first, rest second) or thread `root_font_size_px` through the cascade walker from the top. Blocks Phase 3B.4.

- [ ] **[3B-Q2]** Should `normalizeSpecifiedCalc` collapse pure-numeric terms aggressively (Chrome: `calc(0.5 + 0.5) → calc(1)`) or preserve authoring precision (Firefox: keep as `calc(0.5 + 0.5)`)? — WPT targets Chrome form. Default to Chrome unless WPT shows specific Firefox-shaped expectations.

- [ ] **[3B-Q3]** `ic` / `cap` — T1 stub with `1em` / `0.7em` respectively, or wire to font-cache glyph metrics? — T1 stub passes every in-scope Category-C test file (font-load tests are already out of scope). Start with stub; revisit only if gate 2 falls short.

- [ ] **[3B-Q4]** `vi` / `vb` — stub to `vw` / `vh` (horizontal-tb only) or full writing-mode-aware? — Stub sufficient for 18 subtests in `viewport-units-parsing.html`. Full WM support is a separate layer.

- [ ] **[3B-Q5]** Signed-zero — full IEEE -0 propagation through the MathNode AST, or target Chrome's exact observable output? — Start IEEE-faithful; fall back to Chrome-output-match if `signed-zero.html` < 50% pass rate after Phase 3B.5.

- [ ] **[3B-Q6]** Calc term-sort rule for specified-time serialization is "implementation-defined canonical form" per spec. Confirm Chrome order by running `calc-serialization.html` against current Chrome in a local harness before finalizing sort comparator. — Mitigation: if sort disagrees on a subtest, document the deviation rather than chase pixel-match.
