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
    if (startsWithIgnoreCase(trimmed, "hwb(")) {
        return parseHwbFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "oklab(")) {
        return parseOklabFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "oklch(")) {
        return parseOklchFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "lab(")) {
        return parseLabFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "lch(")) {
        return parseLchFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "color(")) {
        return parseColorFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "color-mix(")) {
        return parseColorMixFunc(trimmed);
    }
    if (startsWithIgnoreCase(trimmed, "light-dark(")) {
        return parseLightDarkFunc(trimmed);
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

pub fn extractFuncArgs(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "(") orelse return null;
    const end = std.mem.lastIndexOf(u8, text, ")") orelse return null;
    if (start >= end) return null;
    return text[start + 1 .. end];
}

/// Tokenize color function arguments, respecting parenthesis nesting.
/// Splits on commas or '/' at depth 0. For modern syntax (no commas), splits on spaces.
/// Returns up to max_args tokens.
fn tokenizeColorArgs(inner: []const u8, out: *[8][]const u8, has_slash: *bool) usize {
    var count: usize = 0;
    has_slash.* = false;

    // First: check if this uses comma syntax (legacy) or space syntax (modern)
    // by looking for commas at depth 0
    var has_comma = false;
    {
        var depth: usize = 0;
        for (inner) |ch| {
            if (ch == '(') depth += 1 else if (ch == ')') {
                if (depth > 0) depth -= 1;
            } else if (ch == ',' and depth == 0) {
                has_comma = true;
                break;
            }
        }
    }

    var depth: usize = 0;
    var start: usize = 0;
    var in_token = false;

    for (inner, 0..) |ch, i| {
        if (ch == '(') {
            depth += 1;
            in_token = true;
            continue;
        }
        if (ch == ')') {
            if (depth > 0) depth -= 1;
            in_token = true;
            continue;
        }

        if (depth == 0) {
            if (has_comma) {
                // Legacy comma syntax: split on ',' at depth 0
                if (ch == ',') {
                    if (in_token) {
                        const tok = std.mem.trim(u8, inner[start..i], " \t");
                        if (tok.len > 0 and count < 8) {
                            out[count] = tok;
                            count += 1;
                        }
                    }
                    start = i + 1;
                    in_token = false;
                    continue;
                }
            } else {
                // Modern space syntax: split on spaces, '/' means alpha follows
                if (ch == '/') {
                    if (in_token) {
                        const tok = std.mem.trim(u8, inner[start..i], " \t");
                        if (tok.len > 0 and count < 8) {
                            out[count] = tok;
                            count += 1;
                        }
                    }
                    has_slash.* = true;
                    start = i + 1;
                    in_token = false;
                    continue;
                }
                if (ch == ' ' or ch == '\t') {
                    if (in_token) {
                        const tok = std.mem.trim(u8, inner[start..i], " \t");
                        if (tok.len > 0 and count < 8) {
                            out[count] = tok;
                            count += 1;
                        }
                    }
                    start = i + 1;
                    in_token = false;
                    continue;
                }
            }
        }
        if (!in_token) {
            start = i;
            in_token = true;
        }
    }
    // Final token
    if (in_token) {
        const tok = std.mem.trim(u8, inner[start..], " \t");
        if (tok.len > 0 and count < 8) {
            out[count] = tok;
            count += 1;
        }
    }
    return count;
}

/// Resolve a color component token that may be a number, percentage, 'none', or calc().
/// For is_alpha=true, percentages are /100, otherwise /100*255.
fn resolveColorComponent(tok: []const u8, is_alpha: bool, is_pct: *bool) ?f32 {
    if (eqlIgnoreCase(tok, "none")) return 0;

    // Check for percentage
    if (tok.len > 0 and tok[tok.len - 1] == '%') {
        is_pct.* = true;
        const pct = std.fmt.parseFloat(f32, tok[0 .. tok.len - 1]) catch return null;
        return if (is_alpha) pct / 100.0 else pct * 255.0 / 100.0;
    }

    // Check for calc()
    if (tok.len >= 5 and eqlIgnoreCase(tok[0..5], "calc(") and tok[tok.len - 1] == ')') {
        const calc_inner = std.mem.trim(u8, tok[5 .. tok.len - 1], " \t");
        // calc(infinity) → max
        if (eqlIgnoreCase(calc_inner, "infinity")) return std.math.floatMax(f32);
        // calc(-infinity) → min
        if (eqlIgnoreCase(calc_inner, "-infinity")) return -std.math.floatMax(f32);
        // calc(NaN) → 0
        if (eqlIgnoreCase(calc_inner, "NaN")) return 0;
        // calc(0 / 0) → NaN → 0
        if (std.mem.eql(u8, std.mem.trim(u8, calc_inner, " "), "0 / 0") or
            std.mem.eql(u8, std.mem.trim(u8, calc_inner, " "), "0/0"))
            return 0;
        // Simple numeric calc
        return std.fmt.parseFloat(f32, calc_inner) catch return null;
    }

    // Strip 'deg' suffix for hue
    const clean = if (std.mem.endsWith(u8, tok, "deg")) tok[0 .. tok.len - 3] else tok;
    return std.fmt.parseFloat(f32, clean) catch null;
}

fn parseRgbFunc(text: []const u8) ?values.Color {
    // CSS Color 4: rgb() accepts 3 or 4 args, 'none' keyword, mixed %/number, calc()
    const inner = extractFuncArgs(text) orelse return null;
    var tokens: [8][]const u8 = undefined;
    var has_slash = false;
    const count = tokenizeColorArgs(inner, &tokens, &has_slash);
    if (count < 3) return null;
    var nums: [4]f32 = .{ 0, 0, 0, 1.0 };
    var alpha_is_pct = false;
    var i: usize = 0;
    while (i < count and i < 4) : (i += 1) {
        var is_pct = false;
        nums[i] = resolveColorComponent(tokens[i], i >= 3, &is_pct) orelse return null;
        if (i >= 3 and is_pct) alpha_is_pct = true;
        if (i < 3 and !is_pct) {
            // Raw number for R/G/B — already in 0-255 range
        } else if (i < 3) {
            // Percentage already converted to 0-255 by resolveColorComponent
        }
    }
    const alpha: u8 = if (count >= 4)
        @intFromFloat(@round(std.math.clamp(if (alpha_is_pct) nums[3] * 255 else nums[3] * 255, 0, 255)))
    else
        255;
    return .{
        .r = clampToU8(nums[0]),
        .g = clampToU8(nums[1]),
        .b = clampToU8(nums[2]),
        .a = alpha,
    };
}

fn parseRgbaFunc(text: []const u8) ?values.Color {
    // CSS Color 4: rgba() is an alias for rgb()
    return parseRgbFunc(text);
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
    // CSS Color 4: hsl() and hsla() are aliases, both accept 3 or 4 args
    const inner = extractFuncArgs(text) orelse return null;
    var tokens: [8][]const u8 = undefined;
    var has_slash = false;
    const count = tokenizeColorArgs(inner, &tokens, &has_slash);
    if (count < 3) return null;
    var vals: [4]f32 = .{ 0, 0, 0, 1.0 };
    var alpha_is_pct = false;
    var i: usize = 0;
    while (i < count and i < 4) : (i += 1) {
        var is_pct = false;
        // For hsl, S and L can be bare numbers (treated as percentages per CSS Color 4)
        vals[i] = resolveColorComponent(tokens[i], i >= 3, &is_pct) orelse return null;
        if (i >= 3 and is_pct) alpha_is_pct = true;
        // For S and L (indices 1,2), percentages are already resolved to 0-255 range by resolveColorComponent
        // but for HSL we need 0-100 percentages. Undo the 255 scaling.
        if (i >= 1 and i <= 2 and is_pct) {
            vals[i] = vals[i] * 100.0 / 255.0;
        }
    }
    const rgb = hslToRgb(vals[0], vals[1], vals[2]);
    const alpha: u8 = if (count >= 4)
        @intFromFloat(std.math.clamp(if (alpha_is_pct) vals[3] * 255.0 else vals[3] * 255.0, 0.0, 255.0))
    else
        255;
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = alpha };
}

fn parseHslaFunc(text: []const u8) ?values.Color {
    // CSS Color 4: hsla() is an alias for hsl()
    return parseHslFunc(text);
}

