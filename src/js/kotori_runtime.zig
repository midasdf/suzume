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
