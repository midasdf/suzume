# Wave 2 Retrospective

**Date**: 2026-04-20
**Owner**: worker-alpha (Phase 2 closer)
**Wave range**: 2026-04-19 → 2026-04-20
**Base tag**: `wave2-base` = `4cf67ed` on `main` (unchanged at wave close)

---

## Wave shape

Option G executed: **Verification Sweep + 1 gated commit** → **0 ships + 1 drop**.

- **Verification Sweep (Phase 0a + 0b)** — SHIPPED as documented artifacts:
  - State Reconciliation: tag `wave2-base`, stash classification, submodule audit, smoke builds green.
  - Baseline Measurement: 8-area WPT baseline at `wave2-base` + 3D-Unblock historical delta measurement.
- **1D.1 Task 11 polyfill deletion (Phase 1a/1b)** — DROPPED on gate D1 failure (−13 subtests on `attributes.html`). Third consecutive revert.

---

## What shipped

**Code**: NOTHING.
- Zero new commits on `main` between wave open (`4cf67ed`) and wave close (`4cf67ed`).
- Zero new tags beyond `wave2-base` itself.
- `zig-out/bin/suzume` size unchanged at 53,302,200 bytes (identical pre- and post-wave).
- No new WPT subtests passing (overall or per-area).
- No binary-size credit (Task 11's ≤ −5 KB target never cashed).

**Non-code side artifact**: branch `wip/layer-1f-design-docs-stash3` at commit `ead52ba` containing Layer 1F design + plan parked from stash@{3} — NOT merged to main, lives only on that branch, Wave 3 seed.

---

## What was documented

Wave 2's actual deliverable is a set of research artifacts that correct the fabricated-scope problems of iterations 1 and 2 and give Wave 3 a known-good foundation:

| Artifact | Purpose |
|----------|---------|
| `.omc/research/2026-04-19-wave2-stash-disposition.md` | Phase 0a — 8 stashes classified; `deps/libnsfb` submodule drift audited; smoke-build checkbox. |
| `.omc/research/2026-04-19-wpt-baseline.md` | Phase 0b — 8-area WPT baseline at `wave2-base` with concrete integers (3104/15342 subtests passing, 20.2%). |
| `.omc/research/2026-04-19-3d-unblock-measurement.md` | T0b.3 — historical Pre/Post measurement of c155016. Δ: css/css-color +598, css/css-values +917 subtests (total +1515 across 104 commits). |
| `.omc/research/2026-04-19-1d1-task11-postmortem.md` | Phase 1a — native coverage audit + root-cause analysis of first 2 reverts. |
| `.omc/research/2026-04-19-1d1-task11-third-drop.md` | Phase 1b — D1 gate failure analysis. Two failure classes documented (native-dispatch vs own-property hygiene). The key learning of the wave. |
| `.omc/research/2026-04-19-wave2-sentinel.txt` | Phase 2 — sentinel WPT_SUMMARY for 10 canonical files at wave close, confirms no regression from revert cycle. |
| `.omc/research/2026-04-19-wave2-retrospective.md` | This document. |
| `.omc/research/2026-04-20-wave3-seed.md` | Wave 3 seed items with candidate layers and Task 11 preconditions. |

---

## Learnings (three that matter)

### L1 — State-reconciliation before wave planning is mandatory, not optional

Iterations 1 and 2 of the Wave 2 plan scoped 6 coding layers. The live `git log main..feature/*` + `git merge-base --is-ancestor` probes in iteration 3 showed all 6 were already on main. Iteration 3 collapsed the scope from 6 layers to 1 retry + 1 sweep. Future waves MUST open with a State Survey + Deliverable Audit template **before** any phase authoring. Never draft from memory or roadmap documents alone.

### L2 — Static source inspection is insufficient for polyfill-to-native migrations

The Phase 1a post-mortem showed 11/11 native Attr methods present and 33 failing subtests structurally mapping to native entry points. The D1 gate still failed, with 13 subtests regressing. The failures broke down into:
- Failure class A (native dispatch): `getAttributeNames`/`removeAttributeNode` returned `undefined` post-deletion despite natives existing. The polyfill was holding prototype registration or dispatch-table wiring that native alone doesn't populate.
- Failure class B (property hygiene): `Object.getOwnPropertyNames(elem)` returned 9 items where 2 were expected. Native Element wrapper leaks internal slots without the polyfill's descriptor redefinition.

**Structural coverage ≠ functional equivalence.** Static analysis can't catch this. Runtime behavioral diff is the only reliable precondition — documented in third-drop §Follow-ups as a Wave 3 blocker for any polyfill-deletion retry.

### L3 — Wave 2 net outcome: course-correction only

WPT progress this wave = **0 new passing subtests**. But:
- Iteration 1/2 phantom-work risk is now documented as a drift ledger and procedural guard.
- Task 11 debt is resolved: "third revert, drop, functional-equivalence-tool prerequisite" — no more in-band retries.
- Wave 3 starts from a measured, integer-level baseline instead of vibes.

A course-correction wave that produces zero subtests but prevents Wave 3 from drifting another two iterations off-ground is net-positive for the project velocity over the next three waves.

---

## Gate summary (per plan §Success Criteria)

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Phase 0a green | ✅ | wave2-base tag; stash+submodule docs; `zig build` + `zig build test` both exit 0 |
| 2 | Phase 0b baseline + 3D-Unblock Δ | ✅ | 8-area table + Pre/Post/Δ table in baseline + 3d-unblock docs |
| 3 | Phase 1 Task 11 landed OR deferred with ADR | ✅ (deferred) | third-drop.md documents D1 failure + revert + drop decision |
| 4 | Phase 2 sentinel ≥ Phase 0b baseline | ✅ (wave-close HEAD = wave2-base, so baseline = post = no regression possible) | sentinel.txt captured |
| 5 | ADR filled including Reality-Reconciliation Drift Ledger | ✅ | plan §Phase 5 |
| 6 | Open-questions file updated | ✅ (W2-Q7/Q8/Q9 resolutions appended) | see plan §Open Questions |
| 7 | `zig build -Doptimize=ReleaseSafe` + `zig build test` green at wave-close HEAD | ✅ | wave-close HEAD = wave-open HEAD = `4cf67ed` (unchanged) |
| 8 | Binary size delta | ✅ (identity) | 53,302,200 bytes pre- and post-wave |

---

## Wave 2 closes

Tag `wave2-base` retained as a reference point for Wave 3's opening State Survey. No merge commits, no branches merged. Wave 3 opens with:
- A measured baseline.
- A proven-failed Task 11 path with specific preconditions for a future retry.
- A seed list (separate doc) of genuinely unstarted work.

One thing we will NOT do next wave: plan against memory or roadmap summaries. State survey first, always.
