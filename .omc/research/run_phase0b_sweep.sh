#!/bin/bash
# Phase 0b — 8-area sweep (re-run including dom/nodes after zombie cleanup)
# Strategy (team-lead): 2 concurrent areas × jobs=2 = 4 suzume procs per wave (fits 4GB RAM VPS).
# Each area writes .omc/research/wave2-baseline-<area>.txt.
# Distinct ports 9876..9883.
set -uo pipefail

cd /home/midasdf/suzume
LOG_DIR=".omc/research"
mkdir -p "$LOG_DIR"

run_area() {
    local area="$1"
    local port="$2"
    local safe="${area//\//-}"
    local out="$LOG_DIR/wave2-baseline-${safe}.txt"
    local start=$(date +%s)
    echo "[$(date +%H:%M:%S)] START $area port=$port"
    TIMEOUT=90 ./tests/wpt/run_wpt_parallel.sh --jobs 2 --port "$port" "$area" > "$out" 2>&1
    local rc=$?
    local end=$(date +%s)
    printf "\nELAPSED_SECONDS=%d\nEXIT=%d\n" "$((end - start))" "$rc" >> "$out"
    if ! grep -q "WPT Tests: ${area}" "$out"; then
        echo "AREA_MISMATCH=1" >> "$out"
    fi
    echo "[$(date +%H:%M:%S)] DONE  $area exit=$rc elapsed=$((end - start))s"
}
export -f run_area
export LOG_DIR

echo "=== PHASE 0b SWEEP START [$(date +%H:%M:%S)] ==="

# Wave 1: smallest areas first (webidl 28 files, dom/events 188)
echo "=== WAVE 1 (webidl + dom/events) ==="
run_area "webidl"      9876 &
P1=$!
run_area "dom/events"  9877 &
P2=$!
wait $P1 $P2
echo "=== WAVE 1 DONE [$(date +%H:%M:%S)] ==="

# Wave 2
echo "=== WAVE 2 (css/cssom + dom/nodes) ==="
run_area "css/cssom"  9878 &
P1=$!
run_area "dom/nodes"  9879 &
P2=$!
wait $P1 $P2
echo "=== WAVE 2 DONE [$(date +%H:%M:%S)] ==="

# Wave 3
echo "=== WAVE 3 (css/css-color + css/css-values) ==="
run_area "css/css-color"  9880 &
P1=$!
run_area "css/css-values" 9881 &
P2=$!
wait $P1 $P2
echo "=== WAVE 3 DONE [$(date +%H:%M:%S)] ==="

# Wave 4: largest areas
echo "=== WAVE 4 (html/dom + css/selectors) ==="
run_area "html/dom"      9882 &
P1=$!
run_area "css/selectors" 9883 &
P2=$!
wait $P1 $P2
echo "=== WAVE 4 DONE [$(date +%H:%M:%S)] ==="

echo "=== PHASE 0b SWEEP ALL DONE [$(date +%H:%M:%S)] ==="
