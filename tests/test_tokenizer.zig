const std = @import("std");
const css_tok = @import("tokenizer");
const TokenType = css_tok.TokenType;
const Tokenizer = css_tok.Tokenizer;

fn expectTokens(source: []const u8, expected: []const TokenType) !void {
    var tok = Tokenizer.init(source);
    for (expected, 0..) |exp, i| {
        const t = tok.next();
        if (t.type != exp) {
            std.debug.print("Token {d}: expected {s}, got {s} (text: \"{s}\")\n", .{
                i,
                @tagName(exp),
                @tagName(t.type),
                t.text(source),
            });
            return error.TestUnexpectedResult;
        }
    }
    const final = tok.next();
    if (final.type != .eof) {
        std.debug.print("Expected EOF, got {s} (text: \"{s}\")\n", .{
            @tagName(final.type),
            final.text(source),
        });
        return error.TestUnexpectedResult;
    }
}

fn expectToken(source: []const u8, expected: TokenType) !Tokenizer {
    var tok = Tokenizer.init(source);
    const t = tok.next();
    try std.testing.expectEqual(expected, t.type);
    return tok;
}

// ─── 1. Basic tests ────────────────────────────────────────────────

test "empty input" {
    try expectTokens("", &.{});
}

test "whitespace" {
    try expectTokens("   \t\n  ", &.{.whitespace});
}

test "only whitespace variants" {
    // form feed
    try expectTokens(" \t\r\n\x0C ", &.{.whitespace});
}

// ─── 2. Delimiter tests ───────────────────────────────────────────

test "all delimiters" {
    try expectTokens("{}();:,[]", &.{
        .open_curly,    .close_curly,
        .open_paren,    .close_paren,
        .semicolon,     .colon,
        .comma,         .open_bracket,
        .close_bracket,
    });
}

// ─── 3. Ident tests ──────────────────────────────────────────────

test "simple ident" {
    try expectTokens("color", &.{.ident});
    var tok = Tokenizer.init("color");
    const t = tok.next();
    try std.testing.expectEqualStrings("color", t.text("color"));
}

test "hyphenated ident" {
    try expectTokens("background-color", &.{.ident});
}

test "custom property" {
    try expectTokens("--my-var", &.{.ident});
    var tok = Tokenizer.init("--my-var");
    const t = tok.next();
    try std.testing.expectEqualStrings("--my-var", t.text("--my-var"));
}

test "ident with underscore" {
    try expectTokens("_private", &.{.ident});
}

test "vendor prefix ident" {
    try expectTokens("-webkit-transform", &.{.ident});
}

// ─── 4. Hash + At-keyword ─────────────────────────────────────────

test "hash id" {
    try expectTokens("#myid", &.{.hash});
}

test "hash hex color" {
    try expectTokens("#FF0000", &.{.hash});
}

test "hash short hex" {
    try expectTokens("#fff", &.{.hash});
}

test "lone hash" {
    // # not followed by ident char → delim
    try expectTokens("# ", &.{ .delim, .whitespace });
}

test "at-keyword" {
    try expectTokens("@media", &.{.at_keyword});
}

test "at-keyword import" {
    try expectTokens("@import", &.{.at_keyword});
}

test "lone at" {
    // @ not followed by ident → delim
    try expectTokens("@ ", &.{ .delim, .whitespace });
}

// ─── 5. Numbers ──────────────────────────────────────────────────

test "integer" {
    var tok = Tokenizer.init("42");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), t.numeric_value, 0.001);
}

test "float" {
    var tok = Tokenizer.init("3.14");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), t.numeric_value, 0.01);
}

test "negative number" {
    var tok = Tokenizer.init("-10");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), t.numeric_value, 0.001);
}

test "positive number" {
    var tok = Tokenizer.init("+5");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), t.numeric_value, 0.001);
}

test "leading dot number" {
    var tok = Tokenizer.init(".5");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.numeric_value, 0.001);
}

test "number with exponent" {
    var tok = Tokenizer.init("1e2");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.number, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), t.numeric_value, 0.1);
}

