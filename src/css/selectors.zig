const std = @import("std");
const util = @import("util.zig");
const bloom_mod = @import("bloom.zig");
pub const SelectorBloomFilter = bloom_mod.SelectorBloomFilter;

pub const Combinator = enum {
    descendant, // space
    child, // >
    next_sibling, // +
    subsequent_sibling, // ~
};

pub const AttributeOp = enum {
    exists, // [attr]
    equals, // [attr="val"]
    contains_word, // [attr~="val"]
    starts_with, // [attr^="val"]
    ends_with, // [attr$="val"]
    contains, // [attr*="val"]
    starts_with_dash, // [attr|="val"]
};

pub const AttributeSel = struct {
    name: []const u8,
    op: AttributeOp,
    value: []const u8 = "",
};

pub const PseudoClass = enum {
    hover,
    focus,
    active,
    visited,
    link,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    nth_child,
    nth_last_child,
    nth_of_type,
    nth_last_of_type,
    root,
    empty,
    checked,
    disabled,
    enabled,
    focus_visible,
    focus_within,
    target,
    placeholder_shown,

    const map = std.StaticStringMap(PseudoClass).initComptime(.{
        .{ "hover", .hover },
        .{ "focus", .focus },
        .{ "active", .active },
        .{ "visited", .visited },
        .{ "link", .link },
        .{ "first-child", .first_child },
        .{ "last-child", .last_child },
        .{ "only-child", .only_child },
        .{ "first-of-type", .first_of_type },
        .{ "last-of-type", .last_of_type },
        .{ "only-of-type", .only_of_type },
        .{ "root", .root },
        .{ "empty", .empty },
        .{ "checked", .checked },
        .{ "disabled", .disabled },
        .{ "enabled", .enabled },
        .{ "focus-visible", .focus_visible },
        .{ "focus-within", .focus_within },
        .{ "target", .target },
        .{ "placeholder-shown", .placeholder_shown },
    });

    pub fn fromString(name: []const u8) ?PseudoClass {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return null;
        for (name, 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = buf[0..name.len];
        if (std.mem.eql(u8, lower, "nth-child")) return .nth_child;
        if (std.mem.eql(u8, lower, "nth-last-child")) return .nth_last_child;
        if (std.mem.eql(u8, lower, "nth-of-type")) return .nth_of_type;
        if (std.mem.eql(u8, lower, "nth-last-of-type")) return .nth_last_of_type;
        return map.get(lower);
    }
};

pub const PseudoElement = enum {
    before,
    after,
};

pub const NthParams = struct {
    a: i32 = 0,
    b: i32 = 0,
};

pub const PseudoClassSel = struct {
    pc: PseudoClass,
    nth: ?NthParams = null,
    not_inner: ?[]const u8 = null, // Raw inner selector string for :not()
};

pub const SimpleSelector = union(enum) {
    type_sel: []const u8,
    class: []const u8,
    id: []const u8,
    universal,
    attribute: AttributeSel,
    pseudo_class: PseudoClassSel,
};

pub const SelectorComponent = union(enum) {
    simple: SimpleSelector,
    combinator: Combinator,
};

pub const Specificity = struct {
    a: u16 = 0, // ID selectors
    b: u16 = 0, // class selectors, attributes, pseudo-classes
    c: u16 = 0, // type selectors, pseudo-elements

    pub fn toU32(self: Specificity) u32 {
        return (@as(u32, self.a) << 20) | (@as(u32, self.b & 0x3FF) << 10) | @as(u32, self.c & 0x3FF);
    }

    pub fn order(a_spec: Specificity, b_spec: Specificity) std.math.Order {
        if (a_spec.a != b_spec.a) return std.math.order(a_spec.a, b_spec.a);
        if (a_spec.b != b_spec.b) return std.math.order(a_spec.b, b_spec.b);
        return std.math.order(a_spec.c, b_spec.c);
    }
};

pub const ParsedSelector = struct {
    components: []SelectorComponent,
    specificity: Specificity,
    pseudo_element: ?PseudoElement = null,

    pub fn deinit(self: *ParsedSelector, allocator: std.mem.Allocator) void {
        allocator.free(self.components);
    }
};

// ── Selector Parsing ─────────────────────────────────────────────────

const SelectorParser = struct {
    source: []const u8,
    pos: usize,
    components: std.ArrayList(SelectorComponent),
    specificity: Specificity,
    allocator: std.mem.Allocator,
    pseudo_element: ?PseudoElement = null,

    fn init(source: []const u8, allocator: std.mem.Allocator) SelectorParser {
        return .{
            .source = source,
            .pos = 0,
            .components = .empty,
            .specificity = .{},
            .allocator = allocator,
            .pseudo_element = null,
        };
    }

    fn deinit(self: *SelectorParser) void {
        self.components.deinit(self.allocator);
    }

    fn peek(self: *SelectorParser) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn advance(self: *SelectorParser) void {
        if (self.pos < self.source.len) self.pos += 1;
    }

    fn skipWhitespace(self: *SelectorParser) void {
        while (self.pos < self.source.len and isWhitespace(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c >= 0x80;
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
    }

    fn consumeIdent(self: *SelectorParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.source[start..self.pos];
    }

    fn consumeString(self: *SelectorParser) []const u8 {
        if (self.pos >= self.source.len) return "";
        const quote = self.source[self.pos];
        if (quote != '"' and quote != '\'') return "";
        self.advance(); // skip opening quote
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == quote) {
                const result = self.source[start..self.pos];
                self.advance(); // skip closing quote
                return result;
            }
            if (c == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2; // skip escape
                continue;
            }
            self.pos += 1;
        }
        return self.source[start..self.pos];
    }

    /// Returns true if the last component is a simple selector (not a combinator),
    /// meaning we need to insert a descendant combinator before the next simple selector.
    fn lastIsSimple(self: *SelectorParser) bool {
        if (self.components.items.len == 0) return false;
        return switch (self.components.items[self.components.items.len - 1]) {
            .simple => true,
            .combinator => false,
        };
    }

    fn parse(self: *SelectorParser) !?ParsedSelector {
        self.skipWhitespace();

        while (self.pos < self.source.len) {
            const c = self.peek();

            if (c == 0) break;

            // Combinator characters
            if (c == '>') {
                self.advance();
                self.skipWhitespace();
                try self.components.append(self.allocator,.{ .combinator = .child });
                continue;
            }
            if (c == '+') {
                self.advance();
                self.skipWhitespace();
                try self.components.append(self.allocator,.{ .combinator = .next_sibling });
                continue;
            }
            if (c == '~') {
                self.advance();
                self.skipWhitespace();
                try self.components.append(self.allocator,.{ .combinator = .subsequent_sibling });
                continue;
            }

            // Whitespace between simple selectors = descendant combinator
            if (isWhitespace(c)) {
                self.skipWhitespace();
                // Only insert descendant combinator if last was a simple selector
                // and the next char is NOT a combinator or end
                const next = self.peek();
                if (next == 0 or next == ',' or next == '{') break;
                if (next == '>' or next == '+' or next == '~') continue; // explicit combinator follows
                if (self.lastIsSimple()) {
                    try self.components.append(self.allocator,.{ .combinator = .descendant });
                }
                continue;
            }

            // Class selector
            if (c == '.') {
                self.advance();
                const name = self.consumeIdent();
                if (name.len == 0) return null;
                try self.components.append(self.allocator,.{ .simple = .{ .class = name } });
                self.specificity.b += 1;
                continue;
            }

            // ID selector
            if (c == '#') {
                self.advance();
                const name = self.consumeIdent();
                if (name.len == 0) return null;
                try self.components.append(self.allocator,.{ .simple = .{ .id = name } });
                self.specificity.a += 1;
                continue;
            }

            // Universal selector
            if (c == '*') {
                self.advance();
                try self.components.append(self.allocator,.{ .simple = .universal });
                continue;
            }

            // Attribute selector
            if (c == '[') {
                const attr = try self.parseAttribute();
                if (attr) |a| {
                    try self.components.append(self.allocator,.{ .simple = .{ .attribute = a } });
                    self.specificity.b += 1;
                } else {
                    return null;
                }
                continue;
            }

            // Pseudo-class or pseudo-element
            if (c == ':') {
                self.advance();
                // :: pseudo-elements
                if (self.peek() == ':') {
                    self.advance(); // skip second ':'
                    const pe_name = self.consumeIdent();
                    if (pe_name.len == 0) return null;
                    if (eqlIgnoreCase(pe_name, "before")) {
                        self.pseudo_element = .before;
                        self.specificity.c += 1; // pseudo-elements have type specificity
                    } else if (eqlIgnoreCase(pe_name, "after")) {
                        self.pseudo_element = .after;
                        self.specificity.c += 1;
                    } else {
                        // Unknown pseudo-element (e.g., ::-webkit-scrollbar) — skip entire selector
                        return null;
                    }
                    continue;
                }
                const name = self.consumeIdent();
                if (name.len == 0) return null;
                if (PseudoClass.fromString(name)) |pc| {
                    var nth: ?NthParams = null;
                    // nth-child, nth-last-child, nth-of-type take (an+b) args
                    if (self.peek() == '(') {
                        const arg_start = self.pos + 1;
                        var depth: u32 = 1;
                        self.advance();
                        while (self.pos < self.source.len and depth > 0) {
                            if (self.source[self.pos] == '(') depth += 1;
                            if (self.source[self.pos] == ')') depth -= 1;
                            self.pos += 1;
                        }
                        const arg_end = if (self.pos > 0) self.pos - 1 else self.pos;
                        if (arg_end > arg_start) {
                            const arg = std.mem.trim(u8, self.source[arg_start..arg_end], " \t");
                            if (pc == .nth_child or pc == .nth_last_child or pc == .nth_of_type or pc == .nth_last_of_type) {
                                nth = parseAnB(arg);
                            }
                        }
                    }
                    try self.components.append(self.allocator, .{ .simple = .{ .pseudo_class = .{ .pc = pc, .nth = nth } } });
                    self.specificity.b += 1;
                } else if (self.peek() == '(' and eqlIgnoreCase(name, "not")) {
                    // :not() pseudo-class
                    self.advance(); // skip '('
                    const inner_start = self.pos;
                    var paren_depth_not: u32 = 1;
                    while (self.pos < self.source.len and paren_depth_not > 0) {
                        if (self.source[self.pos] == '(') paren_depth_not += 1;
                        if (self.source[self.pos] == ')') paren_depth_not -= 1;
                        if (paren_depth_not > 0) self.pos += 1;
                    }
                    const not_inner = self.source[inner_start..self.pos];
                    if (self.pos < self.source.len) self.advance(); // skip ')'
                    try self.components.append(self.allocator, .{ .simple = .{ .pseudo_class = .{
                        .pc = .hover, // placeholder — not used, matching uses not_inner
                        .not_inner = not_inner,
                    } } });
                    self.specificity.b += 1;
                } else if (self.peek() == '(' and (eqlIgnoreCase(name, "where") or eqlIgnoreCase(name, "is"))) {
                    // Handle :where() and :is() — parse inner selector classes/ids
                    self.advance(); // skip '('
                    const inner_start = self.pos;
                    var paren_depth_inner: u32 = 1;
                    while (self.pos < self.source.len and paren_depth_inner > 0) {
                        if (self.source[self.pos] == '(') paren_depth_inner += 1;
                        if (self.source[self.pos] == ')') paren_depth_inner -= 1;
                        if (paren_depth_inner > 0) self.pos += 1;
                    }
                    const inner = self.source[inner_start..self.pos];
                    if (self.pos < self.source.len) self.advance(); // skip ')'

                    // Parse class/id selectors from inner content
                    const is_where = eqlIgnoreCase(name, "where");
                    var inner_pos: usize = 0;
                    while (inner_pos < inner.len) {
                        const ic = inner[inner_pos];
                        if (ic == '.') {
                            inner_pos += 1;
                            const cls_start = inner_pos;
                            while (inner_pos < inner.len and isIdentChar(inner[inner_pos])) inner_pos += 1;
                            if (inner_pos > cls_start) {
                                try self.components.append(self.allocator, .{ .simple = .{ .class = inner[cls_start..inner_pos] } });
                                if (!is_where) self.specificity.b += 1; // :where has zero specificity
                            }
                        } else if (ic == '#') {
                            inner_pos += 1;
                            const id_start = inner_pos;
                            while (inner_pos < inner.len and isIdentChar(inner[inner_pos])) inner_pos += 1;
                            if (inner_pos > id_start) {
                                try self.components.append(self.allocator, .{ .simple = .{ .id = inner[id_start..inner_pos] } });
                                if (!is_where) self.specificity.a += 1;
                            }
                        } else if (isIdentStart(ic)) {
                            const tag_start = inner_pos;
                            while (inner_pos < inner.len and isIdentChar(inner[inner_pos])) inner_pos += 1;
                            if (inner_pos > tag_start) {
                                try self.components.append(self.allocator, .{ .simple = .{ .type_sel = inner[tag_start..inner_pos] } });
                                if (!is_where) self.specificity.c += 1;
                            }
                        } else {
                            inner_pos += 1;
                        }
                    }
                } else {
                    // Unknown pseudo-class, skip including any parenthesized args
                    if (self.peek() == '(') {
                        var depth: u32 = 1;
                        self.advance();
                        while (self.pos < self.source.len and depth > 0) {
                            if (self.source[self.pos] == '(') depth += 1;
                            if (self.source[self.pos] == ')') depth -= 1;
                            self.pos += 1;
                        }
                    }
                    // treat as specificity b (like a class)
                    self.specificity.b += 1;
                }
                continue;
            }

            // Type selector (tag name) — must start with ident start char or '-'
            if (isIdentStart(c) or c == '-') {
                if (self.lastIsSimple()) {
                    // Compound selector without space — this shouldn't happen for
                    // type selectors (e.g. "divp" is not valid). But we handle
                    // cases like pseudo after type by just not inserting a combinator.
                    // Actually compound selectors like "div.foo" are valid — the
                    // type+class case is handled because '.' triggers before we get
                    // here again. But "h1h2" would be wrong. For now just parse it.
                }
                const name = self.consumeIdent();
                if (name.len == 0) return null;
                try self.components.append(self.allocator,.{ .simple = .{ .type_sel = name } });
                self.specificity.c += 1;
                continue;
            }

            // Unknown character, stop parsing
            break;
        }

        if (self.components.items.len == 0) return null;

        return .{
            .components = try self.components.toOwnedSlice(self.allocator),
            .specificity = self.specificity,
            .pseudo_element = self.pseudo_element,
        };
    }

    fn parseAttribute(self: *SelectorParser) !?AttributeSel {
        // Current char is '[', skip it
        self.advance();
        self.skipWhitespace();

        const name = self.consumeIdent();
        if (name.len == 0) return null;

        self.skipWhitespace();

        // Check for closing bracket (exists check)
        if (self.peek() == ']') {
            self.advance();
            return .{ .name = name, .op = .exists };
        }

        // Determine operator
        var op: AttributeOp = .equals;
        const c = self.peek();
        if (c == '=') {
            op = .equals;
            self.advance();
        } else if (c == '~' or c == '^' or c == '$' or c == '*' or c == '|') {
            self.advance();
            if (self.peek() != '=') return null;
            self.advance();
            op = switch (c) {
                '~' => .contains_word,
                '^' => .starts_with,
                '$' => .ends_with,
                '*' => .contains,
                '|' => .starts_with_dash,
                else => unreachable,
            };
        } else {
            // Invalid operator, skip to ']'
            while (self.pos < self.source.len and self.source[self.pos] != ']') self.pos += 1;
            if (self.peek() == ']') self.advance();
            return null;
        }

        self.skipWhitespace();

        // Parse value (quoted or unquoted)
        var value: []const u8 = "";
        if (self.peek() == '"' or self.peek() == '\'') {
            value = self.consumeString();
        } else {
            value = self.consumeIdent();
        }

        self.skipWhitespace();

        // Skip case-sensitivity flag (i or s)
        if (self.peek() == 'i' or self.peek() == 's' or self.peek() == 'I' or self.peek() == 'S') {
            self.advance();
            self.skipWhitespace();
        }

        // Expect ']'
        if (self.peek() == ']') {
            self.advance();
        }

        return .{ .name = name, .op = op, .value = value };
    }
};

pub fn parseSelector(source: []const u8, allocator: std.mem.Allocator) ?ParsedSelector {
    var parser = SelectorParser.init(source, allocator);
    return parser.parse() catch {
        parser.deinit();
        return null;
    };
}

pub fn parseSelectorList(source: []const u8, allocator: std.mem.Allocator) []ParsedSelector {
    var selectors = std.ArrayList(ParsedSelector).init(allocator);
    errdefer selectors.deinit();

    // Split by comma
    var start: usize = 0;
    var i: usize = 0;
    var bracket_depth: u32 = 0;
    var paren_depth: u32 = 0;

    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '[') bracket_depth += 1;
        if (c == ']' and bracket_depth > 0) bracket_depth -= 1;
        if (c == '(') paren_depth += 1;
        if (c == ')' and paren_depth > 0) paren_depth -= 1;
        if (c == ',' and bracket_depth == 0 and paren_depth == 0) {
            const segment = std.mem.trim(u8, source[start..i], " \t\r\n");
            if (segment.len > 0) {
                if (parseSelector(segment, allocator)) |sel| {
                    selectors.append(sel) catch {};
                }
            }
            start = i + 1;
        }
    }

    // Last segment
    const segment = std.mem.trim(u8, source[start..], " \t\r\n");
    if (segment.len > 0) {
        if (parseSelector(segment, allocator)) |sel| {
            selectors.append(sel) catch {};
        }
    }

    return selectors.toOwnedSlice() catch &.{};
}

