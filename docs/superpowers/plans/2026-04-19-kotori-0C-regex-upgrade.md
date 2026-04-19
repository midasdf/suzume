# kotori Layer 0C — RegExp Upgrade — Implementation Plan

**Goal:** Replace the minimal NFA-style backtracker in `vm.zig` with an ECMA-262 §22.2 compliant backtracking RegExp engine in a new dedicated module `src/js/kotori/regex.zig`. Add lookaround, back-references, named captures, `s` / `y` / `u` flags, basic Unicode property escapes, and `lastIndex` / `groups` result wiring. Target +500 WPT subtests, primarily in `dom/nodes` (testharness regex usage) and any `js/regexp/*` area reachable.

**Architecture:** Two-pass design — parse to AST, compile to flat opcode program, execute via backtracking NFA VM. See [`docs/superpowers/specs/2026-04-19-kotori-0C-regex-upgrade-design.md`](../specs/2026-04-19-kotori-0C-regex-upgrade-design.md).

**Spec:** `docs/superpowers/specs/2026-04-19-kotori-0C-regex-upgrade-design.md`
**Parent roadmap:** `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` § Layer 0C

---

## File Structure

### Files to create

- `src/js/kotori/regex.zig` — the replacement engine. Self-contained. Depends only on `std`.
- `tests/test_kotori_regex.zig` — unit tests for the new module.

### Files to modify

- `src/js/kotori/vm.zig`
  - `createRegExp` — expand flag parsing from `gim` to `gimsuy`, write new fields.
  - Nine `regexSearch(...)` call sites — swap to `kotori_regex.searchLegacy(...)`.
  - `nativeRegExpExec` — populate `groups` property when named groups are present; advance `lastIndex` when `g` or `y` is set.
  - `nativeRegExpTest` — honor `sticky` / `lastIndex`.
  - Delete the entire inline regex engine (`regexSearch` through `matchCharClass`, ~476 lines).
- `src/js/kotori/object.zig`
  - Add fields `dot_all`, `sticky`, `unicode`, `last_index` to `RegExpData` struct.
- `build.zig`
  - Add `regex` test module to the kotori unit-tests aggregate so `zig build test-kotori` picks up `test_kotori_regex.zig`.

### Files NOT to modify

- `src/js/kotori/parser.zig` — regex literal parser already reads every needed byte including full flag alphabet.
- `src/js/kotori/lexer.zig`, `compiler.zig`, `bytecode.zig`, `ast.zig`, `token.zig`, `value.zig`, `string_pool.zig`, `kotori.zig`, `kotori_io.zig`.
- Any file outside `src/js/kotori/` except `build.zig` and the new test file.

---

## Task 0 — Audit & Baseline (no code)

- [x] **Step 0.1:** Confirm callers. `grep -n "regexSearch(" src/js/kotori/vm.zig` → expect 9 call sites at (3706, 3822, 3841, 6419, 6430, 6462 def, 6497, 7854, 7865, 7922, 7960). Branch-logs the numbers that need rewiring.
- [x] **Step 0.2:** Confirm `RegExpData` shape at `src/js/kotori/object.zig:76`.
- [x] **Step 0.3:** Capture the baseline `zig build test-kotori` pass count. On HEAD of `main`: 655/689 pass, 13 fail, 21 crash — pre-existing, not regex-related (grep confirmed: zero regex tests fail).
- [x] **Step 0.4:** Assert parser already accepts `gimsuyv` (`parser.zig:617-625`).

---

## Task 1 — Architecture skeleton (Commit #1)

Scaffolds the new module and wires it end-to-end with every existing feature plus nothing new. Backward compatible. All pre-existing regex tests in `tests/test_kotori_vm.zig:1848-2115` pass.

### 1.1 Create `src/js/kotori/regex.zig`

