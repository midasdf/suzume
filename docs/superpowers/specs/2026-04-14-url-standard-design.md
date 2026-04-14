# WHATWG URL Standard — Zig Native Implementation

## Overview

Replace suzume's ad-hoc URL polyfill with a full WHATWG URL Standard implementation in Zig.
Covers URL parsing, serialization, setters, URLSearchParams, host parsing (IPv4/IPv6/domain),
percent encoding, and IDNA (UTS #46 + Punycode) — all without external library dependencies.

**Spec reference**: https://url.spec.whatwg.org/ (Living Standard)

## Motivation

Current state:
- `web_api.zig:1295`: JS polyfill — simple string splitting, no state machine, non-compliant
- `loader.zig:351`: Zig `resolveUrl` — relative URL resolution only, duplicated logic
- URLSearchParams: plain JS object with get/has/toString only
- WPT url/ area: ~39 test files, 10,466 lines of test data — currently untested

Goals:
1. WHATWG URL Standard full compliance
2. Single Zig implementation shared by JS (QuickJS + kotori) and browser internals (loader, fetch)
3. Replace both the JS polyfill and Zig resolveUrl with one canonical parser
4. Pass WPT url/ test suite

## Architecture

### Module Layout

```
src/url/
  url.zig              — URL record, constructor, getters/setters, serialization, canParse, parse
  parser.zig           — WHATWG basic URL parser state machine
  host.zig             — Host parsing: domain, IPv4, IPv6, opaque
  percent_encode.zig   — Percent encode/decode with encode sets
  search_params.zig    — URLSearchParams: all methods + iterator
  idna.zig             — UTS #46 IDNA processing (ToASCII/ToUnicode)
  punycode.zig         — RFC 3492 Punycode encode/decode
  nfc.zig              — Unicode NFC normalization for IDNA
  tables.zig           — IDNA mapping table + NFC data (comptime generated)
src/js/
  url_bindings.zig     — QuickJS native class bindings for URL and URLSearchParams
```

### URL Record (spec section 4.1)

```zig
pub const Url = struct {
    scheme: []u8,
    username: []u8,       // default ""
    password: []u8,       // default ""
    host: ?Host,          // null for cannot-be-a-base URLs
    port: ?u16,           // null = default port for scheme
    path: Path,
    query: ?[]u8,         // null vs "" are distinct
    fragment: ?[]u8,      // null vs "" are distinct
    allocator: Allocator,

    pub fn deinit(self: *Url) void { ... }
    pub fn clone(self: *const Url, alloc: Allocator) !Url { ... }
    pub fn serialize(self: *const Url, exclude_fragment: bool) ![]u8 { ... }
    pub fn serializeZ(self: *const Url, alloc: Allocator) ![:0]const u8 { ... }  // sentinel-terminated for C API callers
    pub fn serializeOrigin(self: *const Url) ![]u8 { ... }
};

pub const Host = union(enum) {
    domain: []u8,         // ASCII domain (after IDNA)
    ipv4: u32,
    ipv6: [8]u16,
    opaque: []u8,         // percent-encoded opaque host
    // Note: empty host is represented as domain(""), not a separate variant.
    // This matches the WHATWG spec where empty host is the empty string.

    pub fn serialize(self: Host) ![]u8 { ... }
};

pub const Path = union(enum) {
    list: std.ArrayListUnmanaged([]u8),  // normal URL path segments
    opaque: []u8,                         // cannot-be-a-base URL
};
```

### Parser State Machine (spec section 4.3)

The basic URL parser is a state machine with these states:

```
scheme_start, scheme, no_scheme,
special_relative_or_authority, path_or_authority, special_authority_slashes, special_authority_ignore_slashes,
authority, host (hostname), port,
file, file_slash, file_host,
relative, relative_slash,
path_start, path, opaque_path,
query, fragment
```

19 states total per WHATWG section 4.3. `path_or_authority` handles non-special schemes
(e.g., `git://`). `relative` and `relative_slash` handle base-relative resolution.

Each state consumes one code point at a time from the input. The parser accepts:
- `input: []const u8` — URL string (UTF-8)
- `base: ?*const Url` — base URL for relative resolution
- `state_override: ?State` — for URL setters (re-parse specific component)

```zig
pub const Parser = struct {
    pub fn parse(allocator: Allocator, input: []const u8, base: ?*const Url) !?Url { ... }
    pub fn parseWithStateOverride(
        allocator: Allocator,
        input: []const u8,
        base: ?*const Url,
        url: *Url,
        state_override: State,
    ) !void { ... }
};
```

Returns `null` on parse failure (spec: return failure), not an error. This distinction matters
because `URL.canParse()` and `URL.parse()` need non-throwing failure paths.

### Special Schemes (spec section 4.2)

```zig
const special_schemes = std.StaticStringMap(u16).initComptime(.{
    .{ "ftp", 21 },
    .{ "file", 0 },    // no default port
    .{ "http", 80 },
    .{ "https", 443 },
    .{ "ws", 80 },
    .{ "wss", 443 },
});
```

### Percent Encoding (spec section 1.3)

Five encode sets, each a superset of the previous:

```zig
pub const EncodeSet = enum {
    c0_control,      // U+0000..U+001F and U+007F+
    fragment,        // c0 + space " < > `
    query,           // c0 + space " # < >
    special_query,   // query + '
    path,            // query + ? ` { }
    userinfo,        // path + / : ; = @ [ \ ] ^ |
    component,       // userinfo + $ & + ,
};

    form_urlencoded,  // application/x-www-form-urlencoded: encode all except *-.0-9A-Za-z_, space→+
};

