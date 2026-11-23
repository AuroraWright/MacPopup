# manual.py: what the manual tests' drivers share (they import it from Tests/Manual, with harness/tools/driver.py):
# prompt(text) shows the person at the Mac what to do, in a window of its own at the top of the screen
# (tools/prompt.swift, which never takes the keyboard from the test instance), and logs it; done() closes it.
# relay() shows what the page asks for (its "ask: …" logs) the same way, for tests the page leads.
import os, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import app_log, log

_window = None


def built(source):
    """The path of a Swift tool compiled from source (harness/tools/build.sh, into build/test/tools)."""
    return subprocess.run([os.environ['HARNESS'] + '/tools/build.sh', source], capture_output=True, text=True,
                          check=True).stdout.strip()


def here(path):
    """A path in Tests/Manual."""
    return os.path.join(HERE, path)


def prompt(text):
    global _window
    if _window is None or _window.poll() is not None:
        _window = subprocess.Popen([built(here('tools/prompt.swift'))], stdin=subprocess.PIPE, text=True)
    _window.stdin.write(text.replace('\n', ' ') + '\n')
    _window.stdin.flush()
    log(f'prompt: {text}')


def page_logs():
    """The page's logs so far (its "TEST …" lines in app.log, without "TEST ")."""
    return [line[line.find('TEST ') + 5:] for line in app_log().splitlines() if 'TEST ' in line]


def relay(until='done', timeout=900):
    """Shows each "ask: <text>" the page logs as a prompt, until the page logs "<until>…": whether it did."""
    shown = 0
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        logs = page_logs()
        asks = [line[5:] for line in logs if line.startswith('ask: ')]
        for ask in asks[shown:]:
            prompt(ask)
        shown = len(asks)
        if any(line.startswith(until) for line in logs):
            return True
        time.sleep(0.2)
    return False


def done():
    if _window is not None and _window.poll() is None:
        _window.stdin.close()
        _window.wait(timeout=5)
