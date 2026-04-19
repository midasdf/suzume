# kotori Layer 3A — CSSOM Completeness Design

**Date**: 2026-04-19
**Branch**: `feature/kotori-layer-3a-cssom`
**Spec references**: CSSOM §6 (CSSStyleDeclaration), CSS Syntax Module Level 3 §5 (parsing / error recovery), CSS Values & Units Level 4 §6 (invalid values), CSS 2.2 §4.1.7 (selector / block boundary recovery).

---

## 1 Scope

Cover CSSOM §6 (CSSStyleDeclaration) gaps visible in WPT `css/cssom` (current 135/677 = 19.9 %).
Target: at least +300 subtests (→ ≥435 pass) after the branch merges.

File isolation — this spec only authorizes edits in:

- `src/css/cssom/style_decl.zig`
- `src/css/cssom/shorthand_serialize.zig`
- `src/css/cssom/computed_slice.zig` (read-only unless strictly required)
- `src/css/parser.zig`

Out of scope for this branch (other agents own them):

- `src/js/dom_style.zig` — Layer 3B
- `src/js/dom_selector.zig`, `src/js/events.zig`, `src/js/dom_element.zig`, `src/js/dom_document.zig`, `src/js/kotori_dom.zig`, `src/js/kotori/*.zig`
- JS glue that exposes these methods to the quickjs runtime (`src/js/dom_api.zig`) — we only rely on its existing contract with the CSSOM layer.

---

## 2 Gaps addressed

### 2.1 `!important` roundtrip in `.cssText`
**Spec**: CSSOM §6.7.2 *Serializing CSS Values* step: every declaration whose `important` flag is true serialises with a trailing ` !important`.

**Current status (verified in `style_decl.zig`)**:
- `StyleDeclList.serialize()` and `StyleDeclList.getCssText()` already emit ` !important`.
- `parseIntoList` already lifts `!important` into `important = true`.

**Risks identified**:
- `parseIntoList` calls `endsWithImportant(raw_val)` which requires `!important` to be a contiguous suffix. WPT uses variants like `color: red ! important`, `color: red !IMPORTANT`, `color: red !important /* trailing comment */`, `color: red !important  ;`. A comment or whitespace between `!` and `important`, or a trailing comment, breaks detection → the whole declaration is kept as value `"red !important"` (verbatim) and `important=false`.
- Parser `parseDeclaration` in `src/css/parser.zig` (already correct — scans back over whitespace between `!` and `important`).

**Fix**: extend `endsWithImportant` in `style_decl.zig` to:

1. Strip trailing CSS comments `/* ... */` and whitespace.
2. Match `important` (case-insensitive).
3. Walk backwards over optional whitespace + optional trailing `/* */` comments.
4. Match `!`.
5. Return the remainder (trimmed of trailing whitespace + comments).

### 2.2 CSS shorthand expansion via direct assignment (`element.style.margin = "10px"`)
**Spec**: CSSOM §6.7.4 *setProperty* + CSS Backgrounds & Borders §4 / CSS Box §8 / CSS Flexbox L1 §7.
- `setter` for a shorthand invokes the setter which MUST expand to component longhands.

**Current status (verified in `dom_api.zig`)**:
- `styleSetProperty` already expands `margin` / `padding` / `border-*` / `flex` / `flex-flow` to longhands and calls `list.upsertShorthand(...)`.
- `parseIntoList` (which services `element.style.cssText = "margin: 1px 2px"`) does **not** expand shorthands — it stores `margin` as a flat entry. This breaks:
  - `element.style.cssText = "margin: 1px"; element.style.marginTop` → must yield `"1px"`.
  - `style.cssText = "margin: 1px 2px"; style.marginRight` → must yield `"2px"`.

**Fix**: after `parseIntoList` inserts an entry whose name matches a known shorthand, expand it via `shorthand_serialize.expandShorthandIntoList`. Implement the inverse table:
- `margin` → `margin-top/right/bottom/left`
- `padding` → `padding-top/right/bottom/left`
- `border-width` → four `border-*-width`
- `border-style` → four `border-*-style`
- `border-color` → four `border-*-color`
- `flex` → `flex-grow / flex-shrink / flex-basis`
- `flex-flow` → `flex-direction / flex-wrap`

Pure TRBL splitter respecting CSS-wide keywords (`inherit` / `initial` / `unset` / `revert`).

### 2.3 Invalid-rule recovery in a stylesheet (CSS Syntax §5.3)
**Spec**: *consume a list of declarations* / *consume a qualified rule* — on error the parser must skip to the next `;` (declarations) or matching `}` (qualified rules) and continue with the next rule / declaration. One bad rule never aborts the sheet.

**Current status (`src/css/parser.zig`)**:
- `parseStyleRuleInner` returns `null` on a missing `{`, but the outer loop already continues correctly.
- `parseDeclaration` returns `null` for no-colon and pushes back, then calls `skipToRecoveryPoint` which advances to `;` / `}`.
- Gaps seen by WPT:
  - `@unknown at;` at top level: `parseAtRule` unknown → `skipAtRule` walks until `;` / `{...}`. Behaviour looks OK; test case: confirm.
  - `}` encountered at declaration-list top level (premature close). Currently handled: `.close_curly, .eof => break`.
  - Malformed value tokens that straddle two declarations — e.g. `color: ;;; width: 10px` must yield `width:10px`. Currently handled (semicolon is a separator).
  - **Missing**: when the parser encounters a syntactically invalid *selector* (e.g. `! foo { color:red } p { color:blue }`), it hangs onto the `!` token as part of the selector. Because `splitSelectors` does not validate, the whole-sheet still parses, but the rule with the bad selector matches nothing — acceptable.
  - **Missing**: inside a declaration block, an at-rule like `@media screen { … }` is attempted — Parser already calls `parseAtRule`. Good.
  - **Actual bug**: `parseAtRule` returns `null` for unknown at-rules *before* `skipAtRule` — but its body runs `skipAtRule`. However when `skipAtRule` returns via EOF inside a nested block it mishandles the brace depth. Verify with a targeted test.

