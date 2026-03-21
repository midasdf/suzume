# suzume 次フェーズ — 動的スクリプト実行 + レンダリング品質

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）の動的スクリプト実行とレンダリング品質を強化するセッション。

### 現在のスコア・互換性
- **ベンチマーク**: 111/111 (100%)
- **QuickJS ES**: 62/62 (ES2024 full)
- **DOM API**: 74/74 (100%)
- **JSエラー 0**: HN, Reddit, Lobsters, SO (4サイト安定)
- **JSエラー可変**: GitHub (0-3), dev.to (0-6) — Webpack/Preact動的ロード依存

### 前セッションで実装済み
- CSS background-image url() + SVGレンダリング (lunasvg v2.4.1)
- CSS position:sticky (paint-time scroll clamping)
- Flex align-self
- querySelector複数属性セレクタ + ドット含む属性値対応
- MutationObserver (Zig-native, childList + attributes)
- Inline `<svg>` 要素サポート
- XMLHttpRequest polyfill改善
- history.pushState URL bar sync
- document.currentScript.tagName/nodeName
- Docker Firefox比較テスト基盤 + JSエラーチェック

### Docker比較結果
- lobste.rs: 0.0% diff
- info.cern.ch: 9.5% diff
- HN: 35.7% diff（SVG矢印は表示される、差分はフォント/レイアウト差）

---

## やること: Priority順

### Priority 1: 動的スクリプト実行

**現状**: `document.createElement('script')` → `script.src = url` → `head.appendChild(script)` でスクリプトを動的に注入しても実行されない。`appendChild`でDOMに追加されるが、HTTPフェッチ→評価のパイプラインがない。

**影響**: Webpackの動的chunk loading、Google Tag Manager、lazy-loaded scripts。GitHub/dev.toのエラーの根本原因。

**実装方針**:
1. `elementAppendChild` / `elementInsertBefore`で`<script>`タグがDOMに追加されたことを検出
2. `src`属性があれば、HTTPフェッチ→`js_rt.eval(code)`で実行
3. `src`がなければ（inline script）、`textContent`を`eval`
4. `script.onload` / `script.onerror` コールバックを発火
5. `async`/`defer`属性の簡易対応（async: 即時実行、defer: DOM idle時）
6. 同一URLの重複実行を防止（loaded URLs set）

**注意点**:
- fetchは同期的にやらないとWebpackのchunk依存関係が壊れる
- `loadBytesWithTimeout`（既存のHTTPクライアント）を使える
- `script.onload`は実行完了後にsetTimeout(cb, 0)で非同期発火
- `type="module"`のES Moduleもサポートが必要（QuickJS-ngはES Module対応済み）
- `type="application/json"`等の非JSスクリプトはスキップ

**テスト**:
- テストHTML: `createElement('script') → script.src = '...' → appendChild` → onload発火確認
- GitHub: Webpack chunk loading が動くか（0エラー安定化）
- dev.to: Preact chunk loading が動くか（0エラー安定化）

### Priority 2: CSS :hover / :focus 擬似クラス

**現状**: パース済みだがマッチングされない。`events.zig`にmouse eventはあるが、CSSの再カスケードとは連動してない。

**影響**: ナビゲーションメニュー、ボタンのハイライト、ツールチップ。

**実装方針**:
- `mouseover`/`mouseout`イベントで`hover_node`をセットし、`dom_dirty`フラグを立てる
- `cascade.zig`のセレクタマッチングで`:hover`をチェック（hover_node == current_node or ancestor）
- パフォーマンス: hover変更時は再cascadeせず、hover_nodeのスタイルだけ上書き

### Priority 3: CSS transform (scale, rotate)

**現状**: translateのみ対応。scale/rotateはパースされない。

**影響**: アイコン回転、ズーム効果、CSSアニメーション（将来的に）。

**実装方針**:
- `computed.zig`に`transform_scale`, `transform_rotate`フィールド追加
- `cascade.zig`でtransform値をパース（matrix未対応でOK）
- `painter.zig`で描画時にaffine変換を適用（libnsfb経由は難しいのでソフトウェア実装）
- scale: blitImageScaledのスケーリングファクター
- rotate: 90°刻み対応（任意角度は後回し）

### Priority 4: CSS @font-face

**現状**: 未実装。カスタムWebフォントが使えない。

