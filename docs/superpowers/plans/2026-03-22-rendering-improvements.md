# suzume レンダリング改善プラン

## コンテキスト

2026-03-22セッションでJS互換性修正（GitHub 2→0 errors）とクラッシュ修正（Lobsters segfault解消）を完了。
次はFirefoxとのビジュアル比較で見つかったレンダリングの差異を改善する。

### 現在のFirefox比較スコア
- HN: 35.7% diff（レイアウト概ね正しい、フォント/スペーシング差）
- Lobsters: 描画OK（クラッシュ解消済み、小さい黒ブロックあり）
- GitHub: 79.3% diff（ヘッダー描画されるがコンテンツ大部分欠落）
- SO: スクショ取得できず（cookie consent問題）

---

## Priority 1: background-size / background-position 実装

**影響**: GitHub（ナビアイコン欠落）、Lobsters（ロゴ/アイコン）
**ファイル**: `src/css/computed.zig`, `src/css/cascade.zig`, `src/paint/painter.zig`

### やること
1. `ComputedStyle`に追加:
   - `background_size: BackgroundSize = .auto` (auto, cover, contain, px, %)
   - `background_position_x: f32 = 0`
   - `background_position_y: f32 = 0`
   - `background_repeat: BackgroundRepeat = .repeat` (repeat, no-repeat, repeat-x, repeat-y)

2. `cascade.zig`でパース:
   - `background-size: contain|cover|100px|50%|auto`
   - `background-position: center|left|right|top|bottom|50% 50%`
   - `background-repeat: no-repeat|repeat-x|repeat-y`
   - `background`ショートハンド内のこれらサブプロパティ

3. `painter.zig`の`paintBox`でbackground-image描画時にサイズ/位置/リピート適用:
   - 現在: `blitImageScaled(surface, x, y, box_w, box_h, ...)` — ボックス全体にストレッチ
   - 修正: background-sizeに従ってソース/デスト計算、positionでオフセット、no-repeatでクリップ

---

## Priority 2: インライン `<svg>` アイコンのサイズ修正

**影響**: GitHub（アイコン全般）、多くのモダンサイト
**ファイル**: `src/layout/tree.zig`, `src/svg/decoder.zig`

### やること
1. SVGの`viewBox`属性からintrinsic寸法を取得（現在は`width`/`height`属性のみ）
2. `viewBox="0 0 16 16"`のようなSVGが正しい16x16で描画されるように
3. CSS `width`/`height` がSVG要素に設定されている場合、そちらを優先

---

## Priority 3: Flexbox wrap レイアウト改善

**影響**: HN（35.7% diff）、GitHub（79.3% diff）
**ファイル**: `src/layout/flex.zig`

### やること
1. `flex-wrap: wrap` 時の `justify-content` 分配を各行に正しく適用
   - 現在: wrap path（L364+）でjustifyロジックが簡略化されてる
   - 修正: 各wrap行内でspace-between/space-around/space-evenly計算
2. `row-gap` / `column-gap` をwrap行間に正しく適用
3. `align-content`（wrap時の行間配置）実装

---

## Priority 4: Grid レイアウト改善

**影響**: GitHub ファイル一覧テーブル
**ファイル**: `src/layout/grid.zig`

### やること
1. `grid-template-columns` の `auto` 値がコンテンツに基づいて正しく計算されるように
2. `display: contents` サポート（ラッパーdivをスキップして子要素をgridに直接配置）
   - `Display` enumに `contents` を追加
   - `tree.zig`でbox生成をスキップし、子要素を親グリッドに配置
3. `fr` ユニットの余剰スペース分配修正

---

## Priority 5: Form要素のCSS尊重

**影響**: HN（ボタン/入力フィールド）
**ファイル**: `src/layout/tree.zig`

### やること
1. ハードコードされたform要素スタイル（L339-390）を条件付きに変更
   - CSSが明示的に設定した場合はCSSを優先
   - CSSが未設定の場合のみデフォルトスタイル適用
