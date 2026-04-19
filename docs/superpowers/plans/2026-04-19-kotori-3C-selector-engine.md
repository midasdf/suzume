# Kotori Layer 3C — Selector Engine Correctness (Implementation Plan)

**Spec**: `docs/superpowers/specs/2026-04-19-kotori-3C-selector-engine-design.md`
**Branch**: `feature/kotori-layer-3c`
**Target**: +1500 subtests in `css/selectors`

## Pre-Flight

- [x] Branch `feature/kotori-layer-3c` created
- [x] `zig build` verified clean on entry
- [ ] Baseline WPT run: `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 css/selectors 2>&1 | tail -80` — **pasted below**

## Baseline (HEAD f40d232)

Baseline results will be inserted here after the initial run completes.

## Commits

### Commit 1 — `fix(kotori 3C): SyntaxError messages include selector + method name`

**Files**: `src/js/dom_selector.zig`

- Add helper `fn throwSelectorSyntax(c, method, sel)` producing `"Failed to execute '<method>': '<sel>' is not a valid selector."`
- Replace six broken call sites (lines 1351, 1371, 1400, 1422, 1590, 1610) with the helper using the correct method name.

**Verify**: `zig build && zig build test`

### Commit 2 — `fix(kotori 3C): bump selector parts buffer 16→64`

**Files**: `src/js/dom_selector.zig`

- `[16]SelectorPart` → `[64]SelectorPart` at `matchSingleSelector`, `walkTreeBySelector`, `walkTreeCollect`.

**Verify**: `zig build && zig build test`

### Commit 3 — `feat(kotori 3C): namespace selector validation per Selectors L4 §6`

**Files**: `src/js/dom_selector.zig`

- Rewrite `hasUndeclaredNamespace` → `selectorHasUndeclaredNamespace` with proper tokenizer
- Accept: empty prefix (`|E`), `*`, known prefixes (`html/svg/math/mathml/xlink/xml`)
- Reject: any other prefix
- Skip attribute operators `|=`, attribute-scoped `[*|attr]`, escaped `\|`
- Fix `|E` null-NS branch in `matchSingleSimple` to check `elem.node.ns == 0`
- Handle `[*|attr]` and `[prefix|attr]` attribute namespace prefixes

**Verify**: `zig build && zig build test`

### Commit 4 — `feat(kotori 3C): reject empty/pseudo-element args in :is/:where`

**Files**: `src/js/dom_api.zig` (selector validation shim regex extensions)

- Add regex guards: `:is(\s*)` / `:where(\s*)` → SyntaxError
- Add: pseudo-element inside `:is()`/`:where()` → SyntaxError
- Ensure `:not()` already covered (pseudo-element rejection exists at line 5940)

**Verify**: `zig build && zig build test`

### Commit 5 — `feat(kotori 3C): attribute selector namespace polish`

**Files**: `src/js/dom_selector.zig`

- Extend `matchAttributeSelector` to handle `[|attr]`, `[*|attr]`, `[prefix|attr=...]` with known-prefix lookup.

**Verify**: `zig build && zig build test`

## Final Verification

- [ ] `zig build` → exit 0
- [ ] `zig build test` → all tests pass
- [ ] `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 css/selectors 2>&1 | tail -80` → WPT delta recorded

## Regression Guard

Spot-check the four already-covered areas to ensure no regression:

- `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 dom/nodes 2>&1 | tail -10`
- `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 dom/events 2>&1 | tail -10`
- `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 html/dom 2>&1 | tail -10`
- `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 css/cssom 2>&1 | tail -10`

## Merge

- `git checkout main && git merge --ff-only feature/kotori-layer-3c` if history linear
- Else `git merge --no-ff feature/kotori-layer-3c` with message noting spec + plan references.
