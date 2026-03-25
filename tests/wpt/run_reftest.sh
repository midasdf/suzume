#!/bin/bash
# Run WPT reftests against suzume using screenshot comparison
# Usage: ./run_reftest.sh <test.html>
# Requires: suzume with --screenshot, python3 with PIL
set -uo pipefail

SUZUME_BIN="$(cd "$(dirname "$0")/../.." && pwd)/zig-out/bin/suzume"
DISPLAY_NUM="${DISPLAY:-:98}"
TIMEOUT=20

TEST_URL="$1"
TEST_HTML="$2"  # path to HTML file
RESULT_DIR="/tmp/suzume-reftest"
mkdir -p "$RESULT_DIR"

# Extract reference from <link rel="match" href="...">
REF_HREF=$(grep -oP 'rel="match"[^>]*href="\K[^"]+' "$TEST_HTML" 2>/dev/null | head -1)
if [ -z "$REF_HREF" ]; then
    echo "SKIP: no <link rel=match> found"
    exit 0
fi

# Resolve reference URL relative to test URL
BASE_URL=$(echo "$TEST_URL" | sed 's|/[^/]*$|/|')
REF_URL="${BASE_URL}${REF_HREF}"

# Take screenshots
DISPLAY="$DISPLAY_NUM" timeout "$TIMEOUT" "$SUZUME_BIN" --screenshot "$RESULT_DIR/test.png" "$TEST_URL" 2>/dev/null
DISPLAY="$DISPLAY_NUM" timeout "$TIMEOUT" "$SUZUME_BIN" --screenshot "$RESULT_DIR/ref.png" "$REF_URL" 2>/dev/null

# Compare using Python
python3 -c "
import sys
try:
    from PIL import Image
    t = Image.open('$RESULT_DIR/test.png')
    r = Image.open('$RESULT_DIR/ref.png')
    if t.size != r.size:
        print('FAIL: size mismatch')
        sys.exit(1)
    diff = sum(1 for a, b in zip(t.tobytes(), r.tobytes()) if abs(a-b) > 2)
    total = t.size[0] * t.size[1] * 3
    pct = diff / total * 100
    if pct < 1:
        print('PASS (diff={:.2f}%)'.format(pct))
    else:
        print('FAIL (diff={:.2f}%)'.format(pct))
        sys.exit(1)
except ImportError:
    # Fallback: byte comparison
    with open('$RESULT_DIR/test.png', 'rb') as f: td = f.read()
    with open('$RESULT_DIR/ref.png', 'rb') as f: rd = f.read()
    if td == rd:
        print('PASS (identical)')
    else:
        print('FAIL (binary diff)')
        sys.exit(1)
"