2. `ComputedStyle`に `padding_set_by_css`, `border_set_by_css` フラグ追加
   （`color_set_by_css`は既にある — 同パターン）

---

## Priority 6: 画像の正しいアスペクト比

**影響**: 全サイト（アバター、サムネイル）
**ファイル**: `src/layout/tree.zig`, `src/main.zig`

### やること
1. `width`のみ / `height`のみ指定時に、もう片方をアスペクト比から計算
   - 現在: `updateImageDimensions()`で実装済みだが、初回レイアウト時には適用されない
   - 修正: 画像デコード後にレイアウト再計算トリガー
2. `width="auto" height="auto"` の場合、画像本来のサイズを使用

---

## Priority 7: テキストoverflow: ellipsis

**影響**: テーブルセル、ナビ項目のテキスト切り詰め
**ファイル**: `src/layout/block.zig`, `src/css/computed.zig`

### やること
1. `text_overflow: .ellipsis` が設定された要素で:
   - inline text layoutで行幅を超えたら "..." を追加
   - `overflow: hidden` と組み合わせて機能するように

---

## テスト方法

```bash
# Docker内でビルド&テスト
cd ~/suzume
zig build
sg docker -c 'docker build -t suzume-compare -f tests/Dockerfile.compare .'

# JSエラーチェック（regression確認）
sg docker -c 'docker run --rm --entrypoint /app/error-check.sh \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m suzume-compare'

# Firefox比較
sudo rm -rf tests/screenshots/docker-results/*
sg docker -c 'docker run --rm \
  -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m \
  suzume-compare "https://news.ycombinator.com" "https://lobste.rs" \
  "https://github.com/nickel-org/nickel.rs"'

# 安定性テスト（5回連続）
for i in 1 2 3 4 5; do
  echo -n "Run $i: "
  sg docker -c "docker run --rm --entrypoint /bin/bash --shm-size=512m \
    -v /usr/share/fonts:/usr/share/fonts:ro suzume-compare \
    -c 'Xvfb :99 -screen 0 800x600x24 &>/dev/null & sleep 1 && \
    DISPLAY=:99 timeout 12 /app/suzume https://github.com/nickel-org/nickel.rs \
    2>&1 | grep ERROR | wc -l'"
  echo " errors"
done
```

## コードベース要約（更新版）

- `src/js/dom_api.zig` (~5150行): DOM API + **templateGetContent** + **upgradeCustomElement**
- `src/js/web_api.zig` (~1920行): polyfills + **Object.getPrototypeOf安全化** + **customElements upgrade改善**
- `src/css/cascade.zig` (~2320行): CSSカスケード + **background_image_url arena copy**
- `src/css/computed.zig`: ComputedStyle（**background-size/position/repeat追加予定**）
- `src/layout/flex.zig` (~840行): Flexbox（**wrap justify-content改善予定**）
- `src/layout/grid.zig`: Grid（**auto-sizing/display:contents改善予定**）
- `src/layout/block.zig` (~1420行): Block + inline レイアウト
- `src/layout/tree.zig` (~500行): box tree構築（**form要素CSS尊重改善予定**）
- `src/paint/painter.zig` (~700行): 描画（**background-size適用予定**）
- `src/paint/image.zig`: 画像キャッシュ + デコード
- `src/svg/decoder.zig`: SVGデコード（lunasvg）

## Docker権限
```bash
sg docker -c 'docker run ...'
```

## 既知のバグ（更新）

1. ~~**GitHub 2 errors**: 解消済み~~
2. **dev.to 6 errors**: HoneyBadger + Pusher WebSocket依存（WebSocket API実装必要）
3. **Reddit 1 error**: reddit.js内部length参照（タイミング依存）
4. ~~**Lobsters crash**: 解消済み~~
5. **CSS rotate描画未適用**: 値パース済み、painter.zigでの90度刻み適用未実装
6. **CSS @font-face未実装**
7. **Lobsters黒ブロック**: <img>アバター(16x16)のプレースホルダー描画問題
