/// Unicode NFC (Canonical Decomposition, followed by Canonical Composition).
/// Used by IDNA processing to normalize domain labels.
///
/// Algorithm:
///   1. Recursively decompose all characters (canonical decomposition)
///   2. Sort combining marks by Canonical Combining Class (stable)
///   3. Compose adjacent starter + combining pairs (canonical composition)
///
/// Hangul syllables (U+AC00..U+D7A3) are handled algorithmically per Unicode Ch. 3.12.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("tables.zig");

// ── Hangul constants (Unicode Ch. 3.12) ──────────────────────────────

const S_BASE: u21 = 0xAC00;
const L_BASE: u21 = 0x1100;
const V_BASE: u21 = 0x1161;
const T_BASE: u21 = 0x11A7;
const L_COUNT: u21 = 19;
const V_COUNT: u21 = 21;
const T_COUNT: u21 = 28;
const N_COUNT: u21 = V_COUNT * T_COUNT; // 588
const S_COUNT: u21 = L_COUNT * N_COUNT; // 11172

/// NFC normalize a sequence of Unicode code points.
pub fn nfcNormalize(allocator: Allocator, input: []const u21) ![]u21 {
    // Step 1: Canonical decomposition (recursive)
    var decomposed: std.ArrayListUnmanaged(u21) = .empty;
    defer decomposed.deinit(allocator);

    for (input) |cp| {
        try decomposeRecursive(allocator, &decomposed, cp);
    }

    // Step 2: Sort combining marks by CCC (stable sort)
    sortByCcc(decomposed.items);

    // Step 3: Canonical composition
    return compose(allocator, decomposed.items);
}

/// Recursively decompose a code point using canonical decomposition.
fn decomposeRecursive(allocator: Allocator, out: *std.ArrayListUnmanaged(u21), cp: u21) !void {
    // Hangul algorithmic decomposition
    if (cp >= S_BASE and cp < S_BASE + S_COUNT) {
        const s_index = cp - S_BASE;
        const l = L_BASE + s_index / N_COUNT;
        const v = V_BASE + (s_index % N_COUNT) / T_COUNT;
        const t_offset = s_index % T_COUNT;
        try out.append(allocator, l);
        try out.append(allocator, v);
        if (t_offset > 0) {
            try out.append(allocator, T_BASE + t_offset);
        }
        return;
    }

    // Table lookup
    if (tables.getDecomposition(cp)) |decomp| {
        // Recursively decompose each component
        for (decomp) |sub_cp| {
            try decomposeRecursive(allocator, out, sub_cp);
        }
    } else {
        // No decomposition — emit as-is
        try out.append(allocator, cp);
    }
}

/// Sort combining marks by Canonical Combining Class.
/// Stable sort: only reorders adjacent marks with different CCC, preserving
/// relative order of marks with the same CCC.
fn sortByCcc(items: []u21) void {
    if (items.len < 2) return;

    // Bubble sort on combining marks (stable, typically very short runs)
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const ccc_i = tables.getCcc(items[i]);
        if (ccc_i == 0) {
            // Starter — don't move
            continue;
        }
        var j = i;
        while (j > 0) {
            const ccc_j = tables.getCcc(items[j - 1]);
            if (ccc_j == 0 or ccc_j <= ccc_i) break;
            // Swap
            const tmp = items[j];
            items[j] = items[j - 1];
            items[j - 1] = tmp;
            j -= 1;
        }
    }
}

