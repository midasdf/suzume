const token = @import("token.zig");
pub const Token = token.Token;
pub const TokenType = token.TokenType;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    template_depth: u8 = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0, .line = 1 };
    }

    // --- helpers ---

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    fn peekAt(self: *Lexer, offset: u32) u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return 0;
        return self.source[idx];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    /// Consume current char if it equals `expected`. Returns true if consumed.
    fn match(self: *Lexer, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn makeToken(self: *Lexer, tt: TokenType, start: u32) Token {
        return .{
            .type = tt,
            .start = start,
            .len = @intCast(self.pos - start),
            .line = self.line,
        };
    }

    fn single(self: *Lexer, tt: TokenType) Token {
        const start = self.pos;
        _ = self.advance();
        return self.makeToken(tt, start);
    }

    // --- whitespace / comment skipping ---

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // single-line comment: skip to end of line
                        self.pos += 2;
                        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                            self.pos += 1;
                        }
                    } else if (self.peekNext() == '*') {
                        // multi-line comment
                        self.pos += 2;
                        while (self.pos + 1 < self.source.len) {
                            if (self.source[self.pos] == '\n') {
                                self.line += 1;
                                self.pos += 1;
                            } else if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                self.pos += 2;
                                break;
                            } else {
                                self.pos += 1;
                            }
                        }
                        // handle unclosed comment (consume remaining)
                        if (self.pos < self.source.len and self.source[self.pos - 1] != '/') {
                            // already at end, nothing to do
                        }
                    } else {
                        break; // not a comment, stop
                    }
                },
                else => break,
            }
        }
    }

    // --- literal readers ---

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;

        // Leading dot: .5 .123
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1; // consume dot
            // consume fractional digits (and separators)
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if ((c >= '0' and c <= '9') or c == '_') {
                    self.pos += 1;
                } else break;
            }
            // optional exponent
            self.readExponent();
            return self.makeToken(.number, start);
        }

        // Must start with a digit here
        // Check for 0x / 0o / 0b prefixes
        if (self.pos < self.source.len and self.source[self.pos] == '0' and
            self.pos + 1 < self.source.len)
        {
            const prefix = self.source[self.pos + 1];
            if (prefix == 'x' or prefix == 'X') {
                self.pos += 2;
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or
                        (c >= 'A' and c <= 'F') or c == '_')
                    {
                        self.pos += 1;
                    } else break;
                }
                return self.makeToken(.number, start);
            } else if (prefix == 'o' or prefix == 'O') {
                self.pos += 2;
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if ((c >= '0' and c <= '7') or c == '_') {
                        self.pos += 1;
                    } else break;
                }
                return self.makeToken(.number, start);
            } else if (prefix == 'b' or prefix == 'B') {
                self.pos += 2;
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if (c == '0' or c == '1' or c == '_') {
                        self.pos += 1;
                    } else break;
                }
                return self.makeToken(.number, start);
            }
        }

        // Integer part (with optional numeric separators)
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if ((c >= '0' and c <= '9') or c == '_') {
                self.pos += 1;
            } else break;
        }

        // Optional fractional part
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            // Peek ahead: could be method call like 42.toString() — only consume dot if followed by digit or end
            const next_pos = self.pos + 1;
            const after_dot = if (next_pos < self.source.len) self.source[next_pos] else 0;
            if (after_dot >= '0' and after_dot <= '9') {
                self.pos += 1; // consume dot
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if ((c >= '0' and c <= '9') or c == '_') {
                        self.pos += 1;
                    } else break;
                }
            } else if (after_dot == 0 or after_dot == ' ' or after_dot == '\t' or
                after_dot == '\n' or after_dot == '\r' or after_dot == ';' or
                after_dot == ',' or after_dot == ')' or after_dot == ']' or
                after_dot == '}' or after_dot == 'e' or after_dot == 'E')
            {
                // trailing dot: e.g. "1." — consume dot
                self.pos += 1;
            }
            // else: don't consume dot (method call like 42.toString)
        }

        // Optional exponent
        self.readExponent();

        return self.makeToken(.number, start);
    }

    fn readExponent(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        const c = self.source[self.pos];
        if (c != 'e' and c != 'E') return;
        self.pos += 1;
        if (self.pos < self.source.len and
            (self.source[self.pos] == '+' or self.source[self.pos] == '-'))
        {
            self.pos += 1;
        }
        while (self.pos < self.source.len) {
            const d = self.source[self.pos];
            if ((d >= '0' and d <= '9') or d == '_') {
                self.pos += 1;
            } else break;
        }
    }

    fn readString(self: *Lexer, quote: u8) Token {
        const start = self.pos;
        _ = self.advance(); // consume opening quote
        while (self.pos < self.source.len) {
            const c = self.advance();
            if (c == '\\') {
                if (self.pos < self.source.len) _ = self.advance(); // skip escaped char
            } else if (c == quote) {
                break;
            }
        }
        return self.makeToken(.string, start);
    }

    fn readTemplate(self: *Lexer) Token {
        const start = self.pos;
        _ = self.advance(); // consume backtick
        while (self.pos < self.source.len) {
            const c = self.advance();
            if (c == '\\') {
                if (self.pos < self.source.len) _ = self.advance();
            } else if (c == '`') {
                return self.makeToken(.template, start);
            } else if (c == '$' and self.pos < self.source.len and self.source[self.pos] == '{') {
                self.pos += 1; // consume '{'
                self.template_depth += 1;
                return self.makeToken(.template_head, start);
            } else if (c == '\n') {
                self.line += 1;
            }
        }
        return self.makeToken(.template, start);
    }

    fn readTemplateContinuation(self: *Lexer) Token {
        const start = self.pos;
        _ = self.advance(); // consume '}'
        while (self.pos < self.source.len) {
            const c = self.advance();
            if (c == '\\') {
                if (self.pos < self.source.len) _ = self.advance();
            } else if (c == '`') {
                self.template_depth -= 1;
                return self.makeToken(.template_tail, start);
            } else if (c == '$' and self.pos < self.source.len and self.source[self.pos] == '{') {
                self.pos += 1; // consume '{'
                return self.makeToken(.template_middle, start);
            } else if (c == '\n') {
                self.line += 1;
            }
        }
        // unterminated — return template_tail anyway
        self.template_depth -= 1;
        return self.makeToken(.template_tail, start);
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_' or c == '$')
            {
                self.pos += 1;
            } else {
                break;
            }
        }
        const word = self.source[start..self.pos];
        const kw = token.lookupKeyword(word);
        const tt = kw orelse .identifier;
        return self.makeToken(tt, start);
    }

    // --- main entry ---

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .type = .eof, .start = self.pos, .len = 0, .line = self.line };
        }

        const c = self.peek();
        const start = self.pos;

        switch (c) {
            // single-char punctuators
            '(' => return self.single(.lparen),
            ')' => return self.single(.rparen),
            '{' => return self.single(.lbrace),
            '}' => {
                if (self.template_depth > 0) return self.readTemplateContinuation();
                return self.single(.rbrace);
            },
            '[' => return self.single(.lbracket),
            ']' => return self.single(.rbracket),
            ';' => return self.single(.semicolon),
            ',' => return self.single(.comma),
            '~' => return self.single(.tilde),
            ':' => return self.single(.colon),

            // ?  ?.  ??  ??=
            '?' => {
                _ = self.advance();
                if (self.match('.')) return self.makeToken(.question_dot, start);
                if (self.match('?')) {
                    // ??= — no dedicated token, emit question_question for now
                    if (self.match('=')) return self.makeToken(.question_question, start);
                    return self.makeToken(.question_question, start);
                }
                return self.makeToken(.question, start);
            },

            // .  ...
            '.' => {
                _ = self.advance();
                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
                    self.pos += 2;
                    return self.makeToken(.ellipsis, start);
                }
                // check for digit after dot (e.g. .5)
                if (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    // back up and read as number
                    self.pos = start;
                    return self.readNumber();
                }
                return self.makeToken(.dot, start);
            },

            // +  ++  +=
            '+' => {
                _ = self.advance();
                if (self.match('+')) return self.makeToken(.plus_plus, start);
                if (self.match('=')) return self.makeToken(.plus_assign, start);
                return self.makeToken(.plus, start);
            },

            // -  --  -=
            '-' => {
                _ = self.advance();
                if (self.match('-')) return self.makeToken(.minus_minus, start);
                if (self.match('=')) return self.makeToken(.minus_assign, start);
                return self.makeToken(.minus, start);
            },

            // *  **  *=  **=
            '*' => {
                _ = self.advance();
                if (self.match('*')) {
                    if (self.match('=')) return self.makeToken(.star_star_eq, start);
                    return self.makeToken(.star_star, start);
                }
                if (self.match('=')) return self.makeToken(.star_assign, start);
                return self.makeToken(.star, start);
            },

            // /  /=  (// and /* handled in skipWhitespace)
            '/' => {
                _ = self.advance();
                if (self.match('=')) return self.makeToken(.slash_eq, start);
                return self.makeToken(.slash, start);
            },

            // %  %=
            '%' => {
                _ = self.advance();
                if (self.match('=')) return self.makeToken(.percent_eq, start);
                return self.makeToken(.percent, start);
            },

            // =  ==  ===  =>
            '=' => {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    if (self.match('=')) return self.makeToken(.eq_eq_eq, start);
                    return self.makeToken(.eq_eq, start);
                }
                if (self.match('>')) return self.makeToken(.arrow, start);
                return self.makeToken(.assign, start);
            },

            // !  !=  !==
            '!' => {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    if (self.match('=')) return self.makeToken(.ne_eq, start);
                    return self.makeToken(.bang_eq, start);
                }
                return self.makeToken(.bang, start);
            },

            // <  <=  <<  <<=
            '<' => {
                _ = self.advance();
                if (self.match('<')) {
                    if (self.match('=')) return self.makeToken(.lt_lt_eq, start);
                    return self.makeToken(.lt_lt, start);
                }
                if (self.match('=')) return self.makeToken(.lt_eq, start);
                return self.makeToken(.lt, start);
            },

            // >  >=  >>  >>>  >>=  >>>=
            '>' => {
                _ = self.advance();
                if (self.peek() == '>') {
                    _ = self.advance();
                    if (self.peek() == '>') {
                        _ = self.advance();
                        if (self.match('=')) return self.makeToken(.gt_gt_gt_eq, start);
                        return self.makeToken(.gt_gt_gt, start);
                    }
                    if (self.match('=')) return self.makeToken(.gt_gt_eq, start);
                    return self.makeToken(.gt_gt, start);
                }
                if (self.match('=')) return self.makeToken(.gt_eq, start);
                return self.makeToken(.gt, start);
            },

            // &  &&  &=  &&=
            '&' => {
                _ = self.advance();
                if (self.match('&')) {
                    if (self.match('=')) return self.makeToken(.amp_amp_assign, start);
                    return self.makeToken(.amp_amp, start);
                }
                if (self.match('=')) return self.makeToken(.amp_eq, start);
                return self.makeToken(.amp, start);
            },

            // |  ||  |=  ||=
            '|' => {
                _ = self.advance();
                if (self.match('|')) {
                    if (self.match('=')) return self.makeToken(.pipe_pipe_eq, start);
                    return self.makeToken(.pipe_pipe, start);
                }
                if (self.match('=')) return self.makeToken(.pipe_eq, start);
                return self.makeToken(.pipe, start);
            },

            // ^  ^=
            '^' => {
                _ = self.advance();
                if (self.match('=')) return self.makeToken(.caret_eq, start);
                return self.makeToken(.caret, start);
            },

            // numbers
            '0'...'9' => return self.readNumber(),

            // strings
            '"', '\'' => return self.readString(c),

            // template literals
            '`' => return self.readTemplate(),

            // identifiers / keywords
            'a'...'z', 'A'...'Z', '_', '$' => return self.readIdentifier(),

            // unknown — return eof to avoid infinite loop
            else => {
                _ = self.advance();
                return .{ .type = .eof, .start = start, .len = 1, .line = self.line };
            },
        }
    }
};
