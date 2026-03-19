const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;

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
            qjs.JS_NewCFunction(ctx, &jsNoOp, "assign", 1));
        _ = qjs.JS_SetPropertyStr(ctx, loc, "replace",
            qjs.JS_NewCFunction(ctx, &jsNoOp, "replace", 1));
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
        \\if(typeof self==='undefined'){globalThis.self=globalThis;}
        \\if(typeof window==='undefined'){globalThis.window=globalThis;}
        \\if(typeof customElements==='undefined'){
        \\  globalThis.customElements={define:function(){},get:function(){return undefined},whenDefined:function(){return Promise.resolve()},upgrade:function(){}};
        \\}
        \\if(typeof MutationObserver==='undefined'){globalThis.MutationObserver=function(cb){this._cb=cb;this.observe=function(){};this.disconnect=function(){};this.takeRecords=function(){return[];};};}
        \\if(typeof IntersectionObserver==='undefined'){globalThis.IntersectionObserver=function(cb){this._cb=cb;this.observe=function(){};this.disconnect=function(){};this.unobserve=function(){};};}
        \\if(typeof ResizeObserver==='undefined'){globalThis.ResizeObserver=function(cb){this._cb=cb;this.observe=function(){};this.disconnect=function(){};this.unobserve=function(){};};}
        \\globalThis.matchMedia=function(q){
        \\  var w=innerWidth,matches=false,m;
        \\  m=q.match(/\(max-width:\s*(\d+)px\)/);if(m)matches=(w<=parseInt(m[1]));
        \\  m=q.match(/\(min-width:\s*(\d+)px\)/);if(m)matches=(w>=parseInt(m[1]));
        \\  m=q.match(/\(max-height:\s*(\d+)px\)/);if(m)matches=(innerHeight<=parseInt(m[1]));
        \\  m=q.match(/\(min-height:\s*(\d+)px\)/);if(m)matches=(innerHeight>=parseInt(m[1]));
        \\  if(q==='(prefers-color-scheme:dark)'||q==='(prefers-color-scheme: dark)')matches=true;
        \\  return{matches:matches,media:q,addEventListener:function(){},removeEventListener:function(){},addListener:function(){},removeListener:function(){}};
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
        \\if(typeof fetch==='undefined'){globalThis.fetch=function(url,opts){return Promise.reject(new Error('fetch not supported'));};}
        \\if(typeof AbortController==='undefined'){globalThis.AbortController=function(){this.signal={aborted:false,addEventListener:function(){}};this.abort=function(){this.signal.aborted=true;};};}
        \\if(typeof XMLHttpRequest==='undefined'){globalThis.XMLHttpRequest=function(){this.open=function(){};this.send=function(){};this.setRequestHeader=function(){};this.addEventListener=function(){};};}
        \\if(typeof DOMParser==='undefined'){globalThis.DOMParser=function(){this.parseFromString=function(){return null;};};}
        \\if(typeof history==='undefined'){globalThis.history={pushState:function(){},replaceState:function(){},back:function(){},forward:function(){},go:function(){},get length(){return 1;},get state(){return null;}};}
    ;
    evalInitScript(ctx, compat_stubs, compat_stubs.len);
}
