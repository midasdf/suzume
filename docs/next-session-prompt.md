# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。基礎レイヤーから順に。

## 前回セッション成果（2026-07-01、Waves 218-225 url-constructor 100% + host parser spec準拠 + CheckJoiners + joining_type fixes + passive-by-default + window.event + Function ctor + smoke test）

url エリア WPT: **79.9% → 85.8%** (5764→6186 subtests, +422)。
dom/events WPT: **58.5% → 69.7%** (249→297 subtests, +48)。
url-constructor: **890/890 (100%)**、url-setters: **279/279 (100%)**、
passive-by-default: **100/100 (100%)**、
url-origin: 405→407、IdnaTestV2: 2230→2483 (+253)。全テスト回帰ゼロ
(kotori 1036/1036, dom 231/231, css pass)。
実ブラウザのスモークテスト: Google + Wikipedia が kotori デフォルト引擎で
正常レンダリング（CSS/JS fetch + kotori script 実行、exit 0、クラッシュなし）。
証拠: docs/evidence/google-kotori-wave225.png, wikipedia-kotori-wave225.png (July 1)。

根本的バグ修正: Wave 211b の leading/consecutive dot rejection は
WHATWG URL §3.5 違反（empty labels は validation error で failure ではない）
だった。リバート時の 79.9%→55.8% regression は endsInNumber と parseIpv4Number
の連鎖バグが原因（endsInNumber が "." で panic、parseIpv4Number が u64
オーバーフローで null 返し endsInNumber=false → domain fallthrough）。
両者を spec準拠に修正し、Wave 211b rejection を削除しても回帰なし。

| Wave | 内容 |
|------|------|
| 218 | **Wave 211b dot rejection 削除 + endsInNumber spec準拠化** (host.zig): leading/consecutive dot rejection を完全削除（WHATWG §3.5: empty labels = validation error）。endsInNumber を WHATWG §3.5.2 に準拠（strictly split + strip empty last + IPv4 number parse）。`http://./` `http://../` `http://foo.09..` が成功するように |
| 219a | **非special scheme empty host with ':' → failure** (parser.zig host_state): `sc://:/` `sc://:12/` `data://:443` `javascript://:443` `mailto://:443` `urn://:443` `turn://:443` `stun://:443` を failure に |
| 219b | **parseIpv4Number u64 オーバーフロー飽和** (host.zig): 大きな hex/octal 数でも構文エラーでなければ maxInt(u64) を返す（endsInNumber=true を維持）。`http://foo.0XFfFfFfFfFfFfFfFfFfAcE123` が endsInNumber=true → parseIpv4 fails → host failure |
| 220 | **relative_slash で非special scheme は authority state へ** (parser.zig): `///` `////` `////x/` against `sc://x/` が正しく empty host + 適切な pathname に解決。url-constructor 100%達成 |
| 221 | **Unicode Joining_Type table + CheckJoiners** (joining_type.zig 新規 + idna.zig): ArabicShaping.txt の L/R/D/C/T/U joining type を hand-curated table で実装。UTS #46 §4.2 step 3 CheckJoiners で ZWNJ (C1) / ZWJ (C2) の配置を検証。IdnaTestV2 C1/C2 の大部分（122→5）を解決 |
| 222 | **leading combining mark 拒否** (idna.zig): UTS #46 §4.2 — ラベル先頭の combining mark (Mn/Me) を拒否。IdnaTestV2 V6 の +33 subtests解決 |

### 検証済みシナリオ (kotori engine)
- url 全体: 6182/7211 pass (85.7%, +418 vs baseline 5764/7211)
- url-constructor: 890/890 pass (100%, +17 vs baseline 873/890)
- url-setters: 279/279 pass (100%)
- url-origin: 407/410 pass (+2 vs baseline 405/410)
- IdnaTestV2: 2479/2671 pass (+249 vs baseline 2230/2671)
- kotori unit: 1036/1036 pass、dom: 231/231 pass、css: pass — 回帰ゼロ
- `http://./` → host="." (success)、`http://../` → host=".." (success)
- `http://foo.09..` → host="foo.09.." (success)
- `sc://:/` `sc://:12/` → failure (empty host with port for non-special)
- `http://foo.0XFfFfFfFfFfFfFfFfFfAcE123` → failure (IPv4 too large)
- `///` against `sc://x/` → `sc:///` (empty host, pathname="/")
- `a‌b` (ZWNJ between Latin) → C1 failure (throw)
- `a‍b` (ZWJ between Latin) → C2 failure (throw)
- `̈c.d` (leading combining mark) → V6 failure (throw)

### 既知の残課題（Waves 218-225 で発見、未着手）
- **IdnaTestV2 残り188 fail**: V6 (108)、C1/C2 (5)、V3 (一部)、A4_2 (一部)
  - V6 の大部分は未割り当て code point の `.valid` 扱い。tables.zig の
    `lookupCodePoint` が未割り当て領域を `.valid` で返している。完全解決には
    UnicodeData.txt の General_Category + IDNA Mapping Table の精査が必要
  - C1/C2 残り5: Virama (V) joining type は実装済み（Wave 223）だが、
    一部の Indic virama code point が virama_codepoints に未収録。完全解決には
    DerivedJoiningType.txt の全 V code point 追加が必要
  - bidi ルール (V3/V5) 未実装
- **dom/events 残り141 fail**: event-global 残り3 (shadow tree 内の window.event)、
  Body-FrameSet-Event-Handlers 12 fail/36 pass (content attribute → new Function 反映は部分実装済み、Forward to Window が未完了)、
  Event-dispatch-throwing、non-cancelable-when-passive、focus-event 等
  - window.event は Wave 225a で実装済み（event-global 0→4）
  - Function constructor は Wave 225b で実装済み（new Function(body) 動作確認済み）
  - Body-FrameSet の content attribute reflection は setAttribute → IDL 属性
    → new Function(body) の連携が必要（HTML §8.1.5.1）
