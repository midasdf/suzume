# CSS Engine Phase 1a: Tokenizer + Parser

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CSS Syntax Level 3 compliant tokenizer and recursive descent parser in Zig, producing a stylesheet AST with all declarations parsed into typed values.

**Architecture:** Zero-copy streaming tokenizer feeds tokens to a recursive descent parser. Parser produces a `Stylesheet` AST with `StyleRule`, `MediaRule`, etc. Shorthand properties expanded at parse time. String interning via `StringPool`. Arena allocator for AST nodes.

**Tech Stack:** Zig 0.14, no external dependencies. Tests via `zig test`.

**Spec:** `docs/superpowers/specs/2026-03-18-css-engine-design.md`

---

## File Structure

```
src/css/
├── tokenizer.zig     -- CSS Syntax L3 tokenizer (streaming, zero-copy)
├── parser.zig        -- Recursive descent parser → Stylesheet AST
├── values.zig        -- CSS value types (Length, Color, Keyword, Calc, etc.)
├── properties.zig    -- PropertyId enum + shorthand expansion + parse fns
├── string_pool.zig   -- String interning for class names, property names
├── ast.zig           -- AST node types (Stylesheet, Rule, Declaration, etc.)
tests/
├── test_tokenizer.zig
├── test_parser.zig
└── fixtures/
    ├── basic.css
    ├── github-nav.css     -- real-world minified CSS
    └── variables.css
```

---

## Chunk 1: Tokenizer

### Task 1: StringPool

**Files:**
- Create: `src/css/string_pool.zig`
- Create: `tests/test_string_pool.zig`

- [ ] **Step 1: Write failing test**

```zig
// tests/test_string_pool.zig
const std = @import("std");
const StringPool = @import("../src/css/string_pool.zig").StringPool;

test "intern returns same pointer for same string" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("hello");
    const b = pool.intern("hello");
    expect(a.ptr == b.ptr);
    expect(std.mem.eql(u8, a, "hello"));
}

test "intern returns different pointers for different strings" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("foo");
    const b = pool.intern("bar");
    expect(a.ptr != b.ptr);
}

test "intern handles empty string" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = pool.intern("");
    expect(a.len == 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tests/test_string_pool.zig`
Expected: FAIL — file not found

- [ ] **Step 3: Implement StringPool**

```zig
// src/css/string_pool.zig
const std = @import("std");

pub const StringPool = struct {
    strings: std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{ .strings = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.deinit(self.allocator);
    }

    /// Intern a string: return a stable pointer to a deduplicated copy.
    pub fn intern(self: *StringPool, str: []const u8) []const u8 {
        if (self.strings.getKey(str)) |existing| return existing;
        const owned = self.allocator.dupe(u8, str) catch return str;
        self.strings.put(self.allocator, owned, {}) catch return str;
        return owned;
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test tests/test_string_pool.zig`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/css/string_pool.zig tests/test_string_pool.zig
git commit -m "feat(css): add StringPool for string interning"
```

---

### Task 2: CSS Value Types

**Files:**
- Create: `src/css/values.zig`

- [ ] **Step 1: Define core value types**

```zig
// src/css/values.zig
const std = @import("std");

pub const Unit = enum {
    px, em, rem, vh, vw, vmin, vmax,
    pt, pc, cm, mm, in_,
    ch, ex, lh,
    percent,
    fr,       // grid fraction
    deg, rad, grad, turn,  // angles
    s, ms,    // time
    none,
};

pub const Length = struct {
    value: f32,
    unit: Unit,
};

pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8,

    pub fn toArgb(self: Color) u32 {
        return (@as(u32, self.a) << 24) | (@as(u32, self.r) << 16) |
               (@as(u32, self.g) << 8) | @as(u32, self.b);
    }

    pub fn fromArgb(argb: u32) Color {
        return .{
            .a = @truncate(argb >> 24),
            .r = @truncate(argb >> 16),
            .g = @truncate(argb >> 8),
            .b = @truncate(argb),
        };
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
};

pub const CalcOp = enum { add, sub, mul, div, value };

pub const CalcNode = struct {
    op: CalcOp,
    value: Value = .{ .keyword = .none },  // for CalcOp.value
};

