// IntersectionObserver — W3C Intersection Observer §3–4
// https://www.w3.org/TR/intersection-observer/
//
// §3.1 IntersectionObserver interface: constructor, observe, unobserve,
//       disconnect, takeRecords
// §3.2 IntersectionObserverEntry: time, rootBounds, boundingClientRect,
//       intersectionRect, isIntersecting, intersectionRatio, target
// §3.3 IntersectionObserverInit: root, rootMargin, threshold
// §4.3 Compute intersection of a target element and the observer's root
// §4.4 Queue an IntersectionObserverEntry when threshold is crossed

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const dom_api = @import("dom_api.zig");

const allocator = std.heap.c_allocator;

// ── Geometry helpers ─────────────────────────────────────────────────

/// Axis-aligned rectangle (matches CSSOM View DOMRect).
const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn top(self: Rect) f32 {
        return self.y;
    }
    fn left(self: Rect) f32 {
        return self.x;
    }
    fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }
    fn right(self: Rect) f32 {
        return self.x + self.w;
    }
    fn area(self: Rect) f32 {
        return self.w * self.h;
    }

    /// §4.3 — intersect two rects; result has zero dimensions when no overlap.
    fn intersect(a: Rect, b: Rect) Rect {
        const ix = @max(a.left(), b.left());
        const iy = @max(a.top(), b.top());
        const ix2 = @min(a.right(), b.right());
        const iy2 = @min(a.bottom(), b.bottom());
        const iw = @max(0.0, ix2 - ix);
        const ih = @max(0.0, iy2 - iy);
        return .{ .x = ix, .y = iy, .w = iw, .h = ih };
    }

    fn zero() Rect {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
};

// ── §3.3 rootMargin parsed form (px + %) ──────────────────────────────

const MarginValue = struct { num: f32 = 0, pct: bool = false };

const RootMargin = struct {
    top: MarginValue = .{},
    right: MarginValue = .{},
    bottom: MarginValue = .{},
    left: MarginValue = .{},
};

/// Parse rootMargin string: "10px 5px 0px 20px" or "10% 5%" (1–4 values, px or %).
/// Returns zero margin on any parse failure.
fn parseRootMargin(s: []const u8) RootMargin {
    var values: [4]MarginValue = .{ .{}, .{}, .{}, .{} };
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < 4) {
        // skip whitespace
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len) break;
        // optional sign
        var neg: bool = false;
        if (s[i] == '-') {
            neg = true;
            i += 1;
        }
        // digits + optional decimal
        const start = i;
        while (i < s.len and (s[i] >= '0' and s[i] <= '9')) i += 1;
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and (s[i] >= '0' and s[i] <= '9')) i += 1;
        }
        if (i == start) break; // no digits
        const num = std.fmt.parseFloat(f32, s[start..i]) catch 0;
        // check unit: '%' → percentage, otherwise consume any non-space chars (px/em/etc.)
        var is_pct: bool = false;
        if (i < s.len and s[i] == '%') {
            is_pct = true;
            i += 1;
        } else {
            while (i < s.len and s[i] != ' ') i += 1;
        }
        values[count] = MarginValue{ .num = if (neg) -num else num, .pct = is_pct };
        count += 1;
    }
    return switch (count) {
        0, 1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
        2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
        3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
        else => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
    };
}

// ── Observer data structures ──────────────────────────────────────────

/// Per-target previous intersection ratio for threshold crossing detection (§4.4).
const TargetState = struct {
    node: *lxb.lxb_dom_node_t,
    prev_ratio: f32,
    /// true on first observe call so we always fire the initial entry (§9.4).
    first: bool,
};

const IntersectionObserverEntry = struct {
    callback: qjs.JSValue, // JS callback function (§3.1 constructor arg)
    /// null root = implicit root (viewport). Non-null root NYI (future: custom root element).
    root_node: ?*lxb.lxb_dom_node_t,
    root_margin: RootMargin,
    /// Sorted thresholds (§3.3); always has at least one value (0.0).
    thresholds: std.ArrayListUnmanaged(f32),
    targets: std.ArrayListUnmanaged(TargetState),
    disconnected: bool,
};

/// Global list of all active IntersectionObservers.
var observers: std.ArrayListUnmanaged(IntersectionObserverEntry) = .empty;

