const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");

// ── External Lexbor functions ────────────────────────────────────────
extern fn lxb_dom_element_get_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize, value_len: *usize) ?[*]const u8;
extern fn lxb_dom_element_local_name(element: *lxb.lxb_dom_element_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_element_has_attribute(element: *lxb.lxb_dom_element_t, qualified_name: [*]const u8, qn_len: usize) bool;
extern fn lxb_dom_node_last_child_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_prev_noi(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;

// ── element.matches(selector) ───────────────────────────────────────

pub fn elementMatchesSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (selector.len == 0) return false;
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;

    const sel = std.mem.trim(u8, selector, " \t\r\n");
    if (sel.len == 0) return false;

    // Handle comma-separated selector list (any match = true)
    var start: usize = 0;
    var depth: usize = 0;
    for (sel, 0..) |ch, i| {
        if (ch == '(' or ch == '[') depth += 1
        else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
        else if (ch == ',' and depth == 0) {
            if (matchSingleSelector(node, std.mem.trim(u8, sel[start..i], " \t"))) return true;
            start = i + 1;
        }
    }
    return matchSingleSelector(node, std.mem.trim(u8, sel[start..], " \t"));
}

/// Match a single (non-comma-separated) selector with combinator support
fn matchSingleSelector(node: *lxb.lxb_dom_node_t, sel: []const u8) bool {
    if (sel.len == 0) return false;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // Parse into parts with combinators
    var parts: [16]SelectorPart = undefined;
    const count = parseSelectorParts(sel, &parts);
    if (count == 0) return false;

    // Simple case: no combinators
    if (count == 1) return matchSingleSimple(elem, parts[0].selector);

    // Match right-to-left: last part must match current node
    if (!matchSingleSimple(elem, parts[count - 1].selector)) return false;

    // Walk backwards through parts, checking combinators
    var cur_node: ?*lxb.lxb_dom_node_t = node;
    var pi: usize = count - 1;
    while (pi > 0) {
        pi -= 1;
        const part = parts[pi];
        const combinator = parts[pi + 1].combinator;
        switch (combinator) {
            .descendant => {
                // Any ancestor must match
                var found = false;
                var anc: ?*lxb.lxb_dom_node_t = if (cur_node) |cn| cn.parent else null;
                while (anc) |a| {
                    if (a.*.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                        if (matchSingleSimple(@ptrCast(a), part.selector)) {
                            cur_node = a;
                            found = true;
                            break;
                        }
                    }
                    anc = a.*.parent;
                }
                if (!found) return false;
            },
            .child => {
                // Direct parent must match
                const par: ?*lxb.lxb_dom_node_t = if (cur_node) |cn| cn.parent else null;
                if (par == null) return false;
                if (par.?.*.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
                if (!matchSingleSimple(@ptrCast(par.?), part.selector)) return false;
                cur_node = par;
            },
            .adjacent_sibling => {
                // Previous element sibling must match
                const prev = prevElementSibling(cur_node orelse return false);
                if (prev == null) return false;
                if (!matchSingleSimple(@ptrCast(prev.?), part.selector)) return false;
                cur_node = prev;
            },
            .general_sibling => {
                // Any previous element sibling must match
                var sib = prevElementSibling(cur_node orelse return false);
                var found = false;
                while (sib) |s| {
                    if (matchSingleSimple(@ptrCast(s), part.selector)) {
                        cur_node = s;
                        found = true;
                        break;
                    }
                    sib = prevElementSibling(s);
                }
                if (!found) return false;
            },
        }
    }
    return true;
}

pub fn matchSingleSimple(elem: *lxb.lxb_dom_element_t, sel: []const u8) bool {
    if (sel.len == 0) return false;

    // Check for compound selector with pseudo-classes: "div:not(.x)", "span.foo:is(.bar)"
    // Split at first ':' that's not inside brackets/parens and match each part
    if (findPseudoStart(sel)) |pseudo_start| {
        if (pseudo_start > 0) {
            // Has a prefix before the pseudo: e.g. "div" in "div:not(.x)"
            if (!matchSingleSimple(elem, sel[0..pseudo_start])) return false;
            return matchSingleSimple(elem, sel[pseudo_start..]);
        }
    }

    // :not(inner) — negate inner match
    if (sel.len > 5 and std.ascii.eqlIgnoreCase(sel[0..5], ":not(") and sel[sel.len - 1] == ')') {
        return !elementMatchesSelector(@ptrCast(elem), sel[5 .. sel.len - 1]);
    }
    // :is(inner) / :where(inner) — OR of comma-separated
    if (sel.len > 4 and std.ascii.eqlIgnoreCase(sel[0..4], ":is(") and sel[sel.len - 1] == ')') {
        return elementMatchesSelector(@ptrCast(elem), sel[4 .. sel.len - 1]);
    }
    if (sel.len > 7 and std.ascii.eqlIgnoreCase(sel[0..7], ":where(") and sel[sel.len - 1] == ')') {
        return elementMatchesSelector(@ptrCast(elem), sel[7 .. sel.len - 1]);
    }
    // Other pseudo-classes
    if (sel[0] == ':') {
        // :first-child, :last-child, :only-child, :empty, :root, :enabled, :disabled, :checked
        if (std.ascii.eqlIgnoreCase(sel, ":first-child")) return isFirstChild(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":last-child")) return isLastChild(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":root")) return isRoot(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":scope")) return true; // :scope matches the context element
        if (std.ascii.eqlIgnoreCase(sel, ":empty")) {
            const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
            return node.first_child == null;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":enabled")) {
            return !lxb_dom_element_has_attribute(elem, "disabled", 8);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":disabled")) {
            return lxb_dom_element_has_attribute(elem, "disabled", 8);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":checked")) {
            return lxb_dom_element_has_attribute(elem, "checked", 7);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":required")) {
            return lxb_dom_element_has_attribute(elem, "required", 8);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":optional")) {
            return !lxb_dom_element_has_attribute(elem, "required", 8);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":only-child")) {
            return isFirstChild(@ptrCast(elem)) and isLastChild(@ptrCast(elem));
        }
        if (std.ascii.eqlIgnoreCase(sel, ":first-of-type")) return isFirstOfType(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":last-of-type")) return isLastOfType(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":only-of-type")) return isFirstOfType(@ptrCast(elem)) and isLastOfType(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":link")) {
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and (std.mem.eql(u8, name_ptr.?[0..name_len], "a") or std.mem.eql(u8, name_ptr.?[0..name_len], "area")))
                return lxb_dom_element_has_attribute(elem, "href", 4);
            return false;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":any-link")) {
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and (std.mem.eql(u8, name_ptr.?[0..name_len], "a") or std.mem.eql(u8, name_ptr.?[0..name_len], "area")))
                return lxb_dom_element_has_attribute(elem, "href", 4);
            return false;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":read-write")) return false;
        if (std.ascii.eqlIgnoreCase(sel, ":read-only")) return true;
        if (std.ascii.eqlIgnoreCase(sel, ":defined")) return true;
        // :nth-child(N) — basic support for simple numeric N
        if (sel.len > 11 and std.ascii.eqlIgnoreCase(sel[0..11], ":nth-child(") and sel[sel.len - 1] == ')') {
            const arg = std.mem.trim(u8, sel[11 .. sel.len - 1], " \t");
            if (std.ascii.eqlIgnoreCase(arg, "odd")) return (getNthIndex(@ptrCast(elem)) % 2) == 1;
            if (std.ascii.eqlIgnoreCase(arg, "even")) return (getNthIndex(@ptrCast(elem)) % 2) == 0;
            if (std.fmt.parseInt(u32, arg, 10)) |n| return getNthIndex(@ptrCast(elem)) == n
            else |_| {}
        }
        // :nth-last-child(N)
        if (sel.len > 16 and std.ascii.eqlIgnoreCase(sel[0..16], ":nth-last-child(") and sel[sel.len - 1] == ')') {
            const arg = std.mem.trim(u8, sel[16 .. sel.len - 1], " \t");
            if (std.fmt.parseInt(u32, arg, 10)) |n| return getNthLastIndex(@ptrCast(elem)) == n
            else |_| {}
        }
        // :dir(ltr) / :dir(rtl)
        if (sel.len > 5 and std.ascii.eqlIgnoreCase(sel[0..5], ":dir(") and sel[sel.len - 1] == ')') {
            const dir_arg = std.mem.trim(u8, sel[5 .. sel.len - 1], " \t");
            // Get element's directionality: check dir attribute up the tree
            const node_ptr: *lxb.lxb_dom_node_t = @ptrCast(elem);
            var cur: ?*lxb.lxb_dom_node_t = node_ptr;
            var resolved_dir: []const u8 = "ltr"; // default
            while (cur) |c| {
                if (c.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                    const el: *lxb.lxb_dom_element_t = @ptrCast(c);
                    var dir_len: usize = 0;
                    const dir_val = lxb_dom_element_get_attribute(el, "dir", 3, &dir_len);
                    if (dir_val != null and dir_len > 0) {
                        const dv = dir_val.?[0..dir_len];
                        if (std.ascii.eqlIgnoreCase(dv, "rtl")) { resolved_dir = "rtl"; break; }
                        if (std.ascii.eqlIgnoreCase(dv, "ltr")) { resolved_dir = "ltr"; break; }
                        break; // "auto" or other → default ltr
                    }
                }
                cur = c.parent;
            }
            return std.ascii.eqlIgnoreCase(dir_arg, resolved_dir);
        }
        // Unknown pseudo — return false (conservative)
        return false;
    }

    // Check for attribute selector embedded in compound: tag[attr], .class[attr], etc.
    if (sel[0] != '[') {
        // Find first '[' not inside parens
        var depth_b: u32 = 0;
        var bracket_pos: ?usize = null;
        for (sel, 0..) |ch, bi| {
            if (ch == '(') depth_b += 1
            else if (ch == ')' and depth_b > 0) depth_b -= 1
            else if (ch == '[' and depth_b == 0) { bracket_pos = bi; break; }
        }
        if (bracket_pos) |bp| {
            if (bp > 0) {
                // Match prefix (tag, .class, etc.) and attr part separately
                if (!matchSingleSimple(elem, sel[0..bp])) return false;
                return matchSingleSimple(elem, sel[bp..]);
            }
        }
    }

    // [attr] or [attr=value] etc.
    if (sel[0] == '[') {
        // May have multiple: [attr1][attr2]
        var pos: usize = 0;
        while (pos < sel.len and sel[pos] == '[') {
            const close = std.mem.indexOfScalarPos(u8, sel, pos + 1, ']') orelse return false;
            if (!matchAttributeSelector(elem, sel[pos + 1 .. close])) return false;
            pos = close + 1;
        }
        // If there's remaining text after ], it's a pseudo-class etc.
        if (pos < sel.len) return matchSingleSimple(elem, sel[pos..]);
        return true;
    }
    // #id
    if (sel[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        if (val != null and val_len == sel.len - 1) {
            return std.mem.eql(u8, val.?[0..val_len], sel[1..]);
        }
        return false;
    }
    // .class
    if (sel[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val != null and val_len > 0) {
            return api.classContains(val.?[0..val_len], sel[1..]);
        }
        return false;
    }
    // * (universal)
    if (sel.len == 1 and sel[0] == '*') return true;

    // Compound: tag.class or tag#id
    if (std.mem.indexOfScalar(u8, sel, '.')) |dot| {
        if (dot > 0) {
            // tag.class
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null or !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel[0..dot])) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
            if (val != null and val_len > 0) return api.classContains(val.?[0..val_len], sel[dot + 1 ..]);
            return false;
        }
    }
    if (std.mem.indexOfScalar(u8, sel, '#')) |hash| {
        if (hash > 0) {
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null or !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel[0..hash])) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
            if (val != null and val_len == sel.len - hash - 1) return std.mem.eql(u8, val.?[0..val_len], sel[hash + 1 ..]);
            return false;
        }
    }

    // Plain tagname
    var name_len: usize = 0;
    const name_ptr = lxb_dom_element_local_name(elem, &name_len);
    if (name_ptr != null) {
        return std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel);
    }
    return false;
}

