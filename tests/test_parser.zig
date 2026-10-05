const std = @import("std");
const css_engine = @import("css");
const ast = css_engine.ast;

// Match production ownership: Parser borrows an arena; its deinit is a no-op.
// Keep the arena at a stable address while the returned AST is inspected.
const Parser = struct {
    arena: *std.heap.ArenaAllocator,
    inner: css_engine.parser.Parser,

    fn init(source: []const u8, allocator: std.mem.Allocator) @This() {
        const arena = allocator.create(std.heap.ArenaAllocator) catch @panic("test arena allocation failed");
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{ .arena = arena, .inner = css_engine.parser.Parser.init(source, arena.allocator()) };
    }

    fn parse(self: *@This()) !ast.Stylesheet {
        return self.inner.parse();
    }

    fn deinit(self: *@This()) void {
        self.inner.deinit();
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

test "parse simple rule" {
    const css = "div { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.selectors.len);
    try std.testing.expectEqualStrings("div", std.mem.trim(u8, rule.selectors[0].source, " \t\r\n"));
    try std.testing.expectEqual(@as(usize, 1), rule.declarations.len);
    try std.testing.expectEqualStrings("color", rule.declarations[0].property_name);
    try std.testing.expectEqualStrings("red", rule.declarations[0].value_raw);
    try std.testing.expect(!rule.declarations[0].important);
}

test "parse multiple declarations" {
    const css = ".btn { color: red; margin: 10px; display: flex; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 3), rule.declarations.len);
    try std.testing.expectEqualStrings("color", rule.declarations[0].property_name);
    try std.testing.expectEqualStrings("margin", rule.declarations[1].property_name);
    try std.testing.expectEqualStrings("display", rule.declarations[2].property_name);
}

test "parse !important" {
    const css = "p { color: red !important; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.declarations.len);
    try std.testing.expect(rule.declarations[0].important);
    try std.testing.expectEqualStrings("red", rule.declarations[0].value_raw);
}

test "parse multiple selectors" {
    const css = "h1, h2, h3 { font-weight: bold; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 3), rule.selectors.len);
    try std.testing.expectEqualStrings("h1", rule.selectors[0].source);
    try std.testing.expectEqualStrings("h2", rule.selectors[1].source);
    try std.testing.expectEqualStrings("h3", rule.selectors[2].source);
}

test "parse @media" {
    const css = "@media (max-width: 768px) { .sidebar { display: none; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const media = stylesheet.rules[0].media;
    try std.testing.expectEqualStrings("(max-width: 768px)", media.query.raw);
    try std.testing.expectEqual(@as(usize, 1), media.rules.len);
    const inner_rule = media.rules[0].style;
    try std.testing.expectEqualStrings(".sidebar", std.mem.trim(u8, inner_rule.selectors[0].source, " \t\r\n"));
}

test "parse @keyframes" {
    const css = "@keyframes fade { from { opacity: 0; } to { opacity: 1; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const kf = stylesheet.rules[0].keyframes;
    try std.testing.expectEqualStrings("fade", kf.name);
    try std.testing.expectEqual(@as(usize, 2), kf.keyframes.len);
    try std.testing.expectEqualStrings("from", kf.keyframes[0].selector_raw);
    try std.testing.expectEqualStrings("to", kf.keyframes[1].selector_raw);
    try std.testing.expectEqual(@as(usize, 1), kf.keyframes[0].declarations.len);
    try std.testing.expectEqualStrings("opacity", kf.keyframes[0].declarations[0].property_name);
}

test "parse nested @media" {
    const css = "@media screen { @media (min-width: 1024px) { div { color: blue; } } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const outer = stylesheet.rules[0].media;
    try std.testing.expectEqualStrings("screen", outer.query.raw);
    try std.testing.expectEqual(@as(usize, 1), outer.rules.len);
    const inner = outer.rules[0].media;
    try std.testing.expectEqualStrings("(min-width: 1024px)", inner.query.raw);
    try std.testing.expectEqual(@as(usize, 1), inner.rules.len);
}

test "parse empty rule" {
    const css = "div { }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 0), rule.declarations.len);
}

test "parse multiple rules" {
    const css = "a { color: blue; } p { margin: 0; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    try std.testing.expectEqualStrings("color", stylesheet.rules[0].style.declarations[0].property_name);
    try std.testing.expectEqualStrings("margin", stylesheet.rules[1].style.declarations[0].property_name);
}

test "parse custom property declaration" {
    const css = ":root { --main-color: #ff0000; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.declarations.len);
    try std.testing.expectEqualStrings("--main-color", rule.declarations[0].property_name);
    try std.testing.expectEqual(ast.PropertyId.custom, rule.declarations[0].property);
    try std.testing.expectEqualStrings("#ff0000", rule.declarations[0].value_raw);
}

test "parse var() in value" {
    const css = ".box { color: var(--main-color); }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.declarations.len);
    try std.testing.expectEqualStrings("var(--main-color)", rule.declarations[0].value_raw);
}

test "parse complex value" {
    const css = ".box { border: 1px solid #000; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqualStrings("1px solid #000", rule.declarations[0].value_raw);
}

test "parse @font-face" {
    const css = "@font-face { font-family: 'MyFont'; src: url('font.woff2'); }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const ff = stylesheet.rules[0].font_face;
    try std.testing.expectEqual(@as(usize, 2), ff.declarations.len);
    try std.testing.expectEqualStrings("font-family", ff.declarations[0].property_name);
    try std.testing.expectEqualStrings("src", ff.declarations[1].property_name);
}

test "skip unknown at-rule" {
    const css = "@charset 'UTF-8'; div { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqualStrings("div", std.mem.trim(u8, rule.selectors[0].source, " \t\r\n"));
    try std.testing.expectEqualStrings("red", rule.declarations[0].value_raw);
}

test "error recovery: missing semicolon" {
    const css = "div { color: red margin: 10px; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    // Should recover and parse at least the first declaration.
    // The second one may or may not parse depending on recovery.
    const rule = stylesheet.rules[0].style;
    try std.testing.expect(rule.declarations.len >= 1);
}

test "real-world minified CSS" {
    const css = ".Nav__x{background-color:var(--bg);opacity:0;visibility:hidden}.foo{display:flex}";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    // First rule
    const r1 = stylesheet.rules[0].style;
    try std.testing.expectEqualStrings(".Nav__x", std.mem.trim(u8, r1.selectors[0].source, " \t\r\n"));
    try std.testing.expectEqual(@as(usize, 3), r1.declarations.len);
    // Second rule
    const r2 = stylesheet.rules[1].style;
    try std.testing.expectEqualStrings(".foo", std.mem.trim(u8, r2.selectors[0].source, " \t\r\n"));
    try std.testing.expectEqual(@as(usize, 1), r2.declarations.len);
}

test "property id mapping" {
    const css = "div { display: flex; z-index: 10; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(ast.PropertyId.display, rule.declarations[0].property);
    try std.testing.expectEqual(ast.PropertyId.z_index, rule.declarations[1].property);
}

test "unknown property" {
    const css = "div { -webkit-magic: 42; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(ast.PropertyId.unknown, rule.declarations[0].property);
    try std.testing.expectEqualStrings("-webkit-magic", rule.declarations[0].property_name);
}

test "source order increments" {
    const css = "a { } b { } c { }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), stylesheet.rules.len);
    try std.testing.expectEqual(@as(u32, 0), stylesheet.rules[0].style.source_order);
    try std.testing.expectEqual(@as(u32, 1), stylesheet.rules[1].style.source_order);
    try std.testing.expectEqual(@as(u32, 2), stylesheet.rules[2].style.source_order);
}

test "skip unknown at-rule with block" {
    const css = "@unknown (display: grid) { .grid { display: grid; } } div { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    // Unknown blocks are skipped; @supports is a supported rule type.
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    try std.testing.expectEqualStrings("div", std.mem.trim(u8, stylesheet.rules[0].style.selectors[0].source, " \t\r\n"));
}

test "complex selector" {
    const css = "div > p.class#id[attr=\"val\"]:hover { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    const rule = stylesheet.rules[0].style;
    try std.testing.expectEqual(@as(usize, 1), rule.selectors.len);
    // The selector source should contain the full selector text.
    const sel = rule.selectors[0].source;
    try std.testing.expect(std.mem.indexOf(u8, sel, "div") != null);
    try std.testing.expect(std.mem.indexOf(u8, sel, ":hover") != null);
}

test "important with no space" {
    const css = "p { color: red!important; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    const rule = stylesheet.rules[0].style;
    try std.testing.expect(rule.declarations[0].important);
    try std.testing.expectEqualStrings("red", rule.declarations[0].value_raw);
}

test "empty stylesheet" {
    const css = "   \n\t  ";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), stylesheet.rules.len);
}