// ── §4.3 Compute the intersection rect ───────────────────────────────

/// Compute bounding rect for a DOM node using the layout box tree.
/// Returns zero rect if node has no layout box (hidden, detached, etc).
fn getBoundingRect(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) Rect {
    const root_box = dom_api.getRootBox(ctx) orelse return Rect.zero();
    const box = dom_api.findBoxForNode(root_box, node) orelse return Rect.zero();
    const bb = box.borderBox();
    return .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
}

/// §4.3 — compute root bounds (viewport expanded by rootMargin).
fn getRootBounds(ctx: *qjs.JSContext, rm: RootMargin) Rect {
    const vp = dom_api.getViewportForCtx(ctx);
    const top    = if (rm.top.pct)    vp.h * rm.top.num    / 100.0 else rm.top.num;
    const right  = if (rm.right.pct)  vp.w * rm.right.num  / 100.0 else rm.right.num;
    const bottom = if (rm.bottom.pct) vp.h * rm.bottom.num / 100.0 else rm.bottom.num;
    const left   = if (rm.left.pct)   vp.w * rm.left.num   / 100.0 else rm.left.num;
    return .{
        .x = -left,
        .y = -top,
        .w = vp.w + left + right,
        .h = vp.h + top + bottom,
    };
}

/// §4.3 — compute intersection ratio: area of intersection / target area.
/// Returns 0 when target has no area.
fn computeRatio(target_rect: Rect, intersection_rect: Rect) f32 {
    const ta = target_rect.area();
    if (ta <= 0) return 0;
    const ia = intersection_rect.area();
    return @min(ia / ta, 1.0);
}

// ── §4.4 Threshold crossing detection ────────────────────────────────

/// Returns true when a threshold is crossed between prev and new ratio.
fn crossesThreshold(thresholds: []const f32, prev: f32, new_ratio: f32) bool {
    for (thresholds) |th| {
        const was_above = prev >= th;
        const now_above = new_ratio >= th;
        if (was_above != now_above) return true;
    }
    return false;
}

// ── Build a JS IntersectionObserverEntry object ───────────────────────

fn makeEntryObject(
    ctx: *qjs.JSContext,
    target: *lxb.lxb_dom_node_t,
    target_rect: Rect,
    intersection_rect: Rect,
    root_rect: Rect,
    ratio: f32,
    is_intersecting: bool,
    time: f64,
) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);

    // time (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "time", qjs.JS_NewFloat64(ctx, time));

    // target (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "target", dom_api.wrapNodePublic(ctx, target));

    // isIntersecting / intersectionRatio (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "isIntersecting", qjs.JS_NewBool(ctx, is_intersecting));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "intersectionRatio", qjs.JS_NewFloat64(ctx, ratio));

    // boundingClientRect (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "boundingClientRect", makeRectObject(ctx, target_rect));

    // intersectionRect (§3.2)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "intersectionRect", makeRectObject(ctx, intersection_rect));

    // rootBounds (§3.2) — null when root is not the implicit root (but we only support implicit root)
    _ = qjs.JS_SetPropertyStr(ctx, obj, "rootBounds", makeRectObject(ctx, root_rect));

    return obj;
}

fn makeRectObject(ctx: *qjs.JSContext, r: Rect) qjs.JSValue {
    const obj = qjs.JS_NewObject(ctx);
    _ = qjs.JS_SetPropertyStr(ctx, obj, "x", qjs.JS_NewFloat64(ctx, r.x));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "y", qjs.JS_NewFloat64(ctx, r.y));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "width", qjs.JS_NewFloat64(ctx, r.w));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "height", qjs.JS_NewFloat64(ctx, r.h));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "top", qjs.JS_NewFloat64(ctx, r.top()));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "left", qjs.JS_NewFloat64(ctx, r.left()));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "bottom", qjs.JS_NewFloat64(ctx, r.bottom()));
    _ = qjs.JS_SetPropertyStr(ctx, obj, "right", qjs.JS_NewFloat64(ctx, r.right()));
    return obj;
}

// ── §4 Notify intersection observers ─────────────────────────────────

