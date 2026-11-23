#!/bin/zsh
# Runs the tests. Usage: scripts/test.sh [unit|web|all] | app [--no-build] [--interactive] [test or folder...]
# See Tests/README.md.
#   unit: the Swift unit tests (Tests/Unit, Swift Testing), a debug build of the package first.
#   web:  the web code's tests (Tests/web, Node's test runner), no packages needed.
#   all:  unit and web (default).
#   app:  the app tests (Tests/App/run.sh) on a development build at build/test/MacPopup.app, built first unless
#         --no-build, and its Yomitan API host's (Tests/Helpers). They don't run while the user's MacPopup or IINA is
#         running.
set -euo pipefail

cd "$(dirname "$0")/.."
SUITE="${1:-all}"

if [[ "$SUITE" == app ]]; then
    shift
    if [[ "${1:-}" == --no-build ]]; then
        shift
    else
        echo "== building build/test/MacPopup.app"
        MACPOPUP_APP=build/test/MacPopup.app scripts/build.sh > build/test-build.log 2>&1 \
            || { echo "FAIL: the build failed (build/test-build.log)"; exit 1; }
    fi
    result=0
    Tests/App/run.sh "$@" || result=$?
    (( result == 2 )) && exit 2
    # The Yomitan API host on its own (no app instance): when no tests were named.
    if (( $# == 0 )) || [[ "$*" == --interactive ]]; then
        echo "== Yomitan API host"
        python3 -I Tests/Helpers/yomitan-api-host.py build/test/MacPopup.app/Contents/Helpers/yomitan_api || result=1
    fi
    exit $result
fi
if [[ "$SUITE" != (unit|web|all) ]]; then
    echo "usage: scripts/test.sh [unit|web|all] | app [--no-build] [--interactive] [test or folder...]" >&2
    exit 2
fi

failed=()
if [[ "$SUITE" == unit || "$SUITE" == all ]]; then
    echo "== unit"
    swift test || failed+=(unit)
fi
if [[ "$SUITE" == web || "$SUITE" == all ]]; then
    echo "== web"
    node --test Tests/web/ || failed+=(web)
fi

if (( ${#failed} )); then
    echo "FAIL: ${failed[*]}"
    exit 1
fi
echo "PASS"