// ---------------------------------------------------------------
// CSS Nesting
// ---------------------------------------------------------------

test "nesting: & > child" {
    const css = ".parent { color: red; & > .child { color: green; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    // Should produce 2 rules: parent + nested
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    // First rule: .parent { color: red; }
    const parent_rule = stylesheet.rules[0].style;
    try std.testing.expect(std.mem.indexOf(u8, parent_rule.selectors[0].source, ".parent") != null);
    try std.testing.expectEqual(@as(usize, 1), parent_rule.declarations.len);
    // Second rule: nested → .parent > .child { color: green; }
    const nested_rule = stylesheet.rules[1].style;
    const nested_sel = nested_rule.selectors[0].source;
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".child") != null);
}

test "nesting: implicit descendant (no &)" {
    const css = ".parent { .child { color: blue; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    const nested_sel = stylesheet.rules[1].style.selectors[0].source;
    // Should be ".parent .child"
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".child") != null);
}

test "nesting: &.modifier" {
    const css = ".test { &.active { color: green; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    const nested_sel = stylesheet.rules[1].style.selectors[0].source;
    // Should be ".test.active"
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".test") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, ".active") != null);
}

test "nesting: & at end" {
    const css = "span > b { .wrapper & { color: red; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    const nested_sel = stylesheet.rules[1].style.selectors[0].source;
    // Should contain "span > b" replacing &
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, "span") != null);
}

