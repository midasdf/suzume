# Layer 1D.1 — Native Attr Methods + Polyfill Retirement Design Spec

**Date**: 2026-04-19
**Parent**: `docs/superpowers/specs/2026-04-19-kotori-1D-namednodemap-methods-design.md` (Layer 1D)
**Master roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` §Layer 1D.1
**Base commit**: `4da2d54` (Merge branch `feature/kotori-layer-1d`), with revert `7c31ab6` restoring the polyfill after Task 9 regressed -26 subtests.
**WPT target**: recover the -26 regression and then reach ≥35/67 (from 9/67 before 1D) on
`/tmp/wpt/dom/nodes/attributes.html`, with stretch to 50+/67.

---

## Context

Layer 1D promoted `Element.attributes` to a native `NamedNodeMap` with prototype, 8
methods, iterator, liveness version counter, and identity cache. Task 9 of Layer 1D
attempted to delete the 333-line JS polyfill at
`src/js/kotori_runtime.zig:1491-1823` that overrides `Element.prototype.{setAttribute,
setAttributeNS, getAttribute, hasAttribute, toggleAttribute, removeAttribute,
removeAttributeNS, getAttributeNode, setAttributeNode, removeAttributeNode,
hasAttributeNS, getAttributeNS}` and maintains a sidecar `el.__attrList`.

Deleting the polyfill produced **58 failures at 1D Task 9 HEAD** (-26 regression on
`attributes.html`) with this rough breakdown:

> - ~15: Attr-node accessors missing — native has no `getAttributeNode`,
>   `getAttributeNodeNS`, `setAttributeNode`, `setAttributeNodeNS`,
>   `removeAttributeNode`.
> - ~5: NS sibling methods missing — native has no `hasAttributeNS`,
>   `getAttributeNS`, `removeAttributeNS`; lexbor has no NS-aware getter helper.
> - ~8: QName validation gaps — polyfill enforced `validateAndExtract` early;
>   native `nativeSetAttribute`/`nativeSetAttributeNS` do now (see §QName
>   validation wiring) but edge cases around DOMException identity and `null`
>   namespace coercion still diverged.
> - ~6: NamedNodeMap stale-index cleanup — `refreshAttributesMap`
>   (`kotori_dom.zig:4800-4804`) leaves indexed own properties from a longer
>   previous snapshot in place; WPT observes `map[oldN-1]` still being an Attr
>   after shrinking the list.
> - misc: `InUseAttributeError`/`NotFoundError` identity, `ownerElement` tracking
>   across `setNamedItem`→`setAttributeNode` paths.

Commit `7c31ab6` reverted Task 9. The polyfill is therefore re-installed today and
regressions are papered over at the cost of keeping the sidecar-vs-lexbor identity
bug: `el.attributes[0]` (native, lexbor-backed) is not `===` to
`el.getAttributeNode(qname)` (polyfill, plain-object sidecar) — the two paths
return different JS objects for the same DOM attribute.

This layer closes every gap listed above and **then** deletes the polyfill as the
final commit, reaching parity with the surface area Task 9 attempted to remove.

---

## WebIDL interface summary

### `Attr` (DOM §4.9.1)

```webidl
[Exposed=Window]
interface Attr : Node {
  readonly attribute DOMString? namespaceURI;
  readonly attribute DOMString? prefix;
  readonly attribute DOMString localName;
  readonly attribute DOMString name;
  [CEReactions] attribute DOMString value;

  readonly attribute Element? ownerElement;
  readonly attribute boolean specified; // useless; always returns true
};
```

Key invariant: `attr.ownerElement === E` ⇔ `attr` is in `E.attributes`. Mutating
APIs (`Element.setAttributeNode`, `Element.removeAttributeNode`,
`NamedNodeMap.setNamedItem`, `NamedNodeMap.removeNamedItem`) all manipulate this
pointer. Layer 1D's `setAttrOwnerElement` helper is the single write point; all
Layer 1D.1 methods go through it.

### `Element` attribute methods (DOM §4.9.1, §4.9.2)

```webidl
partial interface Element {
  sequence<DOMString> getAttributeNames();                 // already native
  DOMString? getAttribute(DOMString qualifiedName);         // native
  DOMString? getAttributeNS(DOMString? ns, DOMString local); // ← 1D.1
  [CEReactions] undefined setAttribute(DOMString qualifiedName,
                                       DOMString value);    // native (+validation)
  [CEReactions] undefined setAttributeNS(DOMString? ns,
                                         DOMString qn,
                                         DOMString value);  // native (+validation)
  [CEReactions] undefined removeAttribute(DOMString qn);    // native
  [CEReactions] undefined removeAttributeNS(DOMString? ns,
                                            DOMString local); // ← 1D.1
  [CEReactions] boolean toggleAttribute(DOMString qn,
                                        optional boolean force); // native
  boolean hasAttribute(DOMString qualifiedName);            // native
  boolean hasAttributeNS(DOMString? ns, DOMString local);   // ← 1D.1

