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

    pub fn init() !HttpClient {
        const global_rc = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        if (global_rc != c.CURLE_OK) return error.CurlGlobalInitFailed;

        const handle = c.curl_easy_init() orelse return error.CurlEasyInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *HttpClient) void {
        c.curl_easy_cleanup(self.handle);
        c.curl_global_cleanup();
    }

    pub fn get(self: *HttpClient, allocator: std.mem.Allocator, url: [:0]const u8) !Response {
        return self.getWithTimeout(allocator, url, 30);
    }

    /// GET with a custom timeout in seconds.
    pub fn getWithTimeout(self: *HttpClient, allocator: std.mem.Allocator, url: [:0]const u8, timeout_secs: c_long) !Response {
        var ctx = WriteContext{
            .buffer = .empty,
            .allocator = allocator,
        };
        errdefer ctx.buffer.deinit(allocator);

        // Reset handle for reuse
        c.curl_easy_reset(self.handle);

        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, @as(?*const fn ([*c]u8, usize, usize, *anyopaque) callconv(.c) usize, &writeCallback));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&ctx)));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT, timeout_secs);
        _ = c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, ua_string.ptr);

        var rc = c.curl_easy_perform(self.handle);

        // SSL CA cert verification failure — retry with peer verification disabled
        // but keep hostname verification (VERIFYHOST=2) to prevent MITM
        if (rc == c.CURLE_SSL_CACERT or rc == c.CURLE_PEER_FAILED_VERIFICATION or rc == c.CURLE_SSL_CERTPROBLEM) {
            std.log.warn("SSL certificate verification failed for {s}, retrying without CA verification", .{url});
            ctx.buffer.clearRetainingCapacity();
            c.curl_easy_reset(self.handle);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, @as(?*const fn ([*c]u8, usize, usize, *anyopaque) callconv(.c) usize, &writeCallback));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&ctx)));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT, timeout_secs);
            _ = c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, ua_string.ptr);
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

        const body = try ctx.buffer.toOwnedSlice(allocator);

        return Response{
            .status_code = @intCast(status_code),
            .body = body,
            .content_type = content_type,
            .allocator = allocator,
        };
    }
};
