# kotori Phase 1a: Lexer + Parser + AST

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a spec-compliant ECMAScript lexer and parser that produces an AST, verified by parsing real JS from web pages.

**Architecture:** Lexer tokenizes UTF-8 source into ECMAScript tokens. Parser consumes tokens via recursive descent (Pratt parsing for expressions) to build a typed AST. All pure transformations, no side effects, no VM dependency.

**Tech Stack:** Zig 0.15, no external dependencies. Test via `zig build test-kotori`.

**Spec:** `docs/superpowers/specs/2026-04-11-kotori-js-engine-design.md`

---

## File Structure

```
suzume/src/js/kotori/
├── value.zig       # JsValue NaN-boxing (stub — needed by ast.zig for literal constants)
├── lexer.zig       # Tokenizer: UTF-8 source → Token stream
├── token.zig       # Token type definitions
├── ast.zig         # AST node definitions
├── parser.zig      # Recursive descent parser with Pratt expression parsing
└── string_pool.zig # Interned string table (u32 IDs for identifiers/property names)

suzume/tests/
├── test_kotori.zig      # Aggregator for all kotori tests
├── test_kotori_lexer.zig
└── test_kotori_parser.zig

suzume/build.zig          # Modified: add test-kotori target
```

---

### Task 1: Project scaffold + build integration

**Files:**
- Create: `src/js/kotori/value.zig`
- Create: `src/js/kotori/token.zig`
- Create: `src/js/kotori/lexer.zig` (stub)
- Create: `src/js/kotori/ast.zig` (stub)
- Create: `src/js/kotori/parser.zig` (stub)
- Create: `src/js/kotori/string_pool.zig` (stub)
- Create: `tests/test_kotori.zig`
- Create: `tests/test_kotori_lexer.zig` (stub)
- Create: `tests/test_kotori_parser.zig` (stub)
- Modify: `build.zig`

- [ ] **Step 1: Create token.zig with all ECMAScript token types**

```zig
// src/js/kotori/token.zig
const std = @import("std");

pub const TokenType = enum(u8) {
    // Literals
    number,          // 42, 3.14, 0xFF, 1e10
    string,          // "hello", 'world'
    regex,           // /pattern/flags
    template,        // `template`
    template_head,   // `head${
    template_middle, // }middle${
    template_tail,   // }tail`

    // Identifiers & keywords
    identifier,
    // Keywords (ES5+)
    kw_break, kw_case, kw_catch, kw_continue, kw_debugger,
    kw_default, kw_delete, kw_do, kw_else, kw_finally,
    kw_for, kw_function, kw_if, kw_in, kw_instanceof,
    kw_new, kw_return, kw_switch, kw_this, kw_throw,
    kw_try, kw_typeof, kw_var, kw_void, kw_while, kw_with,
    // ES6 keywords
    kw_let, kw_const, kw_class, kw_extends, kw_super,
    kw_import, kw_export, kw_yield, kw_async, kw_await,
    kw_of,
    // Literals as keywords
    kw_true, kw_false, kw_null, kw_undefined,

    // Punctuators
    lparen, rparen,       // ( )
    lbrace, rbrace,       // { }
    lbracket, rbracket,   // [ ]
    dot, ellipsis,        // . ...
    semicolon, comma,     // ; ,
    colon, question,      // : ?
    optional_chain,       // ?.
    arrow,                // =>
    // Arithmetic
    plus, minus, star, slash, percent, power,  // + - * / % **
    // Comparison
    lt, gt, le, ge,       // < > <= >=
    eq_eq, ne, eq_eq_eq, ne_eq, // == != === !==
    // Logical
    amp_amp, pipe_pipe,   // && ||
    bang,                  // !
    nullish,              // ??
    // Bitwise
    amp, pipe, caret, tilde, // & | ^ ~
    shl, shr, ushr,       // << >> >>>
    // Assignment
    assign,                // =
    plus_assign, minus_assign, star_assign, slash_assign, percent_assign,
    power_assign, amp_assign, pipe_assign, caret_assign,
    shl_assign, shr_assign, ushr_assign,
    amp_amp_assign, pipe_pipe_assign, nullish_assign,
    // Increment/Decrement
    plus_plus, minus_minus, // ++ --

    // Special
    eof,
    line_terminator,       // for ASI (automatic semicolon insertion)
};

