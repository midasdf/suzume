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

        // DOM §4.2.9: install HTMLCollection / NodeList constructors and wrap
        // getElementsByTagName(NS)/getElementsByClassName so the returned object
        // is spec-compliant (instanceof HTMLCollection, has .item/.namedItem, and
        // applies HTML-vs-non-HTML case sensitivity per DOM §4.5).
        // kotori_dom.zig returns plain arrays; this layer adds the missing
        // interface glue without touching the native bindings.
        _ = self.eval(collection_polyfill_js);

        return self;
    }

    /// JS polyfill that installs HTMLCollection/NodeList constructors and wraps
    /// the native getElementsByTagName(NS)/getElementsByClassName methods.
    /// DOM §4.2.5 (getElementsByTagName), §4.2.6 (getElementsByTagNameNS),
    /// §4.2.9 (HTMLCollection interface).
    const collection_polyfill_js =
        \\(function(){
        \\  // HTMLCollection constructor — prototype chains through Array.prototype so
        \\  // indexed access, .length, Array.from, slice/map/forEach all work while
        \\  // `instanceof HTMLCollection` still returns true (DOM §4.2.9).
        \\  var HTMLCollection = function HTMLCollection(){};
        \\  var hcProto = {
        \\    item: function(i){var n=i>>>0;return n<this.length?this[n]:null;},
        \\    namedItem: function(name){
        \\      name=String(name);
        \\      if(name==='')return null;
        \\      // DOM §4.2.9 namedItem(): match id first, then name (HTML namespace only)
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        if(el.getAttribute('id')===name)return el;
        \\      }
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        var ns=el.namespaceURI;
        \\        if(ns==='http://www.w3.org/1999/xhtml'||ns==null){
        \\          if(el.getAttribute('name')===name)return el;
        \\        }
        \\      }
        \\      return null;
        \\    }
        \\  };
        \\  try{Object.setPrototypeOf(hcProto, Array.prototype);}catch(e){}
        \\  HTMLCollection.prototype = hcProto;
        \\  globalThis.HTMLCollection = HTMLCollection;
        \\
        \\  // NodeList — same approach. Used by querySelectorAll return value branding.
        \\  var NodeList = function NodeList(){};
        \\  var nlProto = {
        \\    item: function(i){var n=i>>>0;return n<this.length?this[n]:null;}
        \\  };
        \\  try{Object.setPrototypeOf(nlProto, Array.prototype);}catch(e){}
        \\  NodeList.prototype = nlProto;
        \\  globalThis.NodeList = NodeList;
        \\
        \\  // Brand a native array as an HTMLCollection (snapshot semantics).
        \\  // kotori arrays do not lose Array.isArray after setPrototypeOf, so
        \\  // the branded array still satisfies assert_array_equals while also
        \\  // inheriting HTMLCollection.prototype.item / .namedItem.
        \\  function brandHC(arr){
        \\    if(arr && typeof arr==='object'){
        \\      try{Object.setPrototypeOf(arr, HTMLCollection.prototype);}catch(e){}
        \\    }
        \\    return arr;
        \\  }
        \\
        \\  // Compute qualifiedName per DOM spec: prefix ? prefix+':'+localName : localName.
        \\  // Workaround: in some kotori paths `localName` may still include the
        \\  // prefix (e.g. "te:st") — strip it so prefix+':'+localName is stable.
        \\  function qualName(el){
        \\    var pfx=el.prefix;
        \\    var ln=el.localName;
        \\    if(pfx){
        \\      var p=pfx+':';
        \\      if(ln.indexOf(p)===0)ln=ln.substring(p.length);
        \\      return pfx+':'+ln;
        \\    }
        \\    return ln;
        \\  }
        \\  function localOnly(el){
        \\    var pfx=el.prefix;
        \\    var ln=el.localName;
        \\    if(pfx){
        \\      var p=pfx+':';
        \\      if(ln.indexOf(p)===0)ln=ln.substring(p.length);
        \\    }
        \\    return ln;
        \\  }
        \\  function asciiLower(s){
        \\    return String(s).replace(/[A-Z]/g,function(c){return String.fromCharCode(c.charCodeAt(0)+32);});
        \\  }
        \\
        \\  // DOM §4.2.5 getElementsByTagName algorithm.
        \\  // root: element/document to search under.
        \\  // qualifiedName: the argument passed to getElementsByTagName.
        \\  function filterByTag(all, qualifiedName){
        \\    if(qualifiedName==='*')return all;
        \\    var out=[];
        \\    var lcQN=asciiLower(qualifiedName);
        \\    for(var i=0;i<all.length;i++){
        \\      var el=all[i];
        \\      if(!el||el.nodeType!==1)continue;
        \\      var ns=el.namespaceURI;
        \\      var qn=qualName(el);
        \\      if(ns==='http://www.w3.org/1999/xhtml'){
        \\        // DOM §4.5: HTML namespace match requires the element's qualified
        \\        // name to equal asciiLower(qualifiedName). Element names that are
        \\        // NOT ascii-lowercased (e.g. uppercase createElementNS) cannot match.
        \\        if(qn===lcQN)out.push(el);
        \\      }else{
        \\        // Non-HTML namespace: exact case match on qualifiedName.
        \\        if(qn===qualifiedName)out.push(el);
        \\      }
        \\    }
        \\    return out;
        \\  }
        \\
        \\  // DOM §4.2.6 getElementsByTagNameNS algorithm.
        \\  function filterByTagNS(all, namespace, localName){
        \\    // Spec: if namespace is empty string, treat as null.
        \\    var nsFilter = (namespace==null||namespace==='') ? null : namespace;
        \\    var nsWild = nsFilter==='*';
        \\    var lnWild = localName==='*';
        \\    var out=[];
        \\    for(var i=0;i<all.length;i++){
        \\      var el=all[i];
        \\      if(!el||el.nodeType!==1)continue;
        \\      var eln=localOnly(el);
        \\      if(!lnWild && eln!==localName)continue;
        \\      var ens=el.namespaceURI;
        \\      if(nsWild){
        \\        out.push(el);
        \\      }else if(nsFilter===null){
        \\        if(ens==null)out.push(el);
        \\      }else{
        \\        if(ens===nsFilter)out.push(el);
        \\      }
        \\    }
        \\    return out;
        \\  }
        \\
        \\  // Collect all descendant elements of root in tree order.
        \\  function allDescendants(root){
        \\    var out=[];
        \\    function walk(n){
        \\      var kids=n.childNodes;
        \\      if(!kids)return;
        \\      for(var i=0;i<kids.length;i++){
        \\        var k=kids[i];
        \\        if(k&&k.nodeType===1){
        \\          out.push(k);
        \\          walk(k);
        \\        }
        \\      }
        \\    }
        \\    walk(root);
        \\    return out;
        \\  }
        \\
        \\  // DOM §4.2.9 HTMLCollection: wrap document/Element getElementsByTagName
        \\  // (NS)/getElementsByClassName to apply spec-correct case and namespace
        \\  // filtering (kotori's native variants use case-insensitive matching,
        \\  // which violates the spec for non-HTML namespaces and XML documents),
        \\  // then brand the returned array as an HTMLCollection so instanceof +
        \\  // item()/namedItem() work per §4.2.9. The returned array is a
        \\  // snapshot because kotori's native collections are not live and we
        \\  // cannot install defineProperty length getters across function returns.
        \\  document.getElementsByTagName = function(qualifiedName){
        \\    qualifiedName = String(qualifiedName);
        \\    return brandHC(filterByTag(allDescendants(document), qualifiedName));
        \\  };
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    Element.prototype.getElementsByTagName = function(qualifiedName){
        \\      qualifiedName = String(qualifiedName);
        \\      return brandHC(filterByTag(allDescendants(this), qualifiedName));
        \\    };
        \\  }
        \\
        \\  document.getElementsByTagNameNS = function(namespace, localName){
        \\    localName = String(localName);
        \\    return brandHC(filterByTagNS(allDescendants(document), namespace, localName));
        \\  };
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    Element.prototype.getElementsByTagNameNS = function(namespace, localName){
        \\      localName = String(localName);
        \\      return brandHC(filterByTagNS(allDescendants(this), namespace, localName));
        \\    };
        \\  }
        \\
        \\  var nativeDocByClass = document.getElementsByClassName;
        \\  if(typeof nativeDocByClass==='function'){
        \\    document.getElementsByClassName = function(names){
        \\      return brandHC(nativeDocByClass.call(document, String(names)));
        \\    };
        \\  }
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    var nativeElemByClass = Element.prototype.getElementsByClassName;
        \\    if(typeof nativeElemByClass==='function'){
        \\      Element.prototype.getElementsByClassName = function(names){
        \\        return brandHC(nativeElemByClass.call(this, String(names)));
        \\      };
        \\    }
        \\  }
        \\})();
    ;


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
