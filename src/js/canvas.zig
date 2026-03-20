const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;

const Allocator = std.mem.Allocator;
const allocator = std.heap.c_allocator;

/// A software pixel buffer for canvas rendering.
pub const CanvasBuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) !CanvasBuffer {
        const pixels = try allocator.alloc(u32, @as(usize, width) * height);
        @memset(pixels, 0x00000000); // transparent
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn deinit(self: *CanvasBuffer) void {
        allocator.free(self.pixels);
    }

    pub fn setPixel(self: *CanvasBuffer, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        self.pixels[@as(usize, uy) * self.width + ux] = color;
    }

    pub fn fillRect(self: *CanvasBuffer, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, @as(i32, @intCast(self.width)));
        const y1 = @min(y + h, @as(i32, @intCast(self.height)));
        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                self.pixels[@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))] = color;
            }
        }
    }

    pub fn clearRect(self: *CanvasBuffer, x: i32, y: i32, w: i32, h: i32) void {
        self.fillRect(x, y, w, h, 0x00000000);
    }

    pub fn strokeRect(self: *CanvasBuffer, x: i32, y: i32, w: i32, h: i32, color: u32, line_width: i32) void {
        // Top edge
        self.fillRect(x, y, w, line_width, color);
        // Bottom edge
        self.fillRect(x, y + h - line_width, w, line_width, color);
        // Left edge
        self.fillRect(x, y, line_width, h, color);
        // Right edge
        self.fillRect(x + w - line_width, y, line_width, h, color);
    }
};

/// Parse a CSS color string to ARGB u32.
pub fn parseColor(color_str: []const u8) u32 {
    const s = std.mem.trim(u8, color_str, " ");
    if (s.len == 0) return 0xFF000000;

    // Hex colors
    if (s[0] == '#') {
        if (s.len == 7) {
            // #RRGGBB
            const r = std.fmt.parseInt(u8, s[1..3], 16) catch 0;
            const g = std.fmt.parseInt(u8, s[3..5], 16) catch 0;
            const b = std.fmt.parseInt(u8, s[5..7], 16) catch 0;
            return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        } else if (s.len == 4) {
            // #RGB
            const r = std.fmt.parseInt(u8, s[1..2], 16) catch 0;
            const g = std.fmt.parseInt(u8, s[2..3], 16) catch 0;
            const b = std.fmt.parseInt(u8, s[3..4], 16) catch 0;
            return 0xFF000000 | (@as(u32, r * 17) << 16) | (@as(u32, g * 17) << 8) | @as(u32, b * 17);
        }
    }

    // Named colors (common ones)
    if (std.mem.eql(u8, s, "black")) return 0xFF000000;
    if (std.mem.eql(u8, s, "white")) return 0xFFFFFFFF;
    if (std.mem.eql(u8, s, "red")) return 0xFFFF0000;
    if (std.mem.eql(u8, s, "green")) return 0xFF008000;
    if (std.mem.eql(u8, s, "blue")) return 0xFF0000FF;
    if (std.mem.eql(u8, s, "yellow")) return 0xFFFFFF00;
    if (std.mem.eql(u8, s, "cyan")) return 0xFF00FFFF;
    if (std.mem.eql(u8, s, "magenta")) return 0xFFFF00FF;
    if (std.mem.eql(u8, s, "orange")) return 0xFFFFA500;
    if (std.mem.eql(u8, s, "gray") or std.mem.eql(u8, s, "grey")) return 0xFF808080;
    if (std.mem.eql(u8, s, "transparent")) return 0x00000000;

    return 0xFF000000; // default black
}

// ── Canvas 2D Context JS Functions ──────────────────────────────────

