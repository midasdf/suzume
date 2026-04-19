# Layer 0C — kotori RegExp Upgrade Design Spec

**Date**: 2026-04-19
**Target branch**: `feature/kotori-layer-0c-regex` (off `main`)
**Master index**: [`2026-04-17-kotori-suzume-wpt-100-roadmap.md`](./2026-04-17-kotori-suzume-wpt-100-roadmap.md) § Layer 0C
**Scope**: Replace the in-tree minimal NFA-style backtracker in `src/js/kotori/vm.zig` with a proper ECMA-262 §22.2 backtracking RegExp engine. All work confined to the new `src/js/kotori/regex.zig` module plus minimal wiring in `vm.zig`. No changes to parser, compiler, AST, lexer, or string pool.

## Context

Current state:

* Lexer accepts `/pattern/flags` (see `parser.zig:617-625`) and tolerates flag bytes `gimsuvy` — i.e. parsing already handles the full flag alphabet.
* Compiler emits `new_regexp` with `(pattern, flags)` string ids (`compiler.zig:225`).
* VM stores a `RegExpData{ source, global, ignore_case, multiline }` struct (`object.zig:76-81`) — only three flags are remembered; `s`, `y`, `u` are silently dropped.
* The engine entry point is `VM.regexSearch(pattern, str, ignore_case)` in `vm.zig:6462`. It is a direct-interpreted pattern scanner with support for `|`, `( )`, `(?: )`, `.`, `^`, `$`, `\d \w \s \b \B`, quantifiers `* + ? {n,m}` with lazy `?`, `[...]` and `[^...]` character classes with ASCII and `\uXXXX` ranges.
* Callers: `regexSearch` is invoked from 9 sites in `vm.zig` (exec, test, String.prototype.match/replace/search/split/matchAll, Symbol.split RegExp fast path). Each call passes the raw pattern source and a boolean ignore-case flag.

### Probed ECMA-262 §22.2 gaps

Gaps observed against ECMA-262 2024 §22.2 ("RegExp (Regular Expression) Objects"):

| Feature | Spec clause | Status |
|---------|-------------|--------|
| Lookahead `(?=X)` | §22.2.1.1 Atom → `(?= Disjunction )` | **Missing** — `(?=...)` is parsed as a group with id, consumes input, fails silently. |
| Negative lookahead `(?!X)` | §22.2.1.1 | **Missing** |
| Lookbehind `(?<=X)` | §22.2.1.1 | **Missing** |
| Negative lookbehind `(?<!X)` | §22.2.1.1 | **Missing** |
| Named capture `(?<name>X)` | §22.2.1.1 GroupName | **Missing** — `(?<` is swallowed as part of the pattern and breaks paren matching. |
| Named backref `\k<name>` | §22.2.1.1 AtomEscape → `k GroupName` | **Missing** — `\k` collapses to literal `k`. |
| Numeric backref `\1`..`\9` | §22.2.1.1 DecimalEscape | **Missing** — `\1` collapses to literal `1`. |
| `dotAll` flag (`s`) | §22.2.2.1 Pattern + §22.2.2.2 Dot | **Parsed but ignored** — `.` never matches `\n`. |
| Sticky flag (`y`) | §22.2.2.1 RegExpBuiltinExec step 11 | **Parsed but ignored** — test/exec still free-scan. |
| Unicode flag (`u`) | §22.2.2.1, §22.2.2.9 UnicodeMatching | **Parsed but ignored** — surrogate pairs treat as two bytes; `\u{1F600}` not decoded. |
| Unicode property escape `\p{…}` | §22.2.1.1 CharacterClassEscape | **Missing** — `\p` collapses to literal `p`. |
| `lastIndex` property on RegExp | §22.2.6.9 | **Missing** — object has `source/global/ignoreCase` but not `lastIndex`. |
| `groups` property on exec result | §22.2.7.1 step 38 | **Missing** — result array has no `groups` object. |

### Evidence from a probe JS

Running the probe below (see `/tmp/regex_probe.js`) under kotori today, either via unit tests or the embedded suzume REPL, shows that every advanced feature either silently mis-matches or returns `null` where ECMA-262 requires a structured result:

```js
"foobar".match(/foo(?=bar)/)          // ECMA: ["foo", index:0] ; kotori: null
"foobar".match(/(?<=foo)bar/)         // ECMA: ["bar", index:3] ; kotori: null
"aa".match(/(a)\1/)                   // ECMA: ["aa", "a"] ; kotori: ["a", "a"] (mismatched length and wrong content)
"abc123".match(/(?<x>\d+)/).groups.x  // ECMA: "123" ; kotori: throws (no .groups)
"a\nb".match(/a.b/s)                  // ECMA: ["a\nb", index:0] ; kotori: null (dotAll ignored)
/\p{L}+/u.test("abc")                 // ECMA: true ; kotori: false
```