pub fn findPseudoStart(sel: []const u8) ?usize {
    // Find ':' that's not inside [] or () — marks start of pseudo-class
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < sel.len) : (i += 1) {
        if (sel[i] == '(' or sel[i] == '[') depth += 1
        else if ((sel[i] == ')' or sel[i] == ']') and depth > 0) depth -= 1
        else if (sel[i] == ':' and depth == 0) return i;
    }
    return null;
}

pub fn isFirstChild(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return false;
    var child: ?*lxb.lxb_dom_node_t = parent.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            // Skip doctype nodes masquerading as elements (null local name)
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len > 0) {
                return @intFromPtr(ch) == @intFromPtr(node);
            }
        }
        child = ch.next;
    }
    return false;
}

pub fn isLastChild(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return false;
    var child = lxb_dom_node_last_child_noi(parent);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(ch);
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr != null and name_len > 0) {
                return @intFromPtr(ch) == @intFromPtr(node);
            }
        }
        child = lxb_dom_node_prev_noi(ch);
    }
    return false;
}

pub fn isRoot(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return false;
    return parent.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT;
}

pub fn isFirstOfType(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return false;
    var name_len: usize = 0;
    const name = lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name == null) return false;
    var child: ?*lxb.lxb_dom_node_t = parent.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var ch_len: usize = 0;
            const ch_name = lxb_dom_element_local_name(@ptrCast(ch), &ch_len);
            if (ch_name != null and ch_len == name_len and std.mem.eql(u8, ch_name.?[0..ch_len], name.?[0..name_len]))
                return @intFromPtr(ch) == @intFromPtr(node);
        }
        child = ch.next;
    }
    return false;
}

