/// WHATWG URL Standard section 4.3: Basic URL Parser.
///
/// 19-state state machine that parses URL strings into URL records.
/// Supports relative URL resolution via a base URL parameter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const host_mod = @import("host");
const pe = @import("percent_encode");

pub const Host = host_mod.Host;

pub const Path = union(enum) {
    list: std.ArrayListUnmanaged([]u8),
    opaque_path: []u8,
};

pub const Url = struct {
    scheme: []u8,
    username: []u8,
    password: []u8,
    host: ?Host,
    port: ?u16,
    path: Path,
    query: ?[]u8,
    fragment: ?[]u8,
    allocator: Allocator,

    pub fn deinit(self: *Url) void {
        const a = self.allocator;
        a.free(self.scheme);
        a.free(self.username);
        a.free(self.password);
        if (self.host) |h| host_mod.freeHost(a, h);
        switch (self.path) {
            .list => |*l| {
                for (l.items) |seg| a.free(seg);
                l.deinit(a);
            },
            .opaque_path => |p| a.free(p),
        }
        if (self.query) |q| a.free(q);
        if (self.fragment) |f| a.free(f);
    }

    /// Serialize URL to string (WHATWG section 4.4).
    pub fn serialize(self: *const Url, allocator: Allocator, exclude_fragment: bool) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        // scheme + ":"
        try out.appendSlice(allocator, self.scheme);
        try out.append(allocator, ':');

        // authority
        if (self.host != null) {
            try out.appendSlice(allocator, "//");
            if (self.username.len > 0 or self.password.len > 0) {
                try out.appendSlice(allocator, self.username);
                if (self.password.len > 0) {
                    try out.append(allocator, ':');
                    try out.appendSlice(allocator, self.password);
                }
                try out.append(allocator, '@');
            }
            const h = try host_mod.serializeHost(allocator, self.host.?);
            defer allocator.free(h);
            try out.appendSlice(allocator, h);
            if (self.port) |p| {
                try out.append(allocator, ':');
                var buf: [5]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{p}) catch unreachable;
                try out.appendSlice(allocator, s);
            }
        }

        // path
        switch (self.path) {
            .list => |l| {
                for (l.items) |seg| {
                    try out.append(allocator, '/');
                    try out.appendSlice(allocator, seg);
                }
                if (l.items.len == 0 and self.host != null) {
                    try out.append(allocator, '/');
                }
            },
            .opaque_path => |p| try out.appendSlice(allocator, p),
        }

        // query
        if (self.query) |q| {
            try out.append(allocator, '?');
            try out.appendSlice(allocator, q);
        }

        // fragment
        if (!exclude_fragment) {
            if (self.fragment) |f| {
                try out.append(allocator, '#');
                try out.appendSlice(allocator, f);
            }
        }

        return out.toOwnedSlice(allocator);
    }

    /// Serialize with null sentinel for C APIs.
    pub fn serializeZ(self: *const Url, allocator: Allocator) ![:0]const u8 {
        const s = try self.serialize(allocator, false);
        defer allocator.free(s);
        const z = try allocator.allocSentinel(u8, s.len, 0);
        @memcpy(z, s);
        return z;
    }

    pub fn serializeOrigin(self: *const Url, allocator: Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.scheme);
        try out.appendSlice(allocator, "://");
        if (self.host) |h| {
            const hs = try host_mod.serializeHost(allocator, h);
            defer allocator.free(hs);
            try out.appendSlice(allocator, hs);
        }
        if (self.port) |p| {
            try out.append(allocator, ':');
            var buf: [5]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{p}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
        return out.toOwnedSlice(allocator);
    }
};

// ── Special Schemes ──────────────────────────────────────────────────

fn isSpecialScheme(scheme: []const u8) bool {
    return getDefaultPort(scheme) != null or std.mem.eql(u8, scheme, "file");
}

fn getDefaultPort(scheme: []const u8) ?u16 {
    if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss")) return 443;
    if (std.mem.eql(u8, scheme, "ftp")) return 21;
    return null;
}

// ── State Machine ────────────────────────────────────────────────────

const State = enum {
    scheme_start,
    scheme,
    no_scheme,
    special_relative_or_authority,
    path_or_authority,
    special_authority_slashes,
    special_authority_ignore_slashes,
    authority,
    host_state,
    port,
    file,
    file_slash,
    file_host,
    relative,
    relative_slash,
    path_start,
    path,
    opaque_path,
    query,
    fragment,
};

