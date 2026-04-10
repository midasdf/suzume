const std = @import("std");
const kotori = @import("kotori");
const Lexer = kotori.Lexer;
const TokenType = kotori.TokenType;

fn expectTokens(source: []const u8, expected_types: []const TokenType) !void {
    var lex = Lexer.init(source);
    for (expected_types, 0..) |exp, i| {
        const t = lex.next();
        if (t.type != exp) {
            std.debug.print("Token {d}: expected {s}, got {s}\n", .{
                i, @tagName(exp), @tagName(t.type),
            });
            return error.TestUnexpectedResult;
        }
    }
    const final = lex.next();
    if (final.type != .eof) {
        std.debug.print("Expected eof, got {s}\n", .{@tagName(final.type)});
        return error.TestUnexpectedResult;
    }
}

test "empty source" {
    try expectTokens("", &.{});
}
