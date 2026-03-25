const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const dom_api = @import("dom_api.zig");

const Allocator = std.mem.Allocator;
const allocator = std.heap.c_allocator;

/// Compare two JSValues by identity (same tag + same pointer for objects/functions).
fn jsValueEqual(a: qjs.JSValue, b: qjs.JSValue) bool {
    return a.tag == b.tag and a.u.ptr == b.u.ptr;
}

/// Check if a JS value is the document object (not window/global).
fn isDocumentObject(ctx: *qjs.JSContext, val: qjs.JSValue) bool {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc);
    return jsValueEqual(val, doc);
}

// ── Event Listener Storage ──────────────────────────────────────────

/// Key for event listener map: node pointer + event type.
const ListenerKey = struct {
    node: *lxb.lxb_dom_node_t,
    event_type: []const u8, // Owned copy

    fn deinit(self: *ListenerKey) void {
        allocator.free(self.event_type);
    }
};

/// A listener record stores callback + addEventListener options (capture/passive/once).
const ListenerRecord = struct {
    callback: qjs.JSValue,
    capture: bool = false,
    passive: bool = false,
    once: bool = false,
};

const ListenerList = std.ArrayListUnmanaged(ListenerRecord);

/// Map from (node_ptr, event_type) -> list of listener records.
/// We use a simple array of entries since the number is typically small.
const ListenerEntry = struct {
    key: ListenerKey,
    callbacks: ListenerList,
};

var listener_entries: std.ArrayListUnmanaged(ListenerEntry) = .empty;
var g_ctx: ?*qjs.JSContext = null;

// ── Window and Document event listeners ───────────
var window_listener_entries: std.ArrayListUnmanaged(WindowListenerEntry) = .empty;
var document_listener_entries: std.ArrayListUnmanaged(WindowListenerEntry) = .empty;

const WindowListenerEntry = struct {
    event_type: []const u8, // Owned copy
    callbacks: ListenerList, // ListenerRecord list
};

fn findOrCreateWindowEntry(event_type: []const u8) ?*WindowListenerEntry {
    for (window_listener_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) return entry;
    }
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

