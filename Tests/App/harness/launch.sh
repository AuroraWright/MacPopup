#!/bin/zsh
# launch.sh <MacPopup.app> <test.js> <run folder>: runs one app test and prints PASS or FAIL (exit 0, 1; 2 when it
# couldn't run). The test instance:
# - only starts when the user's MacPopup (build/ or /Applications) and IINA aren't running, nor another test instance,
#   and only from a development build (scripts/build.sh marks them), which reads the test environment variables: the app
#   as shipped would ignore them and use the user's settings;
# - has its own settings (the defaults, base-settings.json, then the test's "// settings:" line), pasteboard, debug
#   log, models, transcripts and browser folders, all in the run folder, and talks to mock.py instead of AnkiConnect and
#   Yomitan;
# - runs test-lib.js and the test in its pages, and is stopped at "TEST done" or after the test's "// timeout:" (s, 60).
# Header lines in the test file:
# - "// mock: MOCK_IMAGES=1 …": mock.py's switches;
# - "// clipboard: <text>": put on the instance's pasteboard once the test is ready;
# - "// setup: <command>": run (zsh) before the launch, e.g. to make a sound file in "$RUN";
# - "// env: NAME=value …": more environment for the app ($RUN, $HARNESS and $REPO expanded);
# - "// beside: <command>": run (zsh) from just before the launch until the test ends, e.g. a test window for OCR mode
#   to read (output in beside.log; stopped with its children);
# - "// driver: <command>": run (zsh) beside the instance once it's started, for what a page script can't do (Settings
#   is SwiftUI, Accessibility, a fake Yomitan): with RUN, HARNESS, REPO, SUITE and PID (the app's) set, it prints
#   "TEST ok …"/"TEST FAIL …" lines like a page's checks and must exit 0. The test then lasts until it exits (and the
#   page's test, if the file has one, has logged "TEST done").
# The user's settings are exported before and compared after: a change fails the test and says where the copy is.
set -uo pipefail

APP=${1:A} TEST=${2:A} RUN=${3:A}
HARNESS=${0:A:h}
REPO=${HARNESS:h:h:h}
SUITE=com.aury.macpopup.test.app

if pgrep -f "^($REPO/build/MacPopup.app|/Applications/MacPopup.app)/Contents/MacOS/MacPopup|^/Applications/IINA.app/Contents/MacOS/IINA" >/dev/null; then
    echo "NOT RUN: the user's MacPopup or IINA is running"; exit 2
fi
if pgrep -f "^$APP/Contents/MacOS/MacPopup" >/dev/null; then
    echo "NOT RUN: another test instance is running"; exit 2
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :MacPopupDevelopment' "$APP/Contents/Info.plist" 2>/dev/null)" != true ]]; then
    echo "NOT RUN: $APP isn't a development build (MACPOPUP_APP=<path> scripts/build.sh makes one)"; exit 2
fi

header() { sed -n "s|^// $1: ||p" "$TEST" | head -1; }
SETTINGS=$(header settings) MOCK=$(header mock) CLIPBOARD=$(header clipboard) TIMEOUT=$(header timeout)
SETUP=$(header setup) ENV=$(header env) DRIVER=$(header driver) BESIDE=$(header beside)
export RUN HARNESS REPO SUITE

mkdir -p "$RUN/models" "$RUN/browser" "$RUN/Library/Caches/com.aury.macpopup/Transcripts"
cat "$HARNESS/test-lib.js" "$TEST" > "$RUN/script.js"
PB="$REPO/build/test/tools/pb"
if [[ -n "$CLIPBOARD" && ( ! -x "$PB" || "$HARNESS/pb.swift" -nt "$PB" ) ]]; then
    mkdir -p "${PB:h}" && swiftc -o "$PB" "$HARNESS/pb.swift" || { echo "NOT RUN: couldn't build pb"; exit 2; }
fi

if [[ -n "$SETUP" ]] && ! zsh -c "$SETUP" > "$RUN/setup.log" 2>&1; then
    echo "NOT RUN: the setup failed ($RUN/setup.log)"; exit 2
fi
APP_ENV=(${(e)=ENV})

defaults export com.aury.macpopup "$RUN/user-settings.plist"
settings=$(python3 -I -c 'import json, sys
s = json.load(open(sys.argv[1])); s.update(json.loads(sys.argv[2] or "{}")); print(json.dumps(s))' \
    "$HARNESS/base-settings.json" "$SETTINGS") || { echo "NOT RUN: bad // settings: line"; exit 2; }
defaults delete $SUITE 2>/dev/null
defaults write $SUITE settings -string "$settings"

# Game Pause on: a window of our own is made the frontmost app first, as Game Pause freezes the frontmost app when the
# saved OCR window isn't found, which would otherwise be the terminal running the tests (tools/frontguard.swift).
guard=
if python3 -I -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("gamePause") is True else 1)' "$settings"; then
    tool=$("$HARNESS/tools/build.sh" frontguard) || { echo "NOT RUN: couldn't build frontguard"; exit 2; }
    "$tool" > "$RUN/frontguard.log" 2>&1 & guard=$!
    end=$((SECONDS + 8))
    until grep -q '^frontmost' "$RUN/frontguard.log" 2>/dev/null; do
        if (( SECONDS > end )) || ! kill -0 $guard 2>/dev/null; then
            kill $guard 2>/dev/null; defaults delete $SUITE 2>/dev/null
            echo "NOT RUN: Game Pause is on and the front guard window didn't become the frontmost app"; exit 2
        fi
        sleep 0.1
    done