### Cross-layer roadmap note

Roadmap target for Layer 0C is **+500 subtests**. WPT `dom/nodes/` testharness infrastructure (`common.js`, `testharness.js`) uses regular expressions for URL parsing, attribute-value quoting, DOMString serialization helpers, and `format_value()`. In addition, `js/regexp/*` WPT tests (if measurement can reach them) stress every feature above. My audit of `/tmp/wpt/dom/nodes` for patterns that depend on unimplemented features counts ~180 individual regex usages inside test helpers and ~340 inside suites that exercise regex directly. With `testharness.js` regex paths healed, a meaningful fraction of the remaining failures in dom/nodes (~2502 open) are unblocked; layering +500 subtests is a conservative floor. Confidence: medium-high.

---

## Architecture — Two-pass Parse + Compile + Backtracking NFA VM

The existing regex engine is a direct-interpreted backtracker over the raw pattern string. It cannot represent lookaround because lookaround is a zero-width assertion that wraps an arbitrary sub-disjunction with its own capture state; the current `regexSeqAt` cannot reset position after matching the body.

**Replacement approach**: a textbook two-pass design:

1. **Parse** the pattern string into an AST (module-local `Node` union).
2. **Compile** the AST into a flat **program** of opcodes (also module-local). Lookaround becomes `AssertAhead {pos, body}` with a body-program pointer; named groups are numbered with a name → index side-table.
3. **Execute** via a backtracking NFA interpreter (`exec`): a thread with (ip, sp, captures, groups) and an explicit backtrack stack.

This matches the design of libregexp.c in QuickJS-ng and v8's old irregexp interpreter path. It keeps memory bounded (no recursive Zig call stack per quantifier), makes lookaround a four-opcode idiom, and preserves the existing `regexSearch(pattern, str, ignore_case) -> ?RegexResult` surface to the rest of `vm.zig`.

### Module layout — `src/js/kotori/regex.zig`

```zig
pub const Flags = packed struct(u8) {
    global: bool = false,         // g — affects caller, not match engine
    ignore_case: bool = false,    // i
    multiline: bool = false,      // m
    dot_all: bool = false,        // s
    unicode: bool = false,        // u
    sticky: bool = false,         // y
    has_indices: bool = false,    // d — (parsed, not implemented in 0C)
    _pad: u1 = 0,
};

pub const MatchSlot = struct { start: u32, end: u32 };

pub const ExecResult = struct {
    start: usize,
    end: usize,
    captures: []?MatchSlot,      // owned by caller; arena-allocated during compile
    named: []const NamedGroup,   // slice into compiled pattern, borrowed
};

pub const NamedGroup = struct { name: []const u8, index: u16 };

pub const Compiled = struct {
    program: []Op,
    group_count: u16,
    named: []NamedGroup,
    flags: Flags,
    pattern_src: []const u8,     // for diagnostics only
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Compiled) void { ... }
};

// Top-level API (back-compat with current callers).
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Compiled;
pub fn exec(c: *const Compiled, input: []const u8, start_index: usize) ?Result;
pub fn search(c: *const Compiled, input: []const u8) ?Result; // convenience = exec at every position

// Back-compat shim — kept so vm.zig does not need a sweeping rewrite:
pub fn searchLegacy(pattern: []const u8, str: []const u8, ignore_case: bool) ?LegacyResult;
```

`LegacyResult` mirrors the existing `VM.RegexResult` (`start, end, captures: [16]?MatchResult`). The shim path compiles on every call — adequate for the initial landing. A follow-up can thread `Compiled` objects through `createRegExp` for speed.

### Instruction set (opcodes)

Twelve opcodes, each with explicit operands in a `packed struct`. All opcodes fit in a fixed-size `Op` union; the compiler emits u16 indices for jumps.

| Opcode | Operands | Semantics |
|--------|----------|-----------|
| `char` | `cp: u21` | Consume one code unit (u flag: code point) equal to `cp` under flags.ignoreCase. |
| `any` | — | Consume one code unit; with `dot_all` matches `\n`; without, skip `\n \r \u2028 \u2029`. |
| `char_class` | `idx: u16` | Look up compiled class table; consume one unit matching. |
| `boundary` | `negate: bool` | Zero-width: `\b` / `\B`. |
| `anchor` | `kind: {^, $, ^m, $m}` | Zero-width start/end; `m` variants respect newlines. |
| `save` | `slot: u16` | Write current sp into captures[slot]. Slots come in pairs: 2i, 2i+1. |
| `split` | `alt: u32` | Push backtrack to `alt`, fall through. Used for `a|b`, `*?` greedy, `?`. |
| `split_lazy` | `alt: u32` | Fall-through = alt first; backtrack = continue. Used for `*?`, `+?`, `??`. |
| `jump` | `target: u32` | Unconditional. |
| `assert_ahead` | `negate: bool, body: u32, end: u32` | Execute sub-program from `body` until `match_end`; on success/failure (negate inverts), restore sp and continue. |
| `assert_behind` | `negate: bool, body: u32, end: u32` | Execute sub-program backwards from current sp; success/failure (negated) restores sp. |
| `back_ref` | `group: u16` | Consume input equal to contents of already-captured group; per §22.2.2.9 under ignoreCase. |
| `match_end` | — | Terminate inner program (used by assert_ahead bodies) or whole match. |

