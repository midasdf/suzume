# suzume CSS Engine — Design Spec

Replace LibCSS with a self-implemented CSS engine in Zig. Full CSS3 support, optimized for RPi Zero 2W (512MB RAM, Cortex-A53).

## Why

LibCSS blocks progress on every major compatibility issue:
- No CSS custom properties (var()) — #1 compat blocker for modern sites
- No CSS Grid — Wikipedia, MDN, Stack Overflow layouts broken
- No transforms, transitions, animations — visual gaps everywhere
- Crashes on large CSS inputs (>512KB resolved)
- C library with no Zig-native memory control

Self-implementation gives full control over memory, enables incremental improvement, and eliminates the C dependency.

## Architecture

```
src/css/
├── tokenizer.zig    -- CSS Syntax Level 3 tokenizer
├── parser.zig       -- Recursive descent parser
├── selectors.zig    -- Selector parsing + matching + specificity
├── cascade.zig      -- Cascade + inheritance + computed value resolution
├── properties.zig   -- Property definitions, initial values, inheritance flags
├── values.zig       -- Value types (length, color, percentage, calc, etc.)
├── variables.zig    -- CSS custom properties (var()) resolution
├── media.zig        -- @media query evaluation
└── computed.zig     -- ComputedStyle struct (migrated from style/computed.zig)
```

Existing files removed after migration:
- `src/style/cascade.zig` (LibCSS cascade + supplementary layer)
- `src/style/select.zig` (LibCSS select handler)
- `src/bindings/css.zig` (LibCSS C bindings)
- `build_libcss.zig`, `deps/libcss/`, `deps/libwapcaplet/`, `deps/libparserutils/`

Existing files kept:
- `src/style/computed.zig` → moved to `src/css/computed.zig`
- Layout engine (`src/layout/`) — unchanged, consumes ComputedStyle
- Paint engine (`src/paint/`) — unchanged, consumes ComputedStyle

## Phase 1: Core Engine (LibCSS Replacement)

### 1.1 Tokenizer (`tokenizer.zig`)

