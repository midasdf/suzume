const std = @import("std");
const values = @import("values.zig");
const ast = @import("ast.zig");
const util = @import("util.zig");

// ── Color Parsing ───────────────────────────────────────────────────

pub fn parseColor(raw: []const u8) ?values.Color {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '#') {
        return parseHexColor(trimmed);
    }

    if (startsWithIgnoreCase(trimmed, "rgba(")) {
        return parseRgbaFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "rgb(")) {
        return parseRgbFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "hsla(")) {
        return parseHslaFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "hsl(")) {
        return parseHslFunc(trimmed);
    }

    return namedColor(trimmed);
}

fn parseHexColor(hex: []const u8) ?values.Color {
    const digits = hex[1..];
    if (digits.len == 3) {
        const r = hexDigit(digits[0]) orelse return null;
        const g = hexDigit(digits[1]) orelse return null;
        const b = hexDigit(digits[2]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    } else if (digits.len == 4) {
        const r = hexDigit(digits[0]) orelse return null;
        const g = hexDigit(digits[1]) orelse return null;
        const b = hexDigit(digits[2]) orelse return null;
        const a = hexDigit(digits[3]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = a * 17 };
    } else if (digits.len == 6) {
        const r = parseHexByte(digits[0..2]) orelse return null;
        const g = parseHexByte(digits[2..4]) orelse return null;
        const b = parseHexByte(digits[4..6]) orelse return null;
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    } else if (digits.len == 8) {
        const r = parseHexByte(digits[0..2]) orelse return null;
        const g = parseHexByte(digits[2..4]) orelse return null;
        const b = parseHexByte(digits[4..6]) orelse return null;
        const a = parseHexByte(digits[6..8]) orelse return null;
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    return null;
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexByte(s: *const [2]u8) ?u8 {
    const hi = hexDigit(s[0]) orelse return null;
    const lo = hexDigit(s[1]) orelse return null;
    return hi * 16 + lo;
}

fn extractFuncArgs(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.lastIndexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    return text[start + 1 .. end];
}

fn parseRgbFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var nums: [3]f32 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 3) break;
        if (tok.len > 0 and tok[tok.len - 1] == '%') {
            const pct = std.fmt.parseFloat(f32, tok[0 .. tok.len - 1]) catch return null;
            nums[count] = pct * 255.0 / 100.0;
        } else {
            nums[count] = std.fmt.parseFloat(f32, tok) catch return null;
        }
        count += 1;
    }
    if (count < 3) return null;
    return .{
        .r = clampToU8(nums[0]),
        .g = clampToU8(nums[1]),
        .b = clampToU8(nums[2]),
        .a = 255,
    };
}

fn parseRgbaFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var nums: [4]f32 = undefined;
    var count: usize = 0;
    var has_pct: [4]bool = .{ false, false, false, false };
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        if (tok.len > 0 and tok[tok.len - 1] == '%') {
            has_pct[count] = true;
            nums[count] = std.fmt.parseFloat(f32, tok[0 .. tok.len - 1]) catch return null;
        } else {
            nums[count] = std.fmt.parseFloat(f32, tok) catch return null;
        }
        count += 1;
    }
    if (count < 4) return null;
    const r = if (has_pct[0]) nums[0] * 255.0 / 100.0 else nums[0];
    const g = if (has_pct[1]) nums[1] * 255.0 / 100.0 else nums[1];
    const b = if (has_pct[2]) nums[2] * 255.0 / 100.0 else nums[2];
    // Alpha: percentage means /100, otherwise 0.0-1.0
    const a = if (has_pct[3]) nums[3] * 255.0 / 100.0 else nums[3] * 255.0;
    return .{
        .r = clampToU8(r),
        .g = clampToU8(g),
        .b = clampToU8(b),
        .a = clampToU8(a),
    };
}

fn hslToRgb(h_deg: f32, s_pct: f32, l_pct: f32) struct { r: u8, g: u8, b: u8 } {
    const s = std.math.clamp(s_pct / 100.0, 0.0, 1.0);
    const l = std.math.clamp(l_pct / 100.0, 0.0, 1.0);
    var h = @mod(h_deg, 360.0);
    if (h < 0) h += 360.0;

    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const h_prime = h / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = l - c / 2.0;

    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;

    if (h_prime < 1.0) {
        r1 = c;
        g1 = x;
    } else if (h_prime < 2.0) {
        r1 = x;
        g1 = c;
    } else if (h_prime < 3.0) {
        g1 = c;
        b1 = x;
    } else if (h_prime < 4.0) {
        g1 = x;
        b1 = c;
    } else if (h_prime < 5.0) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    return .{
        .r = @intFromFloat(std.math.clamp((r1 + m) * 255.0 + 0.5, 0.0, 255.0)),
        .g = @intFromFloat(std.math.clamp((g1 + m) * 255.0 + 0.5, 0.0, 255.0)),
        .b = @intFromFloat(std.math.clamp((b1 + m) * 255.0 + 0.5, 0.0, 255.0)),
    };
}

fn parseHslFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var vals: [3]f32 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", \t");
    while (iter.next()) |tok| {
        if (count >= 3) break;
        const clean = if (tok.len > 0 and tok[tok.len - 1] == '%') tok[0 .. tok.len - 1] else tok;
        const clean2 = if (std.mem.endsWith(u8, clean, "deg")) clean[0 .. clean.len - 3] else clean;
        vals[count] = std.fmt.parseFloat(f32, clean2) catch return null;
        count += 1;
    }
    if (count < 3) return null;
    const rgb = hslToRgb(vals[0], vals[1], vals[2]);
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
}

fn parseHslaFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var vals: [4]f32 = undefined;
    var count: usize = 0;
    var alpha_is_percentage = false;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        const is_pct = tok.len > 0 and tok[tok.len - 1] == '%';
        if (count == 3 and is_pct) alpha_is_percentage = true;
        const clean = if (is_pct) tok[0 .. tok.len - 1] else tok;
        const clean2 = if (std.mem.endsWith(u8, clean, "deg")) clean[0 .. clean.len - 3] else clean;
        vals[count] = std.fmt.parseFloat(f32, clean2) catch return null;
        count += 1;
    }
    if (count < 4) return null;
    const rgb = hslToRgb(vals[0], vals[1], vals[2]);
    const alpha_f = if (alpha_is_percentage) vals[3] * 255.0 / 100.0 else vals[3] * 255.0;
    return .{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
        .a = @intFromFloat(std.math.clamp(alpha_f, 0.0, 255.0)),
    };
}

fn clampToU8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 255.0));
}

