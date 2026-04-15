#!/bin/bash
# Run WPT baseline measurements across key areas in parallel.
# Each area launches its own http.server on a distinct port so
# parallel runs never share a server (avoids contention/port conflicts).
#
# Usage:
#   ./run_all_baselines.sh [--jobs N]        # N workers per area (default 4)
#   ./run_all_baselines.sh --jobs 8          # 8 workers per area
#
# Python 3's http.server uses ThreadingHTTPServer by default, so
# concurrent requests from multiple suzume workers on the same port
# are handled without blocking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS=4
BASE_PORT=9876  # area 0 gets 9876, area 1 gets 9877, etc.

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs|-j) JOBS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

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

RESULTS_FILE="$SCRIPT_DIR/baseline_results.txt"
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo "=== WPT Parallel Baseline $(date '+%Y-%m-%d %H:%M') ===" | tee "$RESULTS_FILE"
echo "  Areas: ${#AREAS[@]}  Jobs-per-area: $JOBS  Base-port: $BASE_PORT"
echo ""

# Run one area; called in background subshells
run_area() {
    local area="$1"
    local port="$2"
    local idx="$3"
    local outfile="$TMPDIR/area_${idx}.txt"

    echo "[area $idx] Starting: $area on port $port"
    "$SCRIPT_DIR/run_wpt_parallel.sh" --jobs "$JOBS" --port "$port" "$area" \
        > "$outfile" 2>&1
    echo "[area $idx] Done: $area"
}
export -f run_area
export SCRIPT_DIR JOBS

PIDS=()
for i in "${!AREAS[@]}"; do
    PORT=$((BASE_PORT + i))
    run_area "${AREAS[$i]}" "$PORT" "$i" &
    PIDS+=($!)
done

# Wait for all background jobs
FAIL=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=$((FAIL + 1))
done

echo ""
echo "==========================================="
echo "  Parallel baseline complete ($FAIL area failures)"
echo "==========================================="
echo ""

# Collect and display results in area order
for i in "${!AREAS[@]}"; do
    outfile="$TMPDIR/area_${i}.txt"
    echo "--- ${AREAS[$i]} ---"
    if [ -f "$outfile" ]; then
        # Print the summary block
        grep -A6 "WPT Results:" "$outfile" || tail -10 "$outfile"
    else
        echo "  (no output)"
    fi
    echo ""
done | tee -a "$RESULTS_FILE"

echo "Results saved to: $RESULTS_FILE"
