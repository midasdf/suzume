const std = @import("std");
const util = @import("util.zig");

/// Evaluate a CSS media query string against viewport dimensions.
/// Returns true if the query matches (or is empty/unknown — fail-open).
pub fn evaluateMediaQuery(raw: []const u8, viewport_width: f32, viewport_height: f32) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return true;

    // Handle comma-separated queries (OR logic): any match => true
    var comma_iter = CommaIterator.init(trimmed);
    while (comma_iter.next()) |segment| {
        if (evaluateSingleQuery(segment, viewport_width, viewport_height)) return true;
    }
    return false;
}

/// Iterate comma-separated media query segments, respecting parentheses.
const CommaIterator = struct {
    source: []const u8,
    pos: usize,

    fn init(source: []const u8) CommaIterator {
        return .{ .source = source, .pos = 0 };
    }

    fn next(self: *CommaIterator) ?[]const u8 {
        if (self.pos >= self.source.len) return null;
        const start = self.pos;
        var paren_depth: u32 = 0;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '(') paren_depth += 1;
            if (c == ')' and paren_depth > 0) paren_depth -= 1;
            if (c == ',' and paren_depth == 0) {
                const result = std.mem.trim(u8, self.source[start..self.pos], " \t\r\n");
                self.pos += 1;
                if (result.len > 0) return result;
                return self.next();
            }
            self.pos += 1;
        }
        const result = std.mem.trim(u8, self.source[start..self.pos], " \t\r\n");
        if (result.len > 0) return result;
        return null;
    }
};

/// Evaluate a single media query (no commas).
fn evaluateSingleQuery(query: []const u8, vw: f32, vh: f32) bool {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return true;

    // Handle "not ..." prefix
    if (startsWithIgnoreCase(trimmed, "not ")) {
        const rest = std.mem.trim(u8, trimmed[4..], " \t");
        return !evaluateSingleQuery(rest, vw, vh);
    }

    // Handle "only ..." prefix (treat same as without "only")
    if (startsWithIgnoreCase(trimmed, "only ")) {
        const rest = std.mem.trim(u8, trimmed[5..], " \t");
        return evaluateSingleQuery(rest, vw, vh);
    }

    // Split by " and " (AND logic): all must match
    var pos: usize = 0;
    while (pos < trimmed.len) {
        const remaining = trimmed[pos..];
        if (findAndKeyword(remaining)) |and_offset| {
            const part = std.mem.trim(u8, remaining[0..and_offset], " \t");
            if (!evaluateAtom(part, vw, vh)) return false;
            pos += and_offset + 5; // skip " and "
        } else {
            const part = std.mem.trim(u8, remaining, " \t");
            return evaluateAtom(part, vw, vh);
        }
    }
    return true;
}

