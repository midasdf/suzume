//! dom_names.zig — Shared XML Name / XML QName / DOM §1.5 "validate and extract"
//!
//! Single source of truth for name validation used by:
//!   * kotori native path (src/js/kotori_dom.zig)
//!   * QuickJS path (src/js/dom_document.zig, src/js/dom_element.zig,
//!     src/js/dom_api.zig)
//!
//! VM-agnostic — pure std + slices. Callers map `error.InvalidCharacter` to
//! `InvalidCharacterError` and `error.NamespaceMismatch` to `NamespaceError`
//! at their own binding boundary (`queueValidationErr` in kotori_dom.zig,
//! `validateAndExtractQjs` in dom_api.zig).
//!
//! Spec references:
//!   - DOM §1.5 "validate and extract"
//!   - DOM §4.5.1 createElement (Name production, ':' allowed anywhere)
//!   - DOM §4.5.2 createElementNS (QName production)
//!   - DOM §4.9.1 createAttribute / createAttributeNS
//!   - DOM §4.9.2/3 setAttribute / setAttributeNS
//!   - Infra §5 / XML Names §2-3 (lenient browser variant)

const std = @import("std");

pub const XML_NS: []const u8 = "http://www.w3.org/XML/1998/namespace";
pub const XMLNS_NS: []const u8 = "http://www.w3.org/2000/xmlns/";

pub const NameValidationError = error{ InvalidCharacter, NamespaceMismatch };

/// Result of DOM §1.5 "validate and extract".
pub const ValidatedName = struct {
    /// Post-coercion: "" → null per step 1.
    namespace: ?[]const u8,
    /// null when no ':' in qn.
    prefix: ?[]const u8,
    /// Localname portion after the first ':' (or the whole qn if no ':').
    local_name: []const u8,
};

/// Bytes that browsers reject *anywhere* in a Name: ASCII whitespace and
/// control bytes. Matches the long-standing kotori_dom helper. Anything
/// non-ASCII is tolerated, matching `createElementNS_tests` which accepts
/// e.g. "\uFFFFfoo" as VALID.
fn isHardInvalidNameChar(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x00...0x08, 0x0E...0x1F, 0x7F => true,
        else => false,
    };
}

/// Bytes that cannot START a Name / NCName per the lenient browser rules
/// required by WPT `createElementNS_tests`. Matches the pre-existing
/// kotori_dom helper. Note ':' IS rejected as a start char for the
/// NCName-grammar helpers (`isValidQName`), but `isValidName` accepts ':'
/// at any position since the Name production allows ':'.
fn isInvalidNameStartChar(ch: u8) bool {
    if (isHardInvalidNameChar(ch)) return true;
    return switch (ch) {
        '0'...'9', '-', '.', ':' => true,
        '<', '>', '}', '^', '*', '+', ',', '/', '=', '(', ')', '[', ']', '{', '|', ';', '\\', '\'', '"', '`', '~', '!', '?', '#', '$', '%', '&', '@' => true,
        else => false,
    };
}