- **urlsearchparams-constructor 残り4**: DOMException.prototype branding check
  (WebIDL branding check 必要、ポリフィルでは困難)
- **urlencoded-parser 残り70**: Request/Response.formData() 未実装 (fetch API 依存)
- **url-origin 残り3**: `http://./` `http://../` の origin 計算、`blob:ftp://host/path` origin
- **idlharness (0/2)**: WebIDL メタテスト、ハーネス依存が深い
  を含むため分母が大きい。README の数値を更新すること

### Wave 223-225 追加成果（joining_type fixes + passive-by-default + window.event + Function ctor + smoke test）
| Wave | 内容 |
|------|------|
| 223a | **joining_type.zig 0x066E 重複修正**: right_ranges から削除、dual_ranges のみ |
| 223b | **Chorasmian 10FBF-10FC2 範囲修正**: SAMEKH=D, AYIN=U, PE=D, RESH=R |
| 223c | **Virama (V) joining type 実装**: 21 Indic virama code point (U+094D 等)、checkJoiners で L/D/V の V を含める。IdnaTestV2 +4 |
| 223d | **実ブラウザスモークテスト**: Google + Wikipedia が kotori で正常レンダリング。証拠: docs/evidence/google-kotori-wave224.png, wikipedia-kotori-wave224.png (July 1) |
| 224 | **passive-by-default 実装** (kotori_dom.zig): touchstart/touchmove/wheel/mousewheel が window/document/body/html で passive-by-default (HTML §6.5)。_passiveTarget marker で対象判定。passive-by-default.html 68→100 (100%)、dom/events 58.5%→66.0% (+32) |
| 225a | **window.event global 実装** (kotori_dom.zig): HTML spec — window.event を dispatch 中に現在のイベントに設定、dispatch 後に undefined にクリア。setWindowEvent/clearWindowEvent helper。event-global.html 0→4 (+4) |
| 225b | **Function constructor 実装** (vm.zig + kotori_dom.zig): new Function(body) が実際に関数オブジェクトをコンパイルして返す（compileFunctionBody）。nativeNoOpConstructor stub を nativeFunctionConstructor に置換。HTML event handler content attribute 変換の基盤 |
| 225c | **フレッシュスモークテスト証拠**: docs/evidence/google-kotori-wave225.png, wikipedia-kotori-wave225.png (July 1, Wave 225) |

## 前回セッション成果（2026-07-01、Waves 210-217 URLSearchParams + generator + Object.keys + DOMException + IPv6 + IDNA + tab/newline preprocessing）

URLSearchParams の WHATWG form-urlencoded 準拠、generator function の
メソッド呼び出し修正、Object.keys/values/entries の enumerable フィルタ
統一、DOMException の prototype non-enumerable 化、IPv6 embedded IPv4 の
末尾ドット拒否、IDNA validateAsciiLabel からハイフン拒否削除、
preprocessInput で全タブ/改行を事前削除（WHATWG §4.1 準拠）。

url エリア WPT: **78.5% → 79.9%** (5652→5764 subtests, +112)。
url-setters: 271→279 pass (100%)、urlsearchparams-constructor: 21→23、
urlencoded-parser: 30→35、url-searchparams: 3→4 (100%)、
url-constructor: 864→873、url-origin: 402→405。
全テスト回帰ゼロ (kotori 1036, dom 231, css)。

| Wave | 内容 |
|------|------|
| 210a | **URLSearchParams formDecode 仕様準拠** (kotori_runtime.zig): WHATWG §5.1 準拠の formDecode に置換。UTF-8バイト列エンコード→デコード（不正はFFFD、lone surrogate は WTF-8）。`String.fromCharCode` の lone surrogate WTF-8 対応 |
| 210b | **URLSearchParams コンストラクタ修正** (kotori_runtime.zig): sequence validation、Symbol.iterator 優先度、URL.searchParams search-strip 修正 |
| 211 | **generator function .call_method + callJsFunction 修正** (vm.zig): 両パスに generator/async-generator 分岐を追加 |
| 212 | **Object.keys/values/entries enumerable フィルタ統一** (vm.zig): 3関数とも descriptors で enumerable チェック + properties.contains で重複スキップ |
| 213 | **DOMException.prototype non-enumerable** (vm.zig): defineOwnProperty で enumerable=false |
| 214 | **formEncode lone high surrogate 修正** (kotori_runtime.zig): peek して low surrogate でなければ3バイト WTF-8 にフォールバック |
| 215 | **IPv6 parser 末尾ドット付き IPv4 拒否** (host.zig): parseIpv4ForIpv6 関数追加。末尾ドット strip なし、厳密4 part 必須。url-setters 3個解決 |
| 216 | **IDNA validateAsciiLabel からハイフン拒否削除** (idna.zig): WHATWG URL §3.5 では hyphens は validation error（警告のみ）。xn-- や -example を受け入れ。IdnaTestV2 大量解決（+65 subtests） |
| 217 | **preprocessInput で全タブ/改行を事前削除** (parser.zig): WHATWG §4.1 準拠。per-iteration スキップから事前一括削除に変更。authority state の backtracking bug 修正（`http://example\t.` 等）。PreprocessedInput 構造体で所有権追跡 |

### 検証済みシナリオ (kotori engine)
- url 全体: 5764/7211 pass (79.9%, +112 vs baseline 5652/7211)
- url-setters: 279/279 pass (100%, +8 vs baseline 271/279)
- url-constructor: 873/890 pass (+9 vs baseline 864/890)
- url-origin: 405/410 pass (+3 vs baseline 402/410)
- urlsearchparams-constructor: 23/27 pass（+2 vs baseline 21/27）
- urlencoded-parser: 35/105 pass（+5 vs baseline 30/105）
- url-searchparams: 4/4 pass (100%, +1 vs baseline 3/4)
- kotori unit: 1036/1036 pass、dom: 231/231 pass、css: pass — 回帰ゼロ

