// kotori JS engine — public API re-exports.
pub const token = @import("token.zig");
pub const TokenType = token.TokenType;
pub const Token = token.Token;
pub const lookupKeyword = token.lookupKeyword;

pub const lexer = @import("lexer.zig");
pub const Lexer = lexer.Lexer;

pub const ast = @import("ast.zig");
pub const Ast = ast.Ast;
pub const Node = ast.Node;
pub const NodeIndex = ast.NodeIndex;
pub const null_node = ast.null_node;
pub const NodeList = ast.NodeList;
pub const BinaryOp = ast.BinaryOp;
pub const UnaryOp = ast.UnaryOp;
pub const Property = ast.Property;
pub const VarDecl = ast.VarDecl;
pub const Function = ast.Function;
pub const Class = ast.Class;

pub const parser = @import("parser.zig");
pub const Parser = parser.Parser;

pub const value = @import("value.zig");
pub const JsValue = value.JsValue;

pub const string_pool = @import("string_pool.zig");
pub const StringPool = string_pool.StringPool;
pub const StringId = string_pool.StringId;

pub const bytecode = @import("bytecode.zig");
pub const OpCode = bytecode.OpCode;
pub const Bytecode = bytecode.Bytecode;
