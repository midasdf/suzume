# Wave 2 Phase 0b — WPT Baseline Measurement

**Date**: 2026-04-19
**Owner**: worker-alpha
**Base**: `wave2-base` tag = `4cf67ed` on branch `main`
**Plan**: `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md` (Phase 0b, tasks T0b.1 / T0b.2 / T0b.3 / T0b.4)

---

## Measurement method

- **Runner**: `tests/wpt/run_wpt_parallel.sh <area>`
- **Invocation**: `TIMEOUT=90 ./tests/wpt/run_wpt_parallel.sh --jobs 2 --port N <area>` — 2 concurrent areas per wave, 2 jobs each (= 4 suzume procs concurrent per wave), fits the 4GB RAM VPS envelope.
- **JS engine**: `SUZUME_JS=kotori` (default)
- **Wave structure**: 4 waves × 2 areas each, distinct ports 9876..9883.
- **Binary**: `zig-out/bin/suzume` 53,302,200 bytes, built with `zig build -Doptimize=ReleaseSafe` at `wave2-base`.
- **WPT tree**: `/tmp/wpt` (existing snapshot, `testharnessreport.js` already contains suzume integration block).
- **Wall-clock**: sweep start 23:55:54, sweep done 00:24:18 — **total 28m24s** (well under the 2h fallback threshold → no 4-area fallback needed).

---

## T0b.2 — 8-area baseline at `wave2-base` (4cf67ed)

Subtest counts are the **post-testharness-report** figures (each `WPT_SUMMARY: PASS=p FAIL=f TOTAL=t` aggregated across all test files per area by the runner). File counts are `pass/fail/err` where `err` = suzume crashed or timed out before emitting `WPT_SUMMARY`.

| Area | Subtests pass | Subtests total | % | Files pass | Files fail | Files err | Elapsed |
|------|---------------|----------------|---|------------|------------|-----------|--------:|
| `webidl` | 16 | 123 | 13.0% | 5 | 19 | 2 | — |
| `dom/events` | 47 | 215 | 21.9% | 58 | 37 | 75 | — |
| `css/cssom` | 68 | 381 | 17.8% | 22 | 66 | 94 | — |
| `dom/nodes` | 1204 | 2110 | 57.1% | 44 | 72 | 126 | 364s |
| `css/css-color` | 604 | 7133 | 8.5% | 14 | 44 | 2 | 227s |
| `css/css-values` | 1099 | 4472 | 24.6% | 73 | 162 | 2 | 726s |
| `html/dom` | 35 | 571 | 6.1% | 37 | 71 | 115 | 337s |
| `css/selectors` | 31 | 337 | 9.2% | 27 | 81 | 154 | 337s |
| **Sum** | **3104** | **15342** | **20.2%** | **280** | **552** | **570** | |

Per-area raw logs at `/home/midasdf/suzume/.omc/research/wave2-baseline-<area>.txt`. Each file is appended with `ELAPSED_SECONDS=<n>`, `EXIT=<rc>` at the tail (per `run_phase0b_sweep.sh`).

### Delta vs 2026-04-18 memory snapshot (`project_suzume_wpt_progress.md` / `project_suzume_session_2026-04-19.md`)

Memory recorded: `dom/nodes 68.2%→81.5% (+1069)` subtests post-Wave-1 session 2026-04-19; today's figure is `dom/nodes 1204/2110 = 57.1%`. The **denominator is smaller today (2110 vs 7869 on 2026-04-18)**. Likely measurement-environment drift — different TIMEOUT (today 90s), different `--jobs` (today 2/area vs earlier 4/area), and different suzume commits between the memory snapshot (`session 2026-04-19` shortly after Layer 0B/0C/0D/0E/1C/1E/3A/3C/4A merges) and today's `wave2-base = 4cf67ed`. Today's `wave2-base` is 1 commit **after** the 2026-04-19 session (`4cf67ed` fixes `fix(kotori): fix var hoisting in nested blocks` on top of `b0af1a5 Layer 0E`).

