const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const selectors = @import("selectors.zig");
const properties = @import("properties.zig");
const values = @import("values.zig");
const media = @import("media.zig");
const variables = @import("variables.zig");
const util = @import("util.zig");
const computed_mod = @import("computed.zig");
const dom = @import("../dom/node.zig");
const bloom_mod = @import("bloom.zig");

const SelectorBloomFilter = bloom_mod.SelectorBloomFilter;

const ComputedStyle = computed_mod.ComputedStyle;
const DomNode = dom.DomNode;
const PropertyId = ast.PropertyId;
const Declaration = ast.Declaration;
const VarMap = variables.VarMap;

pub const StyleMap = std.AutoHashMap(usize, ComputedStyle);

// ── Style sharing cache ────────────────────────────────────────────────
// When two elements share the same tag, class, id, inline style, and their
// parent's computed style is equivalent, they will produce identical computed
// styles. Cache and reuse to skip redundant cascade work (~30% win per Stylo).

const StyleCacheKey = struct {
    tag_hash: u32,
    class_hash: u32,
    id_hash: u32,
    inline_hash: u32,
    parent_hash: u32,
};

const StyleCacheEntry = struct {
    style: ComputedStyle,
    // Store actual attribute values for collision verification
    tag: ?[]const u8,
    class: ?[]const u8,
    id: ?[]const u8,
    inline_style: ?[]const u8,
};

pub const StyleCache = std.AutoHashMap(StyleCacheKey, StyleCacheEntry);

/// Compare two optional strings for equality (null == null, "a" == "a").
fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn hashAttr(s: ?[]const u8) u32 {
    const str = s orelse return 0;
    var h: u32 = 0;
    for (str) |c| h = h *% 31 +% @as(u32, c);
    return h;
}

fn hashParentStyle(ps: ?*const ComputedStyle) u32 {
    const p = ps orelse return 0;
    // Mix a few inherited properties that most affect child style.
    var h: u32 = @as(u32, @bitCast(p.font_size_px)) *% 2654435761;
    h ^= p.color *% 7;
    h ^= @as(u32, @intFromEnum(p.display)) *% 13;
    // Hash line_height union: tag + payload bits
    const lh_tag: u32 = @intFromEnum(p.line_height);
    const lh_val: u32 = switch (p.line_height) {
        .normal => 0,
        .px => |v| @bitCast(v),
        .number => |v| @bitCast(v),
    };
    h ^= (lh_tag *% 17) ^ (lh_val *% 19);
    h ^= @as(u32, @intFromEnum(p.text_align)) *% 23;
    h ^= @as(u32, p.font_weight) *% 29;
    h ^= @as(u32, @intFromEnum(p.font_style)) *% 31;
    h ^= @as(u32, @intFromEnum(p.white_space)) *% 37;
    h ^= @as(u32, @intFromEnum(p.visibility)) *% 41;
    h ^= @as(u32, @intFromEnum(p.list_style_type)) *% 43;
    return h;
}

pub const CascadeResult = struct {
    styles: StyleMap,
    arena: std.heap.ArenaAllocator,

    pub fn getStyle(self: *const CascadeResult, node: DomNode) ?ComputedStyle {
        return self.styles.get(@intFromPtr(node.lxb_node));
    }

    pub fn deinit(self: *CascadeResult) void {
        self.styles.deinit();
        self.arena.deinit();
    }
};

/// Minimal user-agent default stylesheet (standard browser defaults).
const ua_stylesheet_text =
    \\html { color: #000000; }
    \\body { margin: 8px; color: #000000; }
    \\html, body, div, section, article, aside, nav, main,
    \\header, footer, h1, h2, h3, h4, h5, h6, p, blockquote,
    \\dl, dt, dd, figure, figcaption, form, fieldset,
    \\hr, address, details, summary { display: block; }
    \\head, style, script, link, meta, title, template { display: none; }
    \\table { display: table; }
    \\tr { display: table-row; }
    \\td { display: table-cell; padding: 1px; text-align: left; }
    \\th { display: table-cell; padding: 1px; }
    \\th { font-weight: bold; text-align: center; }
    \\thead { display: table-header-group; }
    \\tbody { display: table-row-group; }
    \\tfoot { display: table-footer-group; }
    \\col { display: table-column; }
    \\colgroup { display: table-column-group; }
    \\caption { display: table-caption; }
    \\ul, ol { display: block; padding-left: 40px; margin-top: 1em; margin-bottom: 1em; }
    \\ol { list-style-type: decimal; }
    \\li { display: list-item; }
    \\h1 { font-size: 2em; font-weight: bold; margin-top: 0.67em; margin-bottom: 0.67em; }
    \\h2 { font-size: 1.5em; font-weight: bold; margin-top: 0.83em; margin-bottom: 0.83em; }
    \\h3 { font-size: 1.17em; font-weight: bold; margin-top: 1em; margin-bottom: 1em; }
    \\h4 { font-weight: bold; margin-top: 1.33em; margin-bottom: 1.33em; }
    \\h5 { font-size: 0.83em; font-weight: bold; margin-top: 1.67em; margin-bottom: 1.67em; }
    \\h6 { font-size: 0.67em; font-weight: bold; margin-top: 2.33em; margin-bottom: 2.33em; }
    \\b, strong { font-weight: bold; display: inline; }
    \\em, i { font-style: italic; display: inline; }
    \\a { color: #0000EE; text-decoration: underline; display: inline; }
    \\span, u, s, del, ins, q, cite, dfn, var, kbd, samp, time, mark,
    \\data, output, wbr, ruby, rt, rp, bdi, bdo, label { display: inline; }
    \\pre { white-space: pre; font-family: monospace; }
    \\code { font-family: monospace; display: inline; white-space: pre; }
    \\pre { margin-top: 1em; margin-bottom: 1em; padding: 8px; }
    \\hr { border-top-width: 1px; margin-top: 8px; margin-bottom: 8px; }
    \\p { margin-top: 1em; margin-bottom: 1em; }
    \\blockquote { margin-left: 40px; margin-right: 40px; margin-top: 1em; margin-bottom: 1em;
    \\  padding-left: 12px; }
    \\button { display: inline-block; padding: 4px; }
    \\input, textarea { display: inline-block; padding: 4px; }
    \\select { display: inline-block; padding: 4px; }
    \\small { font-size: 0.83em; }
    \\sub, sup { font-size: 0.75em; }
    \\abbr { text-decoration: underline; }
    \\center { display: block; text-align: center; margin-left: auto; margin-right: auto; }
    \\noscript { display: none; }
    \\details { display: block; }
    \\summary { display: block; }
    \\dialog { display: none; }
    \\template { display: none; }
;

// ── Inherited properties ─────────────────────────────────────────────
// These properties inherit from parent by default when not explicitly set.
const inherited_properties = [_]PropertyId{
    .color,
    .font_size,
    .font_family,
    .font_weight,
    .font_style,
    .line_height,
    .letter_spacing,
    .text_align,
    .text_decoration,
    .text_transform,
    .white_space,
    .word_break,
    .overflow_wrap,
    .visibility,
    .list_style_type,
    .text_overflow,
};

fn isInherited(prop: PropertyId) bool {
    for (inherited_properties) |p| {
        if (p == prop) return true;
    }
    return false;
}

// ── Cascade priority for sorting declarations ─────────────────────────

const Origin = enum(u8) {
    ua = 0,
    author = 1,
    inline_ = 2,
};

const CascadeEntry = struct {
    decl: Declaration,
    specificity: u32,
    source_order: u32,
    origin: Origin,

    fn priority(self: CascadeEntry) u64 {
        // Sort key: important bit (63), origin (56-62), specificity (24-55), source_order (0-23)
        // Per CSS Cascading Level 5: for !important declarations, specificity order is REVERSED
        // (lower specificity wins, so we invert the specificity bits to make lower spec sort higher).
        var p: u64 = 0;
        if (self.decl.important) {
            p |= @as(u64, 1) << 63;
            p |= @as(u64, @intFromEnum(self.origin)) << 56;
            // Inverted specificity: lower specificity → higher sort position → wins
            p |= @as(u64, 0xFFFFFFFF - self.specificity) << 24;
        } else {
            p |= @as(u64, @intFromEnum(self.origin)) << 56;
            p |= @as(u64, self.specificity) << 24;
        }
        p |= @as(u64, @min(self.source_order, 0xFFFFFF));
        return p;
    }
};

fn cascadeEntryLessThan(_: void, a: CascadeEntry, b: CascadeEntry) bool {
    return a.priority() < b.priority();
}

// ── Main cascade function ─────────────────────────────────────────────

pub fn cascade(
    doc_root: DomNode,
    allocator: std.mem.Allocator,
    external_css: ?[]const u8,
    viewport_width: u32,
    viewport_height: u32,
) !CascadeResult {
    var result = CascadeResult{
        .styles = StyleMap.init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer result.deinit();

    const arena = result.arena.allocator();
    const vw: f32 = @floatFromInt(viewport_width);
    const vh: f32 = @floatFromInt(viewport_height);

    // 1. Parse UA stylesheet
    var ua_parser = parser_mod.Parser.init(ua_stylesheet_text, arena);
    const ua_sheet = try ua_parser.parse();

    // 2. Collect DOM <style> text
    const dom_css = try collectStyleText(doc_root, arena);

    // 3. Combine external + DOM CSS
    var combined_css: []const u8 = "";
    if (external_css) |ext| {
        if (dom_css.len > 0) {
            const buf = try arena.alloc(u8, ext.len + 1 + dom_css.len);
            @memcpy(buf[0..ext.len], ext);
            buf[ext.len] = '\n';
            @memcpy(buf[ext.len + 1 ..], dom_css);
            combined_css = buf;
        } else {
            combined_css = ext;
        }
    } else {
        combined_css = dom_css;
    }

    // 4. Parse author stylesheet
    var author_parser = parser_mod.Parser.init(combined_css, arena);
    const author_sheet = try author_parser.parse();

    // 5. Flatten @media rules and collect applicable style rules
    var ua_rules: std.ArrayList(FlatRule) = .empty;
    try flattenRules(ua_sheet.rules, vw, vh, &ua_rules, arena);

    var author_rules: std.ArrayList(FlatRule) = .empty;
    try flattenRules(author_sheet.rules, vw, vh, &author_rules, arena);

    // 6. Root VarMap (empty — per-element scoping builds VarMaps during walk)
    var root_vars = VarMap.init(arena);

    // 7. Build rule indices
    var ua_index = try buildFlatRuleIndex(ua_rules.items, arena);
    var author_index = try buildFlatRuleIndex(author_rules.items, arena);

    // 8. Walk DOM tree and compute styles
    var root_bloom = SelectorBloomFilter.init();
    var style_cache = StyleCache.init(arena);
    try walkAndCompute(
        doc_root,
        null,
        &result.styles,
        &ua_index,
        &author_index,
        &root_vars,
        vw,
        vh,
        arena,
        &root_bloom,
        &style_cache,
    );

    return result;
}

// ── Flattened rule (after @media evaluation) ──────────────────────────

const FlatRule = struct {
    selectors: []ast.Selector,
    declarations: []Declaration,
    source_order: u32,
};

fn flattenRules(
    rules: []const ast.Rule,
    vw: f32,
    vh: f32,
    out: *std.ArrayList(FlatRule),
    arena: std.mem.Allocator,
) !void {
    for (rules) |rule| {
        switch (rule) {
            .style => |sr| {
                // Store original declarations — shorthand expansion deferred to applyDeclaration
                try out.append(arena, .{
                    .selectors = sr.selectors,
                    .declarations = sr.declarations,
                    .source_order = sr.source_order,
                });
            },
            .media => |mr| {
                if (media.evaluateMediaQuery(mr.query.raw, vw, vh)) {
                    try flattenRules(mr.rules, vw, vh, out, arena);
                }
            },
            else => {},
        }
    }
}

// ── Simple flat rule index ────────────────────────────────────────────

const FlatRuleIndex = struct {
    by_id: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IndexedFlatRule)),
    by_class: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IndexedFlatRule)),
    by_tag: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IndexedFlatRule)),
    universal: std.ArrayListUnmanaged(IndexedFlatRule),
};

