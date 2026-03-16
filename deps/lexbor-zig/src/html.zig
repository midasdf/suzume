pub const document = @import("html/document.zig");
pub const Document = document.Document;

pub const token = @import("html/token.zig");
pub const Token = token.Token;
// pub const TypeType = token.TypeType;
// pub const Type = token.Type;

pub const tokenizer = @import("html/tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;

pub const encoding = @import("html/encoding.zig");
pub const Entry = encoding.Entry;
pub const Encoding = encoding.Encoding;

pub const parser = @import("html/parser.zig");
pub const parse = parser.parse;

pub const tag = @import("html/tag.zig");

pub const serialize = @import("html/serialize.zig");
pub const interface = @import("html/interface.zig");
pub const token_attr = @import("html/token_attr.zig");

pub const element = @import("html/interfaces/element.zig");
