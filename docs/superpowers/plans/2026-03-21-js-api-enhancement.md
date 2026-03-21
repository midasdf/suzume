# JS API Enhancement Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement real MutationObserver, improve XMLHttpRequest polyfill, and strengthen history.pushState for framework compatibility.

**Architecture:** MutationObserver is implemented in Zig (events.zig) with mutation recording at DOM operation points (dom_api.zig). XHR and history improvements are JS polyfill patches (web_api.zig). All changes integrate with the existing event loop in main.zig.

**Tech Stack:** Zig 0.14, QuickJS-ng 0.12.1

**Spec:** `docs/superpowers/specs/2026-03-21-js-api-enhancement-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/js/events.zig` | Modify | MutationObserver registry, record storage, flush logic |
| `src/js/dom_api.zig` | Modify | Record mutations at appendChild/removeChild/setAttribute etc. |
| `src/js/web_api.zig` | Modify | Remove MO polyfill, register Zig-native MO; improve XHR; history URL sync |
| `src/main.zig` | Modify | Add `__suzume_update_url` for history URL bar sync |
| `tests/fixtures/test_mutation_observer.html` | Create | Test page for MutationObserver |

---

## Chunk 1: MutationObserver

### Task 1: MutationObserver data structures + Zig API

**Files:**
- Modify: `src/js/events.zig`

- [ ] **Step 1: Add MutationObserver types and registry**

At the end of `src/js/events.zig`, add:

```zig
// ── MutationObserver ────────────────────────────────────────────────

const MutationRecord = struct {
    type_str: []const u8,       // "childList" or "attributes" (static string, not owned)
    target: *lxb.lxb_dom_node_t,
    attribute_name: ?[]const u8, // owned copy, null for childList
    added_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),
    removed_nodes: std.ArrayListUnmanaged(*lxb.lxb_dom_node_t),

    fn deinit(self: *MutationRecord) void {
        if (self.attribute_name) |name| allocator.free(name);
        self.added_nodes.deinit(allocator);
        self.removed_nodes.deinit(allocator);
    }
};

const ObserveTarget = struct {
    node: *lxb.lxb_dom_node_t,
    child_list: bool,
    attributes: bool,
    subtree: bool,
};

const MutationObserverEntry = struct {
    callback: qjs.JSValue,   // prevent GC via DupValue
    targets: std.ArrayListUnmanaged(ObserveTarget),
    pending_records: std.ArrayListUnmanaged(MutationRecord),
    disconnected: bool,

    fn deinit(self: *MutationObserverEntry, ctx: *qjs.JSContext) void {
        qjs.JS_FreeValue(ctx, self.callback);
        self.targets.deinit(allocator);
        for (self.pending_records.items) |*r| r.deinit();
        self.pending_records.deinit(allocator);
    }
};

var mutation_observers: std.ArrayListUnmanaged(MutationObserverEntry) = .empty;
```

- [ ] **Step 2: Add recordMutation public function**

This is called from dom_api.zig at each DOM mutation point:

```zig
/// Record a mutation for any observing MutationObservers.
pub fn recordMutation(
    target: *lxb.lxb_dom_node_t,
    mutation_type: []const u8,  // "childList" or "attributes"
    added: ?*lxb.lxb_dom_node_t,
    removed: ?*lxb.lxb_dom_node_t,
    attr_name: ?[]const u8,
) void {
    for (mutation_observers.items) |*obs| {
        if (obs.disconnected) continue;
        for (obs.targets.items) |t| {
            const matches = (t.node == target) or
                (t.subtree and isDescendant(target, t.node));
            if (!matches) continue;

            const want = if (std.mem.eql(u8, mutation_type, "childList")) t.child_list
                else if (std.mem.eql(u8, mutation_type, "attributes")) t.attributes
                else false;
            if (!want) continue;

            var record = MutationRecord{
                .type_str = mutation_type,
                .target = target,
                .attribute_name = if (attr_name) |n| (allocator.alloc(u8, n.len) catch null) else null,
                .added_nodes = .empty,
                .removed_nodes = .empty,
            };
            if (record.attribute_name) |dest| {
                if (attr_name) |src| @memcpy(@constCast(dest), src);
            }
            if (added) |a| record.added_nodes.append(allocator, a) catch {};
            if (removed) |r| record.removed_nodes.append(allocator, r) catch {};
            obs.pending_records.append(allocator, record) catch {};
            break; // one record per observer per mutation
        }
    }
}

fn isDescendant(node: *lxb.lxb_dom_node_t, ancestor: *lxb.lxb_dom_node_t) bool {
    var cur: ?*lxb.lxb_dom_node_t = node.parent;
    while (cur) |c| {
        if (c == ancestor) return true;
        cur = c.parent;
    }
    return false;
}
```