// ─── 6. Dimensions + Percentages ─────────────────────────────────

test "dimension px" {
    var tok = Tokenizer.init("10px");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.dimension, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), t.numeric_value, 0.001);
    const unit = tok.source[t.unit_start .. t.unit_start + t.unit_len];
    try std.testing.expectEqualStrings("px", unit);
}

test "dimension em" {
    var tok = Tokenizer.init("2em");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.dimension, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), t.numeric_value, 0.001);
}

test "dimension rem" {
    var tok = Tokenizer.init("1.5rem");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.dimension, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), t.numeric_value, 0.01);
}

test "percentage" {
    var tok = Tokenizer.init("50%");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.percentage, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), t.numeric_value, 0.001);
}

test "negative dimension" {
    var tok = Tokenizer.init("-10px");
    const t = tok.next();
    try std.testing.expectEqual(TokenType.dimension, t.type);
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), t.numeric_value, 0.001);
}

// ─── 7. Strings ──────────────────────────────────────────────────

test "double-quoted string" {
    try expectTokens("\"hello\"", &.{.string});
}

test "single-quoted string" {
    try expectTokens("'world'", &.{.string});
}

test "string with escaped quote" {
    try expectTokens("\"he\\\"llo\"", &.{.string});
}

test "empty string" {
    try expectTokens("\"\"", &.{.string});
}

test "string with escaped newline" {
    try expectTokens("\"line1\\\nline2\"", &.{.string});
}

test "bad string unescaped newline" {
    // A newline inside a string without backslash → bad_string
    // The newline is NOT consumed by the bad_string, so it appears as whitespace
    try expectTokens("\"hello\nworld\"", &.{ .bad_string, .whitespace, .ident, .string });
}

// ─── 8. URL ──────────────────────────────────────────────────────

test "url unquoted" {
    try expectTokens("url(https://example.com/img.png)", &.{.url});
}

test "url quoted becomes function" {
    // url("...") → .function token for "url(", then string, then close_paren
    try expectTokens("url(\"path/to/file.css\")", &.{ .function, .string, .close_paren });
}

test "url with whitespace" {
    try expectTokens("url(  https://example.com  )", &.{.url});
}

// ─── 9. Comments ─────────────────────────────────────────────────

test "comment skipped" {
    try expectTokens("/* comment */div", &.{.ident});
}

test "comment between tokens" {
    try expectTokens("a /* x */ b", &.{ .ident, .whitespace, .whitespace, .ident });
}

test "multiple comments" {
    try expectTokens("/* a *//* b */div", &.{.ident});
}

test "unclosed comment" {
    // Unclosed comment consumes to EOF
    try expectTokens("/* never closed", &.{});
}

// ─── 10. Function ────────────────────────────────────────────────

test "function rgb(" {
    try expectTokens("rgb(", &.{.function});
}

test "function var(" {
    try expectTokens("var(", &.{.function});
}

test "function calc(" {
    try expectTokens("calc(", &.{.function});
}

test "ident not function" {
    // ident NOT followed by '(' is just ident
    try expectTokens("rgb ", &.{ .ident, .whitespace });
}

// ─── 11. Delim (catch-all) ───────────────────────────────────────

test "dot delim" {
    // '.' not followed by digit → delim
    try expectTokens(".foo", &.{ .delim, .ident });
}

test "star delim" {
    try expectTokens("*", &.{.delim});
}

test "greater than" {
    try expectTokens(">", &.{.delim});
}

test "plus not before digit" {
    try expectTokens("+ ", &.{ .delim, .whitespace });
}

test "tilde delim" {
    try expectTokens("~", &.{.delim});
}

test "exclamation delim" {
    try expectTokens("!", &.{.delim});
}

test "equals delim" {
    try expectTokens("=", &.{.delim});
}

// ─── 12. Integration tests ──────────────────────────────────────

