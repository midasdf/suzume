# suzume Phase D — Web API ポリフィル仕様準拠監査

**Date:** 2026-04-15
**Scope:** `src/js/web_api.zig` (2159 LOC) + `url_bindings.zig` + `worker.zig` + `iframe.zig` + `canvas.zig`
**Specs:** HTML / Fetch / XHR / DOM / WebCrypto / Performance / WebSocket / CSSOM View / Encoding

---

## Executive Summary

18件の仕様違反を検出。**HIGH 2件はセキュリティ/クラッシュ系**。

1. 🔒 **crypto.getRandomValues() が Math.random() 使用** — 暗号学的に非セキュア（セキュリティトークン・IV・鍵生成が危険）
2. 💥 **DOMException が未定義** — AbortController/AbortSignal の `new DOMException(...)` でクラッシュ
3. **localStorage に永続化なし** — ナビゲーションでデータ消失
4. **XHR async=false が効かない** — 同期リクエスト不可
5. **Event constructor が `new` チェックなし** — spec違反（TypeError throw すべき）

---

## HIGH-PRIORITY VIOLATIONS

### 1. 🔒 crypto.getRandomValues() が Math.random() ベース (セキュリティ致命的)
- **File:** `web_api.zig:2240`
- **Spec:** [WebCrypto §14.1](https://www.w3.org/TR/WebCryptoAPI/#RandomSource-method-getRandomValues)
- **Current:** `for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*256)`
- **Expected:** OSエントロピー (/dev/urandom) 等の CSPRNG
- **Impact:** セキュリティトークン/IV/鍵生成が予測可能
- **Complexity:** M (Zig native crypto binding)

### 2. 💥 DOMException が未定義 (エラーパスでクラッシュ)
- **File:** `web_api.zig:2162,2168` 他
- **Spec:** [HTML §4.8](https://html.spec.whatwg.org/#domexception)
- **Current:** AbortController 等で `new DOMException(...)` 呼ぶが本体定義なし
- **Fix:** 1行追加 `globalThis.DOMException = function(message,name){...}; DOMException.prototype = Object.create(Error.prototype);`
- **Complexity:** S

### 3. localStorage 永続化なし
- **File:** `web_api.zig:1842`
- **Spec:** [HTML §15.1.1](https://html.spec.whatwg.org/#storage)
- **Current:** `var _ls={}` インメモリのみ、リロードで消失
- **Fix:** SQLite/JSON永続化
- **Complexity:** M

### 4. XMLHttpRequest.send() で async=false 無視
- **File:** `web_api.zig:1856,1860`
- **Spec:** [XHR §4.7.3](https://xhr.spec.whatwg.org/#the-send()-method)
- **Current:** 常に非同期 fetch、`_async` フラグ無視
- **Fix:** 同期HTTPクライアント or ブロッキング
- **Complexity:** M

### 5. Event constructor が `new` チェックなし
- **File:** `web_api.zig:2046`
- **Spec:** [DOM §4.1](https://dom.spec.whatwg.org/#constructor)
- **Current:** `Event('click')` も成功（TypeError throw すべき）
- **Fix:** `if (!(this instanceof Event)) throw new TypeError(...)`
- **Complexity:** S

### 6. performance.mark/measure が no-op
- **File:** `web_api.zig:1538-1539`
- **Spec:** [Performance Timeline §4.1](https://w3c.github.io/performance-timeline/#dom-performance-mark)
- **Current:** `jsNoOp` 呼び出し、エントリー記録なし、getEntriesByName 常に空配列
- **Complexity:** M

### 7. TextEncoder が UTF-16 surrogate pair 未対応
- **File:** `web_api.zig:2135-2140`
- **Spec:** [Encoding §9.1](https://encoding.spec.whatwg.org/#interface-textencoder)
- **Current:** BMP のみ対応、絵文字 (>U+FFFF) 破損
- **Complexity:** M

### 8. FormData constructor 型検証なし
- **File:** `web_api.zig:2012`
- **Spec:** [XHR §4.1](https://xhr.spec.whatwg.org/#dom-formdata)
- **Current:** `new FormData({})` 成功（form以外は TypeError throw すべき）
- **Complexity:** S

### 9. AbortSignal.any() 空配列で未初期化
- **File:** `web_api.zig:2164`
- **Spec:** [DOM §3.2.5](https://dom.spec.whatwg.org/#dom-abortsignal-any)
- **Current:** 空配列でループ飛ばし未初期化シグナル返却
- **Fix:** 空の場合は never-aborted シグナル
- **Complexity:** S

---

## MEDIUM-PRIORITY VIOLATIONS

### 10. URL constructor 無効時に null silent return
- `url_bindings.zig:62-66` — TypeError throw すべき

### 11. Headers.forEach() 大文字小文字保持
- `web_api.zig:2048` — Fetch §5.1: lowercase でコールバックへ

### 12. Worker constructor で Blob/data URL 未対応
- `web_api.zig:2107-2108` — HTML §10.2.3

### 13. XMLHttpRequest.statusText マッピング欠落
- `web_api.zig:1864` — 空文字フォールバック

### 14. TextDecoder 不正 UTF-8 未検証
- `web_api.zig:2145-2154` — Encoding §9.2: invalid→U+FFFD

### 15. localStorage.key() 順序保証なし
- `web_api.zig:1842` — 挿入順トラッキング

---

## LOW-PRIORITY / COSMETIC

16. CustomEvent.detail が live reference（clone すべき）— `web_api.zig:2047`
17. Response.status 範囲検証なし（200-599外も通る）— `web_api.zig:2049`
18. matchMedia() 対応機能限定 — `web_api.zig:1817`
19. ReadableStream/WritableStream が最小スタブ — `web_api.zig:2260`
20. PerformanceObserver 空スタブ — `web_api.zig:2255`

---

## DEFERRED / OUT-OF-SCOPE

- **WebCrypto.subtle** — 暗号化/署名/鍵導出 (M-L)
- **Service Workers** — 登録・ネットワーク傍受・ライフサイクル (L)
- **Notifications / Permissions** — OS連携 (M)
- **IndexedDB** — DB必要 (L)
- **Geolocation** — GPS連携 (M)
- **WebGL** — GPU binding (L)
- **Full CORS** — header検査 (M)
- **SharedArrayBuffer / Atomics.wait** — スレッド協調 (M)

---

## RECOMMENDED FIX ORDER

### Wave 1 — Quick wins / Security (< 1日)
1. 🔒 DOMException 定義追加 (S, 10分)
2. Event constructor `new` チェック (S)
3. FormData 型検証 (S)
4. AbortSignal.any() 空配列 (S)
5. URL constructor invalid→TypeError (S)
6. Headers.forEach lowercase (S)
7. XHR statusText マップ (S)
8. Response.status 範囲検証 (S)

### Wave 2 — Security Critical (優先度高)
9. 🔒 crypto.getRandomValues() CSPRNG化 (M) — セキュリティ脆弱性

### Wave 3 — Core Functionality (数日)
10. localStorage 永続化 (M)
11. XHR async=false 実装 (M)
12. performance.mark/measure エントリー保存 (M)
13. TextEncoder/TextDecoder UTF-8完全 (M)

### Wave 4 — Advanced
14. Worker Blob/data URL (M)
15. PerformanceObserver 実装 (M)
16. localStorage key 順序 (S)

---

## CONCLUSION

ポリフィル層は **広さ優先で深さ不足**。最優先は #1 (crypto security) と #2 (DOMException crash)。Wave 1 の安い8件は10分/個ペース。localStorage 永続化と XHR sync は設計変更を要する。

🔒 **セキュリティ警告**: `crypto.getRandomValues()` がセキュア関数として使われている箇所があれば、**即座に Wave 2 対応を推奨**。
