# kotori Phase D — Modern JS Features Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 8 modern JS features to kotori: `??`, `?.`, spread calls, getter/setter, globalThis, Symbol, generators, WeakMap/WeakSet.

**Architecture:** Each feature follows the same pipeline: add opcodes to bytecode.zig → add/modify AST nodes → update compiler.zig to emit new bytecodes → add VM handlers in vm.zig. TDD: write failing test first, then implement.

**Tech Stack:** Zig, kotori VM (NaN-boxed stack VM), test via `zig build test-kotori`

**Spec:** `docs/superpowers/specs/2026-04-13-kotori-phase-d-design.md`

**Test helpers:**
- `evalExpr(source)` — compile+run JS, return last expression value
- `evalWithMicrotasks(source, global_name)` — run+drain microtasks, return named global
- Test file: `tests/test_kotori_vm.zig`
- Build/test: `cd ~/suzume && zig build test-kotori`

---

## Chunk 1: Nullish Coalescing + Optional Chaining + globalThis

### Task 1: Nullish Coalescing (`??`)

**Files:**
- Modify: `src/js/kotori/bytecode.zig:107` (add opcode before `halt`)
- Modify: `src/js/kotori/compiler.zig:242-261` (add nullish handling alongside logical_and/or)
- Modify: `src/js/kotori/vm.zig:353-365` (add opcode handler alongside jump_if_false/true)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

Add to `tests/test_kotori_vm.zig`:

```zig
test "eval: null ?? 42" {
    const result = try evalExpr("null ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: undefined ?? 42" {
    const result = try evalExpr("undefined ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: 0 ?? 42 (not nullish)" {
    const result = try evalExpr("0 ?? 42");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}

test "eval: false ?? 42 (not nullish)" {
    const result = try evalExpr("false ?? 42");
    try std.testing.expect(!result.asBool());
}

test "eval: empty string ?? 42 (not nullish)" {
    const result = try evalExpr("\"\" ?? 42");
    try std.testing.expect(result.isString());
}

test "eval: hello ?? 42" {
    const result = try evalExpr("\"hello\" ?? 42");
    try std.testing.expect(result.isString());
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | tail -5`
Expected: compilation or runtime error (nullish not handled in compiler)

- [ ] **Step 3: Add `jump_if_not_nullish` opcode**

In `src/js/kotori/bytecode.zig`, add before `halt`:

```zig
    // Nullish coalescing
    jump_if_not_nullish, // pop TOS, jump if NOT null/undefined
    jump_if_nullish,     // pop TOS, jump if null/undefined

    // Special
    typeof_,
    void_,
    halt,
```

Note: Move `typeof_`, `void_`, `halt` after the new opcodes (they were the last entries).

- [ ] **Step 4: Add compiler handling for `??`**

In `src/js/kotori/compiler.zig`, after the `logical_or` block (~line 260), add:

```zig
                if (bin.op == .nullish) {
                    try self.compileNode(bin.lhs);
                    try self.emitOp(.dup);
                    const skip = try self.current.bc.emitJump(self.allocator, .jump_if_not_nullish);
                    try self.emitOp(.pop);
                    try self.compileNode(bin.rhs);
                    self.current.bc.patchJump(skip);
                    return;
                }
```

- [ ] **Step 5: Add VM handler for `jump_if_not_nullish`**

In `src/js/kotori/vm.zig`, after the `jump_if_true` handler (~line 365), add:

```zig
                .jump_if_not_nullish => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (!val.isNull() and !val.isUndefined()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },
                .jump_if_nullish => {
                    const offset = self.readI16(frame);
                    const val = self.pop();
                    if (val.isNull() or val.isUndefined()) {
                        frame.ip = @intCast(@as(i32, @intCast(frame.ip)) + offset);
                    }
                },
```

- [ ] **Step 6: Run tests, verify they pass**

Run: `cd ~/suzume && zig build test-kotori 2>&1 | tail -5`
Expected: All tests pass, exit 0

- [ ] **Step 7: Add `??=` test and implementation**

Add test:
```zig
test "eval: nullish assign ??=" {
    const result = try evalExpr("let x = null; x ??= 5; x");
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.asNumber(), 0.001);
}

test "eval: nullish assign ??= no-op" {
    const result = try evalExpr("let x = 0; x ??= 5; x");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.asNumber(), 0.001);
}
```

In compiler.zig, find the assignment handling (search for `nullish_assign`). The `??=` should already be parsed as an assignment node with `op: .nullish_assign`. Add handling in the assignment compilation: compile LHS load, dup, jump_if_not_nullish, pop, compile RHS, store to LHS.

- [ ] **Step 8: Run tests, verify all pass**

Run: `cd ~/suzume && zig build test-kotori`
Expected: exit 0