- [ ] Introduce module-level types: `Flags`, `MatchSlot`, `Op` (union), `Compiled`, `LegacyResult`.
- [ ] Implement `Parser` — reads Pattern / Disjunction / Alternative / Term / Atom / Quantifier productions. Atom subset: capturing `(...)`, non-capturing `(?:...)`, `.`, char class, class escapes (`\d \D \s \S \w \W \b \B`), char escapes (`\n \t \r \f \v \0 \cX`), `\xHH`, `\uXXXX`, ASCII identity escape, bare character.
- [ ] Implement `Compiler` — lowers AST into a `[]Op` program. Allocates group numbers in source order. Emits `split` / `jump` for `*`, `+`, `?`, `{n,m}`, `|`. Emits `save` for capturing groups.
- [ ] Implement `exec(c, input, start_index) -> ?Result` — backtracking VM with explicit stack. 100 000 step fuel. Returns captures and group_count.
- [ ] Implement `search(c, input) -> ?Result` — tries exec at each position until a match or end of input.
- [ ] Implement `searchLegacy(pattern, str, flags_struct) -> ?LegacyResult` — compile + search + free, copy first 16 captures into fixed-size array for compat.
- [ ] Test module self-terminates on compile errors (`CompileError.InvalidPattern`) and returns `null` to callers on exec-time failure. Spec behavior: RegExp constructor throws SyntaxError; legacy callers fall back to null for now (matches current behavior where malformed patterns silently produce no match).

### 1.2 Update `src/js/kotori/object.zig`

- [ ] Extend `RegExpData`:
  ```zig
  pub const RegExpData = struct {
      source: StringId,
      global: bool = false,
      ignore_case: bool = false,
      multiline: bool = false,
      dot_all: bool = false,
      sticky: bool = false,
      unicode: bool = false,
      last_index: u32 = 0,
  };
  ```
- [ ] Verify no serializer / GC walker reads every field — grep for `regexp_data.` in `src/`. (`vm.zig` only reads `source`, `global`, `ignore_case`, `multiline`. Safe to add fields.)

### 1.3 Update `src/js/kotori/vm.zig`

- [ ] Add `const kotori_regex = @import("regex.zig");` near the existing local imports.
- [ ] In `createRegExp`, extend flag parsing:
  ```zig
  'g' => global = true,
  'i' => ignore_case = true,
  'm' => multiline = true,
  's' => dot_all = true,
  'y' => sticky = true,
  'u' => unicode = true,
  else => {}, // silently ignored, matches current behavior
  ```
  Write all fields. Add `dotAll`, `sticky`, `unicode`, `lastIndex` own properties on the new RegExp object (non-writable bool, writable number for lastIndex).
- [ ] Helper `fn regexpFlags(re: ObjData.regexp_data) kotori_regex.Flags { ... }` — build the Flags struct from the stored booleans. Used by every caller.
- [ ] Replace each `regexSearch(pattern, str, re.ignore_case)` with `kotori_regex.searchLegacy(pattern, str, regexpFlags(re))`. Nine sites.
- [ ] Leave `VM.MatchResult` and `VM.RegexResult` in place — the shim returns the same shape. (Alternative: delete them and use `kotori_regex.LegacyResult` directly. Defer — aim for minimal diff.)
- [ ] **Delete** the inline regex engine: lines ~6448-6938 (`regexSearch`, `simpleMatch`, `regexExpr`, `regexSeq`, `regexSeqAt`, `regexCharMatch`, `isWordChar`, `isSpaceChar`, `toLowerAscii`, `isWordBoundary`, `regexAtomLen`, `findCloseParen`, `findTopPipe`, `BraceQuant`, `parseBraceQuant`, `parseUnicodeEscape`, `matchCharClass`). Their moral equivalents now live inside `regex.zig`.
- [ ] Check if `isWordChar` / `isSpaceChar` / `toLowerAscii` are referenced elsewhere — keep if so. (Initial grep: only used inside the deleted block.)

### 1.4 Create `tests/test_kotori_regex.zig`

- [ ] Pure-Zig unit tests (no VM needed). One test per opcode family. Test list for Commit #1:
  - char, any, dot (no dotAll)
  - char class basics, ranges, negation, escapes inside class
  - boundary `\b` `\B`
  - anchors `^` `$`
  - alternation `a|b`, three-way
  - groups capturing + non-capturing, group numbering
  - quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, lazy variants
  - ignore_case for ASCII
  - pathological: `/(a+)+b/` on non-matching input bounded by step budget returns null instead of hanging

### 1.5 Wire into build.zig

- [ ] Create `test_kotori_regex_mod` module; add `.addImport("kotori_regex", ...)` that points at `src/js/kotori/regex.zig`.
- [ ] Append to `kotori_all_test_mod.addImport(...)` and make `kotori_tests` depend on the new module.

### 1.6 Build & verify

