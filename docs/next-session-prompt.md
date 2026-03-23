# suzume ブラウザ — 次セッションのプロンプト

suzume/CLAUDE.mdを参照して、WPT全エリア100%を目指して作業をお願いします。CSS/JS仕様を検索しながら進めてください。

## 前セッション成果（2026-03-23）

- ✅ shorthand→longhand展開 (margin/padding) + CSS-wide keyword解決
- ✅ margin-trim PropertyId + ComputedStyle + cascade + validation + serialization
- ✅ display two-value syntax validation + margin-trim computed canonicalization
- **WPT css-box: 63.8% → 95.8%** (294/307, +98 subtests)
- **WPT css-display: 40.2% → 47.0%** (118/251, +17 subtests)
- 他エリアのベースライン確立済み

## WPT全エリア現状と100%ロードマップ

| エリア | Pass Rate | Pass/Total | err | 残FAIL原因 |
|--------|-----------|------------|-----|-----------|
| **css-box** | **95.8%** | 294/307 | 51 | calc/%→px(10), margin-trim layout(2), calc serialization(1) |
| css-display | 47.0% | 118/251 | 6 | display-contents(10+), reading-flow/order(15), computed(10), valid(50+) |
| css-sizing | 40.7% | 211/519 | 102 | 大半がlayout reftest (err多) |
| css-position | 38.9% | 139/357 | 16 | position関連reftest |
| css-overflow | 28.8% | 134/466 | 126 | overflow関連reftest (err多) |
| css-values | 24.3% | 391/1610 | 155 | calc()解決, serialization, property validation |

**注意**: errはtestharness.jsのテスト結果取得失敗（タイムアウト or JSエラー）。subtestsにカウントされない。errを減らすのもpass rate向上に重要。

## 優先順位（インパクト × 実装コスト順）

### Tier 1: 横断的インフラ改善（全エリアに効く）

#### 1A. calc() computed value解決 ★最優先★
**影響**: css-box +5, css-values +100以上, css-display +5, 他エリアにも波及
**現状**: getComputedStyleがcalc()をそのまま返す。`calc(0.5em + 10px)` → `"30px"` にすべき
**実装場所**: `computedStyleGetPropertyValue` / `windowGetComputedStyle`のinline style読み出し
**方針**:
1. `resolveCalcToPixels(val, font_size, container_width)` を作る
2. calc()内の`em`/`rem`/`px`/`%`/`vw`/`vh`を全て`px`に変換して四則演算
3. container_widthは`getComputedStyle`呼び出し時にlayout結果から取得（なければ0）
4. 単位が混在して解決不能な場合（`em + %`でcontainer不明）はそのまま返す

#### 1B. % → px computed value解決
**影響**: css-box +5, css-values +50以上
**現状**: `padding: 20%` → `"20%"` だが `"40px"` を返すべき（200px幅コンテナの20%）
**方針**: calc()解決と同じインフラ。layout結果のcontaining block幅を参照

#### 1C. calc() serialization正規化
**影響**: css-box +1, css-values +20以上
**現状**: `calc(2em + 3%)` → そのまま。`calc(3% + 2em)` にすべき
**CSS spec**: canonical order = %, then length units (em, px等), then viewport units (vw, vh等)
**実装**: calc()パーサーでterm抽出 → 単位種別でソート → 再serialization

### Tier 2: プロパティ認識拡充（テスト数多い）

#### 2A. reading-flow / reading-order PropertyId追加
**影響**: css-display +15テスト（valid + computed）
**実装**: ast.zig PropertyId追加 + property_map + computed.zig field + cascade + dom_api.zig
**パターン**: margin-trimと同じ（PropertyId→field→cascade→getComputedStyle）
- reading-flow: normal | flex-visual | flex-flow | grid-rows | grid-columns | grid-order
- reading-order: integer (like z-index)

#### 2B. display computed値の2-value serialization
**影響**: css-display +10テスト
**現状**: getComputedStyleで`display: block`が"block"だが、spec上は"block flow"等の2-value形式が正式
**注意**: WPTのtentativeテスト。Chromeも未実装のものがある

#### 2C. display-contents セマンティクス
**影響**: css-display +10テスト
**現状**: `display:contents`はisValidCssValueで受理済みだがlayout/DOMに効果なし
**必要**: box tree構築で`display:contents`要素自体のboxを生成せず、子をそのまま親に配置

### Tier 3: Layout reftest (最も難度が高い)

