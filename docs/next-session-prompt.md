# suzume ブラウザ — 次セッションのプロンプト

TDDでWPT全エリア90%+を目指す。基礎レイヤーから順に。
プラン: `~/.claude/plans/sleepy-puzzling-shell.md`

## 前セッション成果（2026-03-25）

### 25 commits pushed to main

### WPTスコア
| Area | Start | End | Δ subtests |
|------|-------|-----|-----------|
| dom/nodes | 9.5% | **37.6%** | +1500 |
| classList | 630 | **1060** | +430 |
| css-color | 14.6% | **~24%** | +500 |
| css-text | 50.9% | **52.3%** | +27 |
| css-values | 31.8% | ~33% | +47 |
| css-variables | 24.0% | ~32% | +33 |
| css-display | 68.2% | ~69% | +4 |
| css-selectors | 43.1% | ~47% | +30 |
| css-box | 97.4% | 97.4% | 0 |
| html/dom | new | **27.8%** | baseline |
| dom/events | new | **13.5%** | baseline |
| css/cssom-view | new | **26.4%** | baseline |
| xhr | new | **18.7%** | baseline |

### 主要実装
- **WebDriver server** (21 endpoints, --webdriver=PORT)
- **DOMException constructor** (assert_throws_dom対応) — classList +430テスト
- **CSS Color 4**: hwb, oklab, oklch, lab, lch, color() — +500テスト
- **window/self globals** + Named access on Window
- **:is()/:where()** OR-semantics matching
- **classList DOMTokenList**: toString, toggle force, unique tokens, validation
- **text-wrap/tab-size/hyphens** properties
- **calc()** distributive expansion, NaN/Infinity clamping
- **var()** resolution in getPropertyValue
- **Node.isEqualNode** structural equality
- **element.localName, namespaceURI, prefix**
- **Parallel WPT runner** (run_wpt_parallel.sh)
- **round()/mod()/rem()** CSS math functions
- **opacity %** support + clamp
- **color() computed value** serialization (color(srgb ...) format)

### WPT非CSSエリアのベースライン
- url: 0% (テスト4件、ERR)
- encoding: 未測定
- html/syntax: 2.6% (パーサー適合性、reftest多)
- fetch: 未測定 (236テスト)
- websockets: 未測定 (126テスト)
- webstorage: 0% (timeout問題)
- FileAPI: 4.8%

## 次セッション方針

### 基礎→上位の順序で進める
```
URL/Encoding → HTML Parser → DOM → CSSOM → CSS → Layout → Web APIs
```

### 優先タスク
1. **DOM core** — dom/events改善、Node.cloneNode深化、ChildNodeミキシン
2. **html/dom** — Document properties、element interfaces
3. **CSSOM** — CSSStyleSheet、CSSRule、matchMedia
4. **css-cascade** — @layer実装（1.9%→）
5. **css-selectors** — querySelectorAll内:is()/:where()

### 残りの大きな実装項目（全部やる）
- @layer (CSS Cascade 5) — css-cascade 1.9%
- Shadow DOM — 228テスト
- color-mix() / relative color syntax — css-color +1600テスト
- DOMParser (XML/XHTML) — dom/nodes ERR多数
- Service Workers / Web Workers完全化
- CSS Grid/Flexbox reftests
- position:sticky
- :has() selector matching

## ビルド・テスト

```bash
# ビルド（.zig-cacheが古い場合はrm -rf .zig-cache zig-out）
zig build

# 並列WPTテスト
./tests/wpt/run_wpt_parallel.sh --jobs 4 css/css-box
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
