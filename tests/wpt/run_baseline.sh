#!/bin/bash
# Run WPT baseline measurements across key areas
# Outputs only summary lines for each area
set -u

AREAS=(
    "dom/nodes"
    "dom/events"
    "css/css-values"
    "css/css-display"
    "css/selectors"
    "css/css-color"
    "css/cssom"
    "html/dom"
    "css/css-box"
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_FILE="$SCRIPT_DIR/baseline_results.txt"

echo "=== WPT Baseline $(date '+%Y-%m-%d %H:%M') ===" > "$RESULTS_FILE"

for area in "${AREAS[@]}"; do
    echo "Running: $area ..."
    output=$("$SCRIPT_DIR/run_wpt.sh" "$area" 2>&1)
    # Extract just the summary block
    summary=$(echo "$output" | grep -A5 "WPT Results:")
    echo "" >> "$RESULTS_FILE"
    echo "$summary" >> "$RESULTS_FILE"
    echo "  Done: $area"
    # Kill leftover processes between runs
    pkill -f "http.server 9876" 2>/dev/null
    pkill -f "Xvfb :98" 2>/dev/null
    sleep 1
done

echo ""
echo "=== All results ==="
cat "$RESULTS_FILE"
