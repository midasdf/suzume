const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("stdlib.h");
});

// 0 = uninitialized, 1 = initializing, 2 = ready, 3 = failed.
var curl_init_state = std.atomic.Value(u8).init(0);

fn initCurl() !void {
    if (curl_init_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        const rc = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        curl_init_state.store(if (rc == c.CURLE_OK) 2 else 3, .release);
    }
    while (curl_init_state.load(.acquire) == 1) std.atomic.spinLoopHint();
    if (curl_init_state.load(.acquire) != 2) return error.CurlGlobalInitFailed;
}

const ua_string = "Mozilla/5.0 (X11; Linux " ++ @tagName(builtin.cpu.arch) ++ ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

pub const Response = struct {
    status_code: u32,
    body: []u8,
    content_type: []const u8,
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        if (self.content_type.len > 0) {
            self.allocator.free(self.content_type);
        }
        if (self.etag.len > 0) {
            self.allocator.free(self.etag);
        }
        if (self.last_modified.len > 0) {
            self.allocator.free(self.last_modified);
        }
    }
};

/// Cache entry for conditional requests (ETag/Last-Modified).
const CacheEntry = struct {
    etag: []const u8,
    last_modified: []const u8,
    body: []u8,
    content_type: []const u8,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        if (self.etag.len > 0) allocator.free(self.etag);
        if (self.last_modified.len > 0) allocator.free(self.last_modified);
        allocator.free(self.body);
        if (self.content_type.len > 0) allocator.free(self.content_type);
    }
};

/// Context for capturing response headers.
const HeaderContext = struct {
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    cache_allowed: bool = true,
    received_cookie: bool = false,

    fn deinit(self: *HeaderContext) void {
        if (self.etag) |value| self.allocator.free(value);
        if (self.last_modified) |value| self.allocator.free(value);
        self.etag = null;
        self.last_modified = null;
    }
};

fn headerCallback(data: [*c]u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const total = size * nmemb;
    const ctx: *HeaderContext = @ptrCast(@alignCast(userdata));
    const line = data[0..total];

    // Redirects and interim responses must not contribute final-response metadata.
    if (std.mem.startsWith(u8, line, "HTTP/")) {
        ctx.deinit();
        ctx.cache_allowed = !ctx.received_cookie;
    }
    // Conservatively avoid caching responses whose representation depends on
    // request headers/cookies, or which explicitly prohibit storage.
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(name, "vary") or std.ascii.eqlIgnoreCase(name, "set-cookie")) {
            ctx.cache_allowed = false;
            if (std.ascii.eqlIgnoreCase(name, "set-cookie")) ctx.received_cookie = true;
        } else if (std.ascii.eqlIgnoreCase(name, "cache-control")) {
            var directives = std.mem.splitScalar(u8, value, ',');
            while (directives.next()) |directive| {
                const token = std.mem.trim(u8, directive, " \t");
                if (std.ascii.eqlIgnoreCase(token, "no-store")) ctx.cache_allowed = false;
            }
        }
    }

    // Parse "ETag: ..." header
    if (total > 6 and eqlIgnoreCaseN(line[0..5], "etag:")) {
        const val = std.mem.trim(u8, line[5..], " \t\r\n");
        if (val.len > 0) {
            if (ctx.etag) |old| ctx.allocator.free(old);
            ctx.etag = ctx.allocator.dupe(u8, val) catch null;
        }
    }
    // Parse "Last-Modified: ..." header
    if (total > 15 and eqlIgnoreCaseN(line[0..14], "last-modified:")) {
        const val = std.mem.trim(u8, line[14..], " \t\r\n");
        if (val.len > 0) {
            if (ctx.last_modified) |old| ctx.allocator.free(old);
            ctx.last_modified = ctx.allocator.dupe(u8, val) catch null;
        }
    }
    return total;
}

fn eqlIgnoreCaseN(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

const WriteContext = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};

fn writeCallback(data: [*c]u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const total = size * nmemb;
    const ctx: *WriteContext = @ptrCast(@alignCast(userdata));
    ctx.buffer.appendSlice(ctx.allocator, data[0..total]) catch return 0;
    return total;
}

