#!/bin/bash
# compare-firefox.sh — Screenshot comparison between suzume and Firefox
# Usage: ./compare-firefox.sh [url1] [url2] ...
# If no URLs given, uses a default list of test sites.
set -euo pipefail

RESULTS_DIR="/app/results"
SUZUME_DIR="$RESULTS_DIR/suzume"
FIREFOX_DIR="$RESULTS_DIR/firefox"
DIFF_DIR="$RESULTS_DIR/diff"
DISPLAY_NUM=":50"
WIDTH=1280
HEIGHT=900
LOAD_WAIT=10
TIMEOUT=45

# Default test URLs
DEFAULT_URLS=(
    "https://example.com"
    "https://news.ycombinator.com"
    "https://old.reddit.com"
    "https://en.wikipedia.org/wiki/Web_browser"
    "https://lobste.rs"
    "https://stackoverflow.com/questions/927358/how-do-i-undo-the-most-recent-local-commits-in-git"
    "https://dev.to"
    "https://info.cern.ch"
)

if [ $# -gt 0 ]; then
    URLS=("$@")
else
    URLS=("${DEFAULT_URLS[@]}")
fi

# Ensure output directories exist (volume mount may override Dockerfile mkdir)
mkdir -p "$SUZUME_DIR" "$FIREFOX_DIR" "$DIFF_DIR"

# Start Xvfb
echo "=== Starting Xvfb on $DISPLAY_NUM (${WIDTH}x${HEIGHT}) ==="
Xvfb "$DISPLAY_NUM" -screen 0 "${WIDTH}x${HEIGHT}x24" -ac +extension GLX +render -noreset &
XVFB_PID=$!
sleep 2
export DISPLAY="$DISPLAY_NUM"

# Verify display
xdpyinfo -display "$DISPLAY_NUM" > /dev/null 2>&1 || {
    echo "ERROR: Xvfb failed to start"
    exit 1
}

url_to_filename() {
    echo "$1" | sed 's|https\?://||; s|/|_|g; s|[^a-zA-Z0-9._-]|_|g' | head -c 80
}

echo ""
echo "=== Testing ${#URLS[@]} URLs ==="
echo ""

PASS=0
FAIL=0
RESULTS=()

for url in "${URLS[@]}"; do
    fname="$(url_to_filename "$url").png"
    echo "--- $url ---"

    # 1) Firefox headless screenshot (uses its own headless rendering, no X needed)
    echo "  [Firefox] Taking screenshot..."
    timeout "$TIMEOUT" firefox --headless --window-size="${WIDTH},${HEIGHT}" \
        --screenshot "$FIREFOX_DIR/$fname" "$url" 2>/dev/null || true

    # 2) Suzume screenshot — run in Xvfb then capture root window
    echo "  [Suzume]  Taking screenshot..."
    /app/suzume --url "$url" &
    SUZUME_PID=$!

    # Wait for page to load and render
    sleep "$LOAD_WAIT"

    # Capture the entire Xvfb root window
    xwd -display "$DISPLAY_NUM" -root -silent > /tmp/screen.xwd 2>/dev/null || true
    if [ -s /tmp/screen.xwd ]; then
        magick /tmp/screen.xwd "$SUZUME_DIR/$fname" 2>/dev/null || \
            convert /tmp/screen.xwd "$SUZUME_DIR/$fname" 2>/dev/null || true
        rm -f /tmp/screen.xwd
    fi

    # Kill suzume
    kill "$SUZUME_PID" 2>/dev/null || true
    wait "$SUZUME_PID" 2>/dev/null || true
    sleep 1

    # 3) Generate diff image if both exist
    if [ -f "$FIREFOX_DIR/$fname" ] && [ -f "$SUZUME_DIR/$fname" ]; then
        # Crop both to content area (top portion) and resize to same dimensions
        # Firefox screenshots are full-page height, suzume captures Xvfb viewport
        # Crop to viewport-sized region from top for fair comparison
        # Resize both to same dimensions for fair comparison
        magick "$FIREFOX_DIR/$fname" -resize "${WIDTH}x${HEIGHT}!" "/tmp/ff_resized.png" 2>/dev/null || \
            convert "$FIREFOX_DIR/$fname" -resize "${WIDTH}x${HEIGHT}!" "/tmp/ff_resized.png" 2>/dev/null || true
        magick "$SUZUME_DIR/$fname" -resize "${WIDTH}x${HEIGHT}!" "/tmp/sz_resized.png" 2>/dev/null || \
            convert "$SUZUME_DIR/$fname" -resize "${WIDTH}x${HEIGHT}!" "/tmp/sz_resized.png" 2>/dev/null || true

        if [ -f "/tmp/ff_resized.png" ] && [ -f "/tmp/sz_resized.png" ]; then
            # Compare pixel differences
            DIFF_RESULT=$(compare -metric AE \
                "/tmp/sz_resized.png" \
                "/tmp/ff_resized.png" \
                "$DIFF_DIR/$fname" 2>&1 || true)
            DIFF_PIXELS=$(echo "$DIFF_RESULT" | grep -oP '^[\d.]+' || echo "N/A")

            TOTAL_PIXELS=$((WIDTH * HEIGHT))
            if [ "$DIFF_PIXELS" != "N/A" ] && [ "$TOTAL_PIXELS" -gt 0 ]; then
                DIFF_PCT=$(awk "BEGIN{printf \"%.1f\", ($DIFF_PIXELS/$TOTAL_PIXELS)*100}")
                echo "  [Diff]    ${DIFF_PCT}% pixels differ ($DIFF_PIXELS / $TOTAL_PIXELS)"
                RESULTS+=("$url | ${DIFF_PCT}% diff")
            else
                echo "  [Diff]    $DIFF_RESULT"
                RESULTS+=("$url | compare: $DIFF_RESULT")
            fi
            PASS=$((PASS + 1))
            rm -f /tmp/ff_resized.png /tmp/sz_resized.png
        else
            echo "  [SKIP]    Resize failed"
            RESULTS+=("$url | SKIP: resize failed")
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  [SKIP]    Missing screenshot(s)"
        [ ! -f "$FIREFOX_DIR/$fname" ] && echo "           Firefox: missing"
        [ ! -f "$SUZUME_DIR/$fname" ] && echo "           Suzume: missing"
        RESULTS+=("$url | SKIP: missing screenshot")
        FAIL=$((FAIL + 1))
    fi
    echo ""
done

# Summary
echo "==========================================="
echo "  COMPARISON RESULTS"
echo "==========================================="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""
echo "  Compared: $PASS  |  Skipped: $FAIL"
echo "  Results saved to: $RESULTS_DIR/"
echo "==========================================="

# Cleanup
kill "$XVFB_PID" 2>/dev/null || true