/// Called periodically (from the timer/event loop) to check all observed
/// targets and fire callbacks for any threshold crossings (§4.4).
pub fn flushIntersectionObservers(ctx: *qjs.JSContext) void {
    // §4.2 — get current time for entry timestamps
    const time_val = qjs.JS_GetPropertyStr(ctx, qjs.JS_GetGlobalObject(ctx), "performance");
    var now_ms: f64 = 0;
    if (!quickjs.JS_IsUndefined(time_val) and !quickjs.JS_IsNull(time_val)) {
        const now_fn = qjs.JS_GetPropertyStr(ctx, time_val, "now");
        if (!quickjs.JS_IsUndefined(now_fn)) {
            const result = qjs.JS_Call(ctx, now_fn, time_val, 0, null);
            _ = qjs.JS_ToFloat64(ctx, &now_ms, result);
            qjs.JS_FreeValue(ctx, result);
        }
        qjs.JS_FreeValue(ctx, now_fn);
    }
    qjs.JS_FreeValue(ctx, time_val);

    for (observers.items) |*obs| {
        if (obs.disconnected or obs.targets.items.len == 0) continue;

        const root_bounds = getRootBounds(ctx, obs.root_margin);
        const entries_arr = qjs.JS_NewArray(ctx);
        var count: u32 = 0;

        for (obs.targets.items) |*ts| {
            // §4.3 — compute target bounding rect
            const target_rect = getBoundingRect(ctx, ts.node);
            // §4.3 — compute intersection rect
            const intersection_rect = root_bounds.intersect(target_rect);
            const ratio = computeRatio(target_rect, intersection_rect);
            const is_intersecting = intersection_rect.w > 0 and intersection_rect.h > 0;

            // §4.4 — only queue entry when threshold is crossed (or first observation)
            const should_fire = ts.first or crossesThreshold(obs.thresholds.items, ts.prev_ratio, ratio);

            if (should_fire) {
                ts.first = false;
                ts.prev_ratio = ratio;
                const entry = makeEntryObject(
                    ctx,
                    ts.node,
                    target_rect,
                    intersection_rect,
                    root_bounds,
                    ratio,
                    is_intersecting,
                    now_ms,
                );
                _ = qjs.JS_SetPropertyUint32(ctx, entries_arr, count, entry);
                count += 1;
            }
        }

        if (count > 0) {
            // §4.2 — invoke callback with (entries, observer)
            var call_args = [_]qjs.JSValue{ entries_arr, quickjs.JS_UNDEFINED() };
            const ret = qjs.JS_Call(ctx, obs.callback, quickjs.JS_UNDEFINED(), 2, &call_args);
            qjs.JS_FreeValue(ctx, ret);
        }
        qjs.JS_FreeValue(ctx, entries_arr);
    }
}

// ── Helper to get observer index from JS object ───────────────────────

fn getObserverIdx(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?u32 {
    const idx_val = qjs.JS_GetPropertyStr(ctx, this_val, "_io_idx");
    defer qjs.JS_FreeValue(ctx, idx_val);
    var idx: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &idx, idx_val) != 0) return null;
    if (idx < 0 or @as(usize, @intCast(idx)) >= observers.items.len) return null;
    return @intCast(idx);
}

// ── §3.1 JS Constructor ───────────────────────────────────────────────