pub const Token = struct {
    type: TokenType,
    start: u32,     // byte offset in source
    len: u16,       // byte length
    line: u32,      // 1-based line number

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

/// Keyword lookup table. Returns keyword token type or null.
pub fn lookupKeyword(ident: []const u8) ?TokenType {
    const map = std.StaticStringMap(TokenType).initComptime(.{
        .{ "break", .kw_break }, .{ "case", .kw_case }, .{ "catch", .kw_catch },
        .{ "continue", .kw_continue }, .{ "debugger", .kw_debugger },
        .{ "default", .kw_default }, .{ "delete", .kw_delete }, .{ "do", .kw_do },
        .{ "else", .kw_else }, .{ "finally", .kw_finally }, .{ "for", .kw_for },
        .{ "function", .kw_function }, .{ "if", .kw_if }, .{ "in", .kw_in },
        .{ "instanceof", .kw_instanceof }, .{ "new", .kw_new },
        .{ "return", .kw_return }, .{ "switch", .kw_switch }, .{ "this", .kw_this },
        .{ "throw", .kw_throw }, .{ "try", .kw_try }, .{ "typeof", .kw_typeof },
        .{ "var", .kw_var }, .{ "void", .kw_void }, .{ "while", .kw_while },
        .{ "with", .kw_with },
        .{ "let", .kw_let }, .{ "const", .kw_const }, .{ "class", .kw_class },
        .{ "extends", .kw_extends }, .{ "super", .kw_super },
        .{ "import", .kw_import }, .{ "export", .kw_export },
        .{ "yield", .kw_yield }, .{ "async", .kw_async }, .{ "await", .kw_await },
        .{ "of", .kw_of },
        .{ "true", .kw_true }, .{ "false", .kw_false }, .{ "null", .kw_null },
        .{ "undefined", .kw_undefined },
    });
    return map.get(ident);
}
```

- [ ] **Step 2: Create value.zig stub (NaN-boxing, minimal for AST)**

```zig
// src/js/kotori/value.zig
pub const JsValue = packed struct {
    bits: u64,

    const TAG_NAN: u16 = 0x7FF8;
    const TAG_NULL: u16 = 0x7FF9;
    const TAG_UNDEFINED: u16 = 0x7FFA;
    const TAG_BOOL: u16 = 0x7FFB;
    const TAG_INT: u16 = 0x7FFC;
    const TAG_OBJECT: u16 = 0x7FFD;
    const TAG_STRING: u16 = 0x7FFE;
    const TAG_SYMBOL: u16 = 0x7FFF;

    pub fn initNumber(n: f64) JsValue {
        return .{ .bits = @bitCast(n) };
    }

    pub fn initInt(i: i32) JsValue {
        return .{ .bits = (@as(u64, TAG_INT) << 48) | @as(u64, @as(u32, @bitCast(i))) };
    }

    pub fn initBool(b: bool) JsValue {
        return .{ .bits = (@as(u64, TAG_BOOL) << 48) | @intFromBool(b) };
    }

    pub const null_val = JsValue{ .bits = @as(u64, TAG_NULL) << 48 };
    pub const undefined_val = JsValue{ .bits = @as(u64, TAG_UNDEFINED) << 48 };
    pub const nan_val = JsValue{ .bits = 0x7FF8_0000_0000_0000 }; // canonical NaN

    pub inline fn isGcPtr(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_OBJECT or tag == TAG_STRING;
    }

    pub fn asNumber(self: JsValue) f64 {
        return @bitCast(self.bits);
    }
};
```

- [ ] **Step 3: Create stub files for lexer, ast, parser, string_pool**

```zig
// src/js/kotori/string_pool.zig
const std = @import("std");

pub const StringId = u32;

pub const StringPool = struct {
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(StringId) = .empty,

    pub fn intern(self: *StringPool, allocator: std.mem.Allocator, s: []const u8) !StringId {
        if (self.map.get(s)) |id| return id;
        const id: StringId = @intCast(self.strings.items.len);
        const owned = try allocator.dupe(u8, s);
        try self.strings.append(allocator, owned);
        try self.map.put(allocator, owned, id);
        return id;
    }

    pub fn get(self: *const StringPool, id: StringId) []const u8 {
        return self.strings.items[id];
    }

    pub fn deinit(self: *StringPool, allocator: std.mem.Allocator) void {
        for (self.strings.items) |s| allocator.free(s);
        self.strings.deinit(allocator);
        self.map.deinit(allocator);
    }
};
```

```zig
// src/js/kotori/lexer.zig
const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        // TODO: implement
        return .{ .type = .eof, .start = self.pos, .len = 0, .line = self.line };
    }
};
```

```zig
// src/js/kotori/ast.zig
const std = @import("std");
const StringId = @import("string_pool.zig").StringId;

pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

pub const Node = union(enum) {
    // Literals
    number_literal: f64,
    string_literal: StringId,
    bool_literal: bool,
    null_literal,
    // Placeholder — will be expanded
    identifier: StringId,
    program: []NodeIndex,
};

pub const Ast = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    pub fn addNode(self: *Ast, allocator: std.mem.Allocator, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return idx;
    }

    pub fn getNode(self: *const Ast, idx: NodeIndex) Node {
        return self.nodes.items[idx];
    }

    pub fn deinit(self: *Ast, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }
};
```

```zig
// src/js/kotori/parser.zig
const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Ast = @import("ast.zig").Ast;
const NodeIndex = @import("ast.zig").NodeIndex;
const StringPool = @import("string_pool.zig").StringPool;

pub const Parser = struct {
    lexer: Lexer,
    ast: Ast = .{},
    pool: StringPool = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .lexer = Lexer.init(source),
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !NodeIndex {
        _ = self;
        // TODO: implement
        return 0;
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit(self.allocator);
        self.pool.deinit(self.allocator);
    }
};
```

- [ ] **Step 4: Create test files**

```zig
// tests/test_kotori.zig
comptime {
    _ = @import("test_kotori_lexer.zig");
    _ = @import("test_kotori_parser.zig");
}
```

```zig
// tests/test_kotori_lexer.zig
const std = @import("std");
const Lexer = @import("kotori").Lexer;
const TokenType = @import("kotori").TokenType;

fn expectTokens(source: []const u8, expected: []const TokenType) !void {
    var lexer = Lexer.init(source);
    for (expected) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.type);
    }
    const eof = lexer.next();
    try std.testing.expectEqual(TokenType.eof, eof.type);
}

test "empty source" {
    try expectTokens("", &.{});
}
```

```zig
// tests/test_kotori_parser.zig
const std = @import("std");