pub fn isLastOfType(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return false;
    var name_len: usize = 0;
    const name = lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name == null) return false;
    var child = lxb_dom_node_last_child_noi(parent);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var ch_len: usize = 0;
            const ch_name = lxb_dom_element_local_name(@ptrCast(ch), &ch_len);
            if (ch_name != null and ch_len == name_len and std.mem.eql(u8, ch_name.?[0..ch_len], name.?[0..name_len]))
                return @intFromPtr(ch) == @intFromPtr(node);
        }
        child = lxb_dom_node_prev_noi(ch);
    }
    return false;
}

pub fn getNthIndex(node: *lxb.lxb_dom_node_t) u32 {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return 0;
    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = parent.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            idx += 1;
            if (@intFromPtr(ch) == @intFromPtr(node)) return idx;
        }
        child = ch.next;
    }
    return 0;
}

pub fn getNthLastIndex(node: *lxb.lxb_dom_node_t) u32 {
    const parent = node.parent orelse return 0;
    var idx: u32 = 0;
    var child = lxb_dom_node_last_child_noi(parent);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            idx += 1;
            if (@intFromPtr(ch) == @intFromPtr(node)) return idx;
        }
        child = lxb_dom_node_prev_noi(ch);
    }
    return 0;
}

pub fn matchAttributeSelector(elem: *lxb.lxb_dom_element_t, expr: []const u8) bool {
    // [attr], [attr=val], [attr^=val], [attr$=val], [attr*=val], [attr~=val]
    const trimmed = std.mem.trim(u8, expr, " \t");
    // Find operator
    var op_pos: ?usize = null;
    var op_type: u8 = 0; // 0=exists, '='=exact, '^'=starts, '$'=ends, '*'=contains, '~'=word
    for (trimmed, 0..) |ch, i| {
        if (ch == '=' and i > 0) {
            if (trimmed[i - 1] == '^' or trimmed[i - 1] == '$' or trimmed[i - 1] == '*' or trimmed[i - 1] == '~' or trimmed[i - 1] == '|') {
                op_pos = i - 1;
                op_type = trimmed[i - 1];
            } else {
                op_pos = i;
                op_type = '=';
            }
            break;
        }
    }
    if (op_pos == null) {
        // [attr] — existence check
        var val_len: usize = 0;
        _ = lxb_dom_element_get_attribute(elem, trimmed.ptr, trimmed.len, &val_len);
        return lxb_dom_element_has_attribute(elem, trimmed.ptr, trimmed.len);
    }
    const attr_name = std.mem.trim(u8, trimmed[0..op_pos.?], " \t");
    const val_start = if (op_type == '=') op_pos.? + 1 else op_pos.? + 2;
    var expected = std.mem.trim(u8, trimmed[val_start..], " \t");
    // Strip quotes
    if (expected.len >= 2 and (expected[0] == '"' or expected[0] == '\'') and expected[expected.len - 1] == expected[0]) {
        expected = expected[1 .. expected.len - 1];
    }
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len);
    if (val == null) return false;
    const actual = val.?[0..val_len];

    return switch (op_type) {
        '=' => std.mem.eql(u8, actual, expected),
        '^' => actual.len >= expected.len and std.mem.eql(u8, actual[0..expected.len], expected),
        '$' => actual.len >= expected.len and std.mem.eql(u8, actual[actual.len - expected.len ..], expected),
        '*' => std.mem.indexOf(u8, actual, expected) != null,
        '~' => api.classContains(actual, expected),
        else => false,
    };
}