/// Parse a URL string. Returns null on failure.
pub fn parse(allocator: Allocator, raw_input: []const u8, base: ?*const Url) !?Url {
    // Step 1: Preprocess input — strip leading/trailing C0+space, remove tabs/newlines
    const input = preprocessInput(raw_input);

    var url = Url{
        .scheme = try allocator.alloc(u8, 0),
        .username = try allocator.alloc(u8, 0),
        .password = try allocator.alloc(u8, 0),
        .host = null,
        .port = null,
        .path = .{ .list = .empty },
        .query = null,
        .fragment = null,
        .allocator = allocator,
    };
    var parse_failed = false;
    defer if (parse_failed) url.deinit();

    var state: State = .scheme_start;
    var ptr: usize = 0;
    var at_sign_seen = false;
    var password_token_seen = false;
    var inside_brackets = false;

    // Buffers for accumulating state
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    while (true) {
        const c: ?u8 = if (ptr < input.len) input[ptr] else null;

        switch (state) {
            .scheme_start => {
                if (c != null and std.ascii.isAlphabetic(c.?)) {
                    try buf.append(allocator, std.ascii.toLower(c.?));
                    state = .scheme;
                } else {
                    state = .no_scheme;
                    continue; // don't advance ptr
                }
            },

            .scheme => {
                if (c != null and (std.ascii.isAlphanumeric(c.?) or c.? == '+' or c.? == '-' or c.? == '.')) {
                    try buf.append(allocator, std.ascii.toLower(c.?));
                } else if (c != null and c.? == ':') {
                    // Found scheme
                    allocator.free(url.scheme);
                    url.scheme = try allocator.dupe(u8, buf.items);
                    buf.clearRetainingCapacity();

                    if (std.mem.eql(u8, url.scheme, "file")) {
                        state = .file;
                    } else if (isSpecialScheme(url.scheme)) {
                        if (base != null and std.mem.eql(u8, base.?.scheme, url.scheme)) {
                            state = .special_relative_or_authority;
                        } else {
                            state = .special_authority_slashes;
                        }
                    } else if (ptr + 1 < input.len and input[ptr + 1] == '/') {
                        state = .path_or_authority;
                        ptr += 1;
                    } else {
                        // Cannot-be-a-base URL (opaque path)
                        url.path = .{ .opaque_path = try allocator.alloc(u8, 0) };
                        state = .opaque_path;
                    }
                } else {
                    // Not a scheme — backtrack
                    buf.clearRetainingCapacity();
                    state = .no_scheme;
                    ptr = 0;
                    continue;
                }
            },

            .no_scheme => {
                if (base == null) { parse_failed = true; return null; }
                if (base.?.path == .opaque_path) {
                    if (c != null and c.? == '#') {
                        // Copy base, set fragment
                        try copyBaseToUrl(allocator, &url, base.?);
                        url.fragment = try allocator.alloc(u8, 0);
                        state = .fragment;
                    } else {
                        { parse_failed = true; return null; }
                    }
                } else if (std.mem.eql(u8, base.?.scheme, "file")) {
                    state = .file;
                    continue;
                } else {
                    state = .relative;
                    continue;
                }
            },

            .special_relative_or_authority => {
                if (ptr + 1 < input.len and input[ptr] == '/' and input[ptr + 1] == '/') {
                    state = .special_authority_ignore_slashes;
                    ptr += 1;
                } else {
                    state = .relative;
                    continue;
                }
            },

            .path_or_authority => {
                if (c != null and c.? == '/') {
                    state = .authority;
                } else {
                    state = .path;
                    continue;
                }
            },

            .special_authority_slashes => {
                if (c != null and c.? == '/' and ptr + 1 < input.len and input[ptr + 1] == '/') {
                    state = .special_authority_ignore_slashes;
                    ptr += 1;
                } else {
                    state = .special_authority_ignore_slashes;
                    continue;
                }
            },

            .special_authority_ignore_slashes => {
                if (c == null or (c.? != '/' and c.? != '\\')) {
                    state = .authority;
                    continue;
                }
                // Skip slashes
            },

            .relative => {
                if (base) |b| {
                    allocator.free(url.scheme);
                    url.scheme = try allocator.dupe(u8, b.scheme);

                    if (c == null) {
                        try copyBaseAuthAndPath(allocator, &url, b);
                        url.query = if (b.query) |q| try allocator.dupe(u8, q) else null;
                    } else if (c.? == '/') {
                        state = .relative_slash;
                    } else if (c.? == '?') {
                        try copyBaseAuthAndPath(allocator, &url, b);
                        url.query = try allocator.alloc(u8, 0);
                        state = .query;
                    } else if (c.? == '#') {
                        try copyBaseAuthAndPath(allocator, &url, b);
                        url.query = if (b.query) |q| try allocator.dupe(u8, q) else null;
                        url.fragment = try allocator.alloc(u8, 0);
                        state = .fragment;
                    } else if (isSpecialScheme(url.scheme) and c.? == '\\') {
                        state = .relative_slash;
                    } else {
                        try copyBaseAuthAndPath(allocator, &url, b);
                        url.query = if (b.query) |q| try allocator.dupe(u8, q) else null;
                        // Remove last path segment
                        shortenPath(&url);
                        state = .path;
                        continue;
                    }
                } else { parse_failed = true; return null; }
            },

            .relative_slash => {
                if (c != null and (c.? == '/' or (isSpecialScheme(url.scheme) and c.? == '\\'))) {
                    state = .special_authority_ignore_slashes;
                } else {
                    if (base) |b| {
                        url.host = if (b.host) |h| try cloneHost(allocator, h) else null;
                        url.port = b.port;
                        allocator.free(url.username);
                        url.username = try allocator.dupe(u8, b.username);
                        allocator.free(url.password);
                        url.password = try allocator.dupe(u8, b.password);
                    }
                    state = .path;
                    continue;
                }
            },

            .authority => {
                if (c != null and c.? == '@') {
                    if (at_sign_seen) {
                        // Prepend "%40" to buffer
                        var new_buf: std.ArrayListUnmanaged(u8) = .empty;
                        try new_buf.appendSlice(allocator, "%40");
                        try new_buf.appendSlice(allocator, buf.items);
                        buf.deinit(allocator);
                        buf = new_buf;
                    }
                    at_sign_seen = true;

                    // Process buffer as userinfo
                    for (buf.items) |ch| {
                        if (ch == ':' and !password_token_seen) {
                            password_token_seen = true;
                            continue;
                        }
                        const encoded = try pe.percentEncode(allocator, &[_]u8{ch}, .userinfo);
                        defer allocator.free(encoded);
                        if (password_token_seen) {
                            var new_pw: std.ArrayListUnmanaged(u8) = .empty;
                            try new_pw.appendSlice(allocator, url.password);
                            try new_pw.appendSlice(allocator, encoded);
                            allocator.free(url.password);
                            url.password = try new_pw.toOwnedSlice(allocator);
                        } else {
                            var new_un: std.ArrayListUnmanaged(u8) = .empty;
                            try new_un.appendSlice(allocator, url.username);
                            try new_un.appendSlice(allocator, encoded);
                            allocator.free(url.username);
                            url.username = try new_un.toOwnedSlice(allocator);
                        }
                    }
                    buf.clearRetainingCapacity();
                } else if (c == null or c.? == '/' or c.? == '?' or c.? == '#' or
                    (isSpecialScheme(url.scheme) and c.? == '\\'))
                {
                    if (at_sign_seen and buf.items.len == 0) { parse_failed = true; return null; }
                    // Buffer contains host (and maybe port)
                    ptr -= buf.items.len;
                    buf.clearRetainingCapacity();
                    state = .host_state;
                    continue;
                } else {
                    try buf.append(allocator, c.?);
                }
            },

            .host_state => {
                if (c != null and c.? == ':' and !inside_brackets) {
                    if (isSpecialScheme(url.scheme) and buf.items.len == 0) { parse_failed = true; return null; }
                    const h = try host_mod.parseHost(allocator, buf.items, !isSpecialScheme(url.scheme)) orelse { parse_failed = true; return null; };
                    url.host = h;
                    buf.clearRetainingCapacity();
                    state = .port;
                } else if (c == null or c.? == '/' or c.? == '?' or c.? == '#' or
                    (isSpecialScheme(url.scheme) and c.? == '\\'))
                {
                    if (isSpecialScheme(url.scheme) and buf.items.len == 0) { parse_failed = true; return null; }
                    const h = try host_mod.parseHost(allocator, buf.items, !isSpecialScheme(url.scheme)) orelse { parse_failed = true; return null; };
                    url.host = h;
                    buf.clearRetainingCapacity();
                    state = .path_start;
                    continue;
                } else {
                    if (c.? == '[') inside_brackets = true;
                    if (c.? == ']') inside_brackets = false;
                    try buf.append(allocator, c.?);
                }
            },

            .port => {
                if (c != null and std.ascii.isDigit(c.?)) {
                    try buf.append(allocator, c.?);
                } else if (c == null or c.? == '/' or c.? == '?' or c.? == '#' or
                    (isSpecialScheme(url.scheme) and c.? == '\\'))
                {
                    if (buf.items.len > 0) {
                        const port_num = std.fmt.parseInt(u16, buf.items, 10) catch { parse_failed = true; return null; };
                        url.port = if (getDefaultPort(url.scheme)) |dp| (if (port_num == dp) null else port_num) else port_num;
                    }
                    buf.clearRetainingCapacity();
                    state = .path_start;
                    continue;
                } else {
                    { parse_failed = true; return null; }
                }
            },

            .file => {
                allocator.free(url.scheme);
                url.scheme = try allocator.dupe(u8, "file");
                url.host = Host{ .domain = try allocator.alloc(u8, 0) }; // empty host

                if (c != null and (c.? == '/' or c.? == '\\')) {
                    state = .file_slash;
                } else if (base != null and std.mem.eql(u8, base.?.scheme, "file")) {
                    try copyBaseAuthAndPath(allocator, &url, base.?);
                    url.query = if (base.?.query) |q| try allocator.dupe(u8, q) else null;
                    if (c != null and c.? == '?') {
                        url.query = try allocator.alloc(u8, 0);
                        state = .query;
                    } else if (c != null and c.? == '#') {
                        url.fragment = try allocator.alloc(u8, 0);
                        state = .fragment;
                    } else if (c != null) {
                        url.query = null;
                        shortenPath(&url);
                        state = .path;
                        continue;
                    }
                } else {
                    state = .path;
                    continue;
                }
            },

            .file_slash => {
                if (c != null and (c.? == '/' or c.? == '\\')) {
                    state = .file_host;
                } else {
                    if (base != null and std.mem.eql(u8, base.?.scheme, "file")) {
                        url.host = if (base.?.host) |h| try cloneHost(allocator, h) else null;
                    }
                    state = .path;
                    continue;
                }
            },

            .file_host => {
                if (c == null or c.? == '/' or c.? == '\\' or c.? == '?' or c.? == '#') {
                    if (buf.items.len == 0) {
                        // Empty host — keep the empty domain host set in .file state
                    } else if (isWindowsDriveLetter(buf.items)) {
                        state = .path;
                        // Don't clear buf — it'll be consumed as path
                        ptr -= buf.items.len;
                        buf.clearRetainingCapacity();
                        continue;
                    } else {
                        const h = try host_mod.parseHost(allocator, buf.items, false) orelse { parse_failed = true; return null; };
                        // Free the empty host set in .file
                        if (url.host) |old_h| host_mod.freeHost(allocator, old_h);
                        url.host = h;
                    }
                    buf.clearRetainingCapacity();
                    state = .path_start;
                    continue;
                } else {
                    try buf.append(allocator, c.?);
                }
            },

            .path_start => {
                if (isSpecialScheme(url.scheme)) {
                    state = .path;
                    if (c == null or (c.? != '/' and c.? != '\\')) continue;
                } else if (c != null and c.? == '?') {
                    url.query = try allocator.alloc(u8, 0);
                    state = .query;
                } else if (c != null and c.? == '#') {
                    url.fragment = try allocator.alloc(u8, 0);
                    state = .fragment;
                } else if (c != null) {
                    state = .path;
                    if (c.? != '/') continue;
                }
            },

            .path => {
                if (c == null or c.? == '/' or (isSpecialScheme(url.scheme) and c.? == '\\') or
                    c.? == '?' or c.? == '#')
                {
                    const seg = buf.items;
                    if (isDoubleDot(seg)) {
                        shortenPath(&url);
                    } else if (isSingleDot(seg)) {
                        // Do nothing — single dot segment
                    } else {
                        // Percent-encode the segment and append
                        const encoded = try pe.percentEncode(allocator, seg, .path);
                        switch (url.path) {
                            .list => |*l| try l.append(allocator, encoded),
                            .opaque_path => {},
                        }
                    }
                    buf.clearRetainingCapacity();

                    if (c != null and c.? == '?') {
                        url.query = try allocator.alloc(u8, 0);
                        state = .query;
                    } else if (c != null and c.? == '#') {
                        url.fragment = try allocator.alloc(u8, 0);
                        state = .fragment;
                    }
                } else {
                    try buf.append(allocator, c.?);
                }
            },

            .opaque_path => {
                if (c != null and c.? == '?') {
                    url.query = try allocator.alloc(u8, 0);
                    state = .query;
                } else if (c != null and c.? == '#') {
                    url.fragment = try allocator.alloc(u8, 0);
                    state = .fragment;
                } else if (c != null) {
                    // Append to opaque path
                    const encoded = try pe.percentEncode(allocator, &[_]u8{c.?}, .c0_control);
                    defer allocator.free(encoded);
                    switch (url.path) {
                        .opaque_path => |*p| {
                            var new_path: std.ArrayListUnmanaged(u8) = .empty;
                            try new_path.appendSlice(allocator, p.*);
                            try new_path.appendSlice(allocator, encoded);
                            allocator.free(p.*);
                            p.* = try new_path.toOwnedSlice(allocator);
                        },
                        .list => {},
                    }
                }
            },

            .query => {
                if (c == null or c.? == '#') {
                    // Percent-encode buffer as query
                    const set: pe.EncodeSet = if (isSpecialScheme(url.scheme)) .special_query else .query;
                    const encoded = try pe.percentEncode(allocator, buf.items, set);
                    if (url.query) |q| allocator.free(q);
                    url.query = encoded;
                    buf.clearRetainingCapacity();

                    if (c != null and c.? == '#') {
                        url.fragment = try allocator.alloc(u8, 0);
                        state = .fragment;
                    }
                } else {
                    try buf.append(allocator, c.?);
                }
            },

            .fragment => {
                if (c != null) {
                    try buf.append(allocator, c.?);
                } else {
                    const encoded = try pe.percentEncode(allocator, buf.items, .fragment);
                    if (url.fragment) |f| allocator.free(f);
                    url.fragment = encoded;
                    buf.clearRetainingCapacity();
                }
            },
        }

        if (c == null) break;
        ptr += 1;
    }

    return url;
}