fn parseHwbFunc(text: []const u8) ?values.Color {
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
        if (eqlIgnoreCase(clean2, "none")) {
            vals[count] = 0;
        } else {
            vals[count] = std.fmt.parseFloat(f32, clean2) catch return null;
        }
        count += 1;
    }
    if (count < 3) return null;

    const h = vals[0];
    const w = vals[1] / 100.0; // whiteness as fraction
    const b = vals[2] / 100.0; // blackness as fraction

    // HWB to RGB conversion (CSS Color 4 §4.5)
    var white = w;
    var black = b;
    if (white + black > 1.0) {
        const sum = white + black;
        white /= sum;
        black /= sum;
    }

    // Pure hue in float (HSL with S=1, L=0.5 → c=1, m=0)
    var hue = @mod(h, @as(f32, 360.0));
    if (hue < 0) hue += 360.0;
    const hp = hue / 60.0;
    const x = 1.0 - @abs(@mod(hp, 2.0) - 1.0);
    var rf: f32 = 0;
    var gf: f32 = 0;
    var bf: f32 = 0;
    if (hp < 1.0) {
        rf = 1;
        gf = x;
    } else if (hp < 2.0) {
        rf = x;
        gf = 1;
    } else if (hp < 3.0) {
        gf = 1;
        bf = x;
    } else if (hp < 4.0) {
        gf = x;
        bf = 1;
    } else if (hp < 5.0) {
        rf = x;
        bf = 1;
    } else {
        rf = 1;
        bf = x;
    }

    // Mix: color = hue * (1 - white - black) + white
    const r = rf * (1.0 - white - black) + white;
    const g = gf * (1.0 - white - black) + white;
    const bv = bf * (1.0 - white - black) + white;

    const a: u8 = if (count >= 4) blk: {
        const alpha_f = if (alpha_is_percentage) vals[3] * 255.0 / 100.0 else vals[3] * 255.0;
        break :blk @intFromFloat(std.math.clamp(alpha_f, 0.0, 255.0));
    } else 255;

    return .{
        .r = @intFromFloat(@round(std.math.clamp(r * 255.0, 0.0, 255.0))),
        .g = @intFromFloat(@round(std.math.clamp(g * 255.0, 0.0, 255.0))),
        .b = @intFromFloat(@round(std.math.clamp(bv * 255.0, 0.0, 255.0))),
        .a = a,
    };
}

// ── OKLab/OKLCH/Lab/LCH Color Space Conversion ─────────────────────

fn oklabToSrgb(L: f32, a: f32, b: f32) values.Color {
    // OKLab → LMS (cube root space)
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;

    // Cube
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    // LMS → linear sRGB
    const r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return .{
        .r = @intFromFloat(@round(std.math.clamp(gammaCorrect(r_lin), 0, 1) * 255)),
        .g = @intFromFloat(@round(std.math.clamp(gammaCorrect(g_lin), 0, 1) * 255)),
        .b = @intFromFloat(@round(std.math.clamp(gammaCorrect(b_lin), 0, 1) * 255)),
        .a = 255,
    };
}

fn gammaCorrect(c: f32) f32 {
    if (c <= 0.0031308) return 12.92 * c;
    return 1.055 * std.math.pow(f32, @max(c, 0), 1.0 / 2.4) - 0.055;
}

pub fn parseColorComponent(tok: []const u8, is_pct_scale: f32) ?f32 {
    if (eqlIgnoreCase(tok, "none")) return 0;
    const is_pct = tok.len > 0 and tok[tok.len - 1] == '%';
    const clean = if (is_pct) tok[0 .. tok.len - 1] else tok;
    const val = std.fmt.parseFloat(f32, clean) catch return null;
    return if (is_pct) val / 100.0 * is_pct_scale else val;
}

pub fn parseAngleComponent(tok: []const u8) ?f32 {
    if (eqlIgnoreCase(tok, "none")) return 0;
    if (std.mem.endsWith(u8, tok, "deg")) {
        return std.fmt.parseFloat(f32, tok[0 .. tok.len - 3]) catch null;
    } else if (std.mem.endsWith(u8, tok, "rad")) {
        const r = std.fmt.parseFloat(f32, tok[0 .. tok.len - 3]) catch return null;
        return r * 180.0 / std.math.pi;
    } else if (std.mem.endsWith(u8, tok, "grad")) {
        const g = std.fmt.parseFloat(f32, tok[0 .. tok.len - 4]) catch return null;
        return g * 0.9;
    } else if (std.mem.endsWith(u8, tok, "turn")) {
        const t = std.fmt.parseFloat(f32, tok[0 .. tok.len - 4]) catch return null;
        return t * 360.0;
    }
    return std.fmt.parseFloat(f32, tok) catch null;
}

fn parseOklabFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var vals: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        switch (count) {
            0 => vals[0] = parseColorComponent(tok, 1.0) orelse return null, // L: 0-1 or 0%-100%
            1 => vals[1] = parseColorComponent(tok, 0.4) orelse return null, // a: -0.4 to 0.4
            2 => vals[2] = parseColorComponent(tok, 0.4) orelse return null, // b: -0.4 to 0.4
            3 => vals[3] = parseColorComponent(tok, 1.0) orelse return null, // alpha
            else => {},
        }
        count += 1;
    }
    if (count < 3) return null;
    var color = oklabToSrgb(vals[0], vals[1], vals[2]);
    if (count >= 4) color.a = @intFromFloat(@round(std.math.clamp(vals[3], 0, 1) * 255));
    return color;
}

fn parseOklchFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var count: usize = 0;
    var L: f32 = 0;
    var C: f32 = 0;
    var H: f32 = 0;
    var alpha: f32 = 1;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        switch (count) {
            0 => L = parseColorComponent(tok, 1.0) orelse return null,
            1 => C = parseColorComponent(tok, 0.4) orelse return null,
            2 => H = parseAngleComponent(tok) orelse return null,
            3 => alpha = parseColorComponent(tok, 1.0) orelse return null,
            else => {},
        }
        count += 1;
    }
    if (count < 3) return null;
    // OKLCH → OKLab
    const h_rad = H * std.math.pi / 180.0;
    const a = C * @cos(h_rad);
    const b = C * @sin(h_rad);
    var color = oklabToSrgb(L, a, b);
    if (count >= 4) color.a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
    return color;
}

// CIE Lab/LCH (using D50 illuminant, per CSS Color 4)
fn labToSrgb(L: f32, a: f32, b: f32) values.Color {
    // Lab → XYZ (D50)
    const fy = (L + 16.0) / 116.0;
    const fx = a / 500.0 + fy;
    const fz = fy - b / 200.0;

    const delta = 6.0 / 29.0;
    const x = if (fx > delta) fx * fx * fx else (fx - 16.0 / 116.0) * 3.0 * delta * delta;
    const y = if (fy > delta) fy * fy * fy else (fy - 16.0 / 116.0) * 3.0 * delta * delta;
    const z = if (fz > delta) fz * fz * fz else (fz - 16.0 / 116.0) * 3.0 * delta * delta;

    // D50 white point
    const xn: f32 = 0.96422;
    const yn: f32 = 1.00000;
    const zn: f32 = 0.82521;

    // XYZ (D50) → linear sRGB via Bradford adaptation to D65 then sRGB matrix
    // Simplified: use combined D50→sRGB matrix
    const xw = x * xn;
    const yw = y * yn;
    const zw = z * zn;

    // XYZ D50 → linear sRGB (combined Bradford + sRGB)
    const r_lin = 3.1338561 * xw - 1.6168667 * yw - 0.4906146 * zw;
    const g_lin = -0.9787684 * xw + 1.9161415 * yw + 0.0334540 * zw;
    const b_lin = 0.0719453 * xw - 0.2289914 * yw + 1.4052427 * zw;

    return .{
        .r = @intFromFloat(@round(std.math.clamp(gammaCorrect(r_lin), 0, 1) * 255)),
        .g = @intFromFloat(@round(std.math.clamp(gammaCorrect(g_lin), 0, 1) * 255)),
        .b = @intFromFloat(@round(std.math.clamp(gammaCorrect(b_lin), 0, 1) * 255)),
        .a = 255,
    };
}

fn parseLabFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var vals: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        switch (count) {
            0 => vals[0] = parseColorComponent(tok, 100.0) orelse return null, // L: 0-100
            1 => vals[1] = parseColorComponent(tok, 125.0) orelse return null, // a: -125 to 125
            2 => vals[2] = parseColorComponent(tok, 125.0) orelse return null, // b: -125 to 125
            3 => vals[3] = parseColorComponent(tok, 1.0) orelse return null, // alpha
            else => {},
        }
        count += 1;
    }
    if (count < 3) return null;
    var color = labToSrgb(vals[0], vals[1], vals[2]);
    if (count >= 4) color.a = @intFromFloat(@round(std.math.clamp(vals[3], 0, 1) * 255));
    return color;
}

fn parseLchFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var count: usize = 0;
    var L: f32 = 0;
    var C: f32 = 0;
    var H: f32 = 0;
    var alpha: f32 = 1;
    var iter = std.mem.tokenizeAny(u8, inner, ", /\t");
    while (iter.next()) |tok| {
        if (count >= 4) break;
        switch (count) {
            0 => L = parseColorComponent(tok, 100.0) orelse return null,
            1 => C = parseColorComponent(tok, 150.0) orelse return null,
            2 => H = parseAngleComponent(tok) orelse return null,
            3 => alpha = parseColorComponent(tok, 1.0) orelse return null,
            else => {},
        }
        count += 1;
    }
    if (count < 3) return null;
    // LCH → Lab
    const h_rad = H * std.math.pi / 180.0;
    const a = C * @cos(h_rad);
    const b = C * @sin(h_rad);
    var color = labToSrgb(L, a, b);
    if (count >= 4) color.a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
    return color;
}

