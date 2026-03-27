# suzume 次フェーズ — 残りJSエラー解消 + レンダリング改善

## コンテキスト

suzumeブラウザ（Zig製カスタムブラウザエンジン、RPi Zero 2W向け）の前セッション引き継ぎ。

### 前セッションで実装済み

**Priority 1: 動的スクリプト実行**
- `elementAppendChild`/`elementInsertBefore`で`<script>`タグ検出→HTTP fetch→eval
- `onload`/`onerror`コールバック発火、`document.currentScript`設定
- 重複実行防止（URLハッシュマップ）、ES Module対応
- GitHubのWebpack chunk loading動作確認済み

**Priority 2: CSS :hover / :focus**
- `selectors.zig`: VTableに`isHovered`/`isFocused`追加
- `cascade.zig`: DOM vtable実装（hoverは祖先チェーン含む）
- `dom_api.zig`: `hovered_element`グローバル追加
- `main.zig`: マウスムーブでhover状態更新→再描画トリガー

**Priority 3: CSS transform scale/rotate**
- `computed.zig`: `transform_scale_x/y`, `transform_rotate_deg`追加
- `cascade.zig`: `parseTransform`拡張（scale/scaleX/scaleY/rotate、deg/rad/turn/grad対応）
- `block.zig`: レイアウト時にscale適用（中心基点）
- rotateは値パース済み（描画適用は将来課題）

**Priority 5: CSS :nth-child / :not()**
- `parseAnB()`: `2n+1`, `odd`, `even`, `-n+3`等のan+b式パース
- `:nth-child()`, `:nth-last-child()`, `:nth-of-type()` — position計算+an+b一致判定
- `:not()` — クラス/ID/属性/タグ/擬似クラスの否定マッチング

**GitHub互換性改善**
- `Node.getRootNode()` — 親をたどってdocument返却
- `Node.ownerDocument` — getter（グローバルdocument返却）
- `Node.isConnected` — rootがdocumentかチェック
- `Element.attachShadow()` — stub（querySelector等をコピーしたpseudoオブジェクト）
- `Element.shadowRoot` — デフォルトnull
- `Element.showPopover/hidePopover/togglePopover` — stub
- `Element.insertAdjacentElement()` — 全4ポジション対応
- `document.createElementNS()` — namespace無視でcreateElement動作
- `document.adoptedStyleSheets` — 空配列
- `Document.prototype` — querySelector/querySelectorAll等のDOMメソッド追加
- `DocumentFragment.prototype` — querySelector/querySelectorAll追加
- `ShadowRoot` — グローバルコンストラクタ
- `CSSStyleSheet` — constructor + replaceSync/replace stub
- `CSSLayerBlockRule` — グローバルコンストラクタstub
- `customElements.define` — コンストラクタ登録+upgrade+connectedCallback
- `Object.defineProperty` — `not configurable`エラーの安全ハンドリング
- deferred/dynamic script — source URL付きeval（`evalNamed`）でスタックトレース改善
- `document.currentScript.hasAttribute` — stub追加

### 現在のスコア・互換性（2026-03-22 更新）
- **ベンチマーク**: 111/111 (100%)
- **QuickJS ES**: 62/62 (ES2024 full)
- **DOM API**: 74/74 (100%)
- HN: ✅ 0 errors
- Lobsters: ✅ 0 errors（**クラッシュ解消済み**）
- Reddit: ❌ 1 error（reddit.js内部のlength参照、タイミング依存）
- GitHub: ✅ 0 errors（**2→0、安定**）
- dev.to: ❌ 6 errors（HoneyBadger/Pusher WebSocket依存）
- SO: ✅ 0 errors（安定化）

---

## 完了: GitHubエラー修正（2026-03-22）

### 修正内容
1. `<template>.content` ゲッター実装 → appendChild of undefined 解消
2. `createElement`カスタム要素upgrade（Zig側）→ prototype properties正しくコピー
3. `Object.getPrototypeOf`安全化 → not an object 解消
4. `upgradeEl`改善 → getters/settersをdefinePropertyで正しくコピー
5. Image cache segfault修正 → background_image_url arena copy

### 次フェーズ
→ `docs/superpowers/plans/2026-03-22-rendering-improvements.md` を参照

---

## 参考: 元のGitHubエラー分析

### GitHub エラー1: `appendChild of undefined`

**ファイル**: `github-elements-b6b27a04749574ff.js` module 240721
**スタック**: module 240721 → require(872705) → Turbo module (26533チャンク)
**原因**: Turbo frameworkの`em.start()`（Session.start）内でDOM操作。何かのelement.parentNodeまたはcontainer elementがundefined。

**調査方針**:
1. Turboの26533チャンク内の`em=new class{...}` Sessionクラスを読む
2. `start()`メソッドの中身を特定（minified）
3. `appendChild`を呼ぶ箇所を見つける（ProgressBar, Scroll管理等）
4. 足りないDOM API or elementを特定

**可能性高い原因**:
- Turbo ProgressBarが`document.querySelector("turbo-progress-bar")`を使ってundefined
- `document.documentElement.insertBefore`呼び出しで何かがundefined
- `<head>`内に`<meta name="turbo-*">`がなくてnull chain

### GitHub エラー2: `not an object` at getPrototypeOf

