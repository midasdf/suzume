const std = @import("std");

pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

pub const Node = union(enum) {
    number_literal: f64,
    string_literal: u32, // StringId
    bool_literal: bool,
    null_literal: void,
    identifier: u32, // StringId
    program: struct { body_start: NodeIndex, body_len: u32 },
};

pub const Ast = struct {
    nodes: std.ArrayList(Node),

    pub fn init(allocator: std.mem.Allocator) Ast {
        return .{ .nodes = std.ArrayList(Node).init(allocator) };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit();
    }

    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(node);
        return idx;
    }

    pub fn getNode(self: *const Ast, idx: NodeIndex) Node {
        return self.nodes.items[idx];
    }
};
