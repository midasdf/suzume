const std = @import("std");
const selectors = @import("selectors");

const SimpleSelector = selectors.SimpleSelector;
const Combinator = selectors.Combinator;
const Specificity = selectors.Specificity;
const AttributeOp = selectors.AttributeOp;
const PseudoClass = selectors.PseudoClass;
const ElementAdapter = selectors.ElementAdapter;

// ── Parsing Tests ────────────────────────────────────────────────────

test "parse type selector" {
    const sel = selectors.parseSelector("div", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 0, .c = 1 }, sel.specificity);
}

test "parse class selector" {
    const sel = selectors.parseSelector(".foo", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    try std.testing.expectEqualStrings("foo", sel.components[0].simple.class);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 1, .c = 0 }, sel.specificity);
}

test "parse id selector" {
    const sel = selectors.parseSelector("#bar", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    try std.testing.expectEqualStrings("bar", sel.components[0].simple.id);
    try std.testing.expectEqual(Specificity{ .a = 1, .b = 0, .c = 0 }, sel.specificity);
}

test "parse universal" {
    const sel = selectors.parseSelector("*", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    try std.testing.expect(sel.components[0].simple == .universal);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 0, .c = 0 }, sel.specificity);
}

test "parse compound selector" {
    const sel = selectors.parseSelector("div.foo", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 2), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expectEqualStrings("foo", sel.components[1].simple.class);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 1, .c = 1 }, sel.specificity);
}

