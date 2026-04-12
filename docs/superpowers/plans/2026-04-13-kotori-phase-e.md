# kotori Phase E — Iterator Protocol + Async Generators Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iterator protocol (for-of, yield*, spread), Array/String Symbol.iterator, async generators, and for-await-of to kotori.

**Architecture:** Two stages. Stage 1 builds sync iterator infrastructure (get_iterator opcode, for-of rewrite, yield_delegate, spread iterator support). Stage 2 adds async generators and for-await-of on top. Shared `resolveIterator` helper avoids code duplication.

**Tech Stack:** Zig, kotori VM (NaN-boxed stack VM), test via `zig build test-kotori`

**Spec:** `docs/superpowers/specs/2026-04-13-kotori-phase-e-design.md`

**Test helpers:**
- `evalExpr(source)` — compile+run JS, return last expression value
- `evalWithMicrotasks(source, global_name)` — run+drain microtasks, return named global
- Test file: `tests/test_kotori_vm.zig`
- Build/test: `cd ~/suzume && zig build test-kotori`

**VM conventions:**
- `store_local` peeks TOS (doesn't pop)
- `call_method N` consumes this+func+N args, pushes 1 result
- `get_prop` pops object, pushes property (replaces TOS)
- `jump_if_true`/`jump_if_false` pop TOS

---

## Stage 1: Sync Iterator Infrastructure

### Task 1: IteratorData + iterator ObjType

**Files:**
- Modify: `src/js/kotori/object.zig`

- [ ] **Step 1: Add iterator obj_type and IteratorData**

In `object.zig`, add `iterator` to ObjType enum and IteratorData struct:

```zig
// In ObjType enum, after async_generator:
    iterator,

// New struct before FunctionObj:
pub const IteratorData = struct {
    source: JsValue,
    index: u32 = 0,
};

// In ObjData union, add:
    iterator_data: IteratorData,
```

Update `deinit` — `iterator_data` has no heap allocations, add to the no-op line:
```zig
.none, .native_fn, .dom_node, .dom_style, .regexp_data, .date_ms, .iterator_data => {},
```

- [ ] **Step 2: Add await_pending to GeneratorState and delegate_iterator to GeneratorData**

```zig
pub const GeneratorState = enum(u8) {
    suspended_start,
    suspended_yield,
    executing,
    completed,
    await_pending,  // new: async generator hit await
};

pub const GeneratorData = struct {
    state: GeneratorState = .suspended_start,
    func_obj: *JsObject,
    saved_ip: u32 = 0,
    saved_stack: []JsValue = &.{},
    this_val: JsValue = JsValue.undefined_val,
    init_args: []JsValue = &.{},
    delegate_iterator: ?JsValue = null,  // new: active yield* inner iterator
};
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `cd ~/suzume && zig build test-kotori 2>&1; echo "EXIT: $?"`
Expected: exit 0

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/js/kotori/object.zig && git commit -m "feat(kotori): add iterator ObjType, IteratorData, GeneratorState.await_pending"
```

---

### Task 2: get_iterator opcode + resolveIterator helper

**Files:**
- Modify: `src/js/kotori/bytecode.zig`
- Modify: `src/js/kotori/vm.zig`
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Add get_iterator opcode**

In `bytecode.zig`, add before the yield_value opcode:

```zig
    // Iterators
    get_iterator,   // stack: [iterable] → [iterator]
```

- [ ] **Step 2: Add resolveIterator, findSymbolProp, createArrayIterator, createStringIterator helpers**

In `vm.zig`, add these helper functions near the generator support section:

```zig
    // ── Iterator support ──────────────────────────────────────────────

    fn resolveIterator(self: *VM, iterable: JsValue) !?JsValue {
        if (iterable.isObject()) {
            const obj = iterable.asJsObject();
            // Generator objects are their own iterators
            if (obj.obj_type == .generator) return iterable;
            // Check Symbol.iterator on own + prototype chain
            if (self.findSymbolProp(obj, SYMBOL_ITERATOR)) |iter_fn| {
                return try self.callJsFunction(iter_fn, iterable, &.{});
            }
            // Array fallback
            if (obj.obj_type == .array) {
                return JsValue.initObject(try self.createArrayIterator(iterable));
            }
        }
        // String fallback
        if (iterable.isString()) {
            return JsValue.initObject(try self.createStringIterator(iterable));
        }
        return null;
    }

    fn findSymbolProp(_: *VM, obj: *JsObject, sym_id: u32) ?JsValue {
        var current: ?*JsObject = obj;
        while (current) |cur| {
            if (cur.symbol_props) |sp| {
                if (sp.get(sym_id)) |val| return val;
            }
            current = cur.prototype;
        }
        return null;
    }

    fn createArrayIterator(self: *VM, source: JsValue) !*JsObject {
        const iter = try self.createObj(.{ .obj_type = .iterator });
        iter.data = .{ .iterator_data = .{ .source = source } };
        try self.registerNativeMethod(iter, "next", &nativeIteratorNext);
        return iter;
    }

    fn createStringIterator(self: *VM, source: JsValue) !*JsObject {
        const iter = try self.createObj(.{ .obj_type = .iterator });
        iter.data = .{ .iterator_data = .{ .source = source } };
        try self.registerNativeMethod(iter, "next", &nativeStringIteratorNext);
        return iter;
    }

    fn nativeIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const obj = this.asJsObject();
        if (obj.obj_type != .iterator) return try vm.createIterResult(JsValue.undefined_val, true);
        var data = &obj.data.iterator_data;
        if (!data.source.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const src = data.source.asJsObject();
        if (src.obj_type != .array) return try vm.createIterResult(JsValue.undefined_val, true);
        if (data.index < src.data.array.items.len) {
            const val = src.data.array.items[data.index];
            data.index += 1;
            return try vm.createIterResult(val, false);
        }
        return try vm.createIterResult(JsValue.undefined_val, true);
    }

    fn nativeStringIteratorNext(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return try vm.createIterResult(JsValue.undefined_val, true);
        const obj = this.asJsObject();
        if (obj.obj_type != .iterator) return try vm.createIterResult(JsValue.undefined_val, true);
        var data = &obj.data.iterator_data;
        if (!data.source.isString()) return try vm.createIterResult(JsValue.undefined_val, true);
        const s = vm.pool.get(data.source.asStringId()) orelse return try vm.createIterResult(JsValue.undefined_val, true);
        if (data.index >= s.len) return try vm.createIterResult(JsValue.undefined_val, true);
        // UTF-8 codepoint iteration
        const byte = s[data.index];
        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const end = @min(data.index + cp_len, @as(u32, @intCast(s.len)));
        const char_str = try vm.pool.intern(s[data.index..end]);
        data.index = end;
        return try vm.createIterResult(JsValue.initString(char_str), false);
    }
```

- [ ] **Step 3: Add get_iterator opcode handler**

In `vm.zig` run() switch, add:

```zig
                .get_iterator => {
                    const iterable = self.pop();
                    if (try self.resolveIterator(iterable)) |iterator| {
                        self.push(iterator);
                    } else {
                        // Non-iterable: push a "done" iterator to avoid crash
                        const done_iter = try self.createObj(.{ .obj_type = .iterator });
                        done_iter.data = .{ .iterator_data = .{ .source = JsValue.undefined_val } };
                        try self.registerNativeMethod(done_iter, "next", &nativeIteratorNext);
                        self.push(JsValue.initObject(done_iter));
                    }
                },
```

- [ ] **Step 4: Write test for manual iterator usage**

```zig
test "eval: array iterator manual" {
    const result = try evalExpr(
        \\let a = [10, 20, 30];
        \\let it = a[Symbol.iterator]();
        \\it.next().value
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.asNumber(), 0.001);
}
```

Note: This test depends on Feature 4 (Array Symbol.iterator registration). If implementing in order, add the Symbol.iterator registration first (see Task 4), or skip this test and add it later.

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
cd ~/suzume && git add src/js/kotori/bytecode.zig src/js/kotori/vm.zig && git commit -m "feat(kotori): get_iterator opcode + resolveIterator helper"
```

---

### Task 3: Array/String Symbol.iterator Registration

**Files:**
- Modify: `src/js/kotori/vm.zig` (in initBuiltins)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Register Symbol.iterator on array_proto**

In `initBuiltins`, after the existing array_proto setup, add:

```zig
        // Register Symbol.iterator on array prototype
        if (self.array_proto) |ap| {
            if (ap.symbol_props == null) ap.symbol_props = .{};
            const arr_iter_fn = try self.createNativeFn(&nativeArraySymbolIterator);
            try ap.symbol_props.?.put(self.allocator, SYMBOL_ITERATOR, JsValue.initObject(arr_iter_fn));
        }
```

Add native function:
```zig
    fn nativeArraySymbolIterator(ctx: *anyopaque, this: JsValue, _: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        return JsValue.initObject(try vm.createArrayIterator(this));
    }
```

- [ ] **Step 2: Write tests**

```zig
test "eval: array Symbol.iterator" {
    const result = try evalExpr(
        \\let a = [10, 20];
        \\let it = a[Symbol.iterator]();
        \\let v1 = it.next().value;
        \\let v2 = it.next().value;
        \\v1 + v2
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 3: Run tests, verify pass**

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): Array.prototype[Symbol.iterator] registration"
```

---

### Task 4: Rewrite for-of to use Iterator Protocol

**Files:**
- Modify: `src/js/kotori/compiler.zig` (~line 1249, compileForOfIn)
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing tests for generator for-of**

```zig
test "eval: for-of generator" {
    const result = try evalExpr(
        \\function* g() { yield 10; yield 20; }
        \\let sum = 0;
        \\for (let x of g()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), result.asNumber(), 0.001);
}

test "eval: for-of string chars" {
    const result = try evalExpr(
        \\let s = "";
        \\for (let c of "hi") s += c;
        \\s
    );
    try std.testing.expect(result.isString());
}
```

- [ ] **Step 2: Run tests, verify generator for-of fails**

- [ ] **Step 3: Rewrite the for-of path in compileForOfIn**

In `compiler.zig`, `compileForOfIn` (~line 1249). The `is_for_in == false` path needs replacement.

Replace the block from `if (is_for_in)` / else (the for-of path starting at ~line 1266 with `try self.emitOp(.dup); try self.emitOp(.get_length);`) through the end of the function with:

```zig
        if (is_for_in) {
            // for-in: existing index-based path (unchanged)
            try self.emitOp(.get_keys);
            // ... (keep existing for-in code unchanged)
        } else {
            // for-of: iterator protocol
            try self.emitOp(.get_iterator);
            const iter_name = self.parser.pool.intern("__iter") catch return error.OutOfMemory;
            _ = try self.addLocal(iter_name);
            // iter is already on the stack as the local slot

            const loop_start = self.current.bc.currentOffset();

            // Load iterator, dup for call_method consumption
            try self.compileIdentifierLoad(iter_name);
            try self.emitOp(.dup);
            // Get .next method
            const next_id = try self.parser.pool.intern("next");
            const next_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(next_id)));
            try self.emitOpU16(.get_prop, next_ci);
            // call_method 0: consumes iter+next_fn, pushes result
            try self.emitOpU16(.call_method, 0);
            // dup result, check .done
            try self.emitOp(.dup);
            const done_id = try self.parser.pool.intern("done");
            const done_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(done_id)));
            try self.emitOpU16(.get_prop, done_ci);
            const exit_jump = try self.current.bc.emitJump(self.allocator, .jump_if_true);
            // Not done: get .value
            const value_id = try self.parser.pool.intern("value");
            const value_ci = try self.current.bc.addConstant(self.allocator, JsValue.initInt(@bitCast(value_id)));
            try self.emitOpU16(.get_prop, value_ci);
            // Store to loop variable
            try self.compileStoreVar(var_name.?);
            try self.emitOp(.pop); // discard store_local's peek residue

            self.pushLoopCtx(self.current.scope_depth, false);
            try self.compileNode(body);
            const continue_target = self.current.bc.currentOffset();
            self.patchContinueJumps(continue_target);
            try self.emitLoop(loop_start);

            // Exit
            self.current.bc.patchJump(exit_jump);
            try self.emitOp(.pop); // discard final result object
            self.patchBreakJumps();
            self.popLoopCtx();
            try self.endScope();
            return;
        }
