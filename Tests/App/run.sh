#!/bin/zsh
# Tests/App/run.sh [--interactive] [--network] [test.js | folder]...: runs app tests (every *.test.js under Tests/App by
# default) with harness/launch.sh, one at a time, and prints PASS or FAIL for each. Tests with an "// interactive" line
# (they move the real pointer, type, or make sound) only run with --interactive, and those with a "// network" line
# (they send something to a service on the internet) only with --network too. MACPOPUP_TEST_APP names the development
# build to test (build/test/MacPopup.app by default; scripts/test.sh app builds it). Each test's run folder (its app
# log, test log, mock log and debug log) is build/test/runs/<time>/<test>/.
set -uo pipefail

cd "${0:A:h:h:h}"
interactive=0 network=0
while [[ "${1:-}" == --(interactive|network) ]]; do
    [[ "$1" == --interactive ]] && interactive=1 || network=1
    shift
done
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

passed=0 failed=() skipped=() notrun=()
# Ctrl-C: launch.sh stops the test instance and says how it went; the tests after it aren't run.
interrupted=0
trap 'interrupted=1' INT
for t in $tests; do
    name="${${t#Tests/App/}%.test.js}"
    if { (( ! interactive )) && grep -q '^// interactive' "$t" } || { (( ! network )) && grep -q '^// network' "$t" }; then
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
    if (( code == 3 )); then
        notrun+=("$name")
    elif (( code == 0 )); then
        passed=$((passed + 1))
    else
        failed+=("$name")
    fi
    (( interrupted )) && { echo "interrupted"; break; }
done

echo
(( ${#skipped} )) && echo "skipped (interactive or network): ${skipped[*]}"
(( ${#notrun} )) && echo "not run: ${notrun[*]}"
echo "runs: $RUNS"
if (( ${#failed} || ${#notrun} || interrupted )); then
    echo "FAIL: ${#failed} of $((passed + ${#failed})) (${failed[*]})${notrun:+, ${#notrun} not run}"
    exit 1
fi
echo "PASS: $passed"
