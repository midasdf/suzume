const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;

const Allocator = std.mem.Allocator;
const allocator = std.heap.c_allocator;

/// A message passed between main thread and worker thread.
const Message = struct {
    data: []u8,

    pub fn deinit(self: *Message) void {
        allocator.free(self.data);
    }
};

/// Thread-safe message queue using mutex.
const MessageQueue = struct {
    items: std.ArrayListUnmanaged(Message) = .empty,
    mutex: std.Thread.Mutex = .{},

    fn push(self: *MessageQueue, data: []const u8) !void {
        const owned = try allocator.alloc(u8, data.len);
        @memcpy(owned, data);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, .{ .data = owned });
    }

    fn pop(self: *MessageQueue) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn deinit(self: *MessageQueue) void {
        for (self.items.items) |*msg| msg.deinit();
        self.items.deinit(allocator);
    }
};

pub const WorkerState = enum {
    running,
    terminated,
};

pub const WorkerHandle = struct {
    /// Messages from main → worker
    to_worker: MessageQueue = .{},
    /// Messages from worker → main
    to_main: MessageQueue = .{},
    thread: ?std.Thread = null,
    state: WorkerState = .running,
    id: u32,

    pub fn postToWorker(self: *WorkerHandle, data: []const u8) !void {
        try self.to_worker.push(data);
    }

    pub fn popFromWorker(self: *WorkerHandle) ?Message {
        return self.to_main.pop();
    }

    pub fn terminate(self: *WorkerHandle) void {
        self.state = .terminated;
        // Thread will detect terminated state and exit
    }

    pub fn deinit(self: *WorkerHandle) void {
        self.state = .terminated;
        if (self.thread) |t| t.join();
        self.to_worker.deinit();
        self.to_main.deinit();
    }
};

/// Worker thread entry point.
fn workerThreadMain(handle: *WorkerHandle, script: []const u8) void {
    defer allocator.free(script);

    // Create a new QuickJS runtime for this thread
    const rt = qjs.JS_NewRuntime() orelse return;
    defer qjs.JS_FreeRuntime(rt);
    qjs.JS_SetMemoryLimit(rt, 32 * 1024 * 1024);

    const ctx = qjs.JS_NewContext(rt) orelse return;
    defer qjs.JS_FreeContext(ctx);

    // Set up minimal worker globals
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // self = globalThis
    _ = qjs.JS_SetPropertyStr(ctx, global, "self", qjs.JS_DupValue(ctx, global));

    // console.log stub
    const console_code =
        \\globalThis.console = { log: function(){}, warn: function(){}, error: function(){}, info: function(){}, debug: function(){} };
    ;
    _ = qjs.JS_Eval(ctx, console_code, console_code.len, "<worker-init>", qjs.JS_EVAL_TYPE_GLOBAL);

    // postMessage — sends from worker to main
    // We store the handle pointer as an opaque value
    const handle_ptr_val = qjs.JS_NewInt64(ctx, @intCast(@intFromPtr(handle)));
    _ = qjs.JS_SetPropertyStr(ctx, global, "__workerHandle", handle_ptr_val);

    const post_msg_code =
        \\globalThis.postMessage = function(data) {
        \\  __workerPostMessage(JSON.stringify(data));
        \\};
    ;
    _ = qjs.JS_Eval(ctx, post_msg_code, post_msg_code.len, "<worker-init>", qjs.JS_EVAL_TYPE_GLOBAL);

    _ = qjs.JS_SetPropertyStr(ctx, global, "__workerPostMessage",
        qjs.JS_NewCFunction(ctx, &workerNativePostMessage, "__workerPostMessage", 1));

    // Evaluate the worker script
    const result = qjs.JS_Eval(ctx, script.ptr, script.len, "<worker>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (quickjs.JS_IsException(result)) {
        const exc = qjs.JS_GetException(ctx);
        const exc_str = qjs.JS_ToCString(ctx, exc);
        if (exc_str) |s| {
            std.debug.print("[Worker] Error: {s}\n", .{std.mem.span(s)});
            qjs.JS_FreeCString(ctx, s);
        }
        qjs.JS_FreeValue(ctx, exc);
    }
    qjs.JS_FreeValue(ctx, result);

    // Execute pending jobs
    var pctx: ?*qjs.JSContext = null;
    while (qjs.JS_ExecutePendingJob(rt, &pctx) > 0) {}

    // Message loop — check for incoming messages until terminated
    while (handle.state == .running) {
        if (handle.to_worker.pop()) |msg| {
            var msg_copy = msg;
            defer msg_copy.deinit();

            // Call self.onmessage({data: ...})
            const onmessage = qjs.JS_GetPropertyStr(ctx, global, "onmessage");
            if (qjs.JS_IsFunction(ctx, onmessage)) {
                const event = qjs.JS_NewObject(ctx);
                // Parse JSON data
                const data_val = qjs.JS_ParseJSON(ctx, msg_copy.data.ptr, msg_copy.data.len, "<message>");
                _ = qjs.JS_SetPropertyStr(ctx, event, "data", data_val);
                _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewString(ctx, "message"));
                var argv = [_]qjs.JSValue{event};
                const ret = qjs.JS_Call(ctx, onmessage, global, 1, &argv);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, event);
            }
            qjs.JS_FreeValue(ctx, onmessage);

            // Execute pending jobs after message handling
            while (qjs.JS_ExecutePendingJob(rt, &pctx) > 0) {}
        } else {
            // No message — sleep briefly to avoid busy-waiting
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
}

/// Native postMessage from worker thread → main thread
fn workerNativePostMessage(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get the worker handle from global
    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);
    const handle_val = qjs.JS_GetPropertyStr(c, global, "__workerHandle");
    defer qjs.JS_FreeValue(c, handle_val);

    var handle_int: i64 = 0;
    _ = qjs.JS_ToInt64(c, &handle_int, handle_val);
    const handle: *WorkerHandle = @ptrFromInt(@as(usize, @intCast(handle_int)));

    // Get message string
    var len: usize = 0;
    const str = qjs.JS_ToCStringLen(c, &len, args[0]);
    if (str == null) return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, str);

    handle.to_main.push(str[0..len]) catch {};

    return quickjs.JS_UNDEFINED();
}

/// Spawn a worker thread with the given script.
pub fn spawnWorker(script: []const u8) !*WorkerHandle {
    const handle = try allocator.create(WorkerHandle);
    handle.* = .{ .id = @as(u32, @truncate(@as(u64, @intCast(@intFromPtr(handle))))) };

    // Copy script for the thread
    const script_copy = try allocator.alloc(u8, script.len);
    @memcpy(script_copy, script);

    handle.thread = try std.Thread.spawn(.{}, workerThreadMain, .{ handle, script_copy });

    return handle;
}
