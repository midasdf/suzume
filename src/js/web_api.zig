const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;

// ── Timer system ────────────────────────────────────────────────────

const TimerEntry = struct {
    id: u32,
    callback: qjs.JSValue,
    delay_ms: u32,
    interval: bool,
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
            const saved_callback = entry.callback;
            const saved_id = entry.id;
            const saved_interval = entry.interval;
            const saved_delay = entry.delay_ms;

            // Fire the callback (may trigger timer_list append/realloc)
            const ret = qjs.JS_Call(ctx, saved_callback, quickjs.JS_UNDEFINED(), 0, null);
            qjs.JS_FreeValue(ctx, ret);

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

    return any_active;
}

/// Check if any timers are pending.
pub fn hasTimers() bool {
    for (timer_list.items) |entry| {
        if (!entry.cleared) return true;
    }
    return false;
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

fn jsPerformanceNow(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (perf_origin == 0) perf_origin = currentTimeMs();
    const elapsed: f64 = @floatFromInt(currentTimeMs() - perf_origin);
    return qjs.JS_NewFloat64(c, elapsed);
}

// ── Registration ────────────────────────────────────────────────────

pub fn registerWebApis(js_rt: anytype) void {
    const ctx = js_rt.ctx;
    global_ctx = ctx;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

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

    // -- performance.now() --
    const perf_obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, perf_obj, "now", qjs.JS_NewCFunction(ctx, &jsPerformanceNow, "now", 0));
    _ = qjs.JS_SetPropertyStr(ctx, global, "performance", perf_obj);
}