test "parse descendant combinator" {
    const sel = selectors.parseSelector("div p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expect(sel.components[1].combinator == .descendant);
    try std.testing.expectEqualStrings("p", sel.components[2].simple.type_sel);
}

test "parse child combinator" {
    const sel = selectors.parseSelector("div > p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expect(sel.components[1].combinator == .child);
    try std.testing.expectEqualStrings("p", sel.components[2].simple.type_sel);
}

test "parse next sibling combinator" {
    const sel = selectors.parseSelector("h1 + p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("h1", sel.components[0].simple.type_sel);
    try std.testing.expect(sel.components[1].combinator == .next_sibling);
    try std.testing.expectEqualStrings("p", sel.components[2].simple.type_sel);
}

test "parse subsequent sibling combinator" {
    const sel = selectors.parseSelector("h1 ~ p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("h1", sel.components[0].simple.type_sel);
    try std.testing.expect(sel.components[1].combinator == .subsequent_sibling);
    try std.testing.expectEqualStrings("p", sel.components[2].simple.type_sel);
}

test "parse attribute exists" {
    const sel = selectors.parseSelector("[href]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqualStrings("href", attr.name);
    try std.testing.expectEqual(AttributeOp.exists, attr.op);
}

test "parse attribute equals" {
    const sel = selectors.parseSelector("[type=\"text\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqualStrings("type", attr.name);
    try std.testing.expectEqual(AttributeOp.equals, attr.op);
    try std.testing.expectEqualStrings("text", attr.value);
}

test "parse attribute starts with" {
    const sel = selectors.parseSelector("[href^=\"https\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqualStrings("href", attr.name);
    try std.testing.expectEqual(AttributeOp.starts_with, attr.op);
    try std.testing.expectEqualStrings("https", attr.value);
}

test "parse attribute contains" {
    const sel = selectors.parseSelector("[class*=\"btn\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqual(AttributeOp.contains, attr.op);
    try std.testing.expectEqualStrings("btn", attr.value);
}

test "parse pseudo first-child" {
    const sel = selectors.parseSelector(":first-child", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 1), sel.components.len);
    try std.testing.expectEqual(PseudoClass.first_child, sel.components[0].simple.pseudo_class);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 1, .c = 0 }, sel.specificity);
}

test "parse pseudo last-child" {
    const sel = selectors.parseSelector(":last-child", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(PseudoClass.last_child, sel.components[0].simple.pseudo_class);
}

test "parse complex selector" {
    // .sidebar .nav a => [class("sidebar"), descendant, class("nav"), descendant, type("a")]
    const sel = selectors.parseSelector(".sidebar .nav a", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 5), sel.components.len);
    try std.testing.expectEqualStrings("sidebar", sel.components[0].simple.class);
    try std.testing.expect(sel.components[1].combinator == .descendant);
    try std.testing.expectEqualStrings("nav", sel.components[2].simple.class);
    try std.testing.expect(sel.components[3].combinator == .descendant);
    try std.testing.expectEqualStrings("a", sel.components[4].simple.type_sel);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 2, .c = 1 }, sel.specificity);
}

test "parse selector list" {
    const sels = selectors.parseSelectorList("h1, h2, h3", std.testing.allocator);
    defer {
        for (sels) |s| {
            std.testing.allocator.free(s.components);
        }
        std.testing.allocator.free(sels);
    }

    try std.testing.expectEqual(@as(usize, 3), sels.len);
    try std.testing.expectEqualStrings("h1", sels[0].components[0].simple.type_sel);
    try std.testing.expectEqualStrings("h2", sels[1].components[0].simple.type_sel);
    try std.testing.expectEqualStrings("h3", sels[2].components[0].simple.type_sel);
}

test "specificity ordering" {
    // id > class > type
    const id_spec = Specificity{ .a = 1, .b = 0, .c = 0 };
    const class_spec = Specificity{ .a = 0, .b = 1, .c = 0 };
    const type_spec = Specificity{ .a = 0, .b = 0, .c = 1 };

    try std.testing.expectEqual(std.math.Order.gt, Specificity.order(id_spec, class_spec));
    try std.testing.expectEqual(std.math.Order.gt, Specificity.order(class_spec, type_spec));
    try std.testing.expectEqual(std.math.Order.gt, Specificity.order(id_spec, type_spec));
    try std.testing.expectEqual(std.math.Order.eq, Specificity.order(id_spec, id_spec));
}

test "specificity toU32" {
    const spec = Specificity{ .a = 1, .b = 2, .c = 3 };
    try std.testing.expectEqual(@as(u32, (1 << 16) | (2 << 8) | 3), spec.toU32());
}

test "parse compound with id class and type" {
    // div#main.container => specificity (1,1,1)
    const sel = selectors.parseSelector("div#main.container", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expectEqualStrings("main", sel.components[1].simple.id);
    try std.testing.expectEqualStrings("container", sel.components[2].simple.class);
    try std.testing.expectEqual(Specificity{ .a = 1, .b = 1, .c = 1 }, sel.specificity);
}

test "parse multiple classes" {
    const sel = selectors.parseSelector(".foo.bar.baz", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqual(Specificity{ .a = 0, .b = 3, .c = 0 }, sel.specificity);
}

test "parse child combinator no spaces" {
    const sel = selectors.parseSelector("div>p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expectEqual(@as(usize, 3), sel.components.len);
    try std.testing.expectEqualStrings("div", sel.components[0].simple.type_sel);
    try std.testing.expect(sel.components[1].combinator == .child);
    try std.testing.expectEqualStrings("p", sel.components[2].simple.type_sel);
}

test "parse attribute contains word" {
    const sel = selectors.parseSelector("[class~=\"btn\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqual(AttributeOp.contains_word, attr.op);
}

test "parse attribute ends with" {
    const sel = selectors.parseSelector("[href$=\".pdf\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqual(AttributeOp.ends_with, attr.op);
    try std.testing.expectEqualStrings(".pdf", attr.value);
}

test "parse attribute starts with dash" {
    const sel = selectors.parseSelector("[lang|=\"en\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    const attr = sel.components[0].simple.attribute;
    try std.testing.expectEqual(AttributeOp.starts_with_dash, attr.op);
    try std.testing.expectEqualStrings("en", attr.value);
}

// ── Matching Tests (using mock elements) ─────────────────────────────

const MockElement = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    parent_el: ?*const MockElement = null,
    prev_sibling_el: ?*const MockElement = null,
    next_sibling_el: ?*const MockElement = null,
    first_child_el: ?*const MockElement = null,
    is_document: bool = false,

    const Attr = struct { name: []const u8, value: []const u8 };

    fn adapter(self: *const MockElement) ElementAdapter {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = ElementAdapter.VTable{
        .tagName = tagNameFn,
        .getAttribute = getAttributeFn,
        .parent = parentFn,
        .previousElementSibling = prevSibFn,
        .nextElementSibling = nextSibFn,
        .firstChild = firstChildFn,
        .isDocumentNode = isDocFn,
    };

    fn tagNameFn(ptr: *const anyopaque) ?[]const u8 {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        return self.tag;
    }

    fn getAttributeFn(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, name, "id")) return self.id;
        if (std.mem.eql(u8, name, "class")) return self.class;
        for (self.attrs) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }

    fn parentFn(ptr: *const anyopaque) ?ElementAdapter {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        const p = self.parent_el orelse return null;
        return p.adapter();
    }

    fn prevSibFn(ptr: *const anyopaque) ?ElementAdapter {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        const s = self.prev_sibling_el orelse return null;
        return s.adapter();
    }

    fn nextSibFn(ptr: *const anyopaque) ?ElementAdapter {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        const s = self.next_sibling_el orelse return null;
        return s.adapter();
    }

    fn firstChildFn(ptr: *const anyopaque) ?ElementAdapter {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        const c = self.first_child_el orelse return null;
        return c.adapter();
    }

    fn isDocFn(ptr: *const anyopaque) bool {
        const self: *const MockElement = @ptrCast(@alignCast(ptr));
        return self.is_document;
    }
};

test "match type selector" {
    const el = MockElement{ .tag = "div" };
    var sel = selectors.parseSelector("div", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match type selector case insensitive" {
    const el = MockElement{ .tag = "div" };
    var sel = selectors.parseSelector("DIV", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match type selector mismatch" {
    const el = MockElement{ .tag = "span" };
    var sel = selectors.parseSelector("div", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match class selector" {
    const el = MockElement{ .tag = "div", .class = "foo bar" };
    var sel = selectors.parseSelector(".foo", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match class selector second class" {
    const el = MockElement{ .tag = "div", .class = "foo bar" };
    var sel = selectors.parseSelector(".bar", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match class selector no match" {
    const el = MockElement{ .tag = "div", .class = "foo bar" };
    var sel = selectors.parseSelector(".baz", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match id selector" {
    const el = MockElement{ .tag = "div", .id = "main" };
    var sel = selectors.parseSelector("#main", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match id selector no match" {
    const el = MockElement{ .tag = "div", .id = "sidebar" };
    var sel = selectors.parseSelector("#main", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match universal selector" {
    const el = MockElement{ .tag = "anything" };
    var sel = selectors.parseSelector("*", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match compound selector" {
    const el = MockElement{ .tag = "div", .class = "container" };
    var sel = selectors.parseSelector("div.container", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match compound selector mismatch" {
    const el = MockElement{ .tag = "span", .class = "container" };
    var sel = selectors.parseSelector("div.container", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match child combinator" {
    const parent_el = MockElement{ .tag = "div" };
    const child_el = MockElement{ .tag = "p", .parent_el = &parent_el };

    var sel = selectors.parseSelector("div > p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, child_el.adapter()));
}

test "match child combinator wrong parent" {
    const parent_el = MockElement{ .tag = "span" };
    const child_el = MockElement{ .tag = "p", .parent_el = &parent_el };

    var sel = selectors.parseSelector("div > p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, child_el.adapter()));
}

test "match descendant combinator" {
    const grandparent = MockElement{ .tag = "div" };
    const parent_el = MockElement{ .tag = "section", .parent_el = &grandparent };
    const child_el = MockElement{ .tag = "p", .parent_el = &parent_el };

    var sel = selectors.parseSelector("div p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, child_el.adapter()));
}

test "match next sibling combinator" {
    const h1_el = MockElement{ .tag = "h1" };
    const p_el = MockElement{ .tag = "p", .prev_sibling_el = &h1_el };

    var sel = selectors.parseSelector("h1 + p", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, p_el.adapter()));
}

test "match attribute exists" {
    const el = MockElement{
        .tag = "a",
        .attrs = &.{.{ .name = "href", .value = "https://example.com" }},
    };
    var sel = selectors.parseSelector("[href]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match attribute equals" {
    const el = MockElement{
        .tag = "input",
        .attrs = &.{.{ .name = "type", .value = "text" }},
    };
    var sel = selectors.parseSelector("[type=\"text\"]", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match pseudo first-child" {
    // No previous sibling => is first child
    const el = MockElement{ .tag = "p" };
    var sel = selectors.parseSelector(":first-child", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match pseudo first-child fails" {
    const prev = MockElement{ .tag = "div" };
    const el = MockElement{ .tag = "p", .prev_sibling_el = &prev };
    var sel = selectors.parseSelector(":first-child", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match pseudo last-child" {
    // No next sibling => is last child
    const el = MockElement{ .tag = "p" };
    var sel = selectors.parseSelector(":last-child", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match pseudo empty" {
    const el = MockElement{ .tag = "div" };
    var sel = selectors.parseSelector(":empty", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}

test "match pseudo empty fails" {
    const child = MockElement{ .tag = "span" };
    const el = MockElement{ .tag = "div", .first_child_el = &child };
    var sel = selectors.parseSelector(":empty", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(!selectors.matches(&sel, el.adapter()));
}

test "match pseudo root" {
    const doc = MockElement{ .is_document = true };
    const el = MockElement{ .tag = "html", .parent_el = &doc };
    var sel = selectors.parseSelector(":root", std.testing.allocator) orelse
        return error.ParseFailed;
    defer std.testing.allocator.free(sel.components);

    try std.testing.expect(selectors.matches(&sel, el.adapter()));
}