const IndexedFlatRule = struct {
    selector: selectors.ParsedSelector,
    declarations: []const Declaration,
    source_order: u32,
};

fn buildFlatRuleIndex(rules: []const FlatRule, arena: std.mem.Allocator) !FlatRuleIndex {
    var index = FlatRuleIndex{
        .by_id = .{},
        .by_class = .{},
        .by_tag = .{},
        .universal = .{},
    };

    for (rules) |rule| {
        for (rule.selectors) |sel| {
            const trimmed = std.mem.trim(u8, sel.source, " \t\r\n");
            if (selectors.parseSelector(trimmed, arena)) |parsed| {
                const indexed = IndexedFlatRule{
                    .selector = parsed,
                    .declarations = rule.declarations,
                    .source_order = rule.source_order,
                };
                const key = findKeySelector(parsed.components);
                switch (key) {
                    .id => |id| {
                        const list_ptr = try index.by_id.getOrPutValue(arena, id, .{});
                        try list_ptr.value_ptr.append(arena, indexed);
                    },
                    .class => |cls| {
                        const list_ptr = try index.by_class.getOrPutValue(arena, cls, .{});
                        try list_ptr.value_ptr.append(arena, indexed);
                    },
                    .type_sel => |tag| {
                        const list_ptr = try index.by_tag.getOrPutValue(arena, tag, .{});
                        try list_ptr.value_ptr.append(arena, indexed);
                    },
                    else => {
                        try index.universal.append(arena, indexed);
                    },
                }
            }
        }
    }

    return index;
}

fn findKeySelector(components: []const selectors.SelectorComponent) selectors.SimpleSelector {
    var i: usize = components.len;
    while (i > 0) {
        i -= 1;
        switch (components[i]) {
            .simple => |s| return s,
            .combinator => continue,
        }
    }
    return .universal;
}

// ── DOM adapter for selector matching ─────────────────────────────────

fn makeDomAdapter(node: DomNode) selectors.ElementAdapter {
    return .{
        .ptr = @ptrCast(node.lxb_node),
        .vtable = &dom_vtable,
    };
}

const dom_vtable = selectors.ElementAdapter.VTable{
    .tagName = domTagName,
    .getAttribute = domGetAttribute,
    .parent = domParent,
    .previousElementSibling = domPrevSibling,
    .nextElementSibling = domNextSibling,
    .firstChild = domFirstChild,
    .isDocumentNode = domIsDocument,
};

fn domTagName(ptr: *const anyopaque) ?[]const u8 {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    return node.tagName();
}

fn domGetAttribute(ptr: *const anyopaque, name: []const u8) ?[]const u8 {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    return node.getAttribute(name);
}

fn domParent(ptr: *const anyopaque) ?selectors.ElementAdapter {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    if (node.parent()) |p| return makeDomAdapter(p);
    return null;
}

fn domPrevSibling(ptr: *const anyopaque) ?selectors.ElementAdapter {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    // Walk backwards through siblings to find previous element
    const lxb = @import("../bindings/lexbor.zig").c;
    var sib = node.lxb_node.prev;
    while (sib != null) {
        const s = sib.?;
        if (s.*.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            return makeDomAdapter(DomNode{ .lxb_node = s });
        }
        sib = s.*.prev;
    }
    return null;
}

fn domNextSibling(ptr: *const anyopaque) ?selectors.ElementAdapter {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    const lxb = @import("../bindings/lexbor.zig").c;
    var sib = node.lxb_node.next;
    while (sib != null) {
        const s = sib.?;
        if (s.*.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
            return makeDomAdapter(DomNode{ .lxb_node = s });
        }
        sib = s.*.next;
    }
    return null;
}

fn domFirstChild(ptr: *const anyopaque) ?selectors.ElementAdapter {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    if (node.firstElementChild()) |c| return makeDomAdapter(c);
    return null;
}

fn domIsDocument(ptr: *const anyopaque) bool {
    const node = DomNode{ .lxb_node = @constCast(@ptrCast(@alignCast(ptr))) };
    return node.nodeType() == .document;
}

// ── Tree walk and style computation ───────────────────────────────────

fn walkAndCompute(
    node: DomNode,
    parent_style: ?*const ComputedStyle,
    styles: *StyleMap,
    ua_index: *const FlatRuleIndex,
    author_index: *const FlatRuleIndex,
    var_map: *const VarMap,
    vw: f32,
    vh: f32,
    arena: std.mem.Allocator,
    parent_bloom: *const SelectorBloomFilter,
    style_cache: *StyleCache,
) !void {
    if (node.nodeType() == .element) {
        // Build bloom filter: copy parent's filter and add this element's
        // tag name, id, and class names. This accumulates ancestor info
        // so children can quickly reject descendant selectors.
        var element_bloom = parent_bloom.*;
        if (node.tagName()) |tag| {
            element_bloom.add(SelectorBloomFilter.hashStringLower(tag));
        }
        if (node.getAttribute("id")) |id| {
            element_bloom.add(SelectorBloomFilter.hashString(id));
        }
        if (node.getAttribute("class")) |cls| {
            var cls_iter = std.mem.splitScalar(u8, cls, ' ');
            while (cls_iter.next()) |c| {
                if (c.len > 0) element_bloom.add(SelectorBloomFilter.hashString(c));
            }
        }

        // ── Style sharing cache lookup ─────────────────────────────────
        // Elements with identical attributes and equivalent parent style
        // will produce the same computed style — skip the full cascade.
        const node_tag = node.tagName();
        const node_class = node.getAttribute("class");
        const node_id = node.getAttribute("id");
        const node_inline = node.getAttribute("style");
        const cache_key = StyleCacheKey{
            .tag_hash = hashAttr(node_tag),
            .class_hash = hashAttr(node_class),
            .id_hash = hashAttr(node_id),
            .inline_hash = hashAttr(node_inline),
            .parent_hash = hashParentStyle(parent_style),
        };
        // Only use cache when no custom properties in scope and no HTML presentational attrs
        const has_presentational = node.getAttribute("bgcolor") != null or
            node.getAttribute("width") != null or
            node.getAttribute("height") != null or
            node.getAttribute("align") != null or
            node.getAttribute("valign") != null;
        const can_use_cache = (var_map.parent == null) and !has_presentational;
        if (can_use_cache) {
            if (style_cache.get(cache_key)) |entry| {
                // Verify full string match to prevent hash collision crashes
                if (optionalEql(entry.tag, node_tag) and
                    optionalEql(entry.class, node_class) and
                    optionalEql(entry.id, node_id) and
                    optionalEql(entry.inline_style, node_inline))
                {
                    try styles.put(@intFromPtr(node.lxb_node), entry.style);
                    var cached_copy = entry.style;
                    var child = node.firstChild();
                    while (child) |c| {
                        try walkAndCompute(c, &cached_copy, styles, ua_index, author_index, var_map, vw, vh, arena, &element_bloom, style_cache);
                        child = c.nextSibling();
                    }
                    return;
                }
                // Hash collision — fall through to full cascade
            }
        }

        var style = ComputedStyle{};

        // Inherit from parent
        if (parent_style) |ps| {
            inheritAll(&style, ps);
        }

        // Collect matching declarations
        var entries: std.ArrayList(CascadeEntry) = .empty;

        // UA rules (null = non-pseudo-element rules only)
        try collectMatching(node, ua_index, .ua, &entries, arena, null, &element_bloom);
        // Author rules
        try collectMatching(node, author_index, .author, &entries, arena, null, &element_bloom);
        // Inline style
        if (node.getAttribute("style")) |inline_style| {
            try collectInlineDecls(inline_style, &entries, arena);
        }

        // Sort by cascade priority
        std.mem.sort(CascadeEntry, entries.items, {}, cascadeEntryLessThan);

        // Build per-element VarMap: collect --* declarations from matching rules.
        // If this element declares custom properties, create a child VarMap inheriting
        // from parent. Otherwise, reuse parent VarMap (zero allocation).
        var element_var_map = var_map;
        var has_custom_props = false;
        for (entries.items) |entry| {
            if (entry.decl.property == .custom and entry.decl.property_name.len >= 2 and
                entry.decl.property_name[0] == '-' and entry.decl.property_name[1] == '-')
            {
                has_custom_props = true;
                break;
            }
        }
        var child_var_map_storage: VarMap = undefined;
        if (has_custom_props) {
            child_var_map_storage = VarMap.init(arena);
            child_var_map_storage.parent = var_map;
            for (entries.items) |entry| {
                if (entry.decl.property == .custom and entry.decl.property_name.len >= 2 and
                    entry.decl.property_name[0] == '-' and entry.decl.property_name[1] == '-')
                {
                    child_var_map_storage.set(entry.decl.property_name, entry.decl.value_raw) catch {};
                }
            }
            element_var_map = &child_var_map_storage;
        }

        // Apply in order (lowest priority first, last write wins for same property)
        const parent_fs = if (parent_style) |ps| ps.font_size_px else 16.0;
        for (entries.items) |entry| {
            applyDeclaration(&style, entry.decl, element_var_map, parent_style, parent_fs, vw, vh, arena);
        }

        // Apply HTML presentational attributes as fallback (lowest priority)
        applyHtmlAttributes(node, &style);

        // Compute ::before pseudo-element style
        if (computePseudoContent(node, &style, ua_index, author_index, element_var_map, .before, vw, vh, arena, &element_bloom)) |ps| {
            style.before_content = ps.content;
            style.before_display = ps.display;
        }
        // Compute ::after pseudo-element style
        if (computePseudoContent(node, &style, ua_index, author_index, element_var_map, .after, vw, vh, arena, &element_bloom)) |ps| {
            style.after_content = ps.content;
            style.after_display = ps.display;
        }

        try styles.put(@intFromPtr(node.lxb_node), style);

        // Store in style sharing cache (only when no custom properties in scope).
        if (can_use_cache) {
            style_cache.put(cache_key, .{
                .style = style,
                .tag = node_tag,
                .class = node_class,
                .id = node_id,
                .inline_style = node_inline,
            }) catch {};
        }

        // Recurse into children with this element's VarMap (scoped inheritance).
        // IMPORTANT: pass style by value (stack copy), NOT by HashMap pointer.
        // Pass the element's bloom filter so children accumulate ancestor info.
        var child = node.firstChild();
        while (child) |c| {
            try walkAndCompute(c, &style, styles, ua_index, author_index, element_var_map, vw, vh, arena, &element_bloom, style_cache);
            child = c.nextSibling();
        }
    } else {
        // Non-element nodes (text, etc.) — recurse with parent's VarMap and bloom
        var child = node.firstChild();
        while (child) |c| {
            try walkAndCompute(c, parent_style, styles, ua_index, author_index, var_map, vw, vh, arena, parent_bloom, style_cache);
            child = c.nextSibling();
        }
    }
}