```

Keep the existing for-in path completely unchanged.

- [ ] **Step 4: Run tests — verify BOTH new generator for-of AND existing array for-of pass**

Run: `cd ~/suzume && zig build test-kotori`

Critical regression check: existing `for (let x of [1,2,3])` tests must still pass.

- [ ] **Step 5: Commit**

```bash
cd ~/suzume && git add src/js/kotori/compiler.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): for-of uses iterator protocol — generators and custom iterables work"
```

---

### Task 5: yield* Delegation

**Files:**
- Modify: `src/js/kotori/bytecode.zig`
- Modify: `src/js/kotori/vm.zig`
- Modify: `src/js/kotori/compiler.zig`
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing test**

```zig
test "eval: yield* delegation" {
    const result = try evalExpr(
        \\function* a() { yield 1; yield 2; }
        \\function* b() { yield* a(); yield 3; }
        \\let sum = 0;
        \\for (let x of b()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: yield* array" {
    const result = try evalExpr(
        \\function* g() { yield* [10, 20]; yield 30; }
        \\let sum = 0;
        \\for (let x of g()) sum += x;
        \\sum
    );
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Add yield_delegate opcode**

In `bytecode.zig`:
```zig
    yield_delegate, // yield*: delegate to sub-iterator
```

- [ ] **Step 3: Update compiler to emit yield_delegate**

The compiler already has a `.yield_expr` handler from Phase D. Modify it:

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

- [ ] **Step 4: Add yield_delegate opcode handler (initial call)**

In `vm.zig`, add handler:

```zig
                .yield_delegate => {
                    if (self.active_generator) |gen| {
                        const iterable = self.pop();
                        // Resolve iterator
                        const iterator = try self.resolveIterator(iterable) orelse {
                            // Not iterable: yield* expression evaluates to undefined
                            self.push(JsValue.undefined_val);
                            continue;
                        };
                        // First call to inner iterator
                        const result = try self.callIteratorNext(iterator, JsValue.undefined_val);
                        const done = try self.getIterResultDone(result);
                        if (done) {
                            // Inner iterator immediately done
                            const value = try self.getIterResultValue(result);
                            self.push(value); // yield* evaluates to return value
                            continue;
                        }
                        // Not done: store delegate, suspend like yield_value
                        gen.delegate_iterator = iterator;
                        const yield_val = try self.getIterResultValue(result);
                        // Save state (same as yield_value)
                        const f = &self.frames[self.frame_count - 1];
                        const base = f.base_sp;
                        const stack_len = self.sp - base;
                        if (gen.saved_stack.len > 0) self.allocator.free(gen.saved_stack);
                        const saved = try self.allocator.alloc(JsValue, stack_len);
                        @memcpy(saved, self.stack[base..self.sp]);
                        gen.saved_ip = f.ip;
                        gen.saved_stack = saved;
                        gen.state = .suspended_yield;
                        self.frame_count -= 1;
                        self.sp = base;
                        if (self.sp > 0) self.sp -= 1;
                        return try self.createIterResult(yield_val, false);
                    } else {
                        _ = self.pop();
                        self.push(JsValue.undefined_val);
                    }
                },
```

- [ ] **Step 5: Add iterator helper methods**

```zig
    fn callIteratorNext(self: *VM, iterator: JsValue, sent_value: JsValue) !JsValue {
        const next_id = try self.pool.intern("next");
        if (iterator.isObject()) {
            const obj = iterator.asJsObject();
            if (obj.getProperty(next_id)) |next_fn| {
                return try self.callJsFunction(next_fn, iterator, &.{sent_value});
            }
        }
        return try self.createIterResult(JsValue.undefined_val, true);
    }

    fn getIterResultDone(self: *VM, result: JsValue) !bool {
        if (!result.isObject()) return true;
        const done_id = try self.pool.intern("done");
        const done = result.asJsObject().getProperty(done_id) orelse JsValue.initBool(true);
        return done.isTruthy();
    }

    fn getIterResultValue(self: *VM, result: JsValue) !JsValue {
        if (!result.isObject()) return JsValue.undefined_val;
        const value_id = try self.pool.intern("value");
        return result.asJsObject().getProperty(value_id) orelse JsValue.undefined_val;
    }
```

- [ ] **Step 6: Modify nativeGeneratorNext to handle delegate_iterator**

In the existing `nativeGeneratorNext`, add delegation check at the top of the function:

```zig
    fn nativeGeneratorNext(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;

        // yield* delegation active
        if (gen.delegate_iterator) |delegate| {
            const sent = if (args.len > 0) args[0] else JsValue.undefined_val;
            const result = try vm.callIteratorNext(delegate, sent);
            const done = try vm.getIterResultDone(result);
            if (done) {
                gen.delegate_iterator = null;
                // Resume generator with inner return value as yield* expression result
                gen.state = .executing;
                const final_value = try vm.getIterResultValue(result);
                return try vm.executeGenerator(gen, final_value, true);
            } else {
                // Forward inner yield to outer caller
                const value = try vm.getIterResultValue(result);
                return try vm.createIterResult(value, false);
            }
        }

        // Normal generator next (existing code)
        switch (gen.state) {
            // ... existing code unchanged
        }
    }
```

- [ ] **Step 7: Run tests, verify pass**

- [ ] **Step 8: Commit**

```bash
cd ~/suzume && git add src/js/kotori/bytecode.zig src/js/kotori/compiler.zig src/js/kotori/vm.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): yield* delegation to sub-iterators"
```

---

### Task 6: Spread Iterator Support

**Files:**
- Modify: `src/js/kotori/vm.zig`
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Write failing test**

```zig
test "eval: spread generator" {
    const result = try evalExpr(
        \\function* range(n) { for (let i = 0; i < n; i++) yield i; }
        \\let a = [...range(4)];
        \\a[0] + a[1] + a[2] + a[3]
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 2: Add drainIteratorIntoArray helper and modify spread_into_array**

Add helper:
```zig
    fn drainIteratorIntoArray(self: *VM, iterator_val: JsValue, arr: *JsObject) !void {
        const next_id = try self.pool.intern("next");
        const done_id = try self.pool.intern("done");
        const value_id = try self.pool.intern("value");
        var iterations: u32 = 0;
        while (iterations < 10000) : (iterations += 1) {
            if (!iterator_val.isObject()) break;
            const iter_obj = iterator_val.asJsObject();
            const next_fn = iter_obj.getProperty(next_id) orelse break;
            const result = try self.callJsFunction(next_fn, iterator_val, &.{});
            if (!result.isObject()) break;
            const result_obj = result.asJsObject();
            const done = result_obj.getProperty(done_id) orelse JsValue.initBool(true);
            if (done.isTruthy()) break;
            const value = result_obj.getProperty(value_id) orelse JsValue.undefined_val;
            try arr.data.array.append(self.allocator, value);
        }
    }
```

In `spread_into_array` handler, after the existing string path, add iterator fallback:

```zig
                    // Iterator protocol fallback (generators, custom iterables)
                    if (iterable.isObject()) {
                        const obj = iterable.asJsObject();
                        if (obj.obj_type == .generator or obj.obj_type == .iterator) {
                            try self.drainIteratorIntoArray(iterable, arr);
                            continue;
                        }
                        // Check Symbol.iterator
                        if (self.findSymbolProp(obj, SYMBOL_ITERATOR)) |iter_fn| {
                            const iterator = try self.callJsFunction(iter_fn, iterable, &.{});
                            try self.drainIteratorIntoArray(iterator, arr);
                            continue;
                        }
                    }
```

Note: Add this AFTER the existing array fast path and string path, but BEFORE the final continue/no-op.

- [ ] **Step 3: Run tests, verify pass**

- [ ] **Step 4: Commit**

```bash
cd ~/suzume && git add src/js/kotori/vm.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): spread operator supports generators and iterables"
```

---

## Stage 2: Async Generators + for-await-of

### Task 7: Async Generator Object

**Files:**
- Modify: `src/js/kotori/object.zig`
- Modify: `src/js/kotori/vm.zig`
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Add async_generator obj_type**

In `object.zig`, add to ObjType:
```zig
    async_generator,
```

- [ ] **Step 2: Detect async generator in call opcode**

In `vm.zig`, the `call` opcode handler, after the `is_generator` check, add:

```zig
                    if (func.is_generator and func.is_async) {
                        const base = self.sp - arg_count;
                        var init_args_alloc: []JsValue = &.{};
                        if (arg_count > 0) {
                            init_args_alloc = try self.allocator.alloc(JsValue, arg_count);
                            @memcpy(init_args_alloc, self.stack[base..self.sp]);
                        }
                        self.sp = base - 1;
                        const gen_obj = try self.createAsyncGeneratorObject(obj);
                        gen_obj.data.generator_data.init_args = init_args_alloc;
                        self.push(JsValue.initObject(gen_obj));
                        continue;
                    }
```

This must come BEFORE the existing `if (func.is_generator)` check.

- [ ] **Step 3: Add createAsyncGeneratorObject**

```zig
    fn createAsyncGeneratorObject(self: *VM, func_obj: *JsObject) !*JsObject {
        const gen_obj = try self.createObj(.{ .obj_type = .async_generator });
        gen_obj.data = .{ .generator_data = .{
            .state = .suspended_start,
            .func_obj = func_obj,
        } };
        try self.registerNativeMethod(gen_obj, "next", &nativeAsyncGeneratorNext);
        try self.registerNativeMethod(gen_obj, "return", &nativeAsyncGeneratorReturn);
        return gen_obj;
    }
```

- [ ] **Step 4: Add nativeAsyncGeneratorNext**

Async generator's `.next()` wraps the result in a Promise:

```zig
    fn nativeAsyncGeneratorNext(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .async_generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;

        // For simplicity: execute synchronously and wrap result in resolved Promise
        const result = switch (gen.state) {
            .completed => try vm.createIterResult(JsValue.undefined_val, true),
            .executing, .await_pending => return JsValue.undefined_val,
            .suspended_start => blk: {
                gen.state = .executing;
                break :blk try vm.executeGenerator(gen, JsValue.undefined_val, false);
            },
            .suspended_yield => blk: {
                gen.state = .executing;
                const sent = if (args.len > 0) args[0] else JsValue.undefined_val;
                break :blk try vm.executeGenerator(gen, sent, true);
            },
        };

        // Wrap in resolved Promise
        return try vm.createResolvedPromise(result);
    }

    fn nativeAsyncGeneratorReturn(ctx: *anyopaque, this: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = vmFromCtx(ctx);
        if (!this.isObject()) return JsValue.undefined_val;
        const obj = this.asJsObject();
        if (obj.obj_type != .async_generator) return JsValue.undefined_val;
        var gen = &obj.data.generator_data;
        gen.state = .completed;
        const value = if (args.len > 0) args[0] else JsValue.undefined_val;
        const result = try vm.createIterResult(value, true);
        return try vm.createResolvedPromise(result);
    }
```

- [ ] **Step 5: Add createResolvedPromise helper**

```zig
    fn createResolvedPromise(self: *VM, value: JsValue) !JsValue {
        const promise = try self.createObj(.{ .obj_type = .promise });
        promise.data = .{ .promise_data = .{
            .state = .fulfilled,
            .result = value,
        } };
        if (self.promise_proto) |pp| promise.prototype = pp;
        // Register .then/.catch on this promise
        try self.registerNativeMethod(promise, "then", &nativePromiseThen);
        try self.registerNativeMethod(promise, "catch", &nativePromiseCatch);
        return JsValue.initObject(promise);
    }
```

Note: Check if `nativePromiseThen` / `nativePromiseCatch` already exist from Promise implementation. If they're registered on `promise_proto`, the prototype chain will handle it and you don't need to register them on each instance.

- [ ] **Step 6: Write test**

```zig
test "eval: async generator basic" {
    const result = try evalWithMicrotasks(
        \\async function* ag() { yield 1; yield 2; }
        \\let it = ag();
        \\let r1, r2;
        \\it.next().then(r => { r1 = r.value; });
        \\it.next().then(r => { r2 = r.value; });
        \\globalThis.__r1 = r1;
        \\globalThis.__r2 = r2;
    , "__r1");
    // Check r1 is 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}
```

Note: Async generator tests are tricky with the current test infrastructure because `.then()` callbacks
run via microtask queue. May need to adjust the test pattern. A simpler approach if `await` works in
test context:

```zig
test "eval: async generator with await" {
    const result = try evalWithMicrotasks(
        \\let result = 0;
        \\async function* ag() { yield 1; yield 2; }
        \\async function main() {
        \\  let it = ag();
        \\  let r = await it.next();
        \\  result = r.value;
        \\}
        \\main();
    , "result");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 7: Run tests, verify pass**

- [ ] **Step 8: Commit**

```bash
cd ~/suzume && git add src/js/kotori/object.zig src/js/kotori/vm.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): async generator functions (async function*)"
```

---

### Task 8: for-await-of

**Files:**
- Modify: `src/js/kotori/ast.zig`
- Modify: `src/js/kotori/bytecode.zig`
- Modify: `src/js/kotori/parser.zig`
- Modify: `src/js/kotori/compiler.zig`
- Modify: `src/js/kotori/vm.zig`
- Test: `tests/test_kotori_vm.zig`

- [ ] **Step 1: Add is_await to for_of_stmt AST**

In `ast.zig`, modify `for_of_stmt`:
```zig
    for_of_stmt: struct { left: NodeIndex, right: NodeIndex, body: NodeIndex, is_await: bool = false },
```

- [ ] **Step 2: Add SYMBOL_ASYNC_ITERATOR and get_async_iterator opcode**

In `vm.zig`, update `next_symbol_id` to 5 and add:
```zig
    pub const SYMBOL_ASYNC_ITERATOR: u32 = 4;
```

In `bytecode.zig`:
```zig
    get_async_iterator, // stack: [iterable] → [async_iterator]
```

- [ ] **Step 3: Parse `for await (`**

In `parser.zig`, in `parseStatement`, find the `kw_for` handler. After consuming `for`:

```zig
            .kw_for => {
                self.advance(); // consume 'for'
                var is_await = false;
                if (self.current.type == .kw_await) {
                    is_await = true;
                    self.advance(); // consume 'await'
                }
                try self.expect(.lparen);
                // ... existing for parsing ...
                // When creating for_of_stmt node, pass is_await
```

The exact integration depends on the existing for parsing structure. The `is_await` flag
needs to be threaded through to where `for_of_stmt` node is created.

- [ ] **Step 4: Add get_async_iterator handler**

```zig
                .get_async_iterator => {
                    const iterable = self.pop();
                    // Check Symbol.asyncIterator first
                    if (iterable.isObject()) {
                        const obj = iterable.asJsObject();
                        if (self.findSymbolProp(obj, SYMBOL_ASYNC_ITERATOR)) |iter_fn| {
                            const result = try self.callJsFunction(iter_fn, iterable, &.{});
                            self.push(result);
                            continue;
                        }
                    }
                    // Fallback to sync iterator
                    if (try self.resolveIterator(iterable)) |iterator| {
                        self.push(iterator);
                    } else {
                        const done_iter = try self.createObj(.{ .obj_type = .iterator });
                        done_iter.data = .{ .iterator_data = .{ .source = JsValue.undefined_val } };
                        try self.registerNativeMethod(done_iter, "next", &nativeIteratorNext);
                        self.push(JsValue.initObject(done_iter));
                    }
                },
```

- [ ] **Step 5: Compile for-await-of**

In `compiler.zig`, in the for-of compilation path, check `is_await` flag:

```zig
        // At the start of the for-of path:
        const is_await_of = /* check AST node's is_await field */;
        if (is_await_of) {
            try self.emitOp(.get_async_iterator);
        } else {
            try self.emitOp(.get_iterator);
        }
        // ... rest is same, but after call_method 0, insert await_ if is_await_of:
        try self.emitOpU16(.call_method, 0);
        if (is_await_of) {
            try self.emitOp(.await_);  // await the .next() result
        }
        // ... rest unchanged
```

- [ ] **Step 6: Write test**

```zig
test "eval: for-await-of with async generator" {
    const result = try evalWithMicrotasks(
        \\let sum = 0;
        \\async function* ag() { yield 1; yield 2; yield 3; }
        \\async function main() {
        \\  for await (let x of ag()) { sum += x; }
        \\}
        \\main();
    , "sum");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}

test "eval: for-await-of with sync array" {
    const result = try evalWithMicrotasks(
        \\let sum = 0;
        \\async function main() {
        \\  for await (let x of [1,2,3]) { sum += x; }
        \\}
        \\main();
    , "sum");
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.asNumber(), 0.001);
}
```

- [ ] **Step 7: Run all tests**

- [ ] **Step 8: Commit**

```bash
cd ~/suzume && git add src/js/kotori/ast.zig src/js/kotori/bytecode.zig src/js/kotori/parser.zig src/js/kotori/compiler.zig src/js/kotori/vm.zig tests/test_kotori_vm.zig && git commit -m "feat(kotori): for-await-of with async iterator protocol"
```

---

## Final Verification

- [ ] **Run all kotori tests**: `cd ~/suzume && zig build test-kotori`
- [ ] **Verify test count increased** (was 387)
- [ ] **Run suzume browser build**: `cd ~/suzume && zig build`
