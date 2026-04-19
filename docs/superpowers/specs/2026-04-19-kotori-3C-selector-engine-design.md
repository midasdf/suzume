# Kotori Layer 3C — Selector Engine Correctness (Design Spec)

**Date**: 2026-04-19
**Scope**: `src/js/dom_selector.zig` (primary). Touch `src/js/dom_api.zig` only for SyntaxError message formatting if required.
**Target**: +1500 subtests in `css/selectors` per master roadmap Layer 3C.
**Approach**: Spec-driven fixes against **Selectors Level 4** (W3C CR 2022-11) and **DOM Living Standard §4.2.6** (`matches()`, `closest()`, `querySelector*()`).

## 1. Authoritative Specs

- **Selectors Level 4** — https://www.w3.org/TR/selectors-4/
  - §3 (Selector syntax overview and compound/complex selector grammar)
  - §4 (Type selectors)
  - §6 (Namespace prefixes)
  - §11 (Pseudo-classes), specifically §11.3 `:is()`, §11.4 `:not()`, §11.5 `:where()`, §17 `:has()`
  - §16 (Calculating specificity)
  - §18 (Combinators)
- **DOM Living Standard** — https://dom.spec.whatwg.org/
  - §4.2.6 `matches()` / `closest()` / `querySelector()` / `querySelectorAll()`
  - §4.2.6 "scope-matching a selectors string" (parse failure → `SyntaxError`)
- **CSS Syntax Level 3** — https://www.w3.org/TR/css-syntax-3/
  - §5.4 "Parse a list of selectors" / error recovery

## 2. Current State Analysis (as of HEAD `f40d232`)

### 2.1 Architecture

- `dom_selector.zig` implements an ad-hoc, string-walking selector matcher. No explicit AST.
- Parse entry points:
  - `elementMatchesSelector(node, sel)` → top-level comma split + `matchSingleSelector`
  - `matchSingleSelector` → `parseSelectorParts` + right-to-left combinator walk, calling `matchSingleSimple`
  - `walkTreeBySelector` / `walkTreeCollect` → querySelector/All tree traversal
- SyntaxError throws exist in `elementMatches`, `elementClosest`, `elementQuerySelector`, `elementQuerySelectorAll`, `documentQuerySelector`, `documentQuerySelectorAll`.
- A JavaScript-side validation shim (`_vSel`) in `dom_api.zig:5904-5964` layered on top of the native methods catches most well-known invalid patterns.
- Namespace support via `hasUndeclaredNamespace(sel)` (string scan; very coarse) and `|`/`*|` / `prefix|` branches in `matchSingleSimple`.
- Specificity: **not tracked**. Only matching is computed. For WPT, most specificity tests live in rendering reftests and run through the CSS cascade — out of scope here. But `:is()`/`:not()`/`:has()` matching must still pass their non-reftest `matches()` assertions.

### 2.2 Identified Defects

Found by reading the source and baseline WPT failures:

