/// QuickJS bindings for WHATWG URL and URLSearchParams.
///
/// Strategy: native Zig functions for parsing/serialization, JS wrapper for the class API.
/// This avoids the complexity of full native QuickJS class registration while getting
/// spec-compliant URL parsing.

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const url_parser = @import("url_parser");

const allocator = std.heap.c_allocator;

/// Register URL-related native functions on the global object.
pub fn registerUrlBindings(ctx: *qjs.JSContext) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // Native parse function: __suzume_url_parse(input, base?) → object | null
    _ = qjs.JS_SetPropertyStr(ctx, global, "__suzume_url_parse", qjs.JS_NewCFunction(ctx, &jsUrlParse, "__suzume_url_parse", 2));

    // Native canParse function: __suzume_url_can_parse(input, base?) → bool
    _ = qjs.JS_SetPropertyStr(ctx, global, "__suzume_url_can_parse", qjs.JS_NewCFunction(ctx, &jsUrlCanParse, "__suzume_url_can_parse", 2));

    // Native component setter: __suzume_url_set(href, prop, value) → object | null
    // (URL §6.3 basic-URL-parser-with-state-override semantics)
    _ = qjs.JS_SetPropertyStr(ctx, global, "__suzume_url_set", qjs.JS_NewCFunction(ctx, &jsUrlSet, "__suzume_url_set", 3));

    // Register the JS URL and URLSearchParams classes
    evalScript(ctx, url_class_js);
    evalScript(ctx, url_search_params_js);
}

fn evalScript(ctx: *qjs.JSContext, src: []const u8) void {
    const val = qjs.JS_Eval(ctx, src.ptr, src.len, "<url>", qjs.JS_EVAL_TYPE_GLOBAL);
    qjs.JS_FreeValue(ctx, val);
}

/// Helper: convert JS string arg to Zig slice. Caller must free with JS_FreeCString.
fn getStringArg(ctx: *qjs.JSContext, argv: [*]qjs.JSValue, idx: usize) ?struct { ptr: [*c]const u8, len: usize } {
    const str = qjs.JS_ToCString(ctx, argv[idx]);
    if (str == null) return null;
    return .{ .ptr = str, .len = std.mem.len(str) };
}

/// __suzume_url_parse(input, base?) → JS object with URL fields, or null on failure.
fn jsUrlParse(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    if (argc < 1) return quickjs.JS_NULL();

    // Get input string
    const input_s = getStringArg(c, args, 0) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, input_s.ptr);
    const input = input_s.ptr[0..input_s.len];

    // Get optional base string
    var base_url: ?url_parser.Url = null;
    defer if (base_url) |*b| b.deinit();

    if (argc >= 2 and qjs.JS_IsString(args[1])) {
        const base_s = getStringArg(c, args, 1) orelse return quickjs.JS_NULL();
        defer qjs.JS_FreeCString(c, base_s.ptr);
        base_url = (url_parser.parse(allocator, base_s.ptr[0..base_s.len], null) catch return quickjs.JS_NULL()) orelse return quickjs.JS_NULL();
    }

    // Parse
    const base_ptr: ?*const url_parser.Url = if (base_url) |*b| b else null;
    var url = (url_parser.parse(allocator, input, base_ptr) catch return quickjs.JS_NULL()) orelse return quickjs.JS_NULL();
    defer url.deinit();

    // Build JS result object with all URL fields
    return urlToJsObject(c, &url) catch return quickjs.JS_NULL();
}

/// __suzume_url_can_parse(input, base?) → bool
fn jsUrlCanParse(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);

    const input_s = getStringArg(c, args, 0) orelse return quickjs.JS_NewBool(false);
    defer qjs.JS_FreeCString(c, input_s.ptr);
    const input = input_s.ptr[0..input_s.len];

    var base_url: ?url_parser.Url = null;
    defer if (base_url) |*b| b.deinit();

    if (argc >= 2 and qjs.JS_IsString(args[1])) {
        const base_s = getStringArg(c, args, 1) orelse return quickjs.JS_NewBool(false);
        defer qjs.JS_FreeCString(c, base_s.ptr);
        base_url = (url_parser.parse(allocator, base_s.ptr[0..base_s.len], null) catch return quickjs.JS_NewBool(false)) orelse return quickjs.JS_NewBool(false);
    }

    const base_ptr: ?*const url_parser.Url = if (base_url) |*b| b else null;
    var result = url_parser.parse(allocator, input, base_ptr) catch return quickjs.JS_NewBool(false);
    if (result) |*r| {
        r.deinit();
        return quickjs.JS_NewBool(true);
    }
    return quickjs.JS_NewBool(false);
}