pub fn percentEncode(allocator: Allocator, input: []const u8, set: EncodeSet) ![]u8 { ... }
pub fn percentDecodeBytes(input: []const u8) ![]u8 { ... }
pub fn percentDecodeString(allocator: Allocator, input: []const u8) ![]u8 { ... }
```

### Host Parsing (spec section 3)

```zig
pub fn parseHost(allocator: Allocator, input: []const u8, is_not_special: bool) !?Host {
    // 1. If input starts with '[', parse IPv6
    // 2. If is_not_special, parse opaque host
    // 3. Percent-decode, then UTF-8 decode
    // 4. Run IDNA ToASCII (domain_to_ascii)
    // 5. If result contains forbidden host code point, return failure
    // 6. Try IPv4 parse (ends-in-number check first)
    // 7. Return domain
}

pub fn parseIpv4(input: []const u8) !?u32 { ... }
pub fn parseIpv6(input: []const u8) !?[8]u16 { ... }
pub fn serializeIpv4(addr: u32) [15]u8 { ... }  // max "255.255.255.255"
pub fn serializeIpv6(addr: [8]u16) ![]u8 { ... } // bracket notation, :: compression
```

### IDNA Processing (spec section 3.3, UTS #46)

```zig
pub fn domainToAscii(allocator: Allocator, domain: []const u8, be_strict: bool) !?[]u8 {
    // 1. Split domain on '.'
    // 2. For each label:
    //    a. Apply UTS #46 mapping (lowercase, NFKC_CF, remove ignored)
    //    b. NFC normalize
    //    c. If non-ASCII: Punycode encode → "xn--" prefix
    // 3. Validate labels (length, leading/trailing hyphen, etc.)
    // 4. Join with '.'
    // 5. Return ASCII domain
}

pub fn domainToUnicode(allocator: Allocator, domain: []const u8) ![]u8 {
    // Reverse: decode xn-- labels back to Unicode
}
```

### Punycode (RFC 3492)

Pure algorithmic, no lookup tables needed:

```zig
pub fn encode(allocator: Allocator, input: []const u21) ![]u8 { ... }  // Unicode → ASCII
pub fn decode(allocator: Allocator, input: []const u8) ![]u21 { ... }  // ASCII → Unicode
```

Constants: base=36, tmin=1, tmax=26, skew=38, damp=700, initial_bias=72, initial_n=128.

### IDNA Mapping Table (tables.zig)

UTS #46 defines a mapping table (IdnaMappingTable.txt, ~9000 entries) with statuses:
- `valid` — code point allowed as-is
- `mapped` — replace with mapping (e.g., uppercase → lowercase)
- `ignored` — remove
- `deviation` — depends on transitional processing
- `disallowed` — reject

Strategy: **comptime-generated binary search table** from UTS #46 data.

```zig
pub const IdnaEntry = struct {
    range_start: u21,
    range_end: u21,
    status: Status,
    mapping: ?[]const u21, // null for valid/ignored/disallowed
};

pub const Status = enum { valid, mapped, ignored, deviation, disallowed, disallowed_STD3_valid, disallowed_STD3_mapped };

/// Comptime-generated sorted array. Binary search at runtime.
pub const idna_table: []const IdnaEntry = &.{ ... };

