# kotori Layer 1F — Range + TreeWalker/NodeIterator Polish — Design

**Date**: 2026-04-19
**Branch**: `feature/kotori-layer-1f-range`
**Parent roadmap**: `docs/superpowers/specs/2026-04-17-kotori-suzume-wpt-100-roadmap.md` Layer 1F
**Target**: +50 subtests in dom/nodes + dom/ranges + dom/traversal combined

---

## Baseline (2026-04-19)

| Area | Files | Subtests Pass/Total | Rate |
|------|-------|---------------------|------|
| dom/ranges    | 54 (pass=22 fail=29 err=3) | 892 / 3862  | **23.1%** |
| dom/traversal | 16 (pass=7 fail=4 err=5)   | 28  / 41    | **68.3%** |

Total gap to 100% in these two areas: **~2983 subtests**. Roadmap-promised delivery: +50.

---

## Scope (DOM §5 + §6 + §4.2)

Five spec gaps, each with WPT failure evidence.

### Gap A — Range boundary-point updates on DOM mutation (DOM §5.5 "Boundary points")

**Spec**: DOM §5.5 "Mutating Range" + the "replace data" / "remove a node" / "insert a node" / "split a text node" algorithms (DOM §4.2.7 – §4.2.8).

**Current state** (`src/js/kotori_runtime.zig:711-770`): a live-range registry exists and hooks `Node.prototype.removeChild` and `Element.prototype.removeChild` to call `rangeBpNodeRemoved`. Coverage is limited to removal; **no hooks for insertion, appendChild, insertBefore, CharacterData mutations, or splitText**.

**Failure evidence** (fresh run 2026-04-19):
- `Range-adopt-test.html` 0/4 ("Removing the only element in the range must collapse the range — expected 0 but got 1"): removal works but adoption doesn't collapse.
- `Range-mutations-appendData.html`, `Range-mutations-deleteData.html`, `Range-mutations-insertData.html`, `Range-mutations-replaceData.html`, `Range-mutations-splitText.html`, `Range-mutations-appendChild.html`, `Range-mutations-insertBefore.html`, `Range-mutations-replaceChild.html`, `Range-mutations-removeChild.html` — large test suites. All rely on the DOM §4.2 algorithms running Range-update post-steps.

**Required per DOM §4.2 "replace data" (WPT copy in `Range-mutations.js:280-352`):**
> For every boundary point whose node is *node*, and whose offset is greater than *offset* but less than or equal to *offset + count*, set its offset to *offset*.
> For every boundary point whose node is *node*, and whose offset is greater than *offset + count*, add the length of *data* to its offset, then subtract *count* from it.

**Required per DOM §4.2 "insert" / "append" sibling post-step:**
> For every live range, if the range's start container is *parent* and start offset is greater than *child*'s index, increment start offset by the number of nodes inserted.
> Same for end.

**Required per DOM §4.2 "split a text node" (`splitText`):**
> For every live range whose start node is *node* and start offset is greater than *offset*, set its start node to *new node* and decrease its start offset by *offset*.
> For every live range whose end node is *node* and end offset is greater than *offset*, set its end node to *new node* and decrease its end offset by *offset*.
> For every live range whose start node is *parent of node* and start offset is *(index of node + 1)*, increment its start offset by 1.
> Same for end.

### Gap B — TreeWalker FILTER_REJECT recursion (DOM §6.1 "Traversal")

**Spec**: DOM §6.1, algorithms "nextNode" / "previousNode" / "firstChild" / "lastChild" / "nextSibling" / "previousSibling" / "parentNode". REJECT means "do not visit this node **or its descendants**".

**Current state** (`src/js/kotori_runtime.zig:1140-1240`): `twChild` treats REJECT as "do not descend" but still considers REJECT-ed siblings' descendants on the sibling walk; `nextNode` uses `result !== FILTER_REJECT` to gate descent which is correct; but `twSibling` and `previousNode` have logic that descends into a REJECTed node via its `firstChild`/`lastChild` in some branches.

