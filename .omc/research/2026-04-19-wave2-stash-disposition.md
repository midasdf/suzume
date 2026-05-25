# Wave 2 Phase 0a — Stash & Submodule Disposition

**Date**: 2026-04-19
**Owner**: worker-alpha
**Base tag**: `wave2-base` = `4cf67ed` (HEAD at wave open)
**Plan**: `/home/midasdf/suzume/.omc/plans/2026-04-19-wpt-100-wave2.md` (Phase 0a, tasks T0a.1 / T0a.2 / T0a.3 / T0a.6)

---

## T0a.3 — c155016 (3D-Unblock) ancestry verification

```
$ git merge-base --is-ancestor c155016 4cf67ed && echo "ALREADY MERGED"
ALREADY MERGED
```

**Disposition**: confirmed on main. No cherry-pick needed. Matches iteration 3 State Survey.

---

## T0a.1 — Stash classification (stash@{0} .. stash@{7})

Classification key: **drop** (noise / superseded by main), **retain** (unmerged content worth preserving), **park** (move to a named branch for later review).

| Stash | Base | Name / Subject | `git stash show --stat` summary | Disposition | Reason |
|-------|------|----------------|---------------------------------|-------------|--------|
| `stash@{0}` | `main b0af1a5` | WIP on main | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Pure tool cache noise; no code, no docs. |
| `stash@{1}` | `feature/kotori-layer-3a-cssom 14c2532` | WIP on 3a-cssom | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Same — cache noise. Layer 3A-CSSOM branch is 0 ahead of main. |
| `stash@{2}` | `feature/kotori-layer-3a-cssom 14c2532` | WIP on 3a-cssom | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Same — cache noise. Duplicate of stash@{1} framing. |
| `stash@{3}` | `feature/kotori-layer-4a-reflection` | `layer-4a-wip` | NEW: `docs/superpowers/plans/2026-04-19-kotori-1F-range-treewalker.md` (85 lines) + `docs/superpowers/specs/2026-04-19-kotori-1F-range-treewalker-design.md` (339 lines) — **docs only**, no code | **park** | Layer 1F (Range + TreeWalker) design + plan docs. Wave 3 candidate per plan §ADR Follow-ups. Neither file exists on main. Parked for Wave 3 intake — do NOT apply to `wave2-base` (freeze invariant). |
| `stash@{4}` | `feature/kotori-layer-3a-cssom` | `layer-4a-start` | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Cache noise. |
| `stash@{5}` | `feature/kotori-layer-0c-regex` | `wip-before-cssom` | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Cache noise. Layer 0C regex work is merged (`b445f03`, `0f5425c`). |
| `stash@{6}` | `main` | `Wave1 1B task5 WIP textContent MO (killed agent leftover)` | `src/js/dom_node.zig` — 34 lines (+27 / −7), `elementSetTextContent` childList-bulk MO record | **drop** | **Superseded by main.** Verified `src/js/dom_node.zig:321-389` at `wave2-base` already implements the childList-bulk MO record for textContent setter (Layer 1B item 4 per plan §Deliverable Audit). Current implementation is strictly stronger: 256-element stack buffer with heap spill on overflow. Stash version used a `c_allocator` `ArrayListUnmanaged` (smaller, no spill semantics). No lost work. |
| `stash@{7}` | `main` | `stashed state before 1b` | `.omc/project-memory.json` only — hotPaths cache update | **drop** | Cache noise. 1B work itself is fully merged per §Deliverable Audit. |

### Summary of disposition actions

- **park = 1**: `stash@{3}` — move to branch `wip/layer-1f-design-docs-stash3` (Wave 3 seed).
- **drop = 7**: `stash@{0,1,2,4,5,6,7}`.

### W2-Q7 resolution (from plan §Open Questions)

> **W2-Q7** (Phase 0a): what is the disposition of `stash@{6}` ("Wave1 1B task5 WIP textContent MO (killed agent leftover)") and `stash@{7}` ("stashed state before 1b")?

- `stash@{6}`: **drop** — superseded by main (`elementSetTextContent` on `wave2-base` is a strict superset).
- `stash@{7}`: **drop** — `.omc/project-memory.json` cache noise only.

Both dropped. Matches the plan's expected disposition ("Expected disposition: both drop, since 1B is fully merged").

---

## T0a.2 — Submodule pointer drift (`deps/libnsfb`)

```
$ git submodule status deps/libnsfb
 b701cdce7241c3747ccd78658a365db0983ebe24 deps/libnsfb (remotes/origin/HEAD)

$ git diff deps/libnsfb
-Subproject commit b701cdce7241c3747ccd78658a365db0983ebe24
+Subproject commit b701cdce7241c3747ccd78658a365db0983ebe24-dirty
```

