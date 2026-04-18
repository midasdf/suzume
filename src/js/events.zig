const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const dom_api = @import("dom_api.zig");
const shadow_root_mod = @import("shadow_root.zig");

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
    // Layer 2A — AbortSignal integration (DOM §2.7.1 step 5, §2.9 step 5.3).
    // `removed` is a soft-delete flag checked at dispatch loop heads so that a
    // mid-dispatch abort which strips a later listener from the registry still
    // skips it even when the dispatch loop iterates a snapshot.
    // `signal_ref` + `abort_handler_ref` keep dup'd references to the signal
    // and the internal abort-hook closure so that manual removeEventListener
    // can call `sig.removeEventListener('abort', handler)` and detach the
    // abort step (otherwise `_evtMap['abort']` leaks until the signal GC's).
    removed: bool = false,
    signal_ref: qjs.JSValue = .{ .tag = qjs.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } },
    abort_handler_ref: qjs.JSValue = .{ .tag = qjs.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } },
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
    this_val_raw: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    // QuickJS passes undefined for bare calls like addEventListener(...).
    // Treat undefined this as the global/window object (sloppy mode behavior).
    const this_val = if (quickjs.JS_IsUndefined(this_val_raw)) qjs.JS_GetGlobalObject(c) else this_val_raw;
    defer if (quickjs.JS_IsUndefined(this_val_raw)) qjs.JS_FreeValue(c, this_val);

    // Get event type string
    const type_s = dom_api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    const event_type = type_s.ptr[0..type_s.len];

    // Parse 3rd argument FIRST: options object or boolean (legacy useCapture)
    // DOM spec: options must be read even if callback is null (getter side effects)
    var capture: bool = false;
    var passive: bool = false;
    var passive_explicit: bool = false;
    var once: bool = false;
    // Layer 2A — AbortSignal integration (DOM §2.7.1 step 5, §3.1).
    // If an AbortSignal is supplied, we dup the signal + the abort-hook closure
    // here so the resulting ListenerRecord can later feed them back to
    // sig.removeEventListener('abort', handler) on manual removal.
    var signal_dup: qjs.JSValue = quickjs.JS_UNDEFINED();
    var abort_handler_dup: qjs.JSValue = quickjs.JS_UNDEFINED();
    if (argc >= 3) {
        if (args[2].tag == qjs.JS_TAG_OBJECT) {
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

            // signal option: AbortSignal integration
            const sig_val = qjs.JS_GetPropertyStr(c, args[2], "signal");
            defer qjs.JS_FreeValue(c, sig_val);
            if (sig_val.tag != qjs.JS_TAG_UNDEFINED) {
                if (quickjs.JS_IsNull(sig_val)) {
                    return qjs.JS_ThrowTypeError(c, "Failed to execute 'addEventListener': signal must not be null.");
                }
                // If signal is already aborted, don't add the listener
                const aborted = qjs.JS_GetPropertyStr(c, sig_val, "aborted");
                defer qjs.JS_FreeValue(c, aborted);
                if (qjs.JS_ToBool(c, aborted) > 0) return quickjs.JS_UNDEFINED();
                // Register abort handler to remove the listener.
                // DOM §2.7.1 step 5 + §3.1: the factory returns the inner
                // handler so we can keep a reference and detach the abort
                // step later via sig.removeEventListener('abort', h).
                const sig_js = "(function(sig,el,type,cb,cap){var h=function(){el.removeEventListener(type,cb,cap);};sig.addEventListener('abort',h,{once:true});return h;})";
                const sig_fn = qjs.JS_Eval(c, sig_js, sig_js.len, "<sig>", qjs.JS_EVAL_TYPE_GLOBAL);
                if (!quickjs.JS_IsException(sig_fn)) {
                    var sig_args = [5]qjs.JSValue{ sig_val, this_val, args[0], args[1], quickjs.JS_NewBool(capture) };
                    const handler = qjs.JS_Call(c, sig_fn, quickjs.JS_UNDEFINED(), 5, &sig_args);
                    qjs.JS_FreeValue(c, sig_fn);
                    if (!quickjs.JS_IsException(handler)) {
                        signal_dup = qjs.JS_DupValue(c, sig_val);
                        abort_handler_dup = handler; // transfer ownership (do not free)
                    } else {
                        qjs.JS_FreeValue(c, handler);
                    }
                }
            }
        } else {
            // Legacy: addEventListener(type, cb, useCapture) — any truthy value = capture
            capture = qjs.JS_ToBool(c, args[2]) > 0;
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

    // DOM spec: null/undefined callbacks are ignored (but options were already read above)
    if (!qjs.JS_IsFunction(c, args[1]) and args[1].tag != qjs.JS_TAG_OBJECT) return quickjs.JS_UNDEFINED();
    if (quickjs.JS_IsNull(args[1]) or quickjs.JS_IsUndefined(args[1])) return quickjs.JS_UNDEFINED();

    const record = ListenerRecord{
        .callback = qjs.JS_DupValue(c, args[1]),
        .capture = capture,
        .passive = passive,
        .once = once,
        .signal_ref = signal_dup,
        .abort_handler_ref = abort_handler_dup,
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
            // Check if it's a JS-level node (PI, DocumentType, etc.) with nodeType
            const js_nt = qjs.JS_GetPropertyStr(c, this_val, "nodeType");
            defer qjs.JS_FreeValue(c, js_nt);
            var nt_v: i32 = 0;
            _ = qjs.JS_ToInt32(c, &nt_v, js_nt);
            // Check if this is the global/window object
            const is_global = blk: {
                const gl = qjs.JS_GetGlobalObject(c);
                defer qjs.JS_FreeValue(c, gl);
                break :blk (this_val.tag == gl.tag and this_val.u.ptr == gl.u.ptr);
            };
            if (!is_global) {
                // JS-level node or standalone EventTarget: store listeners on the object.
                // The ListenerRecord is discarded — release the dup'd callback + any
                // abort-tracking refs so they do not leak. The JS-level path's abort
                // hook is already installed on the signal via `sig.addEventListener`
                // above; since we cannot detach it without carrying the handler, leave
                // the polyfill entry in place (it fires `el.removeEventListener(...)`
                // which lands in the JS-level remove path at :315+). Free the dup'd
                // refs now.
                qjs.JS_FreeValue(c, record.callback);
                if (!quickjs.JS_IsUndefined(record.signal_ref)) {
                    qjs.JS_FreeValue(c, record.signal_ref);
                    qjs.JS_FreeValue(c, record.abort_handler_ref);
                }
                const js_code = "(function(el,type,cb,cap,once,pas){var k='__el_'+type+(cap?'\\x00c':'');var a=el[k]||[];for(var i=0;i<a.length;i++)if(a[i].fn===cb)return;a.push({fn:cb,once:once,passive:pas});el[k]=a;})";
                const fn_val = qjs.JS_Eval(c, js_code, js_code.len, "<ael>", qjs.JS_EVAL_TYPE_GLOBAL);
                if (!quickjs.JS_IsException(fn_val)) {
                    var call_args = [6]qjs.JSValue{ this_val, args[0], args[1], quickjs.JS_NewBool(capture), quickjs.JS_NewBool(once), quickjs.JS_NewBool(passive) };

                    const r = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 6, &call_args);
                    qjs.JS_FreeValue(c, r);
                    qjs.JS_FreeValue(c, fn_val);
                }
            } else {
                // Window listener
                const wentry = findOrCreateWindowEntry(event_type) orelse return quickjs.JS_UNDEFINED();
                wentry.callbacks.append(allocator, record) catch {};
            }
        }
    }
    return quickjs.JS_UNDEFINED();
}