const startsWithIgnoreCase = util.startsWithIgnoreCase;
const eqlIgnoreCase = util.eqlIgnoreCase;

/// Lowercase s into buf. Returns null if s is longer than buf.
fn toLowerBuf(s: []const u8, buf: []u8) ?[]u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = util.toLower(c);
    return buf[0..s.len];
}

const NamedColorEntry = struct { []const u8, u32 };

const named_color_table = std.StaticStringMap(values.Color).initComptime(.{
    // CSS Color Level 4 — full 148 named colors + grey aliases
    .{ "transparent", values.Color{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    // currentcolor is NOT in this table — handled at cascade level in cascade.zig
    .{ "aliceblue", values.Color{ .r = 240, .g = 248, .b = 255, .a = 255 } },
    .{ "antiquewhite", values.Color{ .r = 250, .g = 235, .b = 215, .a = 255 } },
    .{ "aqua", values.Color{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "aquamarine", values.Color{ .r = 127, .g = 255, .b = 212, .a = 255 } },
    .{ "azure", values.Color{ .r = 240, .g = 255, .b = 255, .a = 255 } },
    .{ "beige", values.Color{ .r = 245, .g = 245, .b = 220, .a = 255 } },
    .{ "bisque", values.Color{ .r = 255, .g = 228, .b = 196, .a = 255 } },
    .{ "black", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "blanchedalmond", values.Color{ .r = 255, .g = 235, .b = 205, .a = 255 } },
    .{ "blue", values.Color{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    .{ "blueviolet", values.Color{ .r = 138, .g = 43, .b = 226, .a = 255 } },
    .{ "brown", values.Color{ .r = 165, .g = 42, .b = 42, .a = 255 } },
    .{ "burlywood", values.Color{ .r = 222, .g = 184, .b = 135, .a = 255 } },
    .{ "cadetblue", values.Color{ .r = 95, .g = 158, .b = 160, .a = 255 } },
    .{ "chartreuse", values.Color{ .r = 127, .g = 255, .b = 0, .a = 255 } },
    .{ "chocolate", values.Color{ .r = 210, .g = 105, .b = 30, .a = 255 } },
    .{ "coral", values.Color{ .r = 255, .g = 127, .b = 80, .a = 255 } },
    .{ "cornflowerblue", values.Color{ .r = 100, .g = 149, .b = 237, .a = 255 } },
    .{ "cornsilk", values.Color{ .r = 255, .g = 248, .b = 220, .a = 255 } },
    .{ "crimson", values.Color{ .r = 220, .g = 20, .b = 60, .a = 255 } },
    .{ "cyan", values.Color{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "darkblue", values.Color{ .r = 0, .g = 0, .b = 139, .a = 255 } },
    .{ "darkcyan", values.Color{ .r = 0, .g = 139, .b = 139, .a = 255 } },
    .{ "darkgoldenrod", values.Color{ .r = 184, .g = 134, .b = 11, .a = 255 } },
    .{ "darkgray", values.Color{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkgreen", values.Color{ .r = 0, .g = 100, .b = 0, .a = 255 } },
    .{ "darkgrey", values.Color{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkkhaki", values.Color{ .r = 189, .g = 183, .b = 107, .a = 255 } },
    .{ "darkmagenta", values.Color{ .r = 139, .g = 0, .b = 139, .a = 255 } },
    .{ "darkolivegreen", values.Color{ .r = 85, .g = 107, .b = 47, .a = 255 } },
    .{ "darkorange", values.Color{ .r = 255, .g = 140, .b = 0, .a = 255 } },
    .{ "darkorchid", values.Color{ .r = 153, .g = 50, .b = 204, .a = 255 } },
    .{ "darkred", values.Color{ .r = 139, .g = 0, .b = 0, .a = 255 } },
    .{ "darksalmon", values.Color{ .r = 233, .g = 150, .b = 122, .a = 255 } },
    .{ "darkseagreen", values.Color{ .r = 143, .g = 188, .b = 143, .a = 255 } },
    .{ "darkslateblue", values.Color{ .r = 72, .g = 61, .b = 139, .a = 255 } },
    .{ "darkslategray", values.Color{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkslategrey", values.Color{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkturquoise", values.Color{ .r = 0, .g = 206, .b = 209, .a = 255 } },
    .{ "darkviolet", values.Color{ .r = 148, .g = 0, .b = 211, .a = 255 } },
    .{ "deeppink", values.Color{ .r = 255, .g = 20, .b = 147, .a = 255 } },
    .{ "deepskyblue", values.Color{ .r = 0, .g = 191, .b = 255, .a = 255 } },
    .{ "dimgray", values.Color{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dimgrey", values.Color{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dodgerblue", values.Color{ .r = 30, .g = 144, .b = 255, .a = 255 } },
    .{ "firebrick", values.Color{ .r = 178, .g = 34, .b = 34, .a = 255 } },
    .{ "floralwhite", values.Color{ .r = 255, .g = 250, .b = 240, .a = 255 } },
    .{ "forestgreen", values.Color{ .r = 34, .g = 139, .b = 34, .a = 255 } },
    .{ "fuchsia", values.Color{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "gainsboro", values.Color{ .r = 220, .g = 220, .b = 220, .a = 255 } },
    .{ "ghostwhite", values.Color{ .r = 248, .g = 248, .b = 255, .a = 255 } },
    .{ "gold", values.Color{ .r = 255, .g = 215, .b = 0, .a = 255 } },
    .{ "goldenrod", values.Color{ .r = 218, .g = 165, .b = 32, .a = 255 } },
    .{ "gray", values.Color{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "green", values.Color{ .r = 0, .g = 128, .b = 0, .a = 255 } },
    .{ "greenyellow", values.Color{ .r = 173, .g = 255, .b = 47, .a = 255 } },
    .{ "grey", values.Color{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "honeydew", values.Color{ .r = 240, .g = 255, .b = 240, .a = 255 } },
    .{ "hotpink", values.Color{ .r = 255, .g = 105, .b = 180, .a = 255 } },
    .{ "indianred", values.Color{ .r = 205, .g = 92, .b = 92, .a = 255 } },
    .{ "indigo", values.Color{ .r = 75, .g = 0, .b = 130, .a = 255 } },
    .{ "ivory", values.Color{ .r = 255, .g = 255, .b = 240, .a = 255 } },
    .{ "khaki", values.Color{ .r = 240, .g = 230, .b = 140, .a = 255 } },
    .{ "lavender", values.Color{ .r = 230, .g = 230, .b = 250, .a = 255 } },
    .{ "lavenderblush", values.Color{ .r = 255, .g = 240, .b = 245, .a = 255 } },
    .{ "lawngreen", values.Color{ .r = 124, .g = 252, .b = 0, .a = 255 } },
    .{ "lemonchiffon", values.Color{ .r = 255, .g = 250, .b = 205, .a = 255 } },
    .{ "lightblue", values.Color{ .r = 173, .g = 216, .b = 230, .a = 255 } },
    .{ "lightcoral", values.Color{ .r = 240, .g = 128, .b = 128, .a = 255 } },
    .{ "lightcyan", values.Color{ .r = 224, .g = 255, .b = 255, .a = 255 } },
    .{ "lightgoldenrodyellow", values.Color{ .r = 250, .g = 250, .b = 210, .a = 255 } },
    .{ "lightgray", values.Color{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightgreen", values.Color{ .r = 144, .g = 238, .b = 144, .a = 255 } },
    .{ "lightgrey", values.Color{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightpink", values.Color{ .r = 255, .g = 182, .b = 193, .a = 255 } },
    .{ "lightsalmon", values.Color{ .r = 255, .g = 160, .b = 122, .a = 255 } },
    .{ "lightseagreen", values.Color{ .r = 32, .g = 178, .b = 170, .a = 255 } },
    .{ "lightskyblue", values.Color{ .r = 135, .g = 206, .b = 250, .a = 255 } },
    .{ "lightslategray", values.Color{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightslategrey", values.Color{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightsteelblue", values.Color{ .r = 176, .g = 196, .b = 222, .a = 255 } },
    .{ "lightyellow", values.Color{ .r = 255, .g = 255, .b = 224, .a = 255 } },
    .{ "lime", values.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } },
    .{ "limegreen", values.Color{ .r = 50, .g = 205, .b = 50, .a = 255 } },
    .{ "linen", values.Color{ .r = 250, .g = 240, .b = 230, .a = 255 } },
    .{ "magenta", values.Color{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "maroon", values.Color{ .r = 128, .g = 0, .b = 0, .a = 255 } },
    .{ "mediumaquamarine", values.Color{ .r = 102, .g = 205, .b = 170, .a = 255 } },
    .{ "mediumblue", values.Color{ .r = 0, .g = 0, .b = 205, .a = 255 } },
    .{ "mediumorchid", values.Color{ .r = 186, .g = 85, .b = 211, .a = 255 } },
    .{ "mediumpurple", values.Color{ .r = 147, .g = 112, .b = 219, .a = 255 } },
    .{ "mediumseagreen", values.Color{ .r = 60, .g = 179, .b = 113, .a = 255 } },
    .{ "mediumslateblue", values.Color{ .r = 123, .g = 104, .b = 238, .a = 255 } },
    .{ "mediumspringgreen", values.Color{ .r = 0, .g = 250, .b = 154, .a = 255 } },
    .{ "mediumturquoise", values.Color{ .r = 72, .g = 209, .b = 204, .a = 255 } },
    .{ "mediumvioletred", values.Color{ .r = 199, .g = 21, .b = 133, .a = 255 } },
    .{ "midnightblue", values.Color{ .r = 25, .g = 25, .b = 112, .a = 255 } },
    .{ "mintcream", values.Color{ .r = 245, .g = 255, .b = 250, .a = 255 } },
    .{ "mistyrose", values.Color{ .r = 255, .g = 228, .b = 225, .a = 255 } },
    .{ "moccasin", values.Color{ .r = 255, .g = 228, .b = 181, .a = 255 } },
    .{ "navajowhite", values.Color{ .r = 255, .g = 222, .b = 173, .a = 255 } },
    .{ "navy", values.Color{ .r = 0, .g = 0, .b = 128, .a = 255 } },
    .{ "oldlace", values.Color{ .r = 253, .g = 245, .b = 230, .a = 255 } },
    .{ "olive", values.Color{ .r = 128, .g = 128, .b = 0, .a = 255 } },
    .{ "olivedrab", values.Color{ .r = 107, .g = 142, .b = 35, .a = 255 } },
    .{ "orange", values.Color{ .r = 255, .g = 165, .b = 0, .a = 255 } },
    .{ "orangered", values.Color{ .r = 255, .g = 69, .b = 0, .a = 255 } },
    .{ "orchid", values.Color{ .r = 218, .g = 112, .b = 214, .a = 255 } },
    .{ "palegoldenrod", values.Color{ .r = 238, .g = 232, .b = 170, .a = 255 } },
    .{ "palegreen", values.Color{ .r = 152, .g = 251, .b = 152, .a = 255 } },
    .{ "paleturquoise", values.Color{ .r = 175, .g = 238, .b = 238, .a = 255 } },
    .{ "palevioletred", values.Color{ .r = 219, .g = 112, .b = 147, .a = 255 } },
    .{ "papayawhip", values.Color{ .r = 255, .g = 239, .b = 213, .a = 255 } },
    .{ "peachpuff", values.Color{ .r = 255, .g = 218, .b = 185, .a = 255 } },
    .{ "peru", values.Color{ .r = 205, .g = 133, .b = 63, .a = 255 } },
    .{ "pink", values.Color{ .r = 255, .g = 192, .b = 203, .a = 255 } },
    .{ "plum", values.Color{ .r = 221, .g = 160, .b = 221, .a = 255 } },
    .{ "powderblue", values.Color{ .r = 176, .g = 224, .b = 230, .a = 255 } },
    .{ "purple", values.Color{ .r = 128, .g = 0, .b = 128, .a = 255 } },
    .{ "rebeccapurple", values.Color{ .r = 102, .g = 51, .b = 153, .a = 255 } },
    .{ "red", values.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    .{ "rosybrown", values.Color{ .r = 188, .g = 143, .b = 143, .a = 255 } },
    .{ "royalblue", values.Color{ .r = 65, .g = 105, .b = 225, .a = 255 } },
    .{ "saddlebrown", values.Color{ .r = 139, .g = 69, .b = 19, .a = 255 } },
    .{ "salmon", values.Color{ .r = 250, .g = 128, .b = 114, .a = 255 } },
    .{ "sandybrown", values.Color{ .r = 244, .g = 164, .b = 96, .a = 255 } },
    .{ "seagreen", values.Color{ .r = 46, .g = 139, .b = 87, .a = 255 } },
    .{ "seashell", values.Color{ .r = 255, .g = 245, .b = 238, .a = 255 } },
    .{ "sienna", values.Color{ .r = 160, .g = 82, .b = 45, .a = 255 } },
    .{ "silver", values.Color{ .r = 192, .g = 192, .b = 192, .a = 255 } },
    .{ "skyblue", values.Color{ .r = 135, .g = 206, .b = 235, .a = 255 } },
    .{ "slateblue", values.Color{ .r = 106, .g = 90, .b = 205, .a = 255 } },
    .{ "slategray", values.Color{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "slategrey", values.Color{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "snow", values.Color{ .r = 255, .g = 250, .b = 250, .a = 255 } },
    .{ "springgreen", values.Color{ .r = 0, .g = 255, .b = 127, .a = 255 } },
    .{ "steelblue", values.Color{ .r = 70, .g = 130, .b = 180, .a = 255 } },
    .{ "tan", values.Color{ .r = 210, .g = 180, .b = 140, .a = 255 } },
    .{ "teal", values.Color{ .r = 0, .g = 128, .b = 128, .a = 255 } },
    .{ "thistle", values.Color{ .r = 216, .g = 191, .b = 216, .a = 255 } },
    .{ "tomato", values.Color{ .r = 255, .g = 99, .b = 71, .a = 255 } },
    .{ "turquoise", values.Color{ .r = 64, .g = 224, .b = 208, .a = 255 } },
    .{ "violet", values.Color{ .r = 238, .g = 130, .b = 238, .a = 255 } },
    .{ "wheat", values.Color{ .r = 245, .g = 222, .b = 179, .a = 255 } },
    .{ "white", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "whitesmoke", values.Color{ .r = 245, .g = 245, .b = 245, .a = 255 } },
    .{ "yellow", values.Color{ .r = 255, .g = 255, .b = 0, .a = 255 } },
    .{ "yellowgreen", values.Color{ .r = 154, .g = 205, .b = 50, .a = 255 } },
});

fn namedColor(name: []const u8) ?values.Color {
    // StaticStringMap is case-sensitive, so lowercase for lookup
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| {
        buf[i] = util.toLower(c);
    }
    return named_color_table.get(buf[0..name.len]);
}

// ── Length Parsing ──────────────────────────────────────────────────

pub fn parseLength(raw: []const u8) ?values.Length {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Unitless zero
    if (std.mem.eql(u8, trimmed, "0")) {
        return .{ .value = 0, .unit = .px };
    }

    // Find where the number ends and unit begins
    var num_end: usize = 0;
    for (trimmed, 0..) |c, i| {
        if ((c == '-' or c == '+') and i == 0) {
            num_end = i + 1;
        } else if (c == '.' or (c >= '0' and c <= '9')) {
            num_end = i + 1;
        } else {
            break;
        }
    }
    if (num_end == 0) return null;

    const num_str = trimmed[0..num_end];
    const unit_str = trimmed[num_end..];

    const number = std.fmt.parseFloat(f32, num_str) catch return null;
    const unit = parseUnit(unit_str) orelse return null;

    return .{ .value = number, .unit = unit };
}

fn parseUnit(unit_str: []const u8) ?values.Unit {
    if (unit_str.len == 0) return null;

    const unit_map = std.StaticStringMap(values.Unit).initComptime(.{
        .{ "px", .px },
        .{ "em", .em },
        .{ "rem", .rem },
        .{ "vh", .vh },
        .{ "vw", .vw },
        .{ "vmin", .vmin },
        .{ "vmax", .vmax },
        .{ "pt", .pt },
        .{ "cm", .cm },
        .{ "mm", .mm },
        .{ "in", .in_ },
        .{ "ch", .ch },
        .{ "ex", .ex },
        .{ "%", .percent },
        .{ "fr", .fr },
        .{ "deg", .deg },
        .{ "rad", .rad },
        .{ "s", .s },
        .{ "ms", .ms },
        .{ "svh", .svh },
        .{ "dvh", .dvh },
        .{ "lvh", .lvh },
        .{ "svw", .svw },
        .{ "dvw", .dvw },
        .{ "lvw", .lvw },
    });

    // Lowercase for lookup
    var buf: [8]u8 = undefined;
    if (unit_str.len > buf.len) return null;
    for (unit_str, 0..) |c, i| {
        buf[i] = util.toLower(c);
    }
    return unit_map.get(buf[0..unit_str.len]);
}

// ── var() Parsing ───────────────────────────────────────────────────

pub fn parseVarRef(raw: []const u8) ?values.VarRef {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!startsWithIgnoreCase(trimmed, "var(")) return null;
    if (trimmed.len < 5) return null; // var() minimum
    if (trimmed[trimmed.len - 1] != ')') return null;

    const inner = std.mem.trim(u8, trimmed[4 .. trimmed.len - 1], " \t");

    // Must start with --
    if (!std.mem.startsWith(u8, inner, "--")) return null;

    // Find comma for fallback
    // Need to handle nested parens in fallback
    var paren_depth: usize = 0;
    var comma_pos: ?usize = null;
    for (inner, 0..) |c, i| {
        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_pos = i;
            break;
        }
    }

    if (comma_pos) |cp| {
        const name = std.mem.trim(u8, inner[0..cp], " \t");
        const fallback = std.mem.trim(u8, inner[cp + 1 ..], " \t");
        return .{ .name = name, .fallback = if (fallback.len > 0) fallback else null };
    } else {
        return .{ .name = std.mem.trim(u8, inner, " \t"), .fallback = null };
    }
}

// ── Shorthand Expansion ─────────────────────────────────────────────

pub fn expandShorthand(property_name: []const u8, value_raw: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    const trimmed = std.mem.trim(u8, value_raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    // CSS property names are case-insensitive; normalise before comparing.
    var name_buf: [64]u8 = undefined;
    const name = toLowerBuf(property_name, &name_buf) orelse return null;

    if (std.mem.eql(u8, name, "margin")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .margin_top, .name = "margin-top" },
            .{ .id = .margin_right, .name = "margin-right" },
            .{ .id = .margin_bottom, .name = "margin-bottom" },
            .{ .id = .margin_left, .name = "margin-left" },
        }, allocator);
    }
    if (std.mem.eql(u8, name, "padding")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .padding_top, .name = "padding-top" },
            .{ .id = .padding_right, .name = "padding-right" },
            .{ .id = .padding_bottom, .name = "padding-bottom" },
            .{ .id = .padding_left, .name = "padding-left" },
        }, allocator);
    }
    // list-style shorthand: map to list-style-type (simplified — ignores position/image)
    if (std.mem.eql(u8, name, "list-style")) {
        // Extract list-style-type keyword from the shorthand value
        // e.g., "none", "disc", "decimal", "square inside", "none outside"
        var type_val = trimmed;
        var iter = std.mem.splitScalar(u8, trimmed, ' ');
        while (iter.next()) |word| {
            const w = std.mem.trim(u8, word, " ");
            if (w.len == 0) continue;
            if (eqlIgnoreCase(w, "none") or eqlIgnoreCase(w, "disc") or
                eqlIgnoreCase(w, "circle") or eqlIgnoreCase(w, "square") or
                eqlIgnoreCase(w, "decimal"))
            {
                type_val = w;
                break;
            }
        }
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .list_style_type, .property_name = "list-style-type", .value_raw = type_val, .important = false };
        return decls;
    }
    if (std.mem.eql(u8, name, "border-radius")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .border_radius_top_left, .name = "border-top-left-radius" },
            .{ .id = .border_radius_top_right, .name = "border-top-right-radius" },
            .{ .id = .border_radius_bottom_right, .name = "border-bottom-right-radius" },
            .{ .id = .border_radius_bottom_left, .name = "border-bottom-left-radius" },
        }, allocator);
    }
    if (std.mem.eql(u8, name, "border")) {
        return expandBorder(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "background")) {
        return expandBackground(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "flex")) {
        return expandFlex(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "flex-flow")) {
        return expandFlexFlow(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "overflow")) {
        return expandOverflow(trimmed, allocator);
    }
    // Grid shorthands
    if (std.mem.eql(u8, name, "grid-column")) {
        return expandGridSlash(trimmed, .grid_column_start, "grid-column-start", .grid_column_end, "grid-column-end", allocator);
    }
    if (std.mem.eql(u8, name, "grid-row")) {
        return expandGridSlash(trimmed, .grid_row_start, "grid-row-start", .grid_row_end, "grid-row-end", allocator);
    }
    if (std.mem.eql(u8, name, "grid-gap")) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .gap, .property_name = "gap", .value_raw = trimmed, .important = false };
        return decls;
    }
    if (std.mem.eql(u8, name, "grid-column-gap")) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .column_gap, .property_name = "column-gap", .value_raw = trimmed, .important = false };
        return decls;
    }
    if (std.mem.eql(u8, name, "grid-row-gap")) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .row_gap, .property_name = "row-gap", .value_raw = trimmed, .important = false };
        return decls;
    }
    if (std.mem.eql(u8, name, "transition")) {
        return expandTransition(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "animation")) {
        return expandAnimation(trimmed, allocator);
    }
    if (std.mem.eql(u8, name, "outline")) {
        return expandOutline(trimmed, allocator);
    }
    return null;
}

const PropInfo = struct {
    id: ast.PropertyId,
    name: []const u8,
};

fn expandBoxShorthand(
    value: []const u8,
    props: *const [4]PropInfo,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    // Check for CSS-wide keywords
    if (isCssWideKeyword(value)) {
        return makeFourDecls(props, value, value, value, value, allocator);
    }

    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        parts[count] = tok;
        count += 1;
    }
    if (count == 0) return null;

    const top = parts[0];
    const right_val = if (count >= 2) parts[1] else top;
    const bottom = if (count >= 3) parts[2] else top;
    const left_val = if (count >= 4) parts[3] else right_val;

    return makeFourDecls(props, top, right_val, bottom, left_val, allocator);
}

fn makeFourDecls(
    props: *const [4]PropInfo,
    v0: []const u8,
    v1: []const u8,
    v2: []const u8,
    v3: []const u8,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 4) catch return null;
    const vals = [4][]const u8{ v0, v1, v2, v3 };
    for (props, 0..) |p, i| {
        decls[i] = .{
            .property = p.id,
            .property_name = p.name,
            .value_raw = vals[i],
            .important = false,
        };
    }
    return decls;
}

fn expandBorder(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    if (isCssWideKeyword(value)) {
        // 12 declarations: width/style/color for all 4 sides
        const decls = allocator.alloc(ast.Declaration, 12) catch return null;
        const sides = [4]struct { w: ast.PropertyId, s: ast.PropertyId, c: ast.PropertyId, wn: []const u8, sn: []const u8, cn: []const u8 }{
            .{ .w = .border_top_width, .s = .border_top_style, .c = .border_top_color, .wn = "border-top-width", .sn = "border-top-style", .cn = "border-top-color" },
            .{ .w = .border_right_width, .s = .border_right_style, .c = .border_right_color, .wn = "border-right-width", .sn = "border-right-style", .cn = "border-right-color" },
            .{ .w = .border_bottom_width, .s = .border_bottom_style, .c = .border_bottom_color, .wn = "border-bottom-width", .sn = "border-bottom-style", .cn = "border-bottom-color" },
            .{ .w = .border_left_width, .s = .border_left_style, .c = .border_left_color, .wn = "border-left-width", .sn = "border-left-style", .cn = "border-left-color" },
        };
        for (sides, 0..) |side, i| {
            decls[i * 3] = .{ .property = side.w, .property_name = side.wn, .value_raw = value, .important = false };
            decls[i * 3 + 1] = .{ .property = side.s, .property_name = side.sn, .value_raw = value, .important = false };
            decls[i * 3 + 2] = .{ .property = side.c, .property_name = side.cn, .value_raw = value, .important = false };
        }
        return decls;
    }

    // Parse "width style color" — each part is optional
    var width: []const u8 = "medium";
    var style: []const u8 = "none";
    var color_val: []const u8 = "currentcolor";

    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (isBorderStyle(tok)) {
            style = tok;
        } else if (parseLength(tok) != null) {
            width = tok;
        } else {
            // Assume it's a color
            color_val = tok;
        }
    }

    const decls = allocator.alloc(ast.Declaration, 12) catch return null;
    const side_names = [4]struct {
        wid: ast.PropertyId,
        sty: ast.PropertyId,
        col: ast.PropertyId,
        wn: []const u8,
        sn: []const u8,
        cn: []const u8,
    }{
        .{ .wid = .border_top_width, .sty = .border_top_style, .col = .border_top_color, .wn = "border-top-width", .sn = "border-top-style", .cn = "border-top-color" },
        .{ .wid = .border_right_width, .sty = .border_right_style, .col = .border_right_color, .wn = "border-right-width", .sn = "border-right-style", .cn = "border-right-color" },
        .{ .wid = .border_bottom_width, .sty = .border_bottom_style, .col = .border_bottom_color, .wn = "border-bottom-width", .sn = "border-bottom-style", .cn = "border-bottom-color" },
        .{ .wid = .border_left_width, .sty = .border_left_style, .col = .border_left_color, .wn = "border-left-width", .sn = "border-left-style", .cn = "border-left-color" },
    };

    for (side_names, 0..) |side, i| {
        decls[i * 3] = .{ .property = side.wid, .property_name = side.wn, .value_raw = width, .important = false };
        decls[i * 3 + 1] = .{ .property = side.sty, .property_name = side.sn, .value_raw = style, .important = false };
        decls[i * 3 + 2] = .{ .property = side.col, .property_name = side.cn, .value_raw = color_val, .important = false };
    }
    return decls;
}

fn isBorderStyle(tok: []const u8) bool {
    const styles = [_][]const u8{
        "none", "hidden", "dotted", "dashed", "solid",
        "double", "groove", "ridge", "inset", "outset",
    };
    for (styles) |s| {
        if (eqlIgnoreCase(tok, s)) return true;
    }
    return false;
}

fn expandBackground(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    if (isCssWideKeyword(value)) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .background_color, .property_name = "background-color", .value_raw = value, .important = false };
        return decls;
    }

    // First: try parsing the entire value as a single color (handles rgb(), hsl(), etc.)
    if (parseColor(value) != null) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .background_color, .property_name = "background-color", .value_raw = value, .important = false };
        return decls;
    }

    // Try to extract color, image (url), and repeat from the background shorthand
    var color_val: []const u8 = "transparent";
    var image_val: ?[]const u8 = null;
    var repeat_val: ?[]const u8 = null;

    // Tokenize respecting parentheses so rgb(...), url(...) etc. stay intact
    var tokens: [16][]const u8 = undefined;
    var token_count: usize = 0;
    {
        var i: usize = 0;
        while (i < value.len and token_count < tokens.len) {
            // Skip whitespace
            while (i < value.len and (value[i] == ' ' or value[i] == '\t')) i += 1;
            if (i >= value.len) break;
            const start = i;
            var depth: usize = 0;
            while (i < value.len) {
                if (value[i] == '(') {
                    depth += 1;
                } else if (value[i] == ')') {
                    if (depth > 0) depth -= 1;
                    if (depth == 0) { i += 1; break; }
                } else if ((value[i] == ' ' or value[i] == '\t') and depth == 0) {
                    break;
                }
                i += 1;
            }
            if (i > start) {
                tokens[token_count] = value[start..i];
                token_count += 1;
            }
        }
    }

    for (tokens[0..token_count]) |tok| {
        // Extract url(...) or linear-gradient(...) as background-image
        if (startsWithIgnoreCase(tok, "url(")) {
            image_val = tok;
            continue;
        }
        if (startsWithIgnoreCase(tok, "linear-gradient(") or
            startsWithIgnoreCase(tok, "-webkit-linear-gradient(") or
            startsWithIgnoreCase(tok, "-moz-linear-gradient("))
        {
            image_val = tok;
            continue;
        }
        // Extract repeat keywords as background-repeat
        if (eqlIgnoreCase(tok, "no-repeat") or eqlIgnoreCase(tok, "repeat") or
            eqlIgnoreCase(tok, "repeat-x") or eqlIgnoreCase(tok, "repeat-y"))
        {
            repeat_val = tok;
            continue;
        }
        // Skip other background keywords (position, size, attachment)
        if (isBackgroundKeyword(tok)) continue;
        // Try parsing as color (now handles rgb(), hsl() etc. properly)
        if (parseColor(tok) != null) {
            color_val = tok;
            continue;
        }
        // Try parsing as length (could be background-position)
        if (parseLength(tok) != null) continue;
    }

    // Count how many declarations we need
    var n: usize = 1; // always emit background-color
    if (image_val != null) n += 1;
    if (repeat_val != null) n += 1;

    const decls = allocator.alloc(ast.Declaration, n) catch return null;
    var idx: usize = 0;
    decls[idx] = .{ .property = .background_color, .property_name = "background-color", .value_raw = color_val, .important = false };
    idx += 1;
    if (image_val) |img| {
        decls[idx] = .{ .property = .background_image, .property_name = "background-image", .value_raw = img, .important = false };
        idx += 1;
    }
    if (repeat_val) |rep| {
        decls[idx] = .{ .property = .background_repeat, .property_name = "background-repeat", .value_raw = rep, .important = false };
        idx += 1;
    }
    return decls;
}

