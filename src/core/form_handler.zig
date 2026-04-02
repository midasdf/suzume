/// Form handling module — extracted from main.zig.
/// Handles form element detection, data collection, URL encoding, and submission.
const std = @import("std");
const lxb = @import("../bindings/lexbor.zig").c;
const DomNode = @import("../dom/node.zig").DomNode;
const TextInput = @import("../ui/input.zig").TextInput;
const resolveUrl = @import("../net/loader.zig").resolveUrl;
const Loader = @import("../net/loader.zig").Loader;
const events = @import("../js/events.zig");
const http_status = @import("../net/http_status.zig");

/// Walk up the DOM tree to find a form-relevant element (input, button, textarea, select).
pub fn findFormElement(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    if (isFormElement(node)) return node;

    // Search UP (ancestors) — maybe we clicked on text inside a button
    var current: ?*lxb.lxb_dom_node_t = node.parent;
    var depth: u32 = 0;
    while (current) |n| : (depth += 1) {
        if (depth > 5) break;
        if (isFormElement(n)) return n;
        current = n.parent;
    }

    // Search DOWN (descendants) — maybe we clicked on a div containing an input
    if (findFormElementInChildren(node, 0)) |found| return found;

    return null;
}

pub fn isFormElement(node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const dn = DomNode{ .lxb_node = node };
    const tag = dn.tagName() orelse return false;
    return std.mem.eql(u8, tag, "input") or
        std.mem.eql(u8, tag, "button") or
        std.mem.eql(u8, tag, "textarea") or
        std.mem.eql(u8, tag, "select");
}

pub fn findFormElementInChildren(node: *lxb.lxb_dom_node_t, depth: u32) ?*lxb.lxb_dom_node_t {
    if (depth > 20) return null;
    // First pass: look for text inputs
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |c| {
        if (isTextFormElement(c)) return c;
        child = c.next;
    }
    // Recurse for text inputs
    child = node.first_child;
    while (child) |c| {
        if (findFormElementInChildren(c, depth + 1)) |found| {
            if (isTextFormElement(found)) return found;
        }
        child = c.next;
    }
    // Second pass: any form element
    child = node.first_child;
    while (child) |c| {
        if (isFormElement(c)) return c;
        if (findFormElementInChildren(c, depth + 1)) |found| return found;
        child = c.next;
    }
    return null;
}

pub fn isTextFormElement(node: *lxb.lxb_dom_node_t) bool {
    if (node.type != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const dn = DomNode{ .lxb_node = node };
    // Skip elements with style="display:none"
    if (dn.getAttribute("style")) |inline_style| {
        if (std.mem.indexOf(u8, inline_style, "display:none") != null or
            std.mem.indexOf(u8, inline_style, "display: none") != null)
            return false;
    }
    const tag = dn.tagName() orelse return false;
    if (std.mem.eql(u8, tag, "textarea")) return true;
    if (std.mem.eql(u8, tag, "input")) {
        return isTextInputType(dn.getAttribute("type") orelse "text");
    }
    return false;
}

/// Check if an input type string represents a text-entry input.
pub fn isTextInputType(input_type: []const u8) bool {
    return std.mem.eql(u8, input_type, "text") or std.mem.eql(u8, input_type, "search") or
        std.mem.eql(u8, input_type, "password") or std.mem.eql(u8, input_type, "email") or
        std.mem.eql(u8, input_type, "url") or std.mem.eql(u8, input_type, "tel") or
        std.mem.eql(u8, input_type, "number");
}

/// Check if an input type string represents a button.
pub fn isButtonInputType(input_type: []const u8) bool {
    return std.mem.eql(u8, input_type, "submit") or
        std.mem.eql(u8, input_type, "button") or
        std.mem.eql(u8, input_type, "reset");
}

/// Find the parent <form> element of a given DOM node.
pub fn findParentForm(node: *lxb.lxb_dom_node_t) ?*lxb.lxb_dom_node_t {
    var current: ?*lxb.lxb_dom_node_t = node.parent;
    var depth: u32 = 0;
    while (current) |n| : (depth += 1) {
        if (depth > 50) break;
        if (n.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            const dn = DomNode{ .lxb_node = n };
            if (dn.tagName()) |tag| {
                if (std.mem.eql(u8, tag, "form")) return n;
            }
        }
        current = n.parent;
    }
    return null;
}

/// Extract a query parameter value from a query string like "q=test&foo=bar"
pub fn extractQueryParam(query_string: []const u8, param_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < query_string.len) {
        // First find the segment boundary (next '&' or end of string)
        const amp = std.mem.indexOfScalarPos(u8, query_string, pos, '&') orelse query_string.len;
        const segment = query_string[pos..amp];
        // Then look for '=' within this segment
        if (std.mem.indexOfScalar(u8, segment, '=')) |eq_offset| {
            const name = segment[0..eq_offset];
            if (std.mem.eql(u8, name, param_name)) {
                return segment[eq_offset + 1 ..];
            }
        }
        // Skip segments without '=' (bare flags like "?flag&key=val")
        pos = if (amp < query_string.len) amp + 1 else query_string.len;
    }
    return null;
}