pub fn jsRemoveEventListener(
    ctx: ?*qjs.JSContext,
    this_val_raw: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const this_val = if (quickjs.JS_IsUndefined(this_val_raw)) qjs.JS_GetGlobalObject(c) else this_val_raw;
    defer if (quickjs.JS_IsUndefined(this_val_raw)) qjs.JS_FreeValue(c, this_val);

    const type_s = dom_api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, type_s.ptr);
    const event_type = type_s.ptr[0..type_s.len];

    const callback = args[1];

    // Parse capture flag from 3rd argument (per spec, removeEventListener matches on capture)
    var capture: bool = false;
    if (argc >= 3) {
        if (args[2].tag == qjs.JS_TAG_OBJECT) {
            const cap_val = qjs.JS_GetPropertyStr(c, args[2], "capture");
            if (cap_val.tag != qjs.JS_TAG_UNDEFINED) capture = qjs.JS_ToBool(c, cap_val) > 0;
            qjs.JS_FreeValue(c, cap_val);
        } else {
            capture = qjs.JS_ToBool(c, args[2]) > 0;
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
        // Check for JS-level listener storage (__el_ properties)
        {
            const is_global = blk: {
                const gl = qjs.JS_GetGlobalObject(c);
                defer qjs.JS_FreeValue(c, gl);
                break :blk (this_val.tag == gl.tag and this_val.u.ptr == gl.u.ptr);
            };
            if (!is_global and !isDocumentObject(c, this_val)) {
                const rm_js = "(function(el,type,cb,cap){var k='__el_'+type+(cap?'\\x00c':'');var a=el[k];if(!a)return;for(var i=0;i<a.length;i++){if(a[i].fn===cb){a.splice(i,1);return;}}})";
                const rm_fn = qjs.JS_Eval(c, rm_js, rm_js.len, "<rel>", qjs.JS_EVAL_TYPE_GLOBAL);
                if (!quickjs.JS_IsException(rm_fn)) {
                    var rm_args = [4]qjs.JSValue{ this_val, args[0], args[1], quickjs.JS_NewBool(capture) };
                    const rm_r = qjs.JS_Call(c, rm_fn, quickjs.JS_UNDEFINED(), 4, &rm_args);
                    qjs.JS_FreeValue(c, rm_r);
                    qjs.JS_FreeValue(c, rm_fn);
                }
                return quickjs.JS_UNDEFINED();
            }
        }
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

fn jsComposedPath(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    // DOM §4.4.3: return a copy of the event path (touched nodes) built during dispatch.
    // Dispatch stores `_path` on the event object at events.zig:983.
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const stored = qjs.JS_GetPropertyStr(c, this_val, "_path");
    if (qjs.JS_IsArray(stored)) return stored;
    qjs.JS_FreeValue(c, stored);
    return qjs.JS_NewArray(c);
}

fn jsInitEvent(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    // DOM spec: initEvent has no effect while dispatching
    const dispatching = qjs.JS_GetPropertyStr(c, this_val, "_dispatching");
    defer qjs.JS_FreeValue(c, dispatching);
    if (qjs.JS_ToBool(c, dispatching) > 0) return quickjs.JS_UNDEFINED();
    // DOM §4.4.1 step 3: initialize the event — reset all internal flags + target.
    _ = qjs.JS_SetPropertyStr(c, this_val, "_stopped", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(c, this_val, "_stopImmediate", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(c, this_val, "_cancelBubble", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(c, this_val, "defaultPrevented", quickjs.JS_NewBool(false));
    _ = qjs.JS_SetPropertyStr(c, this_val, "target", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, this_val, "currentTarget", quickjs.JS_NULL());
    _ = qjs.JS_SetPropertyStr(c, this_val, "eventPhase", qjs.JS_NewInt32(c, 0));
    // DOM §4.4.1 step 4: type / bubbles / cancelable
    _ = qjs.JS_SetPropertyStr(c, this_val, "type", qjs.JS_DupValue(c, args[0]));
    if (argc >= 2) _ = qjs.JS_SetPropertyStr(c, this_val, "bubbles", qjs.JS_DupValue(c, args[1]));
    if (argc >= 3) _ = qjs.JS_SetPropertyStr(c, this_val, "cancelable", qjs.JS_DupValue(c, args[2]));
    return quickjs.JS_UNDEFINED();
}

/// Per DOM spec, these event types are composed (cross shadow DOM boundary).
fn isComposedEvent(event_type: []const u8) bool {
    // UI Events that are always composed
    const composed_events = [_][]const u8{
        "click",        "dblclick",     "mousedown",        "mouseup",           "mousemove",          "mouseover",   "mouseout",
        "mouseenter",   "mouseleave",   "contextmenu",      "wheel",             "keydown",            "keyup",       "keypress",
        "input",        "beforeinput",  "compositionstart", "compositionupdate", "compositionend",     "focus",       "blur",
        "focusin",      "focusout",     "pointerdown",      "pointerup",         "pointermove",        "pointerover", "pointerout",
        "pointerenter", "pointerleave", "pointercancel",    "gotpointercapture", "lostpointercapture", "touchstart",  "touchmove",
        "touchend",     "touchcancel",  "dragstart",        "drag",              "dragend",            "dragenter",   "dragleave",
        "dragover",     "drop",         "select",           "selectionchange",
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
    _ = qjs.JS_SetPropertyStr(ctx, event, "_trusted", quickjs.JS_NewBool(false));
    {
        // Define isTrusted as a getter reading _trusted (matches Event.prototype behavior)
        const getter_js = "(function(){return this._trusted||false;})";
        const getter = qjs.JS_Eval(ctx, getter_js, getter_js.len, "<isTrusted>", qjs.JS_EVAL_TYPE_GLOBAL);
        const atom = qjs.JS_NewAtom(ctx, "isTrusted");
        // JS_DefinePropertyGetSet consumes getter/setter refs (calls JS_FreeValue internally)
        _ = qjs.JS_DefinePropertyGetSet(ctx, event, atom, getter, quickjs.JS_UNDEFINED(), qjs.JS_PROP_CONFIGURABLE);
        qjs.JS_FreeAtom(ctx, atom);
    }
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
/// Applies Shadow DOM retargeting (DOM §4.4): if the original target is inside
/// a shadow tree, event.target is set to retarget(target, currentTarget) so
/// listeners outside the tree see the host (not the internal node).
fn updateEventObjectForDispatch(ctx: *qjs.JSContext, event: qjs.JSValue, target: ?*lxb.lxb_dom_node_t, current_target: ?*lxb.lxb_dom_node_t, phase: i32) void {
    if (target) |t| {
        const retargeted = shadow_root_mod.retarget(t, current_target);
        _ = qjs.JS_SetPropertyStr(ctx, event, "target", dom_api.wrapNodePublic(ctx, retargeted));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, event, "target", quickjs.JS_NULL());
    }
    if (current_target) |ct| {
        _ = qjs.JS_SetPropertyStr(ctx, event, "currentTarget", dom_api.wrapNodePublic(ctx, ct));
    } else {
        _ = qjs.JS_SetPropertyStr(ctx, event, "currentTarget", quickjs.JS_NULL());
    }
    _ = qjs.JS_SetPropertyStr(ctx, event, "eventPhase", qjs.JS_NewInt32(ctx, phase));

    // Shadow DOM: refresh composedPath _path with closed-tree filtering
    // relative to currentTarget's root. Only does work if a shadow tree is
    // on the current path.
    if (current_target) |ct| {
        refreshComposedPathForCurrentTarget(ctx, event, ct);
    }
}

/// Rebuild the `_path` property on the event to reflect what is visible from
/// a listener at `current_target`. Closed-mode shadow roots' internals are
/// hidden from listeners outside that closed tree.
fn refreshComposedPathForCurrentTarget(
    ctx: *qjs.JSContext,
    event: qjs.JSValue,
    current_target: *lxb.lxb_dom_node_t,
) void {
    const full = qjs.JS_GetPropertyStr(ctx, event, "_full_path");
    defer qjs.JS_FreeValue(ctx, full);
    if (!qjs.JS_IsArray(full)) return;
    const ptrs = qjs.JS_GetPropertyStr(ctx, event, "_full_ptrs");
    defer qjs.JS_FreeValue(ctx, ptrs);

    const len_val = qjs.JS_GetPropertyStr(ctx, full, "length");
    defer qjs.JS_FreeValue(ctx, len_val);
    var len_i: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &len_i, len_val);
    if (len_i <= 0) return;

    const out = qjs.JS_NewArray(ctx);
    var out_i: u32 = 0;
    var i: u32 = 0;
    const ct_root = shadow_root_mod.treeRoot(current_target);
    while (i < @as(u32, @intCast(len_i))) : (i += 1) {
        const item = qjs.JS_GetPropertyUint32(ctx, full, i);
        const ptr_val = qjs.JS_GetPropertyUint32(ctx, ptrs, i);
        var ptr_num: i64 = 0;
        _ = qjs.JS_ToInt64(ctx, &ptr_num, ptr_val);
        qjs.JS_FreeValue(ctx, ptr_val);
        const item_ptr: ?*lxb.lxb_dom_node_t = if (ptr_num == 0) null else @ptrFromInt(@as(usize, @intCast(ptr_num)));
        const visible = visibleFromCurrentTarget(item_ptr, ct_root);
        if (visible) {
            _ = qjs.JS_SetPropertyUint32(ctx, out, out_i, item);
            out_i += 1;
        } else {
            qjs.JS_FreeValue(ctx, item);
        }
    }
    _ = qjs.JS_SetPropertyStr(ctx, event, "_path", out);
}

/// Visibility rule for closed-tree filtering: an item is visible to a
/// listener at `ct_root` if the item's tree root is a shadow-including
/// inclusive ancestor of `ct_root`, OR the item's tree root is inside
/// an open shadow tree. Closed shadow trees hide their internals from
/// nodes outside that tree.
fn visibleFromCurrentTarget(item_opt: ?*lxb.lxb_dom_node_t, ct_root: *lxb.lxb_dom_node_t) bool {
    const item = item_opt orelse return true;
    const item_root = shadow_root_mod.treeRoot(item);
    if (item_root == ct_root) return true;
    // If the listener is inside `item`'s tree (item_root is an ancestor of ct_root), visible.
    if (shadow_root_mod.isShadowIncludingInclusiveAncestor(item_root, ct_root)) return true;
    // If the item is inside the listener's tree or a descendant tree, visibility
    // depends on whether every shadow tree between the item's root and ct_root
    // is open. For Phase 2 simplification, walk from item_root upward via host
    // chain — if any closed shadow root is encountered before reaching ct_root,
    // hide the item.
    var cur: *lxb.lxb_dom_node_t = item_root;
    while (true) {
        if (shadow_root_mod.shadowRootForFragment(cur)) |sr| {
            if (sr.mode == .closed) {
                // Listener must be inside this closed tree to see `item`.
                if (!shadow_root_mod.isShadowIncludingInclusiveAncestor(cur, ct_root)) {
                    return false;
                }
            }
            cur = @ptrCast(sr.host);
            cur = shadow_root_mod.treeRoot(cur);
            if (cur == ct_root) return true;
            continue;
        }
        return true;
    }
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
    var ret: qjs.JSValue = undefined;
    if (qjs.JS_IsFunction(ctx, callback)) {
        ret = qjs.JS_Call(ctx, callback, this_val, 1, &argv);
    } else {
        // Object listener: get handleEvent property and call it with the object as this
        const he = qjs.JS_GetPropertyStr(ctx, callback, "handleEvent");
        if (quickjs.JS_IsException(he)) {
            // Getting handleEvent threw — report the error
            ret = he;
        } else if (qjs.JS_IsFunction(ctx, he)) {
            ret = qjs.JS_Call(ctx, he, callback, 1, &argv);
            qjs.JS_FreeValue(ctx, he);
        } else {
            // handleEvent is not callable — report TypeError per DOM spec
            qjs.JS_FreeValue(ctx, he);
            ret = qjs.JS_ThrowTypeError(ctx, "handleEvent is not a function");
        }
    }
    // If listener threw, report error via ErrorEvent on window (per HTML spec "report the exception")
    if (quickjs.JS_IsException(ret)) {
        const exc = qjs.JS_GetException(ctx);
        const global = qjs.JS_GetGlobalObject(ctx);
        // Report error: call window.onerror (legacy) then dispatch ErrorEvent
        const report_js =
            \\(function(w,err){
            \\  if(w.__isReportingError)return;
            \\  w.__isReportingError=true;
            \\  try{
            \\    var msg=err&&err.message?err.message:String(err);
            \\    if(typeof w.onerror==='function'){try{w.onerror(msg,'',0,0,err);}catch(e){}}
            \\    var ev;try{ev=new ErrorEvent('error',{error:err,message:msg,cancelable:true});}catch(e){ev=new Event('error');ev.error=err;ev.message=msg;}
            \\    w.dispatchEvent(ev);
            \\  }finally{w.__isReportingError=false;}
            \\})
        ;
        const report_fn = qjs.JS_Eval(ctx, report_js, report_js.len, "<report-err>", qjs.JS_EVAL_TYPE_GLOBAL);
        if (!quickjs.JS_IsException(report_fn)) {
            var report_args = [2]qjs.JSValue{ global, exc };
            const report_ret = qjs.JS_Call(ctx, report_fn, quickjs.JS_UNDEFINED(), 2, &report_args);
            qjs.JS_FreeValue(ctx, report_ret);
            qjs.JS_FreeValue(ctx, report_fn);
        }
        qjs.JS_FreeValue(ctx, global);
        qjs.JS_FreeValue(ctx, exc);
    } else {
        qjs.JS_FreeValue(ctx, ret);
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
    if (is_target) {
        // AT_TARGET: fire capturing listeners first, then bubbling listeners (DOM spec 2023+)
        callListenersOnNodeFiltered(ctx, entry, event_obj, node, true);
        callListenersOnNodeFiltered(ctx, entry, event_obj, node, false);
    } else {
        callListenersOnNodeFiltered(ctx, entry, event_obj, node, capture_phase);
    }
}

/// Call listeners on a node, filtered by capture flag.
fn callListenersOnNodeFiltered(ctx: *qjs.JSContext, entry: *ListenerEntry, event_obj: qjs.JSValue, node: *lxb.lxb_dom_node_t, capture_phase: bool) void {
    var i: usize = 0;
    while (i < entry.callbacks.items.len) {
        if (current_event_flags.stop_immediate_propagation) break;
        if (current_event_flags.stop_propagation) break;

        const rec = entry.callbacks.items[i];
        if (rec.capture != capture_phase) {
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
            if (is_target) {
                // AT_TARGET: fire capturing listeners first, then bubbling (DOM spec 2023+)
                callEntryListenersFiltered(ctx, entry, event_obj, this_obj, true);
                callEntryListenersFiltered(ctx, entry, event_obj, this_obj, false);
            } else {
                callEntryListenersFiltered(ctx, entry, event_obj, this_obj, capture_phase);
            }
            break;
        }
    }
}

/// Call listeners from a WindowListenerEntry filtered by capture flag.
fn callEntryListenersFiltered(ctx: *qjs.JSContext, entry: *WindowListenerEntry, event_obj: qjs.JSValue, this_obj: qjs.JSValue, capture_phase: bool) void {
    var i: usize = 0;
    while (i < entry.callbacks.items.len) {
        if (current_event_flags.stop_immediate_propagation) break;
        if (current_event_flags.stop_propagation) break;
        const rec = entry.callbacks.items[i];
        if (rec.capture != capture_phase) {
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

    // Build composed path: path[0] = target, walking up through shadow hosts
    // (via shadow_root.composedParent) so listeners on ancestor hosts can see
    // events originating inside their shadow trees.
    //
    // Truncation for non-composed events: if the event is NOT composed, we
    // stop the path at the boundary of the target's shadow root (i.e., we
    // keep the shadow-root fragment itself but do NOT cross into its host).
    var path: [64]*lxb.lxb_dom_node_t = undefined;
    var path_len: usize = 0;
    var current: ?*lxb.lxb_dom_node_t = target;
    const event_is_composed = blk: {
        if (existing_event) |ev| {
            const cv = qjs.JS_GetPropertyStr(ctx, ev, "composed");
            defer qjs.JS_FreeValue(ctx, cv);
            if (qjs.JS_ToBool(ctx, cv) > 0) break :blk true;
            if (!quickjs.JS_IsUndefined(cv)) break :blk false;
        }
        break :blk isComposedEvent(event_type);
    };
    const target_scope = shadow_root_mod.nodeScope(target);
    while (current) |node| {
        if (path_len < path.len) {
            path[path_len] = node;
            path_len += 1;
        }
        // For non-composed events, when we are about to step from a shadow
        // fragment to its host, stop.
        if (!event_is_composed) {
            if (shadow_root_mod.shadowRootForFragment(node)) |sr| {
                // Only stop when this shadow boundary would take us out of
                // the target's own shadow scope.
                _ = sr;
                if (shadow_root_mod.nodeScope(node) == target_scope or target_scope == 0) {
                    break;
                }
            }
        }
        current = shadow_root_mod.composedParent(node);
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
        // DOM spec: script-dispatched events are not trusted
        _ = qjs.JS_SetPropertyStr(ctx, ev, "_trusted", quickjs.JS_NewBool(false));
        break :blk ev;
    } else blk: {
        owns_event = true;
        const eo = createEventObject(ctx, event_type, target, target);
        _ = qjs.JS_SetPropertyStr(ctx, eo, "_trusted", quickjs.JS_NewBool(true));
        break :blk eo;
    };
    defer {
        if (owns_event) qjs.JS_FreeValue(ctx, event_obj);
    }

    // DOM spec: set composedPath (_path) on event object.
    // Also stash a "_full_path" (with pointers in "_full_ptrs") so
    // per-listener-step closed-tree filtering can refer back to it.
    {
        const path_arr = qjs.JS_NewArray(ctx);
        const full_arr = qjs.JS_NewArray(ctx);
        const ptrs_arr = qjs.JS_NewArray(ctx);
        for (0..path_len) |pi| {
            const wrapped = dom_api.wrapNodePublic(ctx, path[pi]);
            _ = qjs.JS_SetPropertyUint32(ctx, path_arr, @intCast(pi), qjs.JS_DupValue(ctx, wrapped));
            _ = qjs.JS_SetPropertyUint32(ctx, full_arr, @intCast(pi), wrapped);
            _ = qjs.JS_SetPropertyUint32(ctx, ptrs_arr, @intCast(pi), qjs.JS_NewInt64(ctx, @intCast(@intFromPtr(path[pi]))));
        }
        // Add window as the last element in the path (for connected nodes)
        if (path_len > 0 and path[path_len - 1].type == lxb.LXB_DOM_NODE_TYPE_DOCUMENT) {
            const global = qjs.JS_GetGlobalObject(ctx);
            _ = qjs.JS_SetPropertyUint32(ctx, path_arr, @intCast(path_len), qjs.JS_DupValue(ctx, global));
            _ = qjs.JS_SetPropertyUint32(ctx, full_arr, @intCast(path_len), qjs.JS_DupValue(ctx, global));
            _ = qjs.JS_SetPropertyUint32(ctx, ptrs_arr, @intCast(path_len), qjs.JS_NewInt64(ctx, 0));
            qjs.JS_FreeValue(ctx, global);
        }
        _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_path", path_arr);
        _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_full_path", full_arr);
        _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_full_ptrs", ptrs_arr);
    }

    // DOM spec: set dispatch flag — initEvent must short-circuit while dispatching
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(true));

    // DOM spec: set target and srcElement at start of dispatch
    const target_js = dom_api.wrapNodePublic(ctx, target);
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "target", qjs.JS_DupValue(ctx, target_js));
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "srcElement", target_js);

    // Get global and document objects for Window/Document phase dispatch
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // Set window.event (legacy, but widely used — e.g. "event.stopPropagation()" without parameter)
    const saved_event = qjs.JS_GetPropertyStr(ctx, global, "event");
    _ = qjs.JS_SetPropertyStr(ctx, global, "event", qjs.JS_DupValue(ctx, event_obj));
    defer {
        _ = qjs.JS_SetPropertyStr(ctx, global, "event", saved_event);
    }
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    // Check for JS-only Document parent (new Document(), createHTMLDocument())
    // If the root of the lxb path has a JS parentNode that's a Document (nodeType=9),
    // we need to include it in capture/bubble dispatch.
    var js_doc_parent: qjs.JSValue = quickjs.JS_UNDEFINED();
    var has_js_doc: bool = false;
    if (path_len > 0) {
        const root_js = dom_api.wrapNodePublic(ctx, path[path_len - 1]);
        const pn = qjs.JS_GetPropertyStr(ctx, root_js, "parentNode");
        qjs.JS_FreeValue(ctx, root_js);
        if (!quickjs.JS_IsNull(pn) and !quickjs.JS_IsUndefined(pn)) {
            const pn_nt = qjs.JS_GetPropertyStr(ctx, pn, "nodeType");
            var pn_nt_v: i32 = 0;
            _ = qjs.JS_ToInt32(ctx, &pn_nt_v, pn_nt);
            qjs.JS_FreeValue(ctx, pn_nt);
            if (pn_nt_v == 9) {
                // Check it's NOT the main document (already handled separately)
                if (!(pn.tag == doc_obj.tag and pn.u.ptr == doc_obj.u.ptr)) {
                    js_doc_parent = pn;
                    has_js_doc = true;
                } else {
                    qjs.JS_FreeValue(ctx, pn);
                }
            } else {
                qjs.JS_FreeValue(ctx, pn);
            }
        } else {
            qjs.JS_FreeValue(ctx, pn);
        }
    }
    defer if (has_js_doc) qjs.JS_FreeValue(ctx, js_doc_parent);

    // Add JS-only Document to composedPath (_path)
    if (has_js_doc) {
        const path_arr = qjs.JS_GetPropertyStr(ctx, event_obj, "_path");
        if (path_arr.tag == qjs.JS_TAG_OBJECT) {
            // Append document at the end of the path
            _ = qjs.JS_SetPropertyUint32(ctx, path_arr, @intCast(path_len), qjs.JS_DupValue(ctx, js_doc_parent));
        }
        qjs.JS_FreeValue(ctx, path_arr);
    }

    // --- Click activation behavior: pre-activation step (DOM spec §3.7) ---
    // For click events with MouseEvent or element.click(), find the first element
    // with activation behavior in the path and pre-activate (toggle checkbox/radio).
    var activation_target: ?*lxb.lxb_dom_node_t = null;
    var pre_activation_checked: bool = false;
    var has_pre_activation: bool = false;

    if (std.mem.eql(u8, event_type, "click")) {
        const is_activating = if (existing_event) |ev| blk: {
            // External dispatch: only MouseEvent (has 'button' property) triggers activation
            const has_button = qjs.JS_GetPropertyStr(ctx, ev, "button");
            const is_mouse = has_button.tag != qjs.JS_TAG_UNDEFINED;
            qjs.JS_FreeValue(ctx, has_button);
            break :blk is_mouse;
        } else true; // Internal dispatch (element.click()) always triggers

        if (is_activating) {
            // For non-bubbling events, only the target itself can be the activation target.
            // For bubbling events (or internal click()), search the full path.
            const search_len = if (existing_event) |ev| blk: {
                const bub = qjs.JS_GetPropertyStr(ctx, ev, "bubbles");
                defer qjs.JS_FreeValue(ctx, bub);
                break :blk if (qjs.JS_ToBool(ctx, bub) > 0) path_len else @min(path_len, 1);
            } else path_len;

            // Find first element with activation behavior in path (target → root)
            // Per DOM spec: element.click() skips disabled elements, but
            // dispatchEvent(new MouseEvent("click")) still activates them.
            const is_internal_click = existing_event == null;
            for (path[0..search_len]) |node| {
                if (isCheckboxOrRadio(ctx, node) and (!is_internal_click or !isDisabledFormElement(ctx, node))) {
                    activation_target = node;
                    // Legacy pre-activation: save state and set new state
                    const at_js = dom_api.wrapNodePublic(ctx, node);
                    defer qjs.JS_FreeValue(ctx, at_js);
                    const cv = qjs.JS_GetPropertyStr(ctx, at_js, "checked");
                    pre_activation_checked = qjs.JS_ToBool(ctx, cv) > 0;
                    qjs.JS_FreeValue(ctx, cv);
                    // Radio: always set checked=true (never uncheck)
                    // Checkbox: toggle checked state
                    const type_val = qjs.JS_GetPropertyStr(ctx, at_js, "type");
                    defer qjs.JS_FreeValue(ctx, type_val);
                    const is_radio = blk: {
                        const ts = dom_api.jsStringToSlice(ctx, type_val) orelse break :blk false;
                        defer qjs.JS_FreeCString(ctx, ts.ptr);
                        break :blk std.ascii.eqlIgnoreCase(ts.ptr[0..ts.len], "radio");
                    };
                    const new_checked = if (is_radio) true else !pre_activation_checked;
                    // Only set pre-activation if checked state actually changes
                    // (already-checked radio should not fire spurious input/change)
                    if (new_checked != pre_activation_checked) {
                        _ = qjs.JS_SetPropertyStr(ctx, at_js, "checked", quickjs.JS_NewBool(new_checked));
                        has_pre_activation = true;
                    }
                    break;
                } else if (isSubmitButton(ctx, node) and !isDisabledFormElement(ctx, node)) {
                    // Submit button activation: will submit parent form in post-activation
                    activation_target = node;
                    break;
                }
            }
        }
    }

    // Phase 1: Capture (Window → Document → root → ... → parent of target)
    if (has_js_doc) {
        // JS-only Document (new Document, createHTMLDocument): capture on that doc
        if (!current_event_flags.stop_propagation) {
            updateEventPhase(ctx, event_obj, 1); // CAPTURING_PHASE
            setEventCurrentTarget(ctx, event_obj, js_doc_parent);
            dispatchToJsDocPhased(ctx, js_doc_parent, event_obj, event_type, true);
        }
    } else {
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
        // Call on{event} handler property on target element (same target — only stopImmediate blocks)
        if (!current_event_flags.stop_immediate_propagation) {
            const target_js2 = dom_api.wrapNodePublic(ctx, target);
            callOnEventHandler(ctx, target_js2, event_type, event_obj);
            qjs.JS_FreeValue(ctx, target_js2);
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
                // Call on{event} handler on bubble node (same target — only stopImmediate blocks)
                if (!current_event_flags.stop_immediate_propagation) {
                    const node_js = dom_api.wrapNodePublic(ctx, node);
                    callOnEventHandler(ctx, node_js, event_type, event_obj);
                    qjs.JS_FreeValue(ctx, node_js);
                }
            }
        }
        if (has_js_doc) {
            // 3b-alt: JS-only Document bubble listeners
            if (!current_event_flags.stop_propagation) {
                updateEventPhase(ctx, event_obj, 3); // BUBBLING_PHASE
                setEventCurrentTarget(ctx, event_obj, js_doc_parent);
                dispatchToJsDocPhased(ctx, js_doc_parent, event_obj, event_type, false);
                if (!current_event_flags.stop_immediate_propagation)
                    callOnEventHandler(ctx, js_doc_parent, event_type, event_obj);
            }
        } else {
            // 3b: Document bubble listeners + on{event} handler
            if (!current_event_flags.stop_propagation) {
                updateEventPhase(ctx, event_obj, 3); // BUBBLING_PHASE
                setEventCurrentTarget(ctx, event_obj, doc_obj);
                callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, false, false);
                if (!current_event_flags.stop_immediate_propagation)
                    callOnEventHandler(ctx, doc_obj, event_type, event_obj);
            }
            // 3c: Window bubble listeners + on{event} handler
            if (!current_event_flags.stop_propagation) {
                setEventCurrentTarget(ctx, event_obj, global);
                callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, false, false);
                if (!current_event_flags.stop_immediate_propagation)
                    callOnEventHandler(ctx, global, event_type, event_obj);
            }
        }
    }

    var ev_result = !current_event_flags.prevent_default;
    // Also check JS-side defaultPrevented (may have been set before dispatch started)
    if (ev_result) {
        const dp_check = qjs.JS_GetPropertyStr(ctx, event_obj, "defaultPrevented");
        defer qjs.JS_FreeValue(ctx, dp_check);
        if (qjs.JS_ToBool(ctx, dp_check) > 0) ev_result = false;
    }

    // DOM spec: clear dispatch flag and reset event state BEFORE post-activation
    // (tests expect eventPhase=0, currentTarget=null during post-activation handlers)
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(false));
    if (existing_event) |ev| {
        _ = qjs.JS_SetPropertyStr(ctx, ev, "_stopped", quickjs.JS_NewBool(false));
        _ = qjs.JS_SetPropertyStr(ctx, ev, "_cancelBubble", quickjs.JS_NewBool(false));
    }
    updateEventPhase(ctx, event_obj, 0); // NONE
    setEventCurrentTarget(ctx, event_obj, quickjs.JS_NULL());

    current_event_flags = saved_flags;

    // --- Click activation behavior: post-activation step ---
    if (has_pre_activation) {
        if (activation_target) |at| {
            if (!ev_result) {
                // Legacy-canceled-activation: revert checked state
                const at_js = dom_api.wrapNodePublic(ctx, at);
                _ = qjs.JS_SetPropertyStr(ctx, at_js, "checked", quickjs.JS_NewBool(pre_activation_checked));
                qjs.JS_FreeValue(ctx, at_js);
            } else {
                // Post-activation: fire input/change events only if connected
                // Per HTML spec, detached elements should not fire input/change
                const at_js2 = dom_api.wrapNodePublic(ctx, at);
                const conn_val = qjs.JS_GetPropertyStr(ctx, at_js2, "isConnected");
                const is_connected = qjs.JS_ToBool(ctx, conn_val) > 0;
                qjs.JS_FreeValue(ctx, conn_val);
                qjs.JS_FreeValue(ctx, at_js2);
                if (is_connected) {
                    _ = dispatchEvent(ctx, at, "input");
                    _ = dispatchEvent(ctx, at, "change");
                }
            }
        }
    } else if (activation_target != null and ev_result) {
        // Non-checkbox/radio activation: submit button → form submit
        if (activation_target) |at| {
            if (isSubmitButton(ctx, at) and !isDisabledFormElement(ctx, at)) {
                if (findParentForm(at)) |form_node| {
                    // Only submit if form is connected (in a document)
                    const form_js = dom_api.wrapNodePublic(ctx, form_node);
                    defer qjs.JS_FreeValue(ctx, form_js);
                    const conn = qjs.JS_GetPropertyStr(ctx, form_js, "isConnected");
                    const form_connected = qjs.JS_ToBool(ctx, conn) > 0;
                    qjs.JS_FreeValue(ctx, conn);
                    if (form_connected) {
                        // Dispatch 'submit' event on the form (cancelable)
                        const submit_ev_code =
                            \\(function(form, submitter){
                            \\  var ev;
                            \\  try { ev = new SubmitEvent('submit', {bubbles:true, cancelable:true, submitter:submitter}); }
                            \\  catch(e) { ev = new Event('submit', {bubbles:true, cancelable:true}); ev.submitter = submitter; }
                            \\  return form.dispatchEvent(ev);
                            \\})
                        ;
                        const fn_val = qjs.JS_Eval(ctx, submit_ev_code, submit_ev_code.len, "<submit>", qjs.JS_EVAL_TYPE_GLOBAL);
                        if (fn_val.tag != qjs.JS_TAG_EXCEPTION) {
                            const at_js3 = dom_api.wrapNodePublic(ctx, at);
                            var args = [_]qjs.JSValue{ form_js, at_js3 };
                            const result = qjs.JS_Call(ctx, fn_val, quickjs.JS_UNDEFINED(), 2, &args);
                            qjs.JS_FreeValue(ctx, result);
                            qjs.JS_FreeValue(ctx, at_js3);
                        }
                        qjs.JS_FreeValue(ctx, fn_val);
                    }
                }
            }
        }
    }

    return ev_result;
}

/// Cached JS function for dispatching to JS-level event listeners.
var cached_js_doc_dispatch: qjs.JSValue = quickjs.JS_UNDEFINED();

/// Dispatch to JS-level event listeners (__el_ properties) on a JS object,
/// filtered by capture/bubble phase. Used for JS-only Document nodes.
fn dispatchToJsDocPhased(ctx: *qjs.JSContext, doc_obj: qjs.JSValue, event_obj: qjs.JSValue, event_type: []const u8, capture: bool) void {
    // Lazily compile and cache the dispatch helper
    if (quickjs.JS_IsUndefined(cached_js_doc_dispatch)) {
        const js_code =
            \\(function(doc,evt,type,isCap){
            \\  var k='__el_'+type+(isCap?'\x00c':'');
            \\  var a=doc[k];if(!a||!a.length)return;
            \\  var copy=a.slice();
            \\  for(var i=0;i<copy.length;i++){
            \\    if(evt._stopImmediate)break;if(evt._stopped)break;
            \\    var h=copy[i],fn=h.fn||h;
            \\    if(h.once){var idx=a.indexOf(h);if(idx>=0)a.splice(idx,1);}
            \\    if(typeof fn==='function')fn.call(doc,evt);
            \\    else if(fn&&typeof fn.handleEvent==='function')fn.handleEvent(evt);
            \\  }
            \\})
        ;
        cached_js_doc_dispatch = qjs.JS_Eval(ctx, js_code, js_code.len, "<jsdp>", qjs.JS_EVAL_TYPE_GLOBAL);
    }
    if (!quickjs.JS_IsException(cached_js_doc_dispatch)) {
        const type_js = qjs.JS_NewStringLen(ctx, event_type.ptr, event_type.len);
        var args = [4]qjs.JSValue{ doc_obj, event_obj, type_js, quickjs.JS_NewBool(capture) };
        const r = qjs.JS_Call(ctx, cached_js_doc_dispatch, quickjs.JS_UNDEFINED(), 4, &args);
        qjs.JS_FreeValue(ctx, r);
        qjs.JS_FreeValue(ctx, type_js);
    }
    syncStopFlags(ctx, event_obj);
}

/// Check if a DOM node is an <input type="checkbox"> or <input type="radio">.
fn isCheckboxOrRadio(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    var name_len: usize = 0;
    const name_ptr = dom_api.lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name_ptr == null or name_len != 5) return false;
    if (!std.mem.eql(u8, name_ptr.?[0..5], "input")) return false;
    const js = dom_api.wrapNodePublic(ctx, node);
    defer qjs.JS_FreeValue(ctx, js);
    const type_val = qjs.JS_GetPropertyStr(ctx, js, "type");
    defer qjs.JS_FreeValue(ctx, type_val);
    const ts = dom_api.jsStringToSlice(ctx, type_val) orelse return false;
    defer qjs.JS_FreeCString(ctx, ts.ptr);
    const t = ts.ptr[0..ts.len];
    return std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio");
}

