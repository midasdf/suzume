// Heap-allocated JS objects: ordinary objects, functions, upvalue cells.

const std = @import("std");
const value_mod = @import("value.zig");
const string_pool = @import("string_pool.zig");
const bytecode_mod = @import("bytecode.zig");

const JsValue = value_mod.JsValue;
const StringId = string_pool.StringId;
const Bytecode = bytecode_mod.Bytecode;

pub const ObjType = enum(u8) {
    ordinary,
    function,
    array,
    native_function,
    dom_node,
    dom_style,
    window_proxy,
    map,
    set,
    regexp,
    promise,
    date,
    weak_map,
    weak_set,
    generator,
    iterator,
    async_generator,
    typed_array,
    array_buffer,
    proxy,
};

/// ECMA-262 §23.2 — element type tag for typed arrays.
pub const TypedArrayKind = enum(u8) {
    u8_t, // Uint8Array
    i8_t, // Int8Array
    u16_t, // Uint16Array
    i16_t, // Int16Array
    u32_t, // Uint32Array
    i32_t, // Int32Array
    f32_t, // Float32Array
    f64_t, // Float64Array
    u64_big, // BigUint64Array (stored as raw bytes, no BigInt JS value yet)
    i64_big, // BigInt64Array  (stored as raw bytes, no BigInt JS value yet)
    u8_clamped, // Uint8ClampedArray (clamp on write, same read as u8_t)

    /// Number of bytes per element.
    pub fn elementSize(self: TypedArrayKind) usize {
        return switch (self) {
            .u8_t, .i8_t, .u8_clamped => 1,
            .u16_t, .i16_t => 2,
            .u32_t, .i32_t, .f32_t => 4,
            .f64_t, .u64_big, .i64_big => 8,
        };
    }
};

/// Backing storage for a typed array — owns or views raw bytes.
pub const TypedArrayData = struct {
    kind: TypedArrayKind,
    /// Raw bytes. May be an owned allocation or a view into an ArrayBuffer.
    bytes: []u8,
    /// True when this object owns the allocation (must free on deinit).
    owned: bool,
};

/// Per-property attribute bits (packed into one byte).
pub const PropertyAttrs = packed struct(u8) {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    is_accessor: bool = false,
    _pad: u4 = 0,
};

/// Full property descriptor — either a data property or an accessor property.
/// `get` / `set` are each a callable JsValue or undefined.
pub const PropertyDescriptor = union(enum) {
    data: struct { value: JsValue, attrs: PropertyAttrs },
    accessor: struct { get: JsValue, set: JsValue, attrs: PropertyAttrs },

    pub fn attrs(self: PropertyDescriptor) PropertyAttrs {
        return switch (self) {
            .data => |d| d.attrs,
            .accessor => |a| a.attrs,
        };
    }
};