/// URL-encode a string for form submission query parameters.
pub fn urlEncode(allocator: std.mem.Allocator, input_str: []const u8) ?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (input_str) |ch| {
        if (ch == ' ') {
            buf.append(allocator, '+') catch {
                buf.deinit(allocator);
                return null;
            };
        } else if (isUrlSafe(ch)) {
            buf.append(allocator, ch) catch {
                buf.deinit(allocator);
                return null;
            };
        } else {
            buf.append(allocator, '%') catch {
                buf.deinit(allocator);
                return null;
            };
            const hex = "0123456789ABCDEF";
            buf.append(allocator, hex[ch >> 4]) catch {
                buf.deinit(allocator);
                return null;
            };
            buf.append(allocator, hex[ch & 0x0F]) catch {
                buf.deinit(allocator);
                return null;
            };
        }
    }
    return buf.toOwnedSlice(allocator) catch null;
}

/// Check if a character is URL-safe (unreserved per RFC 3986).
pub fn isUrlSafe(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

/// Collect all form input name=value pairs by walking descendants of a form element.
pub fn collectFormData(allocator: std.mem.Allocator, form_node: *lxb.lxb_dom_node_t, focused_node: ?*lxb.lxb_dom_node_t, form_text: *TextInput) ?[]u8 {
    var pairs: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    collectFormDataRecurse(allocator, form_node, focused_node, form_text, &pairs, &first);
    return pairs.toOwnedSlice(allocator) catch {
        pairs.deinit(allocator);
        return null;
    };
}

fn collectFormDataRecurse(
    allocator: std.mem.Allocator,
    node: *lxb.lxb_dom_node_t,
    focused_node: ?*lxb.lxb_dom_node_t,
    form_text: *TextInput,
    pairs: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const dn = DomNode{ .lxb_node = node };
        if (dn.tagName()) |tag| {
            if (std.mem.eql(u8, tag, "textarea")) {
                if (dn.getAttribute("name")) |name| {
                    const value = if (focused_node != null and node == focused_node.?)
                        form_text.getText()
                    else
                        (dn.getAttribute("value") orelse "");

                    appendFormPair(allocator, pairs, first, name, value);
                }
            } else if (std.mem.eql(u8, tag, "input")) {
                const input_type = dn.getAttribute("type") orelse "text";
                if (!std.mem.eql(u8, input_type, "submit") and
                    !std.mem.eql(u8, input_type, "button") and
                    !std.mem.eql(u8, input_type, "reset") and
                    !std.mem.eql(u8, input_type, "image"))
                {
                    if (dn.getAttribute("name")) |name| {
                        const value = if (focused_node != null and node == focused_node.?)
                            form_text.getText()
                        else
                            (dn.getAttribute("value") orelse "");

                        appendFormPair(allocator, pairs, first, name, value);
                    }
                }
            }
        }
    }

    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        collectFormDataRecurse(allocator, ch, focused_node, form_text, pairs, first);
        child = ch.next;
    }
}

fn appendFormPair(allocator: std.mem.Allocator, pairs: *std.ArrayListUnmanaged(u8), first: *bool, name: []const u8, value: []const u8) void {
    const enc_name = urlEncode(allocator, name) orelse return;
    defer allocator.free(enc_name);
    const enc_value = urlEncode(allocator, value) orelse return;
    defer allocator.free(enc_value);

    if (!first.*) {
        pairs.append(allocator, '&') catch return;
    }
    pairs.appendSlice(allocator, enc_name) catch return;
    pairs.append(allocator, '=') catch return;
    pairs.appendSlice(allocator, enc_value) catch return;
    first.* = false;
}

