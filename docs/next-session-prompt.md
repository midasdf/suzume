# suzume — 開発引き継ぎ

## READ FIRST — 2026-10-09 / Wave 238

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

Wave 234 は、catch のない try 文が例外を捨てる不具合を修正した。flex WPT の調査で、幅を故意に間違えた負例が成功と報告されたために見つかった。数値判定の `isNaN(undefined)` は正常だった。コンパイラが catch のない例外経路で値を pop していたので、同じ値を rethrow する。

選んだ flex WPT は 38/38 から 1/38 へ変わった。37 件は捕捉されて捨てられた検査エラーを報告するようになった。残る 1 件も、未対応の offsetWidth を 2 回読んで undefined 同士を比較している。これらを配置の成功とは扱わない。kotori の CSSOM を実際のレイアウトへ接続し、正例と負例をそろえて検証する必要がある。

修正の範囲は例外の伝播に限る。finally の本体はまだ実行されず、return/break/continue を含む終了処理も実装していない。完全な try/finally 対応とは呼ばない。証拠は `docs/evidence/wave234-exceptions.md` に記録した。

Wave 235 は、ネストした flex の再配置で親が確定した高さを使うようにした。従来の処理は高さを保存して最後に戻すだけで、配置中の justify-content には反映していなかった。確定した content-box の幅と高さを一時的に指定し、flex/grid の処理へ直接入る。padding/border の二重控除や、親を基準にした percentage inset の再計算を避け、元の座標と computed style も保持する。

自作の viewport fixture で、検索欄の y 座標は 112 から 475 へ変わった。x=400、寸法 480×48、main の高さ 928、footer の y=976 は変わっていない。見出しとボタンの幅が広すぎること、匿名空白が高さを消費することは残っている。比較画像と直接検査は `docs/evidence/wave235-flex-reflow.md` に記録した。

Wave 236 は、column flex の非 stretch な auto 幅を intrinsic content から決める。空の子を以前の container-wide な幅へ戻さず、min/max-width、box-sizing、親を基準にした percentage を保って再配置する。nowrap と wrap の測定に同じ処理を使う。自作 fixture の見出しは x=583、幅=114、ボタンは x=590、幅=100 となり、横方向の中央配置が反映された。検索欄は x=400/y=475、480×48 を保持した。匿名空白の 20px の高さは 2 件残る。

直接検査は 8 件を追加し、7 件が実装前に失敗した。修正後の flex は Debug / ReleaseSafe とも 59/59 で、既存の 51 件も保持した。通常の block fixture の画像差は AE=0。URL の 28 報告と flex の 11 報告は、修正前後で分母・失敗行とも一致した。Linux/macOS の CI にも flex の単体検査を加えた。証拠は `docs/evidence/wave236-cross-size.md` に記録した。

Wave 237 は、flex/grid の空白だけの DOM text を box の確保前に除外した。normal/pre/pre-wrap とも適用し、NBSP と非空白の匿名 text item、通常の inline 要素間の空白は保持する。inline-flex でも非空白 text を匿名 item に包む。自作 fixture の box 数は 16 から 12 へ減り、余分な 20px の匿名 item が 2 件なくなった。見出しは y=431、検索欄は y=495、ボタンは y=543。検索欄とボタンの border-box 間隔は指定どおりの 12px になった。

DOM 由来の直接検査を 3 件追加した。うち 2 件は実装前に失敗し、修正後は 62/62 の flex/tree テストが Debug / ReleaseSafe とも成功した。4 種の display と 3 種の white-space を検査し、普通の block fixture の画像差も AE=0 だった。URL/flex WPT の報告と失敗行は Wave 236 と一致した。証拠は `docs/evidence/wave237-whitespace.md` に記録した。

Wave 238 は、実ウィンドウの初期配置でブラウザのバーを除いた高さを使う。ナビゲーションと DOM の再配置は、同じ規則で高さを変換する。同期処理用の寸法は変換前のウィンドウ寸法として保持する。バーを描かない screenshot/layout-dump は全体の高さを維持した。kotori はページのスクリプトより先に寸法を受け取り、window とグローバル変数の両方を更新する。QuickJS の outer 寸法も固定の 720 から実寸法へ変えた。

1280×1024 の X11 ウィンドウで、両エンジンとも innerHeight=936、100vh=936px、50vh=468px となった。640×480 の kotori でも innerHeight=392、100vh=392px を確認した。スタイル変更後の同期取得でも維持する。自作 fixture のフッターは status bar の上に表示された。全ページ撮影の画像差と layout dump の差はともに 0。追加した 4 単体テストのうち 3 件は実装前に失敗し、修正後は全件成功した。QuickJS の smoke assertion も 2/2 で成功した。証拠は `docs/evidence/wave238-content-viewport.md` に記録した。

