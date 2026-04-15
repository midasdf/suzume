const std = @import("std");
const net = std.net;
const http = std.http;
const sync = @import("../sync.zig");

// ── WebDriver Command Queue ─────────────────────────────────────────

pub const CommandTag = enum {
    navigate,
    get_url,
    execute_sync,
    execute_async,
    screenshot,
    get_title,
    close_window,
    window_new,
    window_switch,
    window_close,
    get_window_handle,
    get_window_handles,
    noop, // for stub endpoints that need main-thread ack
};

pub const Command = struct {
    tag: CommandTag,
    /// JSON payload or URL string (owned by caller, valid until response)
    payload: []const u8 = "",
    /// Second payload for execute (args JSON)
    payload2: []const u8 = "",
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "", // JSON string, caller must free if allocated
    allocated: bool = false, // if true, body was allocated and must be freed
};

/// Thread-safe command slot for main loop ↔ WebDriver communication.
/// WebDriver thread writes command, signals pending, waits for done.
/// Main thread reads command, executes, writes response, signals done.
pub const CommandSlot = struct {
    command: Command = .{ .tag = .noop },
    response: Response = .{},
    pending: sync.ResetEvent = .{},
    done: sync.ResetEvent = .{},
    mutex: sync.Mutex = .{},

    pub fn submitAndWait(self: *CommandSlot, cmd: Command, timeout_ms: u64) Response {
        self.mutex.lock();
        self.command = cmd;
        self.response = .{ .status = 408, .body = "{\"value\":{\"error\":\"timeout\",\"message\":\"command timed out\",\"stacktrace\":\"\"}}" };
        self.done.reset();
        self.pending.set();
        self.mutex.unlock();

        // Wait for main thread to process
        self.done.timedWait(timeout_ms * std.time.ns_per_ms) catch {
            // Timeout — return the pre-set timeout response
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.response;
        };
        self.mutex.lock();
        const resp = self.response;
        self.mutex.unlock();
        return resp;
    }

    /// Called by main thread: check if there's a pending command.
    pub fn poll(self: *CommandSlot) ?Command {
        if (!self.pending.isSet()) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending.reset();
        return self.command;
    }

    /// Called by main thread: send response back to WebDriver thread.
    pub fn respond(self: *CommandSlot, resp: Response) void {
        self.mutex.lock();
        self.response = resp;
        self.mutex.unlock();
        self.done.set();
    }
};

// ── Session State ───────────────────────────────────────────────────

const Session = struct {
    id: []const u8 = "suzume-session-1",
    active: bool = false,
    script_timeout_ms: u64 = 30000,
    page_load_timeout_ms: u64 = 300000,
    implicit_wait_ms: u64 = 0,
    window_handles: [2][]const u8 = .{ "window-0", "window-1" },
    num_windows: u8 = 1,
    active_window: u8 = 0,
};

// ── WebDriver Server ────────────────────────────────────────────────