/// Find " and " keyword in text (case-insensitive), not inside parens.
fn findAndKeyword(text: []const u8) ?usize {
    if (text.len < 5) return null;
    var i: usize = 0;
    var paren_depth: u32 = 0;
    while (i + 4 < text.len) {
        const c = text[i];
        if (c == '(') paren_depth += 1;
        if (c == ')' and paren_depth > 0) paren_depth -= 1;
        if (paren_depth == 0 and c == ' ' and i + 4 < text.len) {
            if (startsWithIgnoreCase(text[i..], " and ")) {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Evaluate a single atom: either a media type or a parenthesized condition.
fn evaluateAtom(atom: []const u8, vw: f32, vh: f32) bool {
    if (atom.len == 0) return true;

    // Parenthesized condition
    if (atom[0] == '(' and atom[atom.len - 1] == ')') {
        const inner = std.mem.trim(u8, atom[1 .. atom.len - 1], " \t");
        return evaluateCondition(inner, vw, vh);
    }

    // Media type keywords
    if (eqlIgnoreCase(atom, "all")) return true;
    if (eqlIgnoreCase(atom, "screen")) return true;
    if (eqlIgnoreCase(atom, "print")) return false;

    // Unknown media type — fail-open
    return true;
}

/// Evaluate a condition inside parentheses (e.g. "min-width: 768px").
fn evaluateCondition(cond: []const u8, vw: f32, vh: f32) bool {
    // Check for prefers-color-scheme
    if (startsWithIgnoreCase(cond, "prefers-color-scheme")) {
        // Find value after ':'
        const colon_pos = std.mem.indexOf(u8, cond, ":") orelse return true;
        const value = std.mem.trim(u8, cond[colon_pos + 1 ..], " \t");
        // suzume uses light theme (most sites expect light mode)
        if (eqlIgnoreCase(value, "light")) return true;
        if (eqlIgnoreCase(value, "dark")) return false;
        return true;
    }

    // Check for min-width, max-width, min-height, max-height
    const colon_pos = std.mem.indexOf(u8, cond, ":") orelse {
        // No colon — could be e.g. "(color)" — boolean feature, fail-open (true)
        if (eqlIgnoreCase(cond, "color")) return true;
        return true;
    };
    const prop = std.mem.trim(u8, cond[0..colon_pos], " \t");
    const value = std.mem.trim(u8, cond[colon_pos + 1 ..], " \t");

    // Interaction media features
    if (eqlIgnoreCase(prop, "hover")) {
        if (eqlIgnoreCase(value, "hover")) return true;
        if (eqlIgnoreCase(value, "none")) return false;
        return true;
    }
    if (eqlIgnoreCase(prop, "any-hover")) {
        if (eqlIgnoreCase(value, "hover")) return true;
        if (eqlIgnoreCase(value, "none")) return false;
        return true;
    }
    if (eqlIgnoreCase(prop, "pointer")) {
        if (eqlIgnoreCase(value, "fine")) return true;
        if (eqlIgnoreCase(value, "coarse")) return false;
        if (eqlIgnoreCase(value, "none")) return false;
        return true;
    }
    if (eqlIgnoreCase(prop, "any-pointer")) {
        if (eqlIgnoreCase(value, "fine")) return true;
        if (eqlIgnoreCase(value, "coarse")) return false;
        if (eqlIgnoreCase(value, "none")) return false;
        return true;
    }
    // User preference media features
    if (eqlIgnoreCase(prop, "prefers-reduced-motion")) {
        if (eqlIgnoreCase(value, "reduce")) return false;
        if (eqlIgnoreCase(value, "no-preference")) return true;
        return true;
    }
    if (eqlIgnoreCase(prop, "prefers-contrast")) {
        if (eqlIgnoreCase(value, "no-preference")) return true;
        return false;
    }
    // Scripting and display mode
    if (eqlIgnoreCase(prop, "scripting")) {
        if (eqlIgnoreCase(value, "enabled")) return true;
        return false;
    }
    if (eqlIgnoreCase(prop, "display-mode")) {
        if (eqlIgnoreCase(value, "browser")) return true;
        return false;
    }
    // Orientation
    if (eqlIgnoreCase(prop, "orientation")) {
        if (eqlIgnoreCase(value, "landscape")) return vw > vh;
        if (eqlIgnoreCase(value, "portrait")) return vw <= vh;
        return true;
    }
    // Color features
    if (eqlIgnoreCase(prop, "color")) return true;
    if (eqlIgnoreCase(prop, "color-index")) {
        if (eqlIgnoreCase(value, "0")) return true;
        return false;
    }
    if (eqlIgnoreCase(prop, "color-gamut")) {
        if (eqlIgnoreCase(value, "srgb")) return true;
        return false;
    }

    const px_val = parsePixelValue(value) orelse return true; // unknown unit — fail-open

    if (eqlIgnoreCase(prop, "min-width")) return vw >= px_val;
    if (eqlIgnoreCase(prop, "max-width")) return vw <= px_val;
    if (eqlIgnoreCase(prop, "min-height")) return vh >= px_val;
    if (eqlIgnoreCase(prop, "max-height")) return vh <= px_val;
    const eps: f32 = 0.5; // half pixel is close enough for exact viewport queries
    if (eqlIgnoreCase(prop, "width")) return @abs(vw - px_val) < eps;
    if (eqlIgnoreCase(prop, "height")) return @abs(vh - px_val) < eps;

    // Unknown condition — fail-open
    return true;
}

/// Parse a pixel value from a string like "768px", "1024", "48em".
/// Only handles px and unitless. Returns null for unknown units.
fn parsePixelValue(s: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;

    // Find numeric part end
    var num_end: usize = 0;
    var has_dot = false;
    for (trimmed) |c| {
        if ((c == '-' or c == '+') and num_end == 0) {
            num_end += 1;
        } else if (c >= '0' and c <= '9') {
            num_end += 1;
        } else if (c == '.' and !has_dot) {
            has_dot = true;
            num_end += 1;
        } else {
            break;
        }
    }
    if (num_end == 0) return null;

    const num = std.fmt.parseFloat(f32, trimmed[0..num_end]) catch return null;
    const unit = std.mem.trim(u8, trimmed[num_end..], " \t");

    if (unit.len == 0 or eqlIgnoreCase(unit, "px")) return num;
    if (eqlIgnoreCase(unit, "em") or eqlIgnoreCase(unit, "rem")) return num * 16.0;
    if (eqlIgnoreCase(unit, "pt")) return num * 4.0 / 3.0;
    if (eqlIgnoreCase(unit, "cm")) return num * 96.0 / 2.54;
    if (eqlIgnoreCase(unit, "mm")) return num * 96.0 / 25.4;
    if (eqlIgnoreCase(unit, "in")) return num * 96.0;

    return null;
}

const startsWithIgnoreCase = util.startsWithIgnoreCase;
const eqlIgnoreCase = util.eqlIgnoreCase;