- [ ] **Step 9: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): nullish coalescing (??) and ??= operator"
```

---

### Task 2: Optional Chaining (`?.`)

**Files:**
- Modify: `src/js/kotori/ast.zig:55-56` (add optional field to member/computed_member)
- Modify: `src/js/kotori/parser.zig:1588-1600` (set optional flag in parseMember)
- Modify: `src/js/kotori/compiler.zig:437-438,883-908` (emit nullish guards for optional members/calls)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "eval: null?.foo" {
    const result = try evalExpr("null?.foo");
    try std.testing.expect(result.isUndefined());
}

test "eval: undefined?.foo" {
    const result = try evalExpr("undefined?.foo");
    try std.testing.expect(result.isUndefined());
}

test "eval: obj?.a" {
    const result = try evalExpr("let o = {a: 42}; o?.a");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: null?.foo?.bar" {
    const result = try evalExpr("null?.foo?.bar");
    try std.testing.expect(result.isUndefined());
}

test "eval: obj?.a?.b deep chain" {
    const result = try evalExpr("let o = {a: {b: 99}}; o?.a?.b");
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), result.asNumber(), 0.001);
}

test "eval: null?.[0]" {
    const result = try evalExpr("null?.[0]");
    try std.testing.expect(result.isUndefined());
}

test "eval: arr?.[1]" {
    const result = try evalExpr("[10,20,30]?.[1]");
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Add `optional` field to AST member nodes**

In `src/js/kotori/ast.zig`, change:
```zig
    member: struct { object: NodeIndex, property: StringId },
    computed_member: struct { object: NodeIndex, property: NodeIndex },
```
to:
```zig
    member: struct { object: NodeIndex, property: StringId, optional: bool = false },
    computed_member: struct { object: NodeIndex, property: NodeIndex, optional: bool = false },
```

- [ ] **Step 4: Set optional flag in parser**

In `src/js/kotori/parser.zig`, `parseMember` (~line 1588):

Before `self.advance()`, capture whether token is optional:
```zig
    fn parseMember(self: *Parser, object: NodeIndex) ParseError!NodeIndex {
        const is_optional = self.current.type == .optional_chain or self.current.type == .question_dot;
        self.advance(); // consume . or ?.
        if (self.current.type != .identifier and !isKeyword(self.current.type)) {
            return error.UnexpectedToken;
        }
        const text = self.tokenSlice(self.current);
        const sid = self.pool.intern(text) catch return error.OutOfMemory;
        self.advance();
        return self.ast.addNode(self.allocator, .{ .member = .{
            .object = object,
            .property = sid,
            .optional = is_optional,
        } }) catch return error.OutOfMemory;
    }