/// CSS Color 4 §9: color() function — predefined color spaces
fn parseColorFunc(text: []const u8) ?values.Color {
    const inner = extractFuncArgs(text) orelse return null;
    var iter = std.mem.tokenizeAny(u8, inner, " \t/,");

    // First token: color space name
    const space_name = iter.next() orelse return null;

    // Read R G B [/ alpha]
    var vals: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    while (iter.next()) |tok| {
        if (count >= 4) break;
        vals[count] = parseColorComponent(tok, 1.0) orelse return null;
        count += 1;
    }
    if (count < 3) return null;

    var r = vals[0];
    var g = vals[1];
    var b = vals[2];

    // Convert from color space to sRGB
    if (eqlIgnoreCase(space_name, "srgb")) {
        // Already sRGB linear, just clamp
    } else if (eqlIgnoreCase(space_name, "srgb-linear")) {
        // Linear sRGB → sRGB gamma
        r = gammaCorrect(r);
        g = gammaCorrect(g);
        b = gammaCorrect(b);
    } else if (eqlIgnoreCase(space_name, "display-p3")) {
        // Display P3 → linear P3 → XYZ D65 → linear sRGB → sRGB
        // Simplified: approximate by treating as wider gamut sRGB
        // P3 to sRGB approximate conversion
        const rl = inverseGamma(r);
        const gl = inverseGamma(g);
        const bl = inverseGamma(b);
        // P3 linear → XYZ → sRGB linear (combined matrix)
        const sr = 1.2249401 * rl - 0.2249402 * gl + 0.0 * bl;
        const sg = 0.0 * rl + 1.0 * gl + 0.0 * bl;
        const sb = 0.0 * rl - 0.0416198 * gl + 1.0416198 * bl;
        r = gammaCorrect(sr);
        g = gammaCorrect(sg);
        b = gammaCorrect(sb);
    } else if (eqlIgnoreCase(space_name, "a98-rgb")) {
        // Adobe RGB → sRGB (approximate)
        r = gammaCorrect(std.math.pow(f32, @max(r, 0), 563.0 / 256.0));
        g = gammaCorrect(std.math.pow(f32, @max(g, 0), 563.0 / 256.0));
        b = gammaCorrect(std.math.pow(f32, @max(b, 0), 563.0 / 256.0));
    } else if (eqlIgnoreCase(space_name, "prophoto-rgb")) {
        // ProPhoto → sRGB (simplified)
        r = gammaCorrect(r);
        g = gammaCorrect(g);
        b = gammaCorrect(b);
    } else if (eqlIgnoreCase(space_name, "rec2020")) {
        // Rec.2020 → sRGB (simplified)
        r = gammaCorrect(r);
        g = gammaCorrect(g);
        b = gammaCorrect(b);
    } else if (eqlIgnoreCase(space_name, "xyz") or eqlIgnoreCase(space_name, "xyz-d65")) {
        // XYZ D65 → linear sRGB
        const sr = 3.2404542 * r - 1.5371385 * g - 0.4985314 * b;
        const sg2 = -0.9692660 * r + 1.8760108 * g + 0.0415560 * b;
        const sb = 0.0556434 * r - 0.2040259 * g + 1.0572252 * b;
        r = gammaCorrect(sr);
        g = gammaCorrect(sg2);
        b = gammaCorrect(sb);
    } else if (eqlIgnoreCase(space_name, "xyz-d50")) {
        // XYZ D50 → sRGB (via D50→D65 Bradford then sRGB)
        const sr = 3.1338561 * r - 1.6168667 * g - 0.4906146 * b;
        const sg2 = -0.9787684 * r + 1.9161415 * g + 0.0334540 * b;
        const sb = 0.0719453 * r - 0.2289914 * g + 1.4052427 * b;
        r = gammaCorrect(sr);
        g = gammaCorrect(sg2);
        b = gammaCorrect(sb);
    } else {
        return null; // Unknown color space
    }

    return .{
        .r = @intFromFloat(@round(std.math.clamp(r, 0, 1) * 255)),
        .g = @intFromFloat(@round(std.math.clamp(g, 0, 1) * 255)),
        .b = @intFromFloat(@round(std.math.clamp(b, 0, 1) * 255)),
        .a = if (count >= 4) @intFromFloat(@round(std.math.clamp(vals[3], 0, 1) * 255)) else 255,
    };
}

fn inverseGamma(c: f32) f32 {
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn clampToU8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

// ── color-mix() ────────────────────────────────────────────────────
// CSS Color 5: color-mix(in <colorspace>, <color1> [<p1>], <color2> [<p2>])
// We support interpolation in srgb (default), hsl, hwb, oklab, oklch, lab, lch.

fn parseColorMixFunc(raw: []const u8) ?values.Color {
    // Extract content between "color-mix(" and ")"
    const prefix_len = "color-mix(".len;
    if (raw.len < prefix_len + 1) return null;
    const end = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return null;
    const args = std.mem.trim(u8, raw[prefix_len..end], " \t\r\n");

    // Parse "in <colorspace>, <color1> [%], <color2> [%]"
    if (!startsWithIgnoreCase(args, "in ")) return null;
    var rest = args[3..]; // after "in "

    // Find comma after colorspace
    const comma1 = findTopLevelComma(rest) orelse return null;
    const colorspace = std.mem.trim(u8, rest[0..comma1], " \t");
    rest = std.mem.trim(u8, rest[comma1 + 1 ..], " \t");

    // Split remaining into two color+percentage parts
    const comma2 = findTopLevelComma(rest) orelse return null;
    const part1 = std.mem.trim(u8, rest[0..comma2], " \t");
    const part2 = std.mem.trim(u8, rest[comma2 + 1 ..], " \t");

    // Parse color and percentage for each part
    var p1: f32 = -1; // -1 = not specified
    var p2: f32 = -1;
    const c1 = parseColorWithPercent(part1, &p1) orelse return null;
    const c2 = parseColorWithPercent(part2, &p2) orelse return null;

    // Normalize percentages per spec
    if (p1 < 0 and p2 < 0) {
        p1 = 50;
        p2 = 50;
    } else if (p1 < 0) {
        p1 = 100 - p2;
    } else if (p2 < 0) {
        p2 = 100 - p1;
    }
    // Clamp to 0-100
    p1 = std.math.clamp(p1, 0, 100);
    p2 = std.math.clamp(p2, 0, 100);

    // Normalize so they sum to 100 (or less for transparency)
    const total = p1 + p2;
    if (total <= 0) return values.Color.transparent;
    const w1 = p1 / total; // weight for color1 (0..1)

    // Interpolate in chosen color space
    return interpolateColors(c1, c2, w1, colorspace);
}

fn findTopLevelComma(s: []const u8) ?usize {
    var depth: u32 = 0;
    for (s, 0..) |ch, i| {
        if (ch == '(' or ch == '[') depth += 1 else if ((ch == ')' or ch == ']') and depth > 0) depth -= 1 else if (ch == ',' and depth == 0) return i;
    }
    return null;
}

fn parseColorWithPercent(part: []const u8, pct: *f32) ?values.Color {
    const trimmed = std.mem.trim(u8, part, " \t");
    if (trimmed.len == 0) return null;

    // Check for leading percentage: "25% hsl(120deg 10% 20%)"
    // Pattern: digits/dot followed by % then space
    if (trimmed[0] >= '0' and trimmed[0] <= '9') {
        if (std.mem.indexOfScalar(u8, trimmed, '%')) |pct_end| {
            // Make sure % is followed by a space and then a color value
            if (pct_end + 1 < trimmed.len and trimmed[pct_end + 1] == ' ') {
                const pct_str = trimmed[0..pct_end];
                const color_str = std.mem.trim(u8, trimmed[pct_end + 1 ..], " \t");
                // Only treat as leading percent if the color part parses successfully
                if (std.fmt.parseFloat(f32, pct_str)) |v| {
                    if (parseColor(color_str)) |color| {
                        pct.* = v;
                        return color;
                    }
                } else |_| {}
            }
        }
    }

    // Check for trailing percentage: "red 30%", "rgb(255,0,0) 70%"
    if (trimmed[trimmed.len - 1] == '%') {
        // Find start of percentage number (work backwards past function calls)
        var i = trimmed.len - 2;
        while (i > 0 and (trimmed[i] == '.' or (trimmed[i] >= '0' and trimmed[i] <= '9'))) : (i -= 1) {}
        // Check for space before percentage
        if (i > 0 and trimmed[i] == ' ') {
            const pct_str = trimmed[i + 1 .. trimmed.len - 1];
            if (std.fmt.parseFloat(f32, pct_str)) |v| {
                pct.* = v;
                return parseColor(trimmed[0..i]);
            } else |_| {}
        }
    }
    // No percentage, just parse as color
    return parseColor(trimmed);
}

fn interpolateColors(c1: values.Color, c2: values.Color, w1: f32, colorspace: []const u8) ?values.Color {
    const w2 = 1.0 - w1;

    // Interpolate alpha separately (always in linear space)
    const a1 = @as(f32, @floatFromInt(c1.a)) / 255.0;
    const a2 = @as(f32, @floatFromInt(c2.a)) / 255.0;
    const a_out = a1 * w1 + a2 * w2;

    // sRGB interpolation (default)
    if (eqlIgnoreCase(colorspace, "srgb") or colorspace.len == 0) {
        return .{
            .r = clampToU8(@as(f32, @floatFromInt(c1.r)) * w1 + @as(f32, @floatFromInt(c2.r)) * w2),
            .g = clampToU8(@as(f32, @floatFromInt(c1.g)) * w1 + @as(f32, @floatFromInt(c2.g)) * w2),
            .b = clampToU8(@as(f32, @floatFromInt(c1.b)) * w1 + @as(f32, @floatFromInt(c2.b)) * w2),
            .a = clampToU8(a_out * 255.0),
        };
    }

    // sRGB-linear: linearize, interpolate, gamma-correct back
    if (eqlIgnoreCase(colorspace, "srgb-linear")) {
        const r1 = inverseGamma(@as(f32, @floatFromInt(c1.r)) / 255.0);
        const g1 = inverseGamma(@as(f32, @floatFromInt(c1.g)) / 255.0);
        const b1 = inverseGamma(@as(f32, @floatFromInt(c1.b)) / 255.0);
        const r2 = inverseGamma(@as(f32, @floatFromInt(c2.r)) / 255.0);
        const g2 = inverseGamma(@as(f32, @floatFromInt(c2.g)) / 255.0);
        const b2 = inverseGamma(@as(f32, @floatFromInt(c2.b)) / 255.0);
        return .{
            .r = clampToU8(gammaCorrect(r1 * w1 + r2 * w2) * 255.0),
            .g = clampToU8(gammaCorrect(g1 * w1 + g2 * w2) * 255.0),
            .b = clampToU8(gammaCorrect(b1 * w1 + b2 * w2) * 255.0),
            .a = clampToU8(a_out * 255.0),
        };
    }

    // OKLab: convert to OKLab, interpolate, convert back
    if (eqlIgnoreCase(colorspace, "oklab")) {
        const lab1 = srgbToOklab(c1);
        const lab2 = srgbToOklab(c2);
        return oklabToSrgbColor(
            lab1[0] * w1 + lab2[0] * w2,
            lab1[1] * w1 + lab2[1] * w2,
            lab1[2] * w1 + lab2[2] * w2,
            a_out,
        );
    }

    // OKLCH: convert to OKLab→OKLCH, interpolate hue, convert back
    if (eqlIgnoreCase(colorspace, "oklch")) {
        const lab1 = srgbToOklab(c1);
        const lab2 = srgbToOklab(c2);
        const lch1 = labToLch(lab1);
        const lch2 = labToLch(lab2);
        const h = interpolateHue(lch1[2], lch2[2], w1);
        const L = lch1[0] * w1 + lch2[0] * w2;
        const C = lch1[1] * w1 + lch2[1] * w2;
        // Convert LCH back to Lab
        const a_lab = C * @cos(h * std.math.pi / 180.0);
        const b_lab = C * @sin(h * std.math.pi / 180.0);
        return oklabToSrgbColor(L, a_lab, b_lab, a_out);
    }

    // HSL: convert to HSL, interpolate hue, convert back
    if (eqlIgnoreCase(colorspace, "hsl")) {
        const hsl1 = srgbToHsl(c1);
        const hsl2 = srgbToHsl(c2);
        const h = interpolateHue(hsl1[0], hsl2[0], w1);
        const s = hsl1[1] * w1 + hsl2[1] * w2;
        const l = hsl1[2] * w1 + hsl2[2] * w2;
        const rgb = hslToRgb(h, s, l);
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = clampToU8(a_out * 255.0) };
    }

    // HWB: convert to HWB via HSL, interpolate hue, convert back
    if (eqlIgnoreCase(colorspace, "hwb")) {
        const hsl1 = srgbToHsl(c1);
        const hsl2 = srgbToHsl(c2);
        const h = interpolateHue(hsl1[0], hsl2[0], w1);
        const s = hsl1[1] * w1 + hsl2[1] * w2;
        const l = hsl1[2] * w1 + hsl2[2] * w2;
        const rgb = hslToRgb(h, s, l);
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = clampToU8(a_out * 255.0) };
    }

    // Default: fallback to sRGB
    return .{
        .r = clampToU8(@as(f32, @floatFromInt(c1.r)) * w1 + @as(f32, @floatFromInt(c2.r)) * w2),
        .g = clampToU8(@as(f32, @floatFromInt(c1.g)) * w1 + @as(f32, @floatFromInt(c2.g)) * w2),
        .b = clampToU8(@as(f32, @floatFromInt(c1.b)) * w1 + @as(f32, @floatFromInt(c2.b)) * w2),
        .a = clampToU8(a_out * 255.0),
    };
}

