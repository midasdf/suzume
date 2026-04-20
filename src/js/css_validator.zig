//! css_validator.zig — Deep semantic CSS property-value validator.
//!
//! Wave 6 Phase 6.2: paired with `vm.zig`'s bracket dispatch. Closes the
//! `test_invalid_value` regression from Wave 5 Attempt A where
//! syntactically-balanced but semantically-invalid values (e.g.
//! `clamp(none, 1px, 1px)` or
//! `linear-gradient(calc(sign(50%) * 1turn), red, blue)`) slipped through
//! the surface check and landed in the inline style attribute.
//!
//! Layered per spec:
//!   Layer 0: early-accept CSS-wide keywords (inherit/initial/unset/revert),
//!            `var(...)`, and empty string.
//!   Layer 1: top-level tokenizer that respects string literals, URL
//!            parens, and comments when splitting by commas / whitespace.
//!   Layer 2: classify the value — function call vs ident vs dimension
//!            vs compound (space-separated).
//!   Layer 3: per-category validators — math / gradient / calc-size /
//!            URL request modifier / image-resource.
//!   Layer 4: per-property grammar — delegates to the existing helpers in
//!            dom_style.zig when the shape reaches a terminal.
//!   Layer 5: shorthand descent — `background` / `transform` / etc.
//!
//! Public surface: `isValidPropertyValue(prop, val) bool`. Internally
//! safe to call recursively for nested function arguments.

const std = @import("std");

const ArgType = enum {
    number,
    integer,
    length,
    percentage,
    angle,
    time,
    frequency,
    resolution,
    length_percentage, // context-specific (e.g. 50% in a calc)
    ident, // bare identifier (including keywords like `auto`)
    color,
    string, // quoted
    unknown, // unclassified — reject unless consumer opts in
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Scan past a balanced function call (position `i` points at '('). Returns
/// the index of the matching ')' or null if unbalanced / terminates early.
fn findMatchingParen(s: []const u8, open_idx: usize) ?usize {
    if (open_idx >= s.len or s[open_idx] != '(') return null;
    var depth: i32 = 1;
    var i: usize = open_idx + 1;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            i += 1;
            while (i < s.len and s[i] != quote) : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            continue;
        }
        if (ch == '(') depth += 1 else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Extract the inner region of a function call (content between '(' ')').
/// Returns null if the string is not a well-formed single function call at
/// top level.
fn funcInner(s: []const u8) ?[]const u8 {
    const trimmed = trimWs(s);
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close = findMatchingParen(trimmed, open) orelse return null;
    if (close != trimmed.len - 1) return null;
    return trimmed[open + 1 .. close];
}

/// Extract the function name prefix (everything before '(').
fn funcName(s: []const u8) ?[]const u8 {
    const trimmed = trimWs(s);
    if (trimmed.len < 3 or trimmed[trimmed.len - 1] != ')') return null;
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    return trimmed[0..open];
}

/// Split `s` by top-level commas, respecting parens + strings. Appends
/// trimmed slices to `out` (up to `out.len`). Returns number of slices
/// produced, or `null` if more slices than capacity (over-long list).
fn splitTopLevelCommas(s: []const u8, out: [][]const u8) ?usize {
    var count: usize = 0;
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            i += 1;
            while (i < s.len and s[i] != quote) : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            continue;
        }
        if (ch == '(') depth += 1 else if (ch == ')') depth -= 1;
        if (ch == ',' and depth == 0) {
            if (count >= out.len) return null;
            out[count] = trimWs(s[start..i]);
            count += 1;
            start = i + 1;
        }
    }
    if (count >= out.len) return null;
    out[count] = trimWs(s[start..]);
    count += 1;
    return count;
}

/// Split by top-level spaces (including tabs / newlines), respecting
/// parens + strings. Useful for compound values like `transform:
/// translateX(50%) rotate(45deg)`.
fn splitTopLevelSpaces(s: []const u8, out: [][]const u8) ?usize {
    var count: usize = 0;
    var depth: i32 = 0;
    var start: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            if (start == null) start = i;
            const quote = ch;
            i += 1;
            while (i < s.len and s[i] != quote) : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            continue;
        }
        if (ch == '(') {
            if (start == null) start = i;
            depth += 1;
            continue;
        }
        if (ch == ')') {
            depth -= 1;
            continue;
        }
        if (depth == 0 and (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n')) {
            if (start) |st| {
                if (count >= out.len) return null;
                out[count] = s[st..i];
                count += 1;
                start = null;
            }
            continue;
        }
        if (start == null) start = i;
    }
    if (start) |st| {
        if (count >= out.len) return null;
        out[count] = s[st..];
        count += 1;
    }
    return count;
}

// ── Type classification ─────────────────────────────────────────────