```

Also handle `?.[` for computed members. The parser has no `peekNext()`, so handle it
inside `parseMember`: after consuming `?.`, if the current token is `[`, treat it as
optional computed member instead:

```zig
    fn parseMember(self: *Parser, object: NodeIndex) ParseError!NodeIndex {
        const is_optional = self.current.type == .optional_chain or self.current.type == .question_dot;
        self.advance(); // consume . or ?.

        // ?.[ → optional computed member
        if (is_optional and self.current.type == .lbracket) {
            self.advance(); // consume [
            const prop = try self.parsePrecedence(.assignment);
            try self.expect(.rbracket);
            return self.ast.addNode(self.allocator, .{ .computed_member = .{
                .object = object,
                .property = prop,
                .optional = true,
            } }) catch return error.OutOfMemory;
        }

        if (self.current.type != .identifier and !isKeyword(self.current.type)) {
            return error.UnexpectedToken;
        }
        const text = self.tokenSlice(self.current);
        const sid = self.pool.intern(text) catch return error.OutOfMemory;
        self.advance();
        return self.ast.addNode(self.allocator, .{ .member = .{
            .object = object,
            .property = sid,
            .optional = is_optional,
        } }) catch return error.OutOfMemory;
    }
```

The existing `parseComputedMember` stays unchanged (non-optional `[` access).
Note: `?.` lexes as a single token, so after consuming it, the next token is `[`.

- [ ] **Step 5: Add optional member compilation**

In `src/js/kotori/compiler.zig`, modify the `.member` handler (~line 437):

```zig
            .member => |m| {
                if (m.optional) {
                    try self.compileOptionalMember(m.object, m.property);
                } else {
                    try self.compileMemberAccess(m.object, m.property);
                }
            },
            .computed_member => |m| {
                if (m.optional) {
                    try self.compileOptionalComputedMember(m.object, m.property);
                } else {
                    try self.compileComputedMember(m.object, m.property);
                }
            },
```

Add new helper functions:
```zig
    fn compileOptionalMember(self: *Compiler, object: NodeIndex, property: StringId) CompileError!void {
        try self.compileNode(object);               // [obj]
        try self.emitOp(.dup);                       // [obj, obj]
        const null_jump = try self.current.bc.emitJump(self.allocator, .jump_if_nullish); // pops → [obj]
        // Non-null path: do normal get_prop (pops obj, pushes result)
        const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(property)));
        try self.emitOpU16(.get_prop, ci);           // [result]
        const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
        // Null path:
        self.current.bc.patchJump(null_jump);        // [obj] (null/undefined)
        try self.emitOp(.pop);                       // []
        try self.emitConstant(JsValue.undefined_val); // [undefined]
        self.current.bc.patchJump(end_jump);
    }

    fn compileOptionalComputedMember(self: *Compiler, object: NodeIndex, property: NodeIndex) CompileError!void {
        try self.compileNode(object);               // [obj]
        try self.emitOp(.dup);                       // [obj, obj]
        const null_jump = try self.current.bc.emitJump(self.allocator, .jump_if_nullish); // pops → [obj]
        try self.compileNode(property);              // [obj, key]
        try self.emitOp(.get_elem);                  // [result]
        const end_jump = try self.current.bc.emitJump(self.allocator, .jump);
        self.current.bc.patchJump(null_jump);        // [obj]
        try self.emitOp(.pop);                       // []
        try self.emitConstant(JsValue.undefined_val); // [undefined]
        self.current.bc.patchJump(end_jump);
    }
```

- [ ] **Step 6: Run tests, verify they pass**

Run: `cd ~/suzume && zig build test-kotori`
Expected: exit 0

- [ ] **Step 7: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): optional chaining (?.) for member and computed access"
```

---

### Task 3: globalThis

**Files:**
- Modify: `src/js/kotori/vm.zig` (in `initBuiltins`)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing test**

```zig
test "eval: globalThis.parseInt" {
    const result = try evalExpr("globalThis.parseInt(\"42\")");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run test, verify it fails**

- [ ] **Step 3: Register globalThis**

Find `initBuiltins` in vm.zig (~line 1239). At the end of the function, add:

```zig
        // globalThis — proxy to globals via get_prop interception
        // Add a new obj_type or use window_proxy to forward property access to globals
        const global_this = try self.createObj(.{ .obj_type = .window_proxy });
        const gt_id = try self.pool.intern("globalThis");
        try self.globals.put(self.allocator, gt_id, JsValue.initObject(global_this));
```

Then in the `get_prop` handler (~line 537), add a `window_proxy` intercept
(similar to the existing dom_node intercept at line 544):

```zig
                        // globalThis proxy — forward property access to globals
                        if (obj.obj_type == .window_proxy) {
                            if (self.globals.get(name_id)) |global_val| {
                                self.push(global_val);
                                continue;
                            }
                        }
```

This way `globalThis.parseInt` resolves to the global `parseInt` without
copying all globals as properties.

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): globalThis object"
```

---

## Chunk 2: Spread Calls + Object Getter/Setter

### Task 4: Spread in Function Calls

**Files:**
- Modify: `src/js/kotori/bytecode.zig` (add 4 opcodes)
- Modify: `src/js/kotori/compiler.zig:883-908` (modify compileCall to detect spread)
- Modify: `src/js/kotori/vm.zig` (add opcode handlers)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "eval: spread in call Math.max" {
    const result = try evalExpr("Math.max(...[1,2,3])");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.asNumber(), 0.001);
}

test "eval: spread in call function" {
    const result = try evalExpr("function f(a,b,c) { return a+b+c; } f(...[1,2,3])");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: spread mixed args" {
    const result = try evalExpr("function f(a,b,c,d) { return a+b+c+d; } f(0, ...[1,2], 3)");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Add spread opcodes to bytecode.zig**

Add before the nullish coalescing opcodes (or in a logical section):

```zig
    // Spread
    spread_into_array, // stack: [array, iterable] → [array]
    call_spread,       // stack: [func, args_array] → [result]
    call_method_spread, // stack: [this, func, args_array] → [result]
    construct_spread,  // stack: [func, args_array] → [result]
```

- [ ] **Step 4: Modify compileCall to handle spread**

In `src/js/kotori/compiler.zig`, modify `compileCall` (~line 883):

```zig
    fn compileCall(self: *Compiler, callee: NodeIndex, args: NodeList) CompileError!void {
        const callee_node = self.parser.ast.getNode(callee);
        const arg_items = self.parser.ast.getNodeList(args);

        // Check if any arg is a spread node
        var has_spread = false;
        for (arg_items) |arg| {
            if (self.parser.ast.getNode(arg) == .spread) {
                has_spread = true;
                break;
            }
        }

        if (has_spread) {
            return self.compileCallSpread(callee_node, callee, arg_items);
        }

        // existing non-spread path...
        switch (callee_node) {
            .member => |m| {
                // ... existing method call code
            },
            else => {
                // ... existing call code
            },
        }
    }

    fn compileCallSpread(self: *Compiler, callee_node: Node, callee_idx: NodeIndex, arg_items: []const NodeIndex) CompileError!void {
        switch (callee_node) {
            .member => |m| {
                // Method call with spread: obj.method(...args)
                try self.compileNode(m.object);  // [this]
                try self.emitOp(.dup);            // [this, this]
                const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(m.property)));
                try self.emitOpU16(.get_prop, ci); // [this, func]
                try self.emitOpU16(.new_array, 0); // [this, func, args[]]
                for (arg_items) |arg| {
                    switch (self.parser.ast.getNode(arg)) {
                        .spread => |inner| {
                            try self.compileNode(inner);
                            try self.emitOp(.spread_into_array);
                        },
                        else => {
                            try self.compileNode(arg);
                            try self.emitOp(.array_push);
                        },
                    }
                }
                try self.emitOp(.call_method_spread);
            },
            else => {
                try self.compileNode(callee_idx); // [func]
                try self.emitOpU16(.new_array, 0); // [func, args[]]
                for (arg_items) |arg| {
                    switch (self.parser.ast.getNode(arg)) {
                        .spread => |inner| {
                            try self.compileNode(inner);
                            try self.emitOp(.spread_into_array);
                        },
                        else => {
                            try self.compileNode(arg);
                            try self.emitOp(.array_push);
                        },
                    }
                }
                try self.emitOp(.call_spread);
            },
        }
    }
```

Note: `arg_node == .spread` is a tagged union comparison. Use `switch (arg_node) { .spread => |inner| ... }` pattern instead.

- [ ] **Step 5: Add VM handlers for spread opcodes**

In `src/js/kotori/vm.zig`:

```zig
                .spread_into_array => {
                    // Stack: [array, iterable] → [array]
                    const iterable = self.pop();
                    const arr_val = self.peek();
                    if (arr_val.isObject()) {
                        const arr = arr_val.asJsObject();
                        if (iterable.isObject()) {
                            const iter_obj = iterable.asJsObject();
                            if (iter_obj.obj_type == .array) {
                                for (iter_obj.data.array.items) |item| {
                                    try arr.data.array.append(self.allocator, item);
                                }
                            }
                        }
                    }
                },
                .call_spread => {
                    // Stack: [func, args_array] → [result]
                    const args_val = self.pop();
                    const func = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            const result = try self.callJsFunction(func, JsValue.undefined_val, args_obj.data.array.items);
                            self.push(result);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },
                .call_method_spread => {
                    // Stack: [this, func, args_array] → [result]
                    const args_val = self.pop();
                    const func = self.pop();
                    const this = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            const result = try self.callJsFunction(func, this, args_obj.data.array.items);
                            self.push(result);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },
                .construct_spread => {
                    // Stack: [func, args_array] → [result]
                    // Similar to call_spread but with constructor semantics
                    const args_val = self.pop();
                    const func = self.pop();
                    if (args_val.isObject()) {
                        const args_obj = args_val.asJsObject();
                        if (args_obj.obj_type == .array) {
                            const result = try self.callConstruct(func, args_obj.data.array.items);
                            self.push(result);
                        } else {
                            self.push(JsValue.undefined_val);
                        }
                    } else {
                        self.push(JsValue.undefined_val);
                    }
                },
```

Note: `callJsFunction` and `callConstruct` may need to be extracted or already exist. Check vm.zig for the existing call mechanism and adapt. The key is: pop the args array, extract items, pass to the existing call infrastructure.

- [ ] **Step 6: Also modify compileNewExpr for spread**

Modify `compileNewExpr` (~line 910) with same spread detection pattern.

- [ ] **Step 7: Run tests, verify pass**

Run: `cd ~/suzume && zig build test-kotori`

- [ ] **Step 8: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): spread operator in function calls"
```

---

### Task 5: Object Literal Getters/Setters

**Files:**
- Modify: `src/js/kotori/bytecode.zig` (add `define_getter`, `define_setter`)
- Modify: `src/js/kotori/object.zig:27-31` (add getters/setters maps)
- Modify: `src/js/kotori/compiler.zig:930-953` (handle Property.kind in compileObjectLiteral)
- Modify: `src/js/kotori/vm.zig:537-596` (intercept getters in get_prop, setters in set_prop)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "eval: object getter" {
    const result = try evalExpr("let o = { get x() { return 42; } }; o.x");
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: object getter and setter" {
    const result = try evalExpr(
        \\let o = {
        \\  _v: 0,
        \\  set v(x) { this._v = x; },
        \\  get v() { return this._v; }
        \\};
        \\o.v = 10;
        \\o.v
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}

test "eval: class getter" {
    const result = try evalExpr(
        \\class C {
        \\  get name() { return "test"; }
        \\}
        \\new C().name
    );
    try std.testing.expect(result.isString());
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Add opcodes**

In `src/js/kotori/bytecode.zig`:
```zig
    // Getters/Setters
    define_getter, // operand: u16 (property name), stack: [obj, func] → [obj]
    define_setter, // operand: u16 (property name), stack: [obj, func] → [obj]
```

- [ ] **Step 4: Add getter/setter maps to JsObject**

In `src/js/kotori/object.zig`, add fields to `JsObject`:
```zig
pub const JsObject = struct {
    obj_type: ObjType = .ordinary,
    properties: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    prototype: ?*JsObject = null,
    data: ObjData = .none,
    getters: ?std.AutoArrayHashMapUnmanaged(StringId, JsValue) = null,
    setters: ?std.AutoArrayHashMapUnmanaged(StringId, JsValue) = null,
    // ...
```

Update `deinit` to clean up getters/setters:
```zig
    pub fn deinit(self: *JsObject, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        if (self.getters) |*g| g.deinit(allocator);
        if (self.setters) |*s| s.deinit(allocator);
        // ... existing data cleanup
    }
```

- [ ] **Step 5: Modify compiler to emit getter/setter opcodes**

In `src/js/kotori/compiler.zig`, `compileObjectLiteral` (~line 936):

Change the property compilation from:
```zig
                .property => |prop| {
                    // Get key name
                    const key_node = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key_node) {
                        .identifier => |id| id,
                        .string_literal => |id| id,
                        else => 0,
                    };
                    try self.emitOp(.dup); // dup object ref
                    try self.compileNode(prop.value);
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    try self.emitOpU16(.set_prop, ci);
                    try self.emitOp(.pop); // discard set_prop result, keep object
                },
```

To:
```zig
                .property => |prop| {
                    const key_node = self.parser.ast.getNode(prop.key);
                    const key_id: StringId = switch (key_node) {
                        .identifier => |id| id,
                        .string_literal => |id| id,
                        else => 0,
                    };
                    const ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(key_id)));
                    switch (prop.kind) {
                        .init => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.set_prop, ci);
                            try self.emitOp(.pop);
                        },
                        .get => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.define_getter, ci);
                        },
                        .set => {
                            try self.emitOp(.dup);
                            try self.compileNode(prop.value);
                            try self.emitOpU16(.define_setter, ci);
                        },
                    }
                },
