# controller-driver.py, for controller.test.js: has the person set up a controller in Settings → Controllers and record
# the Controller scan key, then shows what the page asks for (manual.relay). tools/gc-watch.swift logs what a game would
# see of the controller meanwhile (gc.log in the run folder); at the end the driver checks it saw nothing while the
# text box had focus, and the presses after.
import os, re, subprocess, sys
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
sys.path.insert(0, os.path.join(os.environ['REPO'], 'Tests/Manual'))
from driver import PID, RUN, SUITE, ax, check, controls, settings, until
from manual import built, done, here, page_logs, prompt, relay

SETTINGS = 'MacPopup Settings'


def button(match):
    """The first of Settings' buttons whose title, label (SwiftUI's is the description) or help `match` accepts, as a
    control dict with the text matched as 'name' (what ax press finds it by), or None."""
    for c in controls(SETTINGS):
        name = next((t for t in (c['title'], c['description'], c['help']) if t and match(t)), None)
        if c['role'] == 'AXButton' and name:
            return {**c, 'name': name}
    return None


def show(section):
    subprocess.run(['defaults', 'write', SUITE, 'settingsSection', '-string', section])


def gc_changes(log_path, start, end):
    """GameController's changes (not connections) logged between two times (ms since 1970)."""
    found = []
    with open(log_path, errors='replace') as f:
        for line in f:
            m = re.match(r'^(\d{12,}) (.*)$', line.strip())
            if m and start <= int(m.group(1)) <= end and not m.group(2).startswith('connected '):
                found.append(m.group(2))
    return found


gc_log = os.path.join(RUN, 'gc.log')
watcher = subprocess.Popen([built(here('tools/gc-watch.swift'))], stdin=subprocess.PIPE, stdout=open(gc_log, 'w'), text=True)
try:
    show('Controllers')
    prompt('Connect a game controller over Bluetooth or USB (only one of its kind), and leave it on. '
           'Settings → Controllers shows it with a Set Up button.')
    setup = until(lambda: (b := button(lambda t: t.startswith('Set Up'))) and b['enabled'] == '1' and b, timeout=300,
                  interval=0.5)
    if check(bool(setup), f"Settings → Controllers lists a controller to set up: {setup and setup['name']}"):
        ax('press', 'AXButton', setup['name'], 1)
        prompt('In Settings: press each button, D-pad direction and trigger once or twice, then push each stick all the '
               'way in every direction, until every control is checked (click Learn next to any that stays unchecked). '
               'Then click Done.')
        layouts = until(lambda: settings().get('gamepadLayouts') or None, timeout=480, interval=0.5)
        check(bool(layouts), f'a layout is saved: {sorted(layouts) if layouts else layouts}')
        check(bool(until(lambda: any(c['role'] == 'AXStaticText' and c['value'] == 'Ready' for c in controls(SETTINGS)),
                         timeout=10, interval=0.5)), 'the controller shows as Ready')

        show('Scanning')
        record = until(lambda: button(lambda t: t == 'Click, then press a button combination on your controller'),
                       timeout=20, interval=0.5)
        if check(bool(record), 'Scanning shows the Controller scan key recorder'):
            ax('press', 'AXButton', record['name'], 1)
            prompt('Hold the buttons you want for looking up words together (e.g. L3 + R3: press both sticks in), '
                   'then let go.')
            scan = until(lambda: settings().get('gamepadScanButtons') or None, timeout=180, interval=0.3)
            check(bool(scan), f'the Controller scan key is saved: {scan}')
    print('settings done', flush=True)

    relay(timeout=900)
    logs = page_logs()
    times = {m.group(1): int(m.group(2)) for line in logs if (m := re.match(r'^(held from|held to|free from|free to) (\d+)$', line))}
    if len(times) == 4:
        setup_seen = gc_changes(gc_log, 0, times['held from'])
        if check(bool(setup_seen), f'gc-watch (a game in the background) saw the controller while it was set up: '
                                   f'{len(setup_seen)} changes'):
            held = gc_changes(gc_log, times['held from'] + 1000, times['held to'])
            check(not held, f'a game sees nothing while the text box has focus: {held[:10]}')
            free = gc_changes(gc_log, times['free from'] + 1500, times['free to'])
            check(bool(free), f'a game sees the controller again after: {len(free)} changes ({free[:5]})')
finally:
    done()
    watcher.stdin.close()
    watcher.wait(timeout=5)