### 既知の残課題（Waves 210-217 で発見、未着手）
- **DOMException.prototype の branding check**: `new URLSearchParams(DOMException.prototype)` が TypeError を投げない
- ~~**lone surrogate を Object key にした場合の FFFD 置換**~~ **解決済み(2026-07-03)**: 調査の結果「文字列表現の根本問題」は誤診。内部表現は既に事実上WTF-8で、StringPool/parser/連結/比較/Object key round-trip/spread は全て正しくlone surrogateを保持する（回帰テスト4本を tests/test_kotori_vm.zig「WTF-8:」プレフィックスで追加、全pass）。唯一の実バグは `codePointAt` が厳格 `std.unicode.utf8Decode` でlone surrogateを拒否して undefined を返すことで、仕様どおりcode unit値を返すフォールバックを実装済み(vm.zig nativeStringCodePointAt)。「3個のFFFD」は端末など外部の厳格UTF-8デコーダがWTF-8バイト列を表示する際の見え方で、kotori内部では発生しない。
- **url-constructor の残り**: `http://./` (dot host without base)、`http://../` (double-dot host without base)、`sc://:/` (empty host with port) — host parser の境界ケース
  - **Wave 219/221 で教訓（2回リバート）**: leading/consecutive dot rejection の単純削除も、all-dots-only のターゲット修正も、両方 79.9%→55.8% の大幅回帰を引き起こす。回帰の根本原因は `domainToAscii` が all-dot 入力（"." や ".."）をどう処理するかにある可能性が高い（空文字列を返して cascade failure？）。次セッションでは `idna.zig domainToAscii` に all-dot 入力テストを追加し、戻り値を確認してから host.zig 側の修正を再度試すこと。
- **IdnaTestV2 残り**: ~545 subtests。C1/C2 (ZWJ/ZWNJ) チェック、bidi ルール等
  - **Wave 220 で調査未完**: HTTPサーバー不安定で失敗パターン分析できず。
  - **Wave 223 で分析完了**: C1=410, C2=400, V3=365, V6=701, A4_2=346。
    C1/C2 は CheckJoiners ルール（UTS #46 §4.2 step 3）未実装が原因。
    実装を試みたが `isJoiningTypeChar` が粗すぎてリバート。**正しい Unicode
    joining-type table（ArabicShaping.txt の Joining_Type=L/D/V プロパティ）
    を tables.zig に追加する必要がある**。V6 は287 expect-fail（unassigned
    code points の包括的 disallowed table が必要）。V6 で不正に受け入れられている
    350個の非ASCIIコードポイントは主に "Other BMP" (186) と "SMP" (131) —
    unassigned code points の可能性が高い。tables.zig の `lookupCodePoint` が
    未割り当て領域を `.valid` で返しているのが根本原因。
- **urlencoded-parser 残り70**: Request/Response.formData() 未実装（fetch API 依存）

## 前回セッション成果（2026-07-01、Waves 210-216 URLSearchParams + generator + Object.keys + DOMException + IPv6 + IDNA hyphen）

URLSearchParams の WHATWG form-urlencoded 準拠、generator function の
メソッド呼び出し修正、Object.keys/values/entries の enumerable フィルタ
統一、DOMException の prototype non-enumerable 化、IPv6 embedded IPv4 の
末尾ドット拒否、IDNA validateAsciiLabel からハイフン拒否削除。

url エリア WPT: **78.5% → 79.6%** (5652→5740 subtests, +88)。
url-setters: 271→279 pass (100%)、urlsearchparams-constructor: 21→23、
urlencoded-parser: 30→35、url-searchparams: 3→4 (100%)。
全テスト回帰ゼロ (kotori 1036, dom 231, css)。

| Wave | 内容 |
|------|------|
| 210a | **URLSearchParams formDecode 仕様準拠** (kotori_runtime.zig): `decodeURIComponent` ベースの percentDecode を WHATWG §5.1 準拠の formDecode に置換。入力文字列をUTF-8バイト列にエンコード → バイト列をUTF-8としてデコード（不正シーケンスはFFFD、lone surrogate は WTF-8 で保持）。url_polyfill_js の _refillSP 用にも同一実装をコピー。`String.fromCharCode` の lone surrogate を WTF-8 エンコードに修正（サロゲートペアは4バイトUTF-8、lone は3バイトWTF-8） |
| 210b | **URLSearchParams コンストラクタ修正** (kotori_runtime.zig): (1) `Array.isArray(init)` 分岐で `p.length !== 2` を厳密チェックして TypeError 投出。(2) `[Symbol.iterator]` 分岐を `_entries`/`entries` より先にチェック。(3) URL.searchParams getter が `this._p.query` ではなく `this._p.search` を渡すよう修正 |
| 211 | **generator function の .call_method + callJsFunction 修正** (vm.zig): `.call` opcode は `func.is_generator` をチェックするが、`.call_method` opcode と `callJsFunction` 関数が同じチェックをスキップしていた。両パスに generator/async-generator の分岐を追加 |
| 212 | **Object.keys/values/entries の enumerable フィルタ統一** (vm.zig): 3関数すべて `obj.descriptors` で enumerable をチェック + `obj.properties.contains(key_id)` で重複スキップ |
| 213 | **DOMException.prototype non-enumerable** (vm.zig:3803): `defineOwnProperty` で `enumerable=false`、legacy codes は enumerable のまま |
| 214 | **formEncode lone high surrogate 修正** (kotori_runtime.zig): high surrogate の次を peek し、low surrogate でなければ3バイト WTF-8 にフォールバック（NaN ガーベージ修正） |
| 215 | **IPv6 parser 末尾ドット付き IPv4 拒否** (host.zig): `parseIpv4ForIpv6` 関数を追加。`parseIpv4` は末尾ドットを strip するが、IPv6 embedded IPv4 は strip しない。`[::1.2.3.]` `[::1.2.]` `[::1.]` を正しく拒否。url-setters の3個の失敗を解決 |
| 216 | **IDNA validateAsciiLabel からハイフン拒否削除** (idna.zig): WHATWG URL §3.5 では leading/trailing hyphens は "validation error"（警告のみ）で failure ではない。`xn--` (空ACE label) や `-example` を正しく受け入れる。IdnaTestV2 の大量の失敗を解決（+65 subtests） |

