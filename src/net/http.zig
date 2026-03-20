const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("curl/curl.h");
});

const ua_string = "suzume/1.0 (Linux; " ++ @tagName(builtin.cpu.arch) ++ ")";

pub const Response = struct {
    status_code: u32,
    body: []u8,
    content_type: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        if (self.content_type.len > 0) {
            self.allocator.free(self.content_type);
        }
    }
};

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

    pub fn init() !HttpClient {
        const global_rc = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        if (global_rc != c.CURLE_OK) return error.CurlGlobalInitFailed;

        const handle = c.curl_easy_init() orelse return error.CurlEasyInitFailed;

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
        c.curl_global_cleanup();
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

        // Reset handle for reuse
        c.curl_easy_reset(self.handle);

        self.setCommonOpts(url, &wctx, opts.timeout_secs, true);

        // Set method and body
        if (opts.method) |method| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, method.ptr);
        }
        if (opts.body) |body| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, body.ptr);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        }

        // Set custom headers
        var header_list: ?*c.struct_curl_slist = null;
        defer if (header_list) |hl| c.curl_slist_free_all(hl);

        if (opts.headers) |headers| {
            for (headers) |hdr| {
                // Format: "Name: Value"
                const header_str = std.fmt.allocPrint(allocator, "{s}: {s}", .{ hdr[0], hdr[1] }) catch continue;
                defer allocator.free(header_str);
                // Need null-terminated for curl
                const header_z = allocator.allocSentinel(u8, header_str.len, 0) catch {
                    continue;
                };
                defer allocator.free(header_z);
                @memcpy(header_z, header_str);
                header_list = c.curl_slist_append(header_list, header_z.ptr);
            }
            if (header_list) |hl| {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, hl);
            }
        }

        var rc = c.curl_easy_perform(self.handle);

        // SSL CA cert verification failure — retry with peer verification disabled
        if (rc == c.CURLE_SSL_CACERT or rc == c.CURLE_PEER_FAILED_VERIFICATION or rc == c.CURLE_SSL_CERTPROBLEM) {
            std.log.warn("SSL certificate verification failed for {s}, retrying without CA verification", .{url});
            wctx.buffer.clearRetainingCapacity();
            c.curl_easy_reset(self.handle);
            self.setCommonOpts(url, &wctx, opts.timeout_secs, false);
            if (opts.method) |method| {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, method.ptr);
            }
            if (opts.body) |body| {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, body.ptr);
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
            }
            if (header_list) |hl| {
                _ = c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, hl);
            }
            rc = c.curl_easy_perform(self.handle);
        }

        if (rc != c.CURLE_OK) {
            return error.CurlPerformFailed;
        }

        var status_code: c_long = 0;
        _ = c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_code);

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

        const body = try wctx.buffer.toOwnedSlice(allocator);

        return Response{
            .status_code = @intCast(status_code),
            .body = body,
            .content_type = content_type,
            .allocator = allocator,
        };
    }

    fn setCommonOpts(self: *HttpClient, url: [:0]const u8, wctx: *WriteContext, timeout_secs: c_long, verify_peer: bool) void {
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, @as(?*const fn ([*c]u8, usize, usize, *anyopaque) callconv(.c) usize, &writeCallback));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(wctx)));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, if (verify_peer) 1 else 0));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT, timeout_secs);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, ua_string.ptr);
        // Re-enable cookie engine after reset (reset clears all options)
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEFILE, @as([*c]const u8, ""));
        if (self.cookie_file) |cf| {
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEFILE, cf.ptr);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_COOKIEJAR, cf.ptr);
        }
    }
};