fn collectMatching(
    node: DomNode,
    index: *const FlatRuleIndex,
    origin: Origin,
    entries: *std.ArrayList(CascadeEntry),
    arena: std.mem.Allocator,
    pseudo: ?selectors.PseudoElement,
    ancestor_bloom: *const SelectorBloomFilter,
) !void {
    const adapter = makeDomAdapter(node);

    // Check universal rules
    for (index.universal.items) |rule| {
        if (rule.selector.pseudo_element != pseudo) continue;
        if (selectors.matchesWithBloom(&rule.selector, adapter, ancestor_bloom)) {
            for (rule.declarations) |decl| {
                try entries.append(arena, .{
                    .decl = decl,
                    .specificity = rule.selector.specificity.toU32(),
                    .source_order = rule.source_order,
                    .origin = origin,
                });
            }
        }
    }

    // Check by tag
    if (node.tagName()) |tag| {
        // Need lowercase for lookup
        var buf: [64]u8 = undefined;
        const lower_tag = toLowerBuf(tag, &buf);
        if (lower_tag) |lt| {
            if (index.by_tag.get(lt)) |rules| {
                for (rules.items) |rule| {
                    if (rule.selector.pseudo_element != pseudo) continue;
                    if (selectors.matchesWithBloom(&rule.selector, adapter, ancestor_bloom)) {
                        for (rule.declarations) |decl| {
                            try entries.append(arena, .{
                                .decl = decl,
                                .specificity = rule.selector.specificity.toU32(),
                                .source_order = rule.source_order,
                                .origin = origin,
                            });
                        }
                    }
                }
            }
        }
    }

    // Check by class
    if (node.getAttribute("class")) |class_attr| {
        var class_iter = std.mem.splitScalar(u8, class_attr, ' ');
        while (class_iter.next()) |cls| {
            if (cls.len == 0) continue;
            if (index.by_class.get(cls)) |rules| {
                for (rules.items) |rule| {
                    if (rule.selector.pseudo_element != pseudo) continue;
                    if (selectors.matchesWithBloom(&rule.selector, adapter, ancestor_bloom)) {
                        for (rule.declarations) |decl| {
                            try entries.append(arena, .{
                                .decl = decl,
                                .specificity = rule.selector.specificity.toU32(),
                                .source_order = rule.source_order,
                                .origin = origin,
                            });
                        }
                    }
                }
            }
        }
    }

    // Check by ID
    if (node.getAttribute("id")) |id| {
        if (index.by_id.get(id)) |rules| {
            for (rules.items) |rule| {
                if (rule.selector.pseudo_element != pseudo) continue;
                if (selectors.matchesWithBloom(&rule.selector, adapter, ancestor_bloom)) {
                    for (rule.declarations) |decl| {
                        try entries.append(arena, .{
                            .decl = decl,
                            .specificity = rule.selector.specificity.toU32(),
                            .source_order = rule.source_order,
                            .origin = origin,
                        });
                    }
                }
            }
        }
    }
}

/// Compute pseudo-element style (::before or ::after) for a given node.
/// Returns a struct with content and display if the pseudo-element has a non-empty content property.
const PseudoContentResult = struct {
    content: []const u8,
    display: ComputedStyle.Display,
};

fn computePseudoContent(
    node: DomNode,
    parent_style: *const ComputedStyle,
    ua_index: *const FlatRuleIndex,
    author_index: *const FlatRuleIndex,
    var_map: *const VarMap,
    pseudo: selectors.PseudoElement,
    vw: f32,
    vh: f32,
    arena: std.mem.Allocator,
    ancestor_bloom: *const SelectorBloomFilter,
) ?PseudoContentResult {
    var style = ComputedStyle{};
    inheritAll(&style, parent_style);

    // Collect matching declarations for this pseudo-element
    var entries: std.ArrayList(CascadeEntry) = .empty;
    collectMatching(node, ua_index, .ua, &entries, arena, pseudo, ancestor_bloom) catch return null;
    collectMatching(node, author_index, .author, &entries, arena, pseudo, ancestor_bloom) catch return null;

    if (entries.items.len == 0) return null;

    std.mem.sort(CascadeEntry, entries.items, {}, cascadeEntryLessThan);

    const parent_fs = parent_style.font_size_px;
    for (entries.items) |entry| {
        applyDeclaration(&style, entry.decl, var_map, parent_style, parent_fs, vw, vh, arena);
    }

    // Must have content property set (and not empty)
    const content = style.content orelse return null;
    if (content.len == 0) return null;

    return .{
        .content = content,
        .display = style.display,
    };
}

fn collectInlineDecls(
    inline_style: []const u8,
    entries: *std.ArrayList(CascadeEntry),
    arena: std.mem.Allocator,
) !void {
    // Wrap in a dummy rule block for the parser
    const wrapped_len = 2 + inline_style.len + 1;
    const wrapped = try arena.alloc(u8, wrapped_len);
    wrapped[0] = '*';
    wrapped[1] = '{';
    @memcpy(wrapped[2 .. 2 + inline_style.len], inline_style);
    wrapped[wrapped_len - 1] = '}';

    var p = parser_mod.Parser.init(wrapped, arena);
    const sheet = p.parse() catch return;

    for (sheet.rules) |rule| {
        switch (rule) {
            .style => |sr| {
                for (sr.declarations) |decl| {
                    // Expand shorthands
                    if (properties.expandShorthand(decl.property_name, decl.value_raw, arena)) |exp| {
                        for (exp) |*ed| {
                            ed.important = decl.important;
                            try entries.append(arena, .{
                                .decl = ed.*,
                                .specificity = 0, // inline style wins by origin, not specificity
                                .source_order = 0xFFFFFF, // high source order
                                .origin = .inline_,
                            });
                        }
                    } else {
                        try entries.append(arena, .{
                            .decl = decl,
                            .specificity = 0,
                            .source_order = 0xFFFFFF,
                            .origin = .inline_,
                        });
                    }
                }
            },
            else => {},
        }
    }
}

// ── Inheritance ──────────────────────────────────────────────────────

fn inheritAll(style: *ComputedStyle, parent: *const ComputedStyle) void {
    style.color = parent.color;
    style.color_set_by_css = parent.color_set_by_css;
    style.font_family = parent.font_family;
    style.font_size_px = parent.font_size_px;
    style.font_weight = parent.font_weight;
    style.font_style = parent.font_style;
    style.line_height = parent.line_height;
    style.letter_spacing = parent.letter_spacing;
    style.text_align = parent.text_align;
    style.text_decoration = parent.text_decoration;
    style.text_transform = parent.text_transform;
    style.white_space = parent.white_space;
    style.word_break = parent.word_break;
    style.overflow_wrap = parent.overflow_wrap;
    style.visibility = parent.visibility;
    style.list_style_type = parent.list_style_type;
    style.text_overflow = parent.text_overflow;
}

fn inheritProperty(style: *ComputedStyle, parent: *const ComputedStyle, prop: PropertyId) void {
    switch (prop) {
        .color => style.color = parent.color,
        .font_size => style.font_size_px = parent.font_size_px,
        .font_family => style.font_family = parent.font_family,
        .font_weight => style.font_weight = parent.font_weight,
        .font_style => style.font_style = parent.font_style,
        .line_height => style.line_height = parent.line_height,
        .letter_spacing => style.letter_spacing = parent.letter_spacing,
        .text_align => style.text_align = parent.text_align,
        .text_decoration => style.text_decoration = parent.text_decoration,
        .text_transform => style.text_transform = parent.text_transform,
        .white_space => style.white_space = parent.white_space,
        .word_break => style.word_break = parent.word_break,
        .overflow_wrap => style.overflow_wrap = parent.overflow_wrap,
        .visibility => style.visibility = parent.visibility,
        .list_style_type => style.list_style_type = parent.list_style_type,
        .text_overflow => style.text_overflow = parent.text_overflow,
        // For non-inherited properties, copy from parent too (explicit inherit keyword)
        .display => style.display = parent.display,
        .position => style.position = parent.position,
        .width => style.width = parent.width,
        .height => style.height = parent.height,
        .margin_top => style.margin_top = parent.margin_top,
        .margin_right => style.margin_right = parent.margin_right,
        .margin_bottom => style.margin_bottom = parent.margin_bottom,
        .margin_left => style.margin_left = parent.margin_left,
        .padding_top => style.padding_top = parent.padding_top,
        .padding_right => style.padding_right = parent.padding_right,
        .padding_bottom => style.padding_bottom = parent.padding_bottom,
        .padding_left => style.padding_left = parent.padding_left,
        .background_color => style.background_color = parent.background_color,
        .opacity => style.opacity = parent.opacity,
        .border_top_width => style.border_top_width = parent.border_top_width,
        .border_right_width => style.border_right_width = parent.border_right_width,
        .border_bottom_width => style.border_bottom_width = parent.border_bottom_width,
        .border_left_width => style.border_left_width = parent.border_left_width,
        .border_top_color => style.border_top_color = parent.border_top_color,
        .border_right_color => style.border_right_color = parent.border_right_color,
        .border_bottom_color => style.border_bottom_color = parent.border_bottom_color,
        .border_left_color => style.border_left_color = parent.border_left_color,
        else => {},
    }
}

// ── Apply a single declaration to a ComputedStyle ─────────────────────