- [ ] **Step 3: Add flushMutationObservers**

```zig
/// Flush pending mutation records to JS callbacks.
/// Called from tickTimers after timer processing.
pub fn flushMutationObservers(ctx: *qjs.JSContext) void {
    var i: usize = 0;
    while (i < mutation_observers.items.len) {
        var obs = &mutation_observers.items[i];
        if (obs.disconnected or obs.pending_records.items.len == 0) {
            i += 1;
            continue;
        }

        // Build JS array of MutationRecord objects
        const records_arr = qjs.JS_NewArray(ctx);
        for (obs.pending_records.items, 0..) |*rec, idx| {
            const record_obj = qjs.JS_NewObject(ctx);
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "type",
                qjs.JS_NewStringLen(ctx, rec.type_str.ptr, rec.type_str.len));
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "target",
                dom_api.wrapNodePublic(ctx, rec.target));

            // addedNodes array
            const added_arr = qjs.JS_NewArray(ctx);
            for (rec.added_nodes.items, 0..) |node, ai| {
                _ = qjs.JS_SetPropertyUint32(ctx, added_arr, @intCast(ai),
                    dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "addedNodes", added_arr);

            // removedNodes array
            const removed_arr = qjs.JS_NewArray(ctx);
            for (rec.removed_nodes.items, 0..) |node, ri| {
                _ = qjs.JS_SetPropertyUint32(ctx, removed_arr, @intCast(ri),
                    dom_api.wrapNodePublic(ctx, node));
            }
            _ = qjs.JS_SetPropertyStr(ctx, record_obj, "removedNodes", removed_arr);

            // attributeName
            if (rec.attribute_name) |name| {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName",
                    qjs.JS_NewStringLen(ctx, name.ptr, name.len));
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, record_obj, "attributeName", quickjs.JS_NULL());
            }

            _ = qjs.JS_SetPropertyUint32(ctx, records_arr, @intCast(idx), record_obj);
            rec.deinit();
        }
        obs.pending_records.clearRetainingCapacity();

        // Call observer callback: callback(records, observer_wrapper)
        var call_args = [_]qjs.JSValue{ records_arr, quickjs.JS_UNDEFINED() };
        const ret = qjs.JS_Call(ctx, obs.callback, quickjs.JS_UNDEFINED(), 2, &call_args);
        qjs.JS_FreeValue(ctx, ret);
        qjs.JS_FreeValue(ctx, records_arr);

        i += 1;
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 5: Commit**

```bash
git add src/js/events.zig
git commit -m "feat: MutationObserver data structures, recording, and flush logic"
```

---

### Task 2: Wire MutationObserver JS API

**Files:**
- Modify: `src/js/events.zig` — add JS constructor/observe/disconnect functions
- Modify: `src/js/web_api.zig` — remove polyfill, register Zig-native

- [ ] **Step 1: Add JS-callable functions in events.zig**

```zig
// ── MutationObserver JS API ─────────────────────────────────────────

