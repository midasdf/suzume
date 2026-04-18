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

// ── Shadow DOM Phase 2: event retargeting + composedPath ──────────────

test "retargeted-target: listener on host sees event.target = host (not inner)" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\host.setAttribute("id", "host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\inner.setAttribute("id", "inner");
        \\sr.appendChild(inner);
        \\var seenId = "";
        \\host.addEventListener("ping", function(e) { seenId = e.target.id; });
        \\inner.dispatchEvent({ type: "ping", composed: true });
        \\seenId;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("host", val);
}

test "composedPath-composed-true: includes both shadow and light nodes" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\host.setAttribute("id", "host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\inner.setAttribute("id", "inner");
        \\sr.appendChild(inner);
        \\var lenSeen = 0;
        \\var hasHost = 0;
        \\var hasInner = 0;
        \\host.addEventListener("ping", function(e) {
        \\  var p = e.composedPath();
        \\  lenSeen = p.length;
        \\  for (var i = 0; i < p.length; i++) {
        \\    if (p[i].id === "host") hasHost = 1;
        \\    if (p[i].id === "inner") hasInner = 1;
        \\  }
        \\});
        \\inner.dispatchEvent({ type: "ping", composed: true });
        \\"" + hasHost + hasInner;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("11", val);
}

test "composedPath-composed-false: listener outside shadow never fires" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\host.setAttribute("id", "host");
        \\var sr = host.attachShadow({ mode: "open" });
        \\var inner = document.createElement("span");
        \\inner.setAttribute("id", "inner");
        \\sr.appendChild(inner);
        \\var hostFired = 0;
        \\host.addEventListener("ping", function(e) { hostFired = 1; });
        \\inner.dispatchEvent({ type: "ping" });
        \\hostFired ? "fired" : "notfired";
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("notfired", val);
}

test "closed-tree-filtering: listener inside closed shadow sees inner; host listener sees retargeted only" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"host\"></div></body></html>",
        \\var host = document.getElementById("host");
        \\host.setAttribute("id", "host");
        \\var sr = host.attachShadow({ mode: "closed" });
        \\var inner = document.createElement("span");
        \\inner.setAttribute("id", "inner");
        \\sr.appendChild(inner);
        \\var hostSeesInner = 0;
        \\var innerSeesInner = 0;
        \\host.addEventListener("ping", function(e) {
        \\  var p = e.composedPath();
        \\  for (var i = 0; i < p.length; i++)
        \\    if (p[i].id === "inner") hostSeesInner = 1;
        \\});
        \\inner.addEventListener("ping", function(e) {
        \\  var p = e.composedPath();
        \\  for (var i = 0; i < p.length; i++)
        \\    if (p[i].id === "inner") innerSeesInner = 1;
        \\});
        \\inner.dispatchEvent({ type: "ping", composed: true });
        \\"" + hostSeesInner + innerSeesInner;
    );
    defer ctx.deinit();

    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    // host should NOT see the closed-tree inner node, but inner's own listener should.
    try std.testing.expectEqualStrings("01", val);
}

// ══════════════════════════════════════════════════════════════════════
// Element.scroll / scrollTo / scrollBy (CSSOM View §6.5)
// ══════════════════════════════════════════════════════════════════════

test "scrollTo(x, y) sets scrollLeft and scrollTop" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scrollTo(40, 80);
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("40,80", val);
}

test "scrollTo({top, left}) sets position via options dict" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scrollTo({ top: 100, left: 25 });
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("25,100", val);
}

test "scrollBy accumulates delta on top of current position" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scrollTo(10, 20);
        \\el.scrollBy(5, 15);
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("15,35", val);
}

test "scroll() is an alias for scrollTo()" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scroll(7, 3);
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("7,3", val);
}

test "scrollBy clamps to zero (no negative scroll)" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scrollTo(10, 10);
        \\el.scrollBy(-50, -50);
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("0,0", val);
}