### 検証済みシナリオ (kotori engine)
- url 全体: 5740/7211 pass (79.6%, +88 vs baseline 5652/7211)
- url-setters: 279/279 pass (100%, +8 vs baseline 271/279)
- urlsearchparams-constructor: 23/27 pass（+2 vs baseline 21/27）
- urlencoded-parser: 35/105 pass（+5 vs baseline 30/105、URLSearchParams部分は全パス、残り70は Request/Response.formData 未実装）
- url-searchparams: 4/4 pass (100%, +1 vs baseline 3/4)
- kotori unit: 1036/1036 pass、dom: 231/231 pass、css: pass — 回帰ゼロ
- generator メソッド呼び出し: `obj[Symbol.iterator]()` が generator object を返す
- Object.keys(DOMException): `prototype` を含まない（legacy codes は含む）
- lone surrogate formEncode: 4ケース全パス（Oracle実証検証）

### 既知の残課題（Waves 210-216 で発見、未着手）
- **DOMException.prototype の branding check**: `new URLSearchParams(DOMException.prototype)` が
  TypeError を投げない。WebIDL の branding check 実装が必要（ポリフィルでは困難）。
- ~~**lone surrogate を Object key にした場合の FFFD 置換**~~ 解決済み(2026-07-03)、
  上の「既知の残課題」の同項目を参照（実バグは codePointAt のみ、修正済み）。
- **url-constructor の残り**: `http://example\t.` (tab in host)、`http://f:`
  (f: scheme without port)、`http://./` (dot host without base) — host parser
  の tab/改行 strip + opaque host 処理の境界ケース

## 前回セッション成果（2026-06-30、Waves 210-213 URLSearchParams + generator + Object.keys + DOMException）

URLSearchParams の percentDecode を WHATWG form-urlencoded 仕様に準拠させ、
コンストラクタのエッジケース（sequence validation、Symbol.iterator 優先度、
URL.searchParams の search-strip）を修正。更に generator function の
`.call_method` と `callJsFunction` パスで generator object が返らない根本
バグを修正（URLSearchParams の `[Symbol.iterator]` だけでなく、一般的な
generator メソッド呼び出しが壊れていた）。Object.keys/values の enumerable
フィルタを修正し、DOMException の `prototype` プロパティを non-enumerable
として定義（legacy code constants は enumerable のまま、ブラウザ挙動に合致）。

url エリア WPT: **78.4% → 78.5%** (5652→5661 subtests, +9)。
urlsearchparams-constructor: 21→23 pass、urlencoded-parser: 30→35 pass、
url-searchparams: 3→4 pass (100%)。全テスト回帰ゼロ (kotori 1036, dom 231)。

| Wave | 内容 |
|------|------|
| 210a | **URLSearchParams formDecode 仕様準拠** (kotori_runtime.zig): `decodeURIComponent` ベースの percentDecode を WHATWG §5.1 準拠の formDecode に置換。入力文字列をUTF-8バイト列にエンコード → バイト列をUTF-8としてデコード（不正シーケンスはFFFD、lone surrogate は WTF-8 で保持）。url_polyfill_js の _refillSP 用にも同一実装をコピー。`String.fromCharCode` の lone surrogate を WTF-8 エンコードに修正（サロゲートペアは4バイトUTF-8、lone は3バイトWTF-8） |
| 210b | **URLSearchParams コンストラクタ修正** (kotori_runtime.zig): (1) `Array.isArray(init)` 分岐で `p.length !== 2` を厳密チェックして TypeError 投出（`[[1]]` と `[[1,2,3]]` 両方カバー）。(2) `[Symbol.iterator]` 分岐を `_entries`/`entries` より先にチェック（URLSearchParams インスタンスのカスタム iterator が entries() に飲まれるのを防止）。(3) URL.searchParams getter が `this._p.query` ではなく `this._p.search` を渡すよう修正（`??a=b` の2文字目 `?` が `%3F` にエンコードされる、ブラウザ挙動に合致） |
| 211 | **generator function の .call_method + callJsFunction 修正** (vm.zig): `.call` opcode は `func.is_generator` をチェックして generator object を返すが、`.call_method` opcode と `callJsFunction` 関数が同じチェックをスキップしていた。`obj[Symbol.iterator]()` や `genFn.call(this)` が generator object ではなく undefined を返す根本原因。両パスに generator/async-generator の分岐を追加。URLSearchParams の「Custom [Symbol.iterator]」テストがパス、一般的な generator メソッド呼び出しも修復 |
| 212 | **Object.keys/values の enumerable フィルタ修正** (vm.zig): `nativeObjectKeys`/`nativeObjectValues` が `obj.properties` の全プロパティを無条件で enumerable 扱いしていたが、`obj.descriptors` に non-enumerable として保存されているプロパティも返していた。`descriptors.get(key_id)` で enumerable をチェックするよう修正。また `descriptors` と `properties` の重複キーの二重カウントも防止 |
| 213 | **DOMException の prototype を non-enumerable 化** (vm.zig:3803): `dom_exc_ctor.setProperty(..., "prototype", ...)` を `defineOwnProperty` で `enumerable=false` に変更。legacy code constants は `setProperty` で enumerable=true のまま（ブラウザは Object.keys(DOMException) で INDEX_SIZE_ERR 等を返す）。urlsearchparams-constructor の DOMException テストの最初の assert_equals がパス（2番目の branding check assert_throws_js は未解決） |

