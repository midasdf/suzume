const std = @import("std");
const lexer_mod = @import("lexer.zig");
const ast_mod = @import("ast.zig");
const pool_mod = @import("string_pool.zig");
const token_mod = @import("token.zig");

const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const null_node = ast_mod.null_node;
const BinaryOp = ast_mod.BinaryOp;
const UnaryOp = ast_mod.UnaryOp;
const Token = token_mod.Token;
const TokenType = token_mod.TokenType;
const StringId = pool_mod.StringId;

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

const Precedence = enum(u8) {
    none = 0,
    comma = 1,
    assignment = 2,
    ternary = 3,
    nullish_ = 4,
    logical_or = 5,
    logical_and = 6,
    bitwise_or = 7,
    bitwise_xor = 8,
    bitwise_and = 9,
    equality = 10,
    comparison = 11,
    shift = 12,
    additive = 13,
    multiplicative = 14,
    exponentiation = 15,
    unary_ = 16,
    postfix = 17,
    call_ = 18,
    member_ = 19,
};

pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    ast: Ast,
    pool: *pool_mod.StringPool,
    allocator: std.mem.Allocator,
    current: Token,
    peek_token: Token,
    prev_line: u32,
    owns_pool: bool = true,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lex = lexer_mod.Lexer.init(source);
        const cur = nextMeaningful(&lex);
        const peek = nextMeaningful(&lex);
        const pool = allocator.create(pool_mod.StringPool) catch @panic("OOM");
        pool.* = pool_mod.StringPool.init(allocator);
        return .{
            .lexer = lex,
            .ast = .{},
            .pool = pool,
            .allocator = allocator,
            .current = cur,
            .peek_token = peek,
            .prev_line = cur.line,
        };
    }

    /// Init with an external shared StringPool (caller owns it).
    pub fn initWithPool(allocator: std.mem.Allocator, source: []const u8, pool: *pool_mod.StringPool) Parser {
        var lex = lexer_mod.Lexer.init(source);
        const cur = nextMeaningful(&lex);
        const peek = nextMeaningful(&lex);
        return .{
            .lexer = lex,
            .ast = .{},
            .pool = pool,
            .allocator = allocator,
            .current = cur,
            .peek_token = peek,
            .prev_line = cur.line,
            .owns_pool = false,
        };
    }

    fn nextMeaningful(lex: *lexer_mod.Lexer) Token {
        while (true) {
            const tok = lex.next();
            if (tok.type != .line_terminator) return tok;
        }
    }

    /// Parse a full program. Returns root program NodeIndex.
    pub fn parse(self: *Parser) !NodeIndex {
        var stmts = std.ArrayListUnmanaged(NodeIndex){};
        defer stmts.deinit(self.allocator);

        while (!self.check(.eof)) {
            const stmt = try self.parseStatement();
            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
        }

        const list = self.ast.addNodeList(self.allocator, stmts.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .program = list }) catch return error.OutOfMemory;
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit(self.allocator);
        if (self.owns_pool) {
            self.pool.deinit();
            self.allocator.destroy(self.pool);
        }
    }

    // ---------------------------------------------------------------
    // Token helpers
    // ---------------------------------------------------------------

    fn advance(self: *Parser) void {
        self.prev_line = self.current.line;
        self.current = self.peek_token;
        self.peek_token = nextMeaningful(&self.lexer);
    }

    fn expect(self: *Parser, tt: TokenType) ParseError!void {
        if (self.current.type == tt) {
            self.advance();
            return;
        }
        return error.UnexpectedToken;
    }

    fn match(self: *Parser, tt: TokenType) bool {
        if (self.current.type == tt) {
            self.advance();
            return true;
        }
        return false;
    }

    fn check(self: *const Parser, tt: TokenType) bool {
        return self.current.type == tt;
    }

    fn tokenSlice(self: *const Parser, tok: Token) []const u8 {
        return tok.slice(self.lexer.source);
    }

    // ---------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------

    pub fn parseExpression(self: *Parser) ParseError!NodeIndex {
        return self.parsePrecedence(.assignment);
    }

    // ---------------------------------------------------------------
    // Pratt core
    // ---------------------------------------------------------------

    fn parsePrecedence(self: *Parser, min_prec: Precedence) ParseError!NodeIndex {
        // 1. Parse prefix (nud)
        var lhs = try self.parsePrefix();

        // 2. Loop infix
        while (true) {
            const infix_prec = infixPrecedence(self.current.type);
            if (@intFromEnum(infix_prec) < @intFromEnum(min_prec)) break;
            if (infix_prec == .none) break;

            lhs = try self.parseInfix(lhs, infix_prec);
        }

        return lhs;
    }

    // ---------------------------------------------------------------
    // Prefix (nud)
    // ---------------------------------------------------------------

    fn parsePrefix(self: *Parser) ParseError!NodeIndex {
        const tt = self.current.type;
        switch (tt) {
            .number => return self.parseNumber(),
            .string => return self.parseString(),
            .kw_true => return self.parseBool(true),
            .kw_false => return self.parseBool(false),
            .kw_null => return self.parseNull(),
            .kw_undefined => return self.parseUndefined(),
            .identifier => return self.parseIdentifier(),
            .kw_this => return self.parseThis(),
            .lparen => return self.parseGrouped(),
            .lbracket => return self.parseArrayLiteral(),
            .lbrace => return self.parseObjectLiteral(),
            .bang => return self.parseUnary(.not),
            .minus => return self.parseUnary(.neg),
            .plus => return self.parseUnary(.pos),
            .tilde => return self.parseUnary(.bit_not),
            .kw_typeof => return self.parseUnary(.typeof_),
            .kw_void => return self.parseUnary(.void_),
            .kw_delete => return self.parseUnary(.delete_),
            .kw_new => return self.parseNew(),
            .plus_plus => return self.parseUpdate(.pre_inc),
            .minus_minus => return self.parseUpdate(.pre_dec),
            .kw_function => return self.parseFunctionExpr(),
            .template => return self.parseTemplateLiteral(),
            .template_head => return self.parseTemplateLiteral(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseNumber(self: *Parser) ParseError!NodeIndex {
        const text = self.tokenSlice(self.current);
        self.advance();
        const val = parseNumericLiteral(text);
        return self.ast.addNode(self.allocator, .{ .number_literal = val }) catch return error.OutOfMemory;
    }

    fn parseNumericLiteral(text: []const u8) f64 {
        if (text.len >= 2 and text[0] == '0') {
            const prefix = text[1];
            if (prefix == 'x' or prefix == 'X') {
                // Strip underscores for parsing
                return @floatFromInt(parseIntStripped(u64, text[2..], 16));
            } else if (prefix == 'o' or prefix == 'O') {
                return @floatFromInt(parseIntStripped(u64, text[2..], 8));
            } else if (prefix == 'b' or prefix == 'B') {
                return @floatFromInt(parseIntStripped(u64, text[2..], 2));
            }
        }
        // Regular decimal (possibly with underscores)
        return parseFloatStripped(text);
    }

    fn parseIntStripped(comptime T: type, text: []const u8, base: u8) T {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (c != '_') {
                if (len < buf.len) {
                    buf[len] = c;
                    len += 1;
                }
            }
        }
        return std.fmt.parseInt(T, buf[0..len], base) catch 0;
    }

    fn parseFloatStripped(text: []const u8) f64 {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (c != '_') {
                if (len < buf.len) {
                    buf[len] = c;
                    len += 1;
                }
            }
        }
        return std.fmt.parseFloat(f64, buf[0..len]) catch 0.0;
    }

    fn parseString(self: *Parser) ParseError!NodeIndex {
        const text = self.tokenSlice(self.current);
        self.advance();
        // Strip quotes
        const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
        const sid = self.pool.intern(content) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .string_literal = sid }) catch return error.OutOfMemory;
    }

    fn parseTemplateLiteral(self: *Parser) ParseError!NodeIndex {
        var parts: [64]NodeIndex = undefined;
        var count: usize = 0;

        if (self.current.type == .template) {
            // No-substitution template: `text`
            const text = self.tokenSlice(self.current);
            self.advance();
            const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
            const sid = self.pool.intern(content) catch return error.OutOfMemory;
            return self.ast.addNode(self.allocator, .{ .string_literal = sid }) catch return error.OutOfMemory;
        }

        // template_head: `text${
        {
            const text = self.tokenSlice(self.current);
            // Strip leading backtick and trailing ${
            const content = if (text.len >= 3) text[1 .. text.len - 2] else "";
            const sid = self.pool.intern(content) catch return error.OutOfMemory;
            const str_node = self.ast.addNode(self.allocator, .{ .string_literal = sid }) catch return error.OutOfMemory;
            if (count < parts.len) {
                parts[count] = str_node;
                count += 1;
            }
            self.advance(); // consume template_head
        }

        // Parse expression + (template_middle | template_tail) pairs
        while (true) {
            // Parse the interpolated expression
            const expr = try self.parsePrecedence(.assignment);
            if (count < parts.len) {
                parts[count] = expr;
                count += 1;
            }

            if (self.current.type == .template_middle) {
                // }text${
                const text = self.tokenSlice(self.current);
                const content = if (text.len >= 3) text[1 .. text.len - 2] else "";
                const sid = self.pool.intern(content) catch return error.OutOfMemory;
                const str_node = self.ast.addNode(self.allocator, .{ .string_literal = sid }) catch return error.OutOfMemory;
                if (count < parts.len) {
                    parts[count] = str_node;
                    count += 1;
                }
                self.advance(); // consume template_middle
            } else if (self.current.type == .template_tail) {
                // }text`
                const text = self.tokenSlice(self.current);
                const content = if (text.len >= 2) text[1 .. text.len - 1] else "";
                const sid = self.pool.intern(content) catch return error.OutOfMemory;
                const str_node = self.ast.addNode(self.allocator, .{ .string_literal = sid }) catch return error.OutOfMemory;
                if (count < parts.len) {
                    parts[count] = str_node;
                    count += 1;
                }
                self.advance(); // consume template_tail
                break;
            } else {
                break; // malformed template
            }
        }

        const list = self.ast.addNodeList(self.allocator, parts[0..count]) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .template_literal = list }) catch return error.OutOfMemory;
    }

    fn parseBool(self: *Parser, val: bool) ParseError!NodeIndex {
        self.advance();
        return self.ast.addNode(self.allocator, .{ .bool_literal = val }) catch return error.OutOfMemory;
    }

    fn parseNull(self: *Parser) ParseError!NodeIndex {
        self.advance();
        return self.ast.addNode(self.allocator, .{ .null_literal = {} }) catch return error.OutOfMemory;
    }

    fn parseUndefined(self: *Parser) ParseError!NodeIndex {
        const sid = self.pool.intern("undefined") catch return error.OutOfMemory;
        self.advance();
        return self.ast.addNode(self.allocator, .{ .identifier = sid }) catch return error.OutOfMemory;
    }

    fn parseIdentifier(self: *Parser) ParseError!NodeIndex {
        const text = self.tokenSlice(self.current);
        const sid = self.pool.intern(text) catch return error.OutOfMemory;
        self.advance();
        // Check for single-param arrow function: x => expr
        if (self.check(.eq_gt) or self.check(.arrow)) {
            const param_node = self.ast.addNode(self.allocator, .{ .identifier = sid }) catch return error.OutOfMemory;
            return self.parseArrowFunction(&.{param_node});
        }
        return self.ast.addNode(self.allocator, .{ .identifier = sid }) catch return error.OutOfMemory;
    }

    fn parseThis(self: *Parser) ParseError!NodeIndex {
        self.advance();
        return self.ast.addNode(self.allocator, .{ .this = {} }) catch return error.OutOfMemory;
    }

    fn parseGrouped(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume (

        // Check for empty parens: () => ...
        if (self.check(.rparen)) {
            self.advance(); // consume )
            if (self.check(.eq_gt) or self.check(.arrow)) {
                return self.parseArrowFunction(&.{});
            }
            return error.UnexpectedToken;
        }

        const first = try self.parsePrecedence(.assignment);

        // Collect comma-separated expressions (potential param list)
        if (self.check(.comma)) {
            var items = std.ArrayListUnmanaged(NodeIndex){};
            defer items.deinit(self.allocator);
            items.append(self.allocator, first) catch return error.OutOfMemory;
            while (self.match(.comma)) {
                const item = try self.parsePrecedence(.assignment);
                items.append(self.allocator, item) catch return error.OutOfMemory;
            }
            try self.expect(.rparen);
            if (self.check(.eq_gt) or self.check(.arrow)) {
                return self.parseArrowFunction(items.items);
            }
            // Not an arrow function - create a sequence/comma expression
            // Return the last item (comma operator semantics handled by binary parser normally,
            // but since we already consumed them, wrap as sequence)
            const list = self.ast.addNodeList(self.allocator, items.items) catch return error.OutOfMemory;
            return self.ast.addNode(self.allocator, .{ .sequence = list }) catch return error.OutOfMemory;
        }

        try self.expect(.rparen);

        // Check for arrow function with single param
        if (self.check(.eq_gt) or self.check(.arrow)) {
            return self.parseArrowFunction(&.{first});
        }

        return first;
    }

    fn parseArrowFunction(self: *Parser, param_exprs: []const NodeIndex) ParseError!NodeIndex {
        self.advance(); // consume =>

        // Parse body: either a block or a single expression
        var body: NodeIndex = undefined;
        if (self.check(.lbrace)) {
            body = try self.parseBlock();
        } else {
            body = try self.parsePrecedence(.assignment);
        }

        // param_exprs are identifier nodes (already in AST), use them directly as params
        const params_list = self.ast.addNodeList(self.allocator, param_exprs) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .arrow_function = .{
            .params = params_list,
            .body = body,
            .is_expression = true,
        } }) catch return error.OutOfMemory;
    }

    fn parseArrayLiteral(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume [
        var items = std.ArrayListUnmanaged(NodeIndex){};
        defer items.deinit(self.allocator);

        while (!self.check(.rbracket) and !self.check(.eof)) {
            const elem = try self.parsePrecedence(.assignment);
            items.append(self.allocator, elem) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbracket);

        const list = self.ast.addNodeList(self.allocator, items.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .array_literal = list }) catch return error.OutOfMemory;
    }

    fn parseObjectLiteral(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume {
        var props = std.ArrayListUnmanaged(NodeIndex){};
        defer props.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const prop = try self.parseProperty();
            props.append(self.allocator, prop) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);

        const list = self.ast.addNodeList(self.allocator, props.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .object_literal = list }) catch return error.OutOfMemory;
    }

    fn parseProperty(self: *Parser) ParseError!NodeIndex {
        // key: value
        const key = try self.parsePropertyKey();
        try self.expect(.colon);
        const value = try self.parsePrecedence(.assignment);
        return self.ast.addNode(self.allocator, .{ .property = .{
            .key = key,
            .value = value,
            .kind = .init,
        } }) catch return error.OutOfMemory;
    }

    fn parsePropertyKey(self: *Parser) ParseError!NodeIndex {
        switch (self.current.type) {
            .identifier => {
                return self.parseIdentifier();
            },
            .string => return self.parseString(),
            .number => return self.parseNumber(),
            .lbracket => {
                self.advance(); // consume [
                const expr = try self.parsePrecedence(.assignment);
                try self.expect(.rbracket);
                return expr;
            },
            else => {
                // Allow keywords as property keys
                if (isKeyword(self.current.type)) {
                    return self.parseIdentifier();
                }
                return error.UnexpectedToken;
            },
        }
    }

    fn isKeyword(tt: TokenType) bool {
        return switch (tt) {
            .kw_break, .kw_case, .kw_catch, .kw_class, .kw_const,
            .kw_continue, .kw_debugger, .kw_default, .kw_delete,
            .kw_do, .kw_else, .kw_export, .kw_extends, .kw_finally,
            .kw_for, .kw_function, .kw_if, .kw_import, .kw_in,
            .kw_instanceof, .kw_let, .kw_new, .kw_return, .kw_static,
            .kw_super, .kw_switch, .kw_this, .kw_throw, .kw_try,
            .kw_typeof, .kw_var, .kw_void, .kw_while, .kw_with,
            .kw_yield, .kw_of, .kw_true, .kw_false, .kw_null,
            .kw_undefined,
            => true,
            else => false,
        };
    }

    fn parseUnary(self: *Parser, op: UnaryOp) ParseError!NodeIndex {
        self.advance(); // consume operator
        const operand = try self.parsePrecedence(.unary_);
        return self.ast.addNode(self.allocator, .{ .unary = .{
            .operand = operand,
            .op = op,
        } }) catch return error.OutOfMemory;
    }

    fn parseUpdate(self: *Parser, op: UnaryOp) ParseError!NodeIndex {
        self.advance(); // consume ++ or --
        const operand = try self.parsePrecedence(.unary_);
        return self.ast.addNode(self.allocator, .{ .update = .{
            .operand = operand,
            .op = op,
        } }) catch return error.OutOfMemory;
    }

    fn parseNew(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'new'
        // Parse callee — use member_ precedence to allow `new Foo.Bar()`
        const callee = try self.parsePrecedence(.member_);

        // Parse arguments
        var args_list: NodeList = .{ .start = 0, .len = 0 };
        if (self.check(.lparen)) {
            self.advance(); // consume (
            var args = std.ArrayListUnmanaged(NodeIndex){};
            defer args.deinit(self.allocator);
            while (!self.check(.rparen) and !self.check(.eof)) {
                const arg = try self.parsePrecedence(.assignment);
                args.append(self.allocator, arg) catch return error.OutOfMemory;
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            args_list = self.ast.addNodeList(self.allocator, args.items) catch return error.OutOfMemory;
        }

        return self.ast.addNode(self.allocator, .{ .new_expr = .{
            .callee = callee,
            .args = args_list,
        } }) catch return error.OutOfMemory;
    }

    fn parseFunctionExpr(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'function'

        // Optional name
        var name: ?StringId = null;
        if (self.current.type == .identifier) {
            const text = self.tokenSlice(self.current);
            name = self.pool.intern(text) catch return error.OutOfMemory;
            self.advance();
        }

        // Parameters
        try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(NodeIndex){};
        defer params.deinit(self.allocator);
        while (!self.check(.rparen) and !self.check(.eof)) {
            const param = try self.parseIdentifier();
            params.append(self.allocator, param) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);

        // Body
        const body = try self.parseBlock();

        const params_list = self.ast.addNodeList(self.allocator, params.items) catch return error.OutOfMemory;

        return self.ast.addNode(self.allocator, .{ .function_expr = .{
            .name = name,
            .params = params_list,
            .body = body,
            .is_expression = true,
        } }) catch return error.OutOfMemory;
    }

    // ---------------------------------------------------------------
    // Statement parsing
    // ---------------------------------------------------------------

    fn parseStatement(self: *Parser) ParseError!NodeIndex {
        switch (self.current.type) {
            .kw_var, .kw_let, .kw_const => return self.parseVarDecl(),
            .kw_if => return self.parseIfStatement(),
            .kw_while => return self.parseWhileStatement(),
            .kw_do => return self.parseDoWhileStatement(),
            .kw_for => return self.parseForStatement(),
            .kw_switch => return self.parseSwitchStatement(),
            .kw_try => return self.parseTryStatement(),
            .kw_return => return self.parseReturnStatement(),
            .kw_throw => return self.parseThrowStatement(),
            .kw_break => return self.parseBreakStatement(),
            .kw_continue => return self.parseContinueStatement(),
            .kw_function => return self.parseFunctionDecl(),
            .kw_class => return self.parseClassDecl(),
            .kw_with => return self.parseWithStatement(),
            .kw_debugger => return self.parseDebuggerStatement(),
            .lbrace => return self.parseBlock(),
            .semicolon => {
                self.advance();
                return self.ast.addNode(self.allocator, .{ .empty_statement = {} }) catch return error.OutOfMemory;
            },
            else => {
                // Check for labeled statement: identifier followed by colon
                if (self.current.type == .identifier and self.peek_token.type == .colon) {
                    return self.parseLabeledStatement();
                }
                // Expression statement
                const expr = try self.parseExpression();
                try self.expectSemicolon();
                return self.ast.addNode(self.allocator, .{ .expression_stmt = expr }) catch return error.OutOfMemory;
            },
        }
    }

    fn expectSemicolon(self: *Parser) ParseError!void {
        if (self.match(.semicolon)) return;
        // ASI: if current is }, eof, or on a new line, treat as implicit semicolon
        if (self.check(.rbrace) or self.check(.eof)) return;
        if (self.current.line > self.prev_line) return;
        return error.UnexpectedToken;
    }

    fn parseBlock(self: *Parser) ParseError!NodeIndex {
        try self.expect(.lbrace);
        var stmts = std.ArrayListUnmanaged(NodeIndex){};
        defer stmts.deinit(self.allocator);
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const stmt = try self.parseStatement();
            stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
        }
        try self.expect(.rbrace);
        const list = self.ast.addNodeList(self.allocator, stmts.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .block = list }) catch return error.OutOfMemory;
    }

    fn parseVarDecl(self: *Parser) ParseError!NodeIndex {
        const kind: ast_mod.VarDecl.Kind = switch (self.current.type) {
            .kw_var => .@"var",
            .kw_let => .let,
            .kw_const => .@"const",
            else => return error.UnexpectedToken,
        };
        self.advance(); // consume var/let/const

        var declarators = std.ArrayListUnmanaged(NodeIndex){};
        defer declarators.deinit(self.allocator);

        while (true) {
            const name = try self.parseIdentifier();
            var init_node: NodeIndex = null_node;
            if (self.match(.eq) or self.match(.assign)) {
                init_node = try self.parsePrecedence(.assignment);
            }
            const decl = self.ast.addNode(self.allocator, .{ .var_declarator = .{
                .name = name,
                .init_ = init_node,
            } }) catch return error.OutOfMemory;
            declarators.append(self.allocator, decl) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expectSemicolon();

        const list = self.ast.addNodeList(self.allocator, declarators.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .var_decl = .{
            .kind = kind,
            .declarators = list,
        } }) catch return error.OutOfMemory;
    }

    fn parseIfStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'if'
        try self.expect(.lparen);
        const condition = try self.parseExpression();
        try self.expect(.rparen);
        const consequent = try self.parseStatement();
        var alternate: NodeIndex = null_node;
        if (self.match(.kw_else)) {
            alternate = try self.parseStatement();
        }
        return self.ast.addNode(self.allocator, .{ .if_stmt = .{
            .test_ = condition,
            .consequent = consequent,
            .alternate = alternate,
        } }) catch return error.OutOfMemory;
    }

    fn parseWhileStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'while'
        try self.expect(.lparen);
        const condition = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseStatement();
        return self.ast.addNode(self.allocator, .{ .while_stmt = .{
            .test_ = condition,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseDoWhileStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'do'
        const body = try self.parseStatement();
        try self.expect(.kw_while);
        try self.expect(.lparen);
        const condition = try self.parseExpression();
        try self.expect(.rparen);
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .do_while_stmt = .{
            .test_ = condition,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseForStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'for'
        try self.expect(.lparen);

        // Parse init
        var init_node: NodeIndex = null_node;
        if (self.check(.semicolon)) {
            // empty init
            self.advance();
        } else if (self.check(.kw_var) or self.check(.kw_let) or self.check(.kw_const)) {
            // var/let/const declaration - parse without consuming semicolon
            init_node = try self.parseVarDeclNoSemicolon();
            // Check for for-in
            if (self.match(.kw_in)) {
                return self.parseForIn(init_node);
            }
            try self.expect(.semicolon);
        } else {
            init_node = try self.parseExpression();
            if (self.match(.kw_in)) {
                return self.parseForIn(init_node);
            }
            try self.expect(.semicolon);
        }

        // Parse test
        var test_node: NodeIndex = null_node;
        if (!self.check(.semicolon)) {
            test_node = try self.parseExpression();
        }
        try self.expect(.semicolon);

        // Parse update
        var update_node: NodeIndex = null_node;
        if (!self.check(.rparen)) {
            update_node = try self.parseExpression();
        }
        try self.expect(.rparen);

        const body = try self.parseStatement();
        return self.ast.addNode(self.allocator, .{ .for_stmt = .{
            .init_ = init_node,
            .test_ = test_node,
            .update = update_node,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseVarDeclNoSemicolon(self: *Parser) ParseError!NodeIndex {
        const kind: ast_mod.VarDecl.Kind = switch (self.current.type) {
            .kw_var => .@"var",
            .kw_let => .let,
            .kw_const => .@"const",
            else => return error.UnexpectedToken,
        };
        self.advance();

        var declarators = std.ArrayListUnmanaged(NodeIndex){};
        defer declarators.deinit(self.allocator);

        while (true) {
            const name = try self.parseIdentifier();
            var init_val: NodeIndex = null_node;
            if (self.match(.eq) or self.match(.assign)) {
                init_val = try self.parsePrecedence(.assignment);
            }
            const decl = self.ast.addNode(self.allocator, .{ .var_declarator = .{
                .name = name,
                .init_ = init_val,
            } }) catch return error.OutOfMemory;
            declarators.append(self.allocator, decl) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }

        const list = self.ast.addNodeList(self.allocator, declarators.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .var_decl = .{
            .kind = kind,
            .declarators = list,
        } }) catch return error.OutOfMemory;
    }

    fn parseForIn(self: *Parser, left: NodeIndex) ParseError!NodeIndex {
        // 'in' already consumed
        const right = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseStatement();
        return self.ast.addNode(self.allocator, .{ .for_in_stmt = .{
            .left = left,
            .right = right,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseSwitchStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'switch'
        try self.expect(.lparen);
        const discriminant = try self.parseExpression();
        try self.expect(.rparen);
        try self.expect(.lbrace);

        var cases = std.ArrayListUnmanaged(NodeIndex){};
        defer cases.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            var test_node: NodeIndex = null_node;
            if (self.match(.kw_case)) {
                test_node = try self.parseExpression();
            } else if (self.match(.kw_default)) {
                test_node = null_node;
            } else {
                return error.UnexpectedToken;
            }
            try self.expect(.colon);

            var body_stmts = std.ArrayListUnmanaged(NodeIndex){};
            defer body_stmts.deinit(self.allocator);
            while (!self.check(.kw_case) and !self.check(.kw_default) and !self.check(.rbrace) and !self.check(.eof)) {
                const stmt = try self.parseStatement();
                body_stmts.append(self.allocator, stmt) catch return error.OutOfMemory;
            }
            const body_list = self.ast.addNodeList(self.allocator, body_stmts.items) catch return error.OutOfMemory;
            const case_node = self.ast.addNode(self.allocator, .{ .switch_case = .{
                .test_ = test_node,
                .body = body_list,
            } }) catch return error.OutOfMemory;
            cases.append(self.allocator, case_node) catch return error.OutOfMemory;
        }
        try self.expect(.rbrace);

        const cases_list = self.ast.addNodeList(self.allocator, cases.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .switch_stmt = .{
            .discriminant = discriminant,
            .cases = cases_list,
        } }) catch return error.OutOfMemory;
    }

    fn parseTryStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'try'
        const block = try self.parseBlock();

        var handler: NodeIndex = null_node;
        var finalizer: NodeIndex = null_node;

        if (self.match(.kw_catch)) {
            var param: NodeIndex = null_node;
            if (self.match(.lparen)) {
                param = try self.parseIdentifier();
                try self.expect(.rparen);
            }
            const catch_body = try self.parseBlock();
            handler = self.ast.addNode(self.allocator, .{ .catch_clause = .{
                .param = param,
                .body = catch_body,
            } }) catch return error.OutOfMemory;
        }

        if (self.match(.kw_finally)) {
            finalizer = try self.parseBlock();
        }

        // At least one of catch/finally required
        if (handler == null_node and finalizer == null_node) {
            return error.UnexpectedToken;
        }

        return self.ast.addNode(self.allocator, .{ .try_stmt = .{
            .block = block,
            .handler = handler,
            .finalizer = finalizer,
        } }) catch return error.OutOfMemory;
    }

    fn parseReturnStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'return'
        var arg: NodeIndex = null_node;
        if (!self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof) and self.current.line == self.prev_line) {
            arg = try self.parseExpression();
        }
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .return_stmt = arg }) catch return error.OutOfMemory;
    }

    fn parseThrowStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'throw'
        const arg = try self.parseExpression();
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .throw_stmt = arg }) catch return error.OutOfMemory;
    }

    fn parseBreakStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'break'
        var label: ?StringId = null;
        if (self.current.type == .identifier and self.current.line == self.prev_line) {
            const text = self.tokenSlice(self.current);
            label = self.pool.intern(text) catch return error.OutOfMemory;
            self.advance();
        }
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .break_stmt = label }) catch return error.OutOfMemory;
    }

    fn parseContinueStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'continue'
        var label: ?StringId = null;
        if (self.current.type == .identifier and self.current.line == self.prev_line) {
            const text = self.tokenSlice(self.current);
            label = self.pool.intern(text) catch return error.OutOfMemory;
            self.advance();
        }
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .continue_stmt = label }) catch return error.OutOfMemory;
    }

    fn parseFunctionDecl(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'function'

        // Name (required for declarations)
        if (self.current.type != .identifier) return error.UnexpectedToken;
        const name_text = self.tokenSlice(self.current);
        const name = self.pool.intern(name_text) catch return error.OutOfMemory;
        self.advance();

        // Parameters
        try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(NodeIndex){};
        defer params.deinit(self.allocator);
        while (!self.check(.rparen) and !self.check(.eof)) {
            const param = try self.parseIdentifier();
            params.append(self.allocator, param) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);

        // Body
        const body = try self.parseBlock();

        const params_list = self.ast.addNodeList(self.allocator, params.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .function_decl = .{
            .name = name,
            .params = params_list,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseClassDecl(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'class'

        var name: ?StringId = null;
        if (self.current.type == .identifier) {
            const text = self.tokenSlice(self.current);
            name = self.pool.intern(text) catch return error.OutOfMemory;
            self.advance();
        }

        var super_class: NodeIndex = null_node;
        if (self.match(.kw_extends)) {
            super_class = try self.parseExpression();
        }

        // Class body - for now just skip balanced braces
        try self.expect(.lbrace);
        var depth: u32 = 1;
        while (depth > 0 and !self.check(.eof)) {
            if (self.check(.lbrace)) depth += 1;
            if (self.check(.rbrace)) depth -= 1;
            if (depth > 0) self.advance();
        }
        try self.expect(.rbrace);

        const empty_body = self.ast.addNodeList(self.allocator, &.{}) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .class_decl = .{
            .name = name,
            .super_class = super_class,
            .body = empty_body,
        } }) catch return error.OutOfMemory;
    }

    fn parseWithStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'with'
        try self.expect(.lparen);
        const object = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseStatement();
        return self.ast.addNode(self.allocator, .{ .with_stmt = .{
            .object = object,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    fn parseDebuggerStatement(self: *Parser) ParseError!NodeIndex {
        self.advance(); // consume 'debugger'
        try self.expectSemicolon();
        return self.ast.addNode(self.allocator, .{ .debugger_stmt = {} }) catch return error.OutOfMemory;
    }

    fn parseLabeledStatement(self: *Parser) ParseError!NodeIndex {
        const text = self.tokenSlice(self.current);
        const label = self.pool.intern(text) catch return error.OutOfMemory;
        self.advance(); // consume identifier
        self.advance(); // consume colon
        const body = try self.parseStatement();
        return self.ast.addNode(self.allocator, .{ .labeled_stmt = .{
            .label = label,
            .body = body,
        } }) catch return error.OutOfMemory;
    }

    // ---------------------------------------------------------------
    // Infix (led)
    // ---------------------------------------------------------------

    fn infixPrecedence(tt: TokenType) Precedence {
        return switch (tt) {
            .comma => .comma,

            // Assignment operators
            .assign, .eq,
            .plus_assign, .plus_eq,
            .minus_assign, .minus_eq,
            .star_assign, .star_eq,
            .slash_eq,
            .percent_eq,
            .star_star_eq,
            .amp_eq,
            .pipe_eq,
            .caret_eq,
            .lt_lt_eq,
            .gt_gt_eq,
            .gt_gt_gt_eq,
            .amp_amp_eq, .amp_amp_assign,
            .pipe_pipe_eq,
            => .assignment,

            .question => .ternary,
            .nullish, .question_question => .nullish_,
            .pipe_pipe => .logical_or,
            .amp_amp => .logical_and,
            .pipe => .bitwise_or,
            .caret => .bitwise_xor,
            .amp => .bitwise_and,
            .eq_eq, .bang_eq, .eq_eq_eq, .ne_eq, .bang_eq_eq => .equality,
            .lt, .gt, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => .comparison,
            .lt_lt, .gt_gt, .gt_gt_gt => .shift,
            .plus, .minus => .additive,
            .star, .slash, .percent => .multiplicative,
            .star_star => .exponentiation,
            .plus_plus, .minus_minus => .postfix,
            .lparen => .call_,
            .dot, .optional_chain, .question_dot => .member_,
            .lbracket => .member_,
            else => .none,
        };
    }

    fn isRightAssociative(tt: TokenType) bool {
        return switch (tt) {
            .assign, .eq,
            .plus_assign, .plus_eq,
            .minus_assign, .minus_eq,
            .star_assign, .star_eq,
            .slash_eq,
            .percent_eq,
            .star_star_eq,
            .amp_eq,
            .pipe_eq,
            .caret_eq,
            .lt_lt_eq,
            .gt_gt_eq,
            .gt_gt_gt_eq,
            .amp_amp_eq, .amp_amp_assign,
            .pipe_pipe_eq,
            .star_star,
            => true,
            else => false,
        };
    }

    fn isAssignmentOp(tt: TokenType) bool {
        return switch (tt) {
            .assign, .eq,
            .plus_assign, .plus_eq,
            .minus_assign, .minus_eq,
            .star_assign, .star_eq,
            .slash_eq,
            .percent_eq,
            .star_star_eq,
            .amp_eq,
            .pipe_eq,
            .caret_eq,
            .lt_lt_eq,
            .gt_gt_eq,
            .gt_gt_gt_eq,
            .amp_amp_eq, .amp_amp_assign,
            .pipe_pipe_eq,
            => true,
            else => false,
        };
    }

    fn parseInfix(self: *Parser, lhs: NodeIndex, prec: Precedence) ParseError!NodeIndex {
        const tt = self.current.type;

        // Postfix ++ / --
        if (tt == .plus_plus or tt == .minus_minus) {
            const op: UnaryOp = if (tt == .plus_plus) .post_inc else .post_dec;
            self.advance();
            return self.ast.addNode(self.allocator, .{ .update = .{
                .operand = lhs,
                .op = op,
            } }) catch return error.OutOfMemory;
        }

        // Call expression
        if (tt == .lparen) {
            return self.parseCall(lhs);
        }

        // Member access
        if (tt == .dot or tt == .optional_chain or tt == .question_dot) {
            return self.parseMember(lhs);
        }

        // Computed member
        if (tt == .lbracket) {
            return self.parseComputedMember(lhs);
        }

        // Ternary
        if (tt == .question) {
            return self.parseTernary(lhs);
        }

        // Assignment
        if (isAssignmentOp(tt)) {
            return self.parseAssignment(lhs, tt);
        }

        // Binary operator
        return self.parseBinary(lhs, tt, prec);
    }

    fn parseBinary(self: *Parser, lhs: NodeIndex, tt: TokenType, prec: Precedence) ParseError!NodeIndex {
        const op = tokenToBinaryOp(tt);
        self.advance();
        const next_prec: Precedence = if (isRightAssociative(tt))
            @enumFromInt(@intFromEnum(prec))
        else
            @enumFromInt(@intFromEnum(prec) + 1);

        const rhs = try self.parsePrecedence(next_prec);
        return self.ast.addNode(self.allocator, .{ .binary = .{
            .lhs = lhs,
            .rhs = rhs,
            .op = op,
        } }) catch return error.OutOfMemory;
    }

    fn parseAssignment(self: *Parser, lhs: NodeIndex, tt: TokenType) ParseError!NodeIndex {
        const op = tokenToBinaryOp(tt);
        self.advance();
        const rhs = try self.parsePrecedence(.assignment);
        return self.ast.addNode(self.allocator, .{ .assignment = .{
            .lhs = lhs,
            .rhs = rhs,
            .op = op,
        } }) catch return error.OutOfMemory;
    }

    fn parseTernary(self: *Parser, condition: NodeIndex) ParseError!NodeIndex {
        self.advance(); // consume ?
        const consequent = try self.parsePrecedence(.assignment);
        try self.expect(.colon);
        const alternate = try self.parsePrecedence(.assignment);
        return self.ast.addNode(self.allocator, .{ .conditional = .{
            .test_ = condition,
            .consequent = consequent,
            .alternate = alternate,
        } }) catch return error.OutOfMemory;
    }

    fn parseCall(self: *Parser, callee: NodeIndex) ParseError!NodeIndex {
        self.advance(); // consume (
        var args = std.ArrayListUnmanaged(NodeIndex){};
        defer args.deinit(self.allocator);
        while (!self.check(.rparen) and !self.check(.eof)) {
            const arg = try self.parsePrecedence(.assignment);
            args.append(self.allocator, arg) catch return error.OutOfMemory;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        const args_list = self.ast.addNodeList(self.allocator, args.items) catch return error.OutOfMemory;
        return self.ast.addNode(self.allocator, .{ .call = .{
            .callee = callee,
            .args = args_list,
        } }) catch return error.OutOfMemory;
    }

    fn parseMember(self: *Parser, object: NodeIndex) ParseError!NodeIndex {
        self.advance(); // consume . or ?.
        if (self.current.type != .identifier and !isKeyword(self.current.type)) {
            return error.UnexpectedToken;
        }
        const text = self.tokenSlice(self.current);
        const sid = self.pool.intern(text) catch return error.OutOfMemory;
        self.advance();
        return self.ast.addNode(self.allocator, .{ .member = .{
            .object = object,
            .property = sid,
        } }) catch return error.OutOfMemory;
    }

    fn parseComputedMember(self: *Parser, object: NodeIndex) ParseError!NodeIndex {
        self.advance(); // consume [
        const prop = try self.parsePrecedence(.assignment);
        try self.expect(.rbracket);
        return self.ast.addNode(self.allocator, .{ .computed_member = .{
            .object = object,
            .property = prop,
        } }) catch return error.OutOfMemory;
    }

    fn tokenToBinaryOp(tt: TokenType) BinaryOp {
        return switch (tt) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .star_star => .power,
            .eq_eq => .eq,
            .bang_eq => .ne,
            .eq_eq_eq => .strict_eq,
            .ne_eq, .bang_eq_eq => .strict_ne,
            .lt => .lt,
            .gt => .gt,
            .lt_eq => .le,
            .gt_eq => .ge,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .lt_lt => .shl,
            .gt_gt => .shr,
            .gt_gt_gt => .ushr,
            .amp_amp => .logical_and,
            .pipe_pipe => .logical_or,
            .nullish, .question_question => .nullish,
            .kw_instanceof => .instanceof,
            .kw_in => .in_,
            .assign, .eq => .assign,
            .plus_assign, .plus_eq => .add_assign,
            .minus_assign, .minus_eq => .sub_assign,
            .star_assign, .star_eq => .mul_assign,
            .slash_eq => .div_assign,
            .percent_eq => .mod_assign,
            .star_star_eq => .power_assign,
            .amp_eq => .bit_and_assign,
            .pipe_eq => .bit_or_assign,
            .caret_eq => .bit_xor_assign,
            .lt_lt_eq => .shl_assign,
            .gt_gt_eq => .shr_assign,
            .gt_gt_gt_eq => .ushr_assign,
            .amp_amp_eq, .amp_amp_assign => .logical_and_assign,
            .pipe_pipe_eq => .logical_or_assign,
            .comma => .comma,
            else => .add, // fallback, should not happen
        };
    }
};