  Attr? getAttributeNode(DOMString qualifiedName);          // ← 1D.1
  Attr? getAttributeNodeNS(DOMString? ns, DOMString local); // ← 1D.1
  [CEReactions] Attr? setAttributeNode(Attr attr);          // ← 1D.1
  [CEReactions] Attr? setAttributeNodeNS(Attr attr);        // ← 1D.1
  [CEReactions] Attr removeAttributeNode(Attr attr);        // ← 1D.1
};
```

All five `…Node` methods are intentionally thin wrappers around the algorithms
DOM §4.9.1 specifies in terms of `NamedNodeMap` counterparts (§4.9.2 prose:
`Element.setAttributeNode(attr)` ≡ `this.attributes.setNamedItem(attr)`). We
re-expose the Layer 1D native NamedNodeMap impls on `Element.prototype` and only
add QName/namespace book-keeping at the edges.

---

## Method: `getAttributeNode` / `getAttributeNodeNS`

### Spec (DOM §4.9.1)

> `getAttributeNode(qualifiedName)` steps:
> 1. Return the result of getting an attribute given qualifiedName and this.

`get an attribute by name(qn, element)`:
1. If element is in the HTML namespace and its node document is an HTML
   document, set qn to qn in ASCII lowercase.
2. Return the first attribute in element's attribute list whose qualified name
   is qn; otherwise null.

`getAttributeNodeNS(namespace, localName)`:
1. Return the result of getting an attribute given namespace, localName, and
   this.

`get an attribute by namespace and local name(ns, local, element)`:
1. If namespace is the empty string, set it to null.
2. Return the first attribute in element's attribute list whose namespace is
   namespace and local name is localName; otherwise null.

### Signature

`Element.prototype.getAttributeNode(qualifiedName: string) → Attr | null`
`Element.prototype.getAttributeNodeNS(namespace: string?, localName: string) → Attr | null`

### Implementation

Both delegate to the Layer 1D `nnmGetNamedItem[NS]` internals *operating directly
on the element*, without requiring an `el.attributes` round-trip (the map object
is only materialised when JS observes it). Factor the inner walk into a shared
helper so `getAttributeNode` and `NamedNodeMap.getNamedItem` share one code path:

```zig
/// DOM §4.9.1 "get an attribute by name" — walks lxb_dom_element's attribute
/// list and returns the cached Attr wrapper for the first match, or null.
fn getAttrByQName(vm: *VM, elem: *lxb.lxb_dom_element_t, qn_in: []const u8) ?*JsObject {
    // Step 1: HTML-namespace + HTML document → ASCII lowercase qn.
    var buf: [256]u8 = undefined;
    const qn = maybeLowercaseForHtml(elem, qn_in, &buf);
    // Fast path: lexbor helper resolves by qualified name.
    const a = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len) orelse return null;
    return getOrCreateAttrWrapper(vm, a);
}