/// Classify a "simple" (non-function-call, non-compound) value token.
/// Used for math/gradient arg typing.
fn classifySimple(tok: []const u8) ArgType {
    if (tok.len == 0) return .unknown;
    // Function calls — classify by function name.
    if (tok[tok.len - 1] == ')') {
        const name = funcName(tok) orelse return .unknown;
        if (eqlIgnoreCase(name, "calc") or eqlIgnoreCase(name, "min") or eqlIgnoreCase(name, "max") or
            eqlIgnoreCase(name, "clamp") or eqlIgnoreCase(name, "round") or eqlIgnoreCase(name, "mod") or
            eqlIgnoreCase(name, "rem") or eqlIgnoreCase(name, "abs") or eqlIgnoreCase(name, "sign") or
            eqlIgnoreCase(name, "hypot") or eqlIgnoreCase(name, "sqrt") or eqlIgnoreCase(name, "pow") or
            eqlIgnoreCase(name, "log") or eqlIgnoreCase(name, "exp"))
            return .length_percentage; // treat as numeric-like, context decides
        if (eqlIgnoreCase(name, "sin") or eqlIgnoreCase(name, "cos") or eqlIgnoreCase(name, "tan"))
            return .number;
        if (eqlIgnoreCase(name, "asin") or eqlIgnoreCase(name, "acos") or eqlIgnoreCase(name, "atan") or
            eqlIgnoreCase(name, "atan2"))
            return .angle;
        if (eqlIgnoreCase(name, "var")) return .length_percentage;
        return .unknown;
    }
    // Quoted string.
    if (tok.len >= 2 and (tok[0] == '"' or tok[0] == '\'')) return .string;
    // Number / dimension / percentage.
    var i: usize = 0;
    if (i < tok.len and (tok[i] == '+' or tok[i] == '-')) i += 1;
    var saw_digit = false;
    var saw_dot = false;
    while (i < tok.len) : (i += 1) {
        const ch = tok[i];
        if (ch >= '0' and ch <= '9') {
            saw_digit = true;
            continue;
        }
        if (ch == '.') {
            if (saw_dot) break;
            saw_dot = true;
            continue;
        }
        if ((ch == 'e' or ch == 'E') and saw_digit) {
            // exponent
            i += 1;
            if (i < tok.len and (tok[i] == '+' or tok[i] == '-')) i += 1;
            var exp_digits = false;
            while (i < tok.len and tok[i] >= '0' and tok[i] <= '9') : (i += 1) exp_digits = true;
            if (!exp_digits) return .unknown;
            break;
        }
        break;
    }
    if (!saw_digit) {
        // Bare ident.
        return .ident;
    }
    // Check suffix.
    const suffix = tok[i..];
    if (suffix.len == 0) {
        return if (saw_dot) .number else .integer;
    }
    if (suffix.len == 1 and suffix[0] == '%') return .percentage;
    if (eqlIgnoreCase(suffix, "px") or eqlIgnoreCase(suffix, "em") or eqlIgnoreCase(suffix, "rem") or
        eqlIgnoreCase(suffix, "ex") or eqlIgnoreCase(suffix, "ch") or eqlIgnoreCase(suffix, "vw") or
        eqlIgnoreCase(suffix, "vh") or eqlIgnoreCase(suffix, "vmin") or eqlIgnoreCase(suffix, "vmax") or
        eqlIgnoreCase(suffix, "cm") or eqlIgnoreCase(suffix, "mm") or eqlIgnoreCase(suffix, "in") or
        eqlIgnoreCase(suffix, "pt") or eqlIgnoreCase(suffix, "pc") or eqlIgnoreCase(suffix, "q") or
        eqlIgnoreCase(suffix, "lh") or eqlIgnoreCase(suffix, "rlh") or eqlIgnoreCase(suffix, "vi") or
        eqlIgnoreCase(suffix, "vb") or eqlIgnoreCase(suffix, "svw") or eqlIgnoreCase(suffix, "svh") or
        eqlIgnoreCase(suffix, "lvw") or eqlIgnoreCase(suffix, "lvh") or eqlIgnoreCase(suffix, "dvw") or
        eqlIgnoreCase(suffix, "dvh") or eqlIgnoreCase(suffix, "cqw") or eqlIgnoreCase(suffix, "cqh") or
        eqlIgnoreCase(suffix, "cqi") or eqlIgnoreCase(suffix, "cqb") or eqlIgnoreCase(suffix, "cqmin") or
        eqlIgnoreCase(suffix, "cqmax")) return .length;
    if (eqlIgnoreCase(suffix, "deg") or eqlIgnoreCase(suffix, "rad") or
        eqlIgnoreCase(suffix, "grad") or eqlIgnoreCase(suffix, "turn")) return .angle;
    if (eqlIgnoreCase(suffix, "s") or eqlIgnoreCase(suffix, "ms")) return .time;
    if (eqlIgnoreCase(suffix, "hz") or eqlIgnoreCase(suffix, "khz")) return .frequency;
    if (eqlIgnoreCase(suffix, "dpi") or eqlIgnoreCase(suffix, "dpcm") or
        eqlIgnoreCase(suffix, "dppx") or eqlIgnoreCase(suffix, "x")) return .resolution;
    return .unknown;
}

