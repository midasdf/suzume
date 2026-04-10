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

test "integer literals" {
    try expectTokens("0 42 100", &.{ .number, .number, .number });
}

test "float literals" {
    try expectTokens("3.14 .5 1e10 2.5e-3", &.{ .number, .number, .number, .number });
}

test "hex, octal, binary" {
    try expectTokens("0xFF 0o77 0b1010", &.{ .number, .number, .number });
}

test "string literals" {
    try expectTokens("\"hello\" 'world'", &.{ .string, .string });
}

test "string with escapes" {
    try expectTokens("\"he\\\"llo\" '\\n\\t'", &.{ .string, .string });
}

test "identifiers" {
    try expectTokens("foo bar _private $dollar", &.{ .identifier, .identifier, .identifier, .identifier });
}

test "keywords" {
    try expectTokens("var x = function", &.{ .kw_var, .identifier, .assign, .kw_function });
}

test "mixed expression" {
    try expectTokens("var x = 42 + y;", &.{
        .kw_var, .identifier, .assign, .number, .plus, .identifier, .semicolon,
    });
}

test "simple template literal" {
    try expectTokens("`hello`", &.{.template});
}

test "template with expression" {
    try expectTokens("`a${x}b`", &.{ .template_head, .identifier, .template_tail });
}

test "template with multiple expressions" {
    try expectTokens("`a${x}b${y}c`", &.{ .template_head, .identifier, .template_middle, .identifier, .template_tail });
}