Linux の実際の resize は未修正。専用の Xvfb 上で 640×480→1280×1024 の変更を XCB の geometry reply で確認したが、ブラウザの寸法は更新されなかった。libnsfb は StructureNotify を購読せず、ConfigureNotify も処理していない。初期化済み surface の geometry 変更も拒否する。単体テストで setter が更新されることと、実ウィンドウの resize 対応は区別する。screen の寸法も既存の未完成な polyfill のままで、kotori の offsetWidth/getBoundingClientRect は未対応。

### 検証結果

| 対象 | GitHub `4a33941` | 統合前の Wave 231 | Wave 238 |
|---|---:|---:|---:|
| `zig build test` | 2125/2125 | 1858/1858 | 2269/2269 |
| ReleaseSafe ビルド | 12/12 steps | 12/12 steps | 12/12 steps |
| kotori DOM (Debug / ReleaseSafe) | — | 242/242 (Debug) | 247/247 / 247/247 |
| URL WPT | 5801/7316 (79.3%) | 6661/7316 (91.0%) | 6662/7316 (91.1%) |
| `url/failure.html` | 375/1175 | 602/1175 | 602/1175 |
| URLSearchParams constructor | 21/27 | 26/27 | 27/27 |

ReleaseSafe の UI/input/navigation/CSS/style テストは 373/373。ローカル HTTP/WebSocket 統合テストは Debug と ReleaseSafe の両方で 9/9。TLS の不正証明書の拒否も検証するが、origin/CORS 全体や実機負荷の検証ではない。

WPT の参照版は `2810902e6a3a78789efe5de3376d4f082087041f`。3 回の計測とも 28 ファイル、7316 サブテストで、報告欠落は 0。GitHub 側と Wave 231 の双方に対する既存成功の退行は 0。`data-uri-fragment.html` の 0 件報告は iframe の動作確認と扱わない。

統合の証拠とファイルごとの比較は `docs/evidence/wave232-integration.md` に記録した。追加した percent encoding の 2 件と branding の 3 件は、実装前に失敗、実装後に成功した。Wave 233 でも URL WPT は 6662/7316 を維持し、新しい失敗と報告欠落は 0。寸法検証の新しい 2 件は実装前に失敗し、実装後の RAM surface テストは Debug / ReleaseSafe とも 4/4 だった。

Wave 232〜237 は main に push 済み。Wave 237 は `a3631dd`。GitHub CI の run `37864269467`、`37866706875`、`37877396993`、`37879314062`、`37890251982`、`37891670132` は全ジョブで成功した。Wave 236 から Linux/macOS の CI は flex の単体検査も実行する。Wave 238 の公開後は、開始時に HEAD と CI の結果を照合する。

Wave 238 のローカル全テストは 2269/2269、80/80 steps。ReleaseSafe の DOM/flex/surface は 313/313、DOM+JS と DOM/style の smoke を含めて 25/25 steps。新しく取り直した URL の 28 報告と flex の 11 報告は、変更前後で分母・失敗行とも一致した。URL は 6662/7316、flex は 1/38、catchless-try は 6/6 を保持した。復元した WPT の sparse checkout に interfaces がなく、最初は分母が 7315 だった。interfaces を追加して両方のバイナリを再実行し、7316 にそろえて比較した。

Wave 234 の kotori 単体テストは Debug / ReleaseSafe とも 1044/1044。追加した 4 件は修正前にすべて失敗し、修正後に成功した。Debug の test バイナリを直接実行しても 1044/1044 だった。自作のブラウザ検査は 1/6 から 6/6 へ改善した。WPT の検査ヘルパーを使った故意の負例は、修正後に正しく失敗する。URL WPT の 28 報告、分母、失敗行は Wave 233 と一致し、6662/7316 を保持した。Wave 234 の viewport fixture の画像差は AE=0 だった。

Wave 235 の flex 単体テストは Debug / ReleaseSafe とも 51/51。最初の新しい 4 件は実装前にすべて失敗した。row/column と content-box/border-box を組み合わせ、高さ 200→120→200 の再配置、子の中心座標、元の座標と style の保持を検査する。親を基準にした 5% padding の検査も 2 件追加した。既存の 45 件はすべて成功を保持した。production CSS/layout の 17/44 件も成功し、通常の block fixture の画像差は AE=0 だった。URL の 28 報告と flex の 11 報告は、Wave 234 と分母・失敗行とも一致した。

一般利用向けの完成には達していない。Wave 231 の Google は検索欄が初期画面外にあり、Wikipedia にはスタイル適用不足があった。GitHub 側の Google の全ページ PNG は 4096×4156、Wave 233 の新しい撮影は 1280×1084 だった。ただし実ページは保存しておらず、制御された比較ではない。スクリプトの大きさによる拒否も残る。画像取得のタイミングを固定していないため、これらの実サイト画像から退行を断定しない。

