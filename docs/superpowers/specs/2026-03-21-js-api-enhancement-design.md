# JS API Enhancement — MutationObserver + XMLHttpRequest + history.pushState

## Goal

Implement real MutationObserver, improve XMLHttpRequest polyfill, and strengthen history.pushState for better framework compatibility (React, Vue, jQuery, Preact).

## Constraints

- RPi Zero 2W: 512MB RAM
- QuickJS-ng 0.12.1 runtime
- Existing polyfill stubs must not regress

## 1. MutationObserver (Real Implementation)

### Current State

Polyfill stub in `src/js/web_api.zig` (lines 1461-1487). `observe()` stores target but never actually tracks DOM mutations. `__fireMutationObservers()` fires dummy records on every DOM dirty.

### Design

Replace the JS polyfill with a Zig-native implementation in `src/js/events.zig`.

**Data structures:**

```
MutationObserverEntry:
  - js_callback: JSValue (prevent GC via JS_DupValue)
  - targets: list of { node_ptr, options }
  - pending_records: list of MutationRecord
  - disconnected: bool

MutationRecord (JS object):
  - type: "childList" | "attributes"
  - target: JSValue (wrapped DOM node)
  - addedNodes: JSValue[] (for childList)
  - removedNodes: JSValue[] (for childList)
  - attributeName: ?string (for attributes)
  - oldValue: ?string (if attributeOldValue requested)

ObserverOptions:
  - childList: bool
  - attributes: bool
  - subtree: bool
  - attributeOldValue: bool
```

**Integration points — where mutations are recorded:**

| DOM operation | File | Mutation type |
|---------------|------|---------------|
| `innerHTML` set | `dom_api.zig` `elementSetInnerHTML` | childList |
| `appendChild` | `dom_api.zig` `elementAppendChild` | childList |
| `removeChild` | `dom_api.zig` `elementRemoveChild` | childList |
| `insertBefore` | `dom_api.zig` `elementInsertBefore` | childList |
| `setAttribute` | `dom_api.zig` `elementSetAttribute` | attributes |
| `removeAttribute` | `dom_api.zig` `elementRemoveAttribute` | attributes |
| `textContent` set | `dom_api.zig` `elementSetTextContent` | childList |
| `classList.add/remove/toggle` | `dom_api.zig` `classListAdd/Remove/Toggle` | attributes (class) |

**Flush timing:** After `tickTimers()` in the event loop (main.zig), call `flushMutationObservers()`. This matches browser behavior where mutation callbacks fire as microtasks after the current task.

**Scope:** `childList` + `attributes` only. `characterData` deferred (rarely used by frameworks).

**Registration in JS:** Replace the polyfill stub with Zig-backed constructor:

```js
// In registerWebApis:
MutationObserver = native_MutationObserver  // Zig C function
MutationObserver.prototype.observe = native_observe
MutationObserver.prototype.disconnect = native_disconnect
MutationObserver.prototype.takeRecords = native_takeRecords
```

### Files Modified

- `src/js/events.zig` — Add MutationObserver registry, record, flush logic
- `src/js/dom_api.zig` — Add `recordMutation()` calls at each integration point
- `src/js/web_api.zig` — Remove polyfill stub, register Zig-native MutationObserver
- `src/main.zig` — Call `flushMutationObservers()` after tickTimers

## 2. XMLHttpRequest (Polyfill Improvement)

### Current State

JS polyfill in `src/js/web_api.zig` (lines 1523-1565). Uses `fetch()` internally, so basic GET/POST works. State machine is simplified.

### Design

Keep the existing fetch()-based polyfill. Add targeted fixes:

1. **`responseType = 'json'`**: Wrap JSON.parse in try/catch to avoid crashes on invalid JSON
2. **`overrideMimeType()`**: Add as no-op method (prevents "not a function" errors)
3. **`withCredentials`**: Map to fetch `credentials: 'include'` option
4. **`getAllResponseHeaders()` fix**: Return proper `\r\n` delimited string
5. **`timeout` property**: Map to AbortController with setTimeout

### Files Modified

- `src/js/web_api.zig` — Update XHR polyfill string

## 3. history.pushState (Strengthening)

### Current State

JS polyfill in `src/js/web_api.zig` (lines 1563-1582). Updates location properties. Back/forward fire popstate. No URL bar sync.

### Design

1. **URL bar sync**: After pushState/replaceState, call `__suzume_update_url(url)` (new native function) to update the URL bar display in main.zig
2. **state property**: Already stored in JS stack array — verify it's accessible via `history.state` getter
3. **popstate event**: Ensure `event.state` is correctly set from the stack

### Files Modified

- `src/js/web_api.zig` — Update history polyfill, add `__suzume_update_url` native
- `src/main.zig` — Add pending URL bar update check in event loop

## Testing

1. **MutationObserver test HTML**: appendChild/removeChild → callback fires with correct addedNodes/removedNodes
2. **Attribute observer test**: setAttribute → callback fires with attributeName
3. **GitHub load test**: Check if React "Uh oh" error is reduced
4. **dev.to load test**: Check if Preact init errors decrease
5. **Docker comparison**: diff % on GitHub/dev.to before and after

## Implementation Order

1. MutationObserver data structures + registration (events.zig)
2. MutationObserver flush logic + event loop integration
3. recordMutation() calls at DOM operation points
4. Remove polyfill stub, wire up Zig-native
5. Test with MutationObserver test HTML
6. XMLHttpRequest polyfill improvements
7. history.pushState URL bar sync
8. Docker comparison tests
