# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。基礎レイヤーから順に。

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

### 0. パフォーマンス改善(ユーザー体感「めちゃめちゃ遅い」、最優先)
判明済みの手がかり(2026-06-13 セッションのプロファイルから):
- **Debug ビルド問題**: `zig build` デフォルトは Debug。日常利用は
  `zig build -Doptimize=ReleaseSafe` を使う(ReleaseFast は @intCast UB が
  怖いので Safe 推奨 — BPM で ReleaseSmall UB を踏んだ前例あり)。
  インストールスクリプト/ドキュメントに常用ビルドフラグを明記すべき
- **同期 HTTP フェッチがメインループをブロック**: 画像・外部スクリプトを
  メインスレッドで 1 件ずつ同期取得(timeout 15s)。Google などリソースが
  多いページで UI が固まる。pending_images の非同期化/並列化が本丸
- **upvalue 機構がホット**: gdb サンプリングで closeUpvaluesAbove /
  getOrCreateUpvalue / getClosureUpvalues が頻出。open_upvalues が線形リスト
  なら sorted 構造化や frame-local 化を検討
- **proxyGet 連打**: live HTMLCollection (getElementsByTagName 等) の
  Proxy trap が JS 呼び出しを伴う。ネイティブ化 or キャッシュ
  (baseURI で同手法により 300s→18s の実績、Wave 183)
- **URL reflection のパース毎回実行**: a.href 等のゲッターが毎アクセスで
  base+href をフルパース。(raw, baseURI) キーのキャッシュで削減可
- StringPool.get は O(1) 化済み (Wave 182) — 同種の「線形スキャン系」が
  他にもないか vm.zig / object.zig を疑え(プロパティ探索、descriptors 等)

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
