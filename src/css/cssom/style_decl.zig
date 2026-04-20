//! style_decl.zig — Phase 1–3 CSSStyleDeclaration backing store
//!
//! Provides StyleDecl + StyleDeclList: an ordered list of { name, value, important }
//! entries per element. Mutations sync back to the lxb "style" attribute so the
//! existing cascade path continues to work without modification.
//!
//! Phase 3 additions:
//!   - StyleDecl.shorthand_for: tag longhands expanded from a shorthand
//!   - upsertShorthand: expands a shorthand, inserts longhands tagged with shorthand_for
//!   - removeShorthand: removes all longhands for a given shorthand
//!   - getPropertyValueShorthand: canonical shorthand serialization from component longhands
//!   - getPropertyPriorityShorthand: "important" iff all component longhands are important

const std = @import("std");
const shorthand_serialize = @import("shorthand_serialize.zig");

// ── Vendor-prefix alias resolution ────────────────────────────────────
//
// CSS Flexbox L1 Appendix A + Compatibility Standard §7:
// -webkit-<name> aliases map to the unprefixed property at parse time.
// The stored/serialized name is always the unprefixed canonical form.

/// Return the canonical (unprefixed) property name for -webkit- flexbox
/// aliases, or the input name unchanged if not an alias.
/// Input must outlive the return value (returns a slice of either the
/// input or a string literal).
pub fn resolveWebkitAlias(name: []const u8) []const u8 {
    const aliases = [_]struct { webkit: []const u8, canonical: []const u8 }{
        .{ .webkit = "-webkit-align-content",   .canonical = "align-content" },
        .{ .webkit = "-webkit-align-items",      .canonical = "align-items" },
        .{ .webkit = "-webkit-align-self",       .canonical = "align-self" },
        .{ .webkit = "-webkit-flex",             .canonical = "flex" },
        .{ .webkit = "-webkit-flex-basis",       .canonical = "flex-basis" },
        .{ .webkit = "-webkit-flex-direction",   .canonical = "flex-direction" },
        .{ .webkit = "-webkit-flex-flow",        .canonical = "flex-flow" },
        .{ .webkit = "-webkit-flex-grow",        .canonical = "flex-grow" },
        .{ .webkit = "-webkit-flex-shrink",      .canonical = "flex-shrink" },
        .{ .webkit = "-webkit-flex-wrap",        .canonical = "flex-wrap" },
        .{ .webkit = "-webkit-justify-content",  .canonical = "justify-content" },
        .{ .webkit = "-webkit-order",            .canonical = "order" },
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(name, a.webkit)) return a.canonical;
    }
    return name;
}

// ── Types ─────────────────────────────────────────────────────────────

pub const StyleDecl = struct {
    /// Normalized kebab-case property name. Owned by the list's arena.
    name: []const u8,
    /// CSSOM-serialized value — no "!important" suffix. Owned by the list's arena.
    value: []const u8,
    important: bool,
    /// When this longhand was expanded from a shorthand (e.g., "margin"), this is
    /// a literal string identifying that shorthand. Not arena-owned; no need to free.
    shorthand_for: ?[]const u8 = null,
};

