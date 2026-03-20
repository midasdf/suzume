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

        const ctx = qjs.JS_NewContext(rt) orelse {
            return error.JsContextInit;
        };
        errdefer qjs.JS_FreeContext(ctx);

        var self = JsRuntime{
            .rt = rt,
            .ctx = ctx,
        };

        // Register web APIs (console, setTimeout, etc.)
        web_api.registerWebApis(&self);

        return self;
    }

    pub fn deinit(self: *JsRuntime) void {
        // Free any remaining timer callbacks before destroying the context
        web_api.deinitTimers(self.ctx);
        qjs.JS_FreeContext(self.ctx);
        qjs.JS_FreeRuntime(self.rt);
    }

    /// Evaluate JavaScript code. Returns the result as a string, or an error string.
    pub fn eval(self: *JsRuntime, code: []const u8) EvalResult {
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
            "<eval>",
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