// ── Selector Matching ────────────────────────────────────────────────

/// A minimal element interface for matching. This abstraction allows
/// matching against different DOM implementations (lexbor, mock, etc.).
pub const ElementAdapter = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        tagName: *const fn (ptr: *const anyopaque) ?[]const u8,
        getAttribute: *const fn (ptr: *const anyopaque, name: []const u8) ?[]const u8,
        parent: *const fn (ptr: *const anyopaque) ?ElementAdapter,
        previousElementSibling: *const fn (ptr: *const anyopaque) ?ElementAdapter,
        nextElementSibling: *const fn (ptr: *const anyopaque) ?ElementAdapter,
        firstChild: *const fn (ptr: *const anyopaque) ?ElementAdapter,
        isDocumentNode: *const fn (ptr: *const anyopaque) bool,
        isHovered: *const fn (ptr: *const anyopaque) bool,
        isFocused: *const fn (ptr: *const anyopaque) bool,
    };

    pub fn tagName(self: ElementAdapter) ?[]const u8 {
        return self.vtable.tagName(self.ptr);
    }

    pub fn getAttribute(self: ElementAdapter, name: []const u8) ?[]const u8 {
        return self.vtable.getAttribute(self.ptr, name);
    }

    pub fn parent(self: ElementAdapter) ?ElementAdapter {
        return self.vtable.parent(self.ptr);
    }

    pub fn previousElementSibling(self: ElementAdapter) ?ElementAdapter {
        return self.vtable.previousElementSibling(self.ptr);
    }

    pub fn nextElementSibling(self: ElementAdapter) ?ElementAdapter {
        return self.vtable.nextElementSibling(self.ptr);
    }

    pub fn firstChild(self: ElementAdapter) ?ElementAdapter {
        return self.vtable.firstChild(self.ptr);
    }

    pub fn isDocumentNode(self: ElementAdapter) bool {
        return self.vtable.isDocumentNode(self.ptr);
    }

    pub fn isHovered(self: ElementAdapter) bool {
        return self.vtable.isHovered(self.ptr);
    }

    pub fn isFocused(self: ElementAdapter) bool {
        return self.vtable.isFocused(self.ptr);
    }
};