fn isBackgroundKeyword(tok: []const u8) bool {
    const keywords = [_][]const u8{
        "no-repeat", "repeat",  "repeat-x", "repeat-y",
        "cover",     "contain", "center",   "top",
        "bottom",    "left",    "right",    "fixed",
        "scroll",    "local",
    };
    for (keywords) |kw| {
        if (eqlIgnoreCase(tok, kw)) return true;
    }
    return false;
}

fn expandFlex(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 3) catch return null;

    if (isCssWideKeyword(value)) {
        decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = value, .important = false };
        decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = value, .important = false };
        decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = value, .important = false };
        return decls;
    }

    // flex: none → 0 0 auto
    if (eqlIgnoreCase(value, "none")) {
        decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = "0", .important = false };
        decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "0", .important = false };
        decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "auto", .important = false };
        return decls;
    }

    // flex: auto → 1 1 auto
    if (eqlIgnoreCase(value, "auto")) {
        decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = "1", .important = false };
        decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
        decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "auto", .important = false };
        return decls;
    }

    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (count >= 3) break;
        parts[count] = tok;
        count += 1;
    }

    if (count == 1) {
        // flex: <number> → grow=number, shrink=1, basis=0%
        decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
        decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
        decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "0%", .important = false };
    } else if (count == 2) {
        // flex: <grow> <shrink|basis>
        // If parts[1] contains a letter or '%', treat as basis (grow=parts[0], shrink=1, basis=parts[1])
        // If parts[1] is purely numeric, treat as shrink (grow=parts[0], shrink=parts[1], basis=0%)
        const second_is_basis = blk: {
            for (parts[1]) |c| {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '%') break :blk true;
            }
            break :blk false;
        };
        if (second_is_basis) {
            // flex: grow basis
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[1], .important = false };
        } else {
            // flex: grow shrink
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[1], .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "0%", .important = false };
        }
    } else {
        // flex: grow shrink basis
        decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
        decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[1], .important = false };
        decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[2], .important = false };
    }
    return decls;
}