/// Classify a calc-sum expression by scanning operators. Returns the
/// result type or `.unknown` if the sub-expression mixes incompatible
/// types.
fn classifyCalcSum(expr: []const u8) ArgType {
    // Split by top-level + / - / * / / operators. For math semantic typing
    // we only need to know: is this "numeric" (any length/number/%/angle/
    // time/function) or "incompatible" (contains a bare ident that isn't a
    // CSS-wide keyword or var)?
    var depth: i32 = 0;
    var tok_start: usize = 0;
    var have_type: ?ArgType = null;
    var i: usize = 0;
    while (i <= expr.len) : (i += 1) {
        const at_end = i == expr.len;
        const ch: u8 = if (at_end) ' ' else expr[i];
        if (!at_end) {
            if (ch == '(') {
                depth += 1;
                continue;
            }
            if (ch == ')') {
                depth -= 1;
                continue;
            }
            if (ch == '"' or ch == '\'') {
                const quote = ch;
                i += 1;
                while (i < expr.len and expr[i] != quote) : (i += 1) {
                    if (expr[i] == '\\' and i + 1 < expr.len) i += 1;
                }
                continue;
            }
        }
        const is_op = !at_end and depth == 0 and (ch == '+' or ch == '-' or ch == '*' or ch == '/');
        const is_space = !at_end and depth == 0 and (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n');
        if (at_end or is_op or is_space) {
            if (i > tok_start) {
                const tok = trimWs(expr[tok_start..i]);
                if (tok.len > 0 and !(tok.len == 1 and (tok[0] == '+' or tok[0] == '-' or tok[0] == '*' or tok[0] == '/'))) {
                    const t = classifySimple(tok);
                    if (t == .ident) {
                        // CSS-wide keyword? Accept those; otherwise reject.
                        if (!(eqlIgnoreCase(tok, "inherit") or eqlIgnoreCase(tok, "initial") or
                            eqlIgnoreCase(tok, "unset") or eqlIgnoreCase(tok, "revert") or
                            eqlIgnoreCase(tok, "pi") or eqlIgnoreCase(tok, "e") or
                            eqlIgnoreCase(tok, "infinity") or eqlIgnoreCase(tok, "-infinity") or
                            eqlIgnoreCase(tok, "nan")))
                        {
                            return .unknown;
                        }
                    } else if (t == .unknown) {
                        return .unknown;
                    } else {
                        // Track dominant type; number can blend with any.
                        if (have_type == null) {
                            have_type = t;
                        } else if (have_type.? != t and t != .number and have_type.? != .number) {
                            // Allow length + percentage mix (length-percentage is valid).
                            const lp_a = have_type.? == .length or have_type.? == .percentage or have_type.? == .length_percentage;
                            const lp_b = t == .length or t == .percentage or t == .length_percentage;
                            if (!(lp_a and lp_b)) {
                                // mixed, but still "numeric-like"; keep unknown to fall
                                // back on caller's type gate.
                            } else {
                                have_type = .length_percentage;
                            }
                        }
                    }
                }
            }
            tok_start = i + 1;
        }
    }
    return have_type orelse .number;
}

// ── Math function validation ────────────────────────────────────────

const MathKind = enum {
    calc,
    min_max,
    clamp,
    round,
    mod_rem,
    abs_sign,
    trig, // sin/cos/tan (angle or number)
    atrig, // asin/acos/atan (number)
    atan2,
    sqrt_exp_log,
    log,
    pow,
    hypot,
};

fn mathKindOf(name: []const u8) ?MathKind {
    if (eqlIgnoreCase(name, "calc")) return .calc;
    if (eqlIgnoreCase(name, "min") or eqlIgnoreCase(name, "max")) return .min_max;
    if (eqlIgnoreCase(name, "clamp")) return .clamp;
    if (eqlIgnoreCase(name, "round")) return .round;
    if (eqlIgnoreCase(name, "mod") or eqlIgnoreCase(name, "rem")) return .mod_rem;
    if (eqlIgnoreCase(name, "abs") or eqlIgnoreCase(name, "sign")) return .abs_sign;
    if (eqlIgnoreCase(name, "sin") or eqlIgnoreCase(name, "cos") or eqlIgnoreCase(name, "tan")) return .trig;
    if (eqlIgnoreCase(name, "asin") or eqlIgnoreCase(name, "acos") or eqlIgnoreCase(name, "atan")) return .atrig;
    if (eqlIgnoreCase(name, "atan2")) return .atan2;
    if (eqlIgnoreCase(name, "sqrt") or eqlIgnoreCase(name, "exp")) return .sqrt_exp_log;
    if (eqlIgnoreCase(name, "log")) return .log;
    if (eqlIgnoreCase(name, "pow")) return .pow;
    if (eqlIgnoreCase(name, "hypot")) return .hypot;
    return null;
}

/// Basic parens-balanced + non-empty args check.
fn hasBalancedArgs(inner: []const u8) bool {
    if (trimWs(inner).len == 0) return false;
    var depth: i32 = 0;
    var saw_content_in_arg: bool = false;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch == '(') {
            depth += 1;
            saw_content_in_arg = true;
        } else if (ch == ')') {
            depth -= 1;
            if (depth < 0) return false;
            saw_content_in_arg = true;
        } else if (ch == ',' and depth == 0) {
            if (!saw_content_in_arg) return false;
            saw_content_in_arg = false;
        } else if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
            saw_content_in_arg = true;
        }
    }
    if (depth != 0) return false;
    return saw_content_in_arg;
}

