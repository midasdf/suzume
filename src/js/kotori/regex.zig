//! kotori Layer 0C — ECMA-262 §22.2 Regular Expressions
//!
//! Two-pass backtracking NFA engine:
//!   1. Parser  — pattern source -> AST (`Node` union)
//!   2. Compiler — AST -> flat program (`[]Op`)
//!   3. VM      — execute program via explicit backtrack stack
//!
//! Design: docs/superpowers/specs/2026-04-19-kotori-0C-regex-upgrade-design.md
//!
//! Public surface used by `vm.zig`:
//!   - `Flags` — flag bitfield
//!   - `LegacyResult` — shape compatible with the old `VM.RegexResult`
//!   - `searchLegacy(pattern, input, flags) -> ?LegacyResult`
//!
//! Layered API (used by future call paths that want to cache compiled regex):
//!   - `compile(alloc, pattern, flags) -> Compiled`
//!   - `exec(c, input, start) -> ?Result`
//!   - `search(c, input) -> ?Result`

const std = @import("std");
const testing = std.testing;

// ═══════════════════════════════════════════════════════════════════════
// Public types
// ═══════════════════════════════════════════════════════════════════════

pub const Flags = packed struct(u8) {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    sticky: bool = false,
    has_indices: bool = false,
    _pad: u1 = 0,
};

pub const MatchSlot = struct {
    start: u32,
    end: u32,
};

pub const NamedGroup = struct {
    name: []const u8,
    index: u16,
};

/// Capture slot count shared with legacy callers. First entry is the whole
/// match (slot 0); remaining slots are capture groups 1..N. ECMA-262 permits
/// unlimited groups; kotori's binding layer currently exposes up to 15
/// numbered captures plus slot 0 == whole-match, matching the old engine.
pub const MAX_CAPTURES: usize = 16;

/// Result returned from the high-level `exec` / `search` API.
pub const Result = struct {
    /// Match bounds in input bytes.
    start: u32,
    end: u32,
    /// Captures[0] == whole match, Captures[i] == group i or null.
    /// Owned by `arena` below; caller must not retain across arena.deinit().
    captures: []?MatchSlot,
    /// Named-group side table, borrowed from `Compiled`.
    named: []const NamedGroup,
};

/// Legacy result shape — mirrors old `VM.RegexResult` so existing vm.zig
/// call sites compile unchanged.
pub const LegacyMatch = struct { start: usize, end: usize };
pub const LegacyResult = struct {
    start: usize,
    end: usize,
    captures: [MAX_CAPTURES]?LegacyMatch = [_]?LegacyMatch{null} ** MAX_CAPTURES,
    /// Names for capture groups. NOT owned — borrowed from the scratch
    /// `Compiled` built inside `searchLegacy`. Caller copies into its own
    /// result object before the transient Compiled is freed.
    named_groups: []const LegacyNamed = &.{},
};
pub const LegacyNamed = struct { name: []const u8, index: u16 };

pub const CompileError = error{
    InvalidPattern,
    UnterminatedGroup,
    UnterminatedCharClass,
    InvalidQuantifier,
    InvalidEscape,
    InvalidGroupName,
    DuplicateGroupName,
    BackrefOutOfRange,
    OutOfMemory,
};

// ═══════════════════════════════════════════════════════════════════════
// Opcode definition
// ═══════════════════════════════════════════════════════════════════════

const OpKind = enum(u8) {
    char,
    any,
    char_class,
    boundary,
    anchor,
    save,
    split,
    split_lazy,
    jump,
    assert_ahead,
    assert_ahead_neg,
    assert_behind,
    assert_behind_neg,
    back_ref,
    match_end,
    fail,
};

const AnchorKind = enum(u8) { line_start, line_end };

const Op = struct {
    kind: OpKind,
    // Operand payloads (not all fields used by every opcode):
    a: u32 = 0, // codepoint | class_index | slot | alt/target | group_index | assert body
    b: u32 = 0, // assert end ip
    c: u32 = 0, // reserved
    flag: bool = false, // boundary negate / anchor-multiline / assert_behind fixed-len
};

/// Character class — a list of code-point ranges plus class-escape flags.
const ClassEntry = struct {
    ranges: []const [2]u21,
    negate: bool,
    /// Additional class-escape predicates baked in (union'd with ranges).
    escapes: ClassEscapes,
};

const ClassEscapes = packed struct(u8) {
    digit: bool = false,
    non_digit: bool = false,
    word: bool = false,
    non_word: bool = false,
    space: bool = false,
    non_space: bool = false,
    _pad: u2 = 0,

    pub fn empty() ClassEscapes {
        return .{};
    }
};

const MutableClass = struct {
    ranges: std.ArrayListUnmanaged([2]u21) = .empty,
    negate: bool = false,
    escapes: ClassEscapes = .{},
};

