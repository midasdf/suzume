const std = @import("std");
const lexer_mod = @import("lexer.zig");
const ast_mod = @import("ast.zig");
const pool_mod = @import("string_pool.zig");

pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    ast: ast_mod.Ast,
    pool: pool_mod.StringPool,
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Parser {
        return .{
            .lexer = lexer_mod.Lexer.init(source),
            .ast = ast_mod.Ast.init(allocator),
            .pool = pool_mod.StringPool.init(allocator),
            .allocator = allocator,
        };
    }

    /// Parse source. Returns root NodeIndex (0 for now — stub).
    pub fn parse(self: *Parser) !ast_mod.NodeIndex {
        _ = self;
        return 0;
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        self.pool.deinit();
    }
};
