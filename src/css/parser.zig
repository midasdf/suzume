const std = @import("std");
const tokenizer_mod = @import("tokenizer");
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenType = tokenizer_mod.TokenType;
const Token = tokenizer_mod.Token;
const ast = @import("ast");

pub const Parser = struct {
    source: []const u8,
    tokenizer: Tokenizer,
    arena: std.heap.ArenaAllocator,
    source_order: u32,
    peeked: ?Token,

    pub fn init(source: []const u8, backing_allocator: std.mem.Allocator) Parser {
        return .{
            .source = source,
            .tokenizer = Tokenizer.init(source),
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .source_order = 0,
            .peeked = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn nextToken(self: *Parser) Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.tokenizer.next();
    }

    fn peekToken(self: *Parser) Token {
        if (self.peeked) |t| return t;
        self.peeked = self.tokenizer.next();
        return self.peeked.?;
    }

    /// Skip whitespace tokens, return next non-whitespace.
    fn skipWhitespace(self: *Parser) Token {
        while (true) {
            const t = self.nextToken();
            if (t.type != .whitespace) return t;
        }
    }

    /// Get the source text slice from start position to end position.
    fn sourceSlice(self: *Parser, start: u32, end: u32) []const u8 {
        const s = @as(usize, start);
        const e = @as(usize, end);
        if (e > self.source.len) return self.source[s..];
        return self.source[s..e];
    }

    // --- Public API ---

    pub fn parse(self: *Parser) !ast.Stylesheet {
        const a = self.alloc();
        var rules: std.ArrayList(ast.Rule) = .empty;
        while (true) {
            const t = self.skipWhitespace();
            if (t.type == .eof) break;
            if (try self.parseRule(t)) |rule| {
                try rules.append(a, rule);
            }
        }
        return .{ .rules = try rules.toOwnedSlice(a) };
    }

    // --- Internal parsing methods ---

    const ParseError = std.mem.Allocator.Error;

    fn parseRule(self: *Parser, first_token: Token) ParseError!?ast.Rule {
        if (first_token.type == .at_keyword) {
            return self.parseAtRule(first_token);
        }
        return self.parseStyleRule(first_token);
    }

    fn parseStyleRule(self: *Parser, first_token: Token) ParseError!?ast.Rule {
        const sel_start = first_token.start;
        var sel_end = first_token.start + first_token.len;

        while (true) {
            const t = self.peekToken();
            if (t.type == .open_curly or t.type == .eof) break;
            _ = self.nextToken();
            sel_end = t.start + t.len;
        }

        const brace = self.nextToken();
        if (brace.type != .open_curly) {
            return null;
        }

        const selector_text = self.sourceSlice(sel_start, sel_end);
        const selectors = try self.splitSelectors(selector_text);
        const declarations = try self.parseDeclarationBlock();

        self.source_order += 1;
        return .{ .style = .{
            .selectors = selectors,
            .declarations = declarations,
            .source_order = self.source_order - 1,
        } };
    }

    fn splitSelectors(self: *Parser, text: []const u8) ParseError![]ast.Selector {
        const a = self.alloc();
        var selectors: std.ArrayList(ast.Selector) = .empty;

        var start: usize = 0;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;

        for (text, 0..) |c, i| {
            switch (c) {
                '(' => paren_depth += 1,
                ')' => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                ',' => {
                    if (paren_depth == 0 and bracket_depth == 0) {
                        const sel = std.mem.trim(u8, text[start..i], " \t\r\n");
                        if (sel.len > 0) {
                            try selectors.append(a, .{ .source = sel });
                        }
                        start = i + 1;
                    }
                },
                else => {},
            }
        }

        const last = std.mem.trim(u8, text[start..], " \t\r\n");
        if (last.len > 0) {
            try selectors.append(a, .{ .source = last });
        }

        return try selectors.toOwnedSlice(a);
    }

    fn parseDeclarationBlock(self: *Parser) ParseError![]ast.Declaration {
        const a = self.alloc();
        var declarations: std.ArrayList(ast.Declaration) = .empty;

        while (true) {
            const t = self.skipWhitespace();
            switch (t.type) {
                .close_curly, .eof => break,
                .semicolon => continue,
                .ident => {
                    if (try self.parseDeclaration(t)) |decl| {
                        try declarations.append(a, decl);
                    }
                },
                else => {
                    self.skipToRecoveryPoint();
                },
            }
        }

        return try declarations.toOwnedSlice(a);
    }

    fn parseDeclaration(self: *Parser, prop_token: Token) ParseError!?ast.Declaration {
        const a = self.alloc();
        const property_name = prop_token.text(self.source);

        // Expect colon.
        const colon = self.skipWhitespace();
        if (colon.type != .colon) {
            self.peeked = colon;
            self.skipToRecoveryPoint();
            return null;
        }

        // Skip leading whitespace in the value.
        var first_value_token: ?Token = null;
        while (true) {
            const t = self.peekToken();
            if (t.type != .whitespace) {
                first_value_token = t;
                break;
            }
            _ = self.nextToken();
        }

        if (first_value_token == null or
            first_value_token.?.type == .semicolon or
            first_value_token.?.type == .close_curly or
            first_value_token.?.type == .eof)
        {
            if (first_value_token) |ft| {
                if (ft.type == .semicolon) {
                    _ = self.nextToken();
                }
            }
            return .{
                .property = ast.PropertyId.fromString(property_name),
                .property_name = property_name,
                .value_raw = "",
                .important = false,
            };
        }

        var important = false;

        // Collect value tokens to detect !important at the end.
        var value_tokens: std.ArrayList(Token) = .empty;

        while (true) {
            const t = self.peekToken();
            if (t.type == .semicolon or t.type == .close_curly or t.type == .eof) {
                if (t.type == .semicolon) {
                    _ = self.nextToken();
                }
                break;
            }
            _ = self.nextToken();
            try value_tokens.append(a, t);
        }

        // Check for !important at the end (ignoring trailing whitespace).
        var tokens_slice = value_tokens.items;
        while (tokens_slice.len > 0 and tokens_slice[tokens_slice.len - 1].type == .whitespace) {
            tokens_slice = tokens_slice[0 .. tokens_slice.len - 1];
        }

        if (tokens_slice.len >= 2) {
            const last = tokens_slice[tokens_slice.len - 1];
            const second_last = tokens_slice[tokens_slice.len - 2];

            if (second_last.type == .delim and last.type == .ident) {
                const bang_text = second_last.text(self.source);
                const imp_text = last.text(self.source);
                if (std.mem.eql(u8, bang_text, "!") and eqlIgnoreCase(imp_text, "important")) {
                    important = true;
                    tokens_slice = tokens_slice[0 .. tokens_slice.len - 2];
                    while (tokens_slice.len > 0 and tokens_slice[tokens_slice.len - 1].type == .whitespace) {
                        tokens_slice = tokens_slice[0 .. tokens_slice.len - 1];
                    }
                }
            }
        }

        // Compute value_raw from remaining tokens.
        var value_raw: []const u8 = "";
        if (tokens_slice.len > 0) {
            const raw_start = tokens_slice[0].start;
            const last_tok = tokens_slice[tokens_slice.len - 1];
            const raw_end = last_tok.start + last_tok.len;
            value_raw = self.sourceSlice(raw_start, raw_end);
        }

        return .{
            .property = ast.PropertyId.fromString(property_name),
            .property_name = property_name,
            .value_raw = value_raw,
            .important = important,
        };
    }

    fn parseAtRule(self: *Parser, at_token: Token) ParseError!?ast.Rule {
        const at_name = at_token.text(self.source);
        const name = if (at_name.len > 1) at_name[1..] else at_name;

        if (eqlIgnoreCase(name, "media")) {
            return try self.parseMediaRule();
        } else if (eqlIgnoreCase(name, "keyframes") or
            eqlIgnoreCase(name, "-webkit-keyframes") or
            eqlIgnoreCase(name, "-moz-keyframes"))
        {
            return try self.parseKeyframesRule();
        } else if (eqlIgnoreCase(name, "font-face")) {
            return try self.parseFontFaceRule();
        } else {
            self.skipAtRule();
            return null;
        }
    }

    fn parseMediaRule(self: *Parser) ParseError!?ast.Rule {
        const first_t = self.skipWhitespace();
        if (first_t.type == .open_curly or first_t.type == .eof) {
            if (first_t.type == .open_curly) {
                const rules = try self.parseRuleList();
                return .{ .media = .{
                    .query = .{ .raw = "" },
                    .rules = rules,
                } };
            }
            return null;
        }

        const query_start = first_t.start;
        var query_end = first_t.start + first_t.len;

        while (true) {
            const t = self.peekToken();
            if (t.type == .open_curly or t.type == .eof) break;
            _ = self.nextToken();
            query_end = t.start + t.len;
        }

        const brace = self.nextToken();
        if (brace.type != .open_curly) return null;

        const query_raw = std.mem.trim(u8, self.sourceSlice(query_start, query_end), " \t\r\n");
        const rules = try self.parseRuleList();

        return .{ .media = .{
            .query = .{ .raw = query_raw },
            .rules = rules,
        } };
    }

    fn parseRuleList(self: *Parser) ParseError![]ast.Rule {
        const a = self.alloc();
        var rules: std.ArrayList(ast.Rule) = .empty;
        while (true) {
            const t = self.skipWhitespace();
            if (t.type == .close_curly or t.type == .eof) break;
            if (try self.parseRule(t)) |rule| {
                try rules.append(a, rule);
            }
        }
        return try rules.toOwnedSlice(a);
    }

    fn parseKeyframesRule(self: *Parser) ParseError!?ast.Rule {
        const a = self.alloc();
        const name_token = self.skipWhitespace();
        if (name_token.type == .eof) return null;

        const name = name_token.text(self.source);

        const brace = self.skipWhitespace();
        if (brace.type != .open_curly) {
            self.peeked = brace;
            self.skipAtRule();
            return null;
        }

        var keyframes: std.ArrayList(ast.Keyframe) = .empty;

        while (true) {
            const t = self.skipWhitespace();
            if (t.type == .close_curly or t.type == .eof) break;

            const kf_sel_start = t.start;
            var kf_sel_end = t.start + t.len;

            while (true) {
                const kt = self.peekToken();
                if (kt.type == .open_curly or kt.type == .eof or kt.type == .close_curly) break;
                _ = self.nextToken();
                kf_sel_end = kt.start + kt.len;
            }

            const kf_brace = self.nextToken();
            if (kf_brace.type != .open_curly) break;

            const selector_raw = std.mem.trim(u8, self.sourceSlice(kf_sel_start, kf_sel_end), " \t\r\n");
            const declarations = try self.parseDeclarationBlock();

            try keyframes.append(a, .{
                .selector_raw = selector_raw,
                .declarations = declarations,
            });
        }

        return .{ .keyframes = .{
            .name = name,
            .keyframes = try keyframes.toOwnedSlice(a),
        } };
    }

    fn parseFontFaceRule(self: *Parser) ParseError!?ast.Rule {
        const brace = self.skipWhitespace();
        if (brace.type != .open_curly) {
            self.peeked = brace;
            self.skipAtRule();
            return null;
        }

        const declarations = try self.parseDeclarationBlock();
        return .{ .font_face = .{
            .declarations = declarations,
        } };
    }

    fn skipAtRule(self: *Parser) void {
        var depth: u32 = 0;
        while (true) {
            const t = self.nextToken();
            switch (t.type) {
                .eof => return,
                .semicolon => {
                    if (depth == 0) return;
                },
                .open_curly => depth += 1,
                .close_curly => {
                    if (depth == 0) return;
                    depth -= 1;
                    if (depth == 0) return;
                },
                else => {},
            }
        }
    }

    fn skipToRecoveryPoint(self: *Parser) void {
        while (true) {
            const t = self.peekToken();
            switch (t.type) {
                .semicolon => {
                    _ = self.nextToken();
                    return;
                },
                .close_curly, .eof => return,
                else => {
                    _ = self.nextToken();
                },
            }
        }
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
};