fn findOrCreateDocumentEntry(event_type: []const u8) ?*WindowListenerEntry {
    for (document_listener_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) return entry;
    }
    const owned_type = allocator.alloc(u8, event_type.len) catch return null;
    @memcpy(owned_type, event_type);
    document_listener_entries.append(allocator, .{
        .event_type = owned_type,
        .callbacks = .empty,
    }) catch {
        allocator.free(owned_type);
        return null;
    };
    return &document_listener_entries.items[document_listener_entries.items.len - 1];
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

    // Parse 3rd argument: options object or boolean (legacy useCapture)
    var capture: bool = false;
    var passive: bool = false;
    var once: bool = false;
    if (argc >= 3) {
        if (args[2].tag == qjs.JS_TAG_BOOL) {
            // Legacy: addEventListener(type, cb, useCapture)
            capture = qjs.JS_ToBool(c, args[2]) > 0;
        } else if (args[2].tag == qjs.JS_TAG_OBJECT) {
            // Options object: {capture, passive, once}
            const cap_val = qjs.JS_GetPropertyStr(c, args[2], "capture");
            if (cap_val.tag != qjs.JS_TAG_UNDEFINED) capture = qjs.JS_ToBool(c, cap_val) > 0;
            qjs.JS_FreeValue(c, cap_val);

            const pass_val = qjs.JS_GetPropertyStr(c, args[2], "passive");
            if (pass_val.tag != qjs.JS_TAG_UNDEFINED) passive = qjs.JS_ToBool(c, pass_val) > 0;
            qjs.JS_FreeValue(c, pass_val);

            const once_val = qjs.JS_GetPropertyStr(c, args[2], "once");
            if (once_val.tag != qjs.JS_TAG_UNDEFINED) once = qjs.JS_ToBool(c, once_val) > 0;
            qjs.JS_FreeValue(c, once_val);
        }
    }

    const record = ListenerRecord{
        .callback = qjs.JS_DupValue(c, args[1]),
        .capture = capture,
        .passive = passive,
        .once = once,
    };

    // Check if this is a window/document object (no opaque node)
    const node = dom_api.getNodePublic(c, this_val);
    if (node) |n| {
        const entry = findOrCreateEntry(n, event_type) orelse return quickjs.JS_UNDEFINED();
        entry.callbacks.append(allocator, record) catch {};
    } else {
        // Distinguish window vs document: check if this_val === global.document
        if (isDocumentObject(c, this_val)) {
            const dentry = findOrCreateDocumentEntry(event_type) orelse return quickjs.JS_UNDEFINED();
            dentry.callbacks.append(allocator, record) catch {};
        } else {
            // Window listener
            const wentry = findOrCreateWindowEntry(event_type) orelse return quickjs.JS_UNDEFINED();
            wentry.callbacks.append(allocator, record) catch {};
        }
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

    const callback = args[1];

    // Parse capture flag from 3rd argument (per spec, removeEventListener matches on capture)
    var capture: bool = false;
    if (argc >= 3) {
        if (args[2].tag == qjs.JS_TAG_BOOL) {
            capture = qjs.JS_ToBool(c, args[2]) > 0;
        } else if (args[2].tag == qjs.JS_TAG_OBJECT) {
            const cap_val = qjs.JS_GetPropertyStr(c, args[2], "capture");
            if (cap_val.tag != qjs.JS_TAG_UNDEFINED) capture = qjs.JS_ToBool(c, cap_val) > 0;
            qjs.JS_FreeValue(c, cap_val);
        }
    }

    const node = dom_api.getNodePublic(c, this_val);
    if (node) |n| {
        for (listener_entries.items) |*entry| {
            if (entry.key.node == n and std.mem.eql(u8, entry.key.event_type, event_type)) {
                // Find and remove the callback that matches by JS object identity AND capture flag
                var i: usize = 0;
                while (i < entry.callbacks.items.len) {
                    const rec = entry.callbacks.items[i];
                    if (jsValueEqual(rec.callback, callback) and rec.capture == capture) {
                        qjs.JS_FreeValue(c, rec.callback);
                        _ = entry.callbacks.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
                break;
            }
        }
    } else {
        // Document or Window listener removal
        const entries_list = if (isDocumentObject(c, this_val)) &document_listener_entries else &window_listener_entries;
        for (entries_list.items) |*entry| {
            if (std.mem.eql(u8, entry.event_type, event_type)) {
                var i: usize = 0;
                while (i < entry.callbacks.items.len) {
                    const rec = entry.callbacks.items[i];
                    if (jsValueEqual(rec.callback, callback) and rec.capture == capture) {
                        qjs.JS_FreeValue(c, rec.callback);
                        _ = entry.callbacks.orderedRemove(i);
                        break;
                    }
                    i += 1;
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
    stop_immediate_propagation: bool = false,
};

/// Thread-local event flags for the current dispatch.
var current_event_flags: EventFlags = .{};

fn jsPreventDefault(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // DOM spec: preventDefault() has no effect if cancelable is false
    if (ctx) |c| {
        const cancelable = qjs.JS_GetPropertyStr(c, this_val, "cancelable");
        defer qjs.JS_FreeValue(c, cancelable);
        if (qjs.JS_ToBool(c, cancelable) <= 0) return quickjs.JS_UNDEFINED();
        // Set defaultPrevented on the JS event object too
        _ = qjs.JS_SetPropertyStr(c, this_val, "defaultPrevented", quickjs.JS_NewBool(true));
    }
    current_event_flags.prevent_default = true;
    return quickjs.JS_UNDEFINED();
}

fn jsStopPropagation(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    current_event_flags.stop_propagation = true;
    if (ctx) |c| {
        _ = qjs.JS_SetPropertyStr(c, this_val, "_stopped", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(c, this_val, "_cancelBubble", quickjs.JS_NewBool(true));
    }
    return quickjs.JS_UNDEFINED();
}

fn jsStopImmediatePropagation(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    current_event_flags.stop_propagation = true;
    current_event_flags.stop_immediate_propagation = true;
    if (ctx) |c| {
        _ = qjs.JS_SetPropertyStr(c, this_val, "_stopped", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(c, this_val, "_stopImmediate", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(c, this_val, "_cancelBubble", quickjs.JS_NewBool(true));
    }
    return quickjs.JS_UNDEFINED();
}

fn jsComposedPath(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}

fn jsInitEvent(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    // initEvent(type, bubbles, cancelable)
    _ = qjs.JS_SetPropertyStr(c, this_val, "type", qjs.JS_DupValue(c, args[0]));
    if (argc >= 2) _ = qjs.JS_SetPropertyStr(c, this_val, "bubbles", qjs.JS_DupValue(c, args[1]));
    if (argc >= 3) _ = qjs.JS_SetPropertyStr(c, this_val, "cancelable", qjs.JS_DupValue(c, args[2]));
    return quickjs.JS_UNDEFINED();
}

fn createEventObject(ctx: *qjs.JSContext, event_type: []const u8, target: ?*lxb.lxb_dom_node_t, current_target: ?*lxb.lxb_dom_node_t) qjs.JSValue {
    const event = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(event)) return event;

    _ = qjs.JS_SetPropertyStr(ctx, event, "type", qjs.JS_NewStringLen(ctx, event_type.ptr, event_type.len));
    _ = qjs.JS_SetPropertyStr(ctx, event, "bubbles", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(ctx, event, "cancelable", quickjs.JS_NewBool(true));
    _ = qjs.JS_SetPropertyStr(ctx, event, "defaultPrevented", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, event, "eventPhase", qjs.JS_NewInt32(ctx, 0));

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
    _ = qjs.JS_SetPropertyStr(ctx, event, "stopImmediatePropagation", qjs.JS_NewCFunction(ctx, &jsStopImmediatePropagation, "stopImmediatePropagation", 0));

    // Additional DOM Event interface properties
    _ = qjs.JS_SetPropertyStr(ctx, event, "_cancelBubble", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, event, "composed", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, event, "isTrusted", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, event, "timeStamp", qjs.JS_NewFloat64(ctx, @as(f64, @floatFromInt(std.time.milliTimestamp()))));
    _ = qjs.JS_SetPropertyStr(ctx, event, "srcElement", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(ctx, event, "composedPath", qjs.JS_NewCFunction(ctx, &jsComposedPath, "composedPath", 0));
    _ = qjs.JS_SetPropertyStr(ctx, event, "initEvent", qjs.JS_NewCFunction(ctx, &jsInitEvent, "initEvent", 3));
    _ = qjs.JS_SetPropertyStr(ctx, event, "NONE", qjs.JS_NewInt32(ctx, 0));
    _ = qjs.JS_SetPropertyStr(ctx, event, "CAPTURING_PHASE", qjs.JS_NewInt32(ctx, 1));
    _ = qjs.JS_SetPropertyStr(ctx, event, "AT_TARGET", qjs.JS_NewInt32(ctx, 2));
    _ = qjs.JS_SetPropertyStr(ctx, event, "BUBBLING_PHASE", qjs.JS_NewInt32(ctx, 3));

    return event;
}

/// Update target/currentTarget/eventPhase on an existing JS event object during dispatch.
fn updateEventObjectForDispatch(ctx: *qjs.JSContext, event: qjs.JSValue, target: ?*lxb.lxb_dom_node_t, current_target: ?*lxb.lxb_dom_node_t, phase: i32) void {
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
    _ = qjs.JS_SetPropertyStr(ctx, event, "eventPhase", qjs.JS_NewInt32(ctx, phase));
}

/// Ensure a JS event object has preventDefault/stopPropagation/stopImmediatePropagation methods
/// that interact with our dispatch flags. This is used when dispatching user-created Event objects.
fn ensureEventMethods(ctx: *qjs.JSContext, event: qjs.JSValue) void {
    // Always overwrite with our native implementations so they interact with current_event_flags
    _ = qjs.JS_SetPropertyStr(ctx, event, "preventDefault", qjs.JS_NewCFunction(ctx, &jsPreventDefault, "preventDefault", 0));
    _ = qjs.JS_SetPropertyStr(ctx, event, "stopPropagation", qjs.JS_NewCFunction(ctx, &jsStopPropagation, "stopPropagation", 0));
    _ = qjs.JS_SetPropertyStr(ctx, event, "stopImmediatePropagation", qjs.JS_NewCFunction(ctx, &jsStopImmediatePropagation, "stopImmediatePropagation", 0));
}

/// Create a mouse event object with clientX, clientY, button, pageX, pageY.
fn createMouseEventObject(ctx: *qjs.JSContext, event_type: []const u8, target: ?*lxb.lxb_dom_node_t, current_target: ?*lxb.lxb_dom_node_t, client_x: i32, client_y: i32, button: i32) qjs.JSValue {
    const event = createEventObject(ctx, event_type, target, current_target);
    if (quickjs.JS_IsException(event)) return event;
    _ = qjs.JS_SetPropertyStr(ctx, event, "clientX", qjs.JS_NewInt32(ctx, client_x));
    _ = qjs.JS_SetPropertyStr(ctx, event, "clientY", qjs.JS_NewInt32(ctx, client_y));
    // pageX/pageY include scroll offset per CSSOM View spec
    _ = qjs.JS_SetPropertyStr(ctx, event, "pageX", qjs.JS_NewInt32(ctx, client_x + @as(i32, @intFromFloat(dom_api.scroll_x))));
    _ = qjs.JS_SetPropertyStr(ctx, event, "pageY", qjs.JS_NewInt32(ctx, client_y + @as(i32, @intFromFloat(dom_api.scroll_y))));
    _ = qjs.JS_SetPropertyStr(ctx, event, "button", qjs.JS_NewInt32(ctx, button));
    // buttons: bitmask of currently pressed buttons. Only set during mousedown.
    const is_down = std.mem.eql(u8, event_type, "mousedown");
    const buttons_val: i32 = if (is_down) (if (button == 0) 1 else if (button == 2) 2 else 0) else 0;
    _ = qjs.JS_SetPropertyStr(ctx, event, "buttons", qjs.JS_NewInt32(ctx, buttons_val));
    return event;
}

/// Sync JS event object's _stopped/_stopImmediate flags to native current_event_flags.
/// This is needed because JS code might set cancelBubble=true or call stopPropagation()
/// via the JS prototype methods (not our native C callbacks).
fn syncStopFlags(ctx: *qjs.JSContext, event_obj: qjs.JSValue) void {
    const stopped = qjs.JS_GetPropertyStr(ctx, event_obj, "_stopped");
    defer qjs.JS_FreeValue(ctx, stopped);
    if (qjs.JS_ToBool(ctx, stopped) > 0) {
        current_event_flags.stop_propagation = true;
    }
    const stop_imm = qjs.JS_GetPropertyStr(ctx, event_obj, "_stopImmediate");
    defer qjs.JS_FreeValue(ctx, stop_imm);
    if (qjs.JS_ToBool(ctx, stop_imm) > 0) {
        current_event_flags.stop_immediate_propagation = true;
    }
}

/// Call listeners on a specific node for the given event type and phase.
/// `is_target` means we're at the target element (phase 2) — call ALL listeners.
/// Otherwise only call listeners matching the `capture_phase` flag.
/// Handles `once` removal and `stopImmediatePropagation`.
fn callListenersOnNode(ctx: *qjs.JSContext, entry: *ListenerEntry, event_obj: qjs.JSValue, node: *lxb.lxb_dom_node_t, is_target: bool, capture_phase: bool) void {
    var i: usize = 0;
    while (i < entry.callbacks.items.len) {
        if (current_event_flags.stop_immediate_propagation) break;

        const rec = entry.callbacks.items[i];
        // At target: call all listeners; during capture/bubble: only matching phase
        if (!is_target and rec.capture != capture_phase) {
            i += 1;
            continue;
        }

        const this = dom_api.wrapNodePublic(ctx, node);
        var argv = [_]qjs.JSValue{event_obj};
        const ret = qjs.JS_Call(ctx, rec.callback, this, 1, &argv);
        qjs.JS_FreeValue(ctx, ret);
        qjs.JS_FreeValue(ctx, this);

        // Sync JS-side stop flags to native (e.g. cancelBubble setter)
        syncStopFlags(ctx, event_obj);

        if (rec.once) {
            qjs.JS_FreeValue(ctx, rec.callback);
            _ = entry.callbacks.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Call listeners from a WindowListenerEntry list with phase filtering.
/// `this_obj` is passed as `this` to callbacks (global for window, document for document).
/// `is_target` = true means AT_TARGET phase (call all listeners regardless of capture flag).
/// `capture_phase` = true means only call capture listeners; false = only bubble listeners.
fn callEntryListeners(ctx: *qjs.JSContext, entries: *std.ArrayListUnmanaged(WindowListenerEntry), event_type: []const u8, event_obj: qjs.JSValue, this_obj: qjs.JSValue, is_target: bool, capture_phase: bool) void {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) {
            var i: usize = 0;
            while (i < entry.callbacks.items.len) {
                if (current_event_flags.stop_immediate_propagation) break;
                const rec = entry.callbacks.items[i];
                // At target: call all; during capture/bubble: only matching phase
                if (!is_target and rec.capture != capture_phase) {
                    i += 1;
                    continue;
                }
                var argv = [_]qjs.JSValue{event_obj};
                const ret = qjs.JS_Call(ctx, rec.callback, this_obj, 1, &argv);
                qjs.JS_FreeValue(ctx, ret);
                syncStopFlags(ctx, event_obj);
                if (rec.once) {
                    qjs.JS_FreeValue(ctx, rec.callback);
                    _ = entry.callbacks.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            break;
        }
    }
}

/// Call window-level listeners for a given event type (legacy, calls all regardless of phase).
fn callWindowListeners(ctx: *qjs.JSContext, event_type: []const u8, event_obj: qjs.JSValue) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, true, false);
}

/// Dispatch a mouse event (mousedown/mouseup/mousemove/mouseover/mouseout) with coordinates.
/// Implements full 3-phase dispatch: capture (root->target), target, bubble (target->root).
pub fn dispatchMouseEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, client_x: i32, client_y: i32, button: i32) bool {
    const saved_flags = current_event_flags;
    current_event_flags = .{};

    // Build path: path[0] = target, path[path_len-1] = root
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

    // Create a single event object reused across all phases
    const event_obj = createMouseEventObject(ctx, event_type, target, target, client_x, client_y, button);
    defer qjs.JS_FreeValue(ctx, event_obj);

    // Phase 1: Capture (root -> target, excluding target)
    if (path_len > 1) {
        var ci: usize = path_len - 1;
        while (ci > 0) : (ci -= 1) {
            if (current_event_flags.stop_propagation) break;
            const node = path[ci];
            updateEventObjectForDispatch(ctx, event_obj, target, node, 1); // CAPTURING_PHASE
            for (listener_entries.items) |*entry| {
                if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(ctx, entry, event_obj, node, false, true);
                    break;
                }
            }
        }
    }

    // Phase 2: At Target
    if (!current_event_flags.stop_propagation) {
        updateEventObjectForDispatch(ctx, event_obj, target, target, 2); // AT_TARGET
        for (listener_entries.items) |*entry| {
            if (entry.key.node == target and std.mem.eql(u8, entry.key.event_type, event_type)) {
                callListenersOnNode(ctx, entry, event_obj, target, true, false);
                break;
            }
        }
    }

    // Phase 3: Bubble (target -> root, excluding target)
    if (path_len > 1) {
        var bi: usize = 1;
        while (bi < path_len) : (bi += 1) {
            if (current_event_flags.stop_propagation) break;
            const node = path[bi];
            updateEventObjectForDispatch(ctx, event_obj, target, node, 3); // BUBBLING_PHASE
            for (listener_entries.items) |*entry| {
                if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(ctx, entry, event_obj, node, false, false);
                    break;
                }
            }
        }
    }

    // Also fire window/document-level listeners (bubbles to window)
    if (!current_event_flags.stop_propagation) {
        updateEventObjectForDispatch(ctx, event_obj, target, null, 3);
        callWindowListeners(ctx, event_type, event_obj);
    }

    const result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return result;
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
/// Implements full 3-phase dispatch: capture (root->target), target, bubble (target->root).
pub fn dispatchKeyboardEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, key_code: u32) bool {
    const saved_flags = current_event_flags;
    current_event_flags = .{};

    // Build path: path[0] = target, path[path_len-1] = root
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

    // Create a single event object reused across all phases
    const event_obj = createEventObject(ctx, event_type, target, target);
    defer qjs.JS_FreeValue(ctx, event_obj);
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "keyCode", qjs.JS_NewInt32(ctx, @intCast(key_code)));
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "which", qjs.JS_NewInt32(ctx, @intCast(key_code)));
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "key", qjs.JS_NewStringLen(ctx, key_name.ptr, key_name.len));

    // Phase 1: Capture (root -> target, excluding target)
    if (path_len > 1) {
        var ci: usize = path_len - 1;
        while (ci > 0) : (ci -= 1) {
            if (current_event_flags.stop_propagation) break;
            const node = path[ci];
            updateEventObjectForDispatch(ctx, event_obj, target, node, 1);
            for (listener_entries.items) |*entry| {
                if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(ctx, entry, event_obj, node, false, true);
                    break;
                }
            }
        }
    }

    // Phase 2: At Target
    if (!current_event_flags.stop_propagation) {
        updateEventObjectForDispatch(ctx, event_obj, target, target, 2);
        for (listener_entries.items) |*entry| {
            if (entry.key.node == target and std.mem.eql(u8, entry.key.event_type, event_type)) {
                callListenersOnNode(ctx, entry, event_obj, target, true, false);
                break;
            }
        }
    }

    // Phase 3: Bubble (target -> root, excluding target)
    if (path_len > 1) {
        var bi: usize = 1;
        while (bi < path_len) : (bi += 1) {
            if (current_event_flags.stop_propagation) break;
            const node = path[bi];
            updateEventObjectForDispatch(ctx, event_obj, target, node, 3);
            for (listener_entries.items) |*entry| {
                if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(ctx, entry, event_obj, node, false, false);
                    break;
                }
            }
        }
    }

    const kb_result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return kb_result;
}

/// Dispatch an event to a target element with full 3-phase dispatch.
/// Returns true if preventDefault was NOT called.
pub fn dispatchEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8) bool {
    return dispatchEventWithObj(ctx, target, event_type, null);
}

/// Dispatch an event, optionally using a pre-existing JS event object.
/// If `existing_event` is non-null, that object is passed to listeners (for dispatchEvent(event)).
/// Otherwise a new event object is created internally.
/// Full 3-phase dispatch per DOM spec: Window → Document → ... → target → ... → Document → Window
fn dispatchEventWithObj(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, existing_event: ?qjs.JSValue) bool {
    const saved_flags = current_event_flags;
    current_event_flags = .{};

    // Build path: path[0] = target, path[path_len-1] = root (document node)
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

    // Use existing event or create a new one
    var owns_event = false;

    // DOM spec: check stop propagation flag from event JS object
    if (existing_event) |ev| {
        const stopped_val = qjs.JS_GetPropertyStr(ctx, ev, "_stopped");
        if (qjs.JS_ToBool(ctx, stopped_val) > 0) {
            current_event_flags.stop_propagation = true;
        }
        qjs.JS_FreeValue(ctx, stopped_val);
    }

    const event_obj = if (existing_event) |ev| blk: {
        ensureEventMethods(ctx, ev);
        break :blk ev;
    } else blk: {
        owns_event = true;
        break :blk createEventObject(ctx, event_type, target, target);
    };
    defer {
        if (owns_event) qjs.JS_FreeValue(ctx, event_obj);
    }

    // Get global and document objects for Window/Document phase dispatch
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    // Phase 1: Capture (Window → Document → root → ... → parent of target)
    // 1a: Window capture listeners
    if (!current_event_flags.stop_propagation) {
        updateEventPhase(ctx, event_obj, 1); // CAPTURING_PHASE
        setEventCurrentTarget(ctx, event_obj, global);
        callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, false, true);
    }
    // 1b: Document capture listeners
    if (!current_event_flags.stop_propagation) {
        setEventCurrentTarget(ctx, event_obj, doc_obj);
        callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, false, true);
    }
    // 1c: DOM node capture (root -> parent of target)
    if (path_len > 1) {
        var ci: usize = path_len - 1;
        while (ci > 0) : (ci -= 1) {
            if (current_event_flags.stop_propagation) break;
            const node = path[ci];
            updateEventObjectForDispatch(ctx, event_obj, target, node, 1);
            for (listener_entries.items) |*entry| {
                if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(ctx, entry, event_obj, node, false, true);
                    break;
                }
            }
        }
    }

    // Phase 2: At Target
    if (!current_event_flags.stop_propagation) {
        updateEventObjectForDispatch(ctx, event_obj, target, target, 2);
        for (listener_entries.items) |*entry| {
            if (entry.key.node == target and std.mem.eql(u8, entry.key.event_type, event_type)) {
                callListenersOnNode(ctx, entry, event_obj, target, true, false);
                break;
            }
        }
    }

    // Phase 3: Bubble (parent of target → ... → root → Document → Window)
    var should_bubble = true;
    if (existing_event != null) {
        const bubbles_val = qjs.JS_GetPropertyStr(ctx, event_obj, "bubbles");
        should_bubble = qjs.JS_ToBool(ctx, bubbles_val) > 0;
        qjs.JS_FreeValue(ctx, bubbles_val);
    }
    if (should_bubble) {
        // 3a: DOM node bubble (parent of target -> root)
        if (path_len > 1) {
            var bi: usize = 1;
            while (bi < path_len) : (bi += 1) {
                if (current_event_flags.stop_propagation) break;
                const node = path[bi];
                updateEventObjectForDispatch(ctx, event_obj, target, node, 3);
                for (listener_entries.items) |*entry| {
                    if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                        callListenersOnNode(ctx, entry, event_obj, node, false, false);
                        break;
                    }
                }
            }
        }
        // 3b: Document bubble listeners
        if (!current_event_flags.stop_propagation) {
            updateEventPhase(ctx, event_obj, 3); // BUBBLING_PHASE
            setEventCurrentTarget(ctx, event_obj, doc_obj);
            callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, false, false);
        }
        // 3c: Window bubble listeners
        if (!current_event_flags.stop_propagation) {
            setEventCurrentTarget(ctx, event_obj, global);
            callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, false, false);
        }
    }

    const ev_result = !current_event_flags.prevent_default;

    // DOM spec: dispatch resets stop propagation flag on the event
    // Also reset eventPhase to NONE after dispatch completes
    if (existing_event) |ev| {
        _ = qjs.JS_SetPropertyStr(ctx, ev, "_stopped", quickjs.JS_NewBool(false));
        _ = qjs.JS_SetPropertyStr(ctx, ev, "_cancelBubble", quickjs.JS_NewBool(false));
    }
    updateEventPhase(ctx, event_obj, 0); // NONE
    setEventCurrentTarget(ctx, event_obj, quickjs.JS_NULL());

    current_event_flags = saved_flags;
    return ev_result;
}

