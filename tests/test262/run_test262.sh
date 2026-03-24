#!/bin/bash
# Run test262 against QuickJS-ng (suzume's JS engine)
# Usage:
#   ./run_test262.sh setup       # Build QuickJS-ng standalone
#   ./run_test262.sh             # Run full test262 suite
#   ./run_test262.sh built-ins   # Run specific category
set -euo pipefail

QJS_DIR="/tmp/quickjs-ng-full"
TEST262_DIR="/tmp/test262"
RUN_TEST262="$QJS_DIR/build/run-test262"

if [ "${1:-}" = "setup" ]; then
    echo "=== Setting up test262 infrastructure ==="

    if [ ! -d "$QJS_DIR" ]; then
        echo "ERROR: QuickJS-ng not cloned. Run:"
        echo "  git clone --depth 1 https://github.com/quickjs-ng/quickjs.git $QJS_DIR"
        exit 1
    fi

    if [ ! -d "$TEST262_DIR" ]; then
        echo "ERROR: test262 not cloned. Run:"
        echo "  git clone --depth 1 https://github.com/nicolo-ribaudo/test262.git $TEST262_DIR"
        exit 1
    fi

    echo "Building QuickJS-ng..."
    cd "$QJS_DIR"
    cmake -B build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3
    cmake --build build -j$(nproc) 2>&1 | tail -5

    if [ -f "$RUN_TEST262" ]; then
        echo "Build successful: $RUN_TEST262"
    else
        echo "ERROR: run-test262 binary not found after build"
        exit 1
    fi

    echo ""
    echo "=== Setup complete! ==="
    echo "Run tests with: $0"
    exit 0
fi

# Check prerequisites
if [ ! -f "$RUN_TEST262" ]; then
    echo "ERROR: run-test262 not found. Run '$0 setup' first."
    exit 1
fi

if [ ! -d "$TEST262_DIR/test" ]; then
    echo "ERROR: test262 not found at $TEST262_DIR"
    exit 1
fi

# Run test262
cd "$QJS_DIR"
echo "=== Running test262 against QuickJS-ng ==="
echo "Test262 dir: $TEST262_DIR"
echo "Runner: $RUN_TEST262"
echo ""

if [ $# -gt 0 ] && [ "$1" != "setup" ]; then
    # Run specific test category
    "$RUN_TEST262" -d "$TEST262_DIR" -f "$1" 2>&1
else
    # Run full suite
    "$RUN_TEST262" -d "$TEST262_DIR" 2>&1
fi
