#!/bin/zsh
# launch.sh <MacPopup.app> <test.js> <run folder>: runs one app test and prints PASS or FAIL (exit 0, 1; 2 when no test
# can run now, 3 when this one couldn't). The test instance:
# - only starts when the user's MacPopup (build/ or /Applications) and IINA aren't running, nor another test instance,
#   and only from a development build (scripts/build.sh marks them), which reads the test environment variables: the app
#   as shipped would ignore them and use the user's settings. If the user's MacPopup (or IINA, in a test that doesn't
#   start IINA itself) starts during the test, the test is stopped and fails;
# - has its own settings (the defaults, base-settings.json, then the test's "// settings:" line), pasteboard, debug
#   log, models, transcripts, browser folders and saved Floating Window lines, all in the run folder, and talks to
#   mock.py instead of AnkiConnect and Yomitan;
# - runs test-lib.js and the test in its pages, and is stopped at "TEST done" or after the test's "// timeout:" (s, 60).
# Header lines in the test file:
# - "// mock: MOCK_IMAGES=1 …": mock.py's switches;
# - "// clipboard: <text>": put on the instance's pasteboard once the test is ready;
# - "// setup: <command>": run (zsh) before the launch, e.g. to make a sound file in "$RUN";
# - "// env: NAME=value …": more environment for the app ($RUN, $HARNESS and $REPO expanded);
# - "// beside: <command>": run (zsh) from just before the launch until the test ends, e.g. a test window for OCR mode
#   to read (output in beside.log; stopped with everything it started, as is the driver);
# - "// driver: <command>": run (zsh) beside the instance once it's started, for what a page script can't do (Settings
#   is SwiftUI, Accessibility, a fake Yomitan): with RUN, HARNESS, REPO, SUITE and PID (the app's) set, it prints
#   "TEST ok …"/"TEST FAIL …" lines like a page's checks and must exit 0. The test then lasts until it exits (and the
#   page's test, if the file has one, has logged "TEST done"); stopped after the timeout, it fails.
# The user's settings are exported before and compared after: a change fails the test and says where the copy is. On
# Ctrl-C (or a kill), everything the test started is stopped and the settings compared all the same.
set -uo pipefail

APP=${1:A} TEST=${2:A} RUN=${3:A}
HARNESS=${0:A:h}
REPO=${HARNESS:h:h:h}
SUITE=com.aury.macpopup.test.app

