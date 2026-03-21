#!/bin/bash
# run-compare.sh — Build docker image and run Firefox comparison tests
# Usage: ./tests/run-compare.sh [url1] [url2] ...
# Results are saved to tests/screenshots/docker-results/
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Building suzume ==="
zig build

echo ""
echo "=== Building Docker image ==="
docker build -t suzume-compare -f tests/Dockerfile.compare .

echo ""
echo "=== Running comparison tests ==="
RESULTS_DIR="$(pwd)/tests/screenshots/docker-results"
mkdir -p "$RESULTS_DIR"

docker run --rm \
    -v "$RESULTS_DIR:/app/results" \
    -v "/usr/share/fonts:/usr/share/fonts:ro" \
    --shm-size=512m \
    suzume-compare "$@"

echo ""
echo "Results saved to: $RESULTS_DIR/"
echo "  suzume/   — suzume screenshots"
echo "  firefox/  — Firefox screenshots"
echo "  diff/     — visual diff images"