pub fn jsMutationObserverConstructor(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    if (!qjs.JS_IsFunction(c, args[0])) return quickjs.JS_UNDEFINED();

    const obj = qjs.JS_NewObject(c);
    // Store observer index as an int property
    const idx: u32 = @intCast(mutation_observers.items.len);
    mutation_observers.append(allocator, .{
        .callback = qjs.JS_DupValue(c, args[0]),
        .targets = .empty,
        .pending_records = .empty,
        .disconnected = false,
    }) catch return quickjs.JS_UNDEFINED();
    _ = qjs.JS_SetPropertyStr(c, obj, "_idx", qjs.JS_NewInt32(c, @intCast(idx)));
    _ = qjs.JS_SetPropertyStr(c, obj, "observe", qjs.JS_NewCFunction(c, &jsMutationObserverObserve, "observe", 2));
    _ = qjs.JS_SetPropertyStr(c, obj, "disconnect", qjs.JS_NewCFunction(c, &jsMutationObserverDisconnect, "disconnect", 0));
    _ = qjs.JS_SetPropertyStr(c, obj, "takeRecords", qjs.JS_NewCFunction(c, &jsMutationObserverTakeRecords, "takeRecords", 0));
    return obj;
}

fn getObserverIdx(ctx: *qjs.JSContext, this_val: qjs.JSValue) ?u32 {
    const idx_val = qjs.JS_GetPropertyStr(ctx, this_val, "_idx");
    defer qjs.JS_FreeValue(ctx, idx_val);
    var idx: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &idx, idx_val) != 0) return null;
    if (idx < 0 or @as(usize, @intCast(idx)) >= mutation_observers.items.len) return null;
    return @intCast(idx);
}

fn jsMutationObserverObserve(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    const target = dom_api.getNodePublic(c, args[0]) orelse return quickjs.JS_UNDEFINED();

    var child_list = false;
    var attributes = false;
    var subtree = false;

    if (argc >= 2 and !quickjs.JS_IsUndefined(args[1])) {
        child_list = jsBoolProp(c, args[1], "childList");
        attributes = jsBoolProp(c, args[1], "attributes");
        subtree = jsBoolProp(c, args[1], "subtree");
    }

    mutation_observers.items[idx].targets.append(allocator, .{
        .node = target,
        .child_list = child_list,
        .attributes = attributes,
        .subtree = subtree,
    }) catch {};
    mutation_observers.items[idx].disconnected = false;
    return quickjs.JS_UNDEFINED();
}

fn jsBoolProp(ctx: *qjs.JSContext, obj: qjs.JSValue, name: [*:0]const u8) bool {
    const val = qjs.JS_GetPropertyStr(ctx, obj, name);
    defer qjs.JS_FreeValue(ctx, val);
    return qjs.JS_ToBool(ctx, val) > 0;
}

fn jsMutationObserverDisconnect(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    const idx = getObserverIdx(c, this_val) orelse return quickjs.JS_UNDEFINED();
    mutation_observers.items[idx].disconnected = true;
    mutation_observers.items[idx].targets.clearRetainingCapacity();
    return quickjs.JS_UNDEFINED();
}

fn jsMutationObserverTakeRecords(
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    _ = getObserverIdx(c, this_val) orelse return qjs.JS_NewArray(c);
    // Return empty array (records are flushed via callback)
    return qjs.JS_NewArray(c);
}
```

- [ ] **Step 2: Export wrapNode and getNode from dom_api.zig**

In `src/js/dom_api.zig`, add public wrapper functions so events.zig can access them:

```zig
pub fn wrapNodePublic(ctx: *qjs.JSContext, node: *lxb.lxb_dom_node_t) qjs.JSValue {
    return wrapNode(ctx, node);
}

pub fn getNodePublic(ctx: *qjs.JSContext, val: qjs.JSValue) ?*lxb.lxb_dom_node_t {
    return getNode(ctx, val);
}
```

- [ ] **Step 3: Register in web_api.zig — replace polyfill**

In `src/js/web_api.zig`, in the compat_stubs string, remove the `MutationObserver` polyfill block (lines 1461-1487). Then in `registerWebApis()`, add native registration after the global object setup:

```zig
// Native MutationObserver (replaces polyfill)
const events = @import("events.zig");
_ = qjs.JS_SetPropertyStr(ctx, global, "MutationObserver",
    qjs.JS_NewCFunction(ctx, &events.jsMutationObserverConstructor, "MutationObserver", 1));
