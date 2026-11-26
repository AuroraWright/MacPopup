# tap-freeze-driver.py [sounds]: the driver of tap-freeze.test.js (evals/sentence-audio/verify-freeze.sh): while
# the game (windows/freezegame.swift) starts a quiet sound every 3 s, so Anki Audio's recorded audio makes its tap again as
# each starts and ends, a 1 s `sample` of the test instance after each sound (20) says whether its main thread is frozen:
# waiting on a queue (_dispatch_sync_f_slow) or in AudioDeviceStop in 90% of the samples, and still 3 s later (the
# deadlock of 2026-11-14: the tap stopped on its IO block's queue). Checks that it never froze, that taps were made
# (Anki Audio's "recording processes"/"the app hasn't played sound yet"/"recording every process" notes) and that none
# failed ("couldn't"). Samples in $RUN/sample-<n>.txt.
import os, re, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, RUN, check, log, running

count = int(sys.argv[1]) if len(sys.argv) > 1 else 20


def sample(name):
    """(samples of the main thread, of them waiting on a queue, in AudioDeviceStop), from a 1 s sample."""
    path = f'{RUN}/{name}.txt'
    subprocess.run(['sample', PID, '1', '-file', path], capture_output=True)
    try:
        lines = open(path, errors='replace').read().splitlines()
    except OSError:
        return None
    total = blocked = 0
    inside = False
    for line in lines:
        if 'com.apple.main-thread' in line:
            total = int(re.search(r'(\d+)', line).group(1))
            inside = True
            continue
        if inside and re.match(r'^    \d+ Thread_', line):
            break
        if inside and not blocked and '_dispatch_sync_f_slow' in line:
            blocked = int(re.search(r'(\d+)', line).group(1))
    stopping = next((int(m.group(1)) for line in lines if (m := re.search(r'(\d+) AudioDeviceStop', line))), 0)
    return total, blocked, stopping


def frozen(result):
    total, blocked, stopping = result
    return total > 0 and max(blocked, stopping) >= total * 0.9


time.sleep(6)
froze = None
done = 0
for n in range(1, count + 1):
    if not running():
        check(False, f'the app quit after {done} sounds')
        break
    time.sleep(2)
    result = sample(f'sample-{n}')
    if not result or not result[0]:
        check(False, f"sample couldn't read the app after sound {n}")
        break
    log(f'sound {n}: main thread waiting on a queue in {result[1]} of {result[0]} samples, the tap stopping in {result[2]}')
    done = n
    if frozen(result):
        time.sleep(3)
        again = sample(f'sample-{n}-again')
        if again and (again[1] or again[2]):
            froze = n
            log(f'FROZEN after sound {n}, 3 s later: waiting on a queue in {again[1]} of {again[0]}, the tap stopping in {again[2]}')
            break
check(froze is None and done == count, f'MacPopup never froze in {done} of {count} sounds' + (f' (frozen after sound {froze})' if froze else ''))
app_log = open(f'{RUN}/app.log', errors='replace').read()
taps = len(re.findall(r"hasn't played|recording every|recording processes", app_log))
errors = len(re.findall(r"\[sentence audio\] couldn't", app_log))
check(taps > 1, f'taps made as the sounds came and went: {taps}')
check(errors == 0, f"taps that couldn't be made: {errors}")
sounds = len(re.findall(r'^\d+ sound \d+$', open(f'{RUN}/beside.log', errors='replace').read(), re.M))
check(sounds >= count * 0.8, f'sounds the game played: {sounds}')
