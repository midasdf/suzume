# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。基礎レイヤーから順に。

## 前回セッション成果（2026-05-26 ultrawork）

### 12 commits, 9 waves (149-158)

| Wave | Commit | 内容 |
|------|--------|------|
| 149 | d49fb07 | Event() ctor rejects empty-type per spec |
| 150 | 54e24ed | WheelEvent ctor: deltaX/Y/Z/deltaMode |
| 151 | 72d7e51+df87186 | TextEncoder/TextDecoder UTF-8 polyfill + surrogate fix |
| 152 | 9e48f0a | URLSearchParams full API (17/27 WPT) |
| 153 | 977edd0 | FocusEvent + InputEvent native constructors |
| 154 | df9a9ec | VM: nativeArraySlice + `in` for TypedArrays |
| 155 | 021d3bf | Blob/File/FileReader polyfill |
| 156 | bc03d12+e47c843 | UTF-16LE/BE decode + \\xHH parser fix |
| 157 | fb92edf | TextDecoder stream decode + pending bytes |
| 158 | a042934 | instanceof fix: File.prototype chain |

### WPT改善（.any.* tests）
- `encoding/api-basics`: 0 → **6/6 PASS**
- `encoding/api-surrogates-utf8`: 0 → **7/7 PASS**
- `urlsearchparams-constructor`: 0 → **17/27 PASS**
- `events/Event-constructors`: 13 → **14/14 PASS**

### 主要変更ファイル
- `src/js/kotori_runtime.zig` — +700 lines (6 polyfills)
- `src/js/kotori_dom.zig` — +90 lines (4 constructors + fix)
- `src/js/kotori/vm.zig` — +67 lines (3 operations)
- `src/js/kotori/parser.zig` — +10 lines (bug fix)

## ビルド（重要）
```bash
# GCC 16/glibc 2.43 の .sframe 問題回避
# /tmp/libc-min/ は再起動後に再作成が必要
zig build --libc /tmp/libc-min/libc.txt
```
libc-min の中身: stripped crt1.o (no .sframe) + dynamic .so symlinks + libc_nonshared.a

## 次セッション優先タスク（4項目全部）

### 1. VM改善
- `instanceof` に `Object.create()` チェーン対応を追加（ネイティブ側）
  - 参考: vm.zig:486-515 の `nativeInstanceOf`、walk は `lhs_obj.prototype` を辿る
  - 問題: `Object.create(Blob.prototype)` で作られた `File.prototype` のプロトタイプチェーンを instanceof が検出しない
- `+ ''` 暗黙的 toString 強制変換の修正
  - 参考: vm.zig:2932 `stringConcat` → `formatValue` fast path（Proxy再帰回避のため意図的）

### 2. Polyfill継続
- `AbortController` + `AbortSignal`（web_api.zig:2677-2688 にJS実装あり → kotori_runtime.zig に注入）
- `DOMParser`（XML/XHTMLパース）
- `MutationObserver`
- `CustomEvent` コンストラクタ（kotori_dom.zig に追加、WheelEventパターン踏襲）

### 3. CSS Cascade @layer
- `src/css/parser.zig:662-704` に @layer 構文解析は既存（透過扱い）
- `src/css/cascade.zig` (3971行) にレイヤー優先度システム追加
- 全テストが reftest（visual比較）のため検証が難しい
- 必要なもの: layer ID追跡、cascade順序付け、revert-layer キーワード
- **大きい機能。複数コミットに分割推奨。**

### 4. DOMコア
- `Node.cloneNode` の名前空間クローン
  - 参考: `src/js/dom_node.zig:1420` `elementCloneNode`
  - SVG要素を暗黙のHTML名前空間でクローンしてしまう問題
- `ChildNode` ミックスインのカバレッジ拡大
  - `before/after/replaceWith/remove` は QuickJS側・kotori側両方に実装済み
  - エッジケーステスト（CharacterData全種、DocumentType等）

### WPTテストの制約
- `.any.js` テスト（JS-only）は file:// で直接動作
- `.any.html` / HTML-pageテストはHTTPサーバー経由だと不安定（hang/timeout）
- ハイブリッド方式: ローカルHTMLがHTTPから testharness.js + .any.js を読み込む（動作確認済み、遅い）
- CSS系テストは reftest（視覚比較）が中心 → JSで検証不可
./tests/wpt/run_wpt_parallel.sh --jobs 4 dom/nodes
./tests/wpt/run_wpt_parallel.sh --jobs 4 html/dom

# WPTセットアップ（/tmp再起動後）
./tests/wpt/run_wpt_parallel.sh setup
# or
./tests/wpt/run_wpt.sh setup

# test262
cd /tmp/quickjs-ng-full && ./run-test262 -c test262.conf
```

## Reftest Results (2026-03-25 late)

Suzume passes visual reftests at very high rates:
- css-flexbox: 89/100 = 89% (sample)
- css-display: 29/30 = 97% (sample)
- css-grid: 8/10 = 80% (sample)

Estimated +1700 additional tests when reftest integrated into runner.

Total available reftests across CSS areas:
- css-grid: 1194
- css-flexbox: 740
- css-backgrounds: 670
- css-sizing: 532
- css-overflow: 475
- css-position: 219
- css-tables: 151
- css-display: 78
Total: ~4059 reftests

Next: integrate reftest into run_wpt_parallel.sh for combined scoring.