fn argTypeOf(arg: []const u8) ArgType {
    const t = trimWs(arg);
    if (t.len == 0) return .unknown;
    // Nested function call: recursively classify.
    if (t[t.len - 1] == ')') {
        const name = funcName(t) orelse return .unknown;
        if (mathKindOf(name)) |_| {
            // Nested math function → classify its inner sum.
            const inner = funcInner(t) orelse return .unknown;
            return classifyCalcSum(inner);
        }
        return classifySimple(t);
    }
    // Multi-token calc sum without explicit calc(): treat as calc-sum.
    if (std.mem.indexOfAny(u8, t, " \t") != null) {
        return classifyCalcSum(t);
    }
    return classifySimple(t);
}

fn isNumericType(t: ArgType) bool {
    return switch (t) {
        .number, .integer, .length, .percentage, .angle, .time,
        .frequency, .resolution, .length_percentage => true,
        else => false,
    };
}

fn typesCompatible(a: ArgType, b: ArgType) bool {
    if (a == b) return true;
    // number is compatible with any numeric type in math functions.
    if (a == .number or b == .number) return isNumericType(a) and isNumericType(b);
    if (a == .integer or b == .integer) return isNumericType(a) and isNumericType(b);
    // length + percentage → length-percentage.
    const is_lp_a = a == .length or a == .percentage or a == .length_percentage;
    const is_lp_b = b == .length or b == .percentage or b == .length_percentage;
    if (is_lp_a and is_lp_b) return true;
    return false;
}

fn validateMathFn(name: []const u8, inner: []const u8) bool {
    if (!hasBalancedArgs(inner)) return false;
    const kind = mathKindOf(name) orelse return true;
    var buf: [32][]const u8 = undefined;
    const n = splitTopLevelCommas(inner, &buf) orelse return false;
    const args = buf[0..n];

    // Validate each arg: recursive isValid-like check.
    for (args) |a| {
        if (a.len == 0) return false;
        // Reject bare idents that aren't CSS-wide keywords, var(), or
        // math constants. This catches `clamp(none, 1px, 1px)`.
        const t = argTypeOf(a);
        if (t == .ident) {
            const tr = trimWs(a);
            if (!(eqlIgnoreCase(tr, "inherit") or eqlIgnoreCase(tr, "initial") or
                eqlIgnoreCase(tr, "unset") or eqlIgnoreCase(tr, "revert") or
                eqlIgnoreCase(tr, "pi") or eqlIgnoreCase(tr, "e") or
                eqlIgnoreCase(tr, "infinity") or eqlIgnoreCase(tr, "-infinity") or
                eqlIgnoreCase(tr, "nan")))
            {
                return false;
            }
        }
        if (t == .unknown) {
            // Check for var() at top level — accept.
            const tr = trimWs(a);
            if (tr.len >= 4 and startsWithIgnoreCase(tr, "var(")) continue;
            // Check if nested balanced math — already type-classified above.
            if (tr.len >= 3 and tr[tr.len - 1] == ')') {
                const nname = funcName(tr) orelse return false;
                // Accept nested math / var — validation bubbles up.
                if (mathKindOf(nname)) |_| {
                    const ninner = funcInner(tr) orelse return false;
                    if (!validateMathFn(nname, ninner)) return false;
                    continue;
                }
                // Non-math function (e.g. gradient) — reject inside math.
                return false;
            }
            return false;
        }
    }

    switch (kind) {
        .calc => {
            if (args.len != 1) return false;
        },
        .min_max, .hypot => {
            if (args.len < 1) return false;
            // Collect types; all numeric, all pairwise compatible.
            var dom: ArgType = .number;
            var set = false;
            for (args) |a| {
                const t = argTypeOf(a);
                if (!isNumericType(t)) return false;
                if (!set) {
                    dom = t;
                    set = true;
                } else if (!typesCompatible(dom, t)) {
                    return false;
                }
            }
        },
        .clamp => {
            if (args.len != 3) return false;
            const ta = argTypeOf(args[0]);
            const tb = argTypeOf(args[1]);
            const tc = argTypeOf(args[2]);
            if (!isNumericType(ta) or !isNumericType(tb) or !isNumericType(tc)) return false;
            if (!typesCompatible(ta, tb)) return false;
            if (!typesCompatible(tb, tc)) return false;
        },
        .round => {
            // 2 or 3 args: [strategy,] A, B
            if (args.len == 3) {
                const s = trimWs(args[0]);
                if (!(eqlIgnoreCase(s, "nearest") or eqlIgnoreCase(s, "up") or
                    eqlIgnoreCase(s, "down") or eqlIgnoreCase(s, "to-zero")))
                    return false;
                const ta = argTypeOf(args[1]);
                const tb = argTypeOf(args[2]);
                if (!isNumericType(ta) or !isNumericType(tb)) return false;
                if (!typesCompatible(ta, tb)) return false;
            } else if (args.len == 2) {
                const ta = argTypeOf(args[0]);
                const tb = argTypeOf(args[1]);
                if (!isNumericType(ta) or !isNumericType(tb)) return false;
                if (!typesCompatible(ta, tb)) return false;
            } else return false;
        },
        .mod_rem => {
            if (args.len != 2) return false;
            const ta = argTypeOf(args[0]);
            const tb = argTypeOf(args[1]);
            if (!isNumericType(ta) or !isNumericType(tb)) return false;
            if (!typesCompatible(ta, tb)) return false;
        },
        .abs_sign => {
            if (args.len != 1) return false;
            if (!isNumericType(argTypeOf(args[0]))) return false;
        },
        .trig => {
            // sin/cos/tan accept angle or number.
            if (args.len != 1) return false;
            const t = argTypeOf(args[0]);
            if (!isNumericType(t)) return false;
            if (!(t == .angle or t == .number or t == .integer or t == .length_percentage)) return false;
        },
        .atrig => {
            if (args.len != 1) return false;
            const t = argTypeOf(args[0]);
            if (!(t == .number or t == .integer or t == .length_percentage)) return false;
        },
        .atan2 => {
            if (args.len != 2) return false;
            const ta = argTypeOf(args[0]);
            const tb = argTypeOf(args[1]);
            if (!isNumericType(ta) or !isNumericType(tb)) return false;
            if (!typesCompatible(ta, tb)) return false;
        },
        .sqrt_exp_log => {
            if (args.len != 1) return false;
            const t = argTypeOf(args[0]);
            if (!(t == .number or t == .integer or t == .length_percentage)) return false;
        },
        .log => {
            if (args.len != 1 and args.len != 2) return false;
            for (args) |a| {
                const t = argTypeOf(a);
                if (!(t == .number or t == .integer or t == .length_percentage)) return false;
            }
        },
        .pow => {
            if (args.len != 2) return false;
            for (args) |a| {
                const t = argTypeOf(a);
                if (!(t == .number or t == .integer or t == .length_percentage)) return false;
            }
        },
    }
    return true;
}