pub const StyleDeclList = struct {
    entries: std.ArrayListUnmanaged(StyleDecl),
    /// Arena that owns all name/value strings. Reset on full cssText= replacement.
    arena: std.heap.ArenaAllocator,
    /// True when entries have changed since the last cssText serialization.
    dirty_css_text: bool = true,
    /// Cached serialized cssText. Owned by the arena; invalidated when dirty_css_text=true.
    cached_css_text: ?[]const u8 = null,

    pub fn init(backing_allocator: std.mem.Allocator) StyleDeclList {
        return .{
            .entries = .empty,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .dirty_css_text = true,
            .cached_css_text = null,
        };
    }

    pub fn deinit(self: *StyleDeclList, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.arena.deinit();
    }

    /// Return the index of the first entry with the given name, or null.
    /// -webkit- flex/alignment aliases are resolved to their canonical name first.
    pub fn indexOf(self: *const StyleDeclList, name: []const u8) ?usize {
        const canonical = resolveWebkitAlias(name);
        for (self.entries.items, 0..) |e, i| {
            if (std.ascii.eqlIgnoreCase(e.name, canonical)) return i;
        }
        return null;
    }

    /// Upsert: remove any prior entry with the same name, append new one.
    /// name and value are copied into the arena.
    /// -webkit- flex/alignment aliases are resolved to their canonical unprefixed
    /// name before storage (Compatibility Standard §7).
    pub fn upsert(
        self: *StyleDeclList,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        important: bool,
    ) !void {
        const canonical_name = resolveWebkitAlias(name);
        // Remove existing entry with this name (last-wins / replace semantics)
        if (self.indexOf(canonical_name)) |idx| {
            _ = self.entries.orderedRemove(idx);
        }
        const owned_name = try self.arena.allocator().dupe(u8, canonical_name);
        const owned_val = try self.arena.allocator().dupe(u8, value);
        try self.entries.append(allocator, .{
            .name = owned_name,
            .value = owned_val,
            .important = important,
        });
        self.dirty_css_text = true;
    }

    /// Remove the entry with the given name. Returns the previous value slice
    /// (points into arena memory — valid until next arena reset), or null.
    pub fn remove(self: *StyleDeclList, name: []const u8) ?[]const u8 {
        if (self.indexOf(name)) |idx| {
            const old_val = self.entries.items[idx].value;
            _ = self.entries.orderedRemove(idx);
            self.dirty_css_text = true;
            return old_val;
        }
        return null;
    }

    // ── Phase 3: shorthand expansion ─────────────────────────────────

    /// Expand a shorthand property into its component longhands and upsert each.
    /// `longhand_names` is a slice of kebab-case longhand names (e.g. &.{"margin-top", ...}).
    /// `longhand_values` is a parallel slice of values (already resolved by the caller).
    /// `important` applies to all longhands. `shorthand_name` is stored as `shorthand_for`.
    /// The caller is responsible for passing the correct parallel arrays.
    pub fn upsertShorthand(
        self: *StyleDeclList,
        allocator: std.mem.Allocator,
        shorthand_name: []const u8,
        longhand_names: []const []const u8,
        longhand_values: []const []const u8,
        important: bool,
    ) !void {
        std.debug.assert(longhand_names.len == longhand_values.len);
        const canonical_sh = resolveWebkitAlias(shorthand_name);
        // First remove any existing longhands tagged for this shorthand, plus the
        // shorthand entry itself if it was stored directly (should not happen normally).
        self.removeShorthand(canonical_sh);
        // Insert each longhand with the shorthand tag.
        const arena = self.arena.allocator();
        const owned_sh = try arena.dupe(u8, canonical_sh);
        for (longhand_names, longhand_values) |lh_name, lh_val| {
            // Also remove any pre-existing plain longhand with this name.
            if (self.indexOf(lh_name)) |idx| {
                _ = self.entries.orderedRemove(idx);
            }
            const owned_name = try arena.dupe(u8, lh_name);
            const owned_val = try arena.dupe(u8, lh_val);
            try self.entries.append(allocator, .{
                .name = owned_name,
                .value = owned_val,
                .important = important,
                .shorthand_for = owned_sh,
            });
        }
        self.dirty_css_text = true;
    }

    /// Remove all entries whose `shorthand_for` equals `shorthand_name` (case-insensitive),
    /// plus any direct entry with that name.
    pub fn removeShorthand(self: *StyleDeclList, shorthand_name: []const u8) void {
        var i: usize = 0;
        var removed = false;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            const is_lh = if (e.shorthand_for) |sf| std.ascii.eqlIgnoreCase(sf, shorthand_name) else false;
            const is_direct = std.ascii.eqlIgnoreCase(e.name, shorthand_name);
            if (is_lh or is_direct) {
                _ = self.entries.orderedRemove(i);
                removed = true;
                // do NOT increment i — next item shifted into position i
            } else {
                i += 1;
            }
        }
        if (removed) self.dirty_css_text = true;
    }

    /// Return the canonical serialization of a shorthand from its component longhands.
    /// Returns null if the shorthand is not supported or any component is missing.
    /// -webkit- flex/alignment aliases are resolved to their canonical name first.
    pub fn getPropertyValueShorthand(
        self: *const StyleDeclList,
        shorthand_name: []const u8,
        buf: []u8,
    ) ?[]const u8 {
        const canonical_sh = resolveWebkitAlias(shorthand_name);
        const Impl = struct {
            fn get(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
                const list: *const StyleDeclList = @ptrCast(@alignCast(ptr));
                for (list.entries.items) |e| {
                    if (std.ascii.eqlIgnoreCase(e.name, name)) return e.value;
                }
                return null;
            }
        };
        const ctx = shorthand_serialize.LookupCtx{ .ptr = @ptrCast(self), .get = Impl.get };
        return shorthand_serialize.serializeShorthand(canonical_sh, ctx, buf);
    }

    /// Return "important" if ALL component longhands for the given shorthand are important,
    /// "" if any is non-important, and null if none found.
    /// -webkit- flex/alignment aliases are resolved to their canonical name first.
    pub fn getPropertyPriorityShorthand(
        self: *const StyleDeclList,
        shorthand_name: []const u8,
    ) ?[]const u8 {
        const canonical_sh = resolveWebkitAlias(shorthand_name);
        var found_any = false;
        for (self.entries.items) |e| {
            const is_lh = if (e.shorthand_for) |sf| std.ascii.eqlIgnoreCase(sf, canonical_sh) else false;
            if (!is_lh) continue;
            found_any = true;
            if (!e.important) return "";
        }
        if (!found_any) return null;
        return "important";
    }

    /// Serialize entries to "name: value[ !important];" format suitable for the
    /// style attribute. Caller owns the returned ArrayList and must call deinit().
    pub fn serialize(self: *const StyleDeclList, allocator: std.mem.Allocator) !std.ArrayList(u8) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            try out.appendSlice(allocator, e.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, e.value);
            if (e.important) try out.appendSlice(allocator, " !important");
            try out.appendSlice(allocator, "; ");
        }
        // Trim trailing space
        if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            out.items.len -= 1;
        }
        return out;
    }

    /// Clear all entries and reset the arena.
    pub fn clear(self: *StyleDeclList, allocator: std.mem.Allocator) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
        self.dirty_css_text = true;
        self.cached_css_text = null;
        _ = allocator; // entries backing memory freed by deinit or clear
    }

    /// Return a cached serialized cssText string. Rebuilt when dirty_css_text=true.
    /// The returned slice is valid until the next mutation or clear.
    /// Caller must NOT free it.
    pub fn getCssText(self: *StyleDeclList) ![]const u8 {
        if (!self.dirty_css_text) {
            return self.cached_css_text orelse "";
        }
        // Serialize into a temporary ArrayList then dupe into the arena.
        const arena_alloc = self.arena.allocator();
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(arena_alloc);
        for (self.entries.items) |e| {
            try tmp.appendSlice(arena_alloc, e.name);
            try tmp.appendSlice(arena_alloc, ": ");
            try tmp.appendSlice(arena_alloc, e.value);
            if (e.important) try tmp.appendSlice(arena_alloc, " !important");
            try tmp.appendSlice(arena_alloc, "; ");
        }
        if (tmp.items.len > 0 and tmp.items[tmp.items.len - 1] == ' ') {
            tmp.items.len -= 1;
        }
        const owned = try self.arena.allocator().dupe(u8, tmp.items);
        self.cached_css_text = owned;
        self.dirty_css_text = false;
        return owned;
    }
};

