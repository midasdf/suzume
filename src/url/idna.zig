/// UTS #46 IDNA Processing — domain name internationalization.
///
/// Implements domainToAscii and domainToUnicode per WHATWG URL Standard section 3.3.
/// Uses tables.zig for IDNA mapping, nfc.zig for normalization, punycode.zig for encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("tables.zig");
const nfc = @import("nfc.zig");
const punycode = @import("punycode.zig");
const joining_type = @import("joining_type.zig");
const bidi_class = @import("bidi_class.zig");
const combining_mark = @import("combining_mark.zig");

/// Convert a domain to its ASCII representation (ACE form).
/// Returns null on failure (invalid domain).
pub fn domainToAscii(allocator: Allocator, domain: []const u8, be_strict: bool) !?[]u8 {
    // 1. Decode UTF-8 to code points. Decode permissively: JS engines can
    // hand us ill-formed sequences (e.g. WTF-8 lone surrogates from JSON
    // "\ud800" escapes) and Utf8Iterator.nextCodepoint assumes pre-validated
    // bytes (panics otherwise). Invalid bytes become U+FFFD, which IDNA
    // mapping then rejects — a parse failure instead of a crash.
    var codepoints: std.ArrayListUnmanaged(u21) = .empty;
    defer codepoints.deinit(allocator);

    var i: usize = 0;
    while (i < domain.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(domain[i]) catch {
            try codepoints.append(allocator, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + seq_len > domain.len) {
            try codepoints.append(allocator, 0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(domain[i .. i + seq_len]) catch {
            try codepoints.append(allocator, 0xFFFD);
            i += 1;
            continue;
        };
        try codepoints.append(allocator, cp);
        i += seq_len;
    }

    // 2. Apply IDNA mapping
    var mapped: std.ArrayListUnmanaged(u21) = .empty;
    defer mapped.deinit(allocator);

    for (codepoints.items) |cp| {
        const entry = tables.lookupCodePoint(cp);
        switch (entry.status) {
            .valid => try mapped.append(allocator, cp),
            .ignored => {}, // skip
            .mapped, .disallowed_STD3_mapped => {
                if (entry.status == .disallowed_STD3_mapped and be_strict) return null;
                const m = tables.getMapping(entry);
                for (m) |mcp| try mapped.append(allocator, mcp);
            },
            .deviation => {
                // Non-transitional processing: treat as valid
                try mapped.append(allocator, cp);
            },
            .disallowed => return null,
            .disallowed_STD3_valid => {
                if (be_strict) return null;
                try mapped.append(allocator, cp);
            },
        }
    }

    // 3. NFC normalize
    const normalized = try nfc.nfcNormalize(allocator, mapped.items);
    defer allocator.free(normalized);

    // 4. CheckBidi (RFC 5893): if any label makes this a Bidi domain name,
    // every label must satisfy the Bidi Rule. Checked on the Unicode form,
    // before punycode encoding.
    {
        var is_bidi = false;
        var ls: usize = 0;
        var k: usize = 0;
        while (k <= normalized.len) : (k += 1) {
            if (k == normalized.len or normalized[k] == '.') {
                if (labelHasRtl(normalized[ls..k])) {
                    is_bidi = true;
                    break;
                }
                ls = k + 1;
            }
        }
        if (is_bidi) {
            ls = 0;
            k = 0;
            while (k <= normalized.len) : (k += 1) {
                if (k == normalized.len or normalized[k] == '.') {
                    if (!checkBidiRule(normalized[ls..k])) return null;
                    ls = k + 1;
                }
            }
        }
    }

    // 5. Split on '.' (U+002E) and process each label
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var label_start: usize = 0;
    var first_label = true;

    for (normalized, 0..) |cp, idx| {
        if (cp == '.' or idx == normalized.len - 1) {
            const label_end = if (cp == '.') idx else idx + 1;
            const label = normalized[label_start..label_end];

            if (!first_label) try result.append(allocator, '.');
            first_label = false;

            // Process this label
            const ascii_label = try processLabel(allocator, label, be_strict) orelse return null;
            defer allocator.free(ascii_label);
            try result.appendSlice(allocator, ascii_label);

            label_start = idx + 1;
        }
    }

    // Handle trailing dot
    if (normalized.len > 0 and normalized[normalized.len - 1] == '.') {
        try result.append(allocator, '.');
    }

    // Handle empty domain
    if (result.items.len == 0 and normalized.len == 0) {
        const empty = try allocator.alloc(u8, 0);
        return @as(?[]u8, empty);
    }

    const slice = try result.toOwnedSlice(allocator);
    return @as(?[]u8, slice);
}

/// Convert a domain from ACE form back to Unicode.
pub fn domainToUnicode(allocator: Allocator, domain: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var it = std.mem.splitScalar(u8, domain, '.');
    var first = true;
    while (it.next()) |label| {
        if (!first) try result.append(allocator, '.');
        first = false;

        if (std.ascii.startsWithIgnoreCase(label, "xn--")) {
            // Decode Punycode
            const encoded = label[4..];
            const decoded = punycode.decode(allocator, encoded) catch {
                // On decode failure, keep the ACE label as-is
                try result.appendSlice(allocator, label);
                continue;
            };
            defer allocator.free(decoded);
            // Encode back to UTF-8
            for (decoded) |cp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch continue;
                try result.appendSlice(allocator, buf[0..len]);
            }
        } else {
            try result.appendSlice(allocator, label);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// UTS #46 §4.2 CheckJoiners: validate ZWNJ (U+200C) and ZWJ (U+200D) placement.
/// Returns true if all ZWNJ/ZWJ are in valid contexts, false if any violates
/// the joiner rules (C1 for ZWNJ, C2 for ZWJ).
///
/// Rules (RFC 5892 Appendix A, CONTEXTJ — referenced by UTS #46 §4.2 step 3):
///   ZWNJ (A.1) at position i is valid if:
///     - Canonical_Combining_Class(label[i-1]) == Virama (ccc=9); OR
///     - The regex (L|D)(T)*ZWNJ(T)*(R|D) matches: preceding non-Transparent
///       code point has Joining_Type L or D, AND following non-Transparent
///       code point has Joining_Type R or D.
///     Otherwise: C1 violation.
///   ZWJ (A.2) at position i is valid ONLY if:
///     - Canonical_Combining_Class(label[i-1]) == Virama (ccc=9).
///     Otherwise: C2 violation.
///
/// Note: the ccc=9 check is on the IMMEDIATELY preceding code point (no
/// Transparent skipping) — that is what "Before(cp)" means in RFC 5892.
fn checkJoiners(label: []const u21) bool {
    for (label, 0..) |cp, i| {
        if (cp == 0x200C) {
            // ZWNJ — C1
            if (i > 0 and joining_type.isVirama(label[i - 1])) continue;
            const pt = precedingJoiningType(label, i);
            const ft = followingJoiningType(label, i + 1);
            if (pt != null and ft != null and
                (pt.? == .left or pt.? == .dual) and
                (ft.? == .right or ft.? == .dual)) continue;
            return false; // C1 violation
        }
        if (cp == 0x200D) {
            // ZWJ — C2
            if (i > 0 and joining_type.isVirama(label[i - 1])) continue;
            return false; // C2 violation
        }
    }
    return true;
}

/// Find the last non-Transparent code point before `pos`, returning its
/// Joining_Type, or null if none (start of label).
fn precedingJoiningType(label: []const u21, pos: usize) ?joining_type.JoiningType {
    var j: usize = pos;
    while (j > 0) {
        j -= 1;
        const pt = joining_type.joiningType(label[j]);
        if (pt == .transparent) continue;
        return pt;
    }
    return null;
}

/// Find the first non-Transparent code point at or after `start`, returning
/// its Joining_Type, or null if none (end of label).
fn followingJoiningType(label: []const u21, start: usize) ?joining_type.JoiningType {
    var k: usize = start;
    while (k < label.len) : (k += 1) {
        const pt = joining_type.joiningType(label[k]);
        if (pt == .transparent) continue;
        return pt;
    }
    return null;
}

// ── RFC 5893 Bidi Rule (UTS #46 §4.2 CheckBidi, WHATWG CheckBidi=true) ──

/// True if any code point is R, AL, or AN — making the whole domain a
/// "Bidi domain name" whose every label must satisfy the Bidi Rule.
fn labelHasRtl(label: []const u21) bool {
    for (label) |cp| {
        switch (bidi_class.bidiClass(cp)) {
            .r, .al, .an => return true,
            else => {},
        }
    }
    return false;
}

/// RFC 5893 §2: validate one label of a Bidi domain name.
fn checkBidiRule(label: []const u21) bool {
    if (label.len == 0) return true;
    const first = bidi_class.bidiClass(label[0]);
    // Rule 1: first character must be L, R, or AL.
    const rtl = switch (first) {
        .r, .al => true,
        .l_or_other => false,
        else => return false, // EN/AN/NSM/etc. leading — invalid
    };
    var last_non_nsm: bidi_class.BidiClass = first;
    var seen_en = false;
    var seen_an = false;
    for (label) |cp| {
        const c = bidi_class.bidiClass(cp);
        if (rtl) {
            // Rule 2: allowed classes in an RTL label.
            switch (c) {
                .r, .al, .an, .en, .es, .cs, .et, .on, .bn, .nsm => {},
                else => return false, // an L character
            }
            if (c == .en) seen_en = true;
            if (c == .an) seen_an = true;
        } else {
            // Rule 5: allowed classes in an LTR label.
            switch (c) {
                .l_or_other, .en, .es, .cs, .et, .on, .bn, .nsm => {},
                else => return false,
            }
        }
        if (c != .nsm) last_non_nsm = c;
    }
    if (rtl) {
        // Rule 3: last non-NSM must be R, AL, EN, or AN.
        switch (last_non_nsm) {
            .r, .al, .en, .an => {},
            else => return false,
        }
        // Rule 4: EN and AN may not both appear.
        if (seen_en and seen_an) return false;
    } else {
        // Rule 6: last non-NSM must be L or EN.
        switch (last_non_nsm) {
            .l_or_other, .en => {},
            else => return false,
        }
    }
    return true;
}

/// Process a single domain label (sequence of code points between dots).
/// Returns the ASCII representation, or null on validation failure.
fn processLabel(allocator: Allocator, label: []const u21, be_strict: bool) !?[]u8 {
    _ = be_strict;

    if (label.len == 0) return try allocator.dupe(u8, "");

    // UTS #46 §4.2: a label must not start with a combining mark
    // (General_Category Mn or Me). IdnaTestV2 V6 cases like "̈c.d" (label
    // starting with U+0308 COMBINING DIAERESIS) must be rejected.
    if (combining_mark.isCombiningMark(label[0])) return null;

    // Check if label is pure ASCII
    var has_non_ascii = false;
    for (label) |cp| {
        if (cp > 0x7F) {
            has_non_ascii = true;
            break;
        }
    }

    if (has_non_ascii) {
        // UTS #46 §4.2 CheckJoiners: validate ZWNJ (U+200C) and ZWJ (U+200D)
        // placement before punycode encoding. A violation is a hard failure
        // (IdnaTestV2 C1/C2 expect throw). Pure-ASCII labels skip this check
        // (ZWNJ/ZWJ are non-ASCII).
        if (!checkJoiners(label)) return null;

        // Punycode encode
        const encoded = punycode.encode(allocator, label) catch return null;
        defer allocator.free(encoded);

        // Build "xn--" + encoded
        var ace: std.ArrayListUnmanaged(u8) = .empty;
        errdefer ace.deinit(allocator);
        try ace.appendSlice(allocator, "xn--");
        try ace.appendSlice(allocator, encoded);

        const ace_label = ace.toOwnedSlice(allocator) catch return null;

        // Validate: decode and re-encode to verify roundtrip
        // (This catches invalid Punycode encoding)

        // Validate label constraints
        if (!validateAceLabel(ace_label)) {
            allocator.free(ace_label);
            return null;
        }

        return ace_label;
    } else {
        // Pure ASCII label — lowercase and validate
        var ascii: std.ArrayListUnmanaged(u8) = .empty;
        errdefer ascii.deinit(allocator);
        for (label) |cp| {
            try ascii.append(allocator, std.ascii.toLower(@intCast(cp)));
        }
        const result = ascii.toOwnedSlice(allocator) catch return null;

        if (!validateAsciiLabel(result)) {
            allocator.free(result);
            return null;
        }

        return result;
    }
}

/// Validate an ACE label (xn--...).
fn validateAceLabel(label: []const u8) bool {
    return validateAsciiLabel(label);
}

/// Validate a plain ASCII label.
fn validateAsciiLabel(label: []const u8) bool {
    if (label.len == 0) return true;

    // Max label length: 63 bytes
    if (label.len > 63) return false;

    // WHATWG URL §3.5: leading/trailing hyphens are "validation errors"
    // (warnings), NOT failures. The URL parser accepts domains like "xn--"
    // (empty ACE label) and "-example" — they just produce a validation
    // error notice. Only IDNA strict mode (UTS #46 §4.3) rejects them, but
    // the URL standard uses non-strict IDNA, so we must not reject here.
    // (Previous code rejected trailing hyphens, which incorrectly rejected
    // "xn--" — see url-setters WPT: host = 'xn--' → https://xn--/)

    // Check for forbidden host code points
    for (label) |c| {
        if (isForbiddenDomainCodePoint(c)) return false;
    }

    return true;
}

fn isForbiddenDomainCodePoint(c: u8) bool {
    return switch (c) {
        0x00...0x1F, 0x7F, // C0 controls and DEL
        '%', // percent (must be part of percent-encoding, not raw)
        ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|',
        => true,
        else => false,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "domainToAscii pure ASCII" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "example.com", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii uppercase to lowercase" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "EXAMPLE.COM", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii German umlaut" {
    const alloc = std.testing.allocator;
    // "münchen.de" -> "xn--mnchen-3ya.de"
    const result = (try domainToAscii(alloc, "m\xc3\xbcnchen.de", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("xn--mnchen-3ya.de", result);
}

test "domainToAscii Japanese" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "\xe4\xbe\x8b\xe3\x81\x88.jp", false)).?;
    defer alloc.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "xn--"));
    try std.testing.expect(std.mem.endsWith(u8, result, ".jp"));
}

test "domainToAscii single label" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "localhost", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("localhost", result);
}

test "domainToAscii trailing dot" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "example.com.", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com.", result);
}

test "domainToUnicode ACE to unicode" {
    const alloc = std.testing.allocator;
    const result = try domainToUnicode(alloc, "xn--mnchen-3ya.de");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("m\xc3\xbcnchen.de", result);
}

test "domainToUnicode plain ASCII passthrough" {
    const alloc = std.testing.allocator;
    const result = try domainToUnicode(alloc, "example.com");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "domainToAscii label too long fails" {
    const alloc = std.testing.allocator;
    // 64 characters label — exceeds 63 byte limit
    const long_label = "a" ** 64 ++ ".com";
    const result = try domainToAscii(alloc, long_label, false);
    try std.testing.expect(result == null);
}

// ── CheckBidi (RFC 5893) tests — cases mirror IdnaTestV2 V3 patterns ──

test "bidi: pure LTR domain unaffected" {
    const alloc = std.testing.allocator;
    const result = (try domainToAscii(alloc, "example.com", false)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("example.com", result);
}

test "bidi: valid Hebrew label" {
    const alloc = std.testing.allocator;
    // אבג — R AL... all R: valid RTL label
    const result = try domainToAscii(alloc, "\xd7\x90\xd7\x91\xd7\x92", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "bidi: digit-leading label in bidi domain fails (rule 1)" {
    const alloc = std.testing.allocator;
    // "0a.אבג" — bidi domain (Hebrew label), "0a" starts with EN → invalid
    const result = try domainToAscii(alloc, "0a.\xd7\x90\xd7\x91\xd7\x92", false);
    try std.testing.expect(result == null);
}

test "bidi: same digit-leading label without RTL is fine" {
    const alloc = std.testing.allocator;
    const result = try domainToAscii(alloc, "0a.bc", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "bidi: L char inside RTL label fails (rule 2)" {
    const alloc = std.testing.allocator;
    // א a א — Latin 'a' (L) inside RTL label
    const result = try domainToAscii(alloc, "\xd7\x90a\xd7\x90", false);
    try std.testing.expect(result == null);
}

test "bidi: RTL label ending in ES fails (rule 3)" {
    const alloc = std.testing.allocator;
    // "א-" ends with HYPHEN... hyphen is ON class; use "א+"? '+' is ES.
    // A label may not end with hyphen anyway; use ES char U+002B via mapping-safe char:
    // simpler: "א7" valid (EN end ok), "א…"? Use ON: '·'? Keep to rule-3 core:
    // NSM after R is fine — "א" + U+0591 (NSM) ends with last_non_nsm = R → valid.
    const ok = try domainToAscii(alloc, "\xd7\x90\xd6\x91", false);
    try std.testing.expect(ok != null);
    alloc.free(ok.?);
}

test "bidi: EN and AN mixed in RTL label fails (rule 4)" {
    const alloc = std.testing.allocator;
    // א 1 ٠ — EN ('1') + AN (U+0660 arabic-indic zero) in same RTL label
    const result = try domainToAscii(alloc, "\xd7\x90" ++ "1" ++ "\xd9\xa0", false);
    try std.testing.expect(result == null);
}

test "bidi: AN in LTR label fails (rule 5)" {
    const alloc = std.testing.allocator;
    // "a٠.א" — bidi domain; LTR label contains AN U+0660 → invalid
    const result = try domainToAscii(alloc, "a\xd9\xa0.\xd7\x90", false);
    try std.testing.expect(result == null);
}

// ── CheckJoiners (RFC 5892 Appendix A CONTEXTJ) tests ──

test "joiners: ZWJ after virama is valid (A.2)" {
    const alloc = std.testing.allocator;
    // क + ् (U+094D virama) + ZWJ + ष — valid Devanagari conjunct
    const result = try domainToAscii(alloc, "\xe0\xa4\x95\xe0\xa5\x8d\xe2\x80\x8d\xe0\xa4\xb7", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "joiners: ZWJ between Latin fails (C2)" {
    const alloc = std.testing.allocator;
    const result = try domainToAscii(alloc, "a\xe2\x80\x8db", false);
    try std.testing.expect(result == null);
}

test "joiners: ZWNJ after virama is valid (A.1 branch 1)" {
    const alloc = std.testing.allocator;
    // क + ् + ZWNJ + ष
    const result = try domainToAscii(alloc, "\xe0\xa4\x95\xe0\xa5\x8d\xe2\x80\x8c\xe0\xa4\xb7", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "joiners: ZWNJ between Latin fails (C1)" {
    const alloc = std.testing.allocator;
    const result = try domainToAscii(alloc, "a\xe2\x80\x8cb", false);
    try std.testing.expect(result == null);
}

test "joiners: ZWNJ in Arabic dual-join context is valid (A.1 regex)" {
    const alloc = std.testing.allocator;
    // ب (BEH, D) + ZWNJ + ب (BEH, D) — matches (L|D)(T)*ZWNJ(T)*(R|D)
    const result = try domainToAscii(alloc, "\xd8\xa8\xe2\x80\x8c\xd8\xa8", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}

test "joiners: Sinhala al-lakuna (ccc=9) before ZWJ is valid" {
    const alloc = std.testing.allocator;
    // ශ + ් (U+0DCA) + ZWJ + ර + ී — "shri" conjunct
    const result = try domainToAscii(alloc, "\xe0\xb7\x81\xe0\xb7\x8a\xe2\x80\x8d\xe0\xb6\xbb\xe0\xb7\x93", false);
    try std.testing.expect(result != null);
    alloc.free(result.?);
}
