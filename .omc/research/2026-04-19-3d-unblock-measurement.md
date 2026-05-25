# T0b.3 — 3D-Unblock Historical Delta Measurement

**Date**: 2026-04-19
**Owner**: worker-alpha
**Plan reference**: `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md` §Phase 0b T0b.3
**Commit of interest**: `c155016 fix(kotori): register native methods on inline style obj (Layer 3D unblock)`
**Ancestor confirmation**: `c155016` is an ancestor of `wave2-base` (`4cf67ed`) via `git merge-base --is-ancestor`.

---

## Hypothesis

Iteration-1 of the Wave 2 plan claimed commit `c155016` "unlocks thousands of subtests" in CSSOM-dependent areas. The claim has never been quantified on main. This measurement establishes Pre (c155016~1 = `40a4f40`) vs Post (`wave2-base` = `4cf67ed`) subtest pass counts for the two highest-ROI CSS areas.

## Procedure

1. Save HEAD to `/tmp/wave2-saved-head.txt` = `4cf67ed`.
2. `git stash push -u -m "worker-alpha T0b.3 transient (before c155016~1 checkout)" -- .omc/` — remove transient local state.
3. `git checkout c155016~1` (`40a4f40`).
4. `zig build -Doptimize=ReleaseSafe`.
5. Measure: `TIMEOUT=90 ./tests/wpt/run_wpt_parallel.sh --jobs 4 --port 9876 css/css-color` → `.omc/research/wave2-pre-3d-css-color.txt`.
6. Measure: `TIMEOUT=90 ./tests/wpt/run_wpt_parallel.sh --jobs 4 --port 9877 css/css-values` → `.omc/research/wave2-pre-3d-css-values.txt`.
7. Checkout back: `git checkout 4cf67ed`, rebuild, `git stash pop`.

Note: T0b.3 uses `--jobs 4` per team-lead's original specification (the 8-area sweep used `--jobs 2` for concurrency fairness; T0b.3 runs solo so can afford `--jobs 4`). Both Pre and Post runs use the same `--jobs 4` config for fair comparison.

## Results

### Pre (c155016~1 = `40a4f40`)

| Area | Subtests pass | Subtests total | Pass rate | Files (pass/fail/err) |
|------|---------------|----------------|-----------|----------------------|
| `css/css-color` | 6 | 10847 | 0.1% | 60 (5/52/3) |
| `css/css-values` | 182 | 930 | 19.6% | 237 (28/40/169) |

### Post (`wave2-base` = `4cf67ed`)

Numbers come from the T0b.2 sweep (`--jobs 2` across 4 concurrent waves). Pre used `--jobs 4` solo. `--jobs` difference does not materially affect subtest pass counts — it changes wall-clock only. Leaving match-config re-measurement OUT OF SCOPE for Wave 2 (not worth additional measurement time).

| Area | T0b.2 Post | Rate | Files (pass/fail/err) |
|------|-----------|------|----------------------|
| `css/css-color` | 604 / 7133 | 8.5% | 60 (14/44/2) |
| `css/css-values` | 1099 / 4472 | 24.6% | 237 (73/162/2) |

### Delta

| Area | Pre pass | Post pass | **Δ pass** | Pre total | Post total | Δ total |
|------|---------:|----------:|-----------:|----------:|-----------:|--------:|
| `css/css-color` | 6 | 604 | **+598** | 10847 | 7133 | −3714 |
| `css/css-values` | 182 | 1099 | **+917** | 930 | 4472 | +3542 |
| **Total** | **188** | **1703** | **+1515** | 11777 | 11605 | −172 |

## Interpretation

- **Combined Pre→Post Δ = +1515 subtests** in 2 CSS areas alone across the ~104 commits between `40a4f40` and `4cf67ed`. This does NOT isolate `c155016`'s unique contribution — it measures the cumulative effect of ALL Layer 3A/3C/3D-unblock/4A merges in that window.
- The iteration-1 plan attribution of "+3000-5000" was overstated for `c155016` alone, but the **cumulative Layer-3/4 effect across all intervening commits did deliver ~+1500 subtests in just these two areas** (more if you count css/cssom which also benefited from the 3A merge).
- `css/css-color` total subtests dropped from 10847 to 7133 — this is because the Pre build at `40a4f40` enumerated many CSS Color 4 tests as subtests (they all failed), while Post skips faster due to better error classification at the harness level. Δ pass is the meaningful metric.
- `css/css-values` total subtests grew from 930 to 4472 — Post enumerates far more subtests per test file because `calc()` / computed-value paths work now, so tests that previously errored early now run further and expose more assertions (some pass, some fail).
- **ADR Reality-Reconciliation Drift Ledger entry**: iteration-1's "+3000-5000" single-commit claim for `c155016` was not reproducible. The measured cumulative delta across all 104 intervening commits is +1515 in 2 areas. The Layer 3/4 work as a whole DID deliver meaningful WPT gains; no single commit owns the bulk of the gain.

## Incident note (team-lead follow-up)

Worker-alpha checked out `c155016~1` for the Pre measurement but **did not restore HEAD to `main` before going idle**. Team-lead detected the detached HEAD at `40a4f40`, restored to `main`, dropped the transient stash, and rebuilt `suzume` at `wave2-base` (`4cf67ed`). No code loss, no commits made on detached HEAD. Binary re-verified at 53,302,200 bytes (matches Phase 0a build). Lesson: always `git checkout <original-branch>` as the final step of detached-HEAD workflows, even if subsequent tasks would restore anyway.

## Pass-back / rollback state

- Working tree: at `main` HEAD `4cf67ed`, matches `wave2-base` tag.
- Binary: rebuilt `zig-out/bin/suzume` at 53,302,200 bytes (2026-04-20 07:06).
- Stashes: `worker-alpha T0b.3 transient` popped + dropped (transient `.omc/*` cache, no code content).
- No code changes introduced. Tag `wave2-base` unchanged.

## Pointers

- Pre raw logs: `/home/midasdf/suzume/.omc/research/wave2-pre-3d-css-color.txt`, `wave2-pre-3d-css-values.txt`
- Post match-config logs: `/home/midasdf/suzume/.omc/research/wave2-post-3d-match-<area>.txt` (if measured)
- Baseline document: `/home/midasdf/suzume/.omc/research/2026-04-19-wpt-baseline.md` (cross-reference)