test "parser placeholder" {
    // TODO: add tests as parser is implemented
    try std.testing.expect(true);
}
```

- [ ] **Step 5: Add test-kotori target to build.zig**

Add after the existing test targets (around line 470):

```zig
// kotori JS engine tests
{
    const kotori_mod = b.createModule(.{
        .root_source_file = b.path("src/js/kotori/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kotori_test = b.addTest(.{
        .root_source_file = b.path("tests/test_kotori.zig"),
        .target = target,
        .optimize = optimize,
    });
    kotori_test.root_module.addImport("kotori", kotori_mod);

    const run_kotori_tests = b.addRunArtifact(kotori_test);
    const test_kotori_step = b.step("test-kotori", "Run kotori JS engine tests");
    test_kotori_step.dependOn(&run_kotori_tests.step);
}
```

- [ ] **Step 6: Build and run tests**

Run: `zig build test-kotori`
Expected: PASS (1 test: "empty source" + placeholder)

- [ ] **Step 7: Commit**

```
feat(kotori): scaffold project with token types, stubs, and test infra
```

---

### Task 2: Lexer — whitespace, comments, punctuators

**Files:**
- Modify: `src/js/kotori/lexer.zig`
- Modify: `tests/test_kotori_lexer.zig`

- [ ] **Step 1: Write failing tests for whitespace and comments**

```zig
test "whitespace is skipped" {
    try expectTokens("   \t\n  ", &.{});
}

test "single-line comment" {
    try expectTokens("// comment\n42", &.{.number});
}

test "multi-line comment" {
    try expectTokens("/* comment */42", &.{.number});
}

test "punctuators" {
    try expectTokens("(){};,", &.{ .lparen, .rparen, .lbrace, .rbrace, .semicolon, .comma });
}

test "multi-char punctuators" {
    try expectTokens("=== !== => ...", &.{ .eq_eq_eq, .ne_eq, .arrow, .ellipsis });
}

test "assignment operators" {
    try expectTokens("+= -= *= &&=", &.{ .plus_assign, .minus_assign, .star_assign, .amp_amp_assign });
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test-kotori`
Expected: FAIL

- [ ] **Step 3: Implement lexer core — skipWhitespace, readPunctuator**

Replace `lexer.zig` with full implementation of:
- `skipWhitespaceAndComments()`: skip spaces, tabs, newlines, `//` and `/* */` comments. Track line numbers.
- `next()`: dispatch to readNumber, readString, readIdentifier, or readPunctuator based on first character.
- Punctuator matching: longest match first (e.g. `===` before `==` before `=`).

Key implementation pattern for `next()`:
```zig
pub fn next(self: *Lexer) Token {
    self.skipWhitespaceAndComments();
    if (self.pos >= self.source.len) return self.makeToken(.eof, 0);

    const c = self.source[self.pos];
    return switch (c) {
        '(' => self.single(.lparen),
        ')' => self.single(.rparen),
        '{' => self.single(.lbrace),
        '}' => self.single(.rbrace),
        '[' => self.single(.lbracket),
        ']' => self.single(.rbracket),
        ';' => self.single(.semicolon),
        ',' => self.single(.comma),
        '~' => self.single(.tilde),
        '?' => self.readQuestion(),    // ? ?. ?? ??=
        '.' => self.readDot(),         // . ... .5 (number)
        '+' => self.readPlus(),        // + ++ +=
        '-' => self.readMinus(),       // - -- -= =>
        '*' => self.readStar(),        // * ** *= **=
        '/' => self.readSlash(),       // / /= (regex handled separately)
        '%' => self.readPercent(),     // % %=
        '=' => self.readEquals(),      // = == === =>
        '!' => self.readBang(),        // ! != !==
        '<' => self.readLt(),          // < <= << <<=
        '>' => self.readGt(),          // > >= >> >>> >>= >>>=
        '&' => self.readAmp(),         // & && &= &&=
        '|' => self.readPipe(),        // | || |= ||=
        '^' => self.readCaret(),       // ^ ^=
        ':' => self.single(.colon),
        '0'...'9' => self.readNumber(),
        '"', '\'' => self.readString(),
        '`' => self.readTemplate(),
        'a'...'z', 'A'...'Z', '_', '$' => self.readIdentifier(),
        else => self.single(.eof), // unknown char, skip
    };
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(kotori): lexer whitespace, comments, and punctuators
```

---

### Task 3: Lexer — numbers, strings, identifiers

**Files:**
- Modify: `src/js/kotori/lexer.zig`
- Modify: `tests/test_kotori_lexer.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "integer literals" {
    try expectTokens("0 42 100", &.{ .number, .number, .number });
}

test "float literals" {
    try expectTokens("3.14 .5 1e10 2.5e-3", &.{ .number, .number, .number, .number });
}

test "hex, octal, binary" {
    try expectTokens("0xFF 0o77 0b1010", &.{ .number, .number, .number });
}

test "string literals" {
    try expectTokens("\"hello\" 'world'", &.{ .string, .string });
}

test "string with escapes" {
    try expectTokens("\"he\\\"llo\" '\\n\\t'", &.{ .string, .string });
}

test "identifiers" {
    try expectTokens("foo bar _private $dollar", &.{ .identifier, .identifier, .identifier, .identifier });
}

test "keywords" {
    try expectTokens("var x = function", &.{ .kw_var, .identifier, .assign, .kw_function });
}

test "mixed expression" {
    try expectTokens("var x = 42 + y;", &.{
        .kw_var, .identifier, .assign, .number, .plus, .identifier, .semicolon,
    });
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test-kotori`
Expected: FAIL

- [ ] **Step 3: Implement readNumber, readString, readIdentifier**

`readNumber()`: handle integer, float, hex (0x), octal (0o), binary (0b), exponent (e/E).
`readString()`: handle `"` and `'` delimiters, escape sequences (`\\`, `\"`, `\n`, `\t`, `\r`, `\0`, `\uXXXX`).
`readIdentifier()`: read `[a-zA-Z_$][a-zA-Z0-9_$]*`, then lookup keyword table.

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(kotori): lexer numbers, strings, identifiers, and keywords
```

---

### Task 4: Lexer — template literals and regex stubs

**Files:**
- Modify: `src/js/kotori/lexer.zig`
- Modify: `tests/test_kotori_lexer.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "simple template literal" {
    try expectTokens("`hello`", &.{.template});
}

test "template with expression" {
    try expectTokens("`a${x}b`", &.{ .template_head, .identifier, .template_tail });
}

test "template with multiple expressions" {
    try expectTokens("`a${x}b${y}c`", &.{ .template_head, .identifier, .template_middle, .identifier, .template_tail });
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Implement readTemplate**

Template literals: scan for `` ` ``, handle `${` (emit template_head/middle), `}` resumes template scanning (emit template_middle/tail). Track template nesting depth for nested templates.

RegExp: defer full implementation. For now, `/` is always `slash` or `slash_assign`. Regex tokenization requires parser context (whether `/` starts a regex or is division), handled later in parser.

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(kotori): lexer template literals
```

---

### Task 5: Lexer — real-world JS stress test

**Files:**
- Modify: `tests/test_kotori_lexer.zig`

- [ ] **Step 1: Write stress test with real JS patterns**

```zig
test "jQuery-like pattern" {
    const source =
        \\(function(global, factory) {
        \\  "use strict";
        \\  if (typeof module === "object" && typeof module.exports === "object") {
        \\    module.exports = factory(global, true);
        \\  } else {
        \\    factory(global);
        \\  }
        \\})(typeof window !== "undefined" ? window : this, function(window, noGlobal) {
        \\  var arr = [];
        \\  var document = window.document;
        \\  var getProto = Object.getPrototypeOf;
        \\  var slice = arr.slice;
        \\  return {};
        \\});
    ;
    // Just verify it lexes without error and produces tokens
    var lexer = Lexer.init(source);
    var count: usize = 0;
    while (true) {
        const tok = lexer.next();
        if (tok.type == .eof) break;
        count += 1;
    }
    try std.testing.expect(count > 50);
}

test "arrow function and destructuring" {
    try expectTokens("const {a, b} = obj;", &.{
        .kw_const, .lbrace, .identifier, .comma, .identifier, .rbrace, .assign, .identifier, .semicolon,
    });
}

test "optional chaining and nullish" {
    try expectTokens("a?.b ?? c", &.{ .identifier, .optional_chain, .identifier, .nullish, .identifier });
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 3: Commit**

```
test(kotori): lexer stress tests with real-world JS patterns
```

---

### Task 6: AST node definitions (full ES5+)

**Files:**
- Modify: `src/js/kotori/ast.zig`

- [ ] **Step 1: Define complete AST node types**

Replace the placeholder AST with full node definitions covering ES5 + key ES6:

```zig
// src/js/kotori/ast.zig
const std = @import("std");
const StringId = @import("string_pool.zig").StringId;

pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

/// Compact node list reference (start index + length into a side array)
pub const NodeList = struct {
    start: u32,
    len: u32,
};

pub const Node = union(enum) {
    // ── Program ──
    program: NodeList,             // top-level statements

    // ── Literals ──
    number_literal: f64,
    string_literal: StringId,
    bool_literal: bool,
    null_literal,
    array_literal: NodeList,       // element expressions (null_node = elision)
    object_literal: NodeList,      // list of property nodes
    property: Property,            // key: value in object literal
    template_literal: NodeList,    // alternating: string_literal, expression, ...
    regex_literal: struct { pattern: StringId, flags: StringId },

    // ── Expressions ──
    identifier: StringId,
    this,
    assignment: Binary,            // lhs = rhs (also +=, -=, etc.)
    binary: Binary,                // lhs op rhs
    unary: Unary,                  // op expr (prefix)
    postfix: Unary,                // expr op (postfix ++ --)
    conditional: Conditional,      // test ? consequent : alternate
    call: Call,                    // callee(args)
    new_expr: Call,                // new callee(args)
    member: Member,                // obj.prop
    computed_member: Binary,       // obj[expr]
    sequence: NodeList,            // expr, expr, expr
    spread: NodeIndex,             // ...expr
    arrow_function: Function,
    yield_expr: struct { argument: NodeIndex, delegate: bool },
    await_expr: NodeIndex,

    // ── Statements ──
    block: NodeList,
    empty_statement,
    expression_stmt: NodeIndex,    // expr;
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    do_while_stmt: WhileStmt,
    for_stmt: ForStmt,
    for_in_stmt: ForInOf,
    for_of_stmt: ForInOf,
    switch_stmt: Switch,
    return_stmt: NodeIndex,        // null_node = bare return
    throw_stmt: NodeIndex,
    try_stmt: TryStmt,
    break_stmt: ?StringId,         // optional label
    continue_stmt: ?StringId,
    labeled_stmt: Labeled,
    with_stmt: Binary,             // object, body
    debugger_stmt,

    // ── Declarations ──
    var_decl: VarDecl,
    function_decl: Function,
    class_decl: Class,

    // ── Patterns (destructuring) ──
    array_pattern: NodeList,
    object_pattern: NodeList,
    assign_pattern: Binary,        // pattern = default

    // ── Support types ──
    switch_case: struct { test: NodeIndex, body: NodeList }, // test = null_node → default
    catch_clause: struct { param: NodeIndex, body: NodeIndex },
};

pub const Binary = struct { lhs: NodeIndex, rhs: NodeIndex, op: u8 = 0 };
pub const Unary = struct { operand: NodeIndex, op: u8 };
pub const Conditional = struct { test: NodeIndex, consequent: NodeIndex, alternate: NodeIndex };
pub const Call = struct { callee: NodeIndex, args: NodeList };
pub const Member = struct { object: NodeIndex, property: StringId };
pub const IfStmt = struct { test: NodeIndex, consequent: NodeIndex, alternate: NodeIndex };
pub const WhileStmt = struct { test: NodeIndex, body: NodeIndex };
pub const ForStmt = struct { init: NodeIndex, test: NodeIndex, update: NodeIndex, body: NodeIndex };
pub const ForInOf = struct { left: NodeIndex, right: NodeIndex, body: NodeIndex };
pub const Switch = struct { discriminant: NodeIndex, cases: NodeList };
pub const TryStmt = struct { block: NodeIndex, handler: NodeIndex, finalizer: NodeIndex };
pub const Labeled = struct { label: StringId, body: NodeIndex };
pub const VarDecl = struct { kind: enum { var_, let, const_ }, declarators: NodeList };
pub const Property = struct { key: NodeIndex, value: NodeIndex, kind: enum { init, get, set }, computed: bool, shorthand: bool };

pub const Function = struct {
    name: ?StringId,
    params: NodeList,
    body: NodeIndex,        // block node
    is_async: bool = false,
    is_generator: bool = false,
    is_expression: bool = false,
};

pub const Class = struct {
    name: ?StringId,
    super_class: NodeIndex,
    body: NodeList,         // list of method definitions
};

// ── AST Container ──

pub const Ast = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    extra: std.ArrayListUnmanaged(NodeIndex) = .empty, // side array for NodeList data

    pub fn addNode(self: *Ast, allocator: std.mem.Allocator, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return idx;
    }

    pub fn addNodeList(self: *Ast, allocator: std.mem.Allocator, items: []const NodeIndex) !NodeList {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, items);
        return .{ .start = start, .len = @intCast(items.len) };
    }

    pub fn getNodeList(self: *const Ast, list: NodeList) []const NodeIndex {
        return self.extra.items[list.start..][0..list.len];
    }

    pub fn getNode(self: *const Ast, idx: NodeIndex) Node {
        return self.nodes.items[idx];
    }

    pub fn deinit(self: *Ast, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.extra.deinit(allocator);
    }
};
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build test-kotori`
Expected: PASS (no new test failures from type changes)

- [ ] **Step 3: Commit**

```
feat(kotori): complete AST node definitions for ES5+
```

---

### Task 7: Parser — expressions (Pratt parsing)

**Files:**
- Modify: `src/js/kotori/parser.zig`
- Modify: `tests/test_kotori_parser.zig`

- [ ] **Step 1: Write failing tests for expression parsing**

```zig
const std = @import("std");
const Parser = @import("kotori").Parser;
const Ast = @import("kotori").Ast;
const Node = @import("kotori").Node;

fn parseExpr(source: []const u8) !struct { ast: Ast, root: Node } {
    var parser = Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    const idx = try parser.parseExpression();
    return .{ .ast = parser.ast, .root = parser.ast.getNode(idx) };
}

test "number literal" {
    const r = try parseExpr("42");
    try std.testing.expectEqual(@as(f64, 42.0), r.root.number_literal);
}

test "string literal" {
    _ = try parseExpr("\"hello\"");
}

test "binary add" {
    const r = try parseExpr("1 + 2");
    try std.testing.expect(r.root == .binary);
}

test "operator precedence: mul before add" {
    // 1 + 2 * 3 → add(1, mul(2, 3))
    const r = try parseExpr("1 + 2 * 3");
    try std.testing.expect(r.root == .binary);
    const rhs_node = r.ast.getNode(r.root.binary.rhs);
    try std.testing.expect(rhs_node == .binary); // 2 * 3
}

test "parenthesized expression" {
    const r = try parseExpr("(1 + 2) * 3");
    try std.testing.expect(r.root == .binary);
    const lhs_node = r.ast.getNode(r.root.binary.lhs);
    try std.testing.expect(lhs_node == .binary); // 1 + 2
}

test "member access" {
    const r = try parseExpr("a.b.c");
    try std.testing.expect(r.root == .member);
}

test "call expression" {
    const r = try parseExpr("foo(1, 2)");
    try std.testing.expect(r.root == .call);
}

test "unary not" {
    const r = try parseExpr("!true");
    try std.testing.expect(r.root == .unary);
}

test "conditional (ternary)" {
    const r = try parseExpr("a ? b : c");
    try std.testing.expect(r.root == .conditional);
}

test "assignment" {
    const r = try parseExpr("x = 42");
    try std.testing.expect(r.root == .assignment);
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Implement Pratt expression parser**

Implement `parseExpression()` using Pratt parsing (top-down operator precedence):

Key functions:
- `parseExpression()` → `parsePrecedence(.assignment)`
- `parsePrecedence(min_prec)` → parse prefix, then loop infix while `prec >= min_prec`
- Prefix parsers: number, string, identifier, `(`, `!`, `-`, `typeof`, `new`, `function`, `[`, `{`
- Infix parsers: `+`, `-`, `*`, `/`, `.`, `[`, `(`, `?`, `=`, `==`, `<`, `&&`, `||`, etc.
- Precedence table: comma(1) < assignment(2) < ternary(3) < nullish(4) < or(5) < and(6) < bitor(7) < bitxor(8) < bitand(9) < equality(10) < comparison(11) < shift(12) < add(13) < mul(14) < power(15) < unary(16) < postfix(17) < call(18) < member(19)

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(kotori): Pratt expression parser with precedence climbing
```

---

### Task 8: Parser — statements and declarations

**Files:**
- Modify: `src/js/kotori/parser.zig`
- Modify: `tests/test_kotori_parser.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "var declaration" {
    var parser = Parser.init(std.testing.allocator, "var x = 42;");
    defer parser.deinit();
    const idx = try parser.parse();
    const node = parser.ast.getNode(idx);
    try std.testing.expect(node == .program);
}

test "if/else" {
    var parser = Parser.init(std.testing.allocator, "if (x) { y; } else { z; }");
    defer parser.deinit();
    _ = try parser.parse();
}

test "while loop" {
    var parser = Parser.init(std.testing.allocator, "while (true) { break; }");
    defer parser.deinit();
    _ = try parser.parse();
}

test "for loop" {
    var parser = Parser.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { x; }");
    defer parser.deinit();
    _ = try parser.parse();
}

test "function declaration" {
    var parser = Parser.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer parser.deinit();
    _ = try parser.parse();
}

test "try/catch/finally" {
    var parser = Parser.init(std.testing.allocator, "try { x; } catch (e) { y; } finally { z; }");
    defer parser.deinit();
    _ = try parser.parse();
}

test "switch" {
    var parser = Parser.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1: a; break;
        \\  case 2: b; break;
        \\  default: c;
        \\}
    );
    defer parser.deinit();
    _ = try parser.parse();
}