pub fn matches(selector: *const ParsedSelector, element: ElementAdapter) bool {
    return matchesWithBloom(selector, element, null);
}

/// Match a selector against an element, optionally using a Bloom filter
/// populated with ancestor class names, IDs, and tag names to quickly reject
/// descendant/child selectors that can't possibly match.
pub fn matchesWithBloom(selector: *const ParsedSelector, element: ElementAdapter, ancestor_bloom: ?*const SelectorBloomFilter) bool {
    const components = selector.components;
    if (components.len == 0) return false;

    // Right-to-left matching
    var idx: usize = components.len;
    var current_element: ?ElementAdapter = element;

    // Start from rightmost component
    while (idx > 0) {
        idx -= 1;
        const comp = components[idx];

        switch (comp) {
            .simple => |simple| {
                const el = current_element orelse return false;
                if (!matchSimple(simple, el)) return false;
            },
            .combinator => |comb| {
                const el = current_element orelse return false;
                // The next component to the left is the one we need to match
                // against the related element
                if (idx == 0) return false;
                idx -= 1;
                const left_comp = components[idx];
                const left_simple = switch (left_comp) {
                    .simple => |s| s,
                    .combinator => return false, // invalid: two combinators in a row
                };

                switch (comb) {
                    .child => {
                        // Bloom filter quick-reject: if the required ancestor simple
                        // selector is definitely not in any ancestor, skip the DOM walk.
                        if (ancestor_bloom) |bf| {
                            if (bloomRejectSimple(left_simple, bf)) return false;
                        }
                        const p = el.parent() orelse return false;
                        if (p.isDocumentNode()) return false;
                        if (!matchSimple(left_simple, p)) return false;
                        current_element = p;
                    },
                    .descendant => {
                        // Bloom filter quick-reject: if the required ancestor simple
                        // selector is definitely not in any ancestor, skip the DOM walk.
                        if (ancestor_bloom) |bf| {
                            if (bloomRejectSimple(left_simple, bf)) return false;
                        }
                        var ancestor = el.parent();
                        while (ancestor) |anc| {
                            if (anc.isDocumentNode()) return false;
                            if (matchSimple(left_simple, anc)) {
                                current_element = anc;
                                break;
                            }
                            ancestor = anc.parent();
                        } else {
                            return false;
                        }
                    },
                    .next_sibling => {
                        const prev = el.previousElementSibling() orelse return false;
                        if (!matchSimple(left_simple, prev)) return false;
                        current_element = prev;
                    },
                    .subsequent_sibling => {
                        var sib = el.previousElementSibling();
                        while (sib) |s| {
                            if (matchSimple(left_simple, s)) {
                                current_element = s;
                                break;
                            }
                            sib = s.previousElementSibling();
                        } else {
                            return false;
                        }
                    },
                }
            },
        }
    }

    return true;
}