// ── Per-element map ───────────────────────────────────────────────────
//
// Keyed by lxb_dom_element_t pointer (as usize).  The map itself is owned by
// dom_api.zig (see g_style_decl_map).  We expose helpers that operate on an
// externally-owned map value so dom_api.zig stays as the single owner.

pub const DeclMap = std.AutoHashMap(usize, *StyleDeclList);

/// Get or create a StyleDeclList for an element pointer.
pub fn getOrCreate(
    map: *DeclMap,
    allocator: std.mem.Allocator,
    elem_ptr: usize,
) !*StyleDeclList {
    const gop = try map.getOrPut(elem_ptr);
    if (!gop.found_existing) {
        const list = try allocator.create(StyleDeclList);
        list.* = StyleDeclList.init(allocator);
        gop.value_ptr.* = list;
    }
    return gop.value_ptr.*;
}

/// Remove and free a StyleDeclList for an element pointer (call on element teardown).
pub fn removeElem(map: *DeclMap, allocator: std.mem.Allocator, elem_ptr: usize) void {
    if (map.fetchRemove(elem_ptr)) |kv| {
        kv.value.deinit(allocator);
        allocator.destroy(kv.value);
    }
}

/// Free every StyleDeclList in the map and deinit the map itself (call on VM shutdown).
pub fn shutdownMap(map: *DeclMap, allocator: std.mem.Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.*.deinit(allocator);
        allocator.destroy(entry.value_ptr.*);
    }
    map.deinit();
}

// ── Parse helper ─────────────────────────────────────────────────────
//
// Populate a StyleDeclList by parsing a raw CSS declaration string
// (the style attribute value, without surrounding braces).

pub fn parseIntoList(
    list: *StyleDeclList,
    allocator: std.mem.Allocator,
    css_text: []const u8,
) !void {
    list.clear(allocator);
    var pos: usize = 0;
    while (pos < css_text.len) {
        // Skip whitespace and comments before property name
        skipWsAndComments(css_text, &pos);
        if (pos >= css_text.len) break;

        // Property name: scan until ':' or ';', skipping comments
        const name_start = pos;
        while (pos < css_text.len) {
            if (css_text[pos] == '/' and pos + 1 < css_text.len and css_text[pos + 1] == '*') {
                skipComment(css_text, &pos);
            } else if (css_text[pos] == ':' or css_text[pos] == ';') {
                break;
            } else {
                pos += 1;
            }
        }
        if (pos >= css_text.len or css_text[pos] != ':') {
            // No colon — skip to next semicolon (comment-aware)
            while (pos < css_text.len and css_text[pos] != ';') {
                if (css_text[pos] == '/' and pos + 1 < css_text.len and css_text[pos + 1] == '*') {
                    skipComment(css_text, &pos);
                } else {
                    pos += 1;
                }
            }
            if (pos < css_text.len) pos += 1;
            continue;
        }
        const raw_name = std.mem.trim(u8, css_text[name_start..pos], " \t\r\n");
        pos += 1; // skip ':'

        // Value: scan for ';' at paren-depth 0, skipping strings and comments.
        // Strings and comments may contain ';' which must not terminate the declaration.
        const val_start = pos;
        var depth: usize = 0;
        while (pos < css_text.len) {
            const ch = css_text[pos];
            if (ch == '/' and pos + 1 < css_text.len and css_text[pos + 1] == '*') {
                skipComment(css_text, &pos);
                continue;
            } else if (ch == '"' or ch == '\'') {
                skipString(css_text, &pos, ch);
                continue;
            } else if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                if (depth > 0) depth -= 1;
            } else if (ch == ';' and depth == 0) {
                break;
            }
            pos += 1;
        }
        const raw_val = std.mem.trim(u8, css_text[val_start..pos], " \t\r\n");
        if (pos < css_text.len) pos += 1; // skip ';'

        if (raw_name.len == 0) continue;

        // Check for !important suffix
        var value = raw_val;
        var important = false;
        if (endsWithImportant(raw_val)) |clean| {
            value = clean;
            important = true;
        }

        try list.upsert(allocator, raw_name, value, important);
    }
}

// ── Private helpers ───────────────────────────────────────────────────

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Skip a CSS comment starting at pos. pos must point to '/'.
/// Advances pos past the closing '*/' (or to end of input if unclosed).
fn skipComment(s: []const u8, pos: *usize) void {
    pos.* += 2; // skip '/' and '*'
    while (pos.* < s.len) {
        if (s[pos.*] == '*' and pos.* + 1 < s.len and s[pos.* + 1] == '/') {
            pos.* += 2;
            return;
        }
        pos.* += 1;
    }
}

/// Skip a quoted string starting at pos. pos must point to the opening quote.
/// Advances pos past the closing quote (handles backslash escapes).
fn skipString(s: []const u8, pos: *usize, quote: u8) void {
    pos.* += 1; // skip opening quote
    while (pos.* < s.len) {
        const c = s[pos.*];
        if (c == '\\') {
            pos.* += 1; // skip backslash
            if (pos.* < s.len) pos.* += 1; // skip escaped char
            continue;
        }
        if (c == quote) {
            pos.* += 1; // skip closing quote
            return;
        }
        pos.* += 1;
    }
}

