# suzume CSSOM `CSSStyleDeclaration` Design Spec

**Date:** 2026-04-15
**Scope:** Native CSSOM `CSSStyleDeclaration` for inline `el.style`
**Status:** Design — implementation deferred
**Related:** `docs/superpowers/specs/2026-04-15-suzume-phaseB-css-audit.md` §9

---

## Executive Summary

Inline style in suzume is currently a **string attribute** (`<tag style="…">`) round-tripped through ad-hoc `getStyleProperty` / `setStyleProperty` helpers. `el.style.foo = "…"` and `el.style.setProperty(…)` both rewrite that string, which means the `!important` bit is silently dropped on the JS-authored path even though the cascade itself (`src/css/cascade.zig`) parses and honors `important` when it reads the attribute back.

This spec proposes a **declaration-list backing store** keyed by DOM element pointer, holding ordered `{ name, value, important }` entries. The `style` attribute becomes the *serialized projection* of that list (updated on every mutation, so `getAttribute("style")` stays correct), while CSSOM operations consult the structured list. This unlocks `setProperty(name, value, "important")`, `getPropertyPriority`, `length`, `item(i)`, and round-trip-preserving `cssText`, without rearchitecting the cascade.

---

## 1. Current State

### Inline-style storage
Inline style is stored **only** as the raw `style` attribute on the lexbor DOM element — there is no structured mirror.

- `styleGetCssText` — `src/js/dom_style.zig:147` — returns `lxb_dom_element_get_attribute(elem, "style")` verbatim.
- `styleSetCssText` — `src/js/dom_style.zig:163` — blindly overwrites the attribute with the input string (no parse, no validate, no `!important` tracking).
- The JS-side `el.style.foo = "bar"` path (in `src/js/dom_api.zig:1631–1759`) calls `dom_style.setStyleProperty(current_style, prop, val, &buf)` which performs **string surgery** on the attribute. `!important` is parsed nowhere in that helper.
- `getStyleProperty` / `setStyleProperty` are the string helpers; call sites in `dom_api.zig:930–1949` and `dom_style.zig:3134–3231` all route through them.

### Cascade read path
`src/css/cascade.zig:925` reads the `style` attribute per element, then `collectInlineDecls` (`cascade.zig:1151`) wraps the string in `* { … }`, runs it through `parser_mod.Parser`, and **does** preserve `important` (`cascade.zig:1177, 1200, 1342`). The cascade sort-key encodes the important bit at position 63 (`cascade.zig:255–259`).

### The bug
The cascade **can** use `!important` on inline declarations when the attribute string contains the `!important` suffix. It just never does, because every JS mutation path normalizes the value through `setStyleProperty` without serializing the priority back into the string.

### CSSOM surface today
- No `setProperty(name, value, priority)` that respects `priority`.
- No `getPropertyPriority` (always `""`).
- No `length` / `item(i)` / indexed getter.
- `removeProperty` (where implemented) does not preserve other declarations' `!important` flags because it rebuilds the string via the priority-stripping helpers.
- camelCase accessors work one-way (property setter) but route through the same lossy path.

---

## 2. Representation Design

Introduce `StyleDeclList`, a per-element array owned by the element (keyed by element pointer in a side map, so zero cost for elements with no inline style).

```zig
pub const StyleDecl = struct {
    name: []const u8,       // normalized kebab-case, arena-owned
    value: []const u8,      // CSSOM-serialized value (no !important suffix)
    important: bool,
    // shorthand metadata — null for longhands, non-null for declarations that
    // were authored as shorthands. Used to reconstruct insertion order and
    // implement the "canonical serialization" rule for shorthand getters.
    shorthand_for: ?[]const []const u8 = null,
};

pub const StyleDeclList = struct {
    entries: std.ArrayList(StyleDecl),   // insertion order preserved
    dirty_serialized: bool,              // cached cssText invalidation
    cached_css_text: ?[]const u8,
};
```

Design notes:

- **Array, not hashmap.** CSSOM mandates insertion-order iteration via `length` / `item(i)`. Last-wins semantics for duplicate sets are handled by removing the prior entry before appending.
- **Kebab-case names only.** camelCase is a JS binding concern, normalized at the API boundary.
- **Value stored post-validation.** Whitespace-normalized, no trailing `!important` in the stored string — the bit is out-of-band.
- **Shorthand entries are expanded.** `setProperty("margin", "1px")` stores four longhand entries (`margin-top`, `-right`, `-bottom`, `-left`) tagged with `shorthand_for = &.{"margin"}`. This matches Blink/Gecko observable behavior: `style.length` counts the four longhands; `style[i]` returns a longhand name; the `margin` getter reconstructs the canonical shorthand from them.
- **Serialization is lazy.** The `style` attribute on the lxb DOM node is *only* resynthesized when something external needs it: `el.getAttribute("style")`, `el.outerHTML`, cascade entry, or `style.cssText` getter. Use `dirty_serialized` to cache.
- **Ownership.** Bind the list's lifetime to the element (free on element teardown). Values are arena-backed — one arena per list, reset on full `cssText=` replace.