/// DOM §4.9.1 "get an attribute by namespace and local name".
fn getAttrByNsLocal(vm: *VM, elem: *lxb.lxb_dom_element_t,
                   ns_in: ?[]const u8, local: []const u8) ?*JsObject {
    const ns = if (ns_in) |n| (if (n.len == 0) null else n) else null;
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| {
        if (attrNsMatches(attr, ns) and attrLocalNameEquals(attr, local)) {
            return getOrCreateAttrWrapper(vm, attr);
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return null;
}

fn nativeGetAttributeNode(ctx, this, args) !JsValue {
    if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const qn = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
    return if (getAttrByQName(vm, elem, qn)) |o| JsValue.initObject(o) else JsValue.null_val;
}

fn nativeGetAttributeNodeNS(ctx, this, args) !JsValue {
    if (args.len < 2) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns: ?[]const u8 = extractOptionalString(vm, args[0]);
    const local = if (args[1].isString()) vm.pool.get(args[1].asStringId()) orelse return JsValue.null_val
                  else argToString(vm, args[1]);
    return if (getAttrByNsLocal(vm, elem, ns, local)) |o| JsValue.initObject(o) else JsValue.null_val;
}
```

### Helpers

- `maybeLowercaseForHtml(elem, src, buf)` mirrors the branch already present in
  `nativeToggleAttribute` (`kotori_dom.zig:5713-5719`) — lowercase iff
  `elem.node.ns == LXB_NS_HTML` and `ownerDocument.is_html`. Extract once; reuse
  from `NamedNodeMap.getNamedItem` (Layer 1D) to eliminate two copies.
- `attrLocalNameEquals(attr, s)` calls `lxb_dom_attr_local_name` and compares
  bytes. `attrNsMatches(attr, ?[]const u8)` maps `attr.node.ns` through
  `nsIdToUri` (`kotori_dom.zig:501`) and compares; null matches only null.

### Edge cases

- Non-string `qn` argument: WebIDL coerces with `ToString`. Follow `argToString`
  pattern used in `nativeSetAttributeNS` at `kotori_dom.zig:3057`.
- Detached element (no owner document): `maybeLowercaseForHtml` must tolerate a
  null document and skip the lowercase step.

### Error cases

None. Both return null if no matching attr.

---

## Method: `setAttributeNode` / `setAttributeNodeNS`

### Spec (DOM §4.9.1)

> `setAttributeNode(attr)` steps:
> 1. Return the result of setting an attribute given `attr` and this.

`set an attribute(attr, element)`:
1. If `attr`'s element is neither null nor `element`, then throw
   `InUseAttributeError` DOMException.
2. Let `oldAttr` be the result of getting an attribute given `attr`'s namespace,
   `attr`'s local name, and `element`.
3. If `oldAttr` is `attr`, return `attr`.
4. If `oldAttr` is non-null, then replace `oldAttr` with `attr` in `element`'s
   attribute list.
5. Otherwise, append `attr` to `element`'s attribute list.
6. Set `attr`'s element to `element`.
7. Return `oldAttr`.

DOM §4.9.1 prose after the algorithm: "The `setAttributeNodeNS(attr)` method
steps, likewise, are to return the result of setting an attribute given `attr`
and this." — same algorithm.

### Signature

`Element.prototype.setAttributeNode(attr: Attr) → Attr | null`
`Element.prototype.setAttributeNodeNS(attr: Attr) → Attr | null`

### Implementation

One native fn is registered under both names:

```zig
fn nativeSetAttributeNodeImpl(ctx, this, args) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const attr_obj = args[0].asJsObject();
    // Duck-type guard: nodeType===2. Reuse the existing `nodeType` read path
    // (kotori_dom.zig ~line 2280 createAttribute sets it).
    if (!isAttrObject(attr_obj)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Step 1: InUseAttributeError if attr.ownerElement is some *other* element.
    if (attrOwnerElement(attr_obj)) |owner_node| {
        if (@intFromPtr(owner_node) != @intFromPtr(@as(*lxb.lxb_dom_node_t, @ptrCast(elem)))) {
            vm.pending_throw = try createDOMExceptionObj(vm, "InUseAttributeError");
            return JsValue.undefined_val;
        }
    }

    // Extract ns + localName + value from the Attr JS wrapper for lookup.
    const ns = readAttrObjNs(vm, attr_obj);           // ?[]const u8
    const local = readAttrObjLocalName(vm, attr_obj); // []const u8
    const value = readAttrObjValue(vm, attr_obj);     // []const u8

    // Step 2: get old attr by (ns, local).
    const old_attr_obj = getAttrByNsLocal(vm, elem, ns, local);

    // Step 3: idempotence.
    if (old_attr_obj) |oa| if (oa == attr_obj) return JsValue.initObject(oa);

    // Steps 4/5: write via the existing lexbor set_attribute path, which
    // also bumps the NamedNodeMap version. Qualified name preserves prefix.
    const qn = buildQName(vm, attr_obj);  // prefix ? prefix + ":" + local : local
    if (ns == null) {
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len,
                                                value.ptr, value.len);
    } else {
        _ = dom_b.lxb_dom_element_set_attribute(elem, qn.ptr, qn.len,
                                                value.ptr, value.len);
        // Lexbor stores ns-aware attrs by qualified name; the ns tag is
        // carried separately on `attr.node.ns`. Mirror nativeSetAttributeNS
        // (kotori_dom.zig:3079) which takes the same shortcut.
    }
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Re-resolve the written lexbor attr and rebind the cache so future
    // el.getAttributeNode(qn) returns the *same* attr_obj.
    const new_lxb_attr = dom_b.lxb_dom_element_attr_by_name(elem, qn.ptr, qn.len)
        orelse return JsValue.null_val;
    // R2 (see 1D spec): if attr_obj was previously bound to a different
    // lxb_dom_attr_t*, remove that stale key first.
    if (getAttrBackingPtr(attr_obj)) |old_key| {
        if (old_key != @intFromPtr(new_lxb_attr)) {
            _ = g_attr_wrappers.remove(old_key);
        }
    }
    try g_attr_wrappers.put(vm.allocator, @intFromPtr(new_lxb_attr), attr_obj);
    setAttrBackingPtr(attr_obj, @intFromPtr(new_lxb_attr));

    // Step 6: set attr's element to `elem`.
    setAttrOwnerElement(vm, attr_obj,
        JsValue.initObject(wrapNode(vm, @ptrCast(elem)).?));

    // Clear old attr's ownerElement (step 4 side-effect).
    if (old_attr_obj) |oa| setAttrOwnerElement(vm, oa, JsValue.null_val);

    // Step 7: return oldAttr or null.
    return if (old_attr_obj) |oa| JsValue.initObject(oa) else JsValue.null_val;
}
```

### Error cases

- `InUseAttributeError` DOMException: `attr.ownerElement` is some other Element.
- `TypeError`: argument missing, non-object, or `nodeType !== 2`.

### Design notes

- `readAttrObjNs` reads the `namespaceURI` own property; coerces `null`/`""` →
  `null`.
- `readAttrObjLocalName` reads `localName`. Required because the caller's
  JS-created Attr may carry a prefix-less localName while the qualified name
  lookup needs both.
- `setAttributeNodeNS` is registered as an alias to `nativeSetAttributeNodeImpl`;
  spec treats them identically ("…likewise…").

---

## Method: `removeAttributeNode`

### Spec (DOM §4.9.1)

> `removeAttributeNode(attr)` steps:
> 1. If this's attribute list does not contain `attr`, then throw
>    `NotFoundError` DOMException.
> 2. Remove `attr`.
> 3. Return `attr`.

`remove(attr)` side-effects set `attr.ownerElement` to null.

### Signature

`Element.prototype.removeAttributeNode(attr: Attr) → Attr`

### Implementation

```zig
fn nativeRemoveAttributeNode(ctx, this, args) !JsValue {
    const vm = VM.vmFromCtx(ctx);
    if (args.len == 0 or !args[0].isObject()) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);

    const attr_obj = args[0].asJsObject();
    if (!isAttrObject(attr_obj)) {
        vm.pending_throw = try createDOMExceptionObj(vm, "TypeError");
        return JsValue.undefined_val;
    }

    // Step 1: containment check. Fast path: the Attr knows its backing lexbor
    // ptr (see setAttrBackingPtr). Walk this element's list and match by ptr.
    const backing = getAttrBackingPtr(attr_obj) orelse {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    };
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    var found = false;
    while (a) |attr| {
        if (@intFromPtr(attr) == backing) { found = true; break; }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    if (!found) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }

    // Step 2: remove by qualified name (lexbor has no remove-by-ptr helper).
    var qn_len: usize = 0;
    const qn_ptr = dom_b.lxb_dom_attr_qualified_name(@ptrCast(@as(*lxb.lxb_dom_attr_t, @ptrFromInt(backing))), &qn_len);
    if (qn_ptr == null) {
        vm.pending_throw = try createDOMExceptionObj(vm, "NotFoundError");
        return JsValue.undefined_val;
    }
    const qn = qn_ptr.?[0..qn_len];

    // Preserve wrapper identity for the return value; drop cache before lexbor frees.
    setAttrOwnerElement(vm, attr_obj, JsValue.null_val);
    _ = g_attr_wrappers.remove(backing);
    setAttrBackingPtr(attr_obj, 0);
    _ = dom_b.lxb_dom_element_remove_attribute(elem, qn.ptr, qn.len);
    bumpElemAttrVersion(elem);
    setDomDirty();

    // Step 3: return the passed-in Attr.
    return JsValue.initObject(attr_obj);
}
```

### Error cases

- `NotFoundError` DOMException: `attr` is not in this element's attribute list
  (either `attr.ownerElement !== this` or the backing ptr is stale).
- `TypeError`: argument missing / non-object / `nodeType !== 2`.

### Interaction with `NamedNodeMap.removeNamedItem`

`Element.removeAttributeNode(attr)` MUST be a wrapper that *finds the qualified
name from the Attr, then calls the same remove-by-qname path*. The
`nativeNnmRemoveNamedItem` from Layer 1D already implements the qname path and
throws `NotFoundError` when the name is not present — reuse its body via a
shared `removeAttrByQName(vm, elem, qn)` helper.

---

## Method: `hasAttributeNS` / `getAttributeNS` / `removeAttributeNS`

### Spec (DOM §4.9.1)

`hasAttributeNS(ns, local)`:
1. If namespace is the empty string, set it to null.
2. Return true if this has an attribute whose namespace is namespace and local
   name is localName; otherwise false.

`getAttributeNS(ns, local)`:
1. Let `attr` be the result of getting an attribute given namespace, localName,
   and this.
2. If `attr` is null, return null.
3. Return `attr`'s value.

`removeAttributeNS(ns, local)`:
1. Remove an attribute given namespace, localName, and this, and then return
   undefined.

### Implementation

```zig
fn nativeHasAttributeNS(ctx, this, args) !JsValue {
    if (args.len < 2) return JsValue.initBool(false);
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.initBool(false);
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.initBool(false);
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalString(vm, args[0]);
    const local = extractString(vm, args[1]) orelse return JsValue.initBool(false);
    return JsValue.initBool(getAttrByNsLocal(vm, elem, ns, local) != null);
}