fn expandFlexFlow(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 2) catch return null;
    decls[0] = .{ .property = .flex_direction, .property_name = "flex-direction", .value_raw = "row", .important = false };
    decls[1] = .{ .property = .flex_wrap, .property_name = "flex-wrap", .value_raw = "nowrap", .important = false };

    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |token| {
        if (eqlIgnoreCase(token, "row") or eqlIgnoreCase(token, "column") or
            eqlIgnoreCase(token, "row-reverse") or eqlIgnoreCase(token, "column-reverse"))
        {
            decls[0].value_raw = token;
        } else if (eqlIgnoreCase(token, "wrap") or eqlIgnoreCase(token, "nowrap") or
            eqlIgnoreCase(token, "wrap-reverse"))
        {
            decls[1].value_raw = token;
        }
    }
    return decls;
}

fn expandOverflow(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 2) catch return null;

    var parts: [2][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (count >= 2) break;
        parts[count] = tok;
        count += 1;
    }
    if (count == 0) return null;

    const x_val = parts[0];
    const y_val = if (count >= 2) parts[1] else x_val;

    decls[0] = .{ .property = .overflow_x, .property_name = "overflow-x", .value_raw = x_val, .important = false };
    decls[1] = .{ .property = .overflow_y, .property_name = "overflow-y", .value_raw = y_val, .important = false };
    return decls;
}