**Failure evidence**: `TreeWalker-traversal-reject.html` fails 3 subtests (nextNode, firstChild, previousNode with `rejectB1Filter`). `TreeWalker-previousNodeLastChildReject.html` fails with C2 REJECT leaking D1/D2.

**Spec algorithm (§6.1 "traverse" for nextNode)**: descend only if filter result is not REJECT; otherwise skip to nextSibling, ascending.

### Gap C — TreeWalker filter is "Get acceptNode every traverse" (DOM §6.2 "filter a node")

**Spec**: DOM §6.2 "filter": the algorithm calls `Get(filter, "acceptNode")` **at every traverse**, coerces to callable, and throws TypeError if not callable.

**Current state** (`src/js/kotori_runtime.zig:1081-1102`): `filterNode` caches `walker._filter` and tests `typeof filter.acceptNode === 'function'` once; if the acceptNode is absent or non-callable, falls back to `FILTER_ACCEPT` (wrong — must throw TypeError) and never calls the `get acceptNode` getter repeatedly.

**Failure evidence**:
- `TreeWalker-acceptNode-filter.html`: "Testing with object lacking acceptNode property" expects `walker.firstChild()` to throw TypeError; currently returns a node.
- "Testing with object with non-function acceptNode property" expects TypeError; currently does not throw.
- "performs `Get` on every traverse" expects `calls === 2` after two nextNode()s; currently `calls === 4` because we read acceptNode during `typeof filter.acceptNode`, call it, and re-read during the filter call.

### Gap D — TreeWalker currentNode setter (DOM §6.1 IDL)

**Spec**: DOM §6.1 IDL: `attribute Node currentNode;` — Web IDL converts non-Node values to TypeError.

**Current state** (line 1122): `function(v){ if (v == null) throw new TypeError(...); this._current = v; }` — only rejects `null` / `undefined`, accepts `{}` and `window`.

**Failure evidence**: `TreeWalker-currentNode.html` "Test that setting currentNode to non-Node values throws" fails on `w.currentNode = {}` and `w.currentNode = window` — no TypeError.

### Gap E — Range `createRange()` / initial container (DOM §5.5)

**Spec**: DOM §5.5 "Document.createRange()" creates a range whose startContainer/endContainer is **the context document** (the `this` Document), not the main `globalThis.document`.

**Current state** (`src/js/kotori_runtime.zig:354`): `this._sc=document;this._so=0;this._ec=document;this._eo=0;` — hardcodes the global `document`, ignoring what document called `createRange()`.

**Failure evidence**: `Range-cloneRange.html` repeatedly fails with "doc.createRange() must create Range whose startContainer is doc expected object "[object HTMLElement]" but got object "[object HTMLElement]"" — but this is because the testharness uses `paras[N].ownerDocument` which, inside an iframe page, is the iframe document, not the main one. Suzume's kotori does not currently support multi-document realms, but the test harness builds up its paras array by `paras[0]=document.getElementById('a')` etc. — so `rangeEndpoints[0].ownerDocument` **is** `document`. So the test should pass… unless `document` from inside the polyfill closure differs from the current document when referenced at call time. (This diagnostic is recorded; the fix is to call `createRange` with `this` bound and use `this` as the starting container, matching spec.)

Secondary IndexSizeError coverage: `Range.setStart/setEnd` throw IndexSizeError on `offset > nLen(node)` today — already implemented (lines 381, 391). Nothing to do here.

### Gap F — NodeIterator pre-order remove behavior (DOM §6.2 "NodeIterator pre-remove")

**Spec**: DOM §6.2 "NodeIterator pre-remove": when a node is removed from its parent, iterators whose referenceNode is an inclusive descendant of the removed node must update per the spec steps.

**Current state** (`src/js/kotori_runtime.zig:1243-1308`): NodeIterator has no pre-remove hook at all.

**Failure evidence**: `NodeIterator-removal.html` 0 passing subtests (entire file fails; the test iterates over `testNodes` from `dom/common.js`). Large upside if foundational common.js reaches this test; lower bound +5 to +15 subtests here.