pub const HttpClient = struct {
    handle: *c.CURL,
    cookie_file: ?[:0]const u8 = null,
    cache: std.StringHashMapUnmanaged(CacheEntry) = .{},
    cache_allocator: std.mem.Allocator = std.heap.c_allocator,

    pub fn init() !HttpClient {
        try initCurl();

        const handle = c.curl_easy_init() orelse return error.CurlEasyInitFailed;

        // Enable HTTP/2 with fallback to HTTP/1.1
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_2TLS));

        // Enable curl's in-memory cookie engine (handles Set-Cookie automatically)
        _ = c.curl_easy_setopt(handle, c.CURLOPT_COOKIEFILE, @as([*c]const u8, ""));

        return .{ .handle = handle };
    }

    /// Enable persistent cookie storage to a file.
    pub fn setCookieFile(self: *HttpClient, path: [:0]const u8) void {
        self.cookie_file = path;
        // Load existing cookies from file
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEFILE, path.ptr);
        // Save cookies to file on cleanup
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEJAR, path.ptr);
        // Load now so cache eligibility sees persisted cookies before transfer.
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIELIST, @as([*c]const u8, "RELOAD"));
    }

    /// Get all cookies for a given domain in "name=value; name2=value2" format.
    pub fn getCookiesForDomain(self: *HttpClient, allocator: std.mem.Allocator, domain: []const u8) ?[]u8 {
        // Flush cookies to the internal list
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIELIST, @as([*c]const u8, "FLUSH"));

        var cookie_list: ?*c.struct_curl_slist = null;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_COOKIELIST, &cookie_list);
        if (cookie_list == null) return null;
        defer c.curl_slist_free_all(cookie_list);

        // Build "name=value; name2=value2" string
        // Each cookie is in Netscape format: domain\tTAILMATCH\tpath\tsecure\texpiry\tname\tvalue
        var result: std.ArrayListUnmanaged(u8) = .empty;
        var cur = cookie_list;
        while (cur) |node| {
            const line = std.mem.span(node.data);
            // Parse tab-separated Netscape cookie format
            var fields: [7][]const u8 = undefined;
            var field_count: usize = 0;
            var start: usize = 0;
            for (line, 0..) |ch, i| {
                if (ch == '\t') {
                    if (field_count < 7) {
                        fields[field_count] = line[start..i];
                        field_count += 1;
                    }
                    start = i + 1;
                }
            }
            if (field_count < 7 and start < line.len) {
                fields[field_count] = line[start..];
                field_count += 1;
            }

            if (field_count >= 7) {
                const cookie_domain = fields[0];
                const name = fields[5];
                const value = fields[6];

                // Check domain match (simple: exact or suffix match)
                const domain_match = std.mem.eql(u8, cookie_domain, domain) or
                    (cookie_domain.len > 0 and cookie_domain[0] == '.' and
                        std.mem.endsWith(u8, domain, cookie_domain[1..]));

                if (domain_match) {
                    if (result.items.len > 0) {
                        result.appendSlice(allocator, "; ") catch continue;
                    }
                    result.appendSlice(allocator, name) catch continue;
                    result.append(allocator, '=') catch continue;
                    result.appendSlice(allocator, value) catch continue;
                }
            }
            cur = node.next;
        }

        if (result.items.len == 0) {
            result.deinit(allocator);
            return null;
        }
        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    /// Add a cookie via document.cookie format: "name=value; path=/; domain=.example.com"
    pub fn setJsCookie(self: *HttpClient, domain: []const u8, cookie_str: []const u8) void {
        // Parse name=value from the cookie string
        var name: []const u8 = "";
        var value: []const u8 = "";
        var path: []const u8 = "/";
        var cookie_domain: []const u8 = domain;
        const expiry: []const u8 = "0"; // session cookie

        // Split by ';' and parse attributes
        var iter = std.mem.splitScalar(u8, cookie_str, ';');
        var first = true;
        while (iter.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " ");
            if (first) {
                first = false;
                // First part is name=value
                if (std.mem.indexOf(u8, part, "=")) |eq| {
                    name = part[0..eq];
                    value = part[eq + 1 ..];
                } else {
                    name = part;
                }
            } else {
                // Cookie attributes
                if (std.mem.indexOf(u8, part, "=")) |eq| {
                    var lower_buf: [32]u8 = undefined;
                    const attr_len = @min(eq, 32);
                    const attr_name = std.ascii.lowerString(lower_buf[0..attr_len], part[0..attr_len]);
                    const attr_val = part[eq + 1 ..];
                    if (std.mem.eql(u8, attr_name, "path")) {
                        path = attr_val;
                    } else if (std.mem.eql(u8, attr_name, "domain")) {
                        cookie_domain = attr_val;
                    }
                }
            }
        }

        if (name.len == 0) return;

        // Build Netscape cookie format:
        // domain\tTAILMATCH\tpath\tsecure\texpiry\tname\tvalue
        const alloc = std.heap.c_allocator;
        const cookie_line = std.fmt.allocPrint(alloc, "{s}\tTRUE\t{s}\tFALSE\t{s}\t{s}\t{s}", .{
            cookie_domain, path, expiry, name, value,
        }) catch return;
        defer alloc.free(cookie_line);

        const cookie_z = alloc.allocSentinel(u8, cookie_line.len, 0) catch return;
        defer alloc.free(cookie_z);
        @memcpy(cookie_z, cookie_line);

        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIELIST, cookie_z.ptr);
    }

    /// Flush cookies to the cookie jar file (if set).
    pub fn flushCookies(self: *HttpClient) void {
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIELIST, @as([*c]const u8, "FLUSH"));
    }

    pub fn deinit(self: *HttpClient) void {
        self.flushCookies();
        c.curl_easy_cleanup(self.handle);
        self.clearCache();
        // Other clients (including image workers) may still be using libcurl.
        // Keep its process-wide state alive until process exit.
    }

    pub const max_cache_bytes = 8 * 1024 * 1024;
    pub const max_cache_entries = 128;

    fn removeCache(self: *HttpClient, url: []const u8) void {
        if (self.cache.fetchRemove(url)) |old| {
            var entry = old.value;
            entry.deinit(self.cache_allocator);
            self.cache_allocator.free(old.key);
        }
    }

    fn clearCache(self: *HttpClient) void {
        var it = self.cache.iterator();
        while (it.next()) |item| {
            item.value_ptr.deinit(self.cache_allocator);
            self.cache_allocator.free(item.key_ptr.*);
        }
        self.cache.deinit(self.cache_allocator);
        self.cache = .{};
    }

    fn cacheBytes(self: *HttpClient) usize {
        var total: usize = 0;
        var it = self.cache.iterator();
        while (it.next()) |item| {
            const entry = item.value_ptr;
            total += item.key_ptr.len + entry.body.len + entry.content_type.len + entry.etag.len + entry.last_modified.len;
        }
        return total;
    }

    fn storeCache(self: *HttpClient, url: []const u8, body: []const u8, ct: []const u8, etag: []const u8, lm: []const u8) !void {
        self.removeCache(url);
        const bytes = url.len + body.len + ct.len + etag.len + lm.len;
        if (bytes > max_cache_bytes) return;
        // Coarse eviction keeps bookkeeping small on 512 MB devices.
        if (self.cache.count() >= max_cache_entries or self.cacheBytes() > max_cache_bytes - bytes) {
            self.clearCache();
        }
        const ca = self.cache_allocator;
        const key = try ca.dupe(u8, url);
        errdefer ca.free(key);
        const cached_body = try ca.dupe(u8, body);
        errdefer ca.free(cached_body);
        const cached_ct = if (ct.len > 0) try ca.dupe(u8, ct) else "";
        errdefer if (cached_ct.len > 0) ca.free(cached_ct);
        const cached_etag = if (etag.len > 0) try ca.dupe(u8, etag) else "";
        errdefer if (cached_etag.len > 0) ca.free(cached_etag);
        const cached_lm = if (lm.len > 0) try ca.dupe(u8, lm) else "";
        errdefer if (cached_lm.len > 0) ca.free(cached_lm);
        try self.cache.put(ca, key, .{
            .body = cached_body,
            .content_type = cached_ct,
            .etag = cached_etag,
            .last_modified = cached_lm,
        });
    }

    pub fn get(self: *HttpClient, allocator: std.mem.Allocator, url: [:0]const u8) !Response {
        return self.getWithTimeout(allocator, url, 30);
    }

    /// GET with a custom timeout in seconds.
    pub fn getWithTimeout(self: *HttpClient, allocator: std.mem.Allocator, url: [:0]const u8, timeout_secs: c_long) !Response {
        return self.request(allocator, url, .{ .timeout_secs = timeout_secs });
    }

    pub const RequestOptions = struct {
        method: ?[:0]const u8 = null, // null = GET
        body: ?[]const u8 = null,
        headers: ?[][2][]const u8 = null,
        timeout_secs: c_long = 30,
    };

    /// General HTTP request with method/body/headers support.
    pub fn request(self: *HttpClient, allocator: std.mem.Allocator, url: [:0]const u8, opts: RequestOptions) !Response {
        var wctx = WriteContext{
            .buffer = .empty,
            .allocator = allocator,
        };
        errdefer wctx.buffer.deinit(allocator);

        // Header capture context
        var hdr_ctx = HeaderContext{ .allocator = allocator };
        defer hdr_ctx.deinit();

        // Reset handle for reuse
        c.curl_easy_reset(self.handle);

        self.setCommonOpts(url, &wctx, opts.timeout_secs);

        // Set header callback to capture ETag/Last-Modified
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HEADERFUNCTION, @as(?*const fn ([*c]u8, usize, usize, *anyopaque) callconv(.c) usize, &headerCallback));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&hdr_ctx)));

        // Set method and body
        if (opts.method) |method| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, method.ptr);
        }
        if (opts.body) |body| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, body.ptr);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        }

        // Set custom headers + conditional cache headers
        var header_list: ?*c.struct_curl_slist = null;
        defer if (header_list) |hl| c.curl_slist_free_all(hl);

        if (opts.headers) |headers| {
            for (headers) |hdr| {
                const header_str = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ hdr[0], hdr[1] });
                defer allocator.free(header_str);
                const header_z = try allocator.allocSentinel(u8, header_str.len, 0);
                defer allocator.free(header_z);
                @memcpy(header_z, header_str);
                header_list = c.curl_slist_append(header_list, header_z.ptr) orelse return error.OutOfMemory;
            }
        }

        // Add conditional headers from cache (only for GET requests)
        const is_get = (opts.method == null or std.ascii.eqlIgnoreCase(opts.method.?, "GET")) and opts.body == null;
        // URL-only cache keys cannot safely represent authenticated/custom requests.
        var cookies: ?*c.struct_curl_slist = null;
        const cookie_rc = c.curl_easy_getinfo(self.handle, c.CURLINFO_COOKIELIST, &cookies);
        const cacheable_request = is_get and opts.headers == null and cookie_rc == c.CURLE_OK and cookies == null;
        c.curl_slist_free_all(cookies);
        if (cacheable_request) {
            if (self.cache.get(url)) |cached| {
                if (cached.etag.len > 0) {
                    const h = allocator.allocSentinel(u8, "If-None-Match: ".len + cached.etag.len, 0) catch null;
                    if (h) |hz| {
                        defer allocator.free(hz);
                        @memcpy(hz[0.."If-None-Match: ".len], "If-None-Match: ");
                        @memcpy(hz["If-None-Match: ".len..], cached.etag);
                        header_list = c.curl_slist_append(header_list, hz.ptr) orelse return error.OutOfMemory;
                    }
                }
                if (cached.last_modified.len > 0) {
                    const h = allocator.allocSentinel(u8, "If-Modified-Since: ".len + cached.last_modified.len, 0) catch null;
                    if (h) |hz| {
                        defer allocator.free(hz);
                        @memcpy(hz[0.."If-Modified-Since: ".len], "If-Modified-Since: ");
                        @memcpy(hz["If-Modified-Since: ".len..], cached.last_modified);
                        header_list = c.curl_slist_append(header_list, hz.ptr) orelse return error.OutOfMemory;
                    }
                }
            }
        }

        if (header_list) |hl| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, hl);
        }

        const rc = c.curl_easy_perform(self.handle);
        if (rc == c.CURLE_PEER_FAILED_VERIFICATION or rc == c.CURLE_SSL_CERTPROBLEM) {
            return error.CertificateVerificationFailed;
        }

        if (rc != c.CURLE_OK) {
            return error.CurlPerformFailed;
        }

        var status_code: c_long = 0;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_code);

        // Handle 304 Not Modified — return cached body
        if (status_code == 304 and cacheable_request) {
            if (self.cache.get(url)) |cached| {
                const body_copy = try allocator.dupe(u8, cached.body);
                errdefer allocator.free(body_copy);
                const ct_copy = if (cached.content_type.len > 0) try allocator.dupe(u8, cached.content_type) else @as([]const u8, "");
                wctx.buffer.deinit(allocator);
                if (!hdr_ctx.cache_allowed) self.removeCache(url);
                return Response{
                    .status_code = 200, // Present as 200 to callers
                    .body = body_copy,
                    .content_type = ct_copy,
                    .allocator = allocator,
                };
            }
        }

        // Get content type
        var ct_ptr: [*c]const u8 = null;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_CONTENT_TYPE, &ct_ptr);
        var content_type: []const u8 = "";
        if (ct_ptr != null) {
            const ct_slice = std.mem.span(ct_ptr);
            const ct_owned = try allocator.alloc(u8, ct_slice.len);
            @memcpy(ct_owned, ct_slice);
            content_type = ct_owned;
        }

        errdefer if (content_type.len > 0) allocator.free(content_type);
        const body = try wctx.buffer.toOwnedSlice(allocator);

        // Store in cache if response has ETag or Last-Modified (only for GET 200)
        if (cacheable_request and status_code == 200 and hdr_ctx.cache_allowed and
            (hdr_ctx.etag != null or hdr_ctx.last_modified != null))
        {
            self.storeCache(url, body, content_type, hdr_ctx.etag orelse "", hdr_ctx.last_modified orelse "") catch {};
        } else if (status_code != 304) {
            self.removeCache(url);
        }

        // Transfer captured headers to response
        const resp_etag = hdr_ctx.etag orelse "";
        const resp_lm = hdr_ctx.last_modified orelse "";
        hdr_ctx.etag = null;
        hdr_ctx.last_modified = null;

        return Response{
            .status_code = @intCast(status_code),
            .body = body,
            .content_type = content_type,
            .etag = resp_etag,
            .last_modified = resp_lm,
            .allocator = allocator,
        };
    }

    fn setCommonOpts(self: *HttpClient, url: [:0]const u8, wctx: *WriteContext, timeout_secs: c_long) void {
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, @as(?*const fn ([*c]u8, usize, usize, *anyopaque) callconv(.c) usize, &writeCallback));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(wctx)));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_2TLS));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_ACCEPT_ENCODING, @as([*c]const u8, ""));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_MAXREDIRS, @as(c_long, 20));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*c]const u8, "http,https"));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT, timeout_secs);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, ua_string.ptr);
        // Re-enable cookie engine after reset (reset clears all options)
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEFILE, @as([*c]const u8, ""));
        if (self.cookie_file) |cf| {
            // reset retains the in-memory cookie engine. Do not re-read the jar
            // on every resource fetch (which can resurrect stale cookie values).
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEJAR, cf.ptr);
        }
    }
};

