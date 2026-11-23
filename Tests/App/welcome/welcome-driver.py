# welcome-driver.py, for shown.test.js and not-shown.test.js: the first-launch welcome window, over Accessibility, with a
# Yomitan API of its own on 59884 that answers only while it's started here.
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import RUN, ax, check, controls, default, equal, log, png_size, until, window_shot, windows

WELCOME = 'Welcome to MacPopup'
BUTTON = 'Open Settings → Scanning'


class Yomitan(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        # Only the version, as an older Yomitan answers the profile's paths (displayOptions) with a 400.
        status, body = (200, b'{"version": "welcome-test"}') if self.path.strip('/') == 'yomitanVersion' else (400, b'')
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *args):
        pass


def texts():
    return [c['value'] for c in controls(WELCOME) if c['role'] == 'AXStaticText']


def buttons():
    return [c['title'] or c['description'] for c in controls(WELCOME) if c['role'] == 'AXButton']


def status(expected, timeout=10):
    """Waits for the Yomitan API row to say Detected or Not detected: whether it says `expected`."""
    found = until(lambda: next((t for t in texts() if t in ('Detected', 'Not detected')), None) == expected, timeout=timeout, interval=0.5)
    return equal(next((t for t in texts() if t in ('Detected', 'Not detected')), None), expected, 'the Yomitan API row')


def shot(name, title=WELCOME, minimum=(540, 620)):
    path = window_shot(title, name)
    size = png_size(path) if path else None
    check(bool(size) and size[0] >= minimum[0] and size[1] >= minimum[1], f'{title} captured ({name}.png, {size})')


def shown():
    check(bool(until(lambda: WELCOME in windows(), timeout=15, interval=0.5)), 'the welcome window is shown')
    equal(default('welcomeShown'), '1', 'welcomeShown saved (no welcome at the next launch)')
    status('Not detected')
    check(BUTTON in buttons(), f'"{BUTTON}" offered')
    # The permissions, as in Settings → Permissions: its rows (a section's header isn't static text over Accessibility).
    # Scanning's "Pause helper" row once took their place, from the first section with any permission in it.
    shown_texts = texts()
    equal([t for t in ('Screen Recording', 'System Audio Recording', 'Accessibility', 'Pause Helper', 'Pause helper') if t in shown_texts],
          ['Screen Recording', 'System Audio Recording', 'Accessibility', 'Pause Helper'],
          f"the permissions shown (the window's short texts: {[t for t in shown_texts if len(t) < 40]})")
    shot('not-detected')

    server = ThreadingHTTPServer(('127.0.0.1', 59884), Yomitan)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # The window checks every 2 s.
    status('Detected')
    check(BUTTON not in buttons(), f'"{BUTTON}" not offered')
    shot('detected')
    server.shutdown()
    server.server_close()
    status('Not detected')

    ax('press', 'AXButton', BUTTON, 1)
    check(bool(until(lambda: 'MacPopup Settings' in windows(), timeout=10, interval=0.5)), 'Settings opens')
    equal(default('settingsSection'), 'Scanning', 'on the section')
    check(bool(until(lambda: any(c['value'] == 'Yomitan API URL' for c in controls('MacPopup Settings')), timeout=5)),
          'Settings shows the Yomitan API URL row')
    shot('settings', 'MacPopup Settings', (820, 400))


def not_shown():
    loaded = until(lambda: 'TEST overlay loaded' in open(f'{RUN}/app.log', errors='replace').read(), timeout=30, interval=0.5)
    check(bool(loaded), 'the overlay loaded')
    time.sleep(3)
    equal(windows().count(WELCOME), 0, 'welcome windows with settings saved and no MACPOPUP_SHOW_WELCOME')
    equal(default('welcomeShown'), None, 'welcomeShown')


shown() if sys.argv[1:] == ['shown'] else not_shown()