/// Skip whitespace and CSS comments, advancing pos.
fn skipWsAndComments(s: []const u8, pos: *usize) void {
    while (pos.* < s.len) {
        if (isWs(s[pos.*])) {
            pos.* += 1;
        } else if (s[pos.*] == '/' and pos.* + 1 < s.len and s[pos.* + 1] == '*') {
            skipComment(s, pos);
        } else {
            break;
        }
    }
}

/// Strip trailing whitespace + CSS comments from `s`. Returns the resulting slice.
/// Iterates until no more trailing whitespace/comments can be removed (comments
/// may be nested between whitespace runs: `red /*a*/ /*b*/`).
fn stripTrailingWsComments(s: []const u8) []const u8 {
    var cur = s;
    while (true) {
        const before = cur;
        cur = std.mem.trimEnd(u8, cur, " \t\r\n\x0c");
        if (cur.len >= 2 and cur[cur.len - 1] == '/' and cur[cur.len - 2] == '*') {
            // Walk back to find the matching '/*'
            var i: usize = cur.len - 2;
            var found = false;
            while (i > 0) {
                i -= 1;
                if (i + 1 < cur.len and cur[i] == '/' and cur[i + 1] == '*') {
                    found = true;
                    cur = cur[0..i];
                    break;
                }
            }
            if (!found) return cur;
        }
        if (cur.len == before.len) return cur;
    }
}

/// If raw_val ends with "!important" (case-insensitive), possibly with
/// whitespace and/or CSS comments interleaved between `!` and `important`
/// and at the tail, return the trimmed value without the suffix.
/// Otherwise return null.
///
/// CSS Syntax §5.4.5 *consume a declaration* step 4: look at the last two
/// non-whitespace, non-comment tokens; if they are `!` + `important`, set
/// the important flag and drop them from the value.
fn endsWithImportant(raw_val: []const u8) ?[]const u8 {
    // Strip trailing whitespace + comments.
    var s = stripTrailingWsComments(raw_val);
    const important = "important";
    if (s.len < important.len) return null;
    const tail = s[s.len - important.len ..];
    if (!std.ascii.eqlIgnoreCase(tail, important)) return null;
    // Ensure the character before `important` is a word boundary.
    if (s.len > important.len) {
        const prev = s[s.len - important.len - 1];
        if ((prev >= 'A' and prev <= 'Z') or (prev >= 'a' and prev <= 'z') or
            (prev >= '0' and prev <= '9') or prev == '-' or prev == '_')
            return null;
    } else {
        // No "!" before "important" at all.
        return null;
    }
    s = s[0 .. s.len - important.len];
    // Strip ws + comments between `!` and `important`.
    s = stripTrailingWsComments(s);
    if (s.len == 0 or s[s.len - 1] != '!') return null;
    s = s[0 .. s.len - 1];
    // Final remainder: trim trailing ws + comments.
    return stripTrailingWsComments(s);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "StyleDeclList upsert and serialize" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", false);
    try list.upsert(alloc, "margin-top", "1px", false);

    var out = try list.serialize(alloc);
    defer out.deinit(alloc);
    try std.testing.expectEqualStrings("color: red; margin-top: 1px;", out.items);
}

test "StyleDeclList important serialization" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);
    try list.upsert(alloc, "margin-top", "1px", false);

    var out = try list.serialize(alloc);
    defer out.deinit(alloc);
    try std.testing.expectEqualStrings("color: red !important; margin-top: 1px;", out.items);
}

test "StyleDeclList upsert replaces existing" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", false);
    try list.upsert(alloc, "color", "blue", true);

    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("blue", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "StyleDeclList remove preserves others" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);
    try list.upsert(alloc, "display", "block", false);

    const old = list.remove("color");
    try std.testing.expect(old != null);
    try std.testing.expectEqualStrings("red", old.?);

    // display entry still present with its important flag intact
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("display", list.entries.items[0].name);
    try std.testing.expect(!list.entries.items[0].important);
}

test "parseIntoList basic" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: red !important; margin: 1px");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("color", list.entries.items[0].name);
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
    try std.testing.expectEqualStrings("margin", list.entries.items[1].name);
    try std.testing.expect(!list.entries.items[1].important);
}

test "parseIntoList calc value" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "width: calc(100% - 20px); color: blue");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("calc(100% - 20px)", list.entries.items[0].value);
}

test "StyleDeclList serialize large inline style — no truncation" {
    // Generates >8192 bytes worth of declarations to verify no truncation occurs.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Insert 200 properties with long values (~50 bytes each → ~10 000 bytes total)
    var name_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const name = std.fmt.bufPrint(&name_buf, "--custom-prop-{d:0>3}", .{i}) catch unreachable;
        const val = std.fmt.bufPrint(&val_buf, "value-long-enough-{d:0>3}", .{i}) catch unreachable;
        try list.upsert(alloc, name, val, false);
    }

    var out = try list.serialize(alloc);
    defer out.deinit(alloc);

    // All 200 entries must be present — check count via semicolons
    var count: usize = 0;
    for (out.items) |c| if (c == ';') { count += 1; };
    try std.testing.expectEqual(@as(usize, 200), count);

    // Last entry must be present (would be lost with the old 8192-byte buffer)
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--custom-prop-199") != null);
}

test "parseIntoList url with semicolon in string" {
    // background: url("a;b") red — the ';' inside the string must not split the declaration
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "background: url(\"a;b\") red; color: green");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("background", list.entries.items[0].name);
    try std.testing.expectEqualStrings("url(\"a;b\") red", list.entries.items[0].value);
    try std.testing.expectEqualStrings("color", list.entries.items[1].name);
    try std.testing.expectEqualStrings("green", list.entries.items[1].value);
}