### 次の優先タスク

1. Linux の実ウィンドウの resize を直す。初期表示の content-height は Wave 238 で検証したが、実際にウィンドウを縮めるとレイアウトと JS の寸法が古いままになる。`resize-x11-test-window` と `viewport-metrics.html` で再現する。イベントの配送と framebuffer の安全な再確保を確認し、拡大・縮小・スタイル変更後の同期取得まで検査する。サブモジュールの gitlink は不要に変更しない。続いて kotori の offsetWidth/getBoundingClientRect を実レイアウトへ接続する。wrapped column の align-content と、finally の実行も残る。finally は通常終了、例外、return/break/continue を先に検査する。
2. Pi Zero 2W の起動、表示、入力、通信、メモリ使用量を確認する。macOS GUI はこの Linux ホストでは動かしていない。TLS のローカル試験は通ったが、origin/CORS、認証付きアセット、実サイトとの通信も調べる。
3. URL/要求 API の残りを処理する。埋め込み IPv4 を含む IPv6 の leading zero は既知の失敗。`urlencoded-parser.any.html` の 70 件は Request/Response.formData の未実装。sendBeacon は true を返すスタブ。不正 UTF-8 の formDecode はネイティブの処理へ統合し、NUL、切れた列、範囲外の列に対する境界テストを追加する。

### 検証コマンド

```bash
cd /home/midasdf/suzume-integration-20261009
zig fmt --check build.zig tools/resize_x11_test_window.zig src/paint/surface.zig src/test_surface.zig src/ui/chrome.zig src/main.zig src/js/web_api.zig src/js/kotori_runtime.zig src/js/kotori/compiler.zig src/js/kotori/object.zig src/js/kotori/vm.zig src/js/kotori_dom.zig src/url/host.zig src/url/parser.zig src/url/percent_encode.zig tests/test_kotori_vm.zig tests/test_kotori_dom.zig
zig build test --summary all
zig build test-kotori -Doptimize=ReleaseSafe --summary all
zig fmt --check src/layout/block.zig src/test_flex_basis.zig src/test_flex_relayout.zig src/test_flex_cross_size.zig src/layout/tree.zig src/test_flex_whitespace.zig
zig build test-flex-basis test-dom-style -Doptimize=ReleaseSafe --summary all
zig build test-surface -Doptimize=ReleaseSafe --summary all
zig build test-kotori-dom test-flex-basis test-dom-js test-dom-style test-surface -Doptimize=ReleaseSafe --summary all
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
ln -s "$PWD/tests/wpt/kotori/catchless-try.html" /tmp/wpt/__suzume_catchless_try_20261009.html
DISPLAY=:98 SUZUME_JS=kotori timeout 90 ./zig-out/bin/suzume --wpt-mode http://127.0.0.1:9876/__suzume_catchless_try_20261009.html
```

`zig build test` は Debug バイナリをインストールする。WPT と閲覧前には必ず ReleaseSafe をビルドし直す。版が変わった WPT のスコアは直接比較せず、before を取り直す。

実ウィンドウの初期寸法と resize を検査する場合は、専用の Xvfb と HTTP サーバーを別ターミナルで起動する。

```bash
cd /home/midasdf/suzume-integration-20261009
Xvfb :118 -screen 0 1280x1024x24 -ac
# 別ターミナル
cd /home/midasdf/suzume-integration-20261009
python3 -m http.server 9877 --bind 127.0.0.1 --directory tests/wpt
# 別ターミナル。対話型ブラウザを止める timeout 124 は意図した終了。
cd /home/midasdf/suzume-integration-20261009
DISPLAY=:118 SUZUME_JS=kotori timeout 30 ./zig-out/bin/suzume http://127.0.0.1:9877/benchmark/viewport-metrics.html
# ブラウザが動いている間に、別ターミナルから実行する。
cd /home/midasdf/suzume-integration-20261009
DISPLAY=:118 zig build resize-x11-test-window -Doptimize=ReleaseSafe -- 640 480
DISPLAY=:118 zig build resize-x11-test-window -Doptimize=ReleaseSafe -- 1280 1024
```

### 地雷リスト

- `g_restyle_height` に content-height を保存しない。変換前のウィンドウ高さを保存し、再配置時に 1 回だけバーを除く。
- 初期 viewport と実ウィンドウの resize を同一視しない。Linux の backend は resize を通知しないため、setter の単体テストだけでは対応を検証できない。
- screen の polyfill を実画面の情報と扱わない。ウィンドウの大きさとモニターの大きさは別の値。
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
- WPT の 0 件報告、タイムアウト、exit 0、DOM の存在だけで成功としない。報告数、分母、画像、実際の操作も確認する。成功する検査にも、故意に失敗させる負例を入れる。undefined 同士の比較や、try 内で捨てられた例外でも成功と報告されることがある。
- iframe/contentWindow、window.open、Beacon、Request/Response を、成功するだけのスタブで埋めない。
- スクリプトの上限は、512MB の実機メモリを測るまで引き上げない。

