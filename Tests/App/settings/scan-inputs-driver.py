# scan-inputs-driver.py, for scan-inputs.test.js: edits Settings → Scanning's advanced scanning inputs over Accessibility
# and checks the lists saved.
import os, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import ax, check, controls, equal, open_settings, settings, until


def saved(want=None):
    """The lists saved: once they're `want` (up to 3 s), or with none (something that mustn't be saved) after 0.8 s."""
    def now():
        values = settings()
        return {'scanInputs': values.get('scanInputs'), 'popupScanInputs': values.get('popupScanInputs')}
    if want is None:
        time.sleep(0.8)
        return now()
    return until(lambda: now() == want, timeout=3) and want or now()


def fields():
    """The scan input fields' values (both lists'), in order."""
    return [c['value'] for c in controls('MacPopup Settings') if c['role'] == 'AXTextField' and c['placeholder'] == 'hover']


def unrecognized():
    return [c['value'] for c in controls('MacPopup Settings') if c['role'] == 'AXStaticText' and c['value'].startswith('Unrecognized input')]


if open_settings('Scanning', 'Advanced scanning inputs'):
    equal(fields(), ['shift', 'alt', 'ctrl', 'mouse2'], 'the fields at first')
    # Row 3 is being edited when row 1 is removed: the edit ends (another field focused) on what is now row 2.
    ax('type', 'AXTextField', 'hover', 3, 'meta')
    ax('press', 'AXButton', 'Remove', 1)
    ax('focus', 'AXTextField', 'hover', 3)
    want = {'scanInputs': ['alt', 'meta'], 'popupScanInputs': ['mouse2']}
    equal(saved(want), want,
          "an edit ended after removing a row above it goes to its own row, not the popup's list")
    equal(fields(), ['alt', 'meta', 'mouse2'], 'the fields then')

    ax('set', 'AXTextField', 'hover', 1, 'foo')
    equal(saved()['scanInputs'], ['alt', 'meta'], 'an unknown input name is not saved')
    equal(unrecognized(), ['Unrecognized input: foo'], 'the note under it')

    ax('set', 'AXTextField', 'hover', 1, 'shift alt')
    want = {'scanInputs': ['alt shift', 'meta'], 'popupScanInputs': ['mouse2']}
    equal(saved(want), want, 'inputs saved in canonical order')
    equal(unrecognized(), [], 'the note goes')

    ax('press', 'AXButton', 'Remove', 2)
    want = {'scanInputs': ['alt shift'], 'popupScanInputs': ['mouse2']}
    equal(saved(want), want, 'after removing row 2')
    # Row 1 is still focused, showing what was typed until its editing ends.
    ax('focus', 'AXTextField', 'hover', 2)
    time.sleep(0.5)
    equal(fields(), ['alt shift', 'mouse2'], 'the fields at the end, row 1 in canonical order once its editing ended')