fn nativeGetAttributeNS(ctx, this, args) !JsValue {
    if (args.len < 2) return JsValue.null_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.null_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.null_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalString(vm, args[0]);
    const local = extractString(vm, args[1]) orelse return JsValue.null_val;
    const attr_obj = getAttrByNsLocal(vm, elem, ns, local) orelse return JsValue.null_val;
    const v_sid = vm.pool.intern("value") catch return JsValue.null_val;
    return attr_obj.getProperty(v_sid) orelse JsValue.null_val;
}

fn nativeRemoveAttributeNS(ctx, this, args) !JsValue {
    if (args.len < 2) return JsValue.undefined_val;
    const vm = VM.vmFromCtx(ctx);
    const node = getThisNode(this) orelse return JsValue.undefined_val;
    if (nodeType(node) != lxb.LXB_DOM_NODE_TYPE_ELEMENT) return JsValue.undefined_val;
    const elem: *lxb.lxb_dom_element_t = @ptrCast(node);
    const ns = extractOptionalString(vm, args[0]);
    const local = extractString(vm, args[1]) orelse return JsValue.undefined_val;
    // Walk the list once; if a match, pull its qualified name and remove
    // by qname (lexbor lacks a remove-by-ns-local helper).
    var a: ?*lxb.lxb_dom_attr_t =
        @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (a) |attr| {
        if (attrNsMatches(attr, ns) and attrLocalNameEquals(attr, local)) {
            if (g_attr_wrappers.get(@intFromPtr(attr))) |w| {
                setAttrOwnerElement(vm, w, JsValue.null_val);
            }
            invalidateAttrWrapper(attr);
            var qn_len: usize = 0;
            const qn_ptr = dom_b.lxb_dom_attr_qualified_name(@ptrCast(attr), &qn_len);
            if (qn_ptr) |qn| {
                _ = dom_b.lxb_dom_element_remove_attribute(elem, qn, qn_len);
            }
            bumpElemAttrVersion(elem);
            setDomDirty();
            return JsValue.undefined_val;
        }
        a = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(attr)));
    }
    return JsValue.undefined_val;
}
```

### Edge cases

- `""` namespace coerces to `null` (spec step 1 on all three).
- Non-string `namespace` argument: `null`/`undefined` → `null`; otherwise
  `ToString`.
- `removeAttributeNS` does NOT throw when not found (DOM §4.9.1 "remove an
  attribute by namespace and local name" returns silently).

### Error cases

None of the three throw.

---

## QName validation wiring (status: Layer 1A already landed most)

Verified against HEAD `4da2d54`:

| Call site | Validator | Status |
|---|---|---|
| `nativeSetAttribute` @ `kotori_dom.zig:3024` | `dom_names.isValidAttrName` | ✅ wired, throws `InvalidCharacterError` |
| `nativeSetAttributeNS` @ `kotori_dom.zig:3067` | `dom_names.validateAndExtract` | ✅ wired, throws `InvalidCharacterError`/`NamespaceError` via `queueValidationErr` |
| `nativeToggleAttribute` @ `kotori_dom.zig:5707` | inline empty-check only | ⚠ upgrade to `dom_names.isValidAttrName` for parity |
| `nativeSetAttributeNodeImpl` (new, this layer) | none today | → add `isValidAttrName` check on `attr.name` |
| `nativeCreateAttribute` @ `kotori_dom.zig:2280` (createAttribute path) | `dom_names.isValidAttrName` | verify; polyfill's removed `validateName` had the same check |
| `nativeCreateAttributeNS` @ `kotori_dom.zig:2326` | `dom_names.validateAndExtract` | ✅ per `kotori_dom.zig:2326` grep |

**Work in 1D.1**:

1. Upgrade `nativeToggleAttribute` @ `kotori_dom.zig:5707-5710` from
   `name_raw.len == 0` to `!dom_names.isValidAttrName(name_raw)`.
2. In `nativeSetAttributeNodeImpl`, validate
   `attr.name` (qualified name) with `isValidAttrName`; for the NS variant the
   Attr was created via `createAttributeNS` which already ran
   `validateAndExtract`, so no re-validation needed there — but defensively run
   `isValidAttrName` since JS callers may have constructed a bare object and
   passed it in.
3. Audit `createAttribute` (`kotori_dom.zig:2280` vicinity) to confirm validation
   runs; add `isValidAttrName` if missing. The polyfill's `validateName` is
   redundant once native owns this.

### `queueValidationErr` bridge

Already exists at `kotori_dom.zig:2113-2117`. All new call sites that run
`validateAndExtract` reuse it so the resulting `DOMException.name` is stable.

---

## `refreshAttributesMap` stale-index sweep

### Current state

`refreshAttributesMap` (`kotori_dom.zig:4791-4831`) pre-writes indexed
(`"0"`, `"1"`, …) + named + length own properties on the cached NamedNodeMap.
The comment at line 4800-4804 documents the known gap:

> Note: stale indexed entries from a longer previous snapshot remain as own
> properties. Writing the new `length` caps observable iteration, and the
> caller's lookups go through named properties or `item()`. A future task can
> sweep stale keys when shrink cases are measured in WPT.

Layer 1D Task 9 WPT run revealed ~6 failures driven by this: tests do
`el.setAttribute('a','1'); el.setAttribute('b','2'); el.removeAttribute('a');
assert el.attributes[1] === undefined` — the old snapshot had length 2 so
`"1"` is still on the map object as an own property after the shrink.

### Fix

Track the highest index written on each snapshot and delete surplus keys on
refresh. Store `__nnmMaxIdx` on the map object alongside `__nnmVer`.

```zig
fn refreshAttributesMap(vm: *VM, map_obj: *JsObject, elem: *lxb.lxb_dom_element_t) void {
    const cur_ver = g_elem_attr_ver.get(@intFromPtr(elem)) orelse 0;
    if (g_sid_nnm_ver) |sid|
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(cur_ver))) catch {};

    // ── NEW: read the previous high-water mark of indexed properties.
    const prev_max: u32 = blk: {
        if (g_sid_nnm_max_idx) |sid| {
            if (map_obj.getProperty(sid)) |v| break :blk @intFromFloat(v.toNumber());
        }
        break :blk 0;
    };

    var count: u32 = 0;
    var attr: ?*lxb.lxb_dom_attr_t = @ptrCast(@alignCast(dom_b.lxb_dom_element_first_attribute_noi(elem)));
    while (attr) |a| {
        // … existing body: set indexed + named props …
        count += 1;
        attr = @ptrCast(@alignCast(dom_b.lxb_dom_element_next_attribute_noi(a)));
    }

    // ── NEW: sweep stale indexed keys ["count" .. "prev_max"-1].
    if (prev_max > count) {
        var i: u32 = count;
        while (i < prev_max) : (i += 1) {
            var idx_buf: [16]u8 = undefined;
            if (std.fmt.bufPrint(&idx_buf, "{d}", .{i})) |idx_str| {
                if (vm.pool.intern(idx_str)) |sid| _ = map_obj.removeProperty(sid);
            } else |_| {}
        }
    }
    // ── NEW: update high-water mark.
    if (g_sid_nnm_max_idx) |sid|
        map_obj.setProperty(vm.allocator, sid, JsValue.initNumber(@floatFromInt(count))) catch {};

    // ── Also sweep stale NAMED keys. We do NOT have the prior qname set, but we
    // can track it the same way via a hidden slot holding a string list — or,
    // simpler, rebuild the whole map object's properties on version change.
    // See "Named key sweep" below.

    if (vm.pool.intern("length")) |len_sid|
        map_obj.setProperty(vm.allocator, len_sid, JsValue.initNumber(@floatFromInt(count))) catch {};
}
```

### Named key sweep

Removed attributes whose qnames differ from survivors also leave stale named
props. Two options:

- **Option A (cheap)**: stash a list of prior qnames in a hidden
  `__nnmNames` slot as a packed string (`"id\0class\0"`). On refresh, parse it,
  diff against the new pass, delete the surplus.
- **Option B (drop-recreate)**: every refresh creates a new map object and
  replaces the `__nnmCache` pointer. Identity then does not hold between two
  reads across a mutation. DOM §4.9.2 requires `el.attributes === el.attributes`
  only *without intervening mutations*, so a fresh object across mutations may
  still pass — **but** WPT `attributes.html` includes `var m = el.attributes;
  el.setAttribute(…); assert(m === el.attributes)` patterns. Verify before
  choosing B.

**Recommended: Option A**. Stash a `JsObject` with own-property keys equal to
the last-seen qname set (values irrelevant — a flag). Iterate it, delete any
key not in the current pass, then repopulate for the next cycle. Cost: one
extra object per map, O(N) per refresh.

### `removeProperty` requirement

Confirm kotori `JsObject.removeProperty(sid) bool` exists. If not, land a
3-line helper on `JsObject` that removes a named slot. Grep confirms
`map_obj.setProperty` is used throughout; a remove primitive must be present
for the stale-name sweep to work.

### New globals

```zig
var g_sid_nnm_max_idx: ?StringId = null; // "__nnmMaxIdx"
var g_sid_nnm_names:   ?StringId = null; // "__nnmNames"   JsObject { qn: true, ... }
```

Both interned next to `g_sid_nnm_elem` / `g_sid_nnm_ver` at
`kotori_dom.zig:460-461`.

---

## Polyfill deletion (final step)

With the above eleven native additions in place, all surface area the polyfill
covers now exists natively with matching semantics. Delete
`src/js/kotori_runtime.zig:1491-1823` (333 lines) in a single commit **after**
the prior native changes are individually verified via WPT:

```bash
git rm -- nothing; just edit the file.
```

The commit must be separate from the additions so any regression bisects
cleanly to the deletion.

### Pre-deletion checklist

- [ ] All 11 methods listed in scope implemented natively.
- [ ] `setAttrOwnerElement` called on every ownership transition (set / remove /
      transfer).
- [ ] `g_attr_wrappers` backing-ptr maintained on `setAttributeNode` transfer.
- [ ] `refreshAttributesMap` sweeps stale indexed + named keys.
- [ ] WPT `attributes.html` score ≥ 35/67 with polyfill **still installed**
      (confirms the new native code alone drives the gains; deletion is then a
      net-zero commit).
- [ ] No regressions in `baseline_results.txt` for `dom/nodes/Element-*`,
      `dom/nodes/Attr-*`, `html/dom/reflection-*`.

### Post-deletion verification

- Re-run same WPT baseline. Score should stay ≥ 35/67 (the native path already
  owned the passing subtests; deletion removes the parallel code path without
  changing behaviour).
- Spot-check identity: `el.setAttribute('x','1'); el.attributes[0] ===
  el.getAttributeNode('x')` must be `true`.

---

## Test plan

### Primary target

| Test file | Current | Target | New native methods exercised |
|---|---|---|---|
| `/tmp/wpt/dom/nodes/attributes.html` | 9/67 at pre-1D, reverted to ~35/67 post-revert | ≥ 35/67 (recover -26) then ≥ 50/67 | getAttributeNode, setAttributeNode, removeAttributeNode, hasAttributeNS, getAttributeNS, removeAttributeNS, NamedNodeMap liveness |
| `/tmp/wpt/dom/nodes/NamedNodeMap-supported-property-names.html` | Layer 1D target | +5 subtests | stale-name sweep |
| `/tmp/wpt/dom/nodes/Element-hasAttributeNS.html` | | target pass | hasAttributeNS |
| `/tmp/wpt/dom/nodes/Element-removeAttributeNS.html` | | target pass | removeAttributeNS |

### Subtest coverage by method

- `getAttributeNode` — returns live wrapper; identity `attrs[0] === getAttributeNode('id')`.
- `getAttributeNodeNS` — ns null coercion for `""`; prefix preservation.
- `setAttributeNode` — returns null when new; returns old Attr when replacing;
  `InUseAttributeError` when Attr belongs to a different element;
  `TypeError` for non-Attr.
- `setAttributeNodeNS` — same as above with ns-aware Attr.
- `removeAttributeNode` — returns removed Attr with `ownerElement === null`;
  `NotFoundError` when `attr.ownerElement` is null or wrong element.
- `hasAttributeNS` — `""`→null, exact local-name match, returns false for
  prefix-qualified miss.
- `getAttributeNS` — returns null when absent, value string when present.
- `removeAttributeNS` — no-op when absent; mutates when present.
- `refreshAttributesMap` sweep — `setAttribute('a','1'); setAttribute('b','2');
  removeAttribute('a'); assert('1' in el.attributes === false)`.

### Verification commands

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/attributes.html
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/NamedNodeMap-supported-property-names.html
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/Element-hasAttributeNS.html
./zig-out/bin/suzume --wpt /tmp/wpt/dom/nodes/Element-removeAttributeNS.html
./zig-out/bin/suzume --wpt-baseline dom/nodes   # full sweep, no regressions
```