/// Helper: set eventPhase on event object.
fn updateEventPhase(ctx: *qjs.JSContext, event_obj: qjs.JSValue, phase: i32) void {
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "eventPhase", qjs.JS_NewInt32(ctx, phase));
}

/// Helper: set currentTarget on event object.
fn setEventCurrentTarget(ctx: *qjs.JSContext, event_obj: qjs.JSValue, current_target: qjs.JSValue) void {
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "currentTarget", qjs.JS_DupValue(ctx, current_target));
}

/// Dispatch a window-level event (load, DOMContentLoaded, etc.).
pub fn dispatchWindowEvent(ctx: *qjs.JSContext, event_type: []const u8) void {
    for (window_listener_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.event_type, event_type)) {
            const event_obj = createEventObject(ctx, event_type, null, null);
            defer qjs.JS_FreeValue(ctx, event_obj);
            var i: usize = 0;
            while (i < entry.callbacks.items.len) {
                const rec = entry.callbacks.items[i];
                var argv = [_]qjs.JSValue{event_obj};
                const global = qjs.JS_GetGlobalObject(ctx);
                const ret = qjs.JS_Call(ctx, rec.callback, global, 1, &argv);
                qjs.JS_FreeValue(ctx, ret);
                qjs.JS_FreeValue(ctx, global);
                if (rec.once) {
                    qjs.JS_FreeValue(ctx, rec.callback);
                    _ = entry.callbacks.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            break;
        }
    }
}