```

Also do the same in `compileClassDecl` for class getter/setter methods.

- [ ] **Step 6: Add VM opcode handlers for define_getter/define_setter**

```zig
                .define_getter => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const func = self.pop();  // getter function
                    const obj_val = self.peek(); // object stays on stack
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        if (obj.getters == null) {
                            obj.getters = .{};
                        }
                        try obj.getters.?.put(self.allocator, name_id, func);
                    }
                },
                .define_setter => {
                    const ci = self.readU16(frame);
                    const name_id: StringId = @bitCast(frame.bc.constants.items[ci].asInt());
                    const func = self.pop();  // setter function
                    const obj_val = self.peek(); // object stays on stack
                    if (obj_val.isObject()) {
                        const obj = obj_val.asJsObject();
                        if (obj.setters == null) {
                            obj.setters = .{};
                        }
                        try obj.setters.?.put(self.allocator, name_id, func);
                    }
                },
```

- [ ] **Step 7: Modify get_prop to call getters**

In `vm.zig`, `get_prop` handler (~line 537), BEFORE the normal property lookup at line 559.

**Safety note:** This is safe because the compiler now emits `define_getter` instead of
`set_prop` for getter properties, so no data property is created alongside the getter.
Getters take priority over inherited properties but not own data properties (since they
won't coexist on the same name).

```zig
                        // Check for getter
                        if (obj.getters) |getters| {
                            if (getters.get(name_id)) |getter_fn| {
                                const result = try self.callJsFunction(getter_fn, obj_val, &.{});
                                self.push(result);
                                continue;
                            }
                        }
                        // Also check prototype chain for getters
                        if (obj.prototype) |proto| {
                            if (proto.getters) |getters| {
                                if (getters.get(name_id)) |getter_fn| {
                                    const result = try self.callJsFunction(getter_fn, obj_val, &.{});
                                    self.push(result);
                                    continue;
                                }
                            }
                        }