test "scrollTop setter directly sets scroll position" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"s\"></div></body></html>",
        \\var el = document.getElementById("s");
        \\el.scrollTop = 55;
        \\el.scrollLeft = 33;
        \\"" + el.scrollLeft + "," + el.scrollTop;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("33,55", val);
}

// ══════════════════════════════════════════════════════════════════════
// HTMLFormElement.submit() / requestSubmit() — HTML §4.10.21.3
// ══════════════════════════════════════════════════════════════════════

test "form.submit() is a no-op on a disconnected form" {
    // Disconnected form: submit() must return undefined without throwing.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var f = document.createElement("form");
        \\var thrown = false;
        \\try { f.submit(); } catch(e) { thrown = true; }
        \\thrown ? "threw" : "ok";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("ok", val);
}

test "form.submit() on connected form dispatches non-cancelable submit event" {
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\var fired = false;
        \\var wasCancelable = true;
        \\f.addEventListener("submit", function(e){ fired = true; wasCancelable = e.cancelable; });
        \\f.submit();
        \\fired + "," + wasCancelable;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("true,false", val);
}

test "form.requestSubmit() on connected form dispatches cancelable submit event" {
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\var fired = false;
        \\var wasCancelable = false;
        \\f.addEventListener("submit", function(e){ fired = true; wasCancelable = e.cancelable; });
        \\f.requestSubmit();
        \\fired + "," + wasCancelable;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("true,true", val);
}

test "form.requestSubmit() is a no-op on a disconnected form" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var f = document.createElement("form");
        \\var fired = false;
        \\f.addEventListener("submit", function(){ fired = true; });
        \\f.requestSubmit();
        \\fired ? "fired" : "noop";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("noop", val);
}

test "form.requestSubmit(submitter) rejects button not belonging to this form" {
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"></form><form id=\"g\"><button id=\"b\"></button></form></body></html>",
        \\var f = document.getElementById("f");
        \\var b = document.getElementById("b");
        \\var threw = false;
        \\try { f.requestSubmit(b); } catch(e) { threw = true; }
        \\threw ? "threw" : "ok";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("threw", val);
}

test "form.requestSubmit() preventDefault cancels submission" {
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\var submits = 0;
        \\f.addEventListener("submit", function(e){ submits++; e.preventDefault(); });
        \\f.requestSubmit();
        \\f.requestSubmit();
        \\"" + submits;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const val = ctx.getResultStr(result) orelse unreachable;
    // Both requestSubmit() calls fired the event; preventDefault was called each time.
    try std.testing.expectEqualStrings("2", val);
}

// ══════════════════════════════════════════════════════════════════════
// Constraint Validation API — HTML Living Standard §4.10.18
// ══════════════════════════════════════════════════════════════════════

test "input.willValidate is true for enabled text input (§4.10.18.2)" {
    // §4.10.18.2: submittable element not barred from constraint validation.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.willValidate ? "true" : "false";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("true", v);
}

test "input[type=hidden].willValidate is false (§4.10.18.2)" {
    // §4.10.18.2: hidden inputs are barred from constraint validation.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"hidden\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.willValidate ? "true" : "false";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("false", v);
}

test "input.validity.valid is true for non-required empty input (§4.10.18.3)" {
    // §4.10.18.3: ValidityState.valid reflects no constraint violations.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.validity.valid ? "valid" : "invalid";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("valid", v);
}

test "required input with empty value has valueMissing (§4.10.18.3)" {
    // §4.10.18.3: valueMissing flag when required + empty value.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" required value=\"\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.validity.valueMissing ? "valueMissing" : "ok";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("valueMissing", v);
}

test "input.checkValidity() returns true for valid input (§4.10.18.4)" {
    // §4.10.18.4: checkValidity returns true when there are no violations.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" value=\"hello\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.checkValidity() ? "valid" : "invalid";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("valid", v);
}

test "input.checkValidity() returns false and fires invalid event (§4.10.18.4)" {
    // §4.10.18.4: checkValidity fires non-bubbling 'invalid' event when invalid.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" required value=\"\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\var fired = false;
        \\i.addEventListener("invalid", function(){ fired = true; });
        \\var result = i.checkValidity();
        \\result + "," + fired;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("false,true", v);
}

