# manual.py: what the manual tests' drivers share (they import it from Tests/Manual, with harness/tools/driver.py):
# prompt(text) shows the person at the Mac what to do, in a window of its own at the top of the screen
# (tools/prompt.swift, which never takes the keyboard from the test instance), and logs it; done() closes it.
import os, subprocess, sys
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import log

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


def done():
    if _window is not None and _window.poll() is None:
        _window.stdin.close()
        _window.wait(timeout=5)