**ファイル**: `behaviors-8f0bad3ae754e9cb.js` module 333791
**スタック**: behaviors → require chain → 何かのsubmodule
**原因**: `Object.getPrototypeOf`にnon-objectが渡された

**調査方針**:
1. behaviorsチャンクをダウンロードして分析
2. module 333791内のrequire chain（n(99020), n(551589)等）を追跡
3. `getPrototypeOf`を呼ぶコードを見つける
4. customElements upgradeのproto walkが原因かチェック

**可能性高い原因**:
- Web ComponentのClass extends HTMLElement で、protoチェーンが不正
- Object.getPrototypeOfのpolyfill不足
- customElements.defineのupgradeElで設定されたproperty descriptorの問題

### 共通アプローチ

`evalNamed`による改善で、エラーのsource URLが正確にスタックトレースに出るようになった。各チャンクファイルをダウンロードして、minifiedコードの特定position周辺を読み、undefinedになるオブジェクトを特定すること。

```bash
# チャンクファイルダウンロード
curl -sL 'https://github.githubassets.com/assets/26533-3b7304f75d999c48.js' -o /tmp/gh_26533.js
curl -sL 'https://github.githubassets.com/assets/behaviors-8f0bad3ae754e9cb.js' -o /tmp/gh_behaviors.js

# 特定positionのコード確認
awk 'NR==LINE' /tmp/file.js | cut -cSTART-END
```

---

## テスト方法

```bash
# Docker内でJSエラーチェック
cd ~/suzume
zig build
sg docker -c 'docker build -t suzume-compare -f tests/Dockerfile.compare .'

# JSエラーカウント（6サイト）
sg docker -c 'docker run --rm --entrypoint /app/error-check.sh \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m suzume-compare'

# 単体サイトテスト（詳細スタックトレース付き）
sg docker -c 'docker run --rm --entrypoint /bin/bash --shm-size=512m \
  -v /usr/share/fonts:/usr/share/fonts:ro suzume-compare \
  -c "Xvfb :99 -screen 0 800x600x24 &>/dev/null & sleep 1 && \
  DISPLAY=:99 timeout 12 /app/suzume https://github.com/nickel-org/nickel.rs \
  2>&1 | grep -E \"ERROR|STACK\""'

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

# Firefox比較テスト
sg docker -c 'docker run --rm \
  -v $(pwd)/tests/screenshots/docker-results:/app/results \
  -v /usr/share/fonts:/usr/share/fonts:ro --shm-size=512m \
  suzume-compare "https://news.ycombinator.com" "https://lobste.rs"'
```

**注意**: テストは必ずDockerコンテナ内で実行すること。ホストでsuzumeを起動するとウィンドウが画面に表示されて作業を妨げる。

---

## コードベース要約（更新版）

- `src/js/dom_api.zig` (~5100行): DOM API、forms、canvas、MutationObserver、querySelector、**動的スクリプト実行**、**getRootNode/ownerDocument/isConnected**、**attachShadow stub**、**createElementNS**
- `src/js/web_api.zig` (~1900行): fetch()、timer、XHR polyfill、MutationObserver登録、history、**customElements.define polyfill**、**CSSStyleSheet stub**、**Object.definePropertyパッチ**
- `src/js/events.zig` (~760行): addEventListener、mouse events、MutationObserver registry/flush
- `src/js/runtime.zig` (~370行): JsRuntime、eval、**evalNamed**、UTF-8、module loader
- `src/css/cascade.zig` (~2300行): CSSカスケード、gradient、extractUrl、background-image、**parseTransform拡張（scale/rotate）**、**domIsHovered/domIsFocused**
- `src/css/properties.zig` (~1150行): CSSプロパティパース、shorthand展開
- `src/css/selectors.zig` (~1000行): セレクタマッチング、specificity、**:nth-child(an+b)**、**:not()**、**:hover/:focus**、**PseudoClassSel構造体**
- `src/css/computed.zig`: ComputedStyle、**transform_scale_x/y, transform_rotate_deg**
- `src/layout/flex.zig` (~840行): Flexbox（align-self対応）
- `src/layout/block.zig` (~1420行): Block + inline レイアウト、**scale transform適用**
- `src/layout/tree.zig` (~500行): box tree構築、inline SVG
- `src/paint/painter.zig` (~700行): 描画、background-image、position:sticky
- `src/svg/decoder.zig`: SVGデコード（lunasvg C wrapper経由）
- `src/main.zig` (~3850行): エントリポイント、スクリプト実行、イベントループ、**hover状態管理**、**evalNamed使用**

## Docker権限
```bash
# ユーザーがdockerグループに入っていない場合
sg docker -c 'docker run ...'
```

## 既知のバグ

1. **GitHub 2 errors**: Turbo framework appendChild + behaviors getPrototypeOf（上記参照）
2. **dev.to 6 errors**: HoneyBadger.js + Pusher WebSocket依存。WebSocket APIの完全実装が必要
3. **Reddit 1 error**: reddit.js内部のlength参照。タイミング依存で0になることもある
4. **SO 0-1 errors**: CookieLaw (OneTrust) 外部スクリプト。タイミング依存
5. **CSS rotate描画未適用**: 値はパース・保存済みだがpainter.zigでの適用は未実装（90度刻みが目標）
6. **CSS @font-face未実装**: Priority 4は未着手