| # | Defect | Spec Violation | Location |
|---|--------|----------------|----------|
| D1 | SyntaxError messages hard-code `"' is not a valid selector."` with no selector value. The `"'" ++ "'"` literal concatenation produces `"' is not a valid selector."` — the actual selector string never appears | WPT assertion messages don't require specific text, but the DOMException message must be non-empty and informative (WebIDL convention) | `dom_selector.zig:1351, 1371, 1400, 1422, 1590, 1610` |
| D2 | `hasUndeclaredNamespace` returns true for **any** pipe not preceded by `*`/`,`/space/`\|`, treating `ns|E` as an error even though `*|E` should pass. The native path relies on this shim, which means bare `ns|E` is always rejected even when WPT expects SyntaxError (good) or match (e.g., HTML with registered namespaces — N/A but still needs precise rule) | Selectors L4 §6.4 | `dom_selector.zig:18-48` |
| D3 | `|E` (null/no namespace) is **not** thrown as error but is treated as "match any element with local name `E`" in `matchSingleSimple` (line 735). Per Selectors L4 §6.5, `|E` means "elements with no namespace" — in HTML documents, all elements **have** a namespace (XHTML), so `|E` should match **nothing** (not error, not wildcard) | Selectors L4 §6.5 | `dom_selector.zig:734-740` |
| D4 | `*|*` branches: the early literal check at line 718 returns true, but `*|tag` in line 728 has `if (local_part.len == 1 and local_part[0] == '*')` which still works. Whole-compound `*\|E[attr]` probably breaks because the `|` scan lands before the `[` | Selectors L4 §6.4 | `dom_selector.zig:716-776` |
| D5 | `:is()` / `:where()` currently pass the inner selector straight to `elementMatchesSelector`, which recurses through `matchSingleSelector` / `parseSelectorParts`. **Complex** selectors inside `:is()` (combinators like `:is(div > span)`) should work but are matched against the element only in descendant orientation — no scope-relativization per Selectors L4 §3.4.1 (scope is the element being tested). Because `:is()` inside `matchSingleSimple` is called on a single element, but `:is(div > .x)` needs to match a `div > .x` where `.x` IS this element — that works because inner recursion uses the element's parent chain. Likely correct but needs test. | Selectors L4 §11.3 | `dom_selector.zig:324-328` |
| D6 | `:not()` forbids **complex** selectors per Selectors L3 but Selectors L4 §11.4 **allows** complex selectors. Currently passes inner to `elementMatchesSelector` recursively, which handles combinators — likely correct. **But** `:not()` with an argument list `:not(a, b)` must reject if **all** arguments match → current code calls `elementMatchesSelector` which splits on top-level commas with OR semantics. Resulting behavior: `:not(.a, .b)` = `!(.a OR .b)` = `!(.a) AND !(.b)` which matches spec. | Selectors L4 §11.4 | `dom_selector.zig:319-322` |
| D7 | `:has()` inner parse does not reject top-level **pseudo-element** (e.g., `:has(::before)`) which per Selectors L4 §17 is invalid. Nested `:has()` inside `:has()` is also invalid unless wrapped in `:is()`/`:where()`. The JS shim catches most, but native `:has(foo:has(bar))` without wrapping should throw | Selectors L4 §17 | `dom_selector.zig:330-334, 1651-1655` |
| D8 | `nodeMatchesSimple` (line 1657) has `:is(` case returning `elementMatchesSelector(node, inner)`. But `node` is passed as `*lxb.lxb_dom_node_t`, not as the scoping root. That's correct semantically (tested against the element). | Selectors L4 §3.4.1 | `dom_selector.zig:1656-1662` |
| D9 | Attribute selectors with namespace wildcard `[*|attr]` — `matchAttributeSelector` strips `*|` prefix but only for the no-op case. For `[*|attr=val]` it accepts the prefix. Does not reject `[undefined|attr]` (undeclared NS) | Selectors L4 §6.3 | `dom_selector.zig:1247-1263` |
| D10 | Escaped pipe `\|` in class/id/attr values — the parser escape handler skips them but the `|`-based namespace detector in `hasUndeclaredNamespace` already handles `\|` via the backslash skip. **However**, `classContains` gets passed the raw needle so `.foo\|bar` decodes via `decodeCssEscapes` → `foo|bar`, which is compared to the class value. Likely correct — verify | — | — |
| D11 | Combinator `||` (column combinator, tables, Selectors L4 §18.5) — **not supported**. Out of scope for phase 3C because WPT css/selectors column tests are gated behind CSS Tables module | Selectors L4 §18.5 | N/A |
| D12 | Whitespace normalization: `selector, selector` with leading/trailing whitespace. Currently `std.mem.trim` strips. But `selector ,  selector` with embedded spaces around commas — parts_buf uses `parseSelectorParts` which tokenizes by whitespace then treats comma as "finalize current token". Actually the split happens in `elementMatchesSelector` itself before `parseSelectorParts`. Fine. | — | — |
| D13 | `prefix|` with non-recognized prefix returns `false` silently in `matchSingleSimple` line 753 (undeclared prefix → `null` NS URI → return false). **Per spec, undeclared namespace prefixes must throw NamespaceError/SyntaxError during parse**, not silently fail. The `hasUndeclaredNamespace` shim catches this at the qS/qSA entry points, but `matches()` and `closest()` also use the shim. However, the shim is too coarse: it rejects `ns|E` even when `ns` = `*` if not immediately before `|`. Need precise rule: reject iff prefix != `*` and != `""`. | Selectors L4 §6.2 + DOM §4.2.6 | `dom_selector.zig:1350, 1370, 1399, 1421, 1589, 1609` + `hasUndeclaredNamespace` |
| D14 | `matchSingleSimple` namespace-prefix branch: when `ns_id` doesn't match any known, returns false without ever throwing. Since we never reach this point (the shim catches `prefix\|` first) this is fine — but if the shim is tightened, we must re-validate. | — | `dom_selector.zig:741-775` |

