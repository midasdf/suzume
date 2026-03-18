const std = @import("std");

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
    nth_child,
    nth_last_child,
    nth_of_type,
    root,
    empty,
    checked,
    disabled,
    enabled,

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
        .{ "root", .root },
        .{ "empty", .empty },
        .{ "checked", .checked },
        .{ "disabled", .disabled },
        .{ "enabled", .enabled },
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
        return map.get(lower);
    }
};

pub const PseudoElement = enum {
    before,
    after,
};

pub const SimpleSelector = union(enum) {
    type_sel: []const u8,
    class: []const u8,
    id: []const u8,
    universal,
    attribute: AttributeSel,
    pseudo_class: PseudoClass,
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
                    // nth-child, nth-last-child, nth-of-type take (an+b) args — skip them
                    if (self.peek() == '(') {
                        var depth: u32 = 1;
                        self.advance();
                        while (self.pos < self.source.len and depth > 0) {
                            if (self.source[self.pos] == '(') depth += 1;
                            if (self.source[self.pos] == ')') depth -= 1;
                            self.pos += 1;
                        }
                    }
                    try self.components.append(self.allocator,.{ .simple = .{ .pseudo_class = pc } });
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
};

pub fn matches(selector: *const ParsedSelector, element: ElementAdapter) bool {
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
                        const p = el.parent() orelse return false;
                        if (p.isDocumentNode()) return false;
                        if (!matchSimple(left_simple, p)) return false;
                        current_element = p;
                    },
                    .descendant => {
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

fn matchPseudoClass(pc: PseudoClass, element: ElementAdapter) bool {
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
        // nth-child/nth-last-child/nth-of-type: return true for now (full an+b parsing not yet implemented)
        .nth_child, .nth_last_child, .nth_of_type => return true,
        // Interactive pseudo-classes: always false for now
        .hover, .focus, .active, .visited, .link => return false,
    }
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var iter = std.mem.splitScalar(u8, haystack, ' ');
    while (iter.next()) |word| {
        if (std.mem.eql(u8, word, needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