- [ ] `zig build test-kotori` — new test module runs, everything green.
- [ ] `zig build` — full executable build passes.
- [ ] Re-run existing `tests/test_kotori_vm.zig` regex tests (1848-2115): expect the same 0 failures as baseline.
- [ ] **Commit message**: `feat(kotori): Layer 0C Task 1 — new regex.zig module (skeleton, parity with current engine)`

---

## Task 2 — Lookahead & lookbehind (Commit #2)

### 2.1 Parser extensions

- [ ] Extend `Parser` in `regex.zig` to recognize four new Atom forms:
  - `(?=` Disjunction `)` → positive lookahead
  - `(?!` Disjunction `)` → negative lookahead
  - `(?<=` Disjunction `)` → positive lookbehind
  - `(?<!` Disjunction `)` → negative lookbehind
- [ ] Guard: `(?<` followed by identifier-start defers to **named group** (Task 3), not lookbehind.

### 2.2 Compiler extensions

- [ ] Emit `assert_ahead` / `assert_behind` opcode with `negate: bool, body_ip: u32, end_ip: u32`.
- [ ] Body is compiled inline but terminated by `match_end`. The outer program skips over the body: `assert_ahead` increments ip past `end_ip` on success.

### 2.3 VM extensions

- [ ] Add `assert_ahead` handler — runs a nested exec loop from `body_ip` starting at current sp. On success (match_end reached), if `!negate` → fall through with captures updated; if `negate` → backtrack. If the inner exec exhausts backtrack stack without match, inverse.
- [ ] Add `assert_behind` handler — for each possible start position `[0 .. sp]`, run exec looking for a match that ends exactly at sp. Return success on first match (non-negate) or none (negate).
  - Optimization: bound the search by the assertion's maximum-match length, but for a clean landing just scan backwards.

### 2.4 Tests

- [ ] `tests/test_kotori_regex.zig`: positive/negative lookahead, positive/negative lookbehind, each with capture-preservation semantics.
- [ ] `tests/test_kotori_vm.zig`: end-to-end via `evalExpr`:
  ```js
  "foobar".match(/foo(?=bar)/)   // -> ["foo"]
  "foobaz".match(/foo(?!bar)/)   // -> ["foo"]
  "foobar".match(/(?<=foo)bar/)  // -> ["bar"]
  "zbar".match(/(?<!foo)bar/)    // -> ["bar"]
  ```

### 2.5 Build & verify

- [ ] `zig build test-kotori` green.
- [ ] **Commit**: `feat(kotori): Layer 0C Task 2 — regex lookahead and lookbehind`

---

## Task 3 — Backrefs & named groups (Commit #3)

### 3.1 Parser extensions

- [ ] `(?<name>Disjunction)` — allocate a numeric capture index, record name → index in a `named: []NamedGroup` side-table.
- [ ] `\k<name>` — parse name, store string → index at compile time; emit `back_ref`.
- [ ] `\1` through `\9`, then `\10` etc. — `DecimalEscape`. Spec rule: `\N` is a backref iff `N <= group_count` at parse completion; otherwise it's an octal escape or an identity escape. For simplicity land the common case: `\N` where `1 <= N <= group_count_so_far` is a backref; else literal `N`. (Spec-perfect single-pass requires a lookahead that we defer.)

### 3.2 Compiler extensions

- [ ] Emit `back_ref {group: u16}` opcode.
- [ ] `Compiled.named` populated from parser side-table.

### 3.3 VM extensions

- [ ] `back_ref` handler — look up `captures[group]`, fail if unset, else consume the same byte sequence (with ignoreCase where flag is set).

### 3.4 nativeRegExpExec wiring

- [ ] In `vm.zig` `nativeRegExpExec`, after populating the result array with captures, construct a `groups` object when `Compiled.named.len > 0`, map each name → capture string (or `undefined` when unmatched), and set as own property `groups`.

### 3.5 Tests

- [ ] Unit: backref works, fails when group didn't match, works across lookahead boundary.
- [ ] Unit: named group compiles, numbering stable across mixed named + unnamed.
- [ ] Integration:
  ```js
  "aa".match(/(a)\1/)              // ["aa", "a"]
  "abab".match(/(ab)\1/)           // ["abab", "ab"]
  "abc123".match(/(?<x>\d+)/).groups.x   // "123"
  "aa".match(/(?<x>a)\k<x>/)[0]    // "aa"
  ```

