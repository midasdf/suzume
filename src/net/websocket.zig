const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("curl/websockets.h");
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
        const handle = c.curl_easy_init() orelse return error.CurlInitFailed;

        _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_USERAGENT, @as([*c]const u8, ua_string));
        // CONNECT_ONLY=2 enables WebSocket upgrade
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 10));

        const rc = c.curl_easy_perform(handle);
        if (rc != c.CURLE_OK) {
            // Try without SSL peer verification
            if (rc == c.CURLE_SSL_CACERT or rc == c.CURLE_PEER_FAILED_VERIFICATION or rc == c.CURLE_SSL_CERTPROBLEM) {
                _ = c.curl_easy_setopt(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0));
                const rc2 = c.curl_easy_perform(handle);
                if (rc2 != c.CURLE_OK) {
                    c.curl_easy_cleanup(handle);
                    return error.WsConnectFailed;
                }
            } else {
                c.curl_easy_cleanup(handle);
                return error.WsConnectFailed;
            }
        }

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
        if (rc != c.CURLE_OK) return error.WsSendFailed;
    }

    /// Send a binary message.
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        if (self.state != .open) return error.WsNotOpen;
        var sent: usize = 0;
        const rc = c.curl_ws_send(self.handle, data.ptr, data.len, &sent, 0, c.CURLWS_BINARY);
        if (rc != c.CURLE_OK) return error.WsSendFailed;
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
        const meta: ?*const c.struct_curl_ws_frame = null;
        _ = meta;

        const rc = c.curl_ws_recv(self.handle, &buf, buf.len, &nread, null);

        if (rc == c.CURLE_AGAIN) {
            // No data available (non-blocking)
            return null;
        }
        if (rc != c.CURLE_OK) {
            // Connection closed or error
            self.state = .closed;
            return null;
        }
        if (nread == 0) return null;

        // Check frame metadata
        const frame_meta: ?*const c.struct_curl_ws_frame = c.curl_ws_meta(self.handle);
        const is_text = if (frame_meta) |fm| (fm.*.flags & c.CURLWS_TEXT) != 0 else true;
        const is_close = if (frame_meta) |fm| (fm.*.flags & c.CURLWS_CLOSE) != 0 else false;

        if (is_close) {
            self.state = .closed;
            return null;
        }

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