/// Decode one UTF-8 codepoint at `s[0..]`. Returns null if `s` is empty or
/// the leading bytes are not a well-formed UTF-8 sequence. Used by
/// `isValidName` to apply codepoint-level XML \u00A72.3 NameStartChar / NameChar
/// gap rejections (browsers tolerate most non-ASCII codepoints in names,
/// but specifically reject a handful of codepoints in the XML production
/// gaps \u2014 see `isCodepointBlockedAsNameStart` / `isCodepointBlockedAsNameChar`).
fn decodeUtf8(s: []const u8) ?struct { cp: u32, len: usize } {
    if (s.len == 0) return null;
    const b0 = s[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xC2) return null;
    if (b0 < 0xE0) {
        if (s.len < 2) return null;
        const b1 = s[1];
        if ((b1 & 0xC0) != 0x80) return null;
        const cp: u32 = (@as(u32, b0 & 0x1F) << 6) | @as(u32, b1 & 0x3F);
        return .{ .cp = cp, .len = 2 };
    }
    if (b0 < 0xF0) {
        if (s.len < 3) return null;
        const b1 = s[1];
        const b2 = s[2];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80) return null;
        const cp: u32 =
            (@as(u32, b0 & 0x0F) << 12) |
            (@as(u32, b1 & 0x3F) << 6) |
            @as(u32, b2 & 0x3F);
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 < 0xF5) {
        if (s.len < 4) return null;
        const b1 = s[1];
        const b2 = s[2];
        const b3 = s[3];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80 or (b3 & 0xC0) != 0x80) return null;
        const cp: u32 =
            (@as(u32, b0 & 0x07) << 18) |
            (@as(u32, b1 & 0x3F) << 12) |
            (@as(u32, b2 & 0x3F) << 6) |
            @as(u32, b3 & 0x3F);
        return .{ .cp = cp, .len = 4 };
    }
    return null;
}

/// Codepoints in the XML 1.0 \u00A72.3 NameStartChar gaps that browsers reject
/// at the START of a Name, even though they are tolerated elsewhere. WPT
/// `Document-createProcessingInstruction.html` enforces these per
/// XML 1.0 \u00A72.3 NameStartChar production:
///   - U+00B7 (MIDDLE DOT): in NameChar but not in NameStartChar
///     ([#xC0-#xD6]|[#xD8-#xF6]|[#xF8-#x2FF]...).
///   - U+00D7 (MULTIPLICATION SIGN): in neither (sits in the [#xD7]
///     gap between [#xC0-#xD6] and [#xD8-#xF6]).
fn isCodepointBlockedAsNameStart(cp: u32) bool {
    return cp == 0x00B7 or cp == 0x00D7;
}

/// Codepoints that XML 1.0 \u00A72.3 NameChar production also rejects (i.e.
/// rejected anywhere in a Name, including interior positions). U+00D7 is
/// outside NameStartChar AND outside the explicit NameChar additions
/// (#xB7 | [#x0300-#x036F] | [#x203F-#x2040]). U+00B7 is in NameChar so
/// it is *not* listed here \u2014 only blocked at start by
/// `isCodepointBlockedAsNameStart`.
fn isCodepointBlockedAsNameChar(cp: u32) bool {
    return cp == 0x00D7;
}

/// XML Name production (lenient browser variant). Used by DOM §4.5.1
/// createElement — i.e. the strict creator APIs. ':' is allowed ANYWHERE
/// (including start and end and repeated colons). Matches WPT
/// `Document-createElement.html:48-53` where `":"`, `":foo"`, `"f:oo"`,
/// `"foo:"`, `"f:o:o"`, `"f::oo"` are all listed as VALID.
///
/// Rejects:
///   * Empty input.
///   * NameStartChar-invalid first byte (other than ':').
///   * Hard-invalid bytes anywhere (whitespace / controls).
///   * Trailing '>' (matches `createElement("foo>")` assertion).
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    // First char must pass NameStartChar rules *except* that ':' is allowed
    // anywhere per the Name production (unlike NCName).
    if (name[0] != ':' and isInvalidNameStartChar(name[0])) return false;
    // First codepoint: enforce XML 1.0 §2.3 NameStartChar gap rejections
    // for the multi-byte codepoints browsers specifically reject at start
    // (e.g. U+00B7, U+00D7). ASCII fast-path above already covered single
    // bytes, so only inspect when leading byte is multi-byte UTF-8.
    if (name[0] >= 0x80) {
        if (decodeUtf8(name)) |first| {
            if (isCodepointBlockedAsNameStart(first.cp)) return false;
        }
    }
    // Interior chars: hard-invalid bytes (whitespace / controls) reject AND
    // XML 1.0 §2.3 NameChar gap codepoints (e.g. U+00D7) reject anywhere.
    var i: usize = 1;
    while (i < name.len) {
        const ch = name[i];
        if (ch < 0x80) {
            if (isHardInvalidNameChar(ch)) return false;
            i += 1;
            continue;
        }
        // Multi-byte codepoint: decode and check NameChar gap blocks.
        if (decodeUtf8(name[i..])) |dec| {
            if (isCodepointBlockedAsNameChar(dec.cp)) return false;
            i += dec.len;
        } else {
            // Malformed UTF-8: skip the bad byte, stay lenient (matches
            // historical "non-ASCII tolerated" behavior for createElementNS).
            i += 1;
        }
    }
    // Trailing '>' → invalid (matches WPT Document-createElement.html:48-53
    // where `"foo>"` is listed as invalid).
    if (name[name.len - 1] == '>') return false;
    return true;
}

