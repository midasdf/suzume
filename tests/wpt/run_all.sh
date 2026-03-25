#!/bin/bash
# Run ALL WPT tests (testharness + reftests) against suzume
# Usage: ./run_all.sh [--jobs N] [area ...]
set -uo pipefail

WPT_DIR="/tmp/wpt"
SUZUME_BIN="$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/suzume"
PORT=$((9876 + RANDOM % 100))
TIMEOUT=25
JOBS=4

AREAS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs|-j) JOBS="$2"; shift 2 ;;
        *) AREAS+=("$1"); shift ;;
    esac
done

if [ ${#AREAS[@]} -eq 0 ]; then
    AREAS=(
        css/css-box css/css-display css/css-values css/css-variables css/css-color
        css/css-text css/css-flexbox css/css-grid css/css-sizing css/css-position
        css/css-overflow css/css-backgrounds css/css-tables css/css-cascade
        css/selectors css/cssom css/cssom-view
        dom/nodes dom/events html/dom
    )
fi

[ -d "$WPT_DIR" ] || { echo "ERROR: WPT not found. Run setup first."; exit 1; }
[ -f "$SUZUME_BIN" ] || { echo "ERROR: suzume not built."; exit 1; }

cd "$WPT_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 &>/dev/null & HTTP_PID=$!
Xvfb :99 -screen 0 800x600x24 -ac &>/dev/null & XVFB_PID=$!
sleep 1
trap "kill $HTTP_PID $XVFB_PID 2>/dev/null" EXIT

GRAND_TH_PASS=0; GRAND_TH_TOTAL=0; GRAND_TH_ERR=0
GRAND_RT_PASS=0; GRAND_RT_TOTAL=0

for AREA in "${AREAS[@]}"; do
    [ -d "$WPT_DIR/$AREA" ] || continue

    TH_PASS=0; TH_TOTAL=0; TH_ERR=0
    RT_PASS=0; RT_TOTAL=0

    # Testharness tests
    while IFS= read -r test; do
        [ -z "$test" ] && continue
        URL="http://127.0.0.1:$PORT/$test"
        OUTPUT=$(DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=600 timeout "$TIMEOUT" "$SUZUME_BIN" "$URL" 2>&1 || true)
        SUMMARY=$(echo "$OUTPUT" | grep "WPT_SUMMARY:" | tail -1)
        if [ -n "$SUMMARY" ]; then
            P=$(echo "$SUMMARY" | grep -oP 'PASS=\K\d+')
            T=$(echo "$SUMMARY" | grep -oP 'TOTAL=\K\d+')
            TH_PASS=$((TH_PASS + P)); TH_TOTAL=$((TH_TOTAL + T))
        else
            TH_ERR=$((TH_ERR + 1))
        fi
    done < <(grep -rl "testharness.js" "$AREA/" 2>/dev/null | grep '\.html$' | sort)

    # Reftests
    while IFS= read -r test; do
        [ -z "$test" ] && continue
        RT_TOTAL=$((RT_TOTAL + 1))
        REF=$(grep -oP 'rel="match"[^>]*href="\K[^"]+' "$test" | head -1)
        [ -z "$REF" ] && continue
        BASE=$(dirname "$test")
        DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=600 timeout "$TIMEOUT" "$SUZUME_BIN" --screenshot /tmp/suzume-wpt-t.png "http://127.0.0.1:$PORT/$test" 2>/dev/null
        DISPLAY=:99 SUZUME_WIDTH=800 SUZUME_HEIGHT=600 timeout "$TIMEOUT" "$SUZUME_BIN" --screenshot /tmp/suzume-wpt-r.png "http://127.0.0.1:$PORT/$BASE/$REF" 2>/dev/null
        R=$(python3 -c "
from PIL import Image
try:
    t=Image.open('/tmp/suzume-wpt-t.png');r=Image.open('/tmp/suzume-wpt-r.png')
    if t.size!=r.size:print('F')
    else:
        d=sum(1 for a,b in zip(t.tobytes(),r.tobytes()) if abs(a-b)>2)
        print('P' if d/(t.size[0]*t.size[1]*3)*100<1 else 'F')
except:print('E')
" 2>&1)
        [ "$R" = "P" ] && RT_PASS=$((RT_PASS+1))
    done < <(grep -rl 'rel="match"' "$AREA/" 2>/dev/null | grep -E '\.html?$' | sort)

    TOTAL=$((TH_TOTAL + RT_TOTAL))
    PASS=$((TH_PASS + RT_PASS))
    PCT="0.0"; [ "$TOTAL" -gt 0 ] && PCT=$(awk "BEGIN{printf \"%.1f\", ($PASS/$TOTAL)*100}")
    echo "$AREA: ${PCT}% (th:$TH_PASS/$TH_TOTAL err:$TH_ERR rt:$RT_PASS/$RT_TOTAL)"

    GRAND_TH_PASS=$((GRAND_TH_PASS+TH_PASS)); GRAND_TH_TOTAL=$((GRAND_TH_TOTAL+TH_TOTAL)); GRAND_TH_ERR=$((GRAND_TH_ERR+TH_ERR))
    GRAND_RT_PASS=$((GRAND_RT_PASS+RT_PASS)); GRAND_RT_TOTAL=$((GRAND_RT_TOTAL+RT_TOTAL))
done

echo ""
echo "==========================================="
echo "  GRAND TOTAL"
echo "==========================================="
GT=$((GRAND_TH_TOTAL+GRAND_RT_TOTAL)); GP=$((GRAND_TH_PASS+GRAND_RT_PASS))
echo "  Testharness: $GRAND_TH_PASS/$GRAND_TH_TOTAL (err:$GRAND_TH_ERR)"
echo "  Reftests:    $GRAND_RT_PASS/$GRAND_RT_TOTAL"
echo "  Combined:    $GP/$GT"
[ "$GT" -gt 0 ] && echo "  Overall:     $(awk "BEGIN{printf \"%.1f\", ($GP/$GT)*100}")%"
echo "==========================================="
