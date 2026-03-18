const std = @import("std");

/// A Bloom filter optimized for CSS ancestor selector matching.
///
/// When matching descendant/child selectors (e.g. `.sidebar .nav a`), we must
/// walk up the DOM tree checking ancestors. This Bloom filter, pre-populated
/// with ancestor class names, IDs, and tag names, allows us to quickly reject
/// selectors that can't possibly match — if a required ancestor class/id/tag
/// is NOT in the filter, the descendant selector can't match.
///
/// 2048-bit (256-byte) filter with 3 hash functions derived from a single u32.
/// Small enough to copy on the stack. False positives are acceptable (we fall
/// back to the normal expensive match); false negatives are not.
pub const SelectorBloomFilter = struct {
    bits: [256]u8,

    pub fn init() SelectorBloomFilter {
        return .{ .bits = std.mem.zeroes([256]u8) };
    }

    /// Insert a hash into the filter.
    pub fn add(self: *SelectorBloomFilter, hash: u32) void {
        // 3 hash functions derived from different bit ranges of the input hash
        const h1 = hash & 0x7FF; // bits 0-10  (11 bits → 0..2047)
        const h2 = (hash >> 11) & 0x7FF; // bits 11-21 (11 bits → 0..2047)
        const h3 = (hash >> 22) & 0x3FF; // bits 22-31 (10 bits → 0..1023)
        self.setBit(h1);
        self.setBit(h2);
        self.setBit(h3 % 2048);
    }

    /// Test whether a hash might be in the filter.
    /// Returns false only if the hash is definitely not present.
    pub fn mightContain(self: *const SelectorBloomFilter, hash: u32) bool {
        const h1 = hash & 0x7FF;
        const h2 = (hash >> 11) & 0x7FF;
        const h3 = (hash >> 22) & 0x3FF;
        return self.getBit(h1) and self.getBit(h2) and self.getBit(h3 % 2048);
    }

    fn setBit(self: *SelectorBloomFilter, bit: u32) void {
        self.bits[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    }

    fn getBit(self: *const SelectorBloomFilter, bit: u32) bool {
        return (self.bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
    }

    /// Hash a string (class name, ID, or tag name) for use with this filter.
    pub fn hashString(s: []const u8) u32 {
        var h: u32 = 0;
        for (s) |c| {
            h = h *% 31 +% @as(u32, c);
        }
        return h;
    }

    /// Hash a string case-insensitively (for tag names).
    pub fn hashStringLower(s: []const u8) u32 {
        var h: u32 = 0;
        for (s) |c| {
            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            h = h *% 31 +% @as(u32, lower);
        }
        return h;
    }
};