/// Lenient "Name" check for DOM §4.9.1 createAttribute and §4.9.2
/// setAttribute. WPT `dom/nodes/productions.js` defines `valid_names` as
/// `["x","X",":","a:0","invalid^Name","\\","'","\"","0","0:a",":a","x:y:x","~"]`
/// — i.e. browsers accept nearly any non-empty string that does not contain
/// hard-invalid bytes (whitespace / controls). Only `invalid_names = [""]`
/// is rejected.
///
/// This helper matches that permissive grammar so pre-existing setAttribute
/// call sites that previously used no validation do not regress when wired
/// through the shared module.
pub fn isValidAttrName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (isHardInvalidNameChar(ch)) return false;
    }
    return true;
}

/// XML QName production (lenient browser variant). Used by DOM §1.5
/// "validate and extract" via `validateAndExtract` below. Rules:
///   * Empty → invalid.
///   * Hard-invalid bytes (whitespace/controls) anywhere → invalid.
///   * If prefixed (contains ':'): both prefix and localName must be
///     non-empty. Prefix start is lenient (WPT accepts "0:a"); the first
///     char of localName must be a valid NameStartChar OR a second ':'
///     (WPT accepts "prefix::local").
///   * If unprefixed: first char must be a NameStartChar. Trailing '>'
///     rejects unprefixed names (matches `"foo>"` case in the fixture).
pub fn isValidQName(name: []const u8) bool {
    if (name.len == 0) return false;
    // Hard-invalid bytes anywhere → reject.
    for (name) |ch| {
        if (isHardInvalidNameChar(ch)) return false;
    }
    if (std.mem.indexOfScalar(u8, name, ':')) |cp| {
        const prefix = name[0..cp];
        const local = name[cp + 1 ..];
        if (prefix.len == 0 or local.len == 0) return false; // ":foo" / "foo:" bad
        // Prefix start lenient (WPT: "0:a" accepted). Only the first char of
        // localName must be a valid NameStartChar, or a second ':'
        // ("prefix::local" is accepted by WPT).
        if (local[0] != ':' and isInvalidNameStartChar(local[0])) return false;
        return true;
    }
    // Unprefixed: first char must be a NameStartChar.
    if (isInvalidNameStartChar(name[0])) return false;
    // Trailing '>' → invalid (matches `"foo>"` in createElementNS_tests).
    if (name[name.len - 1] == '>') return false;
    return true;
}

