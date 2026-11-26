# record-driver.py <app|web> [--other]: the driver of the record-*.test.js tests (Anki Audio recording the captured
# app's audio from the shortcut on: the visual novel backlog way, game audio recording being off). Once the page is ready
# (its trigger comes 1.5 s later), it has another app say an English line at 2.2 s (with --other: afplay, volume 0.15,
# not recorded: it isn't the captured app) and the captured app say its Japanese line at 7.5 s (SIGUSR1: app,
# windows/audiowin.swift from "// beside:"; web, WKAudioTest.app from wkaudio-app.sh), as sentence-audio/run.sh timed
# them; then it waits for the test to end (and quits WKAudioTest). clip-driver.py checks the clip.
import os, re, signal, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import REPO, RUN, check, log, running, until

mode, other = sys.argv[1], '--other' in sys.argv[2:]
target = f'{RUN}/WKAudioTest.app/Contents/MacOS/WKAudioTest' if mode == 'web' else f'{REPO}/build/test/tools/audiowin'


def app_log():
    try:
        with open(f'{RUN}/app.log', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def watch_play(pid):
    """audiowin's play() returning within 3 s: once (2026-11-25, a cold first start) it didn't, and nothing was recorded.
    If it hasn't, its threads are sampled (audiowin-sample.txt) to see where it waits."""
    def played():
        try:
            return 'playing' in open(f'{RUN}/beside.log', errors='replace').read()
        except OSError:
            return False
    if until(played, timeout=3, interval=0.1):
        return
    subprocess.run(['sample', str(pid), '2', '-file', f'{RUN}/audiowin-sample.txt'], capture_output=True)
    check(False, 'the captured app\'s play() returned within 3 s (it stalled: audiowin-sample.txt has its threads)')


def game():
    found = subprocess.run(['pgrep', '-f', f'^{re.escape(target)}( |$)'], capture_output=True, text=True).stdout.split()
    return int(found[0]) if found else None


ready = until(lambda: 'TEST ready' in app_log(), timeout=40, interval=0.05)
start = time.monotonic()
if ready:
    if other:
        time.sleep(max(0, start + 2.2 - time.monotonic()))
        log(f'{int(time.time() * 1000)} the other app speaks')
        subprocess.Popen(['afplay', '-v', '0.15', f'{RUN}/voice-other.aiff'])
    time.sleep(max(0, start + 7.5 - time.monotonic()))
    pid = game()
    if check(bool(pid), f'the captured app ({os.path.basename(target)}) running at 7.5 s'):
        try:
            os.kill(pid, signal.SIGUSR1)
            log(f'{int(time.time() * 1000)} the captured app speaks')
        except ProcessLookupError:
            check(False, 'the captured app still running when told to speak')
        else:
            if mode == 'app':
                watch_play(pid)
else:
    check(False, 'the page never got ready')
while running() and 'TEST done' not in app_log():
    time.sleep(0.2)
if mode == 'web' and game():
    subprocess.run(['pkill', '-f', f'^{re.escape(target)}'])