Per [CSS Syntax Level 3 §4](https://www.w3.org/TR/css-syntax-3/#tokenization).

**Token types:**
```zig
const TokenType = enum {
    ident,           // foo, --my-var
    function,        // calc(, var(, rgb(
    at_keyword,      // @media, @keyframes
    hash,            // #foo, #FF0000
    string,          // "hello", 'world'
    bad_string,
    url,             // url(https://...)
    bad_url,
    delim,           // single char: . # > + ~ * , : ;
    number,          // 42, 3.14, -1
    percentage,      // 50%
    dimension,       // 10px, 2em, 100vh
    whitespace,
    cdo,             // <!--
    cdc,             // -->
    colon,           // :
    semicolon,       // ;
    comma,           // ,
    open_bracket,    // [
    close_bracket,   // ]
    open_paren,      // (
    close_paren,     // )
    open_curly,      // {
    close_curly,     // }
    eof,
};

const Token = struct {
    type: TokenType,
    start: u32,      // byte offset in source
    len: u16,        // byte length
    // Numeric value for number/percentage/dimension tokens
    numeric_value: f32 = 0,
    // Unit for dimension tokens (px, em, rem, vh, vw, %)
    unit: Unit = .none,
};
```

**Design decisions:**
- Zero-copy: tokens reference the source CSS text by offset+length, no string allocation
- Stream-based: `next() -> Token`, no need to tokenize entire input upfront
- Handles CSS escapes (`\XX`), unicode ranges, URL tokens
- Comment skipping built into tokenizer (no separate pass)

**Memory:** ~32 bytes per token. For 500KB CSS with ~25K tokens = ~800KB token stream. Acceptable on 512MB device if we stream instead of materializing all tokens.

### 1.2 Parser (`parser.zig`)

Recursive descent parser producing a stylesheet AST.

**AST types:**
```zig
const Stylesheet = struct {
    rules: []Rule,
};

const Rule = union(enum) {
    style: StyleRule,       // .foo { color: red }
    media: MediaRule,       // @media (max-width: 768px) { ... }
    keyframes: KeyframesRule,
    font_face: FontFaceRule,
    import: ImportRule,
    supports: SupportsRule,
    layer: LayerRule,
};

const StyleRule = struct {
    selectors: []Selector,   // comma-separated selector list
    declarations: []Declaration,
    source_order: u32,       // for cascade ordering
};

const Declaration = struct {
    property: PropertyId,    // enum of known properties
    value: Value,
    important: bool,
};
```

**Parsing strategy:**
1. Parse top-level: identify rules by looking at first token (`@` → at-rule, otherwise → style rule)
2. Style rules: parse selector list until `{`, then parse declaration block
3. At-rules: parse based on at-keyword type
4. Error recovery: on parse error, skip to next `}` or `;` (CSS spec error recovery)
5. Unknown properties preserved as raw strings (forward compatibility)

**Shorthand expansion:** Parser expands shorthands inline:
- `margin: 10px 20px` → margin-top: 10px, margin-right: 20px, margin-bottom: 10px, margin-left: 20px
- `background: red url(...) no-repeat` → background-color, background-image, background-repeat
- `border: 1px solid black` → border-width, border-style, border-color (all sides)

### 1.3 Selectors (`selectors.zig`)

**Selector representation:**
```zig
const Selector = struct {
    components: []Component,  // right-to-left order for matching
    specificity: Specificity,
};

const Specificity = struct {
    inline_: u8 = 0,   // inline style
    ids: u8 = 0,       // #id count
    classes: u8 = 0,    // .class, [attr], :pseudo-class count
    types: u8 = 0,      // element, ::pseudo-element count

    fn toU32(self: Specificity) u32 {
        return (@as(u32, self.inline_) << 24) |
               (@as(u32, self.ids) << 16) |
               (@as(u32, self.classes) << 8) |
               @as(u32, self.types);
    }
};

const Component = union(enum) {
    type_selector: []const u8,       // div, p, a
    class: []const u8,               // .foo
    id: []const u8,                  // #bar
    universal,                       // *
    attribute: AttributeSelector,    // [type="text"]
    pseudo_class: PseudoClass,       // :hover, :first-child
    pseudo_element: PseudoElement,   // ::before, ::after
    combinator: Combinator,          // descendant, child, sibling
};

const Combinator = enum {
    descendant,      // space
    child,           // >
    next_sibling,    // +
    subsequent_sibling, // ~
};

const PseudoClass = union(enum) {
    hover,
    focus,
    active,
    visited,
    link,
    first_child,
    last_child,
    nth_child: NthExpr,      // :nth-child(2n+1)
    nth_of_type: NthExpr,
    not: []Selector,          // :not(.foo)
    is: []Selector,           // :is(.a, .b)
    where: []Selector,        // :where(.a, .b) — zero specificity
    has: []Selector,          // :has(.child)
    root,
    empty,
    checked,
    disabled,
    enabled,
    // ... more as needed
};
```

**Matching algorithm — right-to-left:**
```
matchSelector(element, selector):
    current = element
    for each component in selector.components (right to left):
        if component is combinator:
            advance current according to combinator type
        else:
            if !matchComponent(current, component): return false
    return true
```

**Rule index for fast lookup:**
```zig
const RuleIndex = struct {
    by_id: StringHashMap([]IndexedRule),
    by_class: StringHashMap([]IndexedRule),
    by_tag: StringHashMap([]IndexedRule),
    universal: []IndexedRule,
};
```

When matching an element, collect candidate rules from:
1. `by_id[element.id]`
2. `by_class[class]` for each class on element
3. `by_tag[element.tag]`
4. `universal`

Then test each candidate's full selector. This reduces work from O(all_rules) to O(matching_candidates).

### 1.4 Cascade (`cascade.zig`)

**Cascade ordering** (CSS Cascading Level 5):
```
Priority (low → high):
1. UA stylesheet (default styles)
2. Author normal declarations (by specificity, then source order)
3. Author !important declarations
4. Inline style normal
5. Inline style !important
```

**Process per element:**
```zig
fn computeStyle(element: DomNode, parent_style: ?*const ComputedStyle,
                rule_index: *const RuleIndex, stylesheets: []const Stylesheet,
                variables: *const VarMap) ComputedStyle {
    // 1. Start with inherited properties from parent (or initial values for root)
    var style = if (parent_style) |p| inheritFrom(p) else initialStyle();

    // 2. Collect all matching declarations
    var declarations = collectMatchingDeclarations(element, rule_index, stylesheets);

    // 3. Sort by cascade priority
    sort(declarations, cascadeOrder);

    // 4. Apply declarations in order (last wins within same priority)
    for (declarations) |decl| {
        applyDeclaration(&style, decl);
    }

    // 5. Apply inline style (highest non-!important priority)
    if (element.getAttribute("style")) |inline_style| {
        applyInlineStyle(&style, inline_style);
    }

    // 6. Resolve var() references
    resolveVariables(&style, variables);

    // 7. Resolve calc(), relative units (em → px, % → px)
    resolveComputedValues(&style, parent_style);

    return style;
}
```

### 1.5 Properties (`properties.zig`)

Central registry of all CSS properties.

```zig
const PropertyDef = struct {
    id: PropertyId,
    name: []const u8,
    inherited: bool,
    initial_value: Value,
    parse_fn: *const fn([]const Token) ?Value,
    // Shorthand expansion (null for longhand properties)
    expand_fn: ?*const fn([]const Token) []Declaration = null,
};

// Auto-generate PropertyId enum from property list
const PropertyId = enum {
    display,
    position,
    float_,
    clear,
    width,
    height,
    min_width,
    max_width,
    min_height,
    max_height,
    margin_top,
    margin_right,
    margin_bottom,
    margin_left,
    padding_top,
    // ... ~150 properties for Phase 1 (CSS 2.1 + var + calc)
    // ... ~200 properties for Phase 2 (+ flex, grid, transforms)
    // ... ~250 properties for Phase 3 (+ animations, transitions, filters)
    custom,          // --* custom properties
    unknown,         // unrecognized properties (preserved for forward compat)
};
```

**Inheritance table** (subset):
| Property | Inherited | Initial |
|----------|-----------|---------|
| color | yes | black |
| font-size | yes | 16px (medium) |
| font-family | yes | system default |
| line-height | yes | normal |
| visibility | yes | visible |
| text-align | yes | start |
| display | no | inline |
| margin-* | no | 0 |
| padding-* | no | 0 |
| width/height | no | auto |
| position | no | static |
| opacity | no | 1 |

### 1.6 Values (`values.zig`)

```zig
const Value = union(enum) {
    keyword: Keyword,           // auto, none, block, flex, grid, inherit, initial
    length: Length,              // 10px, 2em, 1rem, 50vh
    percentage: f32,            // 50%
    number: f32,                // 0.5, 42
    color: u32,                 // ARGB
    string: []const u8,         // "hello"
    url: []const u8,            // url(...)
    calc: *CalcExpr,            // calc(100% - 20px)
    list: []Value,              // space or comma separated values
    function: FunctionValue,    // min(), max(), clamp()
    var_ref: VarRef,            // var(--name, fallback)
};

const Length = struct {
    value: f32,
    unit: Unit,
};

const Unit = enum {
    px, em, rem, vh, vw, vmin, vmax,
    pt, pc, cm, mm, in_,
    ch, ex, lh,
    percent,
    none,  // unitless number
};

const CalcExpr = union(enum) {
    value: Value,
    add: struct { left: *CalcExpr, right: *CalcExpr },
    sub: struct { left: *CalcExpr, right: *CalcExpr },
    mul: struct { left: *CalcExpr, right: *CalcExpr },
    div: struct { left: *CalcExpr, right: *CalcExpr },
};
```

### 1.7 CSS Variables (`variables.zig`)

Full CSS Custom Properties spec support:
- Variables scoped to elements (not just :root)
- Cascading: child elements inherit parent's variables
- Fallback values: `var(--name, fallback)`
- Nested var(): `var(--a, var(--b, default))`
- Cycle detection: circular references produce invalid value
- IACVT (Invalid At Computed Value Time): property becomes initial value

```zig
const VarMap = struct {
    // Per-element variable map (inherits from parent)
    vars: StringHashMap(Value),
    parent: ?*const VarMap,

    fn get(self: *const VarMap, name: []const u8) ?Value {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }
};
```

### 1.8 Media Queries (`media.zig`)

```zig
const MediaQuery = union(enum) {
    all,
    screen,
    print,
    width: RangeCondition,      // (min-width: 768px)
    height: RangeCondition,
    prefers_color_scheme: enum { light, dark },
    prefers_reduced_motion: enum { no_preference, reduce },
    not: *MediaQuery,
    and_: struct { left: *MediaQuery, right: *MediaQuery },
    or_: struct { left: *MediaQuery, right: *MediaQuery },
};

fn evaluateMediaQuery(query: MediaQuery, context: MediaContext) bool {
    // context contains viewport width/height, device type, preferences
}
```

## Phase 2: Layout Properties

### Grid Layout
- `grid-template-columns`, `grid-template-rows`
- `grid-column`, `grid-row` (placement)
- `grid-gap` / `gap`
- `grid-auto-flow`
- `fr` unit support
- `repeat()`, `minmax()`, `auto-fill`, `auto-fit`
- Implementation in `src/layout/grid.zig` (new file)

### Transforms
- `transform: translate(), scale(), rotate(), skew()`
- `transform-origin`
- Applied during paint phase, not layout
- Matrix multiplication for composed transforms

### Pseudo-elements
- `::before`, `::after` with `content` property
- Inserted as virtual boxes in the box tree
- Generated during box tree construction (`src/layout/tree.zig`)

### :has() selector
- Subject-based matching (expensive — only evaluate when needed)
- Cache results per cascade run

## Phase 3: Visual Effects

### Transitions
- `transition-property`, `transition-duration`, `transition-timing-function`, `transition-delay`
- Interpolation engine for animatable properties (color, length, transform)
- Triggered on style change detection
- Easing functions: linear, ease, ease-in, ease-out, ease-in-out, cubic-bezier

### Animations
- `@keyframes` rule parsing
- `animation-*` properties
- Keyframe interpolation using same engine as transitions
- Integration with requestAnimationFrame in JS runtime

### Filters
- `filter: blur(), brightness(), contrast(), grayscale(), saturate(), sepia()`
- `backdrop-filter` (if framebuffer supports it)
- Applied during paint phase as post-processing

### Other
- `clip-path: polygon(), circle(), ellipse(), inset()`
- `mask` / `mask-image`
- CSS Counters: `counter-reset`, `counter-increment`, `content: counter()`
- `object-fit`, `object-position`
- `outline` properties

## Memory Budget

Target: CSS engine total < 20MB on typical sites.

| Component | Estimate |
|-----------|----------|
| Stylesheet AST (500KB CSS) | ~2MB |
| Rule index (hash maps) | ~1MB |
| Token stream (if materialized) | ~800KB |
| ComputedStyle per element (~200B × 5000 elements) | ~1MB |
| Variable maps | ~200KB |
| Total | ~5MB typical |

For GitHub (2.3MB CSS, ~10K elements): ~15MB. Within 512MB budget.

Streaming tokenizer avoids materializing all tokens. Parse → discard tokens → keep AST only.

## Migration Strategy

1. Build new CSS engine alongside existing LibCSS code (`src/css/` parallel to `src/style/`)
2. Add build flag `-Dcss-engine=new` to switch between LibCSS and new engine
3. New engine's `cascade()` function has same signature as existing one (returns `StyleMap`)
4. Test on target sites, compare rendering output
5. Once parity reached, remove LibCSS code and build dependencies
6. Remove build flag, new engine becomes default

## Testing Strategy

- Unit tests per module (tokenizer, parser, selectors, cascade)
- CSS test suites: extract relevant tests from [WPT (web-platform-tests)](https://wpt.fyi/)
- Visual regression: screenshot comparison on target sites (GitHub, Wikipedia, MDN, SO, Brave Search)
- Memory profiling: track peak RSS on target sites
- Fuzz testing: feed random CSS to tokenizer/parser, ensure no crashes

## Non-Goals

- CSS Houdini (Paint API, Layout API)
- CSS Regions
- CSS Shapes (shape-outside)
- Multi-column layout (column-count, column-width) — maybe later
- @page / print stylesheets
- CSS Nesting (nice-to-have, not priority)