test "parseIntoList comment with semicolon" {
    // /* comment with ; */ color: red — the ';' inside the comment must not split anything
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "/* 1px */ margin: /* 2px */ 3px");
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("margin", list.entries.items[0].name);
    // value is everything after ':' trimmed; the comment is included in raw_val
    // What matters is that we get exactly one entry (not zero due to early ';' split)
    try std.testing.expect(list.entries.items[0].value.len > 0);
}

test "parseIntoList url single-quoted multiple semicolons in string" {
    // url('a;b;c') — multiple semicolons inside a single-quoted string
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "background: url('a;b;c'); color: blue");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("background", list.entries.items[0].name);
    try std.testing.expectEqualStrings("url('a;b;c')", list.entries.items[0].value);
    try std.testing.expectEqualStrings("color", list.entries.items[1].name);
    try std.testing.expectEqualStrings("blue", list.entries.items[1].value);
}

// ── Phase 2 tests ─────────────────────────────────────────────────────

test "getCssText cached — returns serialized text, caches on second call" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);
    try list.upsert(alloc, "margin-top", "1px", false);

    // First call serializes
    const first = try list.getCssText();
    try std.testing.expectEqualStrings("color: red !important; margin-top: 1px;", first);
    try std.testing.expect(!list.dirty_css_text);

    // Second call returns same slice (no re-allocation)
    const second = try list.getCssText();
    try std.testing.expectEqual(first.ptr, second.ptr);
}

test "getCssText dirty after upsert" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", false);
    _ = try list.getCssText(); // cache it
    try std.testing.expect(!list.dirty_css_text);

    // Mutation marks dirty
    try list.upsert(alloc, "color", "blue", false);
    try std.testing.expect(list.dirty_css_text);

    const text = try list.getCssText();
    try std.testing.expectEqualStrings("color: blue;", text);
}

test "getCssText dirty after remove" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", false);
    try list.upsert(alloc, "display", "block", false);
    _ = try list.getCssText();
    try std.testing.expect(!list.dirty_css_text);

    _ = list.remove("color");
    try std.testing.expect(list.dirty_css_text);
    const text = try list.getCssText();
    try std.testing.expectEqualStrings("display: block;", text);
}

test "cssText reparse replaces prior declarations" {
    // Simulate styleSetCssText: parse new text into existing list, replacing all prior.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Populate with initial declarations
    try list.upsert(alloc, "color", "red", false);
    try list.upsert(alloc, "display", "block", false);
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);

    // Reparse — prior entries must be discarded
    try parseIntoList(&list, alloc, "margin: 2px; color: blue !important");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("margin", list.entries.items[0].name);
    try std.testing.expectEqualStrings("2px", list.entries.items[0].value);
    try std.testing.expect(!list.entries.items[0].important);
    try std.testing.expectEqualStrings("color", list.entries.items[1].name);
    try std.testing.expectEqualStrings("blue", list.entries.items[1].value);
    try std.testing.expect(list.entries.items[1].important);

    // getCssText reflects the new state
    const text = try list.getCssText();
    try std.testing.expectEqualStrings("margin: 2px; color: blue !important;", text);
}

test "cascade important ordering — inline important wins over non-important" {
    // Verify that a list with mixed important/non-important serializes so that
    // the cascade (which reads !important suffix from the attribute) will pick
    // the important entry over the non-important one.
    //
    // Cascade sort key: important bit at position 63 → inline important > author non-important.
    // This test checks the serialize output that the cascade attribute-read path receives.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Author non-important color is set first, then inline important overrides it.
    try list.upsert(alloc, "color", "red", false);   // author non-important (lower priority)
    try list.upsert(alloc, "color", "blue", true);   // inline important (higher priority — replaces)

    // After upsert the list has only one entry (the important one).
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expect(list.entries.items[0].important);

    // The serialized attribute contains "!important" so the cascade parser sets the bit.
    var out = try list.serialize(alloc);
    defer out.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "!important") != null);
    try std.testing.expectEqualStrings("color: blue !important;", out.items);
}

test "cascade important ordering — multiple props, important flags preserved independently" {
    // Verify that important and non-important entries can coexist in the same list
    // and each serializes with the correct suffix.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);        // important
    try list.upsert(alloc, "margin-top", "4px", false);  // non-important
    try list.upsert(alloc, "display", "flex", true);     // important

    var out = try list.serialize(alloc);
    defer out.deinit(alloc);

    // color and display must carry !important; margin-top must not.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "color: red !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "margin-top: 4px;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "display: flex !important") != null);
}

// ── Phase 3 tests ─────────────────────────────────────────────────────

test "upsertShorthand margin 4-value expands to 4 longhands" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "1px", "2px", "1px", "2px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);

    try std.testing.expectEqual(@as(usize, 4), list.entries.items.len);
    try std.testing.expectEqualStrings("margin-top",    list.entries.items[0].name);
    try std.testing.expectEqualStrings("1px",           list.entries.items[0].value);
    try std.testing.expectEqualStrings("margin-right",  list.entries.items[1].name);
    try std.testing.expectEqualStrings("2px",           list.entries.items[1].value);
    try std.testing.expectEqualStrings("margin-bottom", list.entries.items[2].name);
    try std.testing.expectEqualStrings("margin-left",   list.entries.items[3].name);
    // all tagged as shorthand_for = "margin"
    for (list.entries.items) |e| {
        try std.testing.expectEqualStrings("margin", e.shorthand_for.?);
    }
}

test "upsertShorthand length reflects expanded longhands" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "5px", "5px", "5px", "5px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);

    try std.testing.expectEqual(@as(usize, 4), list.entries.items.len);
}

test "upsertShorthand important propagates to all longhands" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "1px", "1px", "1px", "1px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, true);

    for (list.entries.items) |e| {
        try std.testing.expect(e.important);
    }
    // getPropertyPriorityShorthand returns "important"
    const prio = list.getPropertyPriorityShorthand("margin");
    try std.testing.expectEqualStrings("important", prio.?);
}

