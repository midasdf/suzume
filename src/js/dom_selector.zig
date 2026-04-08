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

// ── Scope element for :scope pseudo-class (DOM spec §4.2.6) ────────
// Set by querySelector/querySelectorAll/closest before matching, cleared after.
// :scope matches only this element (or the document root if null).
var g_scope_element: ?*lxb.lxb_dom_node_t = null;

pub fn setScopeElement(node: ?*lxb.lxb_dom_node_t) void {
    g_scope_element = node;
}

pub fn clearScopeElement() void {
    g_scope_element = null;
}

// ── CSS escape decoding (CSS Syntax §4.3.7) ────────────────────────
fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn hexVal(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}
fn encodeUtf8(code: u32, buf: []u8) usize {
    if (code < 0x80) {
        if (buf.len < 1) return 0;
        buf[0] = @intCast(code);
        return 1;
    } else if (code < 0x800) {
        if (buf.len < 2) return 0;
        buf[0] = @intCast(0xC0 | (code >> 6));
        buf[1] = @intCast(0x80 | (code & 0x3F));
        return 2;
    } else if (code < 0x10000) {
        if (buf.len < 3) return 0;
        buf[0] = @intCast(0xE0 | (code >> 12));
        buf[1] = @intCast(0x80 | ((code >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (code & 0x3F));
        return 3;
    } else if (code <= 0x10FFFF) {
        if (buf.len < 4) return 0;
        buf[0] = @intCast(0xF0 | (code >> 18));
        buf[1] = @intCast(0x80 | ((code >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((code >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (code & 0x3F));
        return 4;
    }
    return 0;
}

/// Find next unescaped dot in a selector string (skips \. sequences)
fn findUnescapedDot(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) { i += 2; continue; }
        if (s[i] == '.') return i;
        i += 1;
    }
    return null;
}

/// Find first unescaped char in a selector string
fn findUnescapedChar(s: []const u8, ch: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) { i += 2; continue; }
        if (s[i] == ch) return i;
        i += 1;
    }
    return null;
}

/// Decode CSS escape sequences in a selector value.
/// Returns the decoded string in buf, or input if no escapes present.
fn decodeCssEscapes(input: []const u8, buf: []u8) []const u8 {
    // Fast path: no backslash
    if (std.mem.indexOfScalar(u8, input, '\\') == null) return input;
    var i: usize = 0;
    var out: usize = 0;
    while (i < input.len and out < buf.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 1;
            if (isHexDigit(input[i])) {
                var code: u32 = 0;
                var count: usize = 0;
                while (i < input.len and count < 6 and isHexDigit(input[i])) {
                    code = code * 16 + hexVal(input[i]);
                    i += 1;
                    count += 1;
                }
                // Skip optional single whitespace after hex
                if (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) i += 1;
                // Invalid code points → U+FFFD
                if (code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) {
                    if (out + 3 <= buf.len) {
                        buf[out] = 0xEF;
                        buf[out + 1] = 0xBF;
                        buf[out + 2] = 0xBD;
                        out += 3;
                    }
                } else {
                    out += encodeUtf8(code, buf[out..]);
                }
            } else {
                buf[out] = input[i];
                out += 1;
                i += 1;
            }
        } else if (input[i] == '\\' and i + 1 == input.len) {
            // Backslash at EOF → U+FFFD
            if (out + 3 <= buf.len) {
                buf[out] = 0xEF;
                buf[out + 1] = 0xBF;
                buf[out + 2] = 0xBD;
                out += 3;
            }
            i += 1;
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

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
            // Use elementMatchesSelector for pseudo part so :has() etc. work
            return elementMatchesSelector(@ptrCast(elem), sel[pseudo_start..]);
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
    // :has(inner) — matches if descendant/child/sibling matches inner relative selector
    if (sel.len > 5 and std.ascii.eqlIgnoreCase(sel[0..5], ":has(") and sel[sel.len - 1] == ')') {
        const inner = std.mem.trim(u8, sel[5 .. sel.len - 1], " \t");
        return hasRelativeMatch(@ptrCast(elem), inner);
    }
    // Other pseudo-classes
    if (sel[0] == ':') {
        // :first-child, :last-child, :only-child, :empty, :root, :enabled, :disabled, :checked
        if (std.ascii.eqlIgnoreCase(sel, ":first-child")) return isFirstChild(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":last-child")) return isLastChild(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":root")) return isRoot(@ptrCast(elem));
        if (std.ascii.eqlIgnoreCase(sel, ":scope")) {
            // :scope matches only the context element set by querySelector/closest
            if (g_scope_element) |scope| return (@intFromPtr(elem) == @intFromPtr(scope));
            // If no scope set, :scope matches the document element (:root)
            return isRoot(@ptrCast(elem));
        }
        if (std.ascii.eqlIgnoreCase(sel, ":empty")) {
            const node: *lxb.lxb_dom_node_t = @ptrCast(elem);
            var child = node.first_child;
            while (@intFromPtr(child) != 0) {
                const t = child.*.type;
                // Element(1) or Text(3) or CDATA(4) nodes make it non-empty
                if (t == 1 or t == 3 or t == 4) return false;
                child = child.*.next;
            }
            return true;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":enabled")) {
            // Per spec: form elements + optgroup/option match :enabled/:disabled
            var name_len_e: usize = 0;
            const name_ptr_e = lxb_dom_element_local_name(elem, &name_len_e);
            if (name_ptr_e == null) return false;
            const tag_e = name_ptr_e.?[0..name_len_e];
            if (std.ascii.eqlIgnoreCase(tag_e, "input") or std.ascii.eqlIgnoreCase(tag_e, "button") or
                std.ascii.eqlIgnoreCase(tag_e, "select") or std.ascii.eqlIgnoreCase(tag_e, "textarea") or
                std.ascii.eqlIgnoreCase(tag_e, "fieldset") or std.ascii.eqlIgnoreCase(tag_e, "optgroup") or
                std.ascii.eqlIgnoreCase(tag_e, "option"))
                return !lxb_dom_element_has_attribute(elem, "disabled", 8);
            return false;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":disabled")) {
            var name_len_d: usize = 0;
            const name_ptr_d = lxb_dom_element_local_name(elem, &name_len_d);
            if (name_ptr_d == null) return false;
            const tag_d = name_ptr_d.?[0..name_len_d];
            if (std.ascii.eqlIgnoreCase(tag_d, "input") or std.ascii.eqlIgnoreCase(tag_d, "button") or
                std.ascii.eqlIgnoreCase(tag_d, "select") or std.ascii.eqlIgnoreCase(tag_d, "textarea") or
                std.ascii.eqlIgnoreCase(tag_d, "fieldset") or std.ascii.eqlIgnoreCase(tag_d, "optgroup") or
                std.ascii.eqlIgnoreCase(tag_d, "option"))
                return lxb_dom_element_has_attribute(elem, "disabled", 8);
            return false;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":checked")) {
            return lxb_dom_element_has_attribute(elem, "checked", 7);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":target")) {
            if (api.url_fragment_len == 0) return false;
            var id_len: usize = 0;
            const id_ptr = lxb_dom_element_get_attribute(elem, "id", 2, &id_len);
            if (id_ptr == null or id_len == 0) return false;
            return id_len == api.url_fragment_len and std.mem.eql(u8, id_ptr.?[0..id_len], api.url_fragment[0..api.url_fragment_len]);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":focus")) {
            return api.active_element != null and api.active_element.? == @as(*lxb.lxb_dom_node_t, @ptrCast(elem));
        }
        if (std.ascii.eqlIgnoreCase(sel, ":focus-visible")) {
            return api.active_element != null and api.active_element.? == @as(*lxb.lxb_dom_node_t, @ptrCast(elem));
        }
        if (std.ascii.eqlIgnoreCase(sel, ":focus-within")) {
            const ae = api.active_element orelse return false;
            // Check if elem is ancestor-or-self of active element
            var cur: ?*lxb.lxb_dom_node_t = ae;
            while (cur) |n| {
                if (n == @as(*lxb.lxb_dom_node_t, @ptrCast(elem))) return true;
                cur = n.parent;
            }
            return false;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":required")) {
            return lxb_dom_element_has_attribute(elem, "required", 8);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":optional")) {
            return !lxb_dom_element_has_attribute(elem, "required", 8);
        }
        // :valid / :invalid — form validation pseudo-classes
        // Simplified: elements with required but no value are :invalid
        if (std.ascii.eqlIgnoreCase(sel, ":valid")) {
            if (!lxb_dom_element_has_attribute(elem, "required", 8)) return true;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "value", 5, &val_len);
            return val != null and val_len > 0;
        }
        if (std.ascii.eqlIgnoreCase(sel, ":invalid")) {
            if (!lxb_dom_element_has_attribute(elem, "required", 8)) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "value", 5, &val_len);
            return val == null or val_len == 0;
        }
        // :read-only / :read-write
        if (std.ascii.eqlIgnoreCase(sel, ":read-write")) {
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null) return false;
            const tag = name_ptr.?[0..name_len];
            if ((std.ascii.eqlIgnoreCase(tag, "input") or std.ascii.eqlIgnoreCase(tag, "textarea")) and !lxb_dom_element_has_attribute(elem, "readonly", 8) and !lxb_dom_element_has_attribute(elem, "disabled", 8)) return true;
            return lxb_dom_element_has_attribute(elem, "contenteditable", 15);
        }
        if (std.ascii.eqlIgnoreCase(sel, ":read-only")) {
            var name_len2: usize = 0;
            const name_ptr2 = lxb_dom_element_local_name(elem, &name_len2);
            if (name_ptr2 == null) return true;
            const tag2 = name_ptr2.?[0..name_len2];
            if ((std.ascii.eqlIgnoreCase(tag2, "input") or std.ascii.eqlIgnoreCase(tag2, "textarea")) and (lxb_dom_element_has_attribute(elem, "readonly", 8) or lxb_dom_element_has_attribute(elem, "disabled", 8))) return true;
            if (!std.ascii.eqlIgnoreCase(tag2, "input") and !std.ascii.eqlIgnoreCase(tag2, "textarea")) return !lxb_dom_element_has_attribute(elem, "contenteditable", 15);
            return false;
        }
        // :placeholder-shown
        if (std.ascii.eqlIgnoreCase(sel, ":placeholder-shown")) {
            if (!lxb_dom_element_has_attribute(elem, "placeholder", 11)) return false;
            var val_len2: usize = 0;
            const val2 = lxb_dom_element_get_attribute(elem, "value", 5, &val_len2);
            return val2 == null or val_len2 == 0;
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
            const idx_val = getNthIndex(@ptrCast(elem));
            if (matchNthFormula(arg, idx_val)) return true;
            return false;
        }
        // :nth-last-child(N)
        if (sel.len > 16 and std.ascii.eqlIgnoreCase(sel[0..16], ":nth-last-child(") and sel[sel.len - 1] == ')') {
            const arg = std.mem.trim(u8, sel[16 .. sel.len - 1], " \t");
            const idx_val = getNthLastIndex(@ptrCast(elem));
            if (matchNthFormula(arg, idx_val)) return true;
            return false;
        }
        // :nth-of-type(N)
        if (sel.len > 13 and std.ascii.eqlIgnoreCase(sel[0..13], ":nth-of-type(") and sel[sel.len - 1] == ')') {
            const arg = std.mem.trim(u8, sel[13 .. sel.len - 1], " \t");
            const idx_val = getNthOfTypeIndex(@ptrCast(elem));
            if (matchNthFormula(arg, idx_val)) return true;
            return false;
        }
        // :nth-last-of-type(N)
        if (sel.len > 18 and std.ascii.eqlIgnoreCase(sel[0..18], ":nth-last-of-type(") and sel[sel.len - 1] == ')') {
            const arg = std.mem.trim(u8, sel[18 .. sel.len - 1], " \t");
            const idx_val = getNthLastOfTypeIndex(@ptrCast(elem));
            if (matchNthFormula(arg, idx_val)) return true;
            return false;
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
        // :lang(tag) — BCP 47 extended filtering (RFC 4647 §3.4)
        if (sel.len > 6 and std.ascii.eqlIgnoreCase(sel[0..6], ":lang(") and sel[sel.len - 1] == ')') {
            const lang_arg = std.mem.trim(u8, sel[6 .. sel.len - 1], " \t\"'");
            if (lang_arg.len == 0) return false;
            // Find element's language: walk up tree for lang attribute
            const node_ptr: *lxb.lxb_dom_node_t = @ptrCast(elem);
            var cur: ?*lxb.lxb_dom_node_t = node_ptr;
            var elem_lang: ?[]const u8 = null;
            while (cur) |c| {
                if (c.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                    const el: *lxb.lxb_dom_element_t = @ptrCast(c);
                    var lang_len: usize = 0;
                    const lang_val = lxb_dom_element_get_attribute(el, "lang", 4, &lang_len);
                    if (lang_val != null and lang_len > 0) {
                        elem_lang = lang_val.?[0..lang_len];
                        break;
                    }
                    // Also check xml:lang
                    const xmllang = lxb_dom_element_get_attribute(el, "xml:lang", 8, &lang_len);
                    if (xmllang != null and lang_len > 0) {
                        elem_lang = xmllang.?[0..lang_len];
                        break;
                    }
                }
                cur = c.parent;
            }
            if (elem_lang == null) return false;
            return matchLangBCP47(lang_arg, elem_lang.?);
        }
        // :heading / :heading(N) — CSS Selectors Level 5
        if (std.ascii.eqlIgnoreCase(sel, ":heading") or
            (sel.len > 9 and std.ascii.eqlIgnoreCase(sel[0..9], ":heading(") and sel[sel.len - 1] == ')'))
        {
            // Get element local name
            var tag_len: usize = 0;
            const tag_ptr = lxb_dom_element_local_name(elem, &tag_len);
            if (tag_ptr == null or tag_len < 2) return false;
            const tag = tag_ptr.?[0..tag_len];
            // Check if h1-h6
            if (tag_len != 2 or (tag[0] != 'h' and tag[0] != 'H')) return false;
            const level = tag[1];
            if (level < '1' or level > '6') return false;
            const elem_level: i32 = @as(i32, level - '0');
            // :heading without args matches all h1-h6
            if (std.ascii.eqlIgnoreCase(sel, ":heading")) return true;
            // :heading(N, ...) — check comma-separated integer levels
            const args = std.mem.trim(u8, sel[9 .. sel.len - 1], " \t");
            var it = std.mem.splitScalar(u8, args, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                const n = std.fmt.parseInt(i32, trimmed, 10) catch continue;
                if (n == elem_level) return true;
            }
            return false;
        }
        // Unknown pseudo — return false (conservative)
        return false;
    }

    // Check for attribute selector embedded in compound: tag[attr], .class[attr], etc.
    if (sel[0] != '[') {
        // Find first unescaped '[' not inside parens
        var depth_b: u32 = 0;
        var bracket_pos: ?usize = null;
        var bi: usize = 0;
        while (bi < sel.len) : (bi += 1) {
            if (sel[bi] == '\\' and bi + 1 < sel.len) { bi += 1; continue; } // skip escape
            if (sel[bi] == '(') depth_b += 1
            else if (sel[bi] == ')' and depth_b > 0) depth_b -= 1
            else if (sel[bi] == '[' and depth_b == 0) { bracket_pos = bi; break; }
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
        if (val == null) return false;
        var esc_buf: [512]u8 = undefined;
        const decoded = decodeCssEscapes(sel[1..], &esc_buf);
        if (val_len == decoded.len) {
            return std.mem.eql(u8, val.?[0..val_len], decoded);
        }
        return false;
    }
    // .class (may be chained: .class1.class2.class3)
    if (sel[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val == null or val_len == 0) return false;
        const class_val = val.?[0..val_len];
        var rest = sel[1..];
        while (rest.len > 0) {
            const next_dot = findUnescapedDot(rest) orelse rest.len;
            if (next_dot == 0) return false;
            var esc_buf: [512]u8 = undefined;
            const decoded = decodeCssEscapes(rest[0..next_dot], &esc_buf);
            if (!api.classContains(class_val, decoded)) return false;
            if (next_dot >= rest.len) break;
            rest = rest[next_dot + 1 ..];
        }
        return true;
    }
    // * (universal)
    if (sel.len == 1 and sel[0] == '*') return true;

    // Compound: tag.class1.class2 or tag#id
    if (findUnescapedDot(sel)) |dot| {
        if (dot > 0) {
            // tag.class1.class2...
            var name_len: usize = 0;
            const name_ptr = lxb_dom_element_local_name(elem, &name_len);
            if (name_ptr == null or !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], sel[0..dot])) return false;
            var val_len: usize = 0;
            const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
            if (val == null or val_len == 0) return false;
            const class_val = val.?[0..val_len];
            var rest = sel[dot + 1 ..];
            while (rest.len > 0) {
                const next_dot = findUnescapedDot(rest) orelse rest.len;
                if (next_dot == 0) return false;
                var esc_buf_c: [512]u8 = undefined;
                const decoded_c = decodeCssEscapes(rest[0..next_dot], &esc_buf_c);
                if (!api.classContains(class_val, decoded_c)) return false;
                if (next_dot >= rest.len) break;
                rest = rest[next_dot + 1 ..];
            }
            return true;
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
    // Find ':' that's not inside [] or () and not CSS-escaped — marks start of pseudo-class
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < sel.len) : (i += 1) {
        if (sel[i] == '\\' and i + 1 < sel.len) { i += 1; continue; } // skip CSS escape
        if (sel[i] == '(' or sel[i] == '[') depth += 1
        else if ((sel[i] == ')' or sel[i] == ']') and depth > 0) depth -= 1
        else if (sel[i] == ':' and depth == 0) return i;
    }
    return null;
}