**Fix**: add a depth-safe `skipBadRule` helper that matches the CSS Syntax §5.4.1 block-consume semantics: start at current token, consume until matching `}` at depth 0 (or `;` if no block has opened). Call it from every error branch that currently falls through to `skipToRecoveryPoint`.

Additionally, in `parseDeclaration`:
- If the value, after `!important` stripping, is syntactically empty (only whitespace/comments), drop the declaration (CSS Syntax §5.4.5 requires at least one non-whitespace token).
- If the declaration ends with an open `{` inside the value (e.g. `color: red { junk }; color: blue`), consume the balanced block before returning to caller.

### 2.4 `setProperty(name, value, priority)` priority handling
**Spec**: CSSOM §6.7.4 step 4 — if priority is not the empty string and is not an ASCII case-insensitive match for `"important"`, return without doing anything.

**Status**: `dom_api.zig::styleSetProperty` already handles step 4 (owned by another agent).

**Gap we own**: when `parseIntoList` encounters a value with trailing non-standard priority (e.g. `color: red !foo`), the current code treats the whole thing as the value. CSS Syntax §5.4.5 *consume a declaration* step 4 says the declaration is valid only if the last two non-whitespace tokens are `!` + `important`; otherwise no important flag but the value still parses.

Update `endsWithImportant` to return `null` (not important) when the ident after `!` is anything other than `important`, while leaving the entire raw value (including `!foo`) intact — current code already does this by only matching `important`; we verify.

### 2.5 Secondary gaps revealed by baseline (fix opportunistically)
- **Empty-declaration normalisation**: `color: ;` currently stored as `color` with empty value. CSSOM §6.5 says serialising back should omit it entirely (`cssText` must not show `color: ;`). Fix: parseIntoList filters out empty values.
- **Whitespace-only custom properties**: `--x:  ` must keep the single space value (CSS Variables §2.1). Currently `std.mem.trim` strips it. Special-case `--*` properties in parseIntoList.
- **Property-name case preservation for custom props**: `--Foo` must remain `--Foo` (case-sensitive); non-custom must lowercase. Currently we lowercase via `resolveWebkitAlias` + hashing — verify upsert path for `--`.
- **`getCssText` trailing semicolon**: current output `color: red !important;` ends with `;` — matches Chrome. Check that empty list returns `""`.

---

## 3 API changes (new public exports)

```zig
// style_decl.zig
pub fn expandShorthandValueInto(
    list: *StyleDeclList,
    allocator: std.mem.Allocator,
    shorthand: []const u8,   // e.g. "margin"
    value: []const u8,       // whole RHS, e.g. "1px 2px"
    important: bool,
) !bool;                     // true = expanded, false = not a shorthand
```

```zig
// shorthand_serialize.zig
pub fn splitTrblValue(value: []const u8, out: *[4][]const u8) ?u8;
pub fn isKnownShorthand(name: []const u8) bool;
pub fn longhandsFor(name: []const u8) ?[]const []const u8;
```

```zig
// parser.zig
// Private; depth-aware block skip used by rule-error branches.
fn skipBadRule(self: *Parser) void;
```

No existing signatures change.

---

## 4 Verification strategy

1. **Unit tests in the edited files** for every bullet in §2.
2. **`zig build && zig build test`** green on every sub-commit.
3. **WPT run** `cd tests/wpt && bash run_wpt_parallel.sh --jobs 4 --port 9883 css/cssom` before the first commit and after the last commit; compute delta.
4. Manual spot-check for a representative test from each §2 category.

---

## 5 Commit plan (sub-commits)

| # | Area | Files |
|---|------|-------|
| 1 | `!important` parse robustness (comments, mid-whitespace) | `style_decl.zig` |
| 2 | Shorthand expansion in `parseIntoList` | `style_decl.zig`, `shorthand_serialize.zig` |
| 3 | CSS Syntax §5 error-recovery polish | `parser.zig` |
| 4 | Declaration sanity (empty value, custom-prop whitespace) | `style_decl.zig` |
| 5 | Baseline + final WPT run + doc update | (docs only) |

---

## 6 Risk register

- **Regression of existing 135 passing subtests**: mitigated by running the full `css/cssom` area after each commit; any regression blocks merge.
- **Shared ownership with dom_api**: we keep public API signatures compatible; dom_api continues to call `upsertShorthand` as before.
- **Arena-lifetime**: `expandShorthandValueInto` inserts new entries into `list.arena`; preserves existing invariants (entries' name/value own arena memory).
- **CSS-wide keywords** (`inherit`, `initial`, `unset`, `revert`): when set on a shorthand, must expand to longhands with the *same* keyword (CSS Cascade L4 §7.2), not try to split as TRBL.
