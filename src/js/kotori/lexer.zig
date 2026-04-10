const token = @import("token.zig");
pub const Token = token.Token;
pub const TokenType = token.TokenType;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0, .line = 1 };
    }

    /// Returns the next token. Currently always returns eof (stub).
    pub fn next(self: *Lexer) Token {
        return .{
            .type = .eof,
            .start = self.pos,
            .len = 0,
            .line = self.line,
        };
    }
};