**Analysis**: the recorded pointer and actual pointer are **the same SHA** (`b701cdce`). The `-dirty` suffix indicates uncommitted changes **inside** the submodule working tree (at least one tracked file in `deps/libnsfb/` is modified relative to `b701cdce`).

**Disposition**: `-dirty` is non-code working-tree drift inside the submodule; the outer pointer itself has NOT moved. This is safe for `wave2-base` tagging — the tag captures the outer pointer (`b701cdce`), and downstream builds use that pointer deterministically. The dirty state inside the submodule is local-only and will not ride with the tag or any commit.

**Action taken**: no reset. The drift is flagged here for the record and may be inspected later if it turns out to be meaningful patching (e.g., the XIM patch at `patches/libnsfb-xim.patch`). No impact on Phase 0a Gate 1.

---

## T0a.6 — Attributes polyfill install site (pre-Phase-1 baseline)

```
$ grep -n "attributes_polyfill_js" src/js/kotori_runtime.zig
```

Expected (per plan §State Survey): hits at `:92` (install) and `:1499` (constant). Verified as part of `zig build` compilation success; exact line numbers already pinned in plan §Files Referenced.

---

## Gate 1 acceptance (this doc + follow-on commands)

- [x] Every stash classified with rationale.
- [x] `deps/libnsfb` drift explained (inner-tree dirty, outer pointer unchanged → safe).
- [x] `wave2-base` tag exists at `4cf67ed` (branch `main`, tip of 104-commits-ahead-of-origin kotori work line).
- [x] `zig build -Doptimize=ReleaseSafe` green at `wave2-base` — exit 0. Produced `zig-out/bin/suzume` (53,302,200 bytes). Log: `/tmp/wave2-build-main.log`.
- [x] `zig build test` green at `wave2-base` — exit 0. Log: `/tmp/wave2-zigtest.log`.

---

## Follow-on actions (execution log)

1. ✅ Parked `stash@{3}` (Layer 1F docs) to new branch `wip/layer-1f-design-docs-stash3`, committed as `ead52ba` (`docs(kotori): park Layer 1F design + plan from stash@{3} (Wave 3 seed)`). `git stash branch` consumed the stash from the list (old index `{3}` dropped). Not merged to `main`.
2. ⏸ Stash drops for `{0,1,2,4,5,6,7}` (original indices) deferred to wave close. Rationale: the classification is canonical (above); dropping them now adds git-state churn mid-wave with zero observability benefit. At wave close we can `git stash drop` each, after the post-mortem / measurement research doesn't need to inspect any of them. **Follow-up action**: at Phase 2 ADR close, drop stashes that remain classified as "drop" above, then update the disposition table with a "dropped at <sha>" column.
3. ✅ Smoke builds green — see checkbox block above.

---

## Incident note (during Phase 0a, for the record)

While inspecting stashes, the worker executed `git stash branch wip/layer-1f-design-docs-stash3 stash@{3}`, which applies the stash **and switches HEAD to the new branch** — this is normal `git stash branch` semantics, but produced an inflated dirty tree (the transient `.omc/state/*.json` that had been present on main at the moment of stash creation were now applied atop the new branch). Worker committed the two Layer 1F doc files only, stashed the remaining transient state (new stash entry: current `stash@{0}` "worker-alpha transient dirty state"), then attempted `git checkout master`. This **mis-targeted** `master` (a separate zephwm-line branch at `f30510d`, unrelated to kotori work); `git stash pop` there produced `DU` unmerged paths for `.omc/state/*.json` (those files don't exist on `master`). Worker `git rm -f` the conflicted ephemeral state (cache only, no information loss), then `git checkout main` cleanly — `main` is the kotori work line where `4cf67ed = wave2-base`. Root cause: the repo has two histories (`main` for kotori work, `master` for zephwm work); the initial git-status preamble said `Current branch: master` but HEAD was `4cf67ed` which lives only on `main` — HEAD must have been `main` at the moment of the Phase 0a kickoff despite the preamble string. Lesson: always `git branch --show-current` before taking actions that re-target HEAD.

The Phase 0a worker's own stash (`stash@{0}` "worker-alpha transient dirty state") is ephemeral — contains `.omc/state/*.json` only. Classified as **drop** at wave close with the rest.

**No code files were lost.** No branch moved. `wave2-base=4cf67ed` is still the correct frozen tip of `main`. Wave 2 proceeds.
