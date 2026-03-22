const std = @import("std");
const DomNode = @import("../dom/node.zig").DomNode;
const NodeType = @import("../dom/node.zig").NodeType;
const ComputedStyle = @import("../css/computed.zig").ComputedStyle;
const cascade_mod = @import("../css/cascade.zig");
const Box = @import("box.zig").Box;
const BoxType = @import("box.zig").BoxType;
const lxb = @import("../bindings/lexbor.zig").c;

// Lexbor serialization for inline <svg> outerHTML
const lxb_html_serialize_cb_f = ?*const fn (data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t;
extern fn lxb_html_serialize_tree_cb(node: *lxb.lxb_dom_node_t, cb: lxb_html_serialize_cb_f, ctx: ?*anyopaque) lxb.lxb_status_t;

fn svgSerializeCallback(data: ?[*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) lxb.lxb_status_t {
    if (len == 0) return 0;
    const list: *std.ArrayListUnmanaged(u8) = @ptrCast(@alignCast(ctx orelse return 1));
    const d = data orelse return 1;
    list.appendSlice(std.heap.c_allocator, d[0..len]) catch return 1;
    return 0;
}

/// Build a box tree from a DOM node and its resolved styles.
/// Returns the root Box for the body element.
/// Replace "currentColor" in SVG markup with an actual hex color value.
/// lunasvg doesn't support the CSS currentColor keyword.
fn replaceSvgCurrentColor(buf: *std.ArrayListUnmanaged(u8), color: u32) void {
    const r: u8 = @intCast((color >> 16) & 0xFF);
    const g: u8 = @intCast((color >> 8) & 0xFF);
    const b: u8 = @intCast(color & 0xFF);
    var hex_buf: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch return;

    // Search and replace all occurrences of "currentColor" (12 chars) with "#rrggbb" (7 chars)
    const needle = "currentColor";
    var i: usize = 0;
    while (i + needle.len <= buf.items.len) {
        if (std.mem.eql(u8, buf.items[i .. i + needle.len], needle)) {
            // Replace in-place: "currentColor" (12) → "#rrggbb" (7) + shift left by 5
            @memcpy(buf.items[i .. i + 7], &hex_buf);
            const shift = needle.len - 7;
            std.mem.copyForwards(u8, buf.items[i + 7 ..], buf.items[i + needle.len .. buf.items.len]);
            buf.items.len -= shift;
            i += 7;
        } else {
            i += 1;
        }
    }
}

/// Resolve counter() and counters() functions in CSS content values.
/// Returns a new string with counter values substituted, or null if no counters found.
fn resolveContentCounters(content: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    // Quick check: does it contain "counter("?
    if (std.mem.indexOf(u8, content, "counter(") == null) return null;

    var result = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;

    while (i < content.len) {
        // Look for counter(
        if (i + 8 <= content.len and std.mem.eql(u8, content[i .. i + 8], "counter(")) {
            i += 8;
            // Find closing paren
            const close = std.mem.indexOfScalarPos(u8, content, i, ')') orelse {
                i += 1;
                continue;
            };
            const counter_name = std.mem.trim(u8, content[i..close], " \t'\"");
            const val = css_counters.get(counter_name) orelse 0;
            var buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
            result.appendSlice(std.heap.c_allocator, num_str) catch {};
            i = close + 1;
        } else {
            result.append(std.heap.c_allocator, content[i]) catch {};
            i += 1;
        }
    }

    if (result.items.len == 0) return null;

    // Copy to allocator
    const out = allocator.alloc(u8, result.items.len) catch {
        result.deinit(std.heap.c_allocator);
        return null;
    };
    @memcpy(out, result.items);
    result.deinit(std.heap.c_allocator);
    return out;
}

/// CSS counter state (reset on each buildBoxTree call).
var css_counters: std.StringHashMapUnmanaged(i32) = .empty;

pub fn buildBoxTree(
    body_node: DomNode,
    styles: *const cascade_mod.CascadeResult,
    allocator: std.mem.Allocator,
) !*Box {
    // Reset CSS counters for this build
    css_counters.clearRetainingCapacity();

    const root_box = try allocator.create(Box);
    root_box.* = .{};
    root_box.box_type = .block;
    root_box.dom_node = body_node;

    // Apply body style
    if (styles.getStyle(body_node)) |s| {
        root_box.style = s;
    }

    // Build children
    try buildChildren(root_box, body_node, styles, allocator, null, 0);

    // Wrap mixed inline/block children in anonymous blocks
    try wrapInlineChildren(root_box, allocator);

    return root_box;
}

/// Determine if a display value is inline-level.
fn isInlineDisplay(display: ComputedStyle.Display) bool {
    return display == .inline_ or display == .inline_block or display == .inline_flex;
}

/// Check if a box is inline-level (inline_text, inline_box, or replaced with inline display).
fn isInlineLevelBox(box: *const Box) bool {
    return box.box_type == .inline_text or box.box_type == .inline_box or
        (box.box_type == .replaced and isInlineDisplay(box.style.display));
}

/// After building children, wrap consecutive inline children of a block
/// parent into anonymous block boxes so the block layout sees only block children.
fn wrapInlineChildren(parent: *Box, allocator: std.mem.Allocator) !void {
    // First, recursively process children
    for (parent.children.items) |child| {
        if (child.box_type == .block or child.box_type == .anonymous_block or child.box_type == .inline_box) {
            try wrapInlineChildren(child, allocator);
        }
    }

    // Only wrap if this is a block-level container
    if (parent.box_type != .block and parent.box_type != .anonymous_block) return;

    // For flex/grid containers, ALL inline children must be wrapped in anonymous blocks
    // (CSS spec: "Each in-flow child of a flex container becomes a flex item")
    const is_flex_or_grid = parent.style.display == .flex or parent.style.display == .inline_flex or
        parent.style.display == .grid or parent.style.display == .inline_grid;

    // Check if we have a mix of inline and block children
    var has_inline = false;
    var has_block = false;
    for (parent.children.items) |child| {
        if (isInlineLevelBox(child)) {
            has_inline = true;
        } else {
            has_block = true;
        }
    }

    // For flex/grid: force wrapping if any inline children exist
    // For block: only wrap if mixed inline+block
    if (!has_inline) return;
    if (!is_flex_or_grid and !has_block) return;

    // Mixed: wrap consecutive inline runs in anonymous blocks
    var new_children: @TypeOf(parent.children) = .empty;
    var current_anon: ?*Box = null;

    for (parent.children.items) |child| {
        if (isInlineLevelBox(child)) {
            // Add to current anonymous block (create if needed)
            if (current_anon == null) {
                const anon = try allocator.create(Box);
                anon.* = .{};
                anon.box_type = .anonymous_block;
                anon.style = parent.style;
                anon.style.display = .block; // anonymous blocks are always block-level
                anon.style.background_color = 0x00000000; // transparent
                // Reset box-model properties (anonymous blocks don't have their own margins/padding)
                anon.style.margin_top = 0;
                anon.style.margin_right = 0;
                anon.style.margin_bottom = 0;
                anon.style.margin_left = 0;
                anon.style.padding_top = 0;
                anon.style.padding_right = 0;
                anon.style.padding_bottom = 0;
                anon.style.padding_left = 0;
                anon.style.width = .auto;
                anon.style.height = .auto;
                anon.parent = parent;
                current_anon = anon;
                try new_children.append(allocator, anon);
            }
            child.parent = current_anon.?;
            try current_anon.?.children.append(allocator, child);
        } else {
            // Block child: flush current anon and add directly
            current_anon = null;
            try new_children.append(allocator, child);
        }
    }

    parent.children.deinit(allocator); // free old list buffer (children are moved to new_children)
    parent.children = new_children;
}

fn buildChildren(
    parent_box: *Box,
    dom_node: DomNode,
    styles: *const cascade_mod.CascadeResult,
    allocator: std.mem.Allocator,
    inherited_link: ?[]const u8,
    list_counter_start: u32,
) !void {
    var child_opt = dom_node.firstChild();
    var list_counter: u32 = list_counter_start;
    while (child_opt) |child| {
        defer child_opt = child.nextSibling();

        switch (child.nodeType()) {
            .element => {
                // Get style; skip display:none elements
                const style = styles.getStyle(child) orelse ComputedStyle{};
                if (style.display == .none) continue;

                // display: contents — skip box generation, add children directly to parent
                if (style.display == .contents) {
                    try buildChildren(parent_box, child, styles, allocator, inherited_link, 0);
                    continue;
                }

                // Skip elements with HTML hidden attribute or aria-hidden="true"
                if (child.getAttribute("hidden") != null) continue;
                if (child.getAttribute("aria-hidden")) |ah| {
                    if (std.mem.eql(u8, ah, "true")) continue;
                }

                // Skip closed <details> children (except <summary>)
                if (child.tagName()) |tag| {
                    if (std.mem.eql(u8, tag, "details")) {
                        // Check if open attribute is set
                        if (child.getAttribute("open") == null) {
                            // Closed details: only show <summary>, hide rest
                            // We handle this by skipping the details content below
                        }
                    }
                }

                const child_box = try allocator.create(Box);
                child_box.* = .{};
                child_box.dom_node = child;
                child_box.style = style;
                child_box.parent = parent_box;

                // Determine box type from display
                child_box.box_type = switch (style.display) {
                    .block, .list_item, .flex, .grid, .inline_grid => .block,
                    .table => .block,
                    .table_row, .table_cell, .table_row_group,
                    .table_header_group, .table_footer_group,
                    .table_column, .table_column_group, .table_caption => .block,
                    .inline_block, .inline_flex => .inline_box,
                    .inline_ => .inline_box,
                    else => .block,
                };

                // Apply margin/padding from style
                child_box.margin = .{
                    .top = style.margin_top,
                    .right = style.margin_right,
                    .bottom = style.margin_bottom,
                    .left = style.margin_left,
                };
                child_box.padding = .{
                    .top = style.padding_top,
                    .right = style.padding_right,
                    .bottom = style.padding_bottom,
                    .left = style.padding_left,
                };
                child_box.border = .{
                    .top = style.border_top_width,
                    .right = style.border_right_width,
                    .bottom = style.border_bottom_width,
                    .left = style.border_left_width,
                };

                // Check if this is an <a> element with href
                var link_url = inherited_link;
                if (child.tagName()) |tag| {
                    if (std.mem.eql(u8, tag, "a")) {
                        if (child.getAttribute("href")) |href| {
                            link_url = href;
                            // Use UA default link color only if cascade didn't set a specific color
                            if (!child_box.style.color_set_by_css) {
                                child_box.style.color = 0xFF0000EE;
                            }
                        }
                    }

                    // Handle <img> elements as replaced boxes
                    if (std.mem.eql(u8, tag, "img")) {
                        const img_src = child.getAttribute("src");

                        child_box.box_type = .replaced;
                        child_box.image_url = img_src;

                        // If no src attribute, use minimal placeholder size
                        const has_src = img_src != null;
                        var img_w: f32 = if (has_src) 300 else 0; // default placeholder
                        var img_h: f32 = if (has_src) 150 else 0;
                        if (child.getAttribute("width")) |w_str| {
                            img_w = parseFloatAttr(w_str);
                        }
                        if (child.getAttribute("height")) |h_str| {
                            img_h = parseFloatAttr(h_str);
                        }
                        child_box.intrinsic_width = img_w;
                        child_box.intrinsic_height = img_h;
                    }

                    // Handle inline <svg> elements — rasterize via lunasvg
                    if (std.mem.eql(u8, tag, "svg")) {
                        // Serialize SVG DOM subtree to string
                        var svg_buf: std.ArrayListUnmanaged(u8) = .empty;
                        _ = lxb_html_serialize_tree_cb(child.lxb_node, &svgSerializeCallback, @ptrCast(&svg_buf));

                        // Replace fill="currentColor" with actual CSS color value
                        // lunasvg doesn't understand currentColor
                        if (svg_buf.items.len > 0) {
                            replaceSvgCurrentColor(&svg_buf, style.color);
                        }

                        if (svg_buf.items.len > 0) {
                            // Store as data:image/svg+xml, URL
                            const prefix = "data:image/svg+xml,";
                            const url_buf = allocator.alloc(u8, prefix.len + svg_buf.items.len) catch {
                                svg_buf.deinit(std.heap.c_allocator);
                                continue;
                            };
                            @memcpy(url_buf[0..prefix.len], prefix);
                            @memcpy(url_buf[prefix.len..], svg_buf.items);
                            svg_buf.deinit(std.heap.c_allocator);

                            child_box.box_type = .replaced;
                            child_box.image_url = url_buf;

                            // Get intrinsic dimensions from SVG attributes
                            // Priority: CSS width/height > HTML width/height > viewBox > default
                            var svg_w: f32 = 0;
                            var svg_h: f32 = 0;
                            var has_explicit_dims = false;

                            // Check HTML width/height attributes first
                            if (child.getAttribute("width")) |w_str| {
                                const w = parseFloatAttr(w_str);
                                if (w > 0) { svg_w = w; has_explicit_dims = true; }
                            }
                            if (child.getAttribute("height")) |h_str| {
                                const h = parseFloatAttr(h_str);
                                if (h > 0) { svg_h = h; has_explicit_dims = true; }
                            }

                            // Fall back to viewBox if no explicit width/height
                            if (!has_explicit_dims or svg_w <= 0 or svg_h <= 0) {
                                if (child.getAttribute("viewBox") orelse child.getAttribute("viewbox")) |vb| {
                                    var vb_it = std.mem.tokenizeAny(u8, vb, " ,");
                                    _ = vb_it.next(); // min-x
                                    _ = vb_it.next(); // min-y
                                    if (vb_it.next()) |w_tok| {
                                        if (std.fmt.parseFloat(f32, w_tok)) |w| {
                                            if (svg_w <= 0) svg_w = w;
                                        } else |_| {}
                                    }
                                    if (vb_it.next()) |h_tok| {
                                        if (std.fmt.parseFloat(f32, h_tok)) |h| {
                                            if (svg_h <= 0) svg_h = h;
                                        } else |_| {}
                                    }
                                }
                            }

                            // Default fallback
                            if (svg_w <= 0) svg_w = 100;
                            if (svg_h <= 0) svg_h = 100;

                            // CSS width/height override if explicitly set
                            if (child_box.style.width != .auto) {
                                if (child_box.style.width == .px) svg_w = child_box.style.width.px;
                            }
                            if (child_box.style.height != .auto) {
                                if (child_box.style.height == .px) svg_h = child_box.style.height.px;
                            }
                            child_box.intrinsic_width = svg_w;
                            child_box.intrinsic_height = svg_h;
                        } else {
                            svg_buf.deinit(std.heap.c_allocator);
                        }
                        // Don't recurse into SVG children
                        child_box.parent = parent_box;
                        try parent_box.children.append(allocator, child_box);
                        continue;
                    }

                    // Handle <br> as a line break — empty block with line-height spacing
                    if (std.mem.eql(u8, tag, "br")) {
                        child_box.box_type = .block;
                        child_box.style.display = .block;
                        // Give it one line's height to create a visual break
                        child_box.style.height = .{ .px = child_box.style.font_size_px };
                    }

                    // Handle <hr> as a special replaced element
                    if (std.mem.eql(u8, tag, "hr")) {
                        child_box.is_hr = true;
                    }

                    // Handle <input> elements — skip hidden, show value/placeholder for others
                    if (std.mem.eql(u8, tag, "input")) {
                        const input_type = child.getAttribute("type") orelse "text";
                        if (std.mem.eql(u8, input_type, "hidden")) {
                            // Skip hidden inputs entirely
                            continue;
                        }
                        // Checkbox / radio — render as inline marker
                        if (std.mem.eql(u8, input_type, "checkbox") or std.mem.eql(u8, input_type, "radio")) {
                            child_box.box_type = .inline_box;
                            child_box.style.display = .inline_block;
                            const is_checked = child.getAttribute("checked") != null;
                            const is_radio = std.mem.eql(u8, input_type, "radio");
                            const marker = if (is_radio)
                                (if (is_checked) "\xe2\x97\x89" else "\xe2\x97\x8b") // ◉ / ○
                            else
                                (if (is_checked) "\xe2\x98\x91" else "\xe2\x98\x90"); // ☑ / ☐
                            const marker_box = try allocator.create(Box);
                            marker_box.* = Box{};
                            marker_box.box_type = .inline_text;
                            marker_box.style = child_box.style;
                            marker_box.text = marker;
                            marker_box.parent = child_box;
                            try child_box.children.append(allocator, marker_box);
                            child_box.padding = .{ .top = 0, .right = 4, .bottom = 0, .left = 0 };
                            child_box.border = .{};
                            // Skip the normal input rendering
                            try parent_box.children.append(allocator, child_box);
                            try buildChildren(child_box, child, styles, allocator, link_url, list_counter);
                            continue;
                        }
                        {
                            child_box.box_type = .inline_box;
                            child_box.style.display = .inline_block;
                            // Compute submit/button/reset flag early for default styling
                            const is_button = std.mem.eql(u8, input_type, "submit") or
                                std.mem.eql(u8, input_type, "button") or
                                std.mem.eql(u8, input_type, "reset");

                            // Add default styling for form inputs (only when CSS hasn't explicitly set)
                            if (child_box.style.background_color == 0x00000000) {
                                child_box.style.background_color = if (is_button) 0xFFecedee else 0xFFFFFFFF;
                            }
                            // Default padding for inputs (only if CSS didn't set padding)
                            if (!child_box.style.padding_set_by_css) {
                                if (is_button) {
                                    child_box.padding.top = 6;
                                    child_box.padding.bottom = 6;
                                    child_box.padding.left = 16;
                                    child_box.padding.right = 16;
                                } else {
                                    child_box.padding.top = 2;
                                    child_box.padding.bottom = 2;
                                    child_box.padding.left = 4;
                                    child_box.padding.right = 4;
                                }
                            }
                            // Default border for inputs (only if CSS didn't set border)
                            if (!child_box.style.border_set_by_css) {
                                child_box.border.top = 1;
                                child_box.border.bottom = 1;
                                child_box.border.left = 1;
                                child_box.border.right = 1;
                                if (is_button) {
                                    child_box.style.border_top_color = 0xFFc0c0c0;
                                    child_box.style.border_bottom_color = 0xFF808080;
                                    child_box.style.border_left_color = 0xFFc0c0c0;
                                    child_box.style.border_right_color = 0xFF808080;
                                } else {
                                    child_box.style.border_top_color = 0xFF767676;
                                    child_box.style.border_bottom_color = 0xFF767676;
                                    child_box.style.border_left_color = 0xFF767676;
                                    child_box.style.border_right_color = 0xFF767676;
                                }
                            }
                            // Default text color for buttons (dark text on light background)
                            if (is_button and !child_box.style.color_set_by_css) {
                                child_box.style.color = 0xFF1f1f1f;
                            }
                            // Default border-radius for button-type inputs (6px, modern browser default)
                            if (is_button and child_box.style.border_radius_tl == 0 and
                                child_box.style.border_radius_tr == 0 and
                                child_box.style.border_radius_bl == 0 and
                                child_box.style.border_radius_br == 0)
                            {
                                child_box.style.border_radius_tl = 6;
                                child_box.style.border_radius_tr = 6;
                                child_box.style.border_radius_bl = 6;
                                child_box.style.border_radius_br = 6;
                            }

                            // Default border-radius for text inputs (4px)
                            if (!is_button and child_box.style.border_radius_tl == 0 and
                                child_box.style.border_radius_tr == 0)
                            {
                                child_box.style.border_radius_tl = 4;
                                child_box.style.border_radius_tr = 4;
                                child_box.style.border_radius_bl = 4;
                                child_box.style.border_radius_br = 4;
                            }

                            // Compute width from size attribute or type
                            if (child_box.style.width == .auto) {
                                if (is_button) {
                                    // Submit/button: sized to text content + padding
                                    const btn_text = child.getAttribute("value") orelse
                                        (if (std.mem.eql(u8, input_type, "reset")) "Reset" else "Submit");
                                    const char_width: f32 = child_box.style.font_size_px * 0.6;
                                    const text_w = char_width * @as(f32, @floatFromInt(btn_text.len));
                                    child_box.style.width = .{ .px = text_w }; // content width = text width; padding is separate
                                } else {
                                    // Text/password/etc: width from size attr (default 20 chars)
                                    const size_attr = child.getAttribute("size");
                                    const size_val: f32 = if (size_attr) |s| parseFloatAttr(s) else 20;
                                    const char_width: f32 = child_box.style.font_size_px * 0.6;
                                    child_box.style.width = .{ .px = size_val * char_width };
                                }
                            }

                            // Create text child for value or placeholder
                            const display_text = child.getAttribute("value") orelse
                                (child.getAttribute("placeholder") orelse "");
                            if (display_text.len > 0) {
                                const text_box = try allocator.create(Box);
                                text_box.* = .{};
                                text_box.box_type = .inline_text;
                                text_box.text = display_text;
                                text_box.parent = child_box;
                                text_box.style = child_box.style;
                                // Placeholder text is dimmer
                                if (child.getAttribute("value") == null) {
                                    text_box.style.color = 0xFFA9A9A9; // overlay0
                                }
                                try child_box.children.append(allocator, text_box);
                            }
                        }
                    }

                    // Handle <button> elements — inline-block with padding
                    if (std.mem.eql(u8, tag, "button")) {
                        child_box.box_type = .inline_box;
                        child_box.style.display = .inline_block;
                        if (child_box.style.background_color == 0x00000000) {
                            child_box.style.background_color = 0xFFFFFFFF; // surface0
                        }
                        if (child_box.padding.top == 0 and child_box.padding.bottom == 0) {
                            child_box.padding.top = 4;
                            child_box.padding.bottom = 4;
                            child_box.padding.left = 16;
                            child_box.padding.right = 16;
                        }
                        if (child_box.border.top == 0 and child_box.border.bottom == 0) {
                            child_box.border.top = 1;
                            child_box.border.bottom = 1;
                            child_box.border.left = 1;
                            child_box.border.right = 1;
                            child_box.style.border_top_color = 0xFF767676;
                            child_box.style.border_bottom_color = 0xFF767676;
                            child_box.style.border_left_color = 0xFF767676;
                            child_box.style.border_right_color = 0xFF767676;
                        }
                        // Default border-radius for buttons (6px, modern browser default)
                        if (child_box.style.border_radius_tl == 0 and
                            child_box.style.border_radius_tr == 0 and
                            child_box.style.border_radius_bl == 0 and
                            child_box.style.border_radius_br == 0)
                        {
                            child_box.style.border_radius_tl = 6;
                            child_box.style.border_radius_tr = 6;
                            child_box.style.border_radius_bl = 6;
                            child_box.style.border_radius_br = 6;
                        }
                    }

                    // Handle <option> inside <select> — hide (only selected value shown on select)
                    if (std.mem.eql(u8, tag, "option") or std.mem.eql(u8, tag, "optgroup")) {
                        continue; // Skip — select shows only its value
                    }

                    // Handle <select> elements — inline-block with default width
                    if (std.mem.eql(u8, tag, "select")) {
                        child_box.box_type = .inline_box;
                        child_box.style.display = .inline_block;
                        if (child_box.style.background_color == 0x00000000) {
                            child_box.style.background_color = 0xFFFFFFFF; // surface0
                        }
                        if (child_box.padding.top == 0 and child_box.padding.bottom == 0) {
                            child_box.padding.top = 2;
                            child_box.padding.bottom = 2;
                            child_box.padding.left = 4;
                            child_box.padding.right = 20; // space for dropdown arrow
                        }
                        if (child_box.border.top == 0 and child_box.border.bottom == 0) {
                            child_box.border.top = 1;
                            child_box.border.bottom = 1;
                            child_box.border.left = 1;
                            child_box.border.right = 1;
                            child_box.style.border_top_color = 0xFF767676;
                            child_box.style.border_bottom_color = 0xFF767676;
                            child_box.style.border_left_color = 0xFF767676;
                            child_box.style.border_right_color = 0xFF767676;
                        }
                        if (child_box.style.width == .auto) {
                            // Default width: ~15 chars + arrow space
                            const char_width: f32 = child_box.style.font_size_px * 0.6;
                            child_box.style.width = .{ .px = 15 * char_width + 20 };
                        }
                        // Default border-radius for selects
                        if (child_box.style.border_radius_tl == 0) {
                            child_box.style.border_radius_tl = 4;
                            child_box.style.border_radius_tr = 4;
                            child_box.style.border_radius_bl = 4;
                            child_box.style.border_radius_br = 4;
                        }
                    }

                    // Add selected option text as child of select
                    if (std.mem.eql(u8, tag, "select")) {
                        // Find the selected option's text (or first option)
                        const select_text = blk: {
                            var first_text: ?[]const u8 = null;
                            var opt_child = child.firstChild();
                            while (opt_child) |oc| : (opt_child = oc.nextSibling()) {
                                if (oc.nodeType() != .element) continue;
                                const opt_tag = oc.tagName() orelse continue;
                                if (!std.mem.eql(u8, opt_tag, "option")) continue;
                                const opt_text = oc.textContent() orelse continue;
                                if (first_text == null) first_text = opt_text;
                                if (oc.getAttribute("selected") != null) {
                                    break :blk opt_text;
                                }
                            }
                            break :blk first_text;
                        };
                        if (select_text) |st| {
                            const text_box = try allocator.create(Box);
                            text_box.* = Box{};
                            text_box.box_type = .inline_text;
                            text_box.style = child_box.style;
                            text_box.text = st;
                            text_box.parent = child_box;
                            try child_box.children.append(allocator, text_box);
                        }
                    }

                    // Handle <textarea> elements — block with rows/cols sizing
                    if (std.mem.eql(u8, tag, "textarea")) {
                        if (child_box.style.background_color == 0x00000000) {
                            child_box.style.background_color = 0xFFFFFFFF; // surface0
                        }
                        if (child_box.padding.top == 0 and child_box.padding.bottom == 0) {
                            child_box.padding.top = 4;
                            child_box.padding.bottom = 4;
                            child_box.padding.left = 4;
                            child_box.padding.right = 4;
                        }
                        if (child_box.border.top == 0 and child_box.border.bottom == 0) {
                            child_box.border.top = 1;
                            child_box.border.bottom = 1;
                            child_box.border.left = 1;
                            child_box.border.right = 1;
                            child_box.style.border_top_color = 0xFF767676;
                            child_box.style.border_bottom_color = 0xFF767676;
                            child_box.style.border_left_color = 0xFF767676;
                            child_box.style.border_right_color = 0xFF767676;
                        }
                        const char_width: f32 = child_box.style.font_size_px * 0.6;
                        const line_h: f32 = child_box.style.font_size_px * 1.4;
                        if (child_box.style.width == .auto) {
                            const cols_attr = child.getAttribute("cols");
                            const cols: f32 = if (cols_attr) |s| parseFloatAttr(s) else 20;
                            child_box.style.width = .{ .px = cols * char_width };
                        }
                        if (child_box.style.height == .auto) {
                            const rows_attr = child.getAttribute("rows");
                            const rows: f32 = if (rows_attr) |s| parseFloatAttr(s) else 2;
                            child_box.style.height = .{ .px = rows * line_h };
                        }
                    }

                    // Track list item counters
                    if (style.display == .list_item) {
                        list_counter += 1;
                        child_box.list_index = list_counter;
                    }
                }
                child_box.link_url = link_url;

                // Recurse into children (skip for replaced/void elements)
                const skip_recurse = child_box.box_type == .replaced or
                    (if (child.tagName()) |tag|
                    (std.mem.eql(u8, tag, "input") or
                        std.mem.eql(u8, tag, "br") or
                        std.mem.eql(u8, tag, "hr") or
                        std.mem.eql(u8, tag, "select"))
                else
                    false);
                // Process CSS counters (counter-reset, counter-increment)
                if (style.counter_reset) |cr| {
                    const name = std.mem.trim(u8, cr, " \t");
                    if (name.len > 0) {
                        css_counters.put(std.heap.c_allocator, name, 0) catch {};
                    }
                }
                if (style.counter_increment) |ci| {
                    const name = std.mem.trim(u8, ci, " \t");
                    if (name.len > 0) {
                        if (css_counters.getPtr(name)) |val| {
                            val.* += 1;
                        } else {
                            css_counters.put(std.heap.c_allocator, name, 1) catch {};
                        }
                    }
                }

                if (!skip_recurse) {
                    // Insert ::before pseudo-element as first child
                    // Evaluate counter() in content value
                    const resolved_before = if (style.before_content) |bc|
                        resolveContentCounters(bc, allocator)
                    else
                        null;
                    if (resolved_before orelse style.before_content) |before_content| {
                        const before_box = try allocator.create(Box);
                        before_box.* = .{};
                        before_box.parent = child_box;
                        before_box.style = style;
                        before_box.style.display = style.before_display;
                        before_box.box_type = if (style.before_display == .block) .block else .inline_text;
                        before_box.text = before_content;
                        before_box.link_url = link_url;
                        try child_box.children.append(allocator, before_box);
                    }

                    // If this is an ordered/unordered list, start counter at 0
                    const sub_counter: u32 = if (child.tagName()) |tag| blk: {
                        if (std.mem.eql(u8, tag, "ol") or std.mem.eql(u8, tag, "ul")) {
                            break :blk 0;
                        }
                        break :blk list_counter;
                    } else list_counter;

                    // Closed <details>: only build <summary> children
                    const is_closed_details = if (child.tagName()) |tag|
                        std.mem.eql(u8, tag, "details") and child.getAttribute("open") == null
                    else
                        false;

                    if (is_closed_details) {
                        // Only add <summary> child, skip everything else
                        var detail_child = child.firstChild();
                        while (detail_child) |dc| {
                            defer detail_child = dc.nextSibling();
                            if (dc.nodeType() == .element) {
                                if (dc.tagName()) |dtag| {
                                    if (std.mem.eql(u8, dtag, "summary")) {
                                        const summary_style = styles.getStyle(dc) orelse ComputedStyle{};
                                        const summary_box = try allocator.create(Box);
                                        summary_box.* = .{};
                                        summary_box.dom_node = dc;
                                        summary_box.style = summary_style;
                                        summary_box.box_type = .block;
                                        summary_box.parent = child_box;
                                        summary_box.link_url = link_url;
                                        try buildChildren(summary_box, dc, styles, allocator, link_url, 0);
                                        try child_box.children.append(allocator, summary_box);
                                        break;
                                    }
                                }
                            }
                        }
                    } else {
                        try buildChildren(child_box, child, styles, allocator, link_url, sub_counter);
                    }

                    // Insert ::after pseudo-element as last child
                    const resolved_after = if (style.after_content) |ac|
                        resolveContentCounters(ac, allocator)
                    else
                        null;
                    if (resolved_after orelse style.after_content) |after_content| {
                        const after_box = try allocator.create(Box);
                        after_box.* = .{};
                        after_box.parent = child_box;
                        after_box.style = style;
                        after_box.style.display = style.after_display;
                        after_box.box_type = if (style.after_display == .block) .block else .inline_text;
                        after_box.text = after_content;
                        after_box.link_url = link_url;
                        try child_box.children.append(allocator, after_box);
                    }
                }

                try parent_box.children.append(allocator, child_box);
            },
            .text => {
                const text = child.textContent() orelse continue;

                // Handle white-space property
                const is_pre = parent_box.style.white_space == .pre or
                    parent_box.style.white_space == .pre_wrap;

                if (is_pre) {
                    // In pre mode, preserve whitespace (but still skip completely empty)
                    if (text.len == 0) continue;

                    // Apply text-transform even in pre mode
                    const display_text = if (parent_box.style.text_transform != .none)
                        applyTextTransform(text, parent_box.style.text_transform, allocator) catch text
                    else
                        text;

                    const text_box = try allocator.create(Box);
                    text_box.* = .{};
                    text_box.box_type = .inline_text;
                    text_box.text = display_text;
                    text_box.parent = parent_box;
                    text_box.style = parent_box.style;
                    text_box.link_url = inherited_link;

                    if (inherited_link != null and !text_box.style.color_set_by_css) {
                        text_box.style.color = 0xFF0000EE;
                    }

                    try parent_box.children.append(allocator, text_box);
                } else {
                    // Normal mode: collapse whitespace
                    // 1. Whitespace-only text nodes → single space (for inter-element spacing)
                    //    but skip if parent is block-level with no inline siblings
                    const trimmed = std.mem.trim(u8, text, " \t\n\r");
                    if (trimmed.len == 0) {
                        // Keep as single space for inter-element spacing.
                        // This preserves whitespace between inline siblings in block containers
                        // (e.g., <p>text <span>a</span> <span>b</span></p>)
                        // Only keep if previous child is inline (avoids extra spacing between blocks)
                        const prev_is_inline = blk: {
                            const items = parent_box.children.items;
                            if (items.len == 0) break :blk false;
                            const last = items[items.len - 1];
                            break :blk (last.box_type == .inline_text or last.box_type == .inline_box);
                        };
                        if (prev_is_inline or
                            parent_box.style.display == .inline_ or parent_box.style.display == .inline_block or
                            parent_box.style.display == .inline_flex or parent_box.style.display == .table_cell)
                        {
                            const space_box = try allocator.create(Box);
                            space_box.* = .{};
                            space_box.box_type = .inline_text;
                            space_box.text = " ";
                            space_box.parent = parent_box;
                            space_box.style = parent_box.style;
                            space_box.link_url = inherited_link;
                            try parent_box.children.append(allocator, space_box);
                        }
                        continue;
                    }

                    // 2. Collapse internal whitespace: replace runs of
                    //    whitespace (spaces, tabs, newlines) with single space
                    const collapsed = collapseWhitespace(text, allocator) catch |err| {
                        std.debug.print("[layout] collapseWhitespace failed: {}\n", .{err});
                        continue;
                    };

                    // 3. Apply text-transform
                    const transformed = if (parent_box.style.text_transform != .none)
                        applyTextTransform(collapsed, parent_box.style.text_transform, allocator) catch collapsed
                    else
                        collapsed;

                    const text_box = try allocator.create(Box);
                    text_box.* = .{};
                    text_box.box_type = .inline_text;
                    text_box.text = transformed;
                    text_box.parent = parent_box;
                    // Inherit style from parent
                    text_box.style = parent_box.style;
                    text_box.link_url = inherited_link;

                    // If inside a link, override color to link blue
                    if (inherited_link != null and !text_box.style.color_set_by_css) {
                        text_box.style.color = 0xFF0000EE;
                    }

                    try parent_box.children.append(allocator, text_box);
                }
            },
            else => {},
        }
    }
}

/// Apply CSS text-transform to a string.
fn applyTextTransform(text: []const u8, transform: ComputedStyle.TextTransform, allocator: std.mem.Allocator) ![]const u8 {
    switch (transform) {
        .uppercase => {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (text) |ch| {
                try buf.append(allocator, std.ascii.toUpper(ch));
            }
            return buf.toOwnedSlice(allocator);
        },
        .lowercase => {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (text) |ch| {
                try buf.append(allocator, std.ascii.toLower(ch));
            }
            return buf.toOwnedSlice(allocator);
        },
        .capitalize => {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            var after_space = true;
            for (text) |ch| {
                if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                    after_space = true;
                    try buf.append(allocator, ch);
                } else {
                    if (after_space) {
                        try buf.append(allocator, std.ascii.toUpper(ch));
                    } else {
                        try buf.append(allocator, ch);
                    }
                    after_space = false;
                }
            }
            return buf.toOwnedSlice(allocator);
        },
        .none => return try allocator.dupe(u8, text),
    }
}

/// Collapse whitespace in text: replace runs of whitespace with single space.
/// Preserves a leading space if the original text started with whitespace
/// (needed for inter-element spacing in inline formatting context).
fn collapseWhitespace(text: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Check if text starts with whitespace — preserve as single space
    const starts_with_ws = text.len > 0 and (text[0] == ' ' or text[0] == '\t' or text[0] == '\n' or text[0] == '\r');

    var in_ws = true; // start true to collapse leading whitespace
    for (text) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!in_ws) {
                try buf.append(allocator, ' ');
                in_ws = true;
            }
        } else {
            // If first non-ws char and original started with ws, prepend space
            if (buf.items.len == 0 and starts_with_ws) {
                try buf.append(allocator, ' ');
            }
            try buf.append(allocator, ch);
            in_ws = false;
        }
    }

    // Keep trailing space — it may be needed for inter-element spacing
    // in inline formatting context. The line breaker will handle trailing
    // whitespace at line ends.
    return buf.toOwnedSlice(allocator);
}

/// Parse a numeric attribute string (e.g. "300" or "150.5") to f32.
fn parseFloatAttr(s: []const u8) f32 {
    // Parse digits and optional decimal point
    var result: f32 = 0;
    var frac: f32 = 0;
    var frac_div: f32 = 1;
    var in_frac = false;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            if (in_frac) {
                frac_div *= 10;
                frac += @as(f32, @floatFromInt(ch - '0')) / frac_div;
            } else {
                result = result * 10 + @as(f32, @floatFromInt(ch - '0'));
            }
        } else if (ch == '.') {
            in_frac = true;
        } else {
            break; // stop at non-numeric (e.g. "px")
        }
    }
    return result + frac;
}
