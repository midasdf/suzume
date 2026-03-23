# suzume ブラウザ — 次セッションのプロンプト

suzume/CLAUDE.mdを参照して、以下の作業をお願いします。CSS/JS仕様を検索しながら進めてください。

## 1. getComputedStyle クラッシュ修正（最優先）

`src/js/dom_api.zig` の `windowGetComputedStyle` でJS eval（getter定義）がナビゲーション時にクラッシュする。

**状況：**
- getterをJS evalで定義する方式に変更した（Object.definePropertyでcamelCase/kebab-caseプロパティを定義）
- 単一ページでは動作するが、ナビゲーション時にセグフォ
- `getPropertyValue()` 自体は正常動作（inline style優先も実装済み）

**修正方針：**
- evalでのgetter定義をやめて、Zigから直接`JS_SetPropertyStr`でstatic値をセットする方式に戻す
- ただし `getPropertyValue` は live値を返すのでそちらを使うようWPTテスト側で対応するか、static値を返すだけにする
- 或いは、evalのメモリ管理問題（DupValue/FreeValueの不整合）を調査・修正

## 2. WPT pass rate 改善（26.1% → 目標50%+）

WPTインフラは構築済み。実行方法：

```bash
# WPTチェックアウト（初回のみ）
git clone --depth 1 --sparse https://github.com/web-platform-tests/wpt.git /tmp/wpt-checkout
cd /tmp/wpt-checkout && git sparse-checkout set resources/ css/css-box/ css/css-text/ css/css-inline/ css/css-tables/ css/css-sizing/ css/css-position/ css/css-overflow/ css/css-values/ css/css-display/ css/support/

# testharnessreport.jsにsuzume用コールバック追加が必要（前セッションで追加済みなら不要）

# テスト実行
cd ~/suzume && ./tests/wpt/run_wpt.sh css-box
```

**WPT失敗の3パターンと対策：**

| パターン | 原因 | 対策 |
|---------|------|------|
| `-computed` テスト (0/N) | getComputedStyleが値を返さない | → 上記#1の修正後に大量PASS見込み |
| `-invalid` テスト (0/N) | CSS値バリデーション未実装 | → `element.style[prop] = "invalid"` を受け入れてしまう。setterでバリデーション追加 |
| `-valid` テスト (ほぼPASS) | パースは正しい | → 現状維持、calc()シリアライズ順序の修正で+α |

**`-invalid` テスト修正の方針：**
- `element.style` setterで、CSSプロパティに無効な値を設定しようとした時にrejectする
- 例: `element.style.width = "complex"` → widthとして無効なので受け入れない（空文字のまま）
- `src/js/dom_api.zig` の style setter で CSS値バリデーション関数を呼ぶ

## 3. Firefox diff% 改善

現在のbaseline:
- lobste.rs: 0.0% / info.cern.ch: 2.8% / HN: 28.3% / Wikipedia: 23.3% / old.reddit: ~29%

**残りdiff原因（優先度順）：**

1. **FreeTypeヒンティングモード** — Firefoxの `FT_LOAD_TARGET_LIGHT` を検索して一致させる。`src/paint/text.zig` の `FT_Load_Glyph` と `FT_LOAD_RENDER` フラグを確認
2. **CSS `vertical-align` in IFC** — inline要素のベースライン揃え精度。CSS 2.1 §10.8参照
3. **CSS `white-space` collapsing** — inline要素間のスペース折り畳み。CSS Text Module参照

**試行済みだがリグレッションしたもの（再試行しない）：**
- IFC strut（フォント一致前は逆効果）
- FT_Set_Char_Size（ヒンティング差でWikipedia悪化）
- DejaVu Sansデフォルト化（fontconfig環境依存）

## テスト実行方法

```bash
# ビルド
zig build

# CSSユニットテスト
zig build test-css

# Firefox比較テスト（Docker必要、5サイト約10分）
./tests/run-compare.sh "https://news.ycombinator.com" "https://en.wikipedia.org/wiki/Web_browser" "https://lobste.rs" "https://info.cern.ch" "https://old.reddit.com"

# WPTテスト（Xvfb必要）
./tests/wpt/run_wpt.sh css-box
```