fn testHeader(ctx: *HeaderContext, line: []const u8) void {
    const consumed = headerCallback(@constCast(line.ptr), 1, line.len, ctx);
    std.debug.assert(consumed == line.len);
}

test "response headers replace duplicates and reset across redirects" {
    var ctx = HeaderContext{ .allocator = std.testing.allocator };
    defer ctx.deinit();
    testHeader(&ctx, "HTTP/1.1 302 Found\r\n");
    testHeader(&ctx, "ETag: old\r\n");
    testHeader(&ctx, "ETag: newer\r\n");
    testHeader(&ctx, "Last-Modified: yesterday\r\n");
    testHeader(&ctx, "Cache-Control: no-store\r\n");
    try std.testing.expectEqualStrings("newer", ctx.etag.?);
    testHeader(&ctx, "HTTP/2 200\r\n");
    try std.testing.expect(ctx.etag == null and ctx.last_modified == null);
    try std.testing.expect(ctx.cache_allowed);
    testHeader(&ctx, "Last-Modified: today\r\n");
    testHeader(&ctx, "Last-Modified: tomorrow\r\n");
    try std.testing.expectEqualStrings("tomorrow", ctx.last_modified.?);
}

test "cache refuses no-store, varying and cookie responses" {
    const lines = [_][]const u8{
        "Cache-Control: public, NO-STORE\r\n",
        "Vary: Accept-Language\r\n",
        "Set-Cookie: session=secret\r\n",
    };
    for (lines) |line| {
        var ctx = HeaderContext{ .allocator = std.testing.allocator };
        defer ctx.deinit();
        testHeader(&ctx, line);
        try std.testing.expect(!ctx.cache_allowed);
    }
    var redirect = HeaderContext{ .allocator = std.testing.allocator };
    defer redirect.deinit();
    testHeader(&redirect, "HTTP/1.1 302 Found\r\n");
    testHeader(&redirect, "Set-Cookie: session=secret\r\n");
    testHeader(&redirect, "HTTP/2 200\r\n");
    try std.testing.expect(!redirect.cache_allowed);
}