fn expandGridSlash(
    value: []const u8,
    start_id: ast.PropertyId,
    start_name: []const u8,
    end_id: ast.PropertyId,
    end_name: []const u8,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 2) catch return null;
    // Split by " / "
    if (std.mem.indexOf(u8, value, "/")) |slash_pos| {
        const start_val = std.mem.trim(u8, value[0..slash_pos], " \t");
        const end_val = std.mem.trim(u8, value[slash_pos + 1 ..], " \t");
        decls[0] = .{ .property = start_id, .property_name = start_name, .value_raw = start_val, .important = false };
        decls[1] = .{ .property = end_id, .property_name = end_name, .value_raw = end_val, .important = false };
    } else {
        // No slash: start = value, end = auto (0)
        decls[0] = .{ .property = start_id, .property_name = start_name, .value_raw = value, .important = false };
        decls[1] = .{ .property = end_id, .property_name = end_name, .value_raw = "auto", .important = false };
    }
    return decls;
}

fn isCssWideKeyword(value: []const u8) bool {
    return eqlIgnoreCase(value, "inherit") or
        eqlIgnoreCase(value, "initial") or
        eqlIgnoreCase(value, "unset") or
        eqlIgnoreCase(value, "revert");
}

fn expandTransition(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    // Simplest: scan tokens for a time value, treat it as transition-duration.
    // E.g. "all 0.3s ease" → transition-duration: 0.3s
    var iter = std.mem.tokenizeAny(u8, value, " \t,");
    while (iter.next()) |tok| {
        if (parseLength(tok)) |len| {
            if (len.unit == .s or len.unit == .ms) {
                const decls = allocator.alloc(ast.Declaration, 1) catch return null;
                decls[0] = .{ .property = .transition_duration, .property_name = "transition-duration", .value_raw = tok, .important = false };
                return decls;
            }
        }
    }
    return null;
}

