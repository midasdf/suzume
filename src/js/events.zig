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

    const callback = args[1];

    const node = dom_api.getNodePublic(c, this_val);
    if (node) |n| {
        for (listener_entries.items) |*entry| {
            if (entry.key.node == n and std.mem.eql(u8, entry.key.event_type, event_type)) {
                // Find and remove the callback that matches by JS object identity
                var i: usize = 0;
                while (i < entry.callbacks.items.len) {
                    if (jsValueEqual(entry.callbacks.items[i], callback)) {
                        qjs.JS_FreeValue(c, entry.callbacks.items[i]);
                        _ = entry.callbacks.orderedRemove(i);
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
                var i: usize = 0;
                while (i < entry.callbacks.items.len) {
                    if (jsValueEqual(entry.callbacks.items[i], callback)) {
                        qjs.JS_FreeValue(c, entry.callbacks.items[i]);
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

/// Dispatch a mouse event (mousedown/mouseup/mousemove/mouseover/mouseout) with coordinates.
pub fn dispatchMouseEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, client_x: i32, client_y: i32, button: i32) bool {
    const saved_flags = current_event_flags;
    current_event_flags = .{};

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

    for (path[0..path_len]) |node| {
        if (current_event_flags.stop_propagation) break;

        for (listener_entries.items) |*entry| {
            if (entry.key.node == node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                for (entry.callbacks.items) |callback| {
                    const event_obj = createMouseEventObject(ctx, event_type, target, node, client_x, client_y, button);
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

    // Also fire window/document-level listeners (bubbles to window)
    if (!current_event_flags.stop_propagation) {
        for (window_listener_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.event_type, event_type)) {
                for (entry.callbacks.items) |callback| {
                    const event_obj = createMouseEventObject(ctx, event_type, target, null, client_x, client_y, button);
                    var argv = [_]qjs.JSValue{event_obj};
                    const global = qjs.JS_GetGlobalObject(ctx);
                    const ret = qjs.JS_Call(ctx, callback, global, 1, &argv);
                    qjs.JS_FreeValue(ctx, ret);
                    qjs.JS_FreeValue(ctx, global);
                    qjs.JS_FreeValue(ctx, event_obj);
                    if (current_event_flags.stop_propagation) break;
                }
                break;
            }
        }
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
pub fn dispatchKeyboardEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8, key_code: u32) bool {
    const saved_flags = current_event_flags;
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

    const kb_result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return kb_result;
}

/// Dispatch an event to a target element with bubbling.
/// Returns true if preventDefault was NOT called.
pub fn dispatchEvent(ctx: *qjs.JSContext, target: *lxb.lxb_dom_node_t, event_type: []const u8) bool {
    const saved_flags = current_event_flags;
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

    const ev_result = !current_event_flags.prevent_default;
    current_event_flags = saved_flags;
    return ev_result;
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
    // W3C: returns false if preventDefault() was called, true otherwise
    const not_cancelled = dispatchEvent(c, node, type_str.ptr[0..type_str.len]);
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