// ── Helper: sRGB u8 → OKLab [L, a, b] ─────────────────────────────
fn srgbToOklab(c: values.Color) [3]f32 {
    const r = inverseGamma(@as(f32, @floatFromInt(c.r)) / 255.0);
    const g = inverseGamma(@as(f32, @floatFromInt(c.g)) / 255.0);
    const b = inverseGamma(@as(f32, @floatFromInt(c.b)) / 255.0);
    // Linear sRGB → LMS (Oklab matrix)
    const l_ = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m_ = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s_ = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
    const l_c = std.math.cbrt(l_);
    const m_c = std.math.cbrt(m_);
    const s_c = std.math.cbrt(s_);
    return .{
        0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c,
        1.9779984951 * l_c - 2.4285922050 * m_c + 0.4505937099 * s_c,
        0.0259040371 * l_c + 0.7827717662 * m_c - 0.8086757660 * s_c,
    };
}

fn oklabToSrgbColor(L: f32, a: f32, b_val: f32, alpha: f32) values.Color {
    const col = oklabToSrgb(L, a, b_val);
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = clampToU8(alpha * 255.0) };
}

fn labToLch(lab: [3]f32) [3]f32 {
    const C = @sqrt(lab[1] * lab[1] + lab[2] * lab[2]);
    var H = std.math.atan2(lab[2], lab[1]) * 180.0 / std.math.pi;
    if (H < 0) H += 360.0;
    return .{ lab[0], C, H };
}

fn interpolateHue(h1: f32, h2: f32, w1: f32) f32 {
    var diff = h2 - h1;
    if (diff > 180.0) diff -= 360.0;
    if (diff < -180.0) diff += 360.0;
    var result = h1 + diff * (1.0 - w1);
    if (result < 0) result += 360.0;
    if (result >= 360.0) result -= 360.0;
    return result;
}

