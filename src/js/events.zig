const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const dom_api = @import("dom_api.zig");

const Allocator = std.mem.Allocator;
const allocator = std.heap.c_allocator;

// ── Event Listener Storage ──────────────────────────────────────────

/// Key for event listener map: node pointer + event type.
const ListenerKey = struct {
    node: *lxb.lxb_dom_node_t,
    event_type: []const u8, // Owned copy

    fn deinit(self: *ListenerKey) void {
        allocator.free(self.event_type);
    }
};

const ListenerList = std.ArrayListUnmanaged(qjs.JSValue);

/// Map from (node_ptr, event_type) -> list of callbacks.
/// We use a simple array of entries since the number is typically small.
const ListenerEntry = struct {
    key: ListenerKey,
    callbacks: ListenerList,
};

var listener_entries: std.ArrayListUnmanaged(ListenerEntry) = .empty;
var g_ctx: ?*qjs.JSContext = null;

// ── Window event listeners (load, DOMContentLoaded, etc.) ───────────
var window_listener_entries: std.ArrayListUnmanaged(WindowListenerEntry) = .empty;

const WindowListenerEntry = struct {
    event_type: []const u8, // Owned copy
    callbacks: ListenerList,
};

fn findOrCreateWindowEntry(event_type: []const u8) ?*WindowListenerEntry {
    for (window_listener_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) return entry;
    }
    // Create new
    const owned_type = allocator.alloc(u8, event_type.len) catch return null;
    @memcpy(owned_type, event_type);
    window_listener_entries.append(allocator, .{
        .event_type = owned_type,
        .callbacks = .empty,
    }) catch {
        allocator.free(owned_type);
        return null;
    };
    return &window_listener_entries.items[window_listener_entries.items.len - 1];
}

fn findOrCreateEntry(node: *lxb.lxb_dom_node_t, event_type: []const u8) ?*ListenerEntry {
    for (listener_entries.items) |*entry| {
        if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
            return entry;
        }
    }
    // Create new entry
    const owned_type = allocator.alloc(u8, event_type.len) catch return null;
    @memcpy(owned_type, event_type);
    listener_entries.append(allocator, .{
        .key = .{ .node = node, .event_type = owned_type },
        .callbacks = .empty,
    }) catch {
        allocator.free(owned_type);
        return null;
    };
    return &listener_entries.items[listener_entries.items.len - 1];
}

// ── addEventListener / removeEventListener ──────────────────────────

pub fn jsAddEventListener(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    // Get event type string
    const type_s = dom_api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    const event_type = type_s.ptr[0..type_s.len];

    // Check if callback is a function
    if (!qjs.JS_IsFunction(c, args[1])) return quickjs.JS_UNDEFINED();

    // Check if this is a window/document object (no opaque node)
    const node = dom_api.getNodePublic(c, this_val);
    if (node) |n| {
        const entry = findOrCreateEntry(n, event_type) orelse return quickjs.JS_UNDEFINED();
        entry.callbacks.append(allocator, qjs.JS_DupValue(c, args[1])) catch {};
    } else {
        // Could be window or document addEventListener
        const wentry = findOrCreateWindowEntry(event_type) orelse return quickjs.JS_UNDEFINED();
        wentry.callbacks.append(allocator, qjs.JS_DupValue(c, args[1])) catch {};
    }
    return quickjs.JS_UNDEFINED();
}

pub fn jsRemoveEventListener(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();

    const type_s = dom_api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    const event_type = type_s.ptr[0..type_s.len];

    const node = dom_api.getNodePublic(c, this_val);
    if (node) |n| {
        for (listener_entries.items) |*entry| {
            if (entry.key.node == n and std.mem.eql(u8, entry.key.event_type, event_type)) {
                // Remove matching callback (simple identity check via JS_VALUE comparison is not reliable;
                // just remove first matching callback)
                var i: usize = 0;
                while (i < entry.callbacks.items.len) {
                    // We can't easily compare JS functions, so for now we just don't support
                    // targeted removal. Remove the last one added.
                    if (i == entry.callbacks.items.len - 1) {
                        qjs.JS_FreeValue(c, entry.callbacks.items[i]);
                        _ = entry.callbacks.swapRemove(i);
                        break;
                    }
                    i += 1;
                }
                break;
            }
        }
    } else {
        // Window listener removal
        for (window_listener_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.event_type, event_type)) {
                if (entry.callbacks.items.len > 0) {
                    const last = entry.callbacks.items.len - 1;
                    qjs.JS_FreeValue(c, entry.callbacks.items[last]);
                    _ = entry.callbacks.swapRemove(last);
                }
                break;
            }
        }
    }
    return quickjs.JS_UNDEFINED();
}

// ── Event object creation ───────────────────────────────────────────

const EventFlags = struct {
    prevent_default: bool = false,
    stop_propagation: bool = false,
};

/// Thread-local event flags for the current dispatch.
var current_event_flags: EventFlags = .{};

fn jsPreventDefault(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    current_event_flags.prevent_default = true;
    return quickjs.JS_UNDEFINED();
}