```

- [ ] **Step 4: Replace fireMutationObservers call with Zig-native flush**

In `src/js/web_api.zig` `tickTimers()`, replace the JS-based fireMutationObservers call:

```zig
// Change from:
//   fireMutationObservers(ctx);
// To:
    const events = @import("events.zig");
    events.flushMutationObservers(ctx);
```

Remove the old `fireMutationObservers` function.

- [ ] **Step 5: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 6: Commit**

```bash
git add src/js/events.zig src/js/dom_api.zig src/js/web_api.zig
git commit -m "feat: native MutationObserver — JS API with Zig backend"
```

---

### Task 3: Add recordMutation calls at DOM operation points

**Files:**
- Modify: `src/js/dom_api.zig`

- [ ] **Step 1: Add recordMutation import and calls**

At the top of dom_api.zig, add import:

```zig
const events = @import("events.zig");
```

Then add `events.recordMutation()` calls after each DOM mutation in these functions:

**elementAppendChild** (after `lxb_dom_node_insert_child`):
```zig
events.recordMutation(parent, "childList", child, null, null);
```

**elementRemoveChild** (after `lxb_dom_node_remove`):
```zig
events.recordMutation(parent, "childList", null, child, null);
```

**elementInsertBefore** (after `lxb_dom_node_insert_before` / `lxb_dom_node_insert_child`):
```zig
events.recordMutation(getNode(c, this_val) orelse parent, "childList", new_node, null, null);
```

**elementSetAttribute** (after the setAttribute call):
```zig
const node = getNode(c, this_val) orelse return quickjs.JS_UNDEFINED();
events.recordMutation(node, "attributes", null, null, name_str);
```
(where name_str is the attribute name)

**elementRemoveAttribute** (after the removeAttribute call):
```zig
events.recordMutation(node, "attributes", null, null, name_str);
```

**elementSetInnerHTML** (after successful innerHTML set):
```zig
events.recordMutation(node, "childList", null, null, null);
```

**elementSetTextContent** (after text content change):
```zig
events.recordMutation(node, "childList", null, null, null);
```

**classListAdd/Remove/Toggle** (after class change):
```zig
events.recordMutation(node, "attributes", null, null, "class");
```

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Create test fixture**

Create `tests/fixtures/test_mutation_observer.html`:

```html
<!DOCTYPE html>
<html>
<head><title>MutationObserver Test</title></head>
<body>
<div id="target"></div>
<div id="results"></div>
<script>
var results = [];
var target = document.getElementById('target');
var observer = new MutationObserver(function(mutations) {
  mutations.forEach(function(m) {
    results.push(m.type + ':' + (m.addedNodes.length || 0) + ':' + (m.removedNodes.length || 0));
  });
  document.getElementById('results').textContent = 'Results: ' + results.join(', ');
});
observer.observe(target, { childList: true, attributes: true });

// Test 1: appendChild
var child = document.createElement('div');
child.textContent = 'Hello';
target.appendChild(child);

// Test 2: setAttribute
target.setAttribute('data-test', 'value');

// Test 3: removeChild
setTimeout(function() {
  target.removeChild(child);
  // Expected results: childList:1:0, attributes:0:0, childList:0:1
  document.title = 'PASS: ' + results.length + ' records';
}, 100);
</script>
</body>
</html>
```

- [ ] **Step 4: Commit**

```bash
git add src/js/dom_api.zig tests/fixtures/test_mutation_observer.html
git commit -m "feat: record DOM mutations at appendChild/removeChild/setAttribute etc."
```

---

## Chunk 2: XMLHttpRequest + history.pushState

### Task 4: Improve XMLHttpRequest polyfill

**Files:**
- Modify: `src/js/web_api.zig` (XHR polyfill string)

- [ ] **Step 1: Patch XHR polyfill**

In the compat_stubs string in web_api.zig, find the XMLHttpRequest block and add:

1. `overrideMimeType` method:
```js
XMLHttpRequest.prototype.overrideMimeType=function(){};
```

2. Fix JSON responseType:
```js
// In the send() then chain, change:
//   self.response=self.responseType==='json'?JSON.parse(text):text;
// To:
self.response=self.responseType==='json'?(function(){try{return JSON.parse(text)}catch(e){return null}})():text;
```

3. `dispatchEvent` method:
```js
XMLHttpRequest.prototype.dispatchEvent=function(e){this._fire(e.type,e);};
```

- [ ] **Step 2: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/js/web_api.zig
git commit -m "fix: XHR polyfill — overrideMimeType, JSON error handling, dispatchEvent"
```