### Why not extend cascade's `Declaration` directly
The cascade's `Declaration` struct is parser output (includes `value_raw`, source location). The CSSOM list is authored DOM state. They have different lifecycles (cascade arena is per-recompute; CSSOM list is per-element/long-lived). Keep them separate; use the CSSOM list as the **authoritative source** and serialize into the attribute, then let the cascade parse the attribute as it does today. Cheap and avoids a second consumer of cascade internals.

---

## 3. API Contract (CSSOM §4.1)

Implemented on the `style` object returned by `Element.style` getter.

| Member | Semantics |
|---|---|
| `length` | `list.entries.items.len` |
| `item(i)` / indexed `style[i]` | `entries[i].name` (kebab-case), or `""` if OOB |
| `getPropertyValue(name)` | Look up by normalized kebab name. Return stored `value`, or `""`. For shorthand names: reconstruct from component longhands (return `""` if any component missing / inconsistent important flags). |
| `getPropertyPriority(name)` | `"important"` if entry has `important=true`, else `""`. For shorthand: `"important"` only if **all** component longhands are important; else `""`. |
| `setProperty(name, value, priority?)` | If `value == ""` → delegate to `removeProperty`. Parse+validate. If `name` is a shorthand: expand via `css_props.expandShorthand` and insert/update each longhand entry with the supplied `priority`. Else: upsert single entry. Remove prior entries with same name. Sync attribute. |
| `removeProperty(name)` | If shorthand: remove all component longhands. Else remove single entry. Return the previous serialized value. Sync attribute. Priority flags on **other** declarations are untouched (today's bug). |
| `cssText` getter | Serialize `entries` as `"<name>: <value>[ !important];"` joined by `" "` per CSSOM serialize algorithm. |
| `cssText` setter | Discard current list, re-parse the input via the existing CSS parser (same path cascade uses: wrap in `* { … }`), populate `entries`. |
| camelCase accessors (`backgroundColor` etc.) | JS Proxy / property-by-property binding converts `backgroundColor` ↔ `background-color`, delegates to `getPropertyValue`/`setProperty` with `priority=""`. |
| `parentRule` | `null` (inline style has no rule parent). |

Name normalization: lowercase, camelCase→kebab via the existing `prop_pairs` table in `dom_style.zig:3100`. Custom properties (`--foo`) pass through unchanged and bypass shorthand expansion and validation.

---

## 4. `!important` Data Flow

```
JS: el.style.setProperty("color", "red", "important")
     │
     ▼
dom_style.zig : styleSetProperty (new)
     │   normalize name, validate value, parse priority → important=true
     ▼
StyleDeclList.upsert({name:"color", value:"red", important:true})
     │   remove prior "color" entry, append new
     ▼
serialize list → "color: red !important"
     │
     ▼
lxb_dom_element_set_attribute(elem, "style", serialized)
     │
     ▼
api.setDomDirty() → next recompute_style
     │
     ▼
cascade.zig : collectInlineDecls reads the attribute
     │   parser_mod.Parser sees "!important" suffix, sets decl.important=true
     ▼
CascadeEntry.decl.important = true → sort key bit 63 set
     │
     ▼
final applyDeclaration uses the important-winning entry
```

Round-trip on read: `getPropertyPriority("color")` hits the structured list directly — **does not** re-parse the attribute — so no serialization drift.

---

## 5. Interaction with Existing `dom_style.zig`

### What changes
- `styleSetCssText` — now reparses input into the list (replacing prior), then serializes back into the attribute.
- `styleGetCssText` — now serializes from the list (with cache) instead of reading the attribute (avoids showing stale raw string if something mutated the list between syncs).
- `el.style.foo = "val"` path in `dom_api.zig:1631–1759` — reroute to `styleSetProperty` with `priority=""`. Delete the shorthand-special-case bespoke branches (`flex`, `flex-flow`); `expandShorthand` in `setProperty` handles them uniformly.
- Add `styleSetProperty`, `styleRemoveProperty`, `styleGetPropertyValue`, `styleGetPropertyPriority`, `styleItem`, `styleLength` C-functions bound on the style object.
- `getStyleProperty` / `setStyleProperty` string helpers remain **internal** — still used by the shorthand-reconstruction code paths in `dom_api.zig:930–1949`, but those read from the already-serialized attribute. No !important semantics required there (they're computed-style helpers).

### What stays
- `computedStyleGetPropertyValue` (`dom_style.zig:184`) keeps reading the `style` attribute — the attribute is always in sync after mutations, and this path intentionally shows the *resolved* inline value (var() resolution, CSS-wide keyword resolution).
- Cascade parsing path (`cascade.zig:925, 1151`) is untouched. The cascade already understands `!important` on inline declarations; the fix just ensures that bit actually reaches the attribute string.
- `getComputedStyle(el)` — explicitly **not** a `CSSStyleDeclaration` writable surface. It returns a read-only projection of the cascade result. Document in spec: `getComputedStyle` returns an object with `getPropertyValue` only (today's behavior at `dom_style.zig:2720`); `setProperty` / `cssText` setter on it are no-ops or throw (TBD, see Open Questions).

### cssText round-trip
After `el.style.cssText = "color: red !important; margin: 1px"`:
1. Parse wrapped as `* { color: red !important; margin: 1px }`.
2. Populate list: `[{color, red, true}, {margin-top, 1px, false, shorthand_for=[margin]}, … ×4]`.
3. Serialize attribute: `color: red !important; margin-top: 1px; margin-right: 1px; margin-bottom: 1px; margin-left: 1px;` **or** collapse back to canonical `margin: 1px` via the shorthand-serialization rule (Blink collapses). Pick one — spec leans toward **always expand in the attribute, collapse in the shorthand getter** for deterministic serialization.

---

## 6. Phased Rollout

### Phase 1 — Declaration list + single-longhand !important (unblock JS tests)
- Add `StyleDeclList` + per-element map.
- Rewrite `styleSetProperty` / `styleRemoveProperty` / `styleGetPropertyValue` / `styleGetPropertyPriority` / `styleLength` / `styleItem`.
- Sync attribute on every mutation.
- Cascade already honors `!important` in attribute → end-to-end works for longhands.
- **Not yet:** shorthand expansion, canonical shorthand serialization.
- Tests: `setProperty("color","red","important") → getPropertyPriority==="important"`; `removeProperty` preserves other flags.
- Effort: **~300 LOC**, 1–2 days.

### Phase 2 — Cascade validation + edge cases
- Verify cascade path with authored inline `!important` in realistic stylesheets (author stylesheet non-important + inline important should win; UA important beats author non-important; etc. — already implemented in cascade sort key, just verify).
- Fix `styleSetCssText` to reparse into the list (today it just overwrites the raw string).
- Tests: tiered cascade cases from Phase B audit.
- Effort: **~100 LOC**, half a day.

### Phase 3 — Shorthand expansion + consistency
- On `setProperty(shorthand, …)`: call `css_props.expandShorthand`, insert all longhands with `shorthand_for` tag.
- On shorthand getter: gather matching longhands, check all present and all have the same `important` flag. If not, return `""`. Else return canonical serialization.
- `style.length` now reflects expanded longhand count.
- Tests: `margin`, `padding`, `border`, `background`, `font`, `flex`, `flex-flow`, `grid-*`.
- Effort: **~400 LOC** (mostly canonical-serializer per shorthand), 2–3 days.

### Phase 4 — `CSSStyleSheet` / `CSSRule.style`
- Separate concern: `document.styleSheets[i].cssRules[j].style` also needs a `CSSStyleDeclaration`.
- Backing store differs (lives in stylesheet, not DOM attribute) but API surface is identical — factor the list + API into a shared module.
- Tests: CSSOM WPT cssstylesheet/*.
- Effort: **~500 LOC**, 3–4 days.

---

## 7. Open Questions / Risks

1. **Shorthand attribute serialization.** Expand-in-attribute (simple, deterministic) vs. collapse-in-attribute (shorter, closer to what authors wrote). Blink collapses for canonical shorthands; spec recommends that route for Phase 3. Phase 1 can punt and expand.
2. **Custom properties `--*`.** CSSOM treats them as not shorthands, not validated, preserve raw. Trivial but must bypass kebab/camelCase normalization.
3. **`getComputedStyle` mutability.** Chrome throws on `setProperty`. Firefox silently ignores. Pick "throw NoModificationAllowedError" to match WPT.
4. **Attribute-vs-list drift.** If anything outside this module calls `lxb_dom_element_set_attribute(elem, "style", …)` directly, the list goes stale. Audit call sites; add an invalidation hook on attribute mutations (there's already `setDomDirty`).
5. **Memory.** One arena per element with inline style. Elements without inline style pay zero. On `cssText=` replace, reset the arena.
6. **Parser reuse risk.** `collectInlineDecls` wraps `* {…}` for the full cascade parser. Reusing it for CSSOM parsing inherits parser quirks (comments, bad tokens). Acceptable — consistent semantics between CSSOM input and cascade input.
7. **Round-trip fidelity on exotic values.** `calc()`, `var()`, color functions — already handled by the existing tokenizer/parser; CSSOM serialize rules may differ (e.g., whitespace inside `calc()`). Follow-up WPT will surface cases.

---

## 8. Effort Estimate

| Phase | LOC | Days | Risk |
|---|---|---|---|
| 1. List + longhand API | ~300 | 1–2 | Low |
| 2. Cascade verification | ~100 | 0.5 | Low |
| 3. Shorthand expansion + canonical getter | ~400 | 2–3 | Medium (per-shorthand serializer tedium) |
| 4. CSSRule.style surface | ~500 | 3–4 | Medium |
| **Total** | **~1300** | **~7–10** | — |

Phase 1 alone eliminates the Phase B §9 audit finding and unblocks JS round-trip tests. Phases 2–3 deliver spec-compliant CSSOM. Phase 4 is an independent feature enabling stylesheet-side CSSOM.
