# Proxy/Reflect — kotori JS Engine Extension

## Overview

Add ES2015 Proxy and Reflect to the kotori JS engine. Proxy intercepts fundamental
object operations (get, set, has, delete, enumerate) via handler traps. Reflect
provides default implementations of those operations as static methods.

**Spec reference:** ECMA-262 §26 (Proxy), §28 (Reflect)

## Motivation

Vue3, Svelte5, MobX, Immer, Pinia — all modern reactive frameworks depend on Proxy.
Without it, no modern web framework runs on kotori. This is the single biggest gap
for real-world site compatibility.

## Architecture

### Phase 1: Core Traps (Vue3 minimum)

| Trap | JS Trigger | VM Opcode |
|------|-----------|-----------|
| `get(target, prop, receiver)` | `obj.prop`, `obj[key]` | get_prop, get_elem |
| `set(target, prop, value, receiver)` | `obj.prop = v`, `obj[key] = v` | set_prop, set_elem |
| `has(target, prop)` | `key in obj` | in_ |
| `deleteProperty(target, prop)` | `delete obj.prop` | delete_prop (new) |
| `ownKeys(target)` | `Object.keys(obj)` | get_keys, builtin |

### Phase 2: Callable Proxy

| Trap | JS Trigger | VM Opcode |
|------|-----------|-----------|
| `apply(target, thisArg, args)` | `proxy()` | call |
| `construct(target, args, newTarget)` | `new proxy()` | construct |

### Phase 3: Meta Traps

getPrototypeOf, setPrototypeOf, isExtensible, preventExtensions,
defineProperty, getOwnPropertyDescriptor — lower priority, most sites don't need these.

## Data Structures

### object.zig additions

```zig
// Add to ObjType enum:
proxy,

// Add ProxyData struct:
pub const ProxyData = struct {
    target: *JsObject,    // the wrapped target object
    handler: *JsObject,   // the handler with trap methods
    revoked: bool = false, // true after Proxy.revocable().revoke()
};

// Add to ObjData union:
proxy_data: ProxyData,
```

### VM Interception Pattern

Each opcode handler checks for proxy at the top:

```zig
.get_prop => {
    // ... read name_id ...
    const obj_val = self.pop();
    if (obj_val.isObject()) {
        const obj = obj_val.asJsObject();
        // Proxy interception — MUST be before all other checks
        if (obj.obj_type == .proxy) {
            const result = try self.proxyGet(obj, name_id, obj_val);
            self.push(result);
            continue;
        }
        // ... existing window_proxy, dom_node, getter checks ...
    }
}
```

### Proxy Trap Dispatch

```zig
/// Call a proxy handler trap. Returns null if trap is not defined.
fn callProxyTrap(self: *VM, handler: *JsObject, trap_name: StringId, args: []const JsValue) !?JsValue {
    const trap_fn = handler.getProperty(trap_name) orelse return null;
    if (trap_fn.isUndefined()) return null;
    return try self.callJsFunction(trap_fn, JsValue.initObject(handler), args);
}

/// Proxy [[Get]] — handler.get(target, prop, receiver) or fallback to target.prop
fn proxyGet(self: *VM, proxy_obj: *JsObject, name_id: StringId, receiver: JsValue) !JsValue {
    const pd = proxy_obj.data.proxy_data;
    if (pd.revoked) return error.TypeError; // "proxy is revoked"
    const trap_name = try self.pool.intern(self.allocator, "get");
    if (try self.callProxyTrap(pd.handler, trap_name, &.{
        JsValue.initObject(pd.target), self.stringIdToJsValue(name_id), receiver
    })) |result| {
        return result;
    }
    // Default: read from target
    return pd.target.getProperty(name_id) orelse JsValue.undefined_val;
}
```

Similar pattern for proxySet, proxyHas, proxyDeleteProperty, proxyOwnKeys.

### Proxy Constructor

```zig
// Registered as global "Proxy" constructor
fn proxyConstructor(ctx: *VM, _: JsValue, args: []const JsValue) !JsValue {
    if (args.len < 2) return error.TypeError;
    if (!args[0].isObject()) return error.TypeError; // target must be object
    if (!args[1].isObject()) return error.TypeError; // handler must be object
    const proxy = try ctx.allocator.create(JsObject);
    proxy.* = .{
        .obj_type = .proxy,
        .data = .{ .proxy_data = .{
            .target = args[0].asJsObject(),
            .handler = args[1].asJsObject(),
        }},
    };
    return JsValue.initObject(proxy);
}
```

### Proxy.revocable(target, handler)

Returns `{ proxy, revoke }` where `revoke()` sets `proxy_data.revoked = true`.

### Reflect Object

Static methods that perform the default (non-proxied) object operations:

```
Reflect.get(target, key)        → target[key] (direct, no proxy trap)
Reflect.set(target, key, value) → target[key] = value
Reflect.has(target, key)        → key in target
Reflect.deleteProperty(target, key) → delete target[key]
Reflect.ownKeys(target)         → Object.keys(target) + symbols
Reflect.apply(fn, thisArg, args) → fn.apply(thisArg, args)
Reflect.construct(Ctor, args)    → new Ctor(...args)
```

These call the VM's internal operations directly, bypassing proxy traps.

### New Opcode: delete_prop

Currently kotori may not have a delete opcode. Add:

```zig
delete_prop, // operand: u16 constant index → StringId
             // stack: [obj] → [bool] (true if deleted)
```

Compiler emits this for `delete obj.prop` expressions.

## Memory Management

- Proxy objects hold pointers to target and handler — NOT owned (GC manages lifecycle)
- Revoke sets flag only, doesn't free anything
- ProxyData added to ObjData union — no extra heap allocation

## Testing

- Proxy get/set/has traps with custom handlers
- Proxy with no handler traps (passthrough to target)
- Proxy.revocable + revoke
- Nested proxies (proxy of a proxy)
- Reflect methods match direct operations
- Vue3-style reactive pattern: `new Proxy(data, { get(t,k) { track(k); return t[k]; }, set(t,k,v) { t[k]=v; trigger(k); return true; } })`

## Estimated Size

~700 LOC total across object.zig, vm.zig, compiler.zig, builtins.