fn expandAnimation(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    // Parse "animation-duration animation-timing-function animation-delay ... animation-name"
    // Simplified: find first time value → duration, last non-time/non-keyword token → name.
    var duration_tok: ?[]const u8 = null;
    var name_tok: ?[]const u8 = null;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (parseLength(tok)) |len| {
            if ((len.unit == .s or len.unit == .ms) and duration_tok == null) {
                duration_tok = tok;
                continue;
            }
        }
        // Skip timing function keywords and iteration keywords
        if (eqlIgnoreCase(tok, "ease") or eqlIgnoreCase(tok, "linear") or
            eqlIgnoreCase(tok, "ease-in") or eqlIgnoreCase(tok, "ease-out") or
            eqlIgnoreCase(tok, "ease-in-out") or eqlIgnoreCase(tok, "step-start") or
            eqlIgnoreCase(tok, "step-end") or eqlIgnoreCase(tok, "infinite") or
            eqlIgnoreCase(tok, "none") or eqlIgnoreCase(tok, "normal") or
            eqlIgnoreCase(tok, "reverse") or eqlIgnoreCase(tok, "alternate") or
            eqlIgnoreCase(tok, "alternate-reverse") or eqlIgnoreCase(tok, "both") or
            eqlIgnoreCase(tok, "forwards") or eqlIgnoreCase(tok, "backwards") or
            eqlIgnoreCase(tok, "running") or eqlIgnoreCase(tok, "paused"))
        {
            continue;
        }
        // Skip pure numbers (iteration count)
        if (std.fmt.parseFloat(f32, tok)) |_| continue else |_| {}
        // Whatever remains is likely the animation name
        name_tok = tok;
    }

    var count: usize = 0;
    if (duration_tok != null) count += 1;
    if (name_tok != null) count += 1;
    if (count == 0) return null;

    const decls = allocator.alloc(ast.Declaration, count) catch return null;
    var i: usize = 0;
    if (duration_tok) |dur| {
        decls[i] = .{ .property = .animation_duration, .property_name = "animation-duration", .value_raw = dur, .important = false };
        i += 1;
    }
    if (name_tok) |nm| {
        decls[i] = .{ .property = .animation_name, .property_name = "animation-name", .value_raw = nm, .important = false };
    }
    return decls;
}

