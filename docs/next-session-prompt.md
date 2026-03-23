# suzume ブラウザ — 次セッションのプロンプト

suzume/CLAUDE.mdを参照して、以下の作業をお願いします。CSS/JS仕様を検索しながら進めてください。

## 前セッション成果（2026-03-23 session 2-3）

- ✅ shorthand→longhand展開 (margin/padding)
- ✅ CSS-wide keyword解決 (initial/inherit/unset/revert)
- ✅ margin-trim PropertyId + ComputedStyle + cascade + validation + serialization
- ✅ display two-value syntax validation (contents, inline-table, run-in, flow-root等)
- ✅ margin-trim computed canonicalization (resolveInlineForComputed)
- **WPT css-box: 95.8%** (294/307) — 前セッション63.8%から+32p
- **WPT css-display: 47.0%** (118/251) — 前回ベースラインなし

## WPT全エリア現状

| エリア | Pass Rate | Pass/Total | 改善余地 |
|--------|-----------|------------|---------|
| **css-box** | **95.8%** | 294/307 | calc/%→px(10), margin-trim layout(2), serialization(1) |
| css-display | 47.0% | 118/251 | display-contents, reading-flow/reading-order, computed値 |
| css-sizing | 40.7% | 211/519 | 多くがlayout reftest (err=102) |
| css-position | 38.9% | 139/357 | position関連reftest |
| css-overflow | 28.8% | 134/466 | overflow関連reftest |
| css-values | 24.3% | 391/1610 | calc()解決, serialization |

## 1. 100%に近づけるための優先作業

### css-box残り13テスト
- **calc()/% → px** (10テスト): getComputedStyleで%→px解決（要コンテナ幅）、calc()→px
- **margin-trim layout** (2テスト): flexboxでのmargin-trim実際の効果
- **calc() serialization** (1テスト): calc(2em + 3%) → calc(3% + 2em)

### css-display改善 (47% → 目標70%+)
- **display-contents** (10+テスト): `display:contents` のDOM/layout振る舞い
- **reading-flow/reading-order** (15テスト): 新CSS property追加（PropertyId + validation + computed）
- **display computed値** (10テスト): 2-value display computed serialization
- **display-valid追加** (tentative features): grid-lanes等

### css-values改善 (24% → 目標40%+)
- **calc() → px解決**: getComputedStyleでcalc()をpx値に解決
- **calc() serialization**: canonical term ordering (%, length, viewport)
- **未認識プロパティ値**: 各プロパティのvalidation拡充

## WPT実行方法

```bash
# WPTチェックアウト（/tmp再起動で消える）
git clone --depth 1 --sparse https://github.com/web-platform-tests/wpt.git /tmp/wpt-checkout
cd /tmp/wpt-checkout && git sparse-checkout set resources/ css/css-box/ css/css-text/ css/css-inline/ css/css-tables/ css/css-sizing/ css/css-position/ css/css-overflow/ css/css-values/ css/css-display/ css/support/

# testharnessreport.jsにsuzume用コールバック追加が必要

# テスト実行
cd ~/suzume
./tests/wpt/run_wpt.sh css-box
./tests/wpt/run_wpt.sh css-display
./tests/wpt/run_wpt.sh css-values
./tests/wpt/run_wpt.sh css-position
./tests/wpt/run_wpt.sh css-sizing
./tests/wpt/run_wpt.sh css-overflow
```

## クロスコンパイル

```bash
# HackberryPi (aarch64) 向け
zig build -Dtarget=aarch64-linux-gnu.2.43
# デプロイ
cat zig-out/bin/suzume | sshpass -p Satuki0815 ssh midasdf@10.187.44.109 'cat > /usr/local/bin/suzume && chmod +x /usr/local/bin/suzume'
```

## 実装上の注意

- shorthand展開: `expandBoxShorthandInStyle()`, `splitBoxShorthandParts()`, `getBoxLonghands()`
- shorthand再構築: `reconstructBoxShorthandJS()`, `getLonghandFromShorthand()`
- CSS-wide keyword: `cssInitialValue()`, `isCssInheritedProperty()`, `getInheritedComputedValue()`
- margin-trim: `parseMarginTrim()` (cascade.zig), `fmtMarginTrim()`, `normalizeMarginTrim()`, `isValidMarginTrimValue()`
- display validation: `isValidDisplayValue()` — two-value syntax + list-item対応
- computed style正規化: `resolveInlineForComputed()` — margin-trim等のproperty-specific canonicalization
- getComputedStyleのstatic値セット: `windowGetComputedStyle()` でinline for + prop_pairs