---

## Risk / regression

### R1: `setAttributeNode` cache identity under rebinding

Transferring an Attr from `elA` → `elB` via `setAttributeNode` creates a new
`lxb_dom_attr_t*` on `elB`'s list, making the old cache key stale. Mitigation:
`getAttrBackingPtr` / `setAttrBackingPtr` helpers on the Attr JsObject so
`nativeSetAttributeNodeImpl` can `g_attr_wrappers.remove(old_key)` before
rebinding. Already flagged in Layer 1D spec §R2.

### R2: HTML lowercase asymmetry

`lxb_dom_element_attr_by_name` is case-sensitive. Polyfill normalises via
`normalizeQName`. Native must mirror through `maybeLowercaseForHtml` at every
entry; the existing `nativeToggleAttribute` block at `kotori_dom.zig:5713-5719`
is the reference. Missing this on any new method breaks ~4 HTML-mode subtests.

### R3: `NotFoundError` vs silent-return divergence

- `removeNamedItem[NS]` → throws `NotFoundError` when absent.
- `removeAttribute`/`removeAttributeNS` on Element → returns silently.
- `removeAttributeNode(attr)` → throws `NotFoundError` when `attr` not in list.

Mixing these paths is the single largest semantic trap. The spec differentiation
is tracked per-method above; keep the three paths separated in code (do not
unify `removeAttribute` and `removeNamedItem`).

