pub const c = @cImport({
    @cInclude("quickjs.h");
});

/// Construct JS_UNDEFINED value (tag = JS_TAG_UNDEFINED, val = 0)
/// The C macro uses a designated initializer that Zig's cImport can't translate.
pub fn JS_UNDEFINED() c.JSValue {
    return c.JSValue{
        .u = .{ .int32 = 0 },
        .tag = c.JS_TAG_UNDEFINED,
    };
}

/// Construct JS_NULL value
pub fn JS_NULL() c.JSValue {
    return c.JSValue{
        .u = .{ .int32 = 0 },
        .tag = c.JS_TAG_NULL,
    };
}

/// Construct JS_EXCEPTION value
pub fn JS_EXCEPTION() c.JSValue {
    return c.JSValue{
        .u = .{ .int32 = 0 },
        .tag = c.JS_TAG_EXCEPTION,
    };
}

/// Check if a JSValue is an exception
pub fn JS_IsException(v: c.JSValue) bool {
    return v.tag == c.JS_TAG_EXCEPTION;
}

/// Check if a JSValue is undefined
pub fn JS_IsUndefined(v: c.JSValue) bool {
    return v.tag == c.JS_TAG_UNDEFINED;
}

/// Check if a JSValue is null
pub fn JS_IsNull(v: c.JSValue) bool {
    return v.tag == c.JS_TAG_NULL;
}

/// Construct a JS boolean value (workaround for cImport bool translation issues).
pub fn JS_NewBool(val: bool) c.JSValue {
    return c.JSValue{
        .u = .{ .int32 = if (val) 1 else 0 },
        .tag = c.JS_TAG_BOOL,
    };
}
