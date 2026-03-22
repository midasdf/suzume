const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const HttpClient = @import("../net/http.zig").HttpClient;
const WebSocket = @import("../net/websocket.zig").WebSocket;
const worker_mod = @import("worker.zig");

// ── Navigation request (from location.assign/replace/href setter) ────

var pending_navigation_url: ?[]const u8 = null;

/// Request a navigation from Zig code (used by dom_api.zig).
pub fn requestNavigation(url: []const u8) void {
    if (pending_navigation_url) |old| std.heap.c_allocator.free(old);
    const owned = std.heap.c_allocator.alloc(u8, url.len) catch return;
    @memcpy(owned, url);
    pending_navigation_url = owned;
}

/// Check if JS has requested a navigation. Returns the URL and clears it.
pub fn getPendingNavigation() ?[]const u8 {
    const url = pending_navigation_url;
    pending_navigation_url = null;
    return url;
}

// ── history.pushState URL bar sync ──────────────────────────────────
var pending_url_update: ?[]const u8 = null;

pub fn getPendingUrlUpdate() ?[]const u8 {
    const url = pending_url_update;
    pending_url_update = null;
    return url;
}

fn jsSuzumeUpdateUrl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const str = qjs.JS_ToCStringLen(c, null, args[0]);
    if (str == null) return quickjs.JS_UNDEFINED();
    const s_len = std.mem.len(str);
    defer qjs.JS_FreeCString(c, str);

    if (pending_url_update) |old| std.heap.c_allocator.free(old);
    const copy = std.heap.c_allocator.alloc(u8, s_len) catch return quickjs.JS_UNDEFINED();
    @memcpy(copy, str[0..s_len]);
    pending_url_update = copy;
    return quickjs.JS_UNDEFINED();
}

fn jsLocationAssign(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const dom_api = @import("dom_api.zig");
    const url_s = dom_api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, url_s.ptr);

    // Store navigation URL (allocate owned copy)
    if (pending_navigation_url) |old| std.heap.c_allocator.free(old);
    const owned = std.heap.c_allocator.alloc(u8, url_s.len) catch return quickjs.JS_UNDEFINED();
    @memcpy(owned, url_s.ptr[0..url_s.len]);
    pending_navigation_url = owned;

    return quickjs.JS_UNDEFINED();
}

// ── Viewport dimensions ─────────────────────────────────────────────

/// Viewport (content area) dimensions, updated on resize.
/// Defaults match the HyperPixel4 720×720 display minus chrome bars.
var viewport_width: u32 = 720;
var viewport_height: u32 = 632; // 720 - url_bar(36) - tab_bar(28) - status_bar(24)

/// Call from main.zig after window resize or initial layout.
pub fn setViewportSize(w: u32, h: u32) void {
    viewport_width = w;
    viewport_height = h;
}

// ── Timer system ────────────────────────────────────────────────────

const TimerEntry = struct {
    id: u32,
    callback: qjs.JSValue,
    delay_ms: u32,
    interval: bool,
    is_raf: bool, // requestAnimationFrame: pass timestamp arg
    next_fire: i64, // milliseconds since epoch
    cleared: bool,
};

var timer_list: std.ArrayListUnmanaged(TimerEntry) = .empty;
var next_timer_id: u32 = 1;

/// Context pointer stored in the JSRuntime opaque for timer callbacks.
/// We use a global since QuickJS is single-threaded.
var global_ctx: ?*qjs.JSContext = null;

fn currentTimeMs() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    return @divTrunc(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000), 1);
}

// ── Console API ─────────────────────────────────────────────────────

fn consoleLog(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue, // this_val
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return consoleWrite(ctx, argc, argv, "LOG");
}

fn consoleWarn(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return consoleWrite(ctx, argc, argv, "WARN");
}

fn consoleError(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return consoleWrite(ctx, argc, argv, "ERROR");
}

fn consoleWrite(
    ctx: ?*qjs.JSContext,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
    prefix: []const u8,
) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Build the output line using a buffer, then print it via std.debug.print
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Write prefix
    const prefix_str = std.fmt.bufPrint(buf[pos..], "[JS:{s}] ", .{prefix}) catch "";
    pos += prefix_str.len;

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        const str = qjs.JS_ToCString(c, args[@intCast(i)]);
        if (str) |s| {
            const len = std.mem.len(s);
            const copy_len = @min(len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], s[0..copy_len]);
            pos += copy_len;
            qjs.JS_FreeCString(c, s);
        } else {
            const fallback = "[object]";
            const copy_len = @min(fallback.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], fallback[0..copy_len]);
            pos += copy_len;
        }
    }

    std.debug.print("{s}\n", .{buf[0..pos]});

    return quickjs.JS_UNDEFINED();
}

// ── setTimeout / setInterval / clearTimeout / clearInterval ─────────

fn jsSetTimeout(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return addTimer(ctx, argc, argv, false);
}

fn jsSetInterval(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return addTimer(ctx, argc, argv, true);
}

fn addTimer(
    ctx: ?*qjs.JSContext,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
    interval: bool,
) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();

    const callback = args[0];
    var delay_ms: u32 = 0;
    if (argc >= 2) {
        var d: i32 = 0;
        if (qjs.JS_ToInt32(c, &d, args[1]) == 0) {
            delay_ms = @intCast(@max(d, 0));
        }
    }

    const id = next_timer_id;
    next_timer_id += 1;

    const entry = TimerEntry{
        .id = id,
        .callback = qjs.JS_DupValue(c, callback),
        .delay_ms = delay_ms,
        .interval = interval,
        .is_raf = false,
        .next_fire = currentTimeMs() + @as(i64, delay_ms),
        .cleared = false,
    };

    timer_list.append(std.heap.c_allocator, entry) catch {
        qjs.JS_FreeValue(c, entry.callback);
        return quickjs.JS_UNDEFINED();
    };

    return qjs.JS_NewInt32(c, @intCast(id));
}

fn jsClearTimeout(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return clearTimer(argc, argv);
}

fn jsClearInterval(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return clearTimer(argc, argv);
}

fn clearTimer(argc: c_int, argv: ?[*]qjs.JSValue) qjs.JSValue {
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const ctx = global_ctx orelse return quickjs.JS_UNDEFINED();
    var id_val: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &id_val, args[0]) != 0) return quickjs.JS_UNDEFINED();
    const id: u32 = @intCast(@max(id_val, 0));

    for (timer_list.items) |*entry| {
        if (entry.id == id and !entry.cleared) {
            entry.cleared = true;
            qjs.JS_FreeValue(ctx, entry.callback);
            break;
        }
    }

    return quickjs.JS_UNDEFINED();
}

/// Check and fire any due timers. Returns true if any timers remain active.
pub fn tickTimers(ctx: *qjs.JSContext) bool {
    const now = currentTimeMs();
    var any_active = false;

    var i: usize = 0;
    while (i < timer_list.items.len) {
        const entry = &timer_list.items[i];
        if (entry.cleared) {
            _ = timer_list.swapRemove(i);
            continue;
        }
        if (now >= entry.next_fire) {
            // Save callback and id before JS_Call (which may invalidate entry pointer via realloc)
            const saved_callback = qjs.JS_DupValue(ctx, entry.callback);
            const saved_id = entry.id;
            const saved_interval = entry.interval;
            const saved_delay = entry.delay_ms;
            const saved_is_raf = entry.is_raf;

            // Fire the callback (may trigger timer_list append/realloc)
            // DupValue above protects the callback from being freed if clearInterval
            // is called from within the callback itself.
            const ret = if (saved_is_raf) blk: {
                // requestAnimationFrame: pass DOMHighResTimeStamp (performance.now())
                const timestamp = getPerformanceNow();
                var raf_argv = [_]qjs.JSValue{qjs.JS_NewFloat64(ctx, timestamp)};
                break :blk qjs.JS_Call(ctx, saved_callback, quickjs.JS_UNDEFINED(), 1, &raf_argv);
            } else qjs.JS_Call(ctx, saved_callback, quickjs.JS_UNDEFINED(), 0, null);
            qjs.JS_FreeValue(ctx, ret);
            qjs.JS_FreeValue(ctx, saved_callback);

            // Re-find entry by id (pointer may have been invalidated by JS_Call)
            var found = false;
            for (timer_list.items, 0..) |*e, j| {
                if (e.id == saved_id) {
                    if (saved_interval and !e.cleared) {
                        e.next_fire = now + @as(i64, saved_delay);
                        any_active = true;
                        i += 1;
                    } else {
                        if (!e.cleared) {
                            qjs.JS_FreeValue(ctx, e.callback);
                        }
                        _ = timer_list.swapRemove(j);
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Timer was removed during callback, just continue
            }
        } else {
            any_active = true;
            i += 1;
        }
    }

    // Fire MutationObservers if DOM was mutated
    const dom_api_mod = @import("dom_api.zig");
    if (dom_api_mod.mutation_observers_pending) {
        dom_api_mod.mutation_observers_pending = false;
        const events_mod = @import("events.zig");
        events_mod.flushMutationObservers(ctx);
    }

    return any_active;
}


/// Check if any timers are pending.
pub fn hasTimers() bool {
    for (timer_list.items) |entry| {
        if (!entry.cleared) return true;
    }
    return false;
}

// ── WebSocket Management ────────────────────────────────────────────

const WsEntry = struct {
    ws: WebSocket,
    js_obj: qjs.JSValue, // The JS WebSocket object (has onmessage, onopen, etc.)
    id: u32,
};

var ws_list: std.ArrayListUnmanaged(WsEntry) = .empty;
var ws_next_id: u32 = 1;

fn jsWebSocketConnect(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return qjs.JS_NewInt32(ctx orelse unreachable, -1);
    if (argc < 2) return qjs.JS_NewInt32(c, -1);
    const args = argv orelse return qjs.JS_NewInt32(c, -1);

    const dom_api = @import("dom_api.zig");
    const url_s = dom_api.jsStringToSlice(c, args[0]) orelse return qjs.JS_NewInt32(c, -1);
    defer qjs.JS_FreeCString(c, url_s.ptr);

    // Make null-terminated URL
    const url_z = std.heap.c_allocator.allocSentinel(u8, url_s.len, 0) catch return qjs.JS_NewInt32(c, -1);
    defer std.heap.c_allocator.free(url_z);
    @memcpy(url_z, url_s.ptr[0..url_s.len]);

    std.debug.print("[WebSocket] Connecting to {s}\n", .{url_z});

    var ws = WebSocket.connect(std.heap.c_allocator, url_z) catch {
        std.debug.print("[WebSocket] Connection failed\n", .{});
        return qjs.JS_NewInt32(c, -1);
    };
    _ = &ws;

    const id = ws_next_id;
    ws_next_id += 1;

    ws_list.append(std.heap.c_allocator, .{
        .ws = ws,
        .js_obj = qjs.JS_DupValue(c, args[1]), // Store reference to JS WebSocket object
        .id = id,
    }) catch return qjs.JS_NewInt32(c, -1);

    std.debug.print("[WebSocket] Connected, id={d}\n", .{id});
    return qjs.JS_NewInt32(c, @intCast(id));
}

fn jsWebSocketSend(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    var ws_id: i32 = 0;
    _ = qjs.JS_ToInt32(c, &ws_id, args[0]);

    for (ws_list.items) |*entry| {
        if (entry.id == @as(u32, @intCast(ws_id))) {
            const dom_api = @import("dom_api.zig");
            const data_s = dom_api.jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
            defer qjs.JS_FreeCString(c, data_s.ptr);
            entry.ws.sendText(data_s.ptr[0..data_s.len]) catch {};
            break;
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn jsWebSocketClose(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    var ws_id: i32 = 0;
    _ = qjs.JS_ToInt32(c, &ws_id, args[0]);

    for (ws_list.items) |*entry| {
        if (entry.id == @as(u32, @intCast(ws_id))) {
            entry.ws.close();
            break;
        }
    }
    return quickjs.JS_UNDEFINED();
}

/// Poll all WebSocket connections for incoming messages and fire callbacks.
pub fn tickWebSockets(ctx: *qjs.JSContext) void {
    var i: usize = 0;
    while (i < ws_list.items.len) {
        var entry = &ws_list.items[i];
        if (entry.ws.state == .closed) {
            // Fire onclose
            const onclose = qjs.JS_GetPropertyStr(ctx, entry.js_obj, "onclose");
            if (qjs.JS_IsFunction(ctx, onclose)) {
                const event = qjs.JS_NewObject(ctx);
                _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewString(ctx, "close"));
                _ = qjs.JS_SetPropertyStr(ctx, event, "code", qjs.JS_NewInt32(ctx, 1000));
                _ = qjs.JS_SetPropertyStr(ctx, event, "reason", qjs.JS_NewString(ctx, ""));
                var argv_close = [_]qjs.JSValue{event};
                const ret = qjs.JS_Call(ctx, onclose, entry.js_obj, 1, &argv_close);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, event);
            }
            qjs.JS_FreeValue(ctx, onclose);
            // Cleanup
            qjs.JS_FreeValue(ctx, entry.js_obj);
            entry.ws.deinit();
            _ = ws_list.swapRemove(i);
            continue;
        }

        // Try to receive a message
        if (entry.ws.recv()) |msg| {
            var msg_copy = msg;
            defer msg_copy.deinit();

            const onmessage = qjs.JS_GetPropertyStr(ctx, entry.js_obj, "onmessage");
            if (qjs.JS_IsFunction(ctx, onmessage)) {
                const event = qjs.JS_NewObject(ctx);
                _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewString(ctx, "message"));
                _ = qjs.JS_SetPropertyStr(ctx, event, "data", qjs.JS_NewStringLen(ctx, msg_copy.data.ptr, msg_copy.data.len));
                var argv_msg = [_]qjs.JSValue{event};
                const ret = qjs.JS_Call(ctx, onmessage, entry.js_obj, 1, &argv_msg);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, event);
            }
            qjs.JS_FreeValue(ctx, onmessage);
        }

        i += 1;
    }
}

pub fn deinitWebSockets(ctx: *qjs.JSContext) void {
    for (ws_list.items) |*entry| {
        qjs.JS_FreeValue(ctx, entry.js_obj);
        entry.ws.deinit();
    }
    ws_list.deinit(std.heap.c_allocator);
    ws_list = .empty;
}

// ── Worker Management ────────────────────────────────────────────────

const WorkerEntry = struct {
    handle: *worker_mod.WorkerHandle,
    js_obj: qjs.JSValue, // JS Worker object (has onmessage)
};

var worker_list: std.ArrayListUnmanaged(WorkerEntry) = .empty;

fn jsWorkerCreate(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return qjs.JS_NewInt32(ctx orelse unreachable, -1);
    if (argc < 2) return qjs.JS_NewInt32(c, -1);
    const args = argv orelse return qjs.JS_NewInt32(c, -1);

    const dom_api = @import("dom_api.zig");
    const script_s = dom_api.jsStringToSlice(c, args[0]) orelse return qjs.JS_NewInt32(c, -1);
    defer qjs.JS_FreeCString(c, script_s.ptr);

    std.debug.print("[Worker] Spawning worker ({d} bytes)\n", .{script_s.len});

    const handle = worker_mod.spawnWorker(script_s.ptr[0..script_s.len]) catch {
        std.debug.print("[Worker] Spawn failed\n", .{});
        return qjs.JS_NewInt32(c, -1);
    };

    worker_list.append(std.heap.c_allocator, .{
        .handle = handle,
        .js_obj = qjs.JS_DupValue(c, args[1]),
    }) catch {
        handle.deinit();
        std.heap.c_allocator.destroy(handle);
        return qjs.JS_NewInt32(c, -1);
    };

    return qjs.JS_NewInt32(c, @intCast(handle.id));
}

fn jsWorkerPostMessage(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    var worker_id: i32 = 0;
    _ = qjs.JS_ToInt32(c, &worker_id, args[0]);

    const dom_api = @import("dom_api.zig");
    const data_s = dom_api.jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, data_s.ptr);

    for (worker_list.items) |*entry| {
        if (@as(i32, @intCast(entry.handle.id)) == worker_id) {
            entry.handle.postToWorker(data_s.ptr[0..data_s.len]) catch {};
            break;
        }
    }
    return quickjs.JS_UNDEFINED();
}