/// Check if the bloom filter can definitively reject a simple selector.
/// Returns true if the selector CANNOT match any ancestor (definite rejection).
/// Returns false if the selector MIGHT match (bloom says "maybe present").
fn bloomRejectSimple(simple: SimpleSelector, bf: *const SelectorBloomFilter) bool {
    return switch (simple) {
        .type_sel => |name| !bf.mightContain(SelectorBloomFilter.hashStringLower(name)),
        .class => |cls| !bf.mightContain(SelectorBloomFilter.hashString(cls)),
        .id => |id| !bf.mightContain(SelectorBloomFilter.hashString(id)),
        // universal, attribute, pseudo_class — can't reject via bloom filter
        .universal, .attribute, .pseudo_class => false,
    };
}

fn matchSimple(simple: SimpleSelector, element: ElementAdapter) bool {
    return switch (simple) {
        .universal => true,
        .type_sel => |name| {
            const tag = element.tagName() orelse return false;
            return eqlIgnoreCase(tag, name);
        },
        .class => |cls| {
            const class_attr = element.getAttribute("class") orelse return false;
            return containsWord(class_attr, cls);
        },
        .id => |id| {
            const id_attr = element.getAttribute("id") orelse return false;
            return std.mem.eql(u8, id_attr, id);
        },
        .attribute => |attr| matchAttribute(attr, element),
        .pseudo_class => |pc| matchPseudoClass(pc, element),
    };
}