// ── Helper: sRGB u8 → HSL [h, s, l] ────────────────────────────────
fn srgbToHsl(c: values.Color) [3]f32 {
    const r: f32 = @as(f32, @floatFromInt(c.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(c.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(c.b)) / 255.0;
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const l = (max_c + min_c) / 2.0;
    if (max_c == min_c) return .{ 0, 0, l * 100.0 };
    const d = max_c - min_c;
    const s = if (l > 0.5) d / (2.0 - max_c - min_c) else d / (max_c + min_c);
    var h: f32 = 0;
    if (max_c == r) {
        h = (g - b) / d + (if (g < b) @as(f32, 6.0) else 0.0);
    } else if (max_c == g) {
        h = (b - r) / d + 2.0;
    } else {
        h = (r - g) / d + 4.0;
    }
    return .{ h * 60.0, s * 100.0, l * 100.0 };
}

// ── light-dark() ────────────────────────────────────────────────────
// CSS Color 5: light-dark(<light-color>, <dark-color>)
// We always pick the light color since suzume defaults to light mode.
fn parseLightDarkFunc(raw: []const u8) ?values.Color {
    const prefix_len = "light-dark(".len;
    if (raw.len < prefix_len + 1) return null;
    const end = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return null;
    const args = std.mem.trim(u8, raw[prefix_len..end], " \t\r\n");
    const comma = findTopLevelComma(args) orelse return null;
    const light = std.mem.trim(u8, args[0..comma], " \t");
    // Always return light color (default color scheme)
    return parseColor(light);
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
    // CSS system colors (light mode defaults)
    .{ "canvas", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "canvastext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "linktext", values.Color{ .r = 0, .g = 0, .b = 238, .a = 255 } },
    .{ "visitedtext", values.Color{ .r = 85, .g = 26, .b = 139, .a = 255 } },
    .{ "activetext", values.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    .{ "buttonface", values.Color{ .r = 240, .g = 240, .b = 240, .a = 255 } },
    .{ "buttontext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "buttonborder", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } },
    .{ "field", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "fieldtext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "highlight", values.Color{ .r = 0, .g = 120, .b = 215, .a = 255 } },
    .{ "highlighttext", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "selecteditem", values.Color{ .r = 0, .g = 120, .b = 215, .a = 255 } },
    .{ "selecteditemtext", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "mark", values.Color{ .r = 255, .g = 255, .b = 0, .a = 255 } },
    .{ "marktext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "graytext", values.Color{ .r = 109, .g = 109, .b = 109, .a = 255 } },
    .{ "accentcolor", values.Color{ .r = 0, .g = 120, .b = 215, .a = 255 } },
    .{ "accentcolortext", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    // Deprecated CSS2 system colors — mapped to CSS4 aliases per spec Appendix A
    // https://drafts.csswg.org/css-color-4/#deprecated-system-colors
    .{ "activeborder", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "activecaption", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "appworkspace", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "background", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "buttonhighlight", values.Color{ .r = 240, .g = 240, .b = 240, .a = 255 } }, // → ButtonFace
    .{ "buttonshadow", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "captiontext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } }, // → CanvasText
    .{ "inactiveborder", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "inactivecaption", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "inactivecaptiontext", values.Color{ .r = 109, .g = 109, .b = 109, .a = 255 } }, // → GrayText
    .{ "infobackground", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "infotext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } }, // → CanvasText
    .{ "menu", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "menutext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } }, // → CanvasText
    .{ "scrollbar", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "threeddarkshadow", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "threedface", values.Color{ .r = 240, .g = 240, .b = 240, .a = 255 } }, // → ButtonFace
    .{ "threedhighlight", values.Color{ .r = 240, .g = 240, .b = 240, .a = 255 } }, // → ButtonFace
    .{ "threedlightshadow", values.Color{ .r = 240, .g = 240, .b = 240, .a = 255 } }, // → ButtonFace
    .{ "threedshadow", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "window", values.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } }, // → Canvas
    .{ "windowframe", values.Color{ .r = 118, .g = 118, .b = 118, .a = 255 } }, // → ButtonBorder
    .{ "windowtext", values.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } }, // → CanvasText
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

    // Find where the number ends and unit begins (supports scientific notation like 5e+9)
    var num_end: usize = 0;
    for (trimmed, 0..) |c, i| {
        if ((c == '-' or c == '+') and i == 0) {
            num_end = i + 1;
        } else if (c == '.' or (c >= '0' and c <= '9')) {
            num_end = i + 1;
        } else if ((c == 'e' or c == 'E') and num_end > 0) {
            // Potential scientific notation: only if next char is digit or +/-digit
            const remaining = trimmed[i + 1 ..];
            if (remaining.len > 0 and (remaining[0] >= '0' and remaining[0] <= '9')) {
                num_end = i + 1; // 5e9
            } else if (remaining.len > 1 and (remaining[0] == '+' or remaining[0] == '-') and
                (remaining[1] >= '0' and remaining[1] <= '9'))
            {
                num_end = i + 3; // skip e, sign, and at least one digit
                // Continue scanning remaining digits
                var j: usize = i + 3;
                while (j < trimmed.len and trimmed[j] >= '0' and trimmed[j] <= '9') : (j += 1) {
                    num_end = j + 1;
                }
                break; // done with number
            } else {
                break; // e followed by non-digit = unit (e.g., "em")
            }
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
        .{ "pc", .pc },
        .{ "cm", .cm },
        .{ "mm", .mm },
        .{ "in", .in_ },
        .{ "q", .q },
        .{ "ch", .ch },
        .{ "ex", .ex },
        .{ "%", .percent },
        .{ "fr", .fr },
        .{ "deg", .deg },
        .{ "rad", .rad },
        .{ "grad", .grad },
        .{ "turn", .turn },
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
        var iter = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");
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
    // grid-template shorthand: "rows / columns" or with areas
    // e.g. "min-content 1fr min-content / 12.25rem minmax(0,1fr)"
    if (std.mem.eql(u8, name, "grid-template")) {
        return expandGridTemplate(trimmed, allocator);
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
    // border-top, border-right, border-bottom, border-left shorthands
    if (std.mem.eql(u8, name, "border-top")) {
        return expandBorderSide(trimmed, .border_top_width, "border-top-width", .border_top_style, "border-top-style", .border_top_color, "border-top-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-right")) {
        return expandBorderSide(trimmed, .border_right_width, "border-right-width", .border_right_style, "border-right-style", .border_right_color, "border-right-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-bottom")) {
        return expandBorderSide(trimmed, .border_bottom_width, "border-bottom-width", .border_bottom_style, "border-bottom-style", .border_bottom_color, "border-bottom-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-left")) {
        return expandBorderSide(trimmed, .border_left_width, "border-left-width", .border_left_style, "border-left-style", .border_left_color, "border-left-color", allocator);
    }
    // border-width shorthand: top right bottom left
    if (std.mem.eql(u8, name, "border-width")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .border_top_width, .name = "border-top-width" },
            .{ .id = .border_right_width, .name = "border-right-width" },
            .{ .id = .border_bottom_width, .name = "border-bottom-width" },
            .{ .id = .border_left_width, .name = "border-left-width" },
        }, allocator);
    }
    // border-style shorthand: top right bottom left
    if (std.mem.eql(u8, name, "border-style")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .border_top_style, .name = "border-top-style" },
            .{ .id = .border_right_style, .name = "border-right-style" },
            .{ .id = .border_bottom_style, .name = "border-bottom-style" },
            .{ .id = .border_left_style, .name = "border-left-style" },
        }, allocator);
    }
    // border-color shorthand: top right bottom left
    if (std.mem.eql(u8, name, "border-color")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .border_top_color, .name = "border-top-color" },
            .{ .id = .border_right_color, .name = "border-right-color" },
            .{ .id = .border_bottom_color, .name = "border-bottom-color" },
            .{ .id = .border_left_color, .name = "border-left-color" },
        }, allocator);
    }
    // inset shorthand: top/right/bottom/left
    if (std.mem.eql(u8, name, "inset")) {
        return expandBoxShorthand(trimmed, &.{
            .{ .id = .top, .name = "top" },
            .{ .id = .right, .name = "right" },
            .{ .id = .bottom, .name = "bottom" },
            .{ .id = .left, .name = "left" },
        }, allocator);
    }
    // CSS Logical Properties — map to physical properties (LTR assumed)
    // margin-inline: shorthand for margin-inline-start + margin-inline-end
    if (std.mem.eql(u8, name, "margin-inline")) {
        return expandTwoValueShorthand(trimmed, .margin_left, "margin-left", .margin_right, "margin-right", allocator);
    }
    if (std.mem.eql(u8, name, "margin-block")) {
        return expandTwoValueShorthand(trimmed, .margin_top, "margin-top", .margin_bottom, "margin-bottom", allocator);
    }
    if (std.mem.eql(u8, name, "padding-inline")) {
        return expandTwoValueShorthand(trimmed, .padding_left, "padding-left", .padding_right, "padding-right", allocator);
    }
    if (std.mem.eql(u8, name, "padding-block")) {
        return expandTwoValueShorthand(trimmed, .padding_top, "padding-top", .padding_bottom, "padding-bottom", allocator);
    }
    if (std.mem.eql(u8, name, "inset-inline")) {
        return expandTwoValueShorthand(trimmed, .left, "left", .right, "right", allocator);
    }
    if (std.mem.eql(u8, name, "inset-block")) {
        return expandTwoValueShorthand(trimmed, .top, "top", .bottom, "bottom", allocator);
    }
    // Single-value logical properties → physical equivalents (LTR)
    if (std.mem.eql(u8, name, "margin-inline-start") or std.mem.eql(u8, name, "margin-inline-end") or
        std.mem.eql(u8, name, "margin-block-start") or std.mem.eql(u8, name, "margin-block-end") or
        std.mem.eql(u8, name, "padding-inline-start") or std.mem.eql(u8, name, "padding-inline-end") or
        std.mem.eql(u8, name, "padding-block-start") or std.mem.eql(u8, name, "padding-block-end") or
        std.mem.eql(u8, name, "border-inline-start-width") or std.mem.eql(u8, name, "border-inline-end-width") or
        std.mem.eql(u8, name, "border-block-start-width") or std.mem.eql(u8, name, "border-block-end-width") or
        std.mem.eql(u8, name, "inset-inline-start") or std.mem.eql(u8, name, "inset-inline-end") or
        std.mem.eql(u8, name, "inset-block-start") or std.mem.eql(u8, name, "inset-block-end") or
        std.mem.eql(u8, name, "inline-size") or std.mem.eql(u8, name, "block-size") or
        std.mem.eql(u8, name, "min-inline-size") or std.mem.eql(u8, name, "max-inline-size") or
        std.mem.eql(u8, name, "min-block-size") or std.mem.eql(u8, name, "max-block-size"))
    {
        return expandLogicalSingle(name, trimmed, allocator);
    }
    // border-inline / border-block (logical border shorthands)
    if (std.mem.eql(u8, name, "border-inline")) {
        // Expand to border-left + border-right
        const left = expandBorderSide(trimmed, .border_left_width, "border-left-width", .border_left_style, "border-left-style", .border_left_color, "border-left-color", allocator);
        const right = expandBorderSide(trimmed, .border_right_width, "border-right-width", .border_right_style, "border-right-style", .border_right_color, "border-right-color", allocator);
        if (left != null and right != null) {
            const merged = allocator.alloc(ast.Declaration, 6) catch return left;
            @memcpy(merged[0..3], left.?);
            @memcpy(merged[3..6], right.?);
            return merged;
        }
        return left;
    }
    if (std.mem.eql(u8, name, "border-block")) {
        const top = expandBorderSide(trimmed, .border_top_width, "border-top-width", .border_top_style, "border-top-style", .border_top_color, "border-top-color", allocator);
        const bottom = expandBorderSide(trimmed, .border_bottom_width, "border-bottom-width", .border_bottom_style, "border-bottom-style", .border_bottom_color, "border-bottom-color", allocator);
        if (top != null and bottom != null) {
            const merged = allocator.alloc(ast.Declaration, 6) catch return top;
            @memcpy(merged[0..3], top.?);
            @memcpy(merged[3..6], bottom.?);
            return merged;
        }
        return top;
    }
    // border-inline-start, border-inline-end, border-block-start, border-block-end
    if (std.mem.eql(u8, name, "border-inline-start")) {
        return expandBorderSide(trimmed, .border_left_width, "border-left-width", .border_left_style, "border-left-style", .border_left_color, "border-left-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-inline-end")) {
        return expandBorderSide(trimmed, .border_right_width, "border-right-width", .border_right_style, "border-right-style", .border_right_color, "border-right-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-block-start")) {
        return expandBorderSide(trimmed, .border_top_width, "border-top-width", .border_top_style, "border-top-style", .border_top_color, "border-top-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-block-end")) {
        return expandBorderSide(trimmed, .border_bottom_width, "border-bottom-width", .border_bottom_style, "border-bottom-style", .border_bottom_color, "border-bottom-color", allocator);
    }
    // border-inline-width, border-block-width etc shorthands
    if (std.mem.eql(u8, name, "border-inline-width")) {
        return expandTwoValueShorthand(trimmed, .border_left_width, "border-left-width", .border_right_width, "border-right-width", allocator);
    }
    if (std.mem.eql(u8, name, "border-block-width")) {
        return expandTwoValueShorthand(trimmed, .border_top_width, "border-top-width", .border_bottom_width, "border-bottom-width", allocator);
    }
    if (std.mem.eql(u8, name, "border-inline-color")) {
        return expandTwoValueShorthand(trimmed, .border_left_color, "border-left-color", .border_right_color, "border-right-color", allocator);
    }
    if (std.mem.eql(u8, name, "border-block-color")) {
        return expandTwoValueShorthand(trimmed, .border_top_color, "border-top-color", .border_bottom_color, "border-bottom-color", allocator);
    }
    // font shorthand
    if (std.mem.eql(u8, name, "font")) {
        return expandFont(trimmed, allocator);
    }
    // text-decoration shorthand
    if (std.mem.eql(u8, name, "text-decoration")) {
        return expandTextDecoration(trimmed, allocator);
    }
    // place-items shorthand: align-items + justify-items
    if (std.mem.eql(u8, name, "place-items")) {
        return expandPlaceShorthand(trimmed, .align_items, "align-items", .justify_items, "justify-items", allocator);
    }
    // place-content shorthand: align-content + justify-content
    if (std.mem.eql(u8, name, "place-content")) {
        return expandPlaceShorthand(trimmed, .align_content, "align-content", .justify_content, "justify-content", allocator);
    }
    // place-self shorthand: align-self + justify-self
    if (std.mem.eql(u8, name, "place-self")) {
        return expandPlaceShorthand(trimmed, .align_self, "align-self", .justify_self, "justify-self", allocator);
    }
    // gap shorthand: row-gap + column-gap
    if (std.mem.eql(u8, name, "gap")) {
        return expandGap(trimmed, allocator);
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

/// Expand a 2-value shorthand (e.g., margin-inline: 10px 20px → start end)
fn expandTwoValueShorthand(
    value: []const u8,
    start_id: ast.PropertyId,
    start_name: []const u8,
    end_id: ast.PropertyId,
    end_name: []const u8,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 2) catch return null;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    const first = iter.next() orelse value;
    const second = iter.next() orelse first; // single value = both same
    decls[0] = .{ .property = start_id, .property_name = start_name, .value_raw = first, .important = false };
    decls[1] = .{ .property = end_id, .property_name = end_name, .value_raw = second, .important = false };
    return decls;
}

/// Map a single CSS logical property to its physical equivalent (LTR mode).
fn expandLogicalSingle(name: []const u8, value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    const decls = allocator.alloc(ast.Declaration, 1) catch return null;
    // Map logical → physical (LTR: inline-start=left, inline-end=right, block-start=top, block-end=bottom)
    const mapping = struct {
        fn get(n: []const u8) ?struct { id: ast.PropertyId, pname: []const u8 } {
            if (eql(n, "margin-inline-start")) return .{ .id = .margin_left, .pname = "margin-left" };
            if (eql(n, "margin-inline-end")) return .{ .id = .margin_right, .pname = "margin-right" };
            if (eql(n, "margin-block-start")) return .{ .id = .margin_top, .pname = "margin-top" };
            if (eql(n, "margin-block-end")) return .{ .id = .margin_bottom, .pname = "margin-bottom" };
            if (eql(n, "padding-inline-start")) return .{ .id = .padding_left, .pname = "padding-left" };
            if (eql(n, "padding-inline-end")) return .{ .id = .padding_right, .pname = "padding-right" };
            if (eql(n, "padding-block-start")) return .{ .id = .padding_top, .pname = "padding-top" };
            if (eql(n, "padding-block-end")) return .{ .id = .padding_bottom, .pname = "padding-bottom" };
            if (eql(n, "border-inline-start-width")) return .{ .id = .border_left_width, .pname = "border-left-width" };
            if (eql(n, "border-inline-end-width")) return .{ .id = .border_right_width, .pname = "border-right-width" };
            if (eql(n, "border-block-start-width")) return .{ .id = .border_top_width, .pname = "border-top-width" };
            if (eql(n, "border-block-end-width")) return .{ .id = .border_bottom_width, .pname = "border-bottom-width" };
            if (eql(n, "inset-inline-start")) return .{ .id = .left, .pname = "left" };
            if (eql(n, "inset-inline-end")) return .{ .id = .right, .pname = "right" };
            if (eql(n, "inset-block-start")) return .{ .id = .top, .pname = "top" };
            if (eql(n, "inset-block-end")) return .{ .id = .bottom, .pname = "bottom" };
            if (eql(n, "inline-size")) return .{ .id = .width, .pname = "width" };
            if (eql(n, "block-size")) return .{ .id = .height, .pname = "height" };
            if (eql(n, "min-inline-size")) return .{ .id = .min_width, .pname = "min-width" };
            if (eql(n, "max-inline-size")) return .{ .id = .max_width, .pname = "max-width" };
            if (eql(n, "min-block-size")) return .{ .id = .min_height, .pname = "min-height" };
            if (eql(n, "max-block-size")) return .{ .id = .max_height, .pname = "max-height" };
            return null;
        }
        fn eql(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };
    const m = mapping.get(name) orelse return null;
    decls[0] = .{ .property = m.id, .property_name = m.pname, .value_raw = value, .important = false };
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
        "none",   "hidden", "dotted", "dashed", "solid",
        "double", "groove", "ridge",  "inset",  "outset",
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

    // "none" clears all background properties
    if (eqlIgnoreCase(value, "none")) {
        const decls = allocator.alloc(ast.Declaration, 2) catch return null;
        decls[0] = .{ .property = .background_color, .property_name = "background-color", .value_raw = "transparent", .important = false };
        decls[1] = .{ .property = .background_image, .property_name = "background-image", .value_raw = "none", .important = false };
        return decls;
    }

    // First: try parsing the entire value as a single color (handles rgb(), hsl(), etc.)
    if (parseColor(value) != null) {
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .background_color, .property_name = "background-color", .value_raw = value, .important = false };
        return decls;
    }

    // Try to extract color, image (url), position, size, and repeat from the background shorthand
    var color_val: []const u8 = "transparent";
    var image_val: ?[]const u8 = null;
    var repeat_val: ?[]const u8 = null;
    var position_val: ?[]const u8 = null;
    var size_val: ?[]const u8 = null;

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
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
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

    var gradient_val: ?[]const u8 = null;
    var prev_was_position = false;
    for (tokens[0..token_count], 0..) |tok, ti| {
        _ = ti;
        // Check for size after "/" (e.g., "center/cover")
        if (std.mem.indexOfScalar(u8, tok, '/')) |slash_pos| {
            // Split "position/size"
            const before = tok[0..slash_pos];
            const after = tok[slash_pos + 1 ..];
            if (before.len > 0 and isPositionKeyword(before)) {
                position_val = before;
            }
            if (after.len > 0) {
                size_val = after;
            }
            prev_was_position = false;
            continue;
        }
        // If previous token was a position keyword and this starts with /
        if (prev_was_position and tok.len > 0 and tok[0] == '/') {
            // This shouldn't happen with our tokenizer but handle it
            size_val = if (tok.len > 1) tok[1..] else null;
            prev_was_position = false;
            continue;
        }
        // Extract url(...) or linear-gradient(...) as background-image
        // url() takes priority over gradient (CSS multiple backgrounds: url is primary layer)
        if (startsWithIgnoreCase(tok, "url(")) {
            image_val = tok;
            prev_was_position = false;
            continue;
        }
        if (startsWithIgnoreCase(tok, "linear-gradient(") or
            startsWithIgnoreCase(tok, "-webkit-linear-gradient(") or
            startsWithIgnoreCase(tok, "-moz-linear-gradient(") or
            startsWithIgnoreCase(tok, "radial-gradient(") or
            startsWithIgnoreCase(tok, "conic-gradient(") or
            startsWithIgnoreCase(tok, "repeating-linear-gradient(") or
            startsWithIgnoreCase(tok, "repeating-radial-gradient("))
        {
            gradient_val = tok;
            prev_was_position = false;
            continue;
        }
        // Extract repeat keywords as background-repeat
        if (eqlIgnoreCase(tok, "no-repeat") or eqlIgnoreCase(tok, "repeat") or
            eqlIgnoreCase(tok, "repeat-x") or eqlIgnoreCase(tok, "repeat-y"))
        {
            repeat_val = tok;
            prev_was_position = false;
            continue;
        }
        // Background size keywords (cover, contain)
        if (eqlIgnoreCase(tok, "cover") or eqlIgnoreCase(tok, "contain")) {
            size_val = tok;
            prev_was_position = false;
            continue;
        }
        // Position keywords
        if (isPositionKeyword(tok)) {
            position_val = tok;
            prev_was_position = true;
            continue;
        }
        // Skip attachment keywords (fixed, scroll, local)
        if (eqlIgnoreCase(tok, "fixed") or eqlIgnoreCase(tok, "scroll") or eqlIgnoreCase(tok, "local")) {
            prev_was_position = false;
            continue;
        }
        // Skip origin/clip keywords (border-box, padding-box, content-box)
        if (eqlIgnoreCase(tok, "border-box") or eqlIgnoreCase(tok, "padding-box") or eqlIgnoreCase(tok, "content-box")) {
            prev_was_position = false;
            continue;
        }
        // Try parsing as color (now handles rgb(), hsl() etc. properly)
        if (parseColor(tok) != null) {
            color_val = tok;
            prev_was_position = false;
            continue;
        }
        // Try parsing as length (could be background-position)
        if (parseLength(tok) != null) {
            if (position_val == null) {
                position_val = tok;
                prev_was_position = true;
            }
            continue;
        }
        prev_was_position = false;
    }

    // Use gradient as image if no url() was found
    if (image_val == null and gradient_val != null) {
        image_val = gradient_val;
    }

    // Count how many declarations we need
    var n: usize = 1; // always emit background-color
    if (image_val != null) n += 1;
    // If we have both url() and gradient, emit gradient separately
    if (image_val != null and gradient_val != null and image_val.?.ptr != gradient_val.?.ptr) n += 1;
    if (repeat_val != null) n += 1;
    if (position_val != null) n += 1;
    if (size_val != null) n += 1;

    const decls = allocator.alloc(ast.Declaration, n) catch return null;
    var idx: usize = 0;
    decls[idx] = .{ .property = .background_color, .property_name = "background-color", .value_raw = color_val, .important = false };
    idx += 1;
    if (image_val) |img| {
        decls[idx] = .{ .property = .background_image, .property_name = "background-image", .value_raw = img, .important = false };
        idx += 1;
    }
    // Also emit gradient if url() took priority
    if (image_val != null and gradient_val != null and image_val.?.ptr != gradient_val.?.ptr) {
        decls[idx] = .{ .property = .background_image, .property_name = "background-image", .value_raw = gradient_val.?, .important = false };
        idx += 1;
    }
    if (repeat_val) |rep| {
        decls[idx] = .{ .property = .background_repeat, .property_name = "background-repeat", .value_raw = rep, .important = false };
        idx += 1;
    }
    if (position_val) |pos| {
        decls[idx] = .{ .property = .background_position, .property_name = "background-position", .value_raw = pos, .important = false };
        idx += 1;
    }
    if (size_val) |sz| {
        decls[idx] = .{ .property = .background_size, .property_name = "background-size", .value_raw = sz, .important = false };
        idx += 1;
    }
    return decls;
}

fn isPositionKeyword(tok: []const u8) bool {
    return eqlIgnoreCase(tok, "center") or eqlIgnoreCase(tok, "top") or
        eqlIgnoreCase(tok, "bottom") or eqlIgnoreCase(tok, "left") or
        eqlIgnoreCase(tok, "right");
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

/// Check if a flex shorthand token is a flex-basis value (has units) vs a number (grow/shrink).
fn isFlexBasisValue(s: []const u8) bool {
    if (s.len >= 4 and eqlIgnoreCase(s[0..4], "calc")) {
        // calc() with length/percent units = basis, unitless = number
        for (s) |c| {
            if (c == '%') return true;
        }
        if (std.mem.indexOf(u8, s, "px") != null or
            std.mem.indexOf(u8, s, "em") != null or
            std.mem.indexOf(u8, s, "rem") != null or
            std.mem.indexOf(u8, s, "vw") != null or
            std.mem.indexOf(u8, s, "vh") != null or
            std.mem.indexOf(u8, s, "cqw") != null)
            return true;
        return false;
    }
    if (eqlIgnoreCase(s, "auto") or eqlIgnoreCase(s, "content") or
        eqlIgnoreCase(s, "min-content") or eqlIgnoreCase(s, "max-content") or
        eqlIgnoreCase(s, "fit-content"))
        return true;
    for (s) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '%') return true;
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

    // Split into tokens respecting parentheses (calc(), var(), etc.)
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    {
        var i: usize = 0;
        while (i < value.len and count < 3) {
            // Skip whitespace
            while (i < value.len and (value[i] == ' ' or value[i] == '\t')) i += 1;
            if (i >= value.len) break;
            const start = i;
            var paren_depth: usize = 0;
            while (i < value.len) {
                if (value[i] == '(') {
                    paren_depth += 1;
                } else if (value[i] == ')') {
                    if (paren_depth > 0) paren_depth -= 1;
                } else if ((value[i] == ' ' or value[i] == '\t') and paren_depth == 0) {
                    break;
                }
                i += 1;
            }
            if (i > start) {
                parts[count] = value[start..i];
                count += 1;
            }
        }
    }

    if (count == 1) {
        // Single value: if it has units (%, px, em, etc.), it's flex-basis
        // Otherwise it's flex-grow. calc() with units = basis, calc() without = number.
        const is_basis = isFlexBasisValue(parts[0]);
        if (is_basis) {
            // flex: <basis> → grow=1, shrink=1, basis=value
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = "1", .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[0], .important = false };
        } else {
            // flex: <number> → grow=number, shrink=1, basis=0%
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "0%", .important = false };
        }
    } else if (count == 2) {
        // flex: <grow> <shrink|basis> OR <basis> <grow>
        const first_is_basis = isFlexBasisValue(parts[0]);
        const second_is_basis = isFlexBasisValue(parts[1]);
        if (first_is_basis and !second_is_basis) {
            // flex: <basis> <grow> → grow=parts[1], shrink=1, basis=parts[0]
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[1], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[0], .important = false };
        } else if (second_is_basis) {
            // flex: <grow> <basis>
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = "1", .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[1], .important = false };
        } else {
            // flex: <grow> <shrink>
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[1], .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = "0%", .important = false };
        }
    } else {
        // flex: 3 values — determine which is basis (has units/keyword)
        if (isFlexBasisValue(parts[0])) {
            // flex: <basis> <grow> <shrink>
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[1], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[2], .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[0], .important = false };
        } else if (isFlexBasisValue(parts[2])) {
            // flex: <grow> <shrink> <basis>
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[1], .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[2], .important = false };
        } else {
            // All numbers — treat as grow shrink basis(=0%)
            decls[0] = .{ .property = .flex_grow, .property_name = "flex-grow", .value_raw = parts[0], .important = false };
            decls[1] = .{ .property = .flex_shrink, .property_name = "flex-shrink", .value_raw = parts[1], .important = false };
            decls[2] = .{ .property = .flex_basis, .property_name = "flex-basis", .value_raw = parts[2], .important = false };
        }
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