fn jsStopPropagation(
    _: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    current_event_flags.stop_propagation = true;
    return quickjs.JS_UNDEFINED();
}

fn createEventObject(ctx: *qjs.JSContext, event_type: []const u8, target: ?*lxb.lxb_dom_node_t, current_target: ?*lxb.lxb_dom_node_t) qjs.JSValue {
    const event = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(event)) return event;

    _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewStringLen(ctx, event_type.ptr, event_type.len));

    if (target) |t| {
        _ = qjs.JS_SetPropertyStr(ctx, event, "target", dom_api.wrapNodePublic(ctx, t));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, event, "target", quickjs.JS_NULL());
    }

    if (current_target) |ct| {
        _ = qjs.JS_SetPropertyStr(ctx, event, "currentTarget", dom_api.wrapNodePublic(ctx, ct));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, event, "currentTarget", quickjs.JS_NULL());
    }

    _ = qjs.JS_SetPropertyStr(ctx, event, "preventDefault", qjs.JS_NewCFunction(ctx, &jsPreventDefault, "preventDefault", 0));
    _ = qjs.JS_SetPropertyStr(ctx, event, "stopPropagation", qjs.JS_NewCFunction(ctx, &jsStopPropagation, "stopPropagation", 0));

    return event;
}

// ── Key code to key name mapping ────────────────────────────────────

fn keyCodeToKeyName(buf: *[16]u8, key_code: u32) []const u8 {
    return switch (key_code) {
        8 => "Backspace",
        9 => "Tab",
        13 => "Enter",
        27 => "Escape",
        32 => " ",
        37 => "ArrowLeft",
        38 => "ArrowUp",
        39 => "ArrowRight",
        40 => "ArrowDown",
        46 => "Delete",
        else => {
            if (key_code >= 32 and key_code < 127) {
                buf[0] = @truncate(key_code);
                return buf[0..1];
            }
            return "Unidentified";
        },
    };
}

// ── Event Dispatching ───────────────────────────────────────────────

/// Dispatch a keyboard event (keydown/keyup) with key and keyCode properties.
/// Returns true if preventDefault was NOT called.
pub fn dispatchKeyboardEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, key_code: u32) bool {
    current_event_flags = .{};

    // Collect ancestors for bubbling (target -> ... -> document)
    var path: [64]*lxb.lxb_dom_node_t = undefined;
    var path_len: usize = 0;
    var current: ?*lxb.lxb_dom_node_t = target;
    while (current) |node| {
        if (path_len < path.len) {
            path[path_len] = node;
            path_len += 1;
        }
        current = node.parent;
    }

    // Get key name
    var key_buf: [16]u8 = undefined;
    const key_name = keyCodeToKeyName(&key_buf, key_code);

    // Bubble: from target up to root
    for (path[0..path_len]) |node| {
        if (current_event_flags.stop_propagation) break;

        for (listener_entries.items) |*entry| {
            if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                for (entry.callbacks.items) |callback| {
                    const event_obj = createEventObject(ctx, event_type, target, node);
                    // Add keyboard-specific properties
                    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "keyCode", qjs.JS_NewInt32(ctx, @intCast(key_code)));
                    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "which", qjs.JS_NewInt32(ctx, @intCast(key_code)));
                    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "key", qjs.JS_NewStringLen(ctx, key_name.ptr, key_name.len));
                    var argv = [_]qjs.JSValue{event_obj};
                    const this = dom_api.wrapNodePublic(ctx, node);
                    const ret = qjs.JS_Call(ctx, callback, this, 1, &argv);
                    qjs.JS_FreeValue(ctx, ret);
                    qjs.JS_FreeValue(ctx, this);
                    qjs.JS_FreeValue(ctx, event_obj);

                    if (current_event_flags.stop_propagation) break;
                }
                break;
            }
        }
    }

    return !current_event_flags.prevent_default;
}

/// Dispatch an event to a target element with bubbling.
/// Returns true if preventDefault was NOT called.
pub fn dispatchEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8) bool {
    current_event_flags = .{};

    // Collect ancestors for bubbling (target -> ... -> document)
    var path: [64]*lxb.lxb_dom_node_t = undefined;
    var path_len: usize = 0;
    var current: ?*lxb.lxb_dom_node_t = target;
    while (current) |node| {
        if (path_len < path.len) {
            path[path_len] = node;
            path_len += 1;
        }
        current = node.parent;
    }

    // Bubble: from target up to root
    for (path[0..path_len]) |node| {
        if (current_event_flags.stop_propagation) break;

        // Find listeners for this node + event type
        for (listener_entries.items) |*entry| {
            if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                // Call each callback
                for (entry.callbacks.items) |callback| {
                    const event_obj = createEventObject(ctx, event_type, target, node);
                    var argv = [_]qjs.JSValue{event_obj};
                    const this = dom_api.wrapNodePublic(ctx, node);
                    const ret = qjs.JS_Call(ctx, callback, this, 1, &argv);
                    qjs.JS_FreeValue(ctx, ret);
                    qjs.JS_FreeValue(ctx, this);
                    qjs.JS_FreeValue(ctx, event_obj);

                    if (current_event_flags.stop_propagation) break;
                }
                break;
            }
        }
    }

    return !current_event_flags.prevent_default;
}

