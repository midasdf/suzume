#!/bin/bash
# WPT Failure Analysis Script
# Runs WPT tests and classifies failures by root cause
set -uo pipefail

WPT_DIR="/tmp/wpt"
SUZUME_BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/suzume"
PORT=9876
TIMEOUT=25
AREA="${1:-dom/nodes}"
OUTPUT_DIR="${2:-/tmp/wpt-analysis}"

mkdir -p "$OUTPUT_DIR"

echo "=== WPT Failure Analysis: $AREA ==="

# Start server
cd "$WPT_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null &
HTTP_PID=$!
Xvfb :98 -screen 0 800x600x24 -ac &>/dev/null &
XVFB_PID=$!
sleep 1
trap "kill $HTTP_PID $XVFB_PID 2>/dev/null" EXIT

TESTS=$(grep -rl "testharness.js" "$AREA/" 2>/dev/null | grep '\.html$' | sort)
TEST_COUNT=$(echo "$TESTS" | grep -c '^' || echo 0)

echo "Analyzing $TEST_COUNT test files..."

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_ERR=0

for test in $TESTS; do
    OUTPUT=$(DISPLAY=:98 timeout "$TIMEOUT" "$SUZUME_BIN" "http://127.0.0.1:$PORT/$test" 2>&1 || true)
    SUMMARY=$(echo "$OUTPUT" | grep "WPT_SUMMARY:" | tail -1)

    if [ -z "$SUMMARY" ]; then
        TOTAL_ERR=$((TOTAL_ERR + 1))
        if echo "$OUTPUT" | grep -q "panic\|SEGV\|Segmentation"; then
            echo "CRASH $test" >> "$OUTPUT_DIR/err_crash.txt"
        elif echo "$OUTPUT" | grep -q "timeout"; then
            echo "TIMEOUT $test" >> "$OUTPUT_DIR/err_timeout.txt"
        else
            echo "ERR $test" >> "$OUTPUT_DIR/err_other.txt"
        fi
        continue
    fi

    P=$(echo "$SUMMARY" | grep -oP 'PASS=\K\d+')
    F=$(echo "$SUMMARY" | grep -oP 'FAIL=\K\d+')
    TOTAL_PASS=$((TOTAL_PASS + P))
    TOTAL_FAIL=$((TOTAL_FAIL + F))

    if [ "$F" -gt 0 ]; then
        echo "$OUTPUT" | grep "WPT_FAIL:" | sed 's/.*WPT_FAIL: //' | while IFS= read -r fail_msg; do
            if echo "$fail_msg" | grep -q "not a function"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_missing_function.txt"
            elif echo "$fail_msg" | grep -q "not defined\|is not a constructor"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_missing_class.txt"
            elif echo "$fail_msg" | grep -q "unexpected character\|SyntaxError"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_syntax_error.txt"
            elif echo "$fail_msg" | grep -q "assert_equals"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_wrong_value.txt"
            elif echo "$fail_msg" | grep -q "assert_throws"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_missing_throw.txt"
            elif echo "$fail_msg" | grep -q "assert_true\|assert_false"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_wrong_bool.txt"
            elif echo "$fail_msg" | grep -q "Test timed out"; then
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_timeout.txt"
            else
                echo "$test: $fail_msg" >> "$OUTPUT_DIR/fail_other.txt"
            fi
        done
    fi
done

echo ""
echo "=== Analysis Results: $AREA ==="
echo "PASS: $TOTAL_PASS  FAIL: $TOTAL_FAIL  ERR: $TOTAL_ERR"
if [ "$((TOTAL_PASS + TOTAL_FAIL))" -gt 0 ]; then
    PCT=$(awk "BEGIN{printf \"%.1f\", ($TOTAL_PASS/($TOTAL_PASS+$TOTAL_FAIL))*100}")
    echo "Pass rate: ${PCT}%"
fi
echo ""
echo "Failure categories:"
for f in "$OUTPUT_DIR"/fail_*.txt "$OUTPUT_DIR"/err_*.txt; do
    [ -f "$f" ] || continue
    count=$(wc -l < "$f")
    name=$(basename "$f" .txt)
    echo "  $name: $count"
done
