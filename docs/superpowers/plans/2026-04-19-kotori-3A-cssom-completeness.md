# kotori Layer 3A — CSSOM Completeness Plan

**Branch**: `feature/kotori-layer-3a-cssom`
**Spec**: `docs/superpowers/specs/2026-04-19-kotori-3A-cssom-completeness-design.md`
**Baseline target**: `tests/wpt/ run_wpt_parallel.sh css/cssom` — currently 135/677 (19.9 %), target ≥ 435/677 (+300).

---

## Task list

### Pre-flight
- [x] Branch `feature/kotori-layer-3a-cssom` created from `main`.
- [x] Read `src/css/cssom/style_decl.zig`, `src/css/cssom/shorthand_serialize.zig`, `src/css/parser.zig`.
- [x] Confirm file isolation (no edits outside `src/css/cssom/*` + `src/css/parser.zig`).
- [x] Capture baseline: `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9883 css/cssom 2>&1 | tee /tmp/cssom_baseline.txt`.

### Commit 1 — `!important` parse robustness
Files: `src/css/cssom/style_decl.zig`.

- [ ] Extend `endsWithImportant` to:
  - Strip trailing CSS comments + whitespace before matching `important`.
  - Walk backwards over optional whitespace + optional trailing comments between `!` and `important`.
  - Return trimmed remainder.
- [ ] Unit tests:
  - `color: red !important` → `red`, important.
  - `color: red ! important` → `red`, important.
  - `color: red !IMPORTANT` → `red`, important.
  - `color: red !important /* x */` → `red`, important.
  - `color: red /* x */ !important` → `red`, important.
  - `color: red !foo` → `red !foo` left alone, not important.
- [ ] `zig build && zig build test` green.
- [ ] Commit `fix(cssom): robust !important detection with comments and whitespace`.

### Commit 2 — shorthand expansion via parseIntoList / cssText setter
Files: `src/css/cssom/style_decl.zig`, `src/css/cssom/shorthand_serialize.zig`.

- [ ] Add `longhandsFor(name)` + `isKnownShorthand(name)` in `shorthand_serialize.zig`.
- [ ] Add `splitTrblValue(value, &out)` — returns 1/2/3/4 + filled slots; rejects `inherit`/`initial`/`unset`/`revert` by returning `0` so caller handles CSS-wide keywords itself.
- [ ] Add `expandShorthandValueInto(list, alloc, name, value, important)` helper in `style_decl.zig`:
  - Handles CSS-wide keyword (same keyword to all longhands).
  - Calls TRBL splitter for `margin` / `padding` / `border-*`.
  - Calls flex / flex-flow expansion (reusing logic already in dom_api for the JS path? — no, it lives under `src/css/properties.zig::expandShorthand` which is only reachable inside `src/css/*`, so we can call it directly).
  - Falls back to storing the shorthand as-is if not recognised.
- [ ] Call `expandShorthandValueInto` from `parseIntoList` after reading each declaration.
- [ ] Unit tests:
  - `parseIntoList("margin: 10px")` → four longhands, each `10px`.
  - `parseIntoList("margin: 1px 2px")` → top/bottom=1px, right/left=2px.
  - `parseIntoList("padding: 1px 2px 3px 4px")` → four values.
  - `parseIntoList("flex: 1 1 0%")` → three longhands.
  - `parseIntoList("margin: inherit")` → four longhands all `inherit`.
  - `parseIntoList("margin: 1px !important")` → four longhands, all important.
  - `serialize()` of expanded longhands → matches upstream (canonical round-trip).
- [ ] `zig build && zig build test` green.
- [ ] Commit `feat(cssom): expand CSS shorthands when parsing declarations`.

### Commit 3 — CSS Syntax §5 error recovery polish
Files: `src/css/parser.zig`.

- [ ] Add private `skipBadRule(self)` that consumes until the next balanced `}` at depth 0, or `;` if no `{` has been seen.
- [ ] Use `skipBadRule` from `parseAtRule` unknown branch (already `skipAtRule`, confirm depth correctness; rename only if behaviour changes).
- [ ] In `parseDeclaration`, after stripping `!important`, if the remaining tokens are empty, discard the declaration.
- [ ] In `parseStyleRuleInner`, if a `{` occurs inside the selector text (malformed nesting), treat as rule boundary and emit empty rule, skip the orphan block.
- [ ] Unit / integration tests (inline in parser.zig):
  - `".a { color: red } @!@@; .b { color: blue }"` → two rules parsed (`.a` + `.b`).
  - `".a { color: }" + ".b { color: blue }"` → `.a` has zero declarations, `.b` intact.
  - `"@unknown foo {invalid}; .a { color:red }"` → `.a` survives.
- [ ] `zig build && zig build test` green.
- [ ] Commit `fix(css-parser): recover from invalid rules per CSS Syntax §5`.

### Commit 4 — declaration sanity (empty value, custom-prop whitespace, webkit alias for cssText setter)
Files: `src/css/cssom/style_decl.zig`.

- [ ] In `parseIntoList`: if value is empty after trimming, skip (don't store).
- [ ] Special-case custom properties (`--*`): preserve exact whitespace in value (only strip one leading+trailing space per CSS Variables §2.1).
- [ ] Ensure `resolveWebkitAlias` is applied both in `upsert` AND `parseIntoList`.
- [ ] Unit tests:
  - `parseIntoList("color: ;")` → zero entries.
  - `parseIntoList("--x:   foo   ")` → one entry, value `"foo"` (trimmed per spec).
  - `parseIntoList("--x:  ")` → one entry, value `""` (empty var is valid).
  - `parseIntoList("-webkit-order: 3")` → stored under `order`.
- [ ] `zig build && zig build test` green.
- [ ] Commit `fix(cssom): declaration parse normalisation for empty + custom properties`.

### Final — WPT verification + docs
- [ ] Re-run `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9883 css/cssom 2>&1 | tee /tmp/cssom_final.txt`.
- [ ] Compute delta, record baseline / final counts.
- [ ] Append progress to `.omc/notepads/kotori-layer-3a-cssom/progress.md` if directory exists (skip silently otherwise).
- [ ] Merge branch into `main` only if:
  - All commits build & test clean.
  - WPT delta ≥ +300 subtests OR stalls are root-caused and documented.

## Rollback
- `git reset --hard <pre-commit>` on the feature branch if any commit introduces a regression in `css/cssom` count.
