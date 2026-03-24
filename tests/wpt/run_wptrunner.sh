#!/bin/bash
# Run WPT tests against suzume via wptrunner
# Usage:
#   ./run_wptrunner.sh setup          # First-time setup (clone WPT, install packages)
#   ./run_wptrunner.sh css/css-box/   # Run specific test directory
#   ./run_wptrunner.sh --processes 4 css/css-values/  # Parallel execution
#   ./run_wptrunner.sh all            # Run all tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUZUME_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUZUME_BIN="$SUZUME_DIR/zig-out/bin/suzume"
WPT_DIR="/tmp/wpt"

if [ "${1:-}" = "setup" ]; then
    echo "=== Setting up WPT test infrastructure ==="

    # Clone WPT if not present
    if [ ! -d "$WPT_DIR" ]; then
        echo "Cloning WPT repository..."
        git clone --depth 1 https://github.com/web-platform-tests/wpt.git "$WPT_DIR"
    else
        echo "WPT already cloned at $WPT_DIR"
    fi

    # Install wptrunner from WPT tools
    echo "Installing wptrunner..."
    pip install --quiet "$WPT_DIR/tools/wptrunner" 2>/dev/null || \
        pip install --quiet --break-system-packages "$WPT_DIR/tools/wptrunner"

    # Install suzume wptrunner product adapter
    echo "Installing wpt-suzume adapter..."
    pip install --quiet -e "$SCRIPT_DIR/wpt-suzume" 2>/dev/null || \
        pip install --quiet --break-system-packages -e "$SCRIPT_DIR/wpt-suzume"

    # Set up hosts file if needed
    if ! grep -q "web-platform.test" /etc/hosts 2>/dev/null; then
        echo "Adding WPT hosts entries (requires sudo)..."
        cd "$WPT_DIR" && python3 ./wpt make-hosts-file | sudo tee -a /etc/hosts > /dev/null
    else
        echo "WPT hosts already configured"
    fi

    # Build suzume
    echo "Building suzume..."
    cd "$SUZUME_DIR" && zig build

    echo ""
    echo "=== Setup complete! ==="
    echo "Run tests with: $0 css/css-box/"
    exit 0
fi

# Check prerequisites
if [ ! -d "$WPT_DIR" ]; then
    echo "ERROR: WPT not found. Run '$0 setup' first."
    exit 1
fi

if [ ! -f "$SUZUME_BIN" ]; then
    echo "ERROR: suzume binary not found. Run 'zig build' first."
    exit 1
fi

# Parse arguments
PROCESSES=1
TEST_PATH=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --processes|-p)
            PROCESSES="$2"
            shift 2
            ;;
        --*)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        *)
            TEST_PATH="$1"
            shift
            ;;
    esac
done

if [ -z "$TEST_PATH" ]; then
    echo "Usage: $0 [--processes N] <test-path>"
    echo "Examples:"
    echo "  $0 css/css-box/"
    echo "  $0 --processes 4 css/css-values/"
    echo "  $0 dom/"
    echo "  $0 url/"
    exit 1
fi

# Run wptrunner
cd "$WPT_DIR"
echo "=== Running WPT: $TEST_PATH (processes=$PROCESSES) ==="
python3 ./wpt run \
    --binary "$SUZUME_BIN" \
    --processes "$PROCESSES" \
    --timeout-multiplier 2 \
    --log-mach - \
    "${EXTRA_ARGS[@]}" \
    suzume "$TEST_PATH" 2>&1