test "getPropertyPriorityShorthand — mixed important returns empty" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Insert two longhands with different important flags via upsert (direct)
    try list.upsert(alloc, "margin-top",    "1px", true);
    try list.upsert(alloc, "margin-right",  "2px", false);
    try list.upsert(alloc, "margin-bottom", "1px", true);
    try list.upsert(alloc, "margin-left",   "2px", false);
    // Tag them as shorthand_for manually is not needed — getPropertyPriorityShorthand
    // checks shorthand_for; so use upsertShorthand with mixed flags via two calls.
    // Instead test via upsertShorthand replacing one entry:
    const names2 = [_][]const u8{ "padding-top", "padding-right", "padding-bottom", "padding-left" };
    const vals2  = [_][]const u8{ "3px", "3px", "3px", "3px" };
    try list.upsertShorthand(alloc, "padding", &names2, &vals2, false);

    // padding all non-important → ""
    const prio_pad = list.getPropertyPriorityShorthand("padding");
    try std.testing.expectEqualStrings("", prio_pad.?);
}

test "getPropertyValueShorthand margin — canonical 1-value" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "4px", "4px", "4px", "4px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("margin", &buf);
    try std.testing.expectEqualStrings("4px", result.?);
}

test "getPropertyValueShorthand margin — canonical 2-value" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "1px", "2px", "1px", "2px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("margin", &buf);
    try std.testing.expectEqualStrings("1px 2px", result.?);
}

test "getPropertyValueShorthand margin — canonical 4-value" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "1px", "2px", "3px", "4px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("margin", &buf);
    try std.testing.expectEqualStrings("1px 2px 3px 4px", result.?);
}

test "getPropertyValueShorthand — missing longhand returns null" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Only 2 of 4 longhands present
    try list.upsert(alloc, "margin-top",   "1px", false);
    try list.upsert(alloc, "margin-right", "2px", false);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("margin", &buf);
    try std.testing.expect(result == null);
}

test "removeShorthand removes all tagged longhands" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals  = [_][]const u8{ "1px", "2px", "1px", "2px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals, false);
    try list.upsert(alloc, "color", "red", false);

    list.removeShorthand("margin");

    // Only color remains
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("color", list.entries.items[0].name);
}

test "upsertShorthand flex expands to 3 longhands" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "flex-grow", "flex-shrink", "flex-basis" };
    const vals  = [_][]const u8{ "1", "1", "auto" };
    try list.upsertShorthand(alloc, "flex", &names, &vals, false);

    try std.testing.expectEqual(@as(usize, 3), list.entries.items.len);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("flex", &buf);
    try std.testing.expectEqualStrings("auto", result.?);
}

test "upsertShorthand replaces prior shorthand expansion" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "margin-top", "margin-right", "margin-bottom", "margin-left" };
    const vals1 = [_][]const u8{ "1px", "1px", "1px", "1px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals1, false);

    const vals2 = [_][]const u8{ "8px", "8px", "8px", "8px" };
    try list.upsertShorthand(alloc, "margin", &names, &vals2, false);

    // Still 4 longhands, not 8
    try std.testing.expectEqual(@as(usize, 4), list.entries.items.len);
    try std.testing.expectEqualStrings("8px", list.entries.items[0].value);
}

// ── Phase 4: CSSRule.style backing store round-trip tests ─────────────
//
// The JS CSSStyleDeclaration class uses parseIntoList / serialize as its
// semantic model. These tests verify that model directly (no JS runtime
// needed) so `zig build test-css` covers Phase 4 correctness.

test "Phase4 rule.style setProperty round-trip via parseIntoList+upsert" {
    // Simulates: rule.style.setProperty("color", "red", "")
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Parse initial decls string (mirrors CSSStyleDeclaration constructor)
    try parseIntoList(&list, alloc, "font-size: 14px;");
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);

    // setProperty → upsert
    try list.upsert(alloc, "color", "red", false);
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);

    // Serialize back (_commit: write to rule._decls)
    const css = try list.getCssText();
    try std.testing.expectEqualStrings("font-size: 14px; color: red;", css);
}

test "Phase4 rule.style setProperty with important" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: blue;");
    try list.upsert(alloc, "color", "red", true);

    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);

    const css = try list.getCssText();
    try std.testing.expectEqualStrings("color: red !important;", css);
}

test "Phase4 rule.style removeProperty" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: red; margin-top: 4px;");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);

    const old = list.remove("color");
    try std.testing.expectEqualStrings("red", old.?);
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("margin-top", list.entries.items[0].name);
}

test "Phase4 rule.style length and item" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: red; display: block; font-size: 12px;");
    try std.testing.expectEqual(@as(usize, 3), list.entries.items.len);
    try std.testing.expectEqualStrings("color", list.entries.items[0].name);
    try std.testing.expectEqualStrings("display", list.entries.items[1].name);
    try std.testing.expectEqualStrings("font-size", list.entries.items[2].name);
}

test "Phase4 rule.style cssText setter replaces declarations" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: red;");
    // Simulate cssText= setter: re-parse replaces all prior declarations
    try parseIntoList(&list, alloc, "background: blue; font-weight: bold;");
    try std.testing.expectEqual(@as(usize, 2), list.entries.items.len);
    try std.testing.expectEqualStrings("background", list.entries.items[0].name);
    try std.testing.expectEqualStrings("font-weight", list.entries.items[1].name);
}