pub fn jsIntersectionObserverConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return qjs.JS_ThrowTypeError(c, "IntersectionObserver requires a callback argument");
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (!qjs.JS_IsFunction(c, args[0])) return qjs.JS_ThrowTypeError(c, "IntersectionObserver: callback must be a function");

    // Parse options (§3.3 IntersectionObserverInit)
    var root_margin = RootMargin{};
    var thresholds: std.ArrayListUnmanaged(f32) = .empty;

    if (argc >= 2 and !quickjs.JS_IsUndefined(args[1]) and !quickjs.JS_IsNull(args[1])) {
        const opts = args[1];

        // rootMargin
        const rm_val = qjs.JS_GetPropertyStr(c, opts, "rootMargin");
        defer qjs.JS_FreeValue(c, rm_val);
        if (!quickjs.JS_IsUndefined(rm_val) and !quickjs.JS_IsNull(rm_val)) {
            const rm_str = qjs.JS_ToCString(c, rm_val);
            if (rm_str != null) {
                defer qjs.JS_FreeCString(c, rm_str);
                const rm_ptr: [*c]const u8 = rm_str;
                const len = std.mem.len(rm_ptr);
                root_margin = parseRootMargin(rm_ptr[0..len]);
            }
        }

        // threshold — number or array of numbers (§3.3)
        const th_val = qjs.JS_GetPropertyStr(c, opts, "threshold");
        defer qjs.JS_FreeValue(c, th_val);
        if (!quickjs.JS_IsUndefined(th_val) and !quickjs.JS_IsNull(th_val)) {
            if (th_val.tag == qjs.JS_TAG_OBJECT) {
                // array-like
                const len_val = qjs.JS_GetPropertyStr(c, th_val, "length");
                defer qjs.JS_FreeValue(c, len_val);
                var len: i32 = 0;
                _ = qjs.JS_ToInt32(c, &len, len_val);
                const ulen: u32 = if (len > 0) @intCast(len) else 0;
                var ti: u32 = 0;
                while (ti < ulen) : (ti += 1) {
                    const item = qjs.JS_GetPropertyUint32(c, th_val, ti);
                    defer qjs.JS_FreeValue(c, item);
                    var f: f64 = 0;
                    _ = qjs.JS_ToFloat64(c, &f, item);
                    thresholds.append(allocator, @floatCast(f)) catch {};
                }
            } else {
                // single number
                var f: f64 = 0;
                _ = qjs.JS_ToFloat64(c, &f, th_val);
                thresholds.append(allocator, @floatCast(f)) catch {};
            }
        }
    }

    // Default threshold: [0] (§3.3)
    if (thresholds.items.len == 0) {
        thresholds.append(allocator, 0.0) catch {};
    }

    // Sort thresholds ascending (§3.3)
    std.mem.sort(f32, thresholds.items, {}, std.sort.asc(f32));

    const idx: u32 = @intCast(observers.items.len);
    observers.append(allocator, .{
        .callback = qjs.JS_DupValue(c, args[0]),
        .root_node = null,
        .root_margin = root_margin,
        .thresholds = thresholds,
        .targets = .empty,
        .disconnected = false,
    }) catch return quickjs.JS_UNDEFINED();

    // Build the JS object with methods
    const obj = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, obj, "_io_idx", qjs.JS_NewInt32(c, @intCast(idx)));
    _ = qjs.JS_SetPropertyStr(c, obj, "observe", qjs.JS_NewCFunction(c, &jsObserve, "observe", 1));
    _ = qjs.JS_SetPropertyStr(c, obj, "unobserve", qjs.JS_NewCFunction(c, &jsUnobserve, "unobserve", 1));
    _ = qjs.JS_SetPropertyStr(c, obj, "disconnect", qjs.JS_NewCFunction(c, &jsDisconnect, "disconnect", 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "takeRecords", qjs.JS_NewCFunction(c, &jsTakeRecords, "takeRecords", 0));
    return obj;
}

// ── §3.1 observe(target) ─────────────────────────────────────────────

fn jsObserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    var obs = &observers.items[idx];
    if (obs.disconnected) return quickjs.JS_UNDEFINED();

    // De-duplicate: if already observed, do nothing (§3.1)
    for (obs.targets.items) |ts| {
        if (ts.node == node) return quickjs.JS_UNDEFINED();
    }

    obs.targets.append(allocator, .{
        .node = node,
        .prev_ratio = -1.0, // sentinel: force first-entry fire
        .first = true,
    }) catch {};

    return quickjs.JS_UNDEFINED();
}

// ── §3.1 unobserve(target) ───────────────────────────────────────────

fn jsUnobserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const node = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    var obs = &observers.items[idx];
    var i: usize = 0;
    while (i < obs.targets.items.len) {
        if (obs.targets.items[i].node == node) {
            _ = obs.targets.swapRemove(i);
        } else {
            i += 1;
        }
    }
    return quickjs.JS_UNDEFINED();
}

// ── §3.1 disconnect() ────────────────────────────────────────────────

fn jsDisconnect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var obs = &observers.items[idx];
    obs.disconnected = true;
    obs.targets.clearRetainingCapacity();
    return quickjs.JS_UNDEFINED();
}

// ── §3.1 takeRecords() ───────────────────────────────────────────────
// Returns empty array — we fire immediately so no pending records accumulate.

fn jsTakeRecords(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    return qjs.JS_NewArray(c);
}