pub const Keyword = enum {
    none, auto, inherit, initial, unset, revert,
    block, inline_, inline_block, flex, inline_flex,
    grid, inline_grid, table, list_item,
    table_row, table_cell, table_row_group,
    table_header_group, table_footer_group,
    table_column, table_column_group, table_caption,
    hidden, visible, collapse,
    static_, relative, absolute, fixed, sticky,
    left, right, center, justify,
    normal, nowrap, pre, pre_wrap, pre_line,
    bold, bolder, lighter,
    underline, line_through, overline,
    // ... extend as needed
};

pub const Value = union(enum) {
    keyword: Keyword,
    length: Length,
    percentage: f32,
    number: f32,
    color: Color,
    string: []const u8,
    url: []const u8,
    calc: []CalcNode,       // postfix calc expression
    list: []Value,          // space or comma separated
    var_ref: VarRef,
    function: FunctionValue,
    raw: []const u8,        // unparsed value (forward compat)
};

pub const VarRef = struct {
    name: []const u8,       // "--my-var"
    fallback: ?[]const u8,  // fallback value as raw text
};

pub const FunctionValue = struct {
    name: []const u8,
    args: []Value,
};
```

- [ ] **Step 2: Commit**

```bash
git add src/css/values.zig
git commit -m "feat(css): add CSS value types (Length, Color, Calc, etc.)"
```

---

### Task 3: Token Types

**Files:**
- Create: `src/css/tokenizer.zig` (types only, no logic yet)

- [ ] **Step 1: Define token types**

```zig
// src/css/tokenizer.zig
const std = @import("std");

pub const TokenType = enum {
    ident,
    function,       // name followed by '('
    at_keyword,     // @name
    hash,           // #name
    string,         // "..." or '...'
    bad_string,
    url,            // url(...)
    bad_url,
    delim,          // single character
    number,
    percentage,
    dimension,
    whitespace,
    colon,
    semicolon,
    comma,
    open_bracket,   // [
    close_bracket,  // ]
    open_paren,     // (
    close_paren,    // )
    open_curly,     // {
    close_curly,    // }
    eof,
};