/// Check if a DOM node is a submit button (<button type="submit"> or <input type="submit">).
fn isSubmitButton(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    var name_len: usize = 0;
    const name_ptr = dom_api.lxb_dom_element_local_name(@ptrCast(node), &name_len);
    if (name_ptr == null) return false;
    const name = name_ptr.?[0..name_len];
    if (std.mem.eql(u8, name, "button")) {
        // <button> defaults to type="submit" if no type specified
        const js = dom_api.wrapNodePublic(ctx, node);
        defer qjs.JS_FreeValue(ctx, js);
        const type_val = qjs.JS_GetPropertyStr(ctx, js, "type");
        defer qjs.JS_FreeValue(ctx, type_val);
        const ts = dom_api.jsStringToSlice(ctx, type_val) orelse return true; // default is submit
        defer qjs.JS_FreeCString(ctx, ts.ptr);
        const t = ts.ptr[0..ts.len];
        return std.ascii.eqlIgnoreCase(t, "submit");
    }
    if (std.mem.eql(u8, name, "input")) {
        const js = dom_api.wrapNodePublic(ctx, node);
        defer qjs.JS_FreeValue(ctx, js);
        const type_val = qjs.JS_GetPropertyStr(ctx, js, "type");
        defer qjs.JS_FreeValue(ctx, type_val);
        const ts = dom_api.jsStringToSlice(ctx, type_val) orelse return false;
        defer qjs.JS_FreeCString(ctx, ts.ptr);
        const t = ts.ptr[0..ts.len];
        return std.ascii.eqlIgnoreCase(t, "submit");
    }
    return false;
}

