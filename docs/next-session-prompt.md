# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。CSS/JS仕様を検索しながら進めてください。
プラン: `~/.claude/plans/sleepy-puzzling-shell.md`

## 前セッション成果（2026-03-24 深夜）

### Infrastructure構築（Phase 0）
- ✅ **wptrunner adapter**: `tests/wpt/wpt-suzume/` Python package (NullBrowser + subprocess executor)
- ✅ **`--wpt-mode` flag**: ALERT:行をstdoutルーティング + wpt_result_sent自動終了 + 256KBバッファ
- ✅ **`--screenshot` flag**: stb_image_write経由でフレームバッファPNGダンプ (reftest用)
- ✅ **`run_wpt.sh`改良**: 全WPTカテゴリ対応 (dom/, url/, encoding/等), レガシーcss-X互換
- ✅ **test262セットアップ**: /tmp/quickjs-ng-full (standalone build), /tmp/test262
- ✅ **venv**: `.venv/` に wptrunner + wpt-suzume installed

### test262ベースライン（Phase 1）
- ✅ **99.7% pass** (107/41562 errors, 3353 excluded, 5588 skipped)
- 残りエラー: RegExp Unicode property escapes, TypedArray subarray edge cases
- QuickJS-ng 0.13 (standalone) vs suzume組込み0.12.1 — 差異は小さい

### WPTバグ修正（TDD成果）
- ✅ **Internal table/ruby blockification** — `table-row-group`/`ruby-base` + position:absolute → `block` (CSS Display L3 §2.7)
  - dom_api.zig: `computedStyleToStringWithBox` + `resolveInlineForComputed` 両パス修正
  - display-computed.html: 108/112 → **112/112 PASS**
- ✅ **calc() distributive expansion** — `calc(2*(10px+1rem))` → `calc(20px + 2rem)`
  - dom_api.zig: `tryDistributiveExpansion()` 新関数 (N*(A+B), (A+B)/N, (expr)*N reorder)
  - calc-serialization-002.html: 20/24 → **24/24 PASS**
- ⬜ **NaN/Infinity clamping (partial)** — fmtPx + resolveInlineForComputed にクランプ追加
  - cascade経由のComputedStyleパスはまだ未修正 (calc-infinity-nan-computed: 0/48)

## WPTスコア現状

| エリア | Before | After | 残FAIL主因 |
|--------|--------|-------|-----------|
| **css-box** | 97.4% | 97.4% (299/307) | margin-trim(2), padding-computed calc(6) |
| **css-display** | 68.2% | **69.1%** (328/475) | display-contents(~10), tentative(~14), reftests |
| **css-values** | 31.8% | **~32%+** (1065+8/3350) | NaN/Infinity(48), viewport-units(96+), round/mod/rem(23), calc-size(34) |

## 次セッション優先順位

### Tier 1: 最高インパクト（+100 subtests可能）
1. **NaN/Infinity in cascade** — cascade.zigでcalc()評価時にNaN/Infinity検出→0/MAX clamp (+48 tests)
   - resolveValueToPxDepthでNaN*1px等をパースできるようにする
   - ComputedStyle.Dimension.pxにNaN値が入らないよう防止
2. **viewport units (svw/svh/lvw/lvh/dvw/dvh)** — viewport-units-css2-001.html (64/160, +96 tests)
   - 新viewport unitを getComputedStyleで認識・解決
3. **round()/mod()/rem() functions** — round-mod-rem-serialize.html (1/24, +23 tests)
   - CSS math functionsの追加

### Tier 2: 中インパクト
4. **display:contents semantics** — box tree構築で display:contents 要素のboxを生成しない (+10 tests)
5. **calc-size() function** — 新CSS関数 (3/37 pass, +34 tests)
6. **min/max % preservation** — specified/computed/used value 3層で異なる%処理が必要 (+17 tests)

### Tier 3: 新エリアベースライン取得
- dom/, url/, encoding/, css/cssom/, css/css-cascade/, css/selectors/ のベースラインをまだ取得していない

## 重要な技術的決定

### wptrunner vs run_wpt.sh
- wptrunnerはentry_pointsの互換性問題（Python 3.14 + metadata API変更）で未解決
- 当面は改良版run_wpt.shで全カテゴリTDDサイクルを回す
- wptrunner統合は別セッションで

### WPTチェックアウト
- `/tmp/wpt` — 再起動で消える。`./tests/wpt/run_wpt.sh setup` で再セットアップ
- testharnessreport.jsにsuzumeコールバック注入が必要（setupで自動化済み）

### QuickJS-ng GC無効化（維持）
- `JS_SetGCThreshold(rt, SIZE_MAX)` — testharness.js GC corruption回避
- 48MB memory limitは維持

## 実装済みの主要関数リファレンス

| 機能 | 関数 | 場所 |
|------|------|------|
| calc distributive expansion | `tryDistributiveExpansion()` | dom_api.zig |
| Matching paren finder | `findMatchingParen()` | dom_api.zig |
| Function detection | `containsFunction()` | dom_api.zig |
| NaN/Infinity string check | `containsNanOrInfinity()` | dom_api.zig |
| NaN/Infinity px clamp | `fmtPx()` (modified) | dom_api.zig |
| Blockification (table/ruby) | `computedStyleToStringWithBox` + `resolveInlineForComputed` | dom_api.zig |
| WPT mode flag | `web_api.wpt_mode`, `web_api.wpt_result_sent` | web_api.zig |
| Screenshot dump | `surface.dumpToPng()` | surface.zig |

## ビルド・テスト

```bash
# ビルド
zig build

# CSSユニットテスト
zig build test-css

# WPTテスト（/tmp再起動後は setup 必要）
./tests/wpt/run_wpt.sh setup              # 初回のみ
./tests/wpt/run_wpt.sh css/css-box         # ~20分
./tests/wpt/run_wpt.sh css/css-display     # ~10分
./tests/wpt/run_wpt.sh css/css-values      # ~60分
./tests/wpt/run_wpt.sh dom                 # 未測定
./tests/wpt/run_wpt.sh url                 # 未測定

# test262
cd /tmp/quickjs-ng-full && ./run-test262 -c test262.conf  # ~2分

# venv (wptrunner用)
source .venv/bin/activate
```