/// Expand grid-template shorthand.
/// Format: "rows / columns" — possibly with quoted area strings interspersed.
/// Wikipedia example: "min-content 1fr min-content / 12.25rem minmax(0,1fr)"
/// When areas are present: "'header header' 1fr 'sidebar content' auto / 200px 1fr"
fn expandGridTemplate(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    // Find the slash that separates rows from columns.
    // Need to skip slashes inside parentheses (e.g. minmax()) and quotes.
    var depth: usize = 0;
    var in_quote: u8 = 0;
    var slash_pos: ?usize = null;
    for (value, 0..) |c, i| {
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            in_quote = c;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == '/' and depth == 0) {
            slash_pos = i;
            break;
        }
    }

    if (slash_pos) |sp| {
        const rows_part = std.mem.trim(u8, value[0..sp], " \t");
        const cols_part = std.mem.trim(u8, value[sp + 1 ..], " \t");

        // Check if rows_part contains quoted strings (grid-template-areas)
        const has_areas = std.mem.indexOf(u8, rows_part, "'") != null or std.mem.indexOf(u8, rows_part, "\"") != null;

        if (has_areas) {
            // Extract area strings and row sizes
            // For now, just pass the areas part and columns part
            const decls = allocator.alloc(ast.Declaration, 3) catch return null;
            decls[0] = .{ .property = .grid_template_columns, .property_name = "grid-template-columns", .value_raw = cols_part, .important = false };
            decls[1] = .{ .property = .grid_template_rows, .property_name = "grid-template-rows", .value_raw = extractRowSizes(rows_part), .important = false };
            decls[2] = .{ .property = .grid_template_areas, .property_name = "grid-template-areas", .value_raw = rows_part, .important = false };
            return decls;
        } else {
            const decls = allocator.alloc(ast.Declaration, 2) catch return null;
            decls[0] = .{ .property = .grid_template_rows, .property_name = "grid-template-rows", .value_raw = rows_part, .important = false };
            decls[1] = .{ .property = .grid_template_columns, .property_name = "grid-template-columns", .value_raw = cols_part, .important = false };
            return decls;
        }
    } else {
        // No slash — could be just areas or just columns
        // If it has quotes, treat as areas only
        if (std.mem.indexOf(u8, value, "'") != null or std.mem.indexOf(u8, value, "\"") != null) {
            const decls = allocator.alloc(ast.Declaration, 1) catch return null;
            decls[0] = .{ .property = .grid_template_areas, .property_name = "grid-template-areas", .value_raw = value, .important = false };
            return decls;
        }
        // Otherwise treat as columns
        const decls = allocator.alloc(ast.Declaration, 1) catch return null;
        decls[0] = .{ .property = .grid_template_columns, .property_name = "grid-template-columns", .value_raw = value, .important = false };
        return decls;
    }
}

