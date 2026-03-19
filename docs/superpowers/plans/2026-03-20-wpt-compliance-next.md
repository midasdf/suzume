# suzume WPT準拠改修 — 次回セッションプロンプト

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）のCSS/JS/React SPA仕様準拠を改善中。WPTスタイルのvisual regression testをFirefox比較で実施し、差分を修正するサイクルで進めている。

## 今回のセッションで完了したこと (2026-03-20, セッション2-3)

### セッション2: Priority 1-5 修正
1. **タイマーcrash修正**: `clearInterval`がコールバック実行中に呼ばれるとsegfault → `JS_DupValue`で保護
2. **element.click()/dispatchEvent修復**: `injectElementEventMethods`未呼び出し → 追加
3. **rAF timestamp**: `requestAnimationFrame`コールバックにDOMHighResTimeStampを渡す
4. **getComputedStyle()**: cascade StyleMapから実ComputedStyleを返す実装（30+プロパティ）
5. **insertAdjacentHTML()**: 4 position全対応
6. **align-content**: CSS parse + cascade + flexレイアウト全実装（7値）
7. **HTMLElement.hidden**: getter/setter
8. **ノードidentity保持**: node→JSValueキャッシュ（`===`比較が正常に動作）

### セッション3: インフラ + CSS gradient
9. **大きなスクリプト実行制限緩和**: 100KB→512KB（Acid3の173KBスクリプト実行可能に）
10. **data: URIスキーム対応**: `<script src="data:...">` のURL-encoded/base64両対応
11. **CSS linear-gradient()パース+描画**: 方向キーワード、角度、rgb()/hex/named color全対応
12. **background shorthandのgradient認識**: `linear-gradient()`をbackground-imageとして展開
13. **stripColorStop修正**: rgb()関数内の数字を色ストップ位置と誤認する問題を修正

### テスト結果
- **自作ベンチマーク**: 82/87 (94%) — DOM Core/CSS/Events/Timers/ES6+全カテゴリ100%
- **events-timersテスト**: 10/10 全パス
- **gradientテスト**: 10/10 全パス（全方向、角度、rgb()、ボタン、ヘッダー）
- **Example.com**: 完璧に表示
- **Wikipedia**: コンテンツ読める（横幅問題あり）
- **Acid3**: data: URI 4/5成功、メインスクリプト実行可能に

## 次回やるべきこと（優先度順）

### Priority 1: Wikipedia横幅問題（width=3008px）

**症状**: Wikipediaのページレイアウトが横幅3008pxに広がる（ビューポートは1024px）
**原因候補**:
- テーブルレイアウトがshrink-to-fit幅を超えて拡張
- `max-width`が特定のコンテキストで効かない
- floatレイアウトのcontaining block幅計算ミス
- Wikipediaの`vector-2022`スキンの複雑なCSS
**調査方法**: デバッグ出力でどの要素が3008pxの幅を持ってるか特定

### Priority 2: flexbox内テキストセンタリング

**症状**: `display:flex; align-items:center; justify-content:center`でテキストが中央に来ない
**原因**: flex子要素がテキストノードの場合、anonymous block boxが生成されない可能性
**確認**: gradient testのbox内テキストが左上寄せになっている

### Priority 3: CSS transforms (rotate/scale)

**現状**: translate()のみ
**実装**: 2D変換行列でrotate, scale, skewを実装。painter.zigでの座標変換

### Priority 4: fetch() API

**影響**: React SPA、多くの現代的サイトが使用
**実装**: QuickJSのPromise + httpxで非同期HTTP fetch

### Priority 5: HTMLCanvasElement (2D Context)

**影響**: グラフ、チャート、ゲーム、多くのライブラリ
**実装**: nsfb surface上で直接描画。最低限: fillRect, strokeRect, fillText, beginPath, arc, fill

### Priority 6: テーブルレイアウト改善

**現状**: 基本的なtable-row/table-cellレイアウトはあるが、auto width計算が不正確
**影響**: Wikipedia、多くのドキュメントサイト

### Priority 7: MutationObserver

**影響**: React、Vue等のフレームワーク、多くのライブラリ
**実装**: dom_dirty時にobserverコールバックを発火

### Priority 8: XMLHttpRequest

**影響**: jQueryベースのサイト、レガシーWebアプリ
**実装**: fetch()と同じHTTPクライアントをXHR APIで包む

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
Xephyr :99 -screen 800x2000 -ac &>/dev/null &
DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=2000 ~/suzume/zig-out/bin/suzume "http://localhost:8765/PATH.html" &
sleep 5
DISPLAY=:99 import -window root results/suzume/TEST_NAME.png

# ベンチマーク
DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=4000 ~/suzume/zig-out/bin/suzume "http://localhost:8765/benchmark/suzume-capabilities.html"
# ログに SCORE: 82/87 (94%) が出る

# ビルド注意: zig build のキャッシュが古い場合 touch src/main.zig してから再ビルド
```

## コードベース要約

- `src/css/cascade.zig` (2150行): CSSカスケード、スタイル適用、linear-gradient パーサー
- `src/css/properties.zig` (1110行): CSSプロパティパース、named colors、shorthand展開
- `src/css/computed.zig` (420行): ComputedStyle構造体（align-content追加済み）
- `src/css/selectors.zig` (830行): CSSセレクタマッチング
- `src/layout/flex.zig` (790行): Flexboxレイアウト（align-content対応済み）
- `src/layout/block.zig` (1380行): Block + inlineレイアウト
- `src/js/dom_api.zig` (3600行): DOM API (getComputedStyle, insertAdjacentHTML, hidden, node cache)
- `src/js/web_api.zig` (870行): Web API (timers with rAF timestamp)
- `src/js/events.zig` (460行): イベントシステム（element prototype injection修正済み）
- `src/main.zig` (3600行): エントリポイント、data: URI、parseDataUri
- `src/paint/painter.zig` (780行): 描画エンジン（gradient描画済み）
- `tests/wpt/benchmark/suzume-capabilities.html`: 87項目ベンチマーク

## 外部テストサイト参考

| サイト | 用途 | suzume対応状況 |
|--------|------|----------------|
| Example.com | 最小HTML | ✅ 完璧 |
| Wikipedia | セマンティックHTML | ⚠️ 読める、横幅問題 |
| Acid3 | DOM/CSS/JS | ⚠️ フレーム表示、SVG等未対応でスコアなし |
| HTML5test | HTML5機能 | ❌ JS重すぎ |
| CSS3 Test | CSS3対応 | 未テスト |
| Google Search | 高度なJS | 未テスト |
