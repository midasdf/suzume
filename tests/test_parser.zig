const std = @import("std");
const css_engine = @import("css");
const Parser = css_engine.parser.Parser;
const ast = css_engine.ast;

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
    const css = "@supports (display: grid) { .grid { display: grid; } } div { color: red; }";
    var parser = Parser.init(css, std.testing.allocator);
    defer parser.deinit();
    const stylesheet = try parser.parse();
    // @supports is skipped, div rule is parsed.
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