### 検証済みシナリオ (kotori engine)
- urlsearchparams-constructor: 23/27 pass（+2 vs baseline 21/27）
- urlencoded-parser: 35/105 pass（+5 vs baseline 30/105、URLSearchParams部分は全パス、残り70は Request/Response.formData 未実装）
- url-searchparams: 4/4 pass (100%, +1 vs baseline 3/4)
- url 全体: 5661/7211 pass (78.5%, +9 vs baseline 5652/7211)
- kotori unit: 1036/1036 pass、dom: 231/231 pass、css: pass — 回帰ゼロ
- generator メソッド呼び出し: `obj[Symbol.iterator]()` が generator object を返す（test_gen3.html で検証）
- Object.keys(DOMException): `prototype` を含まない（test_domex.html で検証、legacy codes は含む）

### 既知の残課題（Waves 210-213 で発見、未着手）
- **DOMException.prototype の branding check**: `new URLSearchParams(DOMException.prototype)` が
  TypeError を投げない。WebIDL の branding check 実装が必要（ポリフィルでは困難）。
- **lone surrogate を Object key にした場合の FFFD 置換**: `\uD835x` を
  Object key にすると、kotori は WTF-8 で保存するが、それを String 化する
  際に3個の FFFD になる（仕様は1個）。kotori VM の文字列表現の根本問題。
- **String.fromCharCode で作成した lone surrogate 文字列の比較**:
  fromCharCode を WTF-8 対応したが、文字列比較や toString で WTF-8 を
  正しく処理する必要がある。
- **url-setters の IPv6 host `[::1.2.3.]`**: 末尾ドット付き IPv4 in IPv6
  の解析が不完全。`1.2.3.` が IPv4 として invalid になるべきだが、
  現状は `1`, `2`, `3` を別 piece として処理してしまう。

## 前回セッション成果（2026-06-29 第4部、WebDriver execute/sync+async を kotori デフォルト引擎に対応）

WebDriver の `execute/sync` と `execute/async` がデフォルト kotori エンジンで
動作しなかった根本バグを修正。`handleWebDriverCommand` が `page.js_rt`
(QuickJS) しか見ておらず、`page.kotori_rt` (デフォルト) を無視していた。
両ハンドラを kotori 優先 + QuickJS フォールバックに再構築。
`SUZUME_JS=quickjs` とデフォルト kotori の両方で e2e 検証済み。

| Wave | 内容 |
|------|------|
| 209a | **execute_sync を kotori 対応** (main.zig): kotori を優先使用。ユーザースクリプトを `(function(){ var __r = (…).apply(null,__args); if(typeof __r==='string') return __r; if(__r==null) return null; return JSON.stringify(__r); })()` でラップ — kotori の eval は文字列結果しか表面化しないため、数値/真偽値/オブジェクト/配列を JSON.stringify でシリアライズ。`val orelse "null"` で null/undefined を WebDriver 仕様の `{"value":null}` にマップ |
| 209b | **execute_async を kotori 対応** (main.zig): 同様の kotori 優先分岐。コールバック完了チェック式を `(function(){ var __r=window.__wd_async_result; if(typeof __r==='string') return __r; if(__r==null) return null; return JSON.stringify(__r); })()` に変更 — 文字列結果が `webDriverRawValueResponse` で不正 JSON になる問題を修正 (`webDriverEvalResponse` 経由で JSON エスケープ) |

### 検証済みシナリオ (default kotori engine, example.com)
- execute/sync: string ✅, number ✅, bool ✅, null ✅, undefined ✅, object ✅, array ✅, args ✅, empty string ✅
- execute/async: string ✅, number ✅, bool ✅, object ✅, args ✅ (同期コールバック)
- execute/async with setTimeout: ドキュメント通り null を返す (wptrunner 側でポーリング)
- QuickJS fallback (`SUZUME_JS=quickjs`): 全ケース回帰なし

### 既知の制限
- QuickJS `execute/sync` でオブジェクト返却が `[object Object]` になるのは
  **既存の QuickJS eval の toString 挙動** (今回の変更外)。kotori は問題なし。
- `execute/async` で setTimeout 等の非同期コールバックは null 返却。
  wptrunner はポーリングで対応する設計だが、必要なら event loop で
  `window.__wd_async_done` を監視してレスポンスする拡張が可能。

## 前回セッション成果（2026-06-29 第3部、Waves 207-208 実用度+パフォーマンス）

get_elem 単一チェーン走査化、URLSearchParams toString の WHATWG form_urlencoded
仕様準拠（サロゲートペア含む）、Google レンダリング崩れの原因となっていた
4096×4096 デフォルトウィンドウサイズの修正、JS screen/outerWidth の
ハードコード値を実際のビューポート尺寸に動的化。全テスト回帰ゼロ。