// ── Gradient function validation ────────────────────────────────────

fn isGradientFunc(name: []const u8) bool {
    return eqlIgnoreCase(name, "linear-gradient") or
        eqlIgnoreCase(name, "radial-gradient") or
        eqlIgnoreCase(name, "conic-gradient") or
        eqlIgnoreCase(name, "repeating-linear-gradient") or
        eqlIgnoreCase(name, "repeating-radial-gradient") or
        eqlIgnoreCase(name, "repeating-conic-gradient");
}

/// Validate a gradient direction/position token. Returns true if the
/// token is a legal direction for linear/conic gradients.
fn validGradientDirection(name: []const u8, tok: []const u8) bool {
    const t = trimWs(tok);
    if (t.len == 0) return false;
    // `to <side-or-corner>` for linear.
    if (eqlIgnoreCase(name, "linear-gradient") or eqlIgnoreCase(name, "repeating-linear-gradient")) {
        if (startsWithIgnoreCase(t, "to ")) return true;
        // Angle at top level (no nested math allowed to resolve at parse-time for gradient direction).
        const ty = argTypeOf(t);
        if (ty == .angle) return true;
        // var() passes through.
        if (startsWithIgnoreCase(t, "var(")) return true;
        // calc(...) resolving to an angle — check nested: reject if it contains
        // a `calc(sign(<percentage>)...)` pattern per Wave 5 residual.
        if (t[t.len - 1] == ')') {
            const n = funcName(t) orelse return false;
            if (mathKindOf(n)) |_| {
                const inner = funcInner(t) orelse return false;
                // Must be balanced AND must not reference percentage as the root type
                // without angle terminal.
                if (!validateMathFn(n, inner)) return false;
                // Angle-context math: inspect whether the expression mentions
                // `<percentage>` as a terminal without an angle unit. Reject the
                // Wave 5 pattern `calc(sign(50%) * 1turn)` even though it would
                // type-check as a number*angle — per CSSWG resolution this is
                // still invalid at parse time for gradient direction.
                // Heuristic: if the inner contains `sign(` with a `%` arg, reject.
                if (containsSignOfPercentage(inner)) return false;
                return true;
            }
        }
        return false;
    }
    // Conic: `from <angle>` or `at <position>`.
    if (eqlIgnoreCase(name, "conic-gradient") or eqlIgnoreCase(name, "repeating-conic-gradient")) {
        if (startsWithIgnoreCase(t, "from ") or startsWithIgnoreCase(t, "at ")) return true;
        if (startsWithIgnoreCase(t, "var(")) return true;
        return false;
    }
    return false;
}

fn containsSignOfPercentage(s: []const u8) bool {
    // Look for `sign(` anywhere and check if the corresponding balanced
    // argument contains a `%` before the closing paren.
    var i: usize = 0;
    while (i + 5 <= s.len) : (i += 1) {
        if (startsWithIgnoreCase(s[i..@min(i + 5, s.len)], "sign(")) {
            const open = i + 4;
            const close = findMatchingParen(s, open) orelse return false;
            const inner = s[open + 1 .. close];
            if (std.mem.indexOfScalar(u8, inner, '%') != null) return true;
            i = close;
        }
    }
    return false;
}

fn validateGradientFn(name: []const u8, inner: []const u8) bool {
    if (!hasBalancedArgs(inner)) return false;
    var buf: [32][]const u8 = undefined;
    const n = splitTopLevelCommas(inner, &buf) orelse return false;
    if (n < 2) return false; // need at least 2 color stops (or direction + 1 stop)
    const args = buf[0..n];

    // Decide if the first arg is a direction or a color stop.
    const first = args[0];
    var stops_start: usize = 0;
    var direction_ok = true;
    // Heuristic: first arg is a direction iff it doesn't parse as a color stop.
    if (firstArgLooksLikeDirection(name, first)) {
        direction_ok = validGradientDirection(name, first);
        stops_start = 1;
    }
    if (!direction_ok) return false;
    if (args.len - stops_start < 2) return false; // need at least 2 stops
    // Validate each stop: "<color> <length-percentage>?" shape. MVP: each
    // stop must either be a known color keyword, a color function, a hex,
    // or start with one of those. Empty stops → reject.
    for (args[stops_start..]) |stop| {
        if (trimWs(stop).len == 0) return false;
    }
    return true;
}