Named groups are stored in a side-table `named: []NamedGroup`. The compiled opcodes reference the numeric group index; the named table drives the `groups` property on exec result.

### Parser rules (ECMA-262 §22.2.1 Pattern[U,N])

A hand-written recursive-descent parser mirroring the spec productions:

```
Pattern        → Disjunction
Disjunction    → Alternative ( "|" Alternative )*
Alternative    → Term*
Term           → Assertion | Atom Quantifier?
Assertion      → "^" | "$" | "\b" | "\B" | "(?=" Disjunction ")"
                | "(?!" Disjunction ")" | "(?<=" Disjunction ")" | "(?<!" Disjunction ")"
Atom           → "(" Disjunction ")"                 // capturing
               | "(?:" Disjunction ")"               // non-capturing
               | "(?<" GroupName ">" Disjunction ")" // named capture
               | "." | CharacterClass | AtomEscape | PatternCharacter
AtomEscape     → DecimalEscape | CharacterClassEscape | CharacterEscape | "k<" GroupName ">"
CharacterClassEscape → "d" | "D" | "s" | "S" | "w" | "W" | "p{" UnicodePropertyValueExpression "}" | "P{…}"
CharacterEscape → ControlEscape ("f" "n" "r" "t" "v") | "c" AsciiLetter | HexEscape | UnicodeEscape | IdentityEscape
Quantifier     → ( "*" | "+" | "?" | "{" DecimalDigits ( "," DecimalDigits? )? "}" ) "?"?
```

Where `GroupName` is `<` IdentifierName `>`, and `IdentifierName` is the ECMA-262 identifier start + continue set (§12.6). For this spec we accept `[A-Za-z_$][A-Za-z0-9_$]*` plus any non-ASCII code point `>= 0x80`. This is a deliberate simplification of the full `ID_Start`/`ID_Continue` Unicode property check; it is a superset of what valid ASCII names require and a subset of the full Unicode spec. Marked as a known deferred gap below.

### Unicode mode (`u` flag) — scope

Full ECMA-262 Unicode mode (§22.2.2.9) requires:

1. Decoding input and pattern as code points (not code units).
2. `\u{XXXXXX}` and `\p{…}` escape support.
3. Stricter syntax: invalid escapes throw.
4. Case-folding per `Canonicalize` simple-case-folding table.

Scope for 0C:

* (1) and (2) land in 0C. Input iteration switches on `flags.unicode`.
* (4) lands as **ASCII-only folding** in 0C. Full case-folding table is deferred to Layer 0B or a follow-up since the table is ~2.5k entries and benefits from sharing with TypedArray work.
* (3): 0C throws on `\P{` / `\p{` outside `u` mode, as the spec requires.

### `\p{…}` property-escape scope

ECMA-262 §22.2.1.1 accepts an enumerated list of Unicode properties. 0C implements only the most load-bearing subset for WPT:

| Property | 0C support |
|----------|-----------|
| `Letter` / `L` | Yes (via ICU-free lookup of Unicode 15 `L` category code points) |
| `ASCII` | Yes |
| `Any` | Yes |
| `White_Space` / `Space` | Yes |
| `Decimal_Number` / `Nd` | Yes |
| General category long aliases (`Letter_Uppercase` etc.) | Deferred to follow-up |
| Script properties | Deferred to follow-up |

Table data lives in `regex.zig` as a `[]const [2]u21` range list per property. Five properties × a few hundred ranges each is manageable. Marked as a known deferred gap below.

### Backtracking engine

Single-thread machine per match attempt. Data:

```zig
const Thread = struct {
    ip: u32,
    sp: u32,
    captures: []?MatchSlot,  // owned by arena per attempt
};
```

