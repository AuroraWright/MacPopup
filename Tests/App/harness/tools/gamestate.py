# gamestate.py <executable>: a driver (launch.sh's "// driver:") for tests where the game is paused (Game Pause, which
# stops the captured window's process with the pause helper). It logs the process running <executable> (a test window
# from "// beside:", found by its path) every 0.1 s as "<ms since 1970> <ps state>" into $RUN/state.log ("T…" is stopped,
# "gone" once it quit), for the page to check (test-lib.js processStates, with MOCK_RUN_FILES=1), until the test is done.
# A game the test left stopped is continued (SIGCONT) and fails the test. Also logs whether launchd has the pause
# helper loaded.
import os, re, signal, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import RUN, check, log, running, until

path = sys.argv[1]
helper = subprocess.run(['launchctl', 'print', 'system/com.aury.macpopup.pause-helper'], capture_output=True, text=True)
state = re.search(r'^\s*state = (.*)$', helper.stdout, re.M)
log(f"pause helper: {'loaded, ' + state.group(1) if helper.returncode == 0 and state else 'not loaded in launchd now (it may be started on demand)'}")


def find():
    found = subprocess.run(['pgrep', '-f', f'^{re.escape(path)}( |$)'], capture_output=True, text=True).stdout.split()
    return int(found[0]) if found else None


def stat(pid):
    return subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()


done_offset = 0


def done():
    """Whether the page logged "TEST done" (app.log read on from where it was last)."""
    global done_offset
    try:
        with open(f'{RUN}/app.log', 'rb') as f:
            start = max(0, done_offset - 16)
            f.seek(start)
            data = f.read()
            done_offset = start + len(data)
    except OSError:
        return False
    return b'TEST done' in data


game = until(find, timeout=60, interval=0.1)
if not game:
    check(False, f'no process running {path} (the test window) within 60 s')
    sys.exit(0)
log(f'the game: {os.path.basename(path)}, pid {game}')
with open(f'{RUN}/state.log', 'a') as out:
    while running() and not done():
        now = stat(game) or 'gone'
        out.write(f'{int(time.time() * 1000)} {now}\n')
        out.flush()
        if now == 'gone':
            break
        time.sleep(0.1)
last = stat(game)
if last.startswith('T'):
    os.kill(game, signal.SIGCONT)
    check(False, f'the game ({os.path.basename(path)}) was still stopped when the test ended: continued it')
