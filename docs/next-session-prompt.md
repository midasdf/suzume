# suzume ブラウザ — 次セッションのプロンプト

suzume/CLAUDE.mdを参照して、以下の作業をお願いします。CSS/JS仕様を検索しながら進めてください。

## 前セッション成果（2026-03-23 session 2）

- ✅ shorthand→longhand展開 (margin/padding) — `expandBoxShorthandInStyle()` で1-4値→4 longhand
- ✅ CSS-wide keyword解決 — `cssInitialValue()`, `getInheritedComputedValue()`, `isCssInheritedProperty()`
- ✅ shorthand再構築 — `reconstructBoxShorthandJS()` で longhands → shorthand
- ✅ longhand逆引き — `getLonghandFromShorthand()` + `getShorthandInfoForLonghand()`
- ✅ 親inline style inherit対応 — `getInheritedComputedValue()` で親のstyle属性もチェック
- ✅ FreeType diff%確認 — FT_LOAD_TARGET_LIGHT変更後のbaseline確定
- **WPT css-box pass rate: 81.4%** (250/307 subtests) — 前セッション63.8%から+17.6p

## 1. WPT pass rate さらなる改善（81.4% → 目標90%+）

### WPT実行方法

```bash
# WPTチェックアウト（/tmp再起動で消える。初回 or 消えてたら実行）
git clone --depth 1 --sparse https://github.com/web-platform-tests/wpt.git /tmp/wpt-checkout
cd /tmp/wpt-checkout && git sparse-checkout set resources/ css/css-box/ css/css-text/ css/css-inline/ css/css-tables/ css/css-sizing/ css/css-position/ css/css-overflow/ css/css-values/ css/css-display/ css/support/

# testharnessreport.jsにsuzume用コールバック追加が必要（/tmp再起動で消える）
# ファイル末尾のadd_completion_callbackでWPT_SUMMARY/WPT_FAILをconsole.logに出力

# テスト実行（Xvfb必要。83テスト、約14分）
cd ~/suzume && ./tests/wpt/run_wpt.sh css-box
```

### 残りの主なFAIL原因と対策

| 問題 | FAILテスト数 | 対策 |
|------|------------|------|
| **margin-trim (0/20 computed, 11/34 valid, 2/24 inheritance)** | ~45テスト | margin-trimをPropertyIdに追加＋computed styleサポート＋serialization正規化 |
| **calc()/% → px解決** | ~5テスト | getComputedStyleで%値→px解決（要コンテナ幅）、calc()→px解決 |
| **calc()シリアライズ順序** | 1テスト | `calc(2em + 3%)` → `calc(3% + 2em)` — CSS serialization: %を先に出力 |
| **flexbox margin-trim layout** | 2テスト | margin-trim実装後に対応 |

### 優先度が高い（影響テスト数が多い順）

1. **margin-trim PropertyId追加 + computed + serialization** (~45テスト)
2. **calc()/% → px computed value解決** (~5テスト)
3. **calc()シリアライズ正規化** (1テスト)

## 2. Firefox diff% 改善

### 現在のbaseline（FT_LOAD_TARGET_LIGHT適用後）:
- lobste.rs: 0.0%
- info.cern.ch: 2.7%
- HN: 28.8% (±0.5% content noise)
- Wikipedia: 26.9% (**+3.6% regression from hinting change**)
- old.reddit: 28.6% (±2% content noise)

### Wikipedia regression分析
FT_LOAD_TARGET_LIGHTでWikipedia 23.3%→26.9%に悪化。FT_Set_Char_Sizeでも同じ26.9%まで悪化した前例あり。
→ ヒンティングモード変更はWikipedia不利。FT_LOAD_TARGET_LIGHT以外のアプローチが必要かも。

**残りdiff原因（優先度順）：**

1. **CSS `vertical-align` in IFC** — inline要素のベースライン揃え精度。CSS 2.1 §10.8参照
2. **CSS `white-space` collapsing** — inline要素間のスペース折り畳み。CSS Text Module参照
3. **FreeTypeヒンティング再調査** — FT_LOAD_TARGET_LIGHTのWikipedia regression対策

**試行済みだがリグレッションしたもの（再試行しない）：**
- IFC strut（フォント一致前は逆効果）
- FT_Set_Char_Size（ヒンティング差でWikipedia悪化）
- DejaVu Sansデフォルト化（fontconfig環境依存）
- FT_LOAD_TARGET_LIGHT（Wikipedia +3.6%悪化）

## 3. 他のWPTエリア展開

css-box以外のエリアもテストして改善する:

```bash
./tests/wpt/run_wpt.sh css-display
./tests/wpt/run_wpt.sh css-position
./tests/wpt/run_wpt.sh css-sizing
./tests/wpt/run_wpt.sh css-overflow
./tests/wpt/run_wpt.sh css-values
```

## テスト実行方法

```bash
# ビルド
zig build

# CSSユニットテスト
zig build test-css

# Firefox比較テスト（Docker必要、5サイト約10分）
./tests/run-compare.sh "https://news.ycombinator.com" "https://en.wikipedia.org/wiki/Web_browser" "https://lobste.rs" "https://info.cern.ch" "https://old.reddit.com"

# WPTテスト（Xvfb必要）
./tests/wpt/run_wpt.sh css-box
```

## 実装上の注意

- shorthand展開: `expandBoxShorthandInStyle()`, `splitBoxShorthandParts()`, `getBoxLonghands()` (dom_api.zig内)
- shorthand再構築: `reconstructBoxShorthandJS()`, `getLonghandFromShorthand()`, `getShorthandInfoForLonghand()`
- CSS-wide keyword: `cssInitialValue()`, `isCssInheritedProperty()`, `getInheritedComputedValue()`
- isValidCssValue()でshorthandバリデーション: `isValidShorthandValue()` → `isValidBoxShorthand()`
- getComputedStyleのstatic値セット: `windowGetComputedStyle()` でinline for + prop_pairs
- CSS.supports(): `cssSupports()` 関数