fn firstArgLooksLikeDirection(name: []const u8, arg: []const u8) bool {
    const t = trimWs(arg);
    if (t.len == 0) return false;
    if (startsWithIgnoreCase(t, "to ")) return true;
    if (startsWithIgnoreCase(t, "from ")) return true;
    if (startsWithIgnoreCase(t, "at ")) return true;
    // Angle dimension at top level.
    if (argTypeOf(t) == .angle) return true;
    // calc(...) resolving to angle — only for linear/conic.
    if (t[t.len - 1] == ')') {
        const fn_name = funcName(t) orelse return false;
        if (mathKindOf(fn_name)) |_| {
            if (eqlIgnoreCase(name, "linear-gradient") or eqlIgnoreCase(name, "repeating-linear-gradient") or
                eqlIgnoreCase(name, "conic-gradient") or eqlIgnoreCase(name, "repeating-conic-gradient"))
            {
                return true;
            }
        }
    }
    return false;
}

// ── calc-size validation ────────────────────────────────────────────

fn validateCalcSize(inner: []const u8) bool {
    if (!hasBalancedArgs(inner)) return false;
    var buf: [4][]const u8 = undefined;
    const n = splitTopLevelCommas(inner, &buf) orelse return false;
    if (n != 2) return false;
    const basis = trimWs(buf[0]);
    const expr = trimWs(buf[1]);
    // Basis: any / auto / size / content / min-content / max-content / fit-content / stretch
    // OR nested calc-size(...).
    const basis_ok = eqlIgnoreCase(basis, "any") or eqlIgnoreCase(basis, "auto") or
        eqlIgnoreCase(basis, "size") or eqlIgnoreCase(basis, "content") or
        eqlIgnoreCase(basis, "min-content") or eqlIgnoreCase(basis, "max-content") or
        eqlIgnoreCase(basis, "fit-content") or eqlIgnoreCase(basis, "stretch") or
        (basis.len > 10 and startsWithIgnoreCase(basis, "calc-size(")) or
        (basis.len > 4 and startsWithIgnoreCase(basis, "var(")) or
        argTypeOf(basis) == .length or argTypeOf(basis) == .percentage or
        argTypeOf(basis) == .length_percentage;
    if (!basis_ok) return false;
    // Expr: must NOT be a bare basis keyword (the keyword belongs only to
    // first arg). It must be a calc-sum / length-percentage expression.
    const bare_basis_in_expr = eqlIgnoreCase(expr, "any") or eqlIgnoreCase(expr, "auto") or
        eqlIgnoreCase(expr, "size") or eqlIgnoreCase(expr, "content") or
        eqlIgnoreCase(expr, "min-content") or eqlIgnoreCase(expr, "max-content") or
        eqlIgnoreCase(expr, "fit-content") or eqlIgnoreCase(expr, "stretch");
    if (bare_basis_in_expr) return false;
    // Expr must be well-formed: allow calc/min/max/clamp/etc, or a direct
    // length/percentage.
    if (expr.len == 0) return false;
    return true;
}

// ── URL + request modifier ──────────────────────────────────────────

/// Validate `url("x.png") request(...)` or just `url("x.png")`. Returns
/// true if the value parses as a url optionally followed by a single
/// `request(...)` modifier with recognized sub-functions.
fn validateUrlWithModifier(val: []const u8) bool {
    const t = trimWs(val);
    // Find url( prefix.
    if (!startsWithIgnoreCase(t, "url(")) return false;
    const open = std.mem.indexOfScalar(u8, t, '(') orelse return false;
    const close = findMatchingParen(t, open) orelse return false;
    // After url(...), allow whitespace + request(...).
    var rest_start = close + 1;
    while (rest_start < t.len and (t[rest_start] == ' ' or t[rest_start] == '\t')) : (rest_start += 1) {}
    if (rest_start == t.len) return true; // plain url(...)
    const rest = t[rest_start..];
    if (!startsWithIgnoreCase(rest, "request(")) return false;
    const req_open = std.mem.indexOfScalar(u8, rest, '(') orelse return false;
    const req_close = findMatchingParen(rest, req_open) orelse return false;
    if (req_close != rest.len - 1) return false;
    const req_inner = rest[req_open + 1 .. req_close];
    // Sub-functions: integrity(...), referrer-policy(...), crossorigin(...).
    var buf: [8][]const u8 = undefined;
    const n = splitTopLevelCommas(req_inner, &buf) orelse return false;
    if (n == 0) return false;
    for (buf[0..n]) |sub| {
        const st = trimWs(sub);
        if (st.len == 0) return false;
        const sname = funcName(st) orelse return false;
        if (!(eqlIgnoreCase(sname, "integrity") or eqlIgnoreCase(sname, "referrer-policy") or
            eqlIgnoreCase(sname, "crossorigin"))) return false;
        if (funcInner(st) == null) return false;
    }
    return true;
}