// ── Helpers ──────────────────────────────────────────────────────────

fn preprocessInput(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;

    // Strip leading C0 control + space
    while (start < end and (input[start] <= 0x20)) : (start += 1) {}
    // Strip trailing C0 control + space
    while (end > start and (input[end - 1] <= 0x20)) : (end -= 1) {}

    return input[start..end];
}

fn isDoubleDot(seg: []const u8) bool {
    if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') return true;
    if (std.ascii.eqlIgnoreCase(seg, ".%2e")) return true;
    if (std.ascii.eqlIgnoreCase(seg, "%2e.")) return true;
    if (std.ascii.eqlIgnoreCase(seg, "%2e%2e")) return true;
    return false;
}

fn isSingleDot(seg: []const u8) bool {
    if (seg.len == 1 and seg[0] == '.') return true;
    if (std.ascii.eqlIgnoreCase(seg, "%2e")) return true;
    return false;
}

fn shortenPath(url: *Url) void {
    switch (url.path) {
        .list => |*l| {
            if (l.items.len == 0) return;
            // Don't shorten file URL with drive letter as only segment
            if (std.mem.eql(u8, url.scheme, "file") and l.items.len == 1 and isNormalizedWindowsDriveLetter(l.items[0])) return;
            if (l.pop()) |last| {
                url.allocator.free(last);
            }
        },
        .opaque_path => {},
    }
}