pub fn isFirstChild(node: *lxb.lxb_dom_node_t) bool {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return true; // detached = trivially first (no siblings)
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
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return true; // detached = trivially last (no siblings)
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
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return true; // detached = trivially first
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
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return true; // detached = trivially last
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
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return 1; // detached = trivially 1st
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
    const parent = node.parent orelse return 1; // detached = trivially 1st
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

pub fn getNthOfTypeIndex(node: *lxb.lxb_dom_node_t) u32 {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return 1; // detached = trivially 1st
    var name_len: usize = 0;
    const name = lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name == null) return 0;
    var idx: u32 = 0;
    var child: ?*lxb.lxb_dom_node_t = parent.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var cn_len: usize = 0;
            const cn = lxb_dom_element_local_name(@ptrCast(ch), &cn_len);
            if (cn != null and cn_len == name_len and std.mem.eql(u8, cn.?[0..cn_len], name.?[0..name_len])) {
                idx += 1;
                if (@intFromPtr(ch) == @intFromPtr(node)) return idx;
            }
        }
        child = ch.next;
    }
    return 0;
}

pub fn getNthLastOfTypeIndex(node: *lxb.lxb_dom_node_t) u32 {
    const parent: *lxb.lxb_dom_node_t = node.parent orelse return 1; // detached = trivially 1st
    var name_len: usize = 0;
    const name = lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name == null) return 0;
    var idx: u32 = 0;
    var child = lxb_dom_node_last_child_noi(parent);
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var cn_len: usize = 0;
            const cn = lxb_dom_element_local_name(@ptrCast(ch), &cn_len);
            if (cn != null and cn_len == name_len and std.mem.eql(u8, cn.?[0..cn_len], name.?[0..name_len])) {
                idx += 1;
                if (@intFromPtr(ch) == @intFromPtr(node)) return idx;
            }
        }
        child = lxb_dom_node_prev_noi(ch);
    }
    return 0;
}