---

## Implementation Plan

All edits confined to `src/js/kotori_runtime.zig` (hub polyfill) **only**. Forbidden files per task scope: `dom_selector.zig`, `dom_element.zig`, `events.zig`, `src/js/kotori/regex.zig`, `src/js/kotori/vm.zig` — all untouched.

### Sub-task F1 — CharacterData mutation hooks (replace/insert/delete/append data)

Shadow `Text.prototype.substringData`/`.deleteData`/`.insertData`/`.replaceData`/`.appendData` and the same on `CharacterData.prototype`/`Comment.prototype`/`CDATASection.prototype` (whichever exists). Before calling orig, capture original data.length. After orig returns normally, call `rangeBpReplaceData(node, offset, count, newDataLen)` for each live range:

```js
function rangeBpReplaceData(node, offset, count, newLen) {
  forEachRange(function(r) {
    for (var which of ['start','end']) {
      var k = which==='start' ? '_sc' : '_ec';
      var ok = which==='start' ? '_so' : '_eo';
      if (r[k] !== node) continue;
      var off = r[ok];
      if (off > offset && off <= offset + count) r[ok] = offset;
      else if (off > offset + count) r[ok] = off + newLen - count;
    }
  });
}
```

Map method semantics to the `(offset, count, newDataLen)` triple:
- `appendData(data)` → `(origLen, 0, data.length)`
- `insertData(offset, data)` → `(offset, 0, data.length)`
- `deleteData(offset, count)` → `(offset, count, 0)`
- `replaceData(offset, count, data)` → `(offset, count, data.length)`
- direct `data` setter → `(0, origLen, newData.length)`

### Sub-task F2 — Sibling insert hooks (insertBefore/appendChild/replaceChild)

Shadow `Node.prototype.insertBefore`, `appendChild`, `replaceChild`. For each live range, after a successful insertion:

```js
function rangeBpNodeInserted(parent, child, wasIndex) {
  // wasIndex is the computed child index *after* insertion (the slot it now occupies)
  forEachRange(function(r) {
    if (r._sc === parent && r._so > wasIndex) r._so += 1;
    if (r._ec === parent && r._eo > wasIndex) r._eo += 1;
  });
}
```

For `replaceChild(newChild, oldChild)`: the semantics are remove oldChild then insert newChild at same index. The existing `removeChild`-shadowed hook handles the remove side via `rangeBpNodeRemoved`. The insert side is the same fresh-insert logic.

DocumentFragment edge: inserting a DocumentFragment means N nodes inserted. Use `beforeIdx = idx(ref) or parent.childNodes.length` captured **before** the call; after the call, compute `insertedCount = (child.nodeType === 11) ? (oldLen === new ? oldLen : /* count of inserted - approx */) : 1`. Simpler: capture `parent.childNodes.length` before + after and compute `delta`. Inserted index is still `beforeIdx`. Increment offsets by `delta` for offsets strictly greater than `beforeIdx`.

### Sub-task F3 — splitText / splitNode hook

kotori exposes `Text.prototype.splitText`. DOM §4.2 splitText: new node is created with data after offset, original node truncated. Spec Range-update: see §4.2.8.

Shadow `Text.prototype.splitText` (or fall back to `CharacterData.prototype.splitText`):

```js
if (typeof Text !== 'undefined' && Text.prototype && Text.prototype.splitText) {
  shadow(Text.prototype, 'splitText', function(orig, args) {
    var offset = Number(args[0]) | 0;
    var origNode = this;
    var parent = origNode.parentNode;
    var origIdx = parent ? idx(origNode) : -1;
    var newNode = orig.apply(this, args);
    if (newNode) {
      forEachRange(function(r) {
        rangeBpSplitText(r, origNode, newNode, offset, parent, origIdx);
      });
    }
    return newNode;
  });
}
```