fn jsWorkerTerminate(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    var worker_id: i32 = 0;
    _ = qjs.JS_ToInt32(c, &worker_id, args[0]);

    for (worker_list.items) |*entry| {
        if (@as(i32, @intCast(entry.handle.id)) == worker_id) {
            entry.handle.terminate();
            break;
        }
    }
    return quickjs.JS_UNDEFINED();
}

/// Poll workers for incoming messages from worker → main.
pub fn tickWorkers(ctx: *qjs.JSContext) void {
    var i: usize = 0;
    while (i < worker_list.items.len) {
        var entry = &worker_list.items[i];

        // Check for messages from worker
        while (entry.handle.popFromWorker()) |msg| {
            var msg_copy = msg;
            defer msg_copy.deinit();

            const onmessage = qjs.JS_GetPropertyStr(ctx, entry.js_obj, "onmessage");
            if (qjs.JS_IsFunction(ctx, onmessage)) {
                const event = qjs.JS_NewObject(ctx);
                const data_val = qjs.JS_ParseJSON(ctx, msg_copy.data.ptr, msg_copy.data.len, "<worker-msg>");
                _ = qjs.JS_SetPropertyStr(ctx, event, "data", data_val);
                _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewString(ctx, "message"));
                var argv_msg = [_]qjs.JSValue{event};
                const ret = qjs.JS_Call(ctx, onmessage, entry.js_obj, 1, &argv_msg);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, event);
            }
            qjs.JS_FreeValue(ctx, onmessage);
        }

        // Clean up terminated workers
        if (entry.handle.state == .terminated) {
            qjs.JS_FreeValue(ctx, entry.js_obj);
            entry.handle.deinit();
            std.heap.c_allocator.destroy(entry.handle);
            _ = worker_list.swapRemove(i);
            continue;
        }

        i += 1;
    }
}

pub fn deinitWorkers(ctx: *qjs.JSContext) void {
    for (worker_list.items) |*entry| {
        qjs.JS_FreeValue(ctx, entry.js_obj);
        entry.handle.deinit();
        std.heap.c_allocator.destroy(entry.handle);
    }
    worker_list.deinit(std.heap.c_allocator);
    worker_list = .empty;
}

/// Free all timer callbacks. Called during JsRuntime.deinit().
pub fn deinitTimers(ctx: *qjs.JSContext) void {
    for (timer_list.items) |*entry| {
        if (!entry.cleared) {
            qjs.JS_FreeValue(ctx, entry.callback);
        }
    }
    timer_list.deinit(std.heap.c_allocator);
    timer_list = .empty;
    next_timer_id = 1;
    global_ctx = null;
}

// ── requestAnimationFrame (as setTimeout ~16ms) ─────────────────────

fn jsRequestAnimationFrame(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();

    const callback = args[0];
    if (!qjs.JS_IsFunction(c, callback)) return quickjs.JS_UNDEFINED();

    const id = next_timer_id;
    next_timer_id += 1;

    const entry = TimerEntry{
        .id = id,
        .callback = qjs.JS_DupValue(c, callback),
        .delay_ms = 16, // ~60fps
        .interval = false,
        .is_raf = true,
        .next_fire = currentTimeMs() + 16,
        .cleared = false,
    };

    timer_list.append(std.heap.c_allocator, entry) catch {
        qjs.JS_FreeValue(c, entry.callback);
        return quickjs.JS_UNDEFINED();
    };

    return qjs.JS_NewInt32(c, @intCast(id));
}

// ── performance.now() ───────────────────────────────────────────────

var perf_origin: i64 = 0;

/// Get elapsed ms since origin (for performance.now and rAF timestamp).
fn getPerformanceNow() f64 {
    if (perf_origin == 0) perf_origin = currentTimeMs();
    return @floatFromInt(currentTimeMs() - perf_origin);
}

fn jsPerformanceNow(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewFloat64(c, getPerformanceNow());
}

// ── fetch() API ─────────────────────────────────────────────────────

/// Global HTTP client for fetch() — initialized lazily.
var g_http_client: ?HttpClient = null;
var g_shared_client: ?*HttpClient = null;

/// Set a shared HTTP client from main.zig (shares cookies with Loader).
pub fn setSharedHttpClient(client: *HttpClient) void {
    g_shared_client = client;
}

fn getOrInitHttpClient() ?*HttpClient {
    // Prefer the shared client (shares cookie jar with page loads)
    if (g_shared_client) |shared| return shared;
    if (g_http_client == null) {
        g_http_client = HttpClient.init() catch return null;
    }
    return &g_http_client.?;
}

/// Get the shared HTTP client (for cookie access from dom_api.zig).
pub fn getHttpClient() ?*HttpClient {
    return getOrInitHttpClient();
}

pub fn deinitHttpClient() void {
    g_shared_client = null;
    if (g_http_client) |*client| {
        client.deinit();
        g_http_client = null;
    }
}