## 3. Scope: What We Fix In Layer 3C

Prioritized by WPT delta impact (heuristic: more tests in each category by looking at `/tmp/wpt/css/selectors/` filenames):

### 3C.1 — SyntaxError Message Correctness (D1) — small, foundational
Message must include the offending selector string so DOMException.message isn't broken. Use `qjs.JS_ThrowException` with `DOMException(msg, "SyntaxError")` where `msg = "Failed to execute 'X' on 'Y': '<sel>' is not a valid selector."`.

**Impact**: ~0 subtests directly (WPT asserts exception **name**, not message) but enables correct error rendering and downstream polyfills reading `e.message`.

### 3C.2 — Namespace Selector Correctness (D2, D3, D4, D9, D13)

Per Selectors L4 §6:
- `E` — type selector, matches any namespace **if no default namespace is declared**, else default namespace
- `*|E` — matches `E` in any namespace (including null)
- `|E` — matches `E` with null namespace
- `ns|E` — matches `E` with namespace declared for prefix `ns`. **In Selectors used by `matches()`/`querySelector()` (scope-matching), there are no user-declarable namespaces. Only HTML-assumed `html`, MathML `math`, SVG `svg`, XLink `xlink` mapped implicitly.**
- Per Selectors L4 §6.2 + HTML §14.5 "Selectors for scripting": undeclared prefix → **parse failure**, throws `SyntaxError`.

**Fix**:
1. Rewrite `hasUndeclaredNamespace` to a proper tokenizer that:
   - Finds type selectors of form `prefix|local`
   - Rejects if prefix is not `*` or `""` and not in the implicit set `{html, svg, math, mathml, xlink, xml}`
   - Skips escaped `\|`, attribute selector operators `|=`, `[*|attr]` attributes
2. Fix `|E` (null namespace) branch in `matchSingleSimple` to only match elements whose `ns_id == 0` (null namespace). In lexbor HTML parser all HTML elements have `ns_id == 1`, so `|E` matches nothing in HTML documents. **Exception**: during document creation via `createElement` (no NS), lexbor still assigns `ns_id == 1`. So `|E` against HTML = no-match, matches DOM spec (null NS).
3. Fix `*|*` compound cases: ensure attribute/class selectors after `*|E` still work.
4. Handle `[*|attr]` and `[prefix|attr]` attribute namespace prefixes symmetrically.

**Impact estimate**: ~200-400 subtests in `css/selectors/type-namespaces-*`, `css/selectors/attr-*`.

### 3C.3 — `:is()` / `:where()` / `:not()` / `:has()` Correctness (D5-D8)