with:
```js
function rangeBpSplitText(r, origNode, newNode, offset, parent, origIdx) {
  // If boundary is in origNode past offset → move to newNode with offset -= offset
  if (r._sc === origNode && r._so > offset) { r._sc = newNode; r._so -= offset; }
  if (r._ec === origNode && r._eo > offset) { r._ec = newNode; r._eo -= offset; }
  // If boundary is in parent at index origIdx + 1, increment (new sibling inserted)
  if (parent && origIdx >= 0) {
    if (r._sc === parent && r._so > origIdx + 1 - 0.5 /* i.e. > origIdx */) {
      // Spec: if start offset === index+1, increment; more generally if start offset > index, increment
      // "For every live range whose start node is parent of node and start offset equals index of node + 1, increment by 1"
      if (r._so === origIdx + 1) r._so += 1;
    }
    if (r._ec === parent && r._eo === origIdx + 1) r._eo += 1;
  }
}
```

Exact spec text: "If range's start node is the parent of *node* and its start offset is greater than *node*'s index, increase its start offset by 1" (same as a fresh sibling insert). Since the new sibling is inserted immediately after origNode (at `origIdx + 1`), the sibling-insert hook from F2 already covers offsets strictly greater than `origIdx + 1`. We only need the additional special case of the `offset > originalOffset in origNode` case.

### Sub-task F4 — TreeWalker filter callable-each-time + TypeError

Rewrite `filterNode`:

```js
function filterNode(walker, node) {
  if (!node) return FILTER_REJECT;
  var bit = showBit(node.nodeType);
  if ((walker._whatToShow & bit) === 0) return FILTER_SKIP;
  var filter = walker._filter;
  if (filter == null) return FILTER_ACCEPT;
  var callable;
  if (typeof filter === 'function') {
    callable = filter;
  } else {
    // DOM §6.2 "filter a node": Get(filter, "acceptNode") on every traverse
    var accept = filter.acceptNode;  // property access throws if getter throws
    if (typeof accept !== 'function') {
      throw new TypeError("'acceptNode' is not a function");
    }
    callable = accept;
  }
  var r;
  if (typeof filter === 'function') r = callable.call(null, node);
  else r = callable.call(filter, node);
  var ri = Number(r);
  if (ri === FILTER_ACCEPT || ri === FILTER_REJECT || ri === FILTER_SKIP) return ri;
  return FILTER_REJECT;
}
```

This:
- Reads `filter.acceptNode` every call (satisfies "performs Get on every traverse").
- Throws TypeError if acceptNode is missing/non-callable (satisfies "Testing with object lacking…" / "non-function").
- Uses `filter` as `this` for object filters; null for function filters (satisfies "filter object: this value").

### Sub-task F5 — TreeWalker currentNode setter: reject non-Node

Replace the setter:

```js
function(v) {
  if (v == null || typeof v !== 'object' || typeof v.nodeType !== 'number') {
    throw new TypeError('currentNode must be a Node');
  }
  this._current = v;
}
```

### Sub-task F6 — TreeWalker FILTER_REJECT recursion audit

Per DOM §6.1 "traverse children" + "traverse siblings":
- When descending from currentNode, REJECT means do not descend into `firstChild`/`lastChild` and skip past it entirely.
- When advancing to nextSibling, if sibling is REJECT, move to its next sibling (do not descend into its subtree).

Carefully re-derive and rewrite `twChild`, `twSibling`, `nextNode`, `previousNode` using the algorithms verbatim. Existing code handles REJECT for `twChild` descent correctly (line 1144-1151), but `twSibling` descends into SKIP/REJECT sibling's edge child on `r === FILTER_SKIP`. Need:
- On SKIP: descend into edge child (correct current behavior).
- On REJECT: skip entire subtree, move to sibling-of-sibling (correct current behavior, but needs tighter ordering).

The bug is more subtle: `nextNode` descends from currentNode into firstChild, filters that, and if result is REJECT it **still enters the while-descend loop** that may incorrectly continue. Read fresh with spec in hand:

