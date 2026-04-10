// DOM HTML Serialization — innerHTML/outerHTML getter/setter
// Extracted from dom_api.zig for modularity.

const std = @import("std");
const quickjs = @import("../bindings/quickjs.zig");
const qjs = quickjs.c;
const lxb = @import("../bindings/lexbor.zig").c;
const api = @import("dom_api.zig");
const events = @import("events.zig");

// Lexbor HTML serialization
const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_serialize_deep_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;
extern fn lxb_html_document_parse_fragment(document: *anyopaque, element: *lxb.lxb_dom_element_t, html: [*]const u8, size: usize) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_child(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_remove(node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_destroy(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_insert_before(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;
extern fn lxb_dom_node_insert_after(to: *lxb.lxb_dom_node_t, node: *lxb.lxb_dom_node_t) void;

// ── Serialization Accumulator ──────────────────────────────────────

pub const SerializeAccum = struct {
    buf: []u8,
    pos: usize,
    overflow: bool,
    heap_buf: ?[]u8,

    pub fn init(stack_buf: []u8) SerializeAccum {
        return .{ .buf = stack_buf, .pos = 0, .overflow = false, .heap_buf = null };
    }

    pub fn deinit(self: *SerializeAccum) void {
        if (self.heap_buf) |hb| std.heap.c_allocator.free(hb);
    }

    pub fn result(self: *SerializeAccum) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn append(self: *SerializeAccum, data: []const u8) bool {
        if (self.pos + data.len > self.buf.len) {
            const new_size = @max(self.buf.len * 2, self.pos + data.len + 1024);
            const new_buf = std.heap.c_allocator.alloc(u8, new_size) catch return false;
            @memcpy(new_buf[0..self.pos], self.buf[0..self.pos]);
            if (self.heap_buf) |old| std.heap.c_allocator.free(old);
            self.heap_buf = new_buf;
            self.buf = new_buf;
        }
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
        return true;
    }
};

pub fn serializeCallback(data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    if (len == 0) return 0;
    const accum: *SerializeAccum = @ptrCast(@alignCast(ctx orelse return 1));
    const d = data orelse return 1;
    _ = accum.append(d[0..len]);
    return 0;
}

// ── innerHTML getter ────────────────────────────────────────────────

pub fn elementGetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        _ = lxb_html_serialize_tree_cb(ch, &serializeCallback, @ptrCast(&accum));
        child = ch.next;
    }
    const html = accum.result();
    return qjs.JS_NewStringLen(c, html.ptr, html.len);
}

// ── innerHTML setter ────────────────────────────────────────────────

pub fn elementSetInnerHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_UNDEFINED();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const s = api.jsStringToSlice(c, args[0]) orelse {
        // null/undefined → clear children
        // Collect removed nodes for MutationObserver
        var removed_buf: [64]*lxb.lxb_dom_node_t = undefined;
        var removed_count: usize = 0;
        {
            var ch: ?*lxb.lxb_dom_node_t = node.first_child;
            while (ch) |child| {
                if (removed_count < removed_buf.len) {
                    removed_buf[removed_count] = child;
                    removed_count += 1;
                }
                ch = child.next;
            }
        }
        removeAllChildren(node);
        events.recordMutationChildListBulk(node, &.{}, removed_buf[0..removed_count], null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    };
    defer qjs.JS_FreeCString(c, s.ptr);

    // Collect removed nodes for MutationObserver
    var removed_buf: [64]*lxb.lxb_dom_node_t = undefined;
    var removed_count: usize = 0;
    {
        var ch: ?*lxb.lxb_dom_node_t = node.first_child;
        while (ch) |child| {
            if (removed_count < removed_buf.len) {
                removed_buf[removed_count] = child;
                removed_count += 1;
            }
            ch = child.next;
        }
    }

    // Remove existing children
    removeAllChildren(node);

    // Parse fragment
    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    if (s.len > 0) {
        const frag = lxb_html_document_parse_fragment(doc, elem, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();
        // Move children from fragment to element
        moveChildren(frag, node);
        _ = lxb_dom_node_destroy(frag);
    }

    // Collect added nodes for MutationObserver
    var added_buf: [64]*lxb.lxb_dom_node_t = undefined;
    var added_count: usize = 0;
    {
        var ch: ?*lxb.lxb_dom_node_t = node.first_child;
        while (ch) |child| {
            if (added_count < added_buf.len) {
                added_buf[added_count] = child;
                added_count += 1;
            }
            ch = child.next;
        }
    }
    events.recordMutationChildListBulk(node, added_buf[0..added_count], removed_buf[0..removed_count], null, null);
    api.setDomDirty();
    // Execute scripts in new content
    maybeExecuteScriptsInSubtree(c, node);
    return quickjs.JS_UNDEFINED();
}

// ── outerHTML getter ────────────────────────────────────────────────

pub fn elementGetOuterHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return qjs.JS_NewStringLen(c, "", 0);
    var stack_buf: [8192]u8 = undefined;
    var accum = SerializeAccum.init(&stack_buf);
    defer accum.deinit();
    _ = lxb_html_serialize_tree_cb(node, &serializeCallback, @ptrCast(&accum));
    const html = accum.result();
    return qjs.JS_NewStringLen(c, html.ptr, html.len);
}

// ── outerHTML setter ────────────────────────────────────────────────

pub fn elementSetOuterHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_UNDEFINED();
    const parent = node.parent orelse return quickjs.JS_UNDEFINED();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    if (s.len == 0) {
        lxb_dom_node_remove(node);
        events.recordMutationChildListBulk(parent, &.{}, &.{node}, null, null);
        api.setDomDirty();
        return quickjs.JS_UNDEFINED();
    }

    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, s.ptr, s.len) orelse return quickjs.JS_UNDEFINED();

    // Collect fragment's children before moving (these will be the addedNodes)
    var added_buf: [64]*lxb.lxb_dom_node_t = undefined;
    var added_count: usize = 0;
    {
        var ch: ?*lxb.lxb_dom_node_t = frag.first_child;
        while (ch) |child| {
            if (added_count < added_buf.len) {
                added_buf[added_count] = child;
                added_count += 1;
            }
            ch = child.next;
        }
    }

    // Insert all fragment children before this node, then remove this node
    moveChildrenBefore(frag, node);
    _ = lxb_dom_node_destroy(frag);
    lxb_dom_node_remove(node);
    events.recordMutationChildListBulk(parent, added_buf[0..added_count], &.{node}, null, null);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── insertAdjacentHTML ──────────────────────────────────────────────

pub fn elementInsertAdjacentHTML(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 2) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const node = api.getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return quickjs.JS_UNDEFINED();
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const pos_s = api.jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, pos_s.ptr);
    const html_s = api.jsStringToSlice(c, args[1]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, html_s.ptr);

    if (html_s.len == 0) return quickjs.JS_UNDEFINED();

    const doc = api.getDocument(c) orelse return quickjs.JS_UNDEFINED();
    const frag = lxb_html_document_parse_fragment(doc, elem, html_s.ptr, html_s.len) orelse return quickjs.JS_UNDEFINED();

    const position = pos_s.ptr[0..pos_s.len];
    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        moveChildrenBefore(frag, node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        if (node.first_child) |fc| {
            moveChildrenBefore(frag, fc);
        } else {
            moveChildren(frag, node);
        }
    } else if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        moveChildren(frag, node);
    } else if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        moveChildrenAfter(frag, node);
    }
    _ = lxb_dom_node_destroy(frag);
    api.setDomDirty();
    return quickjs.JS_UNDEFINED();
}