/// Extract row sizes from a grid-template value that has areas.
/// e.g. "'header' auto 'content' 1fr" → "auto 1fr"
fn extractRowSizes(rows_part: []const u8) []const u8 {
    // For the simple case, the row sizes are the non-quoted tokens
    // Since the grid-template rows parsing already handles skipping named lines,
    // we can just pass through and let parseGridTemplate handle it
    return rows_part;
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

fn expandBorderSide(
    value: []const u8,
    w_id: ast.PropertyId,
    w_name: []const u8,
    s_id: ast.PropertyId,
    s_name: []const u8,
    c_id: ast.PropertyId,
    c_name: []const u8,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    if (isCssWideKeyword(value)) {
        const decls = allocator.alloc(ast.Declaration, 3) catch return null;
        decls[0] = .{ .property = w_id, .property_name = w_name, .value_raw = value, .important = false };
        decls[1] = .{ .property = s_id, .property_name = s_name, .value_raw = value, .important = false };
        decls[2] = .{ .property = c_id, .property_name = c_name, .value_raw = value, .important = false };
        return decls;
    }

    var width: []const u8 = "medium";
    var style: []const u8 = "none";
    var color_val: []const u8 = "currentcolor";

    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (isBorderStyle(tok)) {
            style = tok;
        } else if (parseLength(tok) != null or eqlIgnoreCase(tok, "thin") or eqlIgnoreCase(tok, "medium") or eqlIgnoreCase(tok, "thick")) {
            width = tok;
        } else {
            color_val = tok;
        }
    }

    const decls = allocator.alloc(ast.Declaration, 3) catch return null;
    decls[0] = .{ .property = w_id, .property_name = w_name, .value_raw = width, .important = false };
    decls[1] = .{ .property = s_id, .property_name = s_name, .value_raw = style, .important = false };
    decls[2] = .{ .property = c_id, .property_name = c_name, .value_raw = color_val, .important = false };
    return decls;
}