DOM §6.1 nextNode:
```
1. Let node be the currentNode.
2. Let result be FILTER_ACCEPT.
3. While true:
   a. While result !== FILTER_REJECT and node has a child:
      i.  Set node to its first child.
      ii. Set result to the result of filtering node within this.
      iii. If result is FILTER_ACCEPT, set currentNode to node; return node.
   b. Let sibling be null.
   c. Let temporary be node.
   d. While temporary is not null:
      i.   If temporary is root, return null.
      ii.  Set sibling to temporary's next sibling.
      iii. If sibling is not null, set node to sibling; break.
      iv.  Set temporary to temporary's parent.
   e. If sibling is null, return null.
   f. Set result to the result of filtering node within this.
   g. If result is FILTER_ACCEPT, set currentNode to node; return node.
4. End
```

Current code matches this structure. The bug is: after step 3.f returns SKIP or REJECT, the outer `while(true)` restarts, but step 3.a only enters the descent loop when `result !== FILTER_REJECT` — **yet** we need to also descend on SKIP (SKIP means "visit children", REJECT means "skip subtree"). Current code does exactly that. So nextNode REJECT handling is actually already correct.

`twSibling` is where the REJECT logic matters most and is mis-written. Per spec §6.1 "traverse siblings":
```
If type is "next": set node to node's first child; otherwise ...
[detailed algorithm in spec]
```

This sub-task will **re-verify** by running the 3 traversal-reject tests after Sub-task F4/F5 are in; if still failing, rewrite `twSibling`. Defer concrete edits to after measurement.

### Sub-task F7 — NodeIterator pre-remove hook

Extend live-range registry concept: add a `LIVE_ITERATORS` list and shadow `removeChild`/`replaceChild` to also fire `niPreRemove` on each iterator:

```js
function niPreRemove(iter, toBeRemoved) {
  var ref = iter._ref;
  if (iter._root === toBeRemoved || !isAncestorOf(toBeRemoved, ref)) return;
  if (!iter._before) {
    // Set referenceNode to previous-in-preorder of toBeRemoved
    iter._ref = preorderPrev(toBeRemoved, iter._root);
    return;
  }
  var next = preorderNextAfterSubtree(toBeRemoved, iter._root);
  if (next) { iter._ref = next; return; }
  iter._ref = preorderPrev(toBeRemoved, iter._root);
  iter._before = false;
}
```

The `preorderPrev` / `preorderNextAfterSubtree` helpers walk the tree per DOM §6.2 "NodeIterator pre-remove". This hook runs **before** the actual removeChild to capture tree state.

### Sub-task F8 — DocumentFragment / innerHTML hook (optional, time permitting)

`innerHTML` setter on Element does node replacement; currently live ranges may not be updated. Deferred if time runs short.

---

## Implementation order

F4 (TreeWalker filter) → F5 (currentNode setter) → F6 (REJECT audit / rewrite) → F1 (CharacterData hooks) → F2 (insert hooks) → F3 (splitText hook) → F7 (NodeIterator pre-remove). Each sub-task followed by a `zig build` and a targeted WPT re-run; sub-commit per area.

## Verification

After each sub-task:
- `zig build` green
- `zig build test` green (no unit-test regressions)
- Targeted WPT delta recorded

Final verification:
- `dom/ranges` +N pass delta
- `dom/traversal` +M pass delta
- Target: N+M ≥ 50
- No dom/nodes regression (spot-check)

## Risk / limitations

- kotori's `Node.prototype.insertBefore` / `appendChild` / `removeChild` may not be reachable as JS-side prototype methods if they live on specific subclass prototypes. Fallback: shadow on Element / DocumentFragment / Document as well, same pattern as existing removeChild dual-shadow.
- `Text.prototype.splitText` may not be exposed as prototype method by kotori — audit required; if absent, defer F3.
- `DocumentFragment`-based insertions are harder: the fragment's children are transferred, so post-insertion the fragment is empty and we must count children before the call.
- Cross-realm / iframe tests are out of scope (kotori is single-realm).

## Out of scope

- Range-in-shadow tests (shadow DOM is incomplete).
- Foreign-document Range copy-adopt semantics (iframe-heavy tests).
- OpaqueRange tentative tests (non-normative, depends on form-control internals).