fn jsFetch(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get URL string
    const dom_api = @import("dom_api.zig");
    const url_s = dom_api.jsStringToSlice(c, args[0]) orelse {
        // Return rejected Promise
        return rejectPromise(c, "fetch: invalid URL argument");
    };
    defer qjs.JS_FreeCString(c, url_s.ptr);
    const url = url_s.ptr[0..url_s.len];

    // Parse options (method, body, headers)
    var req_opts = HttpClient.RequestOptions{ .timeout_secs = 15 };

    // Buffers for method string and headers
    var method_buf: [:0]u8 = undefined;
    var method_allocated = false;
    defer if (method_allocated) std.heap.c_allocator.free(method_buf);

    var headers_buf: [32][2][]const u8 = undefined;
    var headers_count: usize = 0;
    // Track allocated strings for cleanup (body + up to 32 headers * 2 key/value = max 65)
    var header_strs: [96][]const u8 = undefined;
    var header_str_count: usize = 0;
    defer for (header_strs[0..header_str_count]) |s| {
        std.heap.c_allocator.free(s);
    };

    var body_js: qjs.JSValue = quickjs.JS_UNDEFINED();

    if (argc >= 2) {
        const opts = args[1];
        if (!quickjs.JS_IsUndefined(opts) and !quickjs.JS_IsNull(opts)) {
            // Parse method
            const method_val = qjs.JS_GetPropertyStr(c, opts, "method");
            if (!quickjs.JS_IsUndefined(method_val) and !quickjs.JS_IsNull(method_val)) {
                const ms = dom_api.jsStringToSlice(c, method_val);
                if (ms) |m| {
                    const m_slice = m.ptr[0..m.len];
                    method_buf = std.heap.c_allocator.allocSentinel(u8, m_slice.len, 0) catch {
                        qjs.JS_FreeValue(c, method_val);
                        qjs.JS_FreeCString(c, m.ptr);
                        return rejectPromise(c, "fetch: out of memory");
                    };
                    // Uppercase the method
                    for (m_slice, 0..) |ch, i| {
                        method_buf[i] = std.ascii.toUpper(ch);
                    }
                    method_allocated = true;
                    req_opts.method = method_buf;
                    qjs.JS_FreeCString(c, m.ptr);
                }
            }
            qjs.JS_FreeValue(c, method_val);

            // Parse body
            body_js = qjs.JS_GetPropertyStr(c, opts, "body");
            if (!quickjs.JS_IsUndefined(body_js) and !quickjs.JS_IsNull(body_js)) {
                const bs = dom_api.jsStringToSlice(c, body_js);
                if (bs) |b| {
                    // Allocate owned copy since FreeCString would invalidate
                    const body_owned = std.heap.c_allocator.alloc(u8, b.len) catch {
                        qjs.JS_FreeCString(c, b.ptr);
                        qjs.JS_FreeValue(c, body_js);
                        return rejectPromise(c, "fetch: out of memory");
                    };
                    @memcpy(body_owned, b.ptr[0..b.len]);
                    qjs.JS_FreeCString(c, b.ptr);
                    req_opts.body = body_owned;
                    header_strs[header_str_count] = body_owned;
                    header_str_count += 1;
                }
            }
            qjs.JS_FreeValue(c, body_js);

            // Parse headers
            const hdrs_val = qjs.JS_GetPropertyStr(c, opts, "headers");
            if (!quickjs.JS_IsUndefined(hdrs_val) and !quickjs.JS_IsNull(hdrs_val)) {
                // Get property names from headers object
                var ptab: [*c]qjs.JSPropertyEnum = null;
                var plen: u32 = 0;
                if (qjs.JS_GetOwnPropertyNames(c, &ptab, &plen, hdrs_val, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) == 0) {
                    var hi: u32 = 0;
                    while (hi < plen and headers_count < 32) : (hi += 1) {
                        const atom = ptab[hi].atom;
                        const key_js = qjs.JS_AtomToString(c, atom);
                        const val_js = qjs.JS_GetProperty(c, hdrs_val, atom);

                        const ks = dom_api.jsStringToSlice(c, key_js);
                        const vs = dom_api.jsStringToSlice(c, val_js);

                        if (ks != null and vs != null) {
                            // Allocate owned copies
                            const ko = std.heap.c_allocator.alloc(u8, ks.?.len) catch {
                                qjs.JS_FreeCString(c, ks.?.ptr);
                                qjs.JS_FreeCString(c, vs.?.ptr);
                                qjs.JS_FreeValue(c, key_js);
                                qjs.JS_FreeValue(c, val_js);
                                continue;
                            };
                            @memcpy(ko, ks.?.ptr[0..ks.?.len]);
                            const vo = std.heap.c_allocator.alloc(u8, vs.?.len) catch {
                                std.heap.c_allocator.free(ko);
                                qjs.JS_FreeCString(c, ks.?.ptr);
                                qjs.JS_FreeCString(c, vs.?.ptr);
                                qjs.JS_FreeValue(c, key_js);
                                qjs.JS_FreeValue(c, val_js);
                                continue;
                            };
                            @memcpy(vo, vs.?.ptr[0..vs.?.len]);

                            headers_buf[headers_count] = .{ ko, vo };
                            headers_count += 1;
                            header_strs[header_str_count] = ko;
                            header_str_count += 1;
                            header_strs[header_str_count] = vo;
                            header_str_count += 1;

                            qjs.JS_FreeCString(c, ks.?.ptr);
                            qjs.JS_FreeCString(c, vs.?.ptr);
                        } else {
                            if (ks) |k| qjs.JS_FreeCString(c, k.ptr);
                            if (vs) |v| qjs.JS_FreeCString(c, v.ptr);
                        }

                        qjs.JS_FreeValue(c, key_js);
                        qjs.JS_FreeValue(c, val_js);
                    }
                    // Free property enum
                    var fi: u32 = 0;
                    while (fi < plen) : (fi += 1) {
                        qjs.JS_FreeAtom(c, ptab[fi].atom);
                    }
                    qjs.js_free(c, ptab);
                }
            }
            qjs.JS_FreeValue(c, hdrs_val);
        }
    }

    if (headers_count > 0) {
        req_opts.headers = headers_buf[0..headers_count];
    }

    // Validate URL
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return rejectPromise(c, "fetch: only http/https URLs supported");
    }

    // Make null-terminated URL
    const url_z = std.heap.c_allocator.allocSentinel(u8, url.len, 0) catch {
        return rejectPromise(c, "fetch: out of memory");
    };
    defer std.heap.c_allocator.free(url_z);
    @memcpy(url_z, url);

    const method_str = if (req_opts.method) |m| m.ptr[0..m.len] else "GET";
    std.debug.print("[fetch] {s} {s}\n", .{ method_str, url_z });

    // Synchronous HTTP fetch
    const client = getOrInitHttpClient() orelse {
        return rejectPromise(c, "fetch: failed to initialize HTTP client");
    };

    var response = client.request(std.heap.c_allocator, url_z, req_opts) catch {
        return rejectPromise(c, "fetch: network error");
    };

    // Build Response object
    const resp_obj = qjs.JS_NewObject(c);
    if (quickjs.JS_IsException(resp_obj)) {
        response.deinit();
        return rejectPromise(c, "fetch: failed to create response");
    }

    // Store body as string property
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "_body", qjs.JS_NewStringLen(c, response.body.ptr, response.body.len));
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "status", qjs.JS_NewInt32(c, @intCast(response.status_code)));
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "ok", quickjs.JS_NewBool(response.status_code >= 200 and response.status_code < 300));
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "statusText", qjs.JS_NewStringLen(c, "OK", 2));
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "url", qjs.JS_NewStringLen(c, url.ptr, url.len));

    // Headers object
    const headers_obj = qjs.JS_NewObject(c);
    if (response.content_type.len > 0) {
        _ = qjs.JS_SetPropertyStr(c, headers_obj, "content-type", qjs.JS_NewStringLen(c, response.content_type.ptr, response.content_type.len));
    }
    _ = qjs.JS_SetPropertyStr(c, resp_obj, "headers", headers_obj);

    response.deinit();

    // Add .text() and .json() methods via JS eval
    const global = qjs.JS_GetGlobalObject(c);
    _ = qjs.JS_SetPropertyStr(c, global, "__fetchResp", resp_obj);

    const method_code =
        \\(function() {
        \\  var r = globalThis.__fetchResp;
        \\  delete globalThis.__fetchResp;
        \\  r.text = function() { return Promise.resolve(r._body || ''); };
        \\  r.json = function() { try { return Promise.resolve(JSON.parse(r._body || 'null')); } catch(e) { return Promise.reject(e); } };
        \\  r.blob = function() { return Promise.resolve(new Blob([r._body || ''])); };
        \\  r.clone = function() { return r; };
        \\  var hdr = r.headers || {};
        \\  r.headers = { get: function(n) { return hdr[n.toLowerCase()] || null; }, has: function(n) { return n.toLowerCase() in hdr; }, forEach: function(cb) { for(var k in hdr) cb(hdr[k], k); }, set: function(n,v) { hdr[n.toLowerCase()] = v; } };
        \\  return r;
        \\})()
    ;
    const result = qjs.JS_Eval(c, method_code, method_code.len, "<fetch>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(c, global);

    if (quickjs.JS_IsException(result)) {
        const exc = qjs.JS_GetException(c);
        qjs.JS_FreeValue(c, exc);
        return rejectPromise(c, "fetch: failed to build response");
    }

    // Return Promise.resolve(response)
    return resolvePromise(c, result);
}

fn resolvePromise(ctx: *qjs.JSContext, value: qjs.JSValue) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    const promise_ctor = qjs.JS_GetPropertyStr(ctx, global, "Promise");
    const resolve_fn = qjs.JS_GetPropertyStr(ctx, promise_ctor, "resolve");
    var argv = [_]qjs.JSValue{value};
    const result = qjs.JS_Call(ctx, resolve_fn, promise_ctor, 1, &argv);
    qjs.JS_FreeValue(ctx, resolve_fn);
    qjs.JS_FreeValue(ctx, promise_ctor);
    qjs.JS_FreeValue(ctx, global);
    qjs.JS_FreeValue(ctx, value);
    return result;
}

fn rejectPromise(ctx: *qjs.JSContext, msg: [*:0]const u8) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    const promise_ctor = qjs.JS_GetPropertyStr(ctx, global, "Promise");
    const reject_fn = qjs.JS_GetPropertyStr(ctx, promise_ctor, "reject");
    const err = qjs.JS_NewStringLen(ctx, msg, std.mem.len(msg));
    var argv = [_]qjs.JSValue{err};
    const result = qjs.JS_Call(ctx, reject_fn, promise_ctor, 1, &argv);
    qjs.JS_FreeValue(ctx, reject_fn);
    qjs.JS_FreeValue(ctx, promise_ctor);
    qjs.JS_FreeValue(ctx, global);
    qjs.JS_FreeValue(ctx, err);
    return result;
}

/// No-op stub for unimplemented Web APIs that should silently succeed.
fn jsNoOp(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    return quickjs.JS_UNDEFINED();
}

/// Return an empty JS array (for performance.getEntriesByName etc.)
fn jsReturnEmptyArray(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

// ── atob() / btoa() ─────────────────────────────────────────────────

const b64_encode_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const b64_decode_table = blk: {
    var table: [256]u8 = .{0xFF} ** 256;
    for (b64_encode_table, 0..) |ch, i| {
        table[ch] = @intCast(i);
    }
    table['='] = 0;
    break :blk table;
};

fn jsBtoa(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();

    var len: usize = 0;
    const str = qjs.JS_ToCStringLen(c, &len, args[0]);
    if (str == null) return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);

    const input: [*]const u8 = @ptrCast(str.?);

    // Calculate output size: ceil(len/3) * 4
    const out_len = ((len + 2) / 3) * 4;
    const buf = std.heap.c_allocator.alloc(u8, out_len) catch return quickjs.JS_UNDEFINED();
    defer std.heap.c_allocator.free(buf);

    var i: usize = 0;
    var o: usize = 0;
    while (i < len) {
        const b0: u32 = input[i];
        const b1: u32 = if (i + 1 < len) input[i + 1] else 0;
        const b2: u32 = if (i + 2 < len) input[i + 2] else 0;
        const triple = (b0 << 16) | (b1 << 8) | b2;

        buf[o] = b64_encode_table[@intCast((triple >> 18) & 0x3F)];
        buf[o + 1] = b64_encode_table[@intCast((triple >> 12) & 0x3F)];
        buf[o + 2] = if (i + 1 < len) b64_encode_table[@intCast((triple >> 6) & 0x3F)] else '=';
        buf[o + 3] = if (i + 2 < len) b64_encode_table[@intCast(triple & 0x3F)] else '=';

        i += 3;
        o += 4;
    }

    return qjs.JS_NewStringLen(c, buf.ptr, out_len);
}