test "input.setCustomValidity sets customError (§4.10.18.5)" {
    // §4.10.18.5: setCustomValidity with non-empty string sets customError flag.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" value=\"ok\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.setCustomValidity("bad value");
        \\i.validity.customError ? "customError" : "none";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("customError", v);
}

test "input.setCustomValidity('') clears customError (§4.10.18.5)" {
    // §4.10.18.5: empty string clears the custom validity message.
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" value=\"ok\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.setCustomValidity("bad");
        \\i.setCustomValidity("");
        \\i.validity.customError ? "customError" : "cleared";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("cleared", v);
}

test "input.reportValidity() returns true for valid input (§4.10.18.4)" {
    var ctx = try TestCtx.init(
        "<html><body><form><input id=\"i\" type=\"text\" value=\"hello\"></form></body></html>",
        \\var i = document.getElementById("i");
        \\i.reportValidity() ? "valid" : "invalid";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("valid", v);
}

test "form.checkValidity() returns false when input is invalid (§4.10.21.2)" {
    // §4.10.21.2: statically validate the constraints — form returns false if
    // any submittable element is invalid.
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"><input id=\"i\" type=\"text\" required value=\"\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\f.checkValidity() ? "valid" : "invalid";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("invalid", v);
}

test "form.checkValidity() returns true when all inputs are valid (§4.10.21.2)" {
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"><input id=\"i\" type=\"text\" value=\"hello\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\f.checkValidity() ? "valid" : "invalid";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("valid", v);
}

// ══════════════════════════════════════════════════════════════════════
// HTMLFormElement.elements / length — HTML Living Standard §4.10.21.1
// ══════════════════════════════════════════════════════════════════════

test "form.elements returns collection of submittable elements (§4.10.21.1)" {
    // §4.10.21.1: elements is an HTMLFormControlsCollection of listed elements.
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"><input type=\"text\"><select><option>a</option></select><textarea></textarea><button type=\"button\"></button></form></body></html>",
        \\var f = document.getElementById("f");
        \\f.elements.length + "";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("4", v);
}

test "form.length reflects element count (§4.10.21.1)" {
    // §4.10.21.1: form.length is the number of listed elements.
    var ctx = try TestCtx.init(
        "<html><body><form id=\"f\"><input type=\"text\"><input type=\"text\"></form></body></html>",
        \\var f = document.getElementById("f");
        \\f.length + "";
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const v = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("2", v);
}

// ══════════════════════════════════════════════════════════════════════
// _ownerDoc slot / ownerDocument getter (DOM §4.4)
//
// The ownerDocument getter now reads the per-node `_ownerDoc` slot
// instead of returning globalThis.document. Every wrapper/creator site
// in kotori_dom.zig must write the slot so cross-document operations
// (importNode, createHTMLDocument, createDocument) resolve correctly.
// These tests anchor that contract end-to-end through JS.
// ══════════════════════════════════════════════════════════════════════

test "document.ownerDocument === null (DOM §4.4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\document.ownerDocument === null;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "createElement().ownerDocument === document (DOM §4.4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement("div");
        \\el.ownerDocument === document;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "parsed element ownerDocument === document (DOM §4.4)" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var el = document.getElementById("t");
        \\el.ownerDocument === document;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "createTextNode().ownerDocument === document (DOM §4.4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var t = document.createTextNode("hi");
        \\t.ownerDocument === document;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "createHTMLDocument() new-doc children ownerDocument !== outer document (DOM §7.1)" {
    // DOMImplementation.createHTMLDocument returns a brand-new Document;
    // its descendants' ownerDocument must equal *that* document — not
    // the outer/original document. This is the regression the
    // `_ownerDoc` slot fixes: before, `ownerDocument` always returned
    // `globalThis.document`, masking cross-doc identity.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var d = document.implementation.createHTMLDocument("T");
        \\var el = d.createElement("div");
        \\// Two contracts in one: the new doc is NOT the outer doc,
        \\// and an element created by the new doc reports the new doc
        \\// as its ownerDocument (not the outer one).
        \\(d !== document) && (el.ownerDocument === d) && (el.ownerDocument !== document);
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "cloneNode() preserves ownerDocument (DOM §4.4.1)" {
    var ctx = try TestCtx.init(
        "<html><body><div id=\"t\"></div></body></html>",
        \\var a = document.getElementById("t");
        \\var b = a.cloneNode(true);
        \\b.ownerDocument === document && b.ownerDocument === a.ownerDocument;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "cloneNode sets slot from lexbor clone's owner_document (Option A verification)" {
    // Verifies that wrapNode alone — without any post-hoc setNodeOwnerDoc
    // override — produces the correct ownerDocument on the clone.
    // If lxb_dom_node_clone preserves owner_document (which it does for
    // same-document clones), the _ownerDoc slot comes from wrapNode's
    // lexbor read path rather than an explicit write after the fact.
    var ctx = try TestCtx.init(
        "<html><body><p id=\"src\"><span>text</span></p></body></html>",
        \\var src = document.getElementById("src");
        \\var clone = src.cloneNode(true);
        \\// Both shallow and deep clone must report the same document.
        \\var shallow = src.cloneNode(false);
        \\clone.ownerDocument === document &&
        \\  clone.ownerDocument === src.ownerDocument &&
        \\  shallow.ownerDocument === document;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "importNode sets target as ownerDocument recursively (deep clone) (DOM §4.5)" {
    // DOM §4.5 "import a node": the result and every descendant in the
    // cloned subtree must have the target document (the receiver of the
    // importNode call) as its ownerDocument — not the source node's
    // owner document. This exercises cloneNodeImpl's owner_doc_override
    // path on both the root and children.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var src = document.implementation.createHTMLDocument("src");
        \\var p = src.createElement("p");
        \\var span = src.createElement("span");
        \\p.appendChild(span);
        \\// Target doc is the outer document (this === document binding).
        \\var clone = document.importNode(p, true);
        \\var child = clone.firstChild || (clone.childNodes && clone.childNodes[0]);
        \\// The clone and its child must report the outer document.
        \\(clone.ownerDocument === document) &&
        \\  (clone.ownerDocument !== src) &&
        \\  (child !== null) &&
        \\  (child.ownerDocument === document);
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "cloneNode preserves source ownerDocument (cross-document) (DOM §4.4.1)" {
    // In contrast to importNode, cloneNode keeps the source document as
    // the owner. cloneNodeImpl is called with owner_doc_override=null
    // so wrapNode's lexbor-derived slot wins.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var d = document.implementation.createHTMLDocument("A");
        \\var el = d.createElement("div");
        \\var cl = el.cloneNode(true);
        \\// Clone's ownerDocument must be d (the source doc), not the
        \\// outer `document` that called the script.
        \\(cl.ownerDocument === d) && (cl.ownerDocument !== document);
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "impl.createHTMLDocument returned doc supports importNode (DOM §4.5)" {
    // Documents returned from implementation.createHTMLDocument must have
    // nativeImportNode registered so that cross-document import works.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var d1 = document.implementation.createHTMLDocument('A');
        \\var d2 = document.implementation.createHTMLDocument('B');
        \\var el = d1.createElement('div');
        \\var clone = d2.importNode(el, true);
        \\clone.ownerDocument === d2;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "importNode with zero args throws TypeError (DOM §4.5 step 1)" {
    // DOM §4.5 step 1: calling importNode() with no arguments must throw TypeError.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\(function(){
        \\  try { document.importNode(); return false; }
        \\  catch(e) { return e instanceof TypeError; }
        \\})()
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

// ══════════════════════════════════════════════════════════════════════
// Task 3: Element.attributes — NamedNodeMap (DOM §4.9.1)
// ══════════════════════════════════════════════════════════════════════

test "el.attributes exposes ALL attributes via indexed access (DOM §4.9.1)" {
    // Regression guard for the one-line bug where iteration walked the
    // generic node.next sibling chain instead of the lexbor attr list,
    // which only ever exposed the first attribute.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\el.setAttribute('c', '3');
        \\el.attributes.length;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isNumber());
    try std.testing.expectEqual(@as(f64, 3), result.asNumber());
}

test "el.attributes[2].name is the third attr (DOM §4.9.1)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\el.setAttribute('c', '3');
        \\el.attributes[2].name;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const name = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("c", name);
}

test "el.attributes[0] === el.attributes[0] — Attr identity (DOM §4.9.1)" {
    // WebIDL §3.1 object identity: repeated access to the same Attr must
    // return the same JS wrapper. Implemented via g_attr_wrappers keyed on
    // the lexbor attr pointer.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('x', '1');
        \\el.attributes[0] === el.attributes[0];
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool() and result.asBool());
}

test "el.attributes is live: removeAttribute drops entry (DOM §4.9.1)" {
    // NamedNodeMap is live: mutations to the element's attribute list
    // must be reflected immediately by the next .attributes access.
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('a', '1');
        \\el.setAttribute('b', '2');
        \\var before = el.attributes.length;
        \\el.removeAttribute('a');
        \\var after = el.attributes.length;
        \\[before, after].join(',');
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const s = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("2,1", s);
}

test "el.attributes is live: setAttribute on new name grows length" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\var before = el.attributes.length;
        \\el.setAttribute('a', '1');
        \\var after = el.attributes.length;
        \\[before, after].join(',');
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const s = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("0,1", s);
}

test "setAttribute overwrites: cache invalidated, value reflects new" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('x', 'old');
        \\var a1 = el.attributes[0];
        \\el.setAttribute('x', 'new');
        \\var a2 = el.attributes[0];
        \\a2.value;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    const s = ctx.getResultStr(result) orelse unreachable;
    try std.testing.expectEqualStrings("new", s);
}

// ══════════════════════════════════════════════════════════════════════
// Task 5: Interface prototype hierarchy (spec §3.5)
// ══════════════════════════════════════════════════════════════════════

test "HTMLDivElement.prototype chains to HTMLElement.prototype chains to Element.prototype" {
    var ctx = try TestCtx.init("<html><body></body></html>", "null;");
    defer ctx.deinit();
    const div_proto = kotori_dom.getHtmlProto("HTMLDivElement") orelse return error.MissingDivProto;
    const html_element_proto = kotori_dom.getHtmlElementProto() orelse return error.MissingHtmlElementProto;
    try std.testing.expectEqual(html_element_proto, div_proto.prototype.?);
    try std.testing.expectEqual(ctx.vm.element_proto.?, html_element_proto.prototype.?);
}

test "SVGCircleElement.prototype chains to SVGElement.prototype chains to Element.prototype" {
    var ctx = try TestCtx.init("<html><body></body></html>", "null;");
    defer ctx.deinit();
    const circle_proto = kotori_dom.getSvgProto("SVGCircleElement") orelse return error.MissingCircleProto;
    const svg_element_proto = kotori_dom.getSvgElementProto() orelse return error.MissingSvgElementProto;
    try std.testing.expectEqual(svg_element_proto, circle_proto.prototype.?);
    try std.testing.expectEqual(ctx.vm.element_proto.?, svg_element_proto.prototype.?);
}

test "MathMLElement.prototype chains to Element.prototype" {
    var ctx = try TestCtx.init("<html><body></body></html>", "null;");
    defer ctx.deinit();
    const mathml_element_proto = kotori_dom.getMathMLElementProto() orelse return error.MissingMathMLProto;
    try std.testing.expectEqual(ctx.vm.element_proto.?, mathml_element_proto.prototype.?);
}

// ══════════════════════════════════════════════════════════════════════
// Task 7: applyInterfaceProto — 4-wrapper-site interface dispatch
// (DOM §4.5.3 + HTML §4 + SVG2 §4 + MathML Core §2)
// ══════════════════════════════════════════════════════════════════════

test "createElement('div') has HTMLDivElement prototype" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\[el instanceof HTMLDivElement,
        \\ el instanceof HTMLElement,
        \\ el instanceof Element]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    try std.testing.expect(items[2].isBool() and items[2].asBool());
}

test "createElement('div') is NOT instance of HTMLAnchorElement (shared-proto bug gone)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el instanceof HTMLAnchorElement
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "createElementNS(SVG_NS, 'circle') is SVGCircleElement, not HTMLElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        \\[c instanceof SVGCircleElement, c instanceof HTMLElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and !items[1].asBool());
}

test "createElementNS with HTML NS and uppercase → HTMLUnknownElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElementNS('http://www.w3.org/1999/xhtml', 'DIV');
        \\el instanceof HTMLUnknownElement
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ══════════════════════════════════════════════════════════════════════
// Task 8: Spec §6.1 gap-fill — items 2,3,4,5,6,7,8,10,11,12,18
// ══════════════════════════════════════════════════════════════════════

// §6.1 item 2 — createElement('DIV') lowercases to HTMLDivElement
test "createElement('DIV') lowercases: instanceof HTMLDivElement, tagName='DIV'" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('DIV');
        \\[el instanceof HTMLDivElement, el instanceof HTMLElement, el.tagName]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    // instanceof HTMLDivElement
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    // instanceof HTMLElement
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    // tagName is uppercased 'DIV'
    const tag = ctx.getResultStr(items[2]) orelse return error.NotAString;
    try std.testing.expectEqualStrings("DIV", tag);
}

// §6.1 item 3 — createElement('input') → HTMLInputElement
test "createElement('input') instanceof HTMLInputElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('input');
        \\[el instanceof HTMLInputElement, el instanceof HTMLElement, el instanceof Element]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    try std.testing.expect(items[2].isBool() and items[2].asBool());
}

// §6.1 item 4 — createElement('xfoo') → HTMLUnknownElement (JS-level)
test "createElement('xfoo') instanceof HTMLUnknownElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('xfoo');
        \\[el instanceof HTMLUnknownElement, el instanceof HTMLElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and items[1].asBool());
}