pub fn elementMatches(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NewBool(false);
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, s.ptr);
    return quickjs.JS_NewBool(elementMatchesSelector(node, s.ptr[0..s.len]));
}

// ── element.closest(selector) ───────────────────────────────────────

pub fn elementClosest(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);
    const sel = s.ptr[0..s.len];

    // Walk up from this element
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |n| {
        if (elementMatchesSelector(n, sel)) return api.wrapNode(c, n);
        cur = n.parent;
    }
    return quickjs.JS_NULL();
}

// ── Element querySelector/querySelectorAll on element scope ─────────

pub fn elementQuerySelector(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const found = walkTreeBySelector(node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return api.wrapNode(c, found);
}

pub fn elementQuerySelectorAll(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_NULL();
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, node, s.ptr[0..s.len], arr, &idx);
    // Set NodeList prototype for instanceof checks
    const nl_js = "(function(a){if(typeof NodeList!=='undefined')Object.setPrototypeOf(a,NodeList.prototype);})";
    const nl_fn = qjs.JS_Eval(c, nl_js, nl_js.len, "<nl>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(nl_fn)) {
        var nl_args = [1]qjs.JSValue{arr};
        const nl_r = qjs.JS_Call(c, nl_fn, quickjs.JS_UNDEFINED(), 1, &nl_args);
        qjs.JS_FreeValue(c, nl_r);
        qjs.JS_FreeValue(c, nl_fn);
    }
    return arr;
}