/// Submit a form: collect data, build URL, navigate.
/// Returns the navigation URL (caller must free) or null on failure.
/// The `navigate_fn` callback performs the actual navigation.
pub fn submitForm(
    allocator: std.mem.Allocator,
    form_node: *lxb.lxb_dom_node_t,
    focused_node: ?*lxb.lxb_dom_node_t,
    form_text: *TextInput,
    current_url: ?[]u8,
    loader: *Loader,
    js_rt_ptr: anytype,
    navigate_fn: anytype,
    navigate_ctx: anytype,
) ?[]u8 {
    // Dispatch "submit" event on the form element
    if (js_rt_ptr.*) |*js_rt| {
        const allow = events.dispatchEvent(js_rt.ctx, form_node, "submit");
        js_rt.executePending();
        if (!allow) return null;
    }

    const form_dn = DomNode{ .lxb_node = form_node };
    const action = form_dn.getAttribute("action") orelse "";
    const method_str = form_dn.getAttribute("method") orelse "get";
    const is_post = std.mem.eql(u8, method_str, "post") or std.mem.eql(u8, method_str, "POST");

    std.debug.print("[form] Submitting form method=\"{s}\" action=\"{s}\"\n", .{ method_str, action });

    const query_string = collectFormData(allocator, form_node, focused_node, form_text) orelse return null;
    defer allocator.free(query_string);

    std.debug.print("[form] Form data: {s}\n", .{query_string});

    const base = if (current_url) |u| u else "";
    const resolved_action = resolveUrl(allocator, base, action) catch return null;
    defer allocator.free(resolved_action);

    if (is_post) {
        return handlePostSubmit(allocator, resolved_action, query_string, loader, navigate_fn, navigate_ctx);
    }

    // GET: append query string to URL
    return handleGetSubmit(allocator, resolved_action, query_string, navigate_fn, navigate_ctx);
}

fn handlePostSubmit(
    allocator: std.mem.Allocator,
    resolved_action: [:0]const u8,
    query_string: []u8,
    loader: *Loader,
    navigate_fn: anytype,
    navigate_ctx: anytype,
) ?[]u8 {
    const url_z = allocator.allocSentinel(u8, resolved_action.len, 0) catch return null;
    @memcpy(url_z, resolved_action);

    std.debug.print("[form] POST to: {s}\n", .{resolved_action});

    var headers_arr = [_][2][]const u8{
        .{ "Content-Type", "application/x-www-form-urlencoded" },
    };
    var response = loader.client.request(allocator, url_z, .{
        .method = "POST",
        .body = query_string,
        .headers = &headers_arr,
        .timeout_secs = 15,
    }) catch {
        allocator.free(url_z);
        return null;
    };

    // Check for redirect (3xx)
    if (http_status.isRedirect(response.status_code)) {
        response.deinit();
        if (navigate_fn(navigate_ctx, url_z)) {
            const final_url = allocator.dupe(u8, resolved_action) catch {
                allocator.free(url_z);
                return null;
            };
            allocator.free(url_z);
            return final_url;
        }
        allocator.free(url_z);
        return null;
    }

    response.deinit();
    // For non-redirect POST, navigate to action URL
    if (navigate_fn(navigate_ctx, url_z)) {
        const final_url = allocator.dupe(u8, resolved_action) catch {
            allocator.free(url_z);
            return null;
        };
        allocator.free(url_z);
        return final_url;
    }
    allocator.free(url_z);
    return null;
}

fn handleGetSubmit(
    allocator: std.mem.Allocator,
    resolved_action: [:0]const u8,
    query_string: []u8,
    navigate_fn: anytype,
    navigate_ctx: anytype,
) ?[]u8 {
    var final_url_buf: std.ArrayListUnmanaged(u8) = .empty;
    final_url_buf.appendSlice(allocator, resolved_action) catch return null;

    if (query_string.len > 0) {
        if (std.mem.indexOf(u8, resolved_action, "?") != null) {
            final_url_buf.append(allocator, '&') catch {
                final_url_buf.deinit(allocator);
                return null;
            };
        } else {
            final_url_buf.append(allocator, '?') catch {
                final_url_buf.deinit(allocator);
                return null;
            };
        }
        final_url_buf.appendSlice(allocator, query_string) catch {
            final_url_buf.deinit(allocator);
            return null;
        };
    }

    const final_url = final_url_buf.toOwnedSlice(allocator) catch {
        final_url_buf.deinit(allocator);
        return null;
    };
    const url_z = allocator.allocSentinel(u8, final_url.len, 0) catch {
        allocator.free(final_url);
        return null;
    };
    @memcpy(url_z, final_url);

    std.debug.print("[form] Navigating to: {s}\n", .{final_url});

    if (navigate_fn(navigate_ctx, url_z)) {
        allocator.free(url_z);
        return final_url;
    } else {
        allocator.free(url_z);
        allocator.free(final_url);
        return null;
    }
}
