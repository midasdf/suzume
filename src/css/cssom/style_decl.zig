//! style_decl.zig — Phase 1 CSSStyleDeclaration backing store
//!
//! Provides StyleDecl + StyleDeclList: an ordered list of { name, value, important }
//! entries per element. Mutations sync back to the lxb "style" attribute so the
//! existing cascade path continues to work without modification.

const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────

pub const StyleDecl = struct {
    /// Normalized kebab-case property name. Owned by the list's arena.
    name: []const u8,
    /// CSSOM-serialized value — no "!important" suffix. Owned by the list's arena.
    value: []const u8,
    important: bool,
};

pub const StyleDeclList = struct {
    entries: std.ArrayListUnmanaged(StyleDecl),
    /// Arena that owns all name/value strings. Reset on full cssText= replacement.
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) StyleDeclList {
        return .{
            .entries = .{},
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *StyleDeclList, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.arena.deinit();
    }

    /// Return the index of the first entry with the given name, or null.
    pub fn indexOf(self: *const StyleDeclList, name: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) return i;
        }
        return null;
    }

    /// Upsert: remove any prior entry with the same name, append new one.
    /// name and value are copied into the arena.
    pub fn upsert(
        self: *StyleDeclList,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        important: bool,
    ) !void {
        // Remove existing entry with this name (last-wins / replace semantics)
        if (self.indexOf(name)) |idx| {
            _ = self.entries.orderedRemove(idx);
        }
        const owned_name = try self.arena.allocator().dupe(u8, name);
        const owned_val = try self.arena.allocator().dupe(u8, value);
        try self.entries.append(allocator, .{
            .name = owned_name,
            .value = owned_val,
            .important = important,
        });
    }

    /// Remove the entry with the given name. Returns the previous value slice
    /// (points into arena memory — valid until next arena reset), or null.
    pub fn remove(self: *StyleDeclList, name: []const u8) ?[]const u8 {
        if (self.indexOf(name)) |idx| {
            const old_val = self.entries.items[idx].value;
            _ = self.entries.orderedRemove(idx);
            return old_val;
        }
        return null;
    }

    /// Serialize entries to "name: value[ !important];" format suitable for the
    /// style attribute. Caller owns the returned ArrayList and must call deinit().
    pub fn serialize(self: *const StyleDeclList, allocator: std.mem.Allocator) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        for (self.entries.items) |e| {
            try out.appendSlice(e.name);
            try out.appendSlice(": ");
            try out.appendSlice(e.value);
            if (e.important) try out.appendSlice(" !important");
            try out.appendSlice("; ");
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
        _ = allocator; // entries backing memory freed by deinit or clear
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
        // Skip whitespace
        while (pos < css_text.len and isWs(css_text[pos])) pos += 1;
        if (pos >= css_text.len) break;

        // Property name
        const name_start = pos;
        while (pos < css_text.len and css_text[pos] != ':' and css_text[pos] != ';') pos += 1;
        if (pos >= css_text.len or css_text[pos] != ':') {
            // No colon — skip to next semicolon
            while (pos < css_text.len and css_text[pos] != ';') pos += 1;
            if (pos < css_text.len) pos += 1;
            continue;
        }
        const raw_name = std.mem.trim(u8, css_text[name_start..pos], " \t\r\n");
        pos += 1; // skip ':'

        // Value (may include '(' ')' pairs — scan for ';' at depth 0)
        const val_start = pos;
        var depth: usize = 0;
        while (pos < css_text.len) {
            if (css_text[pos] == '(') {
                depth += 1;
            } else if (css_text[pos] == ')') {
                if (depth > 0) depth -= 1;
            } else if (css_text[pos] == ';' and depth == 0) {
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

/// If raw_val ends with "!important" (case-insensitive, possibly with whitespace),
/// return the trimmed value without the suffix.  Otherwise return null.
fn endsWithImportant(raw_val: []const u8) ?[]const u8 {
    const s = std.mem.trimRight(u8, raw_val, " \t\r\n");
    const suffix = "!important";
    if (s.len < suffix.len) return null;
    const tail = s[s.len - suffix.len ..];
    if (!std.ascii.eqlIgnoreCase(tail, suffix)) return null;
    const before = std.mem.trimRight(u8, s[0 .. s.len - suffix.len], " \t\r\n");
    return before;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "StyleDeclList upsert and serialize" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", false);
    try list.upsert(alloc, "margin-top", "1px", false);

    var out = try list.serialize(alloc);
    defer out.deinit();
    try std.testing.expectEqualStrings("color: red; margin-top: 1px;", out.items);
}

test "StyleDeclList important serialization" {
    const alloc = std.testing.allocator;
    var list = StyleDeclList.init(alloc);
    defer list.deinit(alloc);

    try list.upsert(alloc, "color", "red", true);
    try list.upsert(alloc, "margin-top", "1px", false);

    var out = try list.serialize(alloc);
    defer out.deinit();
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
    defer out.deinit();

    // All 200 entries must be present — check count via semicolons
    var count: usize = 0;
    for (out.items) |c| if (c == ';') { count += 1; };
    try std.testing.expectEqual(@as(usize, 200), count);

    // Last entry must be present (would be lost with the old 8192-byte buffer)
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--custom-prop-199") != null);
}