/// __suzume_url_set(href, prop, value) → updated field object, or null when
/// href itself does not parse. Invalid setter values leave the URL unchanged
/// (spec setters ignore failures silently), so the unchanged fields return.
fn jsUrlSet(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    if (argc < 3) return quickjs.JS_NULL();

    const href_s = getStringArg(c, args, 0) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, href_s.ptr);
    const prop_s = getStringArg(c, args, 1) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, prop_s.ptr);
    const value_s = getStringArg(c, args, 2) orelse return quickjs.JS_NULL();
    defer qjs.JS_FreeCString(c, value_s.ptr);

    const setter = std.meta.stringToEnum(url_parser.Setter, prop_s.ptr[0..prop_s.len]) orelse
        return quickjs.JS_NULL();
    var url = (url_parser.parse(allocator, href_s.ptr[0..href_s.len], null) catch return quickjs.JS_NULL()) orelse
        return quickjs.JS_NULL();
    defer url.deinit();
    url_parser.applySetter(allocator, &url, setter, value_s.ptr[0..value_s.len]) catch
        return quickjs.JS_NULL();
    return urlToJsObject(c, &url) catch quickjs.JS_NULL();
}

/// Convert a parsed Url to a JS object with all standard URL fields.
fn urlToJsObject(ctx: *qjs.JSContext, url: *const url_parser.Url) !qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);

    // href
    const href = try url.serialize(allocator, false);
    defer allocator.free(href);
    _ = qjs.JS_SetPropertyStr(ctx, obj, "href", qjs.JS_NewStringLen(ctx, href.ptr, href.len));

    // origin
    const origin = try url.serializeOrigin(allocator);
    defer allocator.free(origin);
    _ = qjs.JS_SetPropertyStr(ctx, obj, "origin", qjs.JS_NewStringLen(ctx, origin.ptr, origin.len));

    // protocol (scheme + ":")
    const proto_len = url.scheme.len + 1;
    const proto_buf = try allocator.alloc(u8, proto_len);
    defer allocator.free(proto_buf);
    @memcpy(proto_buf[0..url.scheme.len], url.scheme);
    proto_buf[url.scheme.len] = ':';
    _ = qjs.JS_SetPropertyStr(ctx, obj, "protocol", qjs.JS_NewStringLen(ctx, proto_buf.ptr, proto_buf.len));

    // username, password
    _ = qjs.JS_SetPropertyStr(ctx, obj, "username", qjs.JS_NewStringLen(ctx, url.username.ptr, url.username.len));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "password", qjs.JS_NewStringLen(ctx, url.password.ptr, url.password.len));

    // host (hostname:port or just hostname)
    if (url.host) |h| {
        const hs = try url_parser.serializeHost(allocator, h);
        defer allocator.free(hs);
        if (url.port) |p| {
            var buf: [5]u8 = undefined;
            const port_s = std.fmt.bufPrint(&buf, "{d}", .{p}) catch unreachable;
            const host_port_len = hs.len + 1 + port_s.len;
            const host_port = try allocator.alloc(u8, host_port_len);
            defer allocator.free(host_port);
            @memcpy(host_port[0..hs.len], hs);
            host_port[hs.len] = ':';
            @memcpy(host_port[hs.len + 1 ..][0..port_s.len], port_s);
            _ = qjs.JS_SetPropertyStr(ctx, obj, "host", qjs.JS_NewStringLen(ctx, host_port.ptr, host_port.len));
        } else {
            _ = qjs.JS_SetPropertyStr(ctx, obj, "host", qjs.JS_NewStringLen(ctx, hs.ptr, hs.len));
        }
        _ = qjs.JS_SetPropertyStr(ctx, obj, "hostname", qjs.JS_NewStringLen(ctx, hs.ptr, hs.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, obj, "host", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, obj, "hostname", qjs.JS_NewString(ctx, ""));
    }

    // port
    if (url.port) |p| {
        var buf: [5]u8 = undefined;
        const port_s = std.fmt.bufPrint(&buf, "{d}", .{p}) catch unreachable;
        _ = qjs.JS_SetPropertyStr(ctx, obj, "port", qjs.JS_NewStringLen(ctx, port_s.ptr, port_s.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, obj, "port", qjs.JS_NewString(ctx, ""));
    }

    // pathname
    switch (url.path) {
        .list => |l| {
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(allocator);
            for (l.items) |seg| {
                try path_buf.append(allocator, '/');
                try path_buf.appendSlice(allocator, seg);
            }
            _ = qjs.JS_SetPropertyStr(ctx, obj, "pathname", qjs.JS_NewStringLen(ctx, path_buf.items.ptr, path_buf.items.len));
        },
        .opaque_path => |p| {
            _ = qjs.JS_SetPropertyStr(ctx, obj, "pathname", qjs.JS_NewStringLen(ctx, p.ptr, p.len));
        },
    }

    // search
    if (url.query) |q| {
        if (q.len > 0) {
            const search_len = q.len + 1;
            const search_buf = try allocator.alloc(u8, search_len);
            defer allocator.free(search_buf);
            search_buf[0] = '?';
            @memcpy(search_buf[1..], q);
            _ = qjs.JS_SetPropertyStr(ctx, obj, "search", qjs.JS_NewStringLen(ctx, search_buf.ptr, search_buf.len));
        } else {
            _ = qjs.JS_SetPropertyStr(ctx, obj, "search", qjs.JS_NewString(ctx, ""));
        }
        _ = qjs.JS_SetPropertyStr(ctx, obj, "query", qjs.JS_NewStringLen(ctx, q.ptr, q.len));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, obj, "search", qjs.JS_NewString(ctx, ""));
        _ = qjs.JS_SetPropertyStr(ctx, obj, "query", qjs.JS_NewString(ctx, ""));
    }

    // hash
    if (url.fragment) |f| {
        if (f.len > 0) {
            const hash_len = f.len + 1;
            const hash_buf = try allocator.alloc(u8, hash_len);
            defer allocator.free(hash_buf);
            hash_buf[0] = '#';
            @memcpy(hash_buf[1..], f);
            _ = qjs.JS_SetPropertyStr(ctx, obj, "hash", qjs.JS_NewStringLen(ctx, hash_buf.ptr, hash_buf.len));
        } else {
            _ = qjs.JS_SetPropertyStr(ctx, obj, "hash", qjs.JS_NewString(ctx, ""));
        }
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, obj, "hash", qjs.JS_NewString(ctx, ""));
    }

    return obj;
}

