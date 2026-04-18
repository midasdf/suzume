# Layer 1D — NamedNodeMap Methods Design Spec

**Date**: 2026-04-19
**Parent**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` §Layer 1D
**Scope**: Promote `Element.attributes` from a synthetic plain object to a spec-compliant
`NamedNodeMap` with prototype, methods, iterator protocol, and live semantics per
WHATWG DOM §4.9.2.
**Base commits**: `beb7a4b` (HEAD), `eff3c7b` (buildAttributesMap full walk + identity cache),
`c7fb0b1` (setAttribute cache invalidation), `453bfc6` (pre-existing JS attributes polyfill —
**still active**, must be retired as part of this layer).
**WPT delta target**: +18 to +59 subtests across
`/tmp/wpt/dom/nodes/attributes.html` and
`/tmp/wpt/dom/nodes/NamedNodeMap-supported-property-names.html`.

## Context

### Current state (HEAD = `beb7a4b`)

`Element.attributes` is intercepted natively on any `.dom_node`-backed wrapper at
`src/js/kotori_dom.zig:1206-1210`:

```
if (eql(name, "attributes")) {
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    return buildAttributesMap(vm, @ptrCast(node));
}
```

`buildAttributesMap` (`kotori_dom.zig:4236-4273`) creates a **plain** `JsObject` with no
prototype. It walks `lxb_dom_element_first_attribute_noi → lxb_dom_element_next_attribute_noi`
and writes, for each attr:

- an indexed property (`"0"`, `"1"`, …) → cached Attr JsObject
- a named property (qualified name) → cached Attr JsObject
- a single `length` property at the end

Attr identity is guaranteed by `getOrCreateAttrWrapper` (`kotori_dom.zig:4188-4229`) which
memoises wrappers on the lexbor `lxb_dom_attr_t*` via `g_attr_wrappers`
(`kotori_dom.zig:423`). Cache invalidation hooks live in `nativeSetAttribute`
(`kotori_dom.zig:3053-3057`), `nativeSetAttributeNS` (`3081-3084`),
`nativeRemoveAttribute` (`3121-3125`), and `nativeToggleAttribute` (`5030-5033`).

### What is missing

The returned object has **no `item`, `getNamedItem[NS]`, `setNamedItem[NS]`,
`removeNamedItem[NS]`, `Symbol.iterator`**, no `Symbol.toStringTag`, no instanceof
identity, and does **not** live on `NamedNodeMap.prototype` — because no such
prototype is registered. The only presence of the name `NamedNodeMap` in the runtime
is a stub at `src/js/dom_api.zig:4372` in the legacy QuickJS binding code:

```
if(typeof NamedNodeMap==='undefined'){
  globalThis.NamedNodeMap=function(){};
  NamedNodeMap.prototype[Symbol.toStringTag]='NamedNodeMap';
}
```

That stub is attached under the old QuickJS-era binding (`dom_api.zig:4260-4290` also
defines a QuickJS-Proxy-based map), and is effectively dead code for the current
kotori code path — `domNodeGetProp` returns the plain object from
`buildAttributesMap` before the global `NamedNodeMap` constructor is ever consulted.

### Pre-existing JS polyfill (the risk)

Commit `453bfc6` installed a 348-line "attributes polyfill" at
`src/js/kotori_runtime.zig:1491-1823`. It maintains a **parallel sidecar** on every
element (`el.__attrList`) and overrides `Element.prototype.setAttribute`,
`setAttributeNS`, `getAttribute`, `hasAttribute`, `toggleAttribute`,
`removeAttribute`, `removeAttributeNS`, `getAttributeNode`, `setAttributeNode`,
`removeAttributeNode`, etc. Its stated justification (`kotori_runtime.zig:1544-1549`)
is:

> Because the native `element.attributes` NamedNodeMap has a lexbor iteration bug
> (skips all but the first attr) and we cannot replace the native property, we
> maintain our own list of Attr objects alongside it.

Commit `eff3c7b` **fixed that lexbor iteration bug** (the real cause was using
`a.node.next` instead of `lxb_dom_element_next_attribute_noi`). The polyfill's
premise is therefore obsolete, but the polyfill remains installed and continues to
interpose on every `setAttribute`/`getAttribute` call. Its `setAttributeNode` path
(`kotori_runtime.zig:1780-1803`) is the only implementation today — but it
operates on the sidecar, not the lexbor store, and its `ownerElement` tracking is
on plain sidecar objects that are **not** the same wrappers returned by
`buildAttributesMap` (the native path creates Attr wrappers keyed on
`lxb_dom_attr_t*`; the polyfill creates plain JS objects via `makeAttr`).

The two Attr representations are therefore not `===`. Any WPT test that does
`el.attributes.setNamedItem(el.getAttributeNode('x'))` today hits the polyfill
path; any test that does `el.attributes[0]` hits the native path; they return
different objects. This is the single largest source of confusion in the current
code and must be resolved as part of Layer 1D — the native `NamedNodeMap` below
owns the truth; the polyfill is retired.

## WebIDL interface summary

WHATWG DOM §4.9.2 (https://dom.spec.whatwg.org/#interface-namednodemap):

```webidl
[Exposed=Window, LegacyUnenumerableNamedProperties]
interface NamedNodeMap {
  readonly attribute unsigned long length;
  getter Attr? item(unsigned long index);
  getter Attr? getNamedItem(DOMString qualifiedName);
  Attr? getNamedItemNS(DOMString? namespace, DOMString localName);
  [CEReactions] Attr setNamedItem(Attr attr);
  [CEReactions] Attr setNamedItemNS(Attr attr);
  [CEReactions] Attr removeNamedItem(DOMString qualifiedName);
  [CEReactions] Attr removeNamedItemNS(DOMString? namespace, DOMString localName);
};
```

WebIDL §3.8 iterable declarations: "An interface with an indexed property getter
has a default iterator object whose `next()` walks `item(0)`, `item(1)`, …" So
`Symbol.iterator` is implied by the indexed getter; we must install it explicitly
because kotori does not synthesise iterators for indexed-getter interfaces.

WebIDL §3.9.1 supported property names: `NamedNodeMap`'s named-property set equals
`[a.qualifiedName for a in attribute list]` uniquified in order
(https://dom.spec.whatwg.org/#dom-namednodemap-getter-legacyplatformobject).
`LegacyUnenumerableNamedProperties` means named props are non-enumerable; they
still appear in `in` checks and bracket access.

## NamedNodeMap prototype registration

### New global `g_namednodemap_proto`

Add to `kotori_dom.zig` near `g_attr_wrappers` (`kotori_dom.zig:423`):

```zig
/// DOM §4.9.2 NamedNodeMap.prototype — the single shared prototype for every
/// live `Element.attributes` object. Populated during initKotoriDom() before
/// any document is wrapped.
var g_namednodemap_proto: ?*JsObject = null;
```

### Prototype chain

`NamedNodeMap.prototype.__proto__ === Object.prototype`. kotori's `createObj(.{})`
produces an object whose prototype is `vm.object_proto` by default (`vm.zig:2360`-ish
area; object_proto is the root). Follow the same pattern used for
`vm.array_proto` / `vm.element_proto` — create with default, populate methods,
store in the module-level slot, done.

### Init sequence

Add a new `initNamedNodeMapProto(vm: *VM) !void` called from the existing
`initKotoriDom` / `ensureDomEnv` path, after `vm.element_proto` is available
(required so that `Attr.ownerElement` checks can reference the Element prototype)
and before `wrapNode` / the bootstrap document wrap fires. See the ordering
invariant at `kotori_dom.zig:477` (`std.debug.assert(g_html_protos != null)`).

Register the global constructor too:

```zig
// DOM §4.9.2 — expose NamedNodeMap as a WebIDL interface constructor.
const ctor = try vm.createObj(.{});
try ctor.setProperty(vm.allocator, try vm.pool.intern("prototype"),
    JsValue.initObject(g_namednodemap_proto.?));
