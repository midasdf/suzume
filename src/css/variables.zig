const std = @import("std");

/// A hierarchical map of CSS custom properties (variables).
/// Supports parent chain lookup for cascading scope.
pub const VarMap = struct {
    vars: std.StringHashMapUnmanaged([]const u8),
    parent: ?*const VarMap,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VarMap {
        return .{
            .vars = .{},
            .parent = null,
            .allocator = allocator,
        };
    }

    pub fn initWithParent(allocator: std.mem.Allocator, parent: *const VarMap) VarMap {
        return .{
            .vars = .{},
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VarMap) void {
        self.vars.deinit(self.allocator);
    }

    pub fn set(self: *VarMap, name: []const u8, value: []const u8) void {
        self.vars.put(self.allocator, name, value) catch {};
    }

    /// Look up a variable by name, walking the parent chain.
    pub fn get(self: *const VarMap, name: []const u8) ?[]const u8 {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }
};

/// Resolve all var() references in a CSS value string.
/// Returns a newly allocated string with all var() calls replaced,
/// or null if the input contains no var() references.
pub fn resolveVarRefs(
    value_raw: []const u8,
    var_map: *const VarMap,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    return resolveVarRefsDepth(value_raw, var_map, allocator, 0);
}

fn resolveVarRefsDepth(
    value_raw: []const u8,
    var_map: *const VarMap,
    allocator: std.mem.Allocator,
    depth: u32,
) ?[]const u8 {
    if (depth >= 16) return null; // prevent cycles
    if (std.mem.indexOf(u8, value_raw, "var(") == null) return null;

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var pos: usize = 0;
    while (pos < value_raw.len) {
        if (pos + 4 <= value_raw.len and std.mem.eql(u8, value_raw[pos .. pos + 4], "var(")) {
            // Find matching closing paren
            const var_start = pos;
            pos += 4;
            const close = findMatchingParen(value_raw, pos) orelse {
                // Malformed — copy remainder as-is
                result.appendSlice(value_raw[var_start..]) catch return null;
                break;
            };

            const inner = std.mem.trim(u8, value_raw[pos..close], " \t");
            pos = close + 1;

            // Parse name and optional fallback
            const name_end = findCommaOrEnd(inner);
            const name = std.mem.trim(u8, inner[0..name_end], " \t");

            var fallback: ?[]const u8 = null;
            if (name_end < inner.len and inner[name_end] == ',') {
                fallback = std.mem.trim(u8, inner[name_end + 1 ..], " \t");
            }

            // Look up the variable
            if (var_map.get(name)) |val| {
                // Recursively resolve in case the value itself contains var()
                if (resolveVarRefsDepth(val, var_map, allocator, depth + 1)) |resolved| {
                    result.appendSlice(resolved) catch return null;
                    allocator.free(resolved);
                } else {
                    result.appendSlice(val) catch return null;
                }
            } else if (fallback) |fb| {
                // Resolve fallback (may contain nested var())
                if (resolveVarRefsDepth(fb, var_map, allocator, depth + 1)) |resolved| {
                    result.appendSlice(resolved) catch return null;
                    allocator.free(resolved);
                } else {
                    result.appendSlice(fb) catch return null;
                }
            } else {
                // No value and no fallback — leave empty (property becomes invalid)
            }
        } else {
            result.append(value_raw[pos]) catch return null;
            pos += 1;
        }
    }

    return result.toOwnedSlice() catch null;
}

/// Find the position of the closing parenthesis matching an open one.
/// `start` should be right after the '(' character.
fn findMatchingParen(s: []const u8, start: usize) ?usize {
    var depth: u32 = 1;
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '(') depth += 1;
        if (s[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Find the first comma not inside parentheses, or end of string.
fn findCommaOrEnd(s: []const u8) usize {
    var depth: u32 = 0;
    for (s, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == ',' and depth == 0) return i;
    }
    return s.len;
}