// ── JS URL class wrapper ─────────────────────────────────────────────

const url_class_js =
    \\(function(){
    \\"use strict";
    \\function URL(input, base) {
    \\  if (!(this instanceof URL)) throw new TypeError("Failed to construct 'URL': Please use the 'new' operator");
    \\  var parsed = __suzume_url_parse(String(input), base !== undefined ? String(base) : undefined);
    \\  if (!parsed) throw new TypeError("Failed to construct 'URL': Invalid URL");
    \\  this._p = parsed;
    \\  this._sp = null;
    \\}
    \\function _set(self, prop, v) {
    \\  var np = __suzume_url_set(self._p.href, prop, String(v));
    \\  if (np) self._p = np;
    \\}
    \\URL.prototype = {
    \\  get href() { return this._p.href; },
    \\  set href(v) { var p = __suzume_url_parse(String(v)); if (!p) throw new TypeError("Invalid URL"); this._p = p; this._sp = null; },
    \\  get origin() { return this._p.origin; },
    \\  get protocol() { return this._p.protocol; },
    \\  set protocol(v) { _set(this, 'protocol', v); },
    \\  get username() { return this._p.username; },
    \\  set username(v) { _set(this, 'username', v); },
    \\  get password() { return this._p.password; },
    \\  set password(v) { _set(this, 'password', v); },
    \\  get host() { return this._p.host; },
    \\  set host(v) { _set(this, 'host', v); },
    \\  get hostname() { return this._p.hostname; },
    \\  set hostname(v) { _set(this, 'hostname', v); },
    \\  get port() { return this._p.port; },
    \\  set port(v) { _set(this, 'port', v); },
    \\  get pathname() { return this._p.pathname; },
    \\  set pathname(v) { _set(this, 'pathname', v); },
    \\  get search() { return this._p.search; },
    \\  set search(v) { _set(this, 'search', v); this._sp = null; },
    \\  get searchParams() { if (!this._sp) this._sp = new URLSearchParams(this._p.query || ''); return this._sp; },
    \\  get hash() { return this._p.hash; },
    \\  set hash(v) { _set(this, 'hash', v); },
    \\  toString: function() { return this._p.href; },
    \\  toJSON: function() { return this._p.href; }
    \\};
    \\URL.canParse = function(input, base) { return __suzume_url_can_parse(String(input), base !== undefined ? String(base) : undefined); };
    \\URL.parse = function(input, base) { try { return new URL(input, base); } catch(e) { return null; } };
    \\globalThis.URL = URL;
    \\})();
