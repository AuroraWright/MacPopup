# key-recording-driver.py, for key-recording.test.js: starts each of Settings' recorders over Accessibility, asks the
# person at the Mac to press keys (manual.prompt), and checks what was saved.
import os, subprocess, sys
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
sys.path.insert(0, os.path.join(os.environ['REPO'], 'Tests/Manual'))
from driver import PID, SUITE, activate, ax, check, controls, open_settings, settings, until
from manual import done, prompt


def combination(value):
    """A saved key combination as (key, set of modifiers), or None."""
    return (value.get('key'), frozenset(value.get('modifiers') or [])) if isinstance(value, dict) else None


def record(button, index, ask, saved, expected, what):
    """Presses the recorder's button, asks for the keys and waits for the setting: whether it came as expected."""
    activate(PID)
    ax('press', 'AXButton', button, index)
    prompt(ask)
    got = until(lambda: saved(settings()), timeout=90, interval=0.3)
    return check(got == expected, f'{what}: {got} (expected {expected})')


try:
    if open_settings('Scanning', 'Advanced scanning inputs'):
        record('Record New Input', 1, 'Hold Option, Control and Shift together, then let go of them.',
               lambda s: next((set(i.split()) for i in s.get('scanInputs', []) if i != 'shift'), None),
               {'alt', 'ctrl', 'shift'}, 'Record New Input')

    if open_settings('Anki Audio', 'Recording key/buttons'):
        record('Click, then press a key combination', 1, 'Press Control-Option-R.',
               lambda s: combination(s.get('sentenceAudioShortcut')),
               ('KeyR', frozenset({'ctrl', 'alt'})), 'the recording key')
        record('Click, then press a key (with any modifier keys)', 1, 'Press Option-K.',
               lambda s: [combination(k) for k in s.get('sentenceAudioOpenKeys', [])] or None,
               [('KeyK', frozenset({'alt'}))], 'Add Key, the keys to open the backlog')

    # Popup Shortcuts has no row label of its own: its recorders' buttons say what they hold.
    subprocess.run(['defaults', 'write', SUITE, 'settingsSection', '-string', 'Popup Shortcuts'])
    first = until(lambda: next((c['help'] for c in controls('MacPopup Settings') if c['role'] == 'AXButton'
                                and c['help'].endswith('. Click to record a different key combination')), None),
                  timeout=20, interval=0.5)
    if check(bool(first), f'Settings shows Popup Shortcuts (its first recorder: {first})'):
        record(first, 1, 'Press Control-Shift-J.',
               lambda s: (lambda c: c if c and c[0] != 'Escape' else None)(combination((s.get('hotkeys') or [{}])[0])),
               ('KeyJ', frozenset({'ctrl', 'shift'})), 'the first popup shortcut')
    prompt('Done: thank you. You can leave the keyboard now.')
finally:
    done()