/// Compiled regex — outcome of `compile()`.
pub const Compiled = struct {
    program: []Op,
    classes: []ClassEntry,
    group_count: u16,
    named: []NamedGroup,
    flags: Flags,
    allocator: std.mem.Allocator,
    /// Arena that owns all the range/name slices so freeing is a single call.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
        // program / classes / named are arena-allocated; nothing else to free.
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Parser — pattern source -> AST
// ═══════════════════════════════════════════════════════════════════════

const Node = struct {
    kind: NodeKind,
    // Children (for composites). Slice into `ast_pool`.
    children: []Node = &.{},
    // Leaf payload (varies by kind):
    codepoint: u21 = 0,
    range_lo: u21 = 0,
    range_hi: u21 = 0,
    // Quantifier:
    min: u32 = 0,
    max: u32 = 0,
    lazy: bool = false,
    // Groups:
    group_index: u16 = 0,
    group_name: []const u8 = &.{},
    // Char class:
    class: MutableClass = .{},
    // Back-refs:
    backref: u16 = 0,
    backref_name: []const u8 = &.{},
    // Assertions:
    negate: bool = false,
    anchor: AnchorKind = .line_start,
    // Class-escape inside class/alone:
    class_escape: ClassEscapes = .{},
    // Built-in class from \p{...}:
    prop_index: u8 = 0, // index into PROP_TABLES
    prop_negate: bool = false,
};

const NodeKind = enum {
    // atoms
    lit_char,
    any,
    char_class,
    boundary,
    anchor,
    back_ref,
    back_ref_name,
    prop_escape, // \p{...}
    class_escape, // \d, \s, \w (alone, not in class)
    empty,
    // composites
    concat,
    alternation,
    repeat,
    group,
    non_cap_group,
    named_group,
    lookahead,
    lookbehind,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    flags: Flags,
    arena: std.mem.Allocator,
    group_counter: u16 = 0,
    named: std.ArrayListUnmanaged(NamedGroup) = .empty,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn peekAt(self: *Parser, off: usize) ?u8 {
        if (self.pos + off >= self.src.len) return null;
        return self.src[self.pos + off];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn parseDisjunction(self: *Parser) CompileError!Node {
        const first = try self.parseAlternative();
        if (self.peek() != '|') return first;

        var list: std.ArrayListUnmanaged(Node) = .empty;
        try list.append(self.arena, first);
        while (self.peek() == '|') {
            _ = self.advance();
            const nxt = try self.parseAlternative();
            try list.append(self.arena, nxt);
        }
        return Node{
            .kind = .alternation,
            .children = try list.toOwnedSlice(self.arena),
        };
    }

    fn parseAlternative(self: *Parser) CompileError!Node {
        var list: std.ArrayListUnmanaged(Node) = .empty;
        while (true) {
            const p = self.peek() orelse break;
            if (p == '|' or p == ')') break;
            const term = try self.parseTerm();
            try list.append(self.arena, term);
        }
        if (list.items.len == 0) {
            return Node{ .kind = .empty };
        }
        if (list.items.len == 1) return list.items[0];
        return Node{
            .kind = .concat,
            .children = try list.toOwnedSlice(self.arena),
        };
    }

    fn parseTerm(self: *Parser) CompileError!Node {
        // Assertions that don't admit quantifiers: ^, $, \b, \B, lookaround.
        // Everything else: Atom + optional Quantifier.
        const p = self.peek() orelse return error.InvalidPattern;

        switch (p) {
            '^' => {
                _ = self.advance();
                return Node{
                    .kind = .anchor,
                    .anchor = .line_start,
                };
            },
            '$' => {
                _ = self.advance();
                return Node{
                    .kind = .anchor,
                    .anchor = .line_end,
                };
            },
            '\\' => {
                // Could be \b \B (assertions) or an atom escape.
                const next = self.peekAt(1);
                if (next == 'b' or next == 'B') {
                    _ = self.advance();
                    _ = self.advance();
                    return Node{
                        .kind = .boundary,
                        .negate = next.? == 'B',
                    };
                }
                // fall through to atom handling
            },
            else => {},
        }

        const atom = try self.parseAtom();
        // Lookaround admits no quantifier per spec (early error). We just
        // return without trying to read one — caller loop continues.
        switch (atom.kind) {
            .lookahead, .lookbehind => return atom,
            else => {},
        }
        // Optional quantifier.
        if (self.peek()) |q| {
            switch (q) {
                '*', '+', '?', '{' => {
                    if (q == '{') {
                        // Try to parse; if it doesn't look like a quantifier,
                        // treat { as a literal.
                        const save = self.pos;
                        if (try self.tryParseBraceQuant()) |mm| {
                            return self.wrapRepeat(atom, mm.min, mm.max);
                        }
                        self.pos = save;
                    } else {
                        _ = self.advance();
                        const min: u32 = if (q == '+') 1 else 0;
                        const max: u32 = if (q == '?') 1 else std.math.maxInt(u32);
                        return self.wrapRepeat(atom, min, max);
                    }
                },
                else => {},
            }
        }
        return atom;
    }

    fn wrapRepeat(self: *Parser, child: Node, min_: u32, max_: u32) CompileError!Node {
        var lazy = false;
        if (self.peek() == '?') {
            lazy = true;
            _ = self.advance();
        }
        const kids = try self.arena.alloc(Node, 1);
        kids[0] = child;
        return Node{
            .kind = .repeat,
            .children = kids,
            .min = min_,
            .max = max_,
            .lazy = lazy,
        };
    }

    const MinMax = struct { min: u32, max: u32 };

    fn tryParseBraceQuant(self: *Parser) CompileError!?MinMax {
        if (self.peek() != '{') return null;
        _ = self.advance();
        var min_val: u32 = 0;
        var got_digit = false;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            min_val = min_val * 10 + (ch - '0');
            got_digit = true;
            _ = self.advance();
        }
        if (!got_digit) return null;
        if (self.peek() == '}') {
            _ = self.advance();
            return MinMax{ .min = min_val, .max = min_val };
        }
        if (self.peek() != ',') return null;
        _ = self.advance();
        if (self.peek() == '}') {
            _ = self.advance();
            return MinMax{ .min = min_val, .max = std.math.maxInt(u32) };
        }
        var max_val: u32 = 0;
        var got_max = false;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            max_val = max_val * 10 + (ch - '0');
            got_max = true;
            _ = self.advance();
        }
        if (!got_max) return null;
        if (self.peek() != '}') return null;
        _ = self.advance();
        if (max_val < min_val) return error.InvalidQuantifier;
        return MinMax{ .min = min_val, .max = max_val };
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '.' => {
                _ = self.advance();
                return Node{ .kind = .any };
            },
            '(' => return self.parseGroup(),
            '[' => return self.parseCharClass(),
            '\\' => return self.parseAtomEscape(),
            ')' => return error.InvalidPattern,
            '|' => return error.InvalidPattern, // handled in caller
            '*', '+', '?', '{' => return error.InvalidPattern, // nothing to quantify
            else => {
                _ = self.advance();
                return Node{
                    .kind = .lit_char,
                    .codepoint = if (self.flags.unicode) try self.decodeUtf8Continuation(c) else @as(u21, c),
                };
            },
        }
    }

    /// When parser is in Unicode mode and has just advanced past a leading
    /// ASCII byte `lead`, and the following bytes form a UTF-8 continuation,
    /// pull them in and return the resulting code point. When `lead` is
    /// already ASCII (<0x80) return it verbatim.
    fn decodeUtf8Continuation(self: *Parser, lead: u8) CompileError!u21 {
        if (lead < 0x80) return @as(u21, lead);
        const len: usize = utf8LeadLen(lead) orelse return error.InvalidPattern;
        if (len < 2) return @as(u21, lead);
        // We already consumed `lead`; we need to rewind one and let the
        // multi-byte decoder read from there.
        self.pos -= 1;
        if (self.pos + len > self.src.len) return error.InvalidPattern;
        const slice = self.src[self.pos .. self.pos + len];
        const cp = utf8DecodeOne(slice) orelse return error.InvalidPattern;
        self.pos += len;
        return cp;
    }

    fn parseGroup(self: *Parser) CompileError!Node {
        std.debug.assert(self.peek().? == '(');
        _ = self.advance(); // consume '('

        var node_kind: NodeKind = .group;
        var gname: []const u8 = &.{};
        var la_negate = false;
        var lb_negate = false;
        var group_idx: u16 = 0;

        if (self.peek() == '?') {
            _ = self.advance();
            const k = self.peek() orelse return error.InvalidPattern;
            switch (k) {
                ':' => {
                    _ = self.advance();
                    node_kind = .non_cap_group;
                },
                '=' => {
                    _ = self.advance();
                    node_kind = .lookahead;
                },
                '!' => {
                    _ = self.advance();
                    node_kind = .lookahead;
                    la_negate = true;
                },
                '<' => {
                    _ = self.advance();
                    const k2 = self.peek() orelse return error.InvalidPattern;
                    if (k2 == '=') {
                        _ = self.advance();
                        node_kind = .lookbehind;
                    } else if (k2 == '!') {
                        _ = self.advance();
                        node_kind = .lookbehind;
                        lb_negate = true;
                    } else {
                        // Named group: (?<name>...)
                        node_kind = .named_group;
                        const name_start = self.pos;
                        while (self.peek()) |nc| {
                            if (nc == '>') break;
                            if (!isIdentChar(nc)) return error.InvalidGroupName;
                            _ = self.advance();
                        }
                        if (self.peek() != '>') return error.InvalidGroupName;
                        gname = self.src[name_start..self.pos];
                        if (gname.len == 0) return error.InvalidGroupName;
                        _ = self.advance(); // consume '>'
                        self.group_counter += 1;
                        group_idx = self.group_counter;
                        for (self.named.items) |ng| {
                            if (std.mem.eql(u8, ng.name, gname)) return error.DuplicateGroupName;
                        }
                        try self.named.append(self.arena, .{ .name = gname, .index = group_idx });
                    }
                },
                else => return error.InvalidPattern,
            }
        } else {
            // Plain capturing group.
            self.group_counter += 1;
            group_idx = self.group_counter;
        }

        const body = try self.parseDisjunction();
        if (self.peek() != ')') return error.UnterminatedGroup;
        _ = self.advance(); // consume ')'

        const kids = try self.arena.alloc(Node, 1);
        kids[0] = body;

        return switch (node_kind) {
            .non_cap_group => Node{ .kind = .non_cap_group, .children = kids },
            .lookahead => Node{ .kind = .lookahead, .children = kids, .negate = la_negate },
            .lookbehind => Node{ .kind = .lookbehind, .children = kids, .negate = lb_negate },
            .named_group => Node{
                .kind = .named_group,
                .children = kids,
                .group_index = group_idx,
                .group_name = gname,
            },
            else => Node{
                .kind = .group,
                .children = kids,
                .group_index = group_idx,
            },
        };
    }

    fn parseCharClass(self: *Parser) CompileError!Node {
        std.debug.assert(self.peek().? == '[');
        _ = self.advance(); // consume '['

        var klass: MutableClass = .{};
        if (self.peek() == '^') {
            klass.negate = true;
            _ = self.advance();
        }

        while (true) {
            const c = self.peek() orelse return error.UnterminatedCharClass;
            if (c == ']') {
                _ = self.advance();
                return Node{ .kind = .char_class, .class = klass };
            }

            const lo = try self.parseClassAtom(&klass);
            // If we got a class escape (d/s/w/...) that produced a sentinel,
            // parseClassAtom returned a maxInt marker — just continue.
            if (lo == std.math.maxInt(u21)) continue;

            // Range?
            if (self.peek() == '-' and self.peekAt(1) != ']') {
                _ = self.advance(); // consume '-'
                const hi = try self.parseClassAtom(&klass);
                if (hi == std.math.maxInt(u21)) {
                    // e.g. [a-\d] — accept as two separate items per spec's
                    // looseness; lo alone already added.
                    try klass.ranges.append(self.arena, .{ lo, lo });
                    continue;
                }
                if (hi < lo) return error.InvalidPattern;
                try klass.ranges.append(self.arena, .{ lo, hi });
            } else {
                try klass.ranges.append(self.arena, .{ lo, lo });
            }
        }
    }

    /// Returns a single code point for the class atom, or `maxInt(u21)` when
    /// the atom was a class-escape that was applied in-place to `klass`.
    fn parseClassAtom(self: *Parser, klass: *MutableClass) CompileError!u21 {
        const c = self.peek() orelse return error.UnterminatedCharClass;
        if (c == '\\') {
            _ = self.advance();
            const e = self.peek() orelse return error.InvalidEscape;
            switch (e) {
                'd' => {
                    _ = self.advance();
                    klass.escapes.digit = true;
                    return std.math.maxInt(u21);
                },
                'D' => {
                    _ = self.advance();
                    klass.escapes.non_digit = true;
                    return std.math.maxInt(u21);
                },
                's' => {
                    _ = self.advance();
                    klass.escapes.space = true;
                    return std.math.maxInt(u21);
                },
                'S' => {
                    _ = self.advance();
                    klass.escapes.non_space = true;
                    return std.math.maxInt(u21);
                },
                'w' => {
                    _ = self.advance();
                    klass.escapes.word = true;
                    return std.math.maxInt(u21);
                },
                'W' => {
                    _ = self.advance();
                    klass.escapes.non_word = true;
                    return std.math.maxInt(u21);
                },
                'n' => { _ = self.advance(); return '\n'; },
                't' => { _ = self.advance(); return '\t'; },
                'r' => { _ = self.advance(); return '\r'; },
                'f' => { _ = self.advance(); return 0x0C; },
                'v' => { _ = self.advance(); return 0x0B; },
                '0' => { _ = self.advance(); return 0; },
                'b' => { _ = self.advance(); return 0x08; }, // BS inside class
                'x' => {
                    _ = self.advance();
                    return try self.readHexEscape(2);
                },
                'u' => {
                    _ = self.advance();
                    if (self.peek() == '{') {
                        _ = self.advance();
                        const cp = try self.readHexUntilBrace();
                        return cp;
                    }
                    return try self.readHexEscape(4);
                },
                'p', 'P' => {
                    // \p{L} etc. — treat as unicode property range inside class.
                    const neg = (e == 'P');
                    _ = self.advance();
                    if (self.peek() != '{') return error.InvalidEscape;
                    _ = self.advance();
                    const name_start = self.pos;
                    while (self.peek()) |nc| : (_ = self.advance()) {
                        if (nc == '}') break;
                    }
                    if (self.peek() != '}') return error.InvalidEscape;
                    const prop_name = self.src[name_start..self.pos];
                    _ = self.advance(); // '}'
                    const idx = propTableIndex(prop_name) orelse return error.InvalidEscape;
                    const ranges = PROP_TABLES[idx];
                    if (neg) {
                        // Negation inside a positive class: treat as all codepoints
                        // NOT in the property — approximate by adding the gap ranges.
                        try appendComplementRanges(&klass.ranges, self.arena, ranges);
                    } else {
                        for (ranges) |rng| try klass.ranges.append(self.arena, rng);
                    }
                    return std.math.maxInt(u21);
                },
                else => {
                    _ = self.advance();
                    return @as(u21, e); // identity escape
                },
            }
        }
        _ = self.advance();
        if (c < 0x80) return @as(u21, c);
        // Multi-byte UTF-8: rewind and decode
        self.pos -= 1;
        const len = utf8LeadLen(c) orelse return @as(u21, c);
        if (self.pos + len > self.src.len) return @as(u21, c);
        const cp = utf8DecodeOne(self.src[self.pos .. self.pos + len]) orelse return @as(u21, c);
        self.pos += len;
        return cp;
    }

    fn parseAtomEscape(self: *Parser) CompileError!Node {
        std.debug.assert(self.peek().? == '\\');
        _ = self.advance();
        const e = self.peek() orelse return error.InvalidEscape;
        switch (e) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                _ = self.advance();
                var esc = ClassEscapes{};
                switch (e) {
                    'd' => esc.digit = true,
                    'D' => esc.non_digit = true,
                    's' => esc.space = true,
                    'S' => esc.non_space = true,
                    'w' => esc.word = true,
                    'W' => esc.non_word = true,
                    else => unreachable,
                }
                return Node{ .kind = .class_escape, .class_escape = esc };
            },
            'n' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = '\n' }; },
            't' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = '\t' }; },
            'r' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = '\r' }; },
            'f' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = 0x0C }; },
            'v' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = 0x0B }; },
            '0' => { _ = self.advance(); return Node{ .kind = .lit_char, .codepoint = 0 }; },
            'x' => {
                _ = self.advance();
                const cp = try self.readHexEscape(2);
                return Node{ .kind = .lit_char, .codepoint = cp };
            },
            'u' => {
                _ = self.advance();
                if (self.peek() == '{') {
                    _ = self.advance();
                    const cp = try self.readHexUntilBrace();
                    return Node{ .kind = .lit_char, .codepoint = cp };
                }
                const cp = try self.readHexEscape(4);
                return Node{ .kind = .lit_char, .codepoint = cp };
            },
            'k' => {
                _ = self.advance();
                if (self.peek() != '<') {
                    // In non-Unicode mode ECMA-262 B.1.4 allows `\k` as
                    // identity escape. Return literal k.
                    return Node{ .kind = .lit_char, .codepoint = 'k' };
                }
                _ = self.advance();
                const name_start = self.pos;
                while (self.peek()) |nc| {
                    if (nc == '>') break;
                    if (!isIdentChar(nc)) return error.InvalidGroupName;
                    _ = self.advance();
                }
                if (self.peek() != '>') return error.InvalidGroupName;
                const name = self.src[name_start..self.pos];
                _ = self.advance(); // '>'
                return Node{ .kind = .back_ref_name, .backref_name = name };
            },
            'p', 'P' => {
                const neg = (e == 'P');
                _ = self.advance();
                if (self.peek() != '{') return error.InvalidEscape;
                _ = self.advance();
                const name_start = self.pos;
                while (self.peek()) |nc| : (_ = self.advance()) {
                    if (nc == '}') break;
                }
                if (self.peek() != '}') return error.InvalidEscape;
                const prop_name = self.src[name_start..self.pos];
                _ = self.advance();
                const idx = propTableIndex(prop_name) orelse return error.InvalidEscape;
                return Node{ .kind = .prop_escape, .prop_index = @intCast(idx), .prop_negate = neg };
            },
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // Decimal backref — consume digits while group index is valid.
                var v: u32 = 0;
                const save_pos = self.pos;
                while (self.peek()) |dc| {
                    if (dc < '0' or dc > '9') break;
                    v = v * 10 + (dc - '0');
                    _ = self.advance();
                }
                if (v == 0 or v > std.math.maxInt(u16)) return error.BackrefOutOfRange;
                // If the group index doesn't (yet) exist, try to treat as literal.
                // Full spec does a post-parse scan; we approximate: at most we
                // have `group_counter` groups so far. If v <= group_counter OR
                // pattern references a forward group, we still emit a backref
                // and defer validation to compile time.
                _ = save_pos;
                return Node{ .kind = .back_ref, .backref = @intCast(v) };
            },
            else => {
                _ = self.advance();
                return Node{ .kind = .lit_char, .codepoint = @as(u21, e) };
            },
        }
    }

    fn readHexEscape(self: *Parser, n: usize) CompileError!u21 {
        if (self.pos + n > self.src.len) return error.InvalidEscape;
        var cp: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ch = self.src[self.pos + i];
            const d = hexDigit(ch) orelse return error.InvalidEscape;
            cp = cp * 16 + d;
        }
        self.pos += n;
        if (cp > 0x10FFFF) return error.InvalidEscape;
        return @intCast(cp);
    }

    fn readHexUntilBrace(self: *Parser) CompileError!u21 {
        var cp: u32 = 0;
        var n: usize = 0;
        while (self.peek()) |ch| {
            if (ch == '}') break;
            const d = hexDigit(ch) orelse return error.InvalidEscape;
            cp = cp * 16 + d;
            if (cp > 0x10FFFF) return error.InvalidEscape;
            n += 1;
            _ = self.advance();
        }
        if (self.peek() != '}' or n == 0) return error.InvalidEscape;
        _ = self.advance(); // consume '}'
        return @intCast(cp);
    }
};

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$' or c >= 0x80;
}