### R4: Polyfill's `createAttribute` clone semantics (importNode edge)

The polyfill docstring at `kotori_runtime.zig:1486-1490` notes it "also extends
Document.importNode to handle Attr nodes returned by our polyfilled
getAttributeNodeNS." Confirm Layer 1D's native `importNode` already handles
nodeType===2 for Attr; if not, add an Attr branch there before deleting the
polyfill.

### R5: `stale-name` sweep cost on long-attribute elements

Elements with >20 attributes (rare in the wild, common in SVG) incur O(N) per
refresh. Measure against `/tmp/wpt/svg/` baseline to confirm no timing
regressions; kotori's current iteration cost dwarfs this.

### R6: Binary size / memory on RPi Zero 2W (512MB)

+5 native functions × ~2KB each ≈ 10KB additional binary; polyfill deletion
saves ~12KB of embedded JS source. Net neutral to slightly negative. Hidden
slots per map: +2 × 8 bytes. Under budget.

---

## Acceptance criteria

- [ ] `Element.prototype.getAttributeNode` / `getAttributeNodeNS` return the
      same `g_attr_wrappers` instance as `el.attributes[N]` for identical
      attrs (identity: `el.attributes[0] === el.getAttributeNode('id')`).
- [ ] `setAttributeNode` returns null on append, returns replaced Attr on
      replace, throws `InUseAttributeError` on cross-element `attr.ownerElement`,
      throws `TypeError` for non-Attr.