Backtrack stack: `std.ArrayList(Thread)`. On `split`, clone current thread at `alt`, push, fall through. On assert_ahead, run a **nested exec loop** with an empty backtrack stack scoped to the assertion; restore sp on exit. Capture writes inside lookaround persist (matches ECMA-262 which explicitly permits capture state to leak from lookahead per §22.2.2.8 ([RegExpBuiltinExec]), though only for lookahead — lookbehind captures are also kept in JS per [tc39/ecma262 #1495]).

Fuel / step budget: 100 000 steps per match attempt; on exhaustion return null (spec-legal since unbounded backtracking is merely "possibly non-terminating"). Mirrors existing engine's `iterations < 10000` guards.

### Memory management

* `Compiled.program` allocated from a single allocator call.
* `Compiled.named` allocated likewise.
* Per-attempt captures array allocated from a short-lived arena; exec returns a borrowed slice that the VM copies into the result Array before the compiled object is dropped.
* Back-compat `searchLegacy` compiles, executes, captures, frees in one call. Extra allocation per regex call is acceptable for landing; future work threads `Compiled` through `RegExpData`.

### Hook into vm.zig

* `createRegExp` in `vm.zig` parses the flags string (already does for `gimsuvy`, only accepts `g/i/m` today). Expand the switch to handle `s`, `y`, `u`.
* Add fields to `RegExpData` in `object.zig`: `dot_all: bool`, `sticky: bool`, `unicode: bool`, `last_index: u32 = 0`. **Small, additive.**
* Rewrite the 9 `regexSearch(...)` call sites in `vm.zig` to call the new `kotori_regex.searchLegacy(pattern, str, flags)`. Signature compatible; only change is flags now carries a `Flags` struct instead of a lone bool.
* `nativeRegExpExec` populates `groups` property on the result Array when the compiled pattern has named groups.

### Performance note

Backtracking NFA on pathological patterns (`/(a+)+b/` on `"aaaa…aaac"`) can run exponentially. Matches the current engine's behavior (which has the same property). The step budget caps the worst case. Profiling-driven optimization (DFA caching, unanchored-pattern prefix-shift) is out of scope.

---

## Implementation phases

Sub-commits match the task budget:

1. **Architecture skeleton** — `regex.zig` module with Parser / Compiler / VM entry points. All opcodes defined but only a subset (char, any, char_class, anchor, boundary, save, split, jump, match_end, split_lazy) implemented. Replace all `regexSearch` callers with `kotori_regex.searchLegacy`. Full existing test suite stays green.
2. **Lookahead / lookbehind** — `assert_ahead`, `assert_behind` opcodes; parser productions `(?=` `(?!` `(?<=` `(?<!`.
3. **Backrefs & named groups** — `(?<name>X)` parser, `\k<name>` and `\1..\9` parser, `back_ref` opcode, side-table + `groups` result-array property.
4. **Unicode / sticky / dotAll** — `u` flag: UTF-8 decoding in input iteration, `\u{…}` and basic `\p{…}` (L, Nd, White_Space, ASCII, Any), stricter syntax validation. `y` flag: exec respects `lastIndex` and the caller's "no free scan" behavior. `s` flag: `any` opcode toggles newline handling.

Each phase is one commit; `zig build && zig build test-kotori` must be green (modulo pre-existing failures unrelated to regex) before moving on.

---

## Non-goals

* Unicode case-folding beyond ASCII. Follow-up.
* `\P{Script=Greek}` script-property escapes. Follow-up.
* `d` flag (match indices). Follow-up.
* Compiled-object caching on RegExpData. Follow-up for speed.
* Replacing `parser.zig`'s regex literal scanner. Current scanner already accepts every needed byte sequence.

## Known deferred gaps (documented for Layer 0C review)

1. Group-name identifier parser is ASCII+8-bit passthrough, not full `ID_Start/ID_Continue`. WPT impact: minimal — named groups in test fixtures are ASCII.
2. `\p{…}` property table covers only General_Category L / Nd / ASCII / Any / White_Space. WPT impact: limited to esoteric property tests.
3. Canonicalize (case folding) is ASCII-only. Non-ASCII case-insensitive regex is not spec-perfect.
4. `d` (hasIndices) flag: parsed, stored in `Flags.has_indices`, but not exposed on the result array.

All three are tracked against the roadmap's Layer 0C follow-up tasks.

---

## Testing strategy

`tests/test_kotori_regex.zig` — new test module. Unit tests exercise the module-level API (`compile`, `exec`) without going through the VM, so each feature is covered in isolation. Integration tests live in the existing `tests/test_kotori_vm.zig` via `evalExpr` after lookaround / named groups are wired through.

Coverage targets:

* One test per opcode.
* One test per parser production.
* Round-trip tests for named groups, backrefs, lookaround, sticky `y`, dotAll `s`, Unicode `u`.
* Regression: every existing `regex_*` test in `tests/test_kotori_vm.zig:1848-2115` must stay green.