/// DOM §1.5 "validate and extract".
///
/// Input:
///   * `qn` — qualifiedName. Must not be zero-length; callers (e.g.
///     impl.createDocument) handle the empty-qn branch themselves.
///   * `ns_in` — namespace (nullable). `""` is coerced to `null` per step 1.
///
/// Returns:
///   * On success: `ValidatedName` tuple (namespace, prefix, local_name).
///   * On failure: `error.InvalidCharacter` (maps to InvalidCharacterError)
///     or `error.NamespaceMismatch` (maps to NamespaceError).
///
/// Spec steps enforced (numbered per DOM §1.5):
///   1. If namespace is "", set to null.
///   2. Validate qn against QName production → InvalidCharacterError.
///   3-5. Split on first ':'.
///   6. prefix non-null with null namespace → NamespaceError.
///   7. prefix == "xml" with non-XML namespace → NamespaceError.
///   8. qn/prefix == "xmlns" with non-XMLNS namespace → NamespaceError.
///   9. namespace == XMLNS with neither qn nor prefix == "xmlns" → NamespaceError.
///  10. Return (namespace, prefix, localName).
pub fn validateAndExtract(
    qn: []const u8,
    ns_in: ?[]const u8,
) NameValidationError!ValidatedName {
    // Step 1: "" namespace → null.
    const namespace: ?[]const u8 = if (ns_in) |n| (if (n.len == 0) null else n) else null;

    // Step 2: validate qn against QName production.
    if (qn.len == 0) return error.InvalidCharacter;
    if (!isValidQName(qn)) return error.InvalidCharacter;

    // Steps 3-5: split on first ':'.
    var prefix: ?[]const u8 = null;
    var local: []const u8 = qn;
    if (std.mem.indexOfScalar(u8, qn, ':')) |cp| {
        prefix = qn[0..cp];
        local = qn[cp + 1 ..];
    }

    // Step 6: prefix with null namespace → NamespaceError.
    if (prefix != null and namespace == null) return error.NamespaceMismatch;

    // Step 7: prefix == "xml" requires XML namespace.
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml")) {
            if (namespace == null or !std.mem.eql(u8, namespace.?, XML_NS)) {
                return error.NamespaceMismatch;
            }
        }
    }

    // Step 8: qn or prefix == "xmlns" requires XMLNS namespace.
    const qn_is_xmlns = std.mem.eql(u8, qn, "xmlns");
    const prefix_is_xmlns = if (prefix) |p| std.mem.eql(u8, p, "xmlns") else false;
    if (qn_is_xmlns or prefix_is_xmlns) {
        if (namespace == null or !std.mem.eql(u8, namespace.?, XMLNS_NS)) {
            return error.NamespaceMismatch;
        }
    }

    // Step 9: XMLNS namespace requires qn or prefix to be "xmlns".
    if (namespace) |n| {
        if (std.mem.eql(u8, n, XMLNS_NS) and !qn_is_xmlns and !prefix_is_xmlns) {
            return error.NamespaceMismatch;
        }
    }

    return .{ .namespace = namespace, .prefix = prefix, .local_name = local };
}

// ══════════════════════════════════════════════════════════════════════
// Unit tests (run via `zig build test-dom-names`)
// ══════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "isValidName accepts colonated names (Document-createElement.html:48-53)" {
    try testing.expect(isValidName(":"));
    try testing.expect(isValidName(":foo"));
    try testing.expect(isValidName("f:oo"));
    try testing.expect(isValidName("foo:"));
    try testing.expect(isValidName("f:o:o"));
    try testing.expect(isValidName("f::oo"));
    try testing.expect(isValidName("foo"));
}

test "isValidName rejects bad first chars and hard-invalid chars" {
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("1foo"));
    try testing.expect(!isValidName("-foo"));
    try testing.expect(!isValidName(".foo"));
    try testing.expect(!isValidName("fo o"));
    try testing.expect(!isValidName("foo\tbar"));
    try testing.expect(!isValidName("foo\nbar"));
}

test "isValidName XML §2.3 NameStartChar gap rejection (U+00B7, U+00D7)" {
    // Document-createProcessingInstruction.js fixture:
    //   invalid (start): "·A" — U+00B7 is NameChar but NOT NameStartChar.
    //   invalid (start): "×A" — U+00D7 is in the [#xD7] gap, neither.
    //   invalid (interior): "A×" — U+00D7 also rejected as NameChar.
    //   valid (interior): "A·A" — U+00B7 is in NameChar.
    try testing.expect(!isValidName("\u{00B7}A"));
    try testing.expect(!isValidName("\u{00D7}A"));
    try testing.expect(!isValidName("A\u{00D7}"));
    try testing.expect(isValidName("A\u{00B7}A"));
}

