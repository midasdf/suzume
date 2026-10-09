# suzume — 開発引き継ぎ

## READ FIRST — 2026-10-09 / Wave 233

### 状態スナップショット

Raspberry Pi Zero 2W 向けの軽量ブラウザ。kotori が既定の JS エンジンで、QuickJS はフォールバック。一般利用向けには未完成であり、互換性スコアと実ページの使いやすさを別々に検証する。

ユーザーは 2026-10-09 に「どんどん続けてプッシュもして」と指示した。検証済みの変更は GitHub の main へ通常の fast-forward push で公開する。force-push、デプロイ、元の未コミット変更の一括コミットは行わない。

GitHub の main は `4a33941` まで進んでおり、ローカルの Wave 231 (`2978cf7`) と分岐していた。元の作業場所 `/home/midasdf/suzume` を変更せず、次の worktree で両方の履歴を統合した。

- 作業場所: `/home/midasdf/suzume-integration-20261009`
- ブランチ: `integrate-20261009`
- 元の作業場所の main は Wave 231 のまま。未コミット変更と未追跡ファイルも残している。
- 元の追跡済み差分の SHA-256 は、統合前後で `6b83f349aec10af63b9a1ac68b15d472eab92a873eec7a679d4504e274849d4b` と一致した。

Wave 232 の論点は、既存の成功を失わずに両方の履歴を統合することだった。GitHub 側の HTTP/TLS、macOS GUI、CSS/flex/grid、折り返し、タブごとのナビゲーションを取り込んだ。ローカル側の URL/IDNA/Unicode/VM、要求 URL、USVString の修正も保持した。

統合後の VM が使う `getWithAccessorInfo` の実装は追跡されていなかったため補った。未コミットの URL host/parser の修正は内容を確認して移植した。その他の未コミット変更、`src/net/asset_fetcher.zig`、サブモジュール内の変更は取り込んでいない。

URL の percent encoding は、孤立した WTF-8 サロゲートを U+FFFD に置換し、分割されたペアを 1 スカラー値に統合する。内部の WTF-8 保存は変更していない。未コミットの form decoder は、NUL の置換と切れた UTF-8 の処理が不正なため移植しなかった。

DOMException の name/message/code はネイティブの内部データに保存する。prototype の getter は受信側の branding を検証し、偽装オブジェクトや prototype 自身を拒否する。DOM が作る例外も同じネイティブの生成処理を使う。Error の文字列化は getter を読む。統合途中に GitHub 側で成功していた URLSearchParams の branding テストが失敗したため、公開前にこの処理を修正した。

Wave 233 は Linux の初期ウィンドウを実際の画面サイズへ収める。「画面いっぱいに表示する」という方針は保持し、4096×4096 の要求を XCB の画面サイズで制限してから framebuffer を確保する。macOS の既存経路と、画面より背の高い RAM screenshot は維持した。

自作の fixture では、検索欄の x 座標が 1808 から 400 へ変わり、1280×1024 の画面内に入った。同じ fixture の撮影中に観測したプロセスの VmHWM は 200.6MiB から 52.0MiB へ減った。x86_64 の撮影処理を 10ms ごとに観測した値であり、Pi の実機メモリや通常の閲覧負荷の検証ではない。明示した 640×480 の画像差は 0 ピクセルだった。

0 と負の寸法はバックエンドの確保前に拒否する。不正な resize では既存の framebuffer を保持する。RAM surface のテストを Linux でも有効にし、全テストと Linux CI に加えた。証拠は `docs/evidence/wave233-viewport.md` と比較画像に記録した。

### 検証結果

| 対象 | GitHub `4a33941` | 統合前の Wave 231 | Wave 233 |
|---|---:|---:|---:|
| `zig build test` | 2125/2125 | 1858/1858 | 2244/2244 |
| ReleaseSafe ビルド | 12/12 steps | 12/12 steps | 12/12 steps |
| kotori DOM (Debug / ReleaseSafe) | — | 242/242 (Debug) | 245/245 / 245/245 |
| URL WPT | 5801/7316 (79.3%) | 6661/7316 (91.0%) | 6662/7316 (91.1%) |
| `url/failure.html` | 375/1175 | 602/1175 | 602/1175 |
| URLSearchParams constructor | 21/27 | 26/27 | 27/27 |

ReleaseSafe の UI/input/navigation/CSS/style テストは 373/373。ローカル HTTP/WebSocket 統合テストは Debug と ReleaseSafe の両方で 9/9。TLS の不正証明書の拒否も検証するが、origin/CORS 全体や実機負荷の検証ではない。