pub const WebDriverServer = struct {
    port: u16,
    slot: *CommandSlot,
    allocator: std.mem.Allocator,
    session: Session = .{},
    thread: ?std.Thread = null,
    scratch_buf: [512]u8 = undefined, // persistent buffer for getTimeouts etc.

    pub fn init(allocator: std.mem.Allocator, port: u16, slot: *CommandSlot) WebDriverServer {
        return .{
            .port = port,
            .slot = slot,
            .allocator = allocator,
        };
    }

    pub fn start(self: *WebDriverServer) !void {
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    pub fn stop(self: *WebDriverServer) void {
        // Server loop will exit when the process exits
        _ = self;
    }

    fn serverLoop(self: *WebDriverServer) void {
        const address = net.Address.parseIp4("127.0.0.1", self.port) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        std.debug.print("[WebDriver] Listening on 127.0.0.1:{d}\n", .{self.port});

        while (true) {
            const conn = server.accept() catch continue;
            self.handleConnection(conn) catch |e| {
                std.debug.print("[WebDriver] Connection error: {}\n", .{e});
            };
        }
    }

    fn handleConnection(self: *WebDriverServer, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var recv_buf: [65536]u8 = undefined;

        // Handle multiple requests on same connection (keep-alive)
        while (true) {
            // Read HTTP request headers
            var total_read: usize = 0;
            var header_end: ?usize = null;
            while (total_read < recv_buf.len) {
                const n = conn.stream.read(recv_buf[total_read..]) catch return;
                if (n == 0) return; // connection closed
                total_read += n;
                // Search for \r\n\r\n
                if (total_read >= 4) {
                    var k: usize = if (total_read > n + 3) total_read - n - 3 else 0;
                    while (k + 3 < total_read) : (k += 1) {
                        if (std.mem.eql(u8, recv_buf[k..][0..4], "\r\n\r\n")) {
                            header_end = k + 4;
                            break;
                        }
                    }
                    if (header_end != null) break;
                }
            }
            const hdr_end = header_end orelse return;

            // Parse method and path from first line: "METHOD /path HTTP/1.1\r\n"
            const first_line_end = std.mem.indexOf(u8, recv_buf[0..hdr_end], "\r\n") orelse return;
            const first_line = recv_buf[0..first_line_end];
            const method_end = std.mem.indexOf(u8, first_line, " ") orelse return;
            const method_str = first_line[0..method_end];
            const path_start = method_end + 1;
            const path_end = std.mem.indexOf(u8, first_line[path_start..], " ") orelse return;
            const path = first_line[path_start..][0..path_end];
            const method = parseMethod(method_str);

            // Parse Content-Length
            var content_length: usize = 0;
            var search: usize = 0;
            while (search + 16 < hdr_end) : (search += 1) {
                if (std.ascii.eqlIgnoreCase(recv_buf[search..][0..16], "content-length: ")) {
                    const cl_start = search + 16;
                    var cl_end = cl_start;
                    while (cl_end < hdr_end and recv_buf[cl_end] >= '0' and recv_buf[cl_end] <= '9') cl_end += 1;
                    content_length = std.fmt.parseInt(usize, recv_buf[cl_start..cl_end], 10) catch 0;
                    break;
                }
            }

            // Read remaining body if needed
            while (total_read - hdr_end < content_length and total_read < recv_buf.len) {
                const n = conn.stream.read(recv_buf[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }

            const body = if (content_length > 0 and hdr_end + content_length <= total_read)
                recv_buf[hdr_end..][0..content_length]
            else
                recv_buf[hdr_end..hdr_end]; // empty body

            // Dispatch and respond
            const resp = self.dispatch(method, path, body);
            defer if (resp.allocated) self.allocator.free(@constCast(resp.body));

            // Build HTTP response
            var resp_hdr: [512]u8 = undefined;
            const status_text = if (resp.status == 200) "OK" else "Error";
            const hdr = std.fmt.bufPrint(
                &resp_hdr,
                "HTTP/1.1 {d} {s}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
                .{ resp.status, status_text, resp.body.len },
            ) catch return;

            _ = conn.stream.write(hdr) catch return;
            if (resp.body.len > 0) {
                _ = conn.stream.write(resp.body) catch return;
            }
        }
    }

    fn parseMethod(s: []const u8) http.Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        return .GET;
    }

    fn dispatch(self: *WebDriverServer, method: http.Method, path: []const u8, body: []const u8) Response {
        // GET /status
        if (method == .GET and std.mem.eql(u8, path, "/status")) {
            return ok("{\"value\":{\"ready\":true,\"message\":\"suzume WebDriver\"}}");
        }

        // POST /session
        if (method == .POST and std.mem.eql(u8, path, "/session")) {
            return self.createSession(body);
        }

        // All other endpoints require /session/{id}/...
        if (!std.mem.startsWith(u8, path, "/session/")) {
            return self.err(404, "unknown command", "No route for path");
        }

        // Extract session ID and sub-path
        const after_session = path["/session/".len..];
        const slash_pos = std.mem.indexOf(u8, after_session, "/");
        const session_id = if (slash_pos) |p| after_session[0..p] else after_session;
        const sub_path = if (slash_pos) |p| after_session[p..] else "";

        if (!self.session.active or !std.mem.eql(u8, session_id, self.session.id)) {
            return self.err(404, "invalid session id", "No such session");
        }

        // DELETE /session/{id}
        if (method == .DELETE and sub_path.len == 0) {
            return self.deleteSession();
        }

        // Route sub-paths
        return self.routeSession(method, sub_path, body);
    }

    fn routeSession(self: *WebDriverServer, method: http.Method, path: []const u8, body: []const u8) Response {
        // POST /url
        if (method == .POST and std.mem.eql(u8, path, "/url")) {
            return self.navigate(body);
        }
        // GET /url
        if (method == .GET and std.mem.eql(u8, path, "/url")) {
            return self.getUrl();
        }
        // GET /title
        if (method == .GET and std.mem.eql(u8, path, "/title")) {
            return self.getTitle();
        }
        // POST /execute/sync
        if (method == .POST and std.mem.eql(u8, path, "/execute/sync")) {
            return self.executeSync(body);
        }
        // POST /execute/async
        if (method == .POST and std.mem.eql(u8, path, "/execute/async")) {
            return self.executeAsync(body);
        }
        // GET /screenshot
        if (method == .GET and std.mem.eql(u8, path, "/screenshot")) {
            return self.screenshot();
        }
        // GET /window
        if (method == .GET and std.mem.eql(u8, path, "/window")) {
            return self.getWindowHandle();
        }
        // POST /window (switch)
        if (method == .POST and std.mem.eql(u8, path, "/window")) {
            const handle = extractJsonString(body, "handle") orelse return ok("{\"value\":null}");
            return self.slot.submitAndWait(.{ .tag = .window_switch, .payload = handle }, 5000);
        }
        // GET /window/handles
        if (method == .GET and std.mem.eql(u8, path, "/window/handles")) {
            return self.getWindowHandles();
        }
        // POST /window/new
        if (method == .POST and std.mem.eql(u8, path, "/window/new")) {
            return self.newWindow();
        }
        // DELETE /window
        if (method == .DELETE and std.mem.eql(u8, path, "/window")) {
            return self.closeWindow();
        }
        // GET /window/rect
        if (method == .GET and std.mem.eql(u8, path, "/window/rect")) {
            return ok("{\"value\":{\"x\":0,\"y\":0,\"width\":800,\"height\":600}}");
        }
        // POST /window/rect
        if (method == .POST and std.mem.eql(u8, path, "/window/rect")) {
            return ok("{\"value\":{\"x\":0,\"y\":0,\"width\":800,\"height\":600}}");
        }
        // GET /timeouts
        if (method == .GET and std.mem.eql(u8, path, "/timeouts")) {
            return self.getTimeouts();
        }
        // POST /timeouts
        if (method == .POST and std.mem.eql(u8, path, "/timeouts")) {
            return self.setTimeouts(body);
        }
        // POST /actions (stub)
        if (method == .POST and std.mem.eql(u8, path, "/actions")) {
            return ok("{\"value\":null}");
        }
        // DELETE /actions (stub)
        if (method == .DELETE and std.mem.eql(u8, path, "/actions")) {
            return ok("{\"value\":null}");
        }
        // GET /element/active
        if (method == .GET and std.mem.eql(u8, path, "/element/active")) {
            return ok("{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"html-root\"}}");
        }
        // POST /element/{id}/click (match any element ID)
        if (method == .POST and std.mem.startsWith(u8, path, "/element/") and std.mem.endsWith(u8, path, "/click")) {
            return ok("{\"value\":null}");
        }

        return self.err(404, "unknown command", "No route");
    }

    // ── Endpoint Implementations ────────────────────────────────────

    fn createSession(self: *WebDriverServer, _: []const u8) Response {
        if (self.session.active) {
            return self.err(500, "session not created", "Session already exists");
        }
        self.session.active = true;
        self.session.num_windows = 1;
        self.session.active_window = 0;
        return ok(
            "{\"value\":{\"sessionId\":\"suzume-session-1\",\"capabilities\":{" ++
                "\"browserName\":\"suzume\"," ++
                "\"browserVersion\":\"0.4\"," ++
                "\"platformName\":\"linux\"," ++
                "\"acceptInsecureCerts\":true," ++
                "\"setWindowRect\":true," ++
                "\"strictFileInteractability\":false," ++
                "\"pageLoadStrategy\":\"normal\"" ++
                "}}}",
        );
    }

    fn deleteSession(self: *WebDriverServer) Response {
        self.session.active = false;
        return ok("{\"value\":null}");
    }

    fn navigate(self: *WebDriverServer, body: []const u8) Response {
        // Extract URL from {"url": "..."}
        const url = extractJsonString(body, "url") orelse return self.err(400, "invalid argument", "Missing url");
        const resp = self.slot.submitAndWait(.{ .tag = .navigate, .payload = url }, self.session.page_load_timeout_ms);
        return resp;
    }

    fn getUrl(self: *WebDriverServer) Response {
        const resp = self.slot.submitAndWait(.{ .tag = .get_url }, 5000);
        return resp;
    }

    fn getTitle(self: *WebDriverServer) Response {
        const resp = self.slot.submitAndWait(.{ .tag = .get_title }, 5000);
        return resp;
    }

    fn executeSync(self: *WebDriverServer, body: []const u8) Response {
        const script = extractJsonString(body, "script") orelse return self.err(400, "invalid argument", "Missing script");
        const resp = self.slot.submitAndWait(.{
            .tag = .execute_sync,
            .payload = script,
            .payload2 = body, // full body for args extraction
        }, self.session.script_timeout_ms);
        return resp;
    }

    fn executeAsync(self: *WebDriverServer, body: []const u8) Response {
        const script = extractJsonString(body, "script") orelse return self.err(400, "invalid argument", "Missing script");
        const resp = self.slot.submitAndWait(.{
            .tag = .execute_async,
            .payload = script,
            .payload2 = body,
        }, self.session.script_timeout_ms + 5000);
        return resp;
    }

    fn screenshot(self: *WebDriverServer) Response {
        const resp = self.slot.submitAndWait(.{ .tag = .screenshot }, 30000);
        return resp;
    }

    fn getWindowHandle(self: *WebDriverServer) Response {
        return self.slot.submitAndWait(.{ .tag = .get_window_handle }, 5000);
    }

    fn getWindowHandles(self: *WebDriverServer) Response {
        return self.slot.submitAndWait(.{ .tag = .get_window_handles }, 5000);
    }

    fn newWindow(self: *WebDriverServer) Response {
        return self.slot.submitAndWait(.{ .tag = .window_new }, 10000);
    }

    fn closeWindow(self: *WebDriverServer) Response {
        return self.slot.submitAndWait(.{ .tag = .window_close }, 5000);
    }

    fn getTimeouts(self: *WebDriverServer) Response {
        const s = std.fmt.bufPrint(&self.scratch_buf, "{{\"value\":{{\"script\":{d},\"pageLoad\":{d},\"implicit\":{d}}}}}", .{
            self.session.script_timeout_ms,
            self.session.page_load_timeout_ms,
            self.session.implicit_wait_ms,
        }) catch return ok("{\"value\":{}}");
        return ok(s);
    }

    fn setTimeouts(self: *WebDriverServer, body: []const u8) Response {
        // Parse timeout values from JSON
        if (extractJsonNumber(body, "script")) |v| self.session.script_timeout_ms = @intFromFloat(v);
        if (extractJsonNumber(body, "pageLoad")) |v| self.session.page_load_timeout_ms = @intFromFloat(v);
        if (extractJsonNumber(body, "implicit")) |v| self.session.implicit_wait_ms = @intFromFloat(v);
        return ok("{\"value\":null}");
    }

    // ── Response Helpers ────────────────────────────────────────────

    fn ok(body: []const u8) Response {
        return .{ .status = 200, .body = body };
    }

    fn err(self: *WebDriverServer, status: u16, error_code: []const u8, message: []const u8) Response {
        const s = std.fmt.bufPrint(
            &self.scratch_buf,
            "{{\"value\":{{\"error\":\"{s}\",\"message\":\"{s}\",\"stacktrace\":\"\"}}}}",
            .{ error_code, message },
        ) catch return .{
            .status = status,
            .body = "{\"value\":{\"error\":\"unknown error\",\"message\":\"\",\"stacktrace\":\"\"}}",
        };
        return .{ .status = status, .body = s };
    }
};

// ── JSON Helpers (minimal, no allocator needed) ─────────────────────

/// Extract a string value from a simple JSON object: {"key": "value"}
/// Returns unescaped string in the provided static buffer.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Thread-local static buffer for unescaped result
    const S = struct {
        threadlocal var buf: [65536]u8 = undefined;
    };

    // Find "key"
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            // Found "key", now find the value
            var j = i + 1 + key.len + 1; // skip past closing "
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t' or json[j] == '\n')) j += 1;
            if (j < json.len and json[j] == '"') {
                // String value — unescape JSON escape sequences
                var src = j + 1;
                var dst: usize = 0;
                while (src < json.len and json[src] != '"' and dst < S.buf.len) {
                    if (json[src] == '\\' and src + 1 < json.len) {
                        src += 1;
                        switch (json[src]) {
                            '"' => {
                                S.buf[dst] = '"';
                                dst += 1;
                            },
                            '\\' => {
                                S.buf[dst] = '\\';
                                dst += 1;
                            },
                            '/' => {
                                S.buf[dst] = '/';
                                dst += 1;
                            },
                            'n' => {
                                S.buf[dst] = '\n';
                                dst += 1;
                            },
                            'r' => {
                                S.buf[dst] = '\r';
                                dst += 1;
                            },
                            't' => {
                                S.buf[dst] = '\t';
                                dst += 1;
                            },
                            else => {
                                S.buf[dst] = json[src];
                                dst += 1;
                            },
                        }
                        src += 1;
                    } else {
                        S.buf[dst] = json[src];
                        dst += 1;
                        src += 1;
                    }
                }
                return S.buf[0..dst];
            }
        }
    }
    return null;
}

/// Extract a numeric value from JSON: {"key": 30000}
fn extractJsonNumber(json: []const u8, key: []const u8) ?f64 {
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t')) j += 1;
            const start = j;
            while (j < json.len and (json[j] >= '0' and json[j] <= '9' or json[j] == '.' or json[j] == '-')) j += 1;
            if (j > start) {
                return std.fmt.parseFloat(f64, json[start..j]) catch null;
            }
        }
    }
    return null;
}
