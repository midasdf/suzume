/// Integration tests — extracted from main.zig.
/// These tests require a running network and JS runtime.
/// Run with: zig build test-integration or via --test-js/--test-dom-js/--test-http flags.
const std = @import("std");
const Document = @import("../src/dom/tree.zig").Document;
const JsRuntime = @import("../src/js/runtime.zig").JsRuntime;
const dom_api = @import("../src/js/dom_api.zig");
const events = @import("../src/js/events.zig");
const web_api = @import("../src/js/web_api.zig");
const HttpClient = @import("../src/net/http.zig").HttpClient;
const script_executor = @import("../src/core/script_executor.zig");
const lxb = @import("../src/bindings/lexbor.zig").c;

pub fn testHttp(allocator: std.mem.Allocator) !void {
    std.debug.print("=== HTTP Client Test ===\n", .{});
    var client = HttpClient.init() catch |err| {
        std.debug.print("Failed to init HTTP client: {}\n", .{err});
        return err;
    };
    defer client.deinit();
    std.debug.print("Fetching http://example.com ...\n", .{});
    var response = client.get(allocator, "http://example.com") catch |err| {
        std.debug.print("Failed to fetch: {}\n", .{err});
        return err;
    };
    defer response.deinit();
    std.debug.print("Status: {d}\n", .{response.status_code});
    std.debug.print("Content-Type: {s}\n", .{response.content_type});
    std.debug.print("Body length: {d} bytes\n", .{response.body.len});
    const preview_len = @min(response.body.len, 200);
    std.debug.print("Body preview:\n{s}\n", .{response.body[0..preview_len]});
    std.debug.print("=== Test complete ===\n", .{});
}