pub const Token = struct {
    type: TokenType,
    start: u32,
    len: u32,
    numeric_value: f32 = 0,
    unit_start: u32 = 0,   // for dimension tokens: offset of unit string
    unit_len: u16 = 0,

    /// Get the token's text from the source CSS.
    pub fn text(self: Token, source: []const u8) []const u8 {
        const end = self.start + self.len;
        if (end > source.len) return "";
        return source[self.start..end];
    }
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        // TODO: implement
        return .{ .type = .eof, .start = self.pos, .len = 0 };
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/css/tokenizer.zig
git commit -m "feat(css): add token type definitions"
```

---

### Task 4: Tokenizer — Whitespace + Simple Tokens

**Files:**
- Modify: `src/css/tokenizer.zig`
- Create: `tests/test_tokenizer.zig`

- [ ] **Step 1: Write failing tests**

```zig
// tests/test_tokenizer.zig
const std = @import("std");
const Tokenizer = @import("../src/css/tokenizer.zig").Tokenizer;
const TokenType = @import("../src/css/tokenizer.zig").TokenType;

fn expectTokens(source: []const u8, expected: []const TokenType) !void {
    var tok = Tokenizer.init(source);
    for (expected) |exp| {
        const t = tok.next();
        try std.testing.expectEqual(exp, t.type);
    }
    try std.testing.expectEqual(TokenType.eof, tok.next().type);
}

test "empty input" {
    try expectTokens("", &.{});
}

test "whitespace" {
    try expectTokens("   \t\n  ", &.{.whitespace});
}

test "delimiters" {
    try expectTokens("{}();:,[]", &.{
        .open_curly, .close_curly, .open_paren, .close_paren,
        .semicolon, .colon, .comma, .open_bracket, .close_bracket,
    });
}

test "mixed whitespace and delimiters" {
    try expectTokens(" { } ", &.{ .whitespace, .open_curly, .whitespace, .close_curly, .whitespace });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tests/test_tokenizer.zig`
Expected: FAIL

- [ ] **Step 3: Implement whitespace + delimiter tokenization**

In `Tokenizer.next()`:
- Skip and emit whitespace token for runs of space/tab/newline/form-feed
- Emit single-character tokens for `{}();:,[]`
- Return EOF when pos >= source.len

- [ ] **Step 4: Run tests, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add src/css/tokenizer.zig tests/test_tokenizer.zig
git commit -m "feat(css): tokenize whitespace and delimiters"
```

---

### Task 5: Tokenizer — Ident + Hash + At-keyword

- [ ] **Step 1: Add tests**

```zig
test "ident" {
    var tok = Tokenizer.init("color");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.ident, t.type);
    try std.testing.expectEqualStrings("color", t.text("color"));
}

test "ident with hyphens" {
    var tok = Tokenizer.init("background-color");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.ident, t.type);
}

test "custom property name" {
    var tok = Tokenizer.init("--my-var");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.ident, t.type);
}

test "hash" {
    try expectTokens("#foo", &.{.hash});
    try expectTokens("#FF0000", &.{.hash});
}

test "at-keyword" {
    try expectTokens("@media", &.{.at_keyword});
    try expectTokens("@keyframes", &.{.at_keyword});
}
```

- [ ] **Step 2: Implement ident scanning** — scan `[a-zA-Z_-]` start, then `[a-zA-Z0-9_-]` continuation. `#` + ident = hash. `@` + ident = at_keyword. Handle CSS escapes (`\XX`).

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 6: Tokenizer — Numbers + Dimensions + Percentages

- [ ] **Step 1: Add tests**

```zig
test "integer" {
    var tok = Tokenizer.init("42");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), t.numeric_value, 0.01);
}

test "float" {
    var tok = Tokenizer.init("3.14");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), t.numeric_value, 0.01);
}

test "negative number" {
    var tok = Tokenizer.init("-10");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), t.numeric_value, 0.01);
}

test "dimension px" {
    var tok = Tokenizer.init("10px");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.dimension, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), t.numeric_value, 0.01);
}

test "percentage" {
    var tok = Tokenizer.init("50%");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.percentage, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), t.numeric_value, 0.01);
}
```

- [ ] **Step 2: Implement** — scan digits, optional `.`, more digits. If followed by `%` → percentage. If followed by ident → dimension. Else → number.

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 7: Tokenizer — Strings + URLs + Comments

- [ ] **Step 1: Add tests**

```zig
test "double-quoted string" {
    var tok = Tokenizer.init("\"hello world\"");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.string, t.type);
}

test "single-quoted string" {
    var tok = Tokenizer.init("'hello'");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.string, t.type);
}

test "string with escape" {
    var tok = Tokenizer.init("\"he\\\"llo\"");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.string, t.type);
}

test "url token" {
    var tok = Tokenizer.init("url(https://example.com/img.png)");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.url, t.type);
}

test "comments are skipped" {
    try expectTokens("/* comment */ div", &.{.whitespace, .ident});
}

test "comment between tokens" {
    try expectTokens("a /* x */ b", &.{ .ident, .whitespace, .whitespace, .ident });
}
```

- [ ] **Step 2: Implement** — string scanning with escape handling, `url(` detection (unquoted URL vs function), comment skipping (`/* ... */`)

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 8: Tokenizer — Function Tokens + Integration

- [ ] **Step 1: Add tests**

```zig
test "function token" {
    try expectTokens("rgb(", &.{.function});
    try expectTokens("var(", &.{.function});
    try expectTokens("calc(", &.{.function});
}

test "full CSS rule tokenization" {
    try expectTokens(".foo { color: red; }", &.{
        .delim,      // .
        .ident,      // foo
        .whitespace,
        .open_curly,
        .whitespace,
        .ident,      // color
        .colon,
        .whitespace,
        .ident,      // red
        .semicolon,
        .whitespace,
        .close_curly,
    });
}

test "real-world minified CSS" {
    const css = ".NavDropdown-module__dropdown__xm1jd{background-color:var(--bgColor-default);visibility:hidden}";
    var tok = Tokenizer.init(css);
    var count: usize = 0;
    while (tok.next().type != .eof) count += 1;
    try std.testing.expect(count > 10);
}
```

- [ ] **Step 2: Implement** — `ident(` pattern → function token. Ensure all token types work together.

- [ ] **Step 3: Run all tokenizer tests**

Run: `zig test tests/test_tokenizer.zig`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(css): complete CSS Syntax L3 tokenizer"
```

---

## Chunk 2: Parser

### Task 9: AST Types

**Files:**
- Create: `src/css/ast.zig`

- [ ] **Step 1: Define AST types**

```zig
// src/css/ast.zig
const std = @import("std");
const values = @import("values.zig");

pub const PropertyId = enum(u16) {
    display, position, float_, clear,
    width, height, min_width, max_width, min_height, max_height,
    margin_top, margin_right, margin_bottom, margin_left,
    padding_top, padding_right, padding_bottom, padding_left,
    border_top_width, border_right_width, border_bottom_width, border_left_width,
    border_top_color, border_right_color, border_bottom_color, border_left_color,
    border_top_style, border_right_style, border_bottom_style, border_left_style,
    color, background_color, background_image, background_repeat, background_position,
    font_size, font_weight, font_style, font_family,
    line_height, letter_spacing, word_spacing,
    text_align, text_decoration, text_transform, text_indent,
    white_space, word_break, overflow_wrap, text_overflow,
    vertical_align, visibility, opacity,
    overflow_x, overflow_y,
    z_index, top, right, bottom, left,
    list_style_type,
    box_sizing,
    border_radius_top_left, border_radius_top_right,
    border_radius_bottom_left, border_radius_bottom_right,
    box_shadow, text_shadow,
    flex_direction, flex_wrap, justify_content, align_items, align_self,
    flex_grow, flex_shrink, flex_basis, gap, row_gap, column_gap,
    // Grid (Phase 2)
    grid_template_columns, grid_template_rows,
    grid_column_start, grid_column_end, grid_row_start, grid_row_end,
    grid_auto_flow,
    // Transforms (Phase 2)
    transform, transform_origin,
    // Transitions/Animations (Phase 3)
    transition_property, transition_duration, transition_timing_function, transition_delay,
    animation_name, animation_duration, animation_timing_function, animation_delay,
    animation_iteration_count, animation_direction, animation_fill_mode, animation_play_state,
    // Filters (Phase 3)
    filter, backdrop_filter,
    clip_path,
    // Content
    content,
    // Counters
    counter_reset, counter_increment,
    // Custom property
    custom,
    unknown,

    pub fn fromString(name: []const u8) PropertyId {
        // TODO: use comptime string map
        return .unknown;
    }
};

pub const Declaration = struct {
    property: PropertyId,
    property_name: []const u8,  // raw name (for custom properties)
    value: values.Value,
    value_raw: []const u8,      // raw unparsed value text
    important: bool = false,
};

pub const Selector = struct {
    source: []const u8,  // raw selector text (parsing deferred to selectors.zig)
};

pub const StyleRule = struct {
    selectors: []Selector,
    declarations: []Declaration,
    source_order: u32,
};

pub const MediaQuery = struct {
    raw: []const u8,  // unparsed media query text (evaluated in media.zig)
};

pub const Rule = union(enum) {
    style: StyleRule,
    media: MediaRule,
    keyframes: KeyframesRule,
    font_face: FontFaceRule,
    import: ImportRule,
    supports: SupportsRule,
};

pub const MediaRule = struct {
    query: MediaQuery,
    rules: []Rule,
};

pub const KeyframesRule = struct {
    name: []const u8,
    keyframes: []Keyframe,
};

pub const Keyframe = struct {
    selectors: []f32,           // 0.0 = from, 1.0 = to, 0.5 = 50%
    declarations: []Declaration,
};

pub const FontFaceRule = struct {
    declarations: []Declaration,
};

pub const ImportRule = struct {
    url: []const u8,
};

pub const SupportsRule = struct {
    condition: []const u8,
    rules: []Rule,
};

pub const Stylesheet = struct {
    rules: []Rule,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Stylesheet) void {
        // Free all allocated AST memory
        _ = self;
    }
};
```

- [ ] **Step 2: Commit**

```bash
git add src/css/ast.zig
git commit -m "feat(css): add AST types for stylesheet representation"
```

---

### Task 10: Parser — Style Rules

**Files:**
- Create: `src/css/parser.zig`
- Create: `tests/test_parser.zig`

- [ ] **Step 1: Write failing test**

```zig
// tests/test_parser.zig
const std = @import("std");
const Parser = @import("../src/css/parser.zig").Parser;

test "parse simple rule" {
    const css = "div { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.selectors.len);
    try std.testing.expectEqual(@as(usize, 1), rule.declarations.len);
    try std.testing.expectEqualStrings("color", rule.declarations[0].property_name);
}

test "parse multiple declarations" {
    const css = ".btn { color: red; margin: 10px; display: flex; }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 3), rule.declarations.len);
}

test "parse !important" {
    const css = "p { color: red !important; }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules[0].style.declarations[0].important);
}

test "parse multiple selectors" {
    const css = "h1, h2, h3 { font-weight: bold; }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    try std.testing.expectEqual(@as(usize, 3), stylesheet.rules[0].style.selectors.len);
}
```

- [ ] **Step 2: Run test, verify FAIL**

- [ ] **Step 3: Implement Parser.parse()**

Parser logic:
1. `parse()`: loop calling `parseRule()` until EOF
2. `parseRule()`: peek first token — if `@` → `parseAtRule()`, else → `parseStyleRule()`
3. `parseStyleRule()`: consume tokens until `{`, split by comma for selectors. Then `parseDeclarationBlock()`.
4. `parseDeclarationBlock()`: inside `{...}`, parse `property: value;` pairs. Detect `!important` before `;`.
5. Store raw value text for now (value parsing in next task).

- [ ] **Step 4: Run tests, verify PASS**
- [ ] **Step 5: Commit**

---

### Task 11: Parser — At-Rules (@media, @keyframes)

- [ ] **Step 1: Write failing tests**

```zig
test "parse @media rule" {
    const css = "@media (max-width: 768px) { .sidebar { display: none; } }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const media = stylesheet.rules[0].media;
    try std.testing.expectEqual(@as(usize, 1), media.rules.len);
}

test "parse @keyframes" {
    const css = "@keyframes fade { from { opacity: 0; } to { opacity: 1; } }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    const kf = stylesheet.rules[0].keyframes;
    try std.testing.expectEqualStrings("fade", kf.name);
    try std.testing.expectEqual(@as(usize, 2), kf.keyframes.len);
}

test "parse nested @media" {
    const css = "@media screen { @media (min-width: 1024px) { div { color: blue; } } }";
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    const outer = stylesheet.rules[0].media;
    const inner = outer.rules[0].media;
    try std.testing.expectEqual(@as(usize, 1), inner.rules.len);
}
```

- [ ] **Step 2: Implement at-rule parsing** — `@media`: parse query text until `{`, then recursively parse rules inside block. `@keyframes`: parse name, then keyframe blocks. `@font-face`: parse as declaration block. `@import`, `@supports`: parse and store.

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 12: Parser — Value Parsing (Colors)

**Files:**
- Create: `src/css/properties.zig` (color parsing functions)

- [ ] **Step 1: Write failing tests**

```zig
test "parse hex color #RGB" {
    const v = parseColorValue("#f00");
    try std.testing.expectEqual(@as(u8, 255), v.?.r);
    try std.testing.expectEqual(@as(u8, 0), v.?.g);
}

test "parse hex color #RRGGBB" {
    const v = parseColorValue("#FF8800");
    try std.testing.expectEqual(@as(u8, 255), v.?.r);
    try std.testing.expectEqual(@as(u8, 136), v.?.g);
}

test "parse rgb()" {
    const v = parseColorValue("rgb(255, 128, 0)");
    try std.testing.expect(v != null);
}

test "parse named color" {
    const v = parseColorValue("red");
    try std.testing.expectEqual(@as(u8, 255), v.?.r);
}

test "parse hsl()" {
    const v = parseColorValue("hsl(0, 100%, 50%)");
    try std.testing.expect(v != null);
}
```

- [ ] **Step 2: Implement** — Migrate and refactor existing `parseCssColor`, `parseHexColor`, `parseRgbFunc`, `parseHslFunc`, `namedColor` from `src/style/cascade.zig` into `src/css/properties.zig`. These are well-tested functions that can be moved with minimal changes.

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 13: Parser — Value Parsing (Lengths, Keywords, var())

- [ ] **Step 1: Write tests**

```zig
test "parse length 10px" {
    const v = parseLengthValue("10px");
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), v.?.value, 0.01);
    try std.testing.expectEqual(Unit.px, v.?.unit);
}

test "parse length 2em" {
    const v = parseLengthValue("2em");
    try std.testing.expectEqual(Unit.em, v.?.unit);
}

test "parse percentage" {
    // "50%" should parse as percentage
}

test "parse var() reference" {
    const v = parseVarRef("var(--main-color)");
    try std.testing.expectEqualStrings("--main-color", v.?.name);
    try std.testing.expectEqual(@as(?[]const u8, null), v.?.fallback);
}

test "parse var() with fallback" {
    const v = parseVarRef("var(--color, red)");
    try std.testing.expectEqualStrings("--color", v.?.name);
    try std.testing.expect(v.?.fallback != null);
}
```

- [ ] **Step 2: Implement** length parsing, keyword mapping, var() reference parsing.
- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 14: Parser — Shorthand Expansion

- [ ] **Step 1: Write tests**

```zig
test "expand margin shorthand (4 values)" {
    const decls = expandShorthand("margin", "10px 20px 30px 40px");
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    // margin-top: 10px, margin-right: 20px, margin-bottom: 30px, margin-left: 40px
}

test "expand margin shorthand (2 values)" {
    const decls = expandShorthand("margin", "10px 20px");
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    // top/bottom: 10px, left/right: 20px
}

test "expand margin shorthand (1 value)" {
    const decls = expandShorthand("margin", "10px");
    try std.testing.expectEqual(@as(usize, 4), decls.len);
}

test "expand border shorthand" {
    const decls = expandShorthand("border", "1px solid black");
    try std.testing.expect(decls.len >= 3); // width, style, color for all sides
}

test "expand margin: inherit" {
    const decls = expandShorthand("margin", "inherit");
    for (decls) |d| {
        try std.testing.expectEqual(Keyword.inherit, d.value.keyword);
    }
}
```

- [ ] **Step 2: Implement** — shorthands for margin, padding, border, border-radius, background, font, flex, list-style, overflow, transition, animation. CSS-wide keywords (inherit/initial/unset) preserved.

- [ ] **Step 3: Run tests, verify PASS**
- [ ] **Step 4: Commit**

---

### Task 15: Parser — Real-World CSS Integration Test

- [ ] **Step 1: Create test fixtures**

Copy `/tmp/github-nav.css` (the marketing-navigation module CSS from GitHub) to `tests/fixtures/github-nav.css`.

- [ ] **Step 2: Write integration test**

```zig
test "parse real-world GitHub CSS" {
    const css = @embedFile("fixtures/github-nav.css");
    var parser = Parser.init(css, std.testing.allocator);
    const stylesheet = try parser.parse();
    defer stylesheet.deinit();

    // Should parse without errors
    try std.testing.expect(stylesheet.rules.len > 0);

    // Should find visibility:hidden rule
    var found_visibility_hidden = false;
    for (stylesheet.rules) |rule| {
        if (rule == .style) {
            for (rule.style.declarations) |decl| {
                if (decl.property == .visibility) {
                    if (decl.value == .keyword and decl.value.keyword == .hidden) {
                        found_visibility_hidden = true;
                    }
                }
            }
        }
    }
    try std.testing.expect(found_visibility_hidden);
}
```

- [ ] **Step 3: Create fixture with basic CSS for parsing**

```css
/* tests/fixtures/basic.css */
:root {
    --primary: #0066cc;
    --bg: white;
}

body { margin: 0; font-family: sans-serif; }

.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 20px;
}

