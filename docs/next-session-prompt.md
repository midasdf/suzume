# suzume — 開発引き継ぎ

## READ FIRST — 2026-10-09 / Wave 230

### 状態スナップショット

Raspberry Pi Zero 2W 向けの軽量ブラウザ。kotori を既定の JS エンジンとして、TDD で基礎レイヤーから WPT の各エリア 90% 以上を目指す。QuickJS はフォールバック。

Wave 230 は `fetch()` と `XMLHttpRequest.open()` の要求 URL 処理を修正した。
不正な URL は通信層へ渡さず、fetch は TypeError で Promise を拒否し、XHR は SyntaxError の DOMException を投げる。URL の文字列変換が投げた例外も fetch の拒否理由として保持する。
相対 URL は `document.baseURI` で解決する。XHR は open 時点の絶対 URL を保存するため、その後に `<base>` が変わっても送信先は変わらない。ページがグローバルの URL コンストラクタを置き換えても、ネイティブの URL パーサーで解決する。

2026-10-09 の実測値は次のとおり。

| 検証対象 | 着手前 | Wave 230 後 |
|---|---:|---:|
| `zig build test` | 1847/1847 | 1853/1853 |
| kotori unit | 1040/1040 | 1040/1040 |
| kotori DOM | 231/231 | 237/237 |
| URL WPT 全体 | 6469/7316 (88.4%) | 6658/7316 (91.0%) |
| `url/failure.html` | 413/1175 | 602/1175 |

URL WPT は 28 ファイルを実行し、報告欠落は 0。各ファイルの分母を維持し、既存の成功サブテストが失敗へ変わった件数は 0。`data-uri-fragment.html` は着手前・修正後とも 0 サブテストを報告するため、iframe の動作を検証できたとは扱わない。

WPT の参照版は `2810902e6a3a78789efe5de3376d4f082087041f`。2026-07-06 の WPT と分母が異なるため、旧スコアだけで退行を判定しない。同一参照版・同一環境の before/after を比較する。

着手前から 18 ファイルに未コミットの変更があった。
対象は README、script_executor、CSS、VM/compiler/object、DOM、main、net、chrome、URL 関連だった。
`src/net/asset_fetcher.zig` と `docs/evidence/` も未追跡だった。libnsfb サブモジュールにも変更がある。今回のコミットへ既存変更を混ぜないこと。着手前の差分と全検証ログは `/tmp/suzume-20261009/` に保存したが、再起動で消える。

### 次の優先タスク

1. **URLSearchParams の WebIDL USVString 変換。** `urlsearchparams-constructor.any.html` は 23/27。3 件は、非対応サロゲートを含む record のキーを U+FFFD へ変換する処理の不足。変換後のキーが一致する項目は、値を上書きする必要もある。内部の WTF-8 保存の破損ではない。残る 1 件は DOMException.prototype の branding check。
2. **要求・応答 API の不足を解消する。** `urlencoded-parser.any.html` は 35/105。残る 70 件は Request/Response.formData の未実装。sendBeacon は true を返すだけのスタブで、不正 URL の検証もない。送信機能を実装せず成功を装う修正はしない。
3. **日常閲覧の安全性と実機挙動を確認する。** TLS 証明書のフォールバック、origin/CORS、認証付きアセット、Pi Zero 2W のメモリ使用量は、本セッションでは未検証。互換性スコアだけで一般利用向けの完成を宣言しない。

### 検証コマンド