/// Iterative depth-first tree walk to find element by id (stack-safe)
pub fn walkTreeById(root: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = root;
    while (current) |node| {
        if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
            if (val != null and val_len == id.len) {
                if (std.mem.eql(u8, val.?[0..val_len], id)) return node;
            }
        }
        // Depth-first: try first child, then next sibling, then backtrack
        if (node.first_child) |child| {
            current = child;
        } else {
            var backtrack: ?*lxb.lxb_dom_node_t = node;
            current = null;
            while (backtrack) |bt| {
                if (bt == root) break;
                if (bt.next) |sibling| {
                    current = sibling;
                    break;
                }
                backtrack = bt.parent;
            }
        }
    }
    return null;
}

pub fn walkTreeBySelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    if (selector.len == 0) return null;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return null;

    // Handle comma-separated selectors at top level (not inside :not(), :is() etc.)
    {
        var depth: u32 = 0;
        var has_top_comma = false;
        for (trimmed) |ch| {
            if (ch == '(' or ch == '[') depth += 1
            else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
            else if (ch == ',' and depth == 0) { has_top_comma = true; break; }
        }
        if (has_top_comma) {
            var start: usize = 0;
            depth = 0;
            for (trimmed, 0..) |ch, idx| {
                if (ch == '(' or ch == '[') depth += 1
                else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
                else if (ch == ',' and depth == 0) {
                    const sub = std.mem.trim(u8, trimmed[start..idx], " \t");
                    if (sub.len > 0) {
                        if (walkTreeBySelector(node, sub)) |found| return found;
                    }
                    start = idx + 1;
                }
            }
            const sub = std.mem.trim(u8, trimmed[start..], " \t");
            if (sub.len > 0) {
                if (walkTreeBySelector(node, sub)) |found| return found;
            }
            return null;
        }
    }

    // Parse selector with combinators (>, +, ~, space)
    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return null;
    const parts = parts_buf[0..part_count];

    // Start from first child, not root itself (querySelectorAll returns descendants only)
    var current: ?*lxb.lxb_dom_node_t = node.first_child;
    while (current) |n| {
        if (nodeMatchesCompound(n, parts)) return n;
        current = nextDfsNode(n, node);
    }
    return null;
}

