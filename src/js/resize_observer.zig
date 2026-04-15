// ResizeObserver — Resize Observer §3-§4
// https://www.w3.org/TR/resize-observer/
//
// §3.1  ResizeObserver interface: constructor(callback), observe(target, options?),
//        unobserve(target), disconnect()
// §3.2  ResizeObserverEntry: target, contentRect, borderBoxSize,
//        contentBoxSize, devicePixelContentBoxSize
// §3.3  ResizeObserverSize: inlineSize, blockSize
// §3.4  ResizeObserverOptions: box ("content-box" | "border-box" |
//        "device-pixel-content-box")
// §4    Algorithms: broadcast active observations, has active observations

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const dom_api = @import("dom_api.zig");
const dom_element = @import("dom_element.zig");

const allocator = std.heap.c_allocator;

// ── §3.4 Box options ─────────────────────────────────────────────────

const BoxOption = enum {
    content_box,
    border_box,
    device_pixel_content_box,
};

fn parseBoxOption(ctx: *qjs.JSContext, opts: qjs.JSValue) BoxOption {
    if (quickjs.JS_IsUndefined(opts) or quickjs.JS_IsNull(opts)) return .content_box;
    const box_val = qjs.JS_GetPropertyStr(ctx, opts, "box");
    defer qjs.JS_FreeValue(ctx, box_val);
    if (quickjs.JS_IsUndefined(box_val)) return .content_box;
    const s = qjs.JS_ToCString(ctx, box_val);
    if (s == null) return .content_box;
    defer qjs.JS_FreeCString(ctx, s);
    const sl = std.mem.sliceTo(s.?, 0);
    if (std.mem.eql(u8, sl, "border-box")) return .border_box;
    if (std.mem.eql(u8, sl, "device-pixel-content-box")) return .device_pixel_content_box;
    return .content_box;
}

// ── §3.1 Observation target record ───────────────────────────────────

/// One entry in the observed-target list (§3.1 observe algorithm).
const ObservedTarget = struct {
    node: *lxb.lxb_dom_node_t,
    box_option: BoxOption,
    /// Last-reported inline (width) size — used for change detection (§4).
    last_inline: f32,
    /// Last-reported block (height) size — used for change detection (§4).
    last_block: f32,
};

// ── §3.1 Observer record ─────────────────────────────────────────────

const ResizeObserverEntry = struct {
    callback: qjs.JSValue,
    targets: std.ArrayListUnmanaged(ObservedTarget),
    disconnected: bool,
};

var resize_observers: std.ArrayListUnmanaged(ResizeObserverEntry) = .empty;

// ── §4 Size helpers ───────────────────────────────────────────────────

/// Canonical size pair used throughout the flush algorithm.
const SizePair = struct { inline_size: f32, block_size: f32 };

/// Return the content-box size for the node (§3.3 inlineSize = width, blockSize = height).
/// Returns .{0, 0} when the node has no layout box yet.
fn contentSize(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) SizePair {
    const root = dom_api.getRootBox(ctx) orelse return .{ .inline_size = 0, .block_size = 0 };
    const box = dom_api.findBoxForNode(root, node) orelse return .{ .inline_size = 0, .block_size = 0 };
    return .{ .inline_size = box.content.width, .block_size = box.content.height };
}

/// Return the border-box size (§3.3).
fn borderSize(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) SizePair {
    const root = dom_api.getRootBox(ctx) orelse return .{ .inline_size = 0, .block_size = 0 };
    const box = dom_api.findBoxForNode(root, node) orelse return .{ .inline_size = 0, .block_size = 0 };
    const bb = box.borderBox();
    return .{ .inline_size = bb.width, .block_size = bb.height };
}

// ── §3.2 Build a ResizeObserverSize array-of-one ─────────────────────

/// §3.3: ResizeObserverSize { inlineSize, blockSize }
fn makeSize(ctx: *qjs.JSContext, inline_size: f32, block_size: f32) qjs.JSValue {
    const sz = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, sz, "inlineSize", qjs.JS_NewFloat64(ctx, inline_size));
    _ = qjs.JS_SetPropertyStr(ctx, sz, "blockSize", qjs.JS_NewFloat64(ctx, block_size));
    return sz;
}

