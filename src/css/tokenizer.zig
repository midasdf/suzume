const std = @import("std");

pub const TokenType = enum {
    ident,
    function,
    at_keyword,
    hash,
    string,
    bad_string,
    url,
    bad_url,
    delim,
    number,
    percentage,
    dimension,
    whitespace,
    colon,
    semicolon,
    comma,
    open_bracket,
    close_bracket,
    open_paren,
    close_paren,
    open_curly,
    close_curly,
    eof,
};

pub const Token = struct {
    type: TokenType,
    start: u32,
    len: u32,
    numeric_value: f32 = 0,
    unit_start: u32 = 0,
    unit_len: u16 = 0,

    pub fn text(self: Token, source: []const u8) []const u8 {
        const s = @as(usize, self.start);
        const e = s + @as(usize, self.len);
        if (e > source.len) return "";
        return source[s..e];
    }
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .pos = 0 };
    }

    fn peek(self: *Tokenizer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *Tokenizer, offset: u32) u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return 0;
        return self.source[idx];
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
    }

    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or isDigit(c) or c == '-';
    }

    /// Check if the current position starts a number.
    /// number = [+|-] digit | [+|-] '.' digit
    fn startsNumber(self: *Tokenizer) bool {
        const c = self.peek();
        if (isDigit(c)) return true;
        if (c == '.' and isDigit(self.peekAt(1))) return true;
        if (c == '+' or c == '-') {
            const c2 = self.peekAt(1);
            if (isDigit(c2)) return true;
            if (c2 == '.' and isDigit(self.peekAt(2))) return true;
        }
        return false;
    }

    /// Check if the current position starts an ident sequence.
    fn startsIdent(self: *Tokenizer) bool {
        const c = self.peek();
        if (isIdentStart(c)) return true;
        if (c == '-') {
            const c2 = self.peekAt(1);
            if (isIdentStart(c2) or c2 == '-') return true;
            // escape: - followed by \ followed by non-newline
            if (c2 == '\\' and self.peekAt(2) != '\n' and self.peekAt(2) != 0) return true;
        }
        if (c == '\\' and self.peekAt(1) != '\n' and self.peekAt(1) != 0) return true;
        return false;
    }

    /// Consume an escape sequence (backslash already consumed by caller or about to be).
    /// Call this when positioned ON the backslash.
    fn consumeEscape(self: *Tokenizer) void {
        // skip the backslash
        self.advance();
        const c = self.peek();
        if (c == 0) return; // EOF after backslash
        if (isHexDigit(c)) {
            // consume 1-6 hex digits
            var count: u32 = 0;
            while (count < 6 and isHexDigit(self.peek())) {
                self.advance();
                count += 1;
            }
            // optional single whitespace after hex escape
            if (isWhitespace(self.peek())) {
                self.advance();
            }
        } else {
            // any non-newline char is consumed literally
            self.advance();
        }
    }

    /// Consume an ident sequence. Assumes startsIdent() was true.
    fn consumeIdent(self: *Tokenizer) void {
        while (true) {
            const c = self.peek();
            if (isIdentChar(c)) {
                self.advance();
            } else if (c == '\\' and self.peekAt(1) != '\n' and self.peekAt(1) != 0) {
                self.consumeEscape();
            } else {
                break;
            }
        }
    }

    /// Consume a number (digits, optional decimal, optional exponent).
    /// Returns the numeric value.
    fn consumeNumber(self: *Tokenizer) f32 {
        const start = self.pos;
        // optional sign
        if (self.peek() == '+' or self.peek() == '-') {
            self.advance();
        }
        // integer part
        while (isDigit(self.peek())) {
            self.advance();
        }
        // decimal part
        if (self.peek() == '.' and isDigit(self.peekAt(1))) {
            self.advance(); // skip '.'
            while (isDigit(self.peek())) {
                self.advance();
            }
        }
        // exponent part (e.g., 1e10, 1E-3)
        const ec = self.peek();
        if (ec == 'e' or ec == 'E') {
            const after_e = self.peekAt(1);
            if (isDigit(after_e)) {
                self.advance(); // skip 'e'/'E'
                while (isDigit(self.peek())) {
                    self.advance();
                }
            } else if ((after_e == '+' or after_e == '-') and isDigit(self.peekAt(2))) {
                self.advance(); // skip 'e'/'E'
                self.advance(); // skip sign
                while (isDigit(self.peek())) {
                    self.advance();
                }
            }
        }
        const end = self.pos;
        const slice = self.source[@as(usize, start)..@as(usize, end)];
        return std.fmt.parseFloat(f32, slice) catch 0.0;
    }

    /// Consume a string token. self.pos should be ON the opening quote.
    fn consumeString(self: *Tokenizer, quote: u8) TokenType {
        self.advance(); // skip opening quote
        while (true) {
            const c = self.peek();
            if (c == 0) {
                // EOF — return string (per spec, unclosed strings are valid)
                return .string;
            }
            if (c == quote) {
                self.advance(); // skip closing quote
                return .string;
            }
            if (c == '\n' or c == '\r' or c == 0x0C) {
                // unescaped newline → bad string
                return .bad_string;
            }
            if (c == '\\') {
                const after_bs = self.peekAt(1);
                if (after_bs == 0) {
                    // backslash at EOF
                    self.advance();
                    return .string;
                }
                if (after_bs == '\n' or after_bs == '\r' or after_bs == 0x0C) {
                    // escaped newline — continue string
                    self.advance(); // skip backslash
                    if (self.peek() == '\r' and self.peekAt(1) == '\n') {
                        self.advance(); // skip \r
                    }
                    self.advance(); // skip newline char
                    continue;
                }
                // other escape
                self.consumeEscape();
                continue;
            }
            self.advance();
        }
    }

    /// Try to consume a url token (unquoted). Called after "url(" has been consumed.
    fn consumeUrl(self: *Tokenizer) TokenType {
        // skip whitespace
        while (isWhitespace(self.peek())) {
            self.advance();
        }

        // If we see a quote, this is actually a function token (quoted url)
        if (self.peek() == '"' or self.peek() == '\'') {
            // We already consumed "url(", so this should be a function token.
            // But we need to signal this. We'll handle this in the caller.
            return .function;
        }

        // Consume unquoted URL
        while (true) {
            const c = self.peek();
            if (c == 0) {
                return .bad_url;
            }
            if (c == ')') {
                self.advance();
                return .url;
            }
            if (isWhitespace(c)) {
                // skip whitespace, then expect ')'
                while (isWhitespace(self.peek())) {
                    self.advance();
                }
                if (self.peek() == ')') {
                    self.advance();
                    return .url;
                }
                // bad url — whitespace in middle of unquoted url
                return self.consumeBadUrl();
            }
            if (c == '"' or c == '\'' or c == '(' or (c >= 0 and c <= 0x08) or c == 0x0B or (c >= 0x0E and c <= 0x1F) or c == 0x7F) {
                return self.consumeBadUrl();
            }
            if (c == '\\') {
                if (self.peekAt(1) == '\n' or self.peekAt(1) == 0) {
                    return self.consumeBadUrl();
                }
                self.consumeEscape();
                continue;
            }
            self.advance();
        }
    }

    fn consumeBadUrl(self: *Tokenizer) TokenType {
        while (true) {
            const c = self.peek();
            if (c == 0 or c == ')') {
                if (c == ')') self.advance();
                return .bad_url;
            }
            if (c == '\\' and self.peekAt(1) != 0) {
                self.consumeEscape();
            } else {
                self.advance();
            }
        }
    }

    /// Skip a comment. self.pos is ON the '/'. Returns true if comment was consumed.
    fn skipComment(self: *Tokenizer) bool {
        if (self.peek() == '/' and self.peekAt(1) == '*') {
            self.advance(); // skip '/'
            self.advance(); // skip '*'
            while (true) {
                const c = self.peek();
                if (c == 0) return true; // EOF in comment
                if (c == '*' and self.peekAt(1) == '/') {
                    self.advance(); // skip '*'
                    self.advance(); // skip '/'
                    return true;
                }
                self.advance();
            }
        }
        return false;
    }

    pub fn next(self: *Tokenizer) Token {
        // Skip comments (loop because there could be consecutive comments)
        while (true) {
            if (self.peek() == '/' and self.peekAt(1) == '*') {
                _ = self.skipComment();
            } else {
                break;
            }
        }

        if (self.pos >= self.source.len) {
            return .{ .type = .eof, .start = self.pos, .len = 0 };
        }

        const start = self.pos;
        const c = self.peek();

        // Whitespace
        if (isWhitespace(c)) {
            while (isWhitespace(self.peek())) {
                self.advance();
            }
            return .{ .type = .whitespace, .start = start, .len = self.pos - start };
        }

        // Strings
        if (c == '"' or c == '\'') {
            const stype = self.consumeString(c);
            return .{ .type = stype, .start = start, .len = self.pos - start };
        }

        // Hash
        if (c == '#') {
            self.advance();
            if (isIdentChar(self.peek()) or self.peek() == '\\') {
                // consume ident chars and escapes in a loop (like consumeIdent)
                while (true) {
                    if (isIdentChar(self.peek())) {
                        self.advance();
                    } else if (self.peek() == '\\' and self.peekAt(1) != '\n' and self.peekAt(1) != 0) {
                        self.consumeEscape();
                    } else {
                        break;
                    }
                }
                return .{ .type = .hash, .start = start, .len = self.pos - start };
            }
            return .{ .type = .delim, .start = start, .len = 1 };
        }

        // Single-char delimiters
        if (c == '(') {
            self.advance();
            return .{ .type = .open_paren, .start = start, .len = 1 };
        }
        if (c == ')') {
            self.advance();
            return .{ .type = .close_paren, .start = start, .len = 1 };
        }
        if (c == '{') {
            self.advance();
            return .{ .type = .open_curly, .start = start, .len = 1 };
        }
        if (c == '}') {
            self.advance();
            return .{ .type = .close_curly, .start = start, .len = 1 };
        }
        if (c == '[') {
            self.advance();
            return .{ .type = .open_bracket, .start = start, .len = 1 };
        }
        if (c == ']') {
            self.advance();
            return .{ .type = .close_bracket, .start = start, .len = 1 };
        }
        if (c == ':') {
            self.advance();
            return .{ .type = .colon, .start = start, .len = 1 };
        }
        if (c == ';') {
            self.advance();
            return .{ .type = .semicolon, .start = start, .len = 1 };
        }
        if (c == ',') {
            self.advance();
            return .{ .type = .comma, .start = start, .len = 1 };
        }

        // At-keyword
        if (c == '@') {
            self.advance();
            if (self.startsIdent()) {
                self.consumeIdent();
                return .{ .type = .at_keyword, .start = start, .len = self.pos - start };
            }
            return .{ .type = .delim, .start = start, .len = 1 };
        }

        // Number starting with digit or '.'
        if (isDigit(c)) {
            return self.consumeNumericToken(start);
        }
        if (c == '.' and isDigit(self.peekAt(1))) {
            return self.consumeNumericToken(start);
        }

        // Plus sign: could be number or delim
        if (c == '+') {
            if (isDigit(self.peekAt(1)) or (self.peekAt(1) == '.' and isDigit(self.peekAt(2)))) {
                return self.consumeNumericToken(start);
            }
            self.advance();
            return .{ .type = .delim, .start = start, .len = 1 };
        }

        // Minus sign: could be number, ident, or delim
        if (c == '-') {
            // Check number first: -digit or -.digit
            if (isDigit(self.peekAt(1)) or (self.peekAt(1) == '.' and isDigit(self.peekAt(2)))) {
                return self.consumeNumericToken(start);
            }
            // Check ident: -letter, --, -\escape
            if (self.startsIdent()) {
                return self.consumeIdentLikeToken(start);
            }
            // CDC token: -->  (we'll just emit as delim sequence)
            self.advance();
            return .{ .type = .delim, .start = start, .len = 1 };
        }

        // Ident-like (ident, function, url)
        if (isIdentStart(c)) {
            return self.consumeIdentLikeToken(start);
        }

        // Backslash — could start an escape-based ident
        if (c == '\\') {
            if (self.peekAt(1) != '\n' and self.peekAt(1) != 0) {
                // valid escape → treat as ident start
                return self.consumeIdentLikeToken(start);
            }
            self.advance();
            return .{ .type = .delim, .start = start, .len = 1 };
        }

        // Anything else is a delim
        self.advance();
        return .{ .type = .delim, .start = start, .len = 1 };
    }

    fn consumeNumericToken(self: *Tokenizer, start: u32) Token {
        const value = self.consumeNumber();

        // Check for percentage
        if (self.peek() == '%') {
            self.advance();
            return .{
                .type = .percentage,
                .start = start,
                .len = self.pos - start,
                .numeric_value = value,
            };
        }

        // Check for dimension (number followed by ident)
        if (self.startsIdent()) {
            const unit_s = self.pos;
            self.consumeIdent();
            const unit_e = self.pos;
            return .{
                .type = .dimension,
                .start = start,
                .len = self.pos - start,
                .numeric_value = value,
                .unit_start = unit_s,
                .unit_len = @intCast(unit_e - unit_s),
            };
        }

        return .{
            .type = .number,
            .start = start,
            .len = self.pos - start,
            .numeric_value = value,
        };
    }

    fn consumeIdentLikeToken(self: *Tokenizer, start: u32) Token {
        self.consumeIdent();

        // Check if followed by '(' → function or url
        if (self.peek() == '(') {
            const ident_end = self.pos;
            const ident_text = self.source[@as(usize, start)..@as(usize, ident_end)];

            self.advance(); // consume '('

            // Check for url(
            if (eqlIgnoreCase(ident_text, "url")) {
                // Save position in case we need to backtrack
                const save_pos = self.pos;
                const url_type = self.consumeUrl();
                if (url_type == .function) {
                    // It was url("...") — backtrack to after '(' and return function
                    self.pos = save_pos;
                    return .{ .type = .function, .start = start, .len = self.pos - start };
                }
                return .{ .type = url_type, .start = start, .len = self.pos - start };
            }

            return .{ .type = .function, .start = start, .len = self.pos - start };
        }

        return .{ .type = .ident, .start = start, .len = self.pos - start };
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