```bash
cd /home/midasdf/suzume
zig fmt --check src/js/kotori_runtime.zig tests/test_kotori_dom.zig
zig build test --summary all
zig build -Doptimize=ReleaseSafe --summary all
./tests/wpt/run_wpt_parallel.sh setup
# /tmp/wpt が上記の参照版か確認する。版が変わったら before を取り直す。
git -C /tmp/wpt rev-parse HEAD
# 初回は .any.js の HTML ラッパーを生成するため、逐次ランナーを通す。
./tests/wpt/run_wpt.sh url
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

単発で再現するには、Xvfb :98 と /tmp/wpt を配信する HTTP サーバーを起動する。

```bash
cd /tmp/wpt
python3 -m http.server 9876 --bind 127.0.0.1
# 別ターミナル
Xvfb :98 -screen 0 1280x1024x24 -ac
# 別ターミナル
cd /home/midasdf/suzume
DISPLAY=:98 SUZUME_JS=kotori timeout 120 ./zig-out/bin/suzume --wpt-mode http://127.0.0.1:9876/url/failure.html
```

`zig build test` は Debug バイナリをインストールする。WPT や閲覧前には必ず ReleaseSafe をビルドし直す。

### 地雷リスト

- **ReleaseFast を使わないこと。** 範囲外の `@intCast` による UB で過去にハング・回帰が起きた。Debug は計測には遅すぎる。
- **成功数の増分で既存失敗を相殺しないこと。** kotori 1040 件の既存テストと、WPT の既存成功サブテストを 1 件でも失敗へ変えたら退行。
- **host の leading/consecutive dot rejection を戻さないこと。** `.` / `..` は URL の有効なホスト。endsInNumber / parseIpv4Number / domainToAscii の連鎖を無視すると大幅な退行が起きる。Wave 218–229 で修正済み。
- **IDNA の Unicode テーブルを 16.0 に戻さないこと。** データは 17.0。CONTEXTJ、bidi、先頭結合記号 Mn/Mc/Me、VerifyDnsLength=false、ACE ラベル P4 検証は実装済み。テーブルは tools のジェネレータから再生成する。
- **IdnaTestV2 の新しい入力を区別すること。** 2026-10-09 の WPT は 2669/2676。旧 WPT の 2671/2671 とは入力が違う。新しい入力に含まれる U+3F8CD / U+3E8AC の扱いは未調査。
- **lone surrogate の内部保存を再実装しないこと。** 内部文字列は WTF-8 で保存される。StringPool、Object のキー、連結は検証済み。codePointAt は Wave 229 以前に修正済み。WebIDL の境界変換とは別の問題。
- **prototype の freeze を確認すること。** 拡張対象によっては、kotori_dom.zig の `unfrozen_html_protos` へ追加する。
- **test_runner の shutdown race をテスト失敗と誤診しないこと。** Zig 0.16 の IPC 終了時には shutdown race がある。全テスト成功後でも `failed command:` / SIGABRT が出る。テスト結果を確認し、必要なら生成された test バイナリを直接実行する。
- **WPT のゼロ件報告やタイムアウトを成功扱いしないこと。** 分母と報告欠落も before/after で照合する。parallel ランナーは .any.js のラッパーを生成しない。
- **非対応 API を成功するスタブで埋めないこと。** iframe/contentWindow、window.open、Beacon の送信、Request/Response は完成していない。

### 判断済み事項

- 2026-07-06 以前: kotori が既定、QuickJS はフォールバック。ネイティブ実装を優先し、ポリフィルは暫定。
- 2026-07-06: 引き継ぎは `docs/next-session-prompt.md` を唯一の正とする。
- 2026-07-06: 1 論点を 1 つの「Wave NNN」連番コミットにする。`zig build test` の全成功と対象 WPT の before/after 記録をコミット条件とする。
- 2026-10-09: ユーザーから開発の引き継ぎと完成度向上を依頼された。push・公開・デプロイは行わない。

repo-local git identity は `midasdf <midasdf@users.noreply.github.com>`。
Zig の UB 規律は `~/.claude/skills/zig-gotchas/SKILL.md` に従う。

### 実装の索引

- URL パーサー: `src/url/parser.zig`。kotori runtime / DOM / exe から共有モジュール `url_parser` として使用。
- URL クラス: `src/js/kotori_runtime.zig` の prototype アクセサと `_p`。`__suzume_url_parse` / `__suzume_url_set` がネイティブへの入口。
- `<a>` / `<area>`: `hyperlink_utils_polyfill_js`。baseURI は DOM の `docBaseUriString` で計算。
- VM: 未捕捉例外は execute がクリアし、last_uncaught に保存。Promise の反応は runMicrotasks で処理。
- WebDriver: `DISPLAY=:98 ./zig-out/bin/suzume --webdriver 9999`。execute/sync と execute/async は kotori を優先する。非同期コールバックの完了待ちには制限がある。
- libnsfb パッチ: `./scripts/apply-libnsfb-patch.sh "$PWD/patches/libnsfb-xim.patch" "$PWD/deps/libnsfb"`。
- 2026-07-01 の Google / Wikipedia / Hacker News の描画証拠は `docs/evidence/`。2026-10-09 の新規検証とは区別する。
- Wave 229 までの詳細な開発履歴は `git show 1171fae:docs/next-session-prompt.md` で参照する。