test "full CSS rule" {
    try expectTokens(".foo { color: red; }", &.{
        .delim,      // .
        .ident,      // foo
        .whitespace, // ' '
        .open_curly, // {
        .whitespace, // ' '
        .ident,      // color
        .colon,      // :
        .whitespace, // ' '
        .ident,      // red
        .semicolon,  // ;
        .whitespace, // ' '
        .close_curly, // }
    });
}

test "real-world minified CSS" {
    const css = ".Nav__x{visibility:hidden;opacity:0}";
    var tok = Tokenizer.init(css);
    var count: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.type == .eof) break;
        count += 1;
    }
    try std.testing.expect(count > 10);
}

test "negative value in declaration" {
    try expectTokens("margin: -10px", &.{
        .ident,      // margin
        .colon,      // :
        .whitespace, // ' '
        .dimension,  // -10px
    });
}

test "property value list" {
    try expectTokens("margin: 10px 20px 30px 40px", &.{
        .ident,      // margin
        .colon,      // :
        .whitespace,
        .dimension,  // 10px
        .whitespace,
        .dimension,  // 20px
        .whitespace,
        .dimension,  // 30px
        .whitespace,
        .dimension,  // 40px
    });
}

test "color function" {
    try expectTokens("rgb(255, 0, 128)", &.{
        .function,    // rgb(
        .number,      // 255
        .comma,       // ,
        .whitespace,
        .number,      // 0
        .comma,       // ,
        .whitespace,
        .number,      // 128
        .close_paren, // )
    });
}

test "var function with custom property" {
    try expectTokens("var(--main-color)", &.{
        .function,    // var(
        .ident,       // --main-color
        .close_paren, // )
    });
}

test "media query" {
    try expectTokens("@media (max-width: 768px)", &.{
        .at_keyword,    // @media
        .whitespace,
        .open_paren,    // (
        .ident,         // max-width
        .colon,         // :
        .whitespace,
        .dimension,     // 768px
        .close_paren,   // )
    });
}

test "selector combinators" {
    try expectTokens("div > p + span ~ a", &.{
        .ident,      // div
        .whitespace,
        .delim,      // >
        .whitespace,
        .ident,      // p
        .whitespace,
        .delim,      // +
        .whitespace,
        .ident,      // span
        .whitespace,
        .delim,      // ~
        .whitespace,
        .ident,      // a
    });
}

test "attribute selector" {
    try expectTokens("[type=\"text\"]", &.{
        .open_bracket, // [
        .ident,        // type
        .delim,        // =
        .string,       // "text"
        .close_bracket, // ]
    });
}

test "important declaration" {
    try expectTokens("color: red !important", &.{
        .ident,      // color
        .colon,      // :
        .whitespace,
        .ident,      // red
        .whitespace,
        .delim,      // !
        .ident,      // important
    });
}

test "zero without unit" {
    try expectTokens("0", &.{.number});
}

test "multiple rules" {
    const css = "a{color:red}b{color:blue}";
    var tok = Tokenizer.init(css);
    var count: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.type == .eof) break;
        count += 1;
    }
    // a { color : red } b { color : blue }  = 12 tokens
    try std.testing.expectEqual(@as(usize, 12), count);
}

// ─── 13. Edge cases ──────────────────────────────────────────────

test "minus before ident is ident" {
    // -webkit-foo is ONE ident, not delim + ident
    try expectTokens("-webkit-foo", &.{.ident});
}

test "double dash custom property" {
    try expectTokens("--", &.{.ident});
}

test "plus before digit is number" {
    try expectTokens("+42", &.{.number});
}

test "plus before dot digit is number" {
    try expectTokens("+.5", &.{.number});
}

test "minus before dot digit is number" {
    try expectTokens("-.5", &.{.number});
}

test "dot not before digit is delim" {
    try expectTokens(".", &.{.delim});
}

test "lone minus is delim" {
    try expectTokens("- ", &.{ .delim, .whitespace });
}

test "number then ident is dimension" {
    try expectTokens("100vw", &.{.dimension});
}

test "number then percent" {
    try expectTokens("100%", &.{.percentage});
}

test "consecutive idents" {
    try expectTokens("hello world", &.{ .ident, .whitespace, .ident });
}