fn isWindowsDriveLetter(input: []const u8) bool {
    return input.len == 2 and std.ascii.isAlphabetic(input[0]) and (input[1] == ':' or input[1] == '|');
}

fn isNormalizedWindowsDriveLetter(input: []const u8) bool {
    return input.len == 2 and std.ascii.isAlphabetic(input[0]) and input[1] == ':';
}

fn copyBaseToUrl(allocator: Allocator, url: *Url, b: *const Url) !void {
    allocator.free(url.scheme);
    url.scheme = try allocator.dupe(u8, b.scheme);
    try copyBaseAuthAndPath(allocator, url, b);
    url.query = if (b.query) |q| try allocator.dupe(u8, q) else null;
    url.fragment = if (b.fragment) |f| try allocator.dupe(u8, f) else null;
}

fn copyBaseAuthAndPath(allocator: Allocator, url: *Url, b: *const Url) !void {
    allocator.free(url.username);
    url.username = try allocator.dupe(u8, b.username);
    allocator.free(url.password);
    url.password = try allocator.dupe(u8, b.password);
    if (url.host) |h| host_mod.freeHost(allocator, h);
    url.host = if (b.host) |h| try cloneHost(allocator, h) else null;
    url.port = b.port;
    // Copy path
    switch (url.path) {
        .list => |*l| {
            for (l.items) |seg| allocator.free(seg);
            l.deinit(allocator);
        },
        .opaque_path => |p| allocator.free(p),
    }
    switch (b.path) {
        .list => |l| {
            var new_list: std.ArrayListUnmanaged([]u8) = .empty;
            for (l.items) |seg| {
                try new_list.append(allocator, try allocator.dupe(u8, seg));
            }
            url.path = .{ .list = new_list };
        },
        .opaque_path => |p| {
            url.path = .{ .opaque_path = try allocator.dupe(u8, p) };
        },
    }
}