pub const JsObject = struct {
    obj_type: ObjType = .ordinary,
    /// Fast path: value-only map. An entry here implies all-default attrs
    /// (writable=true, enumerable=true, configurable=true, data property).
    properties: std.AutoArrayHashMapUnmanaged(StringId, JsValue) = .{},
    /// Slow path: only allocated when at least one property has non-default
    /// attrs or is an accessor. When present for a key, `properties` must NOT
    /// also contain that key — the slow map is authoritative.
    descriptors: ?std.AutoArrayHashMapUnmanaged(StringId, PropertyDescriptor) = null,
    /// [[Extensible]] internal slot. Defaults to true.
    extensible: bool = true,
    prototype: ?*JsObject = null,
    data: ObjData = .none,
    symbol_props: ?std.AutoArrayHashMapUnmanaged(u32, JsValue) = null,
    symbol_descriptors: ?std.AutoArrayHashMapUnmanaged(u32, PropertyDescriptor) = null,

    pub const NativeFn = *const fn (ctx: *anyopaque, this: value_mod.JsValue, args: []const value_mod.JsValue) anyerror!value_mod.JsValue;

    pub const RegExpData = struct {
        source: string_pool.StringId, // pattern source
        global: bool = false,
        ignore_case: bool = false,
        multiline: bool = false,
        // Layer 0C §22.2.2.1 Pattern[U,N] full flag surface.
        dot_all: bool = false,
        sticky: bool = false,
        unicode: bool = false,
        has_indices: bool = false,
        last_index: u32 = 0,
    };

    pub const MapEntry = struct {
        key: value_mod.JsValue,
        val: value_mod.JsValue,
    };

    pub const PromiseState = enum(u8) { pending, fulfilled, rejected };

    pub const PromiseHandler = struct {
        on_fulfilled: value_mod.JsValue, // function or undefined
        on_rejected: value_mod.JsValue, // function or undefined
        result_promise: *JsObject, // the promise returned by .then()
    };

    pub const PromiseData = struct {
        state: PromiseState = .pending,
        result: value_mod.JsValue = value_mod.JsValue.undefined_val,
        handlers: std.ArrayListUnmanaged(PromiseHandler) = .empty,
    };

    pub const ProxyData = struct {
        target: *JsObject,
        handler: *JsObject,
        revoked: bool = false,
    };

    pub const ObjData = union(enum) {
        none,
        function: FunctionObj,
        array: std.ArrayListUnmanaged(value_mod.JsValue),
        native_fn: NativeFn,
        dom_node: *anyopaque,
        dom_style: *anyopaque,
        map_data: std.ArrayListUnmanaged(MapEntry),
        set_data: std.ArrayListUnmanaged(value_mod.JsValue),
        regexp_data: RegExpData,
        promise_data: PromiseData,
        date_ms: i64,
        weak_map_data: std.AutoArrayHashMapUnmanaged(usize, JsValue),
        weak_set_data: std.AutoArrayHashMapUnmanaged(usize, void),
        generator_data: GeneratorData,
        iterator_data: IteratorData,
        /// ArrayBuffer raw bytes (owned allocation).
        bytes_data: []u8,
        /// ArrayBuffer view (not owned — slice into another buffer).
        bytes_view: []u8,
        /// Typed array with element-type information.
        typed_array_data: TypedArrayData,
        proxy_data: ProxyData,
    };

    pub fn deinit(self: *JsObject, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        if (self.descriptors) |*d| d.deinit(allocator);
        if (self.symbol_props) |*sp| sp.deinit(allocator);
        if (self.symbol_descriptors) |*sd| sd.deinit(allocator);
        switch (self.data) {
            .function => |*f| f.deinit(allocator),
            .array => |*a| a.deinit(allocator),
            .map_data => |*m| m.deinit(allocator),
            .set_data => |*s| s.deinit(allocator),
            .promise_data => |*p| p.handlers.deinit(allocator),
            .weak_map_data => |*wm| wm.deinit(allocator),
            .weak_set_data => |*ws| ws.deinit(allocator),
            .generator_data => |*g| {
                if (g.saved_stack.len > 0) allocator.free(g.saved_stack);
                if (g.init_args.len > 0) allocator.free(g.init_args);
            },
            .bytes_data => |b| if (b.len > 0) allocator.free(b),
            .typed_array_data => |ta| if (ta.owned and ta.bytes.len > 0) allocator.free(ta.bytes),
            .none, .native_fn, .dom_node, .dom_style, .regexp_data, .date_ms, .iterator_data, .bytes_view, .proxy_data => {},
        }
    }

    /// Find an accessor descriptor for `name` walking the prototype chain.
    /// Returns the accessor struct (get/set/attrs) or null if none found.
    pub fn findAccessorDescriptor(self: *const JsObject, name: StringId) ?struct { get: JsValue, set: JsValue, attrs: PropertyAttrs } {
        var cur: ?*const JsObject = self;
        while (cur) |obj| {
            if (obj.descriptors) |*d| {
                if (d.get(name)) |desc| {
                    switch (desc) {
                        .accessor => |a| return .{ .get = a.get, .set = a.set, .attrs = a.attrs },
                        .data => return null, // data property shadows any prototype accessor
                    }
                }
            }
            if (obj.properties.contains(name)) return null; // fast-path data shadows prototype accessor
            cur = obj.prototype;
        }
        return null;
    }

    pub fn getProperty(self: *const JsObject, name: StringId) ?JsValue {
        // Slow-path first: if this key has a descriptor, honour it.
        if (self.descriptors) |*d| {
            if (d.get(name)) |desc| {
                return switch (desc) {
                    .data => |dat| dat.value,
                    // Accessor: caller must invoke the getter; return null here
                    // so higher-level code falls back to getter invocation.
                    .accessor => null,
                };
            }
        }
        if (self.properties.get(name)) |v| return v;
        if (self.prototype) |proto| return proto.getProperty(name);
        return null;
    }

    pub fn setProperty(self: *JsObject, allocator: std.mem.Allocator, name: StringId, val: JsValue) !void {
        // If already in the slow map, update value in place (respecting attrs).
        if (self.descriptors) |*d| {
            if (d.getPtr(name)) |desc| {
                switch (desc.*) {
                    .data => |*dat| {
                        if (dat.attrs.writable) dat.value = val;
                        return;
                    },
                    .accessor => return, // setter invocation handled by VM ordinarySet
                }
            }
        }
        try self.properties.put(allocator, name, val);
    }

    // ── Abstract operations ─────────────────────────────────────────

    /// OrdinaryGetOwnProperty (§10.1.5.1).
    /// Returns the descriptor for an own property, or null if not found.
    pub fn getOwnDescriptor(self: *const JsObject, name: StringId) ?PropertyDescriptor {
        if (self.descriptors) |*d| {
            if (d.get(name)) |desc| return desc;
        }
        if (self.properties.get(name)) |v| {
            return .{ .data = .{
                .value = v,
                .attrs = .{ .writable = true, .enumerable = true, .configurable = true },
            } };
        }
        return null;
    }

    /// OrdinaryIsExtensible (§10.1.3.1).
    pub fn isExtensible_(self: *const JsObject) bool {
        return self.extensible;
    }

    /// OrdinaryPreventExtensions (§10.1.4.1).
    pub fn preventExtensions_(self: *JsObject) void {
        self.extensible = false;
    }

    /// OrdinaryDelete (§10.1.10.1).
    /// Returns false (and does nothing) for non-configurable properties.
    pub fn ordinaryDelete(self: *JsObject, allocator: std.mem.Allocator, name: StringId) bool {
        if (self.descriptors) |*d| {
            if (d.get(name)) |desc| {
                if (!desc.attrs().configurable) return false;
                _ = d.swapRemove(name);
                return true;
            }
        }
        _ = self.properties.swapRemove(name);
        _ = allocator; // kept for signature consistency
        return true;
    }

    /// ValidateAndApplyPropertyDescriptor (§10.1.6.3) helper.
    /// Returns true on success, false when the change is not allowed.
    /// Mutates `self` on success.
    fn validateAndApply(
        self: *JsObject,
        allocator: std.mem.Allocator,
        name: StringId,
        current_opt: ?PropertyDescriptor,
        incoming: PropertyDescriptor,
    ) !bool {
        // No current descriptor: installing a new property.
        if (current_opt == null) {
            if (!self.extensible) return false;
            // Promote to slow map.
            if (self.descriptors == null)
                self.descriptors = .{};
            try self.descriptors.?.put(allocator, name, incoming);
            // Remove from fast map if present.
            _ = self.properties.swapRemove(name);
            return true;
        }

        const current = current_opt.?;

        // If incoming descriptor carries no fields that differ, it's a no-op.
        // Non-configurable invariants:
        if (!current.attrs().configurable) {
            const inc_attrs = incoming.attrs();
            // Cannot change configurable from false to true.
            if (inc_attrs.configurable) return false;
            // Cannot change enumerability on a non-configurable property.
            if (inc_attrs.enumerable != current.attrs().enumerable) return false;
        }

        // Compute the merged descriptor.
        var merged = current;
        switch (incoming) {
            .data => |inc_d| {
                switch (merged) {
                    .data => |*cur_d| {
                        // Update only the fields that the incoming descriptor explicitly sets.
                        if (!cur_d.attrs.configurable and !cur_d.attrs.writable) {
                            // SameValue check — allow write only if values are identical.
                            if (inc_d.value.bits != cur_d.value.bits) return false;
                        }
                        // Apply fields present in the incoming descriptor.
                        cur_d.value = inc_d.value;
                        if (current.attrs().configurable or current.attrs().writable) {
                            cur_d.attrs.writable = inc_d.attrs.writable;
                        }
                        cur_d.attrs.enumerable = inc_d.attrs.enumerable;
                        if (current.attrs().configurable) {
                            cur_d.attrs.configurable = inc_d.attrs.configurable;
                        }
                    },
                    .accessor => {
                        // data → accessor conversion requires configurable.
                        if (!current.attrs().configurable) return false;
                        merged = incoming;
                    },
                }
            },
            .accessor => |inc_a| {
                switch (merged) {
                    .accessor => |*cur_a| {
                        if (!current.attrs().configurable) {
                            // Check that get/set haven't changed.
                            if (inc_a.get.bits != cur_a.get.bits) return false;
                            if (inc_a.set.bits != cur_a.set.bits) return false;
                        }
                        cur_a.get = inc_a.get;
                        cur_a.set = inc_a.set;
                        cur_a.attrs.enumerable = inc_a.attrs.enumerable;
                        if (current.attrs().configurable) {
                            cur_a.attrs.configurable = inc_a.attrs.configurable;
                        }
                    },
                    .data => {
                        // data → accessor conversion requires configurable.
                        if (!current.attrs().configurable) return false;
                        merged = incoming;
                    },
                }
            },
        }

        // Write back to slow map.
        if (self.descriptors == null)
            self.descriptors = .{};
        try self.descriptors.?.put(allocator, name, merged);
        _ = self.properties.swapRemove(name);
        return true;
    }

    /// OrdinaryDefineOwnProperty (§10.1.6.1).
    /// Returns true on success.  On invariant failure returns false (non-strict
    /// callers should ignore; strict callers should throw TypeError).
    pub fn defineOwnProperty(
        self: *JsObject,
        allocator: std.mem.Allocator,
        name: StringId,
        desc: PropertyDescriptor,
    ) !bool {
        const current = self.getOwnDescriptor(name);
        return self.validateAndApply(allocator, name, current, desc);
    }

    // ── Bulk attribute mutations ─────────────────────────────────────

    /// Promote all fast-path properties to the slow (descriptors) map with
    /// the given attribute overrides applied.  Symbol properties are treated
    /// symmetrically.
    fn promoteAllToDescriptors(
        self: *JsObject,
        allocator: std.mem.Allocator,
        make_non_configurable: bool,
        make_non_writable: bool,
    ) !void {
        // String fast-path → slow-path promotion.
        if (self.properties.count() > 0) {
            if (self.descriptors == null) self.descriptors = .{};
            const keys = self.properties.keys();
            const vals = self.properties.values();
            for (keys, vals) |k, v| {
                const new_attrs = PropertyAttrs{
                    .writable = if (make_non_writable) false else true,
                    .enumerable = true,
                    .configurable = if (make_non_configurable) false else true,
                    .is_accessor = false,
                };
                try self.descriptors.?.put(allocator, k, .{ .data = .{ .value = v, .attrs = new_attrs } });
            }
            self.properties.clearRetainingCapacity();
        }
        // String slow-path: patch existing descriptor attrs.
        if (self.descriptors) |*d| {
            for (d.values()) |*pd| {
                switch (pd.*) {
                    .data => |*dat| {
                        if (make_non_configurable) dat.attrs.configurable = false;
                        if (make_non_writable) dat.attrs.writable = false;
                    },
                    .accessor => |*acc| {
                        if (make_non_configurable) acc.attrs.configurable = false;
                    },
                }
            }
        }
        // Symbol fast-path → slow-path promotion.
        if (self.symbol_props) |*sp| {
            if (sp.count() > 0) {
                if (self.symbol_descriptors == null) self.symbol_descriptors = .{};
                const keys = sp.keys();
                const vals = sp.values();
                for (keys, vals) |k, v| {
                    const new_attrs = PropertyAttrs{
                        .writable = if (make_non_writable) false else true,
                        .enumerable = true,
                        .configurable = if (make_non_configurable) false else true,
                        .is_accessor = false,
                    };
                    try self.symbol_descriptors.?.put(allocator, k, .{ .data = .{ .value = v, .attrs = new_attrs } });
                }
                sp.clearRetainingCapacity();
            }
        }
        // Symbol slow-path: patch existing descriptor attrs.
        if (self.symbol_descriptors) |*sd| {
            for (sd.values()) |*pd| {
                switch (pd.*) {
                    .data => |*dat| {
                        if (make_non_configurable) dat.attrs.configurable = false;
                        if (make_non_writable) dat.attrs.writable = false;
                    },
                    .accessor => |*acc| {
                        if (make_non_configurable) acc.attrs.configurable = false;
                    },
                }
            }
        }
    }

    /// Object.freeze — marks all own props non-configurable + non-writable
    /// (data only), then prevents extension.
    pub fn freeze(self: *JsObject, allocator: std.mem.Allocator) !void {
        try self.promoteAllToDescriptors(allocator, true, true);
        self.extensible = false;
    }

    /// Object.seal — marks all own props non-configurable, preserves writable,
    /// then prevents extension.
    pub fn seal(self: *JsObject, allocator: std.mem.Allocator) !void {
        try self.promoteAllToDescriptors(allocator, true, false);
        self.extensible = false;
    }

    /// Object.isFrozen — true when !extensible AND all own props are
    /// non-configurable AND (accessor or non-writable data).
    pub fn isFrozen(self: *const JsObject) bool {
        if (self.extensible) return false;
        // Fast-path properties are writable=true — any remaining means not frozen.
        if (self.properties.count() > 0) return false;
        if (self.descriptors) |*d| {
            for (d.values()) |pd| {
                if (pd.attrs().configurable) return false;
                switch (pd) {
                    .data => |dat| if (dat.attrs.writable) return false,
                    .accessor => {},
                }
            }
        }
        if (self.symbol_props) |*sp| {
            if (sp.count() > 0) return false;
        }
        if (self.symbol_descriptors) |*sd| {
            for (sd.values()) |pd| {
                if (pd.attrs().configurable) return false;
                switch (pd) {
                    .data => |dat| if (dat.attrs.writable) return false,
                    .accessor => {},
                }
            }
        }
        return true;
    }

    /// Object.isSealed — true when !extensible AND all own props are
    /// non-configurable.
    pub fn isSealed(self: *const JsObject) bool {
        if (self.extensible) return false;
        if (self.properties.count() > 0) return false;
        if (self.descriptors) |*d| {
            for (d.values()) |pd| {
                if (pd.attrs().configurable) return false;
            }
        }
        if (self.symbol_props) |*sp| {
            if (sp.count() > 0) return false;
        }
        if (self.symbol_descriptors) |*sd| {
            for (sd.values()) |pd| {
                if (pd.attrs().configurable) return false;
            }
        }
        return true;
    }
};