fn hexDigit(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// UTF-8 helpers
// ═══════════════════════════════════════════════════════════════════════

fn utf8LeadLen(lead: u8) ?usize {
    if (lead < 0x80) return 1;
    if ((lead & 0b1110_0000) == 0b1100_0000) return 2;
    if ((lead & 0b1111_0000) == 0b1110_0000) return 3;
    if ((lead & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}

fn utf8DecodeOne(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const lead = bytes[0];
    if (lead < 0x80) return @as(u21, lead);
    const len = utf8LeadLen(lead) orelse return null;
    if (bytes.len < len) return null;
    var cp: u32 = switch (len) {
        2 => @as(u32, lead & 0x1F),
        3 => @as(u32, lead & 0x0F),
        4 => @as(u32, lead & 0x07),
        else => return null,
    };
    var i: usize = 1;
    while (i < len) : (i += 1) {
        const b = bytes[i];
        if ((b & 0xC0) != 0x80) return null;
        cp = (cp << 6) | @as(u32, b & 0x3F);
    }
    if (cp > 0x10FFFF) return null;
    return @intCast(cp);
}

fn utf8Encode(cp: u21, out: []u8) ?usize {
    if (cp < 0x80) {
        if (out.len < 1) return null;
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (out.len < 2) return null;
        out[0] = @as(u8, @intCast(0xC0 | (cp >> 6)));
        out[1] = @as(u8, @intCast(0x80 | (cp & 0x3F)));
        return 2;
    }
    if (cp < 0x10000) {
        if (out.len < 3) return null;
        out[0] = @as(u8, @intCast(0xE0 | (cp >> 12)));
        out[1] = @as(u8, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        out[2] = @as(u8, @intCast(0x80 | (cp & 0x3F)));
        return 3;
    }
    if (out.len < 4) return null;
    out[0] = @as(u8, @intCast(0xF0 | (cp >> 18)));
    out[1] = @as(u8, @intCast(0x80 | ((cp >> 12) & 0x3F)));
    out[2] = @as(u8, @intCast(0x80 | ((cp >> 6) & 0x3F)));
    out[3] = @as(u8, @intCast(0x80 | (cp & 0x3F)));
    return 4;
}

// ═══════════════════════════════════════════════════════════════════════
// Unicode property tables (minimal subset)
// ═══════════════════════════════════════════════════════════════════════

/// Ranges for \p{L} / \p{Letter} — a pragmatic, curated subset covering
/// Basic Latin, Latin-1, extended Latin, Greek, Cyrillic, Hebrew, Arabic,
/// Hangul, CJK, Hiragana, Katakana. Not a full Unicode 15 table; enough
/// for the dom/nodes testharness fixtures that touch non-ASCII text.
const LETTER_RANGES: []const [2]u21 = &.{
    .{ 'A', 'Z' },
    .{ 'a', 'z' },
    .{ 0x00AA, 0x00AA },
    .{ 0x00B5, 0x00B5 },
    .{ 0x00BA, 0x00BA },
    .{ 0x00C0, 0x00D6 },
    .{ 0x00D8, 0x00F6 },
    .{ 0x00F8, 0x02AF },
    .{ 0x0370, 0x0373 },
    .{ 0x0376, 0x0377 },
    .{ 0x037A, 0x037D },
    .{ 0x037F, 0x037F },
    .{ 0x0386, 0x0386 },
    .{ 0x0388, 0x038A },
    .{ 0x038C, 0x038C },
    .{ 0x038E, 0x03A1 },
    .{ 0x03A3, 0x03FF },
    .{ 0x0400, 0x0481 },
    .{ 0x048A, 0x052F },
    .{ 0x0531, 0x0556 },
    .{ 0x0561, 0x0587 },
    .{ 0x05D0, 0x05EA },
    .{ 0x0620, 0x064A },
    .{ 0x066E, 0x066F },
    .{ 0x0671, 0x06D3 },
    .{ 0x06D5, 0x06D5 },
    .{ 0x06E5, 0x06E6 },
    .{ 0x06EE, 0x06EF },
    .{ 0x06FA, 0x06FC },
    .{ 0x06FF, 0x06FF },
    .{ 0x0710, 0x0710 },
    .{ 0x0712, 0x072F },
    .{ 0x074D, 0x07A5 },
    .{ 0x07B1, 0x07B1 },
    .{ 0x0E00, 0x0E7F },
    .{ 0x0F00, 0x0FFF },
    .{ 0x1100, 0x11FF },
    .{ 0x3040, 0x309F }, // Hiragana
    .{ 0x30A0, 0x30FF }, // Katakana
    .{ 0x3400, 0x4DBF }, // CJK Extension A
    .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
    .{ 0xA000, 0xA48F }, // Yi Syllables
    .{ 0xAC00, 0xD7AF }, // Hangul Syllables
    .{ 0xF900, 0xFAFF }, // CJK Compatibility Ideographs
    .{ 0xFB50, 0xFDFF }, // Arabic Presentation Forms
    .{ 0xFE70, 0xFEFF }, // Arabic Presentation Forms-B
    .{ 0xFF21, 0xFF3A }, // Fullwidth Latin upper
    .{ 0xFF41, 0xFF5A }, // Fullwidth Latin lower
    .{ 0xFF66, 0xFF9D }, // Halfwidth Katakana
};

const DECIMAL_RANGES: []const [2]u21 = &.{
    .{ '0', '9' },
    .{ 0x0660, 0x0669 },
    .{ 0x06F0, 0x06F9 },
    .{ 0x07C0, 0x07C9 },
    .{ 0xFF10, 0xFF19 },
};

const WHITESPACE_RANGES: []const [2]u21 = &.{
    .{ 0x0009, 0x000D },
    .{ 0x0020, 0x0020 },
    .{ 0x00A0, 0x00A0 },
    .{ 0x1680, 0x1680 },
    .{ 0x2000, 0x200A },
    .{ 0x2028, 0x2029 },
    .{ 0x202F, 0x202F },
    .{ 0x205F, 0x205F },
    .{ 0x3000, 0x3000 },
    .{ 0xFEFF, 0xFEFF },
};

const ASCII_RANGES: []const [2]u21 = &.{
    .{ 0x0000, 0x007F },
};

const ANY_RANGES: []const [2]u21 = &.{
    .{ 0x0000, 0x10FFFF },
};

const PROP_TABLES: []const []const [2]u21 = &.{
    LETTER_RANGES,
    DECIMAL_RANGES,
    WHITESPACE_RANGES,
    ASCII_RANGES,
    ANY_RANGES,
};

fn propTableIndex(name: []const u8) ?usize {
    // Accept common aliases.
    if (std.mem.eql(u8, name, "L") or
        std.mem.eql(u8, name, "Letter") or
        std.mem.eql(u8, name, "Alphabetic")) return 0;
    if (std.mem.eql(u8, name, "Nd") or
        std.mem.eql(u8, name, "Decimal_Number") or
        std.mem.eql(u8, name, "digit")) return 1;
    if (std.mem.eql(u8, name, "White_Space") or
        std.mem.eql(u8, name, "space") or
        std.mem.eql(u8, name, "Space")) return 2;
    if (std.mem.eql(u8, name, "ASCII")) return 3;
    if (std.mem.eql(u8, name, "Any")) return 4;
    return null;
}

fn appendComplementRanges(
    list: *std.ArrayListUnmanaged([2]u21),
    alloc: std.mem.Allocator,
    ranges: []const [2]u21,
) CompileError!void {
    // Produce the complement of ranges in [0, 0x10FFFF].
    var cur: u32 = 0;
    for (ranges) |r| {
        if (cur < r[0]) {
            try list.append(alloc, .{ @intCast(cur), @intCast(@as(u32, r[0]) - 1) });
        }
        cur = @as(u32, r[1]) + 1;
    }
    if (cur <= 0x10FFFF) {
        try list.append(alloc, .{ @intCast(cur), 0x10FFFF });
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Compiler — AST -> flat program
// ═══════════════════════════════════════════════════════════════════════

const Compiler = struct {
    alloc: std.mem.Allocator,
    program: std.ArrayListUnmanaged(Op) = .empty,
    classes: std.ArrayListUnmanaged(ClassEntry) = .empty,

    fn emit(self: *Compiler, op: Op) CompileError!u32 {
        const ip: u32 = @intCast(self.program.items.len);
        try self.program.append(self.alloc, op);
        return ip;
    }

    fn patch(self: *Compiler, ip: u32, field: enum { a, b }, target: u32) void {
        switch (field) {
            .a => self.program.items[ip].a = target,
            .b => self.program.items[ip].b = target,
        }
    }

    fn currentIp(self: *Compiler) u32 {
        return @intCast(self.program.items.len);
    }

    fn addClass(self: *Compiler, ce: ClassEntry) CompileError!u16 {
        const idx: u16 = @intCast(self.classes.items.len);
        try self.classes.append(self.alloc, ce);
        return idx;
    }

    fn compileNode(self: *Compiler, node: Node) CompileError!void {
        switch (node.kind) {
            .empty => {},
            .lit_char => {
                _ = try self.emit(.{ .kind = .char, .a = node.codepoint });
            },
            .any => {
                _ = try self.emit(.{ .kind = .any });
            },
            .anchor => {
                _ = try self.emit(.{ .kind = .anchor, .a = @intFromEnum(node.anchor) });
            },
            .boundary => {
                _ = try self.emit(.{ .kind = .boundary, .flag = node.negate });
            },
            .concat => {
                for (node.children) |child| try self.compileNode(child);
            },
            .alternation => {
                // For a|b|c:
                //   SPLIT L1
                //   <a>
                //   JUMP END
                // L1: SPLIT L2
                //   <b>
                //   JUMP END
                // L2: <c>
                // END:
                var jump_ips: std.ArrayListUnmanaged(u32) = .empty;
                defer jump_ips.deinit(self.alloc);
                var i: usize = 0;
                while (i < node.children.len) : (i += 1) {
                    const is_last = i == node.children.len - 1;
                    var split_ip: u32 = 0;
                    if (!is_last) {
                        split_ip = try self.emit(.{ .kind = .split, .a = 0 });
                    }
                    try self.compileNode(node.children[i]);
                    if (!is_last) {
                        const jip = try self.emit(.{ .kind = .jump, .a = 0 });
                        try jump_ips.append(self.alloc, jip);
                        self.patch(split_ip, .a, self.currentIp());
                    }
                }
                const end = self.currentIp();
                for (jump_ips.items) |jip| self.patch(jip, .a, end);
            },
            .repeat => {
                try self.compileRepeat(node);
            },
            .group, .named_group => {
                // SAVE (2*idx), body, SAVE (2*idx + 1)
                const gi = node.group_index;
                _ = try self.emit(.{ .kind = .save, .a = @as(u32, gi) * 2 });
                try self.compileNode(node.children[0]);
                _ = try self.emit(.{ .kind = .save, .a = @as(u32, gi) * 2 + 1 });
            },
            .non_cap_group => {
                try self.compileNode(node.children[0]);
            },
            .char_class => {
                const ce = ClassEntry{
                    .ranges = try self.alloc.dupe([2]u21, node.class.ranges.items),
                    .negate = node.class.negate,
                    .escapes = node.class.escapes,
                };
                const idx = try self.addClass(ce);
                _ = try self.emit(.{ .kind = .char_class, .a = idx });
            },
            .class_escape => {
                // Compile \d / \s / \w as a single-class op.
                const mc = MutableClass{ .escapes = node.class_escape };
                _ = mc;
                const ce = ClassEntry{
                    .ranges = &.{},
                    .negate = false,
                    .escapes = node.class_escape,
                };
                const idx = try self.addClass(ce);
                _ = try self.emit(.{ .kind = .char_class, .a = idx });
            },
            .prop_escape => {
                const ranges = PROP_TABLES[node.prop_index];
                var mut_ranges: std.ArrayListUnmanaged([2]u21) = .empty;
                if (node.prop_negate) {
                    try appendComplementRanges(&mut_ranges, self.alloc, ranges);
                } else {
                    try mut_ranges.appendSlice(self.alloc, ranges);
                }
                const ce = ClassEntry{
                    .ranges = try mut_ranges.toOwnedSlice(self.alloc),
                    .negate = false,
                    .escapes = .{},
                };
                const idx = try self.addClass(ce);
                _ = try self.emit(.{ .kind = .char_class, .a = idx });
            },
            .lookahead => {
                // assert_ahead body_ip end_ip
                const assert_ip = try self.emit(.{
                    .kind = if (node.negate) .assert_ahead_neg else .assert_ahead,
                    .a = 0,
                    .b = 0,
                });
                const body_ip = self.currentIp();
                try self.compileNode(node.children[0]);
                _ = try self.emit(.{ .kind = .match_end });
                const end_ip = self.currentIp();
                self.patch(assert_ip, .a, body_ip);
                self.patch(assert_ip, .b, end_ip);
            },
            .lookbehind => {
                const assert_ip = try self.emit(.{
                    .kind = if (node.negate) .assert_behind_neg else .assert_behind,
                    .a = 0,
                    .b = 0,
                });
                const body_ip = self.currentIp();
                try self.compileNode(node.children[0]);
                _ = try self.emit(.{ .kind = .match_end });
                const end_ip = self.currentIp();
                self.patch(assert_ip, .a, body_ip);
                self.patch(assert_ip, .b, end_ip);
            },
            .back_ref => {
                _ = try self.emit(.{ .kind = .back_ref, .a = node.backref });
            },
            .back_ref_name => {
                // Resolve name -> index — handled by caller after parse.
                // Compiler receives a numeric index directly via rewrite step.
                return error.InvalidPattern;
            },
        }
    }

    fn compileRepeat(self: *Compiler, node: Node) CompileError!void {
        const child = node.children[0];
        const min_ = node.min;
        const max_ = node.max;
        const lazy = node.lazy;

        // Emit `min_` mandatory copies first.
        var i: u32 = 0;
        while (i < min_) : (i += 1) try self.compileNode(child);

        if (max_ == std.math.maxInt(u32)) {
            // Unbounded loop.
            // For greedy:  L1: SPLIT L2 ; <body> ; JUMP L1 ; L2:
            // For lazy:    L1: SPLIT_LAZY L2 ; <body> ; JUMP L1 ; L2:
            const l1 = self.currentIp();
            const split_ip = try self.emit(.{
                .kind = if (lazy) .split_lazy else .split,
                .a = 0,
            });
            try self.compileNode(child);
            _ = try self.emit(.{ .kind = .jump, .a = l1 });
            const l2 = self.currentIp();
            self.patch(split_ip, .a, l2);
        } else {
            // Bounded: emit (max_ - min_) optional copies.
            var remaining = max_ - min_;
            var split_ips: std.ArrayListUnmanaged(u32) = .empty;
            defer split_ips.deinit(self.alloc);
            while (remaining > 0) : (remaining -= 1) {
                const sip = try self.emit(.{
                    .kind = if (lazy) .split_lazy else .split,
                    .a = 0,
                });
                try split_ips.append(self.alloc, sip);
                try self.compileNode(child);
            }
            const end = self.currentIp();
            for (split_ips.items) |sip| self.patch(sip, .a, end);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Compile entry point
// ═══════════════════════════════════════════════════════════════════════

pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Compiled {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var parser = Parser{
        .src = pattern,
        .pos = 0,
        .flags = flags,
        .arena = arena_alloc,
    };
    const root = try parser.parseDisjunction();
    if (parser.pos != pattern.len) return error.InvalidPattern;

    // Resolve named back-refs against the parser's named table.
    try resolveNamedBackrefs(root, parser.named.items);

    var compiler = Compiler{ .alloc = arena_alloc };
    try compiler.compileNode(root);
    _ = try compiler.emit(.{ .kind = .match_end });

    const program = try compiler.program.toOwnedSlice(arena_alloc);
    const classes = try compiler.classes.toOwnedSlice(arena_alloc);
    const named = try arena_alloc.dupe(NamedGroup, parser.named.items);

    return Compiled{
        .program = program,
        .classes = classes,
        .group_count = parser.group_counter,
        .named = named,
        .flags = flags,
        .allocator = alloc,
        .arena = arena,
    };
}

fn resolveNamedBackrefs(root: Node, named: []const NamedGroup) CompileError!void {
    // Walk the AST in-place (children slices are arena-owned & mutable),
    // rewriting `back_ref_name` nodes to numeric `back_ref`.
    try resolveIn(root, named);
}

fn resolveIn(node: Node, named: []const NamedGroup) CompileError!void {
    for (node.children) |*child| {
        if (child.kind == .back_ref_name) {
            var found = false;
            for (named) |ng| {
                if (std.mem.eql(u8, ng.name, child.backref_name)) {
                    child.kind = .back_ref;
                    child.backref = ng.index;
                    found = true;
                    break;
                }
            }
            if (!found) return error.BackrefOutOfRange;
        } else {
            try resolveIn(child.*, named);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Backtracking VM
// ═══════════════════════════════════════════════════════════════════════

const STEP_BUDGET: u64 = 1_000_000;
const MAX_THREADS: usize = 4096;

const Thread = struct {
    ip: u32,
    sp: u32,
    captures: []u32, // 2*group for start, 2*group+1 for end; 0xFFFFFFFF = unset
};

const UNSET: u32 = 0xFFFFFFFF;

fn cloneCaps(alloc: std.mem.Allocator, src: []const u32) ![]u32 {
    return try alloc.dupe(u32, src);
}

/// Execute compiled regex against `input` starting at byte offset `start`.
/// Returns the first match or null.
pub fn exec(c: *const Compiled, input: []const u8, start: usize) ?Result {
    return execInner(c, input, start, null);
}

/// Search — try exec at every position. Returns first match or null.
pub fn search(c: *const Compiled, input: []const u8) ?Result {
    if (c.flags.sticky) return exec(c, input, 0);
    return execInner(c, input, 0, .{ .free_scan = true });
}

const ExecOpts = struct {
    free_scan: bool = false,
};

fn execInner(c: *const Compiled, input: []const u8, start: usize, maybe_opts: ?ExecOpts) ?Result {
    const opts = maybe_opts orelse ExecOpts{};
    var pos: usize = start;
    const max_pos = input.len;

    while (true) {
        if (runFrom(c, input, @intCast(pos))) |result| {
            return result;
        }
        if (!opts.free_scan) return null;
        if (pos >= max_pos) return null;
        // Advance one code unit (byte, or UTF-8 char in unicode mode).
        if (c.flags.unicode) {
            const len = utf8LeadLen(input[pos]) orelse 1;
            pos += len;
        } else {
            pos += 1;
        }
    }
}

fn runFrom(c: *const Compiled, input: []const u8, start: u32) ?Result {
    // Heap-backed per-invocation allocator to simplify cleanup.
    var gpa = std.heap.ArenaAllocator.init(c.allocator);
    defer gpa.deinit();
    const alloc = gpa.allocator();

    const cap_len: usize = (@as(usize, c.group_count) + 1) * 2;
    var captures = alloc.alloc(u32, cap_len) catch return null;
    @memset(captures, UNSET);
    captures[0] = start; // match start

    var stack: std.ArrayListUnmanaged(Thread) = .empty;
    defer stack.deinit(alloc);

    var ip: u32 = 0;
    var sp: u32 = start;
    var steps: u64 = 0;

    const pushBacktrack = struct {
        fn push(
            st: *std.ArrayListUnmanaged(Thread),
            a: std.mem.Allocator,
            t_ip: u32,
            t_sp: u32,
            t_caps: []const u32,
        ) bool {
            if (st.items.len >= MAX_THREADS) return false;
            const cloned = a.dupe(u32, t_caps) catch return false;
            st.append(a, .{ .ip = t_ip, .sp = t_sp, .captures = cloned }) catch return false;
            return true;
        }
    }.push;

    while (true) {
        if (steps >= STEP_BUDGET) return null;
        steps += 1;

        const op = c.program[ip];
        switch (op.kind) {
            .match_end => {
                captures[1] = sp;
                const out_caps = alloc.alloc(?MatchSlot, @as(usize, c.group_count) + 1) catch return null;
                out_caps[0] = .{ .start = captures[0], .end = captures[1] };
                var gi: u16 = 1;
                while (gi <= c.group_count) : (gi += 1) {
                    const s = captures[@as(usize, gi) * 2];
                    const e = captures[@as(usize, gi) * 2 + 1];
                    if (s == UNSET or e == UNSET) {
                        out_caps[gi] = null;
                    } else {
                        out_caps[gi] = .{ .start = s, .end = e };
                    }
                }
                // Allocate persistent result from caller allocator so it
                // survives `gpa.deinit()`. We do a plain alloc + copy.
                const stable = c.allocator.alloc(?MatchSlot, out_caps.len) catch return null;
                @memcpy(stable, out_caps);
                return Result{
                    .start = captures[0],
                    .end = captures[1],
                    .captures = stable,
                    .named = c.named,
                };
            },
            .char => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                const decoded = decodeAt(input, sp, c.flags.unicode);
                const want: u21 = @intCast(op.a);
                const got = decoded.cp;
                if (charEqual(want, got, c.flags.ignore_case)) {
                    sp += @intCast(decoded.len);
                    ip += 1;
                } else {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                }
            },
            .any => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                const decoded = decodeAt(input, sp, c.flags.unicode);
                // Without dotAll, `.` does not match line terminators.
                if (!c.flags.dot_all and isLineTerminator(decoded.cp)) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                sp += @intCast(decoded.len);
                ip += 1;
            },
            .char_class => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                const decoded = decodeAt(input, sp, c.flags.unicode);
                const ce = c.classes[op.a];
                if (classMatches(ce, decoded.cp, c.flags.ignore_case)) {
                    sp += @intCast(decoded.len);
                    ip += 1;
                } else {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                }
            },
            .boundary => {
                const is_b = isWordBoundary(input, sp);
                const want = !op.flag; // flag=true means \B (negate)
                if (is_b == want) {
                    ip += 1;
                } else {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                }
            },
            .anchor => {
                const kind: AnchorKind = @enumFromInt(op.a);
                const ok = switch (kind) {
                    .line_start => sp == 0 or (c.flags.multiline and sp > 0 and isLineTerminator(@as(u21, input[sp - 1]))),
                    .line_end => sp == input.len or (c.flags.multiline and sp < input.len and isLineTerminator(@as(u21, input[sp]))),
                };
                if (ok) {
                    ip += 1;
                } else {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                }
            },
            .save => {
                const slot = op.a;
                if (slot >= captures.len) return null;
                captures[slot] = sp;
                ip += 1;
            },
            .split => {
                // Greedy: prefer fall-through, backtrack is alt.
                if (!pushBacktrack(&stack, alloc, op.a, sp, captures)) return null;
                ip += 1;
            },
            .split_lazy => {
                // Lazy: prefer alt, backtrack is fall-through.
                if (!pushBacktrack(&stack, alloc, ip + 1, sp, captures)) return null;
                ip = op.a;
            },
            .jump => {
                ip = op.a;
            },
            .assert_ahead, .assert_ahead_neg => {
                const neg = (op.kind == .assert_ahead_neg);
                const body_ip = op.a;
                const end_ip = op.b;
                const inner = subExec(c, input, sp, body_ip);
                const matched = inner != null;
                if (matched != !neg) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                // Capture state from successful lookahead persists.
                if (inner) |r| {
                    // Copy captures written by inner program.
                    var gi2: usize = 0;
                    while (gi2 < r.captures.len and gi2 < captures.len) : (gi2 += 1) {
                        if (r.captures[gi2] != UNSET) captures[gi2] = r.captures[gi2];
                    }
                }
                ip = end_ip;
            },
            .assert_behind, .assert_behind_neg => {
                const neg = (op.kind == .assert_behind_neg);
                const body_ip = op.a;
                const end_ip = op.b;
                // Scan backwards over candidate start positions.
                var try_start: u32 = 0;
                var matched = false;
                var match_caps: ?[]u32 = null;
                while (try_start <= sp) : (try_start += 1) {
                    const r = subExecBounded(c, input, try_start, body_ip, sp);
                    if (r) |caps| {
                        matched = true;
                        match_caps = caps;
                        break;
                    }
                }
                if (matched != !neg) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                if (match_caps) |mc| {
                    var gi3: usize = 0;
                    while (gi3 < mc.len and gi3 < captures.len) : (gi3 += 1) {
                        if (mc[gi3] != UNSET) captures[gi3] = mc[gi3];
                    }
                }
                ip = end_ip;
            },
            .back_ref => {
                const g = op.a;
                const s = captures[g * 2];
                const e = captures[g * 2 + 1];
                if (s == UNSET or e == UNSET) {
                    // Matches empty per spec when backref is unset.
                    ip += 1;
                    continue;
                }
                const want = input[s..e];
                if (sp + want.len > input.len) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                const got = input[sp..][0..want.len];
                var ok = true;
                if (c.flags.ignore_case) {
                    var i: usize = 0;
                    while (i < want.len) : (i += 1) {
                        if (toLowerAscii(want[i]) != toLowerAscii(got[i])) {
                            ok = false;
                            break;
                        }
                    }
                } else {
                    ok = std.mem.eql(u8, want, got);
                }
                if (!ok) {
                    if (!backtrack(&stack, &ip, &sp, &captures)) return null;
                    continue;
                }
                sp += @intCast(want.len);
                ip += 1;
            },
            .fail => {
                if (!backtrack(&stack, &ip, &sp, &captures)) return null;
            },
        }
    }
}

fn backtrack(
    stack: *std.ArrayListUnmanaged(Thread),
    ip: *u32,
    sp: *u32,
    captures: *[]u32,
) bool {
    if (stack.items.len == 0) return false;
    const t = stack.pop().?;
    ip.* = t.ip;
    sp.* = t.sp;
    // Overwrite current captures with the saved ones.
    @memcpy(captures.*[0..t.captures.len], t.captures);
    return true;
}

/// Run a sub-program (body_ip onward) with an isolated backtrack stack.
/// Returns captured state (a copy of the full capture array) on success,
/// null on failure. Used by lookahead assertions.
fn subExec(c: *const Compiled, input: []const u8, start: u32, body_ip: u32) ?SubResult {
    var arena = std.heap.ArenaAllocator.init(c.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cap_len: usize = (@as(usize, c.group_count) + 1) * 2;
    var caps = alloc.alloc(u32, cap_len) catch return null;
    @memset(caps, UNSET);

    var stack: std.ArrayListUnmanaged(Thread) = .empty;
    defer stack.deinit(alloc);

    var ip: u32 = body_ip;
    var sp: u32 = start;
    var steps: u64 = 0;

    while (true) {
        if (steps >= STEP_BUDGET) return null;
        steps += 1;

        const op = c.program[ip];
        switch (op.kind) {
            .match_end => {
                const stable = c.allocator.alloc(u32, caps.len) catch return null;
                @memcpy(stable, caps);
                return SubResult{ .captures = stable, .end_sp = sp };
            },
            .char => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                const d = decodeAt(input, sp, c.flags.unicode);
                if (charEqual(@intCast(op.a), d.cp, c.flags.ignore_case)) {
                    sp += @intCast(d.len);
                    ip += 1;
                } else if (!backtrack(&stack, &ip, &sp, &caps)) {
                    return null;
                }
            },
            .any => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                const d = decodeAt(input, sp, c.flags.unicode);
                if (!c.flags.dot_all and isLineTerminator(d.cp)) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                sp += @intCast(d.len);
                ip += 1;
            },
            .char_class => {
                if (sp >= input.len) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                const d = decodeAt(input, sp, c.flags.unicode);
                const ce = c.classes[op.a];
                if (classMatches(ce, d.cp, c.flags.ignore_case)) {
                    sp += @intCast(d.len);
                    ip += 1;
                } else if (!backtrack(&stack, &ip, &sp, &caps)) {
                    return null;
                }
            },
            .boundary => {
                const is_b = isWordBoundary(input, sp);
                const want = !op.flag;
                if (is_b == want) ip += 1 else if (!backtrack(&stack, &ip, &sp, &caps)) return null;
            },
            .anchor => {
                const kind: AnchorKind = @enumFromInt(op.a);
                const ok = switch (kind) {
                    .line_start => sp == 0 or (c.flags.multiline and sp > 0 and isLineTerminator(@as(u21, input[sp - 1]))),
                    .line_end => sp == input.len or (c.flags.multiline and sp < input.len and isLineTerminator(@as(u21, input[sp]))),
                };
                if (ok) ip += 1 else if (!backtrack(&stack, &ip, &sp, &caps)) return null;
            },
            .save => {
                if (op.a >= caps.len) return null;
                caps[op.a] = sp;
                ip += 1;
            },
            .split => {
                if (stack.items.len >= MAX_THREADS) return null;
                const cloned = alloc.dupe(u32, caps) catch return null;
                stack.append(alloc, .{ .ip = op.a, .sp = sp, .captures = cloned }) catch return null;
                ip += 1;
            },
            .split_lazy => {
                if (stack.items.len >= MAX_THREADS) return null;
                const cloned = alloc.dupe(u32, caps) catch return null;
                stack.append(alloc, .{ .ip = ip + 1, .sp = sp, .captures = cloned }) catch return null;
                ip = op.a;
            },
            .jump => ip = op.a,
            .back_ref => {
                const g = op.a;
                const s = caps[g * 2];
                const e = caps[g * 2 + 1];
                if (s == UNSET or e == UNSET) {
                    ip += 1;
                    continue;
                }
                const want = input[s..e];
                if (sp + want.len > input.len) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                const got = input[sp..][0..want.len];
                const ok = if (c.flags.ignore_case)
                    std.ascii.eqlIgnoreCase(want, got)
                else
                    std.mem.eql(u8, want, got);
                if (!ok) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                sp += @intCast(want.len);
                ip += 1;
            },
            .assert_ahead, .assert_ahead_neg => {
                const neg = (op.kind == .assert_ahead_neg);
                const inner = subExec(c, input, sp, op.a);
                const matched = inner != null;
                if (matched != !neg) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                ip = op.b;
            },
            .assert_behind, .assert_behind_neg => {
                const neg = (op.kind == .assert_behind_neg);
                var try_start: u32 = 0;
                var matched = false;
                while (try_start <= sp) : (try_start += 1) {
                    if (subExecBounded(c, input, try_start, op.a, sp)) |_| {
                        matched = true;
                        break;
                    }
                }
                if (matched != !neg) {
                    if (!backtrack(&stack, &ip, &sp, &caps)) return null;
                    continue;
                }
                ip = op.b;
            },
            .fail => {
                if (!backtrack(&stack, &ip, &sp, &caps)) return null;
            },
        }
    }
}

const SubResult = struct {
    captures: []u32,
    end_sp: u32,
};

/// Same as `subExec` but requires the inner match to end at exactly
/// `target_end`. Used by lookbehind. Returns captures on success.
fn subExecBounded(
    c: *const Compiled,
    input: []const u8,
    start: u32,
    body_ip: u32,
    target_end: u32,
) ?[]u32 {
    const r = subExec(c, input, start, body_ip) orelse return null;
    if (r.end_sp != target_end) {
        c.allocator.free(r.captures);
        return null;
    }
    return r.captures;
}

// ═══════════════════════════════════════════════════════════════════════
// Character helpers
// ═══════════════════════════════════════════════════════════════════════

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn toLowerCp(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

fn charEqual(want: u21, got: u21, ignore_case: bool) bool {
    if (want == got) return true;
    if (ignore_case) return toLowerCp(want) == toLowerCp(got);
    return false;
}

fn isLineTerminator(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

fn isWordCp(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        (cp >= '0' and cp <= '9') or
        cp == '_';
}

fn isDigitCp(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn isSpaceCp(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or
        cp == 0x0B or cp == 0x0C or cp == 0xA0 or
        cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or
        cp == 0x2028 or cp == 0x2029 or cp == 0x202F or
        cp == 0x205F or cp == 0x3000 or cp == 0xFEFF;
}

fn isWordBoundary(input: []const u8, sp: u32) bool {
    const left = if (sp > 0) isWordCp(@as(u21, input[sp - 1])) else false;
    const right = if (sp < input.len) isWordCp(@as(u21, input[sp])) else false;
    return left != right;
}

const Decoded = struct { cp: u21, len: usize };

fn decodeAt(input: []const u8, sp: u32, unicode: bool) Decoded {
    if (!unicode or input[sp] < 0x80) {
        return .{ .cp = @as(u21, input[sp]), .len = 1 };
    }
    const len = utf8LeadLen(input[sp]) orelse 1;
    const end = @min(sp + len, input.len);
    const cp = utf8DecodeOne(input[sp..end]) orelse @as(u21, input[sp]);
    return .{ .cp = cp, .len = len };
}

fn classMatches(ce: ClassEntry, cp: u21, ignore_case: bool) bool {
    var hit = false;
    // Escapes first
    if (ce.escapes.digit and isDigitCp(cp)) hit = true;
    if (ce.escapes.non_digit and !isDigitCp(cp)) hit = true;
    if (ce.escapes.word and isWordCp(cp)) hit = true;
    if (ce.escapes.non_word and !isWordCp(cp)) hit = true;
    if (ce.escapes.space and isSpaceCp(cp)) hit = true;
    if (ce.escapes.non_space and !isSpaceCp(cp)) hit = true;
    if (!hit) {
        for (ce.ranges) |r| {
            var lo = r[0];
            var hi = r[1];
            var v = cp;
            if (ignore_case) {
                lo = toLowerCp(lo);
                hi = toLowerCp(hi);
                v = toLowerCp(v);
            }
            if (v >= lo and v <= hi) {
                hit = true;
                break;
            }
        }
    }
    return if (ce.negate) !hit else hit;
}

// ═══════════════════════════════════════════════════════════════════════
// Legacy back-compat shim
// ═══════════════════════════════════════════════════════════════════════

/// Compile + search in one shot. Returns the first match in `str` or null.
/// Ownership: the returned captures array is owned by the caller-provided
/// allocator (`std.heap.page_allocator` internally, sufficient for a single
/// call). The embedded `named_groups` slice points into that same allocation.
///
/// This matches the old `VM.regexSearch` signature closely so vm.zig's nine
/// call sites only need a two-word substitution.
pub fn searchLegacy(pattern: []const u8, str: []const u8, flags: Flags) ?LegacyResult {
    return searchLegacyAlloc(std.heap.page_allocator, pattern, str, flags);
}

pub fn searchLegacyAlloc(
    alloc: std.mem.Allocator,
    pattern: []const u8,
    str: []const u8,
    flags: Flags,
) ?LegacyResult {
    var c = compile(alloc, pattern, flags) catch return null;
    defer c.deinit();
    const r = search(&c, str) orelse return null;
    defer alloc.free(r.captures);

    var out = LegacyResult{
        .start = r.start,
        .end = r.end,
    };
    var i: usize = 1;
    var slot: usize = 0;
    while (i <= c.group_count and slot < MAX_CAPTURES) : (i += 1) {
        if (r.captures[i]) |m| {
            out.captures[slot] = .{ .start = m.start, .end = m.end };
        } else {
            out.captures[slot] = null;
        }
        slot += 1;
    }
    return out;
}

/// Search starting at `start_index`. Used for sticky `y` and `lastIndex`.
pub fn execLegacyAt(
    alloc: std.mem.Allocator,
    pattern: []const u8,
    str: []const u8,
    flags: Flags,
    start_index: usize,
) ?LegacyResult {
    var c = compile(alloc, pattern, flags) catch return null;
    defer c.deinit();
    const r = if (flags.sticky)
        exec(&c, str, start_index)
    else
        execInner(&c, str, start_index, .{ .free_scan = true });
    const match = r orelse return null;
    defer alloc.free(match.captures);

    var out = LegacyResult{
        .start = match.start,
        .end = match.end,
    };
    var i: usize = 1;
    var slot: usize = 0;
    while (i <= c.group_count and slot < MAX_CAPTURES) : (i += 1) {
        if (match.captures[i]) |m| {
            out.captures[slot] = .{ .start = m.start, .end = m.end };
        } else {
            out.captures[slot] = null;
        }
        slot += 1;
    }
    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Unit tests (run via `zig build test-kotori-regex`)
// ═══════════════════════════════════════════════════════════════════════

test "char literal" {
    const r = searchLegacy("abc", "xxabcxx", .{}).?;
    try testing.expectEqual(@as(usize, 2), r.start);
    try testing.expectEqual(@as(usize, 5), r.end);
}

test "char literal not found" {
    try testing.expect(searchLegacy("abc", "xxxxxxx", .{}) == null);
}

test "anchor ^" {
    const r = searchLegacy("^hello", "hello world", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expect(searchLegacy("^world", "hello world", .{}) == null);
}

test "anchor $" {
    const r = searchLegacy("world$", "hello world", .{}).?;
    try testing.expectEqual(@as(usize, 6), r.start);
    try testing.expectEqual(@as(usize, 11), r.end);
}

test "dot matches any except newline" {
    try testing.expect(searchLegacy("a.b", "axb", .{}) != null);
    try testing.expect(searchLegacy("a.b", "a\nb", .{}) == null);
}

test "digit class" {
    const r = searchLegacy("\\d+", "abc123def", .{}).?;
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(@as(usize, 6), r.end);
}

test "word class inside class-char" {
    const r = searchLegacy("[a-z]+", "Hello", .{}).?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 5), r.end);
}

test "negated class" {
    const r = searchLegacy("[^0-9]+", "123abc", .{}).?;
    try testing.expectEqual(@as(usize, 3), r.start);
}

test "alternation" {
    try testing.expect(searchLegacy("cat|dog", "I have a dog", .{}) != null);
    try testing.expect(searchLegacy("cat|dog", "I have a fish", .{}) == null);
}

test "alternation three-way" {
    try testing.expect(searchLegacy("red|green|blue", "color: blue", .{}) != null);
}

test "grouping basic" {
    const r = searchLegacy("(ab)+", "ababab", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 6), r.end);
}

test "capture group" {
    const r = searchLegacy("(\\d+)-(\\d+)", "date 2024-01", .{}).?;
    try testing.expectEqual(@as(usize, 5), r.start);
    try testing.expectEqual(@as(usize, 12), r.end);
    try testing.expect(r.captures[0] != null);
    try testing.expect(r.captures[1] != null);
    try testing.expectEqual(@as(usize, 5), r.captures[0].?.start);
    try testing.expectEqual(@as(usize, 9), r.captures[0].?.end);
    try testing.expectEqual(@as(usize, 10), r.captures[1].?.start);
    try testing.expectEqual(@as(usize, 12), r.captures[1].?.end);
}

test "non-capturing group" {
    const r = searchLegacy("(?:ab)+", "ababab", .{}).?;
    try testing.expectEqual(@as(usize, 6), r.end);
    try testing.expect(r.captures[0] == null);
}

test "quantifier *" {
    try testing.expect(searchLegacy("a*", "bbbaaa", .{}) != null);
}

test "quantifier +" {
    const r = searchLegacy("a+", "bbbaaa", .{}).?;
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(@as(usize, 6), r.end);
}

test "quantifier ?" {
    try testing.expect(searchLegacy("colou?r", "color", .{}) != null);
    try testing.expect(searchLegacy("colou?r", "colour", .{}) != null);
}

test "brace exact" {
    try testing.expect(searchLegacy("\\d{3}", "abc123", .{}) != null);
    try testing.expect(searchLegacy("\\d{4}", "abc123", .{}) == null);
}

test "brace range" {
    const r = searchLegacy("\\d{2,4}", "ab12345", .{}).?;
    try testing.expectEqual(@as(usize, 2), r.start);
    try testing.expectEqual(@as(usize, 6), r.end);
}

test "brace min-only" {
    try testing.expect(searchLegacy("a{2,}", "aaa", .{}) != null);
}

test "lazy quantifier" {
    const r = searchLegacy("a.*?b", "axybxyb", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
}

test "ignore case" {
    try testing.expect(searchLegacy("hello", "HELLO", .{ .ignore_case = true }) != null);
}

test "word boundary" {
    try testing.expect(searchLegacy("\\bworld\\b", "hello world today", .{}) != null);
    try testing.expect(searchLegacy("\\bworld\\b", "helloworld", .{}) == null);
}

test "escaped dot" {
    try testing.expect(searchLegacy("\\d+\\.\\d+", "3.14", .{}) != null);
    try testing.expect(searchLegacy("\\d+\\.\\d+", "314", .{}) == null);
}

test "lookahead positive" {
    const r = searchLegacy("foo(?=bar)", "foobar", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 3), r.end);
}

test "lookahead negative" {
    const r = searchLegacy("foo(?!bar)", "foobaz", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 3), r.end);
    try testing.expect(searchLegacy("foo(?!bar)", "foobar", .{}) == null);
}

test "lookbehind positive" {
    const r = searchLegacy("(?<=foo)bar", "foobar", .{}).?;
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(@as(usize, 6), r.end);
}

test "lookbehind negative" {
    const r = searchLegacy("(?<!foo)bar", "zbar", .{}).?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
}

test "backref numeric" {
    const r = searchLegacy("(a)\\1", "aa", .{}).?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 2), r.end);
}

test "backref failing" {
    try testing.expect(searchLegacy("(a)\\1", "ab", .{}) == null);
}

test "named group match" {
    const r = searchLegacy("(?<yr>\\d+)", "abc123", .{}).?;
    try testing.expectEqual(@as(usize, 3), r.start);
}

test "named backref" {
    try testing.expect(searchLegacy("(?<x>a)\\k<x>", "aa", .{}) != null);
    try testing.expect(searchLegacy("(?<x>a)\\k<x>", "ab", .{}) == null);
}

test "dotAll flag" {
    try testing.expect(searchLegacy("a.b", "a\nb", .{ .dot_all = true }) != null);
    try testing.expect(searchLegacy("a.b", "a\nb", .{}) == null);
}

test "sticky flag fails at pos" {
    // With sticky, the pattern must match at start. "abc" doesn't start with "foo".
    try testing.expect(searchLegacy("foo", "abcfoo", .{ .sticky = true }) == null);
    try testing.expect(searchLegacy("foo", "foobar", .{ .sticky = true }) != null);
}

test "unicode \\u{codepoint} escape" {
    const emoji_bytes = "\xF0\x9F\x98\x80"; // U+1F600
    try testing.expect(searchLegacy("\\u{1F600}", emoji_bytes, .{ .unicode = true }) != null);
}

test "property escape \\p{L}" {
    try testing.expect(searchLegacy("\\p{L}+", "abc", .{ .unicode = true }) != null);
    try testing.expect(searchLegacy("\\p{L}+", "123", .{ .unicode = true }) == null);
}

test "property escape \\p{Nd}" {
    try testing.expect(searchLegacy("\\p{Nd}+", "123", .{ .unicode = true }) != null);
}

test "multiline ^" {
    try testing.expect(searchLegacy("^b", "a\nb", .{ .multiline = true }) != null);
    try testing.expect(searchLegacy("^b", "a\nb", .{}) == null);
}

test "pathological pattern bounded" {
    // Exponential backtracking would hang without step budget.
    try testing.expect(searchLegacy("(a+)+b", "aaaaaaaaaaaaaaaaaaaaaac", .{}) == null);
}