WPT の参照版は `2810902e6a3a78789efe5de3376d4f082087041f`。3 回の計測とも 28 ファイル、7316 サブテストで、報告欠落は 0。GitHub 側と Wave 231 の双方に対する既存成功の退行は 0。`data-uri-fragment.html` の 0 件報告は iframe の動作確認と扱わない。

統合の証拠とファイルごとの比較は `docs/evidence/wave232-integration.md` に記録した。追加した percent encoding の 2 件と branding の 3 件は、実装前に失敗、実装後に成功した。Wave 233 でも URL WPT は 6662/7316 を維持し、新しい失敗と報告欠落は 0。寸法検証の新しい 2 件は実装前に失敗し、実装後の RAM surface テストは Debug / ReleaseSafe とも 4/4 だった。

Wave 232 は `908d115` として main に push 済み。GitHub CI の run `37864269467` は、Linux、macOS、HTTP、security-audit の全ジョブで成功した。Wave 233 の CI は別の実行なので、その結果も確認する。

一般利用向けの完成には達していない。Wave 231 の Google は検索欄が初期画面外にあり、Wikipedia にはスタイル適用不足があった。GitHub 側の Google の全ページ PNG は 4096×4156、Wave 233 の新しい撮影は 1280×1084 だった。ただし実ページは保存しておらず、制御された比較ではない。スクリプトの大きさによる拒否も残る。画像取得のタイミングを固定していないため、これらの実サイト画像から退行を断定しない。

### 次の優先タスク

1. `tests/wpt/benchmark/window-viewport.html` で残る flex の配置を直す。heading/button の align-items と justify-content が指定どおりになっていない。匿名ブロックの扱いと、ブラウザのバーを除いた content-height も調べる。Google/Wikipedia の HTML/CSS はまず一時ファイルに保存し、公開する fixture は最小の自作 HTML/CSS にする。CSS の取得・適用と画像完了のタイミングも分けて確認する。
2. Pi Zero 2W の起動、表示、入力、通信、メモリ使用量を確認する。macOS GUI はこの Linux ホストでは動かしていない。TLS のローカル試験は通ったが、origin/CORS、認証付きアセット、実サイトとの通信も調べる。
3. URL/要求 API の残りを処理する。埋め込み IPv4 を含む IPv6 の leading zero は既知の失敗。`urlencoded-parser.any.html` の 70 件は Request/Response.formData の未実装。sendBeacon は true を返すスタブ。不正 UTF-8 の formDecode はネイティブの処理へ統合し、NUL、切れた列、範囲外の列に対する境界テストを追加する。

### 検証コマンド

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check build.zig src/paint/surface.zig src/test_surface.zig src/ui/chrome.zig src/main.zig src/js/kotori/object.zig src/js/kotori/vm.zig src/js/kotori_dom.zig src/url/host.zig src/url/parser.zig src/url/percent_encode.zig tests/test_kotori_dom.zig
zig build test --summary all
zig build test-surface -Doptimize=ReleaseSafe --summary all
zig build test-kotori-dom -Doptimize=ReleaseSafe --summary all
zig build test-ui-input test-navigation test-css test-dom-style -Doptimize=ReleaseSafe --summary all
python3 tests/http_regression.py
python3 tests/http_regression.py -O ReleaseSafe
zig build -Doptimize=ReleaseSafe --summary all
./tests/wpt/run_wpt_parallel.sh setup
git -C /tmp/wpt rev-parse HEAD
# 初回は .any.js の HTML ラッパーを生成するため、逐次ランナーを通す。
./tests/wpt/run_wpt.sh url
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

単発で再現する場合は、別ターミナルで HTTP サーバーと Xvfb を起動する。

```bash
cd /tmp/wpt
python3 -m http.server 9876 --bind 127.0.0.1
# 別ターミナル
Xvfb :98 -screen 0 1280x1024x24 -ac
# 別ターミナル
cd /home/midasdf/suzume-integration-20261009
DISPLAY=:98 SUZUME_JS=kotori timeout 120 ./zig-out/bin/suzume --wpt-mode http://127.0.0.1:9876/url/failure.html
```

`zig build test` は Debug バイナリをインストールする。WPT と閲覧前には必ず ReleaseSafe をビルドし直す。版が変わった WPT のスコアは直接比較せず、before を取り直す。

### 地雷リスト