/// Dispatch on document listeners (DOMContentLoaded, etc.)
pub fn dispatchDocumentEvent(ctx: *qjs.JSContext, event_type: []const u8) void {
    // Fire document listeners first, then window listeners (bubbling order)
    const event_obj = createEventObject(ctx, event_type, null, null);
    defer qjs.JS_FreeValue(ctx, event_obj);
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);
    callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, true, false);
    callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, true, false);
}

// ── Registration ────────────────────────────────────────────────────

pub fn registerEventApis(ctx: *qjs.JSContext) void {
    g_ctx = ctx;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // Add addEventListener/removeEventListener/dispatchEvent to window (global)
    _ = qjs.JS_SetPropertyStr(ctx, global, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 3));
    _ = qjs.JS_SetPropertyStr(ctx, global, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 3));
    _ = qjs.JS_SetPropertyStr(ctx, global, "dispatchEvent", qjs.JS_NewCFunction(ctx, &jsWindowDispatchEvent, "dispatchEvent", 1));

    // Also add to document
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    if (!quickjs.JS_IsUndefined(doc_obj) and !quickjs.JS_IsNull(doc_obj)) {
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 3));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 3));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "dispatchEvent", qjs.JS_NewCFunction(ctx, &jsDocumentDispatchEvent, "dispatchEvent", 1));
    }
    qjs.JS_FreeValue(ctx, doc_obj);

    // Register Event constructor with phase constants
    // Event(type, options?) constructor + Event.NONE/CAPTURING_PHASE/AT_TARGET/BUBBLING_PHASE
    const event_ctor_js =
        \\(function() {
        \\  function Event(type, opts) {
        \\    if (typeof type !== 'string' && typeof type !== 'undefined') type = String(type);
        \\    this.type = type || '';
        \\    var o = opts || {};
        \\    this.bubbles = !!o.bubbles;
        \\    this.cancelable = !!o.cancelable;
        \\    this.composed = !!o.composed;
        \\    this.defaultPrevented = false;
        \\    this._stopped = false;
        \\    this._stopImmediate = false;
        \\    this.isTrusted = false;
        \\    this.eventPhase = 0;
        \\    this._cancelBubble = false;
        \\    this.timeStamp = Date.now();
        \\    this.target = null;
        \\    this.currentTarget = null;
        \\    this.srcElement = null;
        \\    this._initialized = true;
        \\  }
        \\  Event.NONE = 0;
        \\  Event.CAPTURING_PHASE = 1;
        \\  Event.AT_TARGET = 2;
        \\  Event.BUBBLING_PHASE = 3;
        \\  Event.prototype.NONE = 0;
        \\  Event.prototype.CAPTURING_PHASE = 1;
        \\  Event.prototype.AT_TARGET = 2;
        \\  Event.prototype.BUBBLING_PHASE = 3;
        \\  Event.prototype.preventDefault = function() { if (this.cancelable) { this.defaultPrevented = true; this.returnValue = false; } };
        \\  Event.prototype.stopPropagation = function() { this._stopped = true; this._cancelBubble = true; };
        \\  Event.prototype.stopImmediatePropagation = function() { this._stopped = true; this._stopImmediate = true; this._cancelBubble = true; };
        \\  Event.prototype.composedPath = function() { return this._path ? this._path.slice() : []; };
        \\  Event.prototype.initEvent = function(t, b, c) {
        \\    this.type = t; this.bubbles = !!b; this.cancelable = !!c;
        \\    this.defaultPrevented = false; this._stopped = false; this._stopImmediate = false;
        \\    this._cancelBubble = false; this.returnValue = true; this._initialized = true;
        \\  };
        \\  Object.defineProperty(Event.prototype, 'cancelBubble', {
        \\    get: function() { return this._cancelBubble || false; },
        \\    set: function(v) { if (v) { this._cancelBubble = true; this._stopped = true; } },
        \\    configurable: true
        \\  });
        \\  Object.defineProperty(Event.prototype, 'returnValue', {
        \\    get: function() { return !this.defaultPrevented; },
        \\    set: function(v) { if (!v && this.cancelable) this.defaultPrevented = true; },
        \\    configurable: true
        \\  });
        \\  return Event;
        \\})()
    ;
    const event_ctor = qjs.JS_Eval(ctx, event_ctor_js, event_ctor_js.len, "<Event>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(ctx, global, "Event", event_ctor);

    // CustomEvent extends Event
    const custom_event_js =
        \\(function() {
        \\  function CustomEvent(type, opts) {
        \\    Event.call(this, type, opts);
        \\    this.detail = (opts && opts.detail !== undefined) ? opts.detail : null;
        \\  }
        \\  CustomEvent.prototype = Object.create(Event.prototype);
        \\  CustomEvent.prototype.constructor = CustomEvent;
        \\  CustomEvent.prototype.initCustomEvent = function(t, b, c, d) { this.initEvent(t, b, c); this.detail = d; };
        \\  return CustomEvent;
        \\})()
    ;
    const custom_event_ctor = qjs.JS_Eval(ctx, custom_event_js, custom_event_js.len, "<CustomEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(ctx, global, "CustomEvent", custom_event_ctor);

    // Set up window global (alias to global)
    _ = qjs.JS_SetPropertyStr(ctx, global, "window", qjs.JS_DupValue(ctx, global));
}

/// window.dispatchEvent(event) — fire event at window level
fn jsWindowDispatchEvent(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const event_obj = args[0];
    const type_val = qjs.JS_GetPropertyStr(c, event_obj, "type");
    const type_s = dom_api.jsStringToSlice(c, type_val) orelse {
        qjs.JS_FreeValue(c, type_val);
        return quickjs.JS_NewBool(false);
    };
    defer qjs.JS_FreeCString(c, type_s.ptr);
    qjs.JS_FreeValue(c, type_val);
    const event_type = type_s.ptr[0..type_s.len];

    const saved_flags = current_event_flags;
    current_event_flags = .{};

    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);

    // Window is both target and currentTarget (AT_TARGET)
    updateEventPhase(c, event_obj, 2);
    setEventCurrentTarget(c, event_obj, global);
    _ = qjs.JS_SetPropertyStr(c, event_obj, "target", qjs.JS_DupValue(c, global));
    callEntryListeners(c, &window_listener_entries, event_type, event_obj, global, true, false);

    updateEventPhase(c, event_obj, 0);
    setEventCurrentTarget(c, event_obj, quickjs.JS_NULL());

    const result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return if (result) quickjs.JS_NewBool(true) else quickjs.JS_NewBool(false);
}