/// Find the closest <form> ancestor of a node.
fn findParentForm(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = node.parent;
    while (current) |cur| {
        if (cur.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            var flen: usize = 0;
            const fptr = dom_api.lxb_dom_element_local_name(@ptrCast(cur), &flen);
            if (fptr != null and flen == 4 and std.mem.eql(u8, fptr.?[0..4], "form")) {
                return cur;
            }
        }
        current = cur.parent;
    }
    return null;
}

/// Check if a DOM node is a disabled form element (has disabled=true).
fn isDisabledFormElement(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const js = dom_api.wrapNodePublic(ctx, node);
    defer qjs.JS_FreeValue(ctx, js);
    const disabled = qjs.JS_GetPropertyStr(ctx, js, "disabled");
    defer qjs.JS_FreeValue(ctx, disabled);
    return qjs.JS_ToBool(ctx, disabled) > 0;
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
            _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_trusted", quickjs.JS_NewBool(true));
            _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(true));
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
            _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(false));
            break;
        }
    }
}

/// Dispatch on document listeners (DOMContentLoaded, etc.)
pub fn dispatchDocumentEvent(ctx: *qjs.JSContext, event_type: []const u8) void {
    // Fire document listeners first, then window listeners (bubbling order)
    const event_obj = createEventObject(ctx, event_type, null, null);
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_trusted", quickjs.JS_NewBool(true));
    defer qjs.JS_FreeValue(ctx, event_obj);
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    // Set target/currentTarget to document
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "target", qjs.JS_DupValue(ctx, doc_obj));
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "currentTarget", qjs.JS_DupValue(ctx, doc_obj));
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "eventPhase", qjs.JS_NewInt32(ctx, 2)); // AT_TARGET
    // DOM spec: set dispatch flag — dispatchEvent must throw InvalidStateError while dispatching
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(true));

    // Fire listeners stored on the lxb document node (via document.addEventListener)
    // AT_TARGET: dispatch capture listeners first, then bubble (DOM spec ordering)
    if (dom_api.getDocument(ctx)) |doc_ptr| {
        const doc_node: *lxb.lxb_dom_node_t = @ptrCast(@alignCast(doc_ptr));
        for (listener_entries.items) |*entry| {
            if (entry.key.node == doc_node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                // Two-pass: capture first, then bubble (AT_TARGET ordering)
                for ([2]bool{ true, false }) |capture_phase| {
                    var i: usize = 0;
                    while (i < entry.callbacks.items.len) {
                        if (current_event_flags.stop_immediate_propagation) break;
                        const rec = entry.callbacks.items[i];
                        if (rec.capture != capture_phase) {
                            i += 1;
                            continue;
                        }
                        const cb = qjs.JS_DupValue(ctx, rec.callback);
                        if (rec.once) {
                            qjs.JS_FreeValue(ctx, entry.callbacks.items[i].callback);
                            _ = entry.callbacks.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                        invokeListener(ctx, cb, doc_obj, event_obj);
                        qjs.JS_FreeValue(ctx, cb);
                        syncStopFlags(ctx, event_obj);
                    }
                }
                break;
            }
        }
    }
    // Also fire from document_listener_entries (legacy path)
    callEntryListeners(ctx, &document_listener_entries, event_type, event_obj, doc_obj, true, false);
    // Call on{event} handler on document
    callOnEventHandler(ctx, doc_obj, event_type, event_obj);
    // Bubble to window (phase 3)
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "eventPhase", qjs.JS_NewInt32(ctx, 3)); // BUBBLING_PHASE
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "currentTarget", qjs.JS_DupValue(ctx, global));
    callEntryListeners(ctx, &window_listener_entries, event_type, event_obj, global, false, false);
    callOnEventHandler(ctx, global, event_type, event_obj);
    // DOM spec: clear dispatch flag after dispatch completes
    _ = qjs.JS_SetPropertyStr(ctx, event_obj, "_dispatching", quickjs.JS_NewBool(false));
}

