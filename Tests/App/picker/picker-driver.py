# picker-driver.py <escape|switch>, for the picker tests: once the page has opened the window picker on the OCR window
# (RaiseTestA, which RaiseTestB covers), checks that RaiseTestA was brought to the front (as clicking it would) and the
# picker shows its areas (its Done button); with "switch", brings RaiseTestB to the front (System Events) and checks the
# picker went back to choosing the window (no Done button). Then presses Escape (only while a test window or the
# instance is the frontmost app): the picker closes and the window in front didn't get the key.
import os, re, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, activate, app_log, beside_log, check, equal, frontmost, keys, log, logged, tool, until

case = sys.argv[1]


def pid_of(title):
    found = re.search(rf'started {title} pid (\d+)', beside_log())
    return int(found.group(1)) if found else None


def windows():
    """The on-screen windows, front to back: (pid, layer, x, y, w, h, title)."""
    out = subprocess.run([tool('wins')], capture_output=True, text=True).stdout
    rows = [line.split('\t') for line in out.splitlines()]
    return [(int(r[0]), int(r[1]), *map(int, r[2:6]), r[6]) for r in rows if len(r) == 7]


def state():
    """The test windows front to back, whether the picker shows (the instance's screen-sized windows: the overlay and,
    two levels above it, the picker's panel), the frontmost app's pid and the buttons the picker drew last."""
    all = windows()
    tests = [w[6] for w in all if w[1] == 0 and w[6].startswith('RaiseTest')]
    ours = [w for w in all if w[0] == int(PID)]
    biggest = max((w[4] * w[5] for w in ours), default=0)
    layers = [w[1] for w in ours if w[4] * w[5] >= biggest > 0]
    picker = len(layers) >= 2 and max(layers) >= min(layers) + 2
    buttons = re.findall(r'\[picker\] button (\w+) at', app_log())
    # A drawing logs its buttons from Cancel on.
    last = buttons[len(buttons) - 1 - buttons[::-1].index('cancel'):] if 'cancel' in buttons else []
    result = {'order': tests, 'picker': picker, 'frontmost': frontmost(), 'buttons': last}
    log(f'state: {result}')
    return result


a, b = until(lambda: pid_of('RaiseTestA')), until(lambda: pid_of('RaiseTestB'))
log(f'RaiseTestA {a}, RaiseTestB {b}, the instance {PID}')
if check(bool(a and b), 'both test windows started') and check(bool(logged('select', timeout=40)), 'the page opened the picker'):
    time.sleep(1.5)
    s = state()
    equal(s['order'], ['RaiseTestA', 'RaiseTestB'], 'the picker open: the test windows front to back')
    equal(s['frontmost'], a, "the picker open: the frontmost app's pid (RaiseTestA's)")
    equal(s['picker'], True, 'the picker shows')
    equal(s['buttons'], ['cancel', 'wholeScreen', 'otherWindow', 'undo', 'done'], "the picker's buttons (choosing RaiseTestA's areas)")
    front = 'RaiseTestA'
    if case == 'switch':
        check(activate(b), 'RaiseTestB brought to the front (System Events)')
        time.sleep(1)
        s = state()
        equal(s['frontmost'], b, "RaiseTestB activated: the frontmost app's pid (RaiseTestB's)")
        equal(s['picker'], True, 'RaiseTestB activated: the picker shows')
        equal(s['buttons'], ['cancel', 'wholeScreen'], "RaiseTestB activated: the picker's buttons (choosing a window again)")
        front = 'RaiseTestB'
    if keys([a, b, int(PID)], 'escape'):
        time.sleep(1)
        s = state()
        equal(s['picker'], False, 'after Escape: the picker shows')
        equal(re.findall(rf'{front} got key 53', beside_log()), [], f'Escape kept from {front}')
    else:
        check(False, 'Escape not pressed: neither a test window nor the instance is in front')
log('finished')