/// Create a CanvasRenderingContext2D JS object for a canvas element.
pub fn createContext2D(ctx: *qjs.JSContext, width: u32, height: u32) qjs.JSValue {
    const context = qjs.JS_NewObject(ctx);
    if (quickjs.JS_IsException(context)) return context;

    // Create pixel buffer
    const buf = CanvasBuffer.init(width, height) catch return quickjs.JS_NULL();
    // Store buffer pointer as opaque integer
    const buf_ptr = allocator.create(CanvasBuffer) catch return quickjs.JS_NULL();
    buf_ptr.* = buf;

    _ = qjs.JS_SetPropertyStr(ctx, context, "__bufPtr", qjs.JS_NewInt64(ctx, @intCast(@intFromPtr(buf_ptr))));
    _ = qjs.JS_SetPropertyStr(ctx, context, "__width", qjs.JS_NewInt32(ctx, @intCast(width)));
    _ = qjs.JS_SetPropertyStr(ctx, context, "__height", qjs.JS_NewInt32(ctx, @intCast(height)));

    // State
    _ = qjs.JS_SetPropertyStr(ctx, context, "fillStyle", qjs.JS_NewString(ctx, "#000000"));
    _ = qjs.JS_SetPropertyStr(ctx, context, "strokeStyle", qjs.JS_NewString(ctx, "#000000"));
    _ = qjs.JS_SetPropertyStr(ctx, context, "lineWidth", qjs.JS_NewFloat64(ctx, 1.0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "globalAlpha", qjs.JS_NewFloat64(ctx, 1.0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "font", qjs.JS_NewString(ctx, "10px sans-serif"));
    _ = qjs.JS_SetPropertyStr(ctx, context, "textAlign", qjs.JS_NewString(ctx, "start"));
    _ = qjs.JS_SetPropertyStr(ctx, context, "textBaseline", qjs.JS_NewString(ctx, "alphabetic"));

    // Canvas dimensions
    _ = qjs.JS_SetPropertyStr(ctx, context, "canvas", qjs.JS_NewObject(ctx));

    // Drawing methods
    _ = qjs.JS_SetPropertyStr(ctx, context, "fillRect", qjs.JS_NewCFunction(ctx, &ctxFillRect, "fillRect", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "clearRect", qjs.JS_NewCFunction(ctx, &ctxClearRect, "clearRect", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "strokeRect", qjs.JS_NewCFunction(ctx, &ctxStrokeRect, "strokeRect", 4));

    // Path methods (stubs)
    _ = qjs.JS_SetPropertyStr(ctx, context, "beginPath", qjs.JS_NewCFunction(ctx, &ctxNoOp, "beginPath", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "closePath", qjs.JS_NewCFunction(ctx, &ctxNoOp, "closePath", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "moveTo", qjs.JS_NewCFunction(ctx, &ctxNoOp, "moveTo", 2));
    _ = qjs.JS_SetPropertyStr(ctx, context, "lineTo", qjs.JS_NewCFunction(ctx, &ctxNoOp, "lineTo", 2));
    _ = qjs.JS_SetPropertyStr(ctx, context, "arc", qjs.JS_NewCFunction(ctx, &ctxNoOp, "arc", 6));
    _ = qjs.JS_SetPropertyStr(ctx, context, "arcTo", qjs.JS_NewCFunction(ctx, &ctxNoOp, "arcTo", 5));
    _ = qjs.JS_SetPropertyStr(ctx, context, "quadraticCurveTo", qjs.JS_NewCFunction(ctx, &ctxNoOp, "quadraticCurveTo", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "bezierCurveTo", qjs.JS_NewCFunction(ctx, &ctxNoOp, "bezierCurveTo", 6));
    _ = qjs.JS_SetPropertyStr(ctx, context, "rect", qjs.JS_NewCFunction(ctx, &ctxNoOp, "rect", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "fill", qjs.JS_NewCFunction(ctx, &ctxNoOp, "fill", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "stroke", qjs.JS_NewCFunction(ctx, &ctxNoOp, "stroke", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "clip", qjs.JS_NewCFunction(ctx, &ctxNoOp, "clip", 0));

    // Text methods (stubs)
    _ = qjs.JS_SetPropertyStr(ctx, context, "fillText", qjs.JS_NewCFunction(ctx, &ctxNoOp, "fillText", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "strokeText", qjs.JS_NewCFunction(ctx, &ctxNoOp, "strokeText", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "measureText", qjs.JS_NewCFunction(ctx, &ctxMeasureText, "measureText", 1));

    // Transform methods (stubs)
    _ = qjs.JS_SetPropertyStr(ctx, context, "save", qjs.JS_NewCFunction(ctx, &ctxNoOp, "save", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "restore", qjs.JS_NewCFunction(ctx, &ctxNoOp, "restore", 0));
    _ = qjs.JS_SetPropertyStr(ctx, context, "translate", qjs.JS_NewCFunction(ctx, &ctxNoOp, "translate", 2));
    _ = qjs.JS_SetPropertyStr(ctx, context, "rotate", qjs.JS_NewCFunction(ctx, &ctxNoOp, "rotate", 1));
    _ = qjs.JS_SetPropertyStr(ctx, context, "scale", qjs.JS_NewCFunction(ctx, &ctxNoOp, "scale", 2));
    _ = qjs.JS_SetPropertyStr(ctx, context, "setTransform", qjs.JS_NewCFunction(ctx, &ctxNoOp, "setTransform", 6));
    _ = qjs.JS_SetPropertyStr(ctx, context, "resetTransform", qjs.JS_NewCFunction(ctx, &ctxNoOp, "resetTransform", 0));

    // Image methods (stubs)
    _ = qjs.JS_SetPropertyStr(ctx, context, "drawImage", qjs.JS_NewCFunction(ctx, &ctxNoOp, "drawImage", 9));
    _ = qjs.JS_SetPropertyStr(ctx, context, "createImageData", qjs.JS_NewCFunction(ctx, &ctxCreateImageData, "createImageData", 2));
    _ = qjs.JS_SetPropertyStr(ctx, context, "getImageData", qjs.JS_NewCFunction(ctx, &ctxGetImageData, "getImageData", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "putImageData", qjs.JS_NewCFunction(ctx, &ctxNoOp, "putImageData", 7));

    // Gradient/pattern stubs
    _ = qjs.JS_SetPropertyStr(ctx, context, "createLinearGradient", qjs.JS_NewCFunction(ctx, &ctxCreateGradient, "createLinearGradient", 4));
    _ = qjs.JS_SetPropertyStr(ctx, context, "createRadialGradient", qjs.JS_NewCFunction(ctx, &ctxCreateGradient, "createRadialGradient", 6));
    _ = qjs.JS_SetPropertyStr(ctx, context, "createPattern", qjs.JS_NewCFunction(ctx, &ctxCreateGradient, "createPattern", 2));

    return context;
}

fn getBuf(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?*CanvasBuffer {
    const ptr_val = qjs.JS_GetPropertyStr(ctx, this_val, "__bufPtr");
    defer qjs.JS_FreeValue(ctx, ptr_val);
    var ptr_int: i64 = 0;
    _ = qjs.JS_ToInt64(ctx, &ptr_int, ptr_val);
    if (ptr_int == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(ptr_int)));
}

fn getFillColor(ctx: *qjs.JSContext, this_val: qjs.JSValue) u32 {
    const style_val = qjs.JS_GetPropertyStr(ctx, this_val, "fillStyle");
    defer qjs.JS_FreeValue(ctx, style_val);
    const dom_api = @import("dom_api.zig");
    const s = dom_api.jsStringToSlice(ctx, style_val) orelse return 0xFF000000;
    defer qjs.JS_FreeCString(ctx, s.ptr);
    return parseColor(s.ptr[0..s.len]);
}

fn getStrokeColor(ctx: *qjs.JSContext, this_val: qjs.JSValue) u32 {
    const style_val = qjs.JS_GetPropertyStr(ctx, this_val, "strokeStyle");
    defer qjs.JS_FreeValue(ctx, style_val);
    const dom_api = @import("dom_api.zig");
    const s = dom_api.jsStringToSlice(ctx, style_val) orelse return 0xFF000000;
    defer qjs.JS_FreeCString(ctx, s.ptr);
    return parseColor(s.ptr[0..s.len]);
}

fn ctxFillRect(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 4) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const buf = getBuf(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &x, args[0]);
    _ = qjs.JS_ToFloat64(c, &y, args[1]);
    _ = qjs.JS_ToFloat64(c, &w, args[2]);
    _ = qjs.JS_ToFloat64(c, &h, args[3]);
    const color = getFillColor(c, this_val);
    buf.fillRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h), color);
    return quickjs.JS_UNDEFINED();
}

fn ctxClearRect(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 4) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const buf = getBuf(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &x, args[0]);
    _ = qjs.JS_ToFloat64(c, &y, args[1]);
    _ = qjs.JS_ToFloat64(c, &w, args[2]);
    _ = qjs.JS_ToFloat64(c, &h, args[3]);
    buf.clearRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
    return quickjs.JS_UNDEFINED();
}

fn ctxStrokeRect(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 4) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const buf = getBuf(c, this_val) orelse return quickjs.JS_UNDEFINED();
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &x, args[0]);
    _ = qjs.JS_ToFloat64(c, &y, args[1]);
    _ = qjs.JS_ToFloat64(c, &w, args[2]);
    _ = qjs.JS_ToFloat64(c, &h, args[3]);
    const color = getStrokeColor(c, this_val);
    buf.strokeRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h), color, 1);
    return quickjs.JS_UNDEFINED();
}

fn ctxMeasureText(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const metrics = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, metrics, "width", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, metrics, "actualBoundingBoxAscent", qjs.JS_NewFloat64(c, 0));
    _ = qjs.JS_SetPropertyStr(c, metrics, "actualBoundingBoxDescent", qjs.JS_NewFloat64(c, 0));
    return metrics;
}

fn ctxCreateImageData(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    if (argc < 2) return quickjs.JS_NULL();
    const args = argv orelse return quickjs.JS_NULL();
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(c, &w, args[0]);
    _ = qjs.JS_ToFloat64(c, &h, args[1]);
    const iw: u32 = @intFromFloat(@max(w, 1));
    const ih: u32 = @intFromFloat(@max(h, 1));
    const img = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, img, "width", qjs.JS_NewInt32(c, @intCast(iw)));
    _ = qjs.JS_SetPropertyStr(c, img, "height", qjs.JS_NewInt32(c, @intCast(ih)));
    // data: Uint8ClampedArray
    const len = @as(usize, iw) * ih * 4;
    const arr = qjs.JS_NewArrayBufferCopy(c, null, len);
    _ = qjs.JS_SetPropertyStr(c, img, "data", arr);
    return img;
}

fn ctxGetImageData(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    // Same as createImageData for now
    return ctxCreateImageData(ctx, quickjs.JS_UNDEFINED(), argc, argv);
}

fn ctxCreateGradient(ctx: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_NULL();
    const grad = qjs.JS_NewObject(c);
    _ = qjs.JS_SetPropertyStr(c, grad, "addColorStop", qjs.JS_NewCFunction(c, &ctxNoOp, "addColorStop", 2));
    return grad;
}

fn ctxNoOp(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: ?[*]qjs.JSValue) callconv(.c) qjs.JSValue {
    return quickjs.JS_UNDEFINED();
}