/// document.dispatchEvent(event) — fire event at document level with bubbling to window
fn jsDocumentDispatchEvent(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NewBool(false);
    if (argc < 1) return quickjs.JS_NewBool(false);
    const args = argv orelse return quickjs.JS_NewBool(false);
    const event_obj = args[0];
    const type_val = qjs.JS_GetPropertyStr(c, event_obj, "type");
    const type_s = dom_api.jsStringToSlice(c, type_val) orelse {
        qjs.JS_FreeValue(c, type_val);
        return quickjs.JS_NewBool(false);
    };
    defer qjs.JS_FreeCString(c, type_s.ptr);
    qjs.JS_FreeValue(c, type_val);
    const event_type = type_s.ptr[0..type_s.len];

    const saved_flags = current_event_flags;
    current_event_flags = .{};

    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);
    const doc_obj = qjs.JS_GetPropertyStr(c, global, "document");
    defer qjs.JS_FreeValue(c, doc_obj);

    _ = qjs.JS_SetPropertyStr(c, event_obj, "target", qjs.JS_DupValue(c, doc_obj));

    // AT_TARGET on document
    updateEventPhase(c, event_obj, 2);
    setEventCurrentTarget(c, event_obj, doc_obj);
    callEntryListeners(c, &document_listener_entries, event_type, event_obj, doc_obj, true, false);

    // Bubble to window
    const bubbles_val = qjs.JS_GetPropertyStr(c, event_obj, "bubbles");
    const should_bubble = qjs.JS_ToBool(c, bubbles_val) > 0;
    qjs.JS_FreeValue(c, bubbles_val);
    if (should_bubble and !current_event_flags.stop_propagation) {
        updateEventPhase(c, event_obj, 3);
        setEventCurrentTarget(c, event_obj, global);
        callEntryListeners(c, &window_listener_entries, event_type, event_obj, global, false, false);
    }

    updateEventPhase(c, event_obj, 0);
    setEventCurrentTarget(c, event_obj, quickjs.JS_NULL());

    const result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return if (result) quickjs.JS_NewBool(true) else quickjs.JS_NewBool(false);
}

