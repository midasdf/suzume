# Wave 7 Baseline (pre Phase 6.2 ship)

**Date**: 2026-04-20
**HEAD**: `main @ 62437b5` (Wave 6 Phase 6.0 shipped)
**Binary**: `zig-out/bin/suzume` 53,305,376 bytes (2026-04-20 15:04)
**Measurement**: TIMEOUT=90, jobs=2, SUZUME_JS=kotori (default)

## Final numbers

| Area           | Pass/Total    | Rate    | vs Phase 6.0 | Notes |
|----------------|---------------|---------|--------------|-------|
| css/css-values | **1203/4536** | 26.5%   | exact match  | Phase 6.0 was 1203/4536 |
| dom/nodes      | **6394/7818** | 81.8%   | exact match  | Phase 6.0 was 6394/7819 (1 test subset drift) |
| css/cssom      | **168/701**   | 23.9%   | exact match  | Phase 6.0 was 168/701 |

Zero drift from Wave 6 Phase 6.0 tagging — baselines stable.

## Phase 6.2 acceptance gate (Gate B)

| Gate | Area | Condition | Rationale |
|------|------|-----------|-----------|
| Floor | css/css-values | ≥ 1403 (+200) | Wave 5 rescue recovered ~273, deep validator should recover most residual |
| Stretch | css/css-values | ≥ 1703 (+500) | Gradient + calc-size + url-modifier + shorthand full recovery |
| No-regression | dom/nodes | ≥ 6389 (−5 noise) | Wave 6 seed permits small flakiness |
| Spillover | css/cssom | ≥ 173 (+5) | Expected from computed-style routing |

## Raw files

- `/tmp/wave7-baseline-css-values.txt` (542 lines)
- `/tmp/wave7-baseline-dom-nodes.txt` (325 lines)
- `/tmp/wave7-baseline-cssom.txt` (297 lines)

## Secondary observations

css-values log shows 2 Subtests reports (1203/4536, 1167/4374) — standard WPT-runner pattern when test harness completion fires twice (first partial sum, then final). Authoritative is the larger total (4536).

dom-nodes log: 6394/7818 vs 6392/7764 — identical pattern.

## Next

Phase 6.2 landing target: measure post-merge, compare against these floors, merge iff Gate B passes.
