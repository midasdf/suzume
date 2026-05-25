# Wave 4 Retrospective

**Date**: 2026-04-20
**Wave range**: 2026-04-20 (within-day course correction after Wave 3)
**Base tag**: `wave4-base` = `9b1dac7` on `main` (unchanged at wave close)

---

## Wave shape

Single-attempt diagnostic wave. Goal: land Phase 3B.1 (min/max/clamp math functions) via dom_style.zig surgical edits.

Result: **Diagnostic success, shipping failure**. Root cause traced through the full stack (VM → CSS parser → cascade → dom_style); partial fix (VM bracket dispatch alone) was net-negative (−678 subtests); reverted cleanly.

---

## What shipped

**Code**: NOTHING beyond wave4-base.

- HEAD at wave close = `9b1dac7` = HEAD at wave open (Wave 3 Layer 1F.partial).
- No new tags beyond `wave4-base`.
- `zig-out/bin/suzume` size 53,302,712 bytes (exact match to wave4-base).

---

## What was documented

- `.omc/research/2026-04-20-3b-phase1-measurement.md` — Wave 3 failed retry (0 delta, forbidden-file block)
- `.omc/research/2026-04-20-wave4-3b1-measurement.md` — Wave 4 architectural blocker diagnosis
- `.omc/research/wave4-surgical-css-values.txt` + `wave4-surgical-dom-nodes.txt` + `wave4-surgical-cssom.txt` — VM patch-alone measurement showing net-negative
- `.omc/research/2026-04-20-wave5-seed.md` — coordinated 3-file plan for Wave 5

---

## Key learning: single-file fix breaks the 3-part invariant

**Before Wave 4**:
- `testEl.style[prop] = "max(10px, 20px)"` silently stored nothing (bracket access bypassed dom_set_prop)
- WPT tests counted as FAIL (assertion miss)

**After Wave 4 VM patch alone**:
- Bracket access NOW calls dom_set_prop
- dom_set_prop passes value to CSS parser
- CSS parser rejects `max(...)` (not implemented yet)
- Test harness crashes → ERR state (worse than FAIL)
- Net: -740 css/css-values, +52 dom/nodes, +10 css/cssom = **-678 net**

**Conclusion**: VM bracket dispatch MUST ship with CSS parser support together, or neither.

---

## Wave 4 net outcome

**Progress toward WPT 100%**: 0 new subtests.

**But**:
- Architectural blocker now fully understood (3-file invariant documented)
- Wave 5 seed specifies exact line-level changes across 5 files
- Risk catalog updated with R1-R6 (partial-commit, parser crash, stack imbalance etc.)
- Quantitative proof that single-file attempts are net-negative

**Wave 4 is a research wave**: it produced the seed Wave 5 needs to ship the real +500-1450 subtest win.

---

## Cumulative session progress

| Wave | Commits | Subtests shipped | Research artifacts |
|------|---------|------------------|-------------------|
| Wave 2 | 0 | 0 | 8 |
| Wave 3 Phase 3B.1 attempt 1 | 0 (reverted) | 0 | 1 |
| Wave 3 Layer 1F.partial | 1 (`9b1dac7`) | **+4** | 1 |
| Wave 3 Phase 3B.1 retry | 0 (reverted) | 0 | 1 |
| Wave 4 | 0 (reverted) | 0 | 2 |
| **Total** | **1** | **+4** | **13** |

---

## Follow-ups

1. **Wave 5** — execute the coordinated 3-file landing per Wave 5 seed. Atomic commit across VM + CSS parser + cascade + dom_style. Target +500 subtests (min/max/clamp only).
2. **Wave 6** — once Phase 3B.1 lands, Phase 3B.2 (serialization) and 3B.3 (computed resolution) build on it.
3. **Wave 7+** — Layer 4B form controls (+500), Layer 0D execution timeout, Layer 0F eval local scope.

---

## Reality-Reconciliation Drift Ledger

No drift in Wave 4. State Survey (Wave 3) still accurate. wave4-base accurately represents wave-close state (same as wave-open — no code moved).

---

## ADR (brief, for this research wave)

**Decision**: Diagnostic wave; no code shipping.

**Drivers**:
1. Prior Wave 3 retry blocked by FORBIDDEN file list — needed diagnostic pass to discover real architectural constraint
2. Coordinated 3-file fix has non-trivial complexity; diagnosing before shipping reduces risk of compound regression
3. Wave shipping 0 subtests is acceptable when it delivers a testable Wave 5 seed

**Alternatives considered**:
- A) Attempt full 3-file fix in Wave 4 — rejected: too broad for one wave given session time pressure
- B) Skip Phase 3B and pivot to Layer 4B — rejected: Layer 3B has 2000+ subtest ROI, Layer 4B only 500

**Why diagnostic path**: Wave 5 now has specific line-level coordinates and measured risk catalog, making coordinated execution tractable.

**Consequences**:
- Wave 4 shipped 0 WPT subtests
- Wave 5 has a complete execution blueprint
- Cumulative session WPT gain remains at +4 (Layer 1F.partial only)