/// Match a single simple selector: #id, .class, tag, tag.class, tag#id
pub fn walkTreeBySimpleSelector(node: *lxb.lxb_dom_node_t, selector: []const u8) ?*lxb.lxb_dom_node_t {
    if (selector.len == 0) return null;

    if (selector[0] == '#') {
        // ID selector
        return walkTreeById(node, selector[1..]);
    } else if (selector[0] == '.') {
        // Class selector
        return api.dom_doc.walkTreeByClass(node, selector[1..]);
    } else {
        // Check for tag.class or tag#id compound (e.g. "div.special")
        if (std.mem.indexOfScalar(u8, selector, '.')) |dot_idx| {
            // tag.class — find by tag first, then filter by class
            return api.dom_doc.walkTreeByTagAndClass(node, selector[0..dot_idx], selector[dot_idx + 1 ..]);
        }
        if (std.mem.indexOfScalar(u8, selector, '#')) |hash_idx| {
            // tag#id — find by id (tag is redundant but valid)
            return walkTreeById(node, selector[hash_idx + 1 ..]);
        }
        // Tag name selector
        return api.dom_doc.walkTreeByTag(node, selector);
    }
}

/// Iterative depth-first next node (stack-safe tree traversal helper)
pub fn nextDfsNode(node: *lxb.lxb_dom_node_t, root: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    if (node.first_child) |child| return child;
    var cur: ?*lxb.lxb_dom_node_t = node;
    while (cur) |c| {
        if (c == root) return null;
        if (c.next) |sibling| return sibling;
        cur = c.parent;
    }
    return null;
}

pub fn documentQuerySelector(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const doc_node = api.dom_doc.getDocumentNode() orelse return quickjs.JS_NULL();
    const found = walkTreeBySelector(doc_node, s.ptr[0..s.len]) orelse return quickjs.JS_NULL();
    return api.wrapNode(c, found);
}

pub fn documentQuerySelectorAll(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, s.ptr);

    const arr = qjs.JS_NewArray(c);
    if (quickjs.JS_IsException(arr)) return arr;

    const doc_node = api.dom_doc.getDocumentNode() orelse return arr;
    var idx: u32 = 0;
    walkTreeCollect(c, doc_node, s.ptr[0..s.len], arr, &idx);
    // Set NodeList prototype
    const nl_js = "(function(a){if(typeof NodeList!=='undefined')Object.setPrototypeOf(a,NodeList.prototype);})";
    const nl_fn = qjs.JS_Eval(c, nl_js, nl_js.len, "<nl>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(nl_fn)) {
        var nl_args = [1]qjs.JSValue{arr};
        const nl_r = qjs.JS_Call(c, nl_fn, quickjs.JS_UNDEFINED(), 1, &nl_args);
        qjs.JS_FreeValue(c, nl_r);
        qjs.JS_FreeValue(c, nl_fn);
    }
    return arr;
}