fi

env ${=MOCK} python3 -I "$HARNESS/mock.py" "$RUN/mock.log" & mock=$!
beside=
if [[ -n "$BESIDE" ]]; then
    zsh -c "$BESIDE" > "$RUN/beside.log" 2>&1 & beside=$!
fi
env MACPOPUP_SETTINGS_SUITE=$SUITE MACPOPUP_PASTEBOARD=$SUITE MACPOPUP_TEST_SCRIPT="$RUN/script.js" \
    MACPOPUP_DEBUG_OCR_DIR="$RUN" MACPOPUP_MODELS_DIRECTORY="$RUN/models" MACPOPUP_BROWSER_SUPPORT_DIR="$RUN/browser" \
    MACPOPUP_TRANSCRIPTS_DIRECTORY="$RUN/Library/Caches/com.aury.macpopup/Transcripts" "${APP_ENV[@]}" \
    "$APP/Contents/MacOS/MacPopup" > "$RUN/app.log" 2>&1 & app=$!

# Waits up to $2 seconds for a TEST line ($1) in the log.
logged() {
    local end=$((SECONDS + $2))
    until grep -q "TEST $1" "$RUN/app.log" 2>/dev/null; do
        (( SECONDS > end )) || ! kill -0 $app 2>/dev/null && return 1
        sleep 0.1
    done
}
page=0
grep -q "^test(" "$TEST" && page=1
driver_status=0
if [[ -n "$DRIVER" ]]; then
    PID=$app zsh -c "$DRIVER" > "$RUN/driver.log" 2>&1 & driver=$!
    # (Its output away from run.sh's: a sleep left over when it's killed would hold that open until it ends.)
    ( sleep ${TIMEOUT:-60}; kill $driver 2>/dev/null ) > /dev/null 2>&1 & watchdog=$!
fi
if (( page )) && logged ready 30; then
    [[ -n "$CLIPBOARD" ]] && sleep 1 && "$PB" $SUITE "$CLIPBOARD"
    logged done ${TIMEOUT:-60}
fi
if [[ -n "$DRIVER" ]]; then
    wait $driver; driver_status=$?
    # Its sleep too: left over, it would kill whatever process has the driver's pid by then.
    pkill -P $watchdog 2>/dev/null; kill $watchdog 2>/dev/null; wait $watchdog 2>/dev/null
fi
kill $app $mock 2>/dev/null; wait $app $mock 2>/dev/null
[[ -n "$guard" ]] && { kill $guard 2>/dev/null; wait $guard 2>/dev/null }
if [[ -n "$beside" ]]; then
    pkill -P $beside 2>/dev/null; kill $beside 2>/dev/null; wait $beside 2>/dev/null
fi
defaults delete $SUITE 2>/dev/null

{ grep -o 'TEST .*' "$RUN/app.log"; [[ -n "$DRIVER" ]] && grep -o 'TEST .*' "$RUN/driver.log"; } > "$RUN/test.log"
problems=()
if (( page )); then
    grep -q '^TEST ready' "$RUN/test.log" || problems+=("the test didn't start")
    grep -q '^TEST done' "$RUN/test.log" || problems+=("the test didn't finish")
fi
(( driver_status )) && problems+=("the driver exited with $driver_status ($RUN/driver.log)")
grep -q '^TEST ok' "$RUN/test.log" || grep -q '^TEST FAIL' "$RUN/test.log" || problems+=("nothing was checked")
grep -q '^TEST FAIL' "$RUN/test.log" && problems+=("$(grep -c '^TEST FAIL' "$RUN/test.log") checks failed")
if ! cmp -s <(plutil -convert xml1 -o - "$RUN/user-settings.plist") <(defaults export com.aury.macpopup - | plutil -convert xml1 -o - -); then
    problems+=("THE USER'S SETTINGS CHANGED: their copy from before is $RUN/user-settings.plist")
fi
if (( ${#problems} )); then
    echo "FAIL: ${(j:; :)problems}"
    grep '^TEST FAIL' "$RUN/test.log" | sed 's/^TEST /  /'
    exit 1
fi
echo "PASS ($(grep -c '^TEST ok' "$RUN/test.log") checks)"
