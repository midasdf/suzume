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

    pub fn next(self: *Tokenizer) Token {
        _ = self;
        return .{ .type = .eof, .start = 0, .len = 0 };
    }
};