fn jsAtob(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();

    var len: usize = 0;
    const str = qjs.JS_ToCStringLen(c, &len, args[0]);
    if (str == null) return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);

    const input: [*]const u8 = @ptrCast(str.?);

    // Strip whitespace and count valid chars
    var clean: [8192]u8 = undefined;
    var clean_len: usize = 0;
    for (0..len) |idx| {
        const ch = input[idx];
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') continue;
        if (clean_len >= clean.len) return quickjs.JS_UNDEFINED();
        clean[clean_len] = ch;
        clean_len += 1;
    }

    if (clean_len == 0) return qjs.JS_NewStringLen(c, "", 0);

    // Calculate output size
    var pad: usize = 0;
    if (clean_len > 0 and clean[clean_len - 1] == '=') pad += 1;
    if (clean_len > 1 and clean[clean_len - 2] == '=') pad += 1;
    const out_len = (clean_len / 4) * 3 - pad;

    const buf = std.heap.c_allocator.alloc(u8, out_len) catch return quickjs.JS_UNDEFINED();
    defer std.heap.c_allocator.free(buf);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 < clean_len) {
        const a: u32 = b64_decode_table[clean[i]];
        const b: u32 = b64_decode_table[clean[i + 1]];
        const cc: u32 = b64_decode_table[clean[i + 2]];
        const d: u32 = b64_decode_table[clean[i + 3]];

        if (a == 0xFF or b == 0xFF or cc == 0xFF or d == 0xFF) return quickjs.JS_UNDEFINED();

        const triple = (a << 18) | (b << 12) | (cc << 6) | d;

        if (o < out_len) {
            buf[o] = @intCast((triple >> 16) & 0xFF);
            o += 1;
        }
        if (o < out_len) {
            buf[o] = @intCast((triple >> 8) & 0xFF);
            o += 1;
        }
        if (o < out_len) {
            buf[o] = @intCast(triple & 0xFF);
            o += 1;
        }
        i += 4;
    }

    return qjs.JS_NewStringLen(c, buf.ptr, out_len);
}

// ── URL class, queueMicrotask, structuredClone (JS-based) ───────────

const url_class_js =
    \\globalThis.URL = function URL(url, base) {
    \\  if (!(this instanceof URL)) throw new TypeError("Constructor URL requires 'new'");
    \\  if (typeof url !== "string") url = String(url);
    \\  if (base !== undefined) {
    \\    if (typeof base !== "string") base = String(base);
    \\    if (url.indexOf("://") === -1) {
    \\      var protoE = base.indexOf("://");
    \\      if (protoE !== -1) {
    \\        var baseRest = base.substring(protoE + 3);
    \\        var basePathI = baseRest.indexOf("/");
    \\        var baseOrigin = base.substring(0, protoE + 3) + (basePathI !== -1 ? baseRest.substring(0, basePathI) : baseRest);
    \\        if (url.charAt(0) === "/") {
    \\          url = baseOrigin + url;
    \\        } else {
    \\          var basePath = basePathI !== -1 ? baseRest.substring(basePathI) : "/";
    \\          var lastSlash = basePath.lastIndexOf("/");
    \\          url = baseOrigin + basePath.substring(0, lastSlash + 1) + url;
    \\        }
    \\      }
    \\    }
    \\  }
    \\  this.href = url;
    \\  // Parse protocol
    \\  var protoEnd = url.indexOf("://");
    \\  if (protoEnd === -1) { this.protocol = ""; this.hostname = ""; this.host = ""; this.port = ""; this.pathname = url; this.search = ""; this.hash = ""; this.origin = ""; this.searchParams = {get:function(){return null;},has:function(){return false;},toString:function(){return "";}}; return; }
    \\  this.protocol = url.substring(0, protoEnd + 1);
    \\  var rest = url.substring(protoEnd + 3);
    \\  // Parse hash
    \\  var hashIdx = rest.indexOf("#");
    \\  if (hashIdx !== -1) {
    \\    this.hash = rest.substring(hashIdx);
    \\    rest = rest.substring(0, hashIdx);
    \\  } else {
    \\    this.hash = "";
    \\  }
    \\  // Parse search
    \\  var searchIdx = rest.indexOf("?");
    \\  if (searchIdx !== -1) {
    \\    this.search = rest.substring(searchIdx);
    \\    rest = rest.substring(0, searchIdx);
    \\  } else {
    \\    this.search = "";
    \\  }
    \\  // Parse host and pathname
    \\  var pathIdx = rest.indexOf("/");
    \\  if (pathIdx !== -1) {
    \\    this.host = rest.substring(0, pathIdx);
    \\    this.pathname = rest.substring(pathIdx);
    \\  } else {
    \\    this.host = rest;
    \\    this.pathname = "/";
    \\  }
    \\  // Parse port from host
    \\  var colonIdx = this.host.indexOf(":");
    \\  if (colonIdx !== -1) {
    \\    this.hostname = this.host.substring(0, colonIdx);
    \\    this.port = this.host.substring(colonIdx + 1);
    \\  } else {
    \\    this.hostname = this.host;
    \\    this.port = "";
    \\  }
    \\  this.origin = this.protocol + "//" + this.host;
    \\  // searchParams
    \\  var sp = {};
    \\  var _search = this.search;
    \\  if (_search.length > 1) {
    \\    var pairs = _search.substring(1).split("&");
    \\    for (var i = 0; i < pairs.length; i++) {
    \\      var eq = pairs[i].indexOf("=");
    \\      if (eq !== -1) {
    \\        var key = decodeURIComponent(pairs[i].substring(0, eq));
    \\        var val = decodeURIComponent(pairs[i].substring(eq + 1));
    \\        sp[key] = val;
    \\      } else {
    \\        sp[decodeURIComponent(pairs[i])] = "";
    \\      }
    \\    }
    \\  }
    \\  this.searchParams = {
    \\    _data: sp,
    \\    get: function(name) { return this._data.hasOwnProperty(name) ? this._data[name] : null; },
    \\    has: function(name) { return this._data.hasOwnProperty(name); },
    \\    toString: function() {
    \\      var parts = [];
    \\      for (var k in this._data) {
    \\        if (this._data.hasOwnProperty(k)) parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(this._data[k]));
    \\      }
    \\      return parts.join("&");
    \\    }
    \\  };
    \\};
    \\URL.prototype.toString = function() { return this.href; };
;

const utility_apis_js =
    \\globalThis.queueMicrotask = function(cb) { cb(); };
    \\globalThis.structuredClone = function(obj) { return JSON.parse(JSON.stringify(obj)); };
;

fn evalInitScript(ctx: *qjs.JSContext, code: [*:0]const u8, len: usize) void {
    const result = qjs.JS_Eval(ctx, code, len, "<web_api_init>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(result)) {
        const exc = qjs.JS_GetException(ctx);
        const exc_str = qjs.JS_ToCString(ctx, exc);
        if (exc_str) |s| {
            std.debug.print("[web_api] init script error: {s}\n", .{s});
            qjs.JS_FreeCString(ctx, s);
        }
        qjs.JS_FreeValue(ctx, exc);
    }
    qjs.JS_FreeValue(ctx, result);
}

// ── window.innerWidth / innerHeight / outerWidth / outerHeight ───────

fn jsGetInnerWidth(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intCast(viewport_width));
}

fn jsGetInnerHeight(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, @intCast(viewport_height));
}

fn jsGetOuterWidth(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 720); // full physical screen width
}

fn jsGetOuterHeight(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewInt32(c, 720); // full physical screen height
}

fn defineGetter(
    ctx: *qjs.JSContext,
    global: qjs.JSValue,
    name: [*:0]const u8,
    getter_fn: *const fn (?*qjs.JSContext, qjs.JSValue, c_int, ?[*]qjs.JSValue) callconv(.c) qjs.JSValue,
) void {
    const atom = qjs.JS_NewAtom(ctx, name);
    defer qjs.JS_FreeAtom(ctx, atom);
    const getter = qjs.JS_NewCFunction(ctx, getter_fn, name, 0);
    _ = qjs.JS_DefinePropertyGetSet(
        ctx,
        global,
        atom,
        getter,
        quickjs.JS_UNDEFINED(),
        qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE,
    );
}

// ── Registration ────────────────────────────────────────────────────

