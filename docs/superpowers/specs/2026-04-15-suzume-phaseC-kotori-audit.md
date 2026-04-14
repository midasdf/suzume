# suzume Phase C — kotori JS エンジン ECMAScript 2023 準拠監査

**Date:** 2026-04-15
**Scope:** `src/js/kotori/*` + `kotori_runtime.zig` + `kotori_dom.zig` vs [tc39.es/ecma262](https://tc39.es/ecma262/)
**Current status:** 622 tests pass, 13.6K LOC, ES2023 ほぼフルカバー

---

## Executive Summary

18件の仕様違反を検出。重大度内訳: HIGH 7件 / MEDIUM 7件 / LOW 4件。主要パターン:
1. **Object.freeze/seal/preventExtensions がパススルー** — 凍結がノーオペ
2. **Promise.finally 仕様逸脱** — 両ハンドラに同じコールバック渡す
3. **Array.includes/indexOf が strict equality 使用** — 仕様は SameValueZero (NaN比較で差)
4. **Object.defineProperty が descriptor 無視** — getter即時実行、writable/enumerable/configurable保存なし
5. **Array callbacks が thisArg 無視**
6. **String.normalize がスタブ** — NFC 未実装
7. **Promise resolve が thenable 検出なし** — Promise 以外の `.then` メソッド持つ値を解決できない

---

## HIGH-PRIORITY VIOLATIONS

### 1. Object.freeze / Object.seal / Object.preventExtensions スタブ
- **File:** `vm.zig:2072-2074`, `nativeObjectPassthrough` at `vm.zig:4119-4121`
- **Spec:** ES2023 §20.1.2.3–5
- **Current:** 引数をそのまま返す（no-op）。`isFrozen`/`isSealed` 常に false、`isExtensible` 常に true
- **Fix:** JsObjectに extensible フラグ + descriptor 保存
- **Complexity:** M (3日)

### 2. Promise.finally 仕様逸脱
- **File:** `vm.zig:3768-3771`
- **Spec:** ES2023 §25.4.5.4
- **Current:** `then(cb, cb)` に委譲 — rejection時にコールバック結果で resolve してしまう
- **Fix:** finally 用中間 Promise を作ってラップ
- **Complexity:** M (1日)

### 3. Array.includes / indexOf が strict equality 使用
- **File:** `vm.zig:2688-2696`, 2677-2686
- **Spec:** ES2023 §23.1.3.11/.12 — SameValueZero (NaN===NaNをtrue扱い)
- **Current:** `jsStrictEq` — `[NaN].includes(NaN)` が false
- **Complexity:** S (SameValueZero述語追加)

### 4. Object.defineProperty descriptor 無視
- **File:** `vm.zig:4038-4062`
- **Spec:** ES2023 §20.1.2.4
- **Current:** getter を即実行して結果を保存、writable/enumerable/configurable ignored
- **Fix:** accessor vs data property 分離、属性保存
- **Complexity:** M (2日)

### 5. String.normalize スタブ
- **File:** `vm.zig:4208-4210`
- **Spec:** ES2023 §22.1.3.12
- **Current:** `return this;` — NFC/NFD/NFKC/NFKD未実装
- **Complexity:** L (Unicode正規化テーブル必要、1-3日)

### 6. Array callbacks が thisArg 無視
- **File:** `vm.zig:3022-3197` (forEach, map, filter, reduce, find*, some, every 全部)
- **Spec:** ES2023 §23.1.3.1, .19, .7, .20 等
- **Current:** `args[1]` の thisArg を無視、常に undefined
- **Complexity:** S-M (パターン統一、2日)

### 7. getOwnPropertyDescriptor 全フラグ true
- **File:** `vm.zig:4100-4117`
- **Spec:** ES2023 §20.1.2.9
- **Current:** writable/enumerable/configurable 常に true
- **Root cause:** プロパティ属性ストレージなし
- **Complexity:** M (2日)

---

## MEDIUM-PRIORITY VIOLATIONS

### 8. Object.keys / getOwnPropertyNames 同一視
- **File:** `vm.zig:2070` — 両方 `nativeObjectKeys` に委譲
- **Spec:** §20.1.2.16 (keys: enumerable only) / §20.1.2.11 (getOwnPropertyNames: 全部)

### 9. Object.create 第2引数 propertiesObject 無視
- **File:** `vm.zig:4029-4036`

### 10. Proxy trap invariant 検証なし
- **File:** `vm.zig:8183-8200`
- **Spec:** ES2023 §28.2.1.1 — non-configurable/non-writable プロパティで SameValue チェック

### 11. Promise resolve が thenable 検出なし
- **File:** `vm.zig:3521-3573`
- **Spec:** ES2023 §25.4.1.3.2 step 8 — `.then` メソッド持つオブジェクトを thenable として扱う

### 12. propertyIsEnumerable / isPrototypeOf スタブ
- **File:** `vm.zig:2056-2057` — `nativeReturnTrue` / `nativeReturnFalse`

### 13. Number.prototype.toFixed / toPrecision / toExponential が clamp する
- **File:** `vm.zig:7470-7584`
- **Spec:** §21.1.3.2-.4 — RangeError throw すべき、silent clamp は違反

### 14. Abstract equality string→number で whitespace trim 不完全
- **File:** `vm.zig:6429-6461`
- **Spec:** §7.1.3.1 — form feed / vertical tab / Unicode separator 未対応

---

## LOW-PRIORITY / COSMETIC

15. NaN-boxing の NaN canonicalize — 一部算術で非正準 NaN が残る可能性 (value.zig)
16. Object.is は bit comparison だが NaN-boxing 前提で実は正しい (false alarm)
17. Generator yield* delegation の return/throw propagation エッジケース (vm.zig:1454)
18. Array.concat の穴（holes）保持確認必要

---

## DEFERRED / OUT-OF-SCOPE

- **Full Proxy** — construct/apply/getPrototypeOf/setPrototypeOf/keys trap 未実装
- **SharedArrayBuffer / Atomics** — 非対応宣言済み
- **BigInt** — 非実装
- **Tail Call Optimization** — 非対応
- **Intl** — 別仕様

---

## RECOMMENDED FIX ORDER

### Wave 1 — 低リスク即効性 (2-3日)
1. Array.includes/indexOf → SameValueZero (S)
2. Array callbacks thisArg 対応 (S-M)
3. Promise.finally セマンティクス修正 (M)
4. Number.prototype.toFixed 等 RangeError throw (S)
5. parseInt whitespace 完全化 (S)

### Wave 2 — Descriptor インフラ (1週間)
6. JsObject に descriptor ストレージ追加 (writable/enumerable/configurable)
7. Object.defineProperty 完全実装
8. Object.freeze/seal/preventExtensions + isFrozen/isSealed/isExtensible
9. getOwnPropertyDescriptor 実属性返却
10. propertyIsEnumerable / isPrototypeOf 実装

### Wave 3 — Unicode / Promise (数日)
11. String.normalize NFC (外部テーブル要)
12. Promise resolve thenable 検出
13. Proxy invariant 検証

---

## CONCLUSION

kotori はアーキテクチャ的に堅実で、ES2023 の一般的ユースケースはほぼカバー。仕様違反はクラスタ化してる:
- **descriptor 不足系** (6件) — writable/enumerable/configurable ストレージがないため連鎖的に影響
- **スタブ系** (4件) — freeze/seal/normalize/isPrototypeOf
- **callback 系** (3件) — thisArg / finally / thenable

2-4週間の集中作業で ES2023 フル準拠到達可能。descriptor ストレージ追加が最大の突破口。
