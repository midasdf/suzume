const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const web_api = @import("web_api.zig");

pub const JsRuntime = struct {
    rt: *qjs.JSRuntime,
    ctx: *qjs.JSContext,

    pub fn init() !JsRuntime {
        const rt = qjs.JS_NewRuntime() orelse return error.JsRuntimeInit;
        errdefer qjs.JS_FreeRuntime(rt);

        qjs.JS_SetMemoryLimit(rt, 48 * 1024 * 1024);

        // Interrupt handler prevents infinite loops / very heavy scripts
        qjs.JS_SetInterruptHandler(rt, &interruptHandler, null);

        const ctx = qjs.JS_NewContext(rt) orelse {
            return error.JsContextInit;
        };
        errdefer qjs.JS_FreeContext(ctx);

        // Register ES module loader (must be done before creating context APIs)
        qjs.JS_SetModuleLoaderFunc(rt, null, &moduleLoader, null);

        var self = JsRuntime{
            .rt = rt,
            .ctx = ctx,
        };

        // Register web APIs (console, setTimeout, etc.)
        web_api.registerWebApis(&self);

        return self;
    }

    pub fn deinit(self: *JsRuntime) void {
        // Free any remaining timer callbacks and WebSocket connections before destroying the context
        web_api.deinitTimers(self.ctx);
        web_api.deinitWebSockets(self.ctx);
        web_api.deinitWorkers(self.ctx);
        qjs.JS_FreeContext(self.ctx);
        qjs.JS_FreeRuntime(self.rt);
    }

    /// Evaluate JavaScript code as an ES module.
    pub fn evalModule(self: *JsRuntime, code: []const u8, source_name: [*:0]const u8) EvalResult {
        resetScriptTimer();
        const clean = sanitizeUtf8(code) catch code;
        defer if (clean.ptr != code.ptr) std.heap.c_allocator.free(clean);

        const eval_buf = std.heap.c_allocator.allocSentinel(u8, clean.len, 0) catch {
            return .{ .err = "out of memory" };
        };
        defer std.heap.c_allocator.free(eval_buf);
        @memcpy(eval_buf, clean);

        const result = qjs.JS_Eval(
            self.ctx,
            eval_buf.ptr,
            eval_buf.len,
            source_name,
            qjs.JS_EVAL_TYPE_MODULE,
        );

        if (quickjs.JS_IsException(result)) {
            const exc = qjs.JS_GetException(self.ctx);
            defer qjs.JS_FreeValue(self.ctx, exc);
            const exc_str = qjs.JS_ToCString(self.ctx, exc);
            if (exc_str) |s| {
                defer qjs.JS_FreeCString(self.ctx, s);
                const len = std.mem.len(s);
                const owned = std.heap.c_allocator.alloc(u8, len) catch return .{ .err = "out of memory" };
                @memcpy(owned, s[0..len]);
                return .{ .err = owned };
            }
            return .{ .err = "module evaluation error" };
        }

        qjs.JS_FreeValue(self.ctx, result);
        return .{ .ok = "undefined" };
    }

    /// Evaluate JavaScript code. Returns the result as a string, or an error string.
    pub fn eval(self: *JsRuntime, code: []const u8) EvalResult {
        return self.evalNamed(code, "<eval>");
    }

    pub fn evalNamed(self: *JsRuntime, code: []const u8, source_name: [*:0]const u8) EvalResult {
        resetScriptTimer();
        // Sanitize invalid UTF-8 sequences before QuickJS eval
        const clean = sanitizeUtf8(code) catch code;
        defer if (clean.ptr != code.ptr) std.heap.c_allocator.free(clean);

        // QuickJS utf8_decode assumes null-terminated or UTF8_CHAR_LEN_MAX padding.
        // Ensure we pass a null-terminated buffer to avoid read-past-end.
        const eval_buf = std.heap.c_allocator.allocSentinel(u8, clean.len, 0) catch {
            return .{ .err = "out of memory" };
        };
        defer std.heap.c_allocator.free(eval_buf);
        @memcpy(eval_buf, clean);

        const result = qjs.JS_Eval(
            self.ctx,
            eval_buf.ptr,
            eval_buf.len,
            source_name,
            qjs.JS_EVAL_TYPE_GLOBAL,
        );

        if (quickjs.JS_IsException(result)) {
            const exc = qjs.JS_GetException(self.ctx);
            defer qjs.JS_FreeValue(self.ctx, exc);

            // Try to get stack trace for better debugging
            const stack_val = qjs.JS_GetPropertyStr(self.ctx, exc, "stack");
            if (!quickjs.JS_IsUndefined(stack_val)) {
                defer qjs.JS_FreeValue(self.ctx, stack_val);
                const stack_str = qjs.JS_ToCString(self.ctx, stack_val);
                if (stack_str) |ss| {
                    defer qjs.JS_FreeCString(self.ctx, ss);
                    std.debug.print("[JS:STACK] {s}\n", .{std.mem.span(ss)});
                }
            }

            const exc_str = qjs.JS_ToCString(self.ctx, exc);
            if (exc_str) |s| {
                defer qjs.JS_FreeCString(self.ctx, s);
                const len = std.mem.len(s);
                const owned = std.heap.c_allocator.alloc(u8, len) catch return .{ .err = "out of memory" };
                @memcpy(owned, s[0..len]);
                return .{ .err = owned };
            }
            return .{ .err = "unknown exception" };
        }

        defer qjs.JS_FreeValue(self.ctx, result);

        // Convert result to string
        const str = qjs.JS_ToCString(self.ctx, result);
        if (str) |s| {
            defer qjs.JS_FreeCString(self.ctx, s);
            const len = std.mem.len(s);
            const owned = std.heap.c_allocator.alloc(u8, len) catch return .{ .err = "out of memory" };
            @memcpy(owned, s[0..len]);
            return .{ .ok = owned };
        }

        // undefined, null, etc. - no string representation
        if (quickjs.JS_IsUndefined(result)) return .{ .ok = "undefined" };
        if (quickjs.JS_IsNull(result)) return .{ .ok = "null" };
        return .{ .ok = "" };
    }

    /// Execute pending jobs (promises, etc.) until none remain.
    pub fn executePending(self: *JsRuntime) void {
        var pctx: ?*qjs.JSContext = null;
        while (true) {
            const ret = qjs.JS_ExecutePendingJob(self.rt, &pctx);
            if (ret <= 0) break;
        }
    }

    pub const EvalResult = union(enum) {
        ok: []const u8,
        err: []const u8,

        pub fn isOk(self: EvalResult) bool {
            return self == .ok;
        }

        pub fn value(self: EvalResult) []const u8 {
            return switch (self) {
                .ok => |v| v,
                .err => |v| v,
            };
        }

        /// Free the owned string if it was heap-allocated.
        pub fn deinit(self: EvalResult) void {
            const v = switch (self) {
                .ok => |s| s,
                .err => |s| s,
            };
            // Only free if it's not a known static string
            if (v.len > 0 and !isStatic(v)) {
                std.heap.c_allocator.free(v);
            }
        }

        fn isStatic(s: []const u8) bool {
            const statics = [_][]const u8{
                "undefined",
                "null",
                "",
                "?",
                "unknown exception",
                "out of memory",
            };
            for (statics) |st| {
                if (s.ptr == st.ptr) return true;
            }
            return false;
        }
    };

    /// Sanitize a byte buffer so every byte sequence is valid UTF-8.
    /// Invalid sequences (including overlong encodings, surrogates, and
    /// codepoints > U+10FFFF) are replaced with U+FFFD (EF BF BD).
    fn sanitizeUtf8(input: []const u8) ![]u8 {
        // Quick check: if all ASCII, no sanitization needed
        var needs_sanitize = false;
        for (input) |b| {
            if (b >= 0x80) {
                needs_sanitize = true;
                break;
            }
        }
        if (!needs_sanitize) return @constCast(input);

        const alloc = std.heap.c_allocator;
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(alloc);
        try out.ensureTotalCapacity(alloc, input.len);

        var i: usize = 0;
        while (i < input.len) {
            const b0 = input[i];
            if (b0 < 0x80) {
                try out.append(alloc, b0);
                i += 1;
                continue;
            }

            const seq_len: usize = if (b0 < 0xC0) 0 // invalid continuation
            else if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else if (b0 < 0xF8) 4 else 0;

            if (seq_len == 0 or i + seq_len > input.len) {
                // Latin-1 fallback
                if (b0 >= 0x80) {
                    try out.append(alloc, 0xC0 | (b0 >> 6));
                    try out.append(alloc, 0x80 | (b0 & 0x3F));
                } else {
                    try out.append(alloc, '?');
                }
                i += 1;
                continue;
            }

            // Validate continuation bytes (must be 10xxxxxx)
            var valid = true;
            for (1..seq_len) |j| {
                if ((input[i + j] & 0xC0) != 0x80) {
                    valid = false;
                    break;
                }
            }

            if (!valid) {
                // Latin-1 fallback
                if (b0 >= 0x80) {
                    try out.append(alloc, 0xC0 | (b0 >> 6));
                    try out.append(alloc, 0x80 | (b0 & 0x3F));
                } else {
                    try out.append(alloc, '?');
                }
                i += 1;
                continue;
            }

            // Decode codepoint and validate range
            var cp: u32 = 0;
            switch (seq_len) {
                2 => {
                    cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, input[i + 1] & 0x3F);
                    if (cp < 0x80) valid = false; // overlong
                },
                3 => {
                    cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, input[i + 1] & 0x3F) << 6) | @as(u32, input[i + 2] & 0x3F);
                    if (cp < 0x800) valid = false; // overlong
                    if (cp >= 0xD800 and cp <= 0xDFFF) valid = false; // surrogate
                },
                4 => {
                    cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, input[i + 1] & 0x3F) << 12) | (@as(u32, input[i + 2] & 0x3F) << 6) | @as(u32, input[i + 3] & 0x3F);
                    if (cp < 0x10000) valid = false; // overlong
                    if (cp > 0x10FFFF) valid = false; // out of range
                },
                else => valid = false,
            }

            if (valid) {
                try out.appendSlice(alloc, input[i .. i + seq_len]);
                i += seq_len;
            } else {
                // Try Latin-1 interpretation: 0x80-0xFF → valid UTF-8
                if (b0 >= 0x80 and b0 <= 0xFF) {
                    // Encode Latin-1 byte as UTF-8 (U+0080..U+00FF)
                    try out.append(alloc, 0xC0 | (b0 >> 6));
                    try out.append(alloc, 0x80 | (b0 & 0x3F));
                } else {
                    try out.append(alloc, '?');
                }
                i += 1;
            }
        }
        return out.toOwnedSlice(alloc);
    }
};