test "isValidName tolerates other non-ASCII codepoints (createElementNS lenient)" {
    // createElementNS_tests fixture marks these as VALID — keep tolerated.
    try testing.expect(isValidName("\u{0BC6}foo")); // Tamil sign
    try testing.expect(isValidName("\u{037E}foo")); // Greek question mark
    try testing.expect(isValidName("\u{FFFF}foo")); // private use sentinel
    try testing.expect(isValidName("f\u{FFFF}oo"));
    try testing.expect(isValidName("foo\u{FFFF}"));
    try testing.expect(isValidName("\u{0300}foo")); // combining mark (createElement valid)
    try testing.expect(isValidName("\u{0300}")); // bare combining mark
}

test "isValidQName rejects colonated edge cases allowed by Name" {
    try testing.expect(!isValidQName(":"));
    try testing.expect(!isValidQName(":foo"));
    try testing.expect(!isValidQName("foo:"));
    try testing.expect(!isValidQName(""));
    try testing.expect(isValidQName("f::oo")); // WPT: "prefix::local" accepted
    try testing.expect(isValidQName("f:oo"));
    try testing.expect(isValidQName("foo"));
}

test "validateAndExtract empty namespace coerced to null (step 1)" {
    // qn "f:oo" + ns "" must produce NamespaceError (step 6 fires after coerce).
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("f:oo", ""),
    );
}

test "validateAndExtract step 6 prefix without namespace" {
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("f:oo", null),
    );
}

test "validateAndExtract step 7 xml prefix" {
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("xml:foo", "http://other"),
    );
    const ok = try validateAndExtract("xml:foo", XML_NS);
    try testing.expectEqualStrings("xml", ok.prefix.?);
    try testing.expectEqualStrings("foo", ok.local_name);
}

test "validateAndExtract step 8 xmlns qname" {
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("xmlns", "http://other"),
    );
    const ok = try validateAndExtract("xmlns", XMLNS_NS);
    try testing.expect(ok.prefix == null);
    try testing.expectEqualStrings("xmlns", ok.local_name);
}

test "validateAndExtract step 8 xmlns prefix" {
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("xmlns:foo", "http://other"),
    );
    const ok = try validateAndExtract("xmlns:foo", XMLNS_NS);
    try testing.expectEqualStrings("xmlns", ok.prefix.?);
    try testing.expectEqualStrings("foo", ok.local_name);
}

test "validateAndExtract step 9 XMLNS namespace with non-xmlns qname" {
    // Row 171 of createElementNS_tests — previously leaked through QuickJS.
    try testing.expectError(
        error.NamespaceMismatch,
        validateAndExtract("xmlfoo", XMLNS_NS),
    );
}

test "validateAndExtract bad qname returns InvalidCharacter" {
    try testing.expectError(error.InvalidCharacter, validateAndExtract("1foo", null));
    try testing.expectError(error.InvalidCharacter, validateAndExtract(":foo", null));
    try testing.expectError(error.InvalidCharacter, validateAndExtract("foo:", null));
    try testing.expectError(error.InvalidCharacter, validateAndExtract("", null));
}

test "validateAndExtract normal prefixed qname success" {
    const ok = try validateAndExtract("prefix:local", "http://custom");
    try testing.expectEqualStrings("prefix", ok.prefix.?);
    try testing.expectEqualStrings("local", ok.local_name);
    try testing.expectEqualStrings("http://custom", ok.namespace.?);
}

test "validateAndExtract unprefixed qname success" {
    const ok = try validateAndExtract("localonly", "http://custom");
    try testing.expect(ok.prefix == null);
    try testing.expectEqualStrings("localonly", ok.local_name);
    try testing.expectEqualStrings("http://custom", ok.namespace.?);
}