/// Canonical composition: combine starter + combining mark pairs.
fn compose(allocator: Allocator, input: []const u21) ![]u21 {
    if (input.len == 0) return try allocator.alloc(u21, 0);

    var result: std.ArrayListUnmanaged(u21) = .empty;
    errdefer result.deinit(allocator);

    // Start with the first code point as the "starter candidate"
    try result.append(allocator, input[0]);

    var last_starter_idx: usize = 0;
    var last_ccc: u8 = if (tables.getCcc(input[0]) != 0) 255 else 0;

    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        const cp = input[i];
        const ccc = tables.getCcc(cp);
        const starter = result.items[last_starter_idx];

        // Try Hangul LV + T composition
        if (starter >= S_BASE and starter < S_BASE + S_COUNT) {
            const s_index = starter - S_BASE;
            if (s_index % T_COUNT == 0 and cp >= T_BASE + 1 and cp <= T_BASE + T_COUNT - 1) {
                // LV + T → LVT
                result.items[last_starter_idx] = starter + (cp - T_BASE);
                continue;
            }
        }

        // Try Hangul L + V composition
        if (starter >= L_BASE and starter < L_BASE + L_COUNT) {
            if (cp >= V_BASE and cp < V_BASE + V_COUNT) {
                // L + V → LV
                result.items[last_starter_idx] = S_BASE + (starter - L_BASE) * N_COUNT + (cp - V_BASE) * T_COUNT;
                continue;
            }
        }

        // Try table-based composition
        // Blocked check: a combining mark is blocked if there is a combining mark
        // between it and the starter with CCC >= its CCC (or CCC == 0).
        const blocked = (last_ccc != 0 and last_ccc >= ccc);

        if (!blocked and ccc != 0) {
            // Non-blocked combining mark — try composing with starter
            if (tables.getComposition(starter, cp)) |composed| {
                result.items[last_starter_idx] = composed;
                // Don't update last_ccc — the composed char replaces the starter
                continue;
            }
        } else if (!blocked and ccc == 0) {
            // Another starter — try composing with previous starter
            if (tables.getComposition(starter, cp)) |composed| {
                result.items[last_starter_idx] = composed;
                continue;
            }
        }

        // Cannot compose — append to result
        try result.append(allocator, cp);

        if (ccc == 0) {
            // New starter
            last_starter_idx = result.items.len - 1;
            last_ccc = 0;
        } else {
            last_ccc = ccc;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

test "NFC already normalized ASCII" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &input, result);
}

test "NFC compose e + combining acute -> e-acute" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 0x0065, 0x0301 }; // 'e' + combining acute
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0x00E9}, result); // e-acute
}

test "NFC already composed e-acute" {
    const alloc = std.testing.allocator;
    const input = [_]u21{0x00E9}; // already NFC
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0x00E9}, result);
}

test "NFC Hangul L + V composition" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 0x1100, 0x1161 }; // G + A → GA (U+AC00)
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0xAC00}, result);
}

test "NFC Hangul LV + T composition" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 0xAC00, 0x11A8 }; // GA + G → GAG (U+AC01)
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0xAC01}, result);
}

test "NFC Hangul L + V + T composition" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 0x1100, 0x1161, 0x11A8 }; // G + A + G → GAG
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0xAC01}, result);
}

test "NFC combining mark reordering" {
    const alloc = std.testing.allocator;
    // U+0065 + U+0327 (cedilla, CCC=202) + U+0301 (acute, CCC=230)
    // CCC order: 202 < 230, so order preserved after sort.
    // Composition: e + cedilla → U+0229 (e-cedilla), acute stays.
    // Result: U+0229 + U+0301 (2 chars)
    const input = [_]u21{ 0x0065, 0x0327, 0x0301 };
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u21, 0x0229), result[0]); // e-cedilla
    try std.testing.expectEqual(@as(u21, 0x0301), result[1]); // acute remains
}

test "NFC empty input" {
    const alloc = std.testing.allocator;
    const result = try nfcNormalize(alloc, &[_]u21{});
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "NFC single character" {
    const alloc = std.testing.allocator;
    const input = [_]u21{0x00FC}; // u-umlaut
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0x00FC}, result);
}

test "NFC decomposed u-umlaut recomposes" {
    const alloc = std.testing.allocator;
    const input = [_]u21{ 0x0075, 0x0308 }; // u + combining diaeresis
    const result = try nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u21, &[_]u21{0x00FC}, result); // u-umlaut
}