fn applyDeclaration(
    style: *ComputedStyle,
    decl: Declaration,
    var_map: *const VarMap,
    parent: ?*const ComputedStyle,
    parent_fs: f32,
    vw: f32,
    vh: f32,
    arena: std.mem.Allocator,
) void {
    // Try shorthand expansion for unknown properties (margin, padding, border, etc.)
    if (decl.property == .unknown or decl.property == .custom) {
        if (decl.property != .custom) {
            if (properties.expandShorthand(decl.property_name, decl.value_raw, arena)) |expanded| {
                for (expanded) |*ed| {
                    ed.important = decl.important;
                    applyDeclaration(style, ed.*, var_map, parent, parent_fs, vw, vh, arena);
                }
                return;
            }
        }
    }

    // Resolve var() references
    var raw = decl.value_raw;
    var resolved_raw: ?[]const u8 = null;
    if (std.mem.indexOf(u8, raw, "var(") != null) {
        resolved_raw = variables.resolveVarRefs(raw, var_map, arena);
        if (resolved_raw) |r| raw = r;
    }

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return;

    // Handle CSS-wide keywords
    if (eqlIgnoreCase(trimmed, "inherit")) {
        if (parent) |p| inheritProperty(style, p, decl.property);
        return;
    }
    if (eqlIgnoreCase(trimmed, "initial") or eqlIgnoreCase(trimmed, "unset")) {
        if (eqlIgnoreCase(trimmed, "unset") and isInherited(decl.property)) {
            if (parent) |p| inheritProperty(style, p, decl.property);
        }
        // For initial / non-inherited unset: leave at default (ComputedStyle already has defaults)
        return;
    }

    const fs = style.font_size_px;

    switch (decl.property) {
        .display => {
            if (mapDisplay(trimmed)) |d| style.display = d;
        },
        .position => {
            if (eqlIgnoreCase(trimmed, "static")) style.position = .static_
            else if (eqlIgnoreCase(trimmed, "relative")) style.position = .relative
            else if (eqlIgnoreCase(trimmed, "absolute")) style.position = .absolute
            else if (eqlIgnoreCase(trimmed, "fixed")) style.position = .fixed
            else if (eqlIgnoreCase(trimmed, "sticky")) style.position = .sticky;
        },
        .float_ => {
            if (eqlIgnoreCase(trimmed, "left")) style.float_ = .left
            else if (eqlIgnoreCase(trimmed, "right")) style.float_ = .right
            else if (eqlIgnoreCase(trimmed, "none")) style.float_ = .none;
        },
        .clear => {
            if (eqlIgnoreCase(trimmed, "left")) style.clear = .left
            else if (eqlIgnoreCase(trimmed, "right")) style.clear = .right
            else if (eqlIgnoreCase(trimmed, "both")) style.clear = .both
            else if (eqlIgnoreCase(trimmed, "none")) style.clear = .none;
        },
        .box_sizing => {
            if (eqlIgnoreCase(trimmed, "border-box")) style.box_sizing = .border_box
            else if (eqlIgnoreCase(trimmed, "content-box")) style.box_sizing = .content_box;
        },
        .color => {
            if (properties.parseColor(trimmed)) |c| {
                style.color = c.toArgb();
                style.color_set_by_css = true;
            }
        },
        .background_color => {
            if (eqlIgnoreCase(trimmed, "currentcolor") or eqlIgnoreCase(trimmed, "currentColor")) {
                style.background_color = style.color;
            } else if (properties.parseColor(trimmed)) |c| {
                style.background_color = c.toArgb();
            }
        },
        .background_image => {
            // Parse linear-gradient(direction, color1, color2)
            if (parseLinearGradient(trimmed, style)) {
                // gradient_color_start, gradient_color_end, gradient_direction set
            } else if (startsWithIgnoreCase(trimmed, "url(")) {
                // Extract URL from url("...") or url('...') or url(...)
                if (extractUrl(trimmed)) |url| {
                    style.background_image_url = url;
                }
            }
        },
        .opacity => {
            if (std.fmt.parseFloat(f32, trimmed)) |v| {
                style.opacity = std.math.clamp(v, 0.0, 1.0);
            } else |_| {}
        },
        .visibility => {
            if (eqlIgnoreCase(trimmed, "visible")) style.visibility = .visible
            else if (eqlIgnoreCase(trimmed, "hidden")) style.visibility = .hidden
            else if (eqlIgnoreCase(trimmed, "collapse")) style.visibility = .collapse;
        },
        .font_size => {
            // Handle font-size keywords
            if (eqlIgnoreCase(trimmed, "xx-small")) { style.font_size_px = 9; }
            else if (eqlIgnoreCase(trimmed, "x-small")) { style.font_size_px = 10; }
            else if (eqlIgnoreCase(trimmed, "small")) { style.font_size_px = 13; }
            else if (eqlIgnoreCase(trimmed, "medium")) { style.font_size_px = 16; }
            else if (eqlIgnoreCase(trimmed, "large")) { style.font_size_px = 18; }
            else if (eqlIgnoreCase(trimmed, "x-large")) { style.font_size_px = 24; }
            else if (eqlIgnoreCase(trimmed, "xx-large")) { style.font_size_px = 32; }
            else if (eqlIgnoreCase(trimmed, "xxx-large")) { style.font_size_px = 48; }
            else if (eqlIgnoreCase(trimmed, "smaller")) { style.font_size_px = parent_fs * 0.833; }
            else if (eqlIgnoreCase(trimmed, "larger")) { style.font_size_px = parent_fs * 1.2; }
            else if (properties.parseLength(trimmed)) |len| {
                // Percentage font-size is relative to parent font-size
                if (len.unit == .percent) {
                    style.font_size_px = parent_fs * len.value / 100.0;
                } else {
                    style.font_size_px = resolveLengthToPx(len.value, len.unit, parent_fs, vw, vh);
                }
            } else if (std.fmt.parseFloat(f32, trimmed)) |v| {
                style.font_size_px = v;
            } else |_| {}
        },
        .font_weight => {
            if (std.fmt.parseInt(u16, trimmed, 10)) |w| {
                style.font_weight = w;
            } else |_| {
                if (eqlIgnoreCase(trimmed, "bold")) style.font_weight = 700
                else if (eqlIgnoreCase(trimmed, "normal")) style.font_weight = 400
                else if (eqlIgnoreCase(trimmed, "lighter")) {
                    style.font_weight = if (style.font_weight >= 600) 400 else 100;
                } else if (eqlIgnoreCase(trimmed, "bolder")) {
                    style.font_weight = if (style.font_weight <= 300) 400 else 700;
                }
            }
        },
        .font_style => {
            if (eqlIgnoreCase(trimmed, "normal")) style.font_style = .normal
            else if (eqlIgnoreCase(trimmed, "italic")) style.font_style = .italic
            else if (eqlIgnoreCase(trimmed, "oblique")) style.font_style = .oblique;
        },
        .font_family => {
            // Parse font-family: match known generic families and common font names
            // Check each family in the comma-separated list
            var iter = std.mem.splitScalar(u8, trimmed, ',');
            while (iter.next()) |raw_family| {
                const family = std.mem.trim(u8, raw_family, " \t\r\n'\"");
                if (family.len == 0) continue;
                // Generic families
                if (eqlIgnoreCase(family, "sans-serif") or eqlIgnoreCase(family, "system-ui")) {
                    style.font_family = .sans_serif;
                    break;
                } else if (eqlIgnoreCase(family, "serif")) {
                    style.font_family = .serif;
                    break;
                } else if (eqlIgnoreCase(family, "monospace")) {
                    style.font_family = .monospace;
                    break;
                }
                // Named fonts → map to generic family
                else if (eqlIgnoreCase(family, "Verdana") or eqlIgnoreCase(family, "Arial") or
                    eqlIgnoreCase(family, "Helvetica") or eqlIgnoreCase(family, "Tahoma") or
                    eqlIgnoreCase(family, "Geneva") or eqlIgnoreCase(family, "Segoe UI") or
                    eqlIgnoreCase(family, "Roboto") or eqlIgnoreCase(family, "Inter"))
                {
                    style.font_family = .sans_serif;
                    break;
                } else if (eqlIgnoreCase(family, "Times") or eqlIgnoreCase(family, "Times New Roman") or
                    eqlIgnoreCase(family, "Georgia") or eqlIgnoreCase(family, "Palatino"))
                {
                    style.font_family = .serif;
                    break;
                } else if (eqlIgnoreCase(family, "Courier") or eqlIgnoreCase(family, "Courier New") or
                    eqlIgnoreCase(family, "Consolas") or eqlIgnoreCase(family, "Monaco"))
                {
                    style.font_family = .monospace;
                    break;
                }
                // Unknown font name — try next in list
            }
        },
        .text_align => {
            if (eqlIgnoreCase(trimmed, "left") or eqlIgnoreCase(trimmed, "start"))
                style.text_align = .left
            else if (eqlIgnoreCase(trimmed, "right") or eqlIgnoreCase(trimmed, "end"))
                style.text_align = .right
            else if (eqlIgnoreCase(trimmed, "center"))
                style.text_align = .center
            else if (eqlIgnoreCase(trimmed, "justify"))
                style.text_align = .justify;
        },
        .text_decoration => {
            if (eqlIgnoreCase(trimmed, "none")) {
                style.text_decoration = .{};
            } else if (eqlIgnoreCase(trimmed, "underline")) {
                style.text_decoration = .{ .underline = true };
            } else if (eqlIgnoreCase(trimmed, "line-through")) {
                style.text_decoration = .{ .line_through = true };
            } else if (eqlIgnoreCase(trimmed, "overline")) {
                style.text_decoration = .{ .overline = true };
            }
        },
        .text_transform => {
            if (eqlIgnoreCase(trimmed, "none")) style.text_transform = .none
            else if (eqlIgnoreCase(trimmed, "uppercase")) style.text_transform = .uppercase
            else if (eqlIgnoreCase(trimmed, "lowercase")) style.text_transform = .lowercase
            else if (eqlIgnoreCase(trimmed, "capitalize")) style.text_transform = .capitalize;
        },
        .white_space => {
            if (eqlIgnoreCase(trimmed, "normal")) style.white_space = .normal
            else if (eqlIgnoreCase(trimmed, "pre")) style.white_space = .pre
            else if (eqlIgnoreCase(trimmed, "nowrap")) style.white_space = .nowrap
            else if (eqlIgnoreCase(trimmed, "pre-wrap")) style.white_space = .pre_wrap
            else if (eqlIgnoreCase(trimmed, "pre-line")) style.white_space = .pre_line;
        },
        .word_break => {
            if (eqlIgnoreCase(trimmed, "normal")) style.word_break = .normal
            else if (eqlIgnoreCase(trimmed, "break-all")) style.word_break = .break_all
            else if (eqlIgnoreCase(trimmed, "keep-all")) style.word_break = .keep_all;
        },
        .overflow_wrap => {
            if (eqlIgnoreCase(trimmed, "normal")) style.overflow_wrap = .normal
            else if (eqlIgnoreCase(trimmed, "break-word")) style.overflow_wrap = .break_word
            else if (eqlIgnoreCase(trimmed, "anywhere")) style.overflow_wrap = .anywhere;
        },
        .text_overflow => {
            if (eqlIgnoreCase(trimmed, "clip")) style.text_overflow = .clip
            else if (eqlIgnoreCase(trimmed, "ellipsis")) style.text_overflow = .ellipsis;
        },
        .vertical_align => {
            if (eqlIgnoreCase(trimmed, "baseline")) style.vertical_align = .baseline
            else if (eqlIgnoreCase(trimmed, "top")) style.vertical_align = .top
            else if (eqlIgnoreCase(trimmed, "middle")) style.vertical_align = .middle
            else if (eqlIgnoreCase(trimmed, "bottom")) style.vertical_align = .bottom
            else if (eqlIgnoreCase(trimmed, "text-top")) style.vertical_align = .text_top
            else if (eqlIgnoreCase(trimmed, "text-bottom")) style.vertical_align = .text_bottom
            else if (eqlIgnoreCase(trimmed, "sub")) style.vertical_align = .sub
            else if (eqlIgnoreCase(trimmed, "super")) style.vertical_align = .super;
        },
        .line_height => {
            if (eqlIgnoreCase(trimmed, "normal")) {
                style.line_height = .normal;
            } else if (parseLengthValue(trimmed, fs, vw, vh)) |px| {
                style.line_height = .{ .px = px };
            } else if (std.fmt.parseFloat(f32, trimmed)) |n| {
                style.line_height = .{ .number = n };
            } else |_| {}
        },
        .letter_spacing => {
            if (eqlIgnoreCase(trimmed, "normal")) {
                style.letter_spacing = 0;
            } else if (parseLengthValue(trimmed, fs, vw, vh)) |px| {
                style.letter_spacing = px;
            }
        },
        .width => style.width = parseDimension(trimmed, fs, vw, vh),
        .height => style.height = parseDimension(trimmed, fs, vw, vh),
        .min_width => style.min_width = parseDimension(trimmed, fs, vw, vh),
        .max_width => style.max_width = parseDimensionOrNone(trimmed, fs, vw, vh),
        .min_height => style.min_height = parseDimension(trimmed, fs, vw, vh),
        .max_height => style.max_height = parseDimensionOrNone(trimmed, fs, vw, vh),
        .margin_top => {
            const md = parseMarginValue(trimmed, fs, vw, vh);
            style.margin_top = md.value;
            style.margin_top_auto = md.is_auto;
        },
        .margin_right => {
            const md = parseMarginValue(trimmed, fs, vw, vh);
            style.margin_right = md.value;
            style.margin_right_auto = md.is_auto;
        },
        .margin_bottom => {
            const md = parseMarginValue(trimmed, fs, vw, vh);
            style.margin_bottom = md.value;
            style.margin_bottom_auto = md.is_auto;
        },
        .margin_left => {
            const md = parseMarginValue(trimmed, fs, vw, vh);
            style.margin_left = md.value;
            style.margin_left_auto = md.is_auto;
        },
        .padding_top => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.padding_top = px;
        },
        .padding_right => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.padding_right = px;
        },
        .padding_bottom => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.padding_bottom = px;
        },
        .padding_left => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.padding_left = px;
        },
        .border_top_width => {
            if (parseBorderWidth(trimmed, fs, vw, vh)) |px| style.border_top_width = px;
        },
        .border_right_width => {
            if (parseBorderWidth(trimmed, fs, vw, vh)) |px| style.border_right_width = px;
        },
        .border_bottom_width => {
            if (parseBorderWidth(trimmed, fs, vw, vh)) |px| style.border_bottom_width = px;
        },
        .border_left_width => {
            if (parseBorderWidth(trimmed, fs, vw, vh)) |px| style.border_left_width = px;
        },
        .border_top_color => {
            if (eqlIgnoreCase(trimmed, "currentcolor")) {
                style.border_top_color = style.color;
            } else if (properties.parseColor(trimmed)) |c| style.border_top_color = c.toArgb();
        },
        .border_right_color => {
            if (eqlIgnoreCase(trimmed, "currentcolor")) {
                style.border_right_color = style.color;
            } else if (properties.parseColor(trimmed)) |c| style.border_right_color = c.toArgb();
        },
        .border_bottom_color => {
            if (eqlIgnoreCase(trimmed, "currentcolor")) {
                style.border_bottom_color = style.color;
            } else if (properties.parseColor(trimmed)) |c| style.border_bottom_color = c.toArgb();
        },
        .border_left_color => {
            if (eqlIgnoreCase(trimmed, "currentcolor")) {
                style.border_left_color = style.color;
            } else if (properties.parseColor(trimmed)) |c| style.border_left_color = c.toArgb();
        },
        .border_radius_top_left => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.border_radius_tl = px;
        },
        .border_radius_top_right => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.border_radius_tr = px;
        },
        .border_radius_bottom_left => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.border_radius_bl = px;
        },
        .border_radius_bottom_right => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.border_radius_br = px;
        },
        .overflow_x => {
            if (mapOverflow(trimmed)) |o| style.overflow_x = o;
        },
        .overflow_y => {
            if (mapOverflow(trimmed)) |o| style.overflow_y = o;
        },
        .z_index => {
            if (eqlIgnoreCase(trimmed, "auto")) {
                style.z_index = 0;
            } else if (std.fmt.parseInt(i32, trimmed, 10)) |v| {
                style.z_index = v;
            } else |_| {}
        },
        .top => style.top = parseDimension(trimmed, fs, vw, vh),
        .right => style.right = parseDimension(trimmed, fs, vw, vh),
        .bottom => style.bottom = parseDimension(trimmed, fs, vw, vh),
        .left => style.left = parseDimension(trimmed, fs, vw, vh),
        .list_style_type => {
            if (eqlIgnoreCase(trimmed, "disc")) style.list_style_type = .disc
            else if (eqlIgnoreCase(trimmed, "circle")) style.list_style_type = .circle
            else if (eqlIgnoreCase(trimmed, "square")) style.list_style_type = .square
            else if (eqlIgnoreCase(trimmed, "decimal")) style.list_style_type = .decimal
            else if (eqlIgnoreCase(trimmed, "none")) style.list_style_type = .none;
        },
        .flex_direction => {
            if (eqlIgnoreCase(trimmed, "row")) style.flex_direction = .row
            else if (eqlIgnoreCase(trimmed, "row-reverse")) style.flex_direction = .row_reverse
            else if (eqlIgnoreCase(trimmed, "column")) style.flex_direction = .column
            else if (eqlIgnoreCase(trimmed, "column-reverse")) style.flex_direction = .column_reverse;
        },
        .flex_wrap => {
            if (eqlIgnoreCase(trimmed, "nowrap")) style.flex_wrap = .nowrap
            else if (eqlIgnoreCase(trimmed, "wrap")) style.flex_wrap = .wrap
            else if (eqlIgnoreCase(trimmed, "wrap-reverse")) style.flex_wrap = .wrap_reverse;
        },
        .justify_content => {
            if (eqlIgnoreCase(trimmed, "flex-start") or eqlIgnoreCase(trimmed, "start"))
                style.justify_content = .flex_start
            else if (eqlIgnoreCase(trimmed, "flex-end") or eqlIgnoreCase(trimmed, "end"))
                style.justify_content = .flex_end
            else if (eqlIgnoreCase(trimmed, "center"))
                style.justify_content = .center
            else if (eqlIgnoreCase(trimmed, "space-between"))
                style.justify_content = .space_between
            else if (eqlIgnoreCase(trimmed, "space-around"))
                style.justify_content = .space_around
            else if (eqlIgnoreCase(trimmed, "space-evenly"))
                style.justify_content = .space_evenly;
        },
        .align_content => {
            if (eqlIgnoreCase(trimmed, "stretch"))
                style.align_content = .stretch
            else if (eqlIgnoreCase(trimmed, "flex-start") or eqlIgnoreCase(trimmed, "start"))
                style.align_content = .flex_start
            else if (eqlIgnoreCase(trimmed, "flex-end") or eqlIgnoreCase(trimmed, "end"))
                style.align_content = .flex_end
            else if (eqlIgnoreCase(trimmed, "center"))
                style.align_content = .center
            else if (eqlIgnoreCase(trimmed, "space-between"))
                style.align_content = .space_between
            else if (eqlIgnoreCase(trimmed, "space-around"))
                style.align_content = .space_around
            else if (eqlIgnoreCase(trimmed, "space-evenly"))
                style.align_content = .space_evenly;
        },
        .align_items => {
            if (eqlIgnoreCase(trimmed, "stretch"))
                style.align_items = .stretch
            else if (eqlIgnoreCase(trimmed, "flex-start") or eqlIgnoreCase(trimmed, "start"))
                style.align_items = .flex_start
            else if (eqlIgnoreCase(trimmed, "flex-end") or eqlIgnoreCase(trimmed, "end"))
                style.align_items = .flex_end
            else if (eqlIgnoreCase(trimmed, "center"))
                style.align_items = .center
            else if (eqlIgnoreCase(trimmed, "baseline"))
                style.align_items = .baseline;
        },
        .align_self => {
            if (eqlIgnoreCase(trimmed, "flex-start") or eqlIgnoreCase(trimmed, "start")) style.align_self = .flex_start
            else if (eqlIgnoreCase(trimmed, "flex-end") or eqlIgnoreCase(trimmed, "end")) style.align_self = .flex_end
            else if (eqlIgnoreCase(trimmed, "center")) style.align_self = .center
            else if (eqlIgnoreCase(trimmed, "stretch")) style.align_self = .stretch
            else if (eqlIgnoreCase(trimmed, "baseline")) style.align_self = .baseline
            else if (eqlIgnoreCase(trimmed, "auto")) style.align_self = .auto;
        },
        .flex_grow => {
            if (std.fmt.parseFloat(f32, trimmed)) |v| style.flex_grow = v else |_| {}
        },
        .flex_shrink => {
            if (std.fmt.parseFloat(f32, trimmed)) |v| style.flex_shrink = v else |_| {}
        },
        .order => {
            if (std.fmt.parseInt(i32, trimmed, 10)) |v| style.order = v else |_| {}
        },
        .flex_basis => {
            style.flex_basis = parseDimension(trimmed, fs, vw, vh);
        },
        .gap, .column_gap => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.gap = px;
        },
        .row_gap => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.row_gap = px;
        },
        .box_shadow => {
            parseShadow(trimmed, fs, &style.box_shadow_x, &style.box_shadow_y, &style.box_shadow_blur, &style.box_shadow_color);
        },
        .text_shadow => {
            parseShadow(trimmed, fs, &style.text_shadow_x, &style.text_shadow_y, &style.text_shadow_blur, &style.text_shadow_color);
        },
        // Grid properties
        .grid_template_columns => {
            style.grid_template_columns = parseGridTemplate(trimmed, arena) orelse &.{};
        },
        .grid_template_rows => {
            style.grid_template_rows = parseGridTemplate(trimmed, arena) orelse &.{};
        },
        .grid_auto_flow => {
            if (eqlIgnoreCase(trimmed, "row")) style.grid_auto_flow = .row
            else if (eqlIgnoreCase(trimmed, "column")) style.grid_auto_flow = .column;
        },
        .grid_auto_columns => {
            if (parseOneTrack(trimmed)) |t| style.grid_auto_columns = t;
        },
        .grid_column_start => style.grid_column_start = parseGridLine(trimmed),
        .grid_column_end => {
            if (std.mem.startsWith(u8, trimmed, "span")) {
                const num = std.mem.trim(u8, trimmed[4..], " \t");
                style.grid_column_span = std.fmt.parseInt(u16, num, 10) catch 1;
            } else style.grid_column_end = parseGridLine(trimmed);
        },
        .grid_row_start => style.grid_row_start = parseGridLine(trimmed),
        .grid_row_end => {
            if (std.mem.startsWith(u8, trimmed, "span")) {
                const num = std.mem.trim(u8, trimmed[4..], " \t");
                style.grid_row_span = std.fmt.parseInt(u16, num, 10) catch 1;
            } else style.grid_row_end = parseGridLine(trimmed);
        },
        .content => {
            // Parse CSS content property value (for ::before/::after)
            if (trimmed.len >= 2 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
                const quote = trimmed[0];
                if (trimmed[trimmed.len - 1] == quote) {
                    style.content = trimmed[1 .. trimmed.len - 1];
                }
            } else if (eqlIgnoreCase(trimmed, "none") or eqlIgnoreCase(trimmed, "normal")) {
                style.content = null;
            } else if (trimmed.len > 0) {
                // For counters, attr(), etc. — just store raw for now
                style.content = trimmed;
            }
        },
        .transform => {
            parseTransform(trimmed, &style.transform_translate_x, &style.transform_translate_y, fs, vw, vh);
        },
        .counter_reset => style.counter_reset = arena.dupe(u8, trimmed) catch null,
        .counter_increment => style.counter_increment = arena.dupe(u8, trimmed) catch null,
        .transition_duration => {
            if (properties.parseLength(trimmed)) |len| {
                if (len.unit == .s) style.transition_duration = len.value
                else if (len.unit == .ms) style.transition_duration = len.value / 1000.0;
            }
        },
        .transition_delay => {
            if (properties.parseLength(trimmed)) |len| {
                if (len.unit == .s) style.transition_delay = len.value
                else if (len.unit == .ms) style.transition_delay = len.value / 1000.0;
            }
        },
        .animation_name => style.animation_name = arena.dupe(u8, trimmed) catch null,
        .animation_duration => {
            if (properties.parseLength(trimmed)) |len| {
                if (len.unit == .s) style.animation_duration = len.value
                else if (len.unit == .ms) style.animation_duration = len.value / 1000.0;
            }
        },
        .filter => parseFilter(trimmed, style, fs, vw, vh),
        .object_fit => {
            if (eqlIgnoreCase(trimmed, "contain")) style.object_fit = .contain
            else if (eqlIgnoreCase(trimmed, "cover")) style.object_fit = .cover
            else if (eqlIgnoreCase(trimmed, "fill")) style.object_fit = .fill
            else if (eqlIgnoreCase(trimmed, "none")) style.object_fit = .none
            else if (eqlIgnoreCase(trimmed, "scale-down")) style.object_fit = .scale_down;
        },
        .outline_width => {
            if (parseLengthValue(trimmed, fs, vw, vh)) |px| style.outline_width = px;
        },
        .outline_color => {
            if (properties.parseColor(trimmed)) |c| style.outline_color = c.toArgb();
        },
        // Skip these — just parse to avoid unknown property warnings
        .transition_property, .transition_timing_function,
        .animation_timing_function, .animation_delay,
        .animation_iteration_count, .animation_direction,
        .animation_fill_mode, .animation_play_state,
        .backdrop_filter, .outline_style => {},
        // Skip border-style — we don't track it but it's needed for border-width to display
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style => {},
        // Skip custom properties (already extracted)
        .custom => {},
        // Skip unknown
        else => {},
    }
}

