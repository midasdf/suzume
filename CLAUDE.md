# CLAUDE.md — suzume Browser

## Project

Zig製カスタムブラウザエンジン。RPi Zero 2W (512MB RAM, Cortex-A53, 720x720 HyperPixel4) 向け。
~5MBバイナリ、自前CSS/レイアウトエンジン、QuickJS-ng JSエンジン。

## Build

```bash
zig build                    # native x86_64
zig build test-css           # CSS engine unit tests
zig build run -- --url URL   # run browser
```

## Test (Docker Firefox comparison)

```bash
./tests/run-compare.sh                    # full test suite
# or manually:
zig build
docker build -t suzume-compare -f tests/Dockerfile.compare .
docker run --rm \
  -v "$(pwd)/tests/screenshots/docker-results:/app/results" \
  -v "/usr/share/fonts:/usr/share/fonts:ro" \
  --shm-size=512m \
  suzume-compare "https://news.ycombinator.com" "https://en.wikipedia.org/wiki/Web_browser" "https://lobste.rs" "https://info.cern.ch" "https://old.reddit.com"
```

## Current Baseline (Firefox diff%)

- lobste.rs: 0.0%
- info.cern.ch: 2.8%
- HN: 28.3% (±0.5% content noise)
- Wikipedia: 23.3%
- old.reddit.com: ~29% (±2% content noise — dynamic front page)

## Remaining Diff Causes

残りのdiff%は主に**フォントメトリクス差**が支配的：
- fontconfigで解決済み（NotoSans-Regular.ttf）だがFirefoxとは微妙に異なるフォント選択
- `pt`単位のfont-size（HN: 10pt=13.33px）がu32切り捨てで整数px化される
  - `FT_Set_Char_Size`への変更はヒンティング差でリグレッション→要調査
- IFCのstrut実装はフォントメトリクス差を増幅→先にフォント一致が必要

### 試行済みだがリグレッションした改善
- **IFC strut** — old.reddit 30.6%に悪化。既存のメトリクス差を増幅
- **FT_Set_Char_Size** — Wikipedia 26.9%に悪化。ヒンティング動作が異なる
- **DejaVu Sansデフォルト化** — old.reddit 30.5%に悪化。fontconfig環境依存

### 次に試すべき改善
1. **FreeTypeヒンティングモード調査** — FirefoxのFreeType設定を一致させる
2. **CSS `vertical-align` IFC精度** — inline要素のベースライン揃え
3. **CSS `white-space` collapsing** — inline要素間のスペース折り畳み
4. **`text-align: justify`** — 両端揃えレイアウト

## Improvement Tasks

`/tasks` で一覧を確認。status が `completed` で description に "Deferred" とあるものが未実装タスク。
優先度が高いもの・実装インパクトの大きいものから着手する。

### 改善ループの進め方

1. タスクの description に書かれた実装方針を読む
2. 関連ソースを読んで実装
3. `zig build` でビルド確認
4. 5-10個実装したら `docker build + docker run` で Firefox比較テスト → diff% 確認
5. リグレッションがあれば原因特定して修正
6. 完了したタスクは description を実装内容に更新

### 高インパクト未実装タスク (優先)

- ~~**position:fixed** — ビューポート相対配置~~ ✅ 実装済み
- ~~**position:absolute** — nearest positioned ancestor探索~~ ✅ 実装済み
- **position:sticky** — スクロール連動クランプ (containing block境界で停止)
- **z-index stacking context** — ネストされたスタッキングコンテキスト
- ~~**rowspan** — テーブルの行またがりセル~~ ✅ 実装済み
- ~~**border-style描画** — dashed/dotted/double/groove/ridge~~ ✅ 実装済み
- ~~**multi-stop gradient** — N色グラデーション~~ ✅ 実装済み (max 8 stops)
- **IntersectionObserver** — lazy loading用
- **History API** — SPA pushState/popstate
- **:has() selector** — モダンサイトで必須化が進んでる
- ~~**parent-child margin collapsing** — 完全版~~ ✅ 実装済み
- ~~**inline float wrapping** — テキストがfloat周りに回り込む~~ ✅ 実装済み

## Architecture

```
src/main.zig          — event loop, page loading, image batch loader
src/css/cascade.zig   — CSS cascade, UA stylesheet, property application
src/css/computed.zig  — ComputedStyle struct (120+ fields)
src/css/parser.zig    — CSS parser (@layer, @media, @supports, @keyframes)
src/css/properties.zig — shorthand expansion (border, flex, background, logical properties)
src/css/selectors.zig — selector matching with bloom filter
src/layout/block.zig  — block layout, IFC, floats, margin collapsing
src/layout/flex.zig   — flexbox (row/column/wrap, min-width:auto)
src/layout/grid.zig   — CSS Grid (areas, auto-placement, track sizing)
src/layout/table.zig  — table (cellspacing, cellpadding, valign, border-collapse)
src/layout/tree.zig   — box tree construction from DOM + styles
src/paint/painter.zig — rendering (backgrounds, borders, text, images, shadows)
src/paint/surface.zig — framebuffer abstraction (libnsfb + X11)
src/paint/text.zig    — FreeType + HarfBuzz text shaping
src/js/dom_api.zig    — DOM API bindings (querySelector, classList, etc.)
src/js/web_api.zig    — Web APIs (fetch, localStorage, Canvas, WebSocket, etc.)
tests/compare-firefox.sh — Docker Firefox comparison script
```

## Constraints

- 4GB VPS / 512MB RPi: no heavy dependencies
- JS engine: QuickJS-ng (best balance of size/ES compliance/C API)
- No libcss: self-implemented CSS engine
- Fonts: NotoSansCJK + DejaVu fallback
