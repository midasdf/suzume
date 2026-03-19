#!/bin/bash
# WPT Visual Regression - Run all tests automatically
# Captures Firefox + suzume screenshots side by side

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
SUZUME_BIN="$SCRIPT_DIR/../../zig-out/bin/suzume"
XEPHYR_DISPLAY=":99"
WIDTH=800
HEIGHT=2000
PORT=8765

mkdir -p "$RESULTS_DIR/firefox" "$RESULTS_DIR/suzume" "$RESULTS_DIR/diff"

# Ensure clean state (only kill test-profile Firefox, not user's browser)
pkill -9 -f "firefox.*ff-wpt-profile" 2>/dev/null || true
pkill -f "python3.*http.server.*$PORT" 2>/dev/null || true
sleep 1

# Start HTTP server
cd "$SCRIPT_DIR"
python3 -m http.server $PORT > /dev/null 2>&1 &
HTTP_PID=$!
sleep 1

cleanup() {
    kill $HTTP_PID 2>/dev/null || true
    pkill -9 -f firefox 2>/dev/null || true
    pkill -f "Xephyr.*$XEPHYR_DISPLAY" 2>/dev/null || true
}
trap cleanup EXIT

ensure_xephyr() {
    if ! ps aux | grep -v grep | grep "Xephyr.*$XEPHYR_DISPLAY" > /dev/null 2>&1; then
        Xephyr $XEPHYR_DISPLAY -screen ${WIDTH}x${HEIGHT} -ac > /dev/null 2>&1 &
        sleep 2
    fi
}

capture_firefox() {
    local url="$1"
    local output="$2"
    local wait_secs="${3:-6}"

    pkill -9 -f firefox 2>/dev/null || true
    sleep 1
    ensure_xephyr

    DISPLAY=$XEPHYR_DISPLAY GDK_BACKEND=x11 MOZ_ENABLE_WAYLAND=0 \
        firefox --no-remote --new-instance -profile /tmp/ff-wpt-profile \
        "$url" > /dev/null 2>&1 &
    local pid=$!
    sleep "$wait_secs"

    # Find and maximize the content window
    local win_id
    win_id=$(DISPLAY=$XEPHYR_DISPLAY xdotool search --name "Mozilla Firefox" 2>/dev/null | head -1 || true)
    if [ -n "$win_id" ]; then
        DISPLAY=$XEPHYR_DISPLAY xdotool windowsize "$win_id" $WIDTH $HEIGHT 2>/dev/null || true
        DISPLAY=$XEPHYR_DISPLAY xdotool windowmove "$win_id" 0 0 2>/dev/null || true
        sleep 1
    fi

    # Close any popup windows
    for popup in $(DISPLAY=$XEPHYR_DISPLAY xdotool search --name "Firefox" 2>/dev/null || true); do
        if [ "$popup" != "$win_id" ]; then
            DISPLAY=$XEPHYR_DISPLAY xdotool windowclose "$popup" 2>/dev/null || true
        fi
    done
    sleep 1

    DISPLAY=$XEPHYR_DISPLAY import -window root "$output" 2>/dev/null
    kill -9 $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

capture_suzume() {
    local url="$1"
    local output="$2"
    local wait_secs="${3:-5}"

    ensure_xephyr

    DISPLAY=$XEPHYR_DISPLAY "$SUZUME_BIN" "$url" > /dev/null 2>&1 &
    local pid=$!
    sleep "$wait_secs"

    DISPLAY=$XEPHYR_DISPLAY import -window root "$output" 2>/dev/null
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# Create fresh Firefox profile
rm -rf /tmp/ff-wpt-profile
mkdir -p /tmp/ff-wpt-profile

# Collect test files
TEST_FILES=()
for f in "$SCRIPT_DIR"/css/*.html "$SCRIPT_DIR"/js/*.html; do
    [ -f "$f" ] && TEST_FILES+=("$f")
done

echo "=== WPT Visual Regression Tests ==="
echo "Tests: ${#TEST_FILES[@]}"
echo ""

for test_file in "${TEST_FILES[@]}"; do
    rel_path="${test_file#$SCRIPT_DIR/}"
    name="$(basename "$test_file" .html)"
    category="$(basename "$(dirname "$test_file")")"
    full_name="${category}_${name}"
    url="http://localhost:$PORT/$rel_path"

    wait_time=6
    [[ "$category" == "js" ]] && wait_time=8

    echo -n "[$full_name] "

    ff_img="$RESULTS_DIR/firefox/${full_name}.png"
    sz_img="$RESULTS_DIR/suzume/${full_name}.png"
    diff_img="$RESULTS_DIR/diff/${full_name}.png"

    echo -n "FF.."
    capture_firefox "$url" "$ff_img" "$wait_time"

    echo -n " SZ.."
    capture_suzume "$url" "$sz_img" "$wait_time"

    echo -n " CMP.."
    if [ -f "$ff_img" ] && [ -f "$sz_img" ]; then
        rmse=$(compare -metric RMSE "$ff_img" "$sz_img" "$diff_img" 2>&1 || true)
        echo " RMSE=$rmse"
    else
        echo " SKIP (missing)"
    fi
done

echo ""
echo "=== Done ==="
echo "Results: $RESULTS_DIR/"