- [ ] `removeAttributeNode` returns the removed Attr with
      `ownerElement === null`, throws `NotFoundError` when Attr is not in the
      element's list.
- [ ] `hasAttributeNS` / `getAttributeNS` / `removeAttributeNS` honour `""` →
      null namespace coercion.
- [ ] `nativeToggleAttribute` validates via `dom_names.isValidAttrName`.
- [ ] `refreshAttributesMap` sweeps stale indexed keys (when list shrinks) AND
      stale named keys (when a qname is no longer present).
- [ ] `src/js/kotori_runtime.zig:1491-1823` removed in a standalone commit;
      `kotori_runtime.zig` no longer references `attributes_polyfill_js`.
- [ ] WPT `attributes.html`: ≥ 35/67 passing (recovers the -26 regression);
      stretch ≥ 50/67.
- [ ] `baseline_results.txt` shows no regressions in `dom/nodes/Element-*`,
      `dom/nodes/Attr-*`, `html/dom/reflection-*`.
- [ ] `zig build test` green.

---

## Out of scope

- Full CEReactions (custom elements reactions queue). Owned by Layer 5B (custom
  elements).
- Attr node as full `Node` — `appendChild(attr)` et al. Spec §4.9.1: Attr is a
  Node but cannot be inserted into a document tree; kotori's node insertion
  paths already reject `nodeType === 2` implicitly.
- Case-sensitivity for HTML vs XML documents beyond the lowercase step. Owned
  by Layer 1E.
- Event firing on Attr (MutationObserver attribute records already flow through
  `setAttribute` path — see `recordAttributeMutation` at `kotori_dom.zig:3039`).
- `Attr.prefix` setter (spec deprecates to readonly in DOM4 — no work).
- Migrating `attributes.html` subtests that require full Shadow DOM retargeting.
  Owned by Layer 3A.
