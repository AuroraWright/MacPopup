# gamepad-switch-driver.py, for gamepad-switch.test.js: makes sure SwitchTestA is the frontmost app before the page gives
# the controller focus ("front A" in its log, or "front other <pid>"), then, when the page asks, brings SwitchTestB to the
# front with System Events ("switched to B", or "switched: not done").
import os, re, sys
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import activate, beside_log, check, frontmost, log, logged, until


def pid_of(title):
    found = re.search(rf'started {title} pid (\d+)', beside_log())
    return int(found.group(1)) if found else None


a, b = until(lambda: pid_of('SwitchTestA'), timeout=30), until(lambda: pid_of('SwitchTestB'), timeout=30)
if check(bool(a and b), f'both test windows started (SwitchTestA {a}, SwitchTestB {b})') and logged('want A in front', timeout=60):
    if frontmost() != a:
        activate(a)
    front = frontmost()
    log('front A' if front == a else f'front other {front}')
    if logged('switch now', timeout=60):
        log('switched to B' if activate(b) else f'switched: not done, {frontmost()} in front')
else:
    log('front other none')