fn expandOutline(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    if (isCssWideKeyword(value)) {
        const decls = allocator.alloc(ast.Declaration, 3) catch return null;
        decls[0] = .{ .property = .outline_width, .property_name = "outline-width", .value_raw = value, .important = false };
        decls[1] = .{ .property = .outline_style, .property_name = "outline-style", .value_raw = value, .important = false };
        decls[2] = .{ .property = .outline_color, .property_name = "outline-color", .value_raw = value, .important = false };
        return decls;
    }

    var width: []const u8 = "medium";
    var style: []const u8 = "none";
    var color_val: []const u8 = "currentcolor";

    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (isBorderStyle(tok)) {
            style = tok;
        } else if (parseLength(tok) != null) {
            width = tok;
        } else if (parseColor(tok) != null) {
            color_val = tok;
        }
    }

    const decls = allocator.alloc(ast.Declaration, 3) catch return null;
    decls[0] = .{ .property = .outline_width, .property_name = "outline-width", .value_raw = width, .important = false };
    decls[1] = .{ .property = .outline_style, .property_name = "outline-style", .value_raw = style, .important = false };
    decls[2] = .{ .property = .outline_color, .property_name = "outline-color", .value_raw = color_val, .important = false };
    return decls;
}

// ── General Value Parsing ───────────────────────────────────────────

