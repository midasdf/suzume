# suzume レンダリング品質改善セッション — プロンプト

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）のレンダリング品質を改善するセッション。ベンチマーク111/111 (100%)、DOM API 74/74 (100%)、QuickJS ES 62/62 (100%) 達成済み。16サイト中11がJSエラーゼロ。

## 現在の実サイト表示状況

| サイト | JS Errors | 表示品質 | 主な問題 |
|--------|-----------|---------|---------|
| Hacker News | 0 | ◎ | 投票矢印(▲)非表示（CSS background-image） |
| Old Reddit | 0 | ○ | レイアウト粗い |
| Wikipedia | 0 | ◎ | テーブル+画像+infobox良好 |
| CNN Lite | 0 | ◎ | ほぼ完璧 |
| DDG Lite | 0 | ◎ | 検索+結果完璧 |
| GitHub | 1 | △ | ファイルツリー表示、React "Uh oh" エラー |
| Brave Search | 1 | ○ | 検索結果表示されるがレイアウト崩れ |
| BBC News | 1 | ○ | ナビ+記事表示、レイアウト荒い |
| StackOverflow | 6 | ✗ | メインコンテンツ見えない（白い空間） |
| dev.to | 6 | △ | Preact初期化失敗 |

## やること（優先度順）

### Priority 1: CSS background-image url() レンダリング

**現状**: `background-image: url(...)` が完全に無視されてる。
**影響**: HNの投票矢印、サイトのロゴ、アイコン、ヒーロー画像。多くのサイトで見た目が欠ける。
**実装**:
- cascade.zigでbackground-imageプロパティをパース（url()抽出）
- painter.zigで背景画像をstb_imageでデコードしてレンダリング
- background-size: cover/contain/auto、background-position対応
- 既存の画像ロード基盤（loader.zig）を再利用

### Priority 2: StackOverflow 表示修正

**現状**: メインコンテンツ領域が白い空間（テキストは存在するが見えない）。
**原因候補**:
1. CSSの巨大ファイル（830KB stacks.css）のパース不完全
2. CSS変数チェーン解決の問題（`var(--a, var(--b, var(--c)))`）
3. `display: flex`のlayout問題でコンテンツ高さが0
4. `overflow: hidden`でコンテンツがクリップされてる
**デバッグ方法**: SOのHTMLを保存してローカルで開く。CSSを段階的に削減して原因特定。

### Priority 3: Flexbox垂直センタリング改善

**現状**: `align-items: center` でテキストが完全に中央に来ない場合がある。
**影響**: ボタン内テキスト、ナビゲーションバー、カード内レイアウト。
**修正**: flex.zigのcross axis positioning。

### Priority 4: CSS position:sticky

**現状**: `position: sticky` が完全に無視される（static扱い）。
**影響**: サイトのナビゲーションバーがスクロールで消える。
**実装**: レイアウト時にsticky要素のoffsetTopを記録し、描画時にスクロール位置に応じてY座標を調整。

### Priority 5: GitHub/dev.to JS エラー修正

**GitHub**: Webpack chunk URL解析で`toUpperCase of undefined`。`document.currentScript.src`のURL形式問題。
**dev.to**: Preactの初期化で`__hb_original`(Honeybadger)、`ready` setter失敗。JSフレームワーク内部の問題。

### Priority 6: 表示品質の体系的テスト

Firefoxとの比較スクリーンショットを全サイトで撮って、差異リストを作成して1つずつ修正。

## テスト方法

```bash
# Xvfb起動（ヘッドレス、画面占有なし）
Xvfb :50 -screen 0 1024x1400x24 &

# HTTP server
python3 -m http.server 8765 &

# suzumeスクリーンショット
DISPLAY=:50 SUZUME_WIDTH=1024 SUZUME_HEIGHT=1400 timeout 20 ./zig-out/bin/suzume "$URL" &
sleep 12
WIN_ID=$(DISPLAY=:50 xdotool search --name "" 2>/dev/null | head -1)
DISPLAY=:50 import -window "$WIN_ID" /tmp/screenshot.png

# Firefox比較
firefox --headless --screenshot /tmp/ff-screenshot.png --window-size=1024,1400 "$URL"

# JSエラーカウント
DISPLAY=:50 timeout 20 ./zig-out/bin/suzume "$URL" 2>&1 | grep -c "\[JS:ERROR\]"

# ベンチマーク
DISPLAY=:50 SUZUME_WIDTH=800 SUZUME_HEIGHT=6000 timeout 20 ./zig-out/bin/suzume "http://localhost:8765/tests/wpt/benchmark/suzume-capabilities.html" 2>&1 | grep "SCORE:"
```

## コードベース要約

- `src/js/dom_api.zig` (4500行): DOM API全般、getContext、フォーム要素
- `src/js/web_api.zig` (1700行): fetch、timer、polyfillスタブ群
- `src/js/events.zig` (500行): イベントシステム
- `src/js/runtime.zig` (350行): QuickJS eval、UTF-8サニタイズ、モジュールローダー
- `src/js/canvas.zig`: Canvas 2D ソフトウェアレンダラー
- `src/js/worker.zig`: Web Worker スレッド管理
- `src/css/cascade.zig` (2200行): CSSカスケード、UA stylesheet
- `src/css/properties.zig` (1100行): CSSプロパティパース
- `src/css/media.zig`: メディアクエリ（prefers-color-scheme: light）
- `src/layout/flex.zig` (810行): Flexbox（shrink-to-fit対応）
- `src/layout/block.zig` (1400行): Block + inlineレイアウト
- `src/layout/tree.zig`: box tree構築、select/checkbox描画
- `src/net/http.zig`: libcurl HTTPクライアント（cookie、POST対応）
- `src/net/websocket.zig`: WebSocket（curl ws API）
- `src/paint/painter.zig` (800行): 描画エンジン（gradient対応）
- `src/features/adblock.zig`: tracking/recaptchaスクリプトブロック

## 既知のバグ

1. ~~**Wikipedia横幅問題**~~: 修正済み（contentWidth改善）
2. **flex垂直方向センタリング**: align-items:center でテキストが微妙にずれる場合あり
3. ~~**UTF-8 SyntaxError**~~: 修正済み（QuickJS-ngパッチ + null-terminated buffer）
4. ~~**flex pre-layout性能**~~: shrink-to-fit修正で改善

## コミットルール
- CodeRabbit CLIでローカルレビュー（PR webhookレビューは非効率）
- コミットメッセージに `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>`