fn cloneHost(allocator: Allocator, h: Host) !Host {
    return switch (h) {
        .domain => |d| Host{ .domain = try allocator.dupe(u8, d) },
        .ipv4 => |addr| Host{ .ipv4 = addr },
        .ipv6 => |addr| Host{ .ipv6 = addr },
        .opaque_host => |o| Host{ .opaque_host = try allocator.dupe(u8, o) },
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse absolute HTTP URL" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "http://example.com/path?q=1#frag", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host.?.domain);
    try std.testing.expect(url.port == null);
    try std.testing.expectEqualStrings("q=1", url.query.?);
    try std.testing.expectEqualStrings("frag", url.fragment.?);
    const href = try url.serialize(alloc, false);
    defer alloc.free(href);
    try std.testing.expectEqualStrings("http://example.com/path?q=1#frag", href);
}

test "parse HTTPS with port" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "https://example.com:8080/api", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("https", url.scheme);
    try std.testing.expectEqual(@as(u16, 8080), url.port.?);
}

test "parse default port omitted" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "http://example.com:80/", null)).?;
    defer url.deinit();
    try std.testing.expect(url.port == null); // 80 is default for http
}

test "parse with username and password" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "http://user:pass@example.com/", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("user", url.username);
    try std.testing.expectEqualStrings("pass", url.password);
}

