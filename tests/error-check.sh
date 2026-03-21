#!/bin/bash
# error-check.sh — Count JS errors per site in suzume (runs in Docker/Xvfb)
# Usage: ./error-check.sh [url1] [url2] ...
set -euo pipefail

DISPLAY_NUM=":50"
LOAD_WAIT=15

DEFAULT_URLS=(
    "https://news.ycombinator.com"
    "https://old.reddit.com"
    "https://lobste.rs"
    "https://github.com/nickel-org/nickel.rs"
    "https://dev.to"
    "https://stackoverflow.com/questions/927358"
)

if [ $# -gt 0 ]; then
    URLS=("$@")
else
    URLS=("${DEFAULT_URLS[@]}")
fi

# Start Xvfb
Xvfb "$DISPLAY_NUM" -screen 0 1280x900x24 -ac +extension GLX +render -noreset &>/dev/null &
sleep 2
export DISPLAY="$DISPLAY_NUM"

echo "=== suzume JS Error Check ==="
echo ""

for url in "${URLS[@]}"; do
    # Run suzume, capture stderr+stdout, count errors
    OUTPUT=$(/app/suzume --url "$url" 2>&1 &
    PID=$!
    sleep "$LOAD_WAIT"
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null || true)

    ERROR_COUNT=$(echo "$OUTPUT" | grep -c '\[JS:ERROR\]' || true)
    ERRORS=$(echo "$OUTPUT" | grep '\[JS:ERROR\]' | sed 's/\[JS:ERROR\] //' || true)

    if [ "$ERROR_COUNT" -eq 0 ]; then
        printf "  %-50s  ✅ 0 errors\n" "$url"
    else
        printf "  %-50s  ❌ %d errors\n" "$url" "$ERROR_COUNT"
        echo "$ERRORS" | while read -r line; do
            printf "    → %s\n" "$line"
        done
    fi
done

echo ""
echo "=== Done ==="
kill %1 2>/dev/null || true