/// Check if an element node matches a single simple selector (#id, .class, tag, tag[attr])
pub fn nodeMatchesSimple(node: *lxb.lxb_dom_node_t, selector: []const u8) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    if (selector.len == 0) return false;

    // * (universal selector)
    if (selector.len == 1 and selector[0] == '*') return true;

    // :not(inner) — negate inner match
    if (selector.len > 5 and std.ascii.eqlIgnoreCase(selector[0..5], ":not(") and selector[selector.len - 1] == ')') {
        return !elementMatchesSelector(node, selector[5 .. selector.len - 1]);
    }
    // :has(inner) — matches if any descendant matches inner selector
    if (selector.len > 5 and std.ascii.eqlIgnoreCase(selector[0..5], ":has(") and selector[selector.len - 1] == ')') {
        const inner = selector[5 .. selector.len - 1];
        // Check descendants for a match
        var child: ?*lxb.lxb_dom_node_t = node.first_child;
        while (child) |ch| {
            if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT and elementMatchesSelector(ch, inner)) return true;
            // Also check descendants recursively
            if (walkTreeBySelector(ch, inner) != null) return true;
            child = ch.next;
        }
        return false;
    }
    // :is(inner) / :where(inner) — OR match
    if (selector.len > 4 and std.ascii.eqlIgnoreCase(selector[0..4], ":is(") and selector[selector.len - 1] == ')') {
        return elementMatchesSelector(node, selector[4 .. selector.len - 1]);
    }
    if (selector.len > 7 and std.ascii.eqlIgnoreCase(selector[0..7], ":where(") and selector[selector.len - 1] == ')') {
        return elementMatchesSelector(node, selector[7 .. selector.len - 1]);
    }

    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    // Pseudo-class selectors (starting with :)
    if (selector[0] == ':' and selector.len > 1 and selector[1] != ':') {
        return matchSingleSimple(elem, selector);
    }

    // #id selector
    if (selector[0] == '#') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        return val != null and val_len == selector.len - 1 and
            std.mem.eql(u8, val.?[0..val_len], selector[1..]);
    }

    // .class selector
    if (selector[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        return val != null and val_len > 0 and api.classContains(val.?[0..val_len], selector[1..]);
    }

    // Find bracket position (attribute selector start)
    const bracket_idx = std.mem.indexOfScalar(u8, selector, '[');

    // Find dot position ONLY before bracket (dot inside [attr="val.ue"] is not a class)
    const dot_search_end = bracket_idx orelse selector.len;
    const dot_idx = std.mem.indexOfScalar(u8, selector[0..dot_search_end], '.');

    // Determine the tag name portion end
    const tag_end = dot_idx orelse bracket_idx orelse selector.len;

    // Check tag name (if present)
    if (tag_end > 0) {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr == null or name_len != tag_end or
            !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector[0..tag_end])) return false;
    }

    // Check class (tag.class or tag.class[attr])
    if (dot_idx) |di| {
        const class_end = bracket_idx orelse selector.len;
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val == null or val_len == 0 or
            !api.classContains(val.?[0..val_len], selector[di + 1 .. class_end])) return false;
    }

    // Check attribute selectors [attr="value"][attr2="value2"]...
    if (bracket_idx) |bi| {
        var pos: usize = bi;
        while (pos < selector.len) {
            if (selector[pos] != '[') break;
            const attr_start = pos + 1;
            const close = std.mem.indexOfScalarPos(u8, selector, attr_start, ']') orelse return false;
            const attr_inner = selector[attr_start..close];
            if (std.mem.indexOf(u8, attr_inner, "=\"")) |eq_idx| {
                const attr_name = attr_inner[0..eq_idx];
                const attr_val = std.mem.trim(u8, attr_inner[eq_idx + 2 ..], "\"'");
                var av_len: usize = 0;
                const av = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &av_len);
                if (av == null or av_len != attr_val.len or !std.mem.eql(u8, av.?[0..av_len], attr_val)) return false;
            } else {
                var av_len: usize = 0;
                if (lxb_dom_element_get_attribute(elem, attr_inner.ptr, attr_inner.len, &av_len) == null) return false;
            }
            pos = close + 1;
        }
    }

    // If no bracket and no dot, it was a pure tag match (already checked above)
    // If bracket or dot present, all checks passed
    return true;
}

/// Combinator type between selector parts
pub const Combinator = enum { descendant, child, adjacent_sibling, general_sibling };

/// A parsed selector segment: simple selector + combinator to the next part
pub const SelectorPart = struct {
    selector: []const u8,
    combinator: Combinator, // combinator BEFORE this part (from the previous part to this one)
};

/// Parse a full CSS selector string into parts with combinators.
/// "div > .class + span ~ p" → [{div, descendant}, {.class, child}, {span, adjacent_sibling}, {p, general_sibling}]
pub fn parseSelectorParts(trimmed: []const u8, out: []SelectorPart) usize {
    var count: usize = 0;
    var i: usize = 0;
    var next_combinator: Combinator = .descendant;

    while (i < trimmed.len and count < out.len) {
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        if (i >= trimmed.len) break;

        // Check for combinator tokens
        if (trimmed[i] == '>') {
            next_combinator = .child;
            i += 1;
            continue;
        } else if (trimmed[i] == '+') {
            next_combinator = .adjacent_sibling;
            i += 1;
            continue;
        } else if (trimmed[i] == '~') {
            next_combinator = .general_sibling;
            i += 1;
            continue;
        }

        // Read selector token (until space or combinator, respecting () and [])
        const start = i;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        while (i < trimmed.len) {
            const c = trimmed[i];
            if (paren_depth == 0 and bracket_depth == 0 and
                (c == ' ' or c == '\t' or c == '>' or c == '+' or c == '~')) break;
            if (c == '(') paren_depth += 1
            else if (c == ')' and paren_depth > 0) paren_depth -= 1
            else if (c == '[') bracket_depth += 1
            else if (c == ']' and bracket_depth > 0) bracket_depth -= 1;
            i += 1;
        }

        if (i > start) {
            out[count] = .{ .selector = trimmed[start..i], .combinator = next_combinator };
            count += 1;
            next_combinator = .descendant; // default combinator is descendant (space)
        }
    }
    return count;
}

