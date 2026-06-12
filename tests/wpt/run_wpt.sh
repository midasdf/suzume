#!/bin/bash
# Run WPT testharness.js tests against suzume
# Usage: ./run_wpt.sh [area]
# Examples:
#   ./run_wpt.sh css/css-box        # run css-box tests
#   ./run_wpt.sh css/css-values     # run css-values tests
#   ./run_wpt.sh dom                # run DOM tests
#   ./run_wpt.sh url                # run URL tests
#   ./run_wpt.sh encoding           # run encoding tests
#   ./run_wpt.sh css                # run all CSS tests
#   ./run_wpt.sh setup              # first-time setup
#
# Legacy aliases (backwards compatible):
#   ./run_wpt.sh css-box            # same as css/css-box
#   ./run_wpt.sh css-values         # same as css/css-values
set -uo pipefail

WPT_DIR="/tmp/wpt"
SUZUME_BIN="$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/suzume"
PORT=9876
TIMEOUT=${TIMEOUT:-90}
AREA="${1:-css/css-box}"
DISPLAY_NUM=":98"
JS_ENGINE="${SUZUME_JS:-kotori}"

# Setup mode
if [ "$AREA" = "setup" ]; then
    echo "=== Setting up WPT ==="
    if [ ! -d "$WPT_DIR" ]; then
        git clone --depth 1 https://github.com/web-platform-tests/wpt.git "$WPT_DIR"
    fi
    # Inject testharnessreport.js callback for suzume
    cat >> "$WPT_DIR/resources/testharnessreport.js" << 'JSEOF'

// suzume browser WPT integration
(function() {
    var _results = [];
    var _reported = false;
    function _report(tests) {
        if (_reported) return;
        _reported = true;
        var pass = 0, fail = 0, total = tests.length;
        for (var i = 0; i < tests.length; i++) {
            if (tests[i].status === 0) { pass++; }
            else { fail++; console.log("WPT_FAIL: " + tests[i].name + " — " + (tests[i].message || "")); }
        }
        console.log("WPT_SUMMARY: PASS=" + pass + " FAIL=" + fail + " TOTAL=" + total);
    }
    add_result_callback(function(test) { _results.push(test); });
    add_completion_callback(function(tests, harness_status) { _report(tests); });
    setTimeout(function() {
        if (!_reported && _results.length > 0) _report(_results);
        else if (!_reported) console.log("WPT_SUMMARY: PASS=0 FAIL=0 TOTAL=0");
    }, 6000);
})();
JSEOF
    echo "Setup complete. WPT at $WPT_DIR"
    exit 0
fi

# Handle legacy css-X format
case "$AREA" in
    css-*)
        AREA="css/$AREA"
        ;;
esac

if [ ! -d "$WPT_DIR" ]; then
    echo "ERROR: WPT not found at $WPT_DIR"
    echo "Run: $0 setup"
    exit 1
fi

if [ ! -f "$SUZUME_BIN" ]; then
    echo "ERROR: suzume not built. Run: zig build"
    exit 1
fi

case "$JS_ENGINE" in
    kotori|quickjs) ;;
    *)
        echo "ERROR: Unsupported JS engine: $JS_ENGINE"
        echo "Use SUZUME_JS=kotori or SUZUME_JS=quickjs"
        exit 1
        ;;
esac

# Reuse existing HTTP server and Xvfb if available, otherwise start new ones
OWN_HTTP=0
OWN_XVFB=0

cd "$WPT_DIR"
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q "200"; then
    : # HTTP server already running
else
    python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null &
    HTTP_PID=$!
    OWN_HTTP=1
    sleep 1
fi

if DISPLAY="$DISPLAY_NUM" xdpyinfo &>/dev/null 2>&1; then
    : # Xvfb already running
else
    Xvfb "$DISPLAY_NUM" -screen 0 800x600x24 -ac &>/dev/null &
    XVFB_PID=$!
    OWN_XVFB=1
    sleep 1
fi

trap '[ "$OWN_HTTP" = 1 ] && kill $HTTP_PID 2>/dev/null; [ "$OWN_XVFB" = 1 ] && kill $XVFB_PID 2>/dev/null' EXIT