test "Phase4 rule.style getPropertyValue and getPropertyPriority" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try parseIntoList(&list, alloc, "color: green !important; margin: 0;");

    // getPropertyValue
    const color_idx = list.indexOf("color");
    try std.testing.expect(color_idx != null);
    try std.testing.expectEqualStrings("green", list.entries.items[color_idx.?].value);

    // getPropertyPriority
    try std.testing.expect(list.entries.items[color_idx.?].important);

    const margin_idx = list.indexOf("margin");
    try std.testing.expect(margin_idx != null);
    try std.testing.expect(!list.entries.items[margin_idx.?].important);
}

// ── -webkit- flex/alignment alias round-trip tests ────────────────────
// CSS Flexbox L1 Appendix A + Compatibility Standard §7:
// setProperty("-webkit-<name>", v) stores under the unprefixed canonical name;
// getPropertyValue("-webkit-<name>") and getPropertyValue("<name>") both return v.

test "webkit alias: -webkit-align-content round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-align-content", "center", false);
    // stored under canonical name
    const idx = list.indexOf("align-content");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("align-content", list.entries.items[idx.?].name);
    try std.testing.expectEqualStrings("center", list.entries.items[idx.?].value);
    // lookup by webkit name also works
    try std.testing.expect(list.indexOf("-webkit-align-content") != null);
}

test "webkit alias: -webkit-align-items round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-align-items", "flex-start", false);
    const idx = list.indexOf("align-items");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("flex-start", list.entries.items[idx.?].value);
}

test "webkit alias: -webkit-align-self round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-align-self", "stretch", false);
    try std.testing.expect(list.indexOf("align-self") != null);
}

test "webkit alias: -webkit-flex-direction round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-flex-direction", "column", false);
    try std.testing.expect(list.indexOf("flex-direction") != null);
}

test "webkit alias: -webkit-flex-grow round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-flex-grow", "2", false);
    const idx = list.indexOf("flex-grow");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("2", list.entries.items[idx.?].value);
}

test "webkit alias: -webkit-flex-shrink round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-flex-shrink", "0", false);
    try std.testing.expect(list.indexOf("flex-shrink") != null);
}

test "webkit alias: -webkit-flex-basis round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-flex-basis", "100px", false);
    try std.testing.expect(list.indexOf("flex-basis") != null);
}

test "webkit alias: -webkit-flex-wrap round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-flex-wrap", "wrap", false);
    try std.testing.expect(list.indexOf("flex-wrap") != null);
}

test "webkit alias: -webkit-justify-content round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-justify-content", "space-between", false);
    const idx = list.indexOf("justify-content");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("space-between", list.entries.items[idx.?].value);
}

test "webkit alias: -webkit-order round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try list.upsert(alloc, "-webkit-order", "3", false);
    const idx = list.indexOf("order");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("3", list.entries.items[idx.?].value);
}

test "webkit alias: -webkit-flex shorthand upsertShorthand round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    const names = [_][]const u8{ "flex-grow", "flex-shrink", "flex-basis" };
    const vals  = [_][]const u8{ "1", "1", "0%" };
    try list.upsertShorthand(alloc, "-webkit-flex", &names, &vals, false);
    // longhands stored under canonical shorthand_for = "flex"
    var found: usize = 0;
    for (list.entries.items) |e| {
        if (e.shorthand_for) |sf| {
            if (std.ascii.eqlIgnoreCase(sf, "flex")) found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), found);
    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("-webkit-flex", &buf);
    try std.testing.expect(result != null);
}

test "webkit alias: -webkit-flex-flow shorthand upsertShorthand round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    const names = [_][]const u8{ "flex-direction", "flex-wrap" };
    const vals  = [_][]const u8{ "column", "wrap" };
    try list.upsertShorthand(alloc, "-webkit-flex-flow", &names, &vals, false);
    var found: usize = 0;
    for (list.entries.items) |e| {
        if (e.shorthand_for) |sf| {
            if (std.ascii.eqlIgnoreCase(sf, "flex-flow")) found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("-webkit-flex-flow", &buf);
    try std.testing.expect(result != null);
}

// ── Wave 9: border/outline/gap/font shorthand round-trip ───────────────────

test "Wave9: border shorthand — all four sides equal round-trips" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{
        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    };
    const vals = [_][]const u8{
        "1px", "1px", "1px", "1px",
        "solid", "solid", "solid", "solid",
        "red", "red", "red", "red",
    };
    try list.upsertShorthand(alloc, "border", &names, &vals, false);

    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("border", &buf);
    try std.testing.expectEqualStrings("1px solid red", result.?);
}

test "Wave9: border-top shorthand — width/style/color round-trips" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "border-top-width", "border-top-style", "border-top-color" };
    const vals  = [_][]const u8{ "2px", "dashed", "blue" };
    try list.upsertShorthand(alloc, "border-top", &names, &vals, false);

    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("border-top", &buf);
    try std.testing.expectEqualStrings("2px dashed blue", result.?);
}

test "Wave9: outline shorthand — width/style/color round-trips" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "outline-width", "outline-style", "outline-color" };
    const vals  = [_][]const u8{ "3px", "dotted", "green" };
    try list.upsertShorthand(alloc, "outline", &names, &vals, false);

    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("outline", &buf);
    try std.testing.expectEqualStrings("3px dotted green", result.?);
}

test "Wave9: gap shorthand — equal values collapse to one" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "row-gap", "column-gap" };
    const vals  = [_][]const u8{ "12px", "12px" };
    try list.upsertShorthand(alloc, "gap", &names, &vals, false);

    var buf: [64]u8 = undefined;
    const result = list.getPropertyValueShorthand("gap", &buf);
    try std.testing.expectEqualStrings("12px", result.?);
}