/// §3.3: a frozen array of one ResizeObserverSize (spec returns FrozenArray).
fn makeSizeArray(ctx: *qjs.JSContext, inline_size: f32, block_size: f32) qjs.JSValue {
    const arr = qjs.JS_NewArray(ctx);
    _ = qjs.JS_SetPropertyUint32(ctx, arr, 0, makeSize(ctx, inline_size, block_size));
    return arr;
}

// ── §3.2 Build a ResizeObserverEntry JS object ────────────────────────

/// §3.2 ResizeObserverEntry fields:
///   target, contentRect (DOMRectReadOnly), contentBoxSize,
///   borderBoxSize, devicePixelContentBoxSize
fn buildEntry(
    ctx: *qjs.JSContext,
    node: *lxb.lxb_dom_node_t,
) qjs.JSValue {
    const root = dom_api.getRootBox(ctx);
    var content_x: f32 = 0;
    var content_y: f32 = 0;
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    var border_w: f32 = 0;
    var border_h: f32 = 0;

    if (root) |r| {
        if (dom_api.findBoxForNode(r, node)) |box| {
            content_x = box.content.x;
            content_y = box.content.y;
            content_w = box.content.width;
            content_h = box.content.height;
            const bb = box.borderBox();
            border_w = bb.width;
            border_h = bb.height;
        }
    }

    const entry = qjs.JS_NewObject(ctx);

    // target (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, entry, "target", dom_api.wrapNodePublic(ctx, node));

    // contentRect (§3.2) — DOMRectReadOnly-like plain object
    // [[spec]] ResizeObserver §3.2: contentRect is a DOMRectReadOnly representing
    // the content box. x/y are the offsets within the border box.
    {
        const rect = qjs.JS_NewObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, rect, "x", qjs.JS_NewFloat64(ctx, content_x));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "y", qjs.JS_NewFloat64(ctx, content_y));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "width", qjs.JS_NewFloat64(ctx, content_w));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "height", qjs.JS_NewFloat64(ctx, content_h));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "top", qjs.JS_NewFloat64(ctx, content_y));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "left", qjs.JS_NewFloat64(ctx, content_x));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "right", qjs.JS_NewFloat64(ctx, content_x + content_w));
        _ = qjs.JS_SetPropertyStr(ctx, rect, "bottom", qjs.JS_NewFloat64(ctx, content_y + content_h));
        _ = qjs.JS_SetPropertyStr(ctx, entry, "contentRect", rect);
    }

    // contentBoxSize §3.3 — FrozenArray<ResizeObserverSize>
    _ = qjs.JS_SetPropertyStr(ctx, entry, "contentBoxSize", makeSizeArray(ctx, content_w, content_h));

    // borderBoxSize §3.3
    _ = qjs.JS_SetPropertyStr(ctx, entry, "borderBoxSize", makeSizeArray(ctx, border_w, border_h));

    // devicePixelContentBoxSize §3.3 — DPR assumed 1 (no DPI info available)
    _ = qjs.JS_SetPropertyStr(ctx, entry, "devicePixelContentBoxSize", makeSizeArray(ctx, content_w, content_h));

    return entry;
}

// ── §4 flushResizeObservers ───────────────────────────────────────────

/// §4 "broadcast active observations" step — called from the event loop
/// after layout / after mutations (DOM §2.2 step 11 equivalent).
/// Iterates all observers, checks each target for size change, builds
/// ResizeObserverEntry objects, and invokes the callback.
pub fn flushResizeObservers(ctx: *qjs.JSContext) void {
    var i: usize = 0;
    while (i < resize_observers.items.len) : (i += 1) {
        const obs = &resize_observers.items[i];
        if (obs.disconnected) continue;

        const entries_arr = qjs.JS_NewArray(ctx);
        var count: u32 = 0;

        for (obs.targets.items) |*tgt| {
            // §4: "has active observations" — compare current size to last notified.
            const sz = switch (tgt.box_option) {
                .content_box, .device_pixel_content_box => contentSize(ctx, tgt.node),
                .border_box => borderSize(ctx, tgt.node),
            };

            const inline_changed = @abs(sz.inline_size - tgt.last_inline) > 0.0;
            const block_changed = @abs(sz.block_size - tgt.last_block) > 0.0;
            if (!inline_changed and !block_changed) continue;

            // Update stored size.
            tgt.last_inline = sz.inline_size;
            tgt.last_block = sz.block_size;

            const entry = buildEntry(ctx, tgt.node);
            _ = qjs.JS_SetPropertyUint32(ctx, entries_arr, count, entry);
            count += 1;
        }

        if (count > 0) {
            var call_args = [_]qjs.JSValue{ entries_arr, quickjs.JS_UNDEFINED() };
            const ret = qjs.JS_Call(ctx, obs.callback, quickjs.JS_UNDEFINED(), 2, &call_args);
            qjs.JS_FreeValue(ctx, ret);
        }
        qjs.JS_FreeValue(ctx, entries_arr);
    }
}