pub fn registerWebApis(js_rt: anytype) void {
    const ctx = js_rt.ctx;
    global_ctx = ctx;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // -- Native MutationObserver (replaces polyfill) --
    const events = @import("events.zig");
    _ = qjs.JS_SetPropertyStr(ctx, global, "MutationObserver",
        qjs.JS_NewCFunction2(ctx, &events.jsMutationObserverConstructor, "MutationObserver", 1, qjs.JS_CFUNC_constructor, 0));

    // -- history.pushState URL bar sync --
    _ = qjs.JS_SetPropertyStr(ctx, global, "__suzume_update_url",
        qjs.JS_NewCFunction(ctx, &jsSuzumeUpdateUrl, "__suzume_update_url", 1));

    // -- console object --
    const console_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "log", qjs.JS_NewCFunction(ctx, &consoleLog, "log", 1));
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "warn", qjs.JS_NewCFunction(ctx, &consoleWarn, "warn", 1));
    _ = qjs.JS_SetPropertyStr(ctx, console_obj, "error", qjs.JS_NewCFunction(ctx, &consoleError, "error", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);

    // -- setTimeout / setInterval / clearTimeout / clearInterval --
    _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", qjs.JS_NewCFunction(ctx, &jsSetTimeout, "setTimeout", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", qjs.JS_NewCFunction(ctx, &jsSetInterval, "setInterval", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", qjs.JS_NewCFunction(ctx, &jsClearTimeout, "clearTimeout", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", qjs.JS_NewCFunction(ctx, &jsClearInterval, "clearInterval", 1));

    // -- requestAnimationFrame / cancelAnimationFrame --
    // Implemented as setTimeout(cb, 16) (~60fps) since we don't have a real vsync loop
    _ = qjs.JS_SetPropertyStr(ctx, global, "requestAnimationFrame", qjs.JS_NewCFunction(ctx, &jsRequestAnimationFrame, "requestAnimationFrame", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "cancelAnimationFrame", qjs.JS_NewCFunction(ctx, &jsClearTimeout, "cancelAnimationFrame", 1));

    // -- performance object --
    const perf_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "now", qjs.JS_NewCFunction(ctx, &jsPerformanceNow, "now", 0));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "mark", qjs.JS_NewCFunction(ctx, &jsNoOp, "mark", 1));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "measure", qjs.JS_NewCFunction(ctx, &jsNoOp, "measure", 1));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "clearMarks", qjs.JS_NewCFunction(ctx, &jsNoOp, "clearMarks", 0));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "clearMeasures", qjs.JS_NewCFunction(ctx, &jsNoOp, "clearMeasures", 0));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "getEntriesByName", qjs.JS_NewCFunction(ctx, &jsReturnEmptyArray, "getEntriesByName", 1));
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "getEntriesByType", qjs.JS_NewCFunction(ctx, &jsReturnEmptyArray, "getEntriesByType", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "performance", perf_obj);

    // -- fetch() (native implementation) --
    _ = qjs.JS_SetPropertyStr(ctx, global, "fetch", qjs.JS_NewCFunction(ctx, &jsFetch, "fetch", 2));

    // -- WebSocket native helpers --
    _ = qjs.JS_SetPropertyStr(ctx, global, "__wsConnect", qjs.JS_NewCFunction(ctx, &jsWebSocketConnect, "__wsConnect", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__wsSend", qjs.JS_NewCFunction(ctx, &jsWebSocketSend, "__wsSend", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__wsClose", qjs.JS_NewCFunction(ctx, &jsWebSocketClose, "__wsClose", 1));

    // -- Worker native helpers --
    _ = qjs.JS_SetPropertyStr(ctx, global, "__workerCreate", qjs.JS_NewCFunction(ctx, &jsWorkerCreate, "__workerCreate", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__workerPost", qjs.JS_NewCFunction(ctx, &jsWorkerPostMessage, "__workerPost", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__workerTerminate", qjs.JS_NewCFunction(ctx, &jsWorkerTerminate, "__workerTerminate", 1));

    // -- atob() / btoa() --
    _ = qjs.JS_SetPropertyStr(ctx, global, "btoa", qjs.JS_NewCFunction(ctx, &jsBtoa, "btoa", 1));
    _ = qjs.JS_SetPropertyStr(ctx, global, "atob", qjs.JS_NewCFunction(ctx, &jsAtob, "atob", 1));

    // -- window.innerWidth / innerHeight / outerWidth / outerHeight (getters) --
    defineGetter(ctx, global, "innerWidth", &jsGetInnerWidth);
    defineGetter(ctx, global, "innerHeight", &jsGetInnerHeight);
    defineGetter(ctx, global, "outerWidth", &jsGetOuterWidth);
    defineGetter(ctx, global, "outerHeight", &jsGetOuterHeight);

    // -- navigator object --
    {
        const nav = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, nav, "userAgent", qjs.JS_NewString(ctx,
            "Mozilla/5.0 (Linux; aarch64) AppleWebKit/537.36 (KHTML, like Gecko) suzume/0.4"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "platform", qjs.JS_NewString(ctx, "Linux aarch64"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "language", qjs.JS_NewString(ctx, "ja"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "vendor", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "appName", qjs.JS_NewString(ctx, "Netscape"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "appVersion", qjs.JS_NewString(ctx, "5.0 (Linux)"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "product", qjs.JS_NewString(ctx, "Gecko"));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "onLine", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "cookieEnabled", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(ctx, nav, "maxTouchPoints", qjs.JS_NewInt32(ctx, 0));
        // languages array: ["ja", "en"]
        {
            const langs = qjs.JS_NewArray(ctx);
            _ = qjs.JS_SetPropertyUint32(ctx, langs, 0, qjs.JS_NewString(ctx, "ja"));
            _ = qjs.JS_SetPropertyUint32(ctx, langs, 1, qjs.JS_NewString(ctx, "en"));
            _ = qjs.JS_SetPropertyStr(ctx, nav, "languages", langs);
        }
        // geolocation stub
        {
            const geo = qjs.JS_NewObject(ctx);
            _ = qjs.JS_SetPropertyStr(ctx, geo, "getCurrentPosition",
                qjs.JS_NewCFunction(ctx, &jsNoOp, "getCurrentPosition", 1));
            _ = qjs.JS_SetPropertyStr(ctx, nav, "geolocation", geo);
        }
        _ = qjs.JS_SetPropertyStr(ctx, global, "navigator", nav);
    }

    // -- screen object --
    {
        const screen = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, screen, "width", qjs.JS_NewInt32(ctx, 720));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "height", qjs.JS_NewInt32(ctx, 720));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "availWidth", qjs.JS_NewInt32(ctx, 720));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "availHeight", qjs.JS_NewInt32(ctx, 720));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "colorDepth", qjs.JS_NewInt32(ctx, 24));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "pixelDepth", qjs.JS_NewInt32(ctx, 24));
        _ = qjs.JS_SetPropertyStr(ctx, screen, "orientation", qjs.JS_NewObject(ctx));
        _ = qjs.JS_SetPropertyStr(ctx, global, "screen", screen);
    }

    // -- location object --
    {
        const loc = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, loc, "href", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "protocol", qjs.JS_NewString(ctx, "https:"));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "host", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "hostname", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "port", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "pathname", qjs.JS_NewString(ctx, "/"));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "search", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "hash", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "origin", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "assign",
            qjs.JS_NewCFunction(ctx, &jsLocationAssign, "assign", 1));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "replace",
            qjs.JS_NewCFunction(ctx, &jsLocationAssign, "replace", 1));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "reload",
            qjs.JS_NewCFunction(ctx, &jsNoOp, "reload", 0));
        _ = qjs.JS_SetPropertyStr(ctx, global, "location", loc);
    }

    // -- URL class (JS-based) --
    evalInitScript(ctx, url_class_js, url_class_js.len);

    // -- queueMicrotask, structuredClone (JS-based) --
    evalInitScript(ctx, utility_apis_js, utility_apis_js.len);

    // -- Stub Web APIs for compatibility --
    // Note: window, navigator, screen, location are defined above in Zig.
    // matchMedia is improved to evaluate simple width queries using innerWidth.
    const compat_stubs =
        \\function Image(w,h){this.width=w||0;this.height=h||0;this.src='';this.onload=null;this.onerror=null;}
        \\
        \\(function(){
        \\  var origDefProp=Object.defineProperty;
        \\  Object.defineProperty=function(obj,prop,desc){
        \\    try{return origDefProp.call(Object,obj,prop,desc);}
        \\    catch(e){
        \\      if(e instanceof TypeError&&e.message&&e.message.indexOf('configurable')!==-1){
        \\        if(desc){
        \\          var newDesc={configurable:true,enumerable:!!desc.enumerable};
        \\          if('value'in desc){newDesc.value=desc.value;newDesc.writable=true;}
        \\          else{if(desc.get)newDesc.get=desc.get;if(desc.set)newDesc.set=desc.set;}
        \\          try{return origDefProp.call(Object,obj,prop,newDesc);}catch(e3){
        \\            try{if('value'in desc)obj[prop]=desc.value;}catch(e4){}
        \\          }
        \\        }
        \\        return obj;
        \\      }
        \\      throw e;
        \\    }
        \\  };
        \\})();
        \\if(typeof CSSStyleSheet==='undefined'||!CSSStyleSheet.prototype.replaceSync){
        \\  globalThis.CSSStyleSheet=globalThis.CSSStyleSheet||function(){this.cssRules=[];};
        \\  CSSStyleSheet.prototype.replaceSync=function(css){this._css=css;};
        \\  CSSStyleSheet.prototype.replace=function(css){this._css=css;return Promise.resolve(this);};
        \\}
        \\if(typeof CSSLayerBlockRule==='undefined'){globalThis.CSSLayerBlockRule=function(){};}
        \\if(typeof document!=='undefined'&&!document.adoptedStyleSheets){document.adoptedStyleSheets=[];}
        \\if(typeof self==='undefined'){globalThis.self=globalThis;}
        \\if(typeof window==='undefined'){globalThis.window=globalThis;}
        \\(function(){var _origGPO=Object.getPrototypeOf;Object.getPrototypeOf=function(o){if(o==null)return{};if(typeof o!=='object'&&typeof o!=='function')return _origGPO(Object(o));return _origGPO(o);};})();
        \\if(typeof customElements==='undefined'){
        \\  (function(){
        \\    var registry={};
        \\    function upgradeEl(el,ctor){
        \\      if(!el||el.__ce_upgraded)return;
        \\      el.__ce_upgraded=true;
        \\      var proto=ctor.prototype;
        \\      var names=Object.getOwnPropertyNames(proto);
        \\      for(var i=0;i<names.length;i++){
        \\        var k=names[i];
        \\        if(k==='constructor')continue;
        \\        try{var d=Object.getOwnPropertyDescriptor(proto,k);if(d&&(d.get||d.set)){Object.defineProperty(el,k,d);}else{el[k]=proto[k];}}catch(e){}
        \\      }
        \\      if(typeof el.connectedCallback==='function'&&el.isConnected){try{el.connectedCallback();}catch(e){}}
        \\    }
        \\    globalThis.__ce_registry=registry;
        \\    globalThis.__ce_upgradeEl=upgradeEl;
        \\    globalThis.customElements={
        \\      define:function(name,ctor,opts){
        \\        registry[name]=ctor;
        \\        try{
        \\          if(typeof document!=='undefined'&&document.querySelectorAll){
        \\            var els=document.querySelectorAll(name);
        \\            for(var i=0;i<els.length;i++)upgradeEl(els[i],ctor);
        \\          }
        \\        }catch(e){}
        \\      },
        \\      get:function(name){return registry[name];},
        \\      whenDefined:function(name){
        \\        if(registry[name])return Promise.resolve(registry[name]);
        \\        return new Promise(function(r){
        \\          var iv=setInterval(function(){if(registry[name]){clearInterval(iv);r(registry[name]);}},50);
        \\          setTimeout(function(){clearInterval(iv);r(undefined);},5000);
        \\        });
        \\      },
        \\      upgrade:function(el){
        \\        if(!el||!el.tagName)return;
        \\        var name=el.tagName.toLowerCase();
        \\        var ctor=registry[name];
        \\        if(ctor)upgradeEl(el,ctor);
        \\      }
        \\    };
        \\
        \\  })();
        \\}
        \\// MutationObserver: registered natively in Zig (events.zig)
        \\if(typeof IntersectionObserver==='undefined'){globalThis.IntersectionObserver=function(cb,opts){
        \\  this._cb=cb;this._opts=opts||{};this._observed=[];this._prevRatio=new Map();
        \\  this._disconnected=false;this._timer=null;this._scrollBound=false;
        \\  var threshold=this._opts.threshold;
        \\  if(typeof threshold==='number')threshold=[threshold];
        \\  if(!threshold||!threshold.length)threshold=[0];
        \\  this._thresholds=threshold.slice().sort();
        \\  var rmStr=this._opts.rootMargin||'0px';
        \\  var rmParts=rmStr.match(/-?\d+/g)||[0];
        \\  var t=parseInt(rmParts[0])||0,r=parseInt(rmParts[1]!==undefined?rmParts[1]:rmParts[0])||0;
        \\  var b=parseInt(rmParts[2]!==undefined?rmParts[2]:rmParts[0])||0,l=parseInt(rmParts[3]!==undefined?rmParts[3]:rmParts[1]!==undefined?rmParts[1]:rmParts[0])||0;
        \\  this._rm={t:t,r:r,b:b,l:l};
        \\  var self=this;
        \\  this._crossedThreshold=function(prevRatio,newRatio){
        \\    for(var i=0;i<self._thresholds.length;i++){
        \\      var th=self._thresholds[i];
        \\      if((prevRatio<th&&newRatio>=th)||(prevRatio>=th&&newRatio<th))return true;
        \\    }
        \\    return false;
        \\  };
        \\  this._check=function(){
        \\    if(self._disconnected||self._observed.length===0)return;
        \\    var entries=[];var vw=innerWidth||800,vh=innerHeight||600;
        \\    var rm=self._rm;
        \\    for(var i=0;i<self._observed.length;i++){
        \\      var el=self._observed[i];
        \\      var rect=el.getBoundingClientRect?el.getBoundingClientRect():{x:0,y:0,width:0,height:0,top:0,left:0,right:0,bottom:0};
        \\      var rootT=0-rm.t,rootL=0-rm.l,rootB=vh+rm.b,rootR=vw+rm.r;
        \\      var isIn=rect.bottom>=rootT&&rect.top<=rootB&&rect.right>=rootL&&rect.left<=rootR;
        \\      var ratio=0;
        \\      if(isIn&&rect.width>0&&rect.height>0){
        \\        var overlapX=Math.max(0,Math.min(rect.right,rootR)-Math.max(rect.left,rootL));
        \\        var overlapY=Math.max(0,Math.min(rect.bottom,rootB)-Math.max(rect.top,rootT));
        \\        ratio=Math.min((overlapX*overlapY)/(rect.width*rect.height),1);
        \\      }
        \\      var prevR=self._prevRatio.get(el);
        \\      if(prevR===undefined||self._crossedThreshold(prevR,ratio)){
        \\        self._prevRatio.set(el,ratio);
        \\        var ir=isIn?{x:Math.max(rect.x,rootL),y:Math.max(rect.y,rootT),
        \\          width:isIn?Math.max(0,Math.min(rect.right,rootR)-Math.max(rect.left,rootL)):0,
        \\          height:isIn?Math.max(0,Math.min(rect.bottom,rootB)-Math.max(rect.top,rootT)):0}:{x:0,y:0,width:0,height:0};
        \\        ir.top=ir.y;ir.left=ir.x;ir.right=ir.x+ir.width;ir.bottom=ir.y+ir.height;
        \\        entries.push({target:el,isIntersecting:isIn,intersectionRatio:ratio,
        \\          boundingClientRect:rect,intersectionRect:ir,
        \\          rootBounds:{x:0,y:0,width:vw,height:vh,top:0,left:0,right:vw,bottom:vh},
        \\          time:(typeof performance!=='undefined'?performance.now():Date.now())});
        \\      }
        \\    }
        \\    if(entries.length>0){try{self._cb(entries,self);}catch(e){}}
        \\  };
        \\  this._scrollHandler=function(){if(!self._disconnected)setTimeout(self._check,0);};
        \\  this._startPolling=function(){
        \\    if(!self._scrollBound){
        \\      self._scrollBound=true;
        \\      addEventListener('scroll',self._scrollHandler,{passive:true});
        \\    }
        \\    if(self._timer)return;
        \\    self._timer=setInterval(self._check,250);
        \\  };
        \\  this.observe=function(el){
        \\    if(this._disconnected||!el)return;
        \\    this._observed.push(el);
        \\    var self2=this;
        \\    setTimeout(function(){self2._check();self2._startPolling();},0);
        \\  };
        \\  this.unobserve=function(el){
        \\    this._observed=this._observed.filter(function(e){return e!==el;});
        \\    this._prevRatio.delete(el);
        \\    if(this._observed.length===0&&this._timer){clearInterval(this._timer);this._timer=null;}
        \\  };
        \\  this.disconnect=function(){
        \\    this._disconnected=true;this._observed=[];this._prevRatio.clear();
        \\    if(this._timer){clearInterval(this._timer);this._timer=null;}
        \\    if(this._scrollBound){removeEventListener('scroll',this._scrollHandler);this._scrollBound=false;}
        \\  };
        \\  this.takeRecords=function(){return[];};
        \\};}
        \\if(typeof ResizeObserver==='undefined'){globalThis.ResizeObserver=function(cb){this._cb=cb;this.observe=function(){};this.disconnect=function(){};this.unobserve=function(){};};}
        \\globalThis.matchMedia=function(q){
        \\  var w=innerWidth,matches=false,m;
        \\  m=q.match(/\(max-width:\s*(\d+)px\)/);if(m)matches=(w<=parseInt(m[1]));
        \\  m=q.match(/\(min-width:\s*(\d+)px\)/);if(m)matches=(w>=parseInt(m[1]));
        \\  m=q.match(/\(max-height:\s*(\d+)px\)/);if(m)matches=(innerHeight<=parseInt(m[1]));
        \\  m=q.match(/\(min-height:\s*(\d+)px\)/);if(m)matches=(innerHeight>=parseInt(m[1]));
        \\  if(q==='(prefers-color-scheme:dark)'||q==='(prefers-color-scheme: dark)')matches=true;
        \\  if(q==='not all')matches=false;
        \\  if(q.indexOf('prefers-reduced-motion')>=0)matches=false;
        \\  if(q.indexOf('pointer: fine')>=0||q.indexOf('pointer:fine')>=0)matches=true;
        \\  if(q.indexOf('hover: hover')>=0||q.indexOf('hover:hover')>=0)matches=true;
        \\  var mql={matches:matches,media:q,_listeners:[]};
        \\  mql.addListener=function(fn){if(fn)this._listeners.push({fn:fn,wrap:null});};
        \\  mql.removeListener=function(fn){this._listeners=this._listeners.filter(function(e){return e.fn!==fn;});};
        \\  mql.addEventListener=function(type,fn){if(type==='change'&&fn)this._listeners.push({fn:fn,wrap:null});};
        \\  mql.removeEventListener=function(type,fn){if(type==='change')this._listeners=this._listeners.filter(function(e){return e.fn!==fn;});};
        \\  mql.dispatchEvent=function(e){this._listeners.forEach(function(l){try{l.fn(e);}catch(ex){}});return true;};
        \\  mql.onchange=null;
        \\  return mql;
        \\};
        \\if(typeof getComputedStyle==='undefined'){globalThis.getComputedStyle=function(el){return new Proxy({},{get:function(_,p){return'';}});};}
        \\if(typeof requestIdleCallback==='undefined'){globalThis.requestIdleCallback=function(cb){return setTimeout(cb,1);};}
        \\if(typeof cancelIdleCallback==='undefined'){globalThis.cancelIdleCallback=function(id){clearTimeout(id);};}
        \\if(typeof localStorage==='undefined'){
        \\  var _ls={};globalThis.localStorage={getItem:function(k){return _ls[k]||null;},setItem:function(k,v){_ls[k]=String(v);},removeItem:function(k){delete _ls[k];},clear:function(){_ls={};},get length(){return Object.keys(_ls).length;},key:function(i){return Object.keys(_ls)[i]||null;}};
        \\}
        \\if(typeof sessionStorage==='undefined'){
        \\  var _ss={};globalThis.sessionStorage={getItem:function(k){return _ss[k]||null;},setItem:function(k,v){_ss[k]=String(v);},removeItem:function(k){delete _ss[k];},clear:function(){_ss={};},get length(){return Object.keys(_ss).length;},key:function(i){return Object.keys(_ss)[i]||null;}};
        \\}


        \\if(typeof XMLHttpRequest==='undefined'){
        \\  globalThis.XMLHttpRequest=function(){
        \\    this.readyState=0;this.status=0;this.statusText='';this.responseText='';this.responseURL='';
        \\    this.response='';this.responseType='';this._method='GET';this._url='';this._headers={};this._async=true;
        \\    this.onreadystatechange=null;this.onload=null;this.onerror=null;this.onprogress=null;this.ontimeout=null;
        \\    this._listeners={};this.timeout=0;this.withCredentials=false;
        \\  };
        \\  XMLHttpRequest.UNSENT=0;XMLHttpRequest.OPENED=1;XMLHttpRequest.HEADERS_RECEIVED=2;
        \\  XMLHttpRequest.LOADING=3;XMLHttpRequest.DONE=4;
        \\  XMLHttpRequest.prototype.open=function(method,url,async_){this._method=method;this._url=url;this._async=async_!==false;this.readyState=1;this._fireReadyState();};
        \\  XMLHttpRequest.prototype.setRequestHeader=function(name,value){this._headers[name]=value;};
        \\  XMLHttpRequest.prototype.getResponseHeader=function(name){return this._responseHeaders?this._responseHeaders[name.toLowerCase()]||null:null;};
        \\  XMLHttpRequest.prototype.getAllResponseHeaders=function(){if(!this._responseHeaders)return'';var r='';for(var k in this._responseHeaders)r+=k+': '+this._responseHeaders[k]+'\r\n';return r;};
        \\  XMLHttpRequest.prototype.send=function(body){
        \\    var self=this,opts={method:this._method,headers:this._headers};
        \\    if(body)opts.body=body;
        \\    fetch(this._url,opts).then(function(resp){
        \\      self.status=resp.status;self.statusText=resp.statusText||'';self.responseURL=resp.url||self._url;
        \\      self._responseHeaders={};if(resp.headers&&resp.headers.forEach)resp.headers.forEach(function(v,k){self._responseHeaders[k]=v;});
        \\      self.readyState=2;self._fireReadyState();
        \\      return resp.text();
        \\    }).then(function(text){
        \\      self.readyState=3;self._fireReadyState();
        \\      self.responseText=text;self.response=self.responseType==='json'?(function(){try{return JSON.parse(text);}catch(e){return null;}})():text;
        \\      self.readyState=4;self._fireReadyState();
        \\      if(self.onload)try{self.onload({target:self,type:'load'});}catch(e){}
        \\      self._fire('load',{target:self});
        \\    })['catch'](function(err){
        \\      self.readyState=4;self.status=0;self._fireReadyState();
        \\      if(self.onerror)try{self.onerror({target:self,type:'error'});}catch(e){}
        \\      self._fire('error',{target:self});
        \\    });
        \\  };
        \\  XMLHttpRequest.prototype.abort=function(){this.readyState=0;};
        \\  XMLHttpRequest.prototype.addEventListener=function(type,fn){if(!this._listeners[type])this._listeners[type]=[];this._listeners[type].push(fn);};
        \\  XMLHttpRequest.prototype.removeEventListener=function(type,fn){if(!this._listeners[type])return;this._listeners[type]=this._listeners[type].filter(function(f){return f!==fn;});};
        \\  XMLHttpRequest.prototype._fire=function(type,evt){if(!this._listeners[type])return;for(var i=0;i<this._listeners[type].length;i++)try{this._listeners[type][i](evt);}catch(e){}};
        \\  XMLHttpRequest.prototype._fireReadyState=function(){if(this.onreadystatechange)try{this.onreadystatechange({target:this});}catch(e){}this._fire('readystatechange',{target:this});};
        \\  XMLHttpRequest.prototype.overrideMimeType=function(){};
        \\  XMLHttpRequest.prototype.dispatchEvent=function(e){this._fire(e.type,e);};
        \\}
        \\if(typeof DOMParser==='undefined'){
        \\  globalThis.DOMParser=function(){};
        \\  DOMParser.prototype.parseFromString=function(str,type){
        \\    if(!type||type==='text/html'){
        \\      var container=document.createElement('div');
        \\      container.innerHTML=str;
        \\      var body=container;
        \\      var headEl=null;
        \\      var bodyEl=null;
        \\      for(var i=0;i<container.childNodes.length;i++){
        \\        var ch=container.childNodes[i];
        \\        if(ch.tagName==='HEAD')headEl=ch;
        \\        if(ch.tagName==='BODY')bodyEl=ch;
        \\      }
        \\      var fakeDoc={
        \\        documentElement:container,
        \\        body:bodyEl||container,
        \\        head:headEl||null,
        \\        childNodes:container.childNodes,
        \\        firstChild:container.firstChild,
        \\        querySelector:function(s){return container.querySelector(s);},
        \\        querySelectorAll:function(s){return container.querySelectorAll(s);},
        \\        getElementById:function(id){return container.querySelector('#'+id);},
        \\        getElementsByTagName:function(t){return container.querySelectorAll(t);},
        \\        getElementsByClassName:function(c){return container.querySelectorAll('.'+c);},
        \\        createElement:function(t){return document.createElement(t);},
        \\        createTextNode:function(t){return document.createTextNode(t);},
        \\        createDocumentFragment:function(){return document.createDocumentFragment();}
        \\      };
        \\      return fakeDoc;
        \\    }
        \\    return null;
        \\  };
        \\}
        \\if(typeof history==='undefined'){
        \\  globalThis.history=(function(){
        \\    var stack=[{state:null,url:location.href}],idx=0;
        \\    function syncLoc(url){
        \\      location.href=url;location.pathname=url.replace(/^https?:\/\/[^\/]*/,'').replace(/[?#].*/,'');
        \\      location.search=(url.indexOf('?')>=0?url.slice(url.indexOf('?')).replace(/#.*/,''):'');
        \\      location.hash=(url.indexOf('#')>=0?url.slice(url.indexOf('#')):'');
        \\      if(typeof __suzume_update_url==='function')__suzume_update_url(url);
        \\    }
        \\    return {
        \\      pushState:function(state,title,url){
        \\        if(url){stack=stack.slice(0,idx+1);stack.push({state:state,url:url});idx=stack.length-1;syncLoc(url);}
        \\      },
        \\      replaceState:function(state,title,url){if(url){stack[idx]={state:state,url:url};syncLoc(url);}},
        \\      back:function(){if(idx>0){idx--;syncLoc(stack[idx].url);var e=new Event('popstate');e.state=stack[idx].state;dispatchEvent(e);}},
        \\      forward:function(){if(idx<stack.length-1){idx++;syncLoc(stack[idx].url);var e=new Event('popstate');e.state=stack[idx].state;dispatchEvent(e);}},
        \\      go:function(n){var ni=idx+n;if(ni>=0&&ni<stack.length){idx=ni;syncLoc(stack[ni].url);var e=new Event('popstate');e.state=stack[ni].state;dispatchEvent(e);}},
        \\      get length(){return stack.length;},
        \\      get state(){return stack[idx].state;}
        \\    };
        \\  })();
        \\}
        \\if(typeof dispatchEvent==='undefined'){globalThis.dispatchEvent=function(e){return true;};}
        \\if(typeof FormData==='undefined'){
        \\  globalThis.FormData=function(form){this._data=[];};
        \\  FormData.prototype.append=function(k,v){this._data.push([k,v]);};
        \\  FormData.prototype.get=function(k){for(var i=0;i<this._data.length;i++)if(this._data[i][0]===k)return this._data[i][1];return null;};
        \\  FormData.prototype.has=function(k){return this._data.some(function(p){return p[0]===k;});};
        \\  FormData.prototype.set=function(k,v){for(var i=0;i<this._data.length;i++)if(this._data[i][0]===k){this._data[i][1]=v;return;}this._data.push([k,v]);};
        \\  FormData.prototype.delete=function(k){this._data=this._data.filter(function(p){return p[0]!==k;});};
        \\  FormData.prototype.getAll=function(k){return this._data.filter(function(p){return p[0]===k;}).map(function(p){return p[1];});};
        \\  FormData.prototype.forEach=function(cb,thisArg){this._data.forEach(function(p){cb.call(thisArg,p[1],p[0],this);}.bind(this));};
        \\  FormData.prototype.entries=function(){var d=this._data,i=0;return{next:function(){return i<d.length?{done:false,value:d[i++]}:{done:true};},__proto__:{[Symbol.iterator]:function(){return this;}}};};
        \\  FormData.prototype.keys=function(){var d=this._data,i=0;return{next:function(){return i<d.length?{done:false,value:d[i++][0]}:{done:true};},__proto__:{[Symbol.iterator]:function(){return this;}}};};
        \\  FormData.prototype.values=function(){var d=this._data,i=0;return{next:function(){return i<d.length?{done:false,value:d[i++][1]}:{done:true};},__proto__:{[Symbol.iterator]:function(){return this;}}};};
        \\  FormData.prototype[Symbol.iterator]=function(){return this.entries();};
        \\}
        \\if(typeof URLSearchParams==='undefined'){
        \\  globalThis.URLSearchParams=function(init){
        \\    this._params=[];
        \\    if(typeof init==='string'){
        \\      var s=init.replace(/^\?/,'');
        \\      if(s)s.split('&').forEach(function(p){var kv=p.split('=');this._params.push([decodeURIComponent(kv[0]),decodeURIComponent(kv[1]||'')]);}.bind(this));
        \\    }
        \\  };
        \\  var USPp=URLSearchParams.prototype;
        \\  USPp.get=function(n){for(var i=0;i<this._params.length;i++)if(this._params[i][0]===n)return this._params[i][1];return null;};
        \\  USPp.has=function(n){for(var i=0;i<this._params.length;i++)if(this._params[i][0]===n)return true;return false;};
        \\  USPp.set=function(n,v){for(var i=0;i<this._params.length;i++)if(this._params[i][0]===n){this._params[i][1]=String(v);return;}this._params.push([n,String(v)]);};
        \\  USPp.append=function(n,v){this._params.push([n,String(v)]);};
        \\  USPp.delete=function(n){this._params=this._params.filter(function(p){return p[0]!==n;});};
        \\  USPp.toString=function(){return this._params.map(function(p){return encodeURIComponent(p[0])+'='+encodeURIComponent(p[1]);}).join('&');};
        \\  USPp.forEach=function(cb){this._params.forEach(function(p){cb(p[1],p[0]);});};
        \\  USPp.entries=function(){return this._params[Symbol.iterator]?this._params[Symbol.iterator]():this._params;};
        \\  USPp.keys=function(){return this._params.map(function(p){return p[0];});};
        \\  USPp.values=function(){return this._params.map(function(p){return p[1];});};
        \\  USPp.getAll=function(n){return this._params.filter(function(p){return p[0]===n;}).map(function(p){return p[1];});};
        \\}
        \\if(typeof Event==='undefined'){globalThis.Event=function(type,opts){this.type=type;this.bubbles=!!(opts&&opts.bubbles);this.cancelable=!!(opts&&opts.cancelable);this.defaultPrevented=false;this.eventPhase=0;this.target=null;this.currentTarget=null;this.isTrusted=false;this.timeStamp=Date.now();this.preventDefault=function(){if(this.cancelable)this.defaultPrevented=true;};this.stopPropagation=function(){};this.stopImmediatePropagation=function(){};this.composedPath=function(){return[];};};}
        \\if(typeof CustomEvent==='undefined'){globalThis.CustomEvent=function(type,opts){Event.call(this,type,opts);this.detail=(opts&&opts.detail!==undefined)?opts.detail:null;};CustomEvent.prototype=Object.create(Event.prototype);CustomEvent.prototype.constructor=CustomEvent;}
        \\if(typeof Headers==='undefined'){globalThis.Headers=function(init){this._h={};if(init)for(var k in init)this._h[k.toLowerCase()]=init[k];};Headers.prototype.get=function(n){return this._h[n.toLowerCase()]||null;};Headers.prototype.set=function(n,v){this._h[n.toLowerCase()]=v;};Headers.prototype.has=function(n){return n.toLowerCase() in this._h;};Headers.prototype.forEach=function(cb){for(var k in this._h)cb(this._h[k],k);};}
        \\if(typeof Response==='undefined'){globalThis.Response=function(body,opts){this.body=body;this.status=(opts&&opts.status)||200;this.ok=this.status>=200&&this.status<300;this.headers=new Headers((opts&&opts.headers)||{});this.text=function(){return Promise.resolve(String(body||''));};this.json=function(){return Promise.resolve(JSON.parse(body||'null'));};};}
        \\if(typeof window!=='undefined'&&!window.onerror){window.onerror=function(){};}
        \\if(typeof devicePixelRatio==='undefined'){globalThis.devicePixelRatio=1;}
        \\if(typeof visualViewport==='undefined'){globalThis.visualViewport={width:innerWidth,height:innerHeight,offsetLeft:0,offsetTop:0,scale:1,addEventListener:function(){}};}
        \\if(typeof CSS==='undefined'){
        \\  var _cssprops='display,position,color,background,background-color,background-image,background-size,background-position,background-repeat,margin,margin-top,margin-right,margin-bottom,margin-left,padding,padding-top,padding-right,padding-bottom,padding-left,border,border-top,border-right,border-bottom,border-left,border-color,border-width,border-style,border-radius,width,height,min-width,min-height,max-width,max-height,top,right,bottom,left,float,clear,overflow,overflow-x,overflow-y,z-index,opacity,visibility,cursor,pointer-events,flex,flex-direction,flex-wrap,flex-grow,flex-shrink,flex-basis,justify-content,align-items,align-self,align-content,order,gap,row-gap,column-gap,grid,grid-template-columns,grid-template-rows,grid-column,grid-row,grid-area,grid-gap,font,font-size,font-weight,font-family,font-style,text-align,text-decoration,text-transform,text-overflow,line-height,letter-spacing,word-spacing,white-space,vertical-align,list-style,list-style-type,table-layout,border-collapse,outline,box-shadow,text-shadow,transform,transition,animation,content,box-sizing,object-fit,object-position,resize,user-select,appearance,filter,backdrop-filter,clip-path,will-change,contain,aspect-ratio,accent-color,container-type,container-name,scroll-behavior,overscroll-behavior,touch-action,isolation';
        \\  var _csspropset={};_cssprops.split(',').forEach(function(p){_csspropset[p]=true;});
        \\  globalThis.CSS={
        \\    supports:function(prop,val){
        \\      if(arguments.length===1){
        \\        var s=prop;if(s.indexOf(':')>=0){var parts=s.split(':');prop=parts[0].trim().replace(/^\(/,'');return !!_csspropset[prop];}
        \\        return false;
        \\      }
        \\      return !!_csspropset[prop];
        \\    },
        \\    escape:function(s){return s.replace(/([^\w-])/g,'\\$1');}
        \\  };
        \\}
        \\if(typeof WebSocket==='undefined'){
        \\  globalThis.WebSocket=function(url,protocols){
        \\    this.url=url;this.readyState=0;this.onopen=null;this.onmessage=null;this.onclose=null;this.onerror=null;
        \\    this.CONNECTING=0;this.OPEN=1;this.CLOSING=2;this.CLOSED=3;
        \\    this.bufferedAmount=0;this.extensions='';this.protocol=protocols||'';
        \\    var self=this;
        \\    var id=__wsConnect(url,this);
        \\    if(id<0){this.readyState=3;setTimeout(function(){if(self.onerror)self.onerror({type:'error'});if(self.onclose)self.onclose({type:'close',code:1006,reason:'Connection failed'});},0);return;}
        \\    this._id=id;this.readyState=1;
        \\    setTimeout(function(){if(self.onopen)self.onopen({type:'open'});},0);
        \\  };
        \\  WebSocket.CONNECTING=0;WebSocket.OPEN=1;WebSocket.CLOSING=2;WebSocket.CLOSED=3;
        \\  WebSocket.prototype.send=function(data){if(this.readyState!==1)throw new Error('WebSocket not open');__wsSend(this._id,String(data));};
        \\  WebSocket.prototype.close=function(code,reason){this.readyState=2;__wsClose(this._id);};
        \\  WebSocket.prototype.addEventListener=function(type,fn){this['on'+type]=fn;};
        \\  WebSocket.prototype.removeEventListener=function(){};
        \\}
        \\if(typeof CSSStyleDeclaration==='undefined'){globalThis.CSSStyleDeclaration=function(){};CSSStyleDeclaration.prototype.getPropertyValue=function(n){return this[n]||'';};CSSStyleDeclaration.prototype.setProperty=function(n,v){this[n]=v;};CSSStyleDeclaration.prototype.removeProperty=function(n){delete this[n];return'';};}
        \\if(typeof Worker==='undefined'){
        \\  globalThis.Worker=function(urlOrBlob){
        \\    this.onmessage=null;this.onerror=null;this._terminated=false;
        \\    var script='';
        \\    if(urlOrBlob instanceof Blob){script=urlOrBlob._data||'';}
        \\    else if(typeof urlOrBlob==='string'&&urlOrBlob.indexOf('blob:')===0){script='';}
        \\    else{script='// URL worker: '+urlOrBlob;}
        \\    var self=this;
        \\    this._id=__workerCreate(script,this);
        \\  };
        \\  Worker.prototype.postMessage=function(data){if(!this._terminated)__workerPost(this._id,JSON.stringify(data));};
        \\  Worker.prototype.terminate=function(){this._terminated=true;__workerTerminate(this._id);};
        \\  Worker.prototype.addEventListener=function(type,fn){if(type==='message')this.onmessage=fn;if(type==='error')this.onerror=fn;};
        \\  Worker.prototype.removeEventListener=function(){};
        \\}
        \\if(typeof console!=='undefined'&&!console.warn){console.warn=console.log;console.error=console.log;console.info=console.log;console.debug=console.log;console.trace=function(){};}
        \\if(typeof document!=='undefined'){
        \\  if(!document.getElementsByClassName)document.getElementsByClassName=function(n){return document.querySelectorAll('.'+n);};
        \\  if(!document.getElementsByTagName)document.getElementsByTagName=function(n){return document.querySelectorAll(n);};
        \\  if(!document.getElementsByName)document.getElementsByName=function(n){return document.querySelectorAll('[name=\"'+n+'\"]');};
        \\}
        \\if(typeof getSelection==='undefined'){globalThis.getSelection=function(){return{toString:function(){return'';},rangeCount:0,getRangeAt:function(){return null;},removeAllRanges:function(){},addRange:function(){},isCollapsed:true,type:'None'};};}

        \\if(typeof queueMicrotask==='undefined'){globalThis.queueMicrotask=function(cb){Promise.resolve().then(cb);};}
        \\if(typeof structuredClone==='undefined'){globalThis.structuredClone=function(o){return JSON.parse(JSON.stringify(o));};}
        \\if(typeof Atomics!=='undefined'&&!Atomics.waitAsync){
        \\  Atomics.waitAsync=function(ta,index,value,timeout){
        \\    try{var r=Atomics.wait(ta,index,value,typeof timeout==='number'?timeout:0);
        \\      return{async:false,value:r};}
        \\    catch(e){return{async:true,value:Promise.resolve('ok')};}
        \\  };
        \\}
        \\if(typeof TextEncoder==='undefined'){
        \\  globalThis.TextEncoder=function(){};
        \\  TextEncoder.prototype.encode=function(s){
        \\    var a=[];for(var i=0;i<s.length;i++){var c=s.charCodeAt(i);
        \\      if(c<0x80)a.push(c);else if(c<0x800){a.push(0xC0|(c>>6));a.push(0x80|(c&0x3F));}
        \\      else{a.push(0xE0|(c>>12));a.push(0x80|((c>>6)&0x3F));a.push(0x80|(c&0x3F));}
        \\    }return new Uint8Array(a);
        \\  };
        \\  TextEncoder.prototype.encoding='utf-8';
        \\}
        \\if(typeof TextDecoder==='undefined'){
        \\  globalThis.TextDecoder=function(enc){this.encoding=enc||'utf-8';};
        \\  TextDecoder.prototype.decode=function(buf){
        \\    if(!buf||buf.length===0)return'';var a=buf instanceof Uint8Array?buf:new Uint8Array(buf);
        \\    var s='',i=0;while(i<a.length){var b=a[i];
        \\      if(b<0x80){s+=String.fromCharCode(b);i++;}
        \\      else if(b<0xE0){s+=String.fromCharCode(((b&0x1F)<<6)|(a[i+1]&0x3F));i+=2;}
        \\      else if(b<0xF0){s+=String.fromCharCode(((b&0x0F)<<12)|((a[i+1]&0x3F)<<6)|(a[i+2]&0x3F));i+=3;}
        \\      else{var cp=((b&0x07)<<18)|((a[i+1]&0x3F)<<12)|((a[i+2]&0x3F)<<6)|(a[i+3]&0x3F);
        \\        cp-=0x10000;s+=String.fromCharCode(0xD800+(cp>>10),0xDC00+(cp&0x3FF));i+=4;}
        \\    }return s;
        \\  };
        \\}
        \\if(typeof AbortController==='undefined'){
        \\  globalThis.AbortSignal=function(){this.aborted=false;this._listeners=[];};
        \\  AbortSignal.prototype.addEventListener=function(t,fn){this._listeners.push(fn);};
        \\  AbortSignal.prototype.removeEventListener=function(){};
        \\  globalThis.AbortController=function(){this.signal=new AbortSignal();};
        \\  AbortController.prototype.abort=function(){this.signal.aborted=true;this.signal._listeners.forEach(function(fn){try{fn();}catch(e){}});};
        \\}
        \\if(typeof atob==='undefined'){
        \\  globalThis.atob=function(s){var b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=',r='',i=0;s=s.replace(/[^A-Za-z0-9\+\/\=]/g,'');
        \\    while(i<s.length){var e1=b.indexOf(s.charAt(i++)),e2=b.indexOf(s.charAt(i++)),e3=b.indexOf(s.charAt(i++)),e4=b.indexOf(s.charAt(i++));
        \\      r+=String.fromCharCode((e1<<2)|(e2>>4));if(e3!==64)r+=String.fromCharCode(((e2&15)<<4)|(e3>>2));if(e4!==64)r+=String.fromCharCode(((e3&3)<<6)|e4);}return r;};
        \\  globalThis.btoa=function(s){var b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=',r='',i=0;
        \\    while(i<s.length){var c1=s.charCodeAt(i++),c2=s.charCodeAt(i++),c3=s.charCodeAt(i++);
        \\      r+=b.charAt(c1>>2)+b.charAt(((c1&3)<<4)|(c2>>4));r+=(isNaN(c2)?'=':b.charAt(((c2&15)<<2)|(c3>>4)));r+=(isNaN(c3)?'=':b.charAt(c3&63));}return r;};
        \\}
        \\if(typeof requestIdleCallback==='undefined'){
        \\  globalThis.requestIdleCallback=function(cb){return setTimeout(function(){cb({didTimeout:false,timeRemaining:function(){return 50;}});},1);};
        \\  globalThis.cancelIdleCallback=function(id){clearTimeout(id);};
        \\}
        \\if(typeof Intl==='undefined'){
        \\  globalThis.Intl={};
        \\  Intl.DateTimeFormat=function(locale,opts){this._locale=locale||'en';this._opts=opts||{};};
        \\  Intl.DateTimeFormat.prototype.format=function(d){
        \\    if(!d)d=new Date();var o=this._opts;
        \\    var p=function(n){return n<10?'0'+n:''+n;};
        \\    if(o.dateStyle==='short')return p(d.getMonth()+1)+'/'+p(d.getDate())+'/'+d.getFullYear();
        \\    if(o.dateStyle==='medium'){var m=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];return m[d.getMonth()]+' '+d.getDate()+', '+d.getFullYear();}
        \\    if(o.timeStyle==='short')return p(d.getHours())+':'+p(d.getMinutes());
        \\    if(o.year||o.month||o.day){var r='';if(o.year)r+=d.getFullYear();if(o.month){if(r)r+='-';r+=p(d.getMonth()+1);}if(o.day){if(r)r+='-';r+=p(d.getDate());}return r;}
        \\    return d.toLocaleDateString();
        \\  };
        \\  Intl.DateTimeFormat.prototype.resolvedOptions=function(){return{locale:this._locale,calendar:'gregory',numberingSystem:'latn',timeZone:'UTC'};};
        \\  Intl.DateTimeFormat.prototype.formatToParts=function(d){return[{type:'literal',value:this.format(d)}];};
        \\  Intl.NumberFormat=function(locale,opts){this._locale=locale||'en';this._opts=opts||{};};
        \\  Intl.NumberFormat.prototype.format=function(n){
        \\    var o=this._opts;
        \\    if(o.style==='currency'){var c=o.currency||'USD';var s=n.toFixed(o.maximumFractionDigits||2);return c+' '+s.replace(/\B(?=(\d{3})+(?!\d))/g,',');}
        \\    if(o.style==='percent')return(n*100).toFixed(o.maximumFractionDigits||0)+'%';
        \\    if(o.minimumFractionDigits!==undefined||o.maximumFractionDigits!==undefined){var fd=o.maximumFractionDigits||o.minimumFractionDigits||0;return n.toFixed(fd).replace(/\B(?=(\d{3})+(?!\d))/g,',');}
        \\    if(typeof n==='number'&&n===Math.floor(n))return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g,',');
        \\    return n.toLocaleString();
        \\  };
        \\  Intl.NumberFormat.prototype.resolvedOptions=function(){return{locale:this._locale,numberingSystem:'latn',style:this._opts.style||'decimal'};};
        \\  Intl.NumberFormat.prototype.formatToParts=function(n){return[{type:'integer',value:this.format(n)}];};
        \\  Intl.PluralRules=function(){};Intl.PluralRules.prototype.select=function(n){return n===1?'one':'other';};
        \\  Intl.PluralRules.prototype.resolvedOptions=function(){return{locale:'en',type:'cardinal'};};
        \\  Intl.Collator=function(l,o){this._locale=l;this._opts=o||{};};
        \\  Intl.Collator.prototype.compare=function(a,b){return a<b?-1:a>b?1:0;};
        \\  Intl.RelativeTimeFormat=function(l,o){this._locale=l;this._opts=o||{};};
        \\  Intl.RelativeTimeFormat.prototype.format=function(v,u){var a=Math.abs(v);return v<0?a+' '+u+'s ago':'in '+a+' '+u+'s';};
        \\  Intl.ListFormat=function(l,o){this._opts=o||{};};
        \\  Intl.ListFormat.prototype.format=function(list){return list.join(', ');};
        \\}
        \\if(typeof Blob==='undefined'){
        \\  globalThis.Blob=function(parts,opts){
        \\    this.type=(opts&&opts.type)||'';
        \\    var s='';if(parts)for(var i=0;i<parts.length;i++)s+=typeof parts[i]==='string'?parts[i]:String(parts[i]);
        \\    this._data=s;this.size=s.length;
        \\  };
        \\  Blob.prototype.text=function(){return Promise.resolve(this._data);};
        \\  Blob.prototype.arrayBuffer=function(){var b=new ArrayBuffer(this._data.length);var v=new Uint8Array(b);for(var i=0;i<this._data.length;i++)v[i]=this._data.charCodeAt(i);return Promise.resolve(b);};
        \\  Blob.prototype.slice=function(s,e,t){return new Blob([this._data.slice(s,e)],{type:t||this.type});};
        \\}
        \\if(typeof crypto==='undefined'){
        \\  globalThis.crypto={
        \\    getRandomValues:function(arr){for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*256);return arr;},
        \\    randomUUID:function(){var h='0123456789abcdef',s='';for(var i=0;i<36;i++){if(i===8||i===13||i===18||i===23)s+='-';else if(i===14)s+='4';else if(i===19)s+=h[8+(Math.random()*4|0)];else s+=h[Math.random()*16|0];}return s;},
        \\    subtle:{digest:function(){return Promise.reject('not implemented');},encrypt:function(){return Promise.reject('not implemented');}}
        \\  };
        \\}
        \\if(typeof NodeFilter==='undefined'){
        \\  globalThis.NodeFilter={SHOW_ALL:0xFFFFFFFF,SHOW_ELEMENT:0x1,SHOW_ATTRIBUTE:0x2,SHOW_TEXT:0x4,SHOW_CDATA_SECTION:0x8,SHOW_PROCESSING_INSTRUCTION:0x40,SHOW_COMMENT:0x80,SHOW_DOCUMENT:0x100,SHOW_DOCUMENT_TYPE:0x200,SHOW_DOCUMENT_FRAGMENT:0x400,FILTER_ACCEPT:1,FILTER_REJECT:2,FILTER_SKIP:3};
        \\}
    ;
    evalInitScript(ctx, compat_stubs, compat_stubs.len);
}
