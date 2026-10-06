const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("curl/websockets.h");
    @cInclude("stdlib.h");
});

const ua_string = "suzume/1.0";

pub const WsMessage = struct {
    data: []u8,
    is_text: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WsMessage) void {
        self.allocator.free(self.data);
    }
};

pub const WsState = enum {
    connecting,
    open,
    closing,
    closed,
};

pub const WebSocket = struct {
    handle: *c.CURL,
    state: WsState = .connecting,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, url: [:0]const u8) !WebSocket {
        if (!std.ascii.startsWithIgnoreCase(url, "ws://") and
            !std.ascii.startsWithIgnoreCase(url, "wss://")) return error.InvalidWebSocketScheme;
        try @import("http.zig").initCurl();
        const handle = c.curl_easy_init() orelse return error.CurlInitFailed;
        errdefer c.curl_easy_cleanup(handle);

        _ = c.curl_easy_setopt(handle, c.CURLOPT_PROTOCOLS_STR, @as([*c]const u8, "ws,wss"));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_USERAGENT, @as([*c]const u8, ua_string));
        // CONNECT_ONLY=2 enables WebSocket upgrade
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 10));

        const rc = c.curl_easy_perform(handle);
        if (rc == c.CURLE_PEER_FAILED_VERIFICATION or rc == c.CURLE_SSL_CERTPROBLEM)
            return error.CertificateVerificationFailed;
        if (rc != c.CURLE_OK) return error.WsConnectFailed;

        return WebSocket{
            .handle = handle,
            .state = .open,
            .allocator = allocator,
        };
    }

    /// Send a text message.
    pub fn sendText(self: *WebSocket, data: []const u8) !void {
        if (self.state != .open) return error.WsNotOpen;
        var sent: usize = 0;
        const rc = c.curl_ws_send(self.handle, data.ptr, data.len, &sent, 0, c.CURLWS_TEXT);
        if (rc != c.CURLE_OK or sent != data.len) return error.WsSendFailed;
    }

    /// Send a binary message.
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        if (self.state != .open) return error.WsNotOpen;
        var sent: usize = 0;
        const rc = c.curl_ws_send(self.handle, data.ptr, data.len, &sent, 0, c.CURLWS_BINARY);
        if (rc != c.CURLE_OK or sent != data.len) return error.WsSendFailed;
    }

    /// Send a close frame.
    pub fn close(self: *WebSocket) void {
        if (self.state == .open or self.state == .connecting) {
            var sent: usize = 0;
            _ = c.curl_ws_send(self.handle, "", 0, &sent, 0, c.CURLWS_CLOSE);
            self.state = .closing;
        }
    }

    /// Try to receive a message (non-blocking). Returns null if no data available.
    pub fn recv(self: *WebSocket) ?WsMessage {
        if (self.state != .open) return null;

        var buf: [65536]u8 = undefined;
        var nread: usize = 0;
        var frame_meta: [*c]const c.struct_curl_ws_frame = null;
        // curl_ws_recv requires a metadata output pointer, even if the caller
        // only wants the payload. curl_ws_meta is for callback-mode receives.
        const rc = c.curl_ws_recv(self.handle, &buf, buf.len, &nread, &frame_meta);

        if (rc == c.CURLE_AGAIN) {
            // No data available (non-blocking)
            return null;
        }
        if (rc != c.CURLE_OK) {
            // Connection closed or error
            self.state = .closed;
            return null;
        }
        const is_text = frame_meta != null and (frame_meta.*.flags & c.CURLWS_TEXT) != 0;
        const is_close = frame_meta != null and (frame_meta.*.flags & c.CURLWS_CLOSE) != 0;

        if (is_close) {
            self.state = .closed;
            return null;
        }
        if (nread == 0) return null;

        const data = self.allocator.alloc(u8, nread) catch return null;
        @memcpy(data, buf[0..nread]);

        return WsMessage{
            .data = data,
            .is_text = is_text,
            .allocator = self.allocator,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        if (self.state == .open) self.close();
        c.curl_easy_cleanup(self.handle);
        self.state = .closed;
    }
};

fn requireWebSocketSupport() !void {
    try @import("http.zig").initCurl();
    const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.SkipZigTest;
    var index: usize = 0;
    var ws = false;
    var wss = false;
    while (info.*.protocols[index] != null) : (index += 1) {
        const protocol = std.mem.span(info.*.protocols[index]);
        ws = ws or std.mem.eql(u8, protocol, "ws");
        wss = wss or std.mem.eql(u8, protocol, "wss");
    }
    if (!ws or !wss) return error.SkipZigTest;
}

test "WebSocket refuses non-WebSocket schemes before connecting" {
    try std.testing.expectError(error.InvalidWebSocketScheme, WebSocket.connect(std.testing.allocator, "https://example.com"));
    try std.testing.expectError(error.InvalidWebSocketScheme, WebSocket.connect(std.testing.allocator, "file:///etc/passwd"));
}

test "local WebSocket receives text with required frame metadata" {
    const url = c.getenv("SUZUME_TEST_WS_URL");
    if (url == null) return error.SkipZigTest;
    try requireWebSocketSupport();
    var ws = try WebSocket.connect(std.testing.allocator, std.mem.span(url));
    defer ws.deinit();
    for (0..100) |_| {
        if (ws.recv()) |message| {
            var owned = message;
            defer owned.deinit();
            try std.testing.expect(owned.is_text);
            try std.testing.expectEqualStrings("hello", owned.data);
            return;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.MissingWebSocketMessage;
}

test "local WSS rejects a self-signed certificate without insecure retry" {
    const url = c.getenv("SUZUME_TEST_WSS_URL");
    if (url == null) return error.SkipZigTest;
    try requireWebSocketSupport();
    var ws = WebSocket.connect(std.testing.allocator, std.mem.span(url)) catch |err| {
        try std.testing.expectEqual(error.CertificateVerificationFailed, err);
        return;
    };
    defer ws.deinit();
    return error.UntrustedWebSocketAccepted;
}