pub fn parseValue(property: ast.PropertyId, raw: []const u8) values.Value {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .raw = raw };

    // Check for CSS-wide keywords first
    if (parseCssWideKeyword(trimmed)) |kw| {
        return .{ .keyword = kw };
    }

    // Check for var()
    if (parseVarRef(trimmed)) |vr| {
        return .{ .var_ref = vr };
    }

    // Property-specific parsing
    return switch (property) {
        // Color properties
        .color, .background_color, .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => {
            if (parseColor(trimmed)) |c| return .{ .color = c };
            if (parseKeyword(trimmed)) |kw| return .{ .keyword = kw };
            return .{ .raw = trimmed };
        },
        // Length properties
        .width, .height, .min_width, .max_width, .min_height, .max_height, .margin_top, .margin_right, .margin_bottom, .margin_left, .padding_top, .padding_right, .padding_bottom, .padding_left, .border_top_width, .border_right_width, .border_bottom_width, .border_left_width, .border_radius_top_left, .border_radius_top_right, .border_radius_bottom_left, .border_radius_bottom_right, .font_size, .line_height, .letter_spacing, .word_spacing, .text_indent, .top, .right, .bottom, .left, .gap, .row_gap, .column_gap, .flex_basis => {
            if (parseLength(trimmed)) |l| return .{ .length = l };
            if (parseKeyword(trimmed)) |kw| return .{ .keyword = kw };
            if (std.fmt.parseFloat(f32, trimmed)) |n| return .{ .number = n } else |_| {}
            return .{ .raw = trimmed };
        },
        // Numeric properties
        .flex_grow, .flex_shrink, .opacity, .z_index => {
            if (std.fmt.parseInt(i32, trimmed, 10)) |n| return .{ .integer = n } else |_| {}
            if (std.fmt.parseFloat(f32, trimmed)) |n| return .{ .number = n } else |_| {}
            if (parseKeyword(trimmed)) |kw| return .{ .keyword = kw };
            return .{ .raw = trimmed };
        },
        // Keyword properties
        .display, .position, .float_, .clear, .box_sizing, .visibility, .text_align, .text_decoration, .text_transform, .white_space, .word_break, .overflow_wrap, .text_overflow, .overflow_x, .overflow_y, .flex_direction, .flex_wrap, .justify_content, .align_content, .align_items, .align_self, .font_style, .list_style_type, .vertical_align, .border_top_style, .border_right_style, .border_bottom_style, .border_left_style, .background_repeat, .background_size => {
            if (parseKeyword(trimmed)) |kw| return .{ .keyword = kw };
            return .{ .raw = trimmed };
        },
        // Font weight: number or keyword
        .font_weight => {
            if (std.fmt.parseInt(i32, trimmed, 10)) |n| return .{ .integer = n } else |_| {}
            if (parseKeyword(trimmed)) |kw| return .{ .keyword = kw };
            return .{ .raw = trimmed };
        },
        else => .{ .raw = trimmed },
    };
}

fn parseCssWideKeyword(s: []const u8) ?values.Keyword {
    if (eqlIgnoreCase(s, "inherit")) return .inherit;
    if (eqlIgnoreCase(s, "initial")) return .initial;
    if (eqlIgnoreCase(s, "unset")) return .unset;
    if (eqlIgnoreCase(s, "revert")) return .revert;
    return null;
}

fn parseKeyword(s: []const u8) ?values.Keyword {
    // Check CSS-wide first
    if (parseCssWideKeyword(s)) |kw| return kw;

    const keyword_map = std.StaticStringMap(values.Keyword).initComptime(.{
        .{ "none", .none },
        .{ "auto", .auto },
        .{ "block", .block },
        .{ "inline", .inline_ },
        .{ "inline-block", .inline_block },
        .{ "flex", .flex },
        .{ "inline-flex", .inline_flex },
        .{ "grid", .grid },
        .{ "inline-grid", .inline_grid },
        .{ "table", .table },
        .{ "list-item", .list_item },
        .{ "table-row", .table_row },
        .{ "table-cell", .table_cell },
        .{ "table-row-group", .table_row_group },
        .{ "table-header-group", .table_header_group },
        .{ "table-footer-group", .table_footer_group },
        .{ "table-column", .table_column },
        .{ "table-column-group", .table_column_group },
        .{ "table-caption", .table_caption },
        .{ "hidden", .hidden },
        .{ "visible", .visible },
        .{ "collapse", .collapse },
        .{ "static", .static_ },
        .{ "relative", .relative },
        .{ "absolute", .absolute },
        .{ "fixed", .fixed },
        .{ "sticky", .sticky },
        .{ "left", .left },
        .{ "right", .right },
        .{ "center", .center },
        .{ "justify", .justify },
        .{ "start", .start },
        .{ "end", .end },
        .{ "normal", .normal },
        .{ "nowrap", .nowrap },
        .{ "pre", .pre },
        .{ "pre-wrap", .pre_wrap },
        .{ "pre-line", .pre_line },
        .{ "break-all", .break_all },
        .{ "keep-all", .keep_all },
        .{ "bold", .bold },
        .{ "bolder", .bolder },
        .{ "lighter", .lighter },
        .{ "italic", .italic },
        .{ "oblique", .oblique },
        .{ "underline", .underline },
        .{ "line-through", .line_through },
        .{ "overline", .overline },
        .{ "scroll", .scroll },
        .{ "content-box", .content_box },
        .{ "border-box", .border_box },
        .{ "row", .row },
        .{ "row-reverse", .row_reverse },
        .{ "column", .column },
        .{ "column-reverse", .column_reverse },
        .{ "wrap", .wrap },
        .{ "wrap-reverse", .wrap_reverse },
        .{ "flex-start", .flex_start },
        .{ "flex-end", .flex_end },
        .{ "space-between", .space_between },
        .{ "space-around", .space_around },
        .{ "space-evenly", .space_evenly },
        .{ "stretch", .stretch },
        .{ "baseline", .baseline },
        .{ "solid", .solid },
        .{ "dashed", .dashed },
        .{ "dotted", .dotted },
        .{ "double", .double },
        .{ "groove", .groove },
        .{ "ridge", .ridge },
        .{ "inset", .inset },
        .{ "outset", .outset },
        .{ "transparent", .transparent_kw },
        .{ "currentcolor", .currentcolor },
        .{ "disc", .disc },
        .{ "circle", .circle },
        .{ "square", .square },
        .{ "decimal", .decimal },
        .{ "lower-alpha", .lower_alpha },
        .{ "upper-alpha", .upper_alpha },
        .{ "lower-roman", .lower_roman },
        .{ "upper-roman", .upper_roman },
        .{ "break-word", .break_word },
        .{ "anywhere", .anywhere },
        .{ "clip", .clip },
        .{ "ellipsis", .ellipsis },
        .{ "uppercase", .uppercase },
        .{ "lowercase", .lowercase },
        .{ "capitalize", .capitalize },
    });

    // Lowercase for lookup
    var buf: [32]u8 = undefined;
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = util.toLower(c);
    }
    return keyword_map.get(buf[0..s.len]);
}