| Wave | 内容 |
|------|------|
| 207a | **get_elem 単一チェーン走査** (vm.zig): get_elem ハンドラが findAccessorDescriptor + getProperty の2回走査していたのを、Wave 206b で追加した getWithAccessorInfo に統合して1回走査に |
| 207b | **URLSearchParams toString 修正** (kotori_runtime.zig): encodeURIComponent ベースの toString を WHATWG form_urlencoded エンコードセット仕様に準拠した formEncode 関数に置換。`* - . 0-9 A-Z _ a-z` のみ未エンコード、それ以外は全てパーセントエンコード、スペースは `+`。サロゲートペアを正しく4バイトUTF-8としてエンコード（Oracle レビュー3ラウンドで修正: デッドコード削除、`%` セパレータ追加、`0xF0｜((cp>>18)&0x07)` で高ビット対応） |
| 208b | **Google レンダリング崩れ修正** (chrome.zig): デフォルトウィンドウサイズを 4096×4096 → 1280×1024 に変更。4096px ビューポートが Google の flexbox を異常な幅に伸ばし、ロゴ・検索ボックスを不可視にしていた。レイアウトはXサーバーのクランプ前に発生するため、要求サイズがそのまま CSS viewport になる |
| 208c | **JS screen/outerWidth 動的化** (web_api.zig + kotori_runtime.zig + main.zig): QuickJS の screen/outerWidth/outerHeight がハードコード 720→実際の viewport 寸法に。kotori に setViewportSize メソッドを追加し、initPageJs とリサイズハンドラで実際の尺寸を注入。ポリフィルのハードコード 1280×800 をオーバーライド |

### 既知の残課題（Waves 204-208 で主要ボトルネック解消済み、残るもの）
- **URLSearchParams のネイティブバインディング**: kotori は JS ポリフィル（toString は修正済みだが、ネイティブ search_params.zig の完全バインディングが本筋）
- **外部スクリプトの async/defer 属性未対応**: handleExternalScript は defer のみ対応、async 未実装
- asset_fetcher/image_fetcher のワーカーは cookie を共有しない
- **kotori ポリフィルの screen フォールバック値** がまだ 1280×800（setViewportSize で上書きされるが、初期化前に読まれた場合のリスク）

## 前回セッション成果（2026-06-29 第2部、Waves 206 パフォーマンス集中）

VM ホットパス3箇所を最適化。全テスト回帰ゼロ（kotori 1036, dom 231）。
ReleaseSafe build + smoke test 通過。

| Wave | 内容 |
|------|------|
| 206a | **open_upvalues O(1)化** (vm.zig): `open_upvalues` を `ArrayListUnmanaged(*UpvalueCell)` から `AutoArrayHashMapUnmanaged(u32, *UpvalueCell)` (key=stack_index) に変更。getOrCreateUpvalue が O(n) 線形スキャン → O(1) hash lookup、closeUpvalueAt も O(1) 化。closeUpvaluesAbove は frame exit 時のみ O(open_count) なので許容。ネストしたクロージャのループパターン (`for(var i=0;i<n;i++) fns.push(()=>i)`) が O(n²) → O(n) |
| 206b | **get_prop single chain walk** (vm.zig + object.zig): get_prop が findAccessorDescriptor (full chain walk) + getProperty (another full chain walk) の2回走査していたのを、object.zig に `getWithAccessorInfo` 統合メソッドを追加して1回走査に統合。accessor/data 両方を一度の chain traversal で返す。プロトタイプチェーン3階層の場合 hash lookup が 12回 → 6回に |
| 206c | **nativeArraySort O(n log n)化** (vm.zig): O(n²) 挿入ソート → `std.sort.block` (stable merge sort)。ECMA-262 §23.1.3.30 の undefined-to-end 仕様も実装（undefined を partition out → defined 部分を sort → tail に undefined 配置）。100+ 要素の配列で顕著な速度向上 |

### 既知の残課題（Waves 204-206 で主要ボトルネック解消済み、残るもの）
- **URLSearchParams のネイティブバインディング**: kotori はまだ JS ポリフィル。
  urlencoded-parser (30/105) の主な失敗原因
- **外部スクリプトの async/defer 属性未対応**: handleExternalScript は
  defer のみ対応、async 未実装
- **get_elem ハンドラ** (vm.zig:~1560) も get_prop と同じ二重走査パターン
  (findAccessorDescriptor + getProperty)。getWithAccessorInfo に統合可能
- asset_fetcher/image_fetcher のワーカーは cookie を共有しない
- **curl_global_cleanup の atomic refcount 化** (http.zig): Wave 205 で
  asset_fetcher が N clients を作る問題に対処済み。全 HttpClient が
  refcount 共有

## 前回セッション成果（2026-06-29 第1部、Waves 204-205 パフォーマンス+実用度集中）

外部スクリプト/CSS の同期フェッチを並列化し、VM プロパティアクセスの
ホットパス2箇所を O(1) 化。IDNA の punycode ラウンドトリップ検証を追加。
全テスト回帰ゼロ（kotori 1036, dom 231, css, idna 42, host 77, parser 91）。

| Wave | 内容 |
|------|------|
| 204a | **arrayElementValue 高速パス** (vm.zig:2833): `obj.descriptors == null` の plain array は pool.intern + getOwnDescriptor をスキップして直接スロット読み出し。45 call site（forEach/map/filter/reduce/indexOf/includes/find/join/slice 等）の全配列イテレーションが benefit。per-element の hash lookup + string format が不要に |
| 204b | **well-known property name の pre-intern** (vm.zig): length/size/byteLength/buffer/__proto__ を VM init 時に StringId としてキャッシュし、get_prop/get_elem/set_prop/has_prop の全 `std.mem.eql` string 比較を `name_id == self.sid_length` の u32 比較に置換。毎プロパティアクセスの pool.get + std.mem.eql が消滅 |
| 205a | **asset_fetcher.zig 新規** (src/net/asset_fetcher.zig): image_fetcher と同パターンの one-shot 並列バッチフェッチャー。wave 方式（最大8スレッド）、thread spawn 失敗時は sequential fallback、per-URL timeout + size cap、結果は入力順。fetchBatch/fetchBatchWithParallelism/freeBatch API |
| 205b | **CSS <link> 並列フェッチ** (loader.zig walkForCssLinks): DOM walk で URL と <style> text を worklist に集めてから asset_fetcher で並列取得、document order で結合。従来の 3s×N 直列ブロックが単一バリアに |
| 205c | **CSS @import 並列フェッチ** (loader.zig processImports): @import URL を全て集めてから asset_fetcher で並列取得、@import 順で prepend |
| 205d | **外部 <script src> 並列プリフェッチ** (script_executor.zig): kotoriExecScripts 実行前に DOM walk で全 external script URL を集めて asset_fetcher で並列取得、g_prefetched_scripts map に格納。kotoriHandleExternalScript は map を先に参照し、miss のみ sync fetch に fallback。従来の 5s×N 直列ブロックが単一バリアに（document order は維持） |
| 205e | **IDNA punycode ラウンドトリップ検証** (idna.zig): ACE label (xn--...) を decode → re-encode して元と比較。不正 punycode / IDNA mapping で変化する code point を含む ACE label を reject。IdnaTestV2 の invalid xn-- ケースで期待される throw を実現 |

