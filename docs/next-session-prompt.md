# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。基礎レイヤーから順に。

## 前回セッション成果（2026-06-13 第2部、パフォーマンス集中 Waves 185-189）

体感速度の主要ボトルネック5つのうち4つを解消。WPT url 5180/7244 (71.5%)・
test-kotori 680/14/21・404 leaks 全て変更前と同数（回帰ゼロ）。
a-element.html: **18s → 6.7s (2.7x)**。

| Wave | 内容 |
|------|------|
| 185 | **VM upvalue O(1)化** (vm.zig): open専用リスト分離（closeUpvalues* が閉セルを永久スキャンしてた）+ closure_entries を線形リスト→AutoHashMap（**毎関数呼び出し**で全クロージャ線形スキャンしてた） |
| 186 | **kotori live HTMLCollection キャッシュ** : `__suzume_domVer` (setDomDirty で bump する mutation epoch) を kotori に公開、brandHCLiveLen の Proxy trap が epoch 単位で rebuild をキャッシュ（quickjs 側 createLiveHTMLColl と同パターン）。allDescendants は override 前に捕獲した native getElementsByTagName('*') に委譲（JS childNodes ウォーク排除） |
| 187 | **URL reflection キャッシュ** (kotori_dom.zig): docBaseUriString を (epoch, document.URL) でメモ化、urlReflectionGet に (raw, base) → resolved の StringId キャッシュ（純粋関数なので無期限、VM 変更/8192件で破棄）。liveness は /tmp/wpt/local-live-cache-test.html で検証済み（3/3 pass） |
| 188 | **画像フェッチ非同期化** (src/net/image_fetcher.zig 新規): 4 ワーカースレッド（各自専用 HttpClient、curl easy handle 非共有）+ sync.Mutex キュー。decode/cache/layout/load・error イベントは全てメインスレッドの drain で実行。世代スタンプ (PageState.fetch_gen) でナビゲーション後の stale 結果を破棄。メインループの最大 30s ブロック（10 img × 3s timeout）が解消 |
| 189 | README に ReleaseSafe 常用ビルドを明記、build.zig の test-kotori-dom に url_parser 配線追加 |

### 既知の残課題（このセッションで発見/未着手）
- **test-kotori-dom はまだリンク不能**: `suzume_element_matches` (dom_selector.zig の
  export、quickjs 依存) が test ターゲットに無い。url_parser 配線は直した。
  恒久修正は mark_dirty_fn と同じ callback パターンで extern を関数ポインタ化
  （fallback は kotori_dom 内の matchSimpleSelector）
- **外部スクリプト/CSS はまだ同期フェッチ** (script_executor.zig:311 の 5s timeout、
  loader.zig walkForCssLinks/processImports の 3s×N 直列)。画像と同じ
  fetcher パターンを流用可能だが、スクリプトは実行順序の制約があるので要設計
- 画像 fetcher のワーカーはメイン HttpClient と cookie を共有しない
  （認証付き画像はロードされない可能性。必要になったら cookie file を共有）

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
- test-kotori のベースライン: **680 pass, 14 fail, 21 crash**（zig 0.16 起因、変更前から同数）

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

### 0.5 Google レンダリング崩れ(ユーザー報告)
- 症状: google.com でヘッダーリンク2個のみ描画。ロゴ・検索ボックス不可視
- content size が 4096×4096(クランプ値)に張り付く → 何かが巨大レイアウト
  → 中身が画面外 or 不可視の疑い。JS エラー/panic はログなし
- ヘッドレス再現: `DISPLAY=:98 ./zig-out/bin/suzume "https://www.google.com"`
  + `import -window root /tmp/g.png` でスクショ確認
- 調査ツールにしようとした **--webdriver が zig 0.16 で死んでる**
  (listen は成功するが accept がコマンドを処理しない、curl がタイムアウト。
  src/net/webdriver.zig の env.ioOrPanic() / スレッド起動まわりを疑う)。
  これを直すとレイアウトデバッグが圧倒的に楽になるので先に直す価値あり


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