// §6.1 item 5 — createElement('foo-bar') → HTMLElement (custom name, JS-level)
test "createElement('foo-bar') instanceof HTMLElement (custom element name)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('foo-bar');
        \\[el instanceof HTMLElement, el instanceof HTMLUnknownElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    // instanceof HTMLElement = true
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    // instanceof HTMLUnknownElement = false (valid custom name is HTMLElement, not unknown)
    try std.testing.expect(items[1].isBool() and !items[1].asBool());
}

// §6.1 item 6 — createElement('123') throws InvalidCharacterError
test "createElement('123') throws InvalidCharacterError (digit-leading name)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var threw = false;
        \\try { document.createElement('123'); } catch(e) {
        \\  threw = (e.name === 'InvalidCharacterError');
        \\}
        \\threw
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// §6.1 item 7 — createElementNS(null, 'div') → Element only, not HTMLDivElement
test "createElementNS(null, 'div') gives Element, not HTMLDivElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElementNS(null, 'div');
        \\[el instanceof Element, el instanceof HTMLDivElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    // instanceof Element = true
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    // instanceof HTMLDivElement = false (null namespace)
    try std.testing.expect(items[1].isBool() and !items[1].asBool());
}

// §6.1 item 8 — createElementNS(HTML_NS, 'div') → HTMLDivElement
test "createElementNS(HTML_NS, 'div') instanceof HTMLDivElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElementNS('http://www.w3.org/1999/xhtml', 'div');
        \\[el instanceof HTMLDivElement, el instanceof HTMLElement, el instanceof Element]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    try std.testing.expect(items[2].isBool() and items[2].asBool());
}

