# suzume JS強化セッション — プロンプト

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）のJS/DOM機能を強化するセッション。基本的なHTML/CSS/JSレンダリングは動作しており、Hacker News、Old Reddit、DuckDuckGo Lite、CNN Lite、Wikipediaが読める状態。ベンチマーク82/87 (94%)。fetch() API実装済み。

## 現在の実サイト表示状況

| サイト | 結果 |
|--------|------|
| Example.com | 完璧 |
| DuckDuckGo Lite | 検索結果が読める |
| Hacker News | 30件記事リスト表示 |
| Old Reddit | 投稿・画像・日本語表示 |
| CNN Lite | ニュースヘッドライン表示 |
| Wikipedia | コンテンツ読める（横幅問題あり） |
| Google Search | 白画面（JSフレームワーク複雑すぎ） |

## やること: JS強化（優先度順）

### Priority 1: fetch() POST対応 + headers

**現状**: GET only。`fetch(url, { method: 'POST', body: '...', headers: {...} })` のoptions未パース。
**影響**: ログインフォーム、API呼び出し、SPA全般。
**実装**: web_api.zig の jsFetch で options引数からmethod/body/headersを読み取り、HttpClientにPOST機能を追加。
```zig
// HttpClient に post() メソッド追加
// curl: CURLOPT_POST, CURLOPT_POSTFIELDS, CURLOPT_HTTPHEADER
```

### Priority 2: input.value / textarea.value / select.value

**現状**: `input.value`のgetter/setterが未実装（getAttribute("value")は動くが.valueプロパティが欠如）。
**影響**: フォーム操作全般。React/Vue/jQueryのデータバインディング。
**実装**:
- HTMLInputElement prototype に `value` getter/setter を追加
- getter: lxb_dom_element_get_attribute(elem, "value") + 内部state管理
- setter: 属性更新 + dom_dirty
- textarea: textContent経由
- select: selectedIndex + option[].value

### Priority 3: removeEventListener 修正

**現状**: `removeEventListener(type, callback)` が常に最後に追加されたリスナーを削除。コールバック関数の同一性チェックなし。
**影響**: React/Vue/jQueryのイベントハンドラークリーンアップ。メモリリーク。
**実装**: events.zig の jsRemoveEventListener で `JS_StrictEq` を使ってコールバックの同一性を比較。

### Priority 4: mouse/touch イベント拡充

**現状**: `click`のみ。`mousedown`, `mouseup`, `mousemove`, `mouseover`, `mouseout` 未実装。
**影響**: ドラッグ&ドロップ、ホバーエフェクト、インタラクティブUI。
**実装**: main.zig のイベントループで X11 の ButtonPress/Release/MotionNotify を events.zig に委譲。event object に clientX/clientY/button プロパティ追加。

### Priority 5: MutationObserver (簡易版)

**現状**: JS polyfillスタブ（observe/disconnect が no-op）。
**影響**: React, Vue, 多くのフレームワークが使用。lazy loading。
**実装**:
- observer_list にコールバック+targetNode+options を保存
- dom_dirty 設定時に pending mutations を記録
- tickTimers 後に pending observers を fire
- 最低限: childList + attributes のみ

### Priority 6: location.assign() / history.pushState()

**現状**: no-op スタブ。
**影響**: SPA ルーティング（React Router, Vue Router）。ページ遷移。
**実装**:
- location.assign(url): main.zig にナビゲーション要求フラグを渡す
- history.pushState(): URL表示だけ更新、実際のナビゲーションなし
- popstate イベント: history.back() で発火

### Priority 7: XMLHttpRequest (最低限)

**現状**: 全メソッドが no-op スタブ。
**影響**: jQuery $.ajax()、レガシーWebアプリ。
**実装**:
- open(method, url) でmethod/url保存
- setRequestHeader(name, value) でheaders蓄積
- send(body) で同期HTTP fetch実行
- onreadystatechange / onload コールバック発火
- responseText / status / readyState プロパティ

### Priority 8: window.innerWidth/innerHeight 動的更新