```

Similarly, modify `set_prop` to call setters before normal property set.

- [ ] **Step 8: Run tests, verify pass**

- [ ] **Step 9: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): object literal and class getters/setters"
```

---

## Chunk 3: Symbol

### Task 6: Symbol Value Type

**Files:**
- Modify: `src/js/kotori/value.zig` (add Symbol helpers)
- Modify: `src/js/kotori/vm.zig` (Symbol constructor, typeof, property access)
- Modify: `src/js/kotori/object.zig` (add symbol_props)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "eval: typeof Symbol()" {
    const result = try evalExpr(
        \\let s = Symbol();
        \\typeof s
    );
    // Result should be string "symbol"
    try std.testing.expect(result.isString());
}

test "eval: Symbol uniqueness" {
    const result = try evalExpr("Symbol('a') !== Symbol('a')");
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool());
}

test "eval: Symbol.for registry" {
    const result = try evalExpr("Symbol.for('x') === Symbol.for('x')");
    try std.testing.expect(result.asBool());
}

test "eval: Symbol as property key" {
    const result = try evalExpr(
        \\let s = Symbol();
        \\let o = {};
        \\o[s] = 42;
        \\o[s]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run tests, verify they fail**

- [ ] **Step 3: Add Symbol helpers to value.zig**

In `src/js/kotori/value.zig`, after `isUndefined` (~line 112), add these three functions:

```zig
    pub fn isSymbol(self: JsValue) bool {
        const tag: u16 = @intCast(self.bits >> 48);
        return tag == TAG_SYMBOL;
    }

    pub fn initSymbol(id: u32) JsValue {
        const tag: u64 = @as(u64, TAG_SYMBOL) << 48;
        return .{ .bits = tag | @as(u64, id) };
    }

    pub fn asSymbolId(self: JsValue) u32 {
        return @intCast(self.bits & 0xFFFFFFFF);
    }
```

TAG_SYMBOL (0x7FFF) is already defined at line 19. These go in the "Type checks" section.

- [ ] **Step 4: Add symbol_props to JsObject**

In `src/js/kotori/object.zig`:
```zig
pub const JsObject = struct {
    // ... existing fields
    symbol_props: ?std.AutoArrayHashMapUnmanaged(u32, JsValue) = null,
```

Update `deinit`:
```zig
        if (self.symbol_props) |*sp| sp.deinit(allocator);
```

- [ ] **Step 5: Add Symbol runtime to VM**

In `vm.zig`, add fields to VM struct:
```zig
    next_symbol_id: u32 = 4, // 0-3 reserved for well-known
    symbol_descriptions: std.AutoArrayHashMapUnmanaged(u32, ?StringId) = .{},
    global_symbol_registry: std.StringArrayHashMapUnmanaged(u32) = .{},
```

Well-known symbol constants:
```zig
    pub const SYMBOL_ITERATOR: u32 = 0;
    pub const SYMBOL_TO_PRIMITIVE: u32 = 1;
    pub const SYMBOL_HAS_INSTANCE: u32 = 2;
    pub const SYMBOL_TO_STRING_TAG: u32 = 3;
```

In `initBuiltins`, register Symbol constructor:
```zig
        // Symbol constructor (called as function, NOT with new)
        const symbol_fn = try self.createNativeFn(&nativeSymbolConstructor);
        const symbol_id = try self.pool.intern("Symbol");
        try self.globals.put(self.allocator, symbol_id, JsValue.initObject(symbol_fn));

        // Symbol.for, Symbol.keyFor
        try self.registerNativeMethod(symbol_fn, "for", &nativeSymbolFor);
        try self.registerNativeMethod(symbol_fn, "keyFor", &nativeSymbolKeyFor);

        // Symbol.iterator (well-known symbol as static property)
        const iter_prop = try self.pool.intern("iterator");
        try symbol_fn.setProperty(self.allocator, iter_prop, JsValue.initSymbol(SYMBOL_ITERATOR));
```

Implement native functions:
```zig
    fn nativeSymbolConstructor(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm: *VM = @ptrCast(@alignCast(ctx));
        const id = vm.next_symbol_id;
        vm.next_symbol_id += 1;
        // Store description if provided
        var desc: ?StringId = null;
        if (args.len > 0 and args[0].isString()) {
            desc = args[0].asStringId();
        }
        try vm.symbol_descriptions.put(vm.allocator, id, desc);
        return JsValue.initSymbol(id);
    }
```

- [ ] **Step 6: Update typeof handler**

In vm.zig `typeof_` handler (~line 1029), add Symbol check:

Change the if-else chain. After the `isString()` check, before the `isObject()` check:
```zig
                    else if (val.isSymbol())
                        "symbol"
```

- [ ] **Step 7: Update get_elem/set_elem for Symbol keys**

In `get_elem` handler, add Symbol key support:
```zig
                    // Symbol property access
                    if (key.isSymbol()) {
                        const sym_id = key.asSymbolId();
                        if (obj.symbol_props) |sp| {
                            if (sp.get(sym_id)) |val| {
                                self.push(val);
                                continue;
                            }
                        }
                        self.push(JsValue.undefined_val);
                        continue;
                    }
```

Same for `set_elem`:
```zig
                    if (key.isSymbol()) {
                        const sym_id = key.asSymbolId();
                        if (obj.symbol_props == null) {
                            obj.symbol_props = .{};
                        }
                        try obj.symbol_props.?.put(self.allocator, sym_id, val);
                        self.push(val);
                        continue;
                    }
```

- [ ] **Step 8: Run tests, verify pass**

- [ ] **Step 9: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): Symbol type with registry and property keys"
```

---

## Chunk 4: Generators + WeakMap/WeakSet

### Task 7: Generators + Iterator Protocol

This is the largest and most complex task. Break into sub-steps.

**Files:**
- Modify: `src/js/kotori/bytecode.zig` (add `yield_value`, `yield_delegate`, `get_iterator`)
- Modify: `src/js/kotori/object.zig` (add `generator` obj_type + data)
- Modify: `src/js/kotori/compiler.zig` (compile yield, generator function detection, for-of update)
- Modify: `src/js/kotori/vm.zig` (generator state machine, iterator protocol, for-of runtime)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write basic generator test**

```zig
test "eval: basic generator" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\let it = g();
        \\let a = it.next().value;
        \\let b = it.next().value;
        \\let c = it.next().value;
        \\let d = it.next().done;
        \\a + b + c
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Run test, verify it fails**

- [ ] **Step 3: Add opcodes**

In `bytecode.zig`:
```zig
    // Generators / Iterators
    yield_value,   // pop value, suspend generator, return {value, done:false}
    yield_delegate, // yield* — delegate to sub-iterator
    get_iterator,  // pop iterable, push iterator (Symbol.iterator or array fallback)
```

- [ ] **Step 4: Add generator obj_type and data**

In `object.zig`:

Add to ObjType:
```zig
    generator,
```

Add GeneratorState enum and data:
```zig
    pub const GeneratorState = enum(u8) {
        suspended_start,
        suspended_yield,
        executing,
        completed,
    };

    pub const GeneratorData = struct {
        state: GeneratorState = .suspended_start,
        function: FunctionObj,
        saved_ip: u32 = 0,
        saved_stack: []JsValue = &.{},
        saved_locals: []JsValue = &.{},
        upvalues: []?*UpvalueCell = &.{},
        this_val: JsValue = JsValue.undefined_val,
    };
```

Add to ObjData union:
```zig
        generator_data: GeneratorData,
```

Update deinit for generator_data (free saved_stack, saved_locals).

- [ ] **Step 5: Add is_generator to FunctionObj**

In `object.zig`, add to FunctionObj:
```zig
    is_generator: bool = false,
```

- [ ] **Step 6: Compiler — propagate is_generator flag**

In `compiler.zig`, when compiling `function_decl`/`function_expr`/`arrow_function`, check `func.is_generator` and set it on the FunctionObj being created.

- [ ] **Step 7: Compiler — emit yield_value for yield expressions**

In `compileNode`, handle `yield_expr`:
```zig
            .yield_expr => |y| {
                if (y.argument != null_node) {
                    try self.compileNode(y.argument);
                } else {
                    try self.emitConstant(JsValue.undefined_val);
                }
                if (y.delegate) {
                    try self.emitOp(.yield_delegate);
                } else {
                    try self.emitOp(.yield_value);
                }
            },
```

- [ ] **Step 8: VM — generator creation on function call**

When `call` opcode encounters a function with `is_generator = true`:
- Don't push call frame
- Create GeneratorObject in `suspended_start` state
- Register `.next()`, `.return()`, `.throw()` methods
- Push GeneratorObject as return value

- [ ] **Step 9: VM — generator .next() native method**

```zig
    fn nativeGeneratorNext(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm: *VM = @ptrCast(@alignCast(ctx));
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;

        switch (gen.state) {
            .completed => {
                return try vm.createIterResult(JsValue.undefined_val, true);
            },
            .executing => {
                return error.GeneratorRunning;
            },
            .suspended_start => {
                gen.state = .executing;
                // Start executing the generator function from the beginning
                // Push call frame, execute until yield or return
                const result = try vm.executeGenerator(gen, JsValue.undefined_val);
                return result;
            },
            .suspended_yield => {
                gen.state = .executing;
                // Resume from saved state
                const sent_value = if (args.len > 0) args[0] else JsValue.undefined_val;
                const result = try vm.executeGenerator(gen, sent_value);
                return result;
            },
        }
    }
```

- [ ] **Step 10: VM — executeGenerator helper**

This is the core: restore generator state, run until yield/return, save state.

```zig
    fn executeGenerator(self: *VM, gen: *GeneratorData, sent_value: JsValue) !JsValue {
        // Push a call frame for the generator function
        const func = &gen.function;
        const base_sp = self.sp;

        if (gen.state == .executing and gen.continuation != null) {
            // Resuming from yield: restore saved stack/locals
            const cont = gen.continuation.?;
            // Restore locals + temporaries from saved state
            for (cont.saved_stack, 0..) |val, i| {
                self.stack[base_sp + i] = val;
            }
            self.sp = base_sp + @as(u32, @intCast(cont.saved_stack.len));

            // Push sent_value as the result of the yield expression
            self.push(sent_value);

            // Set up frame at saved IP
            self.frames[self.frame_count] = .{
                .bc = &func.bytecode,
                .ip = cont.saved_ip,
                .base_sp = base_sp,
                .upvalues = gen.upvalues,
            };
        } else {
            // First call (suspended_start): start from beginning
            self.sp = base_sp + func.local_count;
            self.frames[self.frame_count] = .{
                .bc = &func.bytecode,
                .ip = 0,
                .base_sp = base_sp,
                .upvalues = &.{},
            };
        }
        self.frame_count += 1;

        // Run until yield_value or return
        // Use run(until_frame) — the yield_value handler will:
        //   1. Save IP, stack[base_sp..sp], locals to gen.continuation
        //   2. Set gen.state = .suspended_yield
        //   3. Decrement frame_count (pop frame)
        //   4. Break out of run loop by returning a special sentinel
        // The return_ handler will:
        //   1. Set gen.state = .completed
        //   2. Return {value, done:true}
        //
        // Implementation approach: set a generator context pointer on the VM
        // so yield_value/return_ handlers know they're inside a generator.
        self.active_generator = gen;
        defer self.active_generator = null;

        const result = try self.run(self.frame_count - 1);
        // result is the yielded/returned value wrapped in {value, done}
        return result;
    }

    fn createIterResult(self: *VM, value: JsValue, done: bool) !JsValue {
        const obj = try self.allocator.create(JsObject);
        obj.* = .{};
        try self.objects.append(self.allocator, obj);
        const value_id = try self.pool.intern("value");
        const done_id = try self.pool.intern("done");
        try obj.setProperty(self.allocator, value_id, value);
        try obj.setProperty(self.allocator, done_id, JsValue.initBool(done));
        return JsValue.initObject(obj);
    }
```

- [ ] **Step 11: VM — yield_value opcode handler**

Add `active_generator: ?*GeneratorData = null` field to the VM struct.

```zig
                .yield_value => {
                    if (self.active_generator) |gen| {
                        const yield_val = self.pop();
                        // Save current execution state
                        const f = &self.frames[self.frame_count - 1];
                        const base = f.base_sp;
                        const stack_slice = self.stack[base..self.sp];
                        // Allocate and copy saved state
                        const saved = try self.allocator.alloc(JsValue, stack_slice.len);
                        @memcpy(saved, stack_slice);
                        if (gen.continuation) |old| {
                            self.allocator.free(old.saved_stack);
                            self.allocator.destroy(old);
                        }
                        const cont = try self.allocator.create(Continuation);
                        cont.* = .{
                            .bc = f.bc,
                            .ip = f.ip,
                            .saved_stack = saved,
                            .upvalues = f.upvalues,
                            .this_val = gen.this_val,
                            .async_promise = undefined, // not used for generators
                            .has_this_on_stack = false,
                        };
                        gen.continuation = cont;
                        gen.state = .suspended_yield;
                        // Pop frame
                        self.frame_count -= 1;
                        self.sp = base;
                        // Return {value, done: false} — run() will return this
                        const result = try self.createIterResult(yield_val, false);
                        self.push(result);
                        break; // exit run loop
                    }
                },
```

Key insight: `yield_value` acts like `return` but saves state instead of destroying it.
The `run(until_frame)` call in `executeGenerator` will return when frame_count drops to
`until_frame`, and the yielded `{value, done}` result is on the stack.

- [ ] **Step 12: Run basic generator test, verify pass**

- [ ] **Step 13: Add more generator tests**

```zig
test "eval: generator with return" {
    const result = try evalExpr(
        \\function* f() { return 42; }
        \\f().next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: generator next with value" {
    const result = try evalExpr(
        \\function* f() {
        \\  let x = yield 1;
        \\  yield x + 10;
        \\}
        \\let it = f();
        \\it.next();
        \\it.next(5).value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.asNumber(), 0.001);
}

test "eval: generator range" {
    const result = try evalExpr(
        \\function* range(n) {
        \\  for (let i = 0; i < n; i++) yield i;
        \\}
        \\let sum = 0;
        \\let it = range(5);
        \\let r = it.next();
        \\while (!r.done) { sum += r.value; r = it.next(); }
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 14: Commit generators**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): generator functions with yield and iterator protocol"
```

- [ ] **Step 15: Update for-of to use iterator protocol**

Add `get_iterator` opcode handler to VM:
```zig
                .get_iterator => {
                    const iterable = self.pop();
                    if (iterable.isObject()) {
                        const obj = iterable.asJsObject();
                        // Check Symbol.iterator
                        if (obj.symbol_props) |sp| {
                            if (sp.get(VM.SYMBOL_ITERATOR)) |iter_fn| {
                                const iterator = try self.callJsFunction(iter_fn, iterable, &.{});
                                self.push(iterator);
                                continue;
                            }
                        }
                        // Array fallback: create index-based iterator
                        if (obj.obj_type == .array) {
                            const iter = try self.createArrayIterator(iterable);
                            self.push(JsValue.initObject(iter));
                            continue;
                        }
                        // Generator objects are already iterators
                        if (obj.obj_type == .generator) {
                            self.push(iterable);
                            continue;
                        }
                    }
                    // String fallback
                    if (iterable.isString()) {
                        const iter = try self.createStringIterator(iterable);
                        self.push(JsValue.initObject(iter));
                        continue;
                    }
                    return error.NotIterable;
                },
```

Implement `createArrayIterator` and `createStringIterator` — create objects with a `.next()` method that walks by index.

- [ ] **Step 16: Update compiler for-of to use get_iterator**

Modify `compileForOfIn` (~line 1227) — when `is_for_in == false` (for-of):

Replace the current index-based approach with:
```zig
        if (!is_for_in) {
            // for-of: use iterator protocol
            try self.compileNode(right);
            try self.emitOp(.get_iterator);
            const iter_name = self.parser.pool.intern("__iter") catch return error.OutOfMemory;
            _ = try self.addLocal(iter_name);

            const loop_start = self.current.bc.currentOffset();
            // iter.next()
            try self.compileIdentifierLoad(iter_name);
            try self.emitOp(.dup);
            const next_id = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(try self.parser.pool.intern("next"))));
            try self.emitOpU16(.get_prop, next_id);
            try self.emitOpU16(.call_method, 0); // result = iter.next()
            // result on stack, check .done
            try self.emitOp(.dup);
            const done_id = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(try self.parser.pool.intern("done"))));
            try self.emitOpU16(.get_prop, done_id);
            const exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_true);
            // Get .value
            const value_id = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(try self.parser.pool.intern("value"))));
            try self.emitOpU16(.get_prop, value_id);
            try self.compileStoreVar(var_name.?);

            self.pushLoopCtx(self.current.scope_depth, false);
            try self.compileNode(body);
            const continue_target = self.current.bc.currentOffset();
            self.patchContinueJumps(continue_target);
            try self.emitLoop(loop_start);

            self.current.bc.patchJump(exit_jump);
            try self.emitOp(.pop); // discard last result
            self.patchBreakJumps();
            self.popLoopCtx();
            try self.endScope();
            return;
        }
```

- [ ] **Step 17: Test for-of regression**

```zig
test "eval: for-of array still works" {
    const result = try evalExpr(
        \\let sum = 0;
        \\for (let x of [1,2,3]) { sum += x; }
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: for-of generator" {
    const result = try evalExpr(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\let sum = 0;
        \\for (let x of g()) { sum += x; }
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 18: Run all tests, verify pass**

- [ ] **Step 19: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): for-of iterator protocol with generator support"
```

---

### Task 8: WeakMap / WeakSet

**Files:**
- Modify: `src/js/kotori/object.zig` (add `weak_map`, `weak_set` obj_types + data)
- Modify: `src/js/kotori/vm.zig` (register constructors + methods in initBuiltins)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "eval: WeakMap basic" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 42);
        \\wm.get(o)
    );
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.asNumber(), 0.001);
}

