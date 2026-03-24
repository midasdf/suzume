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
TIMEOUT=20
AREA="${1:-css/css-box}"
DISPLAY_NUM=":98"

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
    add_completion_callback(function(tests, harness_status) {
        var pass = 0, fail = 0, total = tests.length;
        for (var i = 0; i < tests.length; i++) {
            if (tests[i].status === 0) {
                pass++;
            } else {
                fail++;
                console.log("WPT_FAIL: " + tests[i].name + " — " + (tests[i].message || ""));
            }
        }
        console.log("WPT_SUMMARY: PASS=" + pass + " FAIL=" + fail + " TOTAL=" + total);
    });
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

# Start HTTP server
cd "$WPT_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null &
HTTP_PID=$!

# Start Xvfb
Xvfb "$DISPLAY_NUM" -screen 0 800x600x24 -ac &>/dev/null &
XVFB_PID=$!
sleep 1

trap "kill $HTTP_PID $XVFB_PID 2>/dev/null" EXIT

# Find testharness test files
if [ ! -d "$WPT_DIR/$AREA" ]; then
    echo "ERROR: Test area not found: $WPT_DIR/$AREA"
    echo "Available CSS areas:"
    ls -d "$WPT_DIR/css/css-"* 2>/dev/null | sed "s|$WPT_DIR/||"
    echo ""
    echo "Other areas: dom/, url/, encoding/, fetch/, html/, webstorage/"
    exit 1
fi

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
echo ""

for test in $TESTS; do
    TOTAL=$((TOTAL + 1))
    URL="http://127.0.0.1:$PORT/$test"

    # Run suzume with Xvfb, capture stderr (console output)
    OUTPUT=$(DISPLAY="$DISPLAY_NUM" timeout "$TIMEOUT" "$SUZUME_BIN" "$URL" 2>&1 || true)

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