pub fn lookupCodePoint(cp: u21) IdnaEntry { ... }  // binary search
```

Table size estimate: ~9000 entries, ~200-250KB in the binary (entries with mappings include
pointer + length + mapping data). Combined with NFC tables (~40KB), total ~290KB.
Acceptable for suzume (~5MB binary).

### NFC Normalization

Full NFC tables are ~40KB. We embed the complete set rather than attempting to subset —
the cost is negligible in a ~5MB browser binary and avoids the risk of missing edge cases
when IDNA mappings produce code points that need further normalization.

```zig
pub fn nfcNormalize(allocator: Allocator, input: []const u21) ![]u21 {
    // 1. Decompose (canonical decomposition — full UnicodeData.txt decomposition mappings)
    // 2. Sort combining marks by Canonical_Combining_Class
    // 3. Compose (canonical composition — full CompositionExclusions.txt aware)
}
```

Data tables (all comptime):
- `canonical_decomposition`: code point → decomposition sequence (~12KB)
- `canonical_combining_class`: code point → CCC value (~8KB)
- `composition_pairs`: (starter, combining) → composed (~15KB)
- `composition_exclusions`: set of excluded compositions (~2KB)

### URLSearchParams (spec section 5)

```zig
pub const SearchParams = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: Allocator,
    url: ?*Url,  // back-pointer: update URL.query on mutation

    pub const Entry = struct { name: []u8, value: []u8 };

    pub fn init(allocator: Allocator, query: ?[]const u8) !SearchParams { ... }
    pub fn deinit(self: *SearchParams) void { ... }

    // Spec methods
    pub fn append(self: *SearchParams, name: []const u8, value: []const u8) !void { ... }
    pub fn delete(self: *SearchParams, name: []const u8, value: ?[]const u8) void { ... }
    pub fn get(self: *const SearchParams, name: []const u8) ?[]const u8 { ... }
    pub fn getAll(self: *const SearchParams, name: []const u8, alloc: Allocator) ![][]const u8 { ... }
    pub fn has(self: *const SearchParams, name: []const u8, value: ?[]const u8) bool { ... }
    pub fn set(self: *SearchParams, name: []const u8, value: []const u8) !void { ... }
    pub fn sort(self: *SearchParams) void { ... }  // stable sort by name, comparing UTF-16 code unit sequences
    // IMPORTANT: byte-wise UTF-8 comparison differs from UTF-16 code unit order for non-BMP
    // characters (U+10000+). Must convert to UTF-16 code units for comparison, or equivalently
    // compare by UTF-16BE byte order. WPT tests verify this edge case.
    pub fn size(self: *const SearchParams) usize { ... }
    pub fn serialize(self: *const SearchParams) ![]u8 { ... }  // application/x-www-form-urlencoded

    // Mutation: update back-pointer URL's query
    fn updateUrl(self: *SearchParams) void { ... }
};
```

The `application/x-www-form-urlencoded` serializer/parser is its own mini-spec:
- Parser: split on `&`, split on first `=`, percent-decode, replace `+` with space
- Serializer: percent-encode with special set (space→`+`, encode everything except `*-.0-9A-Za-z_`)

### URL Setters (spec section 4.5)

Each setter re-invokes the parser with a state override:

```zig
pub fn setProtocol(self: *Url, value: []const u8) !void {
    // Run parser with state_override = .scheme_start
}
pub fn setUsername(self: *Url, value: []const u8) !void {
    // Percent-encode with userinfo set, set directly
}
pub fn setPassword(self: *Url, value: []const u8) !void {
    // Percent-encode with userinfo set, set directly
}
pub fn setHostname(self: *Url, value: []const u8) !void {
    // Run parser with state_override = .hostname
}
pub fn setPort(self: *Url, value: []const u8) !void {
    // Run parser with state_override = .port
}
pub fn setPathname(self: *Url, value: []const u8) !void {
    // Run parser with state_override = .path_start
}
pub fn setSearch(self: *Url, value: []const u8) !void {
    // Clear query, run parser with state_override = .query
    // Also: update searchParams
}
pub fn setHash(self: *Url, value: []const u8) !void {
    // Run parser with state_override = .fragment
}
pub fn setHref(self: *Url, value: []const u8) !void {
    // Full re-parse
}
```

### JS Bindings (url_bindings.zig)

Register URL and URLSearchParams as QuickJS native classes:

```zig
pub fn registerUrlClass(ctx: *qjs.JSContext) void {
    // JS_NewClassID(&url_class_id)
    // JS_NewClass(rt, url_class_id, &url_class_def)  — with .finalizer for GC
    // Constructor: new URL(input, base?)
    //   → Parser.parse() → wrap UrlRecord in JS object
    // Getters: href, origin, protocol, username, password, host, hostname, port, pathname, search, searchParams, hash
    // Setters: href, protocol, username, password, host, hostname, port, pathname, search, hash
    // Methods: toString(), toJSON()
    // Static: URL.canParse(input, base?), URL.parse(input, base?)
}