- ReleaseFast は使わない。範囲外の `@intCast` による UB でハングと回帰が起きた。README の古い cross-build 例をコピーせず、ReleaseSafe を使う。
- 新しい成功数で既存の失敗を相殺しない。統合時には片方の履歴だけでなく、両方のベースラインを比較する。
- 元の dirty worktree で reset や merge をしない。未コミット変更には GitHub 側と重複する修正がある。統合用 worktree のコードを検証してから、必要な部分だけ移植する。
- libnsfb はビルド時の XIM パッチで dirty になる。親 repo の gitlink を不要に更新したり、サブモジュール内の変更を一括公開したりしない。
- host の leading/consecutive dot rejection を戻さない。`.` / `..` は有効なホストであり、validation error と parse failure を区別する。
- Unicode テーブルは 17.0。CONTEXTJ、bidi、先頭の Mn/Mc/Me、VerifyDnsLength=false、ACE の P4 検証は実装済み。テーブルを手で編集せず、tools の生成処理から再生成する。
- IdnaTestV2 は 2669/2676。旧版の 2671/2671 と入力が異なる。U+3F8CD / U+3E8AC などの新しい入力は未調査。
- WTF-8 の内部保存と WebIDL のスカラー値変換を混同しない。record は変換後のキーで衝突を処理し、sequence の重複は保持する。
- DOMException の branding を JS のプロパティで代用しない。例外の内部データを持たない受信側は TypeError にする。一般の TypeError を DOMException として生成しない。
- prototype を拡張する際は freeze を確認する。必要なら kotori_dom.zig の `unfrozen_html_protos` に追加する。
- Zig 0.16 の test runner 終了時には shutdown race がある。全テスト成功後の SIGABRT は、報告と test バイナリの直接実行を確認してから判断する。
- WPT の 0 件報告、タイムアウト、exit 0、DOM の存在だけで成功としない。報告数、分母、画像、実際の操作も確認する。
- iframe/contentWindow、window.open、Beacon、Request/Response を、成功するだけのスタブで埋めない。
- スクリプトの上限は、512MB の実機メモリを測るまで引き上げない。

### 判断済み事項

- 2026-07-06 以前: kotori が既定で、QuickJS はフォールバック。ネイティブ実装を優先する。
- 2026-07-06: 引き継ぎは `docs/next-session-prompt.md` を唯一の正とする。
- 2026-07-06: 1 論点を 1 つの「Wave NNN」連番コミットにする。全テスト成功と対象 WPT の before/after 記録をコミット条件とする。Wave 233 の次は Wave 234。
- 2026-10-09: ユーザーの push 指示を受け、検証済みの統合結果を GitHub main へ公開する。元の未コミット変更は保持する。

repo-local identity は `midasdf <midasdf@users.noreply.github.com>`。Zig の UB 規律は `~/.claude/skills/zig-gotchas/SKILL.md` に従う。

### 実装と証拠の索引

- URL: `src/url/parser.zig` は runtime、DOM、exe の共有モジュール。ネイティブへの入口は `__suzume_url_parse` / `__suzume_url_set`。
- 要求 URL: fetch と XHR はネイティブのパーサーと document.baseURI を使う。XHR は open 時点の絶対 URL を保存する。グローバル URL の差し替えには依存しない。
- DOMException: `VM.createDOMException`、`JsObject.ObjData.dom_exception_data`、prototype の native getter。
- WebDriver: `DISPLAY=:98 ./zig-out/bin/suzume --webdriver 9999`。kotori の execute/sync と execute/async を使う。非同期コールバックの完了待ちには制限がある。
- HTTP/TLS のローカル統合試験: `tests/http_regression.py`。
- libnsfb パッチ: `./scripts/apply-libnsfb-patch.sh "$PWD/patches/libnsfb-xim.patch" "$PWD/deps/libnsfb"`。
- Wave 230/231 の要求 URL と USVString の証拠: `docs/evidence/wave230-url-results.txt`、`wave231-url-results.txt`。
- 描画の既知の未完成箇所: `docs/evidence/wave231-smoke.md`。
- Native window / RAM surface: `src/paint/surface.zig`、`src/test_surface.zig`。自作の描画 fixture は `tests/wpt/benchmark/window-viewport.html`。
- 詳細ログ: `/tmp/suzume-integration-20261009/`。一時ファイルなので再起動で消える。以前のログは `/tmp/suzume-20261009/`。
- Wave 231 の引き継ぎ: `git show 2978cf7:docs/next-session-prompt.md`。Wave 229 以前の履歴: `git show 1171fae:docs/next-session-prompt.md`。
