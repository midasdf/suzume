const std = @import("std");
const css = @import("css");
const parser_mod = css.parser;
const selectors = css.selectors;
const properties = css.properties;

test "parse large CSS without crash" {
    const alloc = std.testing.allocator;
    const file = try std.fs.cwd().openFile("/tmp/github-combined.css", .{});
    defer file.close();
    const css_text = try file.readToEndAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(css_text);

    std.debug.print("\nCSS size: {d} bytes\n", .{css_text.len});

    // Parse
    var p = parser_mod.Parser.init(css_text, alloc);
    defer p.deinit();
    const sheet = try p.parse();
    std.debug.print("Parsed {d} rules\n", .{sheet.rules.len});
    try std.testing.expect(sheet.rules.len > 100);

    // Count rules
    var style_count: usize = 0;
    for (sheet.rules) |rule| {
        if (rule == .style) style_count += 1;
    }
    std.debug.print("Style rules: {d}\n", .{style_count});
    try std.testing.expect(style_count > 50);

    // Flatten with media queries (viewport 720x720)
    std.debug.print("Flattening rules...\n", .{});
    var flat_rules: std.ArrayListUnmanaged(FlatRule) = .empty;
    defer flat_rules.deinit(alloc);
    try flattenRulesHelper(sheet.rules, 720, 720, &flat_rules, alloc);
    std.debug.print("Flat rules: {d}\n", .{flat_rules.items.len});

    // Parse selectors and build index
    std.debug.print("Building rule index...\n", .{});
    var selector_count: usize = 0;
    for (flat_rules.items) |rule| {
        for (rule.selectors) |sel| {
            const trimmed = std.mem.trim(u8, sel.source, " \t\r\n");
            if (selectors.parseSelector(trimmed, alloc)) |parsed| {
                selector_count += 1;
                alloc.free(parsed.components);
            }
        }
    }
    std.debug.print("Selectors parsed: {d}\n", .{selector_count});

    std.debug.print("Large CSS test PASSED\n", .{});
}

const FlatRule = struct {
    selectors: []const css.ast.Selector,
    declarations: []const css.ast.Declaration,
    source_order: u32,
};

fn flattenRulesHelper(
    rules: []const css.ast.Rule,
    vw: f32,
    vh: f32,
    out: *std.ArrayListUnmanaged(FlatRule),
    alloc: std.mem.Allocator,
) !void {
    for (rules) |rule| {
        switch (rule) {
            .style => |sr| {
                // Expand shorthands
                var expanded: std.ArrayListUnmanaged(css.ast.Declaration) = .empty;
                for (sr.declarations) |decl| {
                    if (properties.expandShorthand(decl.property_name, decl.value_raw, alloc)) |exp| {
                        for (exp) |*ed| {
                            ed.important = decl.important;
                        }
                        try expanded.appendSlice(alloc, exp);
                    } else {
                        try expanded.append(alloc, decl);
                    }
                }
                try out.append(alloc, .{
                    .selectors = sr.selectors,
                    .declarations = try expanded.toOwnedSlice(alloc),
                    .source_order = sr.source_order,
                });
            },
            .media => |mr| {
                if (css.media.evaluateMediaQuery(mr.query.raw, vw, vh)) {
                    try flattenRulesHelper(mr.rules, vw, vh, out, alloc);
                }
            },
            else => {},
        }
    }
}
