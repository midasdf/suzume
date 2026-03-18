const std = @import("std");
const css = @import("css");
const properties = css.properties;
const values = css.values;
const ast = css.ast;

// ── Color Parsing Tests ─────────────────────────────────────────────

test "parse hex color #RGB" {
    const c = properties.parseColor("#f0a").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 170), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parse hex color #RRGGBB" {
    const c = properties.parseColor("#ff8800").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 136), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parse hex color #RGBA" {
    const c = properties.parseColor("#f00a").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 170), c.a);
}

test "parse hex color #RRGGBBAA" {
    const c = properties.parseColor("#ff000080").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 128), c.a);
}

test "parse rgb() with commas" {
    const c = properties.parseColor("rgb(255, 128, 0)").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 128), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parse rgb() with spaces" {
    const c = properties.parseColor("rgb(100 200 50)").?;
    try std.testing.expectEqual(@as(u8, 100), c.r);
    try std.testing.expectEqual(@as(u8, 200), c.g);
    try std.testing.expectEqual(@as(u8, 50), c.b);
}

test "parse rgba()" {
    const c = properties.parseColor("rgba(255, 0, 0, 0.5)").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    // 0.5 * 255 = 127.5 → 127
    try std.testing.expectEqual(@as(u8, 127), c.a);
}

test "parse hsl()" {
    const c = properties.parseColor("hsl(0, 100%, 50%)").?;
    // Pure red
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parse hsla()" {
    const c = properties.parseColor("hsla(120, 100%, 50%, 0.5)").?;
    // Pure green
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 255), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    // 0.5 * 255 = 127.5 → 127
    try std.testing.expectEqual(@as(u8, 127), c.a);
}

test "parse named color: red" {
    const c = properties.parseColor("red").?;
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parse named color: transparent" {
    const c = properties.parseColor("transparent").?;
    try std.testing.expectEqual(@as(u8, 0), c.a);
}

test "parse named color case insensitive" {
    const c = properties.parseColor("Navy").?;
    try std.testing.expectEqual(@as(u8, 0), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);
    try std.testing.expectEqual(@as(u8, 128), c.b);
}

test "parse invalid color returns null" {
    try std.testing.expect(properties.parseColor("notacolor") == null);
    try std.testing.expect(properties.parseColor("#xyz") == null);
    try std.testing.expect(properties.parseColor("") == null);
}

// ── Length Parsing Tests ────────────────────────────────────────────

test "parse length: 10px" {
    const l = properties.parseLength("10px").?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.px, l.unit);
}

test "parse length: 2em" {
    const l = properties.parseLength("2em").?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.em, l.unit);
}

test "parse length: 1.5rem" {
    const l = properties.parseLength("1.5rem").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.rem, l.unit);
}

test "parse length: 50%" {
    const l = properties.parseLength("50%").?;
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.percent, l.unit);
}

test "parse length: 100vh" {
    const l = properties.parseLength("100vh").?;
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.vh, l.unit);
}

test "parse length: unitless zero" {
    const l = properties.parseLength("0").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.px, l.unit);
}

test "parse length: negative value" {
    const l = properties.parseLength("-5px").?;
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.px, l.unit);
}

test "parse length: decimal without leading zero" {
    const l = properties.parseLength(".5em").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), l.value, 0.001);
    try std.testing.expectEqual(values.Unit.em, l.unit);
}

test "parse length: invalid" {
    try std.testing.expect(properties.parseLength("abc") == null);
    try std.testing.expect(properties.parseLength("") == null);
}

// ── var() Parsing Tests ─────────────────────────────────────────────

test "parse var() simple" {
    const v = properties.parseVarRef("var(--main-color)").?;
    try std.testing.expectEqualStrings("--main-color", v.name);
    try std.testing.expect(v.fallback == null);
}

test "parse var() with fallback" {
    const v = properties.parseVarRef("var(--color, red)").?;
    try std.testing.expectEqualStrings("--color", v.name);
    try std.testing.expectEqualStrings("red", v.fallback.?);
}

test "parse var() with nested fallback" {
    const v = properties.parseVarRef("var(--a, var(--b, blue))").?;
    try std.testing.expectEqualStrings("--a", v.name);
    try std.testing.expectEqualStrings("var(--b, blue)", v.fallback.?);
}

test "parse var() invalid" {
    try std.testing.expect(properties.parseVarRef("notvar") == null);
    try std.testing.expect(properties.parseVarRef("var(color)") == null); // no --
    try std.testing.expect(properties.parseVarRef("var(") == null); // no closing
}

