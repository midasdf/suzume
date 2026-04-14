//! Integration tests for kotori DOM bindings.
//! Parses HTML via Lexbor, runs JS through kotori VM with DOM bindings,
//! and verifies DOM mutations.

const std = @import("std");
const kotori = @import("kotori");
const kotori_dom = @import("kotori_dom");

const VM = kotori.VM;
const JsValue = kotori.JsValue;
const Compiler = kotori.Compiler;
const Bytecode = kotori.Bytecode;
const StringPool = kotori.StringPool;

// ── Lexbor C types ──────────────────────────────────────────────────
const lxb = @cImport({
    @cDefine("LEXBOR_STATIC", "");
    @cInclude("lexbor/dom/interfaces/element.h");
    @cInclude("lexbor/dom/interfaces/node.h");
});

// ── Lexbor extern functions ─────────────────────────────────────────
extern fn lxb_html_document_create() ?*anyopaque;
extern fn lxb_html_document_destroy(doc: ?*anyopaque) ?*anyopaque;
extern fn lxb_html_document_parse(doc: ?*anyopaque, html: [*]const u8, size: usize) u32;
extern fn lxb_html_document_body_element_noi(doc: ?*anyopaque) ?*lxb.lxb_dom_node_t;
extern fn lxb_dom_node_text_content(node: *lxb.lxb_dom_node_t, len: *usize) ?[*]const u8;
extern fn lxb_dom_element_get_attribute(elem: *lxb.lxb_dom_element_t, qn: [*]const u8, qn_len: usize, val_len: *usize) ?[*]const u8;

// ══════════════════════════════════════════════════════════════════════
// Test helpers
// ══════════════════════════════════════════════════════════════════════

const TestCtx = struct {
    doc: *anyopaque,
    vm: VM,
    compiler: Compiler,
    bc: Bytecode,
    arena: std.heap.ArenaAllocator,

    fn init(html: []const u8, js_src: []const u8) !TestCtx {
        // Parse HTML
        const doc = lxb_html_document_create() orelse return error.LexborFailed;
        if (lxb_html_document_parse(doc, html.ptr, html.len) != 0) {
            _ = lxb_html_document_destroy(doc);
            return error.LexborParseFailed;
        }

        // Arena allocator for all kotori allocations (bulk-freed on deinit)
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const alloc = arena.allocator();

        // Compile JS
        var compiler = Compiler.init(alloc, js_src);
        var bc = try compiler.compile();

        // Create VM
        var vm = VM.init(alloc, &bc, compiler.parser.pool);
        try vm.initBuiltins();

        // Init DOM bindings
        try kotori_dom.initDomBuiltins(&vm, doc);

        return .{
            .doc = doc,
            .vm = vm,
            .compiler = compiler,
            .bc = bc,
            .arena = arena,
        };
    }

    fn run(self: *TestCtx) !JsValue {
        return self.vm.execute();
    }

    fn getBody(self: *TestCtx) ?*lxb.lxb_dom_node_t {
        return lxb_html_document_body_element_noi(self.doc);
    }

    fn getTextContent(node: *lxb.lxb_dom_node_t) ?[]const u8 {
        var len: usize = 0;
        if (lxb_dom_node_text_content(node, &len)) |ptr|
            return ptr[0..len];
        return null;
    }

    fn getAttr(elem: *lxb.lxb_dom_element_t, name: []const u8) ?[]const u8 {
        var len: usize = 0;
        if (lxb_dom_element_get_attribute(elem, name.ptr, name.len, &len)) |ptr|
            return ptr[0..len];
        return null;
    }

    fn getResultStr(self: *TestCtx, val: JsValue) ?[]const u8 {
        if (val.isString()) return self.vm.pool.get(val.asStringId());
        return null;
    }

    fn deinit(self: *TestCtx) void {
        kotori_dom.deinit();
        // Arena bulk-frees all kotori allocations
        self.arena.deinit();
        _ = lxb_html_document_destroy(self.doc);
    }
};

// ══════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════

test "getElementById returns element" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"test\">Hello</div></body></html>",
        \\var el = document.getElementById("test");
        \\el.tagName;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const tag = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("DIV", tag);
}

test "getElementById returns null for missing" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"test\">Hello</div></body></html>",
        \\document.getElementById("nope");
    );
    defer ctx.deinit();

    const result = try ctx.run();
    try std.testing.expect(result.isNull());
}

test "textContent read" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\">Hello World</div></body></html>",
        \\var el = document.getElementById("t");
        \\el.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("Hello World", text);
}

test "textContent write" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\">Old</div></body></html>",
        \\var el = document.getElementById("t");
        \\el.textContent = "New";
    );
    defer ctx.deinit();

    _ = try ctx.run();
    try std.testing.expect(kotori_dom.dom_dirty);

    // Verify via Lexbor directly
    const body = ctx.getBody() orelse unreachable;
    // body > div#t is first child
    const div = body.first_child orelse unreachable;
    const text = TestCtx.getTextContent(div) orelse unreachable;
    try std.testing.expectEqualStrings("New", text);
}

test "innerHTML read" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"><span>Hi</span></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.innerHTML;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const html = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("<span>Hi</span>", html);
}

