const std = @import("std");
const util = @import("util.zig");
const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenType = tokenizer_mod.TokenType;
const Token = tokenizer_mod.Token;
const ast = @import("ast.zig");

pub const Parser = struct {
    source: []const u8,
    tokenizer: Tokenizer,
    allocator: std.mem.Allocator,
    source_order: u32,
    peeked: ?Token,

    pub fn init(source: []const u8, backing_allocator: std.mem.Allocator) Parser {
        return .{
            .source = source,
            .tokenizer = Tokenizer.init(source),
            .allocator = backing_allocator,
            .source_order = 0,
            .peeked = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
        // No-op: caller owns the allocator (typically an arena)
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.allocator;
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
        const s = @min(@as(usize, start), self.source.len);
        const e = @min(@as(usize, end), self.source.len);
        if (s >= e) return "";
        return self.source[s..e];
    }

    // --- Public API ---

    pub fn parse(self: *Parser) !ast.Stylesheet {
        const a = self.alloc();
        var rules: std.ArrayList(ast.Rule) = .empty;
        while (true) {
            const t = self.skipWhitespace();
            if (t.type == .eof) break;
            if (try self.parseRuleWithNesting(t, &rules)) |rule| {
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

    fn parseRuleWithNesting(self: *Parser, first_token: Token, rules: *std.ArrayList(ast.Rule)) ParseError!?ast.Rule {
        if (first_token.type == .at_keyword) {
            return self.parseAtRule(first_token);
        }
        return self.parseStyleRuleInner(first_token, rules);
    }

    fn parseStyleRule(self: *Parser, first_token: Token) ParseError!?ast.Rule {
        return self.parseStyleRuleInner(first_token, null);
    }

    fn parseStyleRuleInner(self: *Parser, first_token: Token, parent_rules: ?*std.ArrayList(ast.Rule)) ParseError!?ast.Rule {
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

        // Parse declarations and nested rules
        const result = try self.parseDeclarationsAndNestedRules(selector_text, parent_rules);

        self.source_order += 1;
        return .{ .style = .{
            .selectors = selectors,
            .declarations = result,
            .source_order = self.source_order - 1,
        } };
    }

    /// Parse a declaration block that may contain CSS nesting.
    /// Nested rules are emitted to parent_rules (or a top-level collector) with the
    /// parent selector prepended.
    fn parseDeclarationsAndNestedRules(
        self: *Parser,
        parent_selector: []const u8,
        parent_rules: ?*std.ArrayList(ast.Rule),
    ) ParseError![]ast.Declaration {
        const a = self.alloc();
        var declarations: std.ArrayList(ast.Declaration) = .empty;
        // Temporary list for nested rules found at this level
        var nested_rules: std.ArrayList(ast.Rule) = .empty;

        while (true) {
            const t = self.skipWhitespace();
            switch (t.type) {
                .close_curly, .eof => break,
                .semicolon => continue,
                .ident => {
                    // Could be a declaration or a nested rule (e.g., "div { ... }")
                    // Peek ahead: if next non-whitespace is '{', it's a nested rule
                    // If next non-whitespace is ':', it's a declaration
                    const peek = self.peekAfterWhitespace();
                    if (peek.type == .open_curly) {
                        // Nested rule: tag selector (e.g., "div { ... }")
                        if (try self.parseNestedRule(t, parent_selector)) |rule| {
                            try nested_rules.append(a, rule);
                        }
                    } else {
                        // Regular declaration
                        if (try self.parseDeclaration(t)) |decl| {
                            try declarations.append(a, decl);
                        }
                    }
                },
                .at_keyword => {
                    // Nested at-rule (e.g., @media inside a style rule)
                    if (try self.parseAtRule(t)) |rule| {
                        try nested_rules.append(a, rule);
                    }
                },
                else => {
                    // Check for nested rule selectors: ., #, &, [, :, >, +, ~, *
                    const text = t.text(self.source);
                    if (isNestedSelectorStart(t.type, text)) {
                        if (try self.parseNestedRule(t, parent_selector)) |rule| {
                            try nested_rules.append(a, rule);
                        }
                    } else {
                        self.skipToRecoveryPoint();
                    }
                },
            }
        }

        // Emit nested rules to the parent collector
        if (nested_rules.items.len > 0) {
            if (parent_rules) |pr| {
                for (nested_rules.items) |rule| {
                    try pr.append(a, rule);
                }
            }
        }

        return try declarations.toOwnedSlice(a);
    }

    /// Check if a token looks like the start of a nested selector
    fn isNestedSelectorStart(token_type: tokenizer_mod.TokenType, text: []const u8) bool {
        if (token_type == .delim) {
            if (text.len > 0) {
                return switch (text[0]) {
                    '.', '#', '&', '*', '>', '+', '~' => true,
                    else => false,
                };
            }
        }
        if (token_type == .colon) return true; // :hover, ::before
        if (token_type == .open_bracket) return true; // [attr]
        return false;
    }

    /// Parse a nested rule: collect selector tokens until '{', then parse body.
    /// Prepend parent selector to create the full selector.
    fn parseNestedRule(self: *Parser, first_token: Token, parent_selector: []const u8) ParseError!?ast.Rule {
        const a = self.alloc();
        const sel_start = first_token.start;
        var sel_end = first_token.start + first_token.len;

        while (true) {
            const p = self.peekToken();
            if (p.type == .open_curly or p.type == .eof or p.type == .close_curly) break;
            _ = self.nextToken();
            sel_end = p.start + p.len;
        }

        const brace = self.nextToken();
        if (brace.type != .open_curly) return null;

        const nested_sel = std.mem.trim(u8, self.sourceSlice(sel_start, sel_end), " \t\r\n");
        const declarations = try self.parseDeclarationBlock();

        // Build combined selector: replace & with parent, or prepend "parent "
        const combined = try self.combineSelectors(parent_selector, nested_sel, a);
        const selectors = try self.splitSelectors(combined);

        self.source_order += 1;
        return .{ .style = .{
            .selectors = selectors,
            .declarations = declarations,
            .source_order = self.source_order - 1,
        } };
    }

    /// Combine parent and nested selectors.
    /// If nested selector contains '&', replace it with parent.
    /// Otherwise, prepend "parent " (descendant combinator).
    fn combineSelectors(self: *Parser, parent: []const u8, nested: []const u8, a: std.mem.Allocator) ParseError![]const u8 {
        _ = self;
        // Check if & is present
        if (std.mem.indexOfScalar(u8, nested, '&')) |_| {
            // Replace all occurrences of & with parent selector
            var result: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < nested.len) {
                if (nested[i] == '&') {
                    result.appendSlice(a, parent) catch return nested;
                    i += 1;
                } else {
                    result.append(a, nested[i]) catch return nested;
                    i += 1;
                }
            }
            return result.toOwnedSlice(a) catch nested;
        } else {
            // Prepend parent as descendant
            const combined = std.fmt.allocPrint(a, "{s} {s}", .{ parent, nested }) catch return nested;
            return combined;
        }
    }

    /// Peek at the next non-whitespace token without consuming anything.
    fn peekAfterWhitespace(self: *Parser) Token {
        // Save current state
        if (self.peeked) |p| {
            return p; // already peeked, return it
        }
        // Peek and check
        const t = self.peekToken();
        if (t.type == .whitespace) {
            // Consume whitespace and peek again
            _ = self.nextToken();
            const next = self.peekToken();
            // We can't put back two tokens, so we need to check
            return next;
        }
        return t;
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

            // Find the ! token by scanning backwards, skipping whitespace between ! and important
            if (last.type == .ident) {
                const imp_text = last.text(self.source);
                if (eqlIgnoreCase(imp_text, "important")) {
                    // Search backwards for the ! delim, skipping whitespace
                    var bang_idx: ?usize = null;
                    var j: usize = tokens_slice.len - 2;
                    while (true) {
                        if (tokens_slice[j].type == .whitespace) {
                            if (j == 0) break;
                            j -= 1;
                            continue;
                        }
                        if (tokens_slice[j].type == .delim and std.mem.eql(u8, tokens_slice[j].text(self.source), "!")) {
                            bang_idx = j;
                        }
                        break;
                    }
                    if (bang_idx) |bi| {
                        important = true;
                        tokens_slice = tokens_slice[0..bi];
                        while (tokens_slice.len > 0 and tokens_slice[tokens_slice.len - 1].type == .whitespace) {
                            tokens_slice = tokens_slice[0 .. tokens_slice.len - 1];
                        }
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
        } else if (eqlIgnoreCase(name, "supports")) {
            return try self.parseSupportsRule();
        } else if (eqlIgnoreCase(name, "import")) {
            return try self.parseImportRule();
        } else if (eqlIgnoreCase(name, "layer")) {
            // CSS Layers (@layer): parse inner rules as if unwrapped.
            // We don't implement layer ordering, but we need to parse the content.
            return try self.parseLayerRule();
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

    fn parseLayerRule(self: *Parser) ParseError!?ast.Rule {
        // @layer can be:
        //   @layer name { rules }  — named layer with content
        //   @layer { rules }       — anonymous layer
        //   @layer name;           — layer declaration (no content)
        //   @layer name, name2;    — layer ordering statement
        // We treat layers as transparent: parse inner rules and flatten them.
        const first_t = self.skipWhitespace();
        if (first_t.type == .eof) return null;

        if (first_t.type == .open_curly) {
            // @layer { rules } — anonymous layer, parse inner rules
            const rules = try self.parseRuleList();
            // Return as media rule with empty query (always matches)
            return .{ .media = .{
                .query = .{ .raw = "" },
                .rules = rules,
            } };
        }

        if (first_t.type == .semicolon) {
            // @layer name; — declaration only, skip
            return null;
        }

        // Skip layer name tokens until '{' or ';'
        while (true) {
            const t = self.peekToken();
            if (t.type == .open_curly or t.type == .semicolon or t.type == .eof) break;
            _ = self.nextToken();
        }

        const next = self.nextToken();
        if (next.type == .open_curly) {
            // @layer name { rules }
            const rules = try self.parseRuleList();
            return .{ .media = .{
                .query = .{ .raw = "" },
                .rules = rules,
            } };
        }
        // @layer name; — semicolon ends it
        return null;
    }

    fn parseImportRule(self: *Parser) ParseError!?ast.Rule {
        // @import url("...") [media];  or  @import "..." [media];
        const first_t = self.skipWhitespace();
        if (first_t.type == .eof) return null;

        var url: []const u8 = "";
        var url_end_pos: u32 = first_t.start + first_t.len;

        const first_text = first_t.text(self.source);

        // Handle url("...") or url('...')
        if (first_t.type == .function and eqlIgnoreCase(first_text, "url(")) {
            // Collect everything until ')'
            const url_start = first_t.start + first_t.len;
            while (true) {
                const t = self.nextToken();
                if (t.type == .close_paren or t.type == .eof or t.type == .semicolon) {
                    url_end_pos = t.start;
                    if (t.type == .semicolon) {
                        // Extract URL and return
                        const raw_url = std.mem.trim(u8, self.sourceSlice(url_start, url_end_pos), " \t\r\n\"'");
                        return .{ .import = .{ .url = raw_url, .media_query = "" } };
                    }
                    break;
                }
            }
            url = std.mem.trim(u8, self.sourceSlice(url_start, url_end_pos), " \t\r\n\"'");
        } else if (first_t.type == .string or first_t.type == .ident) {
            // @import "..." or @import url(...)
            var raw = first_text;
            // Check for url( as ident token
            if (startsWithIgnoreCase(raw, "url(")) {
                const paren_end = std.mem.indexOfScalar(u8, raw, ')') orelse raw.len;
                url = std.mem.trim(u8, raw["url(".len..paren_end], " \t\"'");
            } else {
                // Strip quotes from string token
                if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) {
                    url = raw[1 .. raw.len - 1];
                } else {
                    url = raw;
                }
            }
        } else {
            // Unexpected token, skip to semicolon
            self.peeked = first_t;
            self.skipToRecoveryPoint();
            return null;
        }

        // Collect optional media query until semicolon
        var media_start: u32 = 0;
        var media_end: u32 = 0;
        var has_media = false;

        while (true) {
            const t = self.skipWhitespace();
            if (t.type == .semicolon or t.type == .eof) break;
            if (!has_media) {
                media_start = t.start;
                has_media = true;
            }
            media_end = t.start + t.len;
        }

        const media_query = if (has_media)
            std.mem.trim(u8, self.sourceSlice(media_start, media_end), " \t\r\n")
        else
            "";

        return .{ .import = .{ .url = url, .media_query = media_query } };
    }

    fn startsWithIgnoreCase(str: []const u8, prefix: []const u8) bool {
        if (str.len < prefix.len) return false;
        for (str[0..prefix.len], prefix) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) return false;
        }
        return true;
    }

    fn parseSupportsRule(self: *Parser) ParseError!?ast.Rule {
        // @supports works like @media: condition + rule block.
        // Evaluate the condition: if supported, parse inner rules.
        // If not supported, skip the block.
        const first_t = self.skipWhitespace();
        if (first_t.type == .eof) return null;

        // Collect condition tokens until '{'
        const cond_start = first_t.start;
        var cond_end = first_t.start + first_t.len;
        var found_brace = false;

        if (first_t.type == .open_curly) {
            found_brace = true;
        } else {
            while (true) {
                const t = self.peekToken();
                if (t.type == .open_curly or t.type == .eof) break;
                _ = self.nextToken();
                cond_end = t.start + t.len;
            }
            const brace = self.nextToken();
            if (brace.type == .open_curly) found_brace = true;
        }

        if (!found_brace) return null;

        const condition = std.mem.trim(u8, self.sourceSlice(cond_start, cond_end), " \t\r\n");

        // Evaluate: check if the property in the condition is known
        if (evaluateSupports(condition)) {
            // Supported — parse inner rules (reuse as media rule for flattening)
            const rules = try self.parseRuleList();
            // Return as media rule with "all" query (always applies)
            return .{ .media = .{
                .query = .{ .raw = "all" },
                .rules = rules,
            } };
        } else {
            // Not supported — skip the block
            var depth: u32 = 1;
            while (depth > 0) {
                const t = self.nextToken();
                if (t.type == .eof) break;
                if (t.type == .open_curly) depth += 1;
                if (t.type == .close_curly) depth -= 1;
            }
            return null;
        }
    }

    fn evaluateSupports(condition: []const u8) bool {
        // Parse @supports condition: (property: value), not(...), and/or
        // Simple approach: check if property name inside (...) is a known PropertyId

        // Handle "not (...)"
        var cond = condition;
        var negate = false;
        if (cond.len > 4 and eqlIgnoreCase(cond[0..4], "not ")) {
            negate = true;
            cond = std.mem.trim(u8, cond[4..], " \t");
        }

        // Find (property: value) — extract property name
        if (std.mem.indexOf(u8, cond, "(")) |open| {
            const inner_start = open + 1;
            // Find matching close paren
            var depth: usize = 1;
            var inner_end = inner_start;
            while (inner_end < cond.len and depth > 0) : (inner_end += 1) {
                if (cond[inner_end] == '(') depth += 1;
                if (cond[inner_end] == ')') depth -= 1;
            }
            if (depth == 0 and inner_end > inner_start) {
                const inner = std.mem.trim(u8, cond[inner_start .. inner_end - 1], " \t");
                // Split by ':'
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
                    const prop_name = std.mem.trim(u8, inner[0..colon], " \t");
                    const prop_id = ast.PropertyId.fromString(prop_name);
                    const supported = (prop_id != .unknown);
                    return if (negate) !supported else supported;
                }
            }
        }

        // For "and"/"or" conditions, be optimistic: return true
        return !negate;
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

    const eqlIgnoreCase = util.eqlIgnoreCase;
};