// ── §3.1 JS API helper: get observer index from `this._idx` ──────────

fn getObserverIdx(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?u32 {
    const idx_val = qjs.JS_GetPropertyStr(ctx, this_val, "_ro_idx");
    defer qjs.JS_FreeValue(ctx, idx_val);
    var idx: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &idx, idx_val) != 0) return null;
    if (idx < 0 or @as(usize, @intCast(idx)) >= resize_observers.items.len) return null;
    return @intCast(idx);
}

// ── §3.1 observe(target, options?) ───────────────────────────────────

fn jsResizeObserverObserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var obs = &resize_observers.items[idx];
    if (obs.disconnected) return quickjs.JS_UNDEFINED();

    const node = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    // §3.1: If target is already observed, update the box option.
    const box_opt = if (argc >= 2 and !quickjs.JS_IsUndefined(args[1]))
        parseBoxOption(c, args[1])
    else
        BoxOption.content_box;

    for (obs.targets.items) |*tgt| {
        if (tgt.node == node) {
            // Already observed — update box option and reset last size to force delivery.
            tgt.box_option = box_opt;
            tgt.last_inline = -1; // force delivery next flush
            tgt.last_block = -1;
            // Signal pending
            dom_api.resize_observers_pending = true;
            return quickjs.JS_UNDEFINED();
        }
    }

    obs.targets.append(allocator, .{
        .node = node,
        .box_option = box_opt,
        .last_inline = -1, // force first delivery
        .last_block = -1,
    }) catch return quickjs.JS_UNDEFINED();

    // Signal the event loop that there are active observations pending.
    dom_api.resize_observers_pending = true;
    return quickjs.JS_UNDEFINED();
}

// ── §3.1 unobserve(target) ───────────────────────────────────────────

fn jsResizeObserverUnobserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var obs = &resize_observers.items[idx];
    const node = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    var j: usize = 0;
    while (j < obs.targets.items.len) {
        if (obs.targets.items[j].node == node) {
            _ = obs.targets.swapRemove(j);
        } else {
            j += 1;
        }
    }
    return quickjs.JS_UNDEFINED();
}

// ── §3.1 disconnect() ────────────────────────────────────────────────

fn jsResizeObserverDisconnect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var obs = &resize_observers.items[idx];
    obs.disconnected = true;
    obs.targets.clearRetainingCapacity();
    return quickjs.JS_UNDEFINED();
}

// ── §3.1 Constructor ─────────────────────────────────────────────────

/// ResizeObserver constructor (§3.1).
/// new ResizeObserver(callback) → object with observe/unobserve/disconnect.
pub fn jsResizeObserverConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_ThrowTypeError(c, "ResizeObserver requires a callback");
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (!qjs.JS_IsFunction(c, args[0])) return qjs.JS_ThrowTypeError(c, "ResizeObserver callback must be a function");

    const idx: u32 = @intCast(resize_observers.items.len);
    resize_observers.append(allocator, .{
        .callback = qjs.JS_DupValue(c, args[0]),
        .targets = .empty,
        .disconnected = false,
    }) catch return quickjs.JS_UNDEFINED();

    const obj = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, obj, "_ro_idx", qjs.JS_NewInt32(c, @intCast(idx)));
    _ = qjs.JS_SetPropertyStr(c, obj, "observe", qjs.JS_NewCFunction(c, &jsResizeObserverObserve, "observe", 2));
    _ = qjs.JS_SetPropertyStr(c, obj, "unobserve", qjs.JS_NewCFunction(c, &jsResizeObserverUnobserve, "unobserve", 1));
    _ = qjs.JS_SetPropertyStr(c, obj, "disconnect", qjs.JS_NewCFunction(c, &jsResizeObserverDisconnect, "disconnect", 0));
    return obj;
}
