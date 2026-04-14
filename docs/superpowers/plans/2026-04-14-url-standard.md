# WHATWG URL Standard Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace suzume's ad-hoc URL polyfill with a full WHATWG URL Standard implementation in Zig — URL parsing, serialization, setters, URLSearchParams, host parsing, percent encoding, IDNA, Punycode, NFC.

**Architecture:** Single `src/url/` module with 9 files. Zig-native parser with 19-state WHATWG state machine. Comptime IDNA/NFC tables (~290KB). QuickJS native class bindings. Replaces both JS polyfill and Zig `loader.resolveUrl`.

**Tech Stack:** Zig 0.14, QuickJS (existing binding), WHATWG URL Living Standard, UTS #46, RFC 3492.

**Spec:** `docs/superpowers/specs/2026-04-14-url-standard-design.md`

---

## Chunk 1: Foundation — Percent Encoding + Punycode

**Dependencies:** Tasks 1 and 2 are independent — can be parallelized.

### Task 1: Module skeleton + percent encoding

**Files:**
- Create: `src/url/percent_encode.zig`
- Create: `tests/test_url_percent_encode.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Create `src/url/` directory and `percent_encode.zig` with EncodeSet enum**

```zig
// src/url/percent_encode.zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EncodeSet = enum {
    c0_control,
    fragment,
    query,
    special_query,
    path,
    userinfo,
    component,
    form_urlencoded,
};

/// Returns true if the byte should be percent-encoded for the given set.
pub fn inEncodeSet(byte: u8, set: EncodeSet) bool {
    // C0 control: 0x00-0x1F and > 0x7E
    if (byte <= 0x1F or byte > 0x7E) return true;
    return switch (set) {
        .c0_control => false,
        .fragment => switch (byte) {
            ' ', '"', '<', '>', '`' => true,
            else => false,
        },
        .query => switch (byte) {
            ' ', '"', '#', '<', '>' => true,
            else => false,
        },
        .special_query => switch (byte) {
            ' ', '"', '#', '<', '>', '\'' => true,
            else => false,
        },
        .path => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '`', '{', '}' => true,
            else => false,
        },
        .userinfo => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '`', '{', '}',
            '/', ':', ';', '=', '@', '[', '\\', ']', '^', '|' => true,
            else => false,
        },
        .component => switch (byte) {
            ' ', '"', '#', '<', '>', '?', '`', '{', '}',
            '/', ':', ';', '=', '@', '[', '\\', ']', '^', '|',
            '$', '&', '+', ',' => true,
            else => false,
        },
        .form_urlencoded => switch (byte) {
            '*', '-', '.', '0'...'9', 'A'...'Z', '_', 'a'...'z' => false,
            else => true,
        },
    };
}

const hex_digits = "0123456789ABCDEF";

/// Percent-encode a byte string according to the given encode set.
pub fn percentEncode(allocator: Allocator, input: []const u8, set: EncodeSet) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    for (input) |byte| {
        if (set == .form_urlencoded and byte == ' ') {
            try result.append('+');
        } else if (inEncodeSet(byte, set)) {
            try result.append('%');
            try result.append(hex_digits[byte >> 4]);
            try result.append(hex_digits[byte & 0x0F]);
        } else {
            try result.append(byte);
        }
    }
    return result.toOwnedSlice();
}

/// Percent-decode a byte string. Replaces %XX sequences with the byte value.
/// For form_urlencoded, also replaces '+' with space.
pub fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    return percentDecodeOpts(allocator, input, false);
}

pub fn percentDecodeForm(allocator: Allocator, input: []const u8) ![]u8 {
    return percentDecodeOpts(allocator, input, true);
}