try g_namednodemap_proto.?.setProperty(vm.allocator,
    try vm.pool.intern("constructor"), JsValue.initObject(ctor));
try vm.globals.put(vm.allocator, try vm.pool.intern("NamedNodeMap"),
    JsValue.initObject(ctor));
```

The constructor throws `TypeError` when invoked directly (per WebIDL §3.6.1) — a
two-line native function.

### Wire into `buildAttributesMap`

Change `buildAttributesMap` (`kotori_dom.zig:4236-4273`) so the returned map
object's prototype is `g_namednodemap_proto.?`:

```zig
const map_obj = vm.createObj(.{}) catch return null;
map_obj.prototype = g_namednodemap_proto.?;
// Mark this object as a NamedNodeMap and stash the backing element so methods
// can re-resolve the live attribute list.
map_obj.setProperty(vm.allocator, g_sid_nnm_elem.?,
    JsValue.fromUsize(@intFromPtr(elem))) catch {};
```

`g_sid_nnm_elem` is a new `StringId` (see `g_sid_owner_doc` at `kotori_dom.zig:372`)
interned during init for `"__nnmElem"` — a non-enumerable, non-JS-visible slot
holding the owning element pointer as an opaque integer JsValue. Methods read
this slot (not the indexed snapshot) for spec-correct liveness (see Liveness
section below).

## Method: `item(index)`

### Spec (DOM §4.9.2)

> The `item(index)` method steps are to return `this[index]`.

`this[index]` per the WebIDL indexed getter is "the `Attr` at index `index` in
`this`'s attribute list, or null if `index >= this.length`." The attribute list
is the live one from DOM §4.9.1 — "an ordered set of zero or more attributes".

### Signature

`NamedNodeMap.prototype.item(index: Number) → Attr | null`

### Implementation

```zig
fn nativeNnmItem(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    const want: i64 = @intFromFloat(args[0].toNumber());
    if (want < 0) return JsValue.null_val;
    var idx: i64 = 0;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (idx += 1) {
        if (idx == want) {
            const obj = getOrCreateAttrWrapper(vm, attr) orelse return JsValue.null_val;
            return JsValue.initObject(obj);
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return JsValue.null_val;
}
```

`nnmElem(this)` decodes the `__nnmElem` slot → `*lxb.lxb_dom_element_t`.

### Edge cases

- Non-integer coerce to integer via `toNumber().toInt32()` per WebIDL.
- Negative indices return null (not wrap-around).
- Calling `item` on a detached map (element was GC'd) returns null. Because kotori
  keeps the element alive via the JsObject wrapper in the node cache, this is
  handled naturally as long as the map wrapper itself is reachable.

### Error cases

None. Per spec, `item()` never throws.

## Methods: `getNamedItem` / `getNamedItemNS`

### Spec

§4.9.2:

> `getNamedItem(qualifiedName)` steps: return the result of getting an attribute
> given qualifiedName and element.

§4.9.1 "get an attribute by name":
1. If element is in the HTML namespace and its node document is an HTML document,
   then set qualifiedName to qualifiedName in ASCII lowercase.
2. Return the first attribute in element's attribute list whose qualified name
   is qualifiedName; otherwise null.

`getNamedItemNS(namespace, localName)`: "get an attribute by namespace and local
name" — if namespace is "" set it to null; return the first attribute in
element's attribute list whose namespace is namespace and local name is
localName; otherwise null.

### Implementation sketch

```zig
fn nativeNnmGetNamedItem(ctx, this, args) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const elem = nnmElem(this) orelse return JsValue.null_val;
    var qn = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    // §4.9.1 step 1: lowercase for HTML-namespace element in HTML document.
    var lower_buf: [256]u8 = undefined;
    if (elementInHtmlDoc(elem)) {
        const n = @min(qn.len, lower_buf.len);
        for (qn[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        qn = lower_buf[0..n];
    }
    const a = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse
        return JsValue.null_val;
    const obj = getOrCreateAttrWrapper(vm, a) orelse return JsValue.null_val;
    return JsValue.initObject(obj);
}
```

`elementInHtmlDoc(elem)` = `elem.node.ns == 0x02 /* LXB_NS_HTML */` AND the owner
document is an HTML doc (lexbor tracks this). Existing `nsIdToUri`
(`kotori_dom.zig:501`) handles the namespace side. Document-type flag access
mirrors how `tagNameUpper` (`kotori_dom.zig:4275-4296`) branches on HTML ns.

For `getNamedItemNS`, iterate `lxb_dom_element_first_attribute_noi` and match on
`(attr.node.ns, lxb_dom_attr_local_name)` — similar walk to the existing
`buildAttributesMap`. No lookup-by-NS helper exists in lexbor so manual walk is
required.

### Error cases

None — both return null when not found.

## Methods: `setNamedItem` / `setNamedItemNS`

**This is the hardest method** because the spec-mandated `InUseAttributeError`
requires accurate `attr.ownerElement` tracking across both the native path and
any remaining JS-created Attr.

### Spec (§4.9.2 + §4.9.1 "set an attribute")

`setNamedItem(attr)` / `setNamedItemNS(attr)` steps:

1. If `attr`'s element is neither null nor `element` (i.e. the Attr is attached
   to a different element), then throw `InUseAttributeError` DOMException.
2. Let `oldAttr` be the result of getting an attribute given `attr`'s namespace,
   `attr`'s local name, and `element` (for the NS variant) or given `attr`'s
   qualified name and `element` (for the non-NS variant, per §4.9.1
   "set an attribute" — actually it is always by ns+localName; `setNamedItem` just
   has no explicit namespace argument).
3. If `oldAttr` is `attr`, return `attr`.
4. If `oldAttr` is non-null, then replace `oldAttr` with `attr` in `element`'s
   attribute list.
5. Otherwise, append `attr` to `element`'s attribute list.
6. Set `attr`'s element to `element`.
7. Return `oldAttr`.

### `InUseAttributeError` — the identity problem

`attr.ownerElement` can be:

- **a lexbor-backed Attr wrapper** (from `getOrCreateAttrWrapper`) → today the
  wrapper code at `kotori_dom.zig:2280` only sets `ownerElement: null` when the
  Attr is created via `document.createAttribute`, and `getOrCreateAttrWrapper`
  at `kotori_dom.zig:4188-4229` does not set `ownerElement` at all. We must add
  it. Every cached Attr wrapper should expose a live `ownerElement` that points
  to the Element JsObject whose attribute list the attr currently belongs to.

- **a JS-land plain-object Attr** returned by the legacy polyfill or by
  `Document.createAttribute` / `createAttributeNS`. Its `ownerElement` lives in
  the JS own property written at `kotori_dom.zig:2280`.

### `ownerElement` maintenance plan

Add `setAttrOwnerElement(vm, attr_obj, owner_elem_jsval)` helper:

1. Write the JS-visible `ownerElement` own property.
2. Stash the backing element pointer in a hidden slot `__ownerElemPtr`
   (analogous to `__nnmElem`) so native methods can verify ownership without
   re-crossing the JS boundary.

Call sites to update:

- `getOrCreateAttrWrapper` (`kotori_dom.zig:4188`) — set `ownerElement` to the
  JsObject wrapper for the Attr's containing Element. Lexbor gives
  `attr.node.owner → lxb_dom_element_t*`; wrap via `wrapNode`.
- `nativeSetAttribute` / `nativeSetAttributeNS` (`kotori_dom.zig:3045,3073`) —
  when the existing Attr struct is reused, keep its wrapper's `ownerElement`
  intact.
- `nativeRemoveAttribute` / `nativeToggleAttribute` (removal branch) — clear
  `ownerElement = null` on the wrapper *before* `invalidateAttrWrapper`.
- `createAttribute`/`createAttributeNS` (`kotori_dom.zig:2280`) — already sets
  `ownerElement: null` correctly.

### Implementation sketch

```zig
fn nativeNnmSetNamedItem(ctx, this, args) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse return JsValue.undefined_val;
    const attr_obj = args[0].asJsObject();

    // Step 1: Check attr.ownerElement.
    const oe = attr_obj.getProperty(vm.pool.intern("ownerElement") catch return
        JsValue.undefined_val) orelse JsValue.null_val;
    if (!oe.isNull() and !oe.isUndefined()) {
        const oe_obj = oe.asJsObject();
        const oe_node = getThisNode(oe) orelse null;
        if (oe_node != null and @ptrCast(*lxb.lxb_dom_node_t, elem) != oe_node) {
            vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
            return JsValue.undefined_val;
        }
    }

    // Extract ns + localName + value from the Attr object.
    const ns_val = attr_obj.getProperty(...);
    const ln_val = attr_obj.getProperty(...);
    const v_val  = attr_obj.getProperty(...);

    // Step 2: get old attr by (ns, localName). Return value is the cached Attr
    // wrapper if present, else null.
    const old_attr_node: ?*lxb.lxb_dom_attr_t = lookupAttrByNsLocal(elem, ns, ln);
    const old_attr_obj: ?*JsObject = if (old_attr_node) |a|
        getOrCreateAttrWrapper(vm, a) else null;

    // Step 3: idempotence.
    if (old_attr_obj != null and old_attr_obj.? == attr_obj) {
        return JsValue.initObject(attr_obj);
    }

    // Step 4/5: delegate to lexbor via setAttribute / setAttributeNS.
    if (ns == null) {
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, v.ptr, v.len);
    } else {
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len, v.ptr, v.len);
        // NB: lexbor treats ns-aware attrs by qname; the NS tag is carried
        // separately. Match the pattern in nativeSetAttributeNS:3073.
    }

    // Re-resolve the just-written lexbor attr and cache attr_obj as its wrapper
    // so future reads return the same JS object.
    const new_lxb_attr = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)
        orelse return JsValue.null_val;
    g_attr_wrappers.put(vm.allocator, @intFromPtr(new_lxb_attr), attr_obj) catch {};
    setAttrOwnerElement(vm, attr_obj, JsValue.initObject(wrapNode(vm,
        @ptrCast(elem)).?));

    // Step 6: old's ownerElement → null.
    if (old_attr_obj) |oa| setAttrOwnerElement(vm, oa, JsValue.null_val);

    // Step 7: return old or null.
    return if (old_attr_obj) |oa| JsValue.initObject(oa) else JsValue.null_val;
}
```

### `setNamedItemNS`

Per WebIDL "A legacy interface that has both `setNamedItem` and `setNamedItemNS`
must treat them identically." In practice `setNamedItemNS` is "same algorithm,
but the Attr to set carries its own namespace metadata" — which is already how
the non-NS version works because it reads `attr.namespaceURI` to pick the
lookup. So `setNamedItemNS` is an alias: same native function, registered under
both method names.

### Error cases

- `InUseAttributeError` DOMException: `attr.ownerElement` is a different Element.
- `TypeError`: argument is not an `Attr` (nodeType !== 2 or not an object).

## Methods: `removeNamedItem` / `removeNamedItemNS`

### Spec (§4.9.2 + §4.9.1 "remove an attribute by name"/"by namespace and local name")

`removeNamedItem(qualifiedName)` steps:
1. Let `attr` be the result of `remove an attribute by name` given
   `qualifiedName` and `element`.
2. If `attr` is null, then throw `NotFoundError` DOMException.
3. Return `attr`.

`remove an attribute by name`:
1. Let `attr` be the result of getting an attribute given qualifiedName and
   element.
2. If `attr` is non-null, remove it from element's attribute list. Handle
   attribute changes for attr, element, attr's value, null.
3. Return attr.

`removeNamedItemNS(namespace, localName)`: same, but get-by-NS.

### Implementation

```zig
fn nativeNnmRemoveNamedItem(ctx, this, args) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isString()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const elem = nnmElem(this) orelse return JsValue.undefined_val;
    var qn = vm.pool.get(args[0].asStringId()) orelse return JsValue.undefined_val;
    // HTML lowercase dance, as in getNamedItem.
    ...
    const lxb_attr = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)
        orelse {
            vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
            return JsValue.undefined_val;
        };
    const attr_obj = getOrCreateAttrWrapper(vm, lxb_attr);
    // Save wrapper before invalidation so we can return it.
    invalidateAttrWrapper(lxb_attr);  // drop cache so post-remove accesses re-wrap
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    if (attr_obj) |o| setAttrOwnerElement(vm, o, JsValue.null_val);
    return if (attr_obj) |o| JsValue.initObject(o) else JsValue.null_val;
}
```

### Error cases

- `NotFoundError` DOMException: no attribute with matching name / (namespace,
  localName) exists.

## Iterator protocol

### Current kotori iterator capability (verified)

`src/js/kotori/vm.zig:2385-2388` proves native `Symbol.iterator` registration
works:

```
if (ap.symbol_props == null) ap.symbol_props = .{};
const arr_iter_fn = try self.createNativeFn(&nativeArraySymbolIterator);
try ap.symbol_props.?.put(self.allocator, SYMBOL_ITERATOR,
    JsValue.initObject(arr_iter_fn));