// ── Registration ────────────────────────────────────────────────────

pub fn registerEventApis(ctx: *qjs.JSContext) void {
    g_ctx = ctx;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // window.event: must be own property, initially undefined (DOM spec)
    _ = qjs.JS_SetPropertyStr(ctx, global, "event", quickjs.JS_UNDEFINED());

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
        \\    if(!(this instanceof Event))throw new TypeError("Failed to construct 'Event': Please use the 'new' operator.");
        \\    if(arguments.length<1)throw new TypeError("Failed to construct 'Event': 1 argument required.");
        \\    if (typeof type !== 'string' && typeof type !== 'undefined') type = String(type);
        \\    this.type = type || '';
        \\    var o = opts || {};
        \\    this.bubbles = !!o.bubbles;
        \\    this.cancelable = !!o.cancelable;
        \\    this.composed = !!o.composed;
        \\    this.defaultPrevented = false;
        \\    this._stopped = false;
        \\    this._stopImmediate = false;
        \\    this._trusted=false;Object.defineProperty(this,'isTrusted',{get:Event._isTrustedGetter,configurable:false});
        \\    this.eventPhase = 0;
        \\    this._cancelBubble = false;
        \\    this.timeStamp = (typeof performance!=='undefined'&&performance.now)?performance.now():Date.now();
        \\    this.target = null;
        \\    this.currentTarget = null;
        \\    this.srcElement = null;
        \\    this._initialized = true;
        \\  }
        \\  Event._isTrustedGetter=function(){return this._trusted||false;};
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
        \\  Event.prototype.composedPath = function() { return (this._dispatching && this._path) ? this._path.slice() : []; };
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
        \\  CustomEvent.prototype.initCustomEvent = function(t, b, c, d) { if(arguments.length<1)throw new TypeError("Failed to execute 'initCustomEvent': 1 argument required.");if(this._dispatching)return;this.initEvent(t, b, c); this.detail = d!==undefined?d:null; };
        \\  return CustomEvent;
        \\})()
    ;
    const custom_event_ctor = qjs.JS_Eval(ctx, custom_event_js, custom_event_js.len, "<CustomEvent>", qjs.JS_EVAL_TYPE_GLOBAL);
    _ = qjs.JS_SetPropertyStr(ctx, global, "CustomEvent", custom_event_ctor);

    // UIEvent extends Event
    {
        const js =
            \\(function(){
            \\  function UIEvent(t,o){Event.call(this,t,o);o=o||{};if(o.view!==undefined&&o.view!==null&&typeof o.view!=='object')throw new TypeError("Failed to construct 'UIEvent': member view is not of type Window.");this.view=o.view||null;this.detail=o.detail||0;}
            \\  UIEvent.prototype=Object.create(Event.prototype);UIEvent.prototype.constructor=UIEvent;
            \\  UIEvent.prototype.initUIEvent=function(t,b,c,v,d){if(this._dispatching)return;this.initEvent(t,b,c);this.view=v;this.detail=d;};
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
            \\    if(this._dispatching)return;this.initUIEvent(t,b,c,v,d);this.screenX=sx;this.screenY=sy;this.clientX=cx;this.clientY=cy;
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
            \\    this.keyCode=o.keyCode||0;this.charCode=o.charCode||0;
            \\    this.which=o.which||o.keyCode||0;
            \\    this.ctrlKey=!!o.ctrlKey;this.shiftKey=!!o.shiftKey;
            \\    this.altKey=!!o.altKey;this.metaKey=!!o.metaKey;
            \\    this.repeat=!!o.repeat;this.location=o.location||0;
            \\    this.isComposing=!!o.isComposing;
            \\  }
            \\  KeyboardEvent.prototype=Object.create(UIEvent.prototype);KeyboardEvent.prototype.constructor=KeyboardEvent;
            \\  KeyboardEvent.prototype.initKeyboardEvent=function(t,b,c,v,k,loc,ctrl,alt,shift,meta){
            \\    if(this._dispatching)return;this.initUIEvent(t,b,c,v,0);
            \\    this.key=k||'';this.location=loc||0;
            \\    this.ctrlKey=!!ctrl;this.altKey=!!alt;this.shiftKey=!!shift;this.metaKey=!!meta;
            \\  };
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
            \\  function TextEvent(t,o){UIEvent.call(this,t,o);this.data=(o&&o.data)||'';}
            \\  TextEvent.prototype=Object.create(UIEvent.prototype);TextEvent.prototype.constructor=TextEvent;
            \\  globalThis.TextEvent=TextEvent;
            \\  function MessageEvent(t,o){Event.call(this,t,o);o=o||{};this.data=o.data!==undefined?o.data:null;this.origin=o.origin||'';this.lastEventId=o.lastEventId||'';this.source=o.source||null;this.ports=o.ports||[];}
            \\  MessageEvent.prototype=Object.create(Event.prototype);MessageEvent.prototype.constructor=MessageEvent;
            \\  MessageEvent.prototype.initMessageEvent=function(t,b,c,d,o,l,s,p){if(this._dispatching)return;this.initEvent(t,b,c);this.data=d;this.origin=o;this.lastEventId=l;this.source=s;this.ports=p||[];};
            \\  globalThis.MessageEvent=MessageEvent;
            \\  function CloseEvent(t,o){Event.call(this,t,o);o=o||{};this.wasClean=!!o.wasClean;this.code=o.code||0;this.reason=o.reason||'';}
            \\  CloseEvent.prototype=Object.create(Event.prototype);CloseEvent.prototype.constructor=CloseEvent;
            \\  globalThis.CloseEvent=CloseEvent;
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
            \\  function DeviceMotionEvent(t,o){Event.call(this,t,o);}
            \\  DeviceMotionEvent.prototype=Object.create(Event.prototype);DeviceMotionEvent.prototype.constructor=DeviceMotionEvent;
            \\  globalThis.DeviceMotionEvent=DeviceMotionEvent;
            \\  function DeviceOrientationEvent(t,o){Event.call(this,t,o);}
            \\  DeviceOrientationEvent.prototype=Object.create(Event.prototype);DeviceOrientationEvent.prototype.constructor=DeviceOrientationEvent;
            \\  globalThis.DeviceOrientationEvent=DeviceOrientationEvent;
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
    // DOM spec: InvalidStateError if event's dispatch flag is set
    const dispatch_flag_doc = qjs.JS_GetPropertyStr(c, event_obj, "_dispatching");
    defer qjs.JS_FreeValue(c, dispatch_flag_doc);
    if (qjs.JS_ToBool(c, dispatch_flag_doc) > 0) {
        return dom_api.throwDOMException(c, "InvalidStateError", "The event is already being dispatched.");
    }
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
    // Call document_listener_entries (global doc listeners)
    callEntryListeners(c, &document_listener_entries, event_type, event_obj, doc_obj, true, false);
    // Also call node-based listeners on the document lexbor node
    if (!current_event_flags.stop_propagation) {
        if (dom_api.getNodePublic(c, doc_obj)) |doc_node| {
            for (listener_entries.items) |*entry| {
                if (entry.key.node == doc_node and std.mem.eql(u8, entry.key.event_type, event_type)) {
                    callListenersOnNode(c, entry, event_obj, doc_node, true, false);
                    break;
                }
            }
        }
    }

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
/// HTML spec: click() does nothing on disabled form elements.
/// Activation behavior (checkbox/radio toggle + input/change) handled in dispatchEventWithObj.
fn jsElementClick(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, this_val) orelse return quickjs.JS_UNDEFINED();
    // HTML spec: click() is a no-op on disabled form elements
    if (isDisabledFormElement(c, node)) return quickjs.JS_UNDEFINED();
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

    const node = dom_api.getNodePublic(c, this_val) orelse {
        // Check if this is the window/global object — dispatch from native storage
        const is_window = blk: {
            const gl = qjs.JS_GetGlobalObject(c);
            defer qjs.JS_FreeValue(c, gl);
            break :blk (this_val.tag == gl.tag and this_val.u.ptr == gl.u.ptr);
        };

        const type_val2 = qjs.JS_GetPropertyStr(c, args[0], "type");
        defer qjs.JS_FreeValue(c, type_val2);
        const ts2 = dom_api.jsStringToSlice(c, type_val2) orelse return quickjs.JS_NewBool(true);
        defer qjs.JS_FreeCString(c, ts2.ptr);
        _ = qjs.JS_SetPropertyStr(c, args[0], "_dispatching", quickjs.JS_NewBool(true));
        _ = qjs.JS_SetPropertyStr(c, args[0], "target", qjs.JS_DupValue(c, this_val));
        _ = qjs.JS_SetPropertyStr(c, args[0], "currentTarget", qjs.JS_DupValue(c, this_val));
        _ = qjs.JS_SetPropertyStr(c, args[0], "eventPhase", qjs.JS_NewInt32(c, 2)); // AT_TARGET

        if (is_window) {
            // Dispatch using native window listener entries
            dispatchToNativeEntries(c, &window_listener_entries, ts2.ptr[0..ts2.len], args[0], this_val);
        } else {
            // JS-level node (PI, DocumentType, etc.): dispatch from __el_ storage
            dispatchToJsEntries(c, this_val, args[0], type_val2);
        }

        _ = qjs.JS_SetPropertyStr(c, args[0], "_dispatching", quickjs.JS_NewBool(false));
        _ = qjs.JS_SetPropertyStr(c, args[0], "eventPhase", qjs.JS_NewInt32(c, 0));
        _ = qjs.JS_SetPropertyStr(c, args[0], "currentTarget", quickjs.JS_NULL());
        // Return !defaultPrevented per spec
        const dp = qjs.JS_GetPropertyStr(c, args[0], "defaultPrevented");
        defer qjs.JS_FreeValue(c, dp);
        return quickjs.JS_NewBool(!(qjs.JS_ToBool(c, dp) > 0));
    };

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
pub const jsElementDispatchEventPub = jsElementDispatchEvent;

/// Dispatch event to native listener entries (window or document).
fn dispatchToNativeEntries(c: *qjs.JSContext, entries: *std.ArrayListUnmanaged(WindowListenerEntry), event_type: []const u8, event_obj: qjs.JSValue, target: qjs.JSValue) void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.event_type, event_type)) continue;
        var i: usize = 0;
        while (i < entry.callbacks.items.len) {
            const rec = entry.callbacks.items[i];
            if (rec.once) {
                qjs.JS_FreeValue(c, rec.callback);
                _ = entry.callbacks.orderedRemove(i);
            } else {
                i += 1;
            }
            // Save/restore defaultPrevented for passive listeners
            const saved_dp = qjs.JS_GetPropertyStr(c, event_obj, "defaultPrevented");
            if (qjs.JS_IsFunction(c, rec.callback)) {
                var call_args = [1]qjs.JSValue{event_obj};
                const r = qjs.JS_Call(c, rec.callback, target, 1, &call_args);
                qjs.JS_FreeValue(c, r);
            } else {
                // handleEvent pattern
                const he = qjs.JS_GetPropertyStr(c, rec.callback, "handleEvent");
                if (qjs.JS_IsFunction(c, he)) {
                    var call_args = [1]qjs.JSValue{event_obj};
                    const r = qjs.JS_Call(c, he, rec.callback, 1, &call_args);
                    qjs.JS_FreeValue(c, r);
                }
                qjs.JS_FreeValue(c, he);
            }
            if (rec.passive) {
                _ = qjs.JS_SetPropertyStr(c, event_obj, "defaultPrevented", saved_dp);
            } else {
                qjs.JS_FreeValue(c, saved_dp);
            }
        }
    }
}