/// Also inject addEventListener/removeEventListener into the Element prototype.
/// This must be called after registerDomApis sets the class prototypes.
pub fn injectElementEventMethods(ctx: *qjs.JSContext, class_id: qjs.JSClassID) void {
    const proto = qjs.JS_GetClassProto(ctx, class_id);
    if (quickjs.JS_IsUndefined(proto) or quickjs.JS_IsNull(proto)) {
        qjs.JS_FreeValue(ctx, proto);
        return;
    }
    _ = qjs.JS_SetPropertyStr(ctx, proto, "addEventListener", qjs.JS_NewCFunction(ctx, &jsAddEventListener, "addEventListener", 3));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "removeEventListener", qjs.JS_NewCFunction(ctx, &jsRemoveEventListener, "removeEventListener", 3));
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

/// element.dispatchEvent(event) — fire a custom event, passing the ORIGINAL event object to listeners
fn jsElementDispatchEvent(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_EXCEPTION();
    if (argc < 1) {
        // W3C: TypeError if no event argument
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': 1 argument required");
    }
    const args = argv orelse return quickjs.JS_EXCEPTION();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_EXCEPTION();
    // Get event type from event object's .type property
    const type_val = qjs.JS_GetPropertyStr(c, args[0], "type");
    defer qjs.JS_FreeValue(c, type_val);
    const type_str = dom_api.jsStringToSlice(c, type_val) orelse {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'");
    };
    defer qjs.JS_FreeCString(c, type_str.ptr);
    // W3C: pass the original event object through dispatch, returns false if preventDefault() was called
    const not_cancelled = dispatchEventWithObj(c, node, type_str.ptr[0..type_str.len], args[0]);
    return quickjs.JS_NewBool(not_cancelled);
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
        for (entry.callbacks.items) |rec| {
            qjs.JS_FreeValue(ctx, rec.callback);
        }
        entry.callbacks.deinit(allocator);
        entry.key.deinit();
    }
    listener_entries.deinit(allocator);
    listener_entries = .empty;

    for (window_listener_entries.items) |*entry| {
        for (entry.callbacks.items) |rec| {
            qjs.JS_FreeValue(ctx, rec.callback);
        }
        entry.callbacks.deinit(allocator);
        allocator.free(entry.event_type);
    }
    window_listener_entries.deinit(allocator);
    window_listener_entries = .empty;

    for (document_listener_entries.items) |*entry| {
        entry.callbacks.deinit(allocator);
        allocator.free(entry.event_type);
    }
    document_listener_entries.deinit(allocator);
    document_listener_entries = .empty;

    g_ctx = null;
}