fn parseFilter(s: []const u8, style: *ComputedStyle, font_size: f32, vw: f32, vh: f32) void {
    if (eqlIgnoreCase(s, "none")) {
        style.filter_grayscale = 0;
        style.filter_brightness = 1;
        style.filter_blur = 0;
        return;
    }
    var pos: usize = 0;
    while (pos < s.len) {
        if (std.mem.indexOfPos(u8, s, pos, "grayscale(")) |idx| {
            const start = idx + "grayscale(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const val = std.mem.trim(u8, s[start..end], " \t%");
            if (std.fmt.parseFloat(f32, val)) |v| {
                style.filter_grayscale = if (v > 1) v / 100.0 else v;
            } else |_| {}
            pos = end + 1;
        } else if (std.mem.indexOfPos(u8, s, pos, "brightness(")) |idx| {
            const start = idx + "brightness(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const val = std.mem.trim(u8, s[start..end], " \t%");
            if (std.fmt.parseFloat(f32, val)) |v| {
                style.filter_brightness = if (v > 2) v / 100.0 else v;
            } else |_| {}
            pos = end + 1;
        } else if (std.mem.indexOfPos(u8, s, pos, "blur(")) |idx| {
            const start = idx + "blur(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const val = std.mem.trim(u8, s[start..end], " \t");
            if (parseLengthValue(val, font_size, vw, vh)) |px| {
                style.filter_blur = px;
            }
            pos = end + 1;
        } else break;
    }
}

