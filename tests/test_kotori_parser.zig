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

// ---------------------------------------------------------------
// ES Modules
// ---------------------------------------------------------------

test "import side-effect" {
    var p = Parser.init(std.testing.allocator, "import \"./module.js\";");
    defer p.deinit();
    const idx = try p.parse();
    const prog = p.ast.getNode(idx).program;
    const stmts = p.ast.getNodeList(prog);
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .import_decl);
    const decl = p.ast.getNode(stmts[0]).import_decl;
    try std.testing.expectEqual(@as(u32, 0), decl.specifiers.len);
    // source should be "./module.js" (without quotes)
    try std.testing.expectEqualStrings("./module.js", p.pool.get(decl.source).?);
}

test "import default" {
    var p = Parser.init(std.testing.allocator, "import foo from \"bar\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const decl = p.ast.getNode(stmts[0]).import_decl;
    try std.testing.expectEqualStrings("bar", p.pool.get(decl.source).?);
    const specs = p.ast.getNodeList(decl.specifiers);
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    const spec = p.ast.getNode(specs[0]).import_specifier;
    try std.testing.expect(spec.kind == .default_);
    try std.testing.expectEqualStrings("foo", p.pool.get(spec.local).?);
}

test "import named" {
    var p = Parser.init(std.testing.allocator, "import { a, b as c } from \"mod\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const decl = p.ast.getNode(stmts[0]).import_decl;
    const specs = p.ast.getNodeList(decl.specifiers);
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    const s0 = p.ast.getNode(specs[0]).import_specifier;
    try std.testing.expect(s0.kind == .named);
    try std.testing.expectEqualStrings("a", p.pool.get(s0.local).?);
    const s1 = p.ast.getNode(specs[1]).import_specifier;
    try std.testing.expectEqualStrings("c", p.pool.get(s1.local).?);
    try std.testing.expectEqualStrings("b", p.pool.get(s1.imported.?).?);
}

test "import namespace" {
    var p = Parser.init(std.testing.allocator, "import * as ns from \"mod\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const decl = p.ast.getNode(stmts[0]).import_decl;
    const specs = p.ast.getNodeList(decl.specifiers);
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    const spec = p.ast.getNode(specs[0]).import_specifier;
    try std.testing.expect(spec.kind == .namespace);
    try std.testing.expectEqualStrings("ns", p.pool.get(spec.local).?);
}

test "import default and named" {
    var p = Parser.init(std.testing.allocator, "import React, { useState } from \"react\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const decl = p.ast.getNode(stmts[0]).import_decl;
    const specs = p.ast.getNodeList(decl.specifiers);
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expect(p.ast.getNode(specs[0]).import_specifier.kind == .default_);
    try std.testing.expect(p.ast.getNode(specs[1]).import_specifier.kind == .named);
}

test "export default expression" {
    var p = Parser.init(std.testing.allocator, "export default 42;");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .export_default);
    const inner = p.ast.getNode(p.ast.getNode(stmts[0]).export_default);
    try std.testing.expect(inner == .number_literal);
}

test "export const declaration" {
    var p = Parser.init(std.testing.allocator, "export const x = 1;");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .export_decl);
    const inner = p.ast.getNode(p.ast.getNode(stmts[0]).export_decl);
    try std.testing.expect(inner == .var_decl);
}

test "export function declaration" {
    var p = Parser.init(std.testing.allocator, "export function hello() {}");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .export_decl);
    const inner = p.ast.getNode(p.ast.getNode(stmts[0]).export_decl);
    try std.testing.expect(inner == .function_decl);
}

test "export named" {
    var p = Parser.init(std.testing.allocator, "export { a, b as c };");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .export_named);
    const decl = p.ast.getNode(stmts[0]).export_named;
    try std.testing.expect(decl.source == null);
    const specs = p.ast.getNodeList(decl.specifiers);
    try std.testing.expectEqual(@as(usize, 2), specs.len);
}

test "export all re-export" {
    var p = Parser.init(std.testing.allocator, "export * from \"utils\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .export_all);
    const ea = p.ast.getNode(stmts[0]).export_all;
    try std.testing.expectEqualStrings("utils", p.pool.get(ea.source).?);
    try std.testing.expect(ea.alias == null);
}

test "export all with alias" {
    var p = Parser.init(std.testing.allocator, "export * as helpers from \"utils\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const ea = p.ast.getNode(stmts[0]).export_all;
    try std.testing.expectEqualStrings("helpers", p.pool.get(ea.alias.?).?);
}

test "re-export named" {
    var p = Parser.init(std.testing.allocator, "export { foo, bar as baz } from \"lib\";");
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    const decl = p.ast.getNode(stmts[0]).export_named;
    try std.testing.expectEqualStrings("lib", p.pool.get(decl.source.?).?);
    try std.testing.expectEqual(@as(usize, 2), p.ast.getNodeList(decl.specifiers).len);
}

test "mixed module statements" {
    const source =
        \\import { a } from "mod";
        \\export const x = a;
        \\export default x;
    ;
    var p = Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const idx = try p.parse();
    const stmts = p.ast.getNodeList(p.ast.getNode(idx).program);
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expect(p.ast.getNode(stmts[0]) == .import_decl);
    try std.testing.expect(p.ast.getNode(stmts[1]) == .export_decl);
    try std.testing.expect(p.ast.getNode(stmts[2]) == .export_default);
}