// jsStringToSlice is accessed via dom_api.jsStringToSlice

// ── MutationObserver ────────────────────────────────────────────────

const MutationRecord = struct {
    type_str: []const u8, // "childList" or "attributes" (static, not owned)
    target: *lxb.lxb_dom_node_t,
    attribute_name: ?[]const u8, // owned copy, null for childList
    added_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    removed_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),

    fn deinit(self: *MutationRecord) void {
        if (self.attribute_name) |name| allocator.free(@constCast(name));
        self.added_nodes.deinit(allocator);
        self.removed_nodes.deinit(allocator);
    }
};

const ObserveTarget = struct {
    node: *lxb.lxb_dom_node_t,
    child_list: bool,
    attributes: bool,
    subtree: bool,
};

const MutationObserverEntry = struct {
    callback: qjs.JSValue,
    targets: std.ArrayListUnmanaged(ObserveTarget),
    pending_records: std.ArrayListUnmanaged(MutationRecord),
    disconnected: bool,

    fn deinit(self: *MutationObserverEntry, ctx: *qjs.JSContext) void {
        qjs.JS_FreeValue(ctx, self.callback);
        self.targets.deinit(allocator);
        for (self.pending_records.items) |*r| r.deinit();
        self.pending_records.deinit(allocator);
    }
};

var mutation_observers: std.ArrayListUnmanaged(MutationObserverEntry) = .empty;