test "parse data: URI (opaque path)" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "data:text/html,<h1>Hello</h1>", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("data", url.scheme);
    // Opaque path only percent-encodes C0 controls, not < > /
    try std.testing.expectEqualStrings("text/html,<h1>Hello</h1>", url.path.opaque_path);
}

test "parse relative URL with base" {
    const alloc = std.testing.allocator;
    var base_url = (try parse(alloc, "http://example.com/a/b/c", null)).?;
    defer base_url.deinit();
    var url = (try parse(alloc, "../d", &base_url)).?;
    defer url.deinit();
    const href = try url.serialize(alloc, false);
    defer alloc.free(href);
    try std.testing.expectEqualStrings("http://example.com/a/d", href);
}

test "parse fragment-only relative" {
    const alloc = std.testing.allocator;
    var base_url = (try parse(alloc, "http://example.com/page", null)).?;
    defer base_url.deinit();
    var url = (try parse(alloc, "#section", &base_url)).?;
    defer url.deinit();
    const href = try url.serialize(alloc, false);
    defer alloc.free(href);
    try std.testing.expectEqualStrings("http://example.com/page#section", href);
}

test "parse query-only relative" {
    const alloc = std.testing.allocator;
    var base_url = (try parse(alloc, "http://example.com/page", null)).?;
    defer base_url.deinit();
    var url = (try parse(alloc, "?foo=bar", &base_url)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("foo=bar", url.query.?);
}

test "parse failure returns null" {
    const alloc = std.testing.allocator;
    const result = try parse(alloc, "http://[::invalid", null);
    try std.testing.expect(result == null);
}

test "parse strips whitespace" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "  http://example.com  ", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("http", url.scheme);
}

test "parse file URL" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "file:///home/user/doc.html", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("file", url.scheme);
    try std.testing.expectEqualStrings("", url.host.?.domain);
}

test "serializeZ null-terminated" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "http://example.com/", null)).?;
    defer url.deinit();
    const href = try url.serializeZ(alloc);
    defer alloc.free(href);
    try std.testing.expectEqualStrings("http://example.com/", href);
    try std.testing.expectEqual(@as(u8, 0), href[href.len]);
}

test "parse non-special scheme" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "git://github.com/user/repo", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("git", url.scheme);
}

test "parse suzume:// internal" {
    const alloc = std.testing.allocator;
    var url = (try parse(alloc, "suzume://history", null)).?;
    defer url.deinit();
    try std.testing.expectEqualStrings("suzume", url.scheme);
}