test "nesting: double nesting (2 levels deep)" {
    const css = ".outer { & .middle { & .inner { color: red; } } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    // Should produce 3 rules: .outer, .outer .middle, .outer .middle .inner
    try std.testing.expectEqual(@as(usize, 3), stylesheet.rules.len);
    const inner_sel = stylesheet.rules[2].style.selectors[0].source;
    try std.testing.expect(std.mem.indexOf(u8, inner_sel, ".outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner_sel, ".middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, inner_sel, ".inner") != null);
}

test "nesting: :has() with nested &" {
    const css = "#outer:has(.test) { & #subject { color: red; } }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), stylesheet.rules.len);
    const nested_sel = stylesheet.rules[1].style.selectors[0].source;
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, "#outer:has(.test)") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_sel, "#subject") != null);
}

test "nesting: parent and descendants retain increasing cascade order" {
    var parser = Parser.init(".outer { color: red; & { color: blue; &.active { color: green; } } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), sheet.rules.len);
    for (sheet.rules, 0..) |rule, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), rule.style.source_order);
    }
}

test "nesting: declarations after children keep their later precedence" {
    var parser = Parser.init(".a { color: red; & { color: blue; } color: green; & { color: black; } color: white; }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 5), sheet.rules.len);
    const colors = [_][]const u8{ "red", "blue", "green", "black", "white" };
    for (sheet.rules, 0..) |rule, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), rule.style.source_order);
        try std.testing.expectEqualStrings(".a", rule.style.selectors[0].source);
        try std.testing.expectEqualStrings(colors[index], rule.style.declarations[0].value_raw);
    }
}

