# suzume WPT準拠改修 — 次回セッションプロンプト

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）のCSS/JS/React SPA仕様準拠を改善中。WPTスタイルのvisual regression testをFirefox比較で実施し、差分を修正するサイクルで進めている。

## 今回のセッションで完了したこと (2026-03-20)

### 7コミット分の修正

1. **CSS `background` shorthand**: `rgb()/hsl()` がスペースでトークン分割されるバグ修正。カッコ深度追跡トークナイザー導入
2. **CSS named colors**: 26色→148色（CSS Color Level 4全色）
3. **SUZUME_WIDTH/HEIGHT env var**: WM無し環境でのウィンドウサイズ制御
4. **querySelector複合セレクタ**: descendant(空白), child(>), adjacent(+), general(~) combinator + カンマ区切り対応
5. **element.click() / dispatchEvent()**: W3C準拠（TypeError throw）
6. **JSタイマー即時repaint**: tickTimers後のDOM変更で即座にrepaint。pollEvent timeout=0（タイマーアクティブ時）
7. **flex order**: CSSプロパティ→stable sortで配置順制御
8. **currentcolor**: named_color_tableからsentinel削除、cascadeでstyle.colorに解決
9. **Node.replaceChild()**: W3C準拠実装

### WPTテストスイート

`tests/wpt/` に9テストページ + Firefox参照スクリーンショット + capture.py。
テスト対象: box-model, flexbox, positioning, text, colors, selectors, DOM manipulation, events/timers, SPA routing。

## 次回やるべきこと（優先度順）

### Priority 1: JSタイマーが実際にページ表示に反映されない問題

**症状**: setTimeout/setInterval のコールバックは発火するが、DOM変更後のre-paintが反映されない（events-timersテストで「Waiting...」のまま）。ページロード時のタイマーループ（initPageJs内の100回ループ）で偶然発火するケースのみ動く。

**調査ポイント**:
- メインイベントループのtickTimersは呼ばれている（確認済み）
- pollEvent timeout=0 にしたのでタイマーアクティブ時はブロックしない
- events-timersテストで「Waiting...」のままだったのは **テストHTML内のUTF-8矢印（→）がQuickJSでSyntaxError** を起こしてスクリプト全体が失敗していたため（修正済み）
- 修正後のスクリーンショットが真っ黒だった — re-style後の背景色リセット問題の可能性
- **次回確認**: 修正済みテストHTMLで再テスト。真っ黒問題の調査

### Priority 2: getComputedStyle() 実値返却

**現状**: 空のProxyオブジェクトを返すスタブ実装。
**影響**: Bootstrap, Tailwind, 多くのJSライブラリがレイアウト計算に使用。
**実装方針**:
- `getComputedStyle(element)` で `cascade.zig` の StyleMap から要素のComputedStyleを取得
- CSSプロパティ名→ComputedStyleフィールドのマッピング関数を作成
- 最低限: width, height, display, position, margin-*, padding-*, color, background-color, font-size, font-weight

### Priority 3: insertAdjacentHTML()

**現状**: 未実装。
**影響**: React, jQuery, 多くのフレームワークが使用。
**実装**: 4つのposition（beforebegin, afterbegin, beforeend, afterend）に対応。lexborのフラグメントパーサーを使用。

### Priority 4: align-content (複数行flex)

**現状**: align-items のみ。flex-wrap + align-content の組み合わせが未対応。
**実装**: flex.zig のwrapレイアウトで、各行のcross-axisサイズを計算後にalign-contentで分配。

### Priority 5: HTMLElement.hidden

**現状**: HTML `hidden` 属性はパーサーで認識されるがJSからアクセス不可。
**実装**: element protoにgetter/setterを追加。hidden=true → display:none相当。

### Priority 6: flex shorthand

**現状**: flex-grow, flex-shrink, flex-basis は個別対応だが `flex: 1` のショートハンド未対応。
**実装**: properties.zig の expandFlex() を確認・修正。`flex: 1` = `flex: 1 1 0%` の展開。

### Priority 7: CSS gradients

**現状**: gradient_color_start/end フィールドはあるがパーサー未実装。
**影響**: 多くのサイトのボタン・ヘッダー背景。
**実装**: `linear-gradient(direction, color-stop, ...)` のパースと paint/painter.zig でのピクセル描画。

### Priority 8: CSS transforms (rotate/scale)

**現状**: translate()のみ。
**実装**: 2D変換行列でrotate, scale, skewを実装。painter.zigでの座標変換。

## テスト方法

```bash
# Xephyr + Firefox headless 比較
cd ~/suzume/tests/wpt

# HTTP server起動
python3 -m http.server 8765 &

# Firefox headless スクリーンショット
rm -f /tmp/ff-headless-profile/lock /tmp/ff-headless-profile/.parentlock
MOZ_HEADLESS=1 firefox -profile /tmp/ff-headless-profile --screenshot results/firefox/TEST_NAME.png --window-size=800,2000 "http://localhost:8765/PATH.html"

# suzume スクリーンショット (Xephyr必須)
nohup Xephyr :99 -screen 800x2000 -ac &>/dev/null &
DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=2000 ~/suzume/zig-out/bin/suzume "http://localhost:8765/PATH.html" &
sleep 5
DISPLAY=:99 import -window root results/suzume/TEST_NAME.png

# ビルド注意: zig build のキャッシュが古い場合 touch src/main.zig してから再ビルド
```

## コードベース要約

- `src/css/cascade.zig` (2000行): CSSカスケード、スタイル適用
- `src/css/properties.zig` (1100行): CSSプロパティパース、named colors、shorthand展開
- `src/css/selectors.zig` (830行): CSSセレクタマッチング（cascade用）
- `src/layout/flex.zig` (720行): Flexboxレイアウト（order対応済み）
- `src/layout/block.zig` (1380行): Block + inlineレイアウト
- `src/js/dom_api.zig` (3100行): DOM API (querySelector, classList, style, etc.)
- `src/js/web_api.zig` (870行): Web API (timers, performance, navigator, etc.)
- `src/js/events.zig` (430行): イベントシステム（addEventListener, dispatchEvent, click）
- `src/main.zig` (3400行): エントリポイント、イベントループ、ページ状態管理
- `src/paint/painter.zig` (780行): 描画エンジン

## レビュー方法

```bash
# CodeRabbit CLI
cr review --plain --type committed --base-commit 'HEAD~N'

# 内蔵コードレビュー
# superpowers:code-reviewer agent を使用
```
