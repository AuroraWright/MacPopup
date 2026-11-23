#!/bin/zsh
# Runs the tests. Usage: scripts/test.sh [unit|web|all] (default all). See Tests/README.md.
#   unit: the Swift unit tests (Tests/Unit, Swift Testing), a debug build of the package first.
#   web:  the web code's tests (Tests/web, Node's test runner), no packages needed.
set -euo pipefail

cd "$(dirname "$0")/.."
SUITE="${1:-all}"
failed=()

if [[ "$SUITE" == unit || "$SUITE" == all ]]; then
    echo "== unit"
    swift test || failed+=(unit)
fi
if [[ "$SUITE" == web || "$SUITE" == all ]]; then
    echo "== web"
    node --test Tests/web/ || failed+=(web)
fi
if [[ "$SUITE" != (unit|web|all) ]]; then
    echo "usage: scripts/test.sh [unit|web|all]" >&2
    exit 2
fi

if (( ${#failed} )); then
    echo "FAIL: ${failed[*]}"
    exit 1
fi
echo "PASS"