fn percentDecodeOpts(allocator: Allocator, input: []const u8, plus_as_space: bool) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (hexVal(input[i + 1])) |hi| {
                if (hexVal(input[i + 2])) |lo| {
                    try result.append((hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
            try result.append(input[i]);
            i += 1;
        } else if (plus_as_space and input[i] == '+') {
            try result.append(' ');
            i += 1;
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'F' => @intCast(c - 'A' + 10),
        'a'...'f' => @intCast(c - 'a' + 10),
        else => null,
    };
}
```

- [ ] **Step 2: Write tests for percent encoding**

```zig
// tests/test_url_percent_encode.zig
const std = @import("std");
const pe = @import("../src/url/percent_encode.zig");
const testing = std.testing;
const alloc = testing.allocator;

test "percentEncode c0_control" {
    const result = try pe.percentEncode(alloc, "hello world", .c0_control);
    defer alloc.free(result);
    // space (0x20) is NOT in c0_control set (only 0x00-0x1F and >0x7E)
    try testing.expectEqualStrings("hello world", result);
}

test "percentEncode fragment set" {
    const result = try pe.percentEncode(alloc, "a b<c>d\"e", .fragment);
    defer alloc.free(result);
    try testing.expectEqualStrings("a%20b%3Cc%3Ed%22e", result);
}

test "percentEncode userinfo set" {
    const result = try pe.percentEncode(alloc, "user:pass@host", .userinfo);
    defer alloc.free(result);
    try testing.expectEqualStrings("user%3Apass%40host", result);
}

test "percentEncode form_urlencoded" {
    const result = try pe.percentEncode(alloc, "hello world&foo=bar", .form_urlencoded);
    defer alloc.free(result);
    try testing.expectEqualStrings("hello+world%26foo%3Dbar", result);
}

test "percentDecode basic" {
    const result = try pe.percentDecode(alloc, "hello%20world%3F");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello world?", result);
}

test "percentDecode form plus_as_space" {
    const result = try pe.percentDecodeForm(alloc, "hello+world");
    defer alloc.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "percentDecode invalid sequence passthrough" {
    const result = try pe.percentDecode(alloc, "100%pure%GGok");
    defer alloc.free(result);
    try testing.expectEqualStrings("100%pure%GGok", result);
}

test "percentDecode truncated percent at end" {
    const result = try pe.percentDecode(alloc, "abc%");
    defer alloc.free(result);
    try testing.expectEqualStrings("abc%", result);
}

test "percentDecode single hex digit only" {
    const result = try pe.percentDecode(alloc, "abc%4z");
    defer alloc.free(result);
    try testing.expectEqualStrings("abc%4z", result);
}

test "percentEncode non-ASCII" {
    const result = try pe.percentEncode(alloc, "\xc3\xa9", .c0_control); // UTF-8 for 'e'
    defer alloc.free(result);
    try testing.expectEqualStrings("%C3%A9", result);
}
```

- [ ] **Step 3: Add test to build.zig**

Add a test step for `tests/test_url_percent_encode.zig` to `build.zig`, following the existing pattern (check how `test_selectors.zig` or similar is added).

Run: `cd ~/suzume && zig build test-url-percent-encode 2>&1`
Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/url/percent_encode.zig tests/test_url_percent_encode.zig build.zig
git commit -m "feat(url): percent encoding with WHATWG encode sets"
```

---

### Task 2: Punycode (RFC 3492)

**Files:**
- Create: `src/url/punycode.zig`
- Create: `tests/test_url_punycode.zig`

- [ ] **Step 1: Implement Punycode encode/decode**

```zig
// src/url/punycode.zig
const std = @import("std");
const Allocator = std.mem.Allocator;

// RFC 3492 constants
const base: u32 = 36;
const tmin: u32 = 1;
const tmax: u32 = 26;
const skew: u32 = 38;
const damp: u32 = 700;
const initial_bias: u32 = 72;
const initial_n: u32 = 128;

fn adapt(delta_in: u32, num_points: u32, first_time: bool) u32 {
    var delta = if (first_time) delta_in / damp else delta_in / 2;
    delta += delta / num_points;
    var k: u32 = 0;
    while (delta > ((base - tmin) * tmax) / 2) {
        delta /= base - tmin;
        k += base;
    }
    return k + ((base - tmin + 1) * delta) / (delta + skew);
}

// NOTE: All arithmetic in encode/decode uses checked math (std.math.add/mul)
// to detect overflow per RFC 3492 Section 6.3. Returns error.Overflow on detection.
// This is critical for inputs with large code points (emoji U+1F600+ = 128512).

fn digitToBasic(d: u32) u8 {
    // 0-25 -> 'a'-'z', 26-35 -> '0'-'9'
    if (d < 26) return @intCast(d + 'a') else return @intCast(d - 26 + '0');
}

fn basicToDigit(c: u8) ?u32 {
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= '0' and c <= '9') return @as(u32, c - '0') + 26;
    return null;
}

/// Encode Unicode code points to Punycode ASCII string.
pub fn encode(allocator: Allocator, input: []const u21) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Copy basic code points (ASCII)
    var basic_count: u32 = 0;
    for (input) |cp| {
        if (cp < 128) {
            try output.append(@intCast(cp));
            basic_count += 1;
        }
    }
    if (basic_count > 0) try output.append('-');

    var n: u32 = initial_n;
    var delta: u32 = 0;
    var bias: u32 = initial_bias;
    var handled: u32 = basic_count;
    const input_len: u32 = @intCast(input.len);

    while (handled < input_len) {
        // Find the minimum code point >= n
        var m: u32 = std.math.maxInt(u32);
        for (input) |cp| {
            if (cp >= n and cp < m) m = cp;
        }

        delta = std.math.add(u32, delta, std.math.mul(u32, m - n, handled + 1) catch return error.Overflow) catch return error.Overflow;
        n = m;

        for (input) |cp| {
            if (cp < n) delta += 1;
            if (cp == n) {
                var q = delta;
                var k: u32 = base;
                while (true) {
                    const t_val = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
                    if (q < t_val) break;
                    try output.append(digitToBasic(t_val + (q - t_val) % (base - t_val)));
                    q = (q - t_val) / (base - t_val);
                    k += base;
                }
                try output.append(digitToBasic(q));
                bias = adapt(delta, handled + 1, handled == basic_count);
                delta = 0;
                handled += 1;
            }
        }
        delta += 1;
        n += 1;
    }

    return output.toOwnedSlice();
}

/// Decode Punycode ASCII string to Unicode code points.
pub fn decode(allocator: Allocator, input: []const u8) ![]u21 {
    var output = std.ArrayList(u21).init(allocator);
    errdefer output.deinit();

    // Find the last '-' to separate basic from encoded parts
    var basic_end: usize = 0;
    for (input, 0..) |c, i| {
        if (c == '-') basic_end = i;
    }

    // Copy basic code points
    for (input[0..basic_end]) |c| {
        try output.append(c);
    }

    var n: u32 = initial_n;
    var i: u32 = 0;
    var bias: u32 = initial_bias;
    var pos: usize = if (basic_end > 0) basic_end + 1 else 0;

    while (pos < input.len) {
        const old_i = i;
        var w: u32 = 1;
        var k: u32 = base;
        while (pos < input.len) {
            const digit = basicToDigit(input[pos]) orelse return error.InvalidInput;
            pos += 1;
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return error.Overflow) catch return error.Overflow;
            const t_val = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
            if (digit < t_val) break;
            w *= base - t_val;
            k += base;
        }
        const out_len: u32 = @intCast(output.items.len + 1);
        bias = adapt(i - old_i, out_len, old_i == 0);
        n += i / out_len;
        i = i % out_len;

        try output.insert(i, @intCast(n));
        i += 1;
    }

    return output.toOwnedSlice();
}
```

- [ ] **Step 2: Write tests (RFC 3492 Section 7 test vectors)**

```zig
// tests/test_url_punycode.zig
const std = @import("std");
const punycode = @import("../src/url/punycode.zig");
const testing = std.testing;
const alloc = testing.allocator;

test "encode pure ASCII" {
    const input = [_]u21{ 'a', 'b', 'c' };
    const result = try punycode.encode(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualStrings("abc-", result);
}

test "encode Arabic (Egyptian)" {
    // RFC 3492 example: Egyptian hieroglyphs (simplified test)
    const input = [_]u21{ 0x0644, 0x064A, 0x0647, 0x0645, 0x0627, 0x0628, 0x062A, 0x0643, 0x0644, 0x0645, 0x0648, 0x0634, 0x0639, 0x0631, 0x0628, 0x064A, 0x061F };
    const result = try punycode.encode(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualStrings("egbpdaj6bu4bxfgehfvwxn", result);
}

test "encode mixed ASCII and non-ASCII" {
    // "Mnchen" with u-umlaut -> "Mnchen-3ya"
    const input = [_]u21{ 'M', 0x00FC, 'n', 'c', 'h', 'e', 'n' };
    const result = try punycode.encode(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualStrings("Mnchen-3ya", result);
}

test "decode roundtrip" {
    const original = [_]u21{ 'M', 0x00FC, 'n', 'c', 'h', 'e', 'n' };
    const encoded = try punycode.encode(alloc, &original);
    defer alloc.free(encoded);
    const decoded = try punycode.decode(alloc, encoded);
    defer alloc.free(decoded);
    try testing.expectEqualSlices(u21, &original, decoded);
}

test "encode Japanese" {
    // 3B -> 3B-ww4c5e180e575a65lsy2b
    const input = [_]u21{ '3', 0x5E74, 'B', 0x7D44, 0x91D1, 0x516B, 0x5148, 0x751F };
    const result = try punycode.encode(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualStrings("3B-ww4c5e180e575a65lsy2b", result);
}
```

- [ ] **Step 3: Add test to build.zig, run tests**

Run: `cd ~/suzume && zig build test-url-punycode 2>&1`
Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/url/punycode.zig tests/test_url_punycode.zig build.zig
git commit -m "feat(url): RFC 3492 Punycode encode/decode"
```

---

## Chunk 2: Host & IDNA

**Dependencies:** Task 3 (tables) → Task 4 (NFC) → Task 5 (IDNA) → Task 6 (host). Strictly sequential.

### Task 3: IDNA tables (comptime)

**Files:**
- Create: `src/url/tables.zig`
- Create: `tools/gen_idna_tables.py` (table generator script)
- Create: `tests/test_url_tables.zig`

- [ ] **Step 1: Create Python script to generate IDNA mapping table from Unicode data**

Download UTS #46 IdnaMappingTable.txt and generate a Zig comptime array.
Source: `https://www.unicode.org/Public/idna/latest/IdnaMappingTable.txt`

The script reads the table and outputs a Zig file with:
- `idna_table: []const IdnaEntry` — sorted by range_start for binary search
- `lookupCodePoint(cp: u21) -> IdnaEntry` — binary search function

```python
# tools/gen_idna_tables.py
# Parses IdnaMappingTable.txt → src/url/tables.zig
# Run: python3 tools/gen_idna_tables.py > src/url/tables.zig
```

- [ ] **Step 2: Generate tables.zig**

Run: `cd ~/suzume && python3 tools/gen_idna_tables.py > src/url/tables.zig`

The file should contain:
- `IdnaEntry` struct with `range_start`, `range_end`, `status`, `mapping`
- `Status` enum
- `idna_table` comptime array
- `lookupCodePoint()` binary search
- NFC tables: `canonical_decomposition`, `canonical_combining_class`, `composition_pairs`

- [ ] **Step 3: Write tests for table lookup**

```zig
// tests/test_url_tables.zig
test "lookupCodePoint ASCII lowercase" {
    const entry = tables.lookupCodePoint('a');
    try testing.expect(entry.status == .valid);
}

test "lookupCodePoint ASCII uppercase maps to lowercase" {
    const entry = tables.lookupCodePoint('A');
    try testing.expect(entry.status == .mapped);
    try testing.expect(entry.mapping.?[0] == 'a');
}

test "lookupCodePoint fullwidth maps" {
    // U+FF21 FULLWIDTH LATIN CAPITAL LETTER A -> 'a'
    const entry = tables.lookupCodePoint(0xFF21);
    try testing.expect(entry.status == .mapped);
}

test "lookupCodePoint disallowed" {
    // U+0000 NULL is disallowed
    const entry = tables.lookupCodePoint(0);
    try testing.expect(entry.status == .disallowed);
}
```

- [ ] **Step 4: Run tests, commit**

```bash
git add tools/gen_idna_tables.py src/url/tables.zig tests/test_url_tables.zig build.zig
git commit -m "feat(url): IDNA mapping + NFC tables (comptime generated)"
```

---

### Task 4: NFC normalization

**Files:**
- Create: `src/url/nfc.zig`
- Create: `tests/test_url_nfc.zig`

- [ ] **Step 1: Implement NFC normalize**

Uses tables from `tables.zig` for canonical decomposition, CCC, and composition.

```zig
// src/url/nfc.zig — implements Unicode NFC normalization
// Algorithm: NFD decompose → sort by CCC → canonical compose
```

Key functions:
- `nfcNormalize(allocator, input: []const u21) ![]u21`
- `decompose(allocator, input: []const u21) ![]u21` — recursive canonical decomposition
- `sortByCcc(slice: []u21)` — bubble sort combining marks by Canonical_Combining_Class
- `compose(allocator, input: []const u21) ![]u21` — canonical composition

- [ ] **Step 2: Write tests**

```zig
// tests/test_url_nfc.zig
test "NFC already normalized" {
    const input = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const result = try nfc.nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualSlices(u21, &input, result);
}

test "NFC compose e + combining acute -> e-acute" {
    const input = [_]u21{ 0x0065, 0x0301 }; // 'e' + combining acute
    const result = try nfc.nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualSlices(u21, &[_]u21{0x00E9}, result); // e-acute
}

test "NFC Hangul composition" {
    // Hangul Jamo -> Syllable
    const input = [_]u21{ 0x1100, 0x1161, 0x11A8 }; // G + A + G -> GAG
    const result = try nfc.nfcNormalize(alloc, &input);
    defer alloc.free(result);
    try testing.expectEqualSlices(u21, &[_]u21{0xAC01}, result);
}
```

- [ ] **Step 3: Run tests, commit**

```bash
git add src/url/nfc.zig tests/test_url_nfc.zig build.zig
git commit -m "feat(url): NFC normalization for IDNA processing"
```

---

### Task 5: IDNA processing

**Files:**
- Create: `src/url/idna.zig`
- Create: `tests/test_url_idna.zig`

- [ ] **Step 1: Implement domainToAscii / domainToUnicode**

```zig
// src/url/idna.zig
// UTS #46 processing: mapping → NFC → Punycode for non-ASCII labels
```

Key functions:
- `domainToAscii(allocator, domain: []const u8, be_strict: bool) !?[]u8`
- `domainToUnicode(allocator, domain: []const u8) ![]u8`
- `processLabel(allocator, label: []const u21) !?[]u8` — single label processing
- `mapCodePoints(allocator, input: []const u21) ![]u21` — apply IDNA mapping table
- `validateLabel(label: []const u8) bool` — check length, hyphen rules, etc.

**IMPORTANT:** Pure ASCII labels skip Punycode encoding entirely. Only labels containing
non-ASCII code points after mapping+NFC get the `xn--` prefix + Punycode encode.
Test this explicitly (e.g., "example.com" stays "example.com", never becomes "xn--...").

- [ ] **Step 2: Write tests**

```zig
// tests/test_url_idna.zig
test "domainToAscii pure ASCII" {
    const result = (try idna.domainToAscii(alloc, "example.com", false)).?;
    defer alloc.free(result);
    try testing.expectEqualStrings("example.com", result);
}

test "domainToAscii uppercase to lowercase" {
    const result = (try idna.domainToAscii(alloc, "EXAMPLE.COM", false)).?;
    defer alloc.free(result);
    try testing.expectEqualStrings("example.com", result);
}

test "domainToAscii German umlaut" {
    // "münchen.de" -> "xn--mnchen-3ya.de"
    const result = (try idna.domainToAscii(alloc, "m\xc3\xbcnchen.de", false)).?;
    defer alloc.free(result);
    try testing.expectEqualStrings("xn--mnchen-3ya.de", result);
}

test "domainToAscii Japanese" {
    // Check that a Japanese domain encodes to xn-- prefix
    const result = (try idna.domainToAscii(alloc, "\xe4\xbe\x8b\xe3\x81\x88.jp", false)).?;
    defer alloc.free(result);
    try testing.expect(std.mem.startsWith(u8, result, "xn--"));
    try testing.expect(std.mem.endsWith(u8, result, ".jp"));
}

test "domainToAscii empty label failure" {
    const result = try idna.domainToAscii(alloc, "example..com", false);
    try testing.expect(result == null);
}
```

- [ ] **Step 3: Run tests, commit**

```bash
git add src/url/idna.zig tests/test_url_idna.zig build.zig
git commit -m "feat(url): IDNA processing (UTS #46 domainToAscii/domainToUnicode)"
```

---

### Task 6: Host parsing (IPv4 + IPv6 + domain)

**Files:**
- Create: `src/url/host.zig`
- Create: `tests/test_url_host.zig`

- [ ] **Step 1: Implement host parsing**

```zig
// src/url/host.zig
// WHATWG URL Standard section 3: Host parsing
// parseHost -> IPv6 | opaque | domain (via IDNA) | IPv4
```

Key functions:
- `parseHost(allocator, input: []const u8, is_not_special: bool) !?Host`
- `parseIpv4(input: []const u8) !?u32`
- `parseIpv6(input: []const u8) !?[8]u16`
- `parseOpaqueHost(allocator, input: []const u8) !?[]u8`
- `serializeHost(allocator, host: Host) ![]u8`
- `serializeIpv4(addr: u32, buf: *[15]u8) []u8`
- `serializeIpv6(allocator, addr: [8]u16) ![]u8`
- `endsInNumber(input: []const u8) bool` — spec check before IPv4 parse
- `isForbiddenHostCodePoint(c: u8) bool`

`Host` union type defined here (shared with url.zig):
```zig
pub const Host = union(enum) {
    domain: []u8,
    ipv4: u32,
    ipv6: [8]u16,
    opaque: []u8,
};
```

- [ ] **Step 2: Write tests**

```zig
// tests/test_url_host.zig
test "parseIpv4 basic" {
    const result = (try host_mod.parseIpv4("192.168.1.1")).?;
    try testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 with octal and hex" {
    // 0xC0.0250.1.1 = 192.168.1.1 per WHATWG
    const result = (try host_mod.parseIpv4("0xC0.0250.1.1")).?;
    try testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv4 single number" {
    // 3232235777 = 192.168.1.1
    const result = (try host_mod.parseIpv4("3232235777")).?;
    try testing.expectEqual(@as(u32, 0xC0A80101), result);
}

test "parseIpv6 basic" {
    const result = (try host_mod.parseIpv6("[::1]")).?;
    try testing.expectEqual(@as(u16, 0), result[0]);
    try testing.expectEqual(@as(u16, 1), result[7]);
}

test "parseIpv6 full" {
    const result = (try host_mod.parseIpv6("[2001:0db8:85a3:0000:0000:8a2e:0370:7334]")).?;
    try testing.expectEqual(@as(u16, 0x2001), result[0]);
    try testing.expectEqual(@as(u16, 0x7334), result[7]);
}

test "serializeIpv6 compression" {
    const addr = [8]u16{ 0x2001, 0x0db8, 0, 0, 0, 0, 0, 1 };
    const result = try host_mod.serializeIpv6(alloc, addr);
    defer alloc.free(result);
    try testing.expectEqualStrings("[2001:db8::1]", result);
}

test "parseHost domain via IDNA" {
    const result = (try host_mod.parseHost(alloc, "EXAMPLE.COM", false)).?;
    defer host_mod.freeHost(alloc, result);
    try testing.expectEqualStrings("example.com", result.domain);
}

test "parseHost opaque for non-special" {
    const result = (try host_mod.parseHost(alloc, "hello%20world", true)).?;
    defer host_mod.freeHost(alloc, result);
    try testing.expectEqualStrings("hello%20world", result.opaque);
}
```

- [ ] **Step 3: Run tests, commit**

```bash
git add src/url/host.zig tests/test_url_host.zig build.zig
git commit -m "feat(url): host parsing — IPv4, IPv6, domain (IDNA), opaque"
```

---

## Chunk 3: URL Parser + Serialization

**Dependencies:** Task 7 (parser) depends on Chunks 1-2 (percent_encode + host). Task 8 (url.zig) depends on Task 7.

### Task 7: URL parser state machine

**Files:**
- Create: `src/url/parser.zig`
- Create: `tests/test_url_parser.zig`

This is the largest single task. The parser implements the 19-state WHATWG state machine.

- [ ] **Step 1: Implement parser skeleton with State enum and input preprocessing**

```zig
// src/url/parser.zig
pub const State = enum {
    scheme_start, scheme, no_scheme,
    special_relative_or_authority, path_or_authority,
    special_authority_slashes, special_authority_ignore_slashes,
    authority, host, port,
    file, file_slash, file_host,
    relative, relative_slash,
    path_start, path, opaque_path,
    query, fragment,
};

pub fn parse(allocator: Allocator, input: []const u8, base: ?*const Url) !?Url { ... }
pub fn parseWithStateOverride(...) !void { ... }
```

Input preprocessing per spec:
1. Remove leading/trailing C0 control and space
2. Remove all ASCII tab and newline (U+0009, U+000A, U+000D)
3. UTF-8 decode to code points for iteration

- [ ] **Step 2: Implement scheme_start, scheme, no_scheme states**

These handle the initial scheme detection: `http:`, `https:`, `file:`, custom schemes.

- [ ] **Step 3: Implement authority, host, port states**

Parse `//user:pass@host:port` after scheme.

- [ ] **Step 4: Implement relative, relative_slash, special_relative_or_authority, path_or_authority states**

Handle relative URL resolution against a base URL.

- [ ] **Step 5: Implement path_start, path, opaque_path states**

Parse the path component. Handle `.` and `..` path segment normalization (shorten path).

- [ ] **Step 6: Implement query, fragment states**

Parse `?query` and `#fragment`.

- [ ] **Step 7: Implement file, file_slash, file_host states**

Special handling for `file:///` URLs (Windows drive letters, etc.).

- [ ] **Step 8: Write parser tests**

```zig
// tests/test_url_parser.zig
test "parse absolute HTTP URL" {
    var url = (try parser.parse(alloc, "http://example.com/path?q=1#frag", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("http", url.scheme);
    try testing.expectEqualStrings("example.com", url.host.?.domain);
    try testing.expect(url.port == null); // default port omitted
    try testing.expectEqualStrings("q=1", url.query.?);
    try testing.expectEqualStrings("frag", url.fragment.?);
    // Validate via full serialization rather than inspecting path segments directly
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("http://example.com/path?q=1#frag", href);
}

test "parse relative URL with base" {
    var base_url = (try parser.parse(alloc, "http://example.com/a/b/c", null)).?;
    defer base_url.deinit();
    var url = (try parser.parse(alloc, "../d", &base_url)).?;
    defer url.deinit();
    // Should resolve to http://example.com/a/d
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("http://example.com/a/d", href);
}

test "parse failure returns null" {
    const result = try parser.parse(alloc, "http://[::1", null);
    try testing.expect(result == null);
}

test "parse data: URI" {
    var url = (try parser.parse(alloc, "data:text/html,<h1>Hello</h1>", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("data", url.scheme);
    try testing.expectEqualStrings("text/html,<h1>Hello</h1>", url.path.opaque);
}

test "parse with username and password" {
    var url = (try parser.parse(alloc, "http://user:pass@example.com/", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("user", url.username);
    try testing.expectEqualStrings("pass", url.password);
}

test "parse strips leading/trailing whitespace" {
    var url = (try parser.parse(alloc, "  http://example.com  ", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("http", url.scheme);
}

test "parse file URL" {
    var url = (try parser.parse(alloc, "file:///home/user/doc.html", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("file", url.scheme);
    // file:/// has empty host (domain(""))
    try testing.expectEqualStrings("", url.host.?.domain);
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("file:///home/user/doc.html", href);
}

test "parse file URL with Windows drive" {
    var url = (try parser.parse(alloc, "file:///C:/Users/doc.html", null)).?;
    defer url.deinit();
    try testing.expectEqualStrings("file", url.scheme);
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("file:///C:/Users/doc.html", href);
}
```

- [ ] **Step 9: Run tests, commit**

```bash
git add src/url/parser.zig tests/test_url_parser.zig build.zig
git commit -m "feat(url): WHATWG URL parser state machine (19 states)"
```

---

### Task 8: URL record, serialization, setters

**Files:**
- Create: `src/url/url.zig`
- Create: `tests/test_url.zig`

- [ ] **Step 1: Implement Url struct with serialize/serializeZ/serializeOrigin**

```zig
// src/url/url.zig — URL record + serialization + setters
// Re-exports Host, Path from host.zig. Uses parser.zig for setters.
```

Serialization per spec section 4.4:
1. scheme + ":"
2. If host non-null: "//" + (username/password if non-empty) + host + (port if non-null)
3. path (join with "/" for list, or opaque string)
4. If query non-null: "?" + query
5. If fragment non-null and not exclude_fragment: "#" + fragment

`serializeZ` wraps `serialize` and appends a null sentinel byte.

- [ ] **Step 2: Implement all setters (setHref, setProtocol, setHostname, etc.)**

Each setter calls `parser.parseWithStateOverride` with the appropriate state.
`setSearch` also updates the back-pointer `searchParams`.

- [ ] **Step 3: Implement static methods: canParse, parse (nullable version)**

```zig
pub fn canParse(allocator: Allocator, input: []const u8, base: ?[]const u8) bool {
    // Parse base if provided, then try parsing input against it
    // Return true if parse succeeds, false otherwise
    // Free all allocations
}
```

- [ ] **Step 4: Write tests**

```zig
// tests/test_url.zig
test "serialize roundtrip" {
    var url = (try Url.parse(alloc, "https://user:pass@example.com:8080/path?q=1#frag", null)).?;
    defer url.deinit();
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("https://user:pass@example.com:8080/path?q=1#frag", href);
}

test "serializeZ produces null-terminated" {
    var url = (try Url.parse(alloc, "http://example.com/", null)).?;
    defer url.deinit();
    const href = try url.serializeZ(alloc);
    defer alloc.free(href);
    try testing.expectEqualStrings("http://example.com/", href);
    try testing.expectEqual(@as(u8, 0), href[href.len]); // sentinel
}

test "setHostname" {
    var url = (try Url.parse(alloc, "http://old.com/path", null)).?;
    defer url.deinit();
    try url.setHostname("new.com");
    const href = try url.serialize(false);
    defer alloc.free(href);
    try testing.expectEqualStrings("http://new.com/path", href);
}

test "setSearch updates query" {
    var url = (try Url.parse(alloc, "http://example.com/", null)).?;
    defer url.deinit();
    try url.setSearch("?foo=bar");
    try testing.expectEqualStrings("foo=bar", url.query.?);
}

test "canParse valid" {
    try testing.expect(Url.canParse(alloc, "http://example.com", null));
}

test "canParse invalid" {
    try testing.expect(!Url.canParse(alloc, "://not-a-url", null));
}

test "origin for http" {
    var url = (try Url.parse(alloc, "http://example.com:8080/path", null)).?;
    defer url.deinit();
    const origin = try url.serializeOrigin();
    defer alloc.free(origin);
    try testing.expectEqualStrings("http://example.com:8080", origin);
}

test "default port omitted in serialize" {
    var url = (try Url.parse(alloc, "http://example.com:80/", null)).?;
    defer url.deinit();
    try testing.expect(url.port == null); // 80 is default for http, stored as null
}
```

- [ ] **Step 5: Run tests, commit**

```bash
git add src/url/url.zig tests/test_url.zig build.zig
git commit -m "feat(url): URL record, serialization, setters, canParse"
```

---

## Chunk 4: URLSearchParams

### Task 9: URLSearchParams

**Files:**
- Create: `src/url/search_params.zig`
- Create: `tests/test_url_search_params.zig`

- [ ] **Step 1: Implement SearchParams struct with all methods**

```zig
// src/url/search_params.zig
// WHATWG URL Standard section 5: URLSearchParams
// application/x-www-form-urlencoded parsing and serialization
```

Key: `sort()` must compare by UTF-16 code unit order, not UTF-8 bytes.

```zig
fn utf16Compare(a: []const u8, b: []const u8) bool {
    // Convert both to UTF-16 code units and compare lexicographically
    // This differs from byte comparison for codepoints > U+FFFF
    ...
}
```

Constructor accepts:
- String: `"foo=bar&baz=qux"` → parse as form-urlencoded
- Sequence: `[["foo","bar"],["baz","qux"]]` (handled in JS binding)
- Record: `{foo:"bar"}` (handled in JS binding)

- [ ] **Step 2: Write tests**

```zig
// tests/test_url_search_params.zig
test "parse query string" {
    var sp = try SearchParams.init(alloc, "foo=bar&baz=qux&foo=baz");
    defer sp.deinit();
    try testing.expectEqualStrings("bar", sp.get("foo").?);
    try testing.expectEqual(@as(usize, 3), sp.size());
}

test "getAll returns multiple values" {
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    const all = try sp.getAll("a", alloc);
    defer alloc.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("1", all[0]);
    try testing.expectEqualStrings("3", all[1]);
}

test "append and serialize" {
    var sp = try SearchParams.init(alloc, null);
    defer sp.deinit();
    try sp.append("key", "value with spaces");
    const result = try sp.serialize();
    defer alloc.free(result);
    try testing.expectEqualStrings("key=value+with+spaces", result);
}

test "delete by name" {
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    sp.delete("a", null);
    try testing.expectEqual(@as(usize, 1), sp.size());
    try testing.expect(sp.get("a") == null);
}

test "delete by name and value" {
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    sp.delete("a", "1");
    try testing.expectEqual(@as(usize, 2), sp.size());
    try testing.expectEqualStrings("3", sp.get("a").?);
}

test "set replaces first, removes rest" {
    var sp = try SearchParams.init(alloc, "a=1&b=2&a=3");
    defer sp.deinit();
    try sp.set("a", "99");
    try testing.expectEqual(@as(usize, 2), sp.size());
    try testing.expectEqualStrings("99", sp.get("a").?);
}

test "sort by UTF-16 code unit order" {
    var sp = try SearchParams.init(alloc, "z=1&a=2&m=3");
    defer sp.deinit();
    sp.sort();
    const result = try sp.serialize();
    defer alloc.free(result);
    try testing.expectEqualStrings("a=2&m=3&z=1", result);
}

test "has with value" {
    var sp = try SearchParams.init(alloc, "a=1&a=2");
    defer sp.deinit();
    try testing.expect(sp.has("a", "1"));
    try testing.expect(sp.has("a", null));
    try testing.expect(!sp.has("a", "3"));
}

test "form-urlencoded decode plus" {
    var sp = try SearchParams.init(alloc, "name=hello+world");
    defer sp.deinit();
    try testing.expectEqualStrings("hello world", sp.get("name").?);
}
```

- [ ] **Step 3: Run tests, commit**

```bash
git add src/url/search_params.zig tests/test_url_search_params.zig build.zig
git commit -m "feat(url): URLSearchParams with full WHATWG API"
```

---

### Task 10: Wire SearchParams back-pointer to Url

**Files:**
- Modify: `src/url/url.zig` — add `search_params` field, lazy init
- Modify: `src/url/search_params.zig` — `updateUrl` writes back to `Url.query`
- Modify: `tests/test_url.zig`

- [ ] **Step 1: Add lazy searchParams to Url**

When `url.getSearchParams()` is first called, create a `SearchParams` from `url.query` with back-pointer.

- [ ] **Step 2: Wire bidirectional update**

- `SearchParams.append/set/delete/sort` → call `updateUrl()` → re-serialize to `url.query`
- `Url.setSearch()` → update `search_params` if it exists

- [ ] **Step 3: Write integration test**

```zig
test "searchParams mutation updates URL query" {
    var url = (try Url.parse(alloc, "http://example.com/?a=1", null)).?;
    defer url.deinit();
    var sp = url.getSearchParams();
    try sp.append("b", "2");
    try testing.expectEqualStrings("a=1&b=2", url.query.?);
}
```

- [ ] **Step 4: Run tests, commit**

```bash
git add src/url/url.zig src/url/search_params.zig tests/test_url.zig
git commit -m "feat(url): bidirectional SearchParams ↔ URL.query sync"
```

---

## Chunk 5: JS Bindings + Integration

**Dependencies:** Task 11 (WPT harness) can start as soon as Task 8 is done (independent of Chunk 4).
Tasks 12 (QuickJS bindings) and 13 (loader replacement) are independent of each other — can be parallelized.
Task 14 (browser WPT) depends on Tasks 12+13. Task 15 (kotori) is a stretch goal, independent of 14.

### Task 11: WPT urltestdata.json test harness

**Files:**
- Create: `tests/test_url_wpt.zig`

- [ ] **Step 1: Write a Zig test that reads and validates against WPT urltestdata.json**

The test reads `/tmp/wpt/url/resources/urltestdata.json`, parses each test case, and validates:
- `href` matches `Url.serialize(false)`
- `origin` matches `Url.serializeOrigin()`
- `protocol`, `username`, `password`, `host`, `hostname`, `port`, `pathname`, `search`, `hash` match

Test cases with `"failure": true` should return null from `Url.parse()`.

This is a bulk validation test — it validates the parser against ~600+ test vectors.

- [ ] **Step 2: Run, fix failures iteratively**

Run: `cd ~/suzume && zig build test-url-wpt 2>&1`

Fix parser bugs revealed by the test vectors. This step will likely require multiple iterations.

- [ ] **Step 3: Commit when passing rate is >95%**

```bash
git add tests/test_url_wpt.zig
git commit -m "test(url): WPT urltestdata.json validation harness"
```

---

### Task 12: QuickJS bindings

**Files:**
- Create: `src/js/url_bindings.zig`
- Modify: `src/js/web_api.zig` — replace JS polyfill, call `registerUrlClass`

- [ ] **Step 1: Implement URL native class for QuickJS**

```zig
// src/js/url_bindings.zig
// Register URL and URLSearchParams as QuickJS native classes
// URL: constructor, getters, setters, toString, toJSON, canParse, parse
// URLSearchParams: constructor, append, delete, get, getAll, has, set, sort,
//                  toString, size, entries, keys, values, forEach, @@iterator
```

Use `JS_NewClassID` + `JS_NewClass` with finalizer that calls `Url.deinit()`.

Getters return JS strings from Url fields.
Setters call `Url.setXxx()` methods.
`searchParams` getter returns a URLSearchParams JS object linked to the Url.

- [ ] **Step 2: Implement URLSearchParams native class**

Constructor handles 3 init types:
- String → pass to `SearchParams.init`
- Array of arrays → iterate and append
- Object → iterate own properties and append

Iterator protocol: `entries()`, `keys()`, `values()` return JS iterator objects.
`forEach(callback, thisArg)` calls callback for each entry.
`@@iterator` is alias for `entries`.

- [ ] **Step 3: Replace JS polyfill in web_api.zig**

Remove `url_class_js` constant and `evalInitScript(ctx, url_class_js, ...)` call.
Replace with: `url_bindings.registerUrlClass(ctx)` in `registerWebApis()`.

- [ ] **Step 4: Run existing tests to verify no regression**

Run: `cd ~/suzume && zig build test 2>&1`
Run: `cd ~/suzume && bash tests/wpt/run_wpt.sh dom/nodes 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add src/js/url_bindings.zig src/js/web_api.zig
git commit -m "feat(url): QuickJS native URL/URLSearchParams classes, replace JS polyfill"
```

---

### Task 13: Replace loader.resolveUrl + regression tests

**Files:**
- Modify: `src/net/loader.zig` — replace `resolveUrl` implementation
- Modify: `src/test_url_resolve.zig` — verify existing tests still pass

- [ ] **Step 1: Replace resolveUrl in loader.zig**

```zig
const url_mod = @import("../url/url.zig");

pub fn resolveUrl(allocator: Allocator, base_str: []const u8, relative: []const u8) ![:0]const u8 {
    // try propagates OOM; orelse handles parse failure (null)
    var base = try url_mod.Url.parse(allocator, base_str, null) orelse return error.InvalidBase;
    defer base.deinit();
    var resolved = try url_mod.Url.parse(allocator, relative, &base) orelse return error.InvalidUrl;
    defer resolved.deinit();
    return resolved.serializeZ(allocator);
}
```

Remove the private helper functions (`hasScheme`, `stripFragment`, `stripQueryAndFragment`,
`extractScheme`, `extractOrigin`, `extractBaseDir`) which are only used within `resolveUrl`
itself. The `resolveUrl` public function signature and all its callers remain unchanged.
Note: `iframe.zig` has its own private `extractOrigin` — that is unrelated and stays.

- [ ] **Step 2: Run existing test_url_resolve.zig**

Run: `cd ~/suzume && zig build test-url-resolve 2>&1`
Expected: all 3 existing tests PASS (fragment-only, query-only, suzume:// internal)

- [ ] **Step 3: Run full browser build + test**

Run: `cd ~/suzume && zig build 2>&1`
Expected: clean build, no compile errors

- [ ] **Step 4: Commit**

```bash
git add src/net/loader.zig src/test_url_resolve.zig
git commit -m "refactor(url): replace ad-hoc resolveUrl with WHATWG URL parser"
```

---

### Task 14: WPT browser-level URL tests

**Files:**
- Modify: `tests/wpt/run_wpt.sh` (if needed for url/ area support)

- [ ] **Step 1: Run WPT URL tests**

```bash
cd ~/suzume && bash tests/wpt/run_wpt.sh url 2>&1
```

- [ ] **Step 2: Analyze failures, fix parser/binding issues**

Common failure categories:
- Missing URLSearchParams iterator protocol
- Edge cases in URL setter behavior
- Percent encoding differences
- IDNA edge cases

Fix iteratively until pass rate > 90%.

- [ ] **Step 3: Final commit**

```bash
git add -A src/url/ src/js/url_bindings.zig
git commit -m "fix(url): WPT URL test fixes — parser edge cases and binding fixes"
```

---

### Task 15: kotori integration (stretch)

**Files:**
- Modify: `src/js/kotori_dom.zig` — add URL/URLSearchParams to kotori VM

- [ ] **Step 1: Add ObjType.url and ObjType.url_search_params to kotori**

Register native method dispatch for URL constructor, getters, setters, and SearchParams methods.

This mirrors what url_bindings.zig does for QuickJS but using kotori's native object system.

- [ ] **Step 2: Test with kotori**

```bash
cd ~/suzume && zig build test-kotori 2>&1
```

- [ ] **Step 3: Commit**

```bash
git add src/js/kotori_dom.zig
git commit -m "feat(url): kotori integration for URL/URLSearchParams"
```