test "let/const" {
    var parser = Parser.init(std.testing.allocator, "let x = 1; const y = 2;");
    defer parser.deinit();
    _ = try parser.parse();
}

test "arrow function" {
    var parser = Parser.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer parser.deinit();
    _ = try parser.parse();
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Implement statement parsing**

Add to parser.zig:
- `parse()` → parse program (list of statements until EOF)
- `parseStatement()` → dispatch by keyword/token
- `parseVarDecl()` → var/let/const
- `parseIfStatement()` → if/else
- `parseWhileStatement()` / `parseDoWhileStatement()`
- `parseForStatement()` → for, for-in, for-of
- `parseSwitchStatement()`
- `parseTryStatement()`
- `parseFunctionDecl()` → function name(params) { body }
- `parseBlock()` → { statements }
- `parseReturnStatement()`, `parseThrowStatement()`
- `parseBreakStatement()`, `parseContinueStatement()`
- Automatic Semicolon Insertion (ASI): insert semicolon before `}`, after newline before restricted token, at EOF

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(kotori): statement and declaration parser with ASI
```

---

### Task 9: Parser — real-world JS parsing test

**Files:**
- Modify: `tests/test_kotori_parser.zig`

- [ ] **Step 1: Write integration test with real JS**

```zig
test "parse jQuery-like module pattern" {
    const source =
        \\(function(global, factory) {
        \\  "use strict";
        \\  if (typeof module === "object") {
        \\    module.exports = factory(global, true);
        \\  } else {
        \\    factory(global);
        \\  }
        \\})(typeof window !== "undefined" ? window : this, function(window, noGlobal) {
        \\  var arr = [];
        \\  var document = window.document;
        \\  var getProto = Object.getPrototypeOf;
        \\  var slice = arr.slice;
        \\  var concat = arr.concat;
        \\  var push = arr.push;
        \\  var indexOf = arr.indexOf;
        \\  var class2type = {};
        \\  var toString = class2type.toString;
        \\  var hasOwn = class2type.hasOwnProperty;
        \\  var support = {};
        \\  function isFunction(obj) {
        \\    return typeof obj === "function" && typeof obj.nodeType !== "number";
        \\  }
        \\  function isWindow(obj) {
        \\    return obj !== null && obj === obj.window;
        \\  }
        \\  return {};
        \\});
    ;
    var parser = Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    const idx = try parser.parse();
    const node = parser.ast.getNode(idx);
    try std.testing.expect(node == .program);
}

test "parse class syntax" {
    const source =
        \\class Animal {
        \\  constructor(name) {
        \\    this.name = name;
        \\  }
        \\  speak() {
        \\    return this.name + " makes a noise.";
        \\  }
        \\}
        \\class Dog extends Animal {
        \\  speak() {
        \\    return this.name + " barks.";
        \\  }
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
}
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `zig build test-kotori`
Expected: PASS

- [ ] **Step 3: Commit**

```
test(kotori): real-world JS parsing integration tests
```

---

## Summary

After completing all 9 tasks:
- **Lexer**: tokenizes all ECMAScript tokens (numbers, strings, identifiers, keywords, punctuators, templates)
- **Parser**: recursive descent + Pratt parsing for expressions, full statement/declaration support
- **AST**: complete node types for ES5 + key ES6 (arrow, class, let/const, template, destructuring)
- **StringPool**: interned identifiers for fast lookup
- **Tests**: unit tests + real-world JS parsing stress tests
- **Build**: `zig build test-kotori` target

Next plan: Phase 1b (Compiler + VM basics — AST → Bytecode → execution of `1+1`)