fn parseTransform(s: []const u8, tx: *f32, ty: *f32, font_size: f32, vw: f32, vh: f32) void {
    if (eqlIgnoreCase(s, "none")) {
        tx.* = 0;
        ty.* = 0;
        return;
    }
    var pos: usize = 0;
    while (pos < s.len) {
        if (std.mem.indexOfPos(u8, s, pos, "translateX(")) |idx| {
            const start = idx + "translateX(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const val = std.mem.trim(u8, s[start..end], " \t");
            if (parseLengthValue(val, font_size, vw, vh)) |px| tx.* = px;
            pos = end + 1;
        } else if (std.mem.indexOfPos(u8, s, pos, "translateY(")) |idx| {
            const start = idx + "translateY(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const val = std.mem.trim(u8, s[start..end], " \t");
            if (parseLengthValue(val, font_size, vw, vh)) |px| ty.* = px;
            pos = end + 1;
        } else if (std.mem.indexOfPos(u8, s, pos, "translate(")) |idx| {
            const start = idx + "translate(".len;
            const end = std.mem.indexOfScalarPos(u8, s, start, ')') orelse break;
            const inner = std.mem.trim(u8, s[start..end], " \t");
            if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
                const x_str = std.mem.trim(u8, inner[0..comma], " \t");
                const y_str = std.mem.trim(u8, inner[comma + 1 ..], " \t");
                if (parseLengthValue(x_str, font_size, vw, vh)) |px| tx.* = px;
                if (parseLengthValue(y_str, font_size, vw, vh)) |px| ty.* = px;
            } else {
                // Single value — translateX only
                if (parseLengthValue(inner, font_size, vw, vh)) |px| tx.* = px;
            }
            pos = end + 1;
        } else break;
    }
}

// ── Value parsing helpers ─────────────────────────────────────────────

fn parseLengthValue(s: []const u8, font_size: f32, vw: f32, vh: f32) ?f32 {
    return parseLengthValueDepth(s, font_size, vw, vh, 0);
}

fn parseLengthValueDepth(s: []const u8, font_size: f32, vw: f32, vh: f32, depth: u32) ?f32 {
    if (depth > 10) return null;
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "0")) return 0;

    // Handle clamp(min, preferred, max)
    if (startsWithIgnoreCase(s, "clamp(")) {
        return parseClamp(s, font_size, vw, vh, depth);
    }

    // Handle calc(expression)
    if (startsWithIgnoreCase(s, "calc(")) {
        return parseCalcSimple(s, font_size, vw, vh, depth);
    }

    // Handle min(a, b) and max(a, b)
    if (startsWithIgnoreCase(s, "min(")) {
        return parseMinMax(s, font_size, vw, vh, true, depth);
    }
    if (startsWithIgnoreCase(s, "max(")) {
        return parseMinMax(s, font_size, vw, vh, false, depth);
    }

    if (properties.parseLength(s)) |len| {
        return resolveLengthToPx(len.value, len.unit, font_size, vw, vh);
    }
    // Try as bare number (px)
    if (std.fmt.parseFloat(f32, s)) |v| return v else |_| {}
    return null;
}

const startsWithIgnoreCase = util.startsWithIgnoreCase;

fn parseClamp(s: []const u8, font_size: f32, vw: f32, vh: f32, depth: u32) ?f32 {
    const start = 6; // "clamp(".len
    // Find matching closing paren
    var pdepth: usize = 1;
    var end: usize = start;
    while (end < s.len and pdepth > 0) : (end += 1) {
        if (s[end] == '(') pdepth += 1;
        if (s[end] == ')') pdepth -= 1;
    }
    if (pdepth != 0) return null;
    const inner = s[start .. end - 1];

    // Split by commas (respecting nested parens)
    var parts: [3][]const u8 = .{ "", "", "" };
    var part_idx: usize = 0;
    var paren_depth: usize = 0;
    var part_start: usize = 0;
    for (inner, 0..) |c, i| {
        if (c == '(') paren_depth += 1;
        if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        }
        if (c == ',' and paren_depth == 0 and part_idx < 2) {
            parts[part_idx] = std.mem.trim(u8, inner[part_start..i], " \t");
            part_idx += 1;
            part_start = i + 1;
        }
    }
    if (part_idx == 2) {
        parts[2] = std.mem.trim(u8, inner[part_start..], " \t");
    } else return null;

    // Use parseCalcExpr for each part to handle expressions like "1.08rem + 3.92vw"
    const min_val = parseCalcExpr(parts[0], font_size, vw, vh, depth + 1) orelse
        (parseLengthValueDepth(parts[0], font_size, vw, vh, depth + 1) orelse return null);
    const pref_val = parseCalcExpr(parts[1], font_size, vw, vh, depth + 1) orelse
        (parseLengthValueDepth(parts[1], font_size, vw, vh, depth + 1) orelse return null);
    const max_val = parseCalcExpr(parts[2], font_size, vw, vh, depth + 1) orelse
        (parseLengthValueDepth(parts[2], font_size, vw, vh, depth + 1) orelse return null);

    return std.math.clamp(pref_val, min_val, max_val);
}

fn parseMinMax(s: []const u8, font_size: f32, vw: f32, vh: f32, is_min: bool, depth: u32) ?f32 {
    const prefix_len: usize = 4; // "min(" or "max("
    var end = s.len;
    if (end > 0 and s[end - 1] == ')') end -= 1;
    const inner = std.mem.trim(u8, s[prefix_len..end], " \t");

    // Split by comma (respecting nested parens)
    var paren_depth: usize = 0;
    var split_pos: ?usize = null;
    for (inner, 0..) |c, i| {
        if (c == '(') paren_depth += 1;
        if (c == ')') { if (paren_depth > 0) paren_depth -= 1; }
        if (c == ',' and paren_depth == 0) {
            split_pos = i;
            break;
        }
    }

    if (split_pos) |sp| {
        const a_str = std.mem.trim(u8, inner[0..sp], " \t");
        const b_str = std.mem.trim(u8, inner[sp + 1 ..], " \t");
        const a = parseCalcExpr(a_str, font_size, vw, vh, depth + 1) orelse
            (parseLengthValueDepth(a_str, font_size, vw, vh, depth + 1) orelse return null);
        const b = parseCalcExpr(b_str, font_size, vw, vh, depth + 1) orelse
            (parseLengthValueDepth(b_str, font_size, vw, vh, depth + 1) orelse return null);
        return if (is_min) @min(a, b) else @max(a, b);
    }
    return parseCalcExpr(inner, font_size, vw, vh, depth + 1) orelse
        parseLengthValueDepth(inner, font_size, vw, vh, depth + 1);
}

fn parseCalcSimple(s: []const u8, font_size: f32, vw: f32, vh: f32, depth: u32) ?f32 {
    const start = 5; // "calc(".len
    var end = s.len;
    if (end > 0 and s[end - 1] == ')') end -= 1;
    const inner = std.mem.trim(u8, s[start..end], " \t");
    return parseCalcExpr(inner, font_size, vw, vh, depth);
}

