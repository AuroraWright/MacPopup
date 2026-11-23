# iina-clear-driver.py, for iina-clear.test.js: Settings → IINA Integration → Saved transcriptions over Accessibility.
# The row's text and its Clear… button; Clear… (the button's press waits for the sheet it opens, so it runs on its own
# while the sheet's buttons are pressed), then Cancel, then Clear; the instance's transcripts folder after each; the
# user's transcripts unchanged.
import os, re, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, RUN, ax, check, controls, equal, log, open_settings, tool, until

TITLE = 'MacPopup Settings'
FOLDER = os.path.join(RUN, 'Library/Caches/com.aury.macpopup/Transcripts')
USER = os.path.expanduser('~/Library/Caches/com.aury.macpopup/Transcripts')
QUESTION = 'Clear saved transcriptions?'


def listing(path):
    """The folder's videos and their files, or None when it isn't there."""
    if not os.path.isdir(path):
        return None
    return {name: sorted(os.listdir(os.path.join(path, name))) if os.path.isdir(os.path.join(path, name)) else None
            for name in sorted(os.listdir(path))}


def row():
    """The row's text after its label ("2 videos, 360 KB", "None") and whether Clear… is enabled: (text, enabled)."""
    found, text, enabled = False, None, None
    for c in controls(TITLE):
        if c['role'] == 'AXStaticText' and c['value'] == 'Saved transcriptions':
            found = True
        elif found and text is None and c['role'] == 'AXStaticText' and re.match(r'^(None|\d+ videos?, .+)$', c['value']):
            text = c['value']
        elif found and c['role'] == 'AXButton' and 'Clear…' in (c['title'], c['description']):
            enabled = c['enabled'] == '1'
            break
    return text, enabled


def sheet():
    return any(c['role'] == 'AXStaticText' and c['value'] == QUESTION for c in controls(TITLE))


def press_clear():
    """Presses Clear…, which returns once its sheet is closed: the press, running."""
    log('pressing Clear…')
    return subprocess.Popen([tool('ax'), PID, 'press', 'AXButton', 'Clear…', '1'], stdout=subprocess.PIPE, text=True)


def answer(press, button):
    """Presses the sheet's button once it shows, and waits for the sheet and the Clear… press to end."""
    if not check(bool(until(sheet, timeout=10, interval=0.5)), f'Clear… asks first ("{QUESTION}")'):
        press.kill()
        return False
    buttons = [c for c in controls(TITLE) if c['role'] == 'AXButton' and button in (c['title'], c['description'])]
    equal(len(buttons), 1, f'buttons "{button}"')
    ax('press', 'AXButton', button, 1)
    check(bool(until(lambda: not sheet(), timeout=10, interval=0.5)), f'the sheet went after {button}')
    try:
        log(f'Clear…: {press.communicate(timeout=15)[0].strip()}')
    except subprocess.TimeoutExpired:
        press.kill()
    return True


def main():
    user_before = listing(USER)
    made = listing(FOLDER)
    equal(made, {'aaaa': ['MacPopup transcription', 'lines.json'], 'bbbb': ['lines.json']}, 'the made-up transcripts')
    if not open_settings('IINA Integration', 'Saved transcriptions'):
        return
    text, enabled = until(lambda: (lambda r: r if r[0] else None)(row()), timeout=10) or row()
    check(bool(text and re.match(r'^2 videos, [\d.,]+ KB$', text)), f'the row: {text!r} (2 videos, about 360 KB)')
    equal(enabled, True, 'Clear… enabled')

    if answer(press_clear(), 'Cancel'):
        time.sleep(1)
        equal(listing(FOLDER), made, 'the transcripts after Cancel')
        equal(row(), (text, True), 'the row after Cancel')

    if answer(press_clear(), 'Clear'):
        gone = until(lambda: listing(FOLDER) is None, timeout=5)
        check(bool(gone), f'the transcripts folder removed after Clear: {listing(FOLDER)}')
        cleared = until(lambda: (lambda r: r if r == ('None', False) else None)(row()), timeout=10)
        equal(cleared or row(), ['None', False], 'the row after Clear (its text, Clear… enabled)')
    equal(listing(USER), user_before, "the user's transcripts (~/Library/Caches/com.aury.macpopup/Transcripts)")


main()