/// Match An+B formula: "odd", "even", "3", "2n", "2n+1", "-n+3", etc.
pub fn matchNthFormula(raw_arg: []const u8, idx: u32) bool {
    if (idx == 0) return false;
    // Strip all CSS whitespace (space, tab, newline, carriage return, form feed)
    const ws = " \t\n\r\x0c";
    const arg = std.mem.trim(u8, raw_arg, ws);
    if (arg.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(arg, "odd")) return (idx % 2) == 1;
    if (std.ascii.eqlIgnoreCase(arg, "even")) return (idx % 2) == 0;
    if (std.ascii.eqlIgnoreCase(arg, "n")) return true; // matches all
    // Try simple integer
    if (std.fmt.parseInt(i32, arg, 10)) |n| return n > 0 and idx == @as(u32, @intCast(n))
    else |_| {}
    // Parse An+B: find 'n'
    if (std.mem.indexOfScalar(u8, arg, 'n')) |n_pos| {
        // Parse A (before n)
        var a: i32 = 1;
        if (n_pos > 0) {
            const a_str = std.mem.trim(u8, arg[0..n_pos], ws);
            if (a_str.len == 1 and a_str[0] == '-') { a = -1; }
            else if (a_str.len == 1 and a_str[0] == '+') { a = 1; }
            else if (a_str.len > 0) { a = std.fmt.parseInt(i32, a_str, 10) catch return false; }
        }
        // Parse B (after n)
        var b: i32 = 0;
        if (n_pos + 1 < arg.len) {
            const b_str = std.mem.trim(u8, arg[n_pos + 1 ..], ws);
            if (b_str.len > 0) { b = std.fmt.parseInt(i32, b_str, 10) catch return false; }
        }
        // Match: idx = An + B for some non-negative integer n
        const idx_i: i32 = @intCast(idx);
        if (a == 0) return idx_i == b;
        const diff = idx_i - b;
        if (a > 0) return diff >= 0 and @mod(diff, a) == 0;
        // a < 0: n must be non-negative, so idx <= b
        return diff <= 0 and @mod(-diff, -a) == 0;
    }
    return false;
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
        // Handle *|attr (any namespace) prefix — strip *| and match by local name
        var check_name = trimmed;
        if (check_name.len > 2 and check_name[0] == '*' and check_name[1] == '|') {
            check_name = check_name[2..];
        }
        // Case-insensitive check for HTML attributes
        var lower_buf: [128]u8 = undefined;
        if (check_name.len <= lower_buf.len) {
            for (check_name, 0..) |ch, ci| lower_buf[ci] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            const lower = lower_buf[0..check_name.len];
            return lxb_dom_element_has_attribute(elem, lower.ptr, lower.len);
        }
        return lxb_dom_element_has_attribute(elem, check_name.ptr, check_name.len);
    }
    var attr_name = std.mem.trim(u8, trimmed[0..op_pos.?], " \t");
    // Handle *|attr prefix for namespace wildcard
    if (attr_name.len > 2 and attr_name[0] == '*' and attr_name[1] == '|') {
        attr_name = attr_name[2..];
    }
    const val_start = if (op_type == '=') op_pos.? + 1 else op_pos.? + 2;
    var expected = std.mem.trim(u8, trimmed[val_start..], " \t");
    // Strip quotes
    if (expected.len >= 2 and (expected[0] == '"' or expected[0] == '\'') and expected[expected.len - 1] == expected[0]) {
        expected = expected[1 .. expected.len - 1];
    }
    // Decode CSS escapes in expected value
    var esc_buf: [512]u8 = undefined;
    const decoded_exp = decodeCssEscapes(expected, &esc_buf);
    var val_len: usize = 0;
    const val = lxb_dom_element_get_attribute(elem, attr_name.ptr, attr_name.len, &val_len);
    if (val == null) return false;
    const actual = val.?[0..val_len];

    return switch (op_type) {
        '=' => std.mem.eql(u8, actual, decoded_exp),
        '^' => actual.len >= decoded_exp.len and std.mem.eql(u8, actual[0..decoded_exp.len], decoded_exp),
        '$' => actual.len >= decoded_exp.len and std.mem.eql(u8, actual[actual.len - decoded_exp.len ..], decoded_exp),
        '*' => std.mem.indexOf(u8, actual, decoded_exp) != null,
        '~' => api.classContains(actual, decoded_exp),
        '|' => std.mem.eql(u8, actual, decoded_exp) or
            (actual.len > decoded_exp.len and std.mem.eql(u8, actual[0..decoded_exp.len], decoded_exp) and actual[decoded_exp.len] == '-'),
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

    // Walk up from this element — :scope refers to this element
    setScopeElement(node);
    defer clearScopeElement();
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

    setScopeElement(node);
    defer clearScopeElement();
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

    setScopeElement(node);
    defer clearScopeElement();
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

    // Compound selector with pseudo-classes: ".x:has(.a)", "div:not(.x)"
    // Split at first ':' not inside brackets/parens and match each part
    if (findPseudoStart(selector)) |pseudo_start| {
        if (pseudo_start > 0) {
            if (!nodeMatchesSimple(node, selector[0..pseudo_start])) return false;
            return nodeMatchesSimple(node, selector[pseudo_start..]);
        }
    }

    // :not(inner) — negate inner match
    if (selector.len > 5 and std.ascii.eqlIgnoreCase(selector[0..5], ":not(") and selector[selector.len - 1] == ')') {
        return !elementMatchesSelector(node, selector[5 .. selector.len - 1]);
    }
    // :has(inner) — matches if any descendant/child matches inner selector
    if (selector.len > 5 and std.ascii.eqlIgnoreCase(selector[0..5], ":has(") and selector[selector.len - 1] == ')') {
        const inner = std.mem.trim(u8, selector[5 .. selector.len - 1], " \t");
        return hasRelativeMatch(node, inner);
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
        if (val == null) return false;
        var esc_buf2: [512]u8 = undefined;
        const decoded2 = decodeCssEscapes(selector[1..], &esc_buf2);
        return val_len == decoded2.len and std.mem.eql(u8, val.?[0..val_len], decoded2);
    }

    // .class selector (may be chained: .class1.class2.class3)
    if (selector[0] == '.') {
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val == null or val_len == 0) return false;
        const class_val = val.?[0..val_len];
        // Split chained classes by '.' and check each
        var rest = selector[1..];
        while (rest.len > 0) {
            // Find next dot (start of next class) or end
            const next_dot = findUnescapedDot(rest) orelse rest.len;
            if (next_dot == 0) return false; // empty class like ".foo..bar"
            var esc_buf_cls: [512]u8 = undefined;
            const decoded_cls = decodeCssEscapes(rest[0..next_dot], &esc_buf_cls);
            if (!api.classContains(class_val, decoded_cls)) return false;
            if (next_dot >= rest.len) break;
            rest = rest[next_dot + 1 ..];
        }
        return true;
    }

    // Find bracket position (attribute selector start)
    const bracket_idx = std.mem.indexOfScalar(u8, selector, '[');

    // Find dot position ONLY before bracket (dot inside [attr="val.ue"] is not a class)
    const dot_search_end = bracket_idx orelse selector.len;
    const dot_idx = findUnescapedDot(selector[0..dot_search_end]);

    // Determine the tag name portion end
    const tag_end = dot_idx orelse bracket_idx orelse selector.len;

    // Check tag name (if present)
    if (tag_end > 0) {
        var name_len: usize = 0;
        const name_ptr = lxb_dom_element_local_name(elem, &name_len);
        if (name_ptr == null or name_len != tag_end or
            !std.ascii.eqlIgnoreCase(name_ptr.?[0..name_len], selector[0..tag_end])) return false;
    }

    // Check class (tag.class1.class2 or tag.class[attr])
    if (dot_idx) |di| {
        const class_end = bracket_idx orelse selector.len;
        var val_len: usize = 0;
        const val = lxb_dom_element_get_attribute(elem, "class", 5, &val_len);
        if (val == null or val_len == 0) return false;
        const class_val = val.?[0..val_len];
        // Split chained classes by '.' and check each
        var rest = selector[di + 1 .. class_end];
        while (rest.len > 0) {
            const next_dot = findUnescapedDot(rest) orelse rest.len;
            if (next_dot == 0) return false;
            var esc_buf_cls2: [512]u8 = undefined;
            const decoded_cls2 = decodeCssEscapes(rest[0..next_dot], &esc_buf_cls2);
            if (!api.classContains(class_val, decoded_cls2)) return false;
            if (next_dot >= rest.len) break;
            rest = rest[next_dot + 1 ..];
        }
    }

    // Check attribute selectors [attr="value"][attr2="value2"]...
    if (bracket_idx) |bi| {
        var pos: usize = bi;
        while (pos < selector.len) {
            if (selector[pos] != '[') break;
            const attr_start = pos + 1;
            const close = std.mem.indexOfScalarPos(u8, selector, attr_start, ']') orelse return false;
            if (!matchAttributeSelector(elem, selector[attr_start..close])) return false;
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
        // Skip CSS whitespace (space, tab, LF, CR, FF)
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r' or trimmed[i] == 0x0C)) i += 1;
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

        // Read selector token (until space or combinator, respecting (), [], and CSS escapes)
        const start = i;
        var paren_depth: u32 = 0;
        var bracket_depth: u32 = 0;
        while (i < trimmed.len) {
            const c = trimmed[i];
            // CSS escape: skip \X or \HHHHHH (+ optional space)
            if (c == '\\' and i + 1 < trimmed.len) {
                i += 1; // skip backslash
                if (isHexDigit(trimmed[i])) {
                    var hcount: usize = 0;
                    while (i < trimmed.len and hcount < 6 and isHexDigit(trimmed[i])) {
                        i += 1;
                        hcount += 1;
                    }
                    // Skip optional whitespace after hex escape (it's part of the escape, not a combinator)
                    if (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r' or trimmed[i] == 0x0C)) i += 1;
                } else {
                    i += 1; // skip escaped character
                }
                continue;
            }
            if (paren_depth == 0 and bracket_depth == 0 and
                (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == '>' or c == '+' or c == '~')) break;
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

/// Match a relative selector inside :has(). Handles multi-combinator selectors recursively.
/// inner is the relative selector, e.g. "> .a > .b" or ".a + .b" or just ".a"
fn hasRelativeMatch(node: *lxb.lxb_dom_node_t, inner: []const u8) bool {
    if (inner.len == 0) return false;
    // Handle comma-separated selector list (any match = true)
    {
        var depth: u32 = 0;
        var start: usize = 0;
        for (inner, 0..) |ch, i| {
            if (ch == '(' or ch == '[') depth += 1
            else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1
            else if (ch == ',' and depth == 0) {
                const part = std.mem.trim(u8, inner[start..i], " \t");
                if (part.len > 0 and hasRelativeMatchSingle(node, part)) return true;
                start = i + 1;
            }
        }
        const last = std.mem.trim(u8, inner[start..], " \t");
        return last.len > 0 and hasRelativeMatchSingle(node, last);
    }
}

fn hasRelativeMatchSingle(node: *lxb.lxb_dom_node_t, inner: []const u8) bool {
    if (inner.len == 0) return false;
    // Determine first combinator
    var combinator: u8 = ' '; // default: descendant
    var rest = inner;
    if (inner[0] == '>') {
        combinator = '>';
        rest = std.mem.trim(u8, inner[1..], " \t");
    } else if (inner[0] == '~') {
        combinator = '~';
        rest = std.mem.trim(u8, inner[1..], " \t");
    } else if (inner[0] == '+') {
        combinator = '+';
        rest = std.mem.trim(u8, inner[1..], " \t");
    }
    if (rest.len == 0) return false;

    // Split rest into first simple selector and remaining combinators
    // Find next combinator boundary (space, >, +, ~ not inside parens/brackets)
    var simple_end: usize = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    while (simple_end < rest.len) : (simple_end += 1) {
        const ch = rest[simple_end];
        if (ch == '(' or ch == '[') { paren_depth += 1; bracket_depth += 1; }
        if (ch == ')' or ch == ']') { paren_depth -= 1; bracket_depth -= 1; }
        if (paren_depth <= 0 and bracket_depth <= 0) {
            if (ch == '>' or ch == '+' or ch == '~') break;
            if (ch == ' ' and simple_end + 1 < rest.len) {
                // Check if next non-space char is a combinator or start of selector
                var peek = simple_end + 1;
                while (peek < rest.len and rest[peek] == ' ') peek += 1;
                if (peek < rest.len and (rest[peek] != '>' and rest[peek] != '+' and rest[peek] != '~')) {
                    break; // space combinator
                } else if (peek < rest.len) {
                    // Skip spaces before explicit combinator
                    continue;
                }
            }
        }
    }
    const simple_sel = std.mem.trim(u8, rest[0..simple_end], " \t");
    const remaining = std.mem.trim(u8, rest[simple_end..], " \t");

    // Match simple_sel against nodes in scope determined by combinator
    if (combinator == '>') {
        var child: ?*lxb.lxb_dom_node_t = node.first_child;
        while (child) |ch| {
            if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT and nodeMatchesSimple(ch, simple_sel)) {
                if (remaining.len == 0) return true;
                if (hasRelativeMatch(ch, remaining)) return true;
            }
            child = ch.next;
        }
    } else if (combinator == '+') {
        var sib: ?*lxb.lxb_dom_node_t = node.next;
        while (sib) |s| {
            if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                if (nodeMatchesSimple(s, simple_sel)) {
                    if (remaining.len == 0) return true;
                    if (hasRelativeMatch(s, remaining)) return true;
                }
                break; // adjacent = only first element sibling
            }
            sib = s.next;
        }
    } else if (combinator == '~') {
        var sib: ?*lxb.lxb_dom_node_t = node.next;
        while (sib) |s| {
            if (s.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT and nodeMatchesSimple(s, simple_sel)) {
                if (remaining.len == 0) return true;
                if (hasRelativeMatch(s, remaining)) return true;
            }
            sib = s.next;
        }
    } else {
        // Descendant combinator: check all descendants
        var child: ?*lxb.lxb_dom_node_t = node.first_child;
        while (child) |ch| {
            if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                if (nodeMatchesSimple(ch, simple_sel)) {
                    if (remaining.len == 0) return true;
                    if (hasRelativeMatch(ch, remaining)) return true;
                }
                // Also check ch's descendants
                if (hasRelativeMatch(ch, inner)) return true;
            }
            child = ch.next;
        }
    }
    return false;
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

/// BCP 47 extended filtering (RFC 4647 §3.4)
/// Returns true if the element's language tag matches the given range.
pub fn matchLangBCP47(range: []const u8, tag: []const u8) bool {
    if (range.len == 0 or tag.len == 0) return false;
    // Wildcard matches everything
    if (range.len == 1 and range[0] == '*') return true;

    // Split range and tag into subtags by '-'
    var range_subtags: [16][]const u8 = undefined;
    var range_count: usize = 0;
    {
        var start: usize = 0;
        for (range, 0..) |ch, i| {
            if (ch == '-') {
                if (range_count < 16) { range_subtags[range_count] = range[start..i]; range_count += 1; }
                start = i + 1;
            }
        }
        if (range_count < 16) { range_subtags[range_count] = range[start..]; range_count += 1; }
    }
    var tag_subtags: [16][]const u8 = undefined;
    var tag_count: usize = 0;
    {
        var start: usize = 0;
        for (tag, 0..) |ch, i| {
            if (ch == '-') {
                if (tag_count < 16) { tag_subtags[tag_count] = tag[start..i]; tag_count += 1; }
                start = i + 1;
            }
        }
        if (tag_count < 16) { tag_subtags[tag_count] = tag[start..]; tag_count += 1; }
    }

    if (range_count == 0 or tag_count == 0) return false;

    // Step 1: primary subtags must match (case-insensitive)
    if (!std.ascii.eqlIgnoreCase(range_subtags[0], tag_subtags[0])) return false;

    // Extended filtering: walk through range subtags
    var ri: usize = 1; // range index
    var ti: usize = 1; // tag index
    while (ri < range_count) {
        const r_sub = range_subtags[ri];
        if (r_sub.len == 1 and r_sub[0] == '*') {
            // Wildcard subtag matches anything; advance range only
            ri += 1;
            continue;
        }
        if (ti >= tag_count) return false; // ran out of tag subtags
        const t_sub = tag_subtags[ti];
        if (std.ascii.eqlIgnoreCase(r_sub, t_sub)) {
            // Match: advance both
            ri += 1;
            ti += 1;
        } else if (t_sub.len == 1) {
            // Singleton subtag in tag blocks skipping (RFC 4647 §3.4 step 3D)
            return false;
        } else {
            // Skip this tag subtag and try again
            ti += 1;
        }
    }
    return true;
}