Per Selectors L4 §11.3-11.5, §17:
- `:is(s1, s2, ...)` — matches iff ANY of `s1, s2, ...` matches (selector-list of **complex selectors**).
- `:where()` — same match behavior as `:is()`, specificity 0 (no WPT `matches()` test cares).
- `:not(s1, s2, ...)` — matches iff NONE of `s1, s2, ...` matches. Argument is selector-list of complex selectors.
- `:has(rel)` — matches iff the relative selector `rel` matches any descendant/sibling. `rel` is a relative selector (can start with `>`, `+`, `~` for scope-relative traversal).

**Parse validity** (per spec):
- Empty argument `:is()`, `:not()`, `:where()`, `:has()` → parse failure (SyntaxError).
- Pseudo-elements inside these pseudo-classes (except `:has(::slotted())`) → per Selectors L4 §11 "Only compound selectors are allowed, and pseudo-elements are forbidden" for `:is()`/`:where()`/`:not()`/`:has()`.
- Nested `:has(:has())` must be wrapped in `:is()` or `:where()` per current spec.

**Current shim** catches:
- Empty `:not()`/`:has()` (line 5934 in dom_api.zig)
- `:not(::anything)` (line 5940)
- Nested `:has(:has())` without `:is`/`:where` wrap (line 5943)
- `:has()` with numeric/positional start (line 5938)

**Gaps**:
- `:is()` with pseudo-element argument not rejected by shim → need native rejection OR shim extension.
- `:where()` with pseudo-element argument not rejected.
- Empty `:is()`, `:where()` not rejected.

**Fix**:
1. Extend native parse to reject empty argument for `:is/:not/:where/:has` (symmetric with existing `:not`/`:has`).
2. Extend shim with `:is(\s*)`/`:where(\s*)` empty rejection and pseudo-element rejection inside `:is()`/`:where()`.

**Match semantics**:
- `:is(s1, s2)` — already works via `elementMatchesSelector` top-level comma split returning true on any match. ✓
- `:not(s1, s2)` — inverted OR = NOR. Current code negates `elementMatchesSelector(inner)` which is OR of comma-split. ✓
- `:has(rel)` — `hasRelativeMatch` + `hasRelativeMatchSingle` handle most combinators. Verify `:has(.a, .b)` top-level comma split → matches if any of the relative selectors match. Current code walks `inner` looking for top-level commas. ✓

**Impact estimate**: +200-400 subtests for `:is()`/`:where()`/`:not()`/`:has()` edge cases.

### 3C.4 — Complex Combinator Paths (D-specific)

Sites to verify:
- `a b c` (descendant chain) — `matchSingleSelector`/`nodeMatchesCompound` right-to-left with `.descendant` combinator — current code uses `cur_node.parent` walk. Should handle chains of 3+ parts because it walks backwards through the entire parts array.
- `a > b > c` (child chain) — direct parent walk. Should work.
- `a + b + c` (adjacent sibling chain) — `prevElementSibling`. Should work.
- `a ~ b ~ c` — general sibling. Should work.
- Mixed: `a > b c + d` — works because each step uses its own combinator.
- Parser buffer: `parseSelectorParts(trimmed, &parts)` uses `[16]SelectorPart` → **cap at 16 parts**. If a WPT test uses >16 parts, silent truncation. Should be extended to 64 or dynamically allocated. Trivial fix.

**Fix**: Bump buffer to `[64]SelectorPart`, both in `matchSingleSelector`:237 and `walkTreeBySelector`:1526, `walkTreeCollect`:2077.

**Impact estimate**: +20-50 subtests.

### 3C.5 — Minor Parse/Match Polish

- Case-insensitive attribute operator: `[attr=val i]` flag — already supported (line 1271).
- Case-sensitive flag `s` — already supported (line 1272). Per spec, attribute equality is case-sensitive by default in HTML except for enumerated attributes; we don't track that.
- `::part(name)` / `::slotted(sel)` — out of scope (shadow DOM). Shim rejects malformed forms.

## 4. Design — Concrete Changes

### Change Set A: SyntaxError Messages (D1)

