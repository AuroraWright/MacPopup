#!/bin/zsh
# Tests/App/run.sh [--interactive] [test.js | folder]...: runs app tests (every *.test.js under Tests/App by default)
# with harness/launch.sh, one at a time, and prints PASS or FAIL for each. Tests with an "// interactive" line (they move
# the real pointer, type, or make sound) only run with --interactive. MACPOPUP_TEST_APP names the development build to
# test (build/test/MacPopup.app by default; scripts/test.sh app builds it). Each test's run folder (its app log, test
# log, mock log and debug log) is in build/test/runs/<time>/.
set -uo pipefail

cd "${0:A:h:h:h}"
interactive=0
[[ "${1:-}" == --interactive ]] && { interactive=1; shift; }
APP="${MACPOPUP_TEST_APP:-build/test/MacPopup.app}"
RUNS="build/test/runs/$(date +%Y%m%d-%H%M%S)"

tests=()
for arg in "${@:-Tests/App}"; do
    if [[ -d "$arg" ]]; then
        tests+=("${(@f)$(find "$arg" -name '*.test.js' -not -path '*/harness/*' | sort)}")
    else
        tests+=("$arg")
    fi
done

passed=0 failed=() skipped=()
for t in $tests; do
    name="${${t#Tests/App/}%.test.js}"
    if (( ! interactive )) && grep -q '^// interactive' "$t"; then
        skipped+=("$name"); continue
    fi
    run="$RUNS/${name//\//-}"
    # The same test again in this run: a folder of its own.
    for (( n = 2; ; n++ )); do [[ -e "$run" ]] || break; run="$RUNS/${name//\//-}-$n"; done
    mkdir -p "$run"
    # One test instance at a time (they share the mocks' ports and the settings suite): others wait their turn.
    result=$(lockf -t 1800 build/test/.lock Tests/App/harness/launch.sh "$APP" "$t" "$run")
    code=$?
    echo "$name: $result"
    (( code == 2 )) && { echo "stopped: $name couldn't run"; exit 2; }
    (( code == 0 )) && passed=$((passed + 1)) || failed+=("$name")
done

echo
(( ${#skipped} )) && echo "skipped (interactive): ${skipped[*]}"
echo "runs: $RUNS"
if (( ${#failed} )); then
    echo "FAIL: ${#failed} of $((passed + ${#failed})) (${failed[*]})"
    exit 1
fi
echo "PASS: $passed"