/// Dispatch event to JS-level __el_ storage on target object.
fn dispatchToJsEntries(c: *qjs.JSContext, target: qjs.JSValue, event_obj: qjs.JSValue, type_val: qjs.JSValue) void {
    const js_dispatch =
        \\(function(el,evt,type){
        \\  function _run(k){var a=el[k];if(!a||!a.length)return;
        \\    var copy=a.slice();
        \\    for(var i=0;i<copy.length;i++){
        \\      if(evt._stopImmediate)break;if(evt._stopped)break;
        \\      var h=copy[i];
        \\      if(a.indexOf(h)<0)continue;
        \\      var fn=h.fn||h;
        \\      if(h.once){var idx=a.indexOf(h);if(idx>=0)a.splice(idx,1);}
        \\      var wasPD=evt.defaultPrevented,origRV=evt.returnValue;
        \\      if(h.passive){evt.preventDefault=function(){};var _rvDesc=Object.getOwnPropertyDescriptor(evt,'returnValue');Object.defineProperty(evt,'returnValue',{set:function(){},get:function(){return origRV;},configurable:true});}
        \\      else evt.preventDefault=origPD;
        \\      if(typeof fn==='function')fn.call(el,evt);
        \\      else if(fn&&typeof fn.handleEvent==='function')fn.handleEvent(evt);
        \\      if(h.passive){evt.defaultPrevented=wasPD;if(_rvDesc)Object.defineProperty(evt,'returnValue',_rvDesc);else evt.returnValue=origRV;}
        \\    }
        \\  }
        \\  var origPD=evt.preventDefault;
        \\  _run('__el_'+type+'\x00c');
        \\  _run('__el_'+type);
        \\  evt.preventDefault=origPD;
        \\})
    ;
    const fn_val = qjs.JS_Eval(c, js_dispatch, js_dispatch.len, "<jsd>", qjs.JS_EVAL_TYPE_GLOBAL);
    if (!quickjs.JS_IsException(fn_val)) {
        var d_args = [3]qjs.JSValue{ target, event_obj, type_val };
        const r = qjs.JS_Call(c, fn_val, quickjs.JS_UNDEFINED(), 3, &d_args);
        qjs.JS_FreeValue(c, r);
        qjs.JS_FreeValue(c, fn_val);
    }
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
/// Reset event state without freeing JS values (for leak-safe navigation teardown).
/// Use when the JS runtime is being leaked intentionally to avoid heap corruption.
pub fn resetEventsLeaky() void {
    listener_entries = .empty;
    window_listener_entries = .empty;
    document_listener_entries = .empty;
    cached_js_doc_dispatch = quickjs.JS_UNDEFINED();
    mutation_observers = .empty;
    g_ctx = null;
}

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

    // Free cached JS dispatch helper
    if (!quickjs.JS_IsUndefined(cached_js_doc_dispatch)) {
        qjs.JS_FreeValue(ctx, cached_js_doc_dispatch);
        cached_js_doc_dispatch = quickjs.JS_UNDEFINED();
    }

    g_ctx = null;
}