#### 3A. errテスト削減
**影響**: err合計405テスト（結果未取得でpass扱いにならない）
**原因分析**: タイムアウト（10秒）、JSエラー、reftest形式の非対応
- run_wpt.shのTIMEOUT増加を検討（10→15秒）
- reftest形式（比較画像テスト）は現在のインフラで未対応→スキップが正しい

#### 3B. css-sizing / css-position / css-overflow layout改善
**影響**: 数百テスト。しかし大半がreftest（レンダリング比較）で、testharness形式は少ない
**方針**: まずtestharness形式のテストだけ抽出して改善。reftestは別インフラが必要

## WPT実行方法

```bash
# WPTチェックアウト（/tmp再起動で消える。初回 or 消えてたら実行）
git clone --depth 1 --sparse https://github.com/web-platform-tests/wpt.git /tmp/wpt-checkout
cd /tmp/wpt-checkout && git sparse-checkout set resources/ css/css-box/ css/css-text/ css/css-inline/ css/css-tables/ css/css-sizing/ css/css-position/ css/css-overflow/ css/css-values/ css/css-display/ css/support/

# testharnessreport.jsにsuzume用コールバック追加が必要（/tmp再起動で消える）
# ファイル末尾のadd_completion_callbackでWPT_SUMMARY/WPT_FAILをconsole.logに出力

# テスト実行（Xvfb必要）
cd ~/suzume
./tests/wpt/run_wpt.sh css-box       # 83テスト, ~14分
./tests/wpt/run_wpt.sh css-display   # 33テスト, ~5分
./tests/wpt/run_wpt.sh css-values    # 233テスト, ~40分
./tests/wpt/run_wpt.sh css-position  # 105テスト, ~17分
./tests/wpt/run_wpt.sh css-sizing    # 163テスト, ~27分
./tests/wpt/run_wpt.sh css-overflow  # 204テスト, ~34分

# 全エリア並列実行
for area in css-box css-display css-values css-position css-sizing css-overflow; do
  ./tests/wpt/run_wpt.sh $area 2>&1 | tail -8 &
done; wait
```

## ビルド・テスト・デプロイ

```bash
zig build                    # native x86_64
zig build test-css           # CSS unit tests

# クロスコンパイル (HackberryPi aarch64)
zig build -Dtarget=aarch64-linux-gnu.2.43
cat zig-out/bin/suzume | sshpass -p Satuki0815 ssh midasdf@10.187.44.109 'cat > /usr/local/bin/suzume && chmod +x /usr/local/bin/suzume'

# Firefox比較テスト（Docker, 5サイト, ~10分）
docker build -t suzume-compare -f tests/Dockerfile.compare .
docker run --rm -v "$(pwd)/tests/screenshots/docker-results:/app/results" -v "/usr/share/fonts:/usr/share/fonts:ro" --shm-size=512m suzume-compare "https://news.ycombinator.com" "https://en.wikipedia.org/wiki/Web_browser" "https://lobste.rs" "https://info.cern.ch" "https://old.reddit.com"
```

## 主要関数リファレンス（dom_api.zig内）

| 機能 | 関数 | 場所 |
|------|------|------|
| Shorthand展開 | `expandBoxShorthandInStyle()`, `getBoxLonghands()` | dom_api.zig |
| Shorthand再構築 | `reconstructBoxShorthandJS()`, `getLonghandFromShorthand()` | dom_api.zig |
| CSS-wide keyword | `cssInitialValue()`, `isCssInheritedProperty()`, `getInheritedComputedValue()` | dom_api.zig |
| margin-trim | `normalizeMarginTrim()`, `fmtMarginTrim()`, `isValidMarginTrimValue()` | dom_api.zig |
| margin-trim parse | `parseMarginTrim()` | cascade.zig |
| Computed正規化 | `resolveInlineForComputed()` | dom_api.zig |
| Display validation | `isValidDisplayValue()` | dom_api.zig |
| CSS validation | `isValidCssValue()` | dom_api.zig |
| getComputedStyle static | `windowGetComputedStyle()` inline for + prop_pairs | dom_api.zig |
| getComputedStyle live | `computedStyleGetPropertyValue()` | dom_api.zig |

## 進め方の推奨

1. まずcalc() computed value解決（1A）を実装 — 最もインパクト大
2. 次に % → px解決（1B）— 1Aと同じインフラ
3. css-box 100%確認、他エリアにも波及効果を確認
4. reading-flow/reading-order追加（2A）— css-display改善
5. calc() serialization（1C）— css-values大幅改善
6. 各エリアのWPT実行して改善ループ