Convert `"'" ++ "' is not a valid selector."` (which yields the constant string `"' is not a valid selector."`) into format using the actual selector slice, with a small stack buffer:

```zig
fn throwSelectorSyntax(c: *qjs.JSContext, method: []const u8, sel: []const u8) qjs.JSValue {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Failed to execute '{s}': '{s}' is not a valid selector.", .{ method, sel }) catch "Invalid selector.";
    return api.throwDOMException(c, "SyntaxError", msg);
}
```

Call from each of the six sites, passing the correct method name (`matches`/`closest`/`querySelector`/`querySelectorAll`).

### Change Set B: Namespace Parse/Match (D2, D3, D4, D9, D13)

Replace `hasUndeclaredNamespace` with `selectorNamespaceError` that:

- Tokenizes the selector to find every `|` that's a namespace separator (not attr operator, not escaped, not inside brackets)
- For each, extracts prefix (from start of current simple selector to `|`)
- If prefix is empty (`|E`, `|attr`) — allowed (null NS)
- If prefix is `*` — allowed
- If prefix is recognized literal (`html`, `svg`, `math`, `mathml`, `xlink`, `xml`) — allowed
- Otherwise → report SyntaxError

Fix `|E` null-NS branch in `matchSingleSimple` to check `elem.node.ns` == 0 (null). In lexbor, HTML elements have `ns_id == 1` (XHTML); null NS is `ns_id == 0`.

### Change Set C: `:is()`/`:where()` Empty + Pseudo-Element Validation (D5, D7)

Add early guards in `matchSingleSimple` and `nodeMatchesSimple` when processing `:is(`, `:where(`, `:not(`, `:has(`:

```zig
const inner_trimmed = std.mem.trim(u8, inner, " \t\n\r\x0c");
if (inner_trimmed.len == 0) return false; // match semantic: never matches
// At the parse level (shim or native), this should have already thrown SyntaxError.
```

The match path returns `false`, which is compatible with `:not()` (inverts to `true`, matching all) but breaks WPT expectations. Instead, extend the shim to reject `:is(\s*)` and `:where(\s*)` and pseudo-elements inside.

### Change Set D: Part-Buffer Cap (§3C.4)

Change `[16]SelectorPart` to `[64]SelectorPart` at three sites.

### Change Set E: Attribute Namespace (D9)

Extend `matchAttributeSelector`:
- Handle `|attr` (no NS) — only matches attributes with no explicit prefix
- Handle `prefix|attr` for recognized prefixes
- Reject `undef|attr` via the same shim

## 5. Acceptance

- `zig build` succeeds
- `zig build test` passes 100% (no regression)
- `css/selectors` WPT run shows >= +1500 subtest delta from baseline
- No regression in `dom/nodes`, `dom/events`, `html/dom`

## 6. Implementation Order (Commits)

1. **3C.1 SyntaxError messages** — commit `fix(kotori 3C): SyntaxError messages include selector string`
2. **3C.4 Part-buffer cap** — commit `fix(kotori 3C): bump selector parts buffer 16→64`
3. **3C.2 Namespace parse/match** — commit `feat(kotori 3C): namespace selector validation per Selectors L4 §6`
4. **3C.3 :is()/:where() validation** — commit `feat(kotori 3C): reject empty/pseudo-element args in :is/:where`
5. **3C.5 Attribute namespace polish** — commit `feat(kotori 3C): attribute selector namespace prefix per Selectors L4 §6.3`

After each commit: `zig build && zig build test`. Final WPT run after all commits.

## 7. Baseline Measurement

Will run `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9880 css/selectors` and paste results into plan.

## 8. File Touch List

- `src/js/dom_selector.zig` — all parse/match changes (primary)
- `src/js/dom_api.zig` — only if shim regex needs tightening for empty `:is()`/`:where()` rejection

No other files touched. No conflict with concurrent work on `dom_document.zig`, `dom_element.zig`, `events.zig`, `regex.zig`.