**影響**: Google Fonts使用サイト、アイコンフォント（FontAwesome等）。

**実装方針**:
- `cascade.zig`で`@font-face`ルールをパース（font-family, src: url()）
- フォントファイルをHTTPフェッチ→一時ファイルに保存
- FreeTypeでロード → FontCacheに登録
- woff/woff2はデコンプレス必要（zlib/brotli） — 後回しでttf/otfのみ先

### Priority 5: CSS :nth-child / :not() 擬似クラス

**現状**: `:first-child`, `:last-child` のみ対応。`:nth-child(n)`, `:not(.class)` 未対応。

**影響**: 交互行の色分け（テーブル）、否定セレクタ。

**実装方針**:
- `selectors.zig`に`:nth-child(an+b)`パーサー追加
- `:not()`は内部セレクタを再帰的にマッチ

---

## テスト方法

```bash
# Docker内でJSエラーチェック（ホストに影響なし）
cd ~/suzume
zig build
docker build -t suzume-compare -f tests/Dockerfile.compare .

# JSエラーカウント（6サイト）
docker run --rm --entrypoint /app/error-check.sh \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m suzume-compare

# Firefox比較テスト
docker run --rm \
  -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m \
  suzume-compare "https://news.ycombinator.com" "https://lobste.rs"

# Docker権限: ユーザーがdockerグループに入っていない場合
sg docker -c 'docker run ...'
```

**注意**: テストは必ずDockerコンテナ内で実行すること。ホストでsuzumeを起動するとウィンドウが画面に表示されて作業を妨げる。

## 既知のバグ

1. **GitHub/dev.to JSエラー**: Webpack chunk loadingに動的script実行が必要（Priority 1で修正）
2. **HN 35% diff**: フォントレンダリングとレイアウト高さの差（フォント/行間の問題）
3. **Cloudflare email-decode.js**: `removeChild of undefined` — Cloudflareのスクリプトがメールアドレスの難読化解除で失敗

## コードベース要約

- `src/js/dom_api.zig` (~4700行): DOM API、forms、canvas、MutationObserver records、querySelector
- `src/js/web_api.zig` (~1750行): fetch()、timer、XHR polyfill、MutationObserver登録、history
- `src/js/events.zig` (~760行): addEventListener、mouse events、MutationObserver registry/flush
- `src/js/runtime.zig` (~350行): JsRuntime、eval、UTF-8、module loader
- `src/css/cascade.zig` (~2200行): CSSカスケード、gradient、extractUrl、background-image
- `src/css/properties.zig` (~1150行): CSSプロパティパース、shorthand展開
- `src/css/selectors.zig` (~600行): セレクタマッチング、specificity
- `src/layout/flex.zig` (~840行): Flexbox（align-self対応）
- `src/layout/block.zig` (~1400行): Block + inline レイアウト
- `src/layout/tree.zig` (~500行): box tree構築、inline SVG
- `src/paint/painter.zig` (~700行): 描画、background-image、position:sticky
- `src/svg/decoder.zig`: SVGデコード（lunasvg C wrapper経由）
- `src/svg/svg_wrapper.cpp`: C++ → C bridge（lunasvg API）
- `src/main.zig` (~3800行): エントリポイント、スクリプト実行、イベントループ
- `src/net/http.zig` (~120行): libcurl HTTPクライアント
- `deps/lunasvg/`: lunasvg v2.4.1 + PlutoVG（SVGレンダリング）

## テスト資産

- `tests/Dockerfile.compare`: Docker比較テスト環境（Xvfb + Firefox + suzume）
- `tests/compare-firefox.sh`: Firefox headless vs suzume スクリーンショット比較
- `tests/error-check.sh`: 6サイトJSエラーカウント（Docker内実行）
- `tests/run-compare.sh`: ホストからDocker比較テスト実行ラッパー
- `tests/fixtures/test_svg.html`: SVG img + background-image + inline SVG
- `tests/fixtures/test_mutation_observer.html`: MutationObserver childList/attributes
- `tests/fixtures/test_multi_attr.html`: querySelector複数属性セレクタ
- `tests/fixtures/test_slash_attr.html`: 属性値内のスラッシュ/ドット
- `tests/fixtures/test_so_selector.html`: SO readModuleArgs再現テスト