test "nesting: compound type and ID selectors are not declarations" {
    var parser = Parser.init(".parent { button.active { color: red; } button:hover { color: blue; } #child { color: green; } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), sheet.rules.len);
    const selectors = [_][]const u8{ ".parent button.active", ".parent button:hover", ".parent #child" };
    for (selectors, 0..) |selector, index| {
        try std.testing.expectEqualStrings(selector, sheet.rules[index + 1].style.selectors[0].source);
    }
}

test "nesting: each child inherits the entire parent selector list" {
    var parser = Parser.init(".a, #b { .child, &.active { color: red; } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), sheet.rules.len);
    const children = sheet.rules[1].style.selectors;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings(":is(.a, #b) .child", children[0].source);
    try std.testing.expectEqualStrings(":is(.a, #b).active", children[1].source);
    var parsed = css_engine.selectors.parseSelector(children[1].source, std.testing.allocator) orelse return error.ParseFailed;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(css_engine.selectors.Specificity{ .a = 1, .b = 1, .c = 0 }, parsed.specificity);
}

test "nesting: quoted ampersands are not nesting selectors" {
    var parser = Parser.init(".parent { [data-value='&'] { color: red; } &[data-value='&'] { color: blue; } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), sheet.rules.len);
    try std.testing.expectEqualStrings(".parent [data-value='&']", sheet.rules[1].style.selectors[0].source);
    try std.testing.expectEqualStrings(".parent[data-value='&']", sheet.rules[2].style.selectors[0].source);
}

test "selector lists preserve quoted brackets and escaped commas" {
    var parser = Parser.init("[data-value='] ,'], .a\\,b, :is(.c, .d) { color: red; }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    const selectors = sheet.rules[0].style.selectors;
    try std.testing.expectEqual(@as(usize, 3), selectors.len);
    try std.testing.expectEqualStrings("[data-value='] ,']", selectors[0].source);
    try std.testing.expectEqualStrings(".a\\,b", selectors[1].source);
    try std.testing.expectEqualStrings(":is(.c, .d)", selectors[2].source);
}

test "nesting: media rule lists retain nested style rules" {
    var parser = Parser.init("@media screen { .a { color: red; &.active { color: blue; } } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    const rules = sheet.rules[0].media.rules;
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings(".a.active", rules[1].style.selectors[0].source);
    try std.testing.expect(rules[0].style.source_order < rules[1].style.source_order);
}

test "nesting: conditional groups inherit selectors and bare declarations" {
    var parser = Parser.init(".a { @media screen { color: red; &.active { color: blue; } color: green; } color: black; } .unrelated { color: white; }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), sheet.rules.len);
    const rules = sheet.rules[1].media.rules;
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings(".a", rules[0].style.selectors[0].source);
    try std.testing.expectEqualStrings(".a.active", rules[1].style.selectors[0].source);
    try std.testing.expectEqualStrings(".a", rules[2].style.selectors[0].source);
    try std.testing.expectEqualStrings("green", rules[2].style.declarations[0].value_raw);
    try std.testing.expect(rules[2].style.source_order < sheet.rules[2].style.source_order);
    try std.testing.expectEqualStrings(".unrelated", sheet.rules[3].style.selectors[0].source);
}

test "nesting: inner conditional groups use the immediate parent" {
    var parser = Parser.init(".a { &.active { @media screen { color: red; & > span { color: blue; } } } }", std.testing.allocator);
    defer parser.deinit();
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), sheet.rules.len);
    const rules = sheet.rules[2].media.rules;
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings(".a.active", rules[0].style.selectors[0].source);
    try std.testing.expectEqualStrings(".a.active > span", rules[1].style.selectors[0].source);
}
