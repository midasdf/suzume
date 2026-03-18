# CSS Engine Phase 1b: Selectors + Cascade + Integration

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete selector matching, cascade, inheritance, var() resolution, and integrate with existing layout/paint to fully replace LibCSS.

**Architecture:** Selector parser produces structured Component lists. Right-to-left matching with hash-indexed rule lookup. Cascade collects matching declarations, sorts by origin/specificity/order, applies to ComputedStyle with proper inheritance. var() resolved post-cascade.

**Tech Stack:** Zig 0.15, builds on Phase 1a (tokenizer, parser, ast, properties, values).

**Spec:** `docs/superpowers/specs/2026-03-18-css-engine-design.md`

---

## File Structure

```
src/css/
├── selectors.zig    -- Selector parsing + matching + specificity (NEW)
├── cascade.zig      -- Cascade + inheritance + ComputedStyle generation (NEW)
├── media.zig        -- @media query evaluation (NEW)
├── variables.zig    -- CSS custom properties resolution (NEW)
├── computed.zig     -- ComputedStyle struct (MOVED from src/style/computed.zig)
│                       Keep src/style/computed.zig as re-export for compat
tests/
├── test_selectors.zig
├── test_cascade.zig
```

---

## Task 1: Selector Parsing

**Files:** Create `src/css/selectors.zig`, `tests/test_selectors.zig`

Parse raw selector text (from `ast.Selector.source`) into structured components.

### Data Structures:
```zig
const Combinator = enum { descendant, child, next_sibling, subsequent_sibling };

const SimpleSelector = union(enum) {
    type_sel: []const u8,     // div, p, a
    class: []const u8,        // .foo
    id: []const u8,           // #bar
    universal,                // *
    attribute: AttributeSel,  // [type="text"]
    pseudo_class: PseudoClass,
};

const AttributeSel = struct {
    name: []const u8,
    op: enum { exists, equals, contains_word, starts_with, ends_with, contains, starts_with_dash },
    value: []const u8,
};

const PseudoClass = enum {
    hover, focus, active, visited, link,
    first_child, last_child, only_child,
    first_of_type, last_of_type,
    root, empty, checked, disabled, enabled,
    not,  // :not() — stores negated selectors separately
};

const SelectorComponent = union(enum) {
    simple: SimpleSelector,
    combinator: Combinator,
};

const Specificity = struct { a: u16, b: u16, c: u16 };  // id, class, type

const ParsedSelector = struct {
    components: []SelectorComponent,  // right-to-left order
    specificity: Specificity,
};
```

### Key functions:
- `parseSelector(source: []const u8, allocator) -> ?ParsedSelector`
- `parseSelectorList(source: []const u8, allocator) -> []ParsedSelector`

### Tests:
- Simple: `div`, `.class`, `#id`, `*`
- Combined: `div.class`, `div#id`, `.a.b`
- Descendant: `div p` → [p, descendant, div]
- Child: `div > p`
- Sibling: `h1 + p`, `h1 ~ p`
- Attribute: `[type="text"]`, `[href]`, `[class~="foo"]`
- Pseudo: `:first-child`, `:hover`, `:not(.foo)`
- Complex: `.sidebar .nav-item a`
- Specificity: `#id` = (1,0,0), `.class` = (0,1,0), `div` = (0,0,1)

---

## Task 2: Selector Matching

**Files:** Add to `src/css/selectors.zig`

### Key function:
```zig
pub fn matches(selector: *const ParsedSelector, element: DomNode) bool
```

Right-to-left matching: start at key selector (rightmost), check element. For each combinator, advance to appropriate relative (parent, previous sibling, etc.) and check next component.

### Element interface needed (DomNode from src/dom/node.zig):
- `tagName() -> ?[]const u8`
- `getAttribute(name) -> ?[]const u8`
- `parent() -> ?DomNode`
- `previousSibling() -> ?DomNode`
- `firstChild() -> ?DomNode`

### Tests:
- Type match: `div` matches `<div>`
- Class match: `.foo` matches `<div class="foo bar">`
- ID match: `#main` matches `<div id="main">`
- Descendant: `div p` matches `<div><p>` but not `<p>` alone
- Child: `div > p` matches `<div><p>` but not `<div><span><p>`
- Attribute: `[type="text"]` matches `<input type="text">`
- Not match: `.foo` does NOT match `<div class="bar">`

---

## Task 3: Rule Index

**Files:** Add to `src/css/selectors.zig`

