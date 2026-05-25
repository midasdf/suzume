# Wave 3 State Survey

**Date**: 2026-04-20
**Open**: `wave2-base` = `4cf67ed` on `main` (unchanged from Wave 2 close)
**Survey by**: team-lead (pre-plan)

---

## Git state

### HEAD + branch
```
main  4cf67ed fix(kotori): fix var hoisting in nested blocks and close_upvalue stack pop
```

### Wave-3 candidate feature branches (all 0 commits ahead of main = no prior work)
```
feature/kotori-layer-0d: 0 commits ahead
feature/kotori-layer-0f: 0 commits ahead
feature/kotori-layer-1f: 0 commits ahead    (NOTE: design docs parked separately on wip/layer-1f-design-docs-stash3 @ ead52ba)
feature/kotori-layer-3b: 0 commits ahead
feature/kotori-layer-4b: 0 commits ahead
```

Confirmed: **all 5 Wave 3 candidate layers are genuinely unstarted**. No merged work to reconcile.

### Design spec status
```
docs/superpowers/specs/ has NO specs for 3B, 4B, 0D, 0F
1F design parked on wip branch (not in main specs/)
```

All candidate layers require design spec authorship as first step.

### Stashes
- 8 stashes from Wave 2 operation (stash@{0}=transient, now dropped; stash@{1-7} classified drop/park-on-wip). No Wave 3 additions.

### Submodule
```
deps/libnsfb: -dirty (inner working-tree drift, outer pointer unchanged; Wave 2 confirmed safe)
```

---

## WPT baseline (Wave 2 close, still current)

| Area | Subtests | Rate | wave2-base reference |
|------|----------|------|----------------------|
| css/css-color | 604/7133 | 8.5% | post-3D-unblock cumulative Layer 3/4 work |
| css/css-values | 1099/4472 | **24.6%** | **PRIMARY Layer 3B target** |
| css/cssom | 68/381 | 17.8% | spillover target |
| css/selectors | 31/337 | 9.2% | |
| dom/events | 47/215 | 21.9% | |
| dom/nodes | 1204/2110 | 57.1% | |
| html/dom | 35/571 | **6.1%** | **PRIMARY Layer 4B target** |
| webidl | 16/123 | 13.0% | |

Total Wave 2 close: 3104/15342 subtests (20.2%).

---

## Wave 3 scope decision

**SELECTED**: Layer 3B (CSS Computed Values) — single-layer focus, biggest ROI.

**Rationale**:
- `css/css-values` at 24.6% with 3373 subtests headroom is the single biggest targetable gap.
- Layer 3B is new-code, not polyfill-deletion — clearer risk profile than Task 11.
- 4B/1F/0D/0F deferred to Wave 4+ to keep wave focused (Wave 2 taught us wide scope = iteration thrash).
- Task 11 retry NOT attempted — Wave 2 Learning L2 requires runtime behavioral equivalence tool as precondition; building that tool is separate infrastructure work not suited to same wave as primary target.

**Not selected**:
- Layer 4B — good candidate but +500 estimate vs 3B's +2000. Will take after 3B lands.
- Layer 1F — small delta (+200-400), designs already parked. Take as quick-win in follow-up.
- Layer 0D/0F — infrastructure / reliability work, not coverage gain. Low priority.

---

## Wave 3 plan shape

1. **Design spec authorship**: `docs/superpowers/specs/2026-04-20-kotori-3B-computed-values-design.md`
   - WHATWG CSS Values 4 §4 computed-value production rules
   - Font-relative units (em/rem/ch/ex) → px resolution
   - Viewport units (vw/vh/vmin/vmax)
   - calc() normalization
   - Inherited vs non-inherited properties
   - Currently-failing test inventory from `css/css-values` fail logs
2. **Implementation**: new `src/css/computed.zig` module + `src/js/dom_style.zig` integration with `getComputedStyle()`
3. **WPT validation**: `css/css-values` full-area re-run, per-file deltas documented
4. **Commit**: `feat(kotori): Layer 3B — CSS Computed Values (WHATWG CSS Values 4 §4)` with WPT delta in footer
5. **Tag**: `wave3-layer-3b`

**Acceptance criteria (Gate 1, reviewable now)**:
- Design spec authored and peer-reviewed before implementation begins
- `zig build -Doptimize=ReleaseSafe` + `zig build test` both exit 0
- `css/css-values` subtest pass count ≥ 1099 (baseline, zero-regression floor)
- At least one concrete per-file improvement documented (not necessarily +2000)

**Acceptance criteria (Gate 2, post-measurement)**:
- Net `css/css-values` delta published
- Spillover to `css/cssom` documented (computed-style.html sentinel was Wave 2 timeout → should now run)
- Sentinel regression check: 10 Wave 2 sentinels maintain or improve

---

## Anti-patterns actively guarded against

- ✅ Verified no already-merged state (Wave 2 iteration 1/2 lesson applied).
- ✅ Single-layer scope (Wave 2 iteration 3 lesson applied).
- ✅ Spec-driven: design first, implement second (plan principle #1).
- ✅ No polyfill-deletion in this wave (Wave 2 L2 lesson — waiting on behavioral equivalence tooling).
- ✅ State survey written BEFORE plan authoring (Wave 2 L1 lesson, Wave 3 standing requirement).

---

## Opener checklist

- [x] State Survey authored.
- [x] Deliverable Audit: all 5 candidates confirmed unstarted.
- [x] Baseline still valid (Wave 2 close, HEAD unchanged).
- [x] Single-layer shape selected with rationale.
- [ ] Design spec authored (next step).
- [ ] Architect review of design spec.
- [ ] Implementation.
- [ ] WPT measurement + commit.