### 既知の残課題（このセッションで発見/未着手）
- **URLSearchParams のネイティブバインディング**: kotori はまだ JS ポリフィル
  (kotori_runtime.zig:7374 の url_search_params_polyfill_js)。ネイティブ
  search_params.zig は完成しているが kotori に bind されていない。
  urlencoded-parser (30/105) の主な失敗原因は polyfill の toString が
  encodeURIComponent ベースで WHATWG form_urlencoded set と完全一致しない
  こと。ネイティブバインディングか polyfill の toString を native
  serializer に委譲する kotori native function が必要
- **open_upvalues の線形スキャン** (vm.zig:2770): getOrCreateUpvalue が
  open_upvalues.items を線形スキャン。クロージャキャプチャが O(n)。
  AutoArrayHashMap(u32, *UpvalueCell) への移行で O(1) 化可能
- **get_prop の二重プロトタイプチェーン走査** (vm.zig:1226+1276):
  findAccessorDescriptor + getProperty が同じチェーンを2回走査。
  object.zig に getWithAccessorInfo 統合メソッドを追加して1回化可能
- **nativeArraySort が O(n²) 挿入ソート** (vm.zig:5558):
  std.sort.block / pdq に置換で O(n log n) 化
- **外部スクリプトの async/defer 属性未対応**: handleExternalScript は
  defer のみ対応、async 未実装。HTML spec の async semantics が必要
- asset_fetcher のワーカーは cookie を共有しない（認証付きアセットは
  ロードされない可能性。image_fetcher と同じ制限）

### パフォーマンス改善の残候補（Waves 185-189 + 204-205 で主要ボトルネック解消済み）
- StringPool.get は O(1) 化済み (Wave 182)、upvalue/closure は Wave 185 で解消、
  arrayElementValue は Wave 204a で解消、well-known name 比較は Wave 204b で解消
- 残る線形スキャン系: open_upvalues (上記)、get_prop 二重走査 (上記)
- quickjs エンジン側 (dom_api.zig) の URL reflection (`ru()` ヘルパー) は
  まだ毎アクセス `new URL()`。kotori がデフォルトなので優先度低

## 前回セッション成果（2026-06-13、Waves 174-184）

URL エリア集中改善: **130/274 → 5180/7244 (71.5%)** subtests
(分母はラッパー修正でデータ駆動テストが解放されて 274→7244 に拡大)

| Wave | 内容 |
|------|------|
| 174 | kotori ネイティブ URL バインディング (`__suzume_url_parse`/`can_parse`、src/url の本物パーサー使用) |
| 175 | 素の `location` グローバル + fetch 相対URL解決 |
| 176 | **コンパイラ修正**: ブロック内 function 宣言の sp 崩壊 + 未捕捉例外の VM 汚染 (`execute()` がクリア + `error.UncaughtException`) |
| 177 | IDNA/form-urlencoded の不正 UTF-8 → U+FFFD (panic 解消) |
| 178 | パーサー: 末尾 dot セグメント、file: ドライブレター、localhost、serialize `/.` プレフィックス |
| 179 | kotori JSON.parse `\uXXXX` エスケープ (サロゲートペア + WTF-8) |
| 180 | **URL §6.3 setters** state-override 実装 (`applySetter` in parser.zig、url-setters 279/279 全パス) |
| 181 | for-of/for-in 分割代入 (`for (const [k,v] of …)`) |
| 182 | **StringPool.get O(1)** (線形スキャン→index、a-element 300s+→18s) |
| 183 | HTMLHyperlinkElementUtils (`<a>`/`<area>` 分解アクセサ) + ネイティブ baseURI/URL reflection |
| 184 | マウスカーソル可視化 (libnsfb がブランクカーソル設定→Xカーソルフォント実装、hover 形状切替も有効化) |

### 個別ファイルスコア (url エリア)
- url-setters: **279/279**、url-setters-stripping: **260/260**
- url-constructor: 841/890、url-origin: 391/403
- a-element: 841/889、a-element-origin: 390/402
- IdnaTestV2: 1461/2671 ← 最大の残り (+IdnaTestV2-removed 9/21)
- failure.html: 573/1211 ← 2番目
- urlencoded-parser: 30/105、urlsearchparams-constructor: 21/27
- idlharness: 0/1

## ビルド（重要）
- zig 0.16.0 では素の `zig build` でOK（libc-min ワークアラウンドは不要になった）
- サブモジュール: `.claude/worktrees` の壊れ gitlink は除去済み
- `./scripts/apply-libnsfb-patch.sh "$PWD/patches/libnsfb-xim.patch" "$PWD/deps/libnsfb"`
- test-kotori のベースライン: **1036 pass / 0 fail / 0 crash**（2026-07-03 に再検証。旧記載の
  「680 pass, 14 fail, 21 crash」は stale だった）。`zig build test-kotori` 中に1回
  `failed command:` が出るのは、全テスト完了後に zig 0.16 の test_runner 自身が
  `internal test runner failure: EndOfStream` で SIGABRT する（build runner が IPC パイプを
  先に閉じる shutdown race、coredump で確認済み）だけで、テスト結果には無害。
  direct 実行（`./.zig-cache/o/.../test`）は exit 0 で安定。kotori 側のバグではない。