// ── Shorthand Expansion Tests ───────────────────────────────────────

test "expand margin: 1 value" {
    const decls = properties.expandShorthand("margin", "10px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("margin-top", decls[0].property_name);
    try std.testing.expectEqualStrings("10px", decls[0].value_raw);
    try std.testing.expectEqualStrings("margin-right", decls[1].property_name);
    try std.testing.expectEqualStrings("10px", decls[1].value_raw);
    try std.testing.expectEqualStrings("margin-bottom", decls[2].property_name);
    try std.testing.expectEqualStrings("10px", decls[2].value_raw);
    try std.testing.expectEqualStrings("margin-left", decls[3].property_name);
    try std.testing.expectEqualStrings("10px", decls[3].value_raw);
}

test "expand margin: 2 values" {
    const decls = properties.expandShorthand("margin", "10px 20px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("10px", decls[0].value_raw); // top
    try std.testing.expectEqualStrings("20px", decls[1].value_raw); // right
    try std.testing.expectEqualStrings("10px", decls[2].value_raw); // bottom
    try std.testing.expectEqualStrings("20px", decls[3].value_raw); // left
}

test "expand margin: 3 values" {
    const decls = properties.expandShorthand("margin", "10px 20px 30px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("10px", decls[0].value_raw); // top
    try std.testing.expectEqualStrings("20px", decls[1].value_raw); // right
    try std.testing.expectEqualStrings("30px", decls[2].value_raw); // bottom
    try std.testing.expectEqualStrings("20px", decls[3].value_raw); // left
}

test "expand margin: 4 values" {
    const decls = properties.expandShorthand("margin", "10px 20px 30px 40px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("10px", decls[0].value_raw); // top
    try std.testing.expectEqualStrings("20px", decls[1].value_raw); // right
    try std.testing.expectEqualStrings("30px", decls[2].value_raw); // bottom
    try std.testing.expectEqualStrings("40px", decls[3].value_raw); // left
}

test "expand padding: 1 value" {
    const decls = properties.expandShorthand("padding", "5px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqual(ast.PropertyId.padding_top, decls[0].property);
    try std.testing.expectEqualStrings("5px", decls[0].value_raw);
}

test "expand border" {
    const decls = properties.expandShorthand("border", "1px solid black", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 12), decls.len);
    // First side (top): width, style, color
    try std.testing.expectEqualStrings("border-top-width", decls[0].property_name);
    try std.testing.expectEqualStrings("1px", decls[0].value_raw);
    try std.testing.expectEqualStrings("border-top-style", decls[1].property_name);
    try std.testing.expectEqualStrings("solid", decls[1].value_raw);
    try std.testing.expectEqualStrings("border-top-color", decls[2].property_name);
    try std.testing.expectEqualStrings("black", decls[2].value_raw);
    // Fourth side (left) also gets same values
    try std.testing.expectEqualStrings("border-left-width", decls[9].property_name);
    try std.testing.expectEqualStrings("1px", decls[9].value_raw);
}

test "expand border-radius: 1 value" {
    const decls = properties.expandShorthand("border-radius", "5px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqual(ast.PropertyId.border_radius_top_left, decls[0].property);
    try std.testing.expectEqualStrings("5px", decls[0].value_raw);
    try std.testing.expectEqualStrings("5px", decls[3].value_raw);
}

test "expand border-radius: 4 values" {
    const decls = properties.expandShorthand("border-radius", "1px 2px 3px 4px", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("1px", decls[0].value_raw); // top-left
    try std.testing.expectEqualStrings("2px", decls[1].value_raw); // top-right
    try std.testing.expectEqualStrings("3px", decls[2].value_raw); // bottom-right
    try std.testing.expectEqualStrings("4px", decls[3].value_raw); // bottom-left
}

test "expand flex: single number" {
    const decls = properties.expandShorthand("flex", "1", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 3), decls.len);
    try std.testing.expectEqualStrings("flex-grow", decls[0].property_name);
    try std.testing.expectEqualStrings("1", decls[0].value_raw);
    try std.testing.expectEqualStrings("flex-shrink", decls[1].property_name);
    try std.testing.expectEqualStrings("1", decls[1].value_raw);
    try std.testing.expectEqualStrings("flex-basis", decls[2].property_name);
    try std.testing.expectEqualStrings("0%", decls[2].value_raw);
}

test "expand flex: three values" {
    const decls = properties.expandShorthand("flex", "1 0 auto", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 3), decls.len);
    try std.testing.expectEqualStrings("1", decls[0].value_raw);
    try std.testing.expectEqualStrings("0", decls[1].value_raw);
    try std.testing.expectEqualStrings("auto", decls[2].value_raw);
}

test "expand flex: none" {
    const decls = properties.expandShorthand("flex", "none", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 3), decls.len);
    try std.testing.expectEqualStrings("0", decls[0].value_raw);
    try std.testing.expectEqualStrings("0", decls[1].value_raw);
    try std.testing.expectEqualStrings("auto", decls[2].value_raw);
}

test "expand overflow: single value" {
    const decls = properties.expandShorthand("overflow", "hidden", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqual(ast.PropertyId.overflow_x, decls[0].property);
    try std.testing.expectEqualStrings("hidden", decls[0].value_raw);
    try std.testing.expectEqual(ast.PropertyId.overflow_y, decls[1].property);
    try std.testing.expectEqualStrings("hidden", decls[1].value_raw);
}

test "expand overflow: two values" {
    const decls = properties.expandShorthand("overflow", "hidden scroll", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("hidden", decls[0].value_raw);
    try std.testing.expectEqualStrings("scroll", decls[1].value_raw);
}

test "expand margin: inherit keyword" {
    const decls = properties.expandShorthand("margin", "inherit", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 4), decls.len);
    try std.testing.expectEqualStrings("inherit", decls[0].value_raw);
    try std.testing.expectEqualStrings("inherit", decls[1].value_raw);
    try std.testing.expectEqualStrings("inherit", decls[2].value_raw);
    try std.testing.expectEqualStrings("inherit", decls[3].value_raw);
}

test "expand background: color shorthand" {
    const decls = properties.expandShorthand("background", "#fff", std.testing.allocator).?;
    defer std.testing.allocator.free(decls);
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqual(ast.PropertyId.background_color, decls[0].property);
    try std.testing.expectEqualStrings("#fff", decls[0].value_raw);
}

test "expand unknown shorthand returns null" {
    try std.testing.expect(properties.expandShorthand("color", "red", std.testing.allocator) == null);
}

// ── parseValue Tests ────────────────────────────────────────────────

test "parseValue: color property with named color" {
    const v = properties.parseValue(.color, "red");
    switch (v) {
        .color => |c| {
            try std.testing.expectEqual(@as(u8, 255), c.r);
            try std.testing.expectEqual(@as(u8, 0), c.g);
            try std.testing.expectEqual(@as(u8, 0), c.b);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: length property" {
    const v = properties.parseValue(.width, "100px");
    switch (v) {
        .length => |l| {
            try std.testing.expectApproxEqAbs(@as(f32, 100.0), l.value, 0.001);
            try std.testing.expectEqual(values.Unit.px, l.unit);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: keyword property" {
    const v = properties.parseValue(.display, "flex");
    switch (v) {
        .keyword => |kw| try std.testing.expectEqual(values.Keyword.flex, kw),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: inherit keyword" {
    const v = properties.parseValue(.color, "inherit");
    switch (v) {
        .keyword => |kw| try std.testing.expectEqual(values.Keyword.inherit, kw),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: var reference" {
    const v = properties.parseValue(.color, "var(--main-color)");
    switch (v) {
        .var_ref => |vr| try std.testing.expectEqualStrings("--main-color", vr.name),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: numeric property" {
    const v = properties.parseValue(.opacity, "0.5");
    switch (v) {
        .number => |n| try std.testing.expectApproxEqAbs(@as(f32, 0.5), n, 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: auto keyword for width" {
    const v = properties.parseValue(.width, "auto");
    switch (v) {
        .keyword => |kw| try std.testing.expectEqual(values.Keyword.auto, kw),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: font-weight numeric" {
    const v = properties.parseValue(.font_weight, "700");
    switch (v) {
        .integer => |n| try std.testing.expectEqual(@as(i32, 700), n),
        else => return error.TestUnexpectedResult,
    }
}

test "parseValue: fallback to raw" {
    const v = properties.parseValue(.font_family, "Arial, sans-serif");
    switch (v) {
        .raw => |r| try std.testing.expectEqualStrings("Arial, sans-serif", r),
        else => return error.TestUnexpectedResult,
    }
}