// §6.1 item 10 — createElementNS(SVG_NS, 'circle') is SVGCircleElement AND SVGElement AND Element
test "createElementNS(SVG_NS,'circle') instanceof SVGCircleElement, SVGElement, Element" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
        \\[c instanceof SVGCircleElement, c instanceof SVGElement, c instanceof Element]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    try std.testing.expect(items[2].isBool() and items[2].asBool());
}

// §6.1 item 11 — createElementNS(SVG_NS, 'foo') → SVGElement only (unknown SVG fallback)
test "createElementNS(SVG_NS,'foo') instanceof SVGElement, not SVGCircleElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElementNS('http://www.w3.org/2000/svg', 'foo');
        \\[el instanceof SVGElement, el instanceof SVGCircleElement, el instanceof HTMLElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    // instanceof SVGElement = true
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    // instanceof SVGCircleElement = false
    try std.testing.expect(items[1].isBool() and !items[1].asBool());
    // instanceof HTMLElement = false
    try std.testing.expect(items[2].isBool() and !items[2].asBool());
}

// §6.1 item 12 — createElementNS(MATH_NS, 'mi') → MathMLElement (JS-level)
test "createElementNS(MATH_NS,'mi') instanceof MathMLElement" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElementNS('http://www.w3.org/1998/Math/MathML', 'mi');
        \\[el instanceof MathMLElement, el instanceof Element, el instanceof HTMLElement]
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isObject());
    const arr = result.asJsObject();
    try std.testing.expect(arr.data == .array);
    const items = arr.data.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    // instanceof MathMLElement = true
    try std.testing.expect(items[0].isBool() and items[0].asBool());
    // instanceof Element = true
    try std.testing.expect(items[1].isBool() and items[1].asBool());
    // instanceof HTMLElement = false
    try std.testing.expect(items[2].isBool() and !items[2].asBool());
}