test "innerHTML write" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\">Old</div></body></html>",
        \\var el = document.getElementById("t");
        \\el.innerHTML = "<b>Bold</b>";
    );
    defer ctx.deinit();

    _ = try ctx.run();
    try std.testing.expect(kotori_dom.dom_dirty);
}

test "createElement and appendChild" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"container\"></div></body></html>",
        \\var c = document.getElementById("container");
        \\var p = document.createElement("p");
        \\p.textContent = "Added";
        \\c.appendChild(p);
        \\c.innerHTML;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const html = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("<p>Added</p>", html);
}

test "setAttribute and getAttribute" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.setAttribute("data-value", "42");
        \\el.getAttribute("data-value");
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("42", val);
}

test "className read/write" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\" class=\"old\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.className = "new-class";
        \\el.className;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const cls = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("new-class", cls);
}

test "style property read/write" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\" style=\"color: blue;\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.style.color;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const color = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("blue", color);
}

test "style property write via camelCase" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.style.backgroundColor = "red";
        \\el.style.backgroundColor;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const bg = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("red", bg);
}

test "querySelector by class" {
    var ctx = try TestCtx.init(
        "<html><body><div class=\"foo\">A</div><div class=\"bar\">B</div></body></html>",
        \\var el = document.querySelector(".bar");
        \\el.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("B", text);
}

test "querySelector by tag" {
    var ctx = try TestCtx.init(
        "<html><body><span>First</span><p>Second</p></body></html>",
        \\var el = document.querySelector("p");
        \\el.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("Second", text);
}

test "querySelector by tag.class" {
    var ctx = try TestCtx.init(
        "<html><body><div class=\"a\">X</div><p class=\"a\">Y</p></body></html>",
        \\var el = document.querySelector("p.a");
        \\el.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("Y", text);
}

test "DOM traversal: parentNode, firstChild, nextSibling" {
    var ctx = try TestCtx.init(
        "<html><body><ul id=\"list\"><li>A</li><li>B</li></ul></body></html>",
        \\var ul = document.getElementById("list");
        \\var first = ul.firstElementChild;
        \\var second = first.nextElementSibling;
        \\second.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("B", text);
}

test "createTextNode and appendChild" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\var tn = document.createTextNode("hello");
        \\el.appendChild(tn);
        \\el.textContent;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const text = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("hello", text);
}

test "addEventListener stores listener" {
    var ctx = try TestCtx.init(
        "<html><body><button id=\"btn\">Click</button></body></html>",
        \\var btn = document.getElementById("btn");
        \\btn.addEventListener("click", function() { });
    );
    defer ctx.deinit();

    _ = try ctx.run();
    const listeners = kotori_dom.getListeners();
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqualStrings("click", listeners[0].event_type);
}

test "document.body access" {
    var ctx = try TestCtx.init(
        "<html><body><p>Hello</p></body></html>",
        \\document.body.tagName;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const tag = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("BODY", tag);
}

test "nodeType returns element type" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.nodeType;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    // ELEMENT_NODE = 1
    try std.testing.expectEqual(@as(f64, 1.0), result.asNumber());
}

test "children returns array of elements" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"p\"><span>A</span><span>B</span></div></body></html>",
        \\var el = document.getElementById("p");
        \\el.children.length;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    try std.testing.expectEqual(@as(f64, 2.0), result.asNumber());
}

test "removeChild detaches node" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"p\"><span id=\"c\">X</span></div></body></html>",
        \\var p = document.getElementById("p");
        \\var c = document.getElementById("c");
        \\p.removeChild(c);
        \\p.innerHTML;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const html = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("", html);
}

// ── Shadow DOM Phase 1: JS-runtime behavioral tests ──────────────────

test "attachShadow-twice-throws NotSupportedError" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\host.attachShadow({ mode: "open" });
        \\var caught = "";
        \\try {
        \\  host.attachShadow({ mode: "open" });
        \\} catch (e) {
        \\  caught = e.name;
        \\}
        \\caught;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const name = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("NotSupportedError", name);
}

test "querySelector-scoping: light tree querySelector does not find shadow tree elements" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\inner.setAttribute("id", "inner-span");
        \\sr.appendChild(inner);
        \\var found = document.querySelector("#inner-span");
        \\found === null ? "null" : "found";
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("null", val);
}

test "outerHTML-excludes-shadow: host outerHTML does not contain shadow content" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var p = document.createElement("p");
        \\p.textContent = "shadow-content";
        \\sr.appendChild(p);
        \\host.outerHTML;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const html = ctx.getResultStr(result) orelse unreachable;
    // outerHTML must not contain the shadow tree paragraph
    const has_shadow = std.mem.indexOf(u8, html, "shadow-content") != null;
    try std.testing.expect(!has_shadow);
}

test "getRootNode-composed: false returns ShadowRoot, true returns document" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\sr.appendChild(inner);
        \\var rootDefault = inner.getRootNode();
        \\var rootComposed = inner.getRootNode({ composed: true });
        \\var isShadowRoot = (rootDefault.__isShadowRoot === true) ? "shadow" : "other";
        \\var isDoc = (rootComposed === document) ? "document" : "other";
        \\isShadowRoot + "+" + isDoc;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("shadow+document", val);
}

test "isConnected-in-shadow: element inside shadow tree of connected host is connected" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\sr.appendChild(inner);
        \\inner.isConnected ? "connected" : "disconnected";
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("connected", val);
}
