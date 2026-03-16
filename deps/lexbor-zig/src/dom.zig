pub const document = @import("dom/document.zig");
pub const interface = @import("dom/interface.zig");

pub const node = @import("dom/interfaces/node.zig");
pub const Node = node.Node;

pub const elements = @import("dom/interfaces/elements.zig");

pub const element = @import("dom/interfaces/element.zig");
pub const Element = element.Element;

pub const attr = @import("dom/interfaces/attr.zig");
pub const Attr = attr.Attr;

pub const collection = @import("dom/collection.zig");
pub const Collection = collection.Collection;
