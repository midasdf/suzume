# kotori Layer 1F — Range + TreeWalker/NodeIterator — Implementation Plan

**Branch**: `feature/kotori-layer-1f-range` (created from main)
**Spec**: `docs/superpowers/specs/2026-04-19-kotori-1F-range-treewalker-design.md`
**Roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` Layer 1F
**Target delta**: +50 subtests (dom/ranges + dom/traversal)

## File Scope

All edits confined to **`src/js/kotori_runtime.zig`**.

Forbidden (active on other branches): `dom_selector.zig`, `dom_element.zig`, `events.zig`, `src/js/kotori/regex.zig`, `src/js/kotori/vm.zig`.

Plan docs and specs are read-only once written.

## Baseline (2026-04-19)

- dom/ranges: 892 / 3862 (23.1%)
- dom/traversal: 28 / 41 (68.3%)
- Total starting: 920 passing

## Tasks

- [ ] Task 1 — TreeWalker filter callable-each-traverse + TypeError (Gap C/F4)
  - File: `src/js/kotori_runtime.zig` `filterNode` at ~L1081-L1102
  - Spec: DOM §6.2 "filter a node"
  - Expected delta: +3 in dom/traversal (acceptNode-filter.html: "lacking acceptNode", "non-function acceptNode", "performs Get on every traverse")
  - Commit: `feat(kotori): TreeWalker filter every-traverse Get + TypeError (1F Task 1)`

- [ ] Task 2 — TreeWalker currentNode setter rejects non-Node (Gap D/F5)
  - File: `src/js/kotori_runtime.zig` `defGet(TWP, 'currentNode', …)` at ~L1120-L1123
  - Spec: DOM §6.1 IDL + Web IDL type checks
  - Expected delta: +1 (TreeWalker-currentNode.html "setting currentNode to non-Node values throws")
  - Commit: `feat(kotori): TreeWalker currentNode setter rejects non-Node (1F Task 2)`

- [ ] Task 3 — Range mutation hooks: CharacterData replace-data family (Gap A/F1)
  - File: `src/js/kotori_runtime.zig` Range polyfill closure ~L711-770
  - Spec: DOM §4.2 "replace data" + the per-algorithm Range update step
  - Hooks: `appendData`, `insertData`, `deleteData`, `replaceData` (and `data` setter if reachable) on `CharacterData.prototype` / `Text.prototype` / `Comment.prototype`
  - Expected delta: +200-400 (Range-mutations-{append,insert,delete,replace}Data + Range-mutations-dataChange)
  - Commit: `feat(kotori): Range boundary update on CharacterData mutations (1F Task 3)`

- [ ] Task 4 — Range mutation hooks: insertBefore/appendChild/replaceChild (Gap A/F2)
  - File: `src/js/kotori_runtime.zig`
  - Spec: DOM §4.2 "insert" / "append" / "replace" boundary updates
  - Expected delta: +100-200 (Range-mutations-{appendChild,insertBefore,replaceChild} unselected variants)
  - Commit: `feat(kotori): Range boundary update on child-list mutations (1F Task 4)`

- [ ] Task 5 — Range mutation hooks: splitText (Gap A/F3)
  - File: `src/js/kotori_runtime.zig`
  - Spec: DOM §4.2.8 "split a text node"
  - Expected delta: +50-100 (Range-mutations-splitText unselected variants)
  - Commit: `feat(kotori): Range boundary update on splitText (1F Task 5)`

- [ ] Task 6 — NodeIterator pre-remove (Gap F/F7)
  - File: `src/js/kotori_runtime.zig` — add LIVE_ITERATORS registry + hook into removeChild/replaceChild shadows
  - Spec: DOM §6.2 "NodeIterator pre-remove steps"
  - Expected delta: +10-50 (NodeIterator-removal.html)
  - Commit: `feat(kotori): NodeIterator pre-remove reference update (1F Task 6)`

- [ ] Task 7 — Final verification + measurement
  - Run full dom/ranges + dom/traversal
  - Record deltas
  - Merge to main if +50 achieved
  - Commit: merge commit

## Verification Protocol

Per task:
1. `zig build` → green
2. Targeted WPT test run: `cd /tmp/wpt && bash /home/midasdf/suzume/tests/wpt/run_wpt_parallel.sh --jobs 6 --port <unique> dom/<area>`
3. Record before/after pass count
4. If regression, root-cause in production code (NOT the test)

Final:
- `zig build test` green
- No dom/nodes regression (spot check)
- `git log --oneline` shows sub-commit per task

## Risk Log

- Shadowing `CharacterData.prototype.appendData` etc. may not catch native calls made from C++ internals (e.g., if `innerHTML=` does direct data mutation). Mitigation: audit `kotori_runtime.zig` for data-setter installation; if absent from JS side, the test matrix in Range-mutations-{append,insert,delete}Data will still exercise JS-level calls since the test calls node.appendData() explicitly.
- `Text.prototype.splitText` may not be a JS-visible prototype method. If `typeof Text.prototype.splitText !== 'function'`, Task 5 becomes a no-op + skipped; document and move on.
- DocumentFragment insertion multi-child count: use childNodes delta before/after as the insertion count.
- Iterator pre-remove needs to fire BEFORE the actual removal so the tree state is still reachable.  That means we need a pre-hook, not a post-hook.  Shadow `removeChild` to compute the reference changes before calling orig.