pub fn testJs() void {
    std.debug.print("=== QuickJS-ng Integration Test ===\n", .{});

    var js_rt = JsRuntime.init() catch |err| {
        std.debug.print("Failed to init JS runtime: {}\n", .{err});
        return;
    };
    defer js_rt.deinit();

    // Test 1: arithmetic
    {
        const result = js_rt.eval("1 + 2");
        defer result.deinit();
        std.debug.print("  1 + 2 = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "3")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 2: string concatenation
    {
        const result = js_rt.eval("'hello ' + 'world'");
        defer result.deinit();
        std.debug.print("  'hello ' + 'world' = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "hello world")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 3: JSON.stringify
    {
        const result = js_rt.eval("JSON.stringify({a: 1})");
        defer result.deinit();
        std.debug.print("  JSON.stringify({{a: 1}}) = {s} {s}\n", .{
            result.value(),
            if (std.mem.eql(u8, result.value(), "{\"a\":1}")) "[PASS]" else "[FAIL]",
        });
    }

    // Test 4: console.log
    std.debug.print("  console.log test (expect '[JS:LOG] Hello from JS!' on stderr):\n", .{});
    {
        const result = js_rt.eval("console.log('Hello from JS!')");
        defer result.deinit();
        std.debug.print("  console.log returned: {s} {s}\n", .{
            result.value(),
            if (result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 5: console.warn and console.error
    {
        const result = js_rt.eval("console.warn('warning!'); console.error('error!')");
        defer result.deinit();
        std.debug.print("  console.warn/error: {s}\n", .{if (result.isOk()) "[PASS]" else "[FAIL]"});
    }

    // Test 6: setTimeout
    std.debug.print("  setTimeout test (expect '[JS:LOG] delayed!' on stderr):\n", .{});
    {
        const result = js_rt.eval("setTimeout(() => console.log('delayed!'), 50)");
        defer result.deinit();
        std.debug.print("  setTimeout returned timer id: {s} {s}\n", .{
            result.value(),
            if (result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    // Run the timer loop
    {
        var iterations: u32 = 0;
        while (web_api.hasTimers() and iterations < 200) : (iterations += 1) {
            _ = web_api.tickTimers(js_rt.ctx);
            js_rt.executePending();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        std.debug.print("  Timer loop finished after {d} iterations {s}\n", .{
            iterations,
            if (!web_api.hasTimers()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 7: setInterval + clearInterval
    std.debug.print("  setInterval/clearInterval test:\n", .{});
    {
        const result = js_rt.eval(
            \\var count = 0;
            \\var id = setInterval(function() {
            \\    count++;
            \\    console.log('tick ' + count);
            \\    if (count >= 3) clearInterval(id);
            \\}, 30);
            \\id
        );
        defer result.deinit();

        var iterations: u32 = 0;
        while (web_api.hasTimers() and iterations < 200) : (iterations += 1) {
            _ = web_api.tickTimers(js_rt.ctx);
            js_rt.executePending();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        std.debug.print("  setInterval loop finished after {d} iterations {s}\n", .{
            iterations,
            if (!web_api.hasTimers()) "[PASS]" else "[FAIL]",
        });
    }

    // Test 8: error handling
    {
        const result = js_rt.eval("undeclared_variable");
        defer result.deinit();
        std.debug.print("  error handling: {s} {s}\n", .{
            result.value(),
            if (!result.isOk()) "[PASS]" else "[FAIL]",
        });
    }

    std.debug.print("=== All JS tests done ===\n", .{});
}

pub fn testDomJs() void {
    std.debug.print("=== DOM + JS Integration Test ===\n", .{});

    const html =
        \\<html><body>
        \\<button id="btn">Click me</button>
        \\<p id="output">...</p>
        \\<div class="container"><span class="item">A</span><span class="item">B</span></div>
        \\<script>
        \\  var btn = document.getElementById("btn");
        \\  console.log("Test1 getElementById: " + (btn ? "PASS" : "FAIL"));
        \\  console.log("Test2 tagName: " + (btn.tagName === "BUTTON" ? "PASS" : "FAIL"));
        \\  console.log("Test3 textContent: " + (btn.textContent === "Click me" ? "PASS" : "FAIL"));
        \\  var output = document.getElementById("output");
        \\  output.textContent = "Changed!";
        \\  console.log("Test4 setTextContent: " + (output.textContent === "Changed!" ? "PASS" : "FAIL"));
        \\  btn.setAttribute("data-test", "hello");
        \\  console.log("Test5 setAttribute: " + (btn.getAttribute("data-test") === "hello" ? "PASS" : "FAIL"));
        \\  var body = document.body;
        \\  console.log("Test6 body: " + (body ? "PASS" : "FAIL"));
        \\  var container = document.querySelector(".container");
        \\  console.log("Test7 querySelector: " + (container ? "PASS" : "FAIL"));
        \\  var kids = container.children;
        \\  console.log("Test8 children.length: " + (kids.length === 2 ? "PASS" : "FAIL"));
        \\  var newElem = document.createElement("div");
        \\  newElem.setAttribute("id", "new-div");
        \\  newElem.textContent = "New element";
        \\  document.body.appendChild(newElem);
        \\  var found = document.getElementById("new-div");
        \\  console.log("Test9 createElement+appendChild: " + (found ? "PASS" : "FAIL"));
        \\  var clicked = false;
        \\  btn.addEventListener("click", function(e) {
        \\    clicked = true;
        \\    console.log("Test10 click handler called: PASS");
        \\  });
        \\  console.log("Test10 addEventListener registered");
        \\  container.classList.add("active");
        \\  console.log("Test11 classList.add: " + (container.className.indexOf("active") >= 0 ? "PASS" : "FAIL"));
        \\  container.classList.remove("active");
        \\  console.log("Test11b classList.remove: " + (container.className.indexOf("active") < 0 ? "PASS" : "FAIL"));
        \\  console.log("Test12 parentNode: " + (btn.parentNode ? "PASS" : "FAIL"));
        \\  console.log("All DOM tests completed!");
        \\</script>
        \\</body></html>
    ;

    var doc = Document.parse(html) catch {
        std.debug.print("FAIL: Failed to parse HTML\n", .{});
        return;
    };
    defer doc.deinit();

    var js_rt = JsRuntime.init() catch {
        std.debug.print("FAIL: Failed to init JS runtime\n", .{});
        return;
    };
    defer js_rt.deinit();

    dom_api.registerDomApis(js_rt.rt, js_rt.ctx, @ptrCast(@alignCast(doc.html_doc)));
    events.registerEventApis(js_rt.ctx);
    events.injectElementEventMethods(js_rt.ctx, dom_api.element_class_id);

    script_executor.executeScripts(&doc, &js_rt, std.heap.c_allocator, null, null);

    events.dispatchDocumentEvent(js_rt.ctx, "DOMContentLoaded");
    js_rt.executePending();
    events.dispatchWindowEvent(js_rt.ctx, "load");
    js_rt.executePending();

    // Simulate a click on the button
    std.debug.print("\n--- Simulating click on #btn ---\n", .{});
    const btn_node = findNodeById(doc.documentNode().lxb_node, "btn");
    if (btn_node) |node| {
        _ = events.dispatchEvent(js_rt.ctx, node, "click");
        js_rt.executePending();
    } else {
        std.debug.print("FAIL: Could not find #btn for click test\n", .{});
    }

    events.deinitEvents(js_rt.ctx);
    std.debug.print("=== DOM + JS tests done ===\n", .{});
}

fn findNodeById(node: *lxb.lxb_dom_node_t, id: []const u8) ?*lxb.lxb_dom_node_t {
    if (node.type == lxb.LXB_DOM_NODE_TYPE_ELEMENT) {
        const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
        var val_len: usize = 0;
        const val: ?[*]const u8 = lxb.lxb_dom_element_get_attribute(elem, "id", 2, &val_len);
        if (val != null and val_len == id.len) {
            if (std.mem.eql(u8, val.?[0..val_len], id)) return node;
        }
    }
    var child: ?*lxb.lxb_dom_node_t = node.first_child;
    while (child) |ch| {
        if (findNodeById(ch, id)) |found| return found;
        child = ch.next;
    }
    return null;
}