fn matchAttribute(attr: AttributeSel, element: ElementAdapter) bool {
    switch (attr.op) {
        .exists => {
            return element.getAttribute(attr.name) != null;
        },
        .equals => {
            const val = element.getAttribute(attr.name) orelse return false;
            return std.mem.eql(u8, val, attr.value);
        },
        .contains_word => {
            const val = element.getAttribute(attr.name) orelse return false;
            return containsWord(val, attr.value);
        },
        .starts_with => {
            const val = element.getAttribute(attr.name) orelse return false;
            return std.mem.startsWith(u8, val, attr.value);
        },
        .ends_with => {
            const val = element.getAttribute(attr.name) orelse return false;
            return std.mem.endsWith(u8, val, attr.value);
        },
        .contains => {
            const val = element.getAttribute(attr.name) orelse return false;
            return std.mem.indexOf(u8, val, attr.value) != null;
        },
        .starts_with_dash => {
            const val = element.getAttribute(attr.name) orelse return false;
            if (std.mem.eql(u8, val, attr.value)) return true;
            if (val.len > attr.value.len and
                std.mem.startsWith(u8, val, attr.value) and
                val[attr.value.len] == '-')
            {
                return true;
            }
            return false;
        },
    }
}

fn matchPseudoClass(pcs: PseudoClassSel, element: ElementAdapter) bool {
    // Handle :not() — match if inner selector does NOT match
    if (pcs.not_inner) |inner| {
        return !matchNotInner(inner, element);
    }
    const pc = pcs.pc;
    switch (pc) {
        .first_child => return element.previousElementSibling() == null,
        .last_child => return element.nextElementSibling() == null,
        .only_child => {
            return element.previousElementSibling() == null and
                element.nextElementSibling() == null;
        },
        .root => {
            const p = element.parent() orelse return false;
            return p.isDocumentNode();
        },
        .empty => return element.firstChild() == null,
        .first_of_type => {
            const tag = element.tagName() orelse return false;
            var sib = element.previousElementSibling();
            while (sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) return false;
                }
                sib = s.previousElementSibling();
            }
            return true;
        },
        .last_of_type => {
            const tag = element.tagName() orelse return false;
            var sib = element.nextElementSibling();
            while (sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) return false;
                }
                sib = s.nextElementSibling();
            }
            return true;
        },
        .checked => {
            if (element.getAttribute("checked")) |_| return true;
            return false;
        },
        .disabled => {
            if (element.getAttribute("disabled")) |_| return true;
            return false;
        },
        .enabled => {
            // enabled if not disabled and is a form element
            const tag = element.tagName() orelse return false;
            if (eqlIgnoreCase(tag, "input") or eqlIgnoreCase(tag, "button") or
                eqlIgnoreCase(tag, "select") or eqlIgnoreCase(tag, "textarea"))
            {
                return element.getAttribute("disabled") == null;
            }
            return false;
        },
        .nth_child => {
            const params = pcs.nth orelse return true;
            var position: i32 = 1;
            var sib = element.previousElementSibling();
            while (sib != null) : (sib = sib.?.previousElementSibling()) {
                position += 1;
            }
            return matchesNthFormula(position, params.a, params.b);
        },
        .nth_last_child => {
            const params = pcs.nth orelse return true;
            var position: i32 = 1;
            var sib = element.nextElementSibling();
            while (sib != null) : (sib = sib.?.nextElementSibling()) {
                position += 1;
            }
            return matchesNthFormula(position, params.a, params.b);
        },
        .nth_of_type => {
            const params = pcs.nth orelse return true;
            const tag = element.tagName() orelse return false;
            var position: i32 = 1;
            var sib = element.previousElementSibling();
            while (sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) position += 1;
                }
                sib = s.previousElementSibling();
            }
            return matchesNthFormula(position, params.a, params.b);
        },
        .only_of_type => {
            const tag = element.tagName() orelse return false;
            var prev_sib = element.previousElementSibling();
            while (prev_sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) return false;
                }
                prev_sib = s.previousElementSibling();
            }
            var next_sib = element.nextElementSibling();
            while (next_sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) return false;
                }
                next_sib = s.nextElementSibling();
            }
            return true;
        },
        .nth_last_of_type => {
            const params = pcs.nth orelse return true;
            const tag = element.tagName() orelse return false;
            var position: i32 = 1;
            var sib = element.nextElementSibling();
            while (sib) |s| {
                if (s.tagName()) |st| {
                    if (eqlIgnoreCase(st, tag)) position += 1;
                }
                sib = s.nextElementSibling();
            }
            return matchesNthFormula(position, params.a, params.b);
        },
        // :link matches <a> elements with href attribute (unvisited)
        .link => {
            const tag = element.tagName() orelse "";
            if (eqlIgnoreCase(tag, "a") or eqlIgnoreCase(tag, "area")) {
                return element.getAttribute("href") != null;
            }
            return false;
        },
        // :visited — we don't track visit history, so never matches
        .visited => return false,
        // Interactive pseudo-classes
        .hover => return element.isHovered(),
        .focus => return element.isFocused(),
        .focus_visible => return element.isFocused(), // treat same as :focus
        .focus_within => return element.isFocused(), // approximate: check self only
        .active => return false,
        .target => return false, // no URL fragment tracking
        .placeholder_shown => {
            const tag = element.tagName() orelse return false;
            if (eqlIgnoreCase(tag, "input") or eqlIgnoreCase(tag, "textarea")) {
                // Match if element has a placeholder AND value is empty (per spec)
                if (element.getAttribute("placeholder") == null) return false;
                const val = element.getAttribute("value") orelse return true;
                return val.len == 0;
            }
            return false;
        },
    }
}

