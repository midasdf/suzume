//! kotori_runtime.zig — Runtime wrapper for the kotori JS engine.
//!
//! Provides an eval-based API similar to QuickJS's JsRuntime,
//! enabling multiple script evaluations in the same global scope.

const std = @import("std");
const kotori = @import("kotori");
const kotori_dom = @import("kotori_dom");

pub const VM = kotori.VM;
const JsValue = kotori.JsValue;
const Compiler = kotori.Compiler;
const Bytecode = kotori.Bytecode;
const StringPool = kotori.StringPool;

pub const KotoriRuntime = struct {
    pool: *StringPool,
    vm: VM,
    allocator: std.mem.Allocator,
    document_ptr: ?*anyopaque,
    /// Track compiled bytecodes so they can be freed on deinit.
    bytecodes: std.ArrayListUnmanaged(Bytecode),

    pub const EvalResult = union(enum) {
        ok: ?[]const u8,
        err: []const u8,

        pub fn isOk(self: EvalResult) bool {
            return self == .ok;
        }
    };

    pub fn init(allocator: std.mem.Allocator, document_ptr: *anyopaque) !KotoriRuntime {
        // Allocate a long-lived StringPool shared across all compilations
        const pool = try allocator.create(StringPool);
        pool.* = StringPool.init(allocator);

        // Create a bootstrap bytecode (empty program) to initialize the VM
        var bootstrap_compiler = Compiler.initWithPool(allocator, "", pool);
        var bootstrap_bc = try bootstrap_compiler.compile();
        bootstrap_compiler.deinit();

        var vm = VM.init(allocator, &bootstrap_bc, pool);
        try vm.initBuiltins();
        try kotori_dom.initDomBuiltins(&vm, document_ptr);

        var self = KotoriRuntime{
            .pool = pool,
            .vm = vm,
            .allocator = allocator,
            .document_ptr = document_ptr,
            .bytecodes = .empty,
        };

        // Store the bootstrap bytecode (VM references it)
        try self.bytecodes.append(allocator, bootstrap_bc);

        return self;
    }

    /// Evaluate a JS source string. Returns the result or error message.
    pub fn eval(self: *KotoriRuntime, source: []const u8) EvalResult {
        if (source.len == 0) return .{ .ok = null };

        // Compile with the shared pool
        var compiler = Compiler.initWithPool(self.allocator, source, self.pool);
        const bc = compiler.compile() catch |e| {
            compiler.deinit();
            return .{ .err = @errorName(e) };
        };
        // Transfer function objects to VM before deinit (they're referenced by bytecode constants)
        for (compiler.functions.items) |obj| {
            self.vm.objects.append(self.allocator, obj) catch {};
        }
        compiler.functions.items.len = 0; // prevent deinit from freeing them
        compiler.deinit();

        // Store bytecode (VM will reference it during execution)
        self.bytecodes.append(self.allocator, bc) catch {
            return .{ .err = "OutOfMemory" };
        };
        const bc_ref = &self.bytecodes.items[self.bytecodes.items.len - 1];

        // Load and execute on existing VM (preserves globals)
        self.vm.loadCode(bc_ref);
        const result = self.vm.execute() catch |e| {
            return .{ .err = @errorName(e) };
        };

        // Convert result to string if it's a string
        if (result.isString()) {
            if (self.pool.get(result.asStringId())) |s| {
                return .{ .ok = s };
            }
        }
        return .{ .ok = null };
    }

    /// Evaluate a JS source string as an ES module.
    /// Module code runs in the same global scope but populates module_exports.
    pub fn evalModule(self: *KotoriRuntime, source: []const u8, _: []const u8) EvalResult {
        if (source.len == 0) return .{ .ok = null };

        // Compile with the shared pool
        var compiler = Compiler.initWithPool(self.allocator, source, self.pool);
        const bc = compiler.compile() catch |e| {
            compiler.deinit();
            return .{ .err = @errorName(e) };
        };
        for (compiler.functions.items) |obj| {
            self.vm.objects.append(self.allocator, obj) catch {};
        }
        compiler.functions.items.len = 0;
        compiler.deinit();

        self.bytecodes.append(self.allocator, bc) catch {
            return .{ .err = "OutOfMemory" };
        };
        const bc_ref = &self.bytecodes.items[self.bytecodes.items.len - 1];

        self.vm.loadCode(bc_ref);
        const result = self.vm.execute() catch |e| {
            return .{ .err = @errorName(e) };
        };

        if (result.isString()) {
            if (self.pool.get(result.asStringId())) |s| {
                return .{ .ok = s };
            }
        }
        return .{ .ok = null };
    }

    /// Get module exports after evalModule. Returns the exports map.
    pub fn getModuleExports(self: *KotoriRuntime) *std.AutoArrayHashMapUnmanaged(kotori.StringPool.StringId, kotori.JsValue) {
        return &self.vm.module_exports;
    }

    /// Set the module loader callback for resolving import specifiers.
    pub fn setModuleLoader(
        self: *KotoriRuntime,
        ctx: *anyopaque,
        loader_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, specifier: []const u8) ?[]const u8,
    ) void {
        self.vm.module_loader_ctx = ctx;
        self.vm.module_loader_fn = loader_fn;
    }

    /// Drain the microtask queue (Promise reactions, async/await resumptions).
    /// Must be called before processing timers (spec: microtasks have priority).
    pub fn runMicrotasks(self: *KotoriRuntime) bool {
        return self.vm.runMicrotasks() catch false;
    }

    /// Check if any microtasks are pending.
    pub fn hasPendingMicrotasks(self: *KotoriRuntime) bool {
        return self.vm.hasPendingMicrotasks();
    }

    /// Fire pending timers. Drains microtasks first (per spec).
    /// Returns true if any callbacks were executed.
    pub fn runPendingTimers(self: *KotoriRuntime) bool {
        // Microtasks always run before macrotasks
        _ = self.vm.runMicrotasks() catch {};
        const fired = self.vm.runPendingTimers() catch false;
        // Drain microtasks enqueued by timer callbacks
        _ = self.vm.runMicrotasks() catch {};
        return fired;
    }

    /// Check if any timers are pending.
    pub fn hasPendingTimers(self: *KotoriRuntime) bool {
        return self.vm.hasPendingTimers() or self.vm.hasPendingMicrotasks();
    }

    /// Set the HTTP fetch callback for fetch() API support.
    pub fn setHttpFetcher(
        self: *KotoriRuntime,
        ctx: *anyopaque,
        fetch_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, method: []const u8, body: ?[]const u8) ?VM.HttpFetchResult,
    ) void {
        self.vm.http_fetch_ctx = ctx;
        self.vm.http_fetch_fn = fetch_fn;
    }

    /// Check and clear DOM dirty flag.
    pub fn checkDomDirty() bool {
        if (kotori_dom.dom_dirty) {
            kotori_dom.dom_dirty = false;
            return true;
        }
        return false;
    }

    pub fn deinit(self: *KotoriRuntime) void {
        kotori_dom.deinit();
        self.vm.deinit();
        for (self.bytecodes.items) |*bc| {
            bc.deinit(self.allocator);
        }
        self.bytecodes.deinit(self.allocator);
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }
};
