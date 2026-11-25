#!/bin/zsh
# say.sh <say's arguments>: `say` (with -o in the tests: written to a file, never played), given 20 s a try and tried 3
# times, as it sometimes hangs for minutes (e.g. 2026-11-25, in voices.sh). Exits with say's status, or 1 if every try
# hung. Each line it writes takes it a second or two.
for try in 1 2 3; do
    say "$@" &
    pid=$!
    end=$((SECONDS + 20))
    while kill -0 $pid 2>/dev/null && (( SECONDS < end )); do sleep 0.1; done
    if ! kill -0 $pid 2>/dev/null; then
        wait $pid
        exit $?
    fi
    kill -KILL $pid 2>/dev/null
    wait $pid 2>/dev/null
    print -u2 -- "say.sh: say hung for 20 s (try $try of 3): say $*"
done
exit 1
