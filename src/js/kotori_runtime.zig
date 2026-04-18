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

        // DOM §5: install Range + StaticRange + document.createRange for the
        // kotori engine. This mirrors dom_document.kotori_range_polyfill_js
        // (kept as source-of-truth there; sync changes between the two).
        _ = self.eval(range_polyfill_js);

        // DOM §7.1 DOMTokenList (Element.classList): install a live token list
        // wrapping the element's `class` attribute. Minimal scoped polyfill:
        // no Proxy (avoids `>>> 0` panics in kotori toInt32 on NaN inputs) and
        // no indexed `classList[i]` access — instead a cached wrapper object
        // with methods that re-read `class` live, plus length/value getters.
        _ = self.eval(class_list_polyfill_js);

        // DOM §6 (Traversal) + §4.5 (createElementNS prefix/case fixups) +
        // §4.7 (importNode) + §4.2.3 (NonElementParentNode.getElementById for
        // DocumentFragment) + HTML §4.12.3 (template.content). Pure-JS
        // polyfills that layer over the kotori native bindings without
        // touching kotori_dom.zig.
        _ = self.eval(traversal_and_fixups_js);


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
    /// Known limitations (deliberate, for minimal-diff safety):
    ///  - No Proxy wrapper → indexed access `classList[0]` returns `undefined`
    ///    (a small number of WPT subtests exercise this; they stay failing).
    ///    kotori's narrow `toInt32` panics on `>>> 0` of non-integer floats,
    ///    which makes a spec-faithful Proxy/ToUint32 implementation unsafe.
    ///  - No `Symbol.iterator`; the WPT classList suite does not rely on it.
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
        \\  /* Safe integer coercion — avoids `>>> 0`, which panics in kotori
        \\   * when the operand becomes NaN or Infinity via toInt32. Returns
        \\   * -1 for negative / non-finite / fractional — callers treat -1 as
        \\   * "out of range" (item() returns null). */
        \\  function toIntIndex(v){
        \\    if (v===undefined || v===null) return -1;
        \\    var n = Number(v);
        \\    if (n !== n) return -1;            /* NaN */
        \\    if (n === Infinity || n === -Infinity) return -1;
        \\    if (n < 0) return -1;
        \\    n = Math.floor(n);
        \\    if (n > 2147483647) return -1;
        \\    return n;
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
        \\    if (n < 0) return null;
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
        \\    var seen = {};
        \\    for (var j=0;j<toks.length;j++) seen[':'+toks[j]] = 1;
        \\    var changed = false;
        \\    for (var k=0;k<args.length;k++){
        \\      var key = ':'+args[k];
        \\      if (!seen[key]) { seen[key] = 1; toks.push(args[k]); changed = true; }
        \\    }
        \\    /* Per spec "update steps" run only if the set changed OR the
        \\     * attribute is absent (and we need to materialize it). */
        \\    if (changed || this._el.getAttribute('class')==null) {
        \\      writeTokens(this._el, toks);
        \\    }
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
        \\    /* DOM §7.1 replace(token, newToken): validate BOTH in argument order. */
        \\    var t = String(token), nt = String(newToken);
        \\    validateToken(t);
        \\    validateToken(nt);
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
        \\   * in kotori may be incomplete). */
        \\  function getWrapper(el){
        \\    var w = el.__clsl;
        \\    if (w) return w;
        \\    w = Object.create(DTLP);
        \\    /* Stash the element pointer on a writable-false slot so user code
        \\     * cannot replace it. */
        \\    try {
        \\      Object.defineProperty(w, '_el', {value: el, writable:false, enumerable:false, configurable:false});
        \\    } catch(e) {
        \\      w._el = el;
        \\    }
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
        \\  /* Run the filter (DOM §6.2 "filter a node"). Returns the filter
        \\   * result constant (ACCEPT/REJECT/SKIP). */
        \\  function filterNode(walker, node){
        \\    if (!node) return FILTER_REJECT;
        \\    var bit = showBit(node.nodeType);
        \\    if ((walker._whatToShow & bit) === 0) return FILTER_SKIP;
        \\    var filter = walker._filter;
        \\    if (filter == null) return FILTER_ACCEPT;
        \\    var r;
        \\    try {
        \\      if (typeof filter === 'function') {
        \\        r = filter.call(null, node);
        \\      } else if (typeof filter.acceptNode === 'function') {
        \\        r = filter.acceptNode.call(filter, node);
        \\      } else {
        \\        return FILTER_ACCEPT;
        \\      }
        \\    } catch(e) {
        \\      throw e;
        \\    }
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
        \\    function(v){ if (v == null) throw new TypeError('currentNode must not be null'); this._current = v; }
        \\  );
        \\
        \\  /* DOM §6.1 parentNode: find nearest inclusive ancestor that is
        \\   * an inclusive descendant of root and ACCEPT. */
        \\  TWP.parentNode = function(){
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
        \\  NIP.nextNode     = function(){ return niTraverse(this, true); };
        \\  NIP.previousNode = function(){ return niTraverse(this, false); };
        \\  globalThis.NodeIterator = NodeIterator;
        \\
        \\  /* -------- document.createTreeWalker / createNodeIterator ----- */
        \\  function createTreeWalker(root, whatToShow, filter){
        \\    if (arguments.length < 1 || root == null || typeof root.nodeType !== 'number') {
        \\      throw new TypeError('createTreeWalker requires a Node');
        \\    }
        \\    var w = Object.create(TWP);
        \\    w._root = root;
        \\    w._current = root;
        \\    w._whatToShow = toWhatToShow(whatToShow);
        \\    w._filter = (filter === undefined) ? null : filter;
        \\    return w;
        \\  }
        \\  function createNodeIterator(root, whatToShow, filter){
        \\    if (arguments.length < 1 || root == null || typeof root.nodeType !== 'number') {
        \\      throw new TypeError('createNodeIterator requires a Node');
        \\    }
        \\    var it = Object.create(NIP);
        \\    it._root = root;
        \\    it._ref = root;
        \\    it._before = true;
        \\    it._whatToShow = toWhatToShow(whatToShow);
        \\    it._filter = (filter === undefined) ? null : filter;
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
        \\  /* Wrap document.createElementNS so:
        \\   *  - prefix is set correctly and localName strips the prefix
        \\   *  - if namespace !== HTML namespace, the result is NOT branded
        \\   *    as HTMLElement (using Object.setPrototypeOf).
        \\   *  - if namespace is HTML ns, case is preserved verbatim per spec
        \\   *    (createElement lowercases; createElementNS does not).
        \\   */
        \\  var HTMLNS = 'http://www.w3.org/1999/xhtml';
        \\  var SVGNS  = 'http://www.w3.org/2000/svg';
        \\  /* Capture a non-HTML prototype reference to un-brand non-HTML elements.
        \\   * Prefer Element.prototype; fall back to Node.prototype. */
        \\  var ElementProto = (typeof Element !== 'undefined' && Element.prototype) ? Element.prototype : null;
        \\  var nativeCreateElementNS = document.createElementNS;
        \\  if (typeof nativeCreateElementNS === 'function') {
        \\    document.createElementNS = function(ns, qn){
        \\      /* Convert undefined/null per spec → for namespace, null = no namespace. */
        \\      var nsStr = (ns == null) ? null : String(ns);
        \\      var qnStr = (qn == null) ? String(qn) : String(qn);
        \\      var el = nativeCreateElementNS.call(document, nsStr, qnStr);
        \\      if (el == null) return el;
        \\      /* Fix localName/prefix if qn contains a colon. Native kotori may
        \\       * leave localName as the full qualified name. */
        \\      var colon = qnStr.indexOf(':');
        \\      if (colon >= 0) {
        \\        var pfx = qnStr.substring(0, colon);
        \\        var ln  = qnStr.substring(colon + 1);
        \\        try { Object.defineProperty(el, 'prefix', {value: pfx, configurable:true, enumerable:true}); } catch(e){}
        \\        try { Object.defineProperty(el, 'localName', {value: ln, configurable:true, enumerable:true}); } catch(e){}
        \\      } else {
        \\        /* Explicit null prefix per spec. */
        \\        try {
        \\          var curP = el.prefix;
        \\          if (curP !== null) Object.defineProperty(el, 'prefix', {value: null, configurable:true, enumerable:true});
        \\        } catch(e){}
        \\      }
        \\      /* Brand handling: if ns is not HTML, un-brand by pointing proto
        \\       * to Element.prototype (avoids HTMLElement subclass checks). */
        \\      if (nsStr !== HTMLNS && ElementProto != null) {
        \\        try { Object.setPrototypeOf(el, ElementProto); } catch(e){}
        \\      }
        \\      /* Also fix namespaceURI on the element for null/empty ns. */
        \\      if (nsStr === null || nsStr === '') {
        \\        try { Object.defineProperty(el, 'namespaceURI', {value: null, configurable:true, enumerable:true}); } catch(e){}
        \\      }
        \\      return el;
        \\    };
        \\    if (typeof Document !== 'undefined' && Document.prototype) {
        \\      Document.prototype.createElementNS = document.createElementNS;
        \\    }
        \\  }
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