/// Parse a calc expression with correct operator precedence.
/// + and - are lowest priority (split last), * and / are higher.
/// depth guards against stack overflow from deeply nested calc(calc(calc(...))) inputs.
fn parseCalcExpr(expr: []const u8, font_size: f32, vw: f32, vh: f32, depth: u32) ?f32 {
    if (depth > 10) return null;

    // Find the LAST + or - at top level (not inside parens)
    // This gives correct left-to-right associativity for same-priority ops
    // and ensures * / bind tighter than + -
    var paren_depth: usize = 0;
    var last_add_sub: ?usize = null;
    var last_mul_div: ?usize = null;

    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        if (c == '(') { paren_depth += 1; i += 1; continue; }
        if (c == ')') { if (paren_depth > 0) paren_depth -= 1; i += 1; continue; }
        if (paren_depth == 0) {
            // CSS calc requires spaces around + and -
            if (i > 0 and i + 1 < expr.len and expr[i - 1] == ' ' and expr[i + 1] == ' ') {
                if (c == '+' or c == '-') last_add_sub = i;
            }
            // * and / don't require spaces in CSS calc
            if (c == '*' or c == '/') {
                if (i > 0 and i + 1 < expr.len) last_mul_div = i;
            }
        }
        i += 1;
    }

    // Split at lowest-priority operator first (+ or -)
    if (last_add_sub) |pos| {
        const left = std.mem.trim(u8, expr[0 .. pos - 1], " \t");
        const right = std.mem.trim(u8, expr[pos + 2 ..], " \t");
        const l = parseCalcExpr(left, font_size, vw, vh, depth + 1) orelse return null;
        const r = parseCalcExpr(right, font_size, vw, vh, depth + 1) orelse return null;
        return if (expr[pos] == '+') l + r else l - r;
    }

    // Then * or /
    if (last_mul_div) |pos| {
        const left = std.mem.trim(u8, expr[0..pos], " \t");
        const right = std.mem.trim(u8, expr[pos + 1 ..], " \t");
        const l = parseCalcExpr(left, font_size, vw, vh, depth + 1) orelse return null;
        const r = parseCalcExpr(right, font_size, vw, vh, depth + 1) orelse return null;
        return if (expr[pos] == '*') l * r else if (r != 0) l / r else null;
    }

    // No operator — single value (or nested function like clamp/min/max)
    return parseLengthValueDepth(expr, font_size, vw, vh, depth + 1);
}

fn resolveLengthToPx(value: f32, unit: values.Unit, font_size: f32, vw: f32, vh: f32) f32 {
    return switch (unit) {
        .px => value,
        .em => value * font_size,
        .rem => value * 16.0,
        .ch => value * font_size * 0.5, // approximate: 0 width ≈ 50% of font-size
        .ex => value * font_size * 0.5, // approximate: x-height ≈ 50% of font-size
        .lh => value * font_size * 1.2, // approximate: line-height ≈ 120% of font-size
        .percent => value, // percentage stored as-is, resolved at layout
        .vh, .svh, .dvh, .lvh => value * vh / 100.0,
        .vw, .svw, .dvw, .lvw => value * vw / 100.0,
        .pt => value * 4.0 / 3.0,
        .cm => value * 96.0 / 2.54,
        .mm => value * 96.0 / 25.4,
        .in_ => value * 96.0,
        else => value,
    };
}

fn parseGridTemplate(s: []const u8, alloc: std.mem.Allocator) ?[]const ComputedStyle.GridTrackSize {
    var tracks: std.ArrayListUnmanaged(ComputedStyle.GridTrackSize) = .empty;
    // We need to handle repeat() and minmax() which contain parens, so we can't just tokenize by space.
    // Instead, scan through and handle paren-groups specially.
    var pos: usize = 0;
    while (pos < s.len) {
        // Skip whitespace
        while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t')) pos += 1;
        if (pos >= s.len) break;

        // Check for repeat( or minmax(
        if (pos + 7 <= s.len and std.mem.startsWith(u8, s[pos..], "repeat(")) {
            // Find matching closing paren
            const start = pos + 7;
            var depth: usize = 1;
            var end = start;
            while (end < s.len and depth > 0) : (end += 1) {
                if (s[end] == '(') depth += 1;
                if (s[end] == ')') depth -= 1;
            }
            const inner = s[start..if (end > start and s[end - 1] == ')') end - 1 else end];
            // Parse repeat(N, size)
            if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
                const count_str = std.mem.trim(u8, inner[0..comma], " \t");
                const count = std.fmt.parseInt(usize, count_str, 10) catch {
                    pos = end;
                    continue;
                };
                const size_str = std.mem.trim(u8, inner[comma + 1 ..], " \t");
                const track = parseOneTrack(size_str) orelse {
                    pos = end;
                    continue;
                };
                for (0..count) |_| {
                    tracks.append(alloc, track) catch return null;
                }
            }
            pos = end;
            continue;
        }
        if (pos + 7 <= s.len and std.mem.startsWith(u8, s[pos..], "minmax(")) {
            const start = pos + 7;
            var depth: usize = 1;
            var end = start;
            while (end < s.len and depth > 0) : (end += 1) {
                if (s[end] == '(') depth += 1;
                if (s[end] == ')') depth -= 1;
            }
            const inner = s[start..if (end > start and s[end - 1] == ')') end - 1 else end];
            // Simplify minmax(min, max) to max
            if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
                const max_str = std.mem.trim(u8, inner[comma + 1 ..], " \t");
                const track = parseOneTrack(max_str) orelse ComputedStyle.GridTrackSize.auto;
                tracks.append(alloc, track) catch return null;
            }
            pos = end;
            continue;
        }

        // Regular token: read until space
        const token_start = pos;
        while (pos < s.len and s[pos] != ' ' and s[pos] != '\t') pos += 1;
        const t = s[token_start..pos];
        if (parseOneTrack(t)) |track| {
            tracks.append(alloc, track) catch return null;
        }
    }
    if (tracks.items.len == 0) return null;
    return tracks.toOwnedSlice(alloc) catch return null;
}

fn parseOneTrack(t: []const u8) ?ComputedStyle.GridTrackSize {
    if (eqlIgnoreCase(t, "auto")) return .auto;
    if (eqlIgnoreCase(t, "min-content") or eqlIgnoreCase(t, "max-content")) return .auto;
    // Handle minmax(min, max) — use max value for sizing
    if (std.mem.startsWith(u8, t, "minmax(")) {
        const start = 7;
        var end = t.len;
        if (end > 0 and t[end - 1] == ')') end -= 1;
        const inner = t[start..end];
        // Find comma separating min and max (respect nested parens)
        var pdepth: usize = 0;
        var comma: ?usize = null;
        for (inner, 0..) |c, i| {
            if (c == '(') pdepth += 1;
            if (c == ')') { if (pdepth > 0) pdepth -= 1; }
            if (c == ',' and pdepth == 0) { comma = i; break; }
        }
        if (comma) |cp| {
            const max_str = std.mem.trim(u8, inner[cp + 1 ..], " \t");
            return parseOneTrack(max_str); // recurse to parse the max value
        }
        return .auto;
    }
    if (std.mem.endsWith(u8, t, "fr")) {
        if (std.fmt.parseFloat(f32, t[0 .. t.len - 2])) |v| return .{ .fr = v } else |_| {}
    }
    if (properties.parseLength(t)) |len| {
        if (len.unit == .percent) return .{ .percent = len.value };
        return .{ .px = resolveLengthToPx(len.value, len.unit, 16.0, 0, 0) };
    }
    return null;
}

fn parseGridLine(s: []const u8) i16 {
    return std.fmt.parseInt(i16, s, 10) catch 0;
}

fn parseDimension(s: []const u8, font_size: f32, vw: f32, vh: f32) ComputedStyle.Dimension {
    if (eqlIgnoreCase(s, "auto")) return .auto;
    if (eqlIgnoreCase(s, "none")) return .none;
    if (properties.parseLength(s)) |len| {
        if (len.unit == .percent) return .{ .percent = len.value };
        return .{ .px = resolveLengthToPx(len.value, len.unit, font_size, vw, vh) };
    }
    if (std.mem.eql(u8, s, "0")) return .{ .px = 0 };
    if (std.fmt.parseFloat(f32, s)) |v| return .{ .px = v } else |_| {}
    return .auto;
}

fn parseDimensionOrNone(s: []const u8, font_size: f32, vw: f32, vh: f32) ComputedStyle.Dimension {
    if (eqlIgnoreCase(s, "none")) return .none;
    return parseDimension(s, font_size, vw, vh);
}

const MarginValue = struct {
    value: f32,
    is_auto: bool,
};

fn parseMarginValue(s: []const u8, font_size: f32, vw: f32, vh: f32) MarginValue {
    if (eqlIgnoreCase(s, "auto")) return .{ .value = 0, .is_auto = true };
    if (parseLengthValue(s, font_size, vw, vh)) |px| return .{ .value = px, .is_auto = false };
    return .{ .value = 0, .is_auto = false };
}

fn parseBorderWidth(s: []const u8, font_size: f32, vw: f32, vh: f32) ?f32 {
    if (eqlIgnoreCase(s, "thin")) return 1.0;
    if (eqlIgnoreCase(s, "medium")) return 3.0;
    if (eqlIgnoreCase(s, "thick")) return 5.0;
    return parseLengthValue(s, font_size, vw, vh);
}

fn mapDisplay(s: []const u8) ?ComputedStyle.Display {
    if (eqlIgnoreCase(s, "block")) return .block;
    if (eqlIgnoreCase(s, "inline")) return .inline_;
    if (eqlIgnoreCase(s, "none")) return .none;
    if (eqlIgnoreCase(s, "flex")) return .flex;
    if (eqlIgnoreCase(s, "inline-block")) return .inline_block;
    if (eqlIgnoreCase(s, "inline-flex")) return .inline_flex;
    if (eqlIgnoreCase(s, "grid")) return .grid;
    if (eqlIgnoreCase(s, "inline-grid")) return .inline_grid;
    if (eqlIgnoreCase(s, "table")) return .table;
    if (eqlIgnoreCase(s, "list-item")) return .list_item;
    if (eqlIgnoreCase(s, "table-row")) return .table_row;
    if (eqlIgnoreCase(s, "table-cell")) return .table_cell;
    if (eqlIgnoreCase(s, "table-row-group")) return .table_row_group;
    if (eqlIgnoreCase(s, "table-header-group")) return .table_header_group;
    if (eqlIgnoreCase(s, "table-footer-group")) return .table_footer_group;
    if (eqlIgnoreCase(s, "table-column")) return .table_column;
    if (eqlIgnoreCase(s, "table-column-group")) return .table_column_group;
    if (eqlIgnoreCase(s, "table-caption")) return .table_caption;
    return null;
}

fn mapOverflow(s: []const u8) ?ComputedStyle.Overflow {
    if (eqlIgnoreCase(s, "visible")) return .visible;
    if (eqlIgnoreCase(s, "hidden") or eqlIgnoreCase(s, "clip")) return .hidden;
    if (eqlIgnoreCase(s, "scroll")) return .scroll;
    if (eqlIgnoreCase(s, "auto")) return .auto_;
    return null;
}

