const std = @import("std");
const StringId = @import("string_pool.zig").StringId;

pub const NodeIndex = u32;
pub const null_node: NodeIndex = std.math.maxInt(NodeIndex);

pub const NodeList = struct {
    start: u32,
    len: u32,
};

pub const BinaryOp = enum(u8) {
    add, sub, mul, div, mod, power,
    eq, ne, strict_eq, strict_ne, lt, le, gt, ge,
    bit_and, bit_or, bit_xor, shl, shr, ushr,
    logical_and, logical_or, nullish,
    instanceof, in_,
    assign, add_assign, sub_assign, mul_assign, div_assign, mod_assign,
    power_assign, bit_and_assign, bit_or_assign, bit_xor_assign,
    shl_assign, shr_assign, ushr_assign,
    logical_and_assign, logical_or_assign, nullish_assign,
    comma,
};

pub const UnaryOp = enum(u8) {
    neg, pos, not, bit_not, typeof_, void_, delete_,
    pre_inc, pre_dec, post_inc, post_dec,
};

pub const Node = union(enum) {
    // Program
    program: NodeList,

    // Literals
    number_literal: f64,
    string_literal: StringId,
    bool_literal: bool,
    null_literal,
    array_literal: NodeList,
    object_literal: NodeList,
    property: Property,
    template_literal: NodeList,
    regex_literal: struct { pattern: StringId, flags: StringId },

    // Expressions
    identifier: StringId,
    this,
    assignment: struct { lhs: NodeIndex, rhs: NodeIndex, op: BinaryOp },
    binary: struct { lhs: NodeIndex, rhs: NodeIndex, op: BinaryOp },
    unary: struct { operand: NodeIndex, op: UnaryOp },
    update: struct { operand: NodeIndex, op: UnaryOp },
    conditional: struct { test_: NodeIndex, consequent: NodeIndex, alternate: NodeIndex },
    call: struct { callee: NodeIndex, args: NodeList },
    new_expr: struct { callee: NodeIndex, args: NodeList },
    member: struct { object: NodeIndex, property: StringId },
    computed_member: struct { object: NodeIndex, property: NodeIndex },
    sequence: NodeList,
    spread: NodeIndex,
    arrow_function: Function,
    yield_expr: struct { argument: NodeIndex, delegate: bool },
    await_expr: NodeIndex,
    function_expr: Function,

    // Statements
    block: NodeList,
    empty_statement,
    expression_stmt: NodeIndex,
    if_stmt: struct { test_: NodeIndex, consequent: NodeIndex, alternate: NodeIndex },
    while_stmt: struct { test_: NodeIndex, body: NodeIndex },
    do_while_stmt: struct { test_: NodeIndex, body: NodeIndex },
    for_stmt: struct { init_: NodeIndex, test_: NodeIndex, update: NodeIndex, body: NodeIndex },
    for_in_stmt: struct { left: NodeIndex, right: NodeIndex, body: NodeIndex },
    for_of_stmt: struct { left: NodeIndex, right: NodeIndex, body: NodeIndex },
    switch_stmt: struct { discriminant: NodeIndex, cases: NodeList },
    switch_case: struct { test_: NodeIndex, body: NodeList },
    return_stmt: NodeIndex,
    throw_stmt: NodeIndex,
    try_stmt: struct { block: NodeIndex, handler: NodeIndex, finalizer: NodeIndex },
    catch_clause: struct { param: NodeIndex, body: NodeIndex },
    break_stmt: ?StringId,
    continue_stmt: ?StringId,
    labeled_stmt: struct { label: StringId, body: NodeIndex },
    with_stmt: struct { object: NodeIndex, body: NodeIndex },
    debugger_stmt,

    // Declarations
    var_decl: VarDecl,
    var_declarator: struct { name: NodeIndex, init_: NodeIndex },
    function_decl: Function,
    class_decl: Class,

    // Patterns
    array_pattern: NodeList,
    object_pattern: NodeList,
    assign_pattern: struct { left: NodeIndex, right: NodeIndex },
    rest_element: NodeIndex,
};

pub const Property = struct {
    key: NodeIndex,
    value: NodeIndex,
    kind: enum { init, get, set },
    computed: bool = false,
    shorthand: bool = false,
    method: bool = false,
    is_static: bool = false,
};

pub const VarDecl = struct {
    kind: Kind,
    declarators: NodeList,
    pub const Kind = enum { @"var", let, @"const" };
};

pub const Function = struct {
    name: ?StringId = null,
    params: NodeList,
    body: NodeIndex,
    is_async: bool = false,
    is_generator: bool = false,
    is_expression: bool = false,
};

pub const Class = struct {
    name: ?StringId = null,
    super_class: NodeIndex = null_node,
    body: NodeList,
};

pub const Ast = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    extra: std.ArrayListUnmanaged(NodeIndex) = .empty,

    pub fn addNode(self: *Ast, allocator: std.mem.Allocator, node: Node) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return idx;
    }

    pub fn addNodeList(self: *Ast, allocator: std.mem.Allocator, items: []const NodeIndex) !NodeList {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, items);
        return .{ .start = start, .len = @intCast(items.len) };
    }

    pub fn getNodeList(self: *const Ast, list: NodeList) []const NodeIndex {
        return self.extra.items[list.start..][0..list.len];
    }

    pub fn getNode(self: *const Ast, idx: NodeIndex) Node {
        return self.nodes.items[idx];
    }

    pub fn deinit(self: *Ast, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.extra.deinit(allocator);
    }
};