// ── Script Execution Timeout ────────────────────────────────────────

/// Timestamp (ms) when current script execution started.
var script_start_time: i64 = 0;
/// Maximum execution time per eval() call in milliseconds.
const max_script_execution_ms: i64 = 5000; // 5 seconds

fn currentTimeMs() i64 {
    const ts = std.time.milliTimestamp();
    return ts;
}

/// Called before each eval to reset the timer.
fn resetScriptTimer() void {
    script_start_time = currentTimeMs();
}

/// QuickJS interrupt handler — called periodically during script execution.
/// Return 1 to interrupt (abort), 0 to continue.
fn interruptHandler(_: ?*qjs.JSRuntime, _: ?*anyopaque) callconv(.c) c_int {
    if (script_start_time == 0) return 0; // timer not set
    const elapsed = currentTimeMs() - script_start_time;
    if (elapsed > max_script_execution_ms) {
        std.debug.print("[JS] Script execution timeout ({d}ms > {d}ms limit)\n", .{ elapsed, max_script_execution_ms });
        return 1; // interrupt
    }
    return 0; // continue
}

// ── ES Module Loader ────────────────────────────────────────────────

const HttpClient = @import("../net/http.zig").HttpClient;

/// Module loader callback for JS_SetModuleLoaderFunc.
/// Fetches module source via HTTP and compiles it as an ES module.
fn moduleLoader(
    ctx: ?*qjs.JSContext,
    module_name: [*c]const u8,
    _: ?*anyopaque,
) callconv(.c) ?*qjs.JSModuleDef {
    const c = ctx orelse return null;
    const name = std.mem.span(module_name);

    std.debug.print("[Module] Loading: {s}\n", .{name});

    // Only handle http/https URLs
    if (!std.mem.startsWith(u8, name, "http://") and !std.mem.startsWith(u8, name, "https://")) {
        // For relative paths or bare specifiers, try to resolve against current URL
        // For now, log and return null (module not found)
        std.debug.print("[Module] Skipping non-URL module: {s}\n", .{name});
        _ = qjs.JS_ThrowReferenceError(c, "module '%s' not found", module_name);
        return null;
    }

    // Fetch module source via HTTP
    const url_z = std.heap.c_allocator.allocSentinel(u8, name.len, 0) catch {
        _ = qjs.JS_ThrowReferenceError(c, "out of memory loading module '%s'", module_name);
        return null;
    };
    defer std.heap.c_allocator.free(url_z);
    @memcpy(url_z, name);

    // Use the shared HTTP client if available, otherwise create a temporary one
    const web_api_mod = @import("web_api.zig");
    const client = web_api_mod.getHttpClient() orelse {
        _ = qjs.JS_ThrowReferenceError(c, "HTTP client not available for module '%s'", module_name);
        return null;
    };

    var response = client.getWithTimeout(std.heap.c_allocator, url_z, 10) catch {
        _ = qjs.JS_ThrowReferenceError(c, "failed to fetch module '%s'", module_name);
        return null;
    };
    defer response.deinit();

    if (response.status_code != 200) {
        std.debug.print("[Module] HTTP {d} for {s}\n", .{ response.status_code, name });
        _ = qjs.JS_ThrowReferenceError(c, "HTTP %d loading module '%s'", @as(c_int, @intCast(response.status_code)), module_name);
        return null;
    }

    std.debug.print("[Module] Loaded {d} bytes from {s}\n", .{ response.body.len, name });

    // Null-terminate the source
    const src_z = std.heap.c_allocator.allocSentinel(u8, response.body.len, 0) catch {
        _ = qjs.JS_ThrowReferenceError(c, "out of memory compiling module '%s'", module_name);
        return null;
    };
    defer std.heap.c_allocator.free(src_z);
    @memcpy(src_z, response.body);

    // Compile as ES module
    const func_val = qjs.JS_Eval(c, src_z.ptr, src_z.len, module_name,
        qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY);

    if (quickjs.JS_IsException(func_val)) {
        std.debug.print("[Module] Compilation failed for {s}\n", .{name});
        return null;
    }

    // Get the module definition from the compiled function
    // JS_VALUE_GET_PTR equivalent for getting the module pointer
    const m: ?*qjs.JSModuleDef = @ptrCast(@alignCast(func_val.u.ptr));
    qjs.JS_FreeValue(c, func_val);

    return m;
}