USER_MACPOPUP="^($REPO/build/MacPopup.app|/Applications/MacPopup.app)/Contents/MacOS/MacPopup"
USER_IINA="^/Applications/IINA.app/Contents/MacOS/IINA"
if pgrep -f "$USER_MACPOPUP|$USER_IINA" >/dev/null; then
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
# HARNESS_PID: drivers stop themselves if this script is gone (see tools/driver.py).
HARNESS_PID=$$
export RUN HARNESS REPO SUITE HARNESS_PID
# A test that starts IINA itself (the user's app: there's no other) can't tell the user's IINA starting from its own.
uses_iina=0
[[ "$SETUP$BESIDE$DRIVER" == */Tests/App/iina/* ]] && uses_iina=1

app= mock= beside= driver= watchdog= guard=
# Runs zsh -c "$1" in a process group of its own, so that it's stopped with everything it started (see stop_all), also
# what's left running once it ended (a window started by a beside command that's gone). Only run with &: the function's
# subshell is replaced (exec), so that $! is the group's id.
group() { exec python3 -I -c 'import os, sys; os.setsid(); os.execvp("zsh", ["zsh", "-c", sys.argv[1]])' "$1" }
# Stops what the test started, with everything left in its groups (what's still there after 20 s is killed), and
# removes the test's settings suite. Each group's leader is stopped by its pid too: one only just started may not be a
# group yet. (What's still running after 20 s is killed by pid: a pid reused meanwhile would be too, which macOS's pids,
# handed out in turn, make all but impossible.)
stop_all() {
    local groups=() pids=() left=() end=$((SECONDS + 20))
    for p in $driver $beside $watchdog; do groups+=(-$p); pids+=($p); done
    for p in $app $mock $guard; do pids+=($p); done
    (( ${#pids} )) && kill -TERM -- $groups $pids 2>/dev/null
    while (( ${#pids} )); do
        left=()
        for p in $groups $pids; do kill -0 -- $p 2>/dev/null && left+=($p); done
        (( ${#left} )) || break
        if (( SECONDS > end )); then kill -KILL -- $left 2>/dev/null; break; fi
        sleep 0.1
    done
    for p in $pids; do wait $p 2>/dev/null; done
    defaults delete $SUITE 2>/dev/null
}
settings_changed() {
    ! cmp -s <(plutil -convert xml1 -o - "$RUN/user-settings.plist") <(defaults export com.aury.macpopup - | plutil -convert xml1 -o - -)
}
# Whether the user's MacPopup (or IINA, see uses_iina) started, checked once a second.
checked=0
user_started() {
    (( SECONDS == checked )) && return 1
    checked=$SECONDS
    pgrep -f "$( (( uses_iina )) && echo "$USER_MACPOPUP" || echo "$USER_MACPOPUP|$USER_IINA")" >/dev/null
}
interrupted() {
    # Another Ctrl-C meanwhile doesn't cut the stopping short (it takes 20 s at most).
    trap '' INT TERM HUP
    echo "interrupted: stopping the test instance" >&2
    stop_all
    [[ -f "$RUN/user-settings.plist" ]] && settings_changed \
        && echo "THE USER'S SETTINGS CHANGED: their copy from before is $RUN/user-settings.plist" >&2
    echo "FAIL: interrupted"
    exit 1
}
trap interrupted INT TERM HUP

mkdir -p "$RUN/models" "$RUN/browser" "$RUN/Library/Caches/com.aury.macpopup/Transcripts"
cat "$HARNESS/test-lib.js" "$TEST" > "$RUN/script.js"
PB="$REPO/build/test/tools/pb"
if [[ -n "$CLIPBOARD" && ( ! -x "$PB" || "$HARNESS/pb.swift" -nt "$PB" ) ]]; then
    mkdir -p "${PB:h}" && swiftc -o "$PB" "$HARNESS/pb.swift" || { echo "NOT RUN: couldn't build pb"; exit 3; }
fi

# Stopped (with what it started) after 120 s: setups take up to about 16 s, and `say -o` once hung for minutes.
if [[ -n "$SETUP" ]]; then
    python3 -I -c 'import os, sys; os.setsid(); os.execvp("zsh", ["zsh", "-c", sys.argv[1]])' "$SETUP" > "$RUN/setup.log" 2>&1 &
    setup=$!
    end=$((SECONDS + 120))
    while kill -0 $setup 2>/dev/null && (( SECONDS < end )); do sleep 0.2; done
    if kill -0 $setup 2>/dev/null; then
        kill -KILL -- -$setup $setup 2>/dev/null
        wait $setup 2>/dev/null
        echo "FAIL: the setup took over 120 s ($RUN/setup.log)"; exit 1
    fi
    wait $setup || { echo "FAIL: the setup failed ($RUN/setup.log)"; exit 1; }
fi
APP_ENV=(${(e)=ENV})

defaults export com.aury.macpopup "$RUN/user-settings.plist"
settings=$(python3 -I -c 'import json, sys
s = json.load(open(sys.argv[1])); s.update(json.loads(sys.argv[2] or "{}")); print(json.dumps(s))' \
    "$HARNESS/base-settings.json" "$SETTINGS") || { echo "FAIL: bad // settings: line"; exit 1; }
defaults delete $SUITE 2>/dev/null
defaults write $SUITE settings -string "$settings"

# Game Pause on: a window of our own is made the frontmost app first (tools/frontguard.swift). Game Pause freezes the
# frontmost app when the saved OCR window isn't found, which would otherwise be the terminal running the tests; test
# instances don't (GamePause.gameProcesses), and this guards the run against that changing.
guard=
if python3 -I -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("gamePause") is True else 1)' "$settings"; then
    tool=$("$HARNESS/tools/build.sh" frontguard) || { echo "NOT RUN: couldn't build frontguard"; exit 3; }
    "$tool" > "$RUN/frontguard.log" 2>&1 & guard=$!
    end=$((SECONDS + 8))
    until grep -q '^frontmost' "$RUN/frontguard.log" 2>/dev/null; do
        if (( SECONDS > end )) || ! kill -0 $guard 2>/dev/null; then
            stop_all
            echo "NOT RUN: Game Pause is on and the front guard window didn't become the frontmost app"; exit 3
        fi
        sleep 0.1
    done
fi

# Again: the setup may have taken a while.
if pgrep -f "$USER_MACPOPUP|$USER_IINA" >/dev/null; then
    stop_all
    echo "NOT RUN: the user's MacPopup or IINA is running"; exit 2
fi
env ${=MOCK} python3 -I "$HARNESS/mock.py" "$RUN/mock.log" & mock=$!
# The app only once the mock takes connections: a page could ask it for something at once.
end=$((SECONDS + 15))
until [[ -f "$RUN/mock.ready" ]]; do
    if ! kill -0 $mock 2>/dev/null; then
        # Most likely its ports are taken, e.g. by a mock left from a run that was killed: the other tests would fail too.
        stop_all
        echo "NOT RUN: the mock didn't start (are its ports, 59877-59881, taken?)"; exit 2
    fi
    if (( SECONDS > end )); then
        stop_all
        echo "FAIL: the mock didn't start"; exit 1
    fi
    sleep 0.05
done
if [[ -n "$BESIDE" ]]; then
    group "$BESIDE" > "$RUN/beside.log" 2>&1 & beside=$!
fi
env MACPOPUP_SETTINGS_SUITE=$SUITE MACPOPUP_PASTEBOARD=$SUITE MACPOPUP_TEST_SCRIPT="$RUN/script.js" \
    MACPOPUP_DEBUG_OCR_DIR="$RUN" MACPOPUP_MODELS_DIRECTORY="$RUN/models" MACPOPUP_BROWSER_SUPPORT_DIR="$RUN/browser" MACPOPUP_LINES_FILE="$RUN/lines.json" \
    MACPOPUP_TRANSCRIPTS_DIRECTORY="$RUN/Library/Caches/com.aury.macpopup/Transcripts" "${APP_ENV[@]}" \
    "$APP/Contents/MacOS/MacPopup" > "$RUN/app.log" 2>&1 & app=$!

user_came=0
# Waits up to $2 seconds for a TEST line ($1) in the log.
logged() {
    local end=$((SECONDS + $2))
    until grep -q "TEST $1" "$RUN/app.log" 2>/dev/null; do
        (( SECONDS > end )) || ! kill -0 $app 2>/dev/null && return 1
        user_started && { user_came=1; return 1 }
        sleep 0.1
    done
}
page=0
grep -q "^test(" "$TEST" && page=1
driver_status=0
if [[ -n "$DRIVER" ]]; then
    PID=$app group "$DRIVER" > "$RUN/driver.log" 2>&1 & driver=$!
    # Stops the driver after the timeout, unless it ended first (the page can take longer: it has 30 s to start too).
    # (Its output away from run.sh's: a sleep left over would hold that open until it ends.)
    group "end=\$((SECONDS + ${TIMEOUT:-60})); while (( SECONDS < end )); do kill -0 $driver || exit 0; sleep 0.2; done
        kill -0 -- -$driver && touch '$RUN/watchdog' && kill -TERM -- -$driver" > /dev/null 2>&1 & watchdog=$!
fi
if (( page )) && logged ready 30; then
    [[ -n "$CLIPBOARD" ]] && sleep 1 && "$PB" $SUITE "$CLIPBOARD"
    logged done ${TIMEOUT:-60}
fi
if [[ -n "$DRIVER" ]]; then
    while (( ! user_came )) && kill -0 $driver 2>/dev/null; do
        user_started && user_came=1
        sleep 0.2
    done
    (( user_came )) && kill -TERM -- -$driver 2>/dev/null
    wait $driver; driver_status=$?
fi
stop_all

{ grep -o 'TEST .*' "$RUN/app.log"; [[ -n "$DRIVER" ]] && grep -o 'TEST .*' "$RUN/driver.log"; } > "$RUN/test.log"
problems=()
if (( page )); then
    grep -q '^TEST ready' "$RUN/test.log" || problems+=("the test didn't start")
    grep -q '^TEST done' "$RUN/test.log" || problems+=("the test didn't finish")
fi
(( user_came )) && problems+=("the user's MacPopup or IINA started during the test, which was stopped")
[[ -f "$RUN/watchdog" ]] && problems+=("the driver was stopped after the timeout")
(( driver_status )) && problems+=("the driver exited with $driver_status ($RUN/driver.log)")
grep -q '^TEST ok' "$RUN/test.log" || grep -q '^TEST FAIL' "$RUN/test.log" || problems+=("nothing was checked")
grep -q '^TEST FAIL' "$RUN/test.log" && problems+=("$(grep -c '^TEST FAIL' "$RUN/test.log") checks failed")
if settings_changed; then
    problems+=("THE USER'S SETTINGS CHANGED: their copy from before is $RUN/user-settings.plist")
fi
if (( ${#problems} )); then
    echo "FAIL: ${(j:; :)problems}"
    grep '^TEST FAIL' "$RUN/test.log" | sed 's/^TEST /  /'
    exit 1
fi
echo "PASS ($(grep -c '^TEST ok' "$RUN/test.log") checks)"