fn parseShadow(
    s: []const u8,
    font_size: f32,
    x: *f32,
    y: *f32,
    blur: *f32,
    color: *u32,
) void {
    if (eqlIgnoreCase(s, "none")) {
        x.* = 0;
        y.* = 0;
        blur.* = 0;
        color.* = 0x00000000;
        return;
    }

    var tokens: [8][]const u8 = undefined;
    var token_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, s, " \t");
    while (iter.next()) |tok| {
        if (token_count >= 8) break;
        if (eqlIgnoreCase(tok, "inset")) continue;
        tokens[token_count] = tok;
        token_count += 1;
    }

    if (token_count < 2) return;
    const xv = parseLengthValue(tokens[0], font_size, 0, 0) orelse return;
    const yv = parseLengthValue(tokens[1], font_size, 0, 0) orelse return;
    x.* = xv;
    y.* = yv;

    var color_start: usize = 2;
    if (token_count >= 3) {
        if (parseLengthValue(tokens[2], font_size, 0, 0)) |b| {
            blur.* = b;
            color_start = 3;
            // Skip spread radius if present
            if (token_count >= 4) {
                if (parseLengthValue(tokens[3], font_size, 0, 0)) |_| {
                    color_start = 4;
                }
            }
        }
    }

    if (color_start < token_count) {
        if (properties.parseColor(tokens[color_start])) |c| {
            color.* = c.toArgb();
        }
    } else {
        color.* = 0x80000000; // default semi-transparent black
    }
}

// ── Collect <style> text from DOM ─────────────────────────────────────

fn collectStyleText(node: DomNode, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try walkForStyles(node, &buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn walkForStyles(node: DomNode, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (node.nodeType() == .element) {
        if (node.tagName()) |tag| {
            // Skip <noscript> — its <style> rules are for JS-disabled browsers only
            if (std.ascii.eqlIgnoreCase(tag, "noscript")) return;
            if (std.ascii.eqlIgnoreCase(tag, "style")) {
                var child = node.firstChild();
                while (child) |c| {
                    if (c.nodeType() == .text) {
                        if (c.textContent()) |text| {
                            try buf.appendSlice(allocator, text);
                            try buf.append(allocator, '\n');
                        }
                    }
                    child = c.nextSibling();
                }
                return;
            }
        }
    }
    var child = node.firstChild();
    while (child) |c| {
        try walkForStyles(c, buf, allocator);
        child = c.nextSibling();
    }
}

// ── String utilities ──────────────────────────────────────────────────

// ── HTML presentational attributes ────────────────────────────────

fn applyHtmlAttributes(node: DomNode, style: *ComputedStyle) void {
    // HTML align attribute → text-align (only if text-align not already set by CSS)
    if (node.getAttribute("align")) |align_val| {
        if (style.text_align == .left) { // default = not set by CSS
            if (eqlIgnoreCase(align_val, "center")) style.text_align = .center
            else if (eqlIgnoreCase(align_val, "right")) style.text_align = .right
            else if (eqlIgnoreCase(align_val, "justify")) style.text_align = .justify;
        }
    }
    // HTML width attribute → width (for td, img, table)
    if (node.getAttribute("width")) |width_val| {
        if (style.width == .auto) {
            if (std.fmt.parseFloat(f32, width_val)) |w| {
                style.width = .{ .px = w };
            } else |_| {
                // Check for percentage: "25%"
                if (width_val.len > 0 and width_val[width_val.len - 1] == '%') {
                    if (std.fmt.parseFloat(f32, width_val[0 .. width_val.len - 1])) |pct| {
                        style.width = .{ .percent = pct };
                    } else |_| {}
                }
            }
        }
    }
    // HTML height attribute → height
    if (node.getAttribute("height")) |height_val| {
        if (style.height == .auto) {
            if (std.fmt.parseFloat(f32, height_val)) |h| {
                style.height = .{ .px = h };
            } else |_| {}
        }
    }
    // HTML bgcolor attribute → background-color
    if (node.getAttribute("bgcolor")) |bg_val| {
        if (style.background_color == 0x00000000) {
            if (properties.parseColor(bg_val)) |c| {
                style.background_color = c.toArgb();
            }
        }
    }
    // HTML valign → vertical-align
    if (node.getAttribute("valign")) |valign_val| {
        if (eqlIgnoreCase(valign_val, "middle")) style.vertical_align = .middle
        else if (eqlIgnoreCase(valign_val, "top")) style.vertical_align = .top
        else if (eqlIgnoreCase(valign_val, "bottom")) style.vertical_align = .bottom;
    }
    // HTML hidden attribute
    if (node.getAttribute("hidden") != null) {
        style.display = .none;
    }
    // data-is-here-when: responsive visibility (Stack Overflow pattern)
    // "md lg" = show on medium/large only. On small screens (< 980px), hide.
    if (node.getAttribute("data-is-here-when")) |when| {
        // If the attribute doesn't include "sm" (small), hide on small screens
        if (std.mem.indexOf(u8, when, "sm") == null) {
            style.display = .none;
        }
    }
}

const eqlIgnoreCase = util.eqlIgnoreCase;

fn toLowerBuf(s: []const u8, buf: *[64]u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = util.toLower(c);
    }
    return buf[0..s.len];
}

/// Extract the URL string from url("..."), url('...'), or url(...).
/// Returns the inner URL with quotes stripped, or null on failure.
fn extractUrl(value: []const u8) ?[]const u8 {
    // Find "url(" prefix
    const open = std.mem.indexOf(u8, value, "(") orelse return null;
    const after_open = open + 1;
    if (after_open >= value.len) return null;

    // Find matching closing paren — respect quotes
    var close: ?usize = null;
    var in_quote: u8 = 0;
    for (value[after_open..], after_open..) |ch, idx| {
        if (in_quote != 0) {
            if (ch == in_quote) in_quote = 0;
        } else if (ch == '"' or ch == '\'') {
            in_quote = ch;
        } else if (ch == ')') {
            close = idx;
            break;
        }
    }
    const close_idx = close orelse return null;
    if (close_idx <= after_open) return null;

    var inner = std.mem.trim(u8, value[after_open..close_idx], " \t\r\n");

    // Strip surrounding quotes if present
    if (inner.len >= 2) {
        if ((inner[0] == '"' and inner[inner.len - 1] == '"') or
            (inner[0] == '\'' and inner[inner.len - 1] == '\''))
        {
            inner = inner[1 .. inner.len - 1];
        }
    }

    if (inner.len == 0) return null;
    // Skip data: URIs (too large, not worth caching as background)
    if (std.mem.startsWith(u8, inner, "data:")) return null;
    return inner;
}

/// Parse linear-gradient(direction, color1, color2) and set gradient fields on style.
/// Returns true if successfully parsed.
fn parseLinearGradient(value: []const u8, style: *ComputedStyle) bool {
    // Match linear-gradient(...) or -webkit-linear-gradient(...)
    var inner: []const u8 = undefined;
    if (std.mem.indexOf(u8, value, "linear-gradient(")) |idx| {
        const start = idx + "linear-gradient(".len;
        // Find matching closing paren (handle nested parens for rgb())
        var depth: u32 = 1;
        var end = start;
        while (end < value.len and depth > 0) {
            if (value[end] == '(') depth += 1;
            if (value[end] == ')') depth -= 1;
            if (depth > 0) end += 1;
        }
        if (depth != 0) return false;
        inner = value[start..end];
    } else return false;

    // Split by commas at depth 0 (respecting parentheses like rgb())
    var parts: [8][]const u8 = undefined;
    var part_count: usize = 0;
    {
        var depth_: u32 = 0;
        var seg_start: usize = 0;
        for (inner, 0..) |ch, i| {
            if (ch == '(') depth_ += 1;
            if (ch == ')') {
                if (depth_ > 0) depth_ -= 1;
            }
            if (ch == ',' and depth_ == 0) {
                if (part_count < parts.len) {
                    parts[part_count] = std.mem.trim(u8, inner[seg_start..i], " \t");
                    part_count += 1;
                }
                seg_start = i + 1;
            }
        }
        if (seg_start < inner.len and part_count < parts.len) {
            parts[part_count] = std.mem.trim(u8, inner[seg_start..], " \t");
            part_count += 1;
        }
    }

    if (part_count < 2) return false;

    // Determine direction and color indices
    var dir = ComputedStyle.GradientDirection.to_bottom;
    var color1_idx: usize = 0;
    var color2_idx: usize = 1;

    const first = parts[0];
    if (eqlIgnoreCase(first, "to right")) {
        dir = .to_right;
        color1_idx = 1;
        color2_idx = if (part_count > 2) 2 else 1;
    } else if (eqlIgnoreCase(first, "to left")) {
        dir = .to_left;
        color1_idx = 1;
        color2_idx = if (part_count > 2) 2 else 1;
    } else if (eqlIgnoreCase(first, "to bottom")) {
        dir = .to_bottom;
        color1_idx = 1;
        color2_idx = if (part_count > 2) 2 else 1;
    } else if (eqlIgnoreCase(first, "to top")) {
        dir = .to_top;
        color1_idx = 1;
        color2_idx = if (part_count > 2) 2 else 1;
    } else if (std.mem.endsWith(u8, first, "deg")) {
        // Parse angle: 0deg=to top, 90deg=to right, 180deg=to bottom, 270deg=to left
        const deg_str = first[0 .. first.len - 3];
        if (std.fmt.parseFloat(f32, deg_str)) |deg| {
            const normalized = @mod(deg, 360.0);
            if (normalized < 45 or normalized >= 315) dir = .to_top
            else if (normalized >= 45 and normalized < 135) dir = .to_right
            else if (normalized >= 135 and normalized < 225) dir = .to_bottom
            else dir = .to_left;
        } else |_| {}
        color1_idx = 1;
        color2_idx = if (part_count > 2) 2 else 1;
    }
    // else: first part is a color, no direction specified

    if (color2_idx >= part_count) return false;

    // Parse colors (strip percentage/position suffixes like "red 0%" → "red")
    const c1_raw = stripColorStop(parts[color1_idx]);
    const c2_raw = stripColorStop(parts[color2_idx]);

    const c1 = properties.parseColor(c1_raw) orelse return false;
    const c2 = properties.parseColor(c2_raw) orelse return false;

    style.gradient_color_start = c1.toArgb();
    style.gradient_color_end = c2.toArgb();
    style.gradient_direction = dir;
    return true;
}

/// Strip color-stop position suffix (e.g., "red 50%" → "red", "#fff 0%" → "#fff")
/// Does NOT strip inside function calls like rgb(), hsl().
fn stripColorStop(raw: []const u8) []const u8 {
    // Don't strip from function values (rgb(...), hsl(...), etc.)
    if (std.mem.indexOf(u8, raw, "(") != null) return raw;

    // Find last space that precedes a number/percentage
    var i = raw.len;
    while (i > 0) {
        i -= 1;
        if (raw[i] == ' ') {
            // Check if the rest looks like a stop position
            const rest = std.mem.trim(u8, raw[i + 1 ..], " ");
            if (rest.len > 0 and (rest[rest.len - 1] == '%' or
                (rest[0] >= '0' and rest[0] <= '9')))
            {
                return std.mem.trim(u8, raw[0..i], " ");
            }
            break;
        }
    }
    return raw;
}