pub fn registerSearchParamsClass(ctx: *qjs.JSContext) void {
    // Constructor: new URLSearchParams(init?)
    //   init can be: string, sequence<sequence<string>>, record<string,string>
    // Methods: append, delete, get, getAll, has, set, sort, toString
    // Properties: size (getter)
    // Iterator: entries, keys, values, forEach, @@iterator
}
```

For kotori: add `ObjType.url` and `ObjType.url_search_params` with native method dispatch.

### Integration: Replace loader.resolveUrl

```zig
// Before (loader.zig):
pub fn resolveUrl(allocator: Allocator, base: []const u8, relative: []const u8) ![:0]const u8

// After:
const url_mod = @import("../url/url.zig");

pub fn resolveUrl(allocator: Allocator, base_str: []const u8, relative: []const u8) ![:0]const u8 {
    const base = try url_mod.Url.parse(allocator, base_str, null) orelse return error.InvalidBase;
    defer base.deinit();
    const resolved = try url_mod.Url.parse(allocator, relative, &base) orelse return error.InvalidUrl;
    defer resolved.deinit();
    return resolved.serializeZ(allocator);
}
```

All callers of `loader.resolveUrl` (dom_api, iframe, form_handler, script_executor) benefit automatically.

**Note**: `cascade_libcss.zig` has its own `resolveUrl` with a `callconv(.c)` signature as a
libcss callback — it is NOT a caller of `loader.resolveUrl`. Currently it copies URLs as-is
without resolving. Integrating the new parser into this callback is out of scope for this spec
(pre-existing deficiency). A future follow-up can wrap `Url.parse` inside the libcss C callback.

**Performance note**: The new `resolveUrl` does two full state-machine parses (base + relative)
plus serialization, whereas the old code did simple string manipulation. For hot paths like
CSS `@import` resolution or script loading in loops, callers should cache the parsed base URL
across iterations rather than re-parsing each call.

### Memory Management

- Each `Url` owns its strings via the provided allocator
- `Url.deinit()` frees all owned memory
- `SearchParams` entries are owned; back-pointer to Url is non-owning
- JS GC: QuickJS class finalizer calls `Url.deinit()`
- IDNA tables: comptime — zero runtime allocation
- Parser: single-pass, allocates result Url only (no intermediate copies)

### Error Handling

- `Url.parse()` returns `?Url` — null means parse failure (not an OOM)
- OOM is `error.OutOfMemory` (propagated via `!?Url`)
- JS side: parse failure → throw TypeError("Invalid URL"); OOM → throw

### Testing Strategy

1. **Unit tests per module**: parser, host, percent_encode, punycode, idna, search_params
2. **WPT urltestdata.json**: 10,466 lines of test vectors — parse Zig-side and validate all fields
3. **WPT url/*.html**: full browser-level integration via run_wpt.sh
4. **Regression**: existing test_url_resolve.zig cases must still pass after resolveUrl replacement

## Custom and Non-Standard Schemes

### `suzume://` internal pages

suzume uses `suzume://` for internal pages (history, bookmarks, home). Under WHATWG rules,
non-special schemes parse with opaque path — `suzume://history` gets `opaque: "history"` as host.
This is spec-compliant. Existing consumers in `internal_pages.zig` extract the page name from
the host/path, which continues to work with the opaque host string.

We do NOT add `suzume` to `special_schemes` — that would change parsing semantics. Instead,
consumers of `suzume://` URLs read `host.opaque` or the serialized path as before.

### `data:` URIs

`data:` is a non-special scheme under WHATWG. Parsing produces an opaque path containing the
full media type and data (e.g., `text/html,<h1>Hello</h1>` or `text/plain;base64,...`).
Existing consumers in `script_executor.zig` split on `,` and `;base64` — they operate on the
serialized opaque path string, which the new parser preserves unchanged.

## Scope Exclusions

- `URL.createObjectURL()` / `URL.revokeObjectURL()` — Blob URLs require Blob/File API (Phase D)
- `URL.searchParams` live update on direct query string modification via other means — covered by setter integration
- `cascade_libcss.zig` resolveUrl callback — pre-existing no-op, separate follow-up

## Estimated Size

| Module | LOC estimate |
|--------|-------------|
| parser.zig | ~600 |
| host.zig | ~250 |
| url.zig | ~400 (incl. serializeZ, setters) |
| percent_encode.zig | ~150 (incl. form_urlencoded set) |
| search_params.zig | ~350 (incl. UTF-16 sort) |
| punycode.zig | ~150 |
| idna.zig | ~200 |
| nfc.zig | ~250 (normalization logic) |
| tables.zig | ~400 (IDNA mapping + NFC decomposition/composition, comptime) |
| url_bindings.zig | ~450 (QuickJS + kotori bindings) |
| **Total** | **~3,200** |