// jsStringToSlice is accessed via dom_api.jsStringToSlice

// ── MutationObserver ────────────────────────────────────────────────

const MutationRecord = struct {
    type_str: []const u8, // "childList" or "attributes" (static, not owned)
    target: *lxb.lxb_dom_node_t,
    attribute_name: ?[]const u8, // owned copy, null for childList
    attribute_namespace: ?[]const u8 = null, // owned copy, null unless setAttributeNS
    old_value: ?[]const u8 = null, // owned copy, for attributeOldValue/characterDataOldValue
    added_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    removed_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    previous_sibling: ?*lxb.lxb_dom_node_t = null,
    next_sibling: ?*lxb.lxb_dom_node_t = null,

    fn deinit(self: *MutationRecord) void {
        if (self.attribute_name) |name| allocator.free(@constCast(name));
        if (self.attribute_namespace) |ns| allocator.free(@constCast(ns));
        if (self.old_value) |ov| allocator.free(@constCast(ov));
        self.added_nodes.deinit(allocator);
        self.removed_nodes.deinit(allocator);
    }
};

const ObserveTarget = struct {
    node: *lxb.lxb_dom_node_t,
    child_list: bool,
    attributes: bool,
    attribute_old_value: bool = false,
    character_data: bool = false,
    character_data_old_value: bool = false,
    subtree: bool,
    /// Optional attribute filter: if non-empty, only attributes in this list generate records.
    attribute_filter: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *ObserveTarget) void {
        for (self.attribute_filter.items) |f| allocator.free(@constCast(f));
        self.attribute_filter.deinit(allocator);
    }

    fn matchesAttributeFilter(self: *const ObserveTarget, attr_name: ?[]const u8) bool {
        if (self.attribute_filter.items.len == 0) return true; // no filter = match all
        const name = attr_name orelse return true;
        for (self.attribute_filter.items) |f| {
            if (std.mem.eql(u8, f, name)) return true;
        }
        return false;
    }
};

const MutationObserverEntry = struct {
    callback: qjs.JSValue,
    targets: std.ArrayListUnmanaged(ObserveTarget),
    pending_records: std.ArrayListUnmanaged(MutationRecord),
    disconnected: bool,

    fn deinit(self: *MutationObserverEntry, ctx: *qjs.JSContext) void {
        qjs.JS_FreeValue(ctx, self.callback);
        for (self.targets.items) |*t| t.deinit();
        self.targets.deinit(allocator);
        for (self.pending_records.items) |*r| r.deinit();
        self.pending_records.deinit(allocator);
    }
};

var mutation_observers: std.ArrayListUnmanaged(MutationObserverEntry) = .empty;

/// Suppresses childList mutation recording when true (used by replaceChildren batching).
/// While suppressed, added/removed nodes are collected in deferred buffers.
pub var suppress_childlist: bool = false;
var deferred_target: ?*lxb.lxb_dom_node_t = null;
// DOM §4.9: deferred mutation buffers — dynamic, no artificial cap.
var deferred_added: std.ArrayList(*lxb.lxb_dom_node_t) = .empty;
var deferred_removed: std.ArrayList(*lxb.lxb_dom_node_t) = .empty;

/// Begin suppressing childList mutations (call before replaceChildren loop).
pub fn beginSuppressChildList(target: *lxb.lxb_dom_node_t) void {
    suppress_childlist = true;
    deferred_target = target;
    deferred_added.clearRetainingCapacity();
    deferred_removed.clearRetainingCapacity();
}

/// End suppression and emit one bulk MutationRecord.
pub fn endSuppressChildList() void {
    suppress_childlist = false;
    const target = deferred_target orelse return;
    recordMutationChildListBulk(target, deferred_added.items, deferred_removed.items, null, null);
    deferred_target = null;
}

/// Record a mutation for any observing MutationObservers.
pub fn recordMutation(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
) void {
    recordMutationFull(target, mutation_type, added, removed, attr_name, null, null, null, null);
}

pub fn recordMutationChildList(
    target: *lxb.lxb_dom_node_t,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    prev_sib: ?*lxb.lxb_dom_node_t,
    next_sib: ?*lxb.lxb_dom_node_t,
) void {
    if (suppress_childlist) {
        // Collect for deferred bulk record (dynamic — no cap).
        if (added) |a| {
            deferred_added.append(std.heap.c_allocator, a) catch {};
        }
        if (removed) |r| {
            deferred_removed.append(std.heap.c_allocator, r) catch {};
        }
        return;
    }
    recordMutationFull(target, "childList", added, removed, null, null, null, prev_sib, next_sib);
}

/// Record a childList mutation with multiple added AND removed nodes (for innerHTML/replaceChildren).
pub fn recordMutationChildListBulk(
    target: *lxb.lxb_dom_node_t,
    added_nodes: []const *lxb.lxb_dom_node_t,
    removed_nodes: []const *lxb.lxb_dom_node_t,
    prev_sib: ?*lxb.lxb_dom_node_t,
    next_sib: ?*lxb.lxb_dom_node_t,
) void {
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;
            if (!t.child_list) continue;

            var record = MutationRecord{
                .type_str = "childList",
                .target = target,
                .attribute_name = null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
                .previous_sibling = prev_sib,
                .next_sibling = next_sib,
            };
            for (added_nodes) |n| {
                record.added_nodes.append(allocator, n) catch {};
            }
            for (removed_nodes) |n| {
                record.removed_nodes.append(allocator, n) catch {};
            }
            obs.pending_records.append(allocator, record) catch {};
            break;
        }
    }
}

/// Record a childList mutation with multiple added nodes (for DocumentFragment insertion).
pub fn recordMutationChildListMulti(
    target: *lxb.lxb_dom_node_t,
    added_nodes: []const *lxb.lxb_dom_node_t,
    prev_sib: ?*lxb.lxb_dom_node_t,
    next_sib: ?*lxb.lxb_dom_node_t,
) void {
    if (suppress_childlist) {
        for (added_nodes) |a| {
            deferred_added.append(std.heap.c_allocator, a) catch {};
        }
        return;
    }
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;
            if (!t.child_list) continue;

            var record = MutationRecord{
                .type_str = "childList",
                .target = target,
                .attribute_name = null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
                .previous_sibling = prev_sib,
                .next_sibling = next_sib,
            };
            for (added_nodes) |n| {
                record.added_nodes.append(allocator, n) catch {};
            }
            obs.pending_records.append(allocator, record) catch {};
            break;
        }
    }
}

/// Record a childList mutation with multiple removedNodes (for fragment removal).
pub fn recordMutationChildListRemovedMulti(
    target: *lxb.lxb_dom_node_t,
    removed_nodes: []const *lxb.lxb_dom_node_t,
) void {
    if (suppress_childlist) return;
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;
            if (!t.child_list) continue;

            var record = MutationRecord{
                .type_str = "childList",
                .target = target,
                .attribute_name = null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
                .previous_sibling = null,
                .next_sibling = null,
            };
            for (removed_nodes) |n| {
                record.removed_nodes.append(allocator, n) catch {};
            }
            obs.pending_records.append(allocator, record) catch {};
            break;
        }
    }
}

pub fn recordMutationWithOldValue(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
    old_value: ?[]const u8,
) void {
    recordMutationFull(target, mutation_type, added, removed, attr_name, null, old_value, null, null);
}

pub fn recordMutationAttrNS(
    target: *lxb.lxb_dom_node_t,
    attr_local_name: []const u8,
    attr_namespace: ?[]const u8,
    old_value: ?[]const u8,
) void {
    recordMutationFull(target, "attributes", null, null, attr_local_name, attr_namespace, old_value, null, null);
}

