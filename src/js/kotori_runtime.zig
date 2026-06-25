//! kotori_runtime.zig — Runtime wrapper for the kotori JS engine.
//!
//! Provides an eval-based API similar to QuickJS's JsRuntime,
//! enabling multiple script evaluations in the same global scope.

const std = @import("std");
const kotori = @import("kotori");
const kotori_dom = @import("kotori_dom");
const url_parser = @import("url_parser");

pub const VM = kotori.VM;
const JsValue = kotori.JsValue;
const JsObject = kotori.JsObject;
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

        // DOM §5: install Range + StaticRange + document.createRange for the
        // kotori engine. This mirrors dom_document.kotori_range_polyfill_js
        // (kept as source-of-truth there; sync changes between the two).
        _ = self.eval(range_polyfill_js);

        // DOM §7.1 DOMTokenList (Element.classList): install a live token list
        // wrapping the element's `class` attribute. The wrapper is returned
        // from a Proxy so that indexed access (`classList[0]`, `"0" in list`,
        // `list[1] = ...`) follows WebIDL indexed property rules while still
        // delegating `.length`, `.value`, `.add()`, etc. to the DTLP accessors.
        _ = self.eval(class_list_polyfill_js);

        // HTML §4.6.1/§4.8.4/§4.2.4 relList polyfill for <a>, <area>, <link>.
        // Mirrors classList but bound to the `rel` attribute. Depends on
        // class_list_polyfill_js (DOMTokenList constructor) running first.
        _ = self.eval(rel_list_polyfill_js);

        // DOM §6 (Traversal) + §4.5 (createElementNS prefix/case fixups) +
        // §4.7 (importNode) + §4.2.3 (NonElementParentNode.getElementById for
        // DocumentFragment) + HTML §4.12.3 (template.content). Pure-JS
        // polyfills that layer over the kotori native bindings without
        // touching kotori_dom.zig.
        _ = self.eval(traversal_and_fixups_js);

        // DOM §4.9 (attributes): validation + NS methods + Attr node accessors.
        // Wraps setAttribute/setAttributeNS/toggleAttribute for spec-compliant
        // error throwing (InvalidCharacterError, NamespaceError), adds the NS
        // sibling methods (hasAttributeNS/getAttributeNS/removeAttributeNS) and
        // Attr-node accessors (getAttributeNode(NS)/setAttributeNode(NS)/
        // removeAttributeNode). Also extends Document.importNode to clone Attr
        // nodes with their namespace/prefix/localName preserved.
        _ = self.eval(attributes_polyfill_js);

        // CSSOM §1: CSS global object with supports() + escape() per
        // https://www.w3.org/TR/cssom-1/#the-css-interface. Only a polyfill —
        // the native QJS path already provides this via dom_api.zig:5666 but
        // kotori globals don't see that registration. Without CSS unset, every
        // WPT css/* test-harness fails at `CSS.supports(...)` with
        // "Cannot read properties of undefined (reading 'supports')".
        _ = self.eval(css_global_polyfill_js);

        // CSSOM §6.4: CSSStyleSheet constructable API for kotori. The QJS
        // path installs CSSStyleSheet via dom_api.zig cssom_js block which
        // only runs in the QuickJS context; kotori globals need their own
        // polyfill. Provides new CSSStyleSheet(opts), replaceSync, replace,
        // document.adoptedStyleSheets, and shadowRoot.adoptedStyleSheets.
        _ = self.eval(cssom_polyfill_js);

        // DOM §3.1: AbortController / AbortSignal polyfill for kotori. The QJS
        // path installs these via `src/js/web_api.zig:2677-2691`; kotori has no
        // visibility into that registration, so without this polyfill every
        // WPT test referencing `new AbortController()` throws
        // "Cannot read properties of undefined (reading 'signal')". This is a
        // pure-JS polyfill that composes over the native
        // addEventListener/removeEventListener bindings in kotori_dom.zig.
        _ = self.eval(abort_controller_polyfill_js);

        // HTML §3.2.6 / §3.2.6.1: dataset (DOMStringMap) polyfill. Exposes
        // data-* attributes as a proxy object on Element.prototype.dataset.
        // Camelcase ↔ kebab-case conversion per the spec algorithm.
        _ = self.eval(dataset_polyfill_js);

        // DOM §4.11 Text.prototype.splitText + wholeText. Mirrors the
        // QuickJS-side polyfill at dom_api.zig:4927-4935. Pure-JS layer
        // over the kotori `data` getter/setter + document.createTextNode +
        // parentNode.insertBefore native bindings.
        _ = self.eval(text_polyfill_js);

        // HTML §7.3.3: Named access on the Window object. Browsers expose
        // elements with `id` attributes as properties of the window/global object
        // (e.g. `<div id="foo">` → `window.foo === document.getElementById('foo')`).
        // Scan the DOM now (called after HTML parse, before page scripts execute)
        // and register each id'd element as a read-only global. Not live — only
        // covers elements present at init time, which is sufficient for most WPT
        // tests that reference static HTML elements by id.
        _ = self.eval(named_access_polyfill_js);

        // HTML §4.10.5.1 / §4.10.7 / §4.10.10 / §4.10.21: form-control state.
        // Adds dirty value/checked/selected flag separation, select.options,
        // form.elements/length/reset(), and option.text/index/selected. The
        // kotori native bindings only expose default* (reflected attribute);
        // this polyfill layers per-instance current-state slots above them.
        // Defines on Element.prototype because per-tag prototypes are frozen
        // against defineProperty in this engine; getters branch on tag name.
        _ = self.eval(form_state_polyfill_js);

        // HTML §4.10.18 Constraint Validation API: willValidate / validity
        // (ValidityState) / validationMessage getters + checkValidity() /
        // reportValidity() / setCustomValidity() methods. Mirrors the QJS
        // polyfill at dom_api.zig:3978 which runs only in the QuickJS
        // context; without this kotori-side polyfill, `input.validity` is
        // undefined on kotori and every constraint-validation WPT test
        // fails at the first `.validity.*` access.
        _ = self.eval(validity_polyfill_js);

        // HTML §4.10.5.1.8 / §4.10.11.3: text-field selection API.
        // selectionStart/End/Direction + select()/setSelectionRange()/
        // setRangeText(). Only applicable to textarea and input types
        // text/search/url/tel/password.
        _ = self.eval(selection_polyfill_js);

        // HTML §4.10.5.1.12 / §4.10.5.1.13: valueAsNumber / valueAsDate /
        // stepUp / stepDown for number/range/date/time/datetime-local/
        // month/week inputs. Shares unit-scale parsers with the validity
        // polyfill's stepMismatch.
        _ = self.eval(input_numeric_polyfill_js);

        // HTML §6.3 activation behavior: HTMLElement.click() with form-
        // control default actions (checkbox toggle, radio group check,
        // submit/reset delegation).
        _ = self.eval(click_polyfill_js);

        // HTML §6.6.3 focus management: HTMLElement.focus() / .blur() and
        // document.activeElement getter (returns body when nothing focused).
        _ = self.eval(focus_polyfill_js);

        // WHATWG URL Standard — native basic-URL-parser bindings consumed
        // by the URL polyfill below. __suzume_url_parse(input, base?)
        // returns a parsed field object (or null on failure);
        // __suzume_url_can_parse returns a boolean.
        {
            const parse_fn = try self.vm.createObj(.{ .obj_type = .native_function });
            parse_fn.data = .{ .native_fn = &nativeUrlParse };
            try self.vm.globals.put(allocator, try pool.intern("__suzume_url_parse"), JsValue.initObject(parse_fn));
            const can_parse_fn = try self.vm.createObj(.{ .obj_type = .native_function });
            can_parse_fn.data = .{ .native_fn = &nativeUrlCanParse };
            try self.vm.globals.put(allocator, try pool.intern("__suzume_url_can_parse"), JsValue.initObject(can_parse_fn));
            const set_fn = try self.vm.createObj(.{ .obj_type = .native_function });
            set_fn.data = .{ .native_fn = &nativeUrlSet };
            try self.vm.globals.put(allocator, try pool.intern("__suzume_url_set"), JsValue.initObject(set_fn));
        }

        // WHATWG URL Standard — globalThis.URL constructor + Location
        // augmentation (pathname, protocol, host, etc. derived from href).
        // Tests like show-picker-cross-origin-iframe use
        // `new URL("...", self.location).pathname`.
        _ = self.eval(url_polyfill_js);

        // Fetch §4.1 — wrap native fetch so relative request URLs
        // resolve against document.URL (must run after url_polyfill_js).
        _ = self.eval(fetch_resolve_polyfill_js);

        // XHR §3 — XMLHttpRequest polyfill. Many modern sites (Google,
        // GitHub, …) call `new XMLHttpRequest()` directly, and kotori's
        // native bindings don't include it (the QuickJS path has its own
        // JS-level implementation in web_api.zig). This pure-JS polyfill
        // layers on top of fetch() — same approach the QuickJS path uses —
        // so async XHR works. Without it, `b.i.req.addEventListener(...)`
        // throws "Cannot read properties of undefined (reading
        // 'addEventListener')" because `b.i.req` is the undefined result of
        // `new XMLHttpRequest()`.
        _ = self.eval(xhr_polyfill_js);

        // Navigator / Performance / Screen polyfills. kotori has no native
        // bindings for these; without navigator.userAgent Wikipedia's JS
        // throws "Cannot read properties of undefined (reading 'match')",
        // and without performance.timing Bing throws
        // "Cannot read properties of undefined (reading 'navigationStart')".
        _ = self.eval(navigator_performance_polyfill_js);

        // HTML §4.6.2 — <a>/<area> URL decomposition accessors backed by
        // the native URL parser (must run after url_polyfill_js).
        _ = self.eval(hyperlink_utils_polyfill_js);

        // DOM §2.7 — Event.prototype.returnValue accessor that derives
        // from defaultPrevented. The setter calls preventDefault when
        // assigned `false`; the getter returns !defaultPrevented.
        _ = self.eval(event_returnvalue_polyfill_js);

        // HTML §4.10.5.1.16 radio insert-time exclusivity. Hooks
        // appendChild/insertBefore so a checked radio inserted into a
        // form-rooted tree triggers group exclusivity (uncheck other
        // radios in the same form/name group).
        _ = self.eval(radio_insert_polyfill_js);

        // HTML §4.10.5.1.18 input.files + FileList stub.
        _ = self.eval(file_input_polyfill_js);

        // HTML §3.2.2 cloneNode form-control state propagation.
        // Patches Element.prototype.cloneNode to copy `_value` /
        // `_dirtyValue` / `_checked` / `_dirtyChecked` per spec for
        // input + textarea descendants of the cloned subtree.
        _ = self.eval(clone_form_state_polyfill_js);

        // HTML §3.1.5 / §3.1.6: Document HTMLCollection getters
        // (document.forms/links/images/scripts/embeds/plugins). The QuickJS
        // path installs these in dom_api.zig:5224 but kotori globals need
        // their own polyfill. Each returns a live Proxy-wrapped HTMLCollection
        // with indexed access, .length, .item(), .namedItem(), and named
        // property access (by id then by name — HTMLCollection §4.2.9).
        _ = self.eval(document_collections_polyfill_js);

        // HTML §4.10.18.3: form owner accessor for form-associated elements.
        // input/select/textarea/button/fieldset/output/object.form returns
        // the owning <form>: either the element referenced by a form="id"
        // attribute (if valid) or the nearest <form> ancestor. Without this
        // getter every form-control-infrastructure test fails since
        // `input.form` is undefined.
        _ = self.eval(form_owner_polyfill_js);

        // XHR §3 / HTML §4.10.22.4 — globalThis.FormData constructor +
        // entry-list construction from form. Excludes submit-button entries
        // unless the submitter is explicitly passed (constructor 2nd arg).
        _ = self.eval(formdata_polyfill_js);

        // HTML §8.1.5.4 Window-reflecting body element event handler set:
        // onblur/onerror/onfocus/onload/onscroll/onresize on
        // HTMLBodyElement.prototype + HTMLFrameSetElement.prototype forward
        // their IDL getter/setter to window[attr]. Non-callable non-null
        // setter values coerce to null per HTML §8.1.5.2 event handler IDL
        // attribute setter algorithm.
        _ = self.eval(body_event_handler_polyfill_js);

        // Encoding §9 — TextEncoder / TextDecoder UTF-8 polyfill.
        // Required by encoding .any.* WPT tests.
        _ = self.eval(text_encoder_polyfill_js);

        // FileAPI §6-§8 — Blob, File, FileReader polyfill.
        // Unlocks FileAPI .any.* WPT tests.
        _ = self.eval(blob_file_polyfill_js);

        // WHATWG URL §6: globalThis.URLSearchParams constructor.
        // Run before url_polyfill_js so URL's searchParams getter can use
        // new URLSearchParams().
        _ = self.eval(url_search_params_polyfill_js);

        // DOM Parsing and Serialization §2.1: DOMParser polyfill.
        // The native DOMParser constructor + parseFromString are registered in
        // kotori_dom.zig initDomBuiltins() (new DOMParser().parseFromString(str, type)
        // → Document). This pure-JS IIFE runs a guard check first and only
        // installs the global when the native path is absent — it is a fallback
        // for environments without the kotori_dom native bindings.
        _ = self.eval(domparser_polyfill_js);

        // DOM §4.3: MutationObserver polyfill.
        // The native MutationObserver constructor + observe/disconnect/takeRecords
        // are registered in kotori_dom.zig initDomBuiltins() with full lexbor
        // DOM-hook integration (nativeMoObserve/nativeMoDisconnect/nativeMoTakeRecords).
        // This pure-JS IIFE provides a polling-based + monkey-patch fallback
        // for environments where the native path is unavailable.
        _ = self.eval(mutation_observer_polyfill_js);

        // DOM §2.5: CustomEvent thin-wrapper polyfill.
        // The native CustomEvent constructor + initCustomEvent are registered in
        // kotori_dom.zig initDomBuiltins() (line 1447–1457) with full spec
        // compliance: new CustomEvent(type) creates an Event; new CustomEvent(type,
        // {detail}) reads `detail` from the dictionary; new CustomEvent(type,
        // {bubbles,cancelable}) passes through to nativeEventConstructor.
        // This JS polyfill is a safety-net IIFE that verifies exposure and patches
        // any missing detail accessor on the prototype.
        _ = self.eval(customevent_polyfill_js);

        // Console API polyfill — adds missing methods (count, countReset,
        // time, timeLog, timeEnd, group, groupCollapsed, groupEnd, table,
        // assert, debug, info, trace, dir, clear) to globalThis.console.
        // Uses `if (!c.METHOD) c.METHOD = ...` pattern to avoid overwriting
        // native kotori VM console methods (log/warn/error/etc.).
        _ = self.eval(console_polyfill_js);

        // Streams API — TextDecoderStream + TextEncoderStream polyfill.
        // Installs globals needed by encoding/streams/*.any.html WPT tests.
        // Depends on TextDecoder/TextEncoder from text_encoder_polyfill_js.
        _ = self.eval(streams_polyfill_js);

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
        \\      // HTML §3.1.5 — id match in any namespace, name match in HTML
        \\      // namespace ONLY. Null-namespace elements with a name attr do
        \\      // not get exposed via the named-item path (only their id does).
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        if(el.getAttribute('id')===name)return el;
        \\      }
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        if(el.namespaceURI!=='http://www.w3.org/1999/xhtml')continue;
        \\        if(el.getAttribute('name')===name)return el;
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
        \\      // DOM §4.2.10 — flag the array so set_elem skips indexed writes
        \\      // (HTMLCollection is a legacy-platform-object with no indexed setter).
        \\      try{if(typeof __suzume_markHTMLCollection==='function')__suzume_markHTMLCollection(arr);}catch(e){}
        \\    }
        \\    return arr;
        \\  }
        \\
        \\  // DOM §4.2.9 — fully-live HTMLCollection backed by a Proxy. The
        \\  // `rebuildFn` closure re-walks the DOM on every observable access
        \\  // (length, indexed items, named item dispatch, ownKeys, has,
        \\  // descriptors). Requires kotori Proxy `ownKeys` /
        \\  // `getOwnPropertyDescriptor` traps to route through
        \\  // Object.getOwnPropertyNames + hasOwnProperty (Wave 147 wired
        \\  // these into the native paths).
        \\  function isIdxStr(p){
        \\    if(typeof p!=='string')return false;
        \\    var n=p>>>0;
        \\    return String(n)===p && n<4294967295;
        \\  }
        \\  // HTML §3.1.5 HTMLCollection.namedItem: match id (any namespace)
        \\  // first, then name (HTML-namespace elements ONLY — spec restricts
        \\  // the name attribute path to elements in
        \\  // "http://www.w3.org/1999/xhtml"). Null-namespace elements with a
        \\  // name attribute do NOT get exposed via the named-item path; only
        \\  // their id (matched by the first loop) does.
        \\  function niLookup(items,name){
        \\    if(typeof name!=='string'||name==='')return null;
        \\    for(var i=0;i<items.length;i++){
        \\      var el=items[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      if(el.getAttribute('id')===name)return el;
        \\    }
        \\    for(var i=0;i<items.length;i++){
        \\      var el=items[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      if(el.namespaceURI!=='http://www.w3.org/1999/xhtml')continue;
        \\      if(el.getAttribute('name')===name)return el;
        \\    }
        \\    return null;
        \\  }
        \\  function brandHCLiveLen(rebuildFn){
        \\    var expandos=Object.create(null);
        \\    var target=[];
        \\    // Rebuilds are cached per DOM mutation epoch (__suzume_domVer,
        \\    // bumped by every native setDomDirty). Iterating an N-element
        \\    // collection used to cost N+1 full tree walks through the Proxy
        \\    // get trap; with the stamp it costs one walk per DOM mutation.
        \\    var cache=null,cacheVer=-1;
        \\    var hasVer=typeof __suzume_domVer==='function';
        \\    function q(){
        \\      if(hasVer){
        \\        var v=__suzume_domVer();
        \\        if(cache&&cacheVer===v)return cache;
        \\        cache=rebuildFn();cacheVer=v;
        \\        return cache;
        \\      }
        \\      return rebuildFn();
        \\    }
        \\    try{Object.setPrototypeOf(target, HTMLCollection.prototype);}catch(e){}
        \\    try{if(typeof __suzume_markHTMLCollection==='function')__suzume_markHTMLCollection(target);}catch(e){}
        \\    return new Proxy(target, {
        \\      get:function(t,p,recv){
        \\        if(p==='length')return q().length;
        \\        if(typeof p==='string' && isIdxStr(p)){
        \\          var items=q();
        \\          var idx=p>>>0;
        \\          return idx<items.length?items[idx]:undefined;
        \\        }
        \\        if(typeof p==='string' && Object.prototype.hasOwnProperty.call(expandos,p)) return expandos[p];
        \\        if(typeof p==='string' &&
        \\           p!=='item' && p!=='namedItem' && p!=='length' &&
        \\           p!=='constructor' && p!=='toString' && p!=='toLocaleString' &&
        \\           p!=='valueOf' && p!=='hasOwnProperty' && p!=='isPrototypeOf' &&
        \\           p!=='propertyIsEnumerable'){
        \\          var f=niLookup(q(),p);
        \\          if(f)return f;
        \\        }
        \\        return Reflect.get(t,p,recv);
        \\      },
        \\      set:function(t,p,v,recv){
        \\        if(typeof p==='string' && isIdxStr(p))return true;
        \\        if(typeof p==='string'){
        \\          var f=niLookup(q(),p);
        \\          if(f)return true;
        \\        }
        \\        expandos[p]=v;
        \\        return true;
        \\      },
        \\      has:function(t,p){
        \\        if(p==='length' || p==='item' || p==='namedItem')return true;
        \\        if(typeof p==='string'){
        \\          if(isIdxStr(p))return (p>>>0)<q().length;
        \\          if(Object.prototype.hasOwnProperty.call(expandos,p))return true;
        \\          if(niLookup(q(),p))return true;
        \\        }
        \\        return Reflect.has(t,p);
        \\      },
        \\      ownKeys:function(t){
        \\        var items=q();
        \\        var keys=[];
        \\        var seen=Object.create(null);
        \\        for(var i=0;i<items.length;i++){
        \\          var k=String(i);
        \\          keys.push(k);
        \\          seen[k]=1;
        \\        }
        \\        var ek=Object.getOwnPropertyNames(expandos);
        \\        for(var j=0;j<ek.length;j++){
        \\          if(!seen[ek[j]]){keys.push(ek[j]);seen[ek[j]]=1;}
        \\        }
        \\        for(var i=0;i<items.length;i++){
        \\          var el=items[i];
        \\          if(!el||!el.getAttribute)continue;
        \\          var id=el.getAttribute('id');
        \\          if(id && !seen[id]){keys.push(id);seen[id]=1;}
        \\          if(el.namespaceURI==='http://www.w3.org/1999/xhtml'){
        \\            var nm=el.getAttribute('name');
        \\            if(nm && !seen[nm]){keys.push(nm);seen[nm]=1;}
        \\          }
        \\        }
        \\        return keys;
        \\      },
        \\      getOwnPropertyDescriptor:function(t,p){
        \\        if(typeof p==='string'){
        \\          if(isIdxStr(p)){
        \\            var items=q();
        \\            var idx=p>>>0;
        \\            if(idx<items.length){
        \\              return {value:items[idx],writable:false,enumerable:true,configurable:true};
        \\            }
        \\            return undefined;
        \\          }
        \\          if(Object.prototype.hasOwnProperty.call(expandos,p))return Object.getOwnPropertyDescriptor(expandos,p);
        \\          var f=niLookup(q(),p);
        \\          if(f)return {value:f,writable:false,enumerable:false,configurable:true};
        \\        }
        \\        return undefined;
        \\      }
        \\    });
        \\  }
        \\
        \\  // HTML §4.10.21.2 HTMLFormControlsCollection — extends HTMLCollection.
        \\  // Used by form.elements. namedItem returns RadioNodeList for multi-match.
        \\  var HTMLFormControlsCollection = function HTMLFormControlsCollection(){};
        \\  var hfccProto = {
        \\    namedItem: function(name){
        \\      name=String(name);
        \\      if(name==='')return null;
        \\      var matches=[];
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        var ns=el.namespaceURI;
        \\        if(ns!=null&&ns!=='http://www.w3.org/1999/xhtml')continue;
        \\        if(el.getAttribute('id')===name||el.getAttribute('name')===name){
        \\          matches.push(el);
        \\        }
        \\      }
        \\      if(matches.length===0)return null;
        \\      if(matches.length===1)return matches[0];
        \\      return brandRadioNL(matches);
        \\    }
        \\  };
        \\  try{Object.setPrototypeOf(hfccProto, HTMLCollection.prototype);}catch(e){}
        \\  HTMLFormControlsCollection.prototype = hfccProto;
        \\  globalThis.HTMLFormControlsCollection = HTMLFormControlsCollection;
        \\
        \\  // HTML §4.10.21.3 RadioNodeList — extends NodeList. .value getter/setter
        \\  // for radio button groups (HTML §4.10.21.3). Currently a stub for
        \\  // instanceof support; .value impl can come later.
        \\  var RadioNodeList = function RadioNodeList(){};
        \\  var rnlProto = {};
        \\  Object.defineProperty(rnlProto, 'value', {
        \\    get: function(){
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        if((el.tagName||'').toLowerCase()!=='input')continue;
        \\        if(((el.getAttribute('type')||'radio').toLowerCase())!=='radio')continue;
        \\        if(el.checked)return el.value!=null?el.value:'on';
        \\      }
        \\      return '';
        \\    },
        \\    set: function(v){
        \\      v=String(v);
        \\      for(var i=0;i<this.length;i++){
        \\        var el=this[i];
        \\        if(!el||!el.getAttribute)continue;
        \\        if((el.tagName||'').toLowerCase()!=='input')continue;
        \\        if(((el.getAttribute('type')||'radio').toLowerCase())!=='radio')continue;
        \\        var ev=el.value!=null?el.value:'on';
        \\        if(ev===v){el.checked=true;return;}
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  try{Object.setPrototypeOf(rnlProto, NodeList.prototype);}catch(e){}
        \\  RadioNodeList.prototype = rnlProto;
        \\  globalThis.RadioNodeList = RadioNodeList;
        \\
        \\  function brandHFCC(arr){
        \\    if(arr && typeof arr==='object'){
        \\      try{Object.setPrototypeOf(arr, HTMLFormControlsCollection.prototype);}catch(e){}
        \\    }
        \\    return arr;
        \\  }
        \\  function brandRadioNL(arr){
        \\    if(arr && typeof arr==='object'){
        \\      try{Object.setPrototypeOf(arr, RadioNodeList.prototype);}catch(e){}
        \\    }
        \\    return arr;
        \\  }
        \\  globalThis.__suzume_brandHFCC = brandHFCC;
        \\  globalThis.__suzume_brandRadioNL = brandRadioNL;
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
        \\  // Native getElementsByTagName, captured BEFORE the spec-correct
        \\  // overrides below replace it. The '*' wildcard query has no
        \\  // case/namespace pitfalls, so it is safe as the tree-walk
        \\  // primitive for allDescendants (the JS childNodes walk costs an
        \\  // array materialisation per node; the native walks lexbor
        \\  // C structs directly).
        \\  var nativeDocByTag = document.getElementsByTagName;
        \\  var nativeElemByTag = (typeof Element!=='undefined'&&Element.prototype)?Element.prototype.getElementsByTagName:null;
        \\
        \\  // Collect all descendant elements of root in tree order.
        \\  function allDescendants(root){
        \\    try{
        \\      if(root===document){
        \\        if(typeof nativeDocByTag==='function')return nativeDocByTag.call(document,'*');
        \\      }else if(nativeElemByTag&&root&&root.nodeType===1){
        \\        return nativeElemByTag.call(root,'*');
        \\      }
        \\    }catch(e){}
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
        \\    return brandHCLiveLen(function(){
        \\      return filterByTag(allDescendants(document), qualifiedName);
        \\    });
        \\  };
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    Element.prototype.getElementsByTagName = function(qualifiedName){
        \\      qualifiedName = String(qualifiedName);
        \\      var self=this;
        \\      return brandHCLiveLen(function(){
        \\        return filterByTag(allDescendants(self), qualifiedName);
        \\      });
        \\    };
        \\  }
        \\
        \\  document.getElementsByTagNameNS = function(namespace, localName){
        \\    localName = String(localName);
        \\    return brandHCLiveLen(function(){
        \\      return filterByTagNS(allDescendants(document), namespace, localName);
        \\    });
        \\  };
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    Element.prototype.getElementsByTagNameNS = function(namespace, localName){
        \\      localName = String(localName);
        \\      var self=this;
        \\      return brandHCLiveLen(function(){
        \\        return filterByTagNS(allDescendants(self), namespace, localName);
        \\      });
        \\    };
        \\  }
        \\
        \\  var nativeDocByClass = document.getElementsByClassName;
        \\  if(typeof nativeDocByClass==='function'){
        \\    document.getElementsByClassName = function(names){
        \\      var n=String(names);
        \\      return brandHCLiveLen(function(){
        \\        return nativeDocByClass.call(document, n);
        \\      });
        \\    };
        \\  }
        \\  if(typeof Element!=='undefined' && Element.prototype){
        \\    var nativeElemByClass = Element.prototype.getElementsByClassName;
        \\    if(typeof nativeElemByClass==='function'){
        \\      Element.prototype.getElementsByClassName = function(names){
        \\        var self=this;
        \\        var n=String(names);
        \\        return brandHCLiveLen(function(){
        \\          return nativeElemByClass.call(self, n);
        \\        });
        \\      };
        \\    }
        \\  }
        \\})();
    ;

    /// DOM §5 Range + StaticRange polyfill for kotori. Source-of-truth
    /// reference: src/js/dom_document.zig `kotori_range_polyfill_js`.
    /// Duplicated here because kotori_runtime is a separate build
    /// module that cannot depend on the quickjs-linked dom_document.
    const range_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.Range === 'function' && Range.prototype && Range.prototype.setStart) return;
        \\  /* --- Helpers (DOM §4.2) ------------------------------------ */
        \\  function nLen(n){
        \\    var t=n.nodeType;
        \\    if(t===10)return 0;                          /* DocumentType */
        \\    if(t===3||t===4||t===7||t===8){              /* CDATA, Text, PI, Comment */
        \\      var s=(n.data!=null?n.data:n.textContent);
        \\      return s==null?0:s.length;
        \\    }
        \\    return n.childNodes?n.childNodes.length:0;
        \\  }
        \\  function root(n){while(n&&n.parentNode)n=n.parentNode;return n;}
        \\  function idx(n){
        \\    var p=n.parentNode;if(!p)return 0;
        \\    var cn=p.childNodes;
        \\    for(var i=0;i<cn.length;i++)if(cn[i]===n)return i;
        \\    return 0;
        \\  }
        \\  function isAncestorOf(a,b){
        \\    /* b has ancestor a? */
        \\    var n=b;while(n){if(n===a)return true;n=n.parentNode;}return false;
        \\  }
        \\  /* DOM §5.1 boundary point comparison — returns -1/0/1 */
        \\  function bpCmp(nA,oA,nB,oB){
        \\    if(nA===nB)return oA<oB?-1:oA>oB?1:0;
        \\    if(isAncestorOf(nA,nB)){
        \\      /* nA is ancestor of nB: find child of nA that contains nB */
        \\      var ch=nB;while(ch.parentNode!==nA)ch=ch.parentNode;
        \\      var ci=idx(ch);
        \\      return oA<=ci?-1:1;
        \\    }
        \\    if(isAncestorOf(nB,nA)){
        \\      var ch=nA;while(ch.parentNode!==nB)ch=ch.parentNode;
        \\      var ci=idx(ch);
        \\      return ci<oB?-1:1;
        \\    }
        \\    /* Disconnected — fall back to compareDocumentPosition for ordering. */
        \\    if(typeof nA.compareDocumentPosition==='function'){
        \\      var p=nA.compareDocumentPosition(nB);
        \\      if(p&4)return -1;         /* FOLLOWING */
        \\      if(p&2)return 1;          /* PRECEDING */
        \\    }
        \\    return 0;
        \\  }
        \\  function DOMEx(name){return new DOMException('',name);}
        \\  function ensureNode(n){if(!n||typeof n.nodeType!=='number')throw new TypeError('Argument is not a Node');}
        \\
        \\  /* --- Live range registry (DOM §5.5) ------------------------ */
        \\  var LIVE_RANGES=[]; /* WeakRef not available; keep strong refs. */
        \\  function trackRange(r){LIVE_RANGES.push(r);if(LIVE_RANGES.length>512){LIVE_RANGES.splice(0,LIVE_RANGES.length-512);}}
        \\  function forEachRange(fn){for(var i=0;i<LIVE_RANGES.length;i++)fn(LIVE_RANGES[i]);}
        \\
        \\  /* --- Range interface (DOM §5.2) ----------------------------- */
        \\  function Range(){
        \\    if(!(this instanceof Range))return new Range();
        \\    this._sc=document;this._so=0;this._ec=document;this._eo=0;
        \\    trackRange(this);
        \\  }
        \\  Range.START_TO_START=0;Range.START_TO_END=1;Range.END_TO_END=2;Range.END_TO_START=3;
        \\  var RP=Range.prototype;
        \\  RP.constructor=Range;
        \\  RP.START_TO_START=0;RP.START_TO_END=1;RP.END_TO_END=2;RP.END_TO_START=3;
        \\
        \\  function defGet(p,k,g){Object.defineProperty(p,k,{get:g,configurable:true,enumerable:true});}
        \\  defGet(RP,'startContainer',function(){return this._sc;});
        \\  defGet(RP,'startOffset',function(){return this._so;});
        \\  defGet(RP,'endContainer',function(){return this._ec;});
        \\  defGet(RP,'endOffset',function(){return this._eo;});
        \\  defGet(RP,'collapsed',function(){return this._sc===this._ec&&this._so===this._eo;});
        \\  defGet(RP,'commonAncestorContainer',function(){
        \\    var a=this._sc,b=this._ec;
        \\    if(a===b)return a;
        \\    /* Collect ancestors of a (inclusive), walk b until hit. */
        \\    var anc=[],n=a;while(n){anc.push(n);n=n.parentNode;}
        \\    n=b;while(n){for(var i=0;i<anc.length;i++)if(anc[i]===n)return n;n=n.parentNode;}
        \\    return document;
        \\  });
        \\
        \\  RP.setStart=function(node,offset){
        \\    ensureNode(node);
        \\    if(node.nodeType===10)throw DOMEx('InvalidNodeTypeError');
        \\    offset=Number(offset);if(!isFinite(offset))offset=0;else{offset=Math.floor(offset);if(offset<0)offset=offset+4294967296;}
        \\    if(offset>nLen(node))throw DOMEx('IndexSizeError');
        \\    this._sc=node;this._so=offset;
        \\    if(root(node)!==root(this._ec)||bpCmp(node,offset,this._ec,this._eo)>0){
        \\      this._ec=node;this._eo=offset;
        \\    }
        \\  };
        \\  RP.setEnd=function(node,offset){
        \\    ensureNode(node);
        \\    if(node.nodeType===10)throw DOMEx('InvalidNodeTypeError');
        \\    offset=Number(offset);if(!isFinite(offset))offset=0;else{offset=Math.floor(offset);if(offset<0)offset=offset+4294967296;}
        \\    if(offset>nLen(node))throw DOMEx('IndexSizeError');
        \\    this._ec=node;this._eo=offset;
        \\    if(root(node)!==root(this._sc)||bpCmp(this._sc,this._so,node,offset)>0){
        \\      this._sc=node;this._so=offset;
        \\    }
        \\  };
        \\  RP.setStartBefore=function(node){ensureNode(node);var p=node.parentNode;if(!p)throw DOMEx('InvalidNodeTypeError');this.setStart(p,idx(node));};
        \\  RP.setStartAfter =function(node){ensureNode(node);var p=node.parentNode;if(!p)throw DOMEx('InvalidNodeTypeError');this.setStart(p,idx(node)+1);};
        \\  RP.setEndBefore  =function(node){ensureNode(node);var p=node.parentNode;if(!p)throw DOMEx('InvalidNodeTypeError');this.setEnd(p,idx(node));};
        \\  RP.setEndAfter   =function(node){ensureNode(node);var p=node.parentNode;if(!p)throw DOMEx('InvalidNodeTypeError');this.setEnd(p,idx(node)+1);};
        \\  RP.collapse=function(toStart){
        \\    if(toStart){this._ec=this._sc;this._eo=this._so;}
        \\    else{this._sc=this._ec;this._so=this._eo;}
        \\  };
        \\  RP.selectNode=function(node){
        \\    ensureNode(node);var p=node.parentNode;if(!p)throw DOMEx('InvalidNodeTypeError');
        \\    var i=idx(node);this._sc=p;this._so=i;this._ec=p;this._eo=i+1;
        \\  };
        \\  RP.selectNodeContents=function(node){
        \\    ensureNode(node);if(node.nodeType===10)throw DOMEx('InvalidNodeTypeError');
        \\    this._sc=node;this._so=0;this._ec=node;this._eo=nLen(node);
        \\  };
        \\  RP.compareBoundaryPoints=function(how,sr){
        \\    if(!sr||!(sr instanceof Range))throw new TypeError('Argument is not a Range');
        \\    if(root(this._sc)!==root(sr._sc))throw DOMEx('WrongDocumentError');
        \\    var tn,to,sn,so;
        \\    switch(how){
        \\      case 0:tn=this._sc;to=this._so;sn=sr._sc;so=sr._so;break;
        \\      case 1:tn=this._ec;to=this._eo;sn=sr._sc;so=sr._so;break; /* END_TO_START */
        \\      case 2:tn=this._ec;to=this._eo;sn=sr._ec;so=sr._eo;break; /* END_TO_END */
        \\      case 3:tn=this._sc;to=this._so;sn=sr._ec;so=sr._eo;break; /* START_TO_END */
        \\      default:throw DOMEx('NotSupportedError');
        \\    }
        \\    return bpCmp(tn,to,sn,so);
        \\  };
        \\  RP.isPointInRange=function(node,offset){
        \\    ensureNode(node);
        \\    if(root(node)!==root(this._sc))return false;
        \\    if(node.nodeType===10)throw DOMEx('InvalidNodeTypeError');
        \\    offset=Number(offset);if(!isFinite(offset))offset=0;else{offset=Math.floor(offset);if(offset<0)offset=offset+4294967296;}if(offset>nLen(node))throw DOMEx('IndexSizeError');
        \\    if(bpCmp(node,offset,this._sc,this._so)<0)return false;
        \\    if(bpCmp(node,offset,this._ec,this._eo)>0)return false;
        \\    return true;
        \\  };
        \\  RP.comparePoint=function(node,offset){
        \\    ensureNode(node);
        \\    if(root(node)!==root(this._sc))throw DOMEx('WrongDocumentError');
        \\    if(node.nodeType===10)throw DOMEx('InvalidNodeTypeError');
        \\    offset=Number(offset);if(!isFinite(offset))offset=0;else{offset=Math.floor(offset);if(offset<0)offset=offset+4294967296;}if(offset>nLen(node))throw DOMEx('IndexSizeError');
        \\    if(bpCmp(node,offset,this._sc,this._so)<0)return -1;
        \\    if(bpCmp(node,offset,this._ec,this._eo)>0)return 1;
        \\    return 0;
        \\  };
        \\  RP.intersectsNode=function(node){
        \\    ensureNode(node);
        \\    if(root(node)!==root(this._sc))return false;
        \\    var parent=node.parentNode;if(!parent)return true; /* contained in same tree */
        \\    var off=idx(node);
        \\    return bpCmp(parent,off,this._ec,this._eo)<0 && bpCmp(parent,off+1,this._sc,this._so)>0;
        \\  };
        \\  RP.cloneRange=function(){
        \\    var r=new Range();r._sc=this._sc;r._so=this._so;r._ec=this._ec;r._eo=this._eo;
        \\    return r;
        \\  };
        \\  RP.detach=function(){/* §5.2: no-op */};
        \\
        \\  /* Inclusive-ancestor walker for range-contained node collection. */
        \\  function nextNode(n,stopAt){
        \\    if(n.firstChild)return n.firstChild;
        \\    while(n&&n!==stopAt){if(n.nextSibling)return n.nextSibling;n=n.parentNode;}
        \\    return null;
        \\  }
        \\  /* §5.2 "contained" = both endpoints of node in range. */
        \\  function rangeContains(range,node){
        \\    if(root(node)!==root(range._sc))return false;
        \\    var p=node.parentNode;
        \\    if(!p)return false;
        \\    var off=idx(node);
        \\    return bpCmp(range._sc,range._so,p,off)<=0 && bpCmp(p,off+1,range._ec,range._eo)<=0;
        \\  }
        \\  function rangePartiallyContains(range,node){
        \\    /* node is ancestor of exactly one endpoint */
        \\    var a=isAncestorOf(node,range._sc) && !isAncestorOf(node,range._ec);
        \\    var b=isAncestorOf(node,range._ec) && !isAncestorOf(node,range._sc);
        \\    /* Inclusive ancestor of itself for endpoint containers. */
        \\    var c=node===range._sc && node!==range._ec;
        \\    var d=node===range._ec && node!==range._sc;
        \\    return a||b||c||d;
        \\  }
        \\
        \\  /* DOM §5.2 extract (used by extractContents + deleteContents). */
        \\  function extractOrDelete(range,mode){
        \\    /* mode: 'clone' | 'extract' | 'delete' */
        \\    var frag=(mode==='delete')?null:document.createDocumentFragment();
        \\    if(range._sc===range._ec&&range._so===range._eo)return frag;
        \\    var sc=range._sc,so=range._so,ec=range._ec,eo=range._eo;
        \\    /* Same-node CharacterData: fast path */
        \\    if(sc===ec&&(sc.nodeType===3||sc.nodeType===4||sc.nodeType===8)){
        \\      if(frag){
        \\        var tn=(sc.nodeType===3)?document.createTextNode(sc.data.substring(so,eo))
        \\              :(sc.nodeType===4)?(document.createCDATASection?document.createCDATASection(sc.data.substring(so,eo)):document.createTextNode(sc.data.substring(so,eo)))
        \\              :document.createComment(sc.data.substring(so,eo));
        \\        frag.appendChild(tn);
        \\      }
        \\      if(mode!=='clone'){
        \\        if(typeof sc.deleteData==='function')sc.deleteData(so,eo-so);
        \\        else sc.data=sc.data.substring(0,so)+sc.data.substring(eo);
        \\        if(mode==='delete'){range._ec=sc;range._eo=so;}
        \\      }
        \\      return frag;
        \\    }
        \\    /* Find common ancestor + first partially contained child on each side. */
        \\    var caC=range.commonAncestorContainer;
        \\    var firstPC=null;
        \\    if(!isAncestorOf(sc,ec)){
        \\      var n=sc;while(n&&n.parentNode!==caC)n=n.parentNode;firstPC=n;
        \\    }
        \\    var lastPC=null;
        \\    if(!isAncestorOf(ec,sc)){
        \\      var m=ec;while(m&&m.parentNode!==caC)m=m.parentNode;lastPC=m;
        \\    }
        \\    /* Contained children of commonAncestor, in tree order. */
        \\    var contained=[];
        \\    if(caC.childNodes){
        \\      for(var i=0;i<caC.childNodes.length;i++){
        \\        var c=caC.childNodes[i];
        \\        if(rangeContains(range,c))contained.push(c);
        \\      }
        \\    }
        \\    /* Handle start boundary */
        \\    if(sc===ec){/* covered above */}
        \\    var newSc=sc,newSo=so;
        \\    if(sc.nodeType===3||sc.nodeType===4||sc.nodeType===8){
        \\      /* Partial text: clone the suffix */
        \\      if(frag){
        \\        var txt=(sc.nodeType===3)?document.createTextNode(sc.data.substring(so))
        \\              :(sc.nodeType===4&&document.createCDATASection)?document.createCDATASection(sc.data.substring(so))
        \\              :(sc.nodeType===8)?document.createComment(sc.data.substring(so))
        \\              :document.createTextNode(sc.data.substring(so));
        \\        frag.appendChild(txt);
        \\      }
        \\      if(mode!=='clone'){
        \\        if(typeof sc.deleteData==='function')sc.deleteData(so,(sc.data||'').length-so);
        \\        else sc.data=sc.data.substring(0,so);
        \\      }
        \\    }else if(firstPC){
        \\      /* Clone firstPC, then recursively extract the subrange (so..firstPC's length) */
        \\      var clone=frag?firstPC.cloneNode(false):null;
        \\      if(clone){frag.appendChild(clone);}
        \\      /* Move/clone remaining contained descendants inside firstPC. */
        \\      var sub={_sc:sc,_so:so,_ec:firstPC,_eo:nLen(firstPC)};
        \\      Object.setPrototypeOf(sub,Range.prototype);
        \\      var subFrag=extractOrDelete(sub,mode);
        \\      if(clone&&subFrag){while(subFrag.firstChild)clone.appendChild(subFrag.firstChild);}
        \\    }
        \\    /* Handle contained siblings */
        \\    for(var j=0;j<contained.length;j++){
        \\      var node=contained[j];
        \\      if(mode==='clone'){frag.appendChild(node.cloneNode(true));}
        \\      else if(mode==='extract'){frag.appendChild(node);}
        \\      else{if(node.parentNode)node.parentNode.removeChild(node);}
        \\    }
        \\    /* Handle end boundary */
        \\    if(ec.nodeType===3||ec.nodeType===4||ec.nodeType===8){
        \\      if(frag){
        \\        var txe=(ec.nodeType===3)?document.createTextNode(ec.data.substring(0,eo))
        \\              :(ec.nodeType===4&&document.createCDATASection)?document.createCDATASection(ec.data.substring(0,eo))
        \\              :(ec.nodeType===8)?document.createComment(ec.data.substring(0,eo))
        \\              :document.createTextNode(ec.data.substring(0,eo));
        \\        frag.appendChild(txe);
        \\      }
        \\      if(mode!=='clone'){
        \\        if(typeof ec.deleteData==='function')ec.deleteData(0,eo);
        \\        else ec.data=ec.data.substring(eo);
        \\      }
        \\    }else if(lastPC){
        \\      var cl2=frag?lastPC.cloneNode(false):null;
        \\      if(cl2)frag.appendChild(cl2);
        \\      var sub2={_sc:lastPC,_so:0,_ec:ec,_eo:eo};
        \\      Object.setPrototypeOf(sub2,Range.prototype);
        \\      var sf2=extractOrDelete(sub2,mode);
        \\      if(cl2&&sf2){while(sf2.firstChild)cl2.appendChild(sf2.firstChild);}
        \\    }
        \\    /* Update range boundaries for extract/delete modes */
        \\    if(mode!=='clone'){
        \\      range._sc=newSc;range._so=newSo;range._ec=newSc;range._eo=newSo;
        \\    }
        \\    return frag;
        \\  }
        \\
        \\  RP.cloneContents=function(){return extractOrDelete(this,'clone');};
        \\  RP.extractContents=function(){return extractOrDelete(this,'extract');};
        \\  RP.deleteContents=function(){extractOrDelete(this,'delete');};
        \\  RP.insertNode=function(node){
        \\    ensureNode(node);
        \\    var sc=this._sc,so=this._so;
        \\    var parent,ref;
        \\    if(sc.nodeType===3||sc.nodeType===4||sc.nodeType===8){
        \\      /* Split text at so; insert before the new sibling. */
        \\      parent=sc.parentNode;
        \\      if(!parent)throw DOMEx('HierarchyRequestError');
        \\      if(so===0){
        \\        ref=sc;
        \\      }else if(so>=nLen(sc)){
        \\        ref=sc.nextSibling;
        \\      }else{
        \\        /* Manual splitText (kotori lacks Text.splitText): */
        \\        var d1=sc.data.substring(0,so),d2=sc.data.substring(so);
        \\        var newTxt=document.createTextNode(d2);
        \\        if(typeof sc.deleteData==='function')sc.deleteData(so,sc.data.length-so);
        \\        else sc.data=d1;
        \\        parent.insertBefore(newTxt,sc.nextSibling);
        \\        ref=newTxt;
        \\      }
        \\    }else{
        \\      parent=sc;
        \\      ref=(sc.childNodes&&so<sc.childNodes.length)?sc.childNodes[so]:null;
        \\    }
        \\    if(node===ref)ref=node.nextSibling;
        \\    if(node.parentNode)node.parentNode.removeChild(node);
        \\    parent.insertBefore(node,ref);
        \\  };
        \\  RP.surroundContents=function(newParent){
        \\    ensureNode(newParent);
        \\    /* §5.2: throw InvalidStateError if range partially contains a non-Text node. */
        \\    var s=this._sc,e=this._ec;
        \\    if(s!==e){
        \\      /* Walk from sc up to common ancestor; if any ancestor is non-Text and partially contained → throw. */
        \\      var n=s;while(n&&n!==this.commonAncestorContainer){
        \\        if(n.nodeType!==3&&n.nodeType!==4&&rangePartiallyContains(this,n))throw DOMEx('InvalidStateError');
        \\        n=n.parentNode;
        \\      }
        \\      n=e;while(n&&n!==this.commonAncestorContainer){
        \\        if(n.nodeType!==3&&n.nodeType!==4&&rangePartiallyContains(this,n))throw DOMEx('InvalidStateError');
        \\        n=n.parentNode;
        \\      }
        \\    }
        \\    var nt=newParent.nodeType;
        \\    if(nt===9||nt===10||nt===11)throw DOMEx('InvalidNodeTypeError');
        \\    var frag=this.extractContents();
        \\    while(newParent.firstChild)newParent.removeChild(newParent.firstChild);
        \\    this.insertNode(newParent);
        \\    newParent.appendChild(frag);
        \\    this.selectNode(newParent);
        \\  };
        \\  RP.createContextualFragment=function(html){
        \\    var ctx=this._sc;
        \\    /* Find nearest Element ancestor, default to body */
        \\    var el=ctx;while(el&&el.nodeType!==1)el=el.parentNode;
        \\    if(!el)el=document.body||document.documentElement;
        \\    var tpl=document.createElement(el?el.tagName||'div':'div');
        \\    try{tpl.innerHTML=html;}catch(e){}
        \\    var frag=document.createDocumentFragment();
        \\    while(tpl.firstChild)frag.appendChild(tpl.firstChild);
        \\    return frag;
        \\  };
        \\  RP.getClientRects=function(){return [];};
        \\  RP.getBoundingClientRect=function(){return {x:0,y:0,width:0,height:0,top:0,right:0,bottom:0,left:0};};
        \\  RP.toString=function(){
        \\    var sc=this._sc,so=this._so,ec=this._ec,eo=this._eo;
        \\    if(sc===ec){
        \\      if(sc.nodeType===3||sc.nodeType===4)return(sc.data||'').substring(so,eo);
        \\      var out='',cn=sc.childNodes||[];
        \\      for(var i=so;i<eo&&i<cn.length;i++){
        \\        var k=cn[i];
        \\        if(k.nodeType===3||k.nodeType===4)out+=k.data||'';
        \\        else if(k.textContent!=null)out+=k.textContent||'';
        \\      }
        \\      return out;
        \\    }
        \\    var res='';
        \\    if(sc.nodeType===3||sc.nodeType===4)res+=(sc.data||'').substring(so);
        \\    var cur=nextNode(sc,null);
        \\    while(cur&&cur!==ec){
        \\      if(cur.nodeType===3||cur.nodeType===4){
        \\        /* Only include text fully in range (not ec itself handled below). */
        \\        res+=cur.data||'';
        \\      }
        \\      cur=nextNode(cur,null);
        \\    }
        \\    if(ec.nodeType===3||ec.nodeType===4)res+=(ec.data||'').substring(0,eo);
        \\    return res;
        \\  };
        \\
        \\  globalThis.Range=Range;
        \\
        \\  /* --- StaticRange (DOM §5.3) -------------------------------- */
        \\  function StaticRange(init){
        \\    if(!(this instanceof StaticRange))throw new TypeError("StaticRange must be constructed with 'new'");
        \\    if(!init||typeof init!=='object')throw new TypeError('StaticRange init dictionary required');
        \\    ensureNode(init.startContainer);ensureNode(init.endContainer);
        \\    var sc=init.startContainer, ec=init.endContainer;
        \\    if(sc.nodeType===10||sc.nodeType===7||ec.nodeType===10||ec.nodeType===7)throw DOMEx('InvalidNodeTypeError');
        \\    function __no(n){n=Number(n);if(!isFinite(n)||n<0)return 0;return Math.floor(n);}
        \\    this._sc=sc;this._so=__no(init.startOffset);this._ec=ec;this._eo=__no(init.endOffset);
        \\  }
        \\  var SP=StaticRange.prototype;
        \\  defGet(SP,'startContainer',function(){return this._sc;});
        \\  defGet(SP,'startOffset',function(){return this._so;});
        \\  defGet(SP,'endContainer',function(){return this._ec;});
        \\  defGet(SP,'endOffset',function(){return this._eo;});
        \\  defGet(SP,'collapsed',function(){return this._sc===this._ec&&this._so===this._eo;});
        \\  defGet(SP,'commonAncestorContainer',function(){
        \\    var a=this._sc,b=this._ec;
        \\    if(a===b)return a;
        \\    var anc=[],n=a;while(n){anc.push(n);n=n.parentNode;}
        \\    n=b;while(n){for(var i=0;i<anc.length;i++)if(anc[i]===n)return n;n=n.parentNode;}
        \\    return null;
        \\  });
        \\  globalThis.StaticRange=StaticRange;
        \\
        \\  /* --- document.createRange + Document.prototype.createRange --- */
        \\  function createRange(){return new Range();}
        \\  if(typeof Document!=='undefined'&&Document.prototype){
        \\    Document.prototype.createRange=createRange;
        \\  }
        \\  if(typeof document!=='undefined'){
        \\    try{document.createRange=createRange;}catch(e){}
        \\  }
        \\
        \\  /* --- Live boundary tracking (DOM §5.5) ----------------------
        \\   * Shadow Node.prototype mutation methods so live ranges update
        \\   * when their endpoint nodes are removed / inserted / character
        \\   * data is modified. We cover the primary paths: removeChild,
        \\   * insertBefore, appendChild, and CharacterData.deleteData /
        \\   * insertData / replaceData. This is enough for WPT's common
        \\   * Range-during-mutation tests; complete parent-chain escalation
        \\   * is approximated by walking each tracked range on each call.
        \\   */
        \\  function rangeBpNodeRemoved(range,removed){
        \\    /* If boundary container is (descendant of) removed node, snap
        \\     * to removed.parentNode at the removed-index. */
        \\    function fix(which){
        \\      var n=range[which==='start'?'_sc':'_ec'];
        \\      if(!n)return;
        \\      if(n===removed || isAncestorOf(removed,n)){
        \\        var p=removed.parentNode;
        \\        if(p){
        \\          var i=idx(removed);
        \\          if(which==='start'){range._sc=p;range._so=i;}
        \\          else{range._ec=p;range._eo=i;}
        \\        }
        \\      }else if(n===removed.parentNode){
        \\        /* Sibling removed before boundary index: decrement. */
        \\        var rIdx=idx(removed);
        \\        var off=which==='start'?range._so:range._eo;
        \\        if(rIdx<off){
        \\          if(which==='start')range._so=off-1;else range._eo=off-1;
        \\        }
        \\      }
        \\    }
        \\    fix('start');fix('end');
        \\  }
        \\  function shadow(proto,name,hook){
        \\    if(!proto)return;
        \\    var orig=proto[name];
        \\    if(typeof orig!=='function')return;
        \\    proto[name]=function(){
        \\      return hook.call(this,orig,arguments);
        \\    };
        \\  }
        \\  /* Node.prototype.removeChild */
        \\  if(typeof Node!=='undefined'&&Node.prototype){
        \\    shadow(Node.prototype,'removeChild',function(orig,args){
        \\      var child=args[0];
        \\      var r=orig.apply(this,args);
        \\      if(child)forEachRange(function(rng){rangeBpNodeRemoved(rng,child);});
        \\      return r;
        \\    });
        \\  }
        \\  /* Element.prototype.removeChild (in case Node shadow didn't propagate) */
        \\  if(typeof Element!=='undefined'&&Element.prototype&&Element.prototype.removeChild){
        \\    shadow(Element.prototype,'removeChild',function(orig,args){
        \\      var child=args[0];
        \\      var r=orig.apply(this,args);
        \\      if(child)forEachRange(function(rng){rangeBpNodeRemoved(rng,child);});
        \\      return r;
        \\    });
        \\  }
        \\})();
    ;

    /// DOM §7.1 DOMTokenList polyfill for kotori (Element.classList).
    ///
    /// The polyfill installs `Element.prototype.classList` as a getter that
    /// returns a cached per-element wrapper object. The wrapper implements the
    /// DOMTokenList interface methods (`.add`, `.remove`, `.contains`,
    /// `.toggle`, `.replace`, `.item`, `.supports`, `.toString`, `.forEach`)
    /// plus live `length` and `value` accessors. Every read re-parses the
    /// element's `class` attribute, so mutations via `setAttribute`,
    /// `removeAttribute`, or `.className =` are reflected immediately.
    ///
    /// Spec references (WHATWG DOM):
    ///  - §7.1 DOMTokenList interface (add/remove/toggle/replace/contains/item)
    ///  - §7.1 token validation: empty → SyntaxError,
    ///    ASCII whitespace in a token → InvalidCharacterError
    ///  - §7.1 `.supports()` for a DOMTokenList with no supported-tokens list
    ///    (the `class` attribute has none) must throw TypeError
    ///  - §4.9 ordered set parser: tokens separated by ASCII whitespace
    ///    (U+0009, U+000A, U+000C, U+000D, U+0020); duplicates collapsed
    ///  - WebIDL [SameObject]: `element.classList` returns the same object
    ///    on every access (cached via WeakMap)
    ///  - WebIDL [PutForwards=value]: assigning `element.classList = "..."`
    ///    forwards to `element.classList.value = "..."`, i.e. sets `class`.
    ///
    /// Indexed access (DOM §7.1, WebIDL "supported property indices"):
    ///  - `classList[i]` / `"i" in classList` / `classList[i] = x` go through
    ///    a `Proxy` wrapper. String keys matching /^\d+$/ are treated as
    ///    property indices and resolved against the live token list; all
    ///    other keys fall through to the underlying DTLP-instance (so
    ///    `list.add(...)`, `list.length`, `list.value`, etc. keep working).
    ///  - The spec-faithful `Proxy`/`ToUint32` path is now safe because
    ///    kotori's `toInt32`/`toUint32` were fixed to match ECMA-262 §7.1.6
    ///    (NaN/Infinity/out-of-range → 0 instead of panicking).
    /// Iterator support:
    ///  - `keys`, `values`, `entries`, and `Symbol.iterator` mirror the
    ///    WebIDL iterable surface for DOMTokenList.
    const class_list_polyfill_js =
        \\(function(){
        \\  if (typeof Element==='undefined' || !Element.prototype) return;
        \\  /* ASCII whitespace per DOM §2.3 / §4.9 ordered-set parser. */
        \\  var WS_RE = /[\x09\x0A\x0C\x0D\x20]+/;
        \\  var HAS_WS_RE = /[\x09\x0A\x0C\x0D\x20]/;
        \\  function parseOrderedSet(s){
        \\    if (s==null || s==='') return [];
        \\    var raw = String(s).split(WS_RE);
        \\    var seen = {}, out = [];
        \\    for (var i=0;i<raw.length;i++){
        \\      var t = raw[i];
        \\      if (t==='') continue;
        \\      /* ':' prefix so keys like "constructor"/"toString" don't collide
        \\       * with Object.prototype properties when used as map keys. */
        \\      var k = ':'+t;
        \\      if (seen[k]) continue;
        \\      seen[k] = 1;
        \\      out.push(t);
        \\    }
        \\    return out;
        \\  }
        \\  function serializeOrderedSet(arr){
        \\    var seen = {}, out = [];
        \\    for (var i=0;i<arr.length;i++){
        \\      var t = String(arr[i]);
        \\      var k = ':'+t;
        \\      if (seen[k]) continue;
        \\      seen[k] = 1;
        \\      out.push(t);
        \\    }
        \\    return out.join(' ');
        \\  }
        \\  /* DOM §7.1 validation: throw DOMException per spec codes. */
        \\  function validateToken(t){
        \\    if (t==='') throw new DOMException("The token provided must not be empty.","SyntaxError");
        \\    if (HAS_WS_RE.test(t)) throw new DOMException("The token provided ('"+t+"') contains HTML space characters, which are not valid in tokens.","InvalidCharacterError");
        \\  }
        \\  function getTokens(el){
        \\    if (!el) return [];
        \\    var cl = el.getAttribute('class');
        \\    return parseOrderedSet(cl);
        \\  }
        \\  function writeTokens(el, toks){
        \\    el.setAttribute('class', serializeOrderedSet(toks));
        \\  }
        \\  /* WebIDL unsigned long conversion for item(index). */
        \\  function toIntIndex(v){
        \\    return v>>>0;
        \\  }
        \\
        \\  /* DOMTokenList constructor — WebIDL [Exposed] with no constructor,
        \\   * so user-code `new DOMTokenList()` must throw. It exists primarily
        \\   * so `classList instanceof DOMTokenList` returns true. */
        \\  function DOMTokenList(){
        \\    throw new TypeError("Illegal constructor");
        \\  }
        \\  var DTLP = DOMTokenList.prototype;
        \\  DTLP.constructor = DOMTokenList;
        \\  try { DTLP[Symbol.toStringTag] = 'DOMTokenList'; } catch(e) {}
        \\
        \\  /* Methods. `this` is the wrapper object with a non-enumerable
        \\   * `_el` reference to the owning element. */
        \\  DTLP.item = function(idx){
        \\    /* DOM §7.1 item(index): if index is out of range, return null. */
        \\    var n = toIntIndex(idx);
        \\    var toks = getTokens(this._el);
        \\    if (n >= toks.length) return null;
        \\    return toks[n];
        \\  };
        \\  DTLP.contains = function(token){
        \\    /* DOM §7.1 contains() runs no validation per current spec. */
        \\    var t = String(token);
        \\    var toks = getTokens(this._el);
        \\    for (var i=0;i<toks.length;i++) if (toks[i]===t) return true;
        \\    return false;
        \\  };
        \\  DTLP.add = function(){
        \\    /* DOM §7.1 add(...tokens): validate every argument first, then
        \\     * apply (i.e. validation failures leave state untouched). */
        \\    var args = [];
        \\    for (var i=0;i<arguments.length;i++){
        \\      args.push(String(arguments[i]));
        \\      validateToken(args[i]);
        \\    }
        \\    var toks = getTokens(this._el);
        \\    /* getTokens already split on whitespace + deduped; we still
        \\     * need to write back even when no NEW token is appended so
        \\     * the class attribute is canonicalized — DOM §7.1 update
        \\     * steps run unconditionally after add()/remove()/etc., turning
        \\     * "a a a  b" into "a b" on the next add("a"). */
        \\    var seen = {};
        \\    for (var j=0;j<toks.length;j++) seen[':'+toks[j]] = 1;
        \\    for (var k=0;k<args.length;k++){
        \\      var key = ':'+args[k];
        \\      if (!seen[key]) { seen[key] = 1; toks.push(args[k]); }
        \\    }
        \\    writeTokens(this._el, toks);
        \\  };
        \\  DTLP.remove = function(){
        \\    var args = [];
        \\    for (var i=0;i<arguments.length;i++){
        \\      args.push(String(arguments[i]));
        \\      validateToken(args[i]);
        \\    }
        \\    var toks = getTokens(this._el);
        \\    var drop = {};
        \\    for (var k=0;k<args.length;k++) drop[':'+args[k]] = 1;
        \\    var out = [];
        \\    for (var j=0;j<toks.length;j++){
        \\      if (drop[':'+toks[j]]) continue;
        \\      out.push(toks[j]);
        \\    }
        \\    /* DOM §7.1 remove() always normalizes the attribute when present. */
        \\    if (this._el.getAttribute('class')!=null) {
        \\      writeTokens(this._el, out);
        \\    }
        \\  };
        \\  DTLP.toggle = function(token, force){
        \\    var t = String(token);
        \\    validateToken(t);
        \\    var toks = getTokens(this._el);
        \\    var idx = -1;
        \\    for (var i=0;i<toks.length;i++) if (toks[i]===t) { idx = i; break; }
        \\    var hasForce = (arguments.length >= 2);
        \\    if (idx !== -1) {
        \\      if (!hasForce || !force) {
        \\        toks.splice(idx,1);
        \\        writeTokens(this._el, toks);
        \\        return false;
        \\      }
        \\      return true;
        \\    }
        \\    if (hasForce && !force) return false;
        \\    toks.push(t);
        \\    writeTokens(this._el, toks);
        \\    return true;
        \\  };
        \\  DTLP.replace = function(token, newToken){
        \\    /* DOM §7.1 replace(token, newToken): per spec the empty-string
        \\     * check (SyntaxError) precedes the whitespace check
        \\     * (InvalidCharacterError) for BOTH arguments — running
        \\     * validateToken sequentially flips the precedence when token
        \\     * has whitespace and newToken is empty. */
        \\    var t = String(token), nt = String(newToken);
        \\    if (t==='') throw new DOMException("The token provided must not be empty.","SyntaxError");
        \\    if (nt==='') throw new DOMException("The token provided must not be empty.","SyntaxError");
        \\    if (HAS_WS_RE.test(t)) throw new DOMException("The token provided ('"+t+"') contains HTML space characters, which are not valid in tokens.","InvalidCharacterError");
        \\    if (HAS_WS_RE.test(nt)) throw new DOMException("The token provided ('"+nt+"') contains HTML space characters, which are not valid in tokens.","InvalidCharacterError");
        \\    var toks = getTokens(this._el);
        \\    var idx = -1;
        \\    for (var i=0;i<toks.length;i++) if (toks[i]===t) { idx = i; break; }
        \\    if (idx === -1) return false;
        \\    toks[idx] = nt;
        \\    /* serializeOrderedSet collapses duplicates introduced by the replace. */
        \\    writeTokens(this._el, toks);
        \\    return true;
        \\  };
        \\  DTLP.supports = function(){
        \\    /* DOM §7.1: classList is bound to `class`, which has no supported
        \\     * tokens list, so supports() must throw TypeError. */
        \\    throw new TypeError("DOMTokenList has no supported tokens for the 'class' attribute.");
        \\  };
        \\  DTLP.toString = function(){
        \\    /* DOM §7.1 stringifier: return `class` attribute value verbatim
        \\     * (NOT the ordered-set serialization). */
        \\    if (!this._el) return '';
        \\    var v = this._el.getAttribute('class');
        \\    return v==null ? '' : v;
        \\  };
        \\  DTLP.forEach = function(cb, thisArg){
        \\    var toks = getTokens(this._el);
        \\    for (var i=0;i<toks.length;i++) cb.call(thisArg, toks[i], i, this);
        \\  };
        \\  /* DOM §7.1 Iterable<DOMString>: keys/values/entries/@@iterator.
        \\   * WPT DOMTokenList-iteration.html test "classList inheritance from
        \\   * Array.prototype" requires list[Symbol.iterator] === the exact same
        \\   * function object as Array.prototype[Symbol.iterator].  We assign the
        \\   * Array.prototype reference to DTLP so both accesses return the same
        \\   * JsObject (arr_iter_fn) — strict equality passes.
        \\   *
        \\   * keys/values/entries keep custom implementations that return real
        \\   * iterator objects (obj_type==.iterator) rather than arrays, so that
        \\   * `keys instanceof Array === false` and `[...keys()]` spread works. */
        \\  DTLP[Symbol.iterator] = Array.prototype[Symbol.iterator];
        \\  DTLP.keys = function(){
        \\    var toks = getTokens(this._el);
        \\    var out = [];
        \\    for (var i=0;i<toks.length;i++) out.push(i);
        \\    return out[Symbol.iterator]();
        \\  };
        \\  DTLP.values = function(){
        \\    return getTokens(this._el)[Symbol.iterator]();
        \\  };
        \\  DTLP.entries = function(){
        \\    var toks = getTokens(this._el);
        \\    var out = [];
        \\    for (var i=0;i<toks.length;i++) out.push([i, toks[i]]);
        \\    return out[Symbol.iterator]();
        \\  };
        \\
        \\  /* Live length / value accessors — re-read the attribute on every get. */
        \\  Object.defineProperty(DTLP, 'length', {
        \\    get: function(){ return getTokens(this._el).length; },
        \\    configurable: true, enumerable: true
        \\  });
        \\  Object.defineProperty(DTLP, 'value', {
        \\    get: function(){
        \\      if (!this._el) return '';
        \\      var v = this._el.getAttribute('class');
        \\      return v==null ? '' : v;
        \\    },
        \\    set: function(v){ this._el.setAttribute('class', String(v)); },
        \\    configurable: true, enumerable: true
        \\  });
        \\
        \\  globalThis.DOMTokenList = DOMTokenList;
        \\
        \\  /* WebIDL [SameObject]: every read of element.classList returns the
        \\   * identical wrapper object. Store on the element itself via a
        \\   * non-enumerable property rather than a WeakMap (WeakMap support
        \\   * in kotori may be incomplete).
        \\   *
        \\   * The stored value is a Proxy around the DTLP instance so that
        \\   * indexed lookups (`list[0]`, `"0" in list`) return tokens and
        \\   * bracket-writes (`list[0] = "x"`) are silently ignored per WebIDL
        \\   * "supported property indices" semantics. All other keys (method
        \\   * names, `length`, `value`, `constructor`, symbol well-knowns,
        \\   * private slot `_el`) pass through to the target unchanged so the
        \\   * existing method bodies keep working as-is.
        \\   *
        \\   * kotori VM Symbol-key limitations and workarounds:
        \\   * - `in` operator with Symbol lhs: VM converts Symbol to "undefined"
        \\   *   before invoking the Proxy `has` trap (keyToStringId fallback).
        \\   *   We return true for p==="undefined" so `Symbol.iterator in list`
        \\   *   passes (WPT DOMTokenList-Iterable.html §5).
        \\   * - `proxy[Symbol.iterator]`: VM converts Symbol to "undefined" before
        \\   *   invoking the Proxy `get` trap. We detect p==="undefined" and return
        \\   *   t[Symbol.iterator] (resolved on the non-proxy target via
        \\   *   findSymbolProp) so `list[Symbol.iterator] === Array.prototype[Symbol.iterator]`
        \\   *   passes (WPT DOMTokenList-iteration.html "classList inheritance"). */
        \\  var DIGITS_RE = /^(?:0|[1-9][0-9]*)$/;
        \\  function getWrapper(el){
        \\    var w = el.__clsl;
        \\    if (w) return w;
        \\    var target = Object.create(DTLP);
        \\    /* Stash the element pointer on a writable-false slot so user code
        \\     * cannot replace it. Methods retrieve it via `this._el`, and the
        \\     * Proxy `get` trap returns it untouched for that key. */
        \\    try {
        \\      Object.defineProperty(target, '_el', {value: el, writable:false, enumerable:false, configurable:false});
        \\    } catch(e) {
        \\      target._el = el;
        \\    }
        \\    w = new Proxy(target, {
        \\      get: function(t, p){
        \\        /* Use Number() not unary `+p` — kotori's unary-plus on a
        \\         * numeric string currently mis-coerces to boolean. */
        \\        if (typeof p === 'string' && DIGITS_RE.test(p)) {
        \\          var toks = getTokens(t._el);
        \\          var i = Number(p);
        \\          return i < toks.length ? toks[i] : undefined;
        \\        }
        \\        /* kotori VM converts Symbol keys to "undefined" before calling
        \\         * the Proxy get trap (keyToStringId fallback). Detect this and
        \\         * return t[Symbol.iterator] so `list[Symbol.iterator]` resolves
        \\         * to the correct function for identity checks. */
        \\        if (p === 'undefined') {
        \\          var sym = t[Symbol.iterator];
        \\          if (typeof sym === 'function') return sym;
        \\        }
        \\        return t[p];
        \\      },
        \\      set: function(t, p, v){
        \\        /* WebIDL: writes to integer indices are ignored (no setter). */
        \\        if (typeof p === 'string' && DIGITS_RE.test(p)) return true;
        \\        t[p] = v;
        \\        return true;
        \\      },
        \\      has: function(t, p){
        \\        /* kotori VM converts Symbol keys to the string "undefined" before
        \\         * invoking the Proxy `has` trap. Return true for "undefined" so
        \\         * `Symbol.iterator in list` passes (WPT DOMTokenList-Iterable.html). */
        \\        if (p === 'undefined') return true;
        \\        if (typeof p === 'string' && DIGITS_RE.test(p)) {
        \\          return Number(p) < getTokens(t._el).length;
        \\        }
        \\        return (p in t);
        \\      }
        \\    });
        \\    try {
        \\      Object.defineProperty(el, '__clsl', {value: w, writable:false, enumerable:false, configurable:false});
        \\    } catch(e) {
        \\      el.__clsl = w;
        \\    }
        \\    return w;
        \\  }
        \\
        \\  Object.defineProperty(Element.prototype, 'classList', {
        \\    get: function(){ return getWrapper(this); },
        \\    /* WebIDL [PutForwards=value]: setter forwards to .value. */
        \\    set: function(v){ this.setAttribute('class', String(v)); },
        \\    configurable: true, enumerable: true
        \\  });
        \\})();
    ;

    /// HTML §4.6.1 (HTMLAnchorElement.relList), §4.8.4 (HTMLAreaElement.relList),
    /// §4.2.4 (HTMLLinkElement.relList) — DOMTokenList bound to the `rel` attribute.
    ///
    /// Mirrors classList but bound to `rel` rather than `class`.  The same
    /// DOMTokenList constructor / shared infrastructure from classList is reused
    /// (it is injected first), so this polyfill depends on class_list_polyfill_js
    /// having run first.
    const rel_list_polyfill_js =
        \\(function(){
        \\  /* Reuse the DOMTokenList constructor & shared helpers already installed
        \\   * by the classList polyfill.  If for any reason DOMTokenList is absent
        \\   * we bail out gracefully. */
        \\  var DTL = globalThis.DOMTokenList;
        \\  if (!DTL) return;
        \\  var DTLP = DTL.prototype;
        \\
        \\  /* ASCII whitespace per DOM §2.3 / §4.9 ordered-set parser. */
        \\  var WS_RE = /[\x09\x0A\x0C\x0D\x20]+/;
        \\  var HAS_WS_RE = /[\x09\x0A\x0C\x0D\x20]/;
        \\  function parseOrderedSet(s){
        \\    if (s==null || s==='') return [];
        \\    var raw = String(s).split(WS_RE);
        \\    var seen = {}, out = [];
        \\    for (var i=0;i<raw.length;i++){
        \\      var t = raw[i]; if (t==='') continue;
        \\      var k = ':'+t; if (seen[k]) continue;
        \\      seen[k] = 1; out.push(t);
        \\    }
        \\    return out;
        \\  }
        \\  function serializeOrderedSet(arr){
        \\    var seen = {}, out = [];
        \\    for (var i=0;i<arr.length;i++){
        \\      var t = String(arr[i]); var k = ':'+t;
        \\      if (seen[k]) continue; seen[k] = 1; out.push(t);
        \\    }
        \\    return out.join(' ');
        \\  }
        \\  function validateToken(t){
        \\    if (t==='') throw new DOMException("The token provided must not be empty.","SyntaxError");
        \\    if (HAS_WS_RE.test(t)) throw new DOMException("The token provided ('"+t+"') contains HTML space characters, which are not valid in tokens.","InvalidCharacterError");
        \\  }
        \\  function getRelTokens(el){
        \\    var v = el.getAttribute('rel'); return parseOrderedSet(v);
        \\  }
        \\  function writeRelTokens(el, toks){
        \\    el.setAttribute('rel', serializeOrderedSet(toks));
        \\  }
        \\  function toIntIndex(v){ return v>>>0; }
        \\
        \\  /* Build a relList wrapper for `el`, backed by the `rel` attribute. */
        \\  var DIGITS_RE = /^(?:0|[1-9][0-9]*)$/;
        \\  function getRelWrapper(el){
        \\    var w = el.__rlsl; if (w) return w;
        \\    var target = Object.create(DTLP);
        \\    try {
        \\      Object.defineProperty(target,'_el',{value:el,writable:false,enumerable:false,configurable:false});
        \\    } catch(e){ target._el = el; }
        \\    /* Override methods that read/write `class` to use `rel` instead. */
        \\    target.item = function(idx){
        \\      var n=toIntIndex(idx);
        \\      var toks=getRelTokens(this._el); return n<toks.length?toks[n]:null;
        \\    };
        \\    target.contains = function(token){
        \\      var t=String(token), toks=getRelTokens(this._el);
        \\      for(var i=0;i<toks.length;i++) if(toks[i]===t) return true;
        \\      return false;
        \\    };
        \\    target.add = function(){
        \\      var args=[]; for(var i=0;i<arguments.length;i++){args.push(String(arguments[i]));validateToken(args[i]);}
        \\      var toks=getRelTokens(this._el),seen={};
        \\      for(var j=0;j<toks.length;j++) seen[':'+toks[j]]=1;
        \\      var changed=false;
        \\      for(var k=0;k<args.length;k++){var key=':'+args[k];if(!seen[key]){seen[key]=1;toks.push(args[k]);changed=true;}}
        \\      if(changed||this._el.getAttribute('rel')==null) writeRelTokens(this._el,toks);
        \\    };
        \\    target.remove = function(){
        \\      var args=[]; for(var i=0;i<arguments.length;i++){args.push(String(arguments[i]));validateToken(args[i]);}
        \\      var toks=getRelTokens(this._el),drop={};
        \\      for(var k=0;k<args.length;k++) drop[':'+args[k]]=1;
        \\      var out=[]; for(var j=0;j<toks.length;j++){if(drop[':'+toks[j]])continue;out.push(toks[j]);}
        \\      if(this._el.getAttribute('rel')!=null) writeRelTokens(this._el,out);
        \\    };
        \\    target.toggle = function(token,force){
        \\      var t=String(token); validateToken(t);
        \\      var toks=getRelTokens(this._el),idx=-1;
        \\      for(var i=0;i<toks.length;i++) if(toks[i]===t){idx=i;break;}
        \\      var hasForce=(arguments.length>=2);
        \\      if(idx!==-1){
        \\        if(!hasForce||!force){toks.splice(idx,1);writeRelTokens(this._el,toks);return false;}
        \\        return true;
        \\      }
        \\      if(hasForce&&!force) return false;
        \\      toks.push(t); writeRelTokens(this._el,toks); return true;
        \\    };
        \\    target.replace = function(token,newToken){
        \\      var t=String(token),nt=String(newToken); validateToken(t); validateToken(nt);
        \\      var toks=getRelTokens(this._el),idx=-1;
        \\      for(var i=0;i<toks.length;i++) if(toks[i]===t){idx=i;break;}
        \\      if(idx===-1) return false;
        \\      toks[idx]=nt; writeRelTokens(this._el,toks); return true;
        \\    };
        \\    target.supports = function(){
        \\      /* HTML spec: rel supports "noopener","noreferrer","nofollow", etc.
        \\       * For simplicity throw TypeError as unsupported-tokens path. */
        \\      throw new TypeError("DOMTokenList has no supported tokens for the 'rel' attribute.");
        \\    };
        \\    target.toString = function(){
        \\      if(!this._el) return '';
        \\      var v=this._el.getAttribute('rel'); return v==null?'':v;
        \\    };
        \\    target.forEach = Array.prototype.forEach;
        \\    target[Symbol.iterator] = Array.prototype[Symbol.iterator];
        \\    target.keys    = Array.prototype.keys;
        \\    target.entries = Array.prototype.entries;
        \\    if(Array.prototype.values) target.values = Array.prototype.values;
        \\    Object.defineProperty(target,'length',{
        \\      get:function(){return getRelTokens(this._el).length;},configurable:true,enumerable:true
        \\    });
        \\    Object.defineProperty(target,'value',{
        \\      get:function(){if(!this._el)return'';var v=this._el.getAttribute('rel');return v==null?'':v;},
        \\      set:function(v){this._el.setAttribute('rel',String(v));},configurable:true,enumerable:true
        \\    });
        \\    w = new Proxy(target, {
        \\      get: function(t,p){
        \\        if(typeof p==='string'&&DIGITS_RE.test(p)){
        \\          var toks=getRelTokens(t._el),i=Number(p);
        \\          return i<toks.length?toks[i]:undefined;
        \\        }
        \\        return t[p];
        \\      },
        \\      set: function(t,p,v){
        \\        if(typeof p==='string'&&DIGITS_RE.test(p)) return true;
        \\        t[p]=v; return true;
        \\      },
        \\      has: function(t,p){
        \\        if(typeof p==='symbol') return (p in t);
        \\        if(typeof p==='string'&&DIGITS_RE.test(p)) return Number(p)<getRelTokens(t._el).length;
        \\        return (p in t);
        \\      }
        \\    });
        \\    try {
        \\      Object.defineProperty(el,'__rlsl',{value:w,writable:false,enumerable:false,configurable:false});
        \\    } catch(e){ el.__rlsl = w; }
        \\    return w;
        \\  }
        \\
        \\  /* Install relList / htmlFor / sandbox / sizes on Element.prototype.
        \\   * The specific HTML interface prototypes (HTMLAnchorElement.prototype,
        \\   * etc.) are frozen by the kotori DOM init and cannot accept new
        \\   * properties.  We install on Element.prototype (not frozen) with a
        \\   * localName + namespace guard so unsupported elements return undefined.
        \\   *
        \\   * relList: XHTML <a>, <area>, <link> + SVG <a>  (HTML §4.6.1/§4.8.4/§4.2.4)
        \\   * htmlFor: XHTML <output>                        (HTML §4.10.5.4)
        \\   * sandbox: XHTML <iframe>                        (HTML §4.8.5)
        \\   * sizes:   XHTML <link>                          (HTML §4.2.4)
        \\   */
        \\  var XHTML_NS = 'http://www.w3.org/1999/xhtml';
        \\  var SVG_NS   = 'http://www.w3.org/2000/svg';
        \\  /* Helper: per-element DOMTokenList wrapper keyed by slot name. */
        \\  function makeTokenListGetter(attrName, slotName){
        \\    return function(){
        \\      var cacheKey = '__tl_' + slotName;
        \\      var cached = this[cacheKey];
        \\      if (cached) return cached;
        \\      /* Build a minimal DOMTokenList-like object for the attribute. */
        \\      var el = this;
        \\      var tl = Object.create(DTLP);
        \\      try {
        \\        Object.defineProperty(tl,'_el',{value:el,writable:false,enumerable:false,configurable:false});
        \\        Object.defineProperty(tl,'_attr',{value:attrName,writable:false,enumerable:false,configurable:false});
        \\      } catch(e){ tl._el=el; tl._attr=attrName; }
        \\      /* Override methods to use the correct attribute. */
        \\      function getToks(){ return parseOrderedSet(el.getAttribute(attrName)); }
        \\      function writeToks(t){ el.setAttribute(attrName, serializeOrderedSet(t)); }
        \\      tl.item = function(i){ var n=toIntIndex(i); var t=getToks(); return n<t.length?t[n]:null; };
        \\      tl.contains = function(tk){ var t=getToks(); for(var i=0;i<t.length;i++) if(t[i]===String(tk)) return true; return false; };
        \\      tl.add = function(){ var args=[]; for(var i=0;i<arguments.length;i++){args.push(String(arguments[i]));validateToken(args[i]);} var t=getToks(),s={}; for(var j=0;j<t.length;j++)s[':'+t[j]]=1; var c=false; for(var k=0;k<args.length;k++){var kk=':'+args[k];if(!s[kk]){s[kk]=1;t.push(args[k]);c=true;}} if(c||el.getAttribute(attrName)==null)writeToks(t); };
        \\      tl.remove = function(){ var args=[]; for(var i=0;i<arguments.length;i++){args.push(String(arguments[i]));validateToken(args[i]);} var t=getToks(),d={}; for(var k=0;k<args.length;k++)d[':'+args[k]]=1; var o=[]; for(var j=0;j<t.length;j++){if(d[':'+t[j]])continue;o.push(t[j]);} if(el.getAttribute(attrName)!=null)writeToks(o); };
        \\      tl.toggle = function(tk,f){ var t=String(tk); validateToken(t); var ts=getToks(),idx=-1; for(var i=0;i<ts.length;i++) if(ts[i]===t){idx=i;break;} var hf=(arguments.length>=2); if(idx!==-1){if(!hf||!f){ts.splice(idx,1);writeToks(ts);return false;}return true;} if(hf&&!f)return false; ts.push(t);writeToks(ts);return true; };
        \\      tl.replace = function(tk,nk){ var t=String(tk),n=String(nk); validateToken(t);validateToken(n); var ts=getToks(),idx=-1; for(var i=0;i<ts.length;i++) if(ts[i]===t){idx=i;break;} if(idx===-1)return false; ts[idx]=n;writeToks(ts);return true; };
        \\      tl.supports = function(){ throw new TypeError("DOMTokenList has no supported tokens for the '"+attrName+"' attribute."); };
        \\      tl.toString = function(){ var v=el.getAttribute(attrName); return v==null?'':v; };
        \\      tl.forEach = function(cb,ta){ var t=getToks(); for(var i=0;i<t.length;i++) cb.call(ta,t[i],i,this); };
        \\      tl.keys = function(){ var t=getToks(),o=[]; for(var i=0;i<t.length;i++) o.push(i); return o[Symbol.iterator](); };
        \\      tl.values = function(){ return getToks()[Symbol.iterator](); };
        \\      tl.entries = function(){ var t=getToks(),o=[]; for(var i=0;i<t.length;i++) o.push([i,t[i]]); return o[Symbol.iterator](); };
        \\      tl[Symbol.iterator] = Array.prototype[Symbol.iterator];
        \\      Object.defineProperty(tl,'length',{get:function(){return getToks().length;},configurable:true,enumerable:true});
        \\      Object.defineProperty(tl,'value',{get:function(){var v=el.getAttribute(attrName);return v==null?'':v;},set:function(v){el.setAttribute(attrName,String(v));},configurable:true,enumerable:true});
        \\      try { Object.defineProperty(el,cacheKey,{value:tl,writable:false,enumerable:false,configurable:false}); } catch(e){ el[cacheKey]=tl; }
        \\      return tl;
        \\    };
        \\  }
        \\  function parseOrderedSet(s){ if(s==null||s==='')return[]; var WS=/[\x09\x0A\x0C\x0D\x20]+/,raw=String(s).split(WS),seen={},out=[]; for(var i=0;i<raw.length;i++){var t=raw[i];if(t==='')continue;var k=':'+t;if(seen[k])continue;seen[k]=1;out.push(t);} return out; }
        \\  function serializeOrderedSet(arr){ var seen={},out=[]; for(var i=0;i<arr.length;i++){var t=String(arr[i]),k=':'+t;if(seen[k])continue;seen[k]=1;out.push(t);} return out.join(' '); }
        \\  function validateToken(t){ if(t==='')throw new DOMException("The token provided must not be empty.","SyntaxError"); if(/[\x09\x0A\x0C\x0D\x20]/.test(t))throw new DOMException("The token provided ('"+t+"') contains HTML space characters, which are not valid in tokens.","InvalidCharacterError"); }
        \\  function toIntIndex(v){ return v>>>0; }
        \\  if (typeof Element !== 'undefined' && Element.prototype) {
        \\    var EP = Element.prototype;
        \\    Object.defineProperty(EP, 'relList', {
        \\      get: function(){
        \\        var ns=this.namespaceURI, ln=this.localName;
        \\        if ((ns===XHTML_NS&&(ln==='a'||ln==='area'||ln==='link'))||(ns===SVG_NS&&ln==='a'))
        \\          return getRelWrapper(this);
        \\        return undefined;
        \\      },
        \\      set: function(v){ this.setAttribute('rel',String(v)); },
        \\      configurable: true, enumerable: true
        \\    });
        \\    var htmlForGetter = makeTokenListGetter('for','htmlFor');
        \\    Object.defineProperty(EP, 'htmlFor', {
        \\      get: function(){
        \\        if (this.namespaceURI===XHTML_NS && this.localName==='output') return htmlForGetter.call(this);
        \\        return undefined;
        \\      },
        \\      set: function(v){ this.setAttribute('for',String(v)); },
        \\      configurable: true, enumerable: true
        \\    });
        \\    var sandboxGetter = makeTokenListGetter('sandbox','sandbox');
        \\    Object.defineProperty(EP, 'sandbox', {
        \\      get: function(){
        \\        if (this.namespaceURI===XHTML_NS && this.localName==='iframe') return sandboxGetter.call(this);
        \\        return undefined;
        \\      },
        \\      set: function(v){ this.setAttribute('sandbox',String(v)); },
        \\      configurable: true, enumerable: true
        \\    });
        \\    var sizesGetter = makeTokenListGetter('sizes','sizes');
        \\    Object.defineProperty(EP, 'sizes', {
        \\      get: function(){
        \\        if (this.namespaceURI===XHTML_NS && this.localName==='link') return sizesGetter.call(this);
        \\        return undefined;
        \\      },
        \\      set: function(v){ this.setAttribute('sizes',String(v)); },
        \\      configurable: true, enumerable: true
        \\    });
        \\  }
        \\})();
    ;

    /// DOM §6 (TreeWalker + NodeIterator) + §4.7 (Document.importNode) +
    /// §4.2.3 NonElementParentNode.getElementById on DocumentFragment +
    /// HTML §4.12.3 template.content + small §4.5 createElementNS fixups.
    /// Pure-JS polyfills layered over kotori native bindings.
    const traversal_and_fixups_js =
        \\(function(){
        \\  /* ============ NodeFilter constants (DOM §6.1) =============== */
        \\  var FILTER_ACCEPT = 1, FILTER_REJECT = 2, FILTER_SKIP = 3;
        \\  var SHOW_ALL = 0xFFFFFFFF;
        \\  /* nodeType → whatToShow bit (DOM §6.1). Bit N = nodeType N. */
        \\  function showBit(nt){
        \\    /* whatToShow bits are numbered by nodeType: bit (nodeType-1). */
        \\    if (nt < 1 || nt > 12) return 0;
        \\    return 1 << (nt - 1);
        \\  }
        \\  /* Normalize whatToShow argument to a uint32. kotori's `>>> 0`
        \\   * panics on NaN/Infinity; we normalize manually. */
        \\  function toWhatToShow(v){
        \\    if (v === undefined) return SHOW_ALL;
        \\    var n = Number(v);
        \\    if (n !== n || n === Infinity || n === -Infinity) return 0;
        \\    n = Math.floor(n);
        \\    if (n < 0) n = n + 4294967296;
        \\    n = n % 4294967296;
        \\    if (n < 0) n = n + 4294967296;
        \\    return n;
        \\  }
        \\  if (typeof globalThis.NodeFilter !== 'object' || globalThis.NodeFilter == null) {
        \\    globalThis.NodeFilter = {
        \\      FILTER_ACCEPT: FILTER_ACCEPT,
        \\      FILTER_REJECT: FILTER_REJECT,
        \\      FILTER_SKIP:   FILTER_SKIP,
        \\      SHOW_ALL:          0xFFFFFFFF,
        \\      SHOW_ELEMENT:      0x1,
        \\      SHOW_ATTRIBUTE:    0x2,
        \\      SHOW_TEXT:         0x4,
        \\      SHOW_CDATA_SECTION:0x8,
        \\      SHOW_ENTITY_REFERENCE: 0x10,
        \\      SHOW_ENTITY:       0x20,
        \\      SHOW_PROCESSING_INSTRUCTION: 0x40,
        \\      SHOW_COMMENT:      0x80,
        \\      SHOW_DOCUMENT:     0x100,
        \\      SHOW_DOCUMENT_TYPE:0x200,
        \\      SHOW_DOCUMENT_FRAGMENT: 0x400,
        \\      SHOW_NOTATION:     0x800
        \\    };
        \\  }
        \\
        \\  /* DOM §6.2 InvalidStateError helper */
        \\  function makeInvalidStateError(msg){
        \\    try {
        \\      return new DOMException(msg, 'InvalidStateError');
        \\    } catch(e) {
        \\      var err = new Error(msg);
        \\      err.name = 'InvalidStateError';
        \\      return err;
        \\    }
        \\  }
        \\
        \\  /* Run the filter (DOM §6.2 "filter a node"). Returns the filter
        \\   * result constant (ACCEPT/REJECT/SKIP).
        \\   * Per spec: If active flag is set, throw InvalidStateError.
        \\   * Get(filter, 'acceptNode') on every traverse, throw
        \\   * TypeError if missing / not callable. */
        \\  function filterNode(walker, node){
        \\    if (!node) return FILTER_REJECT;
        \\    /* DOM §6.2: "If the active flag is set, then throw an
        \\     * 'InvalidStateError' DOMException." */
        \\    if (walker._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var bit = showBit(node.nodeType);
        \\    if ((walker._whatToShow & bit) === 0) return FILTER_SKIP;
        \\    var filter = walker._filter;
        \\    if (filter == null) return FILTER_ACCEPT;
        \\    /* Call filter with active=true; reset active before returning/throwing.
        \\     * kotori does not support try/finally, so we use a catch-rethrow pattern. */
        \\    var _NO_ERR = {};
        \\    walker._active = true;
        \\    var r, _filterErr = _NO_ERR;
        \\    if (typeof filter === 'function') {
        \\      try { r = filter.call(null, node); } catch(fe) { _filterErr = fe; }
        \\    } else {
        \\      /* DOM §6.2 "filter a node": perform Get(filter, 'acceptNode')
        \\       * on every traverse. Throw TypeError if not callable.
        \\       * The getter itself may throw (e.g. via Proxy or accessor). */
        \\      var accept;
        \\      try { accept = filter.acceptNode; } catch(fe) { _filterErr = fe; }
        \\      if (_filterErr === _NO_ERR) {
        \\        if (typeof accept !== 'function') {
        \\          walker._active = false;
        \\          throw new TypeError("Failed to execute 'acceptNode' on 'NodeFilter': acceptNode is not a function");
        \\        }
        \\        try { r = accept.call(filter, node); } catch(fe) { _filterErr = fe; }
        \\      }
        \\    }
        \\    walker._active = false;
        \\    if (_filterErr !== _NO_ERR) throw _filterErr;
        \\    var ri = Number(r);
        \\    if (ri === FILTER_ACCEPT || ri === FILTER_REJECT || ri === FILTER_SKIP) return ri;
        \\    return FILTER_REJECT;  /* invalid numeric result → REJECT */
        \\  }
        \\
        \\  /* -------- TreeWalker (DOM §6.1) --------------------------- */
        \\  function TreeWalker(){
        \\    throw new TypeError("Illegal constructor");
        \\  }
        \\  var TWP = TreeWalker.prototype;
        \\  TWP.constructor = TreeWalker;
        \\  try { TWP[Symbol.toStringTag] = 'TreeWalker'; } catch(e) {}
        \\
        \\  function defGet(obj, key, getter, setter){
        \\    var desc = {get: getter, configurable: true, enumerable: true};
        \\    if (setter) desc.set = setter;
        \\    Object.defineProperty(obj, key, desc);
        \\  }
        \\  defGet(TWP, 'root',        function(){ return this._root; });
        \\  defGet(TWP, 'whatToShow',  function(){ return this._whatToShow; });
        \\  defGet(TWP, 'filter',      function(){ return this._filter; });
        \\  defGet(TWP, 'currentNode',
        \\    function(){ return this._current; },
        \\    function(v){
        \\      /* DOM §6.1 IDL: currentNode attribute is a Node; Web IDL type
        \\       * check throws TypeError for non-Node values. */
        \\      if (v == null || typeof v !== 'object' || typeof v.nodeType !== 'number') {
        \\        throw new TypeError('currentNode must be a Node');
        \\      }
        \\      this._current = v;
        \\    }
        \\  );
        \\
        \\  /* DOM §6.1 parentNode: find nearest inclusive ancestor that is
        \\   * an inclusive descendant of root and ACCEPT. */
        \\  TWP.parentNode = function(){
        \\    if (this._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var n = this._current;
        \\    while (n != null && n !== this._root) {
        \\      n = n.parentNode;
        \\      if (n == null) return null;
        \\      if (filterNode(this, n) === FILTER_ACCEPT) {
        \\        this._current = n;
        \\        return n;
        \\      }
        \\    }
        \\    return null;
        \\  };
        \\  /* First child / last child traversal helper (§6.1). */
        \\  function twChild(walker, first){
        \\    if (walker._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var node = walker._current;
        \\    var child = first ? node.firstChild : node.lastChild;
        \\    while (child != null) {
        \\      var r = filterNode(walker, child);
        \\      if (r === FILTER_ACCEPT) {
        \\        walker._current = child;
        \\        return child;
        \\      }
        \\      if (r === FILTER_SKIP) {
        \\        var grand = first ? child.firstChild : child.lastChild;
        \\        if (grand != null) { child = grand; continue; }
        \\      }
        \\      /* Move sideways; if none, pop upward until we find a sibling or
        \\       * hit the walker's current node. */
        \\      while (child != null) {
        \\        var sib = first ? child.nextSibling : child.previousSibling;
        \\        if (sib != null) { child = sib; break; }
        \\        var p = child.parentNode;
        \\        if (p == null || p === walker._root || p === walker._current) return null;
        \\        child = p;
        \\      }
        \\    }
        \\    return null;
        \\  }
        \\  TWP.firstChild = function(){ return twChild(this, true); };
        \\  TWP.lastChild  = function(){ return twChild(this, false); };
        \\
        \\  /* Sibling helper (§6.1). */
        \\  function twSibling(walker, next){
        \\    if (walker._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var node = walker._current;
        \\    if (node === walker._root) return null;
        \\    while (true) {
        \\      var sib = next ? node.nextSibling : node.previousSibling;
        \\      while (sib != null) {
        \\        var r = filterNode(walker, sib);
        \\        if (r === FILTER_ACCEPT) { walker._current = sib; return sib; }
        \\        /* SKIP: descend into sib's edge child */
        \\        node = sib;
        \\        var edge = next ? sib.firstChild : sib.lastChild;
        \\        if (edge != null && r === FILTER_SKIP) { sib = edge; continue; }
        \\        /* REJECT or SKIP with no children: continue to sibling of sib */
        \\        if (r === FILTER_REJECT) {
        \\          sib = next ? sib.nextSibling : sib.previousSibling;
        \\          continue;
        \\        }
        \\        sib = next ? sib.nextSibling : sib.previousSibling;
        \\      }
        \\      node = node.parentNode;
        \\      if (node == null || node === walker._root) return null;
        \\      if (filterNode(walker, node) === FILTER_ACCEPT) return null;
        \\    }
        \\  }
        \\  TWP.nextSibling     = function(){ return twSibling(this, true); };
        \\  TWP.previousSibling = function(){ return twSibling(this, false); };
        \\
        \\  /* nextNode (DOM §6.1): pre-order traversal. */
        \\  TWP.nextNode = function(){
        \\    if (this._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var node = this._current;
        \\    var result = FILTER_ACCEPT;
        \\    while (true) {
        \\      while (result !== FILTER_REJECT && node.firstChild != null) {
        \\        node = node.firstChild;
        \\        result = filterNode(this, node);
        \\        if (result === FILTER_ACCEPT) { this._current = node; return node; }
        \\      }
        \\      /* find following sibling, walking up. */
        \\      var sib = null, tmp = node;
        \\      while (tmp != null) {
        \\        if (tmp === this._root) return null;
        \\        sib = tmp.nextSibling;
        \\        if (sib != null) { node = sib; break; }
        \\        tmp = tmp.parentNode;
        \\      }
        \\      if (sib == null) return null;
        \\      result = filterNode(this, node);
        \\      if (result === FILTER_ACCEPT) { this._current = node; return node; }
        \\    }
        \\  };
        \\  /* previousNode (§6.1) */
        \\  TWP.previousNode = function(){
        \\    if (this._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    var node = this._current;
        \\    while (node !== this._root) {
        \\      var sib = node.previousSibling;
        \\      while (sib != null) {
        \\        node = sib;
        \\        var r = filterNode(this, node);
        \\        while (r !== FILTER_REJECT && node.lastChild != null) {
        \\          node = node.lastChild;
        \\          r = filterNode(this, node);
        \\        }
        \\        if (r === FILTER_ACCEPT) { this._current = node; return node; }
        \\        sib = node.previousSibling;
        \\      }
        \\      if (node === this._root || node.parentNode == null) return null;
        \\      node = node.parentNode;
        \\      if (node === this._root) return null;
        \\      if (filterNode(this, node) === FILTER_ACCEPT) { this._current = node; return node; }
        \\    }
        \\    return null;
        \\  };
        \\  globalThis.TreeWalker = TreeWalker;
        \\
        \\  /* -------- NodeIterator (DOM §6.2) ------------------------- */
        \\  function NodeIterator(){
        \\    throw new TypeError("Illegal constructor");
        \\  }
        \\  var NIP = NodeIterator.prototype;
        \\  NIP.constructor = NodeIterator;
        \\  try { NIP[Symbol.toStringTag] = 'NodeIterator'; } catch(e) {}
        \\  defGet(NIP, 'root',              function(){ return this._root; });
        \\  defGet(NIP, 'whatToShow',        function(){ return this._whatToShow; });
        \\  defGet(NIP, 'filter',            function(){ return this._filter; });
        \\  defGet(NIP, 'referenceNode',     function(){ return this._ref; });
        \\  defGet(NIP, 'pointerBeforeReferenceNode', function(){ return this._before; });
        \\  NIP.detach = function(){};  /* DOM §6.2: no-op for legacy compat */
        \\
        \\  /* Traverse algorithm (§6.2) — next or prev. */
        \\  function niTraverse(iter, next){
        \\    var node = iter._ref;
        \\    var before = iter._before;
        \\    while (true) {
        \\      if (next) {
        \\        if (!before) {
        \\          /* Advance to next node in pre-order within root subtree */
        \\          if (node.firstChild) { node = node.firstChild; }
        \\          else {
        \\            var tmp = node, sib = null;
        \\            while (tmp != null && tmp !== iter._root) {
        \\              sib = tmp.nextSibling;
        \\              if (sib != null) break;
        \\              tmp = tmp.parentNode;
        \\            }
        \\            if (sib == null) return null;
        \\            node = sib;
        \\          }
        \\        } else {
        \\          before = false;
        \\        }
        \\      } else {
        \\        if (before) {
        \\          /* Walk to previous in pre-order. */
        \\          if (node === iter._root) return null;
        \\          var prev = node.previousSibling;
        \\          if (prev != null) {
        \\            node = prev;
        \\            while (node.lastChild != null) node = node.lastChild;
        \\          } else {
        \\            var p = node.parentNode;
        \\            if (p == null || p === iter._root && node === iter._root) return null;
        \\            if (p == null) return null;
        \\            node = p;
        \\            if (node === iter._root) return null;
        \\          }
        \\        } else {
        \\          before = true;
        \\        }
        \\      }
        \\      var r = filterNode(iter, node);
        \\      if (r === FILTER_ACCEPT) {
        \\        iter._ref = node;
        \\        iter._before = before;
        \\        return node;
        \\      }
        \\    }
        \\  }
        \\  NIP.nextNode     = function(){
        \\    if (this._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    return niTraverse(this, true);
        \\  };
        \\  NIP.previousNode = function(){
        \\    if (this._active) throw makeInvalidStateError('The object is in an invalid state.');
        \\    return niTraverse(this, false);
        \\  };
        \\  globalThis.NodeIterator = NodeIterator;
        \\
        \\  /* -------- NodeIterator removal tracking (DOM §6.2) ----------- */
        \\  /* Global registry of all live NodeIterators. Weak references would
        \\   * be ideal but are not universally supported; we use a plain array
        \\   * and accept that detached iterators are never GC'd from the list.
        \\   * This matches the spec's "node iterator list" on the Document. */
        \\  var _niRegistry = [];
        \\
        \\  /* DOM §6.2 "notifying iteration" algorithm.
        \\   * Called *before* the node is removed (parent still set). */
        \\  function _niNotifyRemoval(removedNode){
        \\    /* "For each NodeIterator iter:" */
        \\    for (var i = 0; i < _niRegistry.length; i++) {
        \\      var iter = _niRegistry[i];
        \\      /* "If root is not an inclusive ancestor of node, continue." */
        \\      var n = removedNode;
        \\      var inRoot = false;
        \\      while (n) {
        \\        if (n === iter._root) { inRoot = true; break; }
        \\        n = n.parentNode;
        \\      }
        \\      if (!inRoot) continue;
        \\
        \\      /* "If referenceNode is not an inclusive descendant of node, continue." */
        \\      var ref = iter._ref;
        \\      var refInNode = false;
        \\      n = ref;
        \\      while (n) {
        \\        if (n === removedNode) { refInNode = true; break; }
        \\        n = n.parentNode;
        \\      }
        \\      if (!refInNode) continue;
        \\
        \\      /* "If pointerBeforeReferenceNode is false:" */
        \\      if (!iter._before) {
        \\        /* "Set referenceNode to the first node preceding removedNode." */
        \\        var prev = _previousNode(removedNode);
        \\        if (prev) iter._ref = prev;
        \\        /* pointer stays false, done. */
        \\        continue;
        \\      }
        \\
        \\      /* "If there is a node following the last inclusive descendant:" */
        \\      var nextAfter = _nextNodeAfterSubtree(removedNode);
        \\      if (nextAfter) {
        \\        iter._ref = nextAfter;
        \\        /* pointer stays true */
        \\        continue;
        \\      }
        \\
        \\      /* "Set referenceNode to the first node preceding removedNode,
        \\       *  set pointerBeforeReferenceNode to false." */
        \\      var prev2 = _previousNode(removedNode);
        \\      if (prev2) iter._ref = prev2;
        \\      iter._before = false;
        \\    }
        \\  }
        \\
        \\  /* Return the node immediately preceding removedNode in pre-order
        \\   * (including its last inclusive descendant). */
        \\  function _previousNode(node){
        \\    var prev = node.previousSibling;
        \\    if (prev) {
        \\      while (prev.lastChild) prev = prev.lastChild;
        \\      return prev;
        \\    }
        \\    return node.parentNode || null;
        \\  }
        \\
        \\  /* Return the first node following the last inclusive descendant of
        \\   * removedNode, still within the document (i.e. nextSibling or
        \\   * ancestor's nextSibling). The removedNode has not yet been removed. */
        \\  function _nextNodeAfterSubtree(node){
        \\    /* Walk to the last inclusive descendant */
        \\    var last = node;
        \\    while (last.lastChild) last = last.lastChild;
        \\    /* Find next sibling walking up */
        \\    var cur = last;
        \\    while (cur) {
        \\      if (cur.nextSibling) return cur.nextSibling;
        \\      cur = cur.parentNode;
        \\    }
        \\    return null;
        \\  }
        \\
        \\  /* Patch removeChild to notify iterators before removal. */
        \\  (function(){
        \\    if (typeof Node === 'undefined' || !Node.prototype) return;
        \\    var _origRemoveChild = Node.prototype.removeChild;
        \\    Node.prototype.removeChild = function(child){
        \\      if (child && _niRegistry.length > 0) {
        \\        _niNotifyRemoval(child);
        \\      }
        \\      return _origRemoveChild.call(this, child);
        \\    };
        \\  })();
        \\
        \\  /* -------- document.createTreeWalker / createNodeIterator ----- */
        \\  function isNode(v){
        \\    /* Accept any object with a numeric nodeType — works across realms
        \\     * (iframes) where instanceof Node would fail. */
        \\    return v != null && typeof v === 'object' && typeof v.nodeType === 'number';
        \\  }
        \\  function createTreeWalker(root, whatToShow, filter){
        \\    if (arguments.length < 1 || !isNode(root)) {
        \\      throw new TypeError('createTreeWalker requires a Node');
        \\    }
        \\    var w = Object.create(TWP);
        \\    w._root = root;
        \\    w._current = root;
        \\    w._whatToShow = toWhatToShow(whatToShow);
        \\    w._filter = (filter === undefined || filter === null) ? null : filter;
        \\    w._active = false;
        \\    return w;
        \\  }
        \\  function createNodeIterator(root, whatToShow, filter){
        \\    if (arguments.length < 1 || !isNode(root)) {
        \\      throw new TypeError('createNodeIterator requires a Node');
        \\    }
        \\    var it = Object.create(NIP);
        \\    it._root = root;
        \\    it._ref = root;
        \\    it._before = true;
        \\    it._whatToShow = toWhatToShow(whatToShow);
        \\    it._filter = (filter === undefined || filter === null) ? null : filter;
        \\    it._active = false;
        \\    /* Register for removal notification (DOM §6.2 node iterator list). */
        \\    _niRegistry.push(it);
        \\    return it;
        \\  }
        \\  if (typeof Document !== 'undefined' && Document.prototype) {
        \\    Document.prototype.createTreeWalker = createTreeWalker;
        \\    Document.prototype.createNodeIterator = createNodeIterator;
        \\  }
        \\  try { document.createTreeWalker = createTreeWalker; } catch(e) {}
        \\  try { document.createNodeIterator = createNodeIterator; } catch(e) {}
        \\
        \\  /* Document.importNode is implemented natively (DOM §4.5) — see
        \\   * nativeImportNode in src/js/kotori_dom.zig. No JS polyfill here
        \\   * (the prior instance-level ownerDocument stamping defeated the
        \\   * per-node `_ownerDoc` slot from Task 1, DOM §4.4). */
        \\
        \\  /* ============ DocumentFragment.getElementById (§4.2.3) ====== */
        \\  /* NonElementParentNode mixin: walk descendants for matching id. */
        \\  function fragGetElementById(id){
        \\    if (id === '' || id == null) return null;
        \\    id = String(id);
        \\    var stack = [this];
        \\    while (stack.length) {
        \\      var n = stack.pop();
        \\      var kids = n.childNodes;
        \\      if (!kids) continue;
        \\      for (var i=0; i<kids.length; i++) {
        \\        var c = kids[i];
        \\        if (!c || c.nodeType !== 1) continue;
        \\        if (c.getAttribute && c.getAttribute('id') === id) return c;
        \\        stack.push(c);
        \\      }
        \\    }
        \\    return null;
        \\  }
        \\  if (typeof DocumentFragment !== 'undefined' && DocumentFragment.prototype) {
        \\    DocumentFragment.prototype.getElementById = fragGetElementById;
        \\  }
        \\  if (typeof ShadowRoot !== 'undefined' && ShadowRoot.prototype) {
        \\    if (typeof ShadowRoot.prototype.getElementById !== 'function') {
        \\      ShadowRoot.prototype.getElementById = fragGetElementById;
        \\    }
        \\  }
        \\
        \\  /* ============ createElementNS fixups (§4.5) ================= */
        \\  /* Native kotori_dom.nativeCreateElementNS now handles the full
        \\   * DOM §4.5.3 + HTML §4 dispatch (prefix/localName case
        \\   * preservation via __origLocal + per-tag HTMLElement subclass
        \\   * prototype via applyInterfaceProto). The previous JS polyfill
        \\   * un-branded every non-HTML element to Element.prototype — which
        \\   * defeated SVG/MathML subclass dispatch — and clobbered
        \\   * localName on prefixed qnames. Both concerns are now native
        \\   * responsibilities; no JS wrapper is installed.
        \\   */
        \\
        \\  /* ============ template.content (HTML §4.12.3) =============== */
        \\  /* If native Element doesn't expose .content on template elements,
        \\   * install a lazy DocumentFragment that clones template children
        \\   * into a fragment on first access.
        \\   *
        \\   * NOTE: this is minimal — real templates move their parsed
        \\   * children into the content fragment; we only provide enough to
        \\   * satisfy `template.content` being a DocumentFragment with
        \\   * the parsed children accessible. */
        \\  if (typeof Element !== 'undefined' && Element.prototype) {
        \\    /* Only install if 'content' is not already defined on any prototype. */
        \\    var hasContent = false;
        \\    try {
        \\      var proto = Element.prototype;
        \\      while (proto) {
        \\        var desc = Object.getOwnPropertyDescriptor(proto, 'content');
        \\        if (desc) { hasContent = true; break; }
        \\        proto = Object.getPrototypeOf(proto);
        \\      }
        \\    } catch(e) {}
        \\    if (!hasContent) {
        \\      Object.defineProperty(Element.prototype, 'content', {
        \\        get: function(){
        \\          var tn = this.tagName;
        \\          if (!tn || typeof tn !== 'string') return undefined;
        \\          var low = tn.toLowerCase();
        \\          if (low !== 'template') return undefined;
        \\          if (this.__templateContent) return this.__templateContent;
        \\          var frag = document.createDocumentFragment();
        \\          /* Move children into frag on first access. */
        \\          var kids = this.childNodes;
        \\          if (kids) {
        \\            var arr = [];
        \\            for (var i=0; i<kids.length; i++) arr.push(kids[i]);
        \\            for (var j=0; j<arr.length; j++) {
        \\              try { frag.appendChild(arr[j]); } catch(e){}
        \\            }
        \\          }
        \\          try {
        \\            Object.defineProperty(this, '__templateContent', {value: frag, configurable:true, enumerable:false, writable:false});
        \\          } catch(e) { this.__templateContent = frag; }
        \\          return frag;
        \\        },
        \\        configurable: true, enumerable: true
        \\      });
        \\    }
        \\  }
        \\})();
    ;

    /// DOM §4.9 attributes polyfill — spec-compliant validation + NS methods.
    ///
    /// Why this exists: kotori_dom.zig's native setAttribute(NS)/toggleAttribute
    /// do not validate qualifiedName / namespace combinations per DOM
    /// `validate and extract` (spec §1.4, §4.9.1, §4.9.3), and it ships no
    /// hasAttributeNS/getAttributeNS/removeAttributeNS, nor the Attr-node
    /// accessors getAttributeNode(NS)/setAttributeNode(NS)/removeAttributeNode.
    /// We layer those on Element.prototype from pure JS. Because native DOM
    /// property interception (`dom_get_prop`) wins over JS own-properties, we
    /// do NOT attempt to replace `element.attributes`; instead we provide
    /// spec-correct alternate accessors that carry full Attr metadata (prefix,
    /// namespaceURI, localName, ownerElement).
    ///
    /// Also extends Document.importNode to handle Attr nodes returned by our
    /// polyfilled getAttributeNodeNS (DOM §4.7 importNode + §4.9 Attr cloning).
    const attributes_polyfill_js =
        \\(function(){
        \\  if (typeof Element === 'undefined' || !Element.prototype) return;
        \\
        \\  var XMLNS_NS = 'http://www.w3.org/2000/xmlns/';
        \\  var XML_NS   = 'http://www.w3.org/XML/1998/namespace';
        \\
        \\  /* DOM §1.4 validate and extract. Returns {ns, prefix, localName}.
        \\   * Throws NamespaceError via DOMException. */
        \\  function validateAndExtract(ns, qname){
        \\    /* Step 1: If namespace is the empty string, set it to null. */
        \\    if (ns === '') ns = null;
        \\    /* Step 2: validate(qname) — qname must be non-empty. Name
        \\     * production / QName production checks are simplified to match
        \\     * productions.js: invalid_names=[""], invalid_qnames=["b:"]. */
        \\    if (qname == null || String(qname).length === 0) {
        \\      throw new DOMException('Invalid qualified name', 'InvalidCharacterError');
        \\    }
        \\    var q = String(qname);
        \\    /* Step 3: split qname at ":" */
        \\    var prefix = null, localName = q;
        \\    var colon = q.indexOf(':');
        \\    if (colon >= 0) {
        \\      prefix = q.substring(0, colon);
        \\      localName = q.substring(colon + 1);
        \\      /* QName production: both prefix and localName must be non-empty. */
        \\      if (prefix.length === 0 || localName.length === 0) {
        \\        throw new DOMException('Invalid qualified name: ' + q, 'InvalidCharacterError');
        \\      }
        \\    }
        \\    /* Step 4: prefix requires a namespace. */
        \\    if (prefix != null && ns == null) {
        \\      throw new DOMException('prefix requires a namespace', 'NamespaceError');
        \\    }
        \\    /* Step 5: xml prefix must be bound to the XML namespace. */
        \\    if (prefix === 'xml' && ns !== XML_NS) {
        \\      throw new DOMException('xml prefix must be bound to XML namespace', 'NamespaceError');
        \\    }
        \\    /* Step 6: xmlns qualifiedName or xmlns prefix ⇔ XMLNS namespace. */
        \\    if ((q === 'xmlns' || prefix === 'xmlns') !== (ns === XMLNS_NS)) {
        \\      throw new DOMException('xmlns binding mismatch', 'NamespaceError');
        \\    }
        \\    return {ns: ns, prefix: prefix, localName: localName};
        \\  }
        \\
        \\  /* Validate a qualified name per the Name production for setAttribute.
        \\   * Matches productions.js invalid_names=[""]. */
        \\  function validateName(name){
        \\    if (name == null || String(name).length === 0) {
        \\      throw new DOMException('Invalid name', 'InvalidCharacterError');
        \\    }
        \\  }
        \\
        \\  /* ─── Sidecar attribute list ─────────────────────────────────
        \\   * Because the native `element.attributes` NamedNodeMap has a
        \\   * lexbor iteration bug (skips all but the first attr) and we
        \\   * cannot replace the native property, we maintain our own list
        \\   * of Attr objects alongside it. Each wrapped setAttribute(NS) /
        \\   * toggleAttribute / removeAttribute(NS) updates the sidecar, and
        \\   * getAttributeNode(NS) reads from it. */
        \\  function sidecar(el){
        \\    var s = el.__attrList;
        \\    if (!s) {
        \\      s = [];
        \\      try {
        \\        Object.defineProperty(el, '__attrList', {
        \\          value: s, configurable: true, enumerable: false, writable: true
        \\        });
        \\      } catch(e) { el.__attrList = s; }
        \\    }
        \\    return s;
        \\  }
        \\  function findAttr(list, ns, localName){
        \\    for (var i=0; i<list.length; i++) {
        \\      var a = list[i];
        \\      if (a.namespaceURI === ns && a.localName === localName) return i;
        \\    }
        \\    return -1;
        \\  }
        \\  function findAttrByQName(list, qname){
        \\    for (var i=0; i<list.length; i++) {
        \\      if (list[i].name === qname) return i;
        \\    }
        \\    return -1;
        \\  }
        \\  function makeAttr(el, ns, prefix, localName, value){
        \\    var qn = prefix ? (prefix + ':' + localName) : localName;
        \\    var a = {};
        \\    a.namespaceURI = ns == null ? null : ns;
        \\    a.prefix = prefix == null ? null : prefix;
        \\    a.localName = localName;
        \\    a.name = qn;
        \\    a.nodeName = qn;
        \\    a.nodeType = 2;
        \\    a.specified = true;
        \\    a.ownerElement = el;
        \\    a.value = value == null ? '' : String(value);
        \\    a.nodeValue = a.value;
        \\    a.textContent = a.value;
        \\    return a;
        \\  }
        \\
        \\  /* ─── setAttribute (DOM §4.9.1) ──────────────────────────── */
        \\  var origSetAttribute = Element.prototype.setAttribute;
        \\  Element.prototype.setAttribute = function(name, value){
        \\    validateName(name);
        \\    var qn = String(name);
        \\    /* HTML documents lowercase the qualified name. kotori's
        \\     * getAttribute is already case-insensitive for HTML. */
        \\    var lcqn = qn;
        \\    var ns = this.namespaceURI;
        \\    if (ns === 'http://www.w3.org/1999/xhtml' || ns == null) {
        \\      lcqn = qn.toLowerCase();
        \\    }
        \\    var v = value == null ? '' : String(value);
        \\    /* Native call: propagate to lexbor. */
        \\    origSetAttribute.call(this, lcqn, v);
        \\    /* Sidecar: update or append. setAttribute matches by qname only
        \\     * (first-match wins per spec §4.9.1). */
        \\    var list = sidecar(this);
        \\    var idx = findAttrByQName(list, lcqn);
        \\    if (idx >= 0) {
        \\      list[idx].value = v;
        \\      list[idx].nodeValue = v;
        \\      list[idx].textContent = v;
        \\    } else {
        \\      list.push(makeAttr(this, null, null, lcqn, v));
        \\    }
        \\  };
        \\
        \\  /* ─── setAttributeNS (DOM §4.9.1) ────────────────────────── */
        \\  var origSetAttributeNS = Element.prototype.setAttributeNS;
        \\  Element.prototype.setAttributeNS = function(namespace, qname, value){
        \\    var ext = validateAndExtract(namespace, qname);
        \\    var v = value == null ? '' : String(value);
        \\    var qn = ext.prefix ? (ext.prefix + ':' + ext.localName) : ext.localName;
        \\    /* Call native setAttributeNS with the full qname (lexbor uses qname
        \\     * as key). */
        \\    origSetAttributeNS.call(this, ext.ns, qn, v);
        \\    /* Sidecar: match by (ns, localName) per spec. */
        \\    var list = sidecar(this);
        \\    var idx = findAttr(list, ext.ns, ext.localName);
        \\    if (idx >= 0) {
        \\      list[idx].value = v;
        \\      list[idx].nodeValue = v;
        \\      list[idx].textContent = v;
        \\      /* Per spec §4.9.1 step "set an attribute value": if an attr with
        \\       * (ns, localName) already exists, update value only — prefix
        \\       * stays unchanged. */
        \\    } else {
        \\      list.push(makeAttr(this, ext.ns, ext.prefix, ext.localName, v));
        \\    }
        \\  };
        \\
        \\  /* ─── removeAttribute (DOM §4.9.1) ───────────────────────── */
        \\  var origRemoveAttribute = Element.prototype.removeAttribute;
        \\  Element.prototype.removeAttribute = function(name){
        \\    var qn = String(name);
        \\    origRemoveAttribute.call(this, qn);
        \\    /* Also accept lowercased since native is case-insensitive for HTML. */
        \\    var list = sidecar(this);
        \\    var idx = findAttrByQName(list, qn);
        \\    if (idx < 0) idx = findAttrByQName(list, qn.toLowerCase());
        \\    if (idx >= 0) {
        \\      list[idx].ownerElement = null;
        \\      list.splice(idx, 1);
        \\    }
        \\  };
        \\
        \\  /* ─── removeAttributeNS (DOM §4.9.1) ─────────────────────── */
        \\  Element.prototype.removeAttributeNS = function(namespace, localName){
        \\    var ns = (namespace == null || namespace === '') ? null : String(namespace);
        \\    var ln = String(localName);
        \\    var list = sidecar(this);
        \\    var idx = findAttr(list, ns, ln);
        \\    if (idx >= 0) {
        \\      /* Call native removeAttribute with the qualified name so the
        \\       * lexbor store is kept in sync. */
        \\      var qn = list[idx].name;
        \\      origRemoveAttribute.call(this, qn);
        \\      list[idx].ownerElement = null;
        \\      list.splice(idx, 1);
        \\    }
        \\  };
        \\
        \\  /* ─── toggleAttribute (DOM §4.9.1) ───────────────────────── */
        \\  var origToggleAttribute = Element.prototype.toggleAttribute;
        \\  Element.prototype.toggleAttribute = function(name, force){
        \\    validateName(name);
        \\    var qn = String(name);
        \\    var ns = this.namespaceURI;
        \\    var lcqn = (ns === 'http://www.w3.org/1999/xhtml' || ns == null)
        \\               ? qn.toLowerCase() : qn;
        \\    var list = sidecar(this);
        \\    var idx = findAttrByQName(list, lcqn);
        \\    var has = idx >= 0;
        \\    if (!has) {
        \\      /* Cross-check native in case the sidecar is missing entries for
        \\       * attrs that existed before the polyfill was installed (parsed
        \\       * HTML). */
        \\      has = this.hasAttribute ? this.hasAttribute(lcqn) : false;
        \\    }
        \\    if (!has) {
        \\      if (force === false) return false;
        \\      /* Add with empty string value. */
        \\      origSetAttribute.call(this, lcqn, '');
        \\      if (idx < 0) list.push(makeAttr(this, null, null, lcqn, ''));
        \\      return true;
        \\    } else {
        \\      if (force === true) return true;
        \\      origRemoveAttribute.call(this, lcqn);
        \\      if (idx >= 0) { list[idx].ownerElement = null; list.splice(idx, 1); }
        \\      return false;
        \\    }
        \\  };
        \\
        \\  /* ─── hasAttributeNS (DOM §4.9.3) ────────────────────────── */
        \\  /* Spec requires exact localName match — do NOT fall back to the
        \\   * native case-insensitive hasAttribute or uppercase attrs would
        \\   * incorrectly appear in the null namespace. */
        \\  Element.prototype.hasAttributeNS = function(namespace, localName){
        \\    var ns = (namespace == null || namespace === '') ? null : String(namespace);
        \\    var ln = String(localName);
        \\    return findAttr(sidecar(this), ns, ln) >= 0;
        \\  };
        \\
        \\  /* ─── getAttributeNS (DOM §4.9.3) ────────────────────────── */
        \\  Element.prototype.getAttributeNS = function(namespace, localName){
        \\    var ns = (namespace == null || namespace === '') ? null : String(namespace);
        \\    var ln = String(localName);
        \\    var idx = findAttr(sidecar(this), ns, ln);
        \\    return idx >= 0 ? sidecar(this)[idx].value : null;
        \\  };
        \\
        \\  /* ─── getAttribute override (DOM §4.9.3) ─────────────────── */
        \\  /* Native kotori getAttribute hits lexbor which, for HTML docs,
        \\   * loses case and returns only one value when multiple namespaced
        \\   * attrs share a localName. Spec §4.9.3 getAttribute:
        \\   *   1. If element is in the HTML namespace and its node document
        \\   *      is an HTML document, lowercase qualifiedName.
        \\   *   2. Return the first attribute in attribute list whose
        \\   *      qualifiedName is qualifiedName (case-sensitive). */
        \\  function normalizeQName(el, qn){
        \\    var ns = el.namespaceURI;
        \\    if (ns === 'http://www.w3.org/1999/xhtml' || ns == null) return qn.toLowerCase();
        \\    return qn;
        \\  }
        \\  var origGetAttribute = Element.prototype.getAttribute;
        \\  Element.prototype.getAttribute = function(name){
        \\    var want = normalizeQName(this, String(name));
        \\    /* Native first (covers parsed HTML attrs AND IDL-reflection
        \\     * setters that bypass the sidecar wrapper). */
        \\    var nv = origGetAttribute.call(this, want);
        \\    if (nv !== null) return nv;
        \\    /* Sidecar fallback for attrs only our wrapper tracks (e.g.
        \\     * attr-node setters that may not hit lexbor in all cases). */
        \\    var list = sidecar(this);
        \\    for (var i=0; i<list.length; i++) {
        \\      if (list[i].name === want) return list[i].value;
        \\    }
        \\    return null;
        \\  };
        \\
        \\  /* ─── hasAttribute override ──────────────────────────────── */
        \\  var origHasAttribute = Element.prototype.hasAttribute;
        \\  Element.prototype.hasAttribute = function(name){
        \\    var want = normalizeQName(this, String(name));
        \\    if (origHasAttribute.call(this, want)) return true;
        \\    var list = sidecar(this);
        \\    for (var i=0; i<list.length; i++) {
        \\      if (list[i].name === want) return true;
        \\    }
        \\    return false;
        \\  };
        \\
        \\  /* ─── getAttributeNode / getAttributeNodeNS (DOM §4.9) ───── */
        \\  Element.prototype.getAttributeNode = function(name){
        \\    var qn = String(name);
        \\    var list = sidecar(this);
        \\    var idx = findAttrByQName(list, qn);
        \\    if (idx < 0) idx = findAttrByQName(list, qn.toLowerCase());
        \\    return idx >= 0 ? list[idx] : null;
        \\  };
        \\  Element.prototype.getAttributeNodeNS = function(namespace, localName){
        \\    var ns = (namespace == null || namespace === '') ? null : String(namespace);
        \\    var ln = String(localName);
        \\    var list = sidecar(this);
        \\    var idx = findAttr(list, ns, ln);
        \\    return idx >= 0 ? list[idx] : null;
        \\  };
        \\
        \\  /* ─── setAttributeNode / setAttributeNodeNS (DOM §4.9) ───── */
        \\  function setAttrNodeImpl(el, attr){
        \\    if (!attr || attr.nodeType !== 2) {
        \\      throw new TypeError('setAttributeNode requires an Attr');
        \\    }
        \\    if (attr.ownerElement && attr.ownerElement !== el) {
        \\      throw new DOMException('Attr in use', 'InUseAttributeError');
        \\    }
        \\    var ns = attr.namespaceURI == null ? null : attr.namespaceURI;
        \\    var list = sidecar(el);
        \\    var idx = findAttr(list, ns, attr.localName);
        \\    var oldAttr = idx >= 0 ? list[idx] : null;
        \\    if (oldAttr === attr) return attr;
        \\    /* Apply on lexbor. */
        \\    var qn = attr.prefix ? (attr.prefix + ':' + attr.localName) : attr.localName;
        \\    if (ns == null) origSetAttribute.call(el, qn, attr.value);
        \\    else origSetAttributeNS.call(el, ns, qn, attr.value);
        \\    /* Update sidecar. */
        \\    attr.ownerElement = el;
        \\    if (oldAttr) { oldAttr.ownerElement = null; list[idx] = attr; }
        \\    else list.push(attr);
        \\    return oldAttr;
        \\  }
        \\  Element.prototype.setAttributeNode   = function(a){ return setAttrNodeImpl(this, a); };
        \\  Element.prototype.setAttributeNodeNS = function(a){ return setAttrNodeImpl(this, a); };
        \\
        \\  /* ─── removeAttributeNode (DOM §4.9) ─────────────────────── */
        \\  Element.prototype.removeAttributeNode = function(attr){
        \\    if (!attr || attr.nodeType !== 2) {
        \\      throw new TypeError('removeAttributeNode requires an Attr');
        \\    }
        \\    var list = sidecar(this);
        \\    var ns = attr.namespaceURI == null ? null : attr.namespaceURI;
        \\    var idx = findAttr(list, ns, attr.localName);
        \\    if (idx < 0 || list[idx] !== attr) {
        \\      throw new DOMException('Attribute not found', 'NotFoundError');
        \\    }
        \\    var qn = attr.prefix ? (attr.prefix + ':' + attr.localName) : attr.localName;
        \\    origRemoveAttribute.call(this, qn);
        \\    attr.ownerElement = null;
        \\    list.splice(idx, 1);
        \\    return attr;
        \\  };
        \\
        \\})();
    ;

    /// CSSOM §1 — install the CSS global interface on kotori. Mirrors the
    /// QJS path at `src/js/dom_api.zig:5666` (the native CSS object bound
    /// there is only visible to QJS; kotori globals need their own polyfill).
    /// Implements CSS.supports(property, value) using a scratch element's
    /// inline-style round-trip (accepted if setProperty leaves a non-empty
    /// getPropertyValue), and CSS.escape(v) per CSSOM §6.5.1 serialization
    /// of an identifier.
    const css_global_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.CSS !== 'undefined' && globalThis.CSS.supports) return;
        \\  var CSS_obj = globalThis.CSS || {};
        \\  /* CSS.supports(property, value) OR CSS.supports("property: value") */
        \\  CSS_obj.supports = function(prop, value){
        \\    try {
        \\      var p, v;
        \\      if (value === undefined) {
        \\        /* Condition form: "property: value" */
        \\        var s = String(prop);
        \\        var i = s.indexOf(':');
        \\        if (i < 0) return false;
        \\        p = s.substring(0, i).trim();
        \\        v = s.substring(i + 1).trim();
        \\      } else {
        \\        p = String(prop);
        \\        v = String(value);
        \\      }
        \\      if (!p) return false;
        \\      var el = document.createElement('div');
        \\      try { el.style.setProperty(p, v); } catch (e) { return false; }
        \\      var back = '';
        \\      try { back = el.style.getPropertyValue(p); } catch (e) { back = ''; }
        \\      return back !== '' && back !== null && back !== undefined;
        \\    } catch (e) {
        \\      return false;
        \\    }
        \\  };
        \\  /* CSS.escape(v) per CSSOM §6.5.1 */
        \\  CSS_obj.escape = function(v){
        \\    v = String(v);
        \\    if (!v.length) return '';
        \\    var r = '', i = 0, c;
        \\    if (v.length === 1 && v.charCodeAt(0) === 0) return '\uFFFD';
        \\    for (; i < v.length; i++) {
        \\      c = v.charCodeAt(i);
        \\      if (c === 0) r += '\uFFFD';
        \\      else if ((c >= 1 && c <= 31) || c === 127 ||
        \\               (i === 0 && c >= 48 && c <= 57) ||
        \\               (i === 1 && c >= 48 && c <= 57 && v.charCodeAt(0) === 45)) {
        \\        r += '\\' + c.toString(16) + ' ';
        \\      } else if (i === 0 && c === 45 && v.length === 1) {
        \\        r += '\\' + v.charAt(i);
        \\      } else if (c >= 128 || c === 45 || c === 95 ||
        \\                 (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
        \\                 (c >= 97 && c <= 122)) {
        \\        r += v.charAt(i);
        \\      } else {
        \\        r += '\\' + v.charAt(i);
        \\      }
        \\    }
        \\    return r;
        \\  };
        \\  globalThis.CSS = CSS_obj;
        \\})();
    ;

    /// CSSOM §6.4 — Constructable CSSStyleSheet polyfill for kotori.
    /// Provides: new CSSStyleSheet(opts), replaceSync(text), replace(text),
    /// document.adoptedStyleSheets getter/setter, shadowRoot.adoptedStyleSheets.
    /// Mirrors the QJS cssom_js block in dom_api.zig which only runs in the
    /// QuickJS context.
    const cssom_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.CSSStyleSheet !== 'undefined' && globalThis.CSSStyleSheet._constructed_polyfill) return;
        \\  // MediaList minimal impl
        \\  function _MediaList(mediaStr){
        \\    this._items=mediaStr?mediaStr.split(',').map(function(s){return s.trim();}).filter(function(s){return s.length>0;}):[];
        \\    this.mediaText=this._items.join(', ');
        \\  }
        \\  Object.defineProperty(_MediaList.prototype,'length',{get:function(){return this._items.length;},enumerable:true,configurable:true});
        \\  _MediaList.prototype.item=function(i){return this._items[i>>>0]||null;};
        \\  _MediaList.prototype.toString=function(){return this.mediaText;};
        \\  // ── CSSRule hierarchy (CSSOM §6.4) ──
        \\  function _CSSRuleBase(){}
        \\  // Expose Object.prototype methods explicitly so 'in' operator finds them (kotori setPrototypeOf compat)
        \\  _CSSRuleBase.prototype.hasOwnProperty=function(p){return Object.prototype.hasOwnProperty.call(this,p);};
        \\  _CSSRuleBase.prototype.UNKNOWN_RULE=0;_CSSRuleBase.prototype.STYLE_RULE=1;_CSSRuleBase.prototype.CHARSET_RULE=2;_CSSRuleBase.prototype.IMPORT_RULE=3;
        \\  _CSSRuleBase.prototype.MEDIA_RULE=4;_CSSRuleBase.prototype.FONT_FACE_RULE=5;_CSSRuleBase.prototype.PAGE_RULE=6;
        \\  _CSSRuleBase.prototype.KEYFRAMES_RULE=7;_CSSRuleBase.prototype.KEYFRAME_RULE=8;_CSSRuleBase.prototype.MARGIN_RULE=9;
        \\  _CSSRuleBase.prototype.NAMESPACE_RULE=10;_CSSRuleBase.prototype.COUNTER_STYLE_RULE=11;_CSSRuleBase.prototype.SUPPORTS_RULE=12;
        \\  Object.defineProperty(_CSSRuleBase.prototype,'parentRule',{get:function(){return this._parentRule||null;},enumerable:true,configurable:true});
        \\  Object.defineProperty(_CSSRuleBase.prototype,'parentStyleSheet',{get:function(){return this._parentStyleSheet||null;},enumerable:true,configurable:true});
        \\  Object.defineProperty(_CSSRuleBase.prototype,'type',{get:function(){return this._type||0;},enumerable:true,configurable:true});
        \\  globalThis.CSSRule=_CSSRuleBase;
        \\  globalThis.CSSRule.UNKNOWN_RULE=0;globalThis.CSSRule.STYLE_RULE=1;globalThis.CSSRule.CHARSET_RULE=2;globalThis.CSSRule.IMPORT_RULE=3;
        \\  globalThis.CSSRule.MEDIA_RULE=4;globalThis.CSSRule.FONT_FACE_RULE=5;globalThis.CSSRule.PAGE_RULE=6;
        \\  globalThis.CSSRule.KEYFRAMES_RULE=7;globalThis.CSSRule.KEYFRAME_RULE=8;globalThis.CSSRule.MARGIN_RULE=9;
        \\  globalThis.CSSRule.NAMESPACE_RULE=10;globalThis.CSSRule.COUNTER_STYLE_RULE=11;globalThis.CSSRule.SUPPORTS_RULE=12;
        \\  function _CSSGroupingRuleBase(){}
        \\  Object.setPrototypeOf(_CSSGroupingRuleBase.prototype,_CSSRuleBase.prototype);
        \\  _CSSGroupingRuleBase.prototype.insertRule=function(rule,index){
        \\    if(index===void 0)index=this.cssRules.length;
        \\    if(index<0||index>this.cssRules.length)throw new DOMException('Index out of bounds','IndexSizeError');
        \\    var parsed=_parseStyleRulesK(rule);if(!parsed.length)throw new DOMException('Invalid rule','SyntaxError');
        \\    this.cssRules.splice(index,0,parsed[0]);return index;
        \\  };
        \\  _CSSGroupingRuleBase.prototype.deleteRule=function(index){
        \\    if(index<0||index>=this.cssRules.length)throw new DOMException('Index out of bounds','IndexSizeError');
        \\    this.cssRules.splice(index,1);
        \\  };
        \\  globalThis.CSSGroupingRule=_CSSGroupingRuleBase;
        \\  function _CSSConditionRuleBase(){}
        \\  Object.setPrototypeOf(_CSSConditionRuleBase.prototype,_CSSGroupingRuleBase.prototype);
        \\  Object.defineProperty(_CSSConditionRuleBase.prototype,'conditionText',{get:function(){return this._conditionText||'';},set:function(){},enumerable:true,configurable:true});
        \\  globalThis.CSSConditionRule=_CSSConditionRuleBase;
        \\  function _CSSMediaRuleImpl(mediaText,innerRules){
        \\    this._type=4;this._conditionText=mediaText||'';this.cssRules=_addItem(innerRules||[]);
        \\    this.media=new _MediaList(mediaText);
        \\  }
        \\  Object.setPrototypeOf(_CSSMediaRuleImpl.prototype,_CSSConditionRuleBase.prototype);
        \\  Object.defineProperty(_CSSMediaRuleImpl.prototype,'cssText',{get:function(){
        \\    var inner='';for(var i=0;i<this.cssRules.length;i++)inner+='\n  '+this.cssRules[i].cssText;
        \\    return '@media '+this._conditionText+' {'+inner+'\n}';
        \\  },enumerable:true,configurable:true});
        \\  globalThis.CSSMediaRule=_CSSMediaRuleImpl;
        \\  function _CSSSupportsRuleImpl(condText,innerRules){
        \\    this._type=12;this._conditionText=condText||'';this.cssRules=_addItem(innerRules||[]);
        \\  }
        \\  Object.setPrototypeOf(_CSSSupportsRuleImpl.prototype,_CSSConditionRuleBase.prototype);
        \\  Object.defineProperty(_CSSSupportsRuleImpl.prototype,'cssText',{get:function(){
        \\    var inner='';for(var i=0;i<this.cssRules.length;i++)inner+='\n  '+this.cssRules[i].cssText;
        \\    return '@supports '+this._conditionText+' {'+inner+'\n}';
        \\  },enumerable:true,configurable:true});
        \\  globalThis.CSSSupportsRule=_CSSSupportsRuleImpl;
        \\  // CSSStyleRule
        \\  function CSSStyleRule(sel,body,children){
        \\    this._type=1;this._sel=sel;this._body=body||'';this.cssRules=_addItem(children||[]);
        \\  }
        \\  Object.setPrototypeOf(CSSStyleRule.prototype,_CSSGroupingRuleBase.prototype);
        \\  Object.defineProperty(CSSStyleRule.prototype,'selectorText',{
        \\    get:function(){return this._sel;},
        \\    set:function(v){var c=v.replace(/\/\*[\s\S]*?\*\//g,' ').trim();try{document.querySelector(c);this._sel=c;}catch(e){}},
        \\    enumerable:true,configurable:true
        \\  });
        \\  Object.defineProperty(CSSStyleRule.prototype,'cssText',{
        \\    get:function(){return this._sel+' { '+this._body+' }';},
        \\    enumerable:true,configurable:true
        \\  });
        \\  // style: [SameObject,PutForwards=cssText] — getter returns same proxy, setter forwards to cssText
        \\  Object.defineProperty(CSSStyleRule.prototype,'style',{
        \\    get:function(){return this._style;},
        \\    set:function(v){if(this._style)this._style.cssText=v;},
        \\    enumerable:true,configurable:true
        \\  });
        \\  globalThis.CSSStyleRule=CSSStyleRule;
        \\  // CSSStyleDeclaration stub (actual style objects are Proxy-based, see _makeStyle)
        \\  if(typeof CSSStyleDeclaration==='undefined'){globalThis.CSSStyleDeclaration=function CSSStyleDeclaration(){};}
        \\  // CSSNestedDeclarations stub
        \\  if(typeof CSSNestedDeclarations==='undefined'){globalThis.CSSNestedDeclarations=function CSSNestedDeclarations(decls){this._type=32;this._decls=decls||'';};}
        \\  // Minimal CSSStyleDeclaration-like object with individual property access
        \\  // Note: kotori does not support s[i] string indexing; use s.charAt(i)
        \\  function _parseDecls(text){
        \\    var entries={},pos=0,len=text?text.length:0;
        \\    while(pos<len){
        \\      var ch;
        \\      ch=text.charAt(pos);while(pos<len&&(ch===' '||ch==='\t'||ch==='\r'||ch==='\n')){pos++;ch=text.charAt(pos);}
        \\      if(pos>=len)break;
        \\      var ns=pos;
        \\      ch=text.charAt(pos);while(pos<len&&ch!==':'&&ch!==';'){pos++;ch=text.charAt(pos);}
        \\      if(pos>=len||ch!==':'){ch=text.charAt(pos);while(pos<len&&ch!==';'){pos++;ch=text.charAt(pos);}if(pos<len)pos++;continue;}
        \\      var nm=text.substring(ns,pos).trim().toLowerCase();pos++;
        \\      var vs=pos;
        \\      ch=text.charAt(pos);while(pos<len&&ch!==';'){pos++;ch=text.charAt(pos);}
        \\      var val=text.substring(vs,pos).trim().replace(/\s*!important\s*$/i,'').trim();
        \\      if(nm&&val)entries[nm]=val;
        \\      if(pos<len)pos++;
        \\    }
        \\    return entries;
        \\  }
        \\  function _declsToText(decls){
        \\    var parts=[];
        \\    var keys=Object.keys(decls);
        \\    for(var i=0;i<keys.length;i++){if(decls[keys[i]])parts.push(keys[i]+': '+decls[keys[i]]);}
        \\    return parts.join('; ');
        \\  }
        \\  function _makeStyle(declText){
        \\    var decls=_parseDecls(declText);
        \\    // target holds __rule back-ref (set by rule creation code)
        \\    var target=Object.create(CSSStyleDeclaration.prototype);
        \\    target.__rule=null;target.__sheet=null;
        \\    target.cssText=declText;
        \\    // Copy each parsed declaration onto target for direct property access
        \\    var keys=Object.keys(decls);
        \\    for(var ki=0;ki<keys.length;ki++){target[keys[ki]]=decls[keys[ki]];}
        \\    var proxy=new Proxy(target,{
        \\      set:function(t,k,v){
        \\        if(k==='cssText'){
        \\          // PutForwards: reparse entire declaration block
        \\          var newDecls=_parseDecls(v||'');
        \\          // Clear old keys from target
        \\          var oldKeys=Object.keys(decls);
        \\          for(var _oi=0;_oi<oldKeys.length;_oi++){delete t[oldKeys[_oi]];delete decls[oldKeys[_oi]];}
        \\          // Copy new keys
        \\          var newKeys=Object.keys(newDecls);
        \\          for(var _ni=0;_ni<newKeys.length;_ni++){decls[newKeys[_ni]]=newDecls[newKeys[_ni]];t[newKeys[_ni]]=newDecls[newKeys[_ni]];}
        \\          t.cssText=_declsToText(decls);
        \\          if(t.__rule){t.__rule._body=t.cssText;}
        \\          if(t.__sheet)_syncSheetAdopters(t.__sheet);
        \\          return true;
        \\        }
        \\        t[k]=v;
        \\        if(typeof k==='string'&&k!=='__rule'&&k!=='__sheet'){
        \\          var kb=k.replace(/([A-Z])/g,function(m){return '-'+m.toLowerCase();});
        \\          decls[kb]=v;
        \\          t.cssText=_declsToText(decls);
        \\          if(t.__rule){t.__rule._body=t.cssText;}
        \\          if(t.__sheet)_syncSheetAdopters(t.__sheet);
        \\        }
        \\        return true;
        \\      },
        \\      get:function(t,k){
        \\        if(k==='getPropertyValue')return function(n){return decls[n.toLowerCase()]||'';};
        \\        if(k==='setProperty')return function(n,v){
        \\          var kb=n.toLowerCase();decls[kb]=v;t[kb]=v;
        \\          t.cssText=_declsToText(decls);
        \\          if(t.__rule){t.__rule._body=t.cssText;}
        \\          if(t.__sheet)_syncSheetAdopters(t.__sheet);
        \\        };
        \\        if(k==='removeProperty')return function(n){
        \\          var kb=n.toLowerCase();delete decls[kb];delete t[kb];
        \\          t.cssText=_declsToText(decls);
        \\          if(t.__rule){t.__rule._body=t.cssText;}
        \\          if(t.__sheet)_syncSheetAdopters(t.__sheet);
        \\        };
        \\        return t[k];
        \\      },
        \\      getPrototypeOf:function(t){return CSSStyleDeclaration.prototype;}
        \\    });
        \\    return proxy;
        \\  }
        \\  // CSS rule parsers (minimal, for replaceSync/replace/insertRule)
        \\  // Uses charAt() not [] indexing (kotori string-index limitation)
        \\  // kotori bug: String.indexOf(ch,from) ignores from — use substring workaround
        \\  function _idxOf(s,ch,from){var t=s.substring(from).indexOf(ch);return t===-1?-1:from+t;}
        \\  function _parseAtRuleK(atHead,innerBody){
        \\    var m=atHead.match(/^@(media|supports)\s*([\s\S]*)$/i);
        \\    if(!m)return null;
        \\    var keyword=m[1].toLowerCase(),cond=m[2].trim();
        \\    var innerRules=_parseStyleRulesK(innerBody);
        \\    if(keyword==='media')return new _CSSMediaRuleImpl(cond,innerRules);
        \\    if(keyword==='supports')return new _CSSSupportsRuleImpl(cond,innerRules);
        \\    return null;
        \\  }
        \\  function _parseStyleRulesK(css){
        \\    var rules=[],i=0,clen=css.length;
        \\    while(i<clen){
        \\      var ch=css.charAt(i);
        \\      while(i<clen&&(ch===' '||ch==='\n'||ch==='\r'||ch==='\t')){i++;ch=css.charAt(i);}
        \\      if(i>=clen)break;
        \\      if(ch==='@'){
        \\        var si2=_idxOf(css,';',i),bi2=_idxOf(css,'{',i);
        \\        if(bi2===-1||(si2!==-1&&si2<bi2)){i=si2===-1?clen:si2+1;continue;}
        \\        var atHead2=css.substring(i,bi2).replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\        var d=1,j=bi2+1;while(j<clen&&d>0){var cj=css.charAt(j);if(cj==='{')d++;if(cj==='}')d--;j++;}
        \\        var innerBody2=css.substring(bi2+1,j-1).trim();
        \\        var atRule=_parseAtRuleK(atHead2,innerBody2);
        \\        if(atRule)rules.push(atRule);
        \\        i=j;continue;
        \\      }
        \\      var bi=_idxOf(css,'{',i);if(bi===-1)break;
        \\      var sel=css.substring(i,bi).replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\      var d2=1,j2=bi+1;while(j2<clen&&d2>0){var cj2=css.charAt(j2);if(cj2==='{')d2++;if(cj2==='}')d2--;j2++;}
        \\      var body=css.substring(bi+1,j2-1).trim();
        \\      if(sel){var r=new CSSStyleRule(sel,body,[]);r._style=_makeStyle(body);r._style.__rule=r;rules.push(r);}
        \\      i=j2;
        \\    }
        \\    return rules;
        \\  }
        \\  // Adopted sheet style injection via a hidden <style> element
        \\  var _adoptedElem=new WeakMap();
        \\  function _sheetCSS(sheet){
        \\    if(sheet.disabled)return '';
        \\    var css='';
        \\    for(var i=0;i<sheet.cssRules.length;i++){var r=sheet.cssRules[i];if(r.cssText)css+=r.cssText+'\n';}
        \\    return css;
        \\  }
        \\  function _getAdoptedNode(root){
        \\    var el=_adoptedElem.get(root);
        \\    if(!el){
        \\      el=document.createElement('style');
        \\      el.setAttribute('data-adopted','1');
        \\      if(root===document){document.head?document.head.appendChild(el):document.documentElement.appendChild(el);}
        \\      else if(root&&root.appendChild){root.appendChild(el);}
        \\      _adoptedElem.set(root,el);
        \\    }
        \\    return el;
        \\  }
        \\  function _syncAdopted(root){
        \\    var sheets=root._adoptedStyleSheets||[];
        \\    if(sheets.length===0){var el=_adoptedElem.get(root);if(el&&el.parentNode)el.parentNode.removeChild(el);_adoptedElem.delete(root);return;}
        \\    var css='';
        \\    for(var i=0;i<sheets.length;i++){css+=_sheetCSS(sheets[i]);}
        \\    _getAdoptedNode(root).textContent=css;
        \\  }
        \\  function _syncSheetAdopters(sheet){
        \\    if(sheet._adopters){for(var i=0;i<sheet._adopters.length;i++)_syncAdopted(sheet._adopters[i]);}
        \\  }
        \\  // CSSOM §6.4.1: constructable CSSStyleSheet
        \\  function CSSStyleSheet(opts){
        \\    this.cssRules=_addItem([]);
        \\    this.type='text/css';
        \\    this.ownerNode=null;
        \\    this.ownerRule=null;
        \\    this.parentStyleSheet=null;
        \\    this.href=null;
        \\    this.title=null;
        \\    this._constructed=true;
        \\    this._adopters=[];
        \\    if(opts&&typeof opts==='object'){
        \\      this.disabled=opts.disabled===true;
        \\      this.media=new _MediaList(typeof opts.media==='string'?opts.media:'');
        \\    }else{
        \\      this.disabled=false;
        \\      this.media=new _MediaList('');
        \\    }
        \\  }
        \\  CSSStyleSheet._constructed_polyfill=true;
        \\  // insertRule — @import throws SyntaxError
        \\  CSSStyleSheet.prototype.insertRule=function(rule,index){
        \\    if(index===void 0)index=0;
        \\    var rt=rule.replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\    if(/^@import\b/i.test(rt))throw new DOMException("@import rules are not allowed in constructed stylesheets.",'SyntaxError');
        \\    var rules=_parseStyleRulesK(rule);
        \\    if(!rules.length)throw new DOMException("Invalid rule",'SyntaxError');
        \\    if(index<0||index>this.cssRules.length)throw new DOMException("Index out of bounds",'IndexSizeError');
        \\    this.cssRules.splice(index,0,rules[0]);
        \\    _linkRules([rules[0]],this);
        \\    _syncSheetAdopters(this);
        \\    return index;
        \\  };
        \\  CSSStyleSheet.prototype.deleteRule=function(index){
        \\    if(index<0||index>=this.cssRules.length)throw new DOMException("Index out of bounds",'IndexSizeError');
        \\    this.cssRules.splice(index,1);
        \\    _syncSheetAdopters(this);
        \\  };
        \\  // Mutate array in-place to preserve [SameObject] identity of cssRules
        \\  // Note: arr.length=0 does not work in kotori; use splice instead
        \\  function _replaceRules(arr,newRules){arr.splice(0,arr.length);for(var i=0;i<newRules.length;i++)arr.push(newRules[i]);}
        \\  // Set __rule, __sheet back-refs on style proxy and _parentStyleSheet on rules
        \\  function _linkRules(rules,sheet){
        \\    for(var i=0;i<rules.length;i++){
        \\      var r=rules[i];
        \\      if(r){r._parentStyleSheet=sheet;if(r._style){r._style.__rule=r;r._style.__sheet=sheet;}}
        \\    }
        \\  }
        \\  // Add .item() to a plain cssRules array (CSSRuleList interface)
        \\  function _addItem(arr){if(!arr.item)arr.item=function(i){i=i>>>0;return i<this.length?this[i]:null;};return arr;}
        \\  // CSSOM §6.4.2: replaceSync
        \\  CSSStyleSheet.prototype.replaceSync=function(css){
        \\    if(!this._constructed)throw new DOMException("replaceSync can only be called on constructed CSSStyleSheet.",'NotAllowedError');
        \\    _replaceRules(this.cssRules,_parseStyleRulesK(css));
        \\    _linkRules(this.cssRules,this);
        \\    _syncSheetAdopters(this);
        \\  };
        \\  // CSSOM §6.4.3: replace
        \\  CSSStyleSheet.prototype.replace=function(css){
        \\    if(!this._constructed)return Promise.reject(new DOMException("replace can only be called on constructed CSSStyleSheet.",'NotAllowedError'));
        \\    _replaceRules(this.cssRules,_parseStyleRulesK(css));
        \\    _linkRules(this.cssRules,this);
        \\    _syncSheetAdopters(this);
        \\    return Promise.resolve(this);
        \\  };
        \\  globalThis.CSSStyleSheet=CSSStyleSheet;
        \\  // _validateSheets: throw TypeError/NotAllowedError if any value is not a constructed CSSStyleSheet.
        \\  function _validateSheets(items){
        \\    for(var i=0;i<items.length;i++){
        \\      var s=items[i];
        \\      if(typeof s!=='object'||s===null||!(s instanceof CSSStyleSheet))throw new TypeError('Each member of adoptedStyleSheets must be a CSSStyleSheet.');
        \\      if(!s._constructed)throw new DOMException('Each member of adoptedStyleSheets must be a constructed CSSStyleSheet.','NotAllowedError');
        \\    }
        \\  }
        \\  // _makeObservableArray: override push/pop/splice/etc. on the array
        \\  // instance so mutations trigger _syncAdopted(root). Avoids Proxy since
        \\  // kotori Proxy traps cannot forward t[numericKey] reliably.
        \\  function _makeObservableArray(arr,root){
        \\    var _push=arr.push.bind(arr),_pop=arr.pop.bind(arr),_shift=arr.shift.bind(arr);
        \\    var _unshift=arr.unshift.bind(arr),_splice=arr.splice.bind(arr);
        \\    var _reverse=arr.reverse.bind(arr),_sort=arr.sort.bind(arr),_fill=arr.fill.bind(arr);
        \\    arr.push=function(){_validateSheets(arguments);var r=_push.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.pop=function(){var r=_pop.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.shift=function(){var r=_shift.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.unshift=function(){_validateSheets(arguments);var r=_unshift.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.splice=function(){
        \\      var inserts=Array.prototype.slice.call(arguments,2);
        \\      if(inserts.length>0)_validateSheets(inserts);
        \\      var r=_splice.apply(arr,arguments);_syncAdopted(root);return r;
        \\    };
        \\    arr.reverse=function(){var r=_reverse.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.sort=function(){var r=_sort.apply(arr,arguments);_syncAdopted(root);return r;};
        \\    arr.fill=function(){
        \\      var inserts=Array.prototype.slice.call(arguments,0,1);
        \\      if(inserts.length>0)_validateSheets(inserts);
        \\      var r=_fill.apply(arr,arguments);_syncAdopted(root);return r;
        \\    };
        \\    return arr;
        \\  }
        \\  // document.adoptedStyleSheets getter/setter (CSSOM §6.5)
        \\  if(!document._adoptedStyleSheets)document._adoptedStyleSheets=_makeObservableArray([],document);
        \\  Object.defineProperty(document,'adoptedStyleSheets',{
        \\    get:function(){return this._adoptedStyleSheets;},
        \\    set:function(list){
        \\      var arr=Array.isArray(list)?list:Array.from(list);
        \\      for(var i=0;i<arr.length;i++){
        \\        if(!(arr[i] instanceof CSSStyleSheet)||!arr[i]._constructed)
        \\          throw new DOMException('Each member of adoptedStyleSheets must be a constructed CSSStyleSheet.','NotAllowedError');
        \\      }
        \\      var old=this._adoptedStyleSheets||[];
        \\      for(var i=0;i<old.length;i++){var idx=old[i]._adopters.indexOf(this);if(idx>=0)old[i]._adopters.splice(idx,1);}
        \\      var root=this;
        \\      this._adoptedStyleSheets=_makeObservableArray(arr,root);
        \\      for(var i=0;i<arr.length;i++){if(arr[i]._adopters.indexOf(this)<0)arr[i]._adopters.push(this);}
        \\      _syncAdopted(this);
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // CSSOM §6.5: Element.prototype.sheet — returns a CSSStyleSheet for <style>
        \\  // elements; undefined for others. Mirrors QJS dom_api.zig element.sheet getter.
        \\  // WeakMap: style-element → CSSStyleSheet (non-constructed, ownerNode=elem)
        \\  var _sheetMap=new WeakMap();
        \\  function _parseBodyK(body){
        \\    var decls='',children=[],pendingDecls='',i=0;
        \\    while(i<body.length){
        \\      while(i<body.length&&' \n\r\t'.indexOf(body.charAt(i))!==-1)i++;
        \\      if(i>=body.length)break;
        \\      if(body.charAt(i)==='@'){var bi3=_idxOf(body,'{',i);if(bi3===-1)break;var d3=1,j3=bi3+1;while(j3<body.length&&d3>0){if(body.charAt(j3)==='{')d3++;if(body.charAt(j3)==='}')d3--;j3++;}i=j3;continue;}
        \\      var bi4=_idxOf(body,'{',i);var si4=_idxOf(body,';',i);
        \\      if(bi4!==-1&&(si4===-1||bi4<si4)){
        \\        var sel4=body.substring(i,bi4).replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\        var d4=1,j4=bi4+1;while(j4<body.length&&d4>0){if(body.charAt(j4)==='{')d4++;if(body.charAt(j4)==='}')d4--;j4++;}
        \\        var inner4=body.substring(bi4+1,j4-1).trim();
        \\        if(pendingDecls){var pdR=new CSSStyleRule('',pendingDecls,[]);pdR._style=_makeStyle(pendingDecls);pdR._style.__rule=pdR;children.push(pdR);pendingDecls='';}
        \\        if(sel4){var inn4=_parseBodyK(inner4);var r4=new CSSStyleRule(sel4,inn4.decls,inn4.children);r4._style=_makeStyle(inn4.decls);r4._style.__rule=r4;children.push(r4);}
        \\        i=j4;
        \\      }else if(si4!==-1){
        \\        var d5=body.substring(i,si4+1).trim();
        \\        if(d5){if(children.length===0)decls+=(decls?' ':'')+d5;else pendingDecls+=(pendingDecls?' ':'')+d5;}
        \\        i=si4+1;
        \\      }else{
        \\        var d6=body.substring(i).trim();
        \\        if(d6){if(children.length===0)decls+=(decls?' ':'')+d6;else pendingDecls+=(pendingDecls?' ':'')+d6;}
        \\        break;
        \\      }
        \\    }
        \\    return{decls:decls,children:children};
        \\  }
        \\  function _parseSheetRules(css){
        \\    var rules=[],i=0,clen=css.length;
        \\    while(i<clen){
        \\      var ch=css.charAt(i);
        \\      while(i<clen&&(ch===' '||ch==='\n'||ch==='\r'||ch==='\t')){i++;ch=css.charAt(i);}
        \\      if(i>=clen)break;
        \\      if(ch==='@'){
        \\        var si2=_idxOf(css,';',i),bi2=_idxOf(css,'{',i);
        \\        if(bi2===-1||(si2!==-1&&si2<bi2)){
        \\          i=si2===-1?clen:si2+1;continue;
        \\        }
        \\        var atHead2=css.substring(i,bi2).replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\        var d=1,j=bi2+1;while(j<clen&&d>0){var cj=css.charAt(j);if(cj==='{')d++;if(cj==='}')d--;j++;}
        \\        var innerBody2=css.substring(bi2+1,j-1).trim();
        \\        var atRule=_parseAtRuleK(atHead2,innerBody2);
        \\        if(atRule)rules.push(atRule);
        \\        i=j;continue;
        \\      }
        \\      var bi=_idxOf(css,'{',i);if(bi===-1)break;
        \\      var sel=css.substring(i,bi).replace(/\/\*[\s\S]*?\*\//g,' ').trim();
        \\      var d2=1,j2=bi+1;while(j2<clen&&d2>0){var cj2=css.charAt(j2);if(cj2==='{')d2++;if(cj2==='}')d2--;j2++;}
        \\      var body=css.substring(bi+1,j2-1).trim();
        \\      if(sel){var parsed=_parseBodyK(body);var r2=new CSSStyleRule(sel,parsed.decls,parsed.children);r2._style=_makeStyle(parsed.decls);r2._style.__rule=r2;rules.push(r2);}
        \\      i=j2;
        \\    }
        \\    return rules;
        \\  }
        \\  Object.defineProperty(Element.prototype,'sheet',{get:function(){
        \\    if(!this.tagName||this.tagName.toUpperCase()!=='STYLE')return null;
        \\    var sh=_sheetMap.get(this);
        \\    if(!sh){
        \\      sh=new CSSStyleSheet();
        \\      sh._constructed=false;
        \\      sh.ownerNode=this;
        \\      _sheetMap.set(this,sh);
        \\      sh._lastText=null;
        \\    }
        \\    var txt=this.textContent||'';
        \\    if(txt!==sh._lastText){
        \\      var newRules=_parseSheetRules(txt);
        \\      sh.cssRules.splice(0,sh.cssRules.length);
        \\      for(var _i=0;_i<newRules.length;_i++)sh.cssRules.push(newRules[_i]);
        \\      _addItem(sh.cssRules);
        \\      _linkRules(sh.cssRules,sh);
        \\      sh._lastText=txt;
        \\    }
        \\    return sh;
        \\  },configurable:true,enumerable:true});
        \\  // CSSOM §6.5: document.styleSheets — returns a StyleSheetList of all
        \\  // <style> elements' sheets (excludes adopted sheets injected with data-adopted=1).
        \\  // Uses getElementsByTagName (patched to return plain JS array) for iteration.
        \\  Object.defineProperty(document,'styleSheets',{get:function(){
        \\    var styles=document.getElementsByTagName('style');
        \\    var sheets=[];
        \\    for(var i=0;i<styles.length;i++){
        \\      var el=styles[i];
        \\      if(!el)continue;
        \\      if(el.getAttribute&&el.getAttribute('data-adopted')==='1')continue;
        \\      var sh=el.sheet;if(sh)sheets.push(sh);
        \\    }
        \\    sheets.item=function(i){return this[i>>>0]||null;};
        \\    return sheets;
        \\  },configurable:true,enumerable:true});
        \\  // ShadowRoot: adoptedStyleSheets + styleSheets via single attachShadow patch
        \\  var _origAS=Element.prototype.attachShadow;
        \\  if(_origAS){
        \\    Element.prototype.attachShadow=function(init){
        \\      var sr=_origAS.call(this,init);
        \\      if(sr){
        \\        if(!Object.getOwnPropertyDescriptor(sr,'adoptedStyleSheets')){
        \\          var srRef=sr;
        \\          sr._adoptedStyleSheets=_makeObservableArray([],srRef);
        \\          Object.defineProperty(sr,'adoptedStyleSheets',{
        \\            get:function(){return this._adoptedStyleSheets;},
        \\            set:function(list){
        \\              var arr=Array.isArray(list)?list:Array.from(list);
        \\              for(var i=0;i<arr.length;i++){
        \\                if(!(arr[i] instanceof CSSStyleSheet)||!arr[i]._constructed)
        \\                  throw new DOMException('Each member of adoptedStyleSheets must be a constructed CSSStyleSheet.','NotAllowedError');
        \\              }
        \\              var old=this._adoptedStyleSheets||[];
        \\              for(var i=0;i<old.length;i++){var idx2=old[i]._adopters.indexOf(this);if(idx2>=0)old[i]._adopters.splice(idx2,1);}
        \\              var root2=this;
        \\              this._adoptedStyleSheets=_makeObservableArray(arr,root2);
        \\              for(var i=0;i<arr.length;i++){if(arr[i]._adopters.indexOf(this)<0)arr[i]._adopters.push(this);}
        \\              _syncAdopted(this);
        \\            },
        \\            configurable:true,enumerable:true
        \\          });
        \\        }
        \\        if(!Object.getOwnPropertyDescriptor(sr,'styleSheets')){
        \\          Object.defineProperty(sr,'styleSheets',{get:function(){
        \\            var root=this;
        \\            var styles=root.getElementsByTagName?root.getElementsByTagName('style'):(root.querySelectorAll?root.querySelectorAll('style'):[]);
        \\            var sheets=[];
        \\            for(var i=0;i<styles.length;i++){
        \\              var el=styles[i];
        \\              if(!el)continue;
        \\              if(el.getAttribute&&el.getAttribute('data-adopted')==='1')continue;
        \\              var sh=el.sheet;if(sh)sheets.push(sh);
        \\            }
        \\            sheets.item=function(i){return this[i>>>0]||null;};
        \\            return sheets;
        \\          },configurable:true,enumerable:true});
        \\        }
        \\      }
        \\      return sr;
        \\    };
        \\  }
        \\})();
    ;

    /// DOM §3.1 — AbortController / AbortSignal polyfill. Self-contained
    /// mini-EventTarget (uses an internal `_evtMap`, not suzume's native
    /// addEventListener) because the kotori native path stores listener
    /// records keyed by DOM node pointers / standalone EventTarget `_et_ptr`.
    /// AbortSignal is a plain JS object that the native
    /// `nativeAddEventListener` hook (kotori_dom.zig) calls
    /// `.addEventListener('abort', handler, {once:true})` on to register the
    /// abort step (DOM §2.7.1 step 5). Mirrors the QJS polyfill at
    /// `src/js/web_api.zig:2677-2691`.
    const abort_controller_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.AbortController !== 'undefined') return;
        \\  function AbortSignal(){
        \\    if (!(this instanceof AbortSignal)) throw new TypeError("Failed to construct 'AbortSignal': please use 'new'.");
        \\    this.aborted = false;
        \\    this.reason = undefined;
        \\    this._evtMap = {};
        \\    this.onabort = null;
        \\  }
        \\  AbortSignal.prototype.addEventListener = function(t, fn, o){
        \\    if (!this._evtMap[t]) this._evtMap[t] = [];
        \\    this._evtMap[t].push({ fn: fn, once: !!(o && o.once) });
        \\  };
        \\  AbortSignal.prototype.removeEventListener = function(t, fn){
        \\    var a = this._evtMap[t];
        \\    if (a) for (var i = a.length - 1; i >= 0; i--) if (a[i].fn === fn) a.splice(i, 1);
        \\  };
        \\  AbortSignal.prototype.dispatchEvent = function(e){
        \\    e.target = this; e.currentTarget = this;
        \\    var a = this._evtMap[e.type];
        \\    if (a) {
        \\      a = a.slice();
        \\      for (var i = 0; i < a.length; i++) {
        \\        try { a[i].fn.call(this, e); } catch(ex) {}
        \\        if (a[i].once) this.removeEventListener(e.type, a[i].fn);
        \\      }
        \\    }
        \\    e.currentTarget = null;
        \\    return !e.defaultPrevented;
        \\  };
        \\  AbortSignal.prototype.throwIfAborted = function(){ if (this.aborted) throw this.reason; };
        \\  AbortSignal.abort = function(reason){
        \\    var s = new AbortSignal();
        \\    s.aborted = true;
        \\    s.reason = reason !== undefined ? reason : (typeof DOMException !== 'undefined' ? new DOMException('The operation was aborted.', 'AbortError') : new Error('AbortError'));
        \\    return s;
        \\  };
        \\  AbortSignal.timeout = function(ms){
        \\    var s = new AbortSignal();
        \\    setTimeout(function(){
        \\      s.aborted = true;
        \\      s.reason = typeof DOMException !== 'undefined' ? new DOMException('The operation timed out.', 'TimeoutError') : new Error('TimeoutError');
        \\      var e; try { e = new Event('abort'); } catch(_) { e = { type: 'abort' }; }
        \\      if (s.onabort) try { s.onabort(e); } catch(_){}
        \\      s.dispatchEvent(e);
        \\    }, ms);
        \\    return s;
        \\  };
        \\  AbortSignal.any = function(signals){
        \\    if (!signals || signals.length === 0) return new AbortSignal();
        \\    var s = new AbortSignal();
        \\    for (var i = 0; i < signals.length; i++) {
        \\      if (signals[i].aborted) { s.aborted = true; s.reason = signals[i].reason; return s; }
        \\    }
        \\    var hs = [];
        \\    for (var i = 0; i < signals.length; i++) {
        \\      (function(sig){
        \\        var h = function(){
        \\          if (!s.aborted) {
        \\            s.aborted = true; s.reason = sig.reason;
        \\            for (var k = 0; k < hs.length; k++) hs[k].sig.removeEventListener('abort', hs[k].h);
        \\            var e; try { e = new Event('abort'); } catch(_) { e = { type: 'abort' }; }
        \\            if (s.onabort) try { s.onabort(e); } catch(_){}
        \\            s.dispatchEvent(e);
        \\          }
        \\        };
        \\        hs.push({ sig: sig, h: h });
        \\        sig.addEventListener('abort', h);
        \\      })(signals[i]);
        \\    }
        \\    return s;
        \\  };
        \\  globalThis.AbortSignal = AbortSignal;
        \\  function AbortController(){
        \\    if (!(this instanceof AbortController)) throw new TypeError("Failed to construct 'AbortController': please use 'new'.");
        \\    this.signal = new AbortSignal();
        \\  }
        \\  AbortController.prototype.abort = function(reason){
        \\    var s = this.signal;
        \\    if (!s.aborted) {
        \\      s.aborted = true;
        \\      s.reason = reason !== undefined ? reason : (typeof DOMException !== 'undefined' ? new DOMException('The operation was aborted.', 'AbortError') : new Error('AbortError'));
        \\      var e; try { e = new Event('abort'); } catch(_) { e = { type: 'abort' }; }
        \\      if (s.onabort) try { s.onabort(e); } catch(_){}
        \\      s.dispatchEvent(e);
        \\    }
        \\  };
        \\  globalThis.AbortController = AbortController;
        \\})();
    ;

    /// HTML §7.3.3 — Named access on the Window object.
    /// Scans the parsed DOM for elements with `id` attributes and registers each
    /// as a global variable (e.g. `<div id="foo">` → `globalThis.foo`). Called
    /// after HTML parse but before page scripts, so static IDs are visible.
    /// Uses getElementsByTagName('*') to traverse because `[attr]` selectors are
    /// not supported by the kotori selector engine. Registers each ID as a
    /// configurable getter on globalThis that delegates to getElementById() for
    /// live-ish semantics (element replaced → updated reference).
    const named_access_polyfill_js =
        \\(function(){
        \\  try {
        \\    var all=document.getElementsByTagName('*');
        \\    for(var i=0;i<all.length;i++){
        \\      var el=all[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      var id=el.getAttribute('id');
        \\      if(!id||typeof id!=='string'||id.length===0)continue;
        \\      // Skip if already defined (don't overwrite builtins or previously set globals)
        \\      if(typeof globalThis[id]!=='undefined')continue;
        \\      // Simple assignment: not live but sufficient for static HTML fixtures in WPT
        \\      globalThis[id]=el;
        \\    }
        \\  } catch(e) {}
        \\})();
    ;

    /// HTML §4.10.5.1 / §4.10.7 / §4.10.10 / §4.10.21 — form-control state.
    ///
    /// Adds the *current* state slots (value, checked, selectedness) on form
    /// controls, separated from their *default* counterparts via the spec's
    /// dirty value/checkedness flags (HTML §4.10.5.1 step 2).
    ///
    /// Architecture:
    ///   - kotori freezes per-tag prototypes (HTMLInputElement.prototype etc.)
    ///     against `Object.defineProperty`. Element.prototype is writable.
    ///   - The accessors live on Element.prototype and branch on `tagName`
    ///     so they only act on form controls; non-form elements get
    ///     undefined which matches Web spec.
    ///   - Per-instance `_dirtyValue`, `_value`, `_dirtyChecked`, `_checked`,
    ///     `_dirtySelected`, `_selected` slots (assignable JS object props
    ///     on the wrapper) hold the current-state values.
    ///   - Default* (defaultValue, defaultChecked, defaultSelected) flow
    ///     through the existing `html_reflection.zig` IDL registry which
    ///     reflects the content attribute.
    ///
    /// Spec anchors:
    ///   §4.10.5.1.6 input.defaultValue (reflects "value")
    ///   §4.10.5.1.16 input.checkedness / dirty checkedness flag
    ///   §4.10.5.1 input value sanitization (delegated; we store raw string)
    ///   §4.10.7 select.value / .selectedIndex / .options / .add / .remove
    ///   §4.10.10 option.selected / .defaultSelected / .index / .text
    ///   §4.10.11.5 textarea defaultValue (textContent at parse time)
    ///   §4.10.21.1 form.elements / .length
    ///   §4.10.21.4 form.reset() — fires "reset" event, restores defaults
    const form_state_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function getStr(el,k){return Object.prototype.hasOwnProperty.call(el,k)?el[k]:undefined;}
        \\  // ── input/textarea: value with dirty value flag (§4.10.5.1) ──
        \\  // §4.10.5.1.20 Color state value sanitization (per the
        \\  // optional "liberal acceptance" path, see HTML spec note):
        \\  // major browsers run input through the CSS <color> parser
        \\  // (rejecting `transparent` and `currentcolor`) and convert
        \\  // the result to a 7-char #rrggbb. If the input cannot be
        \\  // parsed, return "#000000". The strict "valid simple color"
        \\  // path is a subset of this and still returns the same hex.
        \\  function _hex2(n){
        \\    n=Math.round(n);if(n<0)n=0;if(n>255)n=255;
        \\    var h=n.toString(16);return h.length===1?'0'+h:h;
        \\  }
        \\  function _rgbHex(r,g,b){return '#'+_hex2(r)+_hex2(g)+_hex2(b);}
        \\  function _isHex(c){return (c>=48&&c<=57)||(c>=65&&c<=70)||(c>=97&&c<=102);}
        \\  function _clamp(x,mn,mx){return x<mn?mn:(x>mx?mx:x);}
        \\  function _parseRgbPart(s){
        \\    s=s.replace(/^\s+|\s+$/g,'');
        \\    if(s===''||s==='none')return null;
        \\    if(s.charAt(s.length-1)==='%'){
        \\      var p=parseFloat(s.slice(0,-1));
        \\      if(isNaN(p))return null;
        \\      return _clamp(p*2.55,0,255);
        \\    }
        \\    var n=parseFloat(s);
        \\    if(isNaN(n))return null;
        \\    return _clamp(n,0,255);
        \\  }
        \\  function _parsePctOrNum(s){
        \\    s=s.replace(/^\s+|\s+$/g,'');
        \\    if(s===''||s==='none')return null;
        \\    if(s.charAt(s.length-1)==='%'){
        \\      var p=parseFloat(s.slice(0,-1));
        \\      if(isNaN(p))return null;
        \\      return p;
        \\    }
        \\    var n=parseFloat(s);
        \\    if(isNaN(n))return null;
        \\    return n;
        \\  }
        \\  function _parseHueDeg(s){
        \\    s=s.replace(/^\s+|\s+$/g,'');
        \\    var m=s.match(/^[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?/);
        \\    if(!m)return null;
        \\    var num=parseFloat(m[0]);
        \\    if(isNaN(num))return null;
        \\    var unit=s.slice(m[0].length).toLowerCase();
        \\    if(unit==='rad')num=num*180/Math.PI;
        \\    else if(unit==='grad')num=num*0.9;
        \\    else if(unit==='turn')num=num*360;
        \\    // 'deg' or '' both treat as degrees
        \\    return ((num%360)+360)%360;
        \\  }
        \\  function _srgbDecode(c){
        \\    // sRGB / displayP3 transfer function (gamma → linear)
        \\    if(c<=0.04045)return c/12.92;
        \\    return Math.pow((c+0.055)/1.055,2.4);
        \\  }
        \\  function _srgbEncode(c){
        \\    // sRGB transfer function (linear → gamma)
        \\    if(c<=0)return 0;
        \\    if(c<=0.0031308)return c*12.92;
        \\    return 1.055*Math.pow(c,1/2.4)-0.055;
        \\  }
        \\  function _hslHex(h,s,l){
        \\    var c=(1-Math.abs(2*l-1))*s;
        \\    var hp=h/60;
        \\    var x=c*(1-Math.abs((hp%2)-1));
        \\    var r1=0,g1=0,b1=0;
        \\    if(hp<1){r1=c;g1=x;}
        \\    else if(hp<2){r1=x;g1=c;}
        \\    else if(hp<3){g1=c;b1=x;}
        \\    else if(hp<4){g1=x;b1=c;}
        \\    else if(hp<5){r1=x;b1=c;}
        \\    else{r1=c;b1=x;}
        \\    var m=l-c/2;
        \\    return _rgbHex((r1+m)*255,(g1+m)*255,(b1+m)*255);
        \\  }
        \\  var _COLOR_TABLE=null;
        \\  function _colorTable(){
        \\    if(_COLOR_TABLE!==null)return _COLOR_TABLE;
        \\    _COLOR_TABLE={};
        \\    var data="aliceblue=f0f8ff,antiquewhite=faebd7,aqua=00ffff,aquamarine=7fffd4,azure=f0ffff,beige=f5f5dc,bisque=ffe4c4,black=000000,blanchedalmond=ffebcd,blue=0000ff,blueviolet=8a2be2,brown=a52a2a,burlywood=deb887,cadetblue=5f9ea0,chartreuse=7fff00,chocolate=d2691e,coral=ff7f50,cornflowerblue=6495ed,cornsilk=fff8dc,crimson=dc143c,cyan=00ffff,darkblue=00008b,darkcyan=008b8b,darkgoldenrod=b8860b,darkgray=a9a9a9,darkgreen=006400,darkgrey=a9a9a9,darkkhaki=bdb76b,darkmagenta=8b008b,darkolivegreen=556b2f,darkorange=ff8c00,darkorchid=9932cc,darkred=8b0000,darksalmon=e9967a,darkseagreen=8fbc8f,darkslateblue=483d8b,darkslategray=2f4f4f,darkslategrey=2f4f4f,darkturquoise=00ced1,darkviolet=9400d3,deeppink=ff1493,deepskyblue=00bfff,dimgray=696969,dimgrey=696969,dodgerblue=1e90ff,firebrick=b22222,floralwhite=fffaf0,forestgreen=228b22,fuchsia=ff00ff,gainsboro=dcdcdc,ghostwhite=f8f8ff,gold=ffd700,goldenrod=daa520,gray=808080,green=008000,greenyellow=adff2f,grey=808080,honeydew=f0fff0,hotpink=ff69b4,indianred=cd5c5c,indigo=4b0082,ivory=fffff0,khaki=f0e68c,lavender=e6e6fa,lavenderblush=fff0f5,lawngreen=7cfc00,lemonchiffon=fffacd,lightblue=add8e6,lightcoral=f08080,lightcyan=e0ffff,lightgoldenrodyellow=fafad2,lightgray=d3d3d3,lightgreen=90ee90,lightgrey=d3d3d3,lightpink=ffb6c1,lightsalmon=ffa07a,lightseagreen=20b2aa,lightskyblue=87cefa,lightslategray=778899,lightslategrey=778899,lightsteelblue=b0c4de,lightyellow=ffffe0,lime=00ff00,limegreen=32cd32,linen=faf0e6,magenta=ff00ff,maroon=800000,mediumaquamarine=66cdaa,mediumblue=0000cd,mediumorchid=ba55d3,mediumpurple=9370db,mediumseagreen=3cb371,mediumslateblue=7b68ee,mediumspringgreen=00fa9a,mediumturquoise=48d1cc,mediumvioletred=c71585,midnightblue=191970,mintcream=f5fffa,mistyrose=ffe4e1,moccasin=ffe4b5,navajowhite=ffdead,navy=000080,oldlace=fdf5e6,olive=808000,olivedrab=6b8e23,orange=ffa500,orangered=ff4500,orchid=da70d6,palegoldenrod=eee8aa,palegreen=98fb98,paleturquoise=afeeee,palevioletred=db7093,papayawhip=ffefd5,peachpuff=ffdab9,peru=cd853f,pink=ffc0cb,plum=dda0dd,powderblue=b0e0e6,purple=800080,rebeccapurple=663399,red=ff0000,rosybrown=bc8f8f,royalblue=4169e1,saddlebrown=8b4513,salmon=fa8072,sandybrown=f4a460,seagreen=2e8b57,seashell=fff5ee,sienna=a0522d,silver=c0c0c0,skyblue=87ceeb,slateblue=6a5acd,slategray=708090,slategrey=708090,snow=fffafa,springgreen=00ff7f,steelblue=4682b4,tan=d2b48c,teal=008080,thistle=d8bfd8,tomato=ff6347,turquoise=40e0d0,violet=ee82ee,wheat=f5deb3,white=ffffff,whitesmoke=f5f5f5,yellow=ffff00,yellowgreen=9acd32,canvas=ffffff,canvastext=000000,linktext=0000ee,visitedtext=551a8b,activetext=ff0000,buttonface=f0f0f0,buttontext=000000,buttonborder=767676,field=ffffff,fieldtext=000000,highlight=0078d7,highlighttext=ffffff,selecteditem=0078d7,selecteditemtext=ffffff,mark=ffff00,marktext=000000,graytext=6d6d6d,accentcolor=0078d7,accentcolortext=ffffff,activeborder=767676,activecaption=ffffff,appworkspace=ffffff,background=ffffff,buttonhighlight=f0f0f0,buttonshadow=767676,captiontext=000000,inactiveborder=767676,inactivecaption=ffffff,inactivecaptiontext=6d6d6d,infobackground=ffffff,infotext=000000,menu=ffffff,menutext=000000,scrollbar=ffffff,threeddarkshadow=767676,threedface=f0f0f0,threedhighlight=f0f0f0,threedlightshadow=f0f0f0,threedshadow=767676,window=ffffff,windowframe=767676,windowtext=000000";
        \\    var pairs=data.split(',');
        \\    for(var i=0;i<pairs.length;i++){
        \\      var p=pairs[i],eq=p.indexOf('=');
        \\      if(eq>0)_COLOR_TABLE[p.slice(0,eq)]='#'+p.slice(eq+1);
        \\    }
        \\    return _COLOR_TABLE;
        \\  }
        \\  function sanitizeColor(v){
        \\    if(typeof v!=='string')return '#000000';
        \\    if(v.indexOf('\u0000')>=0)return '#000000';
        \\    var s=v.replace(/^[\u0009\u000A\u000C\u000D\u0020]+|[\u0009\u000A\u000C\u000D\u0020]+$/g,'');
        \\    if(s==='')return '#000000';
        \\    var lower=s.toLowerCase();
        \\    // Per HTML spec: transparent + currentcolor are explicitly
        \\    // excluded from input type=color value sanitization.
        \\    if(lower==='transparent'||lower==='currentcolor'||lower==='inherit')return '#000000';
        \\    // 3-/6-digit hex
        \\    if(s.charCodeAt(0)===35){
        \\      var hex=s.slice(1),hl=hex.length;
        \\      if(hl===3){
        \\        for(var i=0;i<3;i++)if(!_isHex(hex.charCodeAt(i)))return '#000000';
        \\        return ('#'+hex.charAt(0)+hex.charAt(0)+hex.charAt(1)+hex.charAt(1)+hex.charAt(2)+hex.charAt(2)).toLowerCase();
        \\      }
        \\      if(hl===6){
        \\        for(var i=0;i<6;i++)if(!_isHex(hex.charCodeAt(i)))return '#000000';
        \\        return ('#'+hex).toLowerCase();
        \\      }
        \\      return '#000000';
        \\    }
        \\    // Named/system color
        \\    var t=_colorTable();
        \\    var named=t[lower];
        \\    if(named)return named;
        \\    // Functional notation: rgb()/rgba()/hsl()/hsla()/color()
        \\    var openIdx=lower.indexOf('(');
        \\    if(openIdx>0&&lower.charAt(lower.length-1)===')'){
        \\      var fn=lower.slice(0,openIdx);
        \\      var inner=lower.slice(openIdx+1,lower.length-1);
        \\      var raw=inner.split(/[\s,\/]+/);
        \\      var parts=[];
        \\      for(var i=0;i<raw.length;i++)if(raw[i]!=='')parts.push(raw[i]);
        \\      if(fn==='rgb'||fn==='rgba'){
        \\        if(parts.length<3)return '#000000';
        \\        var r=_parseRgbPart(parts[0]),g=_parseRgbPart(parts[1]),b=_parseRgbPart(parts[2]);
        \\        if(r==null||g==null||b==null)return '#000000';
        \\        return _rgbHex(r,g,b);
        \\      }
        \\      if(fn==='hsl'||fn==='hsla'){
        \\        if(parts.length<3)return '#000000';
        \\        var h=_parseHueDeg(parts[0]),sat=_parsePctOrNum(parts[1]),light=_parsePctOrNum(parts[2]);
        \\        if(h==null||sat==null||light==null)return '#000000';
        \\        return _hslHex(h,sat/100,light/100);
        \\      }
        \\      if(fn==='color'){
        \\        if(parts.length<4)return '#000000';
        \\        var space=parts[0];
        \\        var R=parseFloat(parts[1]),G=parseFloat(parts[2]),B=parseFloat(parts[3]);
        \\        if(isNaN(R)||isNaN(G)||isNaN(B))return '#000000';
        \\        if(space==='srgb'){
        \\          R=_clamp(R,0,1);G=_clamp(G,0,1);B=_clamp(B,0,1);
        \\          return _rgbHex(R*255,G*255,B*255);
        \\        }
        \\        if(space==='srgb-linear'){
        \\          R=_srgbEncode(_clamp(R,0,1));
        \\          G=_srgbEncode(_clamp(G,0,1));
        \\          B=_srgbEncode(_clamp(B,0,1));
        \\          return _rgbHex(R*255,G*255,B*255);
        \\        }
        \\        if(space==='display-p3'){
        \\          // sRGB transfer-function decode → linear D65 displayP3
        \\          var lr=_srgbDecode(R),lg=_srgbDecode(G),lb=_srgbDecode(B);
        \\          // Linear-displayP3 → linear-sRGB matrix (D65, no chromatic adaptation needed)
        \\          var R2= 1.2249401*lr+-0.2249404*lg+ 0.0000004*lb;
        \\          var G2=-0.0420569*lr+ 1.0420571*lg+-0.0000002*lb;
        \\          var B2=-0.0196376*lr+-0.0786361*lg+ 1.0982737*lb;
        \\          R=_srgbEncode(_clamp(R2,0,1));
        \\          G=_srgbEncode(_clamp(G2,0,1));
        \\          B=_srgbEncode(_clamp(B2,0,1));
        \\          return _rgbHex(R*255,G*255,B*255);
        \\        }
        \\        return '#000000';
        \\      }
        \\    }
        \\    return '#000000';
        \\  }
        \\  // ── §4.10.5.1.5/6/7/8/9/13 date/time/number value sanitization ──
        \\  function _sanPad(n,l){var s=String(n);while(s.length<l)s='0'+s;return s;}
        \\  function _sanIsLeap(y){return (y%4===0&&y%100!==0)||y%400===0;}
        \\  function _sanDaysInMonth(y,m){
        \\    if(m===2)return _sanIsLeap(y)?29:28;
        \\    if(m===4||m===6||m===9||m===11)return 30;
        \\    return 31;
        \\  }
        \\  function _sanWeeksInYear(y){
        \\    var jan1=new Date(Date.UTC(y,0,1)).getUTCDay();
        \\    if(jan1===4)return 53;
        \\    if(_sanIsLeap(y)&&jan1===3)return 53;
        \\    return 52;
        \\  }
        \\  // Reject "00014" (5+ digits with leading zero); accept "10000".
        \\  function _sanYearStr(s){
        \\    if(s.length<4)return false;
        \\    if(s.length>4&&s.charAt(0)==='0')return false;
        \\    return true;
        \\  }
        \\  function _sanDate(v){
        \\    if(typeof v!=='string')return '';
        \\    var m=/^(\d{4,})-(\d{2})-(\d{2})$/.exec(v);
        \\    if(!m)return '';
        \\    if(!_sanYearStr(m[1]))return '';
        \\    var Y=+m[1],M=+m[2],D=+m[3];
        \\    if(Y<1)return '';
        \\    if(M<1||M>12)return '';
        \\    if(D<1||D>_sanDaysInMonth(Y,M))return '';
        \\    return m[1]+'-'+_sanPad(M,2)+'-'+_sanPad(D,2);
        \\  }
        \\  // Time spec (§4.10.5.1.10) does NOT mandate normalization, only validation.
        \\  // Datetime-local (§4.10.5.1.6) uses the *normalized* form, so callers
        \\  // pass normalize=true for that path only.
        \\  function _sanTime(v,normalize){
        \\    if(typeof v!=='string')return '';
        \\    var m=/^(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$/.exec(v);
        \\    if(!m)return '';
        \\    var H=+m[1],Mn=+m[2],S=m[3]?+m[3]:0;
        \\    var ms=m[4]||'';
        \\    if(H>23||Mn>59||S>59)return '';
        \\    var t=_sanPad(H,2)+':'+_sanPad(Mn,2);
        \\    if(normalize){
        \\      var msIsZero=ms===''||/^0+$/.test(ms);
        \\      if(S!==0||!msIsZero){
        \\        t+=':'+_sanPad(S,2);
        \\        if(!msIsZero){
        \\          var msTrim=ms.replace(/0+$/,'');
        \\          t+='.'+msTrim;
        \\        }
        \\      }
        \\      return t;
        \\    }
        \\    if(m[3]!==undefined){
        \\      t+=':'+_sanPad(S,2);
        \\      if(m[4]!==undefined)t+='.'+ms;
        \\    }
        \\    return t;
        \\  }
        \\  function _sanDtLocal(v){
        \\    if(typeof v!=='string')return '';
        \\    var m=/^(\d{4,}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?)$/.exec(v);
        \\    if(!m)return '';
        \\    var d=_sanDate(m[1]);
        \\    if(d==='')return '';
        \\    var t=_sanTime(m[2],true);
        \\    if(t==='')return '';
        \\    return d+'T'+t;
        \\  }
        \\  function _sanMonth(v){
        \\    if(typeof v!=='string')return '';
        \\    var m=/^(\d{4,})-(\d{2})$/.exec(v);
        \\    if(!m)return '';
        \\    if(!_sanYearStr(m[1]))return '';
        \\    var Y=+m[1],M=+m[2];
        \\    if(Y<1)return '';
        \\    if(M<1||M>12)return '';
        \\    return m[1]+'-'+_sanPad(M,2);
        \\  }
        \\  function _sanWeek(v){
        \\    if(typeof v!=='string')return '';
        \\    var m=/^(\d{4,})-W(\d{2})$/.exec(v);
        \\    if(!m)return '';
        \\    if(!_sanYearStr(m[1]))return '';
        \\    var Y=+m[1],W=+m[2];
        \\    if(Y<1)return '';
        \\    if(W<1||W>_sanWeeksInYear(Y))return '';
        \\    return m[1]+'-W'+_sanPad(W,2);
        \\  }
        \\  function _sanNumber(v){
        \\    if(typeof v!=='string')return '';
        \\    if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v))return '';
        \\    var n=parseFloat(v);
        \\    if(!isFinite(n))return '';
        \\    return v;
        \\  }
        \\  // Per HTML §4.10.5.1.13 (Range): clamp to [min,max], snap to
        \\  // step base. Default min=0 max=100 step=1. Invalid input ->
        \\  // best representation of the default value (midpoint).
        \\  function _sanRange(v,el){
        \\    if(typeof v!=='string')return '';
        \\    function _f(name,dflt){
        \\      var a=el&&el.getAttribute&&el.getAttribute(name);
        \\      if(a==null)return dflt;
        \\      if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(a))return dflt;
        \\      var n=parseFloat(a);
        \\      return isFinite(n)?n:dflt;
        \\    }
        \\    var min=_f('min',0), max=_f('max',100), step=_f('step',1);
        \\    if(step<=0)step=1;
        \\    function _default(){return (max>=min)?(min+(max-min)/2):min;}
        \\    var n;
        \\    if(!/^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(v)){
        \\      n=_default();
        \\    } else {
        \\      n=parseFloat(v);
        \\      if(!isFinite(n))n=_default();
        \\    }
        \\    if(max>=min){
        \\      if(n<min)n=min;
        \\      if(n>max)n=max;
        \\    } else {
        \\      n=min;
        \\    }
        \\    var diff=n-min;
        \\    var k=Math.round(diff/step);
        \\    var snapped=min+k*step;
        \\    if(max>=min&&snapped>max){
        \\      var k2=Math.floor((max-min)/step);
        \\      snapped=min+k2*step;
        \\    }
        \\    n=snapped;
        \\    function _decimals(x){
        \\      var s=String(x);
        \\      var i=s.indexOf('.');
        \\      return i<0?0:(s.length-i-1);
        \\    }
        \\    var prec=Math.max(_decimals(step),_decimals(min),_decimals(max));
        \\    if(prec>0){
        \\      n=parseFloat(n.toFixed(Math.min(prec+2,12)));
        \\    }
        \\    return String(n);
        \\  }
        \\  // Per HTML §4.10.5.1.5 (URL): strip newlines, then trim ASCII ws.
        \\  function _sanUrl(v){
        \\    if(typeof v!=='string')return v;
        \\    var s=v.replace(/[\u000A\u000D]/g,'');
        \\    return s.replace(/^[\u0009\u000A\u000C\u000D\u0020]+|[\u0009\u000A\u000C\u000D\u0020]+$/g,'');
        \\  }
        \\  // Per HTML §4.10.5.1.6 (Email):
        \\  // single: strip newlines + trim ASCII whitespace.
        \\  // multiple: split on ',', trim newlines+ws per segment, rejoin.
        \\  function _sanEmail(v,multiple){
        \\    if(typeof v!=='string')return v;
        \\    if(multiple){
        \\      var parts=v.split(',');
        \\      var out=[];
        \\      for(var i=0;i<parts.length;i++){
        \\        var s=parts[i].replace(/[\u000A\u000D]/g,'');
        \\        s=s.replace(/^[\u0009\u000A\u000C\u000D\u0020]+|[\u0009\u000A\u000C\u000D\u0020]+$/g,'');
        \\        out.push(s);
        \\      }
        \\      return out.join(',');
        \\    }
        \\    var s2=v.replace(/[\u000A\u000D]/g,'');
        \\    return s2.replace(/^[\u0009\u000A\u000C\u000D\u0020]+|[\u0009\u000A\u000C\u000D\u0020]+$/g,'');
        \\  }
        \\  function _sanText(v){return String(v).replace(/[\u000A\u000D]/g,'');}
        \\  function _sanByType(it,raw,el){
        \\    if(it==='date')return _sanDate(raw);
        \\    if(it==='time')return _sanTime(raw);
        \\    if(it==='datetime-local')return _sanDtLocal(raw);
        \\    if(it==='month')return _sanMonth(raw);
        \\    if(it==='week')return _sanWeek(raw);
        \\    if(it==='number')return _sanNumber(raw);
        \\    if(it==='range')return _sanRange(raw,el);
        \\    if(it==='url')return _sanUrl(raw);
        \\    if(it==='email')return _sanEmail(raw,!!(el&&el.hasAttribute&&el.hasAttribute('multiple')));
        \\    if(it==='color')return sanitizeColor(raw);
        \\    if(it==='text'||it==='search'||it==='tel'||it==='password'||it==='')return _sanText(raw);
        \\    return null;
        \\  }
        \\  Object.defineProperty(EP,'value',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t==='input'){
        \\        var it=(this.type||'').toLowerCase();
        \\        if(it==='color'){
        \\          if(this._dirtyValue===true&&typeof this._value==='string')return sanitizeColor(this._value);
        \\          var ca=this.getAttribute('value');
        \\          return sanitizeColor(ca==null?'':ca);
        \\        }
        \\        // §4.10.5.1.18 filename mode: ignore content attribute, return
        \\        // the selected file name (or '' if none). The dirty/_value
        \\        // path is honored only when explicitly cleared via setter.
        \\        if(it==='file'){
        \\          var fl=this.files;
        \\          if(fl&&fl.length>0&&fl[0]&&typeof fl[0].name==='string')return fl[0].name;
        \\          return '';
        \\        }
        \\        // §4.10.5.1 default-on mode: prefer attribute, fallback "on".
        \\        if(it==='checkbox'||it==='radio'){
        \\          var av=this.getAttribute('value');
        \\          return av==null?'on':av;
        \\        }
        \\        var raw;
        \\        if(this._dirtyValue===true&&typeof this._value==='string')raw=this._value;
        \\        else{var a=this.getAttribute('value');raw=a==null?'':a;}
        \\        var s=_sanByType(it,raw,this);
        \\        return s===null?raw:s;
        \\      }
        \\      if(t==='textarea'){
        \\        if(this._dirtyValue===true&&typeof this._value==='string')return this._value;
        \\        var tc=this.textContent;
        \\        return tc==null?'':tc;
        \\      }
        \\      if(t==='select'){
        \\        var opts=this.querySelectorAll('option');
        \\        for(var i=0;i<opts.length;i++){if(opts[i].selected){
        \\          var v=opts[i].getAttribute('value');
        \\          return v==null?(opts[i].textContent||''):v;
        \\        }}
        \\        // No selected: in select-one mode, first option is the selectedness default.
        \\        if(opts.length&&!this.hasAttribute('multiple')){
        \\          var v=opts[0].getAttribute('value');
        \\          return v==null?(opts[0].textContent||''):v;
        \\        }
        \\        return '';
        \\      }
        \\      if(t==='option'){
        \\        var v=this.getAttribute('value');
        \\        if(v!=null)return v;
        \\        var tc=this.textContent||'';
        \\        return tc.replace(/[\t\n\f\r ]+/g,' ').replace(/^ | $/g,'');
        \\      }
        \\      if(t==='button'||t==='li'||t==='data'||t==='meter'||t==='progress'||t==='param'){
        \\        return this.getAttribute('value')||'';
        \\      }
        \\      return undefined;
        \\    },
        \\    set:function(v){
        \\      var t=tag(this);
        \\      if(t==='input'){
        \\        var it=(this.type||'').toLowerCase();
        \\        // §4.10.5.1.18 filename mode: only null/empty allowed.
        \\        if(it==='file'){
        \\          if(v===null||v===''){
        \\            this._value='';
        \\            this._dirtyValue=true;
        \\            return;
        \\          }
        \\          throw new DOMException('Cannot set non-empty value of file input.','InvalidStateError');
        \\        }
        \\        // §4.10.5.1 default and default-on modes: store in content attr.
        \\        if(it==='checkbox'||it==='radio'||it==='hidden'||it==='submit'||it==='reset'||it==='button'||it==='image'){
        \\          this.setAttribute('value',String(v));
        \\          return;
        \\        }
        \\        // §4.10.5.1 value mode: dirty flag + sanitization.
        \\        this._dirtyValue=true;
        \\        var raw=String(v);
        \\        var s=_sanByType(it,raw,this);
        \\        this._value=s===null?raw:s;
        \\        return;
        \\      }
        \\      if(t==='textarea'){
        \\        this._dirtyValue=true;
        \\        this._value=String(v);
        \\        return;
        \\      }
        \\      if(t==='select'){
        \\        var nv=String(v);
        \\        var opts=this.querySelectorAll('option');
        \\        var matched=false;
        \\        for(var i=0;i<opts.length;i++){
        \\          var o=opts[i];
        \\          var ov=o.getAttribute('value');
        \\          var cmp=ov!=null?ov:(o.textContent||'').replace(/[\t\n\f\r ]+/g,' ').replace(/^ | $/g,'');
        \\          if(!matched&&cmp===nv){
        \\            o._dirtySelected=true;o._selected=true;
        \\            matched=true;
        \\          } else {
        \\            o._dirtySelected=true;o._selected=false;
        \\          }
        \\        }
        \\        return;
        \\      }
        \\      if(t==='option'||t==='button'||t==='li'||t==='data'||t==='meter'||t==='progress'||t==='param'){
        \\        this.setAttribute('value',String(v));
        \\        return;
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── input.defaultValue / textarea.defaultValue (§4.10.5.1.6 / §4.10.11.5) ──
        \\  Object.defineProperty(EP,'defaultValue',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t==='input')return this.getAttribute('value')||'';
        \\      if(t==='textarea')return this.textContent||'';
        \\      if(t==='output'){
        \\        if(typeof this._defaultValue==='string')return this._defaultValue;
        \\        return this.textContent||'';
        \\      }
        \\      return undefined;
        \\    },
        \\    set:function(v){
        \\      var t=tag(this);
        \\      var s=String(v);
        \\      if(t==='input'){this.setAttribute('value',s);return;}
        \\      if(t==='textarea'){this.textContent=s;return;}
        \\      if(t==='output'){this._defaultValue=s;if(this._dirtyValue!==true)this.textContent=s;return;}
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── input.checked / .defaultChecked (§4.10.5.1.16) ──
        \\  Object.defineProperty(EP,'checked',{
        \\    get:function(){
        \\      if(tag(this)!=='input')return undefined;
        \\      if(this._dirtyChecked===true)return this._checked===true;
        \\      return this.hasAttribute('checked');
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='input')return;
        \\      this._dirtyChecked=true;
        \\      var b=!!v;
        \\      this._checked=b;
        \\      // HTML §4.10.5 radio button group exclusivity:
        \\      // when a radio's checkedness becomes true, all other
        \\      // radios in the same group (same form owner, same
        \\      // non-empty name, case-sensitive) must be unchecked.
        \\      if(b&&(this.type||'').toLowerCase()==='radio'){
        \\        var name=(this.getAttribute&&this.getAttribute('name'))||'';
        \\        if(name==='')return;
        \\        // §4.10.5.1.16 radio button group: the same name, same form
        \\        // owner (or both no form owner), and the same tree root.
        \\        // Tree root via getRootNode handles disconnected trees,
        \\        // shadow roots, and document fragments uniformly.
        \\        var fo=function(el){
        \\          var fid=el.getAttribute&&el.getAttribute('form');
        \\          if(fid){
        \\            var d=el.ownerDocument||(typeof document!=='undefined'?document:null);
        \\            if(d&&d.getElementById){
        \\              var ff=d.getElementById(fid);
        \\              if(ff&&(ff.tagName||'').toLowerCase()==='form')return ff;
        \\            }
        \\            return null;
        \\          }
        \\          var p=el.parentNode;
        \\          while(p){
        \\            if(p.nodeType===1&&(p.tagName||'').toLowerCase()==='form')return p;
        \\            p=p.parentNode;
        \\          }
        \\          return null;
        \\        };
        \\        var rootOf=function(el){
        \\          if(typeof el.getRootNode==='function')return el.getRootNode();
        \\          var p=el;
        \\          while(p.parentNode)p=p.parentNode;
        \\          return p;
        \\        };
        \\        var myOwner=fo(this);
        \\        var myRoot=rootOf(this);
        \\        if(!myRoot||!myRoot.querySelectorAll)return;
        \\        var sibs=myRoot.querySelectorAll('input[type=radio]');
        \\        for(var i=0;i<sibs.length;i++){
        \\          var s=sibs[i];
        \\          if(s===this)continue;
        \\          var sn=(s.getAttribute&&s.getAttribute('name'))||'';
        \\          if(sn!==name)continue;
        \\          if(fo(s)!==myOwner)continue;
        \\          if(rootOf(s)!==myRoot)continue;
        \\          s._dirtyChecked=true;s._checked=false;
        \\        }
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'defaultChecked',{
        \\    get:function(){
        \\      if(tag(this)!=='input')return undefined;
        \\      return this.hasAttribute('checked');
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='input')return;
        \\      if(v)this.setAttribute('checked','');else this.removeAttribute('checked');
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── input.indeterminate (§4.10.5.1.16) ──
        \\  // No content attribute reflection; IDL-only state on the element.
        \\  // Spec: pre-activation steps reset indeterminate to false on click.
        \\  Object.defineProperty(EP,'indeterminate',{
        \\    get:function(){
        \\      if(tag(this)!=='input')return undefined;
        \\      return this._indeterminate===true;
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='input')return;
        \\      this._indeterminate=!!v;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── HTMLElement.accessKeyLabel (HTML §6.6.5) ──
        \\  // Returns a UA-defined label for the assigned access key
        \\  // (e.g. "Alt+B"), or "" if no access key is assigned.
        \\  // Simplified heuristic: if accesskey attribute is a single
        \\  // ASCII character, return "Alt+<UPPERCASE>"; else "".
        \\  Object.defineProperty(EP,'accessKeyLabel',{
        \\    get:function(){
        \\      var ak=this.getAttribute&&this.getAttribute('accesskey');
        \\      if(typeof ak!=='string'||ak.length!==1)return '';
        \\      var ch=ak.charCodeAt(0);
        \\      if(ch>=97&&ch<=122)return 'Alt+'+ak.toUpperCase();
        \\      if(ch>=65&&ch<=90)return 'Alt+'+ak;
        \\      if(ch>=48&&ch<=57)return 'Alt+'+ak;
        \\      return '';
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── HTMLElement.labels (HTML §4.10.4) ──
        \\  // labelable elements: button, input (except hidden), keygen,
        \\  // meter, output, progress, select, textarea. Returns an array
        \\  // (acts as NodeList for length + indexed access) of all <label>
        \\  // elements that label this element — direct ancestors AND
        \\  // for=id references.
        \\  Object.defineProperty(EP,'labels',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t!=='input'&&t!=='textarea'&&t!=='select'&&t!=='button'&&t!=='meter'&&t!=='output'&&t!=='progress')return null;
        \\      if(t==='input'&&(this.type||'').toLowerCase()==='hidden')return null;
        \\      var result=[];
        \\      var p=this.parentNode;
        \\      while(p){
        \\        if(p.nodeType===1&&(p.tagName||'').toLowerCase()==='label'){
        \\          result.push(p);
        \\        }
        \\        p=p.parentNode;
        \\      }
        \\      var id=this.getAttribute&&this.getAttribute('id');
        \\      if(id){
        \\        var doc=this.ownerDocument||(typeof document!=='undefined'?document:null);
        \\        if(doc&&doc.getElementsByTagName){
        \\          var allLabels=doc.getElementsByTagName('label');
        \\          for(var i=0;i<allLabels.length;i++){
        \\            var lbl=allLabels[i];
        \\            var forAttr=lbl.getAttribute&&lbl.getAttribute('for');
        \\            if(forAttr===id&&result.indexOf(lbl)===-1)result.push(lbl);
        \\          }
        \\        }
        \\      }
        \\      return result;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── option.selected / .defaultSelected / .index / .text (§4.10.10) ──
        \\  Object.defineProperty(EP,'selected',{
        \\    get:function(){
        \\      if(tag(this)!=='option')return undefined;
        \\      if(this._dirtySelected===true)return this._selected===true;
        \\      return this.hasAttribute('selected');
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='option')return;
        \\      var b=!!v;
        \\      // Per HTML §4.10.10: setting `selected` IDL attribute sets the
        \\      // dirty selectedness flag and the *current* selectedness ONLY.
        \\      // Do NOT touch the content attribute (that drives defaultSelected).
        \\      this._dirtySelected=true;
        \\      this._selected=b;
        \\      // select-one: deselect siblings on true (§4.10.7 selectedness algorithm)
        \\      if(b){
        \\        var p=this.parentNode;
        \\        while(p&&(p.tagName||'').toLowerCase()==='optgroup')p=p.parentNode;
        \\        if(p&&(p.tagName||'').toLowerCase()==='select'&&!p.hasAttribute('multiple')){
        \\          var sibs=p.querySelectorAll('option');
        \\          for(var i=0;i<sibs.length;i++){
        \\            if(sibs[i]===this)continue;
        \\            sibs[i]._dirtySelected=true;sibs[i]._selected=false;
        \\          }
        \\        }
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'defaultSelected',{
        \\    get:function(){
        \\      if(tag(this)!=='option')return undefined;
        \\      return this.hasAttribute('selected');
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='option')return;
        \\      if(v)this.setAttribute('selected','');else this.removeAttribute('selected');
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'index',{
        \\    get:function(){
        \\      if(tag(this)!=='option')return undefined;
        \\      var p=this.parentNode;
        \\      while(p&&(p.tagName||'').toLowerCase()==='optgroup')p=p.parentNode;
        \\      if(!p||(p.tagName||'').toLowerCase()!=='select')return 0;
        \\      var opts=p.querySelectorAll('option');
        \\      for(var i=0;i<opts.length;i++)if(opts[i]===this)return i;
        \\      return 0;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'text',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t==='option'){
        \\        var lab=this.getAttribute('label');
        \\        if(lab!=null)return lab;
        \\        var tc=this.textContent||'';
        \\        return tc.replace(/[\t\n\f\r ]+/g,' ').replace(/^ | $/g,'');
        \\      }
        \\      if(t==='script'||t==='style'||t==='title')return this.textContent||'';
        \\      return undefined;
        \\    },
        \\    set:function(v){
        \\      var t=tag(this);
        \\      if(t==='option'||t==='script'||t==='style'||t==='title'){
        \\        this.textContent=String(v);
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // ── select.selectedIndex / .options / .selectedOptions / .type / .add / .remove / .item / .namedItem (§4.10.7) ──
        \\  Object.defineProperty(EP,'selectedIndex',{
        \\    get:function(){
        \\      if(tag(this)!=='select')return undefined;
        \\      var opts=this.querySelectorAll('option');
        \\      for(var i=0;i<opts.length;i++)if(opts[i].selected)return i;
        \\      return -1;
        \\    },
        \\    set:function(n){
        \\      if(tag(this)!=='select')return;
        \\      n=n|0;
        \\      var opts=this.querySelectorAll('option');
        \\      for(var i=0;i<opts.length;i++){
        \\        if(i===n){opts[i]._dirtySelected=true;opts[i]._selected=true;}
        \\        else{opts[i]._dirtySelected=true;opts[i]._selected=false;}
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'options',{
        \\    get:function(){
        \\      if(tag(this)!=='select')return undefined;
        \\      return this.querySelectorAll('option');
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'selectedOptions',{
        \\    get:function(){
        \\      if(tag(this)!=='select')return undefined;
        \\      var opts=this.querySelectorAll('option'),r=[];
        \\      for(var i=0;i<opts.length;i++)if(opts[i].selected)r.push(opts[i]);
        \\      return r;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // HTML §4.10.5.1 — value IDL attribute mode per input type.
        \\  // Returns 'value' / 'default' / 'default-on' / 'filename'.
        \\  function _valMode(it){
        \\    if(it==='hidden'||it==='submit'||it==='image'||it==='reset'||it==='button')return 'default';
        \\    if(it==='checkbox'||it==='radio')return 'default-on';
        \\    if(it==='file')return 'filename';
        \\    return 'value';
        \\  }
        \\  // Whether selectionStart/End/Direction apply to this type.
        \\  function _isTextSel(it){
        \\    return it==='text'||it==='search'||it==='url'||it==='tel'||it==='password';
        \\  }
        \\  // HTML §4.10.5.7 — algorithm run when input.type changes state.
        \\  function _onTypeChange(el,oldT,newT,oldVal){
        \\    if(oldT===newT)return;
        \\    var oldMode=_valMode(oldT),newMode=_valMode(newT);
        \\    // Spec rule 1: value → default/default-on with non-empty value.
        \\    if(oldMode==='value'&&(newMode==='default'||newMode==='default-on')&&oldVal!==''){
        \\      el.setAttribute('value',oldVal);
        \\    }
        \\    // Spec rule 2: !value → value mode.
        \\    else if(oldMode!=='value'&&newMode==='value'){
        \\      var av=el.getAttribute('value');
        \\      el._value=(av==null?'':av);
        \\      el._dirtyValue=false;
        \\    }
        \\    // Spec rule 3: !filename → filename.
        \\    else if(oldMode!=='filename'&&newMode==='filename'){
        \\      el._value='';
        \\      el._dirtyValue=false;
        \\    }
        \\    // Selection state: non-selectable → selectable resets to (0,0,'none').
        \\    var oldSel=_isTextSel(oldT),newSel=_isTextSel(newT);
        \\    if(!oldSel&&newSel){
        \\      el._selStart=0;
        \\      el._selEnd=0;
        \\      el._selDir='none';
        \\    } else if(oldSel&&!newSel){
        \\      el._selStart=null;
        \\      el._selEnd=null;
        \\      el._selDir=null;
        \\    }
        \\    // §4.10.5.1.16 morph INTO radio with `checked` attribute set:
        \\    // run group exclusivity so other radios in the same group
        \\    // become unchecked. The IDL setter has the canonical walk.
        \\    if(newT==='radio'&&el.checked===true){
        \\      try{el.checked=true;}catch(e){}
        \\    }
        \\  }
        \\  Object.defineProperty(EP,'type',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t==='select')return this.hasAttribute('multiple')?'select-multiple':'select-one';
        \\      // HTML §4.10.11 HTMLTextAreaElement.type: always the literal
        \\      // string "textarea" (read-only).
        \\      if(t==='textarea')return 'textarea';
        \\      // HTML §4.10.15 HTMLFieldSetElement.type: always "fieldset".
        \\      if(t==='fieldset')return 'fieldset';
        \\      // HTML §4.10.8 HTMLButtonElement.type IDL: enumerated
        \\      // attribute with default "submit". Canonical keywords are
        \\      // "submit", "reset", "button". Missing/invalid → "submit".
        \\      if(t==='button'){
        \\        var bv=(this.getAttribute('type')||'').toLowerCase();
        \\        if(bv==='reset'||bv==='button')return bv;
        \\        return 'submit';
        \\      }
        \\      // Other element 'type' (input etc.) handled by IDL reflection.
        \\      return undefined;
        \\    },
        \\    set:function(v){
        \\      // HTML §2.6.2 DOMString reflection setter: set the content
        \\      // attribute. Canonicalization / enumerated-keyword matching
        \\      // happens in the native reflectionSet for input type etc.,
        \\      // but here we just forward to setAttribute so IDL assignment
        \\      // like `input.type = 'number'` updates the attribute (which
        \\      // the getter then re-canonicalizes on read).
        \\      var isInput=tag(this)==='input';
        \\      var oldType,oldVal;
        \\      if(isInput){
        \\        oldType=(this.type||'').toLowerCase();
        \\        try{oldVal=this.value;}catch(e){oldVal='';}
        \\      }
        \\      if(v==null)this.removeAttribute('type');
        \\      else this.setAttribute('type',String(v));
        \\      if(isInput){
        \\        var newType=(this.type||'').toLowerCase();
        \\        if(oldType!==newType)_onTypeChange(this,oldType,newType,oldVal);
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // Methods on Element.prototype too — branch by tag.
        \\  EP.add=function(elem,before){
        \\    if(tag(this)!=='select'){throw new TypeError('add: not a select');}
        \\    if(elem==null)return;
        \\    var ref=null;
        \\    if(before==null){ref=null;}
        \\    else if(typeof before==='number'){
        \\      var opts=this.querySelectorAll('option');
        \\      ref=before<opts.length?opts[before]:null;
        \\    } else { ref=before; }
        \\    if(ref==null)this.appendChild(elem); else this.insertBefore(elem,ref);
        \\  };
        \\  // ChildNode.remove() per DOM §4.4 — must be `length === 0` so
        \\  // WPT Element-remove.html's `assert_equals(node.remove.length, 0)`
        \\  // passes. The HTMLSelectElement.remove(i) overload lives on
        \\  // HTMLSelectElement.prototype below and shadows this method on
        \\  // <select> instances; it falls back to self-removal when called
        \\  // with no arguments (matching ChildNode.remove semantics).
        \\  EP.remove=function(){
        \\    if(this.parentNode)this.parentNode.removeChild(this);
        \\  };
        \\  // HTML §4.10.7 HTMLSelectElement.item / .namedItem.
        \\  // Installed on HTMLSelectElement.prototype (left unfrozen by
        \\  // kotori_dom.zig for this purpose) so they don't leak onto every
        \\  // Element via Element.prototype — `"item" in form` must be false
        \\  // per the form-nameditem WPT.
        \\  if (typeof HTMLSelectElement !== 'undefined') {
        \\    var SP = HTMLSelectElement.prototype;
        \\    Object.defineProperty(SP, 'item', {
        \\      value: function(i){
        \\        var opts=this.querySelectorAll('option');i=i>>>0;
        \\        return i<opts.length?opts[i]:null;
        \\      },
        \\      writable:true, configurable:true, enumerable:false
        \\    });
        \\    Object.defineProperty(SP, 'namedItem', {
        \\      value: function(n){
        \\        // HTML §4.10.7 HTMLSelectElement.namedItem: per the named
        \\        // property algorithm, empty-string name short-circuits to
        \\        // null without matching any option (no option can have id=""
        \\        // or name="" be a supported name property per DOM §4.5.2).
        \\        n=String(n);
        \\        if(n==='')return null;
        \\        var opts=this.querySelectorAll('option');
        \\        for(var i=0;i<opts.length;i++)
        \\          if(opts[i].id===n||opts[i].getAttribute('name')===n)return opts[i];
        \\        return null;
        \\      },
        \\      writable:true, configurable:true, enumerable:false
        \\    });
        \\    // HTML §4.10.7 HTMLSelectElement.remove(index): remove the option
        \\    // at the given index. Calling with no arguments falls back to
        \\    // ChildNode.remove() (DOM §4.4) — same as Element.prototype.remove.
        \\    Object.defineProperty(SP, 'remove', {
        \\      value: function(i){
        \\        if(arguments.length===0){
        \\          if(this.parentNode)this.parentNode.removeChild(this);
        \\          return;
        \\        }
        \\        var opts=this.querySelectorAll('option');
        \\        i=i|0;
        \\        if(i>=0&&i<opts.length)opts[i].parentNode.removeChild(opts[i]);
        \\      },
        \\      writable:true, configurable:true, enumerable:false
        \\    });
        \\  }
        \\  // ── form.elements / .length / .reset() (§4.10.21) ──
        \\  // HTML §4.10.21.1 form.elements: collect form-associated listed
        \\  // elements whose form owner is this form — including elements
        \\  // outside the form's subtree that opt in via the `form="<id>"`
        \\  // attribute. Walking the document and dispatching on node.form
        \\  // (the form_owner polyfill getter) covers both descendants and
        \\  // externally-associated controls in tree order.
        \\  function _collectListed(form){
        \\    var out=[];
        \\    var doc=form.ownerDocument||(typeof document!=='undefined'?document:null);
        \\    var rootScan=doc?(doc.body||doc.documentElement||form):form;
        \\    if(!rootScan)return out;
        \\    var stack=[rootScan],node;
        \\    while(stack.length){
        \\      node=stack.pop();
        \\      var children=node.children;
        \\      if(children){
        \\        for(var i=children.length-1;i>=0;i--)stack.push(children[i]);
        \\      }
        \\      var t=(node.tagName||'').toLowerCase();
        \\      // HTML §4.10.21.1: listed elements are button, fieldset, input,
        \\      // object, output, select, textarea. form.elements must include
        \\      // all of them whose form owner is this form (excluding input
        \\      // type=image, filtered later).
        \\      if(t==='input'||t==='select'||t==='textarea'||t==='button'||t==='output'||t==='fieldset'||t==='object'){
        \\        if(node.form===form)out.push(node);
        \\      }
        \\    }
        \\    return out;
        \\  }
        \\  // HTML §4.10.21.1: form.elements excludes input type=image. Other
        \\  // listed elements are kept.
        \\  function _filterFormElements(arr){
        \\    var out=[];
        \\    for(var i=0;i<arr.length;i++){
        \\      var el=arr[i];
        \\      var t=(el.tagName||'').toLowerCase();
        \\      if(t==='input'){
        \\        var ty=el.getAttribute('type');
        \\        ty=ty==null?'text':String(ty).toLowerCase();
        \\        if(ty==='image')continue;
        \\      }
        \\      out.push(el);
        \\    }
        \\    return out;
        \\  }
        \\  // Per-form HFCC + RadioNodeList Proxy caches (HTML §4.10.21.1
        \\  // [SameObject] form.elements). Both are live (refresh on every
        \\  // access) and named getter resolution follows HTMLFormControlsCollection
        \\  // §4.10.21.2 (returns Element for single match, RadioNodeList for
        \\  // multiple). Array-index-shaped strings (canonical 0/1/2…) skip the
        \\  // named lookup so form.elements["2"] / form.elements[2] are both
        \\  // routed through indexed-property handling per WebIDL §3.9.2.
        \\  var _hfccCache = new WeakMap();
        \\  var _rnlCache = new WeakMap();
        \\  function _isArrayIndex(s){
        \\    if(typeof s!=='string')return false;
        \\    if(s==='0')return true;
        \\    return /^[1-9][0-9]{0,9}$/.test(s);
        \\  }
        \\  function _matchByName(arr, name){
        \\    var matches=[];
        \\    for(var i=0;i<arr.length;i++){
        \\      var el=arr[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      var ns=el.namespaceURI;
        \\      if(ns!=null&&ns!=='http://www.w3.org/1999/xhtml')continue;
        \\      var id=el.getAttribute('id');
        \\      var nm=el.getAttribute('name');
        \\      if(id===name||nm===name)matches.push(el);
        \\    }
        \\    return matches;
        \\  }
        \\  function _getRadioNodeList(form, name){
        \\    var byForm=_rnlCache.get(form);
        \\    if(!byForm){byForm={};_rnlCache.set(form,byForm);}
        \\    if(byForm[name])return byForm[name];
        \\    var target=[];
        \\    function refresh(){
        \\      while(target.length)target.pop();
        \\      var arr=_filterFormElements(_collectListed(form));
        \\      var matches=_matchByName(arr, name);
        \\      for(var i=0;i<matches.length;i++)target.push(matches[i]);
        \\    }
        \\    var rnlProto=globalThis.RadioNodeList&&globalThis.RadioNodeList.prototype;
        \\    var px=new Proxy(target,{
        \\      get:function(t,prop){
        \\        refresh();
        \\        if(typeof prop==='symbol')return target[prop];
        \\        if(prop==='length')return target.length;
        \\        if(prop==='item')return function(i){var n=i>>>0;return n<target.length?target[n]:null;};
        \\        if(_isArrayIndex(prop)){
        \\          var n=+prop;
        \\          return n<target.length?target[n]:undefined;
        \\        }
        \\        if(rnlProto){
        \\          var desc=Object.getOwnPropertyDescriptor(rnlProto,prop);
        \\          if(desc){
        \\            if(desc.get)return desc.get.call(target);
        \\            return desc.value;
        \\          }
        \\        }
        \\        var v=target[prop];
        \\        if(typeof v==='function')return v.bind(target);
        \\        return v;
        \\      },
        \\      set:function(t,prop,value){
        \\        if(rnlProto){
        \\          var desc=Object.getOwnPropertyDescriptor(rnlProto,prop);
        \\          if(desc&&desc.set){desc.set.call(target,value);return true;}
        \\        }
        \\        target[prop]=value;
        \\        return true;
        \\      },
        \\      has:function(t,prop){
        \\        refresh();
        \\        if(prop==='length'||prop==='item')return true;
        \\        if(_isArrayIndex(prop))return +prop<target.length;
        \\        if(rnlProto&&Object.getOwnPropertyDescriptor(rnlProto,prop))return true;
        \\        return prop in target;
        \\      },
        \\      getPrototypeOf:function(){return rnlProto||Array.prototype;}
        \\    });
        \\    byForm[name]=px;
        \\    return px;
        \\  }
        \\  function _getElementsHFCC(form){
        \\    var px=_hfccCache.get(form);
        \\    if(px)return px;
        \\    var target=[];
        \\    function refresh(){
        \\      while(target.length)target.pop();
        \\      var arr=_filterFormElements(_collectListed(form));
        \\      for(var i=0;i<arr.length;i++)target.push(arr[i]);
        \\    }
        \\    var hfccProto=globalThis.HTMLFormControlsCollection&&globalThis.HTMLFormControlsCollection.prototype;
        \\    px=new Proxy(target,{
        \\      get:function(t,prop){
        \\        refresh();
        \\        if(typeof prop==='symbol')return target[prop];
        \\        if(prop==='length')return target.length;
        \\        if(prop==='item')return function(i){var n=i>>>0;return n<target.length?target[n]:null;};
        \\        if(prop==='namedItem'){
        \\          if(hfccProto&&hfccProto.namedItem)return hfccProto.namedItem.bind(target);
        \\          return function(){return null;};
        \\        }
        \\        if(_isArrayIndex(prop)){
        \\          var n=+prop;
        \\          return n<target.length?target[n]:undefined;
        \\        }
        \\        // Forward Array.prototype methods (slice, indexOf, etc.) and
        \\        // own props that already exist on the target before doing the
        \\        // named-property lookup.
        \\        if(typeof prop==='string'&&prop in target){
        \\          var v=target[prop];
        \\          if(typeof v==='function')return v.bind(target);
        \\          return v;
        \\        }
        \\        if(typeof prop==='string'&&prop!==''){
        \\          var matches=_matchByName(target,prop);
        \\          if(matches.length===0)return undefined;
        \\          if(matches.length===1)return matches[0];
        \\          return _getRadioNodeList(form,prop);
        \\        }
        \\        return target[prop];
        \\      },
        \\      has:function(t,prop){
        \\        refresh();
        \\        if(prop==='length'||prop==='item'||prop==='namedItem')return true;
        \\        if(_isArrayIndex(prop))return +prop<target.length;
        \\        if(hfccProto&&Object.getOwnPropertyDescriptor(hfccProto,prop))return true;
        \\        if(typeof prop==='string'&&_matchByName(target,prop).length>0)return true;
        \\        return prop in target;
        \\      },
        \\      getPrototypeOf:function(){return hfccProto||Array.prototype;}
        \\    });
        \\    _hfccCache.set(form,px);
        \\    return px;
        \\  }
        \\  Object.defineProperty(EP,'elements',{
        \\    get:function(){
        \\      if(tag(this)!=='form')return undefined;
        \\      return _getElementsHFCC(this);
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'length',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(t==='form'){var els=this.elements;return els?els.length:0;}
        \\      if(t==='select'){return this.querySelectorAll('option').length;}
        \\      return undefined;
        \\    },
        \\    set:function(n){
        \\      if(tag(this)!=='select')return;
        \\      n=n>>>0;
        \\      var opts=this.querySelectorAll('option');
        \\      if(n<opts.length){
        \\        for(var i=opts.length-1;i>=n;i--)if(opts[i].parentNode)opts[i].parentNode.removeChild(opts[i]);
        \\      } else {
        \\        for(var i=opts.length;i<n;i++){var o=document.createElement('option');this.appendChild(o);}
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  // HTML §4.10.22.3 form.requestSubmit(submitter).
        \\  // Validates the submitter (must be a submit button owned by this form)
        \\  // and then fires a cancelable `submit` event with `event.submitter`
        \\  // set to the submitter (or null if the form is its own submitter).
        \\  // We do NOT perform the actual navigation/form-submission step — most
        \\  // callers either preventDefault() in the submit handler or rely on
        \\  // the handler for testing, per WPT form-requestsubmit coverage.
        \\  EP.requestSubmit=function(submitter){
        \\    if(tag(this)!=='form')throw new TypeError('requestSubmit: not a form');
        \\    // HTML §4.10.22.3 step 1.5 (paraphrased): if form is not connected,
        \\    // return without firing submit. WPT form-requestsubmit covers this.
        \\    if(!this.isConnected)return;
        \\    if(submitter!==undefined&&submitter!==null){
        \\      var st=tag(submitter);
        \\      var isSubmitButton=false;
        \\      if(st==='button'){
        \\        // HTML §4.10.8: button default type is 'submit'. Invalid
        \\        // values also default to 'submit' per missing/invalid value
        \\        // default. So submit-button state ≡ type ∉ {reset, button}.
        \\        var bt=submitter.getAttribute('type');
        \\        if(bt!=null)bt=String(bt).toLowerCase();
        \\        if(bt!=='reset'&&bt!=='button')isSubmitButton=true;
        \\      } else if(st==='input'){
        \\        // HTML §4.10.5.1: input default type is 'text'. Invalid values
        \\        // default to 'text'. Submit/Image button state requires exact
        \\        // 'submit' or 'image' attribute value.
        \\        var it=submitter.getAttribute('type');
        \\        it=it==null?'text':String(it).toLowerCase();
        \\        if(it==='submit'||it==='image')isSubmitButton=true;
        \\      }
        \\      if(!isSubmitButton){
        \\        throw new TypeError('requestSubmit: submitter must be a submit button');
        \\      }
        \\      if(submitter.form!==this){
        \\        throw new DOMException('requestSubmit: submitter is not owned by this form','NotFoundError');
        \\      }
        \\    } else {
        \\      submitter=null;
        \\    }
        \\    // HTML §4.10.21.3 step 4: if firing-submission-events flag is set,
        \\    // return. This blocks reentrant submit/requestSubmit/click() during
        \\    // an in-flight submission (covers both submit handlers and invalid
        \\    // event handlers, per WPT form-requestsubmit reentrancy tests).
        \\    // NOTE: kotori VM does not run `finally` after `return`, so we
        \\    // unset the flag explicitly on every exit path.
        \\    if(this._firingSubmissionEvents)return;
        \\    this._firingSubmissionEvents=true;
        \\    // HTML §4.10.21.3 step 8: interactive validation. Skip iff the
        \\    // form has a novalidate attribute, OR submitter has formnovalidate.
        \\    var noValidate=this.hasAttribute&&this.hasAttribute('novalidate');
        \\    if(submitter&&submitter.hasAttribute&&submitter.hasAttribute('formnovalidate')){
        \\      noValidate=true;
        \\    }
        \\    if(!noValidate&&typeof this.checkValidity==='function'){
        \\      // checkValidity() statically validates the form; for each invalid
        \\      // control it fires `invalid` (cancelable). If any control is
        \\      // invalid, return WITHOUT firing submit.
        \\      var _valid;
        \\      try { _valid=this.checkValidity(); }
        \\      catch(e) { _valid=false; }
        \\      if(!_valid){
        \\        this._firingSubmissionEvents=false;
        \\        return;
        \\      }
        \\    }
        \\    // HTML §4.10.21.3 steps 9-10: fire SubmitEvent (cancelable, bubbles)
        \\    // with event.submitter set to submitter (or null).
        \\    var ev;
        \\    try { ev=new Event('submit',{bubbles:true,cancelable:true}); }
        \\    catch(e) { this._firingSubmissionEvents=false; return; }
        \\    try { Object.defineProperty(ev,'submitter',{value:submitter,writable:false,enumerable:true,configurable:true}); } catch(e) {}
        \\    try { this.dispatchEvent(ev); } catch(e) {}
        \\    this._firingSubmissionEvents=false;
        \\    // We don't perform actual form navigation — handlers are expected
        \\    // to preventDefault() or observe dispatch side effects.
        \\  };
        \\  // HTML §4.10.18 dom-fs-action: form.action getter must
        \\  // return the document's URL when the action content attribute is
        \\  // missing or empty; otherwise the absolute URL obtained by parsing
        \\  // the value relative to the element's base URL. Setter reflects
        \\  // the value onto the action content attribute.
        \\  Object.defineProperty(EP,'action',{
        \\    get:function(){
        \\      if(tag(this)!=='form')return undefined;
        \\      var attr=this.getAttribute('action');
        \\      var docURL=(typeof document!=='undefined'&&document.URL)?document.URL:'';
        \\      if(attr===null||attr==='')return docURL;
        \\      var base=(typeof document!=='undefined'&&document.baseURI)?document.baseURI:docURL;
        \\      try{return new URL(attr,base).href;}catch(e){return attr;}
        \\    },
        \\    set:function(v){
        \\      if(tag(this)!=='form')return;
        \\      this.setAttribute('action',String(v));
        \\    },
        \\    configurable:true,enumerable:true
        \\  });
        \\  EP.reset=function(){
        \\    if(tag(this)!=='form')return;
        \\    // §4.10.21.4 reset(): if not connected, return.
        \\    if(!this.isConnected)return;
        \\    var ev;
        \\    try { ev=new Event('reset',{bubbles:true,cancelable:true}); }
        \\    catch(e){return;}
        \\    var notCanceled=this.dispatchEvent(ev);
        \\    if(!notCanceled)return;
        \\    // §4.10.5.2 form-reset algorithm: clear dirty flags on each control.
        \\    var els=_collectListed(this);
        \\    for(var i=0;i<els.length;i++){
        \\      var el=els[i];
        \\      var t=tag(el);
        \\      if(t==='input'||t==='textarea'){
        \\        el._dirtyValue=false;
        \\        el._value=undefined;
        \\        el._dirtyChecked=false;
        \\        el._checked=undefined;
        \\      } else if(t==='select'){
        \\        var opts=el.querySelectorAll('option');
        \\        for(var j=0;j<opts.length;j++){
        \\          opts[j]._dirtySelected=false;
        \\          opts[j]._selected=undefined;
        \\          // After clearing dirty flag, selected getter falls back to hasAttribute('selected'),
        \\          // which reflects defaultSelected per spec. No attribute change needed.
        \\        }
        \\        // HTML §4.10.7 selectedness rule: if display size is 1 (no `multiple`)
        \\        // and no option has defaultSelected, the first option's selectedness
        \\        // must be set to true. After a reset this applies to the fresh
        \\        // defaultSelected state.
        \\        if(!el.hasAttribute('multiple')){
        \\          var anySel=false;
        \\          for(var j=0;j<opts.length;j++){if(opts[j].selected){anySel=true;break;}}
        \\          if(!anySel&&opts.length>0){
        \\            opts[0]._dirtySelected=true;
        \\            opts[0]._selected=true;
        \\          }
        \\        }
        \\      } else if(t==='output') {
        \\        if(typeof el._defaultValue==='string')el.textContent=el._defaultValue;
        \\        el._dirtyValue=false;
        \\      }
        \\    }
        \\  };
        \\})();
    ;

    /// HTML §4.10.18 Constraint Validation API for kotori.
    ///
    /// Defines willValidate / validity (ValidityState) / validationMessage
    /// getters, plus checkValidity() / reportValidity() / setCustomValidity()
    /// methods. Mirrors the QuickJS-side polyfill at dom_api.zig:3978
    /// (constraint_js) but installed on Element.prototype with tag-based
    /// branching, matching form_state_polyfill_js's "per-tag prototypes are
    /// frozen" workaround for kotori.
    const validity_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  // ValidityState stamp so Object.prototype.toString.call(v) returns
        \\  // "[object ValidityState]" per WebIDL §3.7 (assert_class_string).
        \\  var ValidityState=function ValidityState(){};
        \\  var VS_PROTO=ValidityState.prototype;
        \\  try{if(typeof Symbol!=='undefined'&&Symbol.toStringTag)
        \\    VS_PROTO[Symbol.toStringTag]='ValidityState';}catch(e){}
        \\  try{if(typeof globalThis!=='undefined'&&typeof globalThis.ValidityState==='undefined')
        \\    globalThis.ValidityState=ValidityState;}catch(e){}
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function isSubmittable(el){
        \\    var t=tag(el);
        \\    return t==='input'||t==='textarea'||t==='select'||t==='button';
        \\  }
        \\  function willVal(el){
        \\    if(!isSubmittable(el))return false;
        \\    if(el.disabled)return false;
        \\    var t=tag(el);
        \\    var it=(el.type||'').toLowerCase();
        \\    if(t==='input'&&(it==='hidden'||it==='reset'||it==='button'))return false;
        \\    if(t==='button'&&(it==='reset'||it==='button'))return false;
        \\    if(el.closest&&el.closest('datalist'))return false;
        \\    return true;
        \\  }
        \\  function parseDTV(s,t){
        \\    if(!s)return null;
        \\    var m;
        \\    if(t==='date'){m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(s);if(!m)return null;var d=Date.UTC(+m[1],+m[2]-1,+m[3]);return isNaN(d)?null:d;}
        \\    if(t==='datetime-local'){m=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?$/.exec(s);if(!m)return null;var sec=m[6]?parseFloat(m[6]):0;var ms=Math.round((sec-Math.floor(sec))*1000);var d2=Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5],Math.floor(sec),ms);return isNaN(d2)?null:d2;}
        \\    if(t==='time'){m=/^(\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?$/.exec(s);if(!m)return null;var sec2=m[3]?parseFloat(m[3]):0;return (+m[1])*3600000+(+m[2])*60000+Math.round(sec2*1000);}
        \\    if(t==='month'){m=/^(\d{4})-(\d{2})$/.exec(s);if(!m)return null;return (+m[1])*12+(+m[2])-1;}
        \\    if(t==='week'){m=/^(\d{4})-W(\d{2})$/.exec(s);if(!m)return null;var y=+m[1],w=+m[2];if(w<1||w>53)return null;var jan4=new Date(Date.UTC(y,0,4));var dow=jan4.getUTCDay()||7;var mon1=Date.UTC(y,0,4-dow+1);return mon1+(w-1)*604800000;}
        \\    return null;
        \\  }
        \\  function makeValidity(el){
        \\    var msg=el._customValidationMessage||'';
        \\    var customError=msg!=='';
        \\    var val=el.value;if(val==null)val='';else val=String(val);
        \\    var type=(el.type||'text').toLowerCase();
        \\    var req=el.required||false;
        \\    var valueMissing=false;
        \\    // Radios get special group-inheritance treatment per §4.10.18.3:
        \\    // a radio is missing if ANY radio in its group is required and
        \\    // NO radio in the group is checked (the `required` attribute
        \\    // propagates through name+form group membership).
        \\    if(type==='radio'){
        \\      // §4.10.5.1.16 radio button group: same name, same form
        \\      // owner, same tree root. Iterate via tree-root querySelectorAll
        \\      // so disconnected radios share groups within their own tree.
        \\      var gname=el.name||'';
        \\      var anyRequired=req,anyChecked=(el.checked===true);
        \\      if(gname!==''){
        \\        // HTML §4.10.18.3: defer to the canonical Element.form
        \\        // getter (form_owner_polyfill_js). Validity is evaluated
        \\        // lazily so by the time __fo runs the form-owner polyfill
        \\        // is installed and handles empty form="" and disconnected
        \\        // tree-root lookup correctly.
        \\        var __fo=function(e){
        \\          if(typeof e.form!=='undefined')return e.form||null;
        \\          return null;
        \\        };
        \\        var __ro=function(e){
        \\          if(typeof e.getRootNode==='function')return e.getRootNode();
        \\          var p=e;
        \\          while(p.parentNode)p=p.parentNode;
        \\          return p;
        \\        };
        \\        var myOwner=__fo(el);
        \\        var myRoot=__ro(el);
        \\        if(myRoot&&myRoot.querySelectorAll){
        \\          var all=myRoot.querySelectorAll('input[type=radio]');
        \\          for(var gi=0;gi<all.length;gi++){
        \\            var cand=all[gi];
        \\            if(cand===el)continue;
        \\            if((cand.name||'')!==gname)continue;
        \\            if(__fo(cand)!==myOwner)continue;
        \\            if(__ro(cand)!==myRoot)continue;
        \\            if(cand.required)anyRequired=true;
        \\            if(cand.checked===true)anyChecked=true;
        \\          }
        \\        }
        \\      }
        \\      valueMissing=anyRequired&&!anyChecked;
        \\    } else if(req){
        \\      if(type==='checkbox'){
        \\        valueMissing=!el.checked;
        \\      } else if(type==='file'){
        \\        var files=el.files;
        \\        valueMissing=!files||files.length===0;
        \\      } else if(tag(el)==='select'){
        \\        valueMissing=val===''||val==null;
        \\      } else {
        \\        valueMissing=val==='';
        \\      }
        \\    }
        \\    var minLen=(el.minLength!=null&&el.minLength>=0)?el.minLength:0;
        \\    var maxLen=(el.maxLength!=null&&el.maxLength>=0)?el.maxLength:Infinity;
        \\    // §4.10.18.3 "suffering from being too short/long" require the
        \\    // element's value to have been edited by the user; programmatic
        \\    // value changes don't trip minlength/maxlength constraints.
        \\    var edited=el._userEdited===true;
        \\    var tooShort=edited&&minLen>0&&val.length>0&&val.length<minLen;
        \\    var tooLong=edited&&val.length>maxLen;
        \\    var numVal=parseFloat(val);
        \\    var minV=parseFloat(el.min);
        \\    var maxV=parseFloat(el.max);
        \\    var rangeUnderflow=!isNaN(numVal)&&!isNaN(minV)&&numVal<minV;
        \\    var rangeOverflow=!isNaN(numVal)&&!isNaN(maxV)&&numVal>maxV;
        \\    var typeMismatch=false;
        \\    if(val!==''){
        \\      if(type==='email'){
        \\        var _emRe=/^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        \\        if(el.hasAttribute&&el.hasAttribute('multiple')){
        \\          var _ems=val.split(',');
        \\          for(var _ei=0;_ei<_ems.length;_ei++){
        \\            if(!_emRe.test(_ems[_ei])){typeMismatch=true;break;}
        \\          }
        \\        }else{
        \\          typeMismatch=!_emRe.test(val);
        \\        }
        \\      }
        \\      if(type==='url'){try{new URL(val);}catch(e){typeMismatch=true;}}
        \\    }
        \\    var patternMismatch=false;
        \\    if(val!==''&&el.pattern){
        \\      // HTML §4.10.5.1.7: invalid regex → treat as no pattern.
        \\      // kotori RegExp doesn't throw on syntactic errors, so do a
        \\      // quick paren/bracket balance check before constructing.
        \\      var __vpat=function(p){
        \\        var par=0,br=false;
        \\        for(var i=0;i<p.length;i++){
        \\          var c=p.charAt(i);
        \\          if(c==='\\'){i++;continue;}
        \\          if(br){if(c===']')br=false;continue;}
        \\          if(c==='[')br=true;
        \\          else if(c==='(')par++;
        \\          else if(c===')'){par--;if(par<0)return false;}
        \\        }
        \\        return par===0&&!br;
        \\      };
        \\      // kotori RegExp doesn't yet implement Unicode property
        \\      // escapes (\p{...}/\P{...}). Skip evaluation for those
        \\      // patterns rather than trip a spurious patternMismatch
        \\      // (treat as no pattern — valid).
        \\      var __unsupportedPat=el.pattern.indexOf('\\p{')!==-1||el.pattern.indexOf('\\P{')!==-1;
        \\      if(__vpat(el.pattern)&&!__unsupportedPat){
        \\        try{patternMismatch=!(new RegExp('^(?:'+el.pattern+')$','u')).test(val);}catch(e){}
        \\      }
        \\    }
        \\    var stepMismatch=false;
        \\    if((type==='number'||type==='range')&&val!==''&&!isNaN(numVal)){
        \\      var stepAttr=el.getAttribute('step');
        \\      if(stepAttr!=='any'){
        \\        var step=parseFloat(stepAttr);
        \\        if(!isFinite(step)||step<=0)step=1;
        \\        var base=0;
        \\        var minAttr=el.getAttribute('min');
        \\        if(minAttr!==null){var mb=parseFloat(minAttr);if(isFinite(mb))base=mb;}
        \\        else if(el.defaultValue){var db=parseFloat(el.defaultValue);if(isFinite(db))base=db;}
        \\        var r=(numVal-base)/step;
        \\        var rounded=Math.round(r);
        \\        var tol=1e-9*Math.max(Math.abs(step),1);
        \\        if(Math.abs((r-rounded)*step)>tol)stepMismatch=true;
        \\      }
        \\    }
        \\    if(!stepMismatch&&val!==''&&(type==='date'||type==='time'||type==='datetime-local'||type==='month'||type==='week')){
        \\      var nv=parseDTV(val,type);
        \\      if(nv!==null){
        \\        var scale=1,defStep=1;
        \\        if(type==='date'){scale=86400000;defStep=1;}
        \\        else if(type==='week'){scale=604800000;defStep=1;}
        \\        else if(type==='month'){scale=1;defStep=1;}
        \\        else if(type==='time'||type==='datetime-local'){scale=1000;defStep=60;}
        \\        var stepAttrD=el.getAttribute('step');
        \\        if(stepAttrD!=='any'){
        \\          var stepD=(stepAttrD===null||stepAttrD==='')?defStep:parseFloat(stepAttrD);
        \\          if(!isFinite(stepD)||stepD<=0)stepD=defStep;
        \\          var baseD=null;
        \\          var minAttrD=el.getAttribute('min');
        \\          if(minAttrD!==null&&minAttrD!=='')baseD=parseDTV(minAttrD,type);
        \\          if(baseD===null){
        \\            if(type==='date'||type==='datetime-local'||type==='time')baseD=0;
        \\            else if(type==='week')baseD=Date.UTC(1969,11,29);
        \\            else if(type==='month')baseD=1970*12;
        \\          }
        \\          var unit=stepD*scale;
        \\          var ratio=(nv-baseD)/unit;
        \\          var roundedD=Math.round(ratio);
        \\          var tolD=1e-9*Math.max(Math.abs(unit),1);
        \\          if(Math.abs((ratio-roundedD)*unit)>tolD)stepMismatch=true;
        \\        }
        \\      }
        \\    }
        \\    var valid=!valueMissing&&!tooShort&&!tooLong&&!rangeUnderflow&&!rangeOverflow&&!typeMismatch&&!patternMismatch&&!stepMismatch&&!customError;
        \\    var vs=Object.create(VS_PROTO);
        \\    vs.valueMissing=valueMissing;vs.tooShort=tooShort;vs.tooLong=tooLong;
        \\    vs.rangeUnderflow=rangeUnderflow;vs.rangeOverflow=rangeOverflow;
        \\    vs.typeMismatch=typeMismatch;vs.patternMismatch=patternMismatch;
        \\    vs.stepMismatch=stepMismatch;vs.customError=customError;
        \\    vs.badInput=false;vs.valid=valid;
        \\    return vs;
        \\  }
        \\  try{Object.defineProperty(EP,'willValidate',{
        \\    get:function(){return willVal(this);},
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(EP,'validity',{
        \\    get:function(){
        \\      if(!isSubmittable(this))return undefined;
        \\      return makeValidity(this);
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(EP,'validationMessage',{
        \\    get:function(){
        \\      if(!willVal(this))return '';
        \\      var vs=makeValidity(this);
        \\      if(vs.valid)return '';
        \\      var m=this._customValidationMessage||'';
        \\      return m!==''?m:'Please fill out this field.';
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  EP.checkValidity=function(){
        \\    // HTML §4.10.22.2: forms aggregate their submittable controls.
        \\    if(tag(this)==='form'){
        \\      var ctrls=this.elements||this.querySelectorAll('input,textarea,select,button');
        \\      var allValid=true;
        \\      for(var i=0;i<ctrls.length;i++){
        \\        var c=ctrls[i];
        \\        if(c.checkValidity&&!c.checkValidity())allValid=false;
        \\      }
        \\      if(!allValid){
        \\        try{var fe=new Event('invalid',{bubbles:false,cancelable:true});this.dispatchEvent(fe);}catch(e){}
        \\      }
        \\      return allValid;
        \\    }
        \\    if(!willVal(this))return true;
        \\    var v=makeValidity(this);
        \\    if(v.valid)return true;
        \\    var ev=new Event('invalid',{bubbles:false,cancelable:true});
        \\    this.dispatchEvent(ev);
        \\    return false;
        \\  };
        \\  EP.reportValidity=function(){return this.checkValidity();};
        \\  EP.setCustomValidity=function(msg){
        \\    this._customValidationMessage=msg==null?'':String(msg);
        \\  };
        \\  // ── matches(":valid"|":invalid") delegate to validity polyfill ──
        \\  // The native selector engine only checks required+empty; for
        \\  // patternMismatch / typeMismatch / rangeUnderflow / etc. the
        \\  // JS validity polyfill is the authority. Wrap matches() so
        \\  // these two pseudo-classes route through validity.valid.
        \\  if(typeof EP.matches==='function'){
        \\    var _origMatches=EP.matches;
        \\    EP.matches=function(sel){
        \\      if(typeof sel==='string'){
        \\        var trimmed=String(sel).toLowerCase();
        \\        if(trimmed===':invalid'||trimmed===':valid'){
        \\          if(isSubmittable(this)&&willVal(this)){
        \\            var v=makeValidity(this);
        \\            if(trimmed===':invalid')return !v.valid;
        \\            return v.valid;
        \\          }
        \\          // Non-submittable / non-validatable elements never
        \\          // match :valid or :invalid. Fall through to native
        \\          // for fieldset/form aggregate handling.
        \\        }
        \\      }
        \\      return _origMatches.call(this,sel);
        \\    };
        \\  }
        \\  // ── querySelectorAll(":valid"|":invalid") delegate to matches() ──
        \\  // The native selector engine evaluates :valid/:invalid with a
        \\  // simplified required+empty-value check that misses
        \\  // patternMismatch / typeMismatch / rangeUnderflow. Route the
        \\  // bare-selector form through enumerate + Element.matches() so
        \\  // the JS validity polyfill is the authority for both surfaces.
        \\  function _qsaValidity(root,want){
        \\    var out=[];
        \\    if(!root)return out;
        \\    var stack=[root];
        \\    while(stack.length){
        \\      var node=stack.pop();
        \\      if(node!==root&&node&&node.nodeType===1){
        \\        var t=(node.tagName||'').toLowerCase();
        \\        if(t==='input'||t==='select'||t==='textarea'||t==='button'||t==='fieldset'||t==='form'||t==='output'){
        \\          try{ if(node.matches&&node.matches(want))out.push(node); }catch(e){}
        \\        }
        \\      }
        \\      var ch=node&&node.children;
        \\      if(ch){ for(var qi=ch.length-1;qi>=0;qi--)stack.push(ch[qi]); }
        \\    }
        \\    return out;
        \\  }
        \\  function _wrapQSA(orig){
        \\    return function(sel){
        \\      if(typeof sel==='string'){
        \\        var qt=String(sel).trim().toLowerCase();
        \\        if(qt===':invalid'||qt===':valid')return _qsaValidity(this,qt);
        \\      }
        \\      return orig.call(this,sel);
        \\    };
        \\  }
        \\  if(typeof EP.querySelectorAll==='function'){
        \\    EP.querySelectorAll=_wrapQSA(EP.querySelectorAll);
        \\  }
        \\  if(typeof document!=='undefined'&&typeof document.querySelectorAll==='function'){
        \\    try{ document.querySelectorAll=_wrapQSA(document.querySelectorAll); }catch(e){}
        \\  }
        \\})();
    ;

    /// HTML §4.10.5.1.8 / §4.10.11.3 — Text field selection API for kotori.
    ///
    /// Installs selectionStart / selectionEnd / selectionDirection
    /// IDL attributes and select() / setSelectionRange() / setRangeText()
    /// methods on Element.prototype with tag-and-type branching, matching
    /// form_state_polyfill_js's convention. Per-element selection state
    /// lives in `_selStart`, `_selEnd`, `_selDir` slots.
    ///
    /// Restricted to <textarea> and <input type=text|search|url|tel|password>
    /// per spec ("applicable element"). Accessing these on other types
    /// throws InvalidStateError.
    const selection_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function isTextType(el){
        \\    var t=tag(el);
        \\    if(t==='textarea')return true;
        \\    if(t!=='input')return false;
        \\    var it=(el.type||'text').toLowerCase();
        \\    return it==='text'||it==='search'||it==='url'||it==='tel'||it==='password';
        \\  }
        \\  function valLen(el){var v=el.value;return v==null?0:String(v).length;}
        \\  function clamp(n,max){if(typeof n!=='number'||n<0||!isFinite(n))n=0;else n=Math.floor(n);return n>max?max:n;}
        \\  function throwInv(){throw new DOMException('The element does not support selection.','InvalidStateError');}
        \\  function fireSelect(el){
        \\    try{var ev=new Event('select',{bubbles:true,cancelable:false});el.dispatchEvent(ev);}catch(e){}
        \\  }
        \\  try{Object.defineProperty(EP,'selectionStart',{
        \\    get:function(){
        \\      if(!isTextType(this))return null;
        \\      var s=this._selStart;
        \\      return s==null?valLen(this):clamp(s,valLen(this));
        \\    },
        \\    set:function(v){
        \\      if(!isTextType(this))throwInv();
        \\      v=clamp(v,valLen(this));
        \\      this._selStart=v;
        \\      var e=this._selEnd;
        \\      if(e==null||v>e)this._selEnd=v;
        \\      if(this._selDir==null)this._selDir='none';
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(EP,'selectionEnd',{
        \\    get:function(){
        \\      if(!isTextType(this))return null;
        \\      var e=this._selEnd;
        \\      return e==null?valLen(this):clamp(e,valLen(this));
        \\    },
        \\    set:function(v){
        \\      if(!isTextType(this))throwInv();
        \\      v=clamp(v,valLen(this));
        \\      this._selEnd=v;
        \\      if(this._selDir==null)this._selDir='none';
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(EP,'selectionDirection',{
        \\    get:function(){
        \\      if(!isTextType(this))return null;
        \\      return this._selDir||'none';
        \\    },
        \\    set:function(v){
        \\      if(!isTextType(this))throwInv();
        \\      v=String(v);
        \\      if(v!=='forward'&&v!=='backward'&&v!=='none')v='none';
        \\      this._selDir=v;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  EP.select=function(){
        \\    if(!isTextType(this))return;
        \\    this._selStart=0;
        \\    this._selEnd=valLen(this);
        \\    this._selDir='none';
        \\    fireSelect(this);
        \\  };
        \\  EP.setSelectionRange=function(start,end,dir){
        \\    if(!isTextType(this))throwInv();
        \\    var len=valLen(this);
        \\    start=clamp(start,len);
        \\    end=clamp(end,len);
        \\    if(end<start)end=start;
        \\    this._selStart=start;
        \\    this._selEnd=end;
        \\    if(dir==='forward'||dir==='backward')this._selDir=dir;
        \\    else this._selDir='none';
        \\    fireSelect(this);
        \\  };
        \\  EP.setRangeText=function(replacement,start,end,selectionMode){
        \\    if(!isTextType(this))throwInv();
        \\    replacement=replacement==null?'':String(replacement);
        \\    var cur=this.value==null?'':String(this.value);
        \\    var len=cur.length;
        \\    var selStart=this._selStart==null?len:clamp(this._selStart,len);
        \\    var selEnd=this._selEnd==null?len:clamp(this._selEnd,len);
        \\    if(arguments.length<2){start=selStart;end=selEnd;}
        \\    start=start>>>0;end=end>>>0;
        \\    if(end<start)throw new DOMException('The end index is before the start index.','IndexSizeError');
        \\    if(start>len)start=len;
        \\    if(end>len)end=len;
        \\    var newVal=cur.slice(0,start)+replacement+cur.slice(end);
        \\    this.value=newVal;
        \\    var newEnd=start+replacement.length;
        \\    var mode=selectionMode||'preserve';
        \\    if(mode==='select'){this._selStart=start;this._selEnd=newEnd;}
        \\    else if(mode==='start'){this._selStart=start;this._selEnd=start;}
        \\    else if(mode==='end'){this._selStart=newEnd;this._selEnd=newEnd;}
        \\    else {
        \\      // preserve: adjust old selection relative to insertion
        \\      var delta=replacement.length-(end-start);
        \\      var os=selStart,oe=selEnd;
        \\      if(os>end)os+=delta;
        \\      else if(os>start)os=start+replacement.length;
        \\      if(oe>end)oe+=delta;
        \\      else if(oe>start)oe=start+replacement.length;
        \\      var nlen=newVal.length;
        \\      if(os<0)os=0;if(os>nlen)os=nlen;
        \\      if(oe<0)oe=0;if(oe>nlen)oe=nlen;
        \\      this._selStart=os;this._selEnd=oe;
        \\    }
        \\    this._selDir='none';
        \\    fireSelect(this);
        \\  };
        \\})();
    ;

    /// HTML §4.10.5.1.12 / §4.10.5.1.13 — Numeric input API.
    ///
    /// Installs valueAsNumber (getter/setter) and stepUp(n) / stepDown(n)
    /// methods. For type=number, parses/formats floats. For type=range,
    /// same treatment. Date / time / datetime-local / month / week inputs
    /// use the unit-scale parsers shared with the stepMismatch algorithm.
    ///
    /// Spec rules:
    ///   valueAsNumber getter: NaN if parse fails
    ///   valueAsNumber setter: TypeError if input type is not "applicable",
    ///     otherwise set value to canonical string form
    ///   stepUp/stepDown: multiply allowed steps, clamp to min/max,
    ///     InvalidStateError if input has no step
    const input_numeric_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function itype(el){return (el.type||'').toLowerCase();}
        \\  function isNumericApplicable(el){
        \\    if(tag(el)!=='input')return false;
        \\    var t=itype(el);
        \\    return t==='number'||t==='range'||t==='date'||t==='time'||t==='datetime-local'||t==='month'||t==='week';
        \\  }
        \\  // Parse current value into numeric representation per type.
        \\  // Returns NaN if invalid. Unit: number/range → raw float;
        \\  // date/week/datetime-local/time → ms; month → months-since-yr0.
        \\  function parseVal(el){
        \\    var t=itype(el);
        \\    var v=el.value;if(v==null||v==='')return NaN;
        \\    v=String(v);
        \\    var m;
        \\    if(t==='number'||t==='range'){var n=parseFloat(v);return isNaN(n)?NaN:n;}
        \\    if(t==='date'){m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(v);if(!m)return NaN;return Date.UTC(+m[1],+m[2]-1,+m[3]);}
        \\    if(t==='datetime-local'){m=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?$/.exec(v);if(!m)return NaN;var sec=m[6]?parseFloat(m[6]):0;return Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5],Math.floor(sec),Math.round((sec-Math.floor(sec))*1000));}
        \\    if(t==='time'){m=/^(\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?$/.exec(v);if(!m)return NaN;var s2=m[3]?parseFloat(m[3]):0;return (+m[1])*3600000+(+m[2])*60000+Math.round(s2*1000);}
        \\    if(t==='month'){m=/^(\d{4})-(\d{2})$/.exec(v);if(!m)return NaN;return (+m[1])*12+(+m[2])-1;}
        \\    if(t==='week'){m=/^(\d{4})-W(\d{2})$/.exec(v);if(!m)return NaN;var y=+m[1],w=+m[2];var jan4=new Date(Date.UTC(y,0,4));var dow=jan4.getUTCDay()||7;var mon1=Date.UTC(y,0,4-dow+1);return mon1+(w-1)*604800000;}
        \\    return NaN;
        \\  }
        \\  function pad(n,w){n=String(n);while(n.length<w)n='0'+n;return n;}
        \\  // Format numeric representation back to string per type.
        \\  function formatVal(el,num){
        \\    var t=itype(el);
        \\    if(t==='number'||t==='range'){
        \\      if(!isFinite(num))return '';
        \\      // Canonical float: no trailing zeros. toString is close enough.
        \\      return String(num);
        \\    }
        \\    if(t==='date'){var d=new Date(num);if(isNaN(d.getTime()))return '';return pad(d.getUTCFullYear(),4)+'-'+pad(d.getUTCMonth()+1,2)+'-'+pad(d.getUTCDate(),2);}
        \\    if(t==='datetime-local'){var d=new Date(num);if(isNaN(d.getTime()))return '';var base=pad(d.getUTCFullYear(),4)+'-'+pad(d.getUTCMonth()+1,2)+'-'+pad(d.getUTCDate(),2)+'T'+pad(d.getUTCHours(),2)+':'+pad(d.getUTCMinutes(),2);var s=d.getUTCSeconds(),ms=d.getUTCMilliseconds();if(s>0||ms>0){base+=':'+pad(s,2);if(ms>0)base+='.'+pad(ms,3);}return base;}
        \\    if(t==='time'){num=num%86400000;if(num<0)num+=86400000;var h=Math.floor(num/3600000);var mm=Math.floor((num%3600000)/60000);var s=Math.floor((num%60000)/1000);var ms=Math.floor(num%1000);var base=pad(h,2)+':'+pad(mm,2);if(s>0||ms>0){base+=':'+pad(s,2);if(ms>0)base+='.'+pad(ms,3);}return base;}
        \\    if(t==='month'){var y=Math.floor(num/12);var mo=(num%12)+1;return pad(y,4)+'-'+pad(mo,2);}
        \\    if(t==='week'){var d=new Date(num);if(isNaN(d.getTime()))return '';var y=d.getUTCFullYear();var jan4=new Date(Date.UTC(y,0,4));var dow=jan4.getUTCDay()||7;var mon1=Date.UTC(y,0,4-dow+1);var w=Math.floor((num-mon1)/604800000)+1;if(w<1){y-=1;jan4=new Date(Date.UTC(y,0,4));dow=jan4.getUTCDay()||7;mon1=Date.UTC(y,0,4-dow+1);w=Math.floor((num-mon1)/604800000)+1;}return pad(y,4)+'-W'+pad(w,2);}
        \\    return '';
        \\  }
        \\  function scale(el){
        \\    var t=itype(el);
        \\    if(t==='date')return 86400000;
        \\    if(t==='week')return 604800000;
        \\    if(t==='month')return 1;
        \\    if(t==='time'||t==='datetime-local')return 1000;
        \\    return 1;
        \\  }
        \\  function defStep(el){
        \\    var t=itype(el);
        \\    if(t==='time'||t==='datetime-local')return 60;
        \\    return 1;
        \\  }
        \\  function readStep(el){
        \\    var a=el.getAttribute('step');
        \\    if(a==='any')return null;
        \\    var ds=defStep(el);
        \\    if(a===null||a==='')return ds;
        \\    var s=parseFloat(a);
        \\    if(!isFinite(s)||s<=0)return ds;
        \\    return s;
        \\  }
        \\  function readBase(el){
        \\    var t=itype(el);
        \\    var mn=el.getAttribute('min');
        \\    if(mn!==null&&mn!==''){
        \\      if(t==='number'||t==='range'){var n=parseFloat(mn);if(isFinite(n))return n;}
        \\      else {
        \\        // shim parse via parseVal by briefly writing
        \\        var oldv=el.value;
        \\        try{el.value=mn;var pv=parseVal(el);el.value=oldv;if(!isNaN(pv))return pv;}catch(e){el.value=oldv;}
        \\      }
        \\    }
        \\    if(t==='number'||t==='range'){
        \\      var dv=el.defaultValue;
        \\      if(dv){var n2=parseFloat(dv);if(isFinite(n2))return n2;}
        \\      return 0;
        \\    }
        \\    if(t==='week')return Date.UTC(1969,11,29);
        \\    if(t==='month')return 1970*12;
        \\    return 0;
        \\  }
        \\  try{Object.defineProperty(EP,'valueAsNumber',{
        \\    get:function(){
        \\      if(!isNumericApplicable(this))return NaN;
        \\      var t=itype(this);
        \\      var raw=parseVal(this);
        \\      if(isNaN(raw))return NaN;
        \\      // For number/range, the value is raw. For date types,
        \\      // spec says valueAsNumber returns milliseconds since epoch
        \\      // except for month which returns months-since-1970-01.
        \\      if(t==='month')return raw-1970*12;
        \\      return raw;
        \\    },
        \\    set:function(v){
        \\      if(!isNumericApplicable(this))throw new TypeError('valueAsNumber not applicable');
        \\      var n=Number(v);
        \\      // HTML §4.10.5.7: NaN → set value to empty string. Infinity /
        \\      // -Infinity → throw TypeError. Finite number → format & set.
        \\      if(n!==n){this.value='';return;}
        \\      if(n===Infinity||n===-Infinity)throw new TypeError('valueAsNumber: not a finite number');
        \\      var t=itype(this);
        \\      if(t==='month')n=n+1970*12;
        \\      this.value=formatVal(this,n);
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(EP,'valueAsDate',{
        \\    get:function(){
        \\      if(!isNumericApplicable(this))return null;
        \\      var t=itype(this);
        \\      // HTML §4.10.5.7: valueAsDate applies to date, month, week, time.
        \\      // number, range, datetime-local return null (the latter has a
        \\      // separate spec carve-out — it returns null since it has no
        \\      // single zone-anchored Date representation).
        \\      if(t==='number'||t==='range'||t==='datetime-local')return null;
        \\      var raw=parseVal(this);
        \\      if(isNaN(raw))return null;
        \\      var ms=raw;
        \\      if(t==='month')ms=Date.UTC(Math.floor(raw/12),raw%12,1);
        \\      // time: parseVal returns ms-since-midnight; the Date is anchored
        \\      // at 1970-01-01 00:00:00 UTC, so passing ms directly yields the
        \\      // right time-of-day on the epoch day.
        \\      return new Date(ms);
        \\    },
        \\    set:function(v){
        \\      var t=itype(this);
        \\      // HTML §4.10.5.7: valueAsDate setter throws
        \\      // InvalidStateError for non-applicable types. number, range,
        \\      // and datetime-local don't support valueAsDate (Mozilla bug
        \\      // 1933351 removed datetime-local from the spec list).
        \\      if(!isNumericApplicable(this)||t==='number'||t==='range'||t==='datetime-local')
        \\        throw new DOMException('valueAsDate setter not applicable for type='+t,'InvalidStateError');
        \\      if(v===null){this.value='';return;}
        \\      if(!(v instanceof Date))throw new TypeError('not a Date');
        \\      var ms=v.getTime();if(isNaN(ms)){this.value='';return;}
        \\      if(t==='month'){var nm=v.getUTCFullYear()*12+v.getUTCMonth();this.value=formatVal(this,nm);}
        \\      else this.value=formatVal(this,ms);
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  function stepBy(el,n){
        \\    if(!isNumericApplicable(el))throw new DOMException('stepUp/stepDown not applicable','InvalidStateError');
        \\    var step=readStep(el);
        \\    if(step===null)throw new DOMException('step=any forbids stepUp/stepDown','InvalidStateError');
        \\    var cur=parseVal(el);
        \\    // HTML §4.10.5.1.13 step 6: if value is empty or NaN, both value
        \\    // and valueBeforeStepping default to 0. The empty case is also
        \\    // exempt from the §10 direction-abort: stepDown on an empty
        \\    // input with min="7" produces "7" (snap into range), not no-op.
        \\    var wasEmpty=isNaN(cur);
        \\    if(wasEmpty)cur=0;
        \\    var valueBeforeStepping=cur;
        \\    var base=readBase(el);
        \\    var sc=scale(el);
        \\    // Read min/max bounds once.
        \\    var mn_val=null, mx_val=null;
        \\    var mnAttr=el.getAttribute('min');
        \\    if(mnAttr!==null&&mnAttr!==''){
        \\      var old=el.value;try{el.value=mnAttr;var pmn=parseVal(el);el.value=old;if(!isNaN(pmn))mn_val=pmn;}catch(e){el.value=old;}
        \\    }
        \\    var mxAttr=el.getAttribute('max');
        \\    if(mxAttr!==null&&mxAttr!==''){
        \\      var old2=el.value;try{el.value=mxAttr;var pmx=parseVal(el);el.value=old2;if(!isNaN(pmx))mx_val=pmx;}catch(e){el.value=old2;}
        \\    }
        \\    // §4.10.5.1.13 step 3: if min > max, return.
        \\    if(mn_val!==null&&mx_val!==null&&mn_val>mx_val)return;
        \\    var delta=n*step*sc;
        \\    var next=cur+delta;
        \\    // Snap to step grid based on base (§7 alignment).
        \\    var units=Math.round((next-base)/(step*sc));
        \\    next=base+units*step*sc;
        \\    // §8 clamp to min: smallest value >= min that's an integral
        \\    // multiple of step from base.
        \\    if(mn_val!==null&&next<mn_val){
        \\      var minUnits=Math.ceil((mn_val-base)/(step*sc));
        \\      next=base+minUnits*step*sc;
        \\      if(next<mn_val)next+=step*sc;
        \\    }
        \\    // §9 clamp to max: largest value <= max that's an integral
        \\    // multiple of step from base.
        \\    if(mx_val!==null&&next>mx_val){
        \\      var maxUnits=Math.floor((mx_val-base)/(step*sc));
        \\      next=base+maxUnits*step*sc;
        \\      if(next>mx_val)next-=step*sc;
        \\    }
        \\    // §10: if the chosen direction would cross valueBeforeStepping
        \\    // (i.e., stepDown ended up >, or stepUp ended up <), return
        \\    // without modifying. Skipped when value was originally empty —
        \\    // empty inputs snap into [min,max] regardless of direction
        \\    // (input-stepdown-02 "no initial value and positive min").
        \\    if(!wasEmpty){
        \\      if(n<0&&next>valueBeforeStepping)return;
        \\      if(n>0&&next<valueBeforeStepping)return;
        \\    }
        \\    el.value=formatVal(el,next);
        \\  }
        \\  EP.stepUp=function(n){if(n==null)n=1;var k=Math.trunc(Number(n));if(!isFinite(k)||k===0)k=1;stepBy(this,k);};
        \\  EP.stepDown=function(n){if(n==null)n=1;var k=Math.trunc(Number(n));if(!isFinite(k)||k===0)k=1;stepBy(this,-k);};
        \\})();
    ;

    /// HTML §4.10.5.1.20 / §6.3 "activation behavior" — HTMLElement.click()
    ///
    /// kotori has no native click() method on Element.prototype. This
    /// polyfill implements the spec's activation behavior:
    ///   1. Dispatch a synthetic 'click' MouseEvent (bubbles, cancelable).
    ///   2. If the event was canceled (preventDefault), stop.
    ///   3. Perform activation behavior for the element type:
    ///      - input type=checkbox: toggle checkedness
    ///      - input type=radio: uncheck all radios in the same form+name
    ///        group, check the clicked one
    ///      - input type=submit / button type=submit: form.requestSubmit()
    ///      - input type=reset / button type=reset: form.reset()
    ///
    /// Tests that click on radios to trigger group-wide state changes
    /// (valueMissing re-evaluation, change-event firing) fail without this.
    const click_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function itype(el){return (el.type||'').toLowerCase();}
        \\  EP.click=function(){
        \\    if(this.disabled)return;
        \\    // HTML §4.10.5 + DOM §3.7 synthetic-click activation steps.
        \\    // kotori's native dispatchEvent does NOT run the events.zig
        \\    // pre/post-activation block, so the polyfill is the only path
        \\    // that toggles checked + fires the input/change pair.
        \\    var t=tag(this);
        \\    var it=itype(this);
        \\    var ev;
        \\    try{ev=new MouseEvent('click',{bubbles:true,cancelable:true,view:typeof window!=='undefined'?window:null});}
        \\    catch(e){ev=new Event('click',{bubbles:true,cancelable:true});}
        \\    // Mark so the dispatchEvent activation hook below doesn't
        \\    // double-process this click — .click() pre-toggles + posts
        \\    // input/change itself.
        \\    try{ev._fromClick=true;}catch(e){}
        \\    // §4.10.5.1 pre-activation: toggle checkedness BEFORE click
        \\    // dispatch so onclick handlers see the new state.
        \\    var preChecked=this.checked, preIndet=this.indeterminate;
        \\    // For radio: snapshot the entire group (so we can revert ALL
        \\    // siblings if the click is canceled — the IDL setter unchecks
        \\    // the prior winner, and preventDefault must restore it).
        \\    var radioSnapshot=null;
        \\    if(t==='input'&&it==='checkbox'){
        \\      this.checked=!preChecked;
        \\      if(this.indeterminate!==undefined)this.indeterminate=false;
        \\    } else if(t==='input'&&it==='radio'){
        \\      var rname=(this.getAttribute&&this.getAttribute('name'))||'';
        \\      if(rname!==''){
        \\        radioSnapshot=[];
        \\        var rt=(typeof this.getRootNode==='function')?this.getRootNode():(this.ownerDocument||this);
        \\        if(rt&&rt.querySelectorAll){
        \\          var rsibs=rt.querySelectorAll('input[type=radio]');
        \\          for(var rsi=0;rsi<rsibs.length;rsi++){
        \\            var rs=rsibs[rsi];
        \\            if(((rs.getAttribute&&rs.getAttribute('name'))||'')===rname){
        \\              radioSnapshot.push({el:rs,checked:rs.checked===true,dirty:rs._dirtyChecked===true});
        \\            }
        \\          }
        \\        }
        \\      }
        \\      // §4.10.5.1.16 group exclusivity via IDL setter.
        \\      this.checked=true;
        \\    }
        \\    var notCanceled=this.dispatchEvent(ev);
        \\    if(t==='input'&&(it==='checkbox'||it==='radio')){
        \\      if(!notCanceled){
        \\        if(radioSnapshot){
        \\          // Revert all group siblings (the prior checked one was
        \\          // unset by the IDL setter; restore it).
        \\          for(var rk=0;rk<radioSnapshot.length;rk++){
        \\            var sn=radioSnapshot[rk];
        \\            sn.el._dirtyChecked=sn.dirty;
        \\            sn.el._checked=sn.checked;
        \\          }
        \\        } else {
        \\          this.checked=preChecked;
        \\        }
        \\        if(this.indeterminate!==undefined)this.indeterminate=preIndet;
        \\        return;
        \\      }
        \\      // §4.10.5.1: input + change events from a synthetic activation
        \\      // are TRUSTED (the click event itself is untrusted per spec).
        \\      // Skip for detached elements — WPT
        \\      // Event-dispatch-detached-input-and-change expects no
        \\      // input/change firing on click() of a not-connected input.
        \\      if(this.isConnected===true){
        \\        try{var inp=new Event('input',{bubbles:true,cancelable:false});inp._trusted=true;this.dispatchEvent(inp);}catch(e){}
        \\        try{var chg=new Event('change',{bubbles:true,cancelable:false});chg._trusted=true;this.dispatchEvent(chg);}catch(e){}
        \\      }
        \\      return;
        \\    }
        \\    if(!notCanceled)return;
        \\    if((t==='input'&&(it==='submit'||it==='image'))||(t==='button'&&(it==='submit'||it===''))){
        \\      var form=this.form;
        \\      if(form&&typeof form.requestSubmit==='function'){
        \\        try{form.requestSubmit(this);}catch(e){}
        \\      }
        \\    } else if((t==='input'&&it==='reset')||(t==='button'&&it==='reset')){
        \\      var form2=this.form;
        \\      if(form2&&typeof form2.reset==='function'){
        \\        try{form2.reset();}catch(e){}
        \\      }
        \\    }
        \\  };
        \\  // ── dispatchEvent activation hook (DOM §3 "synthetic click activation
        \\  // steps") — when JS calls
        \\  // `el.dispatchEvent(new MouseEvent('click', {cancelable:true}))`
        \\  // directly on a checkbox/radio, the kotori native dispatch path
        \\  // skips activation behavior. Hook EP.dispatchEvent so the same
        \\  // pre-toggle + revert/post-fire flow used by .click() runs for
        \\  // direct cancelable click events too. The `_fromClick` flag
        \\  // (set by the .click() polyfill above) prevents double-handling
        \\  // when click() itself dispatches.
        \\  var _origDispatch=EP.dispatchEvent;
        \\  if(typeof _origDispatch==='function'){
        \\    EP.dispatchEvent=function(ev){
        \\      var t=tag(this),it=itype(this);
        \\      var isCheckable=t==='input'&&(it==='checkbox'||it==='radio');
        \\      // Activation behavior fires only for MouseEvent (or
        \\      // subclass) click events — `new Event('click')` is the
        \\      // base Event and does NOT trigger activation per spec.
        \\      var isMouseClick=ev&&ev.type==='click'&&typeof MouseEvent!=='undefined'&&ev instanceof MouseEvent;
        \\      if(!isCheckable||!isMouseClick||ev._fromClick){
        \\        return _origDispatch.call(this,ev);
        \\      }
        \\      // Synthetic click activation: pre-toggle, dispatch, revert
        \\      // or post-fire input+change.
        \\      var preChecked=this.checked, preIndet=this.indeterminate;
        \\      var radioSnapshot=null;
        \\      if(it==='checkbox'){
        \\        this.checked=!preChecked;
        \\        if(this.indeterminate!==undefined)this.indeterminate=false;
        \\      } else {
        \\        var rname=(this.getAttribute&&this.getAttribute('name'))||'';
        \\        if(rname!==''){
        \\          radioSnapshot=[];
        \\          var rt=(typeof this.getRootNode==='function')?this.getRootNode():(this.ownerDocument||this);
        \\          if(rt&&rt.querySelectorAll){
        \\            var rsibs=rt.querySelectorAll('input[type=radio]');
        \\            for(var rsi=0;rsi<rsibs.length;rsi++){
        \\              var rs=rsibs[rsi];
        \\              if(((rs.getAttribute&&rs.getAttribute('name'))||'')===rname){
        \\                radioSnapshot.push({el:rs,checked:rs.checked===true,dirty:rs._dirtyChecked===true});
        \\              }
        \\            }
        \\          }
        \\        }
        \\        this.checked=true;
        \\      }
        \\      var notCanceled=_origDispatch.call(this,ev);
        \\      if(!notCanceled){
        \\        if(radioSnapshot){
        \\          for(var rk=0;rk<radioSnapshot.length;rk++){
        \\            var sn=radioSnapshot[rk];
        \\            sn.el._dirtyChecked=sn.dirty;
        \\            sn.el._checked=sn.checked;
        \\          }
        \\        } else {
        \\          this.checked=preChecked;
        \\        }
        \\        if(this.indeterminate!==undefined)this.indeterminate=preIndet;
        \\        return notCanceled;
        \\      }
        \\      // Detached elements skip input/change firing per WPT
        \\      // Event-dispatch-detached-input-and-change.
        \\      if(this.isConnected===true){
        \\        try{var inp=new Event('input',{bubbles:true,cancelable:false});inp._trusted=true;_origDispatch.call(this,inp);}catch(e){}
        \\        try{var chg=new Event('change',{bubbles:true,cancelable:false});chg._trusted=true;_origDispatch.call(this,chg);}catch(e){}
        \\      }
        \\      return notCanceled;
        \\    };
        \\  }
        \\})();
    ;

    /// HTML §6.6.3 focus management — HTMLElement.focus() / .blur() and
    /// document.activeElement getter.
    ///
    /// kotori has no native focus tracking. Tests that check focus
    /// preservation across DOM mutations (e.g. input-type-change-value
    /// "With focus") need this minimal polyfill:
    ///   - el.focus(): records `el` as the active element on the document.
    ///   - el.blur(): clears the active element if it equals `el`.
    ///   - document.activeElement: returns the recorded focused element,
    ///     or document.body when nothing is focused (per spec default).
    /// No focus event dispatch yet — tests that check focus/blur events
    /// will still fail, but identity-based tests (activeElement === el)
    /// pass.
    const focus_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  if(typeof document==='undefined')return;
        \\  var EP=Element.prototype;
        \\  EP.focus=function(){
        \\    // HTML §6.6.3: disabled form controls cannot be focused.
        \\    if(this.disabled===true)return;
        \\    try{document._activeElement=this;}catch(e){}
        \\  };
        \\  EP.blur=function(){
        \\    try{if(document._activeElement===this)document._activeElement=null;}catch(e){}
        \\  };
        \\  try{Object.defineProperty(document,'activeElement',{
        \\    get:function(){
        \\      var ae=this._activeElement;
        \\      if(ae)return ae;
        \\      return this.body||null;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  // Convenience: document.hasFocus() returns true (we always claim
        \\  // focus in WPT mode; no window blur tracking).
        \\  try{document.hasFocus=function(){return true;};}catch(e){}
        \\  // HTML §3.1.4 — Document.defaultView returns the document's
        \\  // associated Window. WPT tests like html/dom/elements/global-attributes/
        \\  // id-attribute.html use `document.defaultView.getComputedStyle(...)`.
        \\  try{
        \\    if(typeof window!=='undefined'&&!document.defaultView){
        \\      Object.defineProperty(document,'defaultView',{
        \\        get:function(){return window;},
        \\        configurable:true,enumerable:true
        \\      });
        \\    }
        \\  }catch(e){}
        \\  // HTML §3.1.5 — document.getElementsByName(name) returns a
        \\  // NodeList of elements whose `name` content attribute equals
        \\  // the given name. Per spec it's also restricted to certain
        \\  // element types (a, applet, button, form, etc.) but in
        \\  // practice browsers return any element with matching name.
        \\  try{
        \\    if(typeof document.getElementsByName!=='function'){
        \\      document.getElementsByName=function(name){
        \\        var n=String(name);
        \\        var all=document.getElementsByTagName('*');
        \\        var result=[];
        \\        for(var i=0;i<all.length;i++){
        \\          var el=all[i];
        \\          if(el.getAttribute&&el.getAttribute('name')===n){
        \\            result.push(el);
        \\          }
        \\        }
        \\        return result;
        \\      };
        \\    }
        \\  }catch(e){}
        \\})();
    ;

    // ── Native WHATWG URL bindings (src/url/parser.zig) ─────────────

    /// Intern `value` and bind it on `obj` under `name`.
    fn setStringProp(vm: *VM, obj: *JsObject, name: []const u8, value: []const u8) !void {
        const key = try vm.pool.intern(name);
        const val = try vm.pool.intern(value);
        try obj.setProperty(vm.allocator, key, JsValue.initString(val));
    }

    /// URL Standard §4.8: serialize a URL's origin. Tuple origin for
    /// special schemes (http/https/ws/wss/ftp), the inner URL's origin
    /// for blob:, opaque origin ("null") for everything else including
    /// file: (implementation-defined; matches WPT expectations).
    fn urlOriginString(allocator: std.mem.Allocator, url: *const url_parser.Url) ![]u8 {
        const special = std.mem.eql(u8, url.scheme, "http") or
            std.mem.eql(u8, url.scheme, "https") or
            std.mem.eql(u8, url.scheme, "ws") or
            std.mem.eql(u8, url.scheme, "wss") or
            std.mem.eql(u8, url.scheme, "ftp");
        if (special) return url.serializeOrigin(allocator);
        if (std.mem.eql(u8, url.scheme, "blob")) {
            const inner_str = switch (url.path) {
                .opaque_path => |p| p,
                .list => |l| if (l.items.len > 0) l.items[0] else return allocator.dupe(u8, "null"),
            };
            var inner = (url_parser.parse(allocator, inner_str, null) catch null) orelse
                return allocator.dupe(u8, "null");
            defer inner.deinit();
            // Guard against blob:blob:... recursion: inner must be special.
            const inner_special = std.mem.eql(u8, inner.scheme, "http") or
                std.mem.eql(u8, inner.scheme, "https") or
                std.mem.eql(u8, inner.scheme, "ws") or
                std.mem.eql(u8, inner.scheme, "wss") or
                std.mem.eql(u8, inner.scheme, "ftp");
            if (!inner_special) return allocator.dupe(u8, "null");
            return inner.serializeOrigin(allocator);
        }
        return allocator.dupe(u8, "null");
    }

    /// Build the JS field object the URL polyfill class wraps:
    /// href/origin/protocol/username/password/host/hostname/port/
    /// pathname/search/hash plus `query` (search without "?", used to
    /// seed searchParams).
    fn urlRecordToJs(vm: *VM, url: *const url_parser.Url) anyerror!JsValue {
        const a = vm.allocator;
        const obj = try vm.createObj(.{});

        const href = try url.serialize(a, false);
        defer a.free(href);
        try setStringProp(vm, obj, "href", href);

        const origin = try urlOriginString(a, url);
        defer a.free(origin);
        try setStringProp(vm, obj, "origin", origin);

        const proto = try std.fmt.allocPrint(a, "{s}:", .{url.scheme});
        defer a.free(proto);
        try setStringProp(vm, obj, "protocol", proto);

        try setStringProp(vm, obj, "username", url.username);
        try setStringProp(vm, obj, "password", url.password);

        if (url.host) |h| {
            const hs = try url_parser.serializeHost(a, h);
            defer a.free(hs);
            try setStringProp(vm, obj, "hostname", hs);
            if (url.port) |p| {
                const hp = try std.fmt.allocPrint(a, "{s}:{d}", .{ hs, p });
                defer a.free(hp);
                try setStringProp(vm, obj, "host", hp);
                const ps = try std.fmt.allocPrint(a, "{d}", .{p});
                defer a.free(ps);
                try setStringProp(vm, obj, "port", ps);
            } else {
                try setStringProp(vm, obj, "host", hs);
                try setStringProp(vm, obj, "port", "");
            }
        } else {
            try setStringProp(vm, obj, "host", "");
            try setStringProp(vm, obj, "hostname", "");
            try setStringProp(vm, obj, "port", "");
        }

        switch (url.path) {
            .list => |l| {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(a);
                for (l.items) |seg| {
                    try buf.append(a, '/');
                    try buf.appendSlice(a, seg);
                }
                try setStringProp(vm, obj, "pathname", buf.items);
            },
            .opaque_path => |p| try setStringProp(vm, obj, "pathname", p),
        }

        if (url.query) |q| {
            if (q.len > 0) {
                const s = try std.fmt.allocPrint(a, "?{s}", .{q});
                defer a.free(s);
                try setStringProp(vm, obj, "search", s);
            } else {
                try setStringProp(vm, obj, "search", "");
            }
            try setStringProp(vm, obj, "query", q);
        } else {
            try setStringProp(vm, obj, "search", "");
            try setStringProp(vm, obj, "query", "");
        }

        if (url.fragment) |f| {
            if (f.len > 0) {
                const s = try std.fmt.allocPrint(a, "#{s}", .{f});
                defer a.free(s);
                try setStringProp(vm, obj, "hash", s);
            } else {
                try setStringProp(vm, obj, "hash", "");
            }
        } else {
            try setStringProp(vm, obj, "hash", "");
        }

        return JsValue.initObject(obj);
    }

    /// __suzume_url_parse(input, base?) → field object | null.
    /// Runs the WHATWG basic URL parser (full host parsing, IDNA,
    /// percent encoding) from src/url/parser.zig.
    fn nativeUrlParse(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = VM.vmFromCtx(ctx);
        if (args.len == 0 or !args[0].isString()) return JsValue.null_val;
        const input = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;

        var base: ?url_parser.Url = null;
        defer if (base) |*b| b.deinit();
        if (args.len > 1 and args[1].isString()) {
            const base_str = vm.pool.get(args[1].asStringId()) orelse return JsValue.null_val;
            base = (url_parser.parse(vm.allocator, base_str, null) catch null) orelse
                return JsValue.null_val;
        }

        const base_ptr: ?*const url_parser.Url = if (base) |*b| b else null;
        var url = (url_parser.parse(vm.allocator, input, base_ptr) catch null) orelse
            return JsValue.null_val;
        defer url.deinit();
        return urlRecordToJs(vm, &url);
    }

    /// __suzume_url_set(href, prop, value) → field object | null.
    /// URL §6.3 component setters: parses href, applies the setter with
    /// basic-URL-parser-with-state-override semantics (src/url applySetter)
    /// and returns the re-serialized field object. Invalid values return
    /// the unchanged URL's fields (spec setters ignore failures silently).
    fn nativeUrlSet(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = VM.vmFromCtx(ctx);
        if (args.len < 3 or !args[0].isString() or !args[1].isString() or !args[2].isString())
            return JsValue.null_val;
        const href = vm.pool.get(args[0].asStringId()) orelse return JsValue.null_val;
        const prop = vm.pool.get(args[1].asStringId()) orelse return JsValue.null_val;
        const value = vm.pool.get(args[2].asStringId()) orelse return JsValue.null_val;

        const setter = std.meta.stringToEnum(url_parser.Setter, prop) orelse return JsValue.null_val;
        var url = (url_parser.parse(vm.allocator, href, null) catch null) orelse
            return JsValue.null_val;
        defer url.deinit();
        url_parser.applySetter(vm.allocator, &url, setter, value) catch return JsValue.null_val;
        return urlRecordToJs(vm, &url);
    }

    /// __suzume_url_can_parse(input, base?) → boolean.
    fn nativeUrlCanParse(ctx: *anyopaque, _: JsValue, args: []const JsValue) anyerror!JsValue {
        const vm = VM.vmFromCtx(ctx);
        if (args.len == 0 or !args[0].isString()) return JsValue.initBool(false);
        const input = vm.pool.get(args[0].asStringId()) orelse return JsValue.initBool(false);

        var base: ?url_parser.Url = null;
        defer if (base) |*b| b.deinit();
        if (args.len > 1 and args[1].isString()) {
            const base_str = vm.pool.get(args[1].asStringId()) orelse
                return JsValue.initBool(false);
            base = (url_parser.parse(vm.allocator, base_str, null) catch null) orelse
                return JsValue.initBool(false);
        }

        const base_ptr: ?*const url_parser.Url = if (base) |*b| b else null;
        var url = (url_parser.parse(vm.allocator, input, base_ptr) catch null) orelse
            return JsValue.initBool(false);
        url.deinit();
        return JsValue.initBool(true);
    }

    /// WHATWG URL Standard — `globalThis.URL` constructor backed by the
    /// native parser (src/url/parser.zig via __suzume_url_parse), plus
    /// Location interface enrichment.
    ///
    /// The class shell stays in JS (field stamping, searchParams
    /// linkage) while all parsing/serialization runs in the native
    /// basic URL parser: full host parsing, IDNA, percent encoding,
    /// relative resolution, spec href normalization.
    ///
    /// Location augmentation: window.location.href is set in
    /// kotori_runtime.setDocumentUrl; this polyfill parses it and
    /// stamps protocol/host/hostname/port/pathname/search/hash/origin
    /// onto the same object so `self.location.pathname` returns the
    /// path portion.
    const url_polyfill_js =
        \\(function(){
        \\  if(typeof globalThis==='undefined')return;
        \\  function percentDecode(s){try{return decodeURIComponent(s);}catch(e){var out='';for(var i=0;i<s.length;i++){if(s.charAt(i)==='%'&&i+2<s.length){var h=s.substring(i+1,i+3);if(/^[0-9A-Fa-f]{2}$/.test(h)){out+=decodeURIComponent(s.substring(i,i+3));i+=2;continue;}}out+=s.charAt(i);}return out;}}
        \\  // Native-backed parse: full WHATWG basic URL parser. Returns a
        \\  // stub for invalid input so location getters degrade gracefully.
        \\  function parseURL(url){
        \\    var p=null;
        \\    try{p=__suzume_url_parse(String(url));}catch(e){p=null;}
        \\    if(p)return p;
        \\    return {href:String(url),protocol:'',host:'',hostname:'',port:'',pathname:'',search:'',hash:'',origin:'null'};
        \\  }
        \\  function URL(url,base){
        \\    if(!(this instanceof URL))throw new TypeError("Constructor URL requires 'new'");
        \\    var p;
        \\    try{p=__suzume_url_parse(String(url),base===undefined?undefined:String(base));}
        \\    catch(e){p=null;}
        \\    if(!p)throw new TypeError("Failed to construct 'URL': Invalid URL");
        \\    this._p=p;
        \\    this._sp=null;
        \\  }
        \\  // URL §6.3 component setters run the native basic URL parser with
        \\  // state override (__suzume_url_set); invalid values are ignored.
        \\  function _set(self,prop,v){
        \\    var np=null;
        \\    try{np=__suzume_url_set(self._p.href,prop,String(v));}catch(e){np=null;}
        \\    if(np)self._p=np;
        \\  }
        \\  function _refillSP(sp,q){
        \\    sp._e=[];
        \\    if(q&&q.length){
        \\      var pairs=q.split('&');
        \\      for(var i=0;i<pairs.length;i++){
        \\        if(pairs[i]==='')continue;
        \\        var eq=pairs[i].indexOf('=');
        \\        var n,val;
        \\        if(eq>=0){n=pairs[i].substring(0,eq);val=pairs[i].substring(eq+1);}
        \\        else{n=pairs[i];val='';}
        \\        sp._e.push([percentDecode(n.replace(/\\+/g,' ')),percentDecode(val.replace(/\\+/g,' '))]);
        \\      }
        \\    }
        \\  }
        \\  function _def(name,getter,setter){
        \\    try{Object.defineProperty(URL.prototype,name,{get:getter,set:setter,configurable:true,enumerable:true});}catch(e){}
        \\  }
        \\  _def('href',function(){return this._p.href;},function(v){
        \\    var p=null;
        \\    try{p=__suzume_url_parse(String(v));}catch(e){p=null;}
        \\    if(!p)throw new TypeError("Failed to set 'href': Invalid URL");
        \\    this._p=p;
        \\    if(this._sp)_refillSP(this._sp,p.query||'');
        \\  });
        \\  _def('origin',function(){return this._p.origin;},function(v){});
        \\  _def('protocol',function(){return this._p.protocol;},function(v){_set(this,'protocol',v);});
        \\  _def('username',function(){return this._p.username||'';},function(v){_set(this,'username',v);});
        \\  _def('password',function(){return this._p.password||'';},function(v){_set(this,'password',v);});
        \\  _def('host',function(){return this._p.host;},function(v){_set(this,'host',v);});
        \\  _def('hostname',function(){return this._p.hostname;},function(v){_set(this,'hostname',v);});
        \\  _def('port',function(){return this._p.port;},function(v){_set(this,'port',v);});
        \\  _def('pathname',function(){return this._p.pathname;},function(v){_set(this,'pathname',v);});
        \\  _def('search',function(){return this._p.search;},function(v){
        \\    _set(this,'search',v);
        \\    if(this._sp)_refillSP(this._sp,this._p.query||'');
        \\  });
        \\  _def('hash',function(){return this._p.hash;},function(v){_set(this,'hash',v);});
        \\  _def('searchParams',function(){
        \\    if(this._sp)return this._sp;
        \\    var self=this;
        \\    var sp=new URLSearchParams(this._p.query||'');
        \\    sp._updateURL=function(){_set(self,'search',sp.toString());};
        \\    this._sp=sp;
        \\    return sp;
        \\  },function(v){throw new TypeError('Cannot set URL property "searchParams"');});
        \\  URL.prototype.toString=function(){return this._p.href;};
        \\  URL.prototype.toJSON=function(){return this._p.href;};
        \\  // WHATWG URL Standard static methods. WebIDL USVString
        \\  // conversion applies: undefined/null inputs stringify to
        \\  // "undefined"/"null" (only a *missing* argument throws), so
        \\  // URL.canParse(undefined, "aaa:/b") is true.
        \\  URL.canParse=function(url,base){
        \\    if(arguments.length===0)throw new TypeError("1 argument required, but only 0 present");
        \\    try{return __suzume_url_can_parse(String(url),base===undefined?undefined:String(base));}catch(e){return false;}
        \\  };
        \\  URL.parse=function(url,base){
        \\    if(arguments.length===0)throw new TypeError("1 argument required, but only 0 present");
        \\    try{return new URL(url,base);}catch(e){return null;}
        \\  };
        \\  if(typeof globalThis.URL==='undefined')globalThis.URL=URL;
        \\  // Augment self.location with getter-derived fields. setDocumentUrl
        \\  // overwrites location.href post-init, so static fields get stale.
        \\  // Getters parse on each access — always reflect the current href.
        \\  if(typeof self!=='undefined'&&self.location){
        \\    var loc=self.location;
        \\    var fields=['protocol','host','hostname','port','pathname','search','hash','origin'];
        \\    for(var fi=0;fi<fields.length;fi++){
        \\      (function(name){
        \\        try{Object.defineProperty(loc,name,{
        \\          get:function(){return parseURL(this.href||'')[name]||'';},
        \\          configurable:true,enumerable:true
        \\        });}catch(e){}
        \\      })(fields[fi]);
        \\    }
        \\    try{loc.toString=function(){return this.href;};}catch(e){}
        \\  }
        \\  // HTML §3.1.2 — document.baseURI getter.
        \\  // Document base URL is computed by parsing the first <base href>
        \\  // (in document order, descendant of document) relative to
        \\  // document's URL; fallback to document's URL when no <base>.
        \\  // Element.prototype.baseURI / Node.baseURI delegate to the
        \\  // owning document's baseURI per DOM §4.4.
        \\  function _docBaseURI(doc){
        \\    var docURL=(doc&&doc.URL)?doc.URL:'';
        \\    var bases=null;
        \\    try{bases=doc&&doc.getElementsByTagName?doc.getElementsByTagName('base'):null;}catch(e){bases=null;}
        \\    if(bases&&bases.length){
        \\      for(var bi=0;bi<bases.length;bi++){
        \\        var bel=bases[bi];
        \\        if(bel&&bel.getAttribute){
        \\          var href=bel.getAttribute('href');
        \\          if(href!=null&&href!==''){
        \\            try{return new URL(href,docURL).href;}catch(e){return docURL;}
        \\          }
        \\        }
        \\      }
        \\    }
        \\    return docURL;
        \\  }
        \\  if(typeof document!=='undefined'){
        \\    try{Object.defineProperty(document,'baseURI',{
        \\      get:function(){return _docBaseURI(this);},
        \\      configurable:true,enumerable:true
        \\    });}catch(e){}
        \\  }
        \\  if(typeof Element!=='undefined'&&Element.prototype){
        \\    try{Object.defineProperty(Element.prototype,'baseURI',{
        \\      get:function(){
        \\        var doc=(this&&this.ownerDocument)||(typeof document!=='undefined'?document:null);
        \\        return doc?_docBaseURI(doc):'';
        \\      },
        \\      configurable:true,enumerable:true
        \\    });}catch(e){}
        \\  }
        \\  // JSON.stringify monkey-patch to support toJSON (needed by URL.prototype.toJSON)
        \\  if(typeof globalThis.JSON!=='undefined'&&globalThis.JSON.stringify&&!globalThis.JSON.__toJSON_patched){
        \\    var _origStringify=globalThis.JSON.stringify;
        \\    globalThis.JSON.stringify=function(val, replacer, space){
        \\      return JSON.stringify._toJSONSerialize(val, replacer, space);
        \\    };
        \\    // Recursive serializer that checks for toJSON
        \\    globalThis.JSON.stringify._toJSONSerialize=function(val, replacer, space){
        \\      if(val!==null&&typeof val==='object'&&typeof val.toJSON==='function'){
        \\        val=val.toJSON();
        \\      }
        \\      return _origStringify.call(globalThis.JSON, val, replacer, space);
        \\    };
        \\    globalThis.JSON.__toJSON_patched=true;
        \\  }
        \\})();
    ;

    /// HTML §4.6.2 HTMLHyperlinkElementUtils — URL decomposition
    /// accessors (href/protocol/host/…) on <a> and <area>, backed by the
    /// native URL parser. Getters reparse the href content attribute
    /// against document.baseURI on each access; setters run the URL §6.3
    /// component setters and write the serialized URL back to the
    /// attribute. Must run after url_polyfill_js (uses document.baseURI).
    const hyperlink_utils_polyfill_js =
        \\(function(){
        \\  if(typeof __suzume_url_parse!=='function')return;
        \\  function _parse(el){
        \\    var raw=el.getAttribute&&el.getAttribute('href');
        \\    if(raw==null)return null;
        \\    var base='';
        \\    try{base=(typeof document!=='undefined'&&document.baseURI)?String(document.baseURI):'';}catch(e){base='';}
        \\    try{return __suzume_url_parse(String(raw),base||undefined);}catch(e){return null;}
        \\  }
        \\  function _writeBack(el,prop,v){
        \\    var p=_parse(el);
        \\    if(!p)return;
        \\    var np=null;
        \\    try{np=__suzume_url_set(p.href,prop,String(v));}catch(e){np=null;}
        \\    if(np)el.setAttribute('href',np.href);
        \\  }
        \\  function _install(proto){
        \\    if(!proto)return;
        \\    try{Object.defineProperty(proto,'href',{
        \\      get:function(){
        \\        var raw=this.getAttribute&&this.getAttribute('href');
        \\        if(raw==null)return '';
        \\        var p=_parse(this);
        \\        return p?p.href:String(raw);
        \\      },
        \\      set:function(v){this.setAttribute('href',String(v));},
        \\      configurable:true,enumerable:true});}catch(e){}
        \\    try{Object.defineProperty(proto,'origin',{
        \\      get:function(){var p=_parse(this);return p?p.origin:'';},
        \\      set:function(v){},
        \\      configurable:true,enumerable:true});}catch(e){}
        \\    try{Object.defineProperty(proto,'protocol',{
        \\      get:function(){var p=_parse(this);return p?p.protocol:':';},
        \\      set:function(v){_writeBack(this,'protocol',v);},
        \\      configurable:true,enumerable:true});}catch(e){}
        \\    var comps=['username','password','host','hostname','port','pathname','search','hash'];
        \\    for(var i=0;i<comps.length;i++){
        \\      (function(name){
        \\        try{Object.defineProperty(proto,name,{
        \\          get:function(){var p=_parse(this);return p?(p[name]||''):'';},
        \\          set:function(v){_writeBack(this,name,v);},
        \\          configurable:true,enumerable:true});}catch(e){}
        \\      })(comps[i]);
        \\    }
        \\    try{proto.toString=function(){return this.href;};}catch(e){}
        \\  }
        \\  if(typeof HTMLAnchorElement!=='undefined')_install(HTMLAnchorElement.prototype);
        \\  if(typeof HTMLAreaElement!=='undefined')_install(HTMLAreaElement.prototype);
        \\})();
    ;

    /// Fetch §4.1: resolve relative request URLs against the document
    /// URL before calling the native fetch. The native layer (vm.zig
    /// nativeFetch) hands its URL string verbatim to the HTTP client,
    /// so a relative fetch("resources/data.json") would otherwise fail
    /// with a network error. Resolution happens at call time because
    /// setDocumentUrl stamps document.URL after runtime init.
    const fetch_resolve_polyfill_js =
        \\(function(){
        \\  if(typeof fetch!=='function'||typeof URL!=='function')return;
        \\  var _nativeFetch=fetch;
        \\  globalThis.fetch=function(input,init){
        \\    var u=(input&&typeof input==='object'&&input.url!==undefined)?String(input.url):String(input);
        \\    try{
        \\      var base=(typeof document!=='undefined'&&document.URL)?String(document.URL):'';
        \\      u=base?new URL(u,base).href:new URL(u).href;
        \\    }catch(e){}
        \\    return _nativeFetch(u,init);
        \\  };
        \\})();
    ;

    /// XMLHttpRequest polyfill built on fetch(). Mirrors the QuickJS-side
    /// implementation in web_api.zig (lines 2233–2294). Async-only: sync XHR
    /// would need a native blocking helper which kotori doesn't expose; modern
    /// sites use async XHR, so this is enough to stop "Cannot read properties
    /// of undefined" errors from `new XMLHttpRequest().addEventListener(...)`.
    const xhr_polyfill_js =
        \\(function(){
        \\  if(typeof XMLHttpRequest!=='undefined')return;
        \\  var STATUS_TEXT={200:'OK',201:'Created',204:'No Content',301:'Moved Permanently',302:'Found',304:'Not Modified',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',500:'Internal Server Error',502:'Bad Gateway',503:'Service Unavailable'};
        \\  function XHR(){
        \\    this.readyState=0;this.status=0;this.statusText='';this.responseText='';
        \\    this.responseURL='';this.response='';this.responseType='';
        \\    this._method='GET';this._url='';this._headers={};this._async=true;
        \\    this.onreadystatechange=null;this.onload=null;this.onerror=null;
        \\    this.onprogress=null;this.ontimeout=null;this.onabort=null;
        \\    this._listeners={};this.timeout=0;this.withCredentials=false;
        \\    this.upload={addEventListener:function(){},removeEventListener:function(){}};
        \\  }
        \\  XHR.UNSENT=0;XHR.OPENED=1;XHR.HEADERS_RECEIVED=2;XHR.LOADING=3;XHR.DONE=4;
        \\  XHR.prototype.open=function(method,url,async_){
        \\    this._method=method;this._url=url;this._async=async_!==false;
        \\    this.readyState=1;this._fireReadyState();
        \\  };
        \\  XHR.prototype.setRequestHeader=function(name,value){this._headers[name]=value;};
        \\  XHR.prototype.getResponseHeader=function(name){return this._responseHeaders?(this._responseHeaders[name.toLowerCase()]||null):null;};
        \\  XHR.prototype.getAllResponseHeaders=function(){if(!this._responseHeaders)return'';var r='';for(var k in this._responseHeaders)r+=k+': '+this._responseHeaders[k]+'\r\n';return r;};
        \\  XHR.prototype.send=function(body){
        \\    var self=this;
        \\    var opts={method:this._method,headers:this._headers};
        \\    if(body!==undefined&&body!==null)opts.body=body;
        \\    if(this.withCredentials)opts.credentials='include';
        \\    fetch(this._url,opts).then(function(resp){
        \\      self.status=resp.status;self.statusText=resp.statusText||STATUS_TEXT[resp.status]||'';
        \\      self.responseURL=resp.url||self._url;
        \\      self._responseHeaders={};
        \\      if(resp.headers&&resp.headers.forEach)resp.headers.forEach(function(v,k){self._responseHeaders[k]=v;});
        \\      self.readyState=2;self._fireReadyState();
        \\      return resp.text();
        \\    }).then(function(text){
        \\      self.readyState=3;self._fireReadyState();
        \\      self.responseText=text;
        \\      self.response=self.responseType==='json'?(function(){try{return JSON.parse(text);}catch(e){return null;}})():text;
        \\      self.readyState=4;self._fireReadyState();
        \\      if(self.onload)try{self.onload({target:self,type:'load'});}catch(e){}
        \\      self._fire('load',{target:self});
        \\    })['catch'](function(err){
        \\      self.readyState=4;self.status=0;self._fireReadyState();
        \\      if(self.onerror)try{self.onerror({target:self,type:'error'});}catch(e){}
        \\      self._fire('error',{target:self});
        \\    });
        \\  };
        \\  XHR.prototype.abort=function(){
        \\    this.readyState=4;this.status=0;
        \\    if(this.onabort)try{this.onabort({target:this,type:'abort'});}catch(e){}
        \\    this._fire('abort',{target:this});
        \\  };
        \\  XHR.prototype.addEventListener=function(type,fn){
        \\    if(!this._listeners[type])this._listeners[type]=[];
        \\    this._listeners[type].push(fn);
        \\  };
        \\  XHR.prototype.removeEventListener=function(type,fn){
        \\    if(!this._listeners[type])return;
        \\    this._listeners[type]=this._listeners[type].filter(function(f){return f!==fn;});
        \\  };
        \\  XHR.prototype._fire=function(type,evt){
        \\    if(!this._listeners[type])return;
        \\    for(var i=0;i<this._listeners[type].length;i++){
        \\      try{this._listeners[type][i](evt);}catch(e){}
        \\    }
        \\  };
        \\  XHR.prototype._fireReadyState=function(){
        \\    if(this.onreadystatechange)try{this.onreadystatechange({target:this});}catch(e){}
        \\    this._fire('readystatechange',{target:this});
        \\  };
        \\  XHR.prototype.overrideMimeType=function(){};
        \\  XHR.prototype.dispatchEvent=function(e){this._fire(e.type,e);};
        \\  globalThis.XMLHttpRequest=XHR;
        \\})();
    ;

    /// navigator / performance / screen polyfills. Many sites read
    /// navigator.userAgent at init (Wikipedia's mw.config) and
    /// performance.timing.navigationStart (Bing analytics). Without these
    /// globals the site scripts throw TypeError on undefined property access
    /// and skip important DOM setup. Mirrors the QuickJS-side globals from
    /// web_api.zig:1898-1990.
    const navigator_performance_polyfill_js =
        \\(function(){
        \\  if(typeof navigator==='undefined'){
        \\    var nav={userAgent:'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',platform:'Linux x86_64',language:'ja',languages:['ja','en'],vendor:'',appName:'Netscape',appVersion:'5.0 (Linux)',product:'Gecko',onLine:true,cookieEnabled:true,maxTouchPoints:0,hardwareConcurrency:4,doNotTrack:null};
        \\    nav.geolocation={getCurrentPosition:function(){},watchPosition:function(){return 0;},clearWatch:function(){}};
        \\    nav.sendBeacon=function(){return true;};
        \\    globalThis.navigator=nav;
        \\  }
        \\  if(typeof performance!=='undefined'){
        \\    var origin=Date.now();
        \\    if(typeof performance.timeOrigin==='undefined')performance.timeOrigin=origin;
        \\    if(typeof performance.getEntries!=='function')performance.getEntries=function(){return [];};
        \\    if(typeof performance.getEntriesByName!=='function')performance.getEntriesByName=function(){return [];};
        \\    if(typeof performance.getEntriesByType!=='function')performance.getEntriesByType=function(){return [];};
        \\    if(typeof performance.mark!=='function')performance.mark=function(){};
        \\    if(typeof performance.measure!=='function')performance.measure=function(){};
        \\    if(typeof performance.clearMarks!=='function')performance.clearMarks=function(){};
        \\    if(typeof performance.clearMeasures!=='function')performance.clearMeasures=function(){};
        \\    if(!performance.timing){
        \\      var timing={};
        \\      timing.navigationStart=origin;
        \\      timing.unloadEventStart=0;
        \\      timing.unloadEventEnd=0;
        \\      timing.redirectStart=0;
        \\      timing.redirectEnd=0;
        \\      timing.fetchStart=origin;
        \\      timing.domainLookupStart=origin;
        \\      timing.domainLookupEnd=origin;
        \\      timing.connectStart=origin;
        \\      timing.connectEnd=origin;
        \\      timing.secureConnectionStart=0;
        \\      timing.requestStart=origin;
        \\      timing.responseStart=origin;
        \\      timing.responseEnd=origin;
        \\      timing.domLoading=origin;
        \\      timing.domInteractive=origin;
        \\      timing.domContentLoadedEventStart=origin;
        \\      timing.domContentLoadedEventEnd=origin;
        \\      timing.domComplete=origin;
        \\      timing.loadEventStart=origin;
        \\      timing.loadEventEnd=origin;
        \\      performance.timing=timing;
        \\    }
        \\    if(!performance.navigation)performance.navigation={type:0,redirectCount:0};
        \\    if(!performance.memory)performance.memory={usedJSHeapSize:0,totalJSHeapSize:0,jsHeapSizeLimit:0};
        \\  }
        \\  if(typeof screen==='undefined'){
        \\    globalThis.screen={width:1280,height:800,availWidth:1280,availHeight:800,colorDepth:24,pixelDepth:24,orientation:{type:'landscape-primary',angle:0}};
        \\  }
        \\  if(typeof matchMedia==='undefined'){
        \\    globalThis.matchMedia=function(q){return{matches:false,media:q,onchange:null,addListener:function(){},removeListener:function(){},addEventListener:function(){},removeEventListener:function(){},dispatchEvent:function(){return true;}};};
        \\  }
        \\  if(typeof requestAnimationFrame==='undefined'){
        \\    globalThis.requestAnimationFrame=function(cb){return setTimeout(function(){cb(Date.now());},16);};
        \\    globalThis.cancelAnimationFrame=function(id){clearTimeout(id);};
        \\  }
        \\  if(typeof Promise==='undefined'||typeof Promise.allSettled==='undefined'){
        \\    if(typeof Promise!=='undefined'){
        \\      Promise.allSettled=function(iter){return Promise.all(iter.map(function(p){return Promise.resolve(p).then(function(v){return{status:'fulfilled',value:v};},function(e){return{status:'rejected',reason:e};});}));};
        \\      Promise.any=function(iter){return new Promise(function(resolve,reject){var pending=0;var errors=[];iter.forEach(function(p,i){pending++;Promise.resolve(p).then(function(v){resolve(v);},function(e){errors[i]=e;if(--pending===0)reject(new AggregateError(errors));});});});};
        \\    }
        \\  }
        \\  if(typeof AggregateError==='undefined'){
        \\    globalThis.AggregateError=function(errors,message){var e=new Error(message);e.errors=errors;return e;};
        \\  }
        \\})();
    ;
    /// srcElement alias for target (DOM §2.6.2).
    ///
    /// returnValue: getter returns `!defaultPrevented`; setter calls
    /// `preventDefault()` when assigned `false` AND `cancelable === true`.
    /// Setting to `true` is a no-op. kotori previously set `returnValue`
    /// as an own data property on each event instance, which shadowed
    /// any prototype accessor — those native setProperty calls were
    /// removed.
    ///
    /// srcElement: legacy alias that returns the same value as
    /// `target`. The native event creation initialized srcElement=null
    /// and never updated it during dispatch; the accessor delegates
    /// to `this.target` so it always matches.
    const event_returnvalue_polyfill_js =
        \\(function(){
        \\  if(typeof Event==='undefined'||!Event.prototype)return;
        \\  try{Object.defineProperty(Event.prototype,'returnValue',{
        \\    get:function(){return !this.defaultPrevented;},
        \\    set:function(v){
        \\      if(v===false&&this.cancelable===true){
        \\        if(typeof this.preventDefault==='function')this.preventDefault();
        \\      }
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{Object.defineProperty(Event.prototype,'srcElement',{
        \\    get:function(){return this.target;},
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\})();
    ;

    /// HTML §4.10.5.1.16 — radio insert-time group exclusivity.
    ///
    /// Per spec, when an `input type=radio` whose checkedness is true is
    /// preinserted into a parent and ends up sharing a radio button group
    /// with another already-checked radio, the OTHERS in the group must
    /// have their checkedness set to false. The IDL `.checked` setter
    /// already performs this walk; this polyfill hooks
    /// `Element.prototype.appendChild` / `insertBefore` so that the post-
    /// insert state triggers the same walk by calling `radio.checked = true`
    /// (which is idempotent for the already-true case but propagates to
    /// the new group context).
    ///
    /// Test "Appending input radio input into a disconnect tree do NOT
    /// update" governs the form-less case: when the post-insert radio has
    /// no form ancestor, exclusivity must NOT fire. We gate by
    /// `formOwner(node) != null`, matching observed browser behavior and
    /// the WPT cases in radio-disconnected-group-owner.html.
    const radio_insert_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  var origAppend=EP.appendChild;
        \\  var origInsertBefore=EP.insertBefore;
        \\  if(typeof origAppend!=='function'||typeof origInsertBefore!=='function')return;
        \\  function formOwnerOf(el){
        \\    // HTML §4.10.18.3: defer to the canonical Element.form getter
        \\    // (form_owner_polyfill_js) which handles tree-root lookup,
        \\    // empty form="", and disconnected-subtree cases. By the time
        \\    // appendChild/insertBefore actually fire on user content the
        \\    // form_owner polyfill has already been installed.
        \\    if(typeof el.form!=='undefined')return el.form||null;
        \\    return null;
        \\  }
        \\  function checkRadioOnInsert(node){
        \\    if(!node||node.nodeType!==1)return;
        \\    if((node.tagName||'').toLowerCase()!=='input')return;
        \\    if((node.type||'').toLowerCase()!=='radio')return;
        \\    if(node.checked!==true)return;
        \\    // Per HTML §4.10.5.1.16: only fire when the radio now has a
        \\    // non-null form owner (form-rooted tree). Orphan trees do
        \\    // not trigger exclusivity on insert per WPT
        \\    // radio-disconnected-group-owner "Appending into disconnect
        \\    // tree don't update".
        \\    if(!formOwnerOf(node))return;
        \\    try{node.checked=true;}catch(e){}
        \\  }
        \\  EP.appendChild=function(child){
        \\    var r=origAppend.call(this,child);
        \\    checkRadioOnInsert(child);
        \\    return r;
        \\  };
        \\  EP.insertBefore=function(child,ref){
        \\    var r=origInsertBefore.call(this,child,ref);
        \\    checkRadioOnInsert(child);
        \\    return r;
        \\  };
        \\})();
    ;

    /// HTML §4.10.5.1.18 — HTMLInputElement.files (FileList).
    ///
    /// Provides a minimal FileList constructor (length + indexed access +
    /// item(i)) plus the input.files accessor:
    ///   - Non-file inputs: getter returns null; setter is a no-op (not
    ///     null-throwing) per spec "files cannot be set when it does not
    ///     apply".
    ///   - type=file inputs: getter returns a persistent FileList for the
    ///     element (lazy-init); setter requires a FileList instance,
    ///     throws TypeError otherwise; setting null is a no-op.
    const file_input_polyfill_js =
        \\(function(){
        \\  if(typeof globalThis==='undefined')return;
        \\  var FileList_ = function FileList(){this._items=[];};
        \\  Object.defineProperty(FileList_.prototype,'length',{
        \\    get:function(){return this._items.length;},
        \\    configurable:true,enumerable:true
        \\  });
        \\  FileList_.prototype.item=function(i){
        \\    i=i>>>0;
        \\    return i<this._items.length?this._items[i]:null;
        \\  };
        \\  try{globalThis.FileList=FileList_;}catch(e){}
        \\  var File_ = function File(bits,name,opts){
        \\    this.name=name==null?'':String(name);
        \\    this.lastModified=(opts&&opts.lastModified)||Date.now();
        \\    this.type=(opts&&opts.type)||'';
        \\    this.size=0;
        \\  };
        \\  try{globalThis.File=File_;}catch(e){}
        \\  // HTML §8.7.1 DataTransfer — minimal stub backing input.files
        \\  // assignment: every DataTransfer owns one persistent FileList,
        \\  // and `dt.files` returns the same instance on every access.
        \\  var DataTransfer_ = function DataTransfer(){
        \\    this._files = new FileList_();
        \\  };
        \\  try{Object.defineProperty(DataTransfer_.prototype,'files',{
        \\    get:function(){return this._files;},
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  try{globalThis.DataTransfer=DataTransfer_;}catch(e){}
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function isFileInput(el){
        \\    return tag(el)==='input'&&(el.type||'').toLowerCase()==='file';
        \\  }
        \\  try{Object.defineProperty(EP,'files',{
        \\    get:function(){
        \\      if(!isFileInput(this))return null;
        \\      if(!this._files)this._files=new FileList_();
        \\      return this._files;
        \\    },
        \\    set:function(v){
        \\      if(!isFileInput(this))return;
        \\      if(v===null)return;
        \\      if(!(v instanceof FileList_))
        \\        throw new TypeError("files must be a FileList");
        \\      this._files=v;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\  // HTML §4.10.5.1.10 — HTMLInputElement.list
        \\  // The list attribute applies to text/search/url/tel/email/date/
        \\  // month/week/time/datetime-local/number/range/color (NOT hidden,
        \\  // password, file, checkbox, radio, submit, image, reset, button).
        \\  // Returns the first element with the matching id, only if it is
        \\  // a <datalist>. Otherwise null.
        \\  var listApplies_={text:1,search:1,url:1,tel:1,email:1,
        \\    date:1,month:1,week:1,time:1,"datetime-local":1,
        \\    number:1,range:1,color:1};
        \\  try{Object.defineProperty(EP,'list',{
        \\    get:function(){
        \\      if(tag(this)!=='input')return undefined;
        \\      var t=(this.type||'text').toLowerCase();
        \\      if(!listApplies_[t])return null;
        \\      var id=this.getAttribute&&this.getAttribute('list');
        \\      if(id==null||id==='')return null;
        \\      if(typeof document==='undefined'||!document.getElementById)
        \\        return null;
        \\      var el=document.getElementById(id);
        \\      if(!el)return null;
        \\      if((el.tagName||'').toLowerCase()!=='datalist')return null;
        \\      return el;
        \\    },
        \\    configurable:true,enumerable:true
        \\  });}catch(e){}
        \\})();
    ;

    /// HTML §3.2.2 "Cloning steps" for form-control elements.
    ///
    /// Native cloneNode duplicates attributes (the *default* value /
    /// checkedness reflection) but does not propagate the per-element
    /// dirty value flag, dirty checkedness flag, raw value, or
    /// checkedness — those live on JS-side state slots
    /// (`_value`, `_dirtyValue`, `_checked`, `_dirtyChecked`) populated
    /// by `form_state_polyfill_js`. The HTML spec explicitly requires
    /// this propagation:
    ///
    ///   "The cloning steps for input elements must propagate the
    ///   value, dirty value flag, checkedness, and dirty checkedness
    ///   flag from node being cloned to copy."
    ///
    /// (Likewise textarea propagates value + dirty value flag.)
    ///
    /// We patch Element.prototype.cloneNode to (a) call through to the
    /// original native implementation, then (b) walk the source +
    /// clone subtrees in lockstep, copying the form-control state
    /// slots for each input/textarea encountered. Selection state
    /// (`_selStart`/`_selEnd`/`_selDir`) is intentionally NOT
    /// propagated — per spec it is per-element runtime state and the
    /// clone should start fresh.
    const clone_form_state_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var orig=Element.prototype.cloneNode;
        \\  if(typeof orig!=='function')return;
        \\  function tag(el){return (el&&el.tagName)?el.tagName.toLowerCase():'';}
        \\  function copyState(src,dst){
        \\    if(!src||!dst)return;
        \\    var t=tag(src);
        \\    if(t==='input'||t==='textarea'){
        \\      if('_value' in src) dst._value=src._value;
        \\      if('_dirtyValue' in src) dst._dirtyValue=src._dirtyValue;
        \\    }
        \\    if(t==='input'){
        \\      if('_checked' in src) dst._checked=src._checked;
        \\      if('_dirtyChecked' in src) dst._dirtyChecked=src._dirtyChecked;
        \\    }
        \\  }
        \\  function walk(src,dst){
        \\    if(!src||!dst)return;
        \\    copyState(src,dst);
        \\    var sk=src.childNodes,dk=dst.childNodes;
        \\    if(!sk||!dk)return;
        \\    var n=sk.length<dk.length?sk.length:dk.length;
        \\    for(var i=0;i<n;i++) walk(sk[i],dk[i]);
        \\  }
        \\  try{Element.prototype.cloneNode=function(deep){
        \\    var copy=orig.call(this,deep);
        \\    if(deep)walk(this,copy);
        \\    else copyState(this,copy);
        \\    return copy;
        \\  };}catch(e){}
        \\})();
    ;

    /// HTML §3.1.5 Document / §4.2.9 HTMLCollection: live collection getters
    /// for document.forms / links / images / scripts / embeds / plugins.
    ///
    /// Each getter returns a Proxy-wrapped live HTMLCollection. On every
    /// access the underlying node list is re-walked, so the collection
    /// tracks DOM mutations (live semantics per §3.1.5). The Proxy adds:
    ///   - indexed access:    coll[0], coll[1], ...
    ///   - named access:      coll.fm1 (by id, then by name)
    ///   - .length
    ///   - .item(i) / .namedItem(n)
    ///   - instanceof HTMLCollection (via getPrototypeOf trap)
    ///   - Symbol.iterator
    ///
    /// Reference (QuickJS path): src/js/dom_api.zig:5224 "coll_js" block.
    /// That installation only runs in the QuickJS engine; kotori globals
    /// never see it, so `document.forms` was undefined on kotori and every
    /// form-navigation / reset-form test that starts with
    /// `document.forms.fm1.reset()` failed immediately.
    const document_collections_polyfill_js =
        \\(function(){
        \\  if(typeof document==='undefined')return;
        \\  if(typeof HTMLCollection==='undefined')return;
        \\  // Collect descendants of document in tree order filtered by fn.
        \\  function collect(fn){
        \\    var out=[];
        \\    function walk(n){
        \\      var kids=n.childNodes;
        \\      if(!kids)return;
        \\      for(var i=0;i<kids.length;i++){
        \\        var k=kids[i];
        \\        if(k&&k.nodeType===1){
        \\          if(fn(k))out.push(k);
        \\          walk(k);
        \\        }
        \\      }
        \\    }
        \\    walk(document);
        \\    return out;
        \\  }
        \\  // DOM §4.2.9 namedItem algorithm: match first by id, then by name.
        \\  // Name matching restricted to HTML-namespace elements (§4.2.9 step 3).
        \\  function buildNameMap(arr){
        \\    var n=Object.create(null);
        \\    for(var i=0;i<arr.length;i++){
        \\      var el=arr[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      var id=el.getAttribute('id');
        \\      if(id&&!(id in n))n[id]=el;
        \\    }
        \\    for(var i=0;i<arr.length;i++){
        \\      var el=arr[i];
        \\      if(!el||!el.getAttribute)continue;
        \\      var ns=el.namespaceURI;
        \\      if(ns!=null&&ns!=='http://www.w3.org/1999/xhtml')continue;
        \\      var nm=el.getAttribute('name');
        \\      if(nm&&!(nm in n))n[nm]=el;
        \\    }
        \\    return n;
        \\  }
        \\  function isIndex(p){
        \\    if(typeof p!=='string')return false;
        \\    if(p.length===0||p.length>10)return false;
        \\    for(var i=0;i<p.length;i++){var c=p.charCodeAt(i);if(c<48||c>57)return false;}
        \\    // Reject leading-zero numeric strings except "0" itself
        \\    if(p.length>1&&p.charCodeAt(0)===48)return false;
        \\    return true;
        \\  }
        \\  function makeLive(filterFn){
        \\    var _cache=null;
        \\    function query(){return collect(filterFn);}
        \\    return function(){
        \\      if(_cache)return _cache;
        \\      _cache=new Proxy({},{
        \\        get:function(t,p){
        \\          var arr=query();
        \\          if(p==='length')return arr.length;
        \\          if(p==='item')return function(i){i=i>>>0;return i<arr.length?arr[i]:null;};
        \\          if(p==='namedItem')return function(n){var m=buildNameMap(arr);n=String(n);if(n==='')return null;return m[n]||null;};
        \\          if(p===Symbol.iterator){var a=arr.slice();return function(){var i=0;return{next:function(){return i<a.length?{value:a[i++],done:false}:{value:undefined,done:true};}};};}
        \\          if(p===Symbol.toStringTag)return 'HTMLCollection';
        \\          if(isIndex(p)){var i=Number(p);return i<arr.length?arr[i]:undefined;}
        \\          if(typeof p==='string'){var m=buildNameMap(arr);if(p in m)return m[p];}
        \\          return t[p];
        \\        },
        \\        has:function(t,p){
        \\          var arr=query();
        \\          if(p==='length'||p==='item'||p==='namedItem')return true;
        \\          if(isIndex(p))return Number(p)<arr.length;
        \\          if(typeof p==='string'){var m=buildNameMap(arr);if(p in m)return true;}
        \\          return false;
        \\        },
        \\        ownKeys:function(){
        \\          var arr=query(),m=buildNameMap(arr),keys=[];
        \\          for(var i=0;i<arr.length;i++)keys.push(String(i));
        \\          var nk=Object.keys(m);
        \\          for(var j=0;j<nk.length;j++)if(keys.indexOf(nk[j])<0)keys.push(nk[j]);
        \\          return keys;
        \\        },
        \\        getOwnPropertyDescriptor:function(t,p){
        \\          var arr=query();
        \\          if(isIndex(p)){var i=Number(p);if(i<arr.length)return{value:arr[i],writable:false,enumerable:true,configurable:true};}
        \\          if(p==='length')return{value:arr.length,writable:false,enumerable:false,configurable:true};
        \\          if(typeof p==='string'){var m=buildNameMap(arr);if(p in m)return{value:m[p],writable:false,enumerable:false,configurable:true};}
        \\          return undefined;
        \\        },
        \\        getPrototypeOf:function(){return HTMLCollection.prototype;}
        \\      });
        \\      return _cache;
        \\    };
        \\  }
        \\  function isTag(name){
        \\    return function(el){
        \\      // HTML namespace filter (HTML §3.1.5 collections):
        \\      // document.images / .forms / .links / .scripts only return
        \\      // elements in the HTML namespace, NOT foreign-namespace
        \\      // elements with the same local name.
        \\      var ns=el.namespaceURI;
        \\      if(ns!=null&&ns!=='http://www.w3.org/1999/xhtml')return false;
        \\      return (el.localName||el.tagName||'').toLowerCase()===name;
        \\    };
        \\  }
        \\  function isLink(el){
        \\    var t=(el.tagName||'').toLowerCase();
        \\    return (t==='a'||t==='area')&&el.hasAttribute&&el.hasAttribute('href');
        \\  }
        \\  try{Object.defineProperty(document,'forms',{get:makeLive(isTag('form')),configurable:true,enumerable:true});}catch(e){}
        \\  try{Object.defineProperty(document,'images',{get:makeLive(isTag('img')),configurable:true,enumerable:true});}catch(e){}
        \\  try{Object.defineProperty(document,'links',{get:makeLive(isLink),configurable:true,enumerable:true});}catch(e){}
        \\  try{Object.defineProperty(document,'scripts',{get:makeLive(isTag('script')),configurable:true,enumerable:true});}catch(e){}
        \\  var embedsGetter=makeLive(isTag('embed'));
        \\  try{Object.defineProperty(document,'embeds',{get:embedsGetter,configurable:true,enumerable:true});}catch(e){}
        \\  try{Object.defineProperty(document,'plugins',{get:embedsGetter,configurable:true,enumerable:true});}catch(e){}
        \\  // HTMLDocument.all — a legacy all-elements collection (may be needed
        \\  // by older scripts). Kept as a plain Proxy without legacy "falsy"
        \\  // [[IsHTMLDDA]] behaviour (the spec quirk is not observable here).
        \\  try{Object.defineProperty(document,'all',{get:makeLive(function(){return true;}),configurable:true,enumerable:false});}catch(e){}
        \\})();
    ;

    /// HTML §4.10.18.3 "Form owner" accessor for form-associated elements.
    ///
    /// Installs Element.prototype.form as an instance getter that returns
    /// the element's owning <form> for listed form-associated tags:
    /// input, select, textarea, button, fieldset, output, object, img (for
    /// object-associated-with-form-owner cases). The algorithm follows the
    /// static form-owner determination:
    ///
    ///   1. If the element has a `form` content attribute, look up the
    ///      element with that id. If it exists AND is a <form>, return it.
    ///      If the attribute is present but no matching form exists, the
    ///      form owner is null (even if there is an ancestor form).
    ///   2. Otherwise, walk ancestors looking for the nearest <form>.
    ///   3. Otherwise, return null.
    ///
    /// This does not implement the "parser-inserted flag" nuance
    /// (reassociation after DOM mutations); the dynamic cases are rare and
    /// require mutation hooks in native code. The static algorithm covers
    /// almost every real-world form and most WPT form-control-infrastructure
    /// subtests.
    const form_owner_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  var EP=Element.prototype;
        \\  function tag(el){return (el.tagName||'').toLowerCase();}
        \\  function isAssociable(t){
        \\    return t==='input'||t==='select'||t==='textarea'||t==='button'||
        \\           t==='fieldset'||t==='output'||t==='object'||t==='label'||
        \\           t==='img';
        \\  }
        \\  function computeFormOwner(el){
        \\    var fa=el.getAttribute('form');
        \\    if(fa!==null){
        \\      // HTML §4.10.18.3: when the form attribute is specified, the
        \\      // owner is the first form element in the element's tree-root
        \\      // whose id matches. Empty string never matches a real form id
        \\      // even if a form has id="" — the tree-order lookup uses the
        \\      // attribute's IDREF semantics, which an empty IDREF cannot
        \\      // satisfy. Fall back to a tree walk for disconnected subtrees
        \\      // (where document.getElementById misses), preferring the
        \\      // first form#id in tree order over the first id-matching
        \\      // element of any tag.
        \\      if(fa==='')return null;
        \\      // Use getElementById semantics: first element in tree order
        \\      // with id===fa, regardless of tag. If that first match is not
        \\      // a form, owner is null even when a later form has the same
        \\      // id. (form_attribute.html "non-form element with same ID
        \\      // inserted earlier in tree order" covers this case.)
        \\      var root=(typeof el.getRootNode==='function')?el.getRootNode():null;
        \\      if(!root){
        \\        var up=el;
        \\        while(up.parentNode)up=up.parentNode;
        \\        root=up;
        \\      }
        \\      var hit=null;
        \\      if(root&&typeof root.getElementById==='function'){
        \\        hit=root.getElementById(fa);
        \\      }
        \\      if(!hit&&root){
        \\        // Tree walk fallback for disconnected subtrees whose root is
        \\        // a plain Element (no getElementById).
        \\        var stack=[root],node;
        \\        while(stack.length){
        \\          node=stack.pop();
        \\          if(node&&node.nodeType===1){
        \\            var nid=(typeof node.getAttribute==='function')?node.getAttribute('id'):node.id;
        \\            if(nid===fa){hit=node;break;}
        \\          }
        \\          var ch=node&&node.children;
        \\          if(ch){for(var i=ch.length-1;i>=0;i--)stack.push(ch[i]);}
        \\        }
        \\      }
        \\      if(hit&&tag(hit)==='form')return hit;
        \\      return null;
        \\    }
        \\    // No form attribute → ascend to nearest form ancestor.
        \\    var p=el.parentNode;
        \\    while(p){
        \\      if(p.nodeType===1&&tag(p)==='form')return p;
        \\      p=p.parentNode;
        \\    }
        \\    return null;
        \\  }
        \\  // HTML §4.10.2: labelable elements. (button, input excluding type=hidden,
        \\  // meter, output, progress, select, textarea, plus form-associated custom
        \\  // elements which we don't model.)
        \\  function isLabelable(el){
        \\    if(!el||el.nodeType!==1)return false;
        \\    var t=tag(el);
        \\    if(t==='button'||t==='select'||t==='textarea'||t==='meter'||t==='output'||t==='progress')return true;
        \\    if(t==='input'){
        \\      var it=(el.getAttribute('type')||'text').toLowerCase();
        \\      return it!=='hidden';
        \\    }
        \\    return false;
        \\  }
        \\  // HTML §4.10.4 label.control: if `for` attribute is set, the labeled
        \\  // control is the first labelable descendant of the label's tree root
        \\  // whose id matches `for`. Otherwise it's the first labelable descendant
        \\  // of the label in tree order. Returns null when no labeled control
        \\  // exists (NOT undefined — the test "label.form" relies on
        \\  // `label.control && label.control.form` short-circuiting to null).
        \\  Object.defineProperty(EP,'control',{
        \\    get:function(){
        \\      if(tag(this)!=='label')return undefined;
        \\      var forAttr=this.getAttribute('for');
        \\      if(forAttr!==null){
        \\        if(forAttr==='')return null;
        \\        var root=(typeof this.getRootNode==='function')?this.getRootNode():null;
        \\        if(!root){
        \\          var up=this;
        \\          while(up.parentNode)up=up.parentNode;
        \\          root=up;
        \\        }
        \\        var hit=null;
        \\        if(root&&typeof root.getElementById==='function')hit=root.getElementById(forAttr);
        \\        return (hit&&isLabelable(hit))?hit:null;
        \\      }
        \\      // No for attribute: first labelable descendant in tree order.
        \\      var stack=[this];
        \\      while(stack.length){
        \\        var n=stack.pop();
        \\        if(n!==this&&isLabelable(n))return n;
        \\        var ch=n&&n.children;
        \\        if(ch){for(var i=ch.length-1;i>=0;i--)stack.push(ch[i]);}
        \\      }
        \\      return null;
        \\    },
        \\    configurable:true,
        \\    enumerable:true
        \\  });
        \\  Object.defineProperty(EP,'form',{
        \\    get:function(){
        \\      var t=tag(this);
        \\      if(!isAssociable(t))return undefined;
        \\      // HTML §4.10.4: label.form is an alias for label.control.form,
        \\      // NOT a walk to the nearest form ancestor. Without a labeled
        \\      // control there is no form owner.
        \\      if(t==='label'){
        \\        var ctrl=this.control;
        \\        return ctrl?(ctrl.form||null):null;
        \\      }
        \\      return computeFormOwner(this);
        \\    },
        \\    configurable:true,
        \\    enumerable:true
        \\  });
        \\})();
    ;

    /// XHR §3 / HTML §4.10.22.4 — globalThis.FormData polyfill.
    ///
    /// Provides a minimal FormData constructor implementing the
    /// "constructing the entry list" algorithm (HTML §4.10.22.4) plus
    /// the standard FormData interface (get/has/getAll/append/set/
    /// delete/forEach/keys/values/entries).
    ///
    /// Constructor:
    ///   new FormData(form?, submitter?)
    ///     - form: optional HTMLFormElement. If provided, iterate
    ///       form.elements and collect entries per spec.
    ///     - submitter: optional submit button. Submit-button entries
    ///       are included ONLY if the control IS the submitter (per
    ///       step 5.6 of "constructing the entry list"). When called
    ///       as `new FormData(form)` (no submitter), submit buttons
    ///       are excluded entirely — this matches WPT
    ///       form-requestsubmit semantics where `new FormData(e.target)`
    ///       inside a submit handler produces a list without the
    ///       submitter button entry.
    ///
    /// Inclusion rules (paraphrased from §4.10.22.4):
    ///   - Skip disabled controls.
    ///   - Skip nameless controls (name attribute missing/empty).
    ///   - input type=submit/reset/button: include only if == submitter.
    ///   - input type=image: include `name.x=0` and `name.y=0` only if
    ///     == submitter.
    ///   - input type=checkbox/radio: include only if checked. Value
    ///     is `value` attribute or "on" if missing.
    ///   - input type=file: include each File from .files (FileList).
    ///   - select: include each selected option's value.
    ///   - textarea / other text inputs: include `name=value`.
    ///   - button (HTMLButtonElement): submit-state default per HTML
    ///     §4.10.8 (Wave 75) — type ∉ {reset,button} ⇒ submit-button
    ///     ⇒ include only if == submitter.
    const formdata_polyfill_js =
        \\(function(){
        \\  if(typeof globalThis==='undefined')return;
        \\  function tag_(el){return ((el&&el.tagName)||'').toLowerCase();}
        \\  function attrLower_(el,n){
        \\    if(!el||!el.getAttribute)return null;
        \\    var v=el.getAttribute(n);
        \\    return v==null?null:String(v).toLowerCase();
        \\  }
        \\  function FormData_(form,submitter){
        \\    this._entries=[];
        \\    if(form==null)return;
        \\    if(tag_(form)!=='form')return;
        \\    if(submitter==null)submitter=null;
        \\    var ctrls=form.elements;
        \\    if(!ctrls)return;
        \\    var n=ctrls.length;
        \\    for(var i=0;i<n;i++){
        \\      var c=ctrls[i];
        \\      if(!c)continue;
        \\      if(c.disabled)continue;
        \\      var name=c.getAttribute&&c.getAttribute('name');
        \\      if(name==null||name==='')continue;
        \\      var t=tag_(c);
        \\      var type=((c.type||'')+'').toLowerCase();
        \\      if(t==='button'){
        \\        var bt=c.getAttribute('type');
        \\        bt=bt==null?'submit':String(bt).toLowerCase();
        \\        if(bt==='reset'||bt==='button')continue;
        \\        if(c!==submitter)continue;
        \\        this._entries.push([name,String(c.value==null?'':c.value)]);
        \\        continue;
        \\      }
        \\      if(t==='input'){
        \\        if(type==='submit'||type==='reset'||type==='button'){
        \\          if(c!==submitter)continue;
        \\          this._entries.push([name,String(c.value==null?'':c.value)]);
        \\          continue;
        \\        }
        \\        if(type==='image'){
        \\          if(c!==submitter)continue;
        \\          this._entries.push([name+'.x','0']);
        \\          this._entries.push([name+'.y','0']);
        \\          continue;
        \\        }
        \\        if(type==='checkbox'||type==='radio'){
        \\          if(!c.checked)continue;
        \\          var v=c.getAttribute('value');
        \\          this._entries.push([name,v==null?'on':String(v)]);
        \\          continue;
        \\        }
        \\        if(type==='file'){
        \\          var fl=c.files;
        \\          if(fl&&fl.length){
        \\            for(var j=0;j<fl.length;j++){
        \\              var f=fl.item?fl.item(j):fl[j];
        \\              this._entries.push([name,f]);
        \\            }
        \\          }
        \\          continue;
        \\        }
        \\        this._entries.push([name,String(c.value==null?'':c.value)]);
        \\        continue;
        \\      }
        \\      if(t==='select'){
        \\        var opts=c.querySelectorAll?c.querySelectorAll('option'):null;
        \\        if(opts){
        \\          for(var k=0;k<opts.length;k++){
        \\            if(opts[k].selected){
        \\              var ov=opts[k].value;
        \\              if(ov==null)ov=opts[k].textContent||'';
        \\              this._entries.push([name,String(ov)]);
        \\            }
        \\          }
        \\        }
        \\        continue;
        \\      }
        \\      if(t==='textarea'){
        \\        this._entries.push([name,String(c.value==null?'':c.value)]);
        \\        continue;
        \\      }
        \\      // object / output / fieldset: skip per spec.
        \\    }
        \\  }
        \\  FormData_.prototype.get=function(name){
        \\    name=String(name);
        \\    for(var i=0;i<this._entries.length;i++){
        \\      if(this._entries[i][0]===name)return this._entries[i][1];
        \\    }
        \\    return null;
        \\  };
        \\  FormData_.prototype.has=function(name){
        \\    name=String(name);
        \\    for(var i=0;i<this._entries.length;i++){
        \\      if(this._entries[i][0]===name)return true;
        \\    }
        \\    return false;
        \\  };
        \\  FormData_.prototype.getAll=function(name){
        \\    name=String(name);
        \\    var r=[];
        \\    for(var i=0;i<this._entries.length;i++){
        \\      if(this._entries[i][0]===name)r.push(this._entries[i][1]);
        \\    }
        \\    return r;
        \\  };
        \\  FormData_.prototype.append=function(name,value){
        \\    this._entries.push([String(name),String(value)]);
        \\  };
        \\  FormData_.prototype.set=function(name,value){
        \\    name=String(name);value=String(value);
        \\    var found=false;
        \\    var newE=[];
        \\    for(var i=0;i<this._entries.length;i++){
        \\      if(this._entries[i][0]===name){
        \\        if(!found){newE.push([name,value]);found=true;}
        \\      }else{newE.push(this._entries[i]);}
        \\    }
        \\    if(!found)newE.push([name,value]);
        \\    this._entries=newE;
        \\  };
        \\  FormData_.prototype['delete']=function(name){
        \\    name=String(name);
        \\    var newE=[];
        \\    for(var i=0;i<this._entries.length;i++){
        \\      if(this._entries[i][0]!==name)newE.push(this._entries[i]);
        \\    }
        \\    this._entries=newE;
        \\  };
        \\  FormData_.prototype.forEach=function(cb,thisArg){
        \\    for(var i=0;i<this._entries.length;i++){
        \\      cb.call(thisArg,this._entries[i][1],this._entries[i][0],this);
        \\    }
        \\  };
        \\  FormData_.prototype.keys=function(){
        \\    var arr=[];
        \\    for(var i=0;i<this._entries.length;i++)arr.push(this._entries[i][0]);
        \\    return arr;
        \\  };
        \\  FormData_.prototype.values=function(){
        \\    var arr=[];
        \\    for(var i=0;i<this._entries.length;i++)arr.push(this._entries[i][1]);
        \\    return arr;
        \\  };
        \\  FormData_.prototype.entries=function(){
        \\    var arr=[];
        \\    for(var i=0;i<this._entries.length;i++){
        \\      arr.push([this._entries[i][0],this._entries[i][1]]);
        \\    }
        \\    return arr;
        \\  };
        \\  try{globalThis.FormData=FormData_;}catch(e){}
        \\})();
    ;

    /// HTML §8.1.5.4 Window-reflecting body element event handler set.
    ///
    /// Installs IDL accessor descriptors on HTMLBodyElement.prototype and
    /// HTMLFrameSetElement.prototype for these six event handler attributes:
    ///
    ///   onblur, onerror, onfocus, onload, onscroll, onresize
    ///
    /// Per HTML §8.1.5.4 these IDL attributes do NOT operate on the host
    /// element directly — they get/set the corresponding event handler on
    /// the Window. The IDL setter coerces non-callable non-null values to
    /// null per HTML §8.1.5.2 step 4 ("If V is not null and is not a
    /// callable Function … set the corresponding event handler to null").
    ///
    /// `enumerable: true` mirrors how WebIDL operations + attributes are
    /// emitted on prototypes — required for `for (var k in body)` to see
    /// these attributes (testEnumerate).
    ///
    /// NOT YET implemented (testReflect / testForwardToWindow first
    /// assert): content attribute parsing into a function via
    /// `setAttribute('onblur', 'return')`. That requires HTML §8.1.5.1
    /// "compile event handler" which depends on a working Function
    /// constructor (kotori's Function ctor is currently a no-op stub),
    /// so deferred.
    const body_event_handler_polyfill_js =
        \\(function(){
        \\  if(typeof globalThis==='undefined')return;
        \\  if(typeof HTMLBodyElement==='undefined')return;
        \\  var attrs=['onblur','onerror','onfocus','onload','onscroll','onresize'];
        \\  var protos=[];
        \\  try{protos.push(HTMLBodyElement.prototype);}catch(e){}
        \\  try{if(typeof HTMLFrameSetElement!=='undefined')protos.push(HTMLFrameSetElement.prototype);}catch(e){}
        \\  function makeGetter(name){
        \\    return function(){
        \\      var v=globalThis[name];
        \\      return (typeof v==='function')?v:null;
        \\    };
        \\  }
        \\  function makeSetter(name){
        \\    return function(v){
        \\      // HTML §8.1.5.2 — non-callable non-null becomes null on set.
        \\      globalThis[name]=(typeof v==='function')?v:null;
        \\    };
        \\  }
        \\  for(var p=0;p<protos.length;p++){
        \\    var P=protos[p];
        \\    if(!P)continue;
        \\    for(var i=0;i<attrs.length;i++){
        \\      var name=attrs[i];
        \\      try{
        \\        Object.defineProperty(P,name,{
        \\          configurable:true,
        \\          enumerable:true,
        \\          get:makeGetter(name),
        \\          set:makeSetter(name)
        \\        });
        \\      }catch(e){}
        \\    }
        \\  }
        \\  // Initialise window[attr] to null so the IDL getter sees a
        \\  // defined slot (otherwise globalThis[name] is undefined and
        \\  // the for..in enumeration on globalThis won't show the slot
        \\  // — though body's getter still returns null per the
        \\  // typeof check, this keeps `'onblur' in window` truthy on
        \\  // engines where globals are visible only after first set).
        \\  for(var i=0;i<attrs.length;i++){
        \\    if(typeof globalThis[attrs[i]]==='undefined'){
        \\      try{globalThis[attrs[i]]=null;}catch(e){}
        \\    }
        \\  }
        \\})();
    ;

    /// Encoding §9 TextEncoder / TextDecoder polyfill for kotori.
    /// Mirrors the QuickJS-side polyfill in web_api.zig. Provides
    /// UTF-8 encode/decode with surrogate-pair handling per the
    /// WHATWG Encoding Standard: lone surrogates → U+FFFD on encode;
    /// invalid UTF-8 sequences → U+FFFD on decode.
    const text_encoder_polyfill_js =
        \\if(typeof TextEncoder==='undefined'){
        \\  globalThis.TextEncoder=function(){};
        \\  TextEncoder.prototype.encode=function(s){
        \\    if(s===undefined||s===null)return new Uint8Array(0);
        \\    var a=[];for(var i=0;i<s.length;i++){var c=s.charCodeAt(i);
        \\      if(c>=0xD800&&c<=0xDBFF){
        \\        var lo=s.charCodeAt(i+1);
        \\        if(lo>=0xDC00&&lo<=0xDFFF){var cp=0x10000+((c-0xD800)<<10)+(lo-0xDC00);a.push(0xF0|(cp>>18));a.push(0x80|((cp>>12)&0x3F));a.push(0x80|((cp>>6)&0x3F));a.push(0x80|(cp&0x3F));i++;}
        \\        else{a.push(0xEF);a.push(0xBF);a.push(0xBD);}
        \\      }else if(c>=0xDC00&&c<=0xDFFF){a.push(0xEF);a.push(0xBF);a.push(0xBD);}
        \\      else if(c<0x80)a.push(c);
        \\      else if(c<0x800){a.push(0xC0|(c>>6));a.push(0x80|(c&0x3F));}
        \\      else{a.push(0xE0|(c>>12));a.push(0x80|((c>>6)&0x3F));a.push(0x80|(c&0x3F));}
        \\    }return new Uint8Array(a);
        \\  };
        \\  TextEncoder.prototype.encoding='utf-8';
        \\}
        \\if(typeof TextDecoder==='undefined'){
        \\  globalThis.TextDecoder=function(enc,opts){
        \\    // Encoding §10.2 step 2-3: label validation
        \\    var _label;
        \\    if(enc===undefined||enc===null){_label='utf-8';}
        \\    else if(typeof enc==='object'&&enc!==null&&typeof enc.toString==='function'){
        \\      var ts=enc.toString();
        \\      if(typeof ts!=='string')throw new TypeError('toString returned non-string');
        \\      _label=ts;
        \\    }else{_label=String(enc);}
        \\    if(_label==='')throw new RangeError('Encoding label must not be empty');
        \\    var label=_label.toLowerCase();
        \\    // Only support encoding labels that are valid per Encoding §4.12
        \\    // Encoding §4.12 label → canonical name mapping
        \\    var labels={'unicode-1-1-utf-8':'utf-8',utf8:'utf-8',unicode11utf8:'utf-8',
        \\      unicode20utf8:'utf-8','x-utf8':'utf-8','utf-16le':'utf-16le','utf-16':'utf-16le',
        \\      'utf-16be':'utf-16be',csunicode:'utf-16le',unicodefffe:'utf-16be',
        \\      ucs2:'utf-16le','iso-10646-ucs-2':'utf-16le',
        \\      ascii:'windows-1252','iso-8859-1':'windows-1252',latin1:'windows-1252',
        \\      'iso-8859-2':'iso-8859-2','iso-8859-15':'iso-8859-15',
        \\      'windows-1252':'windows-1252','ansi_x3.4-1968':'windows-1252',
        \\      'iso-ir-6':'windows-1252','iso646-us':'windows-1252',us:'windows-1252',
        \\      ibm367:'windows-1252',cp367:'windows-1252',csascii:'windows-1252',
        \\      'iso-8859-1:1987':'windows-1252','iso_8859-1:1987':'windows-1252',
        \\      'iso-ir-100':'windows-1252','iso_8859-1':'windows-1252',latin1l:'windows-1252',
        \\      csisolatin1:'windows-1252',iso88591:'windows-1252','iso_8859-1:1987rb':'windows-1252'};
        \\    this.encoding=labels[label]||label;
        \\    this.fatal=!!(opts&&opts.fatal);this.ignoreBOM=!!(opts&&opts.ignoreBOM);
        \\    this._pending=null; // Encoding §9.2 step 5 — pending buffer for stream decode
        \\  };
        \\  TextDecoder.prototype.decode=function(buf,opts){
        \\    var stream=!!(opts&&opts.stream);
        \\    // Encoding §9.2 step 7-8: flush on null/undefined input
        \\    if(buf===undefined||buf===null||buf.byteLength===0){
        \\      if(this._pending){var r=String.fromCharCode(0xFFFD);this._pending=null;return r;}
        \\      return'';
        \\    }
        \\    var a=buf instanceof Uint8Array?buf:new Uint8Array(buf.buffer||buf);
        \\    // Prepend pending bytes from previous stream decode (Encoding §9.2 step 6)
        \\    if(this._pending){
        \\      var c=new Uint8Array(this._pending.length+a.length);
        \\      c.set(this._pending);c.set(a,this._pending.length);a=c;this._pending=null;
        \\    }
        \\    var s='',i=0;
        \\    // UTF-16 decode (little-endian, big-endian, auto-detect)
        \\    if(this.encoding==='utf-16le'||this.encoding==='utf-16be'||this.encoding==='utf-16'){
        \\      var isLE=this.encoding==='utf-16le'||this.encoding==='utf-16';
        \\      if(this.encoding==='utf-16'&&a.length>=2){
        \\        if(a[0]===0xFF&&a[1]===0xFE){isLE=true;i=2;}
        \\        else if(a[0]===0xFE&&a[1]===0xFF){isLE=false;i=2;}
        \\        // else: no BOM — keep isLE=true (Encoding §6.2 step 4, default LE)
        \\      }else if(!this.ignoreBOM&&a.length>=2){
        \\        if((isLE&&a[0]===0xFF&&a[1]===0xFE)||(!isLE&&a[0]===0xFE&&a[1]===0xFF))i=2;
        \\      }
        \\      while(i<a.length){
        \\        if(i+1>=a.length){if(stream){this._pending=a.slice(i);break;}else{s+=String.fromCharCode(0xFFFD);break;}}
        \\        var w=isLE?(a[i]|(a[i+1]<<8)):((a[i]<<8)|a[i+1]);i+=2;
        \\        if(w>=0xD800&&w<=0xDBFF){ // high surrogate
        \\          if(i+1>=a.length){
        \\            if(stream){this._pending=a.slice(i-2);break;} // save from high surrogate
        \\            else{s+=String.fromCharCode(0xFFFD);break;}
        \\          }
        \\          var w2=isLE?(a[i]|(a[i+1]<<8)):((a[i]<<8)|a[i+1]);
        \\          if(w2>=0xDC00&&w2<=0xDFFF){s+=String.fromCodePoint(0x10000+((w-0xD800)<<10)+(w2-0xDC00));i+=2;}
        \\          else{s+=String.fromCharCode(0xFFFD);}
        \\        }else if(w>=0xDC00&&w<=0xDFFF){s+=String.fromCharCode(0xFFFD);} // lone low surrogate
        \\        else{s+=String.fromCharCode(w);}
        \\      }return s;
        \\    }
        \\    // UTF-8 decode
        \\    function isCont(b){return b>=0x80&&b<=0xBF;}
        \\    while(i<a.length){var b=a[i];
        \\      if(b<0x80){s+=String.fromCharCode(b);i++;}
        \\      else if(b<0xC2){s+=String.fromCharCode(0xFFFD);i++;}
        \\      else if(b<0xE0){
        \\        if(i+1>=a.length||!isCont(a[i+1])){
        \\          if(stream&&i+1>=a.length){this._pending=a.slice(i);break;} // save trailing for stream
        \\          else{s+=String.fromCharCode(0xFFFD);i++;}
        \\        }else{s+=String.fromCharCode(((b&0x1F)<<6)|(a[i+1]&0x3F));i+=2;}
        \\      }else if(b<0xF0){
        \\        if(i+2>=a.length||!isCont(a[i+1])||!isCont(a[i+2])){
        \\          if(stream&&i+2>=a.length){this._pending=a.slice(i);break;} // save trailing for stream
        \\          else{s+=String.fromCharCode(0xFFFD);i++;}
        \\        }else{var cp3=((b&0x0F)<<12)|((a[i+1]&0x3F)<<6)|(a[i+2]&0x3F);
        \\          if(cp3<0x800){s+=String.fromCharCode(0xFFFD);i++;}
        \\          else{s+=String.fromCharCode(cp3);i+=3;}}
        \\      }else if(b<0xF5){
        \\        if(i+3>=a.length||!isCont(a[i+1])||!isCont(a[i+2])||!isCont(a[i+3])){
        \\          if(stream&&i+3>=a.length){this._pending=a.slice(i);break;} // save trailing for stream
        \\          else{s+=String.fromCharCode(0xFFFD);i++;}
        \\        }else{var cp4=((b&0x07)<<18)|((a[i+1]&0x3F)<<12)|((a[i+2]&0x3F)<<6)|(a[i+3]&0x3F);
        \\          if(cp4<0x10000||cp4>0x10FFFF){s+=String.fromCharCode(0xFFFD);i++;}
        \\          else{s+=String.fromCodePoint(cp4);i+=4;}}
        \\      }else{s+=String.fromCharCode(0xFFFD);i++;}
        \\    }return s;
        \\  };
        \\}
    ;

    /// FileAPI §6-§8: Blob, File, FileReader polyfill for kotori.
    /// Mirrors QuickJS polyfill in web_api.zig. Provides Blob (type/size/
    /// slice/text/arrayBuffer), File (name/lastModified), and FileReader
    /// (readAsText/readAsArrayBuffer/readAsDataURL/abort).
    const blob_file_polyfill_js =
        \\if(typeof Blob==='undefined'){
        \\  globalThis.Blob=function(parts,opts){
        \\    this.type=(opts&&opts.type)||'';
        \\    var s='';if(parts)for(var i=0;i<parts.length;i++)s+=typeof parts[i]==='string'?parts[i]:String(parts[i]);
        \\    this._data=s;this.size=s.length;
        \\  };
        \\  Blob.prototype.text=function(){return Promise.resolve(this._data);};
        \\  Blob.prototype.arrayBuffer=function(){var b=new ArrayBuffer(this._data.length);var v=new Uint8Array(b);for(var i=0;i<this._data.length;i++)v[i]=this._data.charCodeAt(i);return Promise.resolve(b);};
        \\  Blob.prototype.slice=function(s,e,t){return new Blob([this._data.slice(s,e)],{type:t||this.type});};
        \\}
        \\{ // always overwrite stub from file_input_polyfill_js (Wave 158)
        \\  globalThis.File=function(parts,name,opts){
        \\    Blob.call(this,parts,opts);this.name=name;this.lastModified=(opts&&opts.lastModified)||Date.now();
        \\  };
        \\  File.prototype=Object.create(Blob.prototype);File.prototype.constructor=File;
        \\}
        \\if(typeof FileReader==='undefined'){
        \\  globalThis.FileReader=function(){this.readyState=0;this.result=null;this.error=null;this.onload=null;this.onerror=null;this.onloadend=null;};
        \\  FileReader.EMPTY=0;FileReader.LOADING=1;FileReader.DONE=2;
        \\  FileReader.prototype.readAsText=function(blob){var self=this;self.readyState=1;blob.text().then(function(t){self.result=t;self.readyState=2;if(self.onload)self.onload({target:self});if(self.onloadend)self.onloadend({target:self});});};
        \\  FileReader.prototype.readAsArrayBuffer=function(blob){var self=this;self.readyState=1;blob.arrayBuffer().then(function(b){self.result=b;self.readyState=2;if(self.onload)self.onload({target:self});if(self.onloadend)self.onloadend({target:self});});};
        \\  FileReader.prototype.readAsDataURL=function(blob){var self=this;self.readyState=1;blob.text().then(function(t){self.result='data:'+(blob.type||'')+';base64,'+btoa(t);self.readyState=2;if(self.onload)self.onload({target:self});if(self.onloadend)self.onloadend({target:self});});};
        \\  FileReader.prototype.abort=function(){this.readyState=2;if(this.onerror)this.onerror({target:this});};
        \\}
    ;

    /// WHATWG URL §6: URLSearchParams polyfill for kotori.
    /// Pure-JS implementation with full append/delete/entries/forEach/get/
    /// getAll/has/set/sort/size/toString/iterator support plus proper
    /// application/x-www-form-urlencoded serialization.
    const url_search_params_polyfill_js =
        \\(function(){
        \\  "use strict";
        \\  if(typeof URLSearchParams!=='undefined'&&URLSearchParams.prototype&&URLSearchParams.prototype.sort)return;
        \\  function percentDecode(s){try{return decodeURIComponent(s);}catch(e){var out='';for(var i=0;i<s.length;i++){if(s.charAt(i)==='%'&&i+2<s.length){var h=s.substring(i+1,i+3);if(/^[0-9A-Fa-f]{2}$/.test(h)){out+=decodeURIComponent(s.substring(i,i+3));i+=2;continue;}}out+=s.charAt(i);}return out;}}
        \\  function cuAt(s,pos){var cp=s.charCodeAt(pos);return cp>=0x10000?0xD800+((cp-0x10000)>>10):pos<s.length?cp:-1;}
        \\  function cuLen(s){var l=0;for(var i=0;i<s.length;i++){var c=s.charCodeAt(i);l+=c>=0x10000?2:1;}return l;}
        \\  function URLSearchParams(init){
        \\    this._e=[];
        \\    if(init===undefined||init===null)return;
        \\    if(typeof init==='string'){
        \\      var s=init.charAt(0)==='?'?init.substring(1):init;
        \\      if(s){
        \\        var pairs=s.split('&');
        \\        for(var i=0;i<pairs.length;i++){
        \\          if(pairs[i]==='')continue;
        \\          var eq=pairs[i].indexOf('=');
        \\          var n,v;
        \\          if(eq>=0){n=pairs[i].substring(0,eq);v=pairs[i].substring(eq+1);}
        \\          else{n=pairs[i];v='';}
        \\          var replP=function(t){return t.split('+').join(' ');};
        \\          this._e.push([percentDecode(replP(n)),percentDecode(replP(v))]);
        \\        }
        \\      }
        \\    }else if(Array.isArray(init)){for(var i=0;i<init.length;i++)this._e.push([String(init[i][0]),String(init[i][1])]);}
        \\    else if(init&&init._entries&&typeof init._entries.length==='number'){for(var i=0;i<init._entries.length;i++)this._e.push([String(init._entries[i][0]),String(init._entries[i][1])]);}
        \\    else if(init&&typeof init.entries==='function'){
        \\      var it=init.entries();
        \\      var r=it.next?it.next():null;
        \\      while(r&&!r.done){var p=r.value;this._e.push([String(p[0]),String(p[1])]);r=it.next?it.next():null;}
        \\    }else if(typeof Symbol!=='undefined'&&Symbol.iterator&&init[Symbol.iterator]){
        \\      var it=init[Symbol.iterator](),r;
        \\      while(!(r=it.next()).done){var p=r.value;if(!p||typeof p.length!=='number'||p.length<2)throw new TypeError('URLSearchParams: expected a sequence of name-value pairs');this._e.push([String(p[0]),String(p[1])]);}
        \\    }else if(typeof init==='object'||typeof init==='function'){
        \\      var keys=Object.keys(init);
        \\      for(var i=0;i<keys.length;i++)this._e.push([String(keys[i]),String(init[keys[i]])]);
        \\    }
        \\  }
        \\  URLSearchParams.prototype.toString=function(){return this._e.map(function(p){return encodeURIComponent(p[0]).replace(/%20/g,'+').replace(/%2A/g,'*')+'='+encodeURIComponent(p[1]).replace(/%20/g,'+').replace(/%2A/g,'*');}).join('&');};
        \\  URLSearchParams.prototype.valueOf=function(){return this.toString();};
        \\  URLSearchParams.prototype.append=function(n,v){this._e.push([String(n),String(v)]);if(this._updateURL)this._updateURL();};
        \\  URLSearchParams.prototype["delete"]=function(n,v){
        \\    n=String(n);var hasVal=v!==undefined;var nv=hasVal?String(v):null;var e=this._e;
        \\    var newE=[];for(var i=0;i<e.length;i++){if(!(e[i][0]===n&&(!hasVal||e[i][1]===nv)))newE.push(e[i]);}
        \\    this._e=newE;
        \\    if(this._updateURL)this._updateURL();
        \\  };
        \\  URLSearchParams.prototype.get=function(n){n=String(n);for(var i=0;i<this._e.length;i++)if(this._e[i][0]===n)return this._e[i][1];return null;};
        \\  URLSearchParams.prototype.getAll=function(n){n=String(n);var r=[];for(var i=0;i<this._e.length;i++)if(this._e[i][0]===n)r.push(this._e[i][1]);return r;};
        \\  URLSearchParams.prototype.has=function(n,v){n=String(n);for(var i=0;i<this._e.length;i++)if(this._e[i][0]===n&&(v===undefined||this._e[i][1]===String(v)))return true;return false;};
        \\  URLSearchParams.prototype.set=function(n,v){
        \\    n=String(n);v=String(v);var found=false,e=this._e;
        \\    for(var i=0;i<e.length;i++){
        \\      if(e[i][0]===n){
        \\        if(!found){e[i][1]=v;found=true;}
        \\        else{e.splice(i,1);i--;}
        \\      }
        \\    }
        \\    if(!found)e.push([n,v]);
        \\    if(this._updateURL)this._updateURL();
        \\  };
        \\  URLSearchParams.prototype.sort=function(){var e=this._e,i;for(i=0;i<e.length;i++)e[i]._$i=i;e.sort(function(a,b){var ak=a[0],bk=b[0];var j=0;while(j<ak.length||j<bk.length){var ca=cuAt(ak,j),cb=cuAt(bk,j);if(ca===-1&&cb===-1)break;if(ca===-1)return -1*cb;if(cb===-1)return ca;if(ca!==cb)return ca-cb;j++;}return a._$i-b._$i;});for(i=0;i<e.length;i++)delete e[i]._$i;if(this._updateURL)this._updateURL();};
        \\  try{Object.defineProperty(URLSearchParams.prototype,'size',{get:function(){return this._e.length;},configurable:true,enumerable:true});}catch(e){}
        \\  URLSearchParams.prototype.forEach=function(cb,thisArg){for(var i=0;i<this._e.length;i++)cb.call(thisArg,this._e[i][1],this._e[i][0],this);};
        \\  URLSearchParams.prototype.entries=function(){var self=this,i=0;var it={next:function(){if(i<self._e.length){var v=[self._e[i][0],self._e[i][1]];i++;return{value:v,done:false};}return{value:undefined,done:true};}};if(typeof Symbol!=='undefined'&&Symbol.iterator)it[Symbol.iterator]=function(){return this;};return it;};
        \\  URLSearchParams.prototype.keys=function(){var self=this,i=0;var it={next:function(){return i<self._e.length?{value:self._e[i++][0],done:false}:{value:undefined,done:true};}};if(typeof Symbol!=='undefined'&&Symbol.iterator)it[Symbol.iterator]=function(){return this;};return it;};
        \\  URLSearchParams.prototype.values=function(){var self=this,i=0;var it={next:function(){return i<self._e.length?{value:self._e[i++][1],done:false}:{value:undefined,done:true};}};if(typeof Symbol!=='undefined'&&Symbol.iterator)it[Symbol.iterator]=function(){return this;};return it;};
        \\  if(typeof Symbol!=='undefined'&&Symbol.iterator)URLSearchParams.prototype[Symbol.iterator]=URLSearchParams.prototype.entries;
        \\  globalThis.URLSearchParams=URLSearchParams;
        \\})();
    ;

    /// HTML §3.2.6 / §3.2.6.1 DOMStringMap (dataset) polyfill for kotori.
    ///
    /// Installs `Element.prototype.dataset` as a getter returning a Proxy
    /// that maps camelCase property access to data-* content attributes.
    ///
    /// Name conversion rules (HTML §3.2.6.1):
    ///   - camelCase → kebab:  insert '-' before each uppercase letter, lowercase it
    ///     e.g.  fooBar  → data-foo-bar
    ///   - kebab → camelCase:  strip 'data-', convert -x → X
    ///     e.g.  data-foo-bar → fooBar
    ///
    /// Supported operations:
    ///   - get  dataset.fooBar     → getAttribute('data-foo-bar') ?? undefined
    ///   - set  dataset.fooBar='v' → setAttribute('data-foo-bar', 'v')
    ///   - has  'fooBar' in dataset → hasAttribute('data-foo-bar')
    ///   - delete dataset.fooBar  → removeAttribute('data-foo-bar')
    ///   - ownKeys / enumerate    → all data-* attribute names converted to camelCase
    ///
    /// DOM §4.11 Text.prototype.splitText and Text.prototype.wholeText.
    /// kotori's native bindings expose `data` as an own-data-via-domNodeSet
    /// path on Text nodes; this polyfill layers the two missing methods on
    /// top. Both call out to native `document.createTextNode` /
    /// `parentNode.insertBefore` for tree mutation.
    const text_polyfill_js =
        \\(function(){
        \\  if(typeof Text==='undefined'||!Text.prototype)return;
        \\  var P=Text.prototype;
        \\  // DOM §4.11.4 splitText(offset) — split this Text into two at offset.
        \\  if(typeof P.splitText!=='function'){
        \\    P.splitText=function(o){
        \\      if(this.nodeType!==3)throw new DOMException("Not a Text node",'InvalidNodeTypeError');
        \\      o=o>>>0;
        \\      var s=this.data||'';
        \\      if(o>s.length)throw new DOMException('The index is not in the allowed range.','IndexSizeError');
        \\      var newData=s.slice(o);
        \\      this.data=s.slice(0,o);
        \\      var n=document.createTextNode(newData);
        \\      if(this.parentNode)this.parentNode.insertBefore(n,this.nextSibling);
        \\      return n;
        \\    };
        \\  }
        \\  // DOM §4.11.3 wholeText getter — concatenate text of all adjacent
        \\  // Text siblings (walking previousSibling first, then nextSibling).
        \\  try{
        \\    Object.defineProperty(P,'wholeText',{get:function(){
        \\      if(this.nodeType!==3)return this.data;
        \\      var t='',n=this;
        \\      while(n.previousSibling&&n.previousSibling.nodeType===3)n=n.previousSibling;
        \\      while(n&&n.nodeType===3){t+=n.data;n=n.nextSibling;}
        \\      return t;
        \\    },configurable:true});
        \\  }catch(e){}
        \\})();
    ;

    /// Identity cache: the same Proxy object is returned on repeated accesses
    /// (WebIDL [SameObject]) using a hidden `__datasetProxy` slot.
    const dataset_polyfill_js =
        \\(function(){
        \\  if(typeof Element==='undefined'||!Element.prototype)return;
        \\  // DOMStringMap class for instanceof checks.
        \\  // HTML §3.2.6: `dataset` is a DOMStringMap. WPT
        \\  // dataset.html test uses `dataset instanceof DOMStringMap`.
        \\  if(typeof globalThis.DOMStringMap==='undefined'){
        \\    globalThis.DOMStringMap=function DOMStringMap(){};
        \\  }
        \\  // Convert camelCase key → data-* attribute name.
        \\  // HTML §3.2.6.1 step 2: for each uppercase letter U, insert '-'+lowercase(U).
        \\  function toAttr(key){
        \\    var s='data-';
        \\    for(var i=0;i<key.length;i++){
        \\      var c=key[i];
        \\      if(c>='A'&&c<='Z'){s+='-'+c.toLowerCase();}
        \\      else{s+=c;}
        \\    }
        \\    return s;
        \\  }
        \\  // Convert data-* attribute name → camelCase key.
        \\  // HTML §3.2.6.1 step 1: strip 'data-', for each '-x' → uppercase(x).
        \\  function toKey(attr){
        \\    var s=attr.slice(5); // strip 'data-'
        \\    var out='';
        \\    var i=0;
        \\    while(i<s.length){
        \\      var c=s[i];
        \\      if(c==='-'&&i+1<s.length){
        \\        var nx=s[i+1];
        \\        if(nx>='a'&&nx<='z'){out+=nx.toUpperCase();i+=2;continue;}
        \\      }
        \\      out+=c;i++;
        \\    }
        \\    return out;
        \\  }
        \\  // Check if an attribute name is a valid data-* name (lowercase only after 'data-').
        \\  function isDataAttr(name){
        \\    if(name.length<=5||name.slice(0,5)!=='data-')return false;
        \\    // data-* names must not contain uppercase letters per HTML §3.2.6.1
        \\    var rest=name.slice(5);
        \\    for(var i=0;i<rest.length;i++){
        \\      var c=rest[i];
        \\      if(c>='A'&&c<='Z')return false;
        \\    }
        \\    return true;
        \\  }
        \\  var SLOT='__datasetProxy';
        \\  // HTML §3.2.6.1 attribute name's algorithm rejects keys with a
        \\  // '-' followed by an ASCII lowercase letter. The setter / deleter
        \\  // throw SyntaxError in that case; the getter / has trap simply
        \\  // report the property as missing because no valid `data-*`
        \\  // attribute can ever round-trip back to such a key.
        \\  function _dsValidKey(key){
        \\    for(var i=0;i<key.length;i++){
        \\      if(key[i]==='-' && i+1<key.length){
        \\        var nx=key.charCodeAt(i+1);
        \\        if(nx>=0x61 && nx<=0x7A) return false;
        \\      }
        \\    }
        \\    return true;
        \\  }
        \\  var handler={
        \\    get:function(el,key){
        \\      if(typeof key!=='string')return undefined;
        \\      if(!_dsValidKey(key))return undefined;
        \\      var v=el.getAttribute(toAttr(key));
        \\      return v===null?undefined:v;
        \\    },
        \\    set:function(el,key,value){
        \\      if(typeof key!=='string')return true;
        \\      // HTML §3.2.6.1 attribute name algorithm step 2.1: a U+002D
        \\      // HYPHEN-MINUS followed by an ASCII lowercase letter renders
        \\      // the key invalid → throw a "SyntaxError" DOMException.
        \\      for(var i=0;i<key.length;i++){
        \\        if(key[i]==='-' && i+1<key.length){
        \\          var nx=key.charCodeAt(i+1);
        \\          if(nx>=0x61 && nx<=0x7A){
        \\            throw new DOMException('Invalid dataset key: '+key,'SyntaxError');
        \\          }
        \\        }
        \\      }
        \\      el.setAttribute(toAttr(key),''+value);
        \\      return true;
        \\    },
        \\    has:function(el,key){
        \\      if(typeof key!=='string')return false;
        \\      if(!_dsValidKey(key))return false;
        \\      return el.hasAttribute(toAttr(key));
        \\    },
        \\    deleteProperty:function(el,key){
        \\      if(typeof key!=='string')return true;
        \\      // HTML §3.2.6.1 — invalid dataset keys ('-' + a-z) cannot map
        \\      // back to a valid `data-*` attribute, so the deletion silently
        \\      // no-ops (matches Chrome/Firefox observable behaviour: the
        \\      // dataset-delete WPT calls `delete dataset['-foo']` without a
        \\      // try/catch and expects the attribute to remain intact).
        \\      if(!_dsValidKey(key))return true;
        \\      el.removeAttribute(toAttr(key));
        \\      return true;
        \\    },
        \\    ownKeys:function(el){
        \\      var keys=[];
        \\      var attrs=el.attributes;
        \\      if(!attrs)return keys;
        \\      for(var i=0;i<attrs.length;i++){
        \\        var a=attrs[i];
        \\        var nm=a?a.name:null;
        \\        if(nm&&isDataAttr(nm))keys.push(toKey(nm));
        \\      }
        \\      return keys;
        \\    },
        \\    getOwnPropertyDescriptor:function(el,key){
        \\      if(typeof key!=='string')return undefined;
        \\      var attr=toAttr(key);
        \\      if(!el.hasAttribute(attr))return undefined;
        \\      return{value:el.getAttribute(attr),writable:true,enumerable:true,configurable:true};
        \\    }
        \\  };
        \\  // HTML §3.2.6: dataset is on HTMLElement, SVGElement, MathMLElement.
        \\  // Random-namespace elements (e.g., createElementNS("test", ...))
        \\  // do NOT have dataset. WPT dataset.html "Should not have a
        \\  // .dataset on random elements" — return undefined.
        \\  var HTML_NS='http://www.w3.org/1999/xhtml';
        \\  var SVG_NS='http://www.w3.org/2000/svg';
        \\  var MATHML_NS='http://www.w3.org/1998/Math/MathML';
        \\  function hasDataset(el){
        \\    var ns=el.namespaceURI;
        \\    if(ns==null)return true;
        \\    return ns===HTML_NS||ns===SVG_NS||ns===MATHML_NS;
        \\  }
        \\  Object.defineProperty(Element.prototype,'dataset',{
        \\    get:function(){
        \\      if(!hasDataset(this))return undefined;
        \\      var cached=this[SLOT];
        \\      if(cached)return cached;
        \\      // Target inherits DOMStringMap.prototype so the Proxy passes
        \\      // `instanceof DOMStringMap` (instanceof opcode walks
        \\      // target.prototype after Wave 61 proxyGetPrototype fix).
        \\      var target=Object.create(DOMStringMap.prototype);
        \\      // Copy element reference so handler can read/write attrs.
        \\      // Proxy traps already accept the target as `el`; bridge by
        \\      // routing through a wrapper handler that uses `this`.
        \\      var elRef=this;
        \\      var wrapHandler={
        \\        get:function(_t,k){
        \\          var v=handler.get(elRef,k);
        \\          /* HTML §3.2.6 — DOMStringMap inherits from Object.prototype.
        \\           * If the named getter has no match (no `data-*` attribute
        \\           * mapping to this key), fall through to the target's
        \\           * prototype chain so `dataset.toString` resolves to
        \\           * Object.prototype.toString. */
        \\          if(v===undefined && typeof k==='string' && !handler.has(elRef,k)) return _t[k];
        \\          return v;
        \\        },
        \\        set:function(_t,k,v){
        \\          var r=handler.set(elRef,k,v);
        \\          // Force return true so the engine doesn't write to the
        \\          // proxy target after the trap (some Proxy impls fall
        \\          // back to setting on target if the trap return is
        \\          // mis-interpreted).
        \\          return true;
        \\        },
        \\        has:function(_t,k){
        \\          if(handler.has(elRef,k))return true;
        \\          /* HTML §3.2.6 keeps the DOMStringMap on Object.prototype's
        \\           * chain — fall through to the target's [[HasProperty]] so
        \\           * `'toString' in dataset` (and other inherited members)
        \\           * still report true. */
        \\          return k in _t;
        \\        },
        \\        deleteProperty:function(_t,k){return handler.deleteProperty(elRef,k);},
        \\        ownKeys:function(_t){return handler.ownKeys(elRef);},
        \\        getOwnPropertyDescriptor:function(_t,k){return handler.getOwnPropertyDescriptor(elRef,k);},
        \\        getPrototypeOf:function(){return DOMStringMap.prototype;}
        \\      };
        \\      var p=new Proxy(target,wrapHandler);
        \\      try{Object.defineProperty(this,SLOT,{value:p,writable:false,enumerable:false,configurable:false});}catch(e){}
        \\      return p;
        \\    },
        \\    configurable:true,
        \\    enumerable:true
        \\  });
        \\})();
    ;

    /// DOM Parsing and Serialization §2.1 — DOMParser polyfill for the kotori
    /// engine. The native implementation in kotori_dom.zig registers
    /// `DOMParser` as a global constructor with a native `parseFromString`.
    /// This pure-JS fallback provides the same interface when running without
    /// the native bindings. Supported content types: text/html (full HTML parse
    /// via innerHTML), text/xml / application/xml / application/xhtml+xml /
    /// image/svg+xml (basic XML string parse through createHTMLDocument + innerHTML).
    const domparser_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.DOMParser !== 'undefined') return;
        \\  function DOMParser(){
        \\    if (!(this instanceof DOMParser))
        \\      throw new TypeError("Failed to construct 'DOMParser': Please use the 'new' operator.");
        \\  }
        \\  /// DOM Parsing and Serialization §2.2: parseFromString(str, type) → Document.
        \\  /// type is the MIME content type:
        \\  ///   "text/html"            → HTML parse (standard path)
        \\  ///   "text/xml"            }
        \\  ///   "application/xml"     } XML-mode: parse via innerHTML
        \\  ///   "application/xhtml+xml}  (lexbor-style tag soup), then set
        \\  ///   "image/svg+xml"       }  contentType to the requested type.
        \\  DOMParser.prototype.parseFromString = function(str, type) {
        \\    type = String(type);
        \\    str = String(str);
        \\    var isHtml = type === 'text/html';
        \\    var isXml = type === 'text/xml' || type === 'application/xml' ||
        \\                type === 'application/xhtml+xml' || type === 'image/svg+xml';
        \\    if (!isHtml && !isXml)
        \\      throw new TypeError("Failed to execute 'parseFromString' on 'DOMParser': The provided type '" + type + "' is not supported.");
        \\    // Use document.implementation.createHTMLDocument for a clean Document.
        \\    var doc;
        \\    if (typeof document !== 'undefined' && document.implementation &&
        \\        typeof document.implementation.createHTMLDocument === 'function') {
        \\      doc = document.implementation.createHTMLDocument('');
        \\    } else {
        \\      // Fallback: create a minimal Document stub
        \\      doc = { nodeType: 9, documentElement: null, body: null, head: null };
        \\    }
        \\    // Parse via innerHTML inside a temporary element.
        \\    // Per spec, text/html sets the doc's type to "text/html".
        \\    var tmp = doc.createElement ? doc.createElement('div') :
        \\      typeof document !== 'undefined' ? document.createElement('div') : null;
        \\    if (!tmp) return doc;
        \\    tmp.innerHTML = str;
        \\    // For <html>/<head>/<body> parsing: innerHTML on a <div> won't
        \\    // create those when the source is a full document. Detect and
        \\    // reconstruct the minimal document structure.
        \\    var hasHtml = false, hasHead = false, hasBody = false;
        \\    for (var i = 0; i < tmp.childNodes.length; i++) {
        \\      var c = tmp.childNodes[i];
        \\      if (c.nodeType === 1) {
        \\        var tn = (c.tagName || '').toLowerCase();
        \\        if (tn === 'html') hasHtml = true;
        \\        if (tn === 'head') hasHead = true;
        \\        if (tn === 'body') hasBody = true;
        \\      }
        \\    }
        \\    if (isHtml) {
        \\      // Ensure documentElement exists (spec requires it for HTML docs).
        \\      if (hasHtml) {
        \\        // Find the <html> element and make it doc.documentElement.
        \\        for (var j = 0; j < tmp.childNodes.length; j++) {
        \\          var cn = tmp.childNodes[j];
        \\          if (cn.nodeType === 1 && (cn.tagName||'').toLowerCase() === 'html') {
        \\            if (doc.documentElement) {
        \\              while (cn.firstChild) doc.documentElement.appendChild(cn.firstChild);
        \\            } else {
        \\              doc.appendChild(cn);
        \\            }
        \\          } else if (cn.nodeType === 1) {
        \\            if (doc.documentElement) doc.documentElement.appendChild(cn);
        \\            else {
        \\              try { doc.appendChild(cn); } catch(e) {}
        \\            }
        \\          } else {
        \\            if (doc.documentElement) doc.documentElement.appendChild(cn);
        \\            else {
        \\              try { doc.appendChild(cn); } catch(e) {}
        \\            }
        \\          }
        \\        }
        \\      } else {
        \\        while (tmp.firstChild) {
        \\          if (doc.documentElement) {
        \\            doc.documentElement.appendChild(tmp.firstChild);
        \\          } else {
        \\            try { doc.appendChild(tmp.firstChild); } catch(e) { break; }
        \\          }
        \\        }
        \\      }
        \\      try { doc.contentType = 'text/html'; } catch(e) {}
        \\    } else {
        \\      // XML-mode: wrap parsed children in the document.
        \\      while (tmp.firstChild) {
        \\        try { doc.appendChild(tmp.firstChild); } catch(e) { break; }
        \\      }
        \\      if (doc.documentElement && doc.documentElement.nodeType === 1) {
        \\        try { doc.documentElement.setAttribute('xmlns', 'http://www.w3.org/1999/xhtml'); } catch(e) {}
        \\      }
        \\      try { doc.contentType = type; } catch(e) {}
        \\    }
        \\    return doc;
        \\  };
        \\  globalThis.DOMParser = DOMParser;
        \\  try { Object.defineProperty(DOMParser, 'name', { value: 'DOMParser', configurable: true }); } catch(e) {}
        \\})();
    ;

    /// DOM §4.3 — MutationObserver polyfill for the kotori engine.
    /// The native implementation in kotori_dom.zig provides a fully
    /// integrated MutationObserver with lexbor DOM hooks (observe,
    /// disconnect, takeRecords) and mutated-node recording in the C layer.
    /// This pure-JS fallback uses a polling-based approach when the native
    /// implementation is unavailable: snapshots childList/attributes of
    /// observed targets on each observe() call and checks for changes on a
    /// timer, while also monkey-patching Node/Element DOM mutation methods
    /// to queue MutationRecords synchronously.
    const mutation_observer_polyfill_js =
        \\(function(){
        \\  if (typeof globalThis.MutationObserver !== 'undefined') return;
        \\
        \\  function MutationRecord(type, target) {
        \\    this.type = type;
        \\    this.target = target;
        \\    this.addedNodes = (target.ownerDocument ? target.ownerDocument.createDocumentFragment() : null) || [];
        \\    this.removedNodes = (target.ownerDocument ? target.ownerDocument.createDocumentFragment() : null) || [];
        \\    this.previousSibling = null;
        \\    this.nextSibling = null;
        \\    this.attributeName = null;
        \\    this.attributeNamespace = null;
        \\    this.oldValue = null;
        \\  }
        \\
        \\  function MutationObserver(callback) {
        \\    if (!(this instanceof MutationObserver))
        \\      throw new TypeError("Failed to construct 'MutationObserver': Please use the 'new' operator.");
        \\    this._callback = callback;
        \\    this._targets = [];
        \\    this._records = [];
        \\    this._pending = false;
        \\  }
        \\
        \\  /// Global registry of all active MutationObservers.
        \\  var g_observers = [];
        \\
        \\  /// Notify all matching observers about a list of MutationRecords.
        \\  function _broadcast(records) {
        \\    for (var oi = 0; oi < g_observers.length; oi++) {
        \\      var obs = g_observers[oi];
        \\      if (obs._disconnected) continue;
        \\      var matched = [];
        \\      for (var ri = 0; ri < records.length; ri++) {
        \\        var rec = records[ri];
        \\        for (var ti = 0; ti < obs._targets.length; ti++) {
        \\          var t = obs._targets[ti];
        \\          if (rec.target === t.target) { matched.push(rec); break; }
        \\          if (t.options.subtree && t.target.contains && t.target.contains(rec.target)) {
        \\            matched.push(rec); break;
        \\          }
        \\        }
        \\      }
        \\      if (matched.length > 0) {
        \\        obs._records = obs._records.concat(matched);
        \\        if (!obs._pending) {
        \\          obs._pending = true;
        \\          if (typeof setTimeout !== 'undefined') {
        \\            (function(mo) {
        \\              setTimeout(function() {
        \\                mo._pending = false;
        \\                var recs = mo.takeRecords();
        \\                if (recs.length > 0) {
        \\                  try { mo._callback(recs, mo); } catch(ex) {}
        \\                }
        \\              }, 0);
        \\            })(obs);
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\
        \\  /// DOM §4.3.3: observe(target, options)
        \\  MutationObserver.prototype.observe = function(target, options) {
        \\    if (!target || target.nodeType === undefined)
        \\      throw new TypeError("Failed to execute 'observe' on 'MutationObserver': parameter 1 is not of type 'Node'.");
        \\    var opts = options || {};
        \\    var cl = !!opts.childList;
        \\    var attrs = !!opts.attributes;
        \\    var cd = !!opts.characterData;
        \\    var sub = !!opts.subtree;
        \\    if (!cl && !attrs && !cd)
        \\      throw new TypeError("Failed to execute 'observe' on 'MutationObserver': The options object must set at least one of 'childList', 'attributes', or 'characterData' to true.");
        \\    for (var i = 0; i < this._targets.length; i++) {
        \\      if (this._targets[i].target === target) {
        \\        this._targets[i] = {
        \\          target: target,
        \\          options: { childList: cl, attributes: attrs, characterData: cd, subtree: sub,
        \\                     attributeOldValue: !!opts.attributeOldValue,
        \\                     characterDataOldValue: !!opts.characterDataOldValue,
        \\                     attributeFilter: Array.isArray(opts.attributeFilter) ? opts.attributeFilter.slice() : null },
        \\          childSnapshot: null,
        \\          attrSnapshot: null
        \\        };
        \\        return;
        \\      }
        \\    }
        \\    var entry = {
        \\      target: target,
        \\      options: { childList: cl, attributes: attrs, characterData: cd, subtree: sub,
        \\                 attributeOldValue: !!opts.attributeOldValue,
        \\                 characterDataOldValue: !!opts.characterDataOldValue,
        \\                 attributeFilter: Array.isArray(opts.attributeFilter) ? opts.attributeFilter.slice() : null },
        \\      childSnapshot: null,
        \\      attrSnapshot: null
        \\    };
        \\    if (cl) {
        \\      entry.childSnapshot = [];
        \\      var c = target.firstChild;
        \\      while (c) { entry.childSnapshot.push(c); c = c.nextSibling; }
        \\    }
        \\    if (attrs) {
        \\      entry.attrSnapshot = {};
        \\      var atts = target.attributes;
        \\      if (atts) {
        \\        for (var a = 0; a < atts.length; a++) {
        \\          var attr = atts[a];
        \\          entry.attrSnapshot[attr.name] = attr.value;
        \\        }
        \\      }
        \\    }
        \\    this._targets.push(entry);
        \\    if (g_observers.indexOf(this) === -1) g_observers.push(this);
        \\  };
        \\
        \\  /// DOM §4.3.5: disconnect()
        \\  MutationObserver.prototype.disconnect = function() {
        \\    this._targets = [];
        \\    this._disconnected = true;
        \\    var idx = g_observers.indexOf(this);
        \\    if (idx !== -1) g_observers.splice(idx, 1);
        \\  };
        \\
        \\  /// DOM §4.3.6: takeRecords() → sequence<MutationRecord>
        \\  MutationObserver.prototype.takeRecords = function() {
        \\    var r = this._records;
        \\    this._records = [];
        \\    return r;
        \\  };
        \\
        \\  globalThis.MutationObserver = MutationObserver;
        \\  try { Object.defineProperty(MutationObserver, 'name', { value: 'MutationObserver', configurable: true }); } catch(e) {}
        \\
        \\  // ── Monkey-patch DOM mutation methods for synchronous recording ──
        \\  if (typeof Node !== 'undefined') {
        \\    var _appendChild = Node.prototype.appendChild;
        \\    Node.prototype.appendChild = function(child) {
        \\      var rec = new MutationRecord('childList', this);
        \\      try { rec.addedNodes.appendChild(child); } catch(e) {}
        \\      var ps = this.lastChild;
        \\      rec.previousSibling = ps;
        \\      rec.nextSibling = null;
        \\      var ret = _appendChild.call(this, child);
        \\      _broadcast([rec]);
        \\      return ret;
        \\    };
        \\    var _insertBefore = Node.prototype.insertBefore;
        \\    Node.prototype.insertBefore = function(child, ref) {
        \\      var rec = new MutationRecord('childList', this);
        \\      try { rec.addedNodes.appendChild(child); } catch(e) {}
        \\      rec.previousSibling = ref ? ref.previousSibling : this.lastChild;
        \\      rec.nextSibling = ref;
        \\      var ret = _insertBefore.call(this, child, ref);
        \\      _broadcast([rec]);
        \\      return ret;
        \\    };
        \\    var _removeChild = Node.prototype.removeChild;
        \\    Node.prototype.removeChild = function(child) {
        \\      var rec = new MutationRecord('childList', this);
        \\      try { rec.removedNodes.appendChild(child); } catch(e) {}
        \\      rec.previousSibling = child.previousSibling;
        \\      rec.nextSibling = child.nextSibling;
        \\      var ret = _removeChild.call(this, child);
        \\      _broadcast([rec]);
        \\      return ret;
        \\    };
        \\    var _replaceChild = Node.prototype.replaceChild;
        \\    Node.prototype.replaceChild = function(newChild, oldChild) {
        \\      var removedRec = new MutationRecord('childList', this);
        \\      try { removedRec.removedNodes.appendChild(oldChild); } catch(e) {}
        \\      removedRec.previousSibling = oldChild.previousSibling;
        \\      removedRec.nextSibling = oldChild.nextSibling;
        \\      var addedRec = new MutationRecord('childList', this);
        \\      try { addedRec.addedNodes.appendChild(newChild); } catch(e) {}
        \\      addedRec.previousSibling = oldChild.previousSibling;
        \\      addedRec.nextSibling = oldChild.nextSibling;
        \\      var ret = _replaceChild.call(this, newChild, oldChild);
        \\      _broadcast([removedRec, addedRec]);
        \\      return ret;
        \\    };
        \\  }
        \\  if (typeof Element !== 'undefined') {
        \\    var _setAttribute = Element.prototype.setAttribute;
        \\    Element.prototype.setAttribute = function(name, value) {
        \\      var rec = new MutationRecord('attributes', this);
        \\      rec.attributeName = name;
        \\      rec.oldValue = this.getAttribute(name);
        \\      var ret = _setAttribute.call(this, name, value);
        \\      _broadcast([rec]);
        \\      return ret;
        \\    };
        \\    var _removeAttribute = Element.prototype.removeAttribute;
        \\    Element.prototype.removeAttribute = function(name) {
        \\      var rec = new MutationRecord('attributes', this);
        \\      rec.attributeName = name;
        \\      rec.oldValue = this.getAttribute(name);
        \\      var ret = _removeAttribute.call(this, name);
        \\      _broadcast([rec]);
        \\      return ret;
        \\    };
        \\    if (typeof Element.prototype.setAttributeNS === 'function') {
        \\      var _setAttributeNS = Element.prototype.setAttributeNS;
        \\      Element.prototype.setAttributeNS = function(ns, name, value) {
        \\        var rec = new MutationRecord('attributes', this);
        \\        rec.attributeName = name;
        \\        rec.attributeNamespace = ns;
        \\        rec.oldValue = this.getAttributeNS(ns, name);
        \\        var ret = _setAttributeNS.call(this, ns, name, value);
        \\        _broadcast([rec]);
        \\        return ret;
        \\      };
        \\    }
        \\  }
        \\})();
    ;

    /// DOM §2.5 — CustomEvent thin-wrapper polyfill for the kotori engine.
    /// The native CustomEvent constructor + initCustomEvent are registered in
    /// kotori_dom.zig initDomBuiltins() (line 1447–1457) and the constructor
    /// handles `new CustomEvent(type)`, `new CustomEvent(type, {detail})`, and
    /// `new CustomEvent(type, {bubbles, cancelable})` via delegation to
    /// nativeEventConstructor. This pure-JS IIFE serves as a safety net: it
    /// verifies global exposure, patches the prototype chain (CustomEvent.prototype
    /// → Event.prototype), ensures the `detail` property is a data property
    /// with value `null` (not undefined), and exposes the legacy
    /// `initCustomEvent` method when missing.
    const customevent_polyfill_js =
        \\(function(){
        \\  // Guard: if the native constructor is already registered and the
        \\  // prototype chain looks correct we skip the JS path entirely.
        \\  if (typeof globalThis.CustomEvent === 'function') {
        \\    // Quick sanity-check: does the proto have a `detail` property?
        \\    if (globalThis.CustomEvent.prototype &&
        \\        globalThis.CustomEvent.prototype.hasOwnProperty &&
        \\        globalThis.CustomEvent.prototype.hasOwnProperty('detail')) {
        \\      return;
        \\    }
        \\  }
        \\  // Either no native CustomEvent or it's incomplete — install the JS
        \\  // constructor. Delegate to the native Event constructor so that all
        \\  // the spec-level handling (type coercion, eventInitDict parsing,
        \\  // bubbles/cancelable/composed extraction, dispatch flag, etc.)
        \\  // stays on the native path.
        \\  var _NativeEvent = (typeof Event !== 'undefined') ? Event : null;
        \\  function CustomEvent(type, eventInitDict) {
        \\    if (!(this instanceof CustomEvent))
        \\      throw new TypeError("Failed to construct 'CustomEvent': Please use the 'new' operator.");
        \\    // Construct via Event and add detail.
        \\    if (_NativeEvent) {
        \\      // If the native Event constructor enforces constructor check,
        \\      // we must fake it. Apply() style: create a fresh Event, then
        \\      // copy over its own-properties.
        \\      var ev = new _NativeEvent(type, eventInitDict);
        \\      // Copy own enumerable keys from ev to this.
        \\      var keys = Object.keys(ev);
        \\      for (var i = 0; i < keys.length; i++) {
        \\        try { this[keys[i]] = ev[keys[i]]; } catch(e) {}
        \\      }
        \\      // If Event sets non-enumerable props (type, bubbles, etc.) that
        \\      // are inherited, we leave them alone — this CustomEvent instance
        \\      // inherits them through its prototype chain.
        \\    } else {
        \\      // No native Event — minimal stub.
        \\      this.type = String(type);
        \\      this.bubbles = !!(eventInitDict && eventInitDict.bubbles);
        \\      this.cancelable = !!(eventInitDict && eventInitDict.cancelable);
        \\    }
        \\    // DOM §2.8 — event dispatch flags.
        \\    this.NONE = 0; this.CAPTURING_PHASE = 1; this.AT_TARGET = 2;
        \\    this.BUBBLING_PHASE = 3;
        \\    this.eventPhase = 0;
        \\    this.target = null;
        \\    this.currentTarget = null;
        \\    this.defaultPrevented = false;
        \\    this.isTrusted = false;
        \\    this.timeStamp = Date.now();
        \\    this._dispatching = false;
        \\    // DOM §2.5: detail — initialized to null, overridden from dict.
        \\    var d = null;
        \\    if (eventInitDict && 'detail' in eventInitDict) d = eventInitDict.detail;
        \\    // Define as a non-enumerable data property for consistency with
        \\    // the native path. Writable so `initCustomEvent` can update it.
        \\    try {
        \\      Object.defineProperty(this, 'detail', {
        \\        value: d, writable: true, enumerable: false, configurable: true
        \\      });
        \\    } catch(e) { this.detail = d; }
        \\  }
        \\  // Prototype chain: CustomEvent.prototype → Event.prototype
        \\  if (_NativeEvent) {
        \\    CustomEvent.prototype = Object.create(_NativeEvent.prototype);
        \\  } else {
        \\    CustomEvent.prototype = {};
        \\  }
        \\  CustomEvent.prototype.constructor = CustomEvent;
        \\  // Legacy initCustomEvent(type, bubbles, cancelable, detail)
        \\  CustomEvent.prototype.initCustomEvent = function(type, bubbles, cancelable, detail) {
        \\    if (this._dispatching) return;
        \\    this.type = String(type);
        \\    this.bubbles = !!bubbles;
        \\    this.cancelable = !!cancelable;
        \\    try {
        \\      Object.defineProperty(this, 'detail', {
        \\        value: detail !== undefined ? detail : null,
        \\        writable: true, enumerable: false, configurable: true
        \\      });
        \\    } catch(e) { this.detail = detail !== undefined ? detail : null; }
        \\  };
        \\  // preventDefault / stopPropagation / stopImmediatePropagation
        \\  CustomEvent.prototype.preventDefault = function() {
        \\    if (this.cancelable && !this._dispatching) this.defaultPrevented = true;
        \\  };
        \\  CustomEvent.prototype.stopPropagation = function() {
        \\    this._stopPropagation = true;
        \\  };
        \\  CustomEvent.prototype.stopImmediatePropagation = function() {
        \\    this._stopImmediatePropagation = true;
        \\    this._stopPropagation = true;
        \\  };
        \\  globalThis.CustomEvent = CustomEvent;
        \\  try { Object.defineProperty(CustomEvent, 'name', { value: 'CustomEvent', configurable: true }); } catch(e) {}
        \\})();
    ;

    /// Console API polyfill — adds missing methods to globalThis.console.
    /// Kotori VM already registers log/warn/error/info/debug/dir/assert/time/
    /// timeEnd/timeLog/count/countReset/clear/trace/group/groupCollapsed/groupEnd/
    /// table natively via vm.zig initBuiltins(). This polyfill fills gaps in
    /// environments where those native bindings are absent, using the pattern
    /// `if (!c.METHOD) c.METHOD = ...` to avoid overwriting native methods.
    const console_polyfill_js =
        \\(function(){
        \\  "use strict";
        \\  var c = globalThis.console;
        \\  if (!c) { c = {}; globalThis.console = c; }
        \\
        \\  // Count tracking
        \\  c._counts = c._counts || {};
        \\  if (!c.count) c.count = function(label) {
        \\    var l = String(label || 'default');
        \\    c._counts[l] = (c._counts[l] || 0) + 1;
        \\    c.log(l + ': ' + c._counts[l]);
        \\  };
        \\  if (!c.countReset) c.countReset = function(label) {
        \\    var l = String(label || 'default');
        \\    c._counts[l] = 0;
        \\    c.log(l + ': 0');
        \\  };
        \\
        \\  // Timer tracking
        \\  c._timers = c._timers || {};
        \\  if (!c.time) c.time = function(label) {
        \\    var l = String(label || 'default');
        \\    c._timers[l] = Date.now();
        \\  };
        \\  if (!c.timeLog) c.timeLog = function(label) {
        \\    var l = String(label || 'default');
        \\    if (c._timers[l] !== undefined) c.log(l + ': ' + (Date.now() - c._timers[l]) + ' ms');
        \\  };
        \\  if (!c.timeEnd) c.timeEnd = function(label) {
        \\    var l = String(label || 'default');
        \\    if (c._timers[l] !== undefined) {
        \\      c.log(l + ': ' + (Date.now() - c._timers[l]) + ' ms');
        \\      delete c._timers[l];
        \\    }
        \\  };
        \\
        \\  // Grouping
        \\  c._groupIndent = c._groupIndent || '';
        \\  if (!c.group) c.group = function(label) {
        \\    if (label !== undefined) c.log(c._groupIndent + label);
        \\    c._groupIndent += '  ';
        \\  };
        \\  if (!c.groupCollapsed) c.groupCollapsed = c.group;
        \\  if (!c.groupEnd) c.groupEnd = function() {
        \\    c._groupIndent = (c._groupIndent || '').slice(0, -2) || '';
        \\  };
        \\
        \\  // Table
        \\  if (!c.table) c.table = function(data) {
        \\    c.log(typeof data === 'object' ? JSON.stringify(data, null, 1) : String(data));
        \\  };
        \\
        \\  // Assert
        \\  if (!c.assert) c.assert = function(cond) {
        \\    if (!cond) {
        \\      var args = Array.prototype.slice.call(arguments, 1);
        \\      c.error('Assertion failed' + (args.length ? ': ' + args.join(' ') : ''));
        \\    }
        \\  };
        \\
        \\  // Aliases
        \\  if (!c.debug) c.debug = c.log;
        \\  if (!c.info) c.info = c.log;
        \\
        \\  // Trace
        \\  if (!c.trace) c.trace = function() {
        \\    try { throw new Error(); } catch (e) { c.log(e.stack || 'trace'); }
        \\  };
        \\
        \\  // Dir
        \\  if (!c.dir) c.dir = function(item) {
        \\    c.log(typeof item === 'object' ? JSON.stringify(item) : String(item));
        \\  };
        \\
        \\  // Clear (no-op)
        \\  if (!c.clear) c.clear = function() {};
        \\})();
    ;

    /// Streams API — TextDecoderStream + TextEncoderStream polyfill.
    /// These are TransformStream-based wrappers around TextDecoder/TextEncoder
    /// that provide readable/writable stream interfaces. WPT tests for the
    /// Encoding Standard exercise the streaming decode path
    /// (encoding/streams/*.any.html).
    /// Requires TextDecoder/TextEncoder (text_encoder_polyfill_js) registered
    /// earlier in init().
    const streams_polyfill_js =
        \\(function(){
        \\  "use strict";
        \\
        \\  // Stub ReadableStream / WritableStream / TransformStream if the native
        \\  // kotori VM did not install them. Mirrors the stubs in web_api.zig.
        \\  if (typeof ReadableStream === 'undefined') {
        \\    globalThis.ReadableStream = function(underlyingSource) {
        \\      var src = underlyingSource || {};
        \\      this._src = src;
        \\      this._queue = [];
        \\      this._closed = false;
        \\      this._errored = false;
        \\      this._error = null;
        \\      this._pullWaiters = [];
        \\
        \\      var self = this;
        \\      var controller = {
        \\        enqueue: function(chunk) {
        \\          self._queue.push(chunk);
        \\          var waiters = self._pullWaiters.splice(0);
        \\          for (var i = 0; i < waiters.length; i++) waiters[i]();
        \\        },
        \\        close: function() {
        \\          self._closed = true;
        \\          var waiters = self._pullWaiters.splice(0);
        \\          for (var i = 0; i < waiters.length; i++) waiters[i]();
        \\        },
        \\        error: function(e) {
        \\          self._errored = true;
        \\          self._error = e;
        \\          var waiters = self._pullWaiters.splice(0);
        \\          for (var i = 0; i < waiters.length; i++) waiters[i]();
        \\        }
        \\      };
        \\
        \\      this._controller = controller;
        \\      this._started = false;
        \\      this._pulling = false;
        \\
        \\      // Call start synchronously
        \\      if (typeof src.start === 'function') {
        \\        try {
        \\          src.start(controller);
        \\        } catch (e) {
        \\          controller.error(e);
        \\        }
        \\      }
        \\      this._started = true;
        \\    };
        \\
        \\    ReadableStream.prototype.getReader = function() {
        \\      var rs = this;
        \\      return {
        \\        read: function() {
        \\          // Fast path: return synchronously if data/close already available
        \\          if (rs._errored) return Promise.reject(rs._error);
        \\          if (rs._queue.length > 0) return Promise.resolve({ value: rs._queue.shift(), done: false });
        \\          if (rs._closed) return Promise.resolve({ value: undefined, done: true });
        \\          // Need more data — try pull(), then wait
        \\          return new Promise(function(resolve, reject) {
        \\            function attemptRead() {
        \\              if (rs._errored) { reject(rs._error); return; }
        \\              if (rs._queue.length > 0) { resolve({ value: rs._queue.shift(), done: false }); return; }
        \\              if (rs._closed) { resolve({ value: undefined, done: true }); return; }
        \\              // Try pull()
        \\              if (typeof rs._src.pull === 'function' && !rs._pulling) {
        \\                rs._pulling = true;
        \\                try { rs._src.pull(rs._controller); } catch (e) { rs._pulling = false; reject(e); return; }
        \\                rs._pulling = false;
        \\                if (rs._queue.length > 0 || rs._closed) { attemptRead(); return; }
        \\              }
        \\              // Wait for enqueue/close/error
        \\              rs._pullWaiters.push(function() { attemptRead(); });
        \\            }
        \\            attemptRead();
        \\          });
        \\        },
        \\        releaseLock: function() {},
        \\        cancel: function() { rs._closed = true; return Promise.resolve(); }
        \\      };
        \\    };
        \\    ReadableStream.prototype.cancel = function() {
        \\      this._closed = true; return Promise.resolve();
        \\    };
        \\
        \\    // ReadableStream.from(iterable) — static
        \\    ReadableStream.from = function(iterable) {
        \\      var rs = new ReadableStream({
        \\        start: function(ctrl) {
        \\          if (iterable && typeof iterable[Symbol.iterator] === 'function') {
        \\            var it = iterable[Symbol.iterator]();
        \\            for (var entry = it.next(); !entry.done; entry = it.next()) {
        \\              ctrl.enqueue(entry.value);
        \\            }
        \\          }
        \\          ctrl.close();
        \\        }
        \\      });
        \\      return rs;
        \\    };
        \\
        \\    // readable.pipeThrough(transform) — returns transform.readable
        \\    // First drains source synchronously, then falls back to async pumping
        \\    ReadableStream.prototype.pipeThrough = function(transform) {
        \\      var source = this;
        \\      var writable = transform.writable;
        \\      if (!writable) throw new TypeError('transform.writable is undefined');
        \\      var writer = writable.getWriter();
        \\      // Synchronously drain chunks already in source queue
        \\      try {
        \\        while (source._queue.length > 0) {
        \\          writer.write(source._queue.shift());
        \\        }
        \\        if (source._closed) { writer.close(); return transform.readable; }
        \\      } catch (e) {}
        \\      // Source not done — async pump for remaining data
        \\      var reader = source.getReader();
        \\      function pump() {
        \\        reader.read().then(function(result) {
        \\          if (result.done) { writer.close(); return; }
        \\          try { writer.write(result.value); } catch (e) {}
        \\          pump();
        \\        });
        \\      }
        \\      pump();
        \\      return transform.readable;
        \\    };
        \\
        \\    // readable.pipeTo(dest) — returns Promise
        \\    ReadableStream.prototype.pipeTo = function(dest) {
        \\      var source = this;
        \\      var writer = dest.getWriter();
        \\      var reader = source.getReader();
        \\      return new Promise(function(resolve, reject) {
        \\        function pump() {
        \\          reader.read().then(function(result) {
        \\            if (result.done) { writer.close(); resolve(); return; }
        \\            try { writer.write(result.value); } catch (e) { reject(e); return; }
        \\            pump();
        \\          }).catch(reject);
        \\        }
        \\        pump();
        \\      });
        \\    };
        \\  }
        \\
        \\  if (typeof WritableStream === 'undefined') {
        \\    globalThis.WritableStream = function(sink) {
        \\      this._sink = sink || {};
        \\    };
        \\    WritableStream.prototype.getWriter = function() {
        \\      var ws = this;
        \\      return {
        \\        write: function(chunk) {
        \\          if (ws._sink.write) return Promise.resolve(ws._sink.write(chunk));
        \\          return Promise.resolve();
        \\        },
        \\        close: function() {
        \\          if (ws._sink.close) ws._sink.close();
        \\          return Promise.resolve();
        \\        },
        \\        releaseLock: function() {},
        \\        abort: function() { return Promise.resolve(); }
        \\      };
        \\    };
        \\  }
        \\
        \\  if (typeof TransformStream === 'undefined') {
        \\    globalThis.TransformStream = function(transformer) {
        \\      var chunks = [];
        \\      var rc = { enqueue: function(c) { chunks.push(c); } };
        \\      var self = this;
        \\      this.readable = new ReadableStream({
        \\        start: function(ctrl) {},
        \\        pull: function(ctrl) { if (chunks.length) ctrl.enqueue(chunks.shift()); }
        \\      });
        \\      this.writable = new WritableStream({
        \\        write: function(chunk) {
        \\          if (transformer && transformer.transform) transformer.transform(chunk, rc);
        \\          else rc.enqueue(chunk);
        \\        }
        \\      });
        \\    };
        \\  }
        \\
        \\  // TextDecoderStream — wraps TextDecoder as a TransformStream
        \\  if (typeof TextDecoderStream === 'undefined') {
        \\    globalThis.TextDecoderStream = function(encoding, options) {
        \\      var decoder = new TextDecoder(encoding, options || {});
        \\      var bufQueue = [];
        \\      var self = this;
        \\
        \\      this._encoding = decoder.encoding;
        \\      this._fatal = decoder.fatal;
        \\      this._ignoreBOM = decoder.ignoreBOM;
        \\
        \\      this._readable = new ReadableStream({
        \\        start: function(ctrl) { self._readerCtrl = ctrl; },
        \\        pull: function(ctrl) {
        \\          if (bufQueue.length > 0) {
        \\            var chunksToDecode = bufQueue.splice(0);
        \\            // Concatenate and decode
        \\            var totalLen = 0;
        \\            for (var i = 0; i < chunksToDecode.length; i++) totalLen += chunksToDecode[i].length;
        \\            var merged = new Uint8Array(totalLen);
        \\            var off = 0;
        \\            for (var i = 0; i < chunksToDecode.length; i++) {
        \\              merged.set(chunksToDecode[i], off);
        \\              off += chunksToDecode[i].length;
        \\            }
        \\            ctrl.enqueue(decoder.decode(merged, { stream: true }));
        \\          }
        \\        }
        \\      });
        \\
        \\      this._writable = new WritableStream({
        \\        write: function(chunk) {
        \\          if (chunk instanceof Uint8Array) {
        \\            bufQueue.push(chunk);
        \\            if (self._readerCtrl && self._readerCtrl.enqueue) {
        \\              // Drain immediately
        \\              var toDecode = bufQueue.splice(0);
        \\              var totalLen = 0;
        \\              for (var i = 0; i < toDecode.length; i++) totalLen += toDecode[i].length;
        \\              var merged = new Uint8Array(totalLen);
        \\              var off = 0;
        \\              for (var i = 0; i < toDecode.length; i++) {
        \\                merged.set(toDecode[i], off);
        \\                off += toDecode[i].length;
        \\              }
        \\              self._readerCtrl.enqueue(decoder.decode(merged, { stream: true }));
        \\            }
        \\          } else if (ArrayBuffer.isView && ArrayBuffer.isView(chunk)) {
        \\            bufQueue.push(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
        \\          } else if (chunk instanceof ArrayBuffer) {
        \\            bufQueue.push(new Uint8Array(chunk));
        \\          }
        \\        },
        \\        close: function() {
        \\          var remaining = decoder.decode();
        \\          if (remaining) self._readerCtrl.enqueue(remaining);
        \\          self._readerCtrl.close();
        \\        }
        \\      });
        \\    };
        \\
        \\    Object.defineProperty(TextDecoderStream.prototype, 'encoding', {
        \\      get: function() { return this._encoding; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextDecoderStream.prototype, 'fatal', {
        \\      get: function() { return this._fatal; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextDecoderStream.prototype, 'ignoreBOM', {
        \\      get: function() { return this._ignoreBOM; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextDecoderStream.prototype, 'readable', {
        \\      get: function() { return this._readable; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextDecoderStream.prototype, 'writable', {
        \\      get: function() { return this._writable; },
        \\      configurable: true, enumerable: true
        \\    });
        \\  }
        \\
        \\  // TextEncoderStream — wraps TextEncoder as a TransformStream
        \\  if (typeof TextEncoderStream === 'undefined') {
        \\    globalThis.TextEncoderStream = function() {
        \\      var encoder = new TextEncoder();
        \\      var self = this;
        \\      var encChunks = [];
        \\
        \\      this._readable = new ReadableStream({
        \\        start: function(ctrl) { self._encCtrl = ctrl; },
        \\        pull: function(ctrl) {
        \\          if (encChunks.length > 0) {
        \\            var all = encChunks.splice(0);
        \\            for (var i = 0; i < all.length; i++) ctrl.enqueue(all[i]);
        \\          }
        \\        }
        \\      });
        \\
        \\      this._writable = new WritableStream({
        \\        write: function(chunk) {
        \\          var encoded = encoder.encode(String(chunk));
        \\          encChunks.push(encoded);
        \\          if (self._encCtrl && self._encCtrl.enqueue) {
        \\            var all = encChunks.splice(0);
        \\            for (var i = 0; i < all.length; i++) self._encCtrl.enqueue(all[i]);
        \\          }
        \\        },
        \\        close: function() {
        \\          if (self._encCtrl) self._encCtrl.close();
        \\        }
        \\      });
        \\    };
        \\
        \\    Object.defineProperty(TextEncoderStream.prototype, 'encoding', {
        \\      get: function() { return 'utf-8'; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextEncoderStream.prototype, 'readable', {
        \\      get: function() { return this._readable; },
        \\      configurable: true, enumerable: true
        \\    });
        \\    Object.defineProperty(TextEncoderStream.prototype, 'writable', {
        \\      get: function() { return this._writable; },
        \\      configurable: true, enumerable: true
        \\    });
        \\  }
        \\})();
    ;

    /// HTML §4.1.4: propagate the page's URL into document.URL /
    /// document.documentURI / window.location.href. Called from the main
    /// page-load flow after init() when the base_url is known. Without this
    /// the document's address stays at the bootstrap default (about:blank)
    /// and IDL attributes that spec "returns document's URL" (e.g.
    /// formAction when missing/empty, baseURI) return the wrong value.
    pub fn setDocumentUrl(self: *KotoriRuntime, url: []const u8) void {
        const url_sid = self.pool.intern(url) catch return;
        const doc_sid = self.pool.intern("document") catch return;
        const doc_val = self.vm.globals.get(doc_sid) orelse return;
        if (!doc_val.isObject()) return;
        const doc_obj = doc_val.asJsObject();
        if (self.pool.intern("URL")) |k| {
            doc_obj.setProperty(self.allocator, k, JsValue.initString(url_sid)) catch {};
        } else |_| {}
        if (self.pool.intern("documentURI")) |k| {
            doc_obj.setProperty(self.allocator, k, JsValue.initString(url_sid)) catch {};
        } else |_| {}
        // window.location.href
        const window_sid = self.pool.intern("window") catch return;
        const window_val = self.vm.globals.get(window_sid) orelse return;
        if (!window_val.isObject()) return;
        const window_obj = window_val.asJsObject();
        const loc_sid = self.pool.intern("location") catch return;
        const loc_val = window_obj.getProperty(loc_sid) orelse return;
        if (!loc_val.isObject()) return;
        const loc_obj = loc_val.asJsObject();
        if (self.pool.intern("href")) |k| {
            loc_obj.setProperty(self.allocator, k, JsValue.initString(url_sid)) catch {};
        } else |_| {}
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