test "cache owns copies, replaces entries and releases all memory" {
    var client = HttpClient{ .handle = undefined, .cache_allocator = std.testing.allocator };
    defer client.clearCache();
    try client.storeCache("https://example.com", "first", "text/html", "v1", "");
    try client.storeCache("https://example.com", "second", "text/plain", "v2", "today");
    try std.testing.expectEqual(@as(u32, 1), client.cache.count());
    try std.testing.expectEqualStrings("second", client.cache.get("https://example.com").?.body);
    client.removeCache("https://example.com");
    try std.testing.expectEqual(@as(usize, 0), client.cacheBytes());
}

test "cache enforces byte and entry budgets" {
    var client = HttpClient{ .handle = undefined, .cache_allocator = std.testing.allocator };
    defer client.clearCache();
    for (0..HttpClient.max_cache_entries + 1) |i| {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "url-{d}", .{i});
        try client.storeCache(key, "body", "", "tag", "");
        try std.testing.expect(client.cache.count() <= HttpClient.max_cache_entries);
    }
    const large = try std.testing.allocator.alloc(u8, HttpClient.max_cache_bytes / 2);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try client.storeCache("a", large, "", "tag", "");
    try client.storeCache("b", large, "", "tag", "");
    try std.testing.expect(client.cacheBytes() <= HttpClient.max_cache_bytes);
    try std.testing.expect(client.cache.get("a") == null);
    const oversized = try std.testing.allocator.alloc(u8, HttpClient.max_cache_bytes);
    defer std.testing.allocator.free(oversized);
    try client.storeCache("b", oversized, "", "tag", "");
    try std.testing.expect(client.cache.get("b") == null);
}

