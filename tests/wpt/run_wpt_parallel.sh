#!/bin/bash
# Run WPT testharness.js tests against suzume with parallel execution
# Usage: ./run_wpt_parallel.sh [--jobs N] <area>
# Examples:
#   ./run_wpt_parallel.sh --jobs 4 css/css-box
#   ./run_wpt_parallel.sh --jobs 8 css/css-values
#   ./run_wpt_parallel.sh css/css-display
set -uo pipefail

WPT_DIR="/tmp/wpt"
SUZUME_BIN="$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/suzume"
PORT=9876
TIMEOUT=20
JOBS=4

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs|-j) JOBS="$2"; shift 2 ;;
        setup)
            echo "=== Setting up WPT ==="
            [ -d "$WPT_DIR" ] || git clone --depth 1 https://github.com/web-platform-tests/wpt.git "$WPT_DIR"
            grep -q "suzume browser" "$WPT_DIR/resources/testharnessreport.js" 2>/dev/null || cat >> "$WPT_DIR/resources/testharnessreport.js" << 'JSEOF'

// suzume browser WPT integration
(function() {
    add_completion_callback(function(tests, harness_status) {
        var pass = 0, fail = 0, total = tests.length;
        for (var i = 0; i < tests.length; i++) {
            if (tests[i].status === 0) { pass++; }
            else { fail++; console.log("WPT_FAIL: " + tests[i].name + " — " + (tests[i].message || "")); }
        }
        console.log("WPT_SUMMARY: PASS=" + pass + " FAIL=" + fail + " TOTAL=" + total);
    });
})();
JSEOF
            exit 0 ;;
        *) AREA="$1"; shift ;;
    esac
done

AREA="${AREA:-css/css-box}"
# Legacy css-X format
case "$AREA" in css-*) AREA="css/$AREA" ;; esac

[ -d "$WPT_DIR" ] || { echo "ERROR: Run '$0 setup' first."; exit 1; }
[ -f "$SUZUME_BIN" ] || { echo "ERROR: Run 'zig build' first."; exit 1; }

# Start shared HTTP server
cd "$WPT_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null &
HTTP_PID=$!

# Start Xvfb displays (one per job)
XVFB_PIDS=""
for i in $(seq 0 $((JOBS-1))); do
    DISP=$((98 + i))
    Xvfb ":$DISP" -screen 0 800x600x24 -ac &>/dev/null &
    XVFB_PIDS="$XVFB_PIDS $!"
done
sleep 1

cleanup() {
    kill $HTTP_PID $XVFB_PIDS 2>/dev/null
}
trap cleanup EXIT

# Find test files
TESTS=$(grep -rl "testharness.js" "$AREA/" 2>/dev/null | grep '\.html$' | sort)
TEST_COUNT=$(echo "$TESTS" | grep -c '^' || echo 0)

echo "=== WPT Tests: $AREA ($TEST_COUNT files, $JOBS parallel) ==="

# Temp dir for results
TMPDIR=$(mktemp -d)

# Run tests in parallel using xargs
run_single_test() {
    local test="$1"
    local job_id="$2"
    local disp=$((98 + (job_id % JOBS)))
    local url="http://127.0.0.1:$PORT/$test"
    local output
    output=$(DISPLAY=":$disp" timeout "$TIMEOUT" "$SUZUME_BIN" "$url" 2>&1 || true)
    local summary
    summary=$(echo "$output" | grep "WPT_SUMMARY:" | tail -1)
    if [ -n "$summary" ]; then
        local p f t
        p=$(echo "$summary" | grep -oP 'PASS=\K\d+')
        f=$(echo "$summary" | grep -oP 'FAIL=\K\d+')
        t=$(echo "$summary" | grep -oP 'TOTAL=\K\d+')
        echo "$p $f $t $test" >> "$TMPDIR/results.txt"
        if [ "$f" -gt 0 ]; then
            echo "FAIL $test ($p/$t pass)"
            echo "$output" | grep "WPT_FAIL:" | head -3 | sed 's/^.*WPT_FAIL:/  FAIL:/'
        fi
    else
        echo "0 0 0 ERR:$test" >> "$TMPDIR/results.txt"
    fi
}
export -f run_single_test
export SUZUME_BIN PORT TIMEOUT JOBS TMPDIR

# Execute with parallel (GNU parallel or xargs fallback)
echo "$TESTS" | nl -ba | while read num test; do
    echo "$test $((num % JOBS))"
done | xargs -P "$JOBS" -L1 bash -c 'run_single_test "$0" "$1"'

# Aggregate results
TOTAL=0; PASS_TESTS=0; FAIL_TESTS=0; ERRORS=0
TOTAL_SUBTESTS=0; TOTAL_PASS=0; TOTAL_FAIL=0

if [ -f "$TMPDIR/results.txt" ]; then
    while IFS=' ' read -r p f t test; do
        if [[ "$test" == ERR:* ]]; then
            ERRORS=$((ERRORS + 1))
        else
            TOTAL=$((TOTAL + 1))
            TOTAL_PASS=$((TOTAL_PASS + p))
            TOTAL_FAIL=$((TOTAL_FAIL + f))
            TOTAL_SUBTESTS=$((TOTAL_SUBTESTS + t))
            if [ "$f" = "0" ]; then
                PASS_TESTS=$((PASS_TESTS + 1))
            else
                FAIL_TESTS=$((FAIL_TESTS + 1))
            fi
        fi
    done < "$TMPDIR/results.txt"
fi

echo ""
echo "==========================================="
echo "  WPT Results: $AREA"
echo "==========================================="
echo "  Test files: $((TOTAL + ERRORS)) (pass=$PASS_TESTS fail=$FAIL_TESTS err=$ERRORS)"
echo "  Subtests: $TOTAL_PASS/$TOTAL_SUBTESTS pass"
if [ "$TOTAL_SUBTESTS" -gt 0 ]; then
    PCT=$(awk "BEGIN{printf \"%.1f\", ($TOTAL_PASS/$TOTAL_SUBTESTS)*100}")
    echo "  Pass rate: ${PCT}%"
fi
echo "==========================================="

rm -rf "$TMPDIR"