# Find testharness test files
if [ ! -d "$WPT_DIR/$AREA" ]; then
    echo "ERROR: Test area not found: $WPT_DIR/$AREA"
    echo "Available CSS areas:"
    ls -d "$WPT_DIR/css/css-"* 2>/dev/null | sed "s|$WPT_DIR/||"
    echo ""
    echo "Other areas: dom/, url/, encoding/, fetch/, html/, webstorage/"
    exit 1
fi

# Generate HTML wrappers for .any.js tests (WPT convention).
# Honors `// META: script=...` dependency includes (e.g.
# /common/subset-tests-by-key.js for url-constructor) the way the real
# wptserve wrapper generation does. Without a ?include/?exclude variant
# query the subset helpers run every subtest, so one wrapper covers all
# variants.
for anyjs in $(find "$AREA/" -name "*.any.js" 2>/dev/null); do
    wrapper="${anyjs%.any.js}.any.html"
    if [ ! -f "$wrapper" ]; then
        {
            printf '<!DOCTYPE html>\n'
            printf '<script src="/resources/testharness.js"></script>\n'
            printf '<script src="/resources/testharnessreport.js"></script>\n'
            grep -oP '^//\s*META:\s*script=\K\S+' "$anyjs" | while read -r dep; do
                printf '<script src="%s"></script>\n' "$dep"
            done
            printf '<script src="%s"></script>\n' "$(basename "$anyjs")"
        } > "$wrapper"
    fi
done

TESTS=$(grep -rl "testharness.js" "$AREA/" 2>/dev/null | grep '\.html$' | sort)
TEST_COUNT=$(echo "$TESTS" | grep -c '^' || echo 0)

TOTAL=0
PASS_TESTS=0
FAIL_TESTS=0
ERRORS=0
TOTAL_SUBTESTS=0
TOTAL_PASS=0
TOTAL_FAIL=0

echo "=== WPT Tests: $AREA ($TEST_COUNT files) ==="
echo "=== JS Engine: $JS_ENGINE ==="
echo ""

for test in $TESTS; do
    TOTAL=$((TOTAL + 1))
    URL="http://127.0.0.1:$PORT/$test"

    # Run suzume with Xvfb, capture stderr/stdout (WPT summary is emitted in --wpt-mode)
    OUTPUT=$(DISPLAY="$DISPLAY_NUM" SUZUME_JS="$JS_ENGINE" timeout "$TIMEOUT" "$SUZUME_BIN" --wpt-mode "$URL" 2>&1 || true)

    # Extract WPT_SUMMARY line
    SUMMARY=$(echo "$OUTPUT" | grep "WPT_SUMMARY:" | tail -1)

    if [ -n "$SUMMARY" ]; then
        P=$(echo "$SUMMARY" | grep -oP 'PASS=\K\d+')
        F=$(echo "$SUMMARY" | grep -oP 'FAIL=\K\d+')
        T=$(echo "$SUMMARY" | grep -oP 'TOTAL=\K\d+')
        TOTAL_SUBTESTS=$((TOTAL_SUBTESTS + T))
        TOTAL_PASS=$((TOTAL_PASS + P))
        TOTAL_FAIL=$((TOTAL_FAIL + F))

        if [ "$F" = "0" ]; then
            PASS_TESTS=$((PASS_TESTS + 1))
        else
            FAIL_TESTS=$((FAIL_TESTS + 1))
            echo "FAIL $test ($P/$T pass)"
            echo "$OUTPUT" | grep "WPT_FAIL:" | head -5 | sed 's/^.*WPT_FAIL:/  FAIL:/'
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi

    # Progress indicator (every 10 tests)
    if [ $((TOTAL % 10)) -eq 0 ]; then
        echo "  ... $TOTAL/$TEST_COUNT tests done"
    fi
done

echo ""
echo "==========================================="
echo "  WPT Results: $AREA"
echo "==========================================="
echo "  Test files: $TOTAL (pass=$PASS_TESTS fail=$FAIL_TESTS err=$ERRORS)"
echo "  Subtests: $TOTAL_PASS/$TOTAL_SUBTESTS pass"
if [ "$TOTAL_SUBTESTS" -gt 0 ]; then
    PCT=$(awk "BEGIN{printf \"%.1f\", ($TOTAL_PASS/$TOTAL_SUBTESTS)*100}")
    echo "  Pass rate: ${PCT}%"
fi
echo "==========================================="