## WPT 実行
```bash
./tests/wpt/run_wpt_parallel.sh setup   # /tmp/wpt クローン (再起動後)
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
# 単発:
DISPLAY=:98 timeout 120 ./zig-out/bin/suzume --wpt-mode "http://127.0.0.1:9876/url/xxx.any.html"
```
- run_wpt.sh のラッパー生成が `// META: script=` を解決するようになった
- Xvfb :98 + python3 -m http.server 9876 (in /tmp/wpt) が前提
- ⚠️ run_wpt.sh で一度ラッパー生成してから parallel を使う（rm url/*.any.html で再生成可）

## 次セッション優先タスク

### 0. パフォーマンス改善 — Waves 185-189 でほぼ完了 ✅
残り:
- 外部スクリプト/CSS の同期フェッチ(上記「既知の残課題」参照)
- StringPool.get は O(1) 化済み (Wave 182)、upvalue/closure は Wave 185 で解消
  — 同種の「線形スキャン系」が他にもないか vm.zig / object.zig を疑え
  (プロパティ探索、descriptors 等)
- quickjs エンジン側 (dom_api.zig) の URL reflection (`ru()` ヘルパー) は
  まだ毎アクセス `new URL()`。kotori がデフォルトなので優先度低

### 0.5 Google レンダリング崩れ(ユーザー報告) — ✅ 検証済み (2026-06-29)
- 症状(元): google.com でヘッダーリンク2個のみ描画。ロゴ・検索ボックス不可視
- 根本原因: デフォルトウィンドウサイズが 4096×4096 (クランプ値) で Google の
  flexbox を異常な幅に伸ばしていた。Wave 208b で 1280×1024 に修正済み。
- **検証 (2026-06-29 第4部)**: Xvfb :98 + ReleaseSafe build で実際に
  `https://www.google.com` を読み込み、WebDriver execute/sync (Wave 209 で
  kotori 対応済み) で DOM を直接照合して可視性を確認。スクショは
  `docs/evidence/google-kotori.png` に保存。
  - title="Google", url=google.com, viewport=1280×936 (Wave 208b 修正確認)
  - body children=10, img count=12 (logo visible, alt="ワールドカップ 2026: 芸術的エラシコ")
  - 検索 textarea#APjFqb visible, role=search 存在
  - 4つの submit button 可視 (Google 検索 + I'm Feeling Lucky ×2)
  - 18 リンク (Gmail/画像/ストア/ログイン 等ヘッダーリンク全て visible)
  - ユーザー報告の症状(リンク2個のみ、ロゴ+検索ボックス不可視)は完全に解消済み
- 追加検証: Wikipedia (Zig 記事) + Hacker News も同一セッションで検証。
  スクショは `docs/evidence/wikipedia-kotori.png`, `docs/evidence/hackernews-kotori.png`。
  - Wikipedia: title/h1 正常, 39段落 (33段落に本文テキスト), 522 リンク, 15 img, infobox visible
  - Hacker News: 30 posts, 30 scores, 229 リンク, 上位5タイトル取得可能
  → kotori デフォルト引擎で Google/Wikipedia/Hacker News の3サイトが実用的に描画可能
- 調査ツールにしようとした **--webdriver は Wave 190 で修正済み、Wave 209 で
  kotori デフォルト引擎での execute/sync+async も対応済み**。
  `DISPLAY=:98 ./zig-out/bin/suzume --webdriver 9999` で起動、
  `curl http://127.0.0.1:9999/status` で動作確認可能。レイアウトデバッグに活用可。


### 1. IdnaTestV2 (残り ~1200 subtests)
- `src/url/idna.zig` / `tables.zig` の UTS#46 конформance
- パターン: xn-- punycode 検証 (invalid → throw)、bidi/contextJ チェック

### 2. urlencoded-parser (30/105) + urlsearchparams-*
- kotori の URLSearchParams は JS ポリフィル。`src/url/search_params.zig`
  (ネイティブ実装あり) をバインドするのが本筋
- application/x-www-form-urlencoded の UTF-8 デコード規則

### 3. IPv4 パーサー強化
- `http://0300.168.0xF0` → 192.168.0.240 (octal/hex/短縮形、url-constructor 残りの一部)
- percent-decoded host の IPv4 再解釈 (`%30%78...`)
- 末尾ドット (`0xc0.0250.01.`)

### 4. failure.html / idlharness
- failure.html: URL ctor + a.href 両方で invalid 入力の扱い
- idlharness.any.html (0/1): WebIDL メタテスト、ハーネス依存が深い

### 5. kotori 残課題（このセッションで発見、未着手）
- ループの per-iteration binding (クロージャが最終値を見る — D3 テストケース)
- lone surrogate の percent-encode は WTF-8 バイトを encode（spec は U+FFFD 置換）
  → pool 文字列を percent-encode する際に CESU/WTF-8 サロゲートを FFFD に置換すべき
- url-setters の `Object.entries` 依存は解決済み（分割代入対応で）

## アーキテクチャメモ
- URL パーサーは共有モジュール `url_parser` (build.zig で kotori_dom/kotori_rt/exe に配線)
- kotori の URL クラス = prototype アクセサ + `this._p` (ネイティブ field object)
- setters は `__suzume_url_set(href, prop, value)` → `parser.applySetter()`
- `<a>`/`<area>` は hyperlink_utils_polyfill_js (kotori_runtime.zig)
- interface prototype は freeze される — ポリフィルで拡張するなら
  kotori_dom.zig の `unfrozen_html_protos` に追加
- document.baseURI はネイティブ (`docBaseUriString` in kotori_dom.zig)
- VM: 未捕捉例外は `execute()` がクリアして `last_uncaught` に保存