// §6.1 item 18 — XMLDocument.createElement('foo').ownerDocument === that XML doc
test "XMLDocument createElement('foo').ownerDocument === the XML doc (DOM §4.4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var xmlDoc = document.implementation.createDocument(null, '', null);
        \\var el = xmlDoc.createElement('foo');
        \\(el.ownerDocument === xmlDoc) && (el.ownerDocument !== document)
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// ══════════════════════════════════════════════════════════════════════
// Layer 1D — NamedNodeMap (DOM §4.9.2)
// ══════════════════════════════════════════════════════════════════════

// Task 1: prototype + constructor registration.
test "NamedNodeMap constructor + prototype installed (Layer 1D Task 1)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\typeof NamedNodeMap === 'function' &&
        \\typeof NamedNodeMap.prototype === 'object' &&
        \\NamedNodeMap.prototype.constructor === NamedNodeMap;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "new NamedNodeMap() throws (WebIDL §3.6.1)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var threw = false;
        \\try { new NamedNodeMap(); } catch (e) { threw = true; }
        \\threw;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// Task 2: el.attributes links to NamedNodeMap.prototype.
test "el.attributes __proto__ === NamedNodeMap.prototype (Layer 1D Task 2)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\Object.getPrototypeOf(el.attributes) === NamedNodeMap.prototype;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "el.attributes[0] and el.attributes['id'] still resolve after Task 2" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes[0].value === 'x' && el.attributes['id'].value === 'x' &&
        \\el.attributes.length === 1;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// Task 3: el.attributes === el.attributes identity invariant.
test "el.attributes === el.attributes (identity cache, Layer 1D Task 3)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\el.attributes === el.attributes;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

// Task 4: liveness — cached map reflects mutations on next read.
test "NamedNodeMap liveness: length + named access update after setAttribute (Layer 1D Task 4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\var m = el.attributes;
        \\var before = m.length;
        \\el.setAttribute('id', 'x');
        \\before === 0 && m.length === 1 && m['id'].value === 'x';
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "NamedNodeMap liveness: length drops after removeAttribute (Layer 1D Task 4)" {
    var ctx = try TestCtx.init(
        "<html><body></body></html>",
        \\var el = document.createElement('div');
        \\el.setAttribute('id', 'x');
        \\var m = el.attributes;
        \\var before = m.length;
        \\el.removeAttribute('id');
        \\before === 1 && m.length === 0;
    );
    defer ctx.deinit();
    const result = try ctx.run();
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}
