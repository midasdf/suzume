const std = @import("std");
const kotori = @import("kotori");
const Parser = kotori.Parser;
const Node = kotori.Node;

test "number literal" {
    var p = Parser.init(std.testing.allocator, "42");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .number_literal);
}

test "string literal" {
    var p = Parser.init(std.testing.allocator, "\"hello\"");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .string_literal);
}

test "binary add" {
    var p = Parser.init(std.testing.allocator, "1 + 2");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .binary);
}

test "operator precedence: mul before add" {
    var p = Parser.init(std.testing.allocator, "1 + 2 * 3");
    defer p.deinit();
    const idx = try p.parseExpression();
    const node = p.ast.getNode(idx);
    try std.testing.expect(node == .binary);
    // rhs should be binary (2*3)
    const rhs = p.ast.getNode(node.binary.rhs);
    try std.testing.expect(rhs == .binary);
}

test "parenthesized expression" {
    var p = Parser.init(std.testing.allocator, "(1 + 2) * 3");
    defer p.deinit();
    const idx = try p.parseExpression();
    const node = p.ast.getNode(idx);
    try std.testing.expect(node == .binary);
    // lhs should be binary (1+2)
    const lhs = p.ast.getNode(node.binary.lhs);
    try std.testing.expect(lhs == .binary);
}

test "member access" {
    var p = Parser.init(std.testing.allocator, "a.b.c");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .member);
}

test "call expression" {
    var p = Parser.init(std.testing.allocator, "foo(1, 2)");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .call);
}

test "unary not" {
    var p = Parser.init(std.testing.allocator, "!true");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .unary);
}

test "conditional ternary" {
    var p = Parser.init(std.testing.allocator, "a ? b : c");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .conditional);
}

test "assignment" {
    var p = Parser.init(std.testing.allocator, "x = 42");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .assignment);
}

test "computed member" {
    var p = Parser.init(std.testing.allocator, "a[0]");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .computed_member);
}

test "new expression" {
    var p = Parser.init(std.testing.allocator, "new Foo(1)");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .new_expr);
}

test "typeof" {
    var p = Parser.init(std.testing.allocator, "typeof x");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .unary);
}

test "logical operators" {
    var p = Parser.init(std.testing.allocator, "a && b || c");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .binary);
}

test "array literal" {
    var p = Parser.init(std.testing.allocator, "[1, 2, 3]");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .array_literal);
}

test "object literal" {
    var p = Parser.init(std.testing.allocator, "{a: 1, b: 2}");
    defer p.deinit();
    const idx = try p.parseExpression();
    try std.testing.expect(p.ast.getNode(idx) == .object_literal);
}

// ---------------------------------------------------------------
// Statement / declaration tests
// ---------------------------------------------------------------

test "var declaration" {
    var p = Parser.init(std.testing.allocator, "var x = 42;");
    defer p.deinit();
    const idx = try p.parse();
    try std.testing.expect(p.ast.getNode(idx) == .program);
}

test "if else" {
    var p = Parser.init(std.testing.allocator, "if (x) { y; } else { z; }");
    defer p.deinit();
    _ = try p.parse();
}

test "while loop" {
    var p = Parser.init(std.testing.allocator, "while (true) { break; }");
    defer p.deinit();
    _ = try p.parse();
}

test "for loop" {
    var p = Parser.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { x; }");
    defer p.deinit();
    _ = try p.parse();
}

test "function declaration" {
    var p = Parser.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer p.deinit();
    _ = try p.parse();
}

test "try catch finally" {
    var p = Parser.init(std.testing.allocator, "try { x; } catch (e) { y; } finally { z; }");
    defer p.deinit();
    _ = try p.parse();
}

test "switch" {
    var p = Parser.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1: a; break;
        \\  case 2: b; break;
        \\  default: c;
        \\}
    );
    defer p.deinit();
    _ = try p.parse();
}

test "let const" {
    var p = Parser.init(std.testing.allocator, "let x = 1; const y = 2;");
    defer p.deinit();
    _ = try p.parse();
}

test "arrow function statement" {
    var p = Parser.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer p.deinit();
    _ = try p.parse();
}

test "do while" {
    var p = Parser.init(std.testing.allocator, "do { x; } while (y);");
    defer p.deinit();
    _ = try p.parse();
}

test "for in" {
    var p = Parser.init(std.testing.allocator, "for (var k in obj) { x; }");
    defer p.deinit();
    _ = try p.parse();
}

test "labeled statement" {
    var p = Parser.init(std.testing.allocator, "outer: for (;;) { break outer; }");
    defer p.deinit();
    _ = try p.parse();
}

test "empty and expression statements" {
    var p = Parser.init(std.testing.allocator, "; foo(); bar;");
    defer p.deinit();
    _ = try p.parse();
}

test "throw statement" {
    var p = Parser.init(std.testing.allocator, "throw new Error('oops');");
    defer p.deinit();
    _ = try p.parse();
}

test "with statement" {
    var p = Parser.init(std.testing.allocator, "with (obj) { x; }");
    defer p.deinit();
    _ = try p.parse();
}

test "debugger statement" {
    var p = Parser.init(std.testing.allocator, "debugger;");
    defer p.deinit();
    _ = try p.parse();
}

test "parse jQuery-like module pattern" {
    const source =
        \\(function(global, factory) {
        \\  "use strict";
        \\  if (typeof module === "object") {
        \\    module.exports = factory(global, true);
        \\  } else {
        \\    factory(global);
        \\  }
        \\})(typeof window !== "undefined" ? window : this, function(window, noGlobal) {
        \\  var arr = [];
        \\  var document = window.document;
        \\  var getProto = Object.getPrototypeOf;
        \\  var slice = arr.slice;
        \\  var concat = arr.concat;
        \\  var push = arr.push;
        \\  var indexOf = arr.indexOf;
        \\  var class2type = {};
        \\  var toString = class2type.toString;
        \\  var hasOwn = class2type.hasOwnProperty;
        \\  var support = {};
        \\  function isFunction(obj) {
        \\    return typeof obj === "function" && typeof obj.nodeType !== "number";
        \\  }
        \\  function isWindow(obj) {
        \\    return obj !== null && obj === obj.window;
        \\  }
        \\  return {};
        \\});
    ;
    var p = Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const idx = try p.parse();
    try std.testing.expect(p.ast.getNode(idx) == .program);
}

test "parse class syntax" {
    const source =
        \\class Animal {
        \\  constructor(name) {
        \\    this.name = name;
        \\  }
        \\  speak() {
        \\    return this.name + " makes a noise.";
        \\  }
        \\}
        \\class Dog extends Animal {
        \\  speak() {
        \\    return this.name + " barks.";
        \\  }
        \\}
    ;
    var p = Parser.init(std.testing.allocator, source);
    defer p.deinit();
    _ = try p.parse();
}

test "parse modern JS patterns" {
    const source =
        \\const api = {
        \\  fetchData: function(url) {
        \\    try {
        \\      var response = fetch(url);
        \\      var data = response.json();
        \\      return data;
        \\    } catch (err) {
        \\      console.error(err);
        \\      return null;
        \\    }
        \\  }
        \\};
    ;
    var p = Parser.init(std.testing.allocator, source);
    defer p.deinit();
    _ = try p.parse();
}
