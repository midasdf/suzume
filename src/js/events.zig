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

    // DOM spec: callback can be a function or an object with handleEvent method
    // Null callbacks are ignored per spec
    if (!qjs.JS_IsFunction(c, args[1]) and args[1].tag != qjs.JS_TAG_OBJECT) return quickjs.JS_UNDEFINED();
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) return quickjs.JS_UNDEFINED();

    // Parse 3rd argument: options object or boolean (legacy useCapture)
    var capture: bool = false;
    var passive: bool = false;
    var passive_explicit: bool = false;
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
            if (pass_val.tag != qjs.JS_TAG_UNDEFINED) {
                passive = qjs.JS_ToBool(c, pass_val) > 0;
                passive_explicit = true;
            }
            qjs.JS_FreeValue(c, pass_val);

            const once_val = qjs.JS_GetPropertyStr(c, args[2], "once");
            if (once_val.tag != qjs.JS_TAG_UNDEFINED) once = qjs.JS_ToBool(c, once_val) > 0;
            qjs.JS_FreeValue(c, once_val);
        }
    }
    // Passive-by-default: touchstart, touchmove, wheel on window/document/body
    if (!passive_explicit and event_type.len > 0) {
        if (std.mem.eql(u8, event_type, "touchstart") or
            std.mem.eql(u8, event_type, "touchmove") or
            std.mem.eql(u8, event_type, "wheel") or
            std.mem.eql(u8, event_type, "mousewheel"))
        {
            // Check if target is window, document, or body
            if (dom_api.getNodePublic(c, this_val)) |node| {
                if (node.type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
                    passive = true;
                } else if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
                    var name_len: usize = 0;
                    const name_ptr = @import("dom_api.zig").lxb_dom_element_local_name(@ptrCast(node), &name_len);
                    if (name_ptr != null and name_len == 4 and std.mem.eql(u8, name_ptr.?[0..4], "body")) passive = true;
                    if (name_ptr != null and name_len == 4 and std.mem.eql(u8, name_ptr.?[0..4], "html")) passive = true;
                }
            } else {
                // No node = window/global → passive by default
                passive = true;
            }
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

/// Per DOM spec, these event types are composed (cross shadow DOM boundary).
fn isComposedEvent(event_type: []const u8) bool {
    // UI Events that are always composed
    const composed_events = [_][]const u8{
        "click", "dblclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout",
        "mouseenter", "mouseleave", "contextmenu", "wheel",
        "keydown", "keyup", "keypress",
        "input", "beforeinput", "compositionstart", "compositionupdate", "compositionend",
        "focus", "blur", "focusin", "focusout",
        "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout",
        "pointerenter", "pointerleave", "pointercancel", "gotpointercapture", "lostpointercapture",
        "touchstart", "touchmove", "touchend", "touchcancel",
        "dragstart", "drag", "dragend", "dragenter", "dragleave", "dragover", "drop",
        "select", "selectionchange",
    };
    for (composed_events) |e| {
        if (std.mem.eql(u8, event_type, e)) return true;
    }
    return false;
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
    // Per spec: UI events (click, input, focus, etc.) are composed by default
    const is_composed = isComposedEvent(event_type);
    _ = qjs.JS_SetPropertyStr(ctx, event, "composed", quickjs.JS_NewBool(is_composed));
    _ = qjs.JS_SetPropertyStr(ctx, event, "isTrusted", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(ctx, event, "timeStamp", qjs.JS_NewFloat64(ctx, @import("web_api.zig").getPerformanceNow()));
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

/// Call on{eventType} property handler on a JS object (element, document, or window).
/// DOM spec: event handler IDL attributes (onclick, onload, etc.) act as event listeners.
fn callOnEventHandler(ctx: *qjs.JSContext, target_obj: qjs.JSValue, event_type: []const u8, event_obj: qjs.JSValue) void {
    if (current_event_flags.stop_immediate_propagation) return;
    // Build "on" + eventType property name
    var name_buf: [64]u8 = undefined;
    if (event_type.len + 2 > name_buf.len) return;
    name_buf[0] = 'o';
    name_buf[1] = 'n';
    @memcpy(name_buf[2 .. 2 + event_type.len], event_type);
    name_buf[2 + event_type.len] = 0;
    const prop_name: [*:0]const u8 = @ptrCast(name_buf[0 .. 2 + event_type.len :0]);

    const handler = qjs.JS_GetPropertyStr(ctx, target_obj, prop_name);
    defer qjs.JS_FreeValue(ctx, handler);
    if (qjs.JS_IsFunction(ctx, handler)) {
        var argv = [_]qjs.JSValue{event_obj};
        const ret = qjs.JS_Call(ctx, handler, target_obj, 1, &argv);
        qjs.JS_FreeValue(ctx, ret);
        syncStopFlags(ctx, event_obj);
    }
}

/// Invoke a listener callback. Handles both function callbacks and
/// object listeners with a handleEvent method (DOM spec §2.8).
fn invokeListener(ctx: *qjs.JSContext, callback: qjs.JSValue, this_val: qjs.JSValue, event_obj: qjs.JSValue) void {
    var argv = [_]qjs.JSValue{event_obj};
    if (qjs.JS_IsFunction(ctx, callback)) {
        const ret = qjs.JS_Call(ctx, callback, this_val, 1, &argv);
        qjs.JS_FreeValue(ctx, ret);
    } else {
        // Object listener: get handleEvent property and call it with the object as this
        const he = qjs.JS_GetPropertyStr(ctx, callback, "handleEvent");
        if (qjs.JS_IsFunction(ctx, he)) {
            const ret = qjs.JS_Call(ctx, he, callback, 1, &argv);
            qjs.JS_FreeValue(ctx, ret);
        }
        qjs.JS_FreeValue(ctx, he);
    }
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
    // Sync defaultPrevented → prevent_default flag
    const dp = qjs.JS_GetPropertyStr(ctx, event_obj, "defaultPrevented");
    defer qjs.JS_FreeValue(ctx, dp);
    if (qjs.JS_ToBool(ctx, dp) > 0) {
        current_event_flags.prevent_default = true;
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
        // Passive listeners: temporarily make event non-cancelable
        if (rec.passive) {
            const saved = qjs.JS_GetPropertyStr(ctx, event_obj, "cancelable");
            _ = qjs.JS_SetPropertyStr(ctx, event_obj, "cancelable", quickjs.JS_NewBool(false));
            invokeListener(ctx, rec.callback, this, event_obj);
            _ = qjs.JS_SetPropertyStr(ctx, event_obj, "cancelable", saved);
        } else {
            invokeListener(ctx, rec.callback, this, event_obj);
        }
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
                if (rec.passive) {
                    const saved = qjs.JS_GetPropertyStr(ctx, event_obj, "cancelable");
                    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "cancelable", quickjs.JS_NewBool(false));
                    invokeListener(ctx, rec.callback, this_obj, event_obj);
                    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "cancelable", saved);
                } else {
                    invokeListener(ctx, rec.callback, this_obj, event_obj);
                }
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
        // Call on{event} handler property on target element
        if (!current_event_flags.stop_propagation) {
            const target_js = dom_api.wrapNodePublic(ctx, target);
            callOnEventHandler(ctx, target_js, event_type, event_obj);
            qjs.JS_FreeValue(ctx, target_js);
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
                // Call on{event} handler on bubble node
                if (!current_event_flags.stop_propagation) {
                    const node_js = dom_api.wrapNodePublic(ctx, node);
                    callOnEventHandler(ctx, node_js, event_type, event_obj);
                    qjs.JS_FreeValue(ctx, node_js);
                }
            }
        }
        // 3b: Document bubble listeners + on{event} handler
        if (!current_event_flags.stop_propagation) {
            updateEventPhase(ctx, event_obj, 3); // BUBBLING_PHASE
            setEventCurrentTarget(ctx, event_obj, doc_obj);
            callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, false, false);
            callOnEventHandler(ctx, doc_obj, event_type, event_obj);
        }
        // 3c: Window bubble listeners + on{event} handler
        if (!current_event_flags.stop_propagation) {
            setEventCurrentTarget(ctx, event_obj, global);
            callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, false, false);
            callOnEventHandler(ctx, global, event_type, event_obj);
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
        \\    this.timeStamp = (typeof performance!=='undefined'&&performance.now)?performance.now():Date.now();
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
        \\    if(arguments.length<1)throw new TypeError("Failed to execute 'initEvent': 1 argument required, but only 0 present.");
        \\    if(this._dispatching)return;
        \\    this.type = t; this.bubbles = !!b; this.cancelable = !!c;
        \\    this.defaultPrevented = false; this._stopped = false; this._stopImmediate = false;
        \\    this._cancelBubble = false; this.returnValue = true; this._initialized = true;
        \\    this.target = null; this.currentTarget = null;
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
        \\  CustomEvent.prototype.initCustomEvent = function(t, b, c, d) { if(arguments.length<1)throw new TypeError("Failed to execute 'initCustomEvent': 1 argument required.");this.initEvent(t, b, c); this.detail = d!==undefined?d:null; };
        \\  return CustomEvent;
        \\})()
    ;
    const custom_event_ctor = qjs.JS_Eval(ctx, custom_event_js, custom_event_js.len, "<CustomEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(ctx, global, "CustomEvent", custom_event_ctor);

    // UIEvent extends Event
    {
        const js =
            \\(function(){
            \\  function UIEvent(t,o){Event.call(this,t,o);o=o||{};this.view=o.view||null;this.detail=o.detail||0;}
            \\  UIEvent.prototype=Object.create(Event.prototype);UIEvent.prototype.constructor=UIEvent;
            \\  UIEvent.prototype.initUIEvent=function(t,b,c,v,d){this.initEvent(t,b,c);this.view=v;this.detail=d;};
            \\  return UIEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<UIEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "UIEvent", ctor);
    }
    // MouseEvent extends UIEvent
    {
        const js =
            \\(function(){
            \\  function MouseEvent(t,o){UIEvent.call(this,t,o);o=o||{};
            \\    this.screenX=o.screenX||0;this.screenY=o.screenY||0;
            \\    this.clientX=o.clientX||0;this.clientY=o.clientY||0;
            \\    this.pageX=o.pageX||this.clientX;this.pageY=o.pageY||this.clientY;
            \\    this.button=o.button||0;this.buttons=o.buttons||0;
            \\    this.relatedTarget=o.relatedTarget||null;
            \\    this.ctrlKey=!!o.ctrlKey;this.shiftKey=!!o.shiftKey;
            \\    this.altKey=!!o.altKey;this.metaKey=!!o.metaKey;
            \\  }
            \\  MouseEvent.prototype=Object.create(UIEvent.prototype);MouseEvent.prototype.constructor=MouseEvent;
            \\  MouseEvent.prototype.initMouseEvent=function(t,b,c,v,d,sx,sy,cx,cy,ctrl,alt,shift,meta,btn,rt){
            \\    this.initUIEvent(t,b,c,v,d);this.screenX=sx;this.screenY=sy;this.clientX=cx;this.clientY=cy;
            \\    this.ctrlKey=ctrl;this.altKey=alt;this.shiftKey=shift;this.metaKey=meta;this.button=btn;this.relatedTarget=rt;
            \\  };
            \\  MouseEvent.prototype.getModifierState=function(){return false;};
            \\  return MouseEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<MouseEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "MouseEvent", ctor);
    }
    // KeyboardEvent extends UIEvent
    {
        const js =
            \\(function(){
            \\  function KeyboardEvent(t,o){UIEvent.call(this,t,o);o=o||{};
            \\    this.key=o.key||'';this.code=o.code||'';
            \\    this.keyCode=o.keyCode||0;this.which=o.which||o.keyCode||0;
            \\    this.ctrlKey=!!o.ctrlKey;this.shiftKey=!!o.shiftKey;
            \\    this.altKey=!!o.altKey;this.metaKey=!!o.metaKey;
            \\    this.repeat=!!o.repeat;this.location=o.location||0;
            \\  }
            \\  KeyboardEvent.prototype=Object.create(UIEvent.prototype);KeyboardEvent.prototype.constructor=KeyboardEvent;
            \\  KeyboardEvent.prototype.getModifierState=function(){return false;};
            \\  KeyboardEvent.DOM_KEY_LOCATION_STANDARD=0;KeyboardEvent.DOM_KEY_LOCATION_LEFT=1;
            \\  KeyboardEvent.DOM_KEY_LOCATION_RIGHT=2;KeyboardEvent.DOM_KEY_LOCATION_NUMPAD=3;
            \\  return KeyboardEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<KeyboardEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "KeyboardEvent", ctor);
    }
    // FocusEvent extends UIEvent
    {
        const js =
            \\(function(){
            \\  function FocusEvent(t,o){UIEvent.call(this,t,o);o=o||{};this.relatedTarget=o.relatedTarget||null;}
            \\  FocusEvent.prototype=Object.create(UIEvent.prototype);FocusEvent.prototype.constructor=FocusEvent;
            \\  return FocusEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<FocusEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "FocusEvent", ctor);
    }
    // WheelEvent extends MouseEvent
    {
        const js =
            \\(function(){
            \\  function WheelEvent(t,o){MouseEvent.call(this,t,o);o=o||{};
            \\    this.deltaX=o.deltaX||0;this.deltaY=o.deltaY||0;this.deltaZ=o.deltaZ||0;
            \\    this.deltaMode=o.deltaMode||0;
            \\  }
            \\  WheelEvent.prototype=Object.create(MouseEvent.prototype);WheelEvent.prototype.constructor=WheelEvent;
            \\  WheelEvent.DOM_DELTA_PIXEL=0;WheelEvent.DOM_DELTA_LINE=1;WheelEvent.DOM_DELTA_PAGE=2;
            \\  return WheelEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<WheelEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "WheelEvent", ctor);
    }
    // InputEvent extends UIEvent
    {
        const js =
            \\(function(){
            \\  function InputEvent(t,o){UIEvent.call(this,t,o);o=o||{};this.inputType=o.inputType||'';this.data=o.data||null;this.isComposing=!!o.isComposing;}
            \\  InputEvent.prototype=Object.create(UIEvent.prototype);InputEvent.prototype.constructor=InputEvent;
            \\  return InputEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<InputEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "InputEvent", ctor);
    }

    // PointerEvent extends MouseEvent
    {
        const js =
            \\(function(){
            \\  function PointerEvent(t,o){MouseEvent.call(this,t,o);o=o||{};
            \\    this.pointerId=o.pointerId||0;this.width=o.width||1;this.height=o.height||1;
            \\    this.pressure=o.pressure||0;this.tangentialPressure=o.tangentialPressure||0;
            \\    this.tiltX=o.tiltX||0;this.tiltY=o.tiltY||0;this.twist=o.twist||0;
            \\    this.pointerType=o.pointerType||'';this.isPrimary=o.isPrimary!==undefined?!!o.isPrimary:false;
            \\  }
            \\  PointerEvent.prototype=Object.create(MouseEvent.prototype);PointerEvent.prototype.constructor=PointerEvent;
            \\  PointerEvent.prototype.getCoalescedEvents=function(){return[];};
            \\  PointerEvent.prototype.getPredictedEvents=function(){return[];};
            \\  return PointerEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<PointerEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "PointerEvent", ctor);
    }
    // TouchEvent extends UIEvent (stub)
    {
        const js =
            \\(function(){
            \\  function TouchEvent(t,o){UIEvent.call(this,t,o);o=o||{};
            \\    this.touches=o.touches||[];this.targetTouches=o.targetTouches||[];
            \\    this.changedTouches=o.changedTouches||[];
            \\  }
            \\  TouchEvent.prototype=Object.create(UIEvent.prototype);TouchEvent.prototype.constructor=TouchEvent;
            \\  return TouchEvent;})()
        ;
        const ctor = qjs.JS_Eval(ctx, js, js.len, "<TouchEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
        _ = qjs.JS_SetPropertyStr(ctx, global, "TouchEvent", ctor);
    }
    // CompositionEvent, HashChangeEvent, PopStateEvent stubs
    {
        const js =
            \\(function(){
            \\  function CompositionEvent(t,o){UIEvent.call(this,t,o);this.data=(o&&o.data)||'';}
            \\  CompositionEvent.prototype=Object.create(UIEvent.prototype);CompositionEvent.prototype.constructor=CompositionEvent;
            \\  globalThis.CompositionEvent=CompositionEvent;
            \\  function HashChangeEvent(t,o){Event.call(this,t,o);o=o||{};this.oldURL=o.oldURL||'';this.newURL=o.newURL||'';}
            \\  HashChangeEvent.prototype=Object.create(Event.prototype);HashChangeEvent.prototype.constructor=HashChangeEvent;
            \\  globalThis.HashChangeEvent=HashChangeEvent;
            \\  function PopStateEvent(t,o){Event.call(this,t,o);this.state=(o&&o.state)||null;}
            \\  PopStateEvent.prototype=Object.create(Event.prototype);PopStateEvent.prototype.constructor=PopStateEvent;
            \\  globalThis.PopStateEvent=PopStateEvent;
            \\  function ErrorEvent(t,o){Event.call(this,t,o);o=o||{};this.message=o.message||'';this.filename=o.filename||'';this.lineno=o.lineno||0;this.colno=o.colno||0;this.error=o.error||null;}
            \\  ErrorEvent.prototype=Object.create(Event.prototype);ErrorEvent.prototype.constructor=ErrorEvent;
            \\  globalThis.ErrorEvent=ErrorEvent;
            \\  function ProgressEvent(t,o){Event.call(this,t,o);o=o||{};this.lengthComputable=!!o.lengthComputable;this.loaded=o.loaded||0;this.total=o.total||0;}
            \\  ProgressEvent.prototype=Object.create(Event.prototype);ProgressEvent.prototype.constructor=ProgressEvent;
            \\  globalThis.ProgressEvent=ProgressEvent;
            \\  function BeforeUnloadEvent(t,o){Event.call(this,t||'beforeunload',o);this.returnValue='';}
            \\  BeforeUnloadEvent.prototype=Object.create(Event.prototype);BeforeUnloadEvent.prototype.constructor=BeforeUnloadEvent;
            \\  globalThis.BeforeUnloadEvent=BeforeUnloadEvent;
            \\  function StorageEvent(t,o){Event.call(this,t,o);o=o||{};this.key=o.key||null;this.oldValue=o.oldValue||null;this.newValue=o.newValue||null;this.url=o.url||'';this.storageArea=o.storageArea||null;}
            \\  StorageEvent.prototype=Object.create(Event.prototype);StorageEvent.prototype.constructor=StorageEvent;
            \\  StorageEvent.prototype.initStorageEvent=function(t,b,c,k,o,n,u,s){this.initEvent(t,b,c);this.key=k;this.oldValue=o;this.newValue=n;this.url=u;this.storageArea=s;};
            \\  globalThis.StorageEvent=StorageEvent;
            \\  function TransitionEvent(t,o){Event.call(this,t,o);o=o||{};this.propertyName=o.propertyName||'';this.elapsedTime=o.elapsedTime||0;this.pseudoElement=o.pseudoElement||'';}
            \\  TransitionEvent.prototype=Object.create(Event.prototype);TransitionEvent.prototype.constructor=TransitionEvent;
            \\  globalThis.TransitionEvent=TransitionEvent;
            \\  function AnimationEvent(t,o){Event.call(this,t,o);o=o||{};this.animationName=o.animationName||'';this.elapsedTime=o.elapsedTime||0;this.pseudoElement=o.pseudoElement||'';}
            \\  AnimationEvent.prototype=Object.create(Event.prototype);AnimationEvent.prototype.constructor=AnimationEvent;
            \\  globalThis.AnimationEvent=AnimationEvent;
            \\  function PageTransitionEvent(t,o){Event.call(this,t,o);this.persisted=!!(o&&o.persisted);}
            \\  PageTransitionEvent.prototype=Object.create(Event.prototype);PageTransitionEvent.prototype.constructor=PageTransitionEvent;
            \\  globalThis.PageTransitionEvent=PageTransitionEvent;
            \\  function SecurityPolicyViolationEvent(t,o){Event.call(this,t,o);o=o||{};this.documentURI=o.documentURI||'';this.referrer=o.referrer||'';this.blockedURI=o.blockedURI||'';this.violatedDirective=o.violatedDirective||'';this.effectiveDirective=o.effectiveDirective||'';this.originalPolicy=o.originalPolicy||'';this.sourceFile=o.sourceFile||'';this.lineNumber=o.lineNumber||0;this.columnNumber=o.columnNumber||0;this.statusCode=o.statusCode||0;this.disposition=o.disposition||'enforce';this.sample=o.sample||'';}
            \\  SecurityPolicyViolationEvent.prototype=Object.create(Event.prototype);SecurityPolicyViolationEvent.prototype.constructor=SecurityPolicyViolationEvent;
            \\  globalThis.SecurityPolicyViolationEvent=SecurityPolicyViolationEvent;
            \\  function PromiseRejectionEvent(t,o){Event.call(this,t,o);this.promise=(o&&o.promise)||null;this.reason=(o&&o.reason)||undefined;}
            \\  PromiseRejectionEvent.prototype=Object.create(Event.prototype);PromiseRejectionEvent.prototype.constructor=PromiseRejectionEvent;
            \\  globalThis.PromiseRejectionEvent=PromiseRejectionEvent;
            \\  function DragEvent(t,o){MouseEvent.call(this,t,o);this.dataTransfer=(o&&o.dataTransfer)||null;}
            \\  DragEvent.prototype=Object.create(MouseEvent.prototype);DragEvent.prototype.constructor=DragEvent;
            \\  globalThis.DragEvent=DragEvent;
            \\  function FormDataEvent(t,o){Event.call(this,t,o);this.formData=(o&&o.formData)||null;}
            \\  FormDataEvent.prototype=Object.create(Event.prototype);FormDataEvent.prototype.constructor=FormDataEvent;
            \\  globalThis.FormDataEvent=FormDataEvent;
            \\  function SubmitEvent(t,o){Event.call(this,t,o);this.submitter=(o&&o.submitter)||null;}
            \\  SubmitEvent.prototype=Object.create(Event.prototype);SubmitEvent.prototype.constructor=SubmitEvent;
            \\  globalThis.SubmitEvent=SubmitEvent;
            \\  function ToggleEvent(t,o){Event.call(this,t,o);o=o||{};this.oldState=o.oldState||'';this.newState=o.newState||'';}
            \\  ToggleEvent.prototype=Object.create(Event.prototype);ToggleEvent.prototype.constructor=ToggleEvent;
            \\  globalThis.ToggleEvent=ToggleEvent;
            \\})()
        ;
        const r = qjs.JS_Eval(ctx, js, js.len, "<misc-events>", qjs.JS_EVAL_TYPE_GLOBAL);
        qjs.JS_FreeValue(ctx, r);
    }

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
    if (argc < 1) return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': 1 argument required");
    const args = argv orelse return quickjs.JS_NewBool(false);
    // DOM spec: TypeError if not an Event (check by trying to get .type property)
    const type_val = qjs.JS_GetPropertyStr(c, args[0], "type");
    if (dom_api.jsStringToSlice(c, type_val) == null) {
        qjs.JS_FreeValue(c, type_val);
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    }
    // DOM spec: InvalidStateError if event's dispatch flag is set or not initialized
    const dispatch_flag = qjs.JS_GetPropertyStr(c, args[0], "_dispatching");
    defer qjs.JS_FreeValue(c, dispatch_flag);
    if (qjs.JS_ToBool(c, dispatch_flag) > 0) {
        qjs.JS_FreeValue(c, type_val);
        return dom_api.throwDOMException(c, "InvalidStateError", "The event is already being dispatched.");
    }
    const init_flag = qjs.JS_GetPropertyStr(c, args[0], "_initialized");
    defer qjs.JS_FreeValue(c, init_flag);
    if (init_flag.tag != qjs.JS_TAG_UNDEFINED and qjs.JS_ToBool(c, init_flag) == 0) {
        qjs.JS_FreeValue(c, type_val);
        return dom_api.throwDOMException(c, "InvalidStateError", "The event has not been initialized.");
    }
    const event_obj = args[0];
    const type_s = dom_api.jsStringToSlice(c, type_val) orelse {
        qjs.JS_FreeValue(c, type_val);
        return quickjs.JS_NewBool(false);
    };
    defer qjs.JS_FreeCString(c, type_s.ptr);
    qjs.JS_FreeValue(c, type_val);
    const event_type = type_s.ptr[0..type_s.len];

    const saved_flags = current_event_flags;
    current_event_flags = .{};

    _ = qjs.JS_SetPropertyStr(c, event_obj, "_dispatching", quickjs.JS_NewBool(true));

    const global = qjs.JS_GetGlobalObject(c);
    defer qjs.JS_FreeValue(c, global);

    // Window is both target and currentTarget (AT_TARGET)
    updateEventPhase(c, event_obj, 2);
    setEventCurrentTarget(c, event_obj, global);
    _ = qjs.JS_SetPropertyStr(c, event_obj, "target", qjs.JS_DupValue(c, global));
    callEntryListeners(c, &window_listener_entries, event_type, event_obj, global, true, false);

    updateEventPhase(c, event_obj, 0);
    setEventCurrentTarget(c, event_obj, quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, event_obj, "_dispatching", quickjs.JS_NewBool(false));

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
    if (argc < 1) return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': 1 argument required");
    const args = argv orelse return quickjs.JS_NewBool(false);
    // DOM spec: TypeError if argument is null/undefined/not an Event
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    }
    const event_obj = args[0];
    // Check _initialized flag (createEvent events start uninitialized)
    const init_flag = qjs.JS_GetPropertyStr(c, event_obj, "_initialized");
    defer qjs.JS_FreeValue(c, init_flag);
    if (init_flag.tag != qjs.JS_TAG_UNDEFINED and qjs.JS_ToBool(c, init_flag) == 0) {
        return dom_api.throwDOMException(c, "InvalidStateError", "The event has not been initialized.");
    }
    const type_val = qjs.JS_GetPropertyStr(c, event_obj, "type");
    const type_s = dom_api.jsStringToSlice(c, type_val) orelse {
        qjs.JS_FreeValue(c, type_val);
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    };
    defer qjs.JS_FreeCString(c, type_s.ptr);
    qjs.JS_FreeValue(c, type_val);
    const event_type = type_s.ptr[0..type_s.len];

    const saved_flags = current_event_flags;
    current_event_flags = .{};

    _ = qjs.JS_SetPropertyStr(c, event_obj, "_dispatching", quickjs.JS_NewBool(true));

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
    _ = qjs.JS_SetPropertyStr(c, event_obj, "_dispatching", quickjs.JS_NewBool(false));

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
    _ = qjs.JS_SetPropertyStr(ctx, proto, "focus", qjs.JS_NewCFunction(ctx, &jsElementFocus, "focus", 0));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "blur", qjs.JS_NewCFunction(ctx, &jsElementBlur, "blur", 0));
    _ = qjs.JS_SetPropertyStr(ctx, proto, "dispatchEvent", qjs.JS_NewCFunction(ctx, &jsElementDispatchEvent, "dispatchEvent", 1));
    qjs.JS_FreeValue(ctx, proto);
}

/// element.focus() — programmatically focus the element
fn jsElementFocus(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const old_active = dom_api.active_element;
    if (old_active != null and old_active != node) {
        // Blur the previously focused element
        _ = dispatchEvent(c, old_active.?, "blur");
    }
    dom_api.active_element = node;
    _ = dispatchEvent(c, node, "focus");
    dom_api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

/// element.blur() — remove focus from the element
fn jsElementBlur(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (dom_api.active_element == node) {
        dom_api.active_element = null;
        _ = dispatchEvent(c, node, "blur");
        dom_api.setDomDirty();
    }
    return quickjs.JS_UNDEFINED();
}

/// element.click() — programmatically fire a click event on the element
/// For checkbox/radio inputs, toggles the checked state before dispatching.
fn jsElementClick(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_UNDEFINED();

    // HTML spec: checkbox/radio toggle checked state on click activation
    // Check via JS properties (tagName, type) since we can't access lexbor directly
    const tagName_val = qjs.JS_GetPropertyStr(c, this_val, "tagName");
    defer qjs.JS_FreeValue(c, tagName_val);
    if (dom_api.jsStringToSlice(c, tagName_val)) |tag_s| {
        defer qjs.JS_FreeCString(c, tag_s.ptr);
        if (std.ascii.eqlIgnoreCase(tag_s.ptr[0..tag_s.len], "INPUT")) {
            const type_val = qjs.JS_GetPropertyStr(c, this_val, "type");
            defer qjs.JS_FreeValue(c, type_val);
            if (dom_api.jsStringToSlice(c, type_val)) |type_s| {
                defer qjs.JS_FreeCString(c, type_s.ptr);
                const t = type_s.ptr[0..type_s.len];
                if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) {
                    const checked_val = qjs.JS_GetPropertyStr(c, this_val, "checked");
                    const was_checked = qjs.JS_ToBool(c, checked_val) > 0;
                    qjs.JS_FreeValue(c, checked_val);
                    _ = qjs.JS_SetPropertyStr(c, this_val, "checked", quickjs.JS_NewBool(!was_checked));
                }
            }
        }
    }

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

    // DOM spec: TypeError if not an Event object
    if (quickjs.JS_IsNull(args[0]) or quickjs.JS_IsUndefined(args[0])) {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
    }

    // DOM spec: InvalidStateError if event's dispatch flag is set or not initialized
    const dispatch_flag = qjs.JS_GetPropertyStr(c, args[0], "_dispatching");
    defer qjs.JS_FreeValue(c, dispatch_flag);
    if (qjs.JS_ToBool(c, dispatch_flag) > 0) {
        return dom_api.throwDOMException(c, "InvalidStateError", "The event is already being dispatched.");
    }
    const init_flag = qjs.JS_GetPropertyStr(c, args[0], "_initialized");
    defer qjs.JS_FreeValue(c, init_flag);
    if (init_flag.tag != qjs.JS_TAG_UNDEFINED and qjs.JS_ToBool(c, init_flag) == 0) {
        return dom_api.throwDOMException(c, "InvalidStateError", "The event has not been initialized.");
    }

    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_NewBool(true);

    // Get event type from event object's .type property
    const type_val = qjs.JS_GetPropertyStr(c, args[0], "type");
    defer qjs.JS_FreeValue(c, type_val);
    const type_str = dom_api.jsStringToSlice(c, type_val) orelse {
        return qjs.JS_ThrowTypeError(c, "Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'");
    };
    defer qjs.JS_FreeCString(c, type_str.ptr);
    // Set dispatch flag, dispatch, then clear
    _ = qjs.JS_SetPropertyStr(c, args[0], "_dispatching", quickjs.JS_NewBool(true));
    const not_cancelled = dispatchEventWithObj(c, node, type_str.ptr[0..type_str.len], args[0]);
    _ = qjs.JS_SetPropertyStr(c, args[0], "_dispatching", quickjs.JS_NewBool(false));
    return quickjs.JS_NewBool(not_cancelled);
}

// Pub wrappers for document event methods
pub const jsAddEventListenerPub = jsAddEventListener;
pub const jsRemoveEventListenerPub = jsRemoveEventListener;
pub const jsWindowDispatchEventPub = jsWindowDispatchEvent;

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