```

`SYMBOL_ITERATOR` is a module-level constant. `get_iterator` opcode dispatch
(`vm.zig:1863-1874`) calls `resolveIterator` which reads `obj.symbol_props`.
Iterator results use `obj_type = .iterator` with `iterator_data.source` holding
the iterable (`vm.zig:1856,1869,7623,9206,9213`). **No VM changes required.**

### Implementation

```zig
fn nativeNnmSymbolIterator(ctx, this, _: []const JsValue) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    // Return an iterator object that wraps the NamedNodeMap.
    const iter = try vm.createObj(.{ .obj_type = .iterator });
    iter.data = .{ .iterator_data = .{ .source = this } };
    try vm.registerNativeMethod(iter, "next", &nativeNnmIteratorNext);
    // Store index in a hidden slot.
    try iter.setProperty(vm.allocator, try vm.pool.intern("__i"), JsValue.initNumber(0));
    return JsValue.initObject(iter);
}

fn nativeNnmIteratorNext(ctx, this, _: []const JsValue) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    const iter = this.asJsObject();
    const src = iter.data.iterator_data.source;
    const elem = nnmElem(src) orelse return iterResultDone(vm);
    const i_val = iter.getProperty(vm.pool.intern("__i") catch return iterResultDone(vm))
        orelse JsValue.initNumber(0);
    const i: u32 = @intFromFloat(i_val.toNumber());
    // Walk to the i-th attribute.
    var j: u32 = 0;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| : (j += 1) {
        if (j == i) {
            const obj = getOrCreateAttrWrapper(vm, attr)
                orelse return iterResultDone(vm);
            try iter.setProperty(vm.allocator, try vm.pool.intern("__i"),
                JsValue.initNumber(@floatFromInt(i + 1)));
            return iterResultValue(vm, JsValue.initObject(obj));
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return iterResultDone(vm);
}
```

Helpers `iterResultDone` / `iterResultValue` already exist in kotori_dom style
(see `nativeArrayIteratorNext` usage at `vm.zig:1858`).

### Registration on prototype

```zig
if (g_namednodemap_proto.?.symbol_props == null)
    g_namednodemap_proto.?.symbol_props = .{};
const iter_fn = try vm.createNativeFn(&nativeNnmSymbolIterator);
try g_namednodemap_proto.?.symbol_props.?.put(vm.allocator, SYMBOL_ITERATOR,
    JsValue.initObject(iter_fn));
```

## Liveness / cache invalidation

### Spec requirement

DOM §4.9.2 note: "A `NamedNodeMap` object is live; reflecting any changes made
to its associated element's attribute list." Concretely, the sequence:

```js
const m = el.attributes;
el.setAttribute('x', '1');
m.length;          // must be N+1
m.getNamedItem('x').value;  // must be '1'
```

### Design choice: live re-walk, not snapshot

`buildAttributesMap` today pre-writes indexed properties `"0"`, `"1"`, … and a
`length` property. After `setAttribute`, those snapshots are stale.

**Fix**: do not write indexed snapshots. Instead, intercept indexed reads in
`domObjectGetProp` (the generic getProperty path in `vm.zig` — same mechanism
used for array indexed access) or install an indexed getter on the prototype.
kotori's `JsObject` does not have a generic indexed-access callback today, so
the simplest implementation is:

**Option A — lazy rebuild** (cheap, preserves current structure).
Keep the indexed-pre-write, and bump a per-Element attribute version counter in
Zig (`var g_elem_attr_ver: std.AutoHashMapUnmanaged(usize, u64) = .{}`). Each
NamedNodeMap stashes the version at build time in a hidden slot. Any
NamedNodeMap read path (`length`, `item`, `getNamedItem`, iterator) compares the
stored version to the current one; on mismatch, re-populate indexed slots and
`length` before servicing the read.

**Option B — always walk lexbor** (cleaner, ~same cost at 2-5 attrs).
Drop the indexed-pre-write from `buildAttributesMap`. Keep only the backing
element pointer in the hidden slot. `length` becomes a native getter that
walks lexbor. `item(i)` walks lexbor. Named access `map["id"]` becomes
problematic because bracket-access on an object without an own property falls
through to `[[Get]]` which walks the prototype chain — we'd need a named-getter
hook the same as the indexed case.

**Recommended: Option A**. Rationale:
- The existing `buildAttributesMap` structure (own indexed + named props) is the
  path that already makes `map[0]` and `map["id"]` work without a custom getter.
- The version bump is one integer write at each `setAttribute[NS]` /
  `removeAttribute` / `toggleAttribute` call site, dwarfed by the lexbor work
  already happening there.
- The re-populate path re-uses the already-correct `buildAttributesMap` body
  (extract it into `refreshAttributesMap(vm, map_obj, elem)`).

### Version bump sites

Add `bumpElemAttrVersion(elem: *lxb.lxb_dom_element_t)` and call at every
existing Attr cache invalidation site:

- `nativeSetAttribute` (`kotori_dom.zig:3063` and `3066`).
- `nativeSetAttributeNS` (`kotori_dom.zig:3090`, `3093`).
- `nativeRemoveAttribute` (`kotori_dom.zig:3126`).
- `nativeToggleAttribute` (add + remove branches, `kotori_dom.zig:5035, 5044`).
- Any future `setNamedItem` / `removeNamedItem` paths (this spec).

### Map-object identity

Per §4.9.2 "The `attributes` attribute's getter steps are to return a
`NamedNodeMap` associated with this." and the accompanying note "Each
`attributes` getter invocation returns the *same* `NamedNodeMap`." So
`el.attributes === el.attributes` must hold. Today it does not
(`buildAttributesMap` creates a fresh object every call).

**Fix**: Cache the map on the Element JsObject via a hidden slot `__nnmCache`
→ map JsObject. First call builds, caches, and writes version. Subsequent
calls return the cached map after refresh. Invalidation happens automatically
because the version counter triggers refresh, not rebuild.

## Test plan

### Primary targets

| Test file | Subtests | Relevant NamedNodeMap methods |
|---|---|---|
| `/tmp/wpt/dom/nodes/attributes.html` | 32 remaining (of 67) | `item`, `getNamedItem[NS]`, `setNamedItem[NS]`, `removeNamedItem[NS]`, iterator |
| `/tmp/wpt/dom/nodes/NamedNodeMap-supported-property-names.html` | ~10-15 | named-property enumeration, `LegacyUnenumerableNamedProperties` |
| `/tmp/wpt/dom/nodes/Element-hasAttributes.html` | ~5 | relies on `map.length` liveness |

### Subtest coverage by method

- `item()` — `attributes.html` "el.attributes.item(0)", "… item(999) returns null".
- `getNamedItem` — "setAttribute then getNamedItem returns Attr", "getNamedItem
  for absent attr returns null", HTML lowercase case.
- `getNamedItemNS` — "setAttributeNS then getNamedItemNS", "null namespace
  resolution" (empty-string coerces to null).
- `setNamedItem` — "returns null when appending", "returns old Attr when
  replacing", `InUseAttributeError` when the Attr belongs to a different
  element.
- `setNamedItemNS` — same semantics with ns-aware Attrs.
- `removeNamedItem` — "returns removed Attr", `NotFoundError` when absent.
- `removeNamedItemNS` — NS variant + `NotFoundError`.
- Iterator — `for (let a of el.attributes)` produces Attr objects in index
  order; `[...el.attributes].length === el.attributes.length`;
  `el.attributes[Symbol.iterator]` is callable.

### Verification commands

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/attributes.html
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/NamedNodeMap-supported-property-names.html
```

## Risk / regression

### R1: JS polyfill collision (high risk, concrete mitigation)

`kotori_runtime.zig:1476-1824` still installs the `attributes_polyfill_js`. It
overrides `Element.prototype.setAttribute`, `getAttribute`, `hasAttribute`,
`toggleAttribute`, `removeAttribute`, `removeAttributeNS`, `getAttributeNode`,
`setAttributeNode`, `removeAttributeNode`, etc., and maintains a parallel
`__attrList` sidecar that is not synchronised with the lexbor store except via
its own wrappers.

The polyfill's `setAttributeNode` returns a plain-object Attr that is not the
same object as the lexbor-backed Attr wrapper returned by `el.attributes[0]`.
If we ship `setNamedItem` in native code while the polyfill's `setAttributeNode`
still runs, one path writes to lexbor + `g_attr_wrappers`, the other writes to
the sidecar — every WPT test comparing `nnm.setNamedItem(a) === oldFromLexbor`
will fail.

**Mitigation**:
1. Delete the polyfill's sidecar (`__attrList`) and all of its wrapper
   overrides EXCEPT the `validateAndExtract` + `validateName` pieces that
   implement spec §1.5 QName validation (Layer 1A responsibility — see
   `2026-04-17-kotori-suzume-wpt-100-roadmap.md` §1A).
2. Extract `validateAndExtract` into its own tiny polyfill so setAttributeNS
   still throws `NamespaceError` for bad QNames — this is Layer 1A's
   responsibility but is coupled here.
3. Replace the polyfilled `setAttributeNode` / `getAttributeNode` /
   `removeAttributeNode` with native implementations: they wrap the
   NamedNodeMap methods one-to-one (per spec: "The `setAttributeNode(attr)`
   method steps are to return the result of setting an attribute given
   `attr` and this.").
4. Regenerate `baseline_results.txt` before and after the polyfill removal to
   catch unrelated regressions (the polyfill is known to touch `createAttribute`
   clone semantics used by importNode — those must survive).

### R2: Wrapper identity across element boundaries

If we cache `g_attr_wrappers[lxb_attr_ptr] = attr_obj_from_JS`, then
transferring the same JS Attr to a different Element via `setNamedItem` must
update the cache key — lexbor allocates a new `lxb_dom_attr_t` on the target
Element's list; the old key becomes stale. Spec §4.9.1 "set an attribute" step
6 "Set attr's element to element." Our `setAttrOwnerElement` must be paired
with `g_attr_wrappers.put(new_key, attr_obj)` AND `g_attr_wrappers.remove(old_key)`.

### R3: Lexbor's attribute lookup case sensitivity

`lxb_dom_element_attr_by_name` is case-sensitive. For HTML documents, spec
requires callers to lowercase. We must lowercase at every entry point rather
than relying on lexbor to do it — mirror the branch at `kotori_dom.zig:5015-5020`.

### R4: Iterator + live mutation within the loop

Per spec the map is live during iteration. If the user does `setAttribute` mid-
`for..of`, the iterator should reflect the mutation on the *next* `next()`
call. Option B (native walk of lexbor per `next`) already delivers this. The
stored `__i` counter does not: inserting a new attribute at index 0 would show
the same element twice. Spec is ambiguous here; observed browser behaviour
walks the live list by **index**, which our design matches.

### R5: `NamedNodeMap` global visibility in test harness

WPT's `testharness.js` does `new NamedNodeMap instanceof`-style checks in some
assert helpers. The global constructor must be callable in `typeof` checks even
though the spec disallows `new NamedNodeMap()`. Our registered constructor
throws `TypeError` on invocation but still exposes `.prototype` — matches
browsers.

### R6: Binary size / memory on RPi Zero 2W (512MB)

Native NamedNodeMap adds ~8 new native functions + one prototype slot + per-Element
version-counter hashmap entry. Net budget impact: <2KB binary, <1KB hot state.
Well under the project budget.

## Acceptance criteria

- [ ] `g_namednodemap_proto` registered before first document wrap
      (`kotori_dom.zig:477` assertion pattern extended).
- [ ] `globalThis.NamedNodeMap.prototype === el.attributes.__proto__`.
- [ ] `el.attributes === el.attributes` (identity cache).
- [ ] `el.attributes[Symbol.toStringTag]` returns `"NamedNodeMap"`.
- [ ] All 8 methods implemented natively: `item`, `getNamedItem`,
      `getNamedItemNS`, `setNamedItem`, `setNamedItemNS`, `removeNamedItem`,
      `removeNamedItemNS`, `[Symbol.iterator]`.
- [ ] `setNamedItem` with another element's Attr throws `InUseAttributeError`.
- [ ] `removeNamedItem`/`removeNamedItemNS` for absent attr throws
      `NotFoundError`.
- [ ] Liveness: `setAttribute` after map read reflects on next read
      (length + item + getNamedItem).
- [ ] `for..of el.attributes` yields Attr objects in index order; spreading
      into array has correct `length`.
- [ ] `attributes.html` WPT: at least **18 additional subtests pass** (target 32).
- [ ] `NamedNodeMap-supported-property-names.html` WPT: ≥50% pass.
- [ ] `kotori_runtime.zig` polyfill removed except for the QName validation
      slice; Layer 1A tracks the residual.
- [ ] `zig build test` green; `baseline_results.txt` shows no regressions in
      `dom/nodes/Element-*`, `dom/nodes/Attr-*`, `html/dom/reflection-*`.

## Out of scope

- Spec-complete QName validation (`InvalidCharacterError` for names violating
  the XML Name production). Owned by Layer 1A
  (`2026-04-17-kotori-suzume-wpt-100-roadmap.md` §1A).
- Case-sensitivity semantics for HTML vs XML documents. Owned by Layer 1E.
- `Element.id` / `Element.className` IDL reflection attributes. Owned by
  Layer 4A.
- MutationObserver records for `setNamedItem` / `removeNamedItem`. These
  already fire today through the existing setAttribute path used under the
  hood; Layer 1B covers the standalone cases.
- Shadow DOM retargeting of Attr events. Out of scope — Attr is not an
  EventTarget in DOM4.