;

// ── JS URLSearchParams class ─────────────────────────────────────────

const url_search_params_js =
    \\(function(){
    \\"use strict";
    \\function URLSearchParams(init) {
    \\  this._e = [];
    \\  if (init === undefined || init === null) return;
    \\  if (typeof init === 'string') {
    \\    var s = init.charAt(0) === '?' ? init.substring(1) : init;
    \\    if (s) { var pairs = s.split('&'); for (var i = 0; i < pairs.length; i++) { var eq = pairs[i].indexOf('='); var n, v; if (eq >= 0) { n = pairs[i].substring(0, eq); v = pairs[i].substring(eq + 1); } else { n = pairs[i]; v = ''; } this._e.push([decodeURIComponent(n.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]); } }
    \\  } else if (typeof Symbol !== 'undefined' && Symbol.iterator && init[Symbol.iterator]) {
    \\    var it = init[Symbol.iterator](), r; while (!(r = it.next()).done) { var p = r.value; this._e.push([String(p[0]), String(p[1])]); }
    \\  } else if (typeof init === 'object') {
    \\    var keys = Object.keys(init); for (var i = 0; i < keys.length; i++) this._e.push([String(keys[i]), String(init[keys[i]])]);
    \\  }
    \\}
    \\URLSearchParams.prototype = {
    \\  append: function(n, v) { this._e.push([String(n), String(v)]); },
    \\  delete: function(n, v) { this._e = this._e.filter(function(p) { return !(p[0] === String(n) && (arguments.length < 2 || p[1] === String(v))); }); },
    \\  get: function(n) { n = String(n); for (var i = 0; i < this._e.length; i++) if (this._e[i][0] === n) return this._e[i][1]; return null; },
    \\  getAll: function(n) { n = String(n); var r = []; for (var i = 0; i < this._e.length; i++) if (this._e[i][0] === n) r.push(this._e[i][1]); return r; },
    \\  has: function(n, v) { n = String(n); for (var i = 0; i < this._e.length; i++) if (this._e[i][0] === n && (arguments.length < 2 || this._e[i][1] === String(v))) return true; return false; },
    \\  set: function(n, v) { n = String(n); v = String(v); var found = false, e = this._e; for (var i = 0; i < e.length; i++) { if (e[i][0] === n) { if (!found) { e[i][1] = v; found = true; } else { e.splice(i, 1); i--; } } } if (!found) e.push([n, v]); },
    \\  sort: function() { this._e.sort(function(a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); },
    \\  get size() { return this._e.length; },
    \\  toString: function() { return this._e.map(function(p) { return encodeURIComponent(p[0]).replace(/%20/g,'+') + '=' + encodeURIComponent(p[1]).replace(/%20/g,'+'); }).join('&'); },
    \\  forEach: function(cb, thisArg) { for (var i = 0; i < this._e.length; i++) cb.call(thisArg, this._e[i][1], this._e[i][0], this); },
    \\  entries: function() { var i = 0, e = this._e; return { next: function() { if (i < e.length) { var v = [e[i][0], e[i][1]]; i++; return { value: v, done: false }; } return { value: undefined, done: true }; } }; },
    \\  keys: function() { var i = 0, e = this._e; return { next: function() { return i < e.length ? { value: e[i++][0], done: false } : { value: undefined, done: true }; } }; },
    \\  values: function() { var i = 0, e = this._e; return { next: function() { return i < e.length ? { value: e[i++][1], done: false } : { value: undefined, done: true }; } }; }
    \\};
    \\if (typeof Symbol !== 'undefined' && Symbol.iterator) URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
    \\globalThis.URLSearchParams = URLSearchParams;
    \\})();
;
