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

        qjs.JS_SetMemoryLimit(rt, 32 * 1024 * 1024);

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
        const result = qjs.JS_Eval(
            self.ctx,
            code.ptr,
            code.len,
            "<eval>",
            qjs.JS_EVAL_TYPE_GLOBAL,
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
};