@media (max-width: 768px) {
    .container { padding: 0 10px; }
    .sidebar { display: none; }
}
```

- [ ] **Step 4: Run all parser tests**

Run: `zig test tests/test_parser.zig`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/ tests/test_parser.zig
git commit -m "feat(css): complete parser with real-world CSS test"
```

---

## Chunk 3: Build Integration

### Task 16: Wire Up to Build System

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Add test steps for new CSS modules**

Add to build.zig:
```zig
// CSS engine tests
const css_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/test_tokenizer.zig"),
    .target = target,
    .optimize = optimize,
});
const css_tests = b.addTest(.{ .root_module = css_test_mod });
const run_css_tests = b.addRunArtifact(css_tests);
const css_test_step = b.step("test-css", "Run CSS engine tests");
css_test_step.dependOn(&run_css_tests.step);
```

- [ ] **Step 2: Verify**

Run: `zig build test-css`
Expected: All CSS tests PASS

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "build: add test-css step for new CSS engine"
```

---

### Task 17: PropertyId String Mapping

- [ ] **Step 1: Implement `PropertyId.fromString()`** using a comptime-generated hash map or a chain of string comparisons.

- [ ] **Step 2: Test all ~80 Phase 1 property names map correctly**

- [ ] **Step 3: Commit**

---

**End of Phase 1a. Next: Phase 1b (Selectors + Cascade) builds on this foundation.**