### 3.6 Build & verify

- [ ] `zig build test-kotori` green.
- [ ] **Commit**: `feat(kotori): Layer 0C Task 3 — regex backrefs + named groups + groups result`

---

## Task 4 — Unicode / sticky / dotAll flags (Commit #4)

### 4.1 `s` flag (dotAll)

- [ ] `any` opcode handler consults `Flags.dot_all`; when true, matches line terminators as well.

### 4.2 `y` flag (sticky)

- [ ] `search()` and caller-side `nativeRegExpExec` / `nativeRegExpTest`: when sticky is set, do **not** scan; attempt match at `RegExpData.last_index` only.
- [ ] Advance `last_index` on successful match when `g` or `y` is set; reset to 0 on failure (when `y`).
- [ ] Expose `lastIndex` as a writable own number property.

### 4.3 `u` flag (Unicode)

- [ ] Input iteration inside the VM switches on `flags.unicode`:
  - Non-unicode: byte-by-byte, existing behavior.
  - Unicode: decode UTF-8 at sp; `char`, `any`, `char_class` consume full code point.
- [ ] Parser: recognize `\u{XXXXXX}` code-point escape when in Unicode mode; accept `\u{X}`..`\u{10FFFF}`.
- [ ] Parser: stricter syntax per §22.2.2.9 — in `u` mode reject invalid escapes (`\p{` outside Unicode mode throws), `{n,m}` must be well-formed, `]` not allowed unescaped outside class.

### 4.4 `\p{…}` basic property escapes

- [ ] Ship constant range tables in `regex.zig` for: `L` / `Letter`, `Nd` / `Decimal_Number`, `White_Space` / `Space`, `ASCII`, `Any`.
- [ ] `char_class` tables can reference those arrays by index.
- [ ] Outside `u` mode, parser treats `\p{...}` as an error (or identity) per spec.

### 4.5 Tests

- [ ] Unit: dotAll consumes `\n`; no-dotAll rejects.
- [ ] Unit: sticky only matches at lastIndex.
- [ ] Unit: Unicode mode decodes `\u{1F600}` (emoji = 4 bytes UTF-8) and matches.
- [ ] Unit: `/\p{L}+/u` matches non-ASCII letters; `/\p{Nd}/u` matches digits.
- [ ] Integration:
  ```js
  /a.b/s.test("a\nb")                          // true
  (() => { const r = /abc/y; r.lastIndex = 3; return r.test("xyzabc"); })()   // true
  "\u{1F600}".match(/\u{1F600}/u)[0]           // "\u{1F600}"
  "héllo".match(/\p{L}+/u)[0]                  // "héllo"
  ```

### 4.6 Build & verify

- [ ] `zig build test-kotori` green.
- [ ] **Commit**: `feat(kotori): Layer 0C Task 4 — regex unicode, sticky, and dotAll flags`

---

## Task 5 — WPT measurement + merge

- [ ] Run `scripts/wpt_run.sh` (or equivalent) across `dom/nodes` on feature branch. Capture pass rate.
- [ ] Diff against baseline (68.2% / 5367 passing). Report delta.
- [ ] If measurable, also run `js/regexp/*` area.
- [ ] Author final commit message aggregating findings.
- [ ] Merge to `main` via fast-forward or rebase — follow repo convention. (The existing 0A/1A/1B branches were merged via `git merge`.)

---

## Verification checklist (before declaring done)

- [ ] `zig build` passes.
- [ ] `zig build test-kotori` — new test module + existing tests all green. Pre-existing non-regex failures stay at their baseline count (13 fail, 21 crash).
- [ ] `tests/test_kotori_vm.zig:1848-2115` — every existing regex test passes.
- [ ] WPT dom/nodes delta measured and reported.
- [ ] Branch pushed (or merged per repo flow).

## Risk register

* **Backtracking on pathological patterns**: step-budget cap keeps us bounded. Same trade-off as current engine.
* **UTF-8 boundary math**: Unicode mode must not advance sp into the middle of a code point. Solid test coverage per Task 4.1 mitigates.
* **`\p{...}` table size**: ~2k total ranges across the five properties. Minor binary-size impact.
* **Existing capture-array size (16)**: kept for back-compat. Patterns with > 16 capturing groups silently drop trailing groups — same as current behavior. Spec requires unlimited; marked as deferred gap in the spec.