/// Dispatch a window-level event (load, DOMContentLoaded, etc.).
pub fn dispatchWindowEvent(ctx: *qjs.JSContext, event_type: []const u8) void {
    for (window_listener_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) {
            for (entry.callbacks.items) |callback| {
                const event_obj = createEventObject(ctx, event_type, null, null);
                var argv = [_]qjs.JSValue{event_obj};
                const global = qjs.JS_GetGlobalObject(ctx);
                const ret = qjs.JS_Call(ctx, callback, global, 1, &argv);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, global);
                qjs.JS_FreeValue(ctx, event_obj);
            }
            break;
        }
    }
}

/// Also dispatch on document listeners for "DOMContentLoaded"
pub fn dispatchDocumentEvent(ctx: *qjs.JSContext, event_type: []const u8) void {
    // DOMContentLoaded is typically listened on document, which we treat
    // as window-level since our document object doesn't have an opaque node.
    dispatchWindowEvent(ctx, event_type);
}

// ── Registration ────────────────────────────────────────────────────

pub fn registerEventApis(ctx: *qjs.JSContext) void {
    g_ctx = ctx;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // Add addEventListener/removeEventListener to window (global)
    _ = qjs.JS_SetPropertyStr(ctx, global, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, global, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 2));

    // Also add to document
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    if (!quickjs.JS_IsUndefined(doc_obj) and !quickjs.JS_IsNull(doc_obj)) {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 2));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 2));
    }
    qjs.JS_FreeValue(ctx, doc_obj);

    // Set up window global (alias to global)
    _ = qjs.JS_SetPropertyStr(ctx, global, "window", qjs.JS_DupValue(ctx, global));
}

/// Also inject addEventListener/removeEventListener into the Element prototype.
/// This must be called after registerDomApis sets the class prototypes.
pub fn injectElementEventMethods(ctx: *qjs.JSContext, class_id: qjs.JSClassID) void {
    const proto = qjs.JS_GetClassProto(ctx, class_id);
    if (quickjs.JS_IsUndefined(proto) or quickjs.JS_IsNull(proto)) {
        qjs.JS_FreeValue(ctx, proto);
        return;
    }
    _ = qjs.JS_SetPropertyStr(ctx, proto, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 2));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "click", qjs.JS_NewCFunction(ctx, &jsElementClick, "click", 0));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "dispatchEvent", qjs.JS_NewCFunction(ctx, &jsElementDispatchEvent, "dispatchEvent", 1));
    qjs.JS_FreeValue(ctx, proto);
}

/// element.click() — programmatically fire a click event on the element
fn jsElementClick(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_UNDEFINED();
    _ = dispatchEvent(c, node, "click");
    return quickjs.JS_UNDEFINED();
}

/// element.dispatchEvent(event) — fire a custom event
fn jsElementDispatchEvent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return qjs.JS_FALSE;
    if (argc < 1) return qjs.JS_FALSE;
    const args = argv orelse return qjs.JS_FALSE;
    const node = dom_api.getNodePublic(c, this_val) orelse return qjs.JS_FALSE;
    // Get event type from event object's .type property
    const type_val = qjs.JS_GetPropertyStr(c, args[0], "type");
    defer qjs.JS_FreeValue(c, type_val);
    const type_str = dom_api.jsStringToSlice(c, type_val) orelse return qjs.JS_FALSE;
    defer qjs.JS_FreeCString(c, type_str.ptr);
    const result = dispatchEvent(c, node, type_str.ptr[0..type_str.len]);
    return if (result) qjs.JS_TRUE else qjs.JS_FALSE;
}

/// Expose the element_class_id for the event system to inject methods.
pub fn getElementClassId() qjs.JSClassID {
    return @import("dom_api.zig").element_class_id;
}

/// Expose the text_class_id.
pub fn getTextClassId() qjs.JSClassID {
    return @import("dom_api.zig").text_class_id;
}

/// Clean up all event listeners. Called when navigating to a new page.
pub fn deinitEvents(ctx: *qjs.JSContext) void {
    for (listener_entries.items) |*entry| {
        for (entry.callbacks.items) |cb| {
            qjs.JS_FreeValue(ctx, cb);
        }
        entry.callbacks.deinit(allocator);
        entry.key.deinit();
    }
    listener_entries.deinit(allocator);
    listener_entries = .empty;

    for (window_listener_entries.items) |*entry| {
        for (entry.callbacks.items) |cb| {
            qjs.JS_FreeValue(ctx, cb);
        }
        entry.callbacks.deinit(allocator);
        allocator.free(entry.event_type);
    }
    window_listener_entries.deinit(allocator);
    window_listener_entries = .empty;

    g_ctx = null;
}

// jsStringToSlice is accessed via dom_api.jsStringToSlice