/// Record a mutation for any observing MutationObservers.
pub fn recordMutation(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
) void {
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;

            const want = if (std.mem.eql(u8, mutation_type, "childList")) t.child_list
            else if (std.mem.eql(u8, mutation_type, "attributes")) t.attributes
            else false;
            if (!want) continue;

            var record = MutationRecord{
                .type_str = mutation_type,
                .target = target,
                .attribute_name = null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
            };
            if (attr_name) |n| {
                const copy = allocator.alloc(u8, n.len) catch null;
                if (copy) |c| {
                    @memcpy(c, n);
                    record.attribute_name = c;
                }
            }
            if (added) |a| record.added_nodes.append(allocator, a) catch {};
            if (removed) |r| record.removed_nodes.append(allocator, r) catch {};
            obs.pending_records.append(allocator, record) catch {};
            break;
        }
    }
}

fn isDescendant(node: *lxb.lxb_dom_node_t, ancestor: *lxb.lxb_dom_node_t) bool {
    var cur: ?*lxb.lxb_dom_node_t = node.parent;
    while (cur) |c| {
        if (c == ancestor) return true;
        cur = c.parent;
    }
    return false;
}

/// Flush pending mutation records to JS callbacks.
pub fn flushMutationObservers(ctx: *qjs.JSContext) void {
    var i: usize = 0;
    while (i < mutation_observers.items.len) {
        var obs = &mutation_observers.items[i];
        if (obs.disconnected or obs.pending_records.items.len == 0) {
            i += 1;
            continue;
        }

        const records_arr = qjs.JS_NewArray(ctx);
        for (obs.pending_records.items, 0..) |*rec, idx| {
            const record_obj = qjs.JS_NewObject(ctx);
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "type",
                qjs.JS_NewStringLen(ctx, rec.type_str.ptr, rec.type_str.len));
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "target",
                dom_api.wrapNodePublic(ctx, rec.target));

            const added_arr = qjs.JS_NewArray(ctx);
            for (rec.added_nodes.items, 0..) |node, ai| {
                _ = qjs.JS_SetPropertyUint32(ctx, added_arr, @intCast(ai),
                    dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "addedNodes", added_arr);

            const removed_arr = qjs.JS_NewArray(ctx);
            for (rec.removed_nodes.items, 0..) |node, ri| {
                _ = qjs.JS_SetPropertyUint32(ctx, removed_arr, @intCast(ri),
                    dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "removedNodes", removed_arr);

            if (rec.attribute_name) |name| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName",
                    qjs.JS_NewStringLen(ctx, name.ptr, name.len));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName", quickjs.JS_NULL());
            }

            _ = qjs.JS_SetPropertyUint32(ctx, records_arr, @intCast(idx), record_obj);
            rec.deinit();
        }
        obs.pending_records.clearRetainingCapacity();

        var call_args = [_]qjs.JSValue{ records_arr, quickjs.JS_UNDEFINED() };
        const ret = qjs.JS_Call(ctx, obs.callback, quickjs.JS_UNDEFINED(), 2, &call_args);
        qjs.JS_FreeValue(ctx, ret);
        qjs.JS_FreeValue(ctx, records_arr);

        i += 1;
    }
}

// ── MutationObserver JS API ─────────────────────────────────────────

pub fn jsMutationObserverConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (!qjs.JS_IsFunction(c, args[0])) return quickjs.JS_UNDEFINED();

    const obj = qjs.JS_NewObject(c);
    const idx: u32 = @intCast(mutation_observers.items.len);
    mutation_observers.append(allocator, .{
        .callback = qjs.JS_DupValue(c, args[0]),
        .targets = .empty,
        .pending_records = .empty,
        .disconnected = false,
    }) catch return quickjs.JS_UNDEFINED();
    _ = qjs.JS_SetPropertyStr(c, obj, "_idx", qjs.JS_NewInt32(c, @intCast(idx)));
    _ = qjs.JS_SetPropertyStr(c, obj, "observe",
        qjs.JS_NewCFunction(c, &jsMutationObserverObserve, "observe", 2));
    _ = qjs.JS_SetPropertyStr(c, obj, "disconnect",
        qjs.JS_NewCFunction(c, &jsMutationObserverDisconnect, "disconnect", 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "takeRecords",
        qjs.JS_NewCFunction(c, &jsMutationObserverTakeRecords, "takeRecords", 0));
    return obj;
}

fn getObserverIdx(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?u32 {
    const idx_val = qjs.JS_GetPropertyStr(ctx, this_val, "_idx");
    defer qjs.JS_FreeValue(ctx, idx_val);
    var idx: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &idx, idx_val) != 0) return null;
    if (idx < 0 or @as(usize, @intCast(idx)) >= mutation_observers.items.len) return null;
    return @intCast(idx);
}

fn jsMutationObserverObserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const target = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    var child_list = false;
    var attributes_opt = false;
    var subtree = false;

    if (argc >= 2 and !quickjs.JS_IsUndefined(args[1])) {
        child_list = jsBoolProp(c, args[1], "childList");
        attributes_opt = jsBoolProp(c, args[1], "attributes");
        subtree = jsBoolProp(c, args[1], "subtree");
    }

    mutation_observers.items[idx].targets.append(allocator, .{
        .node = target,
        .child_list = child_list,
        .attributes = attributes_opt,
        .subtree = subtree,
    }) catch {};
    mutation_observers.items[idx].disconnected = false;
    return quickjs.JS_UNDEFINED();
}

fn jsBoolProp(ctx: *qjs.JSContext, obj: qjs.JSValue, name: [*:0]const u8) bool {
    const val = qjs.JS_GetPropertyStr(ctx, obj, name);
    defer qjs.JS_FreeValue(ctx, val);
    return qjs.JS_ToBool(ctx, val) > 0;
}

fn jsMutationObserverDisconnect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    mutation_observers.items[idx].disconnected = true;
    mutation_observers.items[idx].targets.clearRetainingCapacity();
    return quickjs.JS_UNDEFINED();
}

fn jsMutationObserverTakeRecords(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}