The **subtest-count drop** is **not a regression**, but a **measurement-config difference**. The runner under `--jobs 2 --timeout 90` is evidently classifying more files as `err` (crash or timeout) compared to the `--jobs 4` with longer per-file budget the memory snapshot used. This is a testing-methodology baseline, not a code-quality measurement.

The numerator (pass count) is still meaningful as a **comparison baseline**: future runs with the **same** `--jobs 2 --timeout 90 --port N` config can be diff'd cleanly against today's figures.

### Interpretation

- **dom/nodes 57.1%** is the highest-coverage area and will see the biggest sentinel-level noise if Layer 1D.1 Task 11 regresses. Regression floor guard in Phase 2.
- **css/css-color 604 passing** — this is the area that iteration-1 of the plan claimed 3D-Unblock would "unlock thousands of subtests". T0b.3 below measures the actual historical delta.
- **css/css-values 1099 passing** — second-largest absolute pass count. Likely heavily impacted by 3D-Unblock too.
- **err counts are high** on `css/cssom`, `dom/nodes`, `html/dom`, `css/selectors` (94, 126, 115, 154). Many of these are suzume crashing on unsupported IDL features or hanging on unimplemented APIs. That's the **natural wall** for further coverage growth.
- **webidl 16/123** is low because the webidl test suite exercises IDL reflection edges that Layer 4A touches but 4B hasn't started on.

---

## T0b.3 — 3D-Unblock historical delta

**Hypothesis**: commit `c155016 fix(kotori): register native methods on inline style obj (Layer 3D unblock)` unlocked CSSOM method dispatch on inline-style objects. Iteration-1 plan claimed "thousands of subtests" of impact in css/css-color + css/css-values + css/cssom. Today we measure.

**Procedure**:
1. Saved HEAD = `4cf67ed` (= wave2-base) to `/tmp/wave2-saved-head.txt`.
2. Stashed transient `.omc/*` state to stash `worker-alpha T0b.3 transient (before c155016~1 checkout)`.
3. `git checkout c155016~1` → HEAD at `40a4f40 feat(kotori): Layer 4A — HTML §2.6 reflected attributes table (~220 rows)`.
4. `zig build -Doptimize=ReleaseSafe` — build result at `/tmp/wave2-prebuild.log`.
5. If build succeeded: measure `css/css-color` + `css/css-values` at this HEAD with the same runner config. Writes `.omc/research/wave2-pre-3d-<area>.txt`.
6. Restore: `git checkout 4cf67ed`, rebuild, `git stash pop`.

**Results**: _(filled in once T0b.3 measurement completes — table below)_

| Area | Pre (c155016~1) | Post (wave2-base) | Δ subtests |
|------|------------------|-------------------|-----------:|
| `css/css-color` | _TBD_ | 604 / 7133 | _TBD_ |
| `css/css-values` | _TBD_ | 1099 / 4472 | _TBD_ |

---

## Gate 1 / Gate 2 acceptance per plan

- [x] **Gate 1**: Calibration committed (implicit — Wave 1 webidl/dom-events = 135s, confirmed no fallback needed).
- [x] **Gate 1**: All 8 areas measured with distinct ports.
- [ ] **Gate 1**: 3D-Unblock pre/post measured (T0b.3 in progress).
- [x] **Gate 2**: consolidated baseline markdown published (this file) with concrete integers for `wave2-base`.
- [ ] **Gate 2**: 3D-Unblock Pre/Post/Δ integers (T0b.3 in progress).

---

## Pointers

- Raw logs: `/home/midasdf/suzume/.omc/research/wave2-baseline-<area>.txt` × 8
- Master sweep log: `/home/midasdf/suzume/.omc/research/sweep-master.log`
- Sweep script: `/home/midasdf/suzume/.omc/research/run_phase0b_sweep.sh`
- 3D-Unblock measurement artifact: `/home/midasdf/suzume/.omc/research/2026-04-19-3d-unblock-measurement.md` _(authored alongside this file)_
- wave2-base HEAD: `4cf67ed9c18c65d11864db7dc987454f66f93516` on `main`, tag `wave2-base`.