/// Check if position matches an+b formula
fn matchesNthFormula(position: i32, a: i32, b: i32) bool {
    if (a == 0) return position == b;
    const diff = position - b;
    if (a > 0) {
        return diff >= 0 and @mod(diff, a) == 0;
    } else {
        return diff <= 0 and @mod(diff, -a) == 0;
    }
}

/// Parse an+b expression (e.g., "2n+1", "odd", "even", "3", "-n+3")
pub fn parseAnB(s: []const u8) NthParams {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (eqlIgnoreCase(trimmed, "odd")) return .{ .a = 2, .b = 1 };
    if (eqlIgnoreCase(trimmed, "even")) return .{ .a = 2, .b = 0 };

    // Try pure number first
    if (std.fmt.parseInt(i32, trimmed, 10)) |n| {
        return .{ .a = 0, .b = n };
    } else |_| {}

    // Find 'n' position
    var n_pos: ?usize = null;
    for (trimmed, 0..) |ch, i| {
        if (ch == 'n' or ch == 'N') {
            n_pos = i;
            break;
        }
    }
    const np = n_pos orelse return .{ .a = 0, .b = 0 };

    // Parse 'a' (before 'n')
    var a: i32 = 1;
    if (np > 0) {
        const a_str = std.mem.trim(u8, trimmed[0..np], " \t");
        if (std.mem.eql(u8, a_str, "-")) {
            a = -1;
        } else if (std.mem.eql(u8, a_str, "+")) {
            a = 1;
        } else {
            a = std.fmt.parseInt(i32, a_str, 10) catch 1;
        }
    }

    // Parse 'b' (after 'n')
    var b: i32 = 0;
    if (np + 1 < trimmed.len) {
        const b_str = std.mem.trim(u8, trimmed[np + 1 ..], " \t");
        if (b_str.len > 0) {
            b = std.fmt.parseInt(i32, b_str, 10) catch 0;
        }
    }

    return .{ .a = a, .b = b };
}

