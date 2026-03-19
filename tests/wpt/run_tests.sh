#!/bin/bash
# WPT Visual Regression Test Runner
# Usage: ./run_tests.sh [test_file.html]
# If no argument, runs all tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
SUZUME_BIN="$SCRIPT_DIR/../../zig-out/bin/suzume"
XEPHYR_DISPLAY=":99"
WIDTH=800
HEIGHT=2000
PORT=8765
WAIT_RENDER=4   # seconds to wait for page render
WAIT_JS=6       # seconds for JS-heavy pages

mkdir -p "$RESULTS_DIR/firefox" "$RESULTS_DIR/suzume" "$RESULTS_DIR/diff"

# Start HTTP server
echo "=== Starting HTTP server on port $PORT ==="
cd "$SCRIPT_DIR"
python3 -m http.server $PORT &
HTTP_PID=$!
trap "kill $HTTP_PID 2>/dev/null; kill_xephyr 2>/dev/null" EXIT

sleep 1

kill_xephyr() {
    pkill -f "Xephyr.*$XEPHYR_DISPLAY" 2>/dev/null || true
}

# Collect test files
if [ $# -gt 0 ]; then
    TEST_FILES=("$@")
else
    TEST_FILES=()
    for f in "$SCRIPT_DIR"/css/*.html "$SCRIPT_DIR"/js/*.html; do
        [ -f "$f" ] && TEST_FILES+=("$f")
    done
fi

echo "=== Found ${#TEST_FILES[@]} test files ==="

run_firefox() {
    local url="$1"
    local output="$2"
    local wait="$3"

    kill_xephyr
    sleep 0.5

    Xephyr $XEPHYR_DISPLAY -screen ${WIDTH}x${HEIGHT} -ac &
    sleep 1

    DISPLAY=$XEPHYR_DISPLAY firefox --no-remote --new-instance \
        -width $WIDTH -height $HEIGHT "$url" &
    FF_PID=$!
    sleep "$wait"

    DISPLAY=$XEPHYR_DISPLAY import -window root "$output"
    kill $FF_PID 2>/dev/null || true
    wait $FF_PID 2>/dev/null || true
    kill_xephyr
    sleep 0.5
}

run_suzume() {
    local url="$1"
    local output="$2"
    local wait="$3"

    kill_xephyr
    sleep 0.5

    Xephyr $XEPHYR_DISPLAY -screen ${WIDTH}x${HEIGHT} -ac &
    sleep 1

    DISPLAY=$XEPHYR_DISPLAY "$SUZUME_BIN" "$url" &
    SZ_PID=$!
    sleep "$wait"

    DISPLAY=$XEPHYR_DISPLAY import -window root "$output"
    kill $SZ_PID 2>/dev/null || true
    wait $SZ_PID 2>/dev/null || true
    kill_xephyr
    sleep 0.5
}

compare_images() {
    local ff_img="$1"
    local sz_img="$2"
    local diff_img="$3"
    local name="$4"

    if [ ! -f "$ff_img" ] || [ ! -f "$sz_img" ]; then
        echo "  SKIP: Missing screenshot for $name"
        return
    fi

    # Get metrics
    local metric
    metric=$(compare -metric AE "$ff_img" "$sz_img" "$diff_img" 2>&1 || true)

    # Percentage difference
    local pct
    pct=$(compare -metric RMSE "$ff_img" "$sz_img" null: 2>&1 || true)

    echo "  Pixel diff: $metric | RMSE: $pct"
}

echo ""
echo "=== Running tests ==="
echo ""

for test_file in "${TEST_FILES[@]}"; do
    # Get relative path for URL
    rel_path="${test_file#$SCRIPT_DIR/}"
    name="$(basename "$test_file" .html)"
    category="$(basename "$(dirname "$test_file")")"
    full_name="${category}_${name}"
    url="http://localhost:$PORT/$rel_path"

    # Determine wait time (JS tests need more time)
    wait_time=$WAIT_RENDER
    if [[ "$category" == "js" ]]; then
        wait_time=$WAIT_JS
    fi

    echo "--- Testing: $full_name ---"
    echo "  URL: $url"

    ff_img="$RESULTS_DIR/firefox/${full_name}.png"
    sz_img="$RESULTS_DIR/suzume/${full_name}.png"
    diff_img="$RESULTS_DIR/diff/${full_name}.png"

    echo "  [1/3] Firefox..."
    run_firefox "$url" "$ff_img" "$wait_time"

    echo "  [2/3] suzume..."
    run_suzume "$url" "$sz_img" "$wait_time"

    echo "  [3/3] Comparing..."
    compare_images "$ff_img" "$sz_img" "$diff_img" "$full_name"

    echo ""
done

echo "=== Done! Results in $RESULTS_DIR ==="
echo "  Firefox: $RESULTS_DIR/firefox/"
echo "  suzume:  $RESULTS_DIR/suzume/"
echo "  Diffs:   $RESULTS_DIR/diff/"