**現状**: ハードコード 800x600。
**影響**: レスポンシブデザイン、CSS media queries。
**実装**: web_api.zig の setViewportSize が既にあるので、jsGetInnerWidth/Height でviewport_width/heightを返すだけ。

### Priority 9: document.activeElement

**現状**: 未実装。
**影響**: フォーカス管理、アクセシビリティ。
**実装**: グローバルにfocused_nodeポインタを保持、focus/blur イベント発火時に更新。

### Priority 10: scrollTo() / scrollBy() / scrollTop 連携

**現状**: no-op。scrollTopは常に0。
**影響**: スムーススクロール、infinite scroll、anchor navigation。
**実装**: main.zig の scroll_y 変数を dom_api からアクセス可能にする。

## テスト方法

```bash
# Xephyr + Firefox headless 比較
cd ~/suzume/tests/wpt

# HTTP server起動
python3 -m http.server 8765 &

# Xephyr
Xephyr :99 -screen 800x2000 -ac &>/dev/null &

# suzume
DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=2000 ~/suzume/zig-out/bin/suzume "http://localhost:8765/PATH.html" &
sleep 5
DISPLAY=:99 import -window root /tmp/screenshot.png

# ベンチマーク
DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=4000 ~/suzume/zig-out/bin/suzume "http://localhost:8765/benchmark/suzume-capabilities.html"
# ログに SCORE: 82/87 (94%) が出る

# 実サイトテスト
DISPLAY=:99 SUZUME_WIDTH=1024 SUZUME_HEIGHT=1400 ~/suzume/zig-out/bin/suzume "https://news.ycombinator.com/" &
DISPLAY=:99 SUZUME_WIDTH=1024 SUZUME_HEIGHT=1400 ~/suzume/zig-out/bin/suzume "https://old.reddit.com/" &
DISPLAY=:99 SUZUME_WIDTH=1024 SUZUME_HEIGHT=1400 ~/suzume/zig-out/bin/suzume "https://lite.duckduckgo.com/lite/?q=test" &
```

## 既知のバグ

1. **Wikipedia横幅問題**: width=7480px に拡張される。テーブル/inline-block のshrink-to-fit幅計算ミス
2. **flex垂直方向センタリング**: align-items:center でテキストが中央に来ない（pre-layout位置調整の問題）
3. **UTF-8 SyntaxError**: Latin-1フォールバックしてもQuickJS内部でエラーが出るケースあり（大きなminifiedスクリプト）
4. **flex pre-layout性能**: auto幅子要素を2回レイアウトするので大きなページで遅い可能性

## コードベース要約

- `src/js/dom_api.zig` (3600行): DOM API、getComputedStyle、insertAdjacentHTML、node cache、input/form系API
- `src/js/web_api.zig` (1050行): fetch()、timer、console、performance、polyfillスタブ群
- `src/js/events.zig` (460行): addEventListener/removeEventListener、click、keyboard events
- `src/js/runtime.zig` (230行): JsRuntime、eval、UTF-8 sanitize
- `src/css/cascade.zig` (2150行): CSSカスケード、linear-gradient パーサー
- `src/css/properties.zig` (1110行): CSSプロパティパース
- `src/layout/flex.zig` (810行): Flexbox（pre-layout、align-content対応）
- `src/layout/tree.zig` (200行): box tree構築、anonymous block wrap
- `src/layout/block.zig` (1380行): Block + inlineレイアウト
- `src/net/http.zig` (120行): libcurl HTTPクライアント（GET only）
- `src/main.zig` (3700行): エントリポイント、data: URI、イベントループ
- `src/paint/painter.zig` (780行): 描画エンジン（gradient対応）

## テスト資産

- `tests/wpt/benchmark/suzume-capabilities.html`: 87項目ベンチマーク
- `tests/wpt/js/002-events-timers.html`: 10テスト（全パス）
- `tests/wpt/js/004-fetch.html`: 7テスト（全パス）
- `tests/wpt/css/008-gradients.html`: 10テスト（全パス）