pub const IteratorData = struct {
    source: JsValue,
    index: u32 = 0,
};

pub const GeneratorState = enum(u8) {
    suspended_start,
    suspended_yield,
    executing,
    completed,
    await_pending,
};

pub const GeneratorData = struct {
    state: GeneratorState = .suspended_start,
    func_obj: *JsObject, // the function object (for bytecode + upvalues)
    saved_ip: u32 = 0,
    saved_stack: []JsValue = &.{},
    this_val: JsValue = JsValue.undefined_val,
    init_args: []JsValue = &.{}, // arguments passed to generator function
    delegate_iterator: ?JsValue = null, // active yield* inner iterator
};

pub const FunctionObj = struct {
    bytecode: Bytecode,
    param_count: u16 = 0,
    local_count: u16 = 0,
    name: ?StringId = null,
    upvalue_count: u16 = 0,
    upvalue_defs: []UpvalueDef = &.{},
    owns_bytecode: bool = true,
    is_async: bool = false,
    is_generator: bool = false,

    pub fn deinit(self: *FunctionObj, allocator: std.mem.Allocator) void {
        if (self.owns_bytecode) {
            self.bytecode.deinit(allocator);
            if (self.upvalue_defs.len > 0) allocator.free(self.upvalue_defs);
        }
    }
};

/// Describes how to capture one upvalue when creating a closure.
pub const UpvalueDef = struct {
    index: u16,
    is_local: bool, // true = capture parent's local, false = capture parent's upvalue
};

/// A heap-allocated cell for a captured variable.
/// Open: `value` is kept in sync with the stack slot.
/// Closed: `value` holds the variable after the stack frame is gone.
pub const UpvalueCell = struct {
    value: JsValue = JsValue.undefined_val,
    is_open: bool = true,
    stack_index: u32 = 0, // which stack slot this tracks (while open)
};
