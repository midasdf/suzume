/// Shared layout utilities — extracted from layout/block.zig.
/// Common text/Unicode functions used across layout modules.
const std = @import("std");

/// Check if a Unicode codepoint is in a CJK range where line breaks are allowed
/// between any two adjacent CJK characters (no spaces needed).
pub fn isCjkCodepoint(cp: u21) bool {
    return (cp >= 0x3000 and cp <= 0x9FFF) or // CJK Symbols, Hiragana, Katakana, CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Halfwidth and Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2FFFF); // CJK Unified Ideographs Extension B+
}

/// Decode a single UTF-8 codepoint starting at text[pos].
/// Returns the codepoint and the byte length of that codepoint (1-4).
pub fn decodeUtf8(text: []const u8, pos: usize) struct { cp: u21, len: u3 } {
    if (pos >= text.len) return .{ .cp = 0, .len = 1 };
    const b0 = text[pos];
    if (b0 < 0x80) {
        return .{ .cp = b0, .len = 1 };
    } else if (b0 < 0xE0) {
        if (pos + 1 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x1F) << 6) | @as(u21, text[pos + 1] & 0x3F);
        return .{ .cp = cp, .len = 2 };
    } else if (b0 < 0xF0) {
        if (pos + 2 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, text[pos + 1] & 0x3F) << 6) | @as(u21, text[pos + 2] & 0x3F);
        return .{ .cp = cp, .len = 3 };
    } else {
        if (pos + 3 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
        const cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, text[pos + 1] & 0x3F) << 12) | (@as(u21, text[pos + 2] & 0x3F) << 6) | @as(u21, text[pos + 3] & 0x3F);
        return .{ .cp = cp, .len = 4 };
    }
}

/// Check if a Unicode codepoint is whitespace (for layout purposes).
pub fn isWhitespace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or
        cp == 0x00A0 or // non-breaking space
        cp == 0x2000 or cp == 0x2001 or cp == 0x2002 or cp == 0x2003 or // em/en spaces
        cp == 0x2004 or cp == 0x2005 or cp == 0x2006 or cp == 0x2007 or
        cp == 0x2008 or cp == 0x2009 or cp == 0x200A or cp == 0x200B or
        cp == 0x3000; // ideographic space
}