/// Record a mutation with all fields including previousSibling/nextSibling.
fn recordMutationFull(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
    attr_namespace: ?[]const u8,
    old_value: ?[]const u8,
    prev_sib: ?*lxb.lxb_dom_node_t,
    next_sib: ?*lxb.lxb_dom_node_t,
) void {
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;

            const want = if (std.mem.eql(u8, mutation_type, "childList")) t.child_list else if (std.mem.eql(u8, mutation_type, "attributes")) t.attributes else if (std.mem.eql(u8, mutation_type, "characterData")) t.character_data else false;
            if (!want) continue;

            // DOM §4.3.3 step 3.3: attributeFilter only matches attributes in the
            // null namespace. Namespaced attributes (e.g. xlink:href) bypass the
            // filter entirely — they are never matched by attributeFilter even if
            // the local name appears in the list.
            if (std.mem.eql(u8, mutation_type, "attributes")) {
                if (t.attribute_filter.items.len > 0) {
                    if (attr_namespace != null) continue;
                    if (!t.matchesAttributeFilter(attr_name)) continue;
                }
            }

            var record = MutationRecord{
                .type_str = mutation_type,
                .target = target,
                .attribute_name = null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
                .previous_sibling = prev_sib,
                .next_sibling = next_sib,
            };
            if (attr_name) |n| {
                const copy = allocator.alloc(u8, n.len) catch null;
                if (copy) |c| {
                    @memcpy(c, n);
                    record.attribute_name = c;
                }
            }
            if (attr_namespace) |ns| {
                const ns_copy = allocator.alloc(u8, ns.len) catch null;
                if (ns_copy) |nc| {
                    @memcpy(nc, ns);
                    record.attribute_namespace = nc;
                }
            }
            // Store old value only when the matching oldValue option is set for this mutation type
            const wants_old_value = if (std.mem.eql(u8, mutation_type, "attributes"))
                t.attribute_old_value
            else if (std.mem.eql(u8, mutation_type, "characterData"))
                t.character_data_old_value
            else
                false;
            if (old_value != null and wants_old_value) {
                if (old_value) |ov| {
                    const ov_copy = allocator.alloc(u8, ov.len) catch null;
                    if (ov_copy) |ovc| {
                        @memcpy(ovc, ov);
                        record.old_value = ovc;
                    }
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
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "type", qjs.JS_NewStringLen(ctx, rec.type_str.ptr, rec.type_str.len));
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "target", dom_api.wrapNodePublic(ctx, rec.target));

            const added_arr = qjs.JS_NewArray(ctx);
            for (rec.added_nodes.items, 0..) |node, ai| {
                _ = qjs.JS_SetPropertyUint32(ctx, added_arr, @intCast(ai), dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "addedNodes", added_arr);

            const removed_arr = qjs.JS_NewArray(ctx);
            for (rec.removed_nodes.items, 0..) |node, ri| {
                _ = qjs.JS_SetPropertyUint32(ctx, removed_arr, @intCast(ri), dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "removedNodes", removed_arr);

            if (rec.attribute_name) |name| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName", qjs.JS_NewStringLen(ctx, name.ptr, name.len));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName", quickjs.JS_NULL());
            }
            if (rec.attribute_namespace) |ns| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeNamespace", qjs.JS_NewStringLen(ctx, ns.ptr, ns.len));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeNamespace", quickjs.JS_NULL());
            }
            if (rec.previous_sibling) |ps| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "previousSibling", dom_api.wrapNodePublic(ctx, ps));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "previousSibling", quickjs.JS_NULL());
            }
            if (rec.next_sibling) |ns| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "nextSibling", dom_api.wrapNodePublic(ctx, ns));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "nextSibling", quickjs.JS_NULL());
            }
            if (rec.old_value) |ov| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "oldValue", qjs.JS_NewStringLen(ctx, ov.ptr, ov.len));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "oldValue", quickjs.JS_NULL());
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
    _ = qjs.JS_SetPropertyStr(c, obj, "observe", qjs.JS_NewCFunction(c, &jsMutationObserverObserve, "observe", 2));
    _ = qjs.JS_SetPropertyStr(c, obj, "disconnect", qjs.JS_NewCFunction(c, &jsMutationObserverDisconnect, "disconnect", 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "takeRecords", qjs.JS_NewCFunction(c, &jsMutationObserverTakeRecords, "takeRecords", 0));
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
    var character_data = false;
    var subtree = false;

    if (argc >= 2 and !quickjs.JS_IsUndefined(args[1])) {
        child_list = jsBoolProp(c, args[1], "childList");
        attributes_opt = jsBoolProp(c, args[1], "attributes");
        character_data = jsBoolProp(c, args[1], "characterData");
        subtree = jsBoolProp(c, args[1], "subtree");

        // DOM spec: at least one of childList/attributes/characterData must be true
        if (!child_list and !attributes_opt and !character_data) {
            // Check if attributeOldValue or attributeFilter or characterDataOldValue imply attributes/characterData
            const attr_old = jsBoolProp(c, args[1], "attributeOldValue");
            const char_old = jsBoolProp(c, args[1], "characterDataOldValue");
            const attr_filter = qjs.JS_GetPropertyStr(c, args[1], "attributeFilter");
            defer qjs.JS_FreeValue(c, attr_filter);
            const has_filter = !quickjs.JS_IsUndefined(attr_filter);
            if (attr_old) attributes_opt = true;
            if (has_filter) attributes_opt = true;
            if (char_old) character_data = true;
            if (!child_list and !attributes_opt and !character_data)
                return qjs.JS_ThrowTypeError(c, "Failed to execute 'observe': The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.");
        } else {
            // Validate: attributeOldValue=true requires attributes!=false
            const attr_old = jsBoolProp(c, args[1], "attributeOldValue");
            if (attr_old and !attributes_opt)
                return qjs.JS_ThrowTypeError(c, "Failed to execute 'observe': The options object may not set 'attributeOldValue' to true when 'attributes' is false.");
            const attr_filter = qjs.JS_GetPropertyStr(c, args[1], "attributeFilter");
            defer qjs.JS_FreeValue(c, attr_filter);
            if (!quickjs.JS_IsUndefined(attr_filter) and !attributes_opt)
                return qjs.JS_ThrowTypeError(c, "Failed to execute 'observe': The options object may not set 'attributeFilter' when 'attributes' is false.");
            const char_old = jsBoolProp(c, args[1], "characterDataOldValue");
            if (char_old and !character_data)
                return qjs.JS_ThrowTypeError(c, "Failed to execute 'observe': The options object may not set 'characterDataOldValue' to true when 'characterData' is false.");
        }
    }

    const attr_old_val = if (argc >= 2) jsBoolProp(c, args[1], "attributeOldValue") else false;
    const char_data_old = if (argc >= 2) jsBoolProp(c, args[1], "characterDataOldValue") else false;

    // Parse attributeFilter array
    var attr_filter_list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (argc >= 2) {
        const af = qjs.JS_GetPropertyStr(c, args[1], "attributeFilter");
        defer qjs.JS_FreeValue(c, af);
        if (!quickjs.JS_IsUndefined(af) and af.tag == qjs.JS_TAG_OBJECT) {
            const len_val = qjs.JS_GetPropertyStr(c, af, "length");
            defer qjs.JS_FreeValue(c, len_val);
            var len: i32 = 0;
            _ = qjs.JS_ToInt32(c, &len, len_val);
            const ulen: u32 = if (len > 0) @intCast(len) else 0;
            var fi: u32 = 0;
            while (fi < ulen) : (fi += 1) {
                const item = qjs.JS_GetPropertyUint32(c, af, fi);
                defer qjs.JS_FreeValue(c, item);
                const s = dom_api.jsStringToSlice(c, item) orelse continue;
                defer qjs.JS_FreeCString(c, s.ptr);
                const copy = allocator.alloc(u8, s.len) catch continue;
                @memcpy(copy, s.ptr[0..s.len]);
                attr_filter_list.append(allocator, copy) catch {
                    allocator.free(copy);
                };
            }
        }
    }

    mutation_observers.items[idx].targets.append(allocator, .{
        .node = target,
        .child_list = child_list,
        .attributes = attributes_opt,
        .attribute_old_value = attr_old_val,
        .character_data = character_data,
        .character_data_old_value = char_data_old,
        .subtree = subtree,
        .attribute_filter = attr_filter_list,
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
    for (mutation_observers.items[idx].targets.items) |*t| {
        t.deinit();
    }
    mutation_observers.items[idx].targets.clearRetainingCapacity();
    return quickjs.JS_UNDEFINED();
}

fn jsMutationObserverTakeRecords(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const arr = qjs.JS_NewArray(c);
    // Find the observer matching this_val and drain pending records
    const obs_id_val = qjs.JS_GetPropertyStr(c, this_val, "_idx");
    defer qjs.JS_FreeValue(c, obs_id_val);
    const obs_id = if (obs_id_val.tag == qjs.JS_TAG_INT) @as(usize, @intCast(qjs.JS_VALUE_GET_INT(obs_id_val))) else return arr;
    if (obs_id >= mutation_observers.items.len) return arr;
    var obs = &mutation_observers.items[obs_id];
    var idx: u32 = 0;
    for (obs.pending_records.items) |rec| {
        const record = qjs.JS_NewObject(c);
        _ = qjs.JS_SetPropertyStr(c, record, "type", qjs.JS_NewStringLen(c, rec.type_str.ptr, rec.type_str.len));
        _ = qjs.JS_SetPropertyStr(c, record, "target", dom_api.wrapNodePublic(c, rec.target));
        if (rec.attribute_name) |an| {
            _ = qjs.JS_SetPropertyStr(c, record, "attributeName", qjs.JS_NewStringLen(c, an.ptr, an.len));
        } else {
            _ = qjs.JS_SetPropertyStr(c, record, "attributeName", quickjs.JS_NULL());
        }
        // addedNodes / removedNodes as arrays
        const added = qjs.JS_NewArray(c);
        for (rec.added_nodes.items, 0..) |n, j| {
            _ = qjs.JS_SetPropertyUint32(c, added, @intCast(j), dom_api.wrapNodePublic(c, n));
        }
        _ = qjs.JS_SetPropertyStr(c, record, "addedNodes", added);
        const removed = qjs.JS_NewArray(c);
        for (rec.removed_nodes.items, 0..) |n, j| {
            _ = qjs.JS_SetPropertyUint32(c, removed, @intCast(j), dom_api.wrapNodePublic(c, n));
        }
        _ = qjs.JS_SetPropertyStr(c, record, "removedNodes", removed);
        // previousSibling / nextSibling
        if (rec.previous_sibling) |ps| {
            _ = qjs.JS_SetPropertyStr(c, record, "previousSibling", dom_api.wrapNodePublic(c, ps));
        } else {
            _ = qjs.JS_SetPropertyStr(c, record, "previousSibling", quickjs.JS_NULL());
        }
        if (rec.next_sibling) |ns| {
            _ = qjs.JS_SetPropertyStr(c, record, "nextSibling", dom_api.wrapNodePublic(c, ns));
        } else {
            _ = qjs.JS_SetPropertyStr(c, record, "nextSibling", quickjs.JS_NULL());
        }
        // attributeNamespace
        if (rec.attribute_namespace) |ans| {
            _ = qjs.JS_SetPropertyStr(c, record, "attributeNamespace", qjs.JS_NewStringLen(c, ans.ptr, ans.len));
        } else {
            _ = qjs.JS_SetPropertyStr(c, record, "attributeNamespace", quickjs.JS_NULL());
        }
        // oldValue
        if (rec.old_value) |ov| {
            _ = qjs.JS_SetPropertyStr(c, record, "oldValue", qjs.JS_NewStringLen(c, ov.ptr, ov.len));
        } else {
            _ = qjs.JS_SetPropertyStr(c, record, "oldValue", quickjs.JS_NULL());
        }
        _ = qjs.JS_SetPropertyUint32(c, arr, idx, record);
        idx += 1;
    }
    obs.pending_records.clearRetainingCapacity();
    return arr;
}