fn testCacheAllocation(allocator: std.mem.Allocator) !void {
    var client = HttpClient{ .handle = undefined, .cache_allocator = allocator };
    defer client.clearCache();
    try client.storeCache("url", "body", "text/plain", "tag", "today");
}

test "cache rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCacheAllocation, .{});
}

test "local HTTP integration: compression, revalidation, redirects, POST, TLS" {
    const origin_ptr = c.getenv("SUZUME_TEST_ORIGIN");
    if (origin_ptr == null) return error.SkipZigTest;
    const origin = std.mem.span(origin_ptr);
    const allocator = std.testing.allocator;
    var client = try HttpClient.init();
    client.cache_allocator = allocator;
    defer client.deinit();
    const routes = [_][]const u8{ "/gzip", "/etag", "/etag", "/redirect", "/no-store", "/vary", "/cookie", "/etag" };
    var cookie_seen = false;
    for (routes) |route| {
        const url = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ origin, route }, 0);
        defer allocator.free(url);
        var response = try client.get(allocator, url);
        defer response.deinit();
        try std.testing.expectEqual(@as(u32, 200), response.status_code);
        try std.testing.expectEqualStrings("hello browser", response.body);
        if (std.mem.eql(u8, route, "/cookie")) cookie_seen = true;
        if (cookie_seen or std.mem.eql(u8, route, "/redirect") or std.mem.eql(u8, route, "/no-store") or std.mem.eql(u8, route, "/vary")) {
            try std.testing.expect(client.cache.get(url) == null);
        }
    }
    const post_url = try std.fmt.allocPrintSentinel(allocator, "{s}/echo", .{origin}, 0);
    defer allocator.free(post_url);
    var posted = try client.request(allocator, post_url, .{ .method = "POST", .body = "a\x00b" });
    defer posted.deinit();
    try std.testing.expectEqualStrings("a\x00b", posted.body);
    const tls_ptr = c.getenv("SUZUME_TEST_TLS_URL");
    if (tls_ptr == null) return error.SkipZigTest;
    const tls_url = std.mem.span(tls_ptr);
    const tls_z = try allocator.dupeZ(u8, tls_url);
    defer allocator.free(tls_z);
    try std.testing.expectError(error.CertificateVerificationFailed, client.get(allocator, tls_z));
}
