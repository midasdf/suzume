# Wave 232 — upstream integration and URL compatibility

Measured on 2026-10-09, Linux x86_64, Zig 0.16, kotori, ReleaseSafe.

## Baselines and preservation

- Remote baseline: `origin/main` at `4a33941`.
- Local committed baseline: Wave 231, `2978cf7`.
- Integration worktree: `/home/midasdf/suzume-integration-20261009`, branch `integrate-20261009`.
- Merge base: `1a115c3`. Both histories are retained; no reset or force-push is required.
- Original worktree: `/home/midasdf/suzume`, left at Wave 231 with its pending work intact.
- Original tracked diff SHA-256 before and after integration: `6b83f349aec10af63b9a1ac68b15d472eab92a873eec7a679d4504e274849d4b`.
- Only the reviewed URL host/parser changes were ported from that pending work. The missing `getWithAccessorInfo` implementation was supplied in the integration worktree. Other pending changes and the asset-fetcher file were not swept into the merge.
- The pending form decoder was not ported: replacing NUL is incorrect, and its truncated UTF-8 handling needs a separate implementation and boundary tests. A native NUL-preservation test now guards this boundary.

## Verification

| Check | Remote baseline | Integrated |
|---|---:|---:|
| `zig build test --summary all` | 2125/2125; 78/78 steps | 2240/2240; 78/78 steps |
| `zig build -Doptimize=ReleaseSafe --summary all` | 12/12 steps | 12/12 steps |
| kotori DOM tests, Debug | — | 245/245 |
| kotori DOM tests, ReleaseSafe | — | 245/245 |
| UI/input/navigation/CSS/style tests, ReleaseSafe | — | 373/373 |
| Local HTTP/WebSocket integration, Debug | — | 9/9 |
| Local HTTP/WebSocket integration, ReleaseSafe | — | 9/9 |
| URL WPT | 5801/7316 (79.3%) | 6662/7316 (91.1%) |

The network integration suite covers local HTTP compression, cache revalidation, redirects, POST, TLS certificate rejection, WebSocket metadata, and protocol rejection. It is not a complete origin/CORS audit or a target-device memory measurement. The Python fixture server printed BrokenPipeError during rejected TLS handshakes; both test executions reported all nine tests passed and exited zero.

Regression tests were run before implementation:

- Lone-surrogate percent encoding: 19/20 passed, one new test failed; after implementation it passed.
- Split surrogate-pair percent encoding: 20/21 passed, one new test failed; after implementation 21/21 passed.
- Native DOMException branding/getters/argument conversion: 242/245 passed, all three new tests failed; after implementation 245/245 passed.

DOMException now stores its name/message/code in native internal data, exposes enumerable branded prototype getters, and shares its native exception factory with DOM-generated exceptions. A fake receiver, prototype object, or object inheriting from a real exception does not pass the branding check. Error stringification reads accessors rather than skipping them. URLSearchParams constructor WPT is now 27/27; the first merged binary had lost a remote-baseline success in this file, so it was repaired before publication.

## URL WPT comparison

WPT revision: `2810902e6a3a78789efe5de3376d4f082087041f`.

Each run reported the same 28 files and 7316 subtests. Missing reports: zero. New failure lines against the remote baseline: zero. New failure lines against local Wave 231: zero. Comparison used complete `WPT_FAIL:` lines as raw bytes, and confirmed per-file success counts and denominators.

| File | Remote `4a33941` | Local Wave 231 | Wave 232 |
|---|---:|---:|---:|
| IdnaTestV2-removed.any.html | 9/21 | 21/21 | 21/21 |
| IdnaTestV2.any.html | 2176/2676 | 2669/2676 | 2669/2676 |
| a-element-origin.html | 402/415 | 415/415 | 415/415 |
| a-element.html | 852/897 | 896/897 | 896/897 |
| data-uri-fragment.html | 0/0 | 0/0 | 0/0 |
| failure.html | 375/1175 | 602/1175 | 602/1175 |
| historical.any.html | 1/1 | 1/1 | 1/1 |
| idlharness.any.html | 0/2 | 0/2 | 0/2 |
| url-constructor.any.html | 852/898 | 897/898 | 897/898 |
| url-origin.any.html | 403/416 | 416/416 | 416/416 |
| url-searchparams.any.html | 3/4 | 4/4 | 4/4 |
| url-setters-stripping.any.html | 320/320 | 320/320 | 320/320 |
| url-setters.any.html | 277/279 | 279/279 | 279/279 |
| url-statics-canparse.any.html | 8/8 | 8/8 | 8/8 |
| url-statics-parse.any.html | 8/8 | 8/8 | 8/8 |
| url-tojson.any.html | 1/1 | 1/1 | 1/1 |
| urlencoded-parser.any.html | 30/105 | 35/105 | 35/105 |
| urlsearchparams-append.any.html | 4/4 | 4/4 | 4/4 |
| urlsearchparams-constructor.any.html | 21/27 | 26/27 | 27/27 |
| urlsearchparams-delete.any.html | 8/8 | 8/8 | 8/8 |
| urlsearchparams-foreach.any.html | 6/6 | 6/6 | 6/6 |
| urlsearchparams-get.any.html | 2/2 | 2/2 | 2/2 |
| urlsearchparams-getall.any.html | 2/2 | 2/2 | 2/2 |
| urlsearchparams-has.any.html | 4/4 | 4/4 | 4/4 |
| urlsearchparams-set.any.html | 2/2 | 2/2 | 2/2 |
| urlsearchparams-size.any.html | 4/4 | 4/4 | 4/4 |
| urlsearchparams-sort.any.html | 17/17 | 17/17 | 17/17 |
| urlsearchparams-stringifier.any.html | 14/14 | 14/14 | 14/14 |
| Total | 5801/7316 | 6661/7316 | 6662/7316 |

The zero-subtest data URI report does not validate iframe behavior. Remaining embedded-IPv4-in-IPv6 rejection cases, IDNA inputs, formData(), and Beacon behavior remain separate tasks.

## Reproduction

```bash
cd /home/midasdf/suzume-integration-20261009
zig build test --summary all
zig build test-kotori-dom -Doptimize=ReleaseSafe --summary all
zig build test-ui-input test-navigation test-css test-dom-style -Doptimize=ReleaseSafe --summary all
python3 tests/http_regression.py
python3 tests/http_regression.py -O ReleaseSafe
zig build -Doptimize=ReleaseSafe --summary all
./tests/wpt/run_wpt_parallel.sh setup
./tests/wpt/run_wpt.sh url
./tests/wpt/run_wpt_parallel.sh --jobs 8 url
```

The actual three-way comparison used pre-generated HTML wrappers and the same server and Xvfb displays for each binary. Detailed logs are temporarily retained under `/tmp/suzume-integration-20261009/`, in `wpt-remote/`, `wpt-wave232/`, and `wave232-*.log`; the local baseline logs are under `/tmp/suzume-20261009/wpt-wave231/`.

## Rendering limits

An upstream-baseline Google capture exited zero but rendered a 4096×4156 full-page PNG. Its 1,123,848-byte external script was rejected by the existing script-size limit. No visual success or visual-regression conclusion is drawn from that capture; controlled local fixtures and image-completion timing are still needed. Mac GUI operation and Raspberry Pi Zero 2W execution were not tested on this Linux host.