/// Match :not() inner selector against an element
fn matchNotInner(inner: []const u8, element: ElementAdapter) bool {
    // Simple matching for common :not() patterns
    const trimmed = std.mem.trim(u8, inner, " \t");
    if (trimmed.len == 0) return false;

    // :not(.class)
    if (trimmed[0] == '.') {
        const cls = trimmed[1..];
        const class_attr = element.getAttribute("class") orelse return false;
        return containsWord(class_attr, cls);
    }
    // :not(#id)
    if (trimmed[0] == '#') {
        const id = trimmed[1..];
        const id_attr = element.getAttribute("id") orelse return false;
        return std.mem.eql(u8, id_attr, id);
    }
    // :not([attr])
    if (trimmed[0] == '[') {
        if (std.mem.indexOfScalar(u8, trimmed, ']')) |close| {
            const attr_name = std.mem.trim(u8, trimmed[1..close], " \t");
            return element.getAttribute(attr_name) != null;
        }
        return false;
    }
    // :not(:pseudo)
    if (trimmed[0] == ':') {
        const pseudo_name = trimmed[1..];
        if (PseudoClass.fromString(pseudo_name)) |pc| {
            return matchPseudoClass(.{ .pc = pc }, element);
        }
        return false;
    }
    // :not(tagname)
    const tag = element.tagName() orelse return false;
    return eqlIgnoreCase(tag, trimmed);
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var iter = std.mem.splitScalar(u8, haystack, ' ');
    while (iter.next()) |word| {
        if (std.mem.eql(u8, word, needle)) return true;
    }
    return false;
}

const eqlIgnoreCase = util.eqlIgnoreCase;