test "Wave9: font shorthand — size + family basic round-trip" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    const names = [_][]const u8{ "font-style", "font-weight", "font-size", "line-height", "font-family" };
    const vals  = [_][]const u8{ "normal", "normal", "16px", "normal", "Arial" };
    try list.upsertShorthand(alloc, "font", &names, &vals, false);

    var buf: [128]u8 = undefined;
    const result = list.getPropertyValueShorthand("font", &buf);
    try std.testing.expectEqualStrings("16px Arial", result.?);
}

// ── CSSOM §6.7.3 setProperty / getPropertyPriority semantics ────────────────

test "CSSOM §6.7.3: setProperty with priority 'important' sets important flag" {
    // Step 6: if priority is "important" (case-insensitive), set the important flag.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);

    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expect(list.entries.items[0].important);
    // getPropertyPriority: property exists and is important → "important"
    const idx = list.indexOf("color");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("important",
        if (list.entries.items[idx.?].important) "important" else "");
}

test "CSSOM §6.7.3: setProperty with empty priority does not set important" {
    // Step 4: empty priority string → treat as non-important (no early return).
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "blue", false);

    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expect(!list.entries.items[0].important);
    const idx = list.indexOf("color");
    try std.testing.expect(idx != null);
    try std.testing.expectEqualStrings("",
        if (list.entries.items[0].important) "important" else "");
}

test "CSSOM §6.7.3: setProperty with invalid priority leaves existing property unchanged" {
    // Step 4: non-empty priority that is not "important" → return without doing anything.
    // At the StyleDeclList layer the caller (dom_api.zig) performs this guard;
    // we verify the list is not mutated when the invalid-priority case is bypassed.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // Pre-populate an entry.
    try list.upsert(alloc, "color", "red", false);

    // Simulate §6.7.3 step 4: invalid priority → caller does not call upsert.
    // Verify entry is unchanged.
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(!list.entries.items[0].important);
}

test "CSSOM §6.7.3: getPropertyPriority returns 'important' for important property" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "margin-top", "10px", true);

    const idx = list.indexOf("margin-top");
    try std.testing.expect(idx != null);
    const prio: []const u8 = if (list.entries.items[idx.?].important) "important" else "";
    try std.testing.expectEqualStrings("important", prio);
}

test "CSSOM §6.7.3: getPropertyPriority returns '' for non-important property" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "margin-top", "10px", false);

    const idx = list.indexOf("margin-top");
    try std.testing.expect(idx != null);
    const prio: []const u8 = if (list.entries.items[idx.?].important) "important" else "";
    try std.testing.expectEqualStrings("", prio);
}

test "CSSOM §6.7.3: getPropertyPriority returns '' for unknown property" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // No entries at all → indexOf returns null → caller returns "".
    const idx = list.indexOf("color");
    try std.testing.expect(idx == null);
}

test "CSSOM §6.7.3: setProperty priority 'IMPORTANT' (uppercase) accepted" {
    // Step 4 case-insensitive comparison: "IMPORTANT" must not be rejected.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    // std.ascii.eqlIgnoreCase("IMPORTANT", "important") == true → important = true.
    const is_important = std.ascii.eqlIgnoreCase("IMPORTANT", "important");
    try std.testing.expect(is_important);

    try list.upsert(alloc, "color", "green", is_important);
    try std.testing.expect(list.entries.items[0].important);
}

test "CSSOM §6.7.3: setProperty clears important when re-set with empty priority" {
    // Updating an existing property with priority="" clears the important flag.
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);
    try std.testing.expect(list.entries.items[0].important);

    // Re-set same property, non-important.
    try list.upsert(alloc, "color", "red", false);
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expect(!list.entries.items[0].important);
}

// ── Layer 3A: !important parse robustness ─────────────────────────────
//
// CSS Syntax §5.4.5 *consume a declaration* step 4: examine the last two
// non-whitespace, non-comment tokens. If they are `!` + `important`, set
// the important flag and drop them from the value.

test "Layer3A important: basic trailing !important" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red !important");
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "Layer3A important: uppercase IMPORTANT" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red !IMPORTANT");
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "Layer3A important: whitespace between ! and important" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red !  important");
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "Layer3A important: trailing comment after !important" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red !important /* trailing */");
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "Layer3A important: comment between ! and important" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red ! /* x */ important");
    try std.testing.expectEqualStrings("red", list.entries.items[0].value);
    try std.testing.expect(list.entries.items[0].important);
}

test "Layer3A important: not important for !foo tail" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);
    try parseIntoList(&list, alloc, "color: red !foo");
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
    // Whole tail preserved as value (no important stripped).
    try std.testing.expect(!list.entries.items[0].important);
    try std.testing.expect(std.mem.indexOf(u8, list.entries.items[0].value, "!foo") != null);
}

test "Layer3A important: no match when !important is the full value" {
    // A bare "!important" (no preceding value) has no remainder — ill-formed,
    // but the helper still reports the flag and returns an empty remainder.
    // parseIntoList filters out empty values (see Layer3A normalisation commit).
    const r = endsWithImportant("!important");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("", r.?);
}

test "Layer3A important: word-boundary rejects 'un!important' suffix glue" {
    // "something!important" (no whitespace before `!`) must NOT be flagged
    // because there's no `!` as a separate token — the leading `t` of
    // `red!important` is still valid though, per CSS Syntax §5.4.5:
    // `!` is always its own token. Our implementation requires the `!`
    // to be directly preceded by ws/comment or be the value start.
    //
    // Validate: "red!important" — the `!` is its own token, important set,
    // remainder "red".
    const r = endsWithImportant("red!important");
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("red", r.?);

    // Whereas "redimportant" (no bang) → null.
    const r2 = endsWithImportant("redimportant");
    try std.testing.expect(r2 == null);
}