### 判断済み事項

- 2026-07-06 以前: kotori が既定で、QuickJS はフォールバック。ネイティブ実装を優先する。
- 2026-07-06: 引き継ぎは `docs/next-session-prompt.md` を唯一の正とする。
- 2026-07-06: 1 論点を 1 つの「Wave NNN」連番コミットにする。全テスト成功と対象 WPT の before/after 記録をコミット条件とする。Wave 238 の次は Wave 239。
- 2026-10-09: ユーザーの push 指示を受け、検証済みの統合結果を GitHub main へ公開する。元の未コミット変更は保持する。
- 2026-10-09: 実ウィンドウのページはブラウザのバーを除いた寸法で配置する。バーを描かない全ページ撮影は全寸法を保ち、両モードを同じ高さに強制しない。

repo-local identity は `midasdf <midasdf@users.noreply.github.com>`。Zig の UB 規律は `~/.claude/skills/zig-gotchas/SKILL.md` に従う。

### 実装と証拠の索引

- URL: `src/url/parser.zig` は runtime、DOM、exe の共有モジュール。ネイティブへの入口は `__suzume_url_parse` / `__suzume_url_set`。
- 要求 URL: fetch と XHR はネイティブのパーサーと document.baseURI を使う。XHR は open 時点の絶対 URL を保存する。グローバル URL の差し替えには依存しない。
- DOMException: `VM.createDOMException`、`JsObject.ObjData.dom_exception_data`、prototype の native getter。
- WebDriver: `DISPLAY=:98 SUZUME_JS=quickjs ./zig-out/bin/suzume --webdriver 9999`。現在の execute/sync と execute/async は QuickJS の js_rt へ渡す。kotori_rt の実行経路は未接続。非同期コールバックの完了待ちにも制限がある。
- HTTP/TLS のローカル統合試験: `tests/http_regression.py`。
- libnsfb パッチ: `./scripts/apply-libnsfb-patch.sh "$PWD/patches/libnsfb-xim.patch" "$PWD/deps/libnsfb"`。
- Wave 230/231 の要求 URL と USVString の証拠: `docs/evidence/wave230-url-results.txt`、`wave231-url-results.txt`。
- 描画の既知の未完成箇所: `docs/evidence/wave231-smoke.md`。
- Native window / RAM surface: `src/paint/surface.zig`、`src/test_surface.zig`。自作の描画 fixture は `tests/wpt/benchmark/window-viewport.html`。
- catch のない try の例外伝播: `src/js/kotori/compiler.zig` の `compileTryCatch`。ブラウザ用回帰テストは `tests/wpt/kotori/catchless-try.html`。詳細は `docs/evidence/wave234-exceptions.md`。
- ネストした formatting context の再配置: `src/layout/block.zig` の `relayoutChildrenWithContainingHeight`。直接検査は `src/test_flex_relayout.zig`、証拠は `docs/evidence/wave235-flex-reflow.md`。
- column flex の auto cross size: `src/layout/flex.zig` の `layoutColumnItem`。直接検査は `src/test_flex_cross_size.zig`、証拠は `docs/evidence/wave236-cross-size.md`。
- 空白だけの flex/grid DOM text: `src/layout/tree.zig` の `buildChildren`。inline-flex の匿名 item は `wrapInlineChildren`。直接検査は `src/test_flex_whitespace.zig`、証拠は `docs/evidence/wave237-whitespace.md`。
- 初期 content viewport: 高さは `src/main.zig` の `documentViewportHeight` で変換する。共有する寸法は `src/js/web_api.zig` の viewport state に保存する。kotori の初期化は `src/core/script_executor.zig`。fixture は `tests/wpt/benchmark/viewport-metrics.html`、証拠は `docs/evidence/wave238-content-viewport.md`。
- X11 の resize 検査: `tools/resize_x11_test_window.zig`。Linux の専用 Xvfb で root window の子が 1 個のときだけ変更する。
- 詳細ログ: `/tmp/suzume-wave238-20261009/`。Wave 237 以前の一時ログは、このセッションでは存在しなかった。公開済みの証拠文書と比較画像を使う。
- Wave 231 の引き継ぎ: `git show 2978cf7:docs/next-session-prompt.md`。Wave 229 以前の履歴: `git show 1171fae:docs/next-session-prompt.md`。