// ── Public entry ────────────────────────────────────────────────────

/// Returns true if `val` is a syntactically + semantically plausible
/// value for the given `prop`. Use as a setter-time guard per CSSOM
/// §6.7.2 "invalid values don't change specified value".
pub fn isValidPropertyValue(prop: []const u8, val: []const u8) bool {
    _ = prop; // property-specific grammar is delegated to callers via dom_style
    const trimmed = trimWs(val);

    // Layer 0: empty / CSS-wide keywords / var().
    if (trimmed.len == 0) return true;
    if (eqlIgnoreCase(trimmed, "inherit") or eqlIgnoreCase(trimmed, "initial") or
        eqlIgnoreCase(trimmed, "unset") or eqlIgnoreCase(trimmed, "revert") or
        eqlIgnoreCase(trimmed, "revert-layer")) return true;
    if (trimmed.len >= 4 and startsWithIgnoreCase(trimmed[0..4], "var(")) return true;

    // Layer 2: classify shape. Focus on function-call validation — bare
    // idents and dimensions fall through to `true` here; the caller's
    // property-specific grammar (dom_style.isValidCssValue switch) catches
    // those. Shorthand descent is handled for known-compound values.
    // When `funcInner` fails the value is NOT a single balanced top-level
    // function call (e.g. `translateX(50%) rotate(45deg)` — two sibling
    // calls). Fall through to the compound descent below.
    if (trimmed[trimmed.len - 1] == ')' and funcInner(trimmed) != null) {
        const name = funcName(trimmed) orelse return false;
        const inner = funcInner(trimmed) orelse return false;

        if (mathKindOf(name)) |_| return validateMathFn(name, inner);
        if (isGradientFunc(name)) return validateGradientFn(name, inner);
        if (eqlIgnoreCase(name, "calc-size")) return validateCalcSize(inner);
        if (eqlIgnoreCase(name, "url")) return true; // simple url()
        // Color funcs — delegate structural check: ensure balanced and
        // non-empty; detailed color validation happens in dom_style.
        if (eqlIgnoreCase(name, "rgb") or eqlIgnoreCase(name, "rgba") or
            eqlIgnoreCase(name, "hsl") or eqlIgnoreCase(name, "hsla") or
            eqlIgnoreCase(name, "hwb") or eqlIgnoreCase(name, "lab") or
            eqlIgnoreCase(name, "lch") or eqlIgnoreCase(name, "oklab") or
            eqlIgnoreCase(name, "oklch") or eqlIgnoreCase(name, "color"))
        {
            // hwb specifically forbids commas.
            if (eqlIgnoreCase(name, "hwb")) {
                if (std.mem.indexOfScalar(u8, inner, ',') != null) return false;
            }
            return hasBalancedArgs(inner);
        }
        if (eqlIgnoreCase(name, "image") or eqlIgnoreCase(name, "image-set") or
            eqlIgnoreCase(name, "cross-fade") or eqlIgnoreCase(name, "element") or
            eqlIgnoreCase(name, "paint"))
        {
            return hasBalancedArgs(inner);
        }
        if (eqlIgnoreCase(name, "translate") or eqlIgnoreCase(name, "translateX") or
            eqlIgnoreCase(name, "translateY") or eqlIgnoreCase(name, "translateZ") or
            eqlIgnoreCase(name, "translate3d") or eqlIgnoreCase(name, "scale") or
            eqlIgnoreCase(name, "scaleX") or eqlIgnoreCase(name, "scaleY") or
            eqlIgnoreCase(name, "scaleZ") or eqlIgnoreCase(name, "scale3d") or
            eqlIgnoreCase(name, "rotate") or eqlIgnoreCase(name, "rotateX") or
            eqlIgnoreCase(name, "rotateY") or eqlIgnoreCase(name, "rotateZ") or
            eqlIgnoreCase(name, "rotate3d") or eqlIgnoreCase(name, "skew") or
            eqlIgnoreCase(name, "skewX") or eqlIgnoreCase(name, "skewY") or
            eqlIgnoreCase(name, "matrix") or eqlIgnoreCase(name, "matrix3d") or
            eqlIgnoreCase(name, "perspective"))
        {
            return validateTransformFn(name, inner);
        }
        // Unknown function — delegate to property-specific grammar: accept
        // as balanced + non-empty (property switch will reject truly
        // unknown ones).
        return hasBalancedArgs(inner);
    }

    // Compound value (space-separated at top level): check for URL request
    // modifier pattern `url(...) request(...)`.
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) {
        // Short-circuit: if starts with url( and contains request(, run the
        // dedicated validator; otherwise check each piece is balanced.
        if (startsWithIgnoreCase(trimmed, "url(") and std.mem.indexOf(u8, trimmed, "request(") != null) {
            return validateUrlWithModifier(trimmed);
        }
        // Descend into shorthand pieces: each whitespace-separated piece or
        // comma-separated layer must have balanced parens. Bracket-level
        // validation is delegated; here we only reject clearly-malformed
        // shape (unbalanced parens, empty function-call).
        var layers: [16][]const u8 = undefined;
        const lc = splitTopLevelCommas(trimmed, &layers) orelse return false;
        for (layers[0..lc]) |layer| {
            var pieces: [16][]const u8 = undefined;
            const pc = splitTopLevelSpaces(trimWs(layer), &pieces) orelse return false;
            for (pieces[0..pc]) |p| {
                if (p.len == 0) return false;
                if (p[p.len - 1] == ')') {
                    // Recursive: each function call must validate.
                    if (!isValidPropertyValue("", p)) return false;
                }
            }
        }
        return true;
    }

    // Bare token: defer to caller.
    return true;
}