// ── Helpers ─────────────────────────────────────────────────────────

fn removeAllChildren(node: *lxb.lxb_dom_node_t) void {
    while (node.first_child) |child| {
        lxb_dom_node_remove(child);
    }
}

fn moveChildren(from: *lxb.lxb_dom_node_t, to: *lxb.lxb_dom_node_t) void {
    while (from.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_child(to, child);
    }
}

fn moveChildrenBefore(from: *lxb.lxb_dom_node_t, before: *lxb.lxb_dom_node_t) void {
    while (from.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_before(before, child);
    }
}

fn moveChildrenAfter(from: *lxb.lxb_dom_node_t, after_node: *lxb.lxb_dom_node_t) void {
    var anchor = after_node;
    while (from.first_child) |child| {
        lxb_dom_node_remove(child);
        lxb_dom_node_insert_after(anchor, child);
        anchor = child;
    }
}

fn maybeExecuteScriptsInSubtree(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) void {
    // Walk subtree and execute any <script> elements
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (ch.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const js_val = api.wrapNode(ctx, ch);
            api.maybeExecuteDynamicScriptPublic(ctx, ch, js_val);
            qjs.JS_FreeValue(ctx, js_val);
            maybeExecuteScriptsInSubtree(ctx, ch);
        }
        child = ch.next;
    }
}