Hash-map index for fast rule lookup:
```zig
const IndexedRule = struct {
    selector: ParsedSelector,
    rule_idx: u32,    // index into stylesheet.rules
    decl_idx: u32,    // index into rule.declarations
};

const RuleIndex = struct {
    by_id: StringHashMap(ArrayList(IndexedRule)),
    by_class: StringHashMap(ArrayList(IndexedRule)),
    by_tag: StringHashMap(ArrayList(IndexedRule)),
    universal: ArrayList(IndexedRule),

    pub fn build(stylesheet: ast.Stylesheet, allocator) RuleIndex;
    pub fn candidatesFor(element: DomNode) -> iterator of IndexedRule;
};
```

---

## Task 4: Media Query Evaluation

**Files:** Create `src/css/media.zig`

Parse and evaluate @media conditions:
- `screen`, `all`, `print`
- `(min-width: Npx)`, `(max-width: Npx)`
- `(min-height: Npx)`, `(max-height: Npx)`
- `(prefers-color-scheme: dark/light)`
- `not`, `and`, `or` / `,` combinators

### Key function:
```zig
pub fn evaluateMediaQuery(raw: []const u8, viewport_width: f32, viewport_height: f32) bool
```

---

## Task 5: CSS Variables Resolution

**Files:** Create `src/css/variables.zig`

Per-element variable scoping with inheritance:
```zig
const VarMap = struct {
    vars: StringHashMap([]const u8),
    parent: ?*const VarMap,

    pub fn resolve(name: []const u8) ?[]const u8;
};

pub fn resolveVarRefs(value_raw: []const u8, vars: *const VarMap) []const u8;
```

- Resolve `var(--name)` → value from VarMap
- Resolve `var(--name, fallback)` → value or fallback
- Nested: `var(--a, var(--b, default))`
- Cycle detection (max depth 16)

---

## Task 6: Cascade + ComputedStyle Generation

**Files:** Create `src/css/cascade.zig`

The main integration point. Replaces `src/style/cascade.zig`.

### Key function (same interface as existing):
```zig
pub fn cascade(
    doc_root: DomNode,
    allocator: std.mem.Allocator,
    external_css: ?[]const u8,
    viewport_width: u32,
    viewport_height: u32,
) !CascadeResult
```

### CascadeResult:
```zig
pub const CascadeResult = struct {
    styles: StyleMap,
    // Internal state for cleanup
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CascadeResult) void;
};
```

### Process:
1. Parse UA stylesheet + author CSS → Stylesheet AST
2. Build RuleIndex
3. Extract custom property declarations (--*) into per-element VarMaps
4. Walk DOM tree, for each element:
   a. Collect matching declarations from RuleIndex
   b. Add inline style declarations
   c. Sort by cascade priority (origin, !important, specificity, source order)
   d. Start with inherited properties from parent ComputedStyle
   e. Apply declarations in order
   f. Resolve var() references
   g. Resolve relative units (em → px, % → px, vh/vw → px)
   h. Store ComputedStyle in StyleMap

### UA Stylesheet (embed in cascade.zig):
```css
html, body, div, p, h1-h6, ul, ol, li, form, table, section, article, nav, main, aside, header, footer { display: block; }
span, a, em, strong, b, i, u, s, small, code, kbd, var, sub, sup, abbr, mark, q, cite { display: inline; }
h1 { font-size: 2em; font-weight: bold; margin: 0.67em 0; }
h2 { font-size: 1.5em; font-weight: bold; margin: 0.83em 0; }
h3 { font-size: 1.17em; font-weight: bold; margin: 1em 0; }
h4 { font-weight: bold; margin: 1.33em 0; }
h5 { font-size: 0.83em; font-weight: bold; margin: 1.67em 0; }
h6 { font-size: 0.67em; font-weight: bold; margin: 2.33em 0; }
p { margin: 1em 0; }
a { color: #5599dd; text-decoration: underline; }
strong, b { font-weight: bold; }
em, i { font-style: italic; }
ul, ol { padding-left: 40px; margin: 1em 0; }
li { display: list-item; }
pre, code { font-family: monospace; white-space: pre; }
table { display: table; border-collapse: separate; border-spacing: 2px; }
/* ... more defaults */
```

---

## Task 7: Integration — Replace LibCSS

**Files:** Modify `src/main.zig`, `src/style/cascade.zig` (or replace calls)

1. The new `src/css/cascade.zig` exports same `cascade()` signature as old `src/style/cascade.zig`
2. Update `src/main.zig` to import from `src/css/cascade.zig` instead of `src/style/cascade.zig`
3. Keep `src/style/computed.zig` in place (layout/paint depend on it)
4. Remove LibCSS from build (comment out in build.zig, don't delete yet)
5. Test on device

---

## Task 8: Smoke Test on Device

Build, deploy, test on GitHub/Wikipedia/Brave Search/HN. Compare with old rendering. Fix any regressions.
