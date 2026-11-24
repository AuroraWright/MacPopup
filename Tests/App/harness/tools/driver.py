# driver.py: helpers for drivers written in Python (launch.sh's "// driver:"; RUN, HARNESS, REPO, SUITE and PID set).
# A driver imports it with sys.path.insert(0, os.environ['HARNESS'] + '/tools') and checks with check/equal, which print
# "TEST ok …"/"TEST FAIL …" lines as a page's checks; it exits 0 whatever they found.
import json, os, signal, subprocess, sys, threading, time

RUN, HARNESS, REPO, SUITE = (os.environ[name] for name in ('RUN', 'HARNESS', 'REPO', 'SUITE'))
PID = os.environ.get('PID', '')


def _stop_without_harness():
    """Stops the driver's group (as launch.sh would) if launch.sh is gone, e.g. killed: a driver in a session of its
    own doesn't get the terminal's Ctrl-C, and would otherwise go on pressing keys and moving the pointer."""
    harness = int(os.environ.get('HARNESS_PID') or 0)
    while harness:
        try:
            os.kill(harness, 0)
        except (ProcessLookupError, PermissionError):
            # (Another user's process with its pid: it's gone all the same.)
            os.killpg(os.getpgrp(), signal.SIGTERM)
            return
        time.sleep(1)


threading.Thread(target=_stop_without_harness, daemon=True).start()


def log(message):
    print(message, flush=True)


def check(ok, message):
    log(f"TEST {'ok' if ok else 'FAIL'} {message}")
    return ok


def equal(actual, expected, message):
    """Equal as JSON values (2 and 2.0 alike, keys in any order)."""
    a, e = json.dumps(actual, ensure_ascii=False), json.dumps(expected, ensure_ascii=False)
    same = json.loads(a) == json.loads(e)
    return check(same, f'{message}: {a}' + ('' if same else f' (expected {e})'))


def tool(name):
    """The path of tools/<name>.swift compiled (tools/build.sh)."""
    return subprocess.run([f'{HARNESS}/tools/build.sh', name], capture_output=True, text=True, check=True).stdout.strip()


def until(find, timeout=10, interval=0.2):
    """What find() returns once it's truthy, or None after timeout seconds."""
    end = time.monotonic() + timeout
    while True:
        value = find()
        if value or time.monotonic() > end:
            return value
        time.sleep(interval)


def running():
    try:
        os.kill(int(PID), 0)
        return True
    except (OSError, ValueError):
        return False


def ax(*args):
    """Runs tools/ax.swift on the test instance: (succeeded, output)."""
    result = subprocess.run([tool('ax'), PID, *map(str, args)], capture_output=True, text=True)
    log(f"ax {' '.join(map(str, args))}: {result.stdout.strip()[:200]}")
    return result.returncode == 0, result.stdout


def windows():
    return subprocess.run([tool('ax'), PID, 'windows'], capture_output=True, text=True).stdout.splitlines()


def controls(window=None):
    """The instance's controls (ax list): dicts with role, help, title, description, placeholder, value, enabled, window."""
    output = subprocess.run([tool('ax'), PID, 'list', *([window] if window else [])], capture_output=True, text=True).stdout
    keys = ('role', 'help', 'title', 'description', 'placeholder', 'value', 'enabled', 'window')
    return [dict(zip(keys, line.split('\t'))) for line in output.splitlines() if line.count('\t') == 7]


def default(key):
    """A key of the test instance's defaults suite, as `defaults read` prints it, or None."""
    result = subprocess.run(['defaults', 'read', SUITE, key], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def settings():
    """The test instance's saved settings."""
    export = subprocess.run(['defaults', 'export', SUITE, '-'], capture_output=True).stdout
    text = subprocess.run(['plutil', '-extract', 'settings', 'raw', '-o', '-', '-'], input=export, capture_output=True).stdout
    return json.loads(text or b'{}')


def window_shot(title, name):
    """Captures the test instance's window with this title (only it, with screencapture -l) into $RUN/<name>.png: the
    path, or None when there's no such window."""
    ids = subprocess.run([tool('winid'), PID, title], capture_output=True, text=True).stdout.split()
    if not ids:
        return None
    path = f'{RUN}/{name}.png'
    subprocess.run(['screencapture', '-x', '-o', '-l', ids[0], path])
    return path if os.path.exists(path) else None


def open_settings(section, label, timeout=20):
    """Has Settings show this section (its title) once the page opens it (native('openSettings'), see settings/*.test.js),
    and waits for its window to show a row of the section (its label): whether it came."""
    subprocess.run(['defaults', 'write', SUITE, 'settingsSection', '-string', section])
    shown = until(lambda: any(c['role'] == 'AXStaticText' and c['value'] == label for c in controls('MacPopup Settings')),
                  timeout=timeout, interval=0.5)
    return check(bool(shown), f'Settings shows {section} ({label})')


def png_size(path):
    with open(path, 'rb') as f:
        header = f.read(24)
    return int.from_bytes(header[16:20], 'big'), int.from_bytes(header[20:24], 'big')


# For interactive tests ("// interactive"): the real pointer and keys, only on the test instance's (or a test window's)
# windows, through tools/mouse.swift and tools/keys.swift.

def app_log():
    try:
        with open(f'{RUN}/app.log', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def logged(text, timeout=30):
    """Waits until the page logs "TEST <text>…" (app.log): the line (without "TEST "), or None after timeout seconds."""
    def find():
        for line in app_log().splitlines():
            at = line.find(f'TEST {text}')
            if at >= 0:
                return line[at + 5:]
        return None
    return until(find, timeout=timeout, interval=0.1)


def mouse(*args):
    """Runs tools/mouse.swift: (succeeded, output)."""
    result = subprocess.run([tool('mouse'), *map(str, args)], capture_output=True, text=True)
    return result.returncode == 0, result.stdout.strip()


def keep_pointer():
    """Puts the real pointer back where it is now when the driver exits (also when launch.sh's watchdog stops it)."""
    import atexit, signal
    _, at = mouse('pos')
    x, y = at.split()
    put_back = lambda: (mouse('put', x, y), log(f'the pointer put back at {x},{y}'))
    atexit.register(put_back)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def keys(pids, step):
    """One key press with tools/keys.swift, only while one of `pids` is the frontmost app: whether it was sent."""
    result = subprocess.run([tool('keys'), ','.join(map(str, pids)), step], capture_output=True, text=True)
    log(f'key {step}: {result.stdout.strip()}')
    return result.returncode == 0


def frontmost():
    """The frontmost app's pid (lsappinfo), or 0."""
    out = subprocess.run(['lsappinfo', 'info', '-only', 'pid', subprocess.run(['lsappinfo', 'front'], capture_output=True, text=True).stdout.strip()],
                         capture_output=True, text=True).stdout
    digits = ''.join(c for c in out.split('=')[-1] if c.isdigit())
    return int(digits) if digits else 0


def activate(pid):
    """Brings a test window's process to the front, as clicking it would (System Events, as a process can't take the front
    from another app itself): whether it's in front after."""
    subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {int(pid)}) to true'],
                   capture_output=True)
    return bool(until(lambda: frontmost() == int(pid), timeout=3))


def beside_log():
    try:
        with open(f'{RUN}/beside.log', errors='replace') as f:
            return f.read()
    except OSError:
        return ''