test "eval: WeakMap has and delete" {
    const result = try evalExpr(
        \\let wm = new WeakMap();
        \\let o = {};
        \\wm.set(o, 1);
        \\wm.delete(o);
        \\wm.has(o)
    );
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "eval: WeakSet basic" {
    const result = try evalExpr(
        \\let ws = new WeakSet();
        \\let o = {};
        \\ws.add(o);
        \\ws.has(o)
    );
    try std.testing.expect(result.asBool());
}
```

- [ ] **Step 2: Run tests, verify fail**

- [ ] **Step 3: Add obj_types and data**

In `object.zig`:
```zig
    weak_map,
    weak_set,
```

Add data:
```zig
        weak_map_data: std.AutoArrayHashMapUnmanaged(usize, JsValue), // @intFromPtr(obj) → value
        weak_set_data: std.AutoArrayHashMapUnmanaged(usize, void),     // @intFromPtr(obj) → void
```

Update deinit.

- [ ] **Step 4: Register WeakMap/WeakSet in initBuiltins**

Register as constructors with `.set()`, `.get()`, `.has()`, `.delete()` (WeakMap) and `.add()`, `.has()`, `.delete()` (WeakSet).

Each method:
- Check that key is an object (throw TypeError if primitive)
- Use `@intFromPtr(key.asJsObject())` as the hash key

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add -A && git commit -m "feat(kotori): WeakMap and WeakSet"
```

---

## Final Verification

- [ ] **Run all kotori tests**: `cd ~/suzume && zig build test-kotori`
- [ ] **Verify test count increased significantly** (was 348)
- [ ] **Run suzume browser build** to verify no regressions: `cd ~/suzume && zig build`
