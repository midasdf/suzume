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

test "whitespace is skipped" {
    try expectTokens("   \t\n  ", &.{});
}

test "single-line comment" {
    try expectTokens("// comment\n42", &.{.number});
}

test "multi-line comment" {
    try expectTokens("/* comment */42", &.{.number});
}

test "punctuators" {
    try expectTokens("(){};,", &.{ .lparen, .rparen, .lbrace, .rbrace, .semicolon, .comma });
}

test "multi-char punctuators" {
    try expectTokens("=== !== => ...", &.{ .eq_eq_eq, .ne_eq, .arrow, .ellipsis });
}

test "assignment operators" {
    try expectTokens("+= -= *= &&=", &.{ .plus_assign, .minus_assign, .star_assign, .amp_amp_assign });
}