fn expandFont(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    // System font keywords — ignore (return null)
    const system_fonts = [_][]const u8{ "caption", "icon", "menu", "message-box", "small-caption", "status-bar" };
    for (system_fonts) |sf| {
        if (eqlIgnoreCase(value, sf)) return null;
    }

    if (isCssWideKeyword(value)) {
        const decls = allocator.alloc(ast.Declaration, 5) catch return null;
        decls[0] = .{ .property = .font_style, .property_name = "font-style", .value_raw = value, .important = false };
        decls[1] = .{ .property = .font_weight, .property_name = "font-weight", .value_raw = value, .important = false };
        decls[2] = .{ .property = .font_size, .property_name = "font-size", .value_raw = value, .important = false };
        decls[3] = .{ .property = .line_height, .property_name = "line-height", .value_raw = value, .important = false };
        decls[4] = .{ .property = .font_family, .property_name = "font-family", .value_raw = value, .important = false };
        return decls;
    }

    // Parse: [font-style] [font-variant] [font-weight] font-size[/line-height] font-family
    // Tokenize respecting quoted strings
    var tokens: [16][]const u8 = undefined;
    var token_count: usize = 0;
    {
        var i: usize = 0;
        while (i < value.len and token_count < tokens.len) {
            while (i < value.len and (value[i] == ' ' or value[i] == '\t')) i += 1;
            if (i >= value.len) break;
            const start = i;
            if (value[i] == '"' or value[i] == '\'') {
                const quote = value[i];
                i += 1;
                while (i < value.len and value[i] != quote) i += 1;
                if (i < value.len) i += 1; // skip closing quote
            } else {
                while (i < value.len and value[i] != ' ' and value[i] != '\t') i += 1;
            }
            if (i > start) {
                tokens[token_count] = value[start..i];
                token_count += 1;
            }
        }
    }
    if (token_count < 2) return null; // Need at least font-size and font-family

    var font_style: []const u8 = "normal";
    var font_weight: []const u8 = "normal";
    var font_size: []const u8 = "medium";
    var line_height: []const u8 = "normal";
    var family_start: usize = 0;

    // Scan tokens left to right for optional style/variant/weight, then size, then family
    var ti: usize = 0;
    // Parse optional font-style
    if (ti < token_count) {
        if (eqlIgnoreCase(tokens[ti], "italic") or eqlIgnoreCase(tokens[ti], "oblique")) {
            font_style = tokens[ti];
            ti += 1;
        } else if (eqlIgnoreCase(tokens[ti], "normal")) {
            ti += 1; // could be style, variant, or weight — skip
        }
    }
    // Parse optional font-variant (small-caps) — skip it
    if (ti < token_count and eqlIgnoreCase(tokens[ti], "small-caps")) {
        ti += 1;
    }
    // Parse optional font-weight
    if (ti < token_count) {
        const w = tokens[ti];
        if (eqlIgnoreCase(w, "bold") or eqlIgnoreCase(w, "bolder") or eqlIgnoreCase(w, "lighter")) {
            font_weight = w;
            ti += 1;
        } else if (w.len > 0 and w[0] >= '1' and w[0] <= '9') {
            // Could be a numeric weight (100-900) or could be font-size
            // Numeric weights are 100,200,...900 — check if it's a round hundred
            if (std.fmt.parseInt(u32, w, 10)) |n| {
                if (n >= 100 and n <= 900 and n % 100 == 0) {
                    font_weight = w;
                    ti += 1;
                }
            } else |_| {}
        }
    }
    // Next token must be font-size (possibly with /line-height)
    if (ti >= token_count) return null;
    const size_tok = tokens[ti];
    ti += 1;
    // Check for font-size/line-height
    if (std.mem.indexOf(u8, size_tok, "/")) |slash| {
        font_size = size_tok[0..slash];
        line_height = size_tok[slash + 1 ..];
    } else {
        font_size = size_tok;
    }
    // Rest is font-family
    family_start = ti;
    if (family_start >= token_count) return null;

    // Reconstruct font-family from remaining tokens (join with spaces)
    // Use the original value slice from the start of family_start token to end
    const family_begin = @intFromPtr(tokens[family_start].ptr) - @intFromPtr(value.ptr);
    const font_family = value[family_begin..];

    var decl_count: usize = 3; // font-size, font-family, font-style always
    decl_count += 1; // font-weight
    if (!std.mem.eql(u8, line_height, "normal")) decl_count += 1;

    const decls = allocator.alloc(ast.Declaration, decl_count) catch return null;
    var di: usize = 0;
    decls[di] = .{ .property = .font_style, .property_name = "font-style", .value_raw = font_style, .important = false };
    di += 1;
    decls[di] = .{ .property = .font_weight, .property_name = "font-weight", .value_raw = font_weight, .important = false };
    di += 1;
    decls[di] = .{ .property = .font_size, .property_name = "font-size", .value_raw = font_size, .important = false };
    di += 1;
    if (!std.mem.eql(u8, line_height, "normal")) {
        decls[di] = .{ .property = .line_height, .property_name = "line-height", .value_raw = line_height, .important = false };
        di += 1;
    }
    decls[di] = .{ .property = .font_family, .property_name = "font-family", .value_raw = font_family, .important = false };
    return decls;
}

fn expandTextDecoration(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    // text-decoration: underline red wavy → extract line value (underline/line-through/overline/none)
    // We only support the line sub-property for now; pass through to text_decoration
    var line_val: []const u8 = value;
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    while (iter.next()) |tok| {
        if (eqlIgnoreCase(tok, "none") or eqlIgnoreCase(tok, "underline") or
            eqlIgnoreCase(tok, "line-through") or eqlIgnoreCase(tok, "overline"))
        {
            line_val = tok;
            break;
        }
    }
    const decls = allocator.alloc(ast.Declaration, 1) catch return null;
    decls[0] = .{ .property = .text_decoration, .property_name = "text-decoration", .value_raw = line_val, .important = false };
    return decls;
}

/// Expand place-items, place-content, place-self shorthands.
/// 1 value: both properties get the same value.
/// 2 values: first is align-*, second is justify-*.
fn expandPlaceShorthand(
    value: []const u8,
    align_id: ast.PropertyId,
    align_name: []const u8,
    justify_id: ast.PropertyId,
    justify_name: []const u8,
    allocator: std.mem.Allocator,
) ?[]ast.Declaration {
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    const first = iter.next() orelse return null;
    const second = iter.next();

    const decls = allocator.alloc(ast.Declaration, 2) catch return null;
    decls[0] = .{ .property = align_id, .property_name = align_name, .value_raw = first, .important = false };
    decls[1] = .{ .property = justify_id, .property_name = justify_name, .value_raw = second orelse first, .important = false };
    return decls;
}

/// Expand gap shorthand: "row-gap column-gap" or single value for both.
fn expandGap(value: []const u8, allocator: std.mem.Allocator) ?[]ast.Declaration {
    var iter = std.mem.tokenizeAny(u8, value, " \t");
    const first = iter.next() orelse return null;
    const second = iter.next();

    const decls = allocator.alloc(ast.Declaration, 2) catch return null;
    decls[0] = .{ .property = .row_gap, .property_name = "row-gap", .value_raw = first, .important = false };
    decls[1] = .{ .property = .column_gap, .property_name = "column-gap", .value_raw = second orelse first, .important = false };
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