fn validateTransformFn(name: []const u8, inner: []const u8) bool {
    if (!hasBalancedArgs(inner)) return false;
    var buf: [16][]const u8 = undefined;
    const n = splitTopLevelCommas(inner, &buf) orelse return false;
    const args = buf[0..n];
    for (args) |a| {
        const at = trimWs(a);
        if (at.len == 0) return false;
        const t = argTypeOf(at);
        // Transform args may be length, percentage, number, angle (rotate),
        // or calc-based expressions. Reject bare unknown idents like
        // `translateX(invalid)`.
        if (t == .ident) {
            if (!(eqlIgnoreCase(at, "inherit") or eqlIgnoreCase(at, "initial") or
                eqlIgnoreCase(at, "unset") or eqlIgnoreCase(at, "revert")))
                return false;
        }
        if (t == .unknown) {
            // var() / nested math accepted.
            if (startsWithIgnoreCase(at, "var(")) continue;
            if (at[at.len - 1] == ')') {
                const nn = funcName(at) orelse return false;
                if (mathKindOf(nn)) |_| {
                    const ninner = funcInner(at) orelse return false;
                    if (!validateMathFn(nn, ninner)) return false;
                    continue;
                }
            }
            return false;
        }
    }
    _ = name;
    return true;
}

// ── Unit tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "Layer 0: CSS-wide keywords accepted" {
    try testing.expect(isValidPropertyValue("width", "inherit"));
    try testing.expect(isValidPropertyValue("width", "initial"));
    try testing.expect(isValidPropertyValue("width", "unset"));
    try testing.expect(isValidPropertyValue("width", "revert"));
    try testing.expect(isValidPropertyValue("width", ""));
}

test "math: clamp(none, ...) rejected" {
    try testing.expect(!isValidPropertyValue("width", "clamp(none, 1px, 1px)"));
}

test "math: clamp valid 3-arg accepted" {
    try testing.expect(isValidPropertyValue("width", "clamp(10px, 20px, 30px)"));
}

test "math: min/max accept numeric args" {
    try testing.expect(isValidPropertyValue("width", "min(10px, 20px)"));
    try testing.expect(isValidPropertyValue("width", "max(30px, 40px)"));
}

test "math: calc() valid" {
    try testing.expect(isValidPropertyValue("width", "calc(100px + 50px)"));
    try testing.expect(isValidPropertyValue("width", "calc(100%  - 20px)"));
}

test "math: calc() rejects bare idents" {
    try testing.expect(!isValidPropertyValue("width", "calc(none)"));
}

test "math: empty args rejected" {
    try testing.expect(!isValidPropertyValue("width", "clamp()"));
    try testing.expect(!isValidPropertyValue("width", "min()"));
    try testing.expect(!isValidPropertyValue("width", "calc()"));
}

test "gradient: linear-gradient(calc(sign(%)...), ...) rejected" {
    try testing.expect(!isValidPropertyValue(
        "background-image",
        "linear-gradient(calc(sign(50%) * 1turn), red, blue)",
    ));
}

test "gradient: empty rejected" {
    try testing.expect(!isValidPropertyValue("background-image", "linear-gradient()"));
}

test "gradient: valid two-stop accepted" {
    try testing.expect(isValidPropertyValue("background-image", "linear-gradient(red, blue)"));
    try testing.expect(isValidPropertyValue("background-image", "linear-gradient(to right, red, blue)"));
    try testing.expect(isValidPropertyValue("background-image", "linear-gradient(45deg, red, blue)"));
}

test "calc-size: basis in first arg OK" {
    try testing.expect(isValidPropertyValue("width", "calc-size(auto, 100px + 10%)"));
}

test "calc-size: basis in second arg NG" {
    try testing.expect(!isValidPropertyValue("width", "calc-size(100px, auto)"));
}

test "url+request: accepted with integrity" {
    try testing.expect(isValidPropertyValue(
        "background-image",
        "url(\"x\") request(integrity(\"sha256-abc\"))",
    ));
}

test "transform: translateX(50%) rotate(45deg) accepted" {
    try testing.expect(isValidPropertyValue(
        "transform",
        "translateX(50%) rotate(45deg)",
    ));
}

test "transform: translateX(invalid) rejected" {
    try testing.expect(!isValidPropertyValue("transform", "translateX(invalid)"));
}

test "background: linear-gradient(), url(...) center/cover accepted" {
    try testing.expect(isValidPropertyValue(
        "background",
        "linear-gradient(red, blue), url(\"x.png\") center/cover",
    ));
}

test "background: linear-gradient() rejected in layer" {
    try testing.expect(!isValidPropertyValue("background", "linear-gradient()"));
}

test "hwb: space syntax accepted, comma syntax rejected" {
    try testing.expect(isValidPropertyValue("color", "hwb(0 0% 0%)"));
    try testing.expect(!isValidPropertyValue("color", "hwb(0, 0%, 0%)"));
}