---

### Task 5: Strengthen history.pushState

**Files:**
- Modify: `src/js/web_api.zig` — add `__suzume_update_url` native function
- Modify: `src/main.zig` — check pending URL update in event loop

- [ ] **Step 1: Add native URL bar update function**

In `src/js/web_api.zig`, add a global variable and native function:

```zig
var pending_url_update: ?[]const u8 = null;

pub fn getPendingUrlUpdate() ?[]const u8 {
    const url = pending_url_update;
    pending_url_update = null;
    return url;
}

fn jsSuzumeUpdateUrl(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: ?[*]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const c = ctx orelse return quickjs.JS_UNDEFINED();
    if (argc < 1) return quickjs.JS_UNDEFINED();
    const args = argv orelse return quickjs.JS_UNDEFINED();
    const s = jsStringToSlice(c, args[0]) orelse return quickjs.JS_UNDEFINED();
    defer qjs.JS_FreeCString(c, s.ptr);

    // Store URL for main event loop to pick up
    if (pending_url_update) |old| std.heap.c_allocator.free(old);
    const copy = std.heap.c_allocator.alloc(u8, s.len) catch return quickjs.JS_UNDEFINED();
    @memcpy(copy, s.ptr[0..s.len]);
    pending_url_update = copy;
    return quickjs.JS_UNDEFINED();
}
```

Register in `registerWebApis`:
```zig
_ = qjs.JS_SetPropertyStr(ctx, global, "__suzume_update_url",
    qjs.JS_NewCFunction(ctx, &jsSuzumeUpdateUrl, "__suzume_update_url", 1));
```

- [ ] **Step 2: Update history polyfill to call URL bar sync**

In the history polyfill string, update pushState:
```js
pushState:function(state,title,url){
  if(url){stack=stack.slice(0,idx+1);stack.push({state:state,url:url});idx=stack.length-1;
    location.href=url;location.pathname=url.replace(/^https?:\/\/[^\/]*/,'').replace(/[?#].*/,'');
    location.search=(url.indexOf('?')>=0?url.slice(url.indexOf('?')).replace(/#.*/,''):'');
    location.hash=(url.indexOf('#')>=0?url.slice(url.indexOf('#')):'');
    if(typeof __suzume_update_url==='function')__suzume_update_url(url);
  }
},
```

Same for replaceState.

- [ ] **Step 3: In main.zig, check pending URL update**

In the event loop, after checking navigation requests, add:

```zig
if (web_api.getPendingUrlUpdate()) |new_url| {
    defer std.heap.c_allocator.free(new_url);
    url_input.clear();
    for (new_url) |ch| url_input.insertChar(ch);
}
```

- [ ] **Step 4: Build and verify**

Run: `zig build 2>&1 | head -20`

- [ ] **Step 5: Commit**

```bash
git add src/js/web_api.zig src/main.zig
git commit -m "feat: history.pushState URL bar sync via __suzume_update_url"
```

---

## Chunk 3: Testing

### Task 6: Docker comparison test

- [ ] **Step 1: Build and Docker test**

```bash
zig build
docker build -t suzume-compare -f tests/Dockerfile.compare .
docker run --rm -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m \
  suzume-compare "https://github.com" "https://dev.to" "https://news.ycombinator.com"
```

- [ ] **Step 2: Compare with previous results**

Previous: HN 35.5%, lobste.rs 0.0%
Check: GitHub/dev.to JS errors reduced?

- [ ] **Step 3: Push and update memory**

```bash
git push origin main
```

Update project memory with MutationObserver implementation status.
