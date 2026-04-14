# suzume Phase B — CSS 仕様準拠監査

**Date:** 2026-04-15
**Scope:** `src/js/dom_style.zig` + `src/js/dom_selector.zig` + `src/css/*` vs W3C CSS Working Group specs
**Approach:** spec-driven — find violations of CSS specs, not WPT hacks

---

## Executive Summary

1. **animation-duration initial値がバグ** — `"auto"` 返却、仕様は `"0s"` (CSS Animations §3)
2. **outline-style / outline-width / accent-color のinitial値欠落** — 空文字列返却、仕様は各々 `solid` / `medium` / `auto`
3. **text-decoration-color initial hardcoded `rgb(0,0,0)`** — 仕様は `currentcolor` (CSS Text Decoration §3.2)
4. **flex-basis: content 未対応** — `auto` にフォールバック (CSS Flexbox §9.11)
5. **outline-color / caret-color が inline color に即解決** — 仕様は `currentcolor` キーワード保持

---

## HIGH-PRIORITY VIOLATIONS

### 1. animation-duration initial値が `"auto"` (仕様違反)
- **File:** `src/js/dom_style.zig:2392`
- **Spec:** [CSS Animations 1 §3](https://www.w3.org/TR/css-animations-1/#animation-duration-property) — Initial value: `0s`
- **Fix:** 1 line — `"auto"` → `"0s"`
- **Complexity:** S

### 2. outline-style / outline-width / accent-color initial値欠落
- **File:** `src/js/dom_style.zig:2227–2550` (cssInitialValue)
- **Spec:**
  - outline-style: `solid` — [CSS UI 4 §4.1.1](https://www.w3.org/TR/css-ui-4/#outline-style-property)
  - outline-width: `medium` — [CSS UI 4 §4.1.2](https://www.w3.org/TR/css-ui-4/#outline-width-property)
  - accent-color: `auto` — [CSS UI 4 §5](https://www.w3.org/TR/css-ui-4/#accent-color-property)
- **Current:** 落ちて空文字列 `""`
- **Fix:** 3 lines 追加
- **Complexity:** S

### 3. text-decoration-color initial hardcoded rgb(0,0,0)
- **File:** `src/js/dom_style.zig:2277`
- **Spec:** [CSS Text Decoration 3 §3.2](https://www.w3.org/TR/css-text-decor-3/#text-decoration-color-property) — Initial: `currentcolor`
- **Current:** `"rgb(0, 0, 0)"` 固定
- **Fix:** `"currentcolor"` キーワード保持、computedStyleToString時に解決
- **Complexity:** M

### 4. outline-color initial が inline color に即解決
- **File:** `src/js/dom_style.zig:394–396`
- **Spec:** [CSS UI 4 §4.1.3](https://www.w3.org/TR/css-ui-4/#outline-color-property) — Initial: `currentcolor` (computed value as specified)
- **Current:** `argbToCssColor(c, style.color, ...)` で即解決
- **Fix:** `"currentcolor"` キーワード維持
- **Complexity:** M

### 5. caret-color の auto→currentcolor パス欠落
- **File:** `src/js/dom_style.zig:397–398`
- **Spec:** [CSS UI 4 §5.2](https://www.w3.org/TR/css-ui-4/#caret-color-property) — auto の computed は currentcolor
- **Current:** auto を経由せず直接 color に解決
- **Fix:** computed step で "currentcolor" 経由
- **Complexity:** M

### 6. :is() specificity が `b+1` 固定
- **File:** `src/css/selectors.zig:449–452`
- **Spec:** [CSS Selectors 4 §4.2](https://www.w3.org/TR/selectors-4/#specificity-rules) — `:is(...)` = 内側セレクタの最大 specificity
- **Current:** 単純に `specificity.b += 1`
- **Example:** `:is(#id, .class)` 期待 (1,0,0)、実装 (0,1,0)
- **Fix:** 内側再パース + max 比較
- **Complexity:** M

### 7. :has() specificity 同上
- **File:** `src/css/selectors.zig:418–422`
- **Spec:** [CSS Selectors 4 §4.2](https://www.w3.org/TR/selectors-4/#specificity-adjust)
- **Fix:** `:is()` と同じロジック適用
- **Complexity:** M

---

## MEDIUM-PRIORITY VIOLATIONS

### 8. flex-basis: content 未対応
- **File:** `src/css/cascade.zig`
- **Spec:** [CSS Flexbox 1 §9.11](https://www.w3.org/TR/css-flexbox-1/#flex-basis-property)
- **Current:** `content` キーワードを拒否→`auto`
- **Fix:** パーサーに追加 + flex item intrinsic sizing
- **Complexity:** M
- **Impact:** css-flexbox WPTスコア向上寄与

### 9. CSSOM: CSSStyleDeclaration.setProperty/removeProperty !important 未対応
- **File:** `src/js/dom_style.zig:3165` 付近
- **Spec:** [CSSOM §4.1](https://drafts.csswg.org/cssom/#the-cssstyledeclaration-interface)
- **Current:** `style.cssText` 文字列操作のみ
- **Fix:** ネイティブ `setProperty(name, value, priority)` + property map + !important フラグ保持
- **Complexity:** M (~100 lines)

### 10. grid-template shorthand 展開不足
- **File:** `src/css/properties.zig`
- **Spec:** [CSS Grid 2 §8.5](https://www.w3.org/TR/css-grid-2/#propdef-grid-template)
- **Current:** ショートハンド受理、ロングハンド展開なし
- **Complexity:** M

### 11. border-collapse computed値フォールスルー
- **File:** `src/js/dom_style.zig:2562` 付近
- **Spec:** [CSS Tables 3 §3.1](https://www.w3.org/TR/css-tables-3/#border-collapse-property)
- **Fix:** getComputedStyle プロパティ一覧に追加
- **Complexity:** S

---

## LOW-PRIORITY / COSMETIC

### 12. color() 関数 serialization検証 — `dom_style.zig:1247`
### 13. Logical properties writing-mode 未考慮 — `dom_style.zig:2300`
### 14. mask-* プロパティパース済み未レンダリング — `dom_style.zig:2425`

---

## DEFERRED / OUT-OF-SCOPE

| 機能 | 理由 | 影響 |
|------|------|------|
| `@container` Container Queries | layout engine統合必須 | css-contain |
| Subgrid | grid line inheritance複雑 | css-grid +10-15% |
| CSS Masking rendering | rasterマスク必要 | N/A |
| CSS Animations rendering | アニメーションループ必要 | css-animations |
| @layer cascade origin | cascade priority レベル追加 | css-cascade |

---

## RECOMMENDED FIX ORDER

### Wave 1 — Quick wins (~10 min)
1. animation-duration `"auto"` → `"0s"` (S)
2. outline-style initial `solid` 追加 (S)
3. outline-width initial `medium` 追加 (S)
4. accent-color initial `auto` 追加 (S)
5. border-collapse computed listing 追加 (S)

### Wave 2 — Spec keyword保持 (~半日)
6. text-decoration-color → `currentcolor` 保持 (M)
7. outline-color → `currentcolor` 保持 (M)
8. caret-color → auto→currentcolor パス (M)

### Wave 3 — Selector specificity正しく (~半日)
9. `:is()` max-specificity 計算 (M)
10. `:has()` 同上 (M)

### Wave 4 — Flex/CSSOM機能追加
11. flex-basis: content 対応 (M)
12. CSSStyleDeclaration.setProperty !important 対応 (M)

### Deferred — 別フェーズ
- Container Queries, Subgrid, Masking rendering, Animations runtime, @layer

---

## CONCLUSION

CSS基盤スコアは既に高水準（css-box 97.4%, selectors 85.3%）。残る仕様違反は新しめの仕様（CSS UI 4, CSSOM L1, Selectors L4）のエッジケースが中心。Wave 1 の安い5つで初期値系を潰し、Wave 2-3 で keyword 保持とspecificity正規化、Wave 4 で機能追加。Container Queries/Subgrid 等は大型なので別フェーズ。
