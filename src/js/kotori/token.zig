const std = @import("std");

pub const TokenType = enum(u8) {
    // Literals
    number,
    string,
    regex,
    template,
    template_head,
    template_middle,
    template_tail,

    // Identifiers
    identifier,

    // Keywords (ES5 + ES6)
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_export,
    kw_extends,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_let,
    kw_new,
    kw_return,
    kw_static,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    kw_yield,
    kw_of,

    // Special keyword-like values
    kw_true,
    kw_false,
    kw_null,
    kw_undefined,

    // Punctuators
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    dot,
    dot_dot_dot,
    semicolon,
    comma,
    question,
    question_question,
    question_dot,
    colon,
    tilde,
    bang,
    bang_eq,
    bang_eq_eq,
    eq,
    eq_eq,
    eq_eq_eq,
    eq_gt,
    plus,
    plus_eq,
    plus_assign, // alias for plus_eq
    plus_plus,
    minus,
    minus_eq,
    minus_assign, // alias for minus_eq
    minus_minus,
    star,
    star_eq,
    star_assign, // alias for star_eq
    star_star,
    star_star_eq,
    slash,
    slash_eq,
    percent,
    percent_eq,
    amp,
    amp_eq,
    amp_amp,
    amp_amp_eq,
    amp_amp_assign, // alias for amp_amp_eq (&&=)
    pipe,
    pipe_eq,
    pipe_pipe,
    pipe_pipe_eq,
    caret,
    caret_eq,
    lt,
    lt_eq,
    lt_lt,
    lt_lt_eq,
    gt,
    gt_eq,
    gt_gt,
    gt_gt_eq,
    gt_gt_gt,
    gt_gt_gt_eq,

    // Aliases used by tests / alternate names
    ne_eq, // !== (same as bang_eq_eq semantically, separate tag for clarity)
    arrow, // => (same as eq_gt semantically)
    ellipsis, // ... (same as dot_dot_dot semantically)
    assign, // = (alias for eq)
    optional_chain, // ?. (alias for question_dot)
    nullish, // ?? (alias for question_question)

    // Control
    eof,
    line_terminator,
};

pub const Token = struct {
    type: TokenType,
    start: u32,
    len: u16,
    line: u32,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start .. self.start + self.len];
    }
};

const keyword_map = std.StaticStringMap(TokenType).initComptime(.{
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "catch", .kw_catch },
    .{ "class", .kw_class },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "debugger", .kw_debugger },
    .{ "default", .kw_default },
    .{ "delete", .kw_delete },
    .{ "do", .kw_do },
    .{ "else", .kw_else },
    .{ "export", .kw_export },
    .{ "extends", .kw_extends },
    .{ "false", .kw_false },
    .{ "finally", .kw_finally },
    .{ "for", .kw_for },
    .{ "function", .kw_function },
    .{ "if", .kw_if },
    .{ "import", .kw_import },
    .{ "in", .kw_in },
    .{ "instanceof", .kw_instanceof },
    .{ "let", .kw_let },
    .{ "new", .kw_new },
    .{ "null", .kw_null },
    .{ "of", .kw_of },
    .{ "return", .kw_return },
    .{ "static", .kw_static },
    .{ "super", .kw_super },
    .{ "switch", .kw_switch },
    .{ "this", .kw_this },
    .{ "throw", .kw_throw },
    .{ "true", .kw_true },
    .{ "try", .kw_try },
    .{ "typeof", .kw_typeof },
    .{ "undefined", .kw_undefined },
    .{ "var", .kw_var },
    .{ "void", .kw_void },
    .{ "while", .kw_while },
    .{ "with", .kw_with },
    .{ "yield", .kw_yield },
});

pub fn lookupKeyword(word: []const u8) ?TokenType {
    return keyword_map.get(word);
}
