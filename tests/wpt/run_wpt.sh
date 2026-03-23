#!/bin/bash
# Run WPT testharness.js tests against suzume
# Usage: ./run_wpt.sh [css-area]
# Examples:
#   ./run_wpt.sh css-box        # run css-box tests only
#   ./run_wpt.sh css-values     # run css-values tests only
#   ./run_wpt.sh all            # run all CSS tests
set -euo pipefail

WPT_DIR="/tmp/wpt-checkout"
SUZUME_BIN="$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/suzume"
PORT=9876
TIMEOUT=10
AREA="${1:-css-box}"
DISPLAY_NUM=":98"

if [ ! -d "$WPT_DIR" ]; then
    echo "ERROR: WPT checkout not found at $WPT_DIR"
    echo "Run: git clone --depth 1 --sparse https://github.com/web-platform-tests/wpt.git $WPT_DIR"
    exit 1
fi

# Start HTTP server
cd "$WPT_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null &
HTTP_PID=$!

# Start Xvfb
Xvfb "$DISPLAY_NUM" -screen 0 800x600x24 -ac &>/dev/null &
XVFB_PID=$!
sleep 2

trap "kill $HTTP_PID $XVFB_PID 2>/dev/null" EXIT

# Find testharness test files
if [ "$AREA" = "all" ]; then
    TESTS=$(grep -rl "testharness.js" css/ 2>/dev/null | grep '\.html$' | sort)
else
    TESTS=$(grep -rl "testharness.js" "css/$AREA/" 2>/dev/null | grep '\.html$' | sort)
fi

TOTAL=0
PASS_TESTS=0
FAIL_TESTS=0
ERRORS=0
TOTAL_SUBTESTS=0
TOTAL_PASS=0
TOTAL_FAIL=0

echo "=== WPT Tests: $AREA ==="
echo ""

for test in $TESTS; do
    TOTAL=$((TOTAL + 1))
    URL="http://127.0.0.1:$PORT/$test"

    # Run suzume with Xvfb, capture output
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
            # Uncomment to see passing tests too:
            # echo "PASS $test ($P/$T)"
        else
            FAIL_TESTS=$((FAIL_TESTS + 1))
            echo "FAIL $test ($P/$T pass)"
            echo "$OUTPUT" | grep "WPT_FAIL:" | head -3 | sed 's/^.*WPT_FAIL:/  FAIL:/'
        fi
    else
        ERRORS=$((ERRORS + 1))
        # echo "ERR  $test"
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