/// Check if a node matches a full compound selector with combinators (>, +, ~, space)
pub fn nodeMatchesCompound(node: *lxb.lxb_dom_node_t, parts: []const SelectorPart) bool {
    if (parts.len == 0) return false;
    // Last part must match the node itself
    if (!nodeMatchesSimple(node, parts[parts.len - 1].selector)) return false;
    if (parts.len == 1) return true;

    // Walk backwards through parts, checking relationships
    var current: *lxb.lxb_dom_node_t = node;
    var pi: usize = parts.len - 1;
    while (pi > 0) {
        pi -= 1;
        const part = parts[pi];
        const combinator = parts[pi + 1].combinator;

        switch (combinator) {
            .descendant => {
                // Any ancestor must match
                var ancestor: ?*lxb.lxb_dom_node_t = current.parent;
                var found = false;
                while (ancestor) |a| {
                    if (nodeMatchesSimple(a, part.selector)) {
                        current = a;
                        found = true;
                        break;
                    }
                    ancestor = a.parent;
                }
                if (!found) return false;
            },
            .child => {
                // Direct parent must match
                const parent = current.parent orelse return false;
                if (!nodeMatchesSimple(parent, part.selector)) return false;
                current = parent;
            },
            .adjacent_sibling => {
                // Previous element sibling must match
                const prev = prevElementSibling(current) orelse return false;
                if (!nodeMatchesSimple(prev, part.selector)) return false;
                current = prev;
            },
            .general_sibling => {
                // Any preceding element sibling must match
                var sib: ?*lxb.lxb_dom_node_t = prevElementSibling(current);
                var found = false;
                while (sib) |s| {
                    if (nodeMatchesSimple(s, part.selector)) {
                        current = s;
                        found = true;
                        break;
                    }
                    sib = prevElementSibling(s);
                }
                if (!found) return false;
            },
        }
    }
    return true;
}

/// Get previous element sibling (skip text/comment nodes)
pub fn prevElementSibling(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var cur: ?*lxb.lxb_dom_node_t = node.prev;
    while (cur) |c| {
        if (c.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) return c;
        cur = c.prev;
    }
    return null;
}

/// Iterative querySelectorAll collector — supports compound selectors with combinators
pub fn walkTreeCollect(ctx: *qjs.JSContext, root: *lxb.lxb_dom_node_t, selector: []const u8, arr: qjs.JSValue, idx: *u32) void {
    if (selector.len == 0) return;
    const trimmed = std.mem.trim(u8, selector, " \t");
    if (trimmed.len == 0) return;

    // Handle comma-separated selectors (top-level only, not inside :not() etc.)
    {
        var depth: u32 = 0;
        var has_top_comma = false;
        for (trimmed) |ch| {
            if (ch == '(' or ch == '[') depth += 1
            else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
            else if (ch == ',' and depth == 0) { has_top_comma = true; break; }
        }
        if (has_top_comma) {
            var start: usize = 0;
            depth = 0;
            for (trimmed, 0..) |ch, i| {
                if (ch == '(' or ch == '[') depth += 1
                else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
                else if (ch == ',' and depth == 0) {
                    const sub = std.mem.trim(u8, trimmed[start..i], " \t");
                    if (sub.len > 0) walkTreeCollect(ctx, root, sub, arr, idx);
                    start = i + 1;
                }
            }
            const sub = std.mem.trim(u8, trimmed[start..], " \t");
            if (sub.len > 0) walkTreeCollect(ctx, root, sub, arr, idx);
            return;
        }
    }

    var parts_buf: [16]SelectorPart = undefined;
    const part_count = parseSelectorParts(trimmed, &parts_buf);
    if (part_count == 0) return;
    const parts = parts_buf[0..part_count];

    // Start from first child, not root (querySelectorAll returns descendants only)
    var current: ?*lxb.lxb_dom_node_t = root.first_child;
    while (current) |node| {
        if (nodeMatchesCompound(node, parts)) {
            _ = qjs.JS_SetPropertyUint32(ctx, arr, idx.*, api.wrapNode(ctx, node));
            idx.* += 1;
        }
        current = nextDfsNode(node, root);
    }
}
