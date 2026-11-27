# yomitan-profile-driver.py, for yomitan-profile.test.js and yomitan-profile-retry.test.js: which Yomitan Popup rows
# Settings shows as controlled by the Yomitan profile (greyed out, with a note), over Accessibility.
import os, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import ax, check, controls, equal, log, open_settings, settings, until

NOTE = 'Controlled by your Yomitan settings.'
# The rows of SettingsSchema.yomitanDisplayKeys in the section, then those of yomitanDictionaryKeys, by their labels.
DISPLAY = ['Theme', 'Scale', 'Display mode', 'Font family', 'Font size', 'Line height', 'Compact glossaries', 'Compact tags',
           'Show tags for expressions and their readings', 'Average frequencies', 'Frequency display style', 'Term display style',
           'Pitch accent display styles (downstep notation)', 'Pitch accent display styles (downstep position)',
           'Pitch accent display styles (graph)', 'Selection indicator style', 'Action bar appearance (visibility)',
           'Action bar appearance (location)', 'Popup CSS', 'Popup outer CSS']
DICTIONARY = ['Default dictionary collapse behavior', 'Per-dictionary collapse rules', 'Imported dictionary styles']


def controlled():
    """The labels of the rows with the note: each note's row is the last of their labels before it (a switch comes
    between a row's label and its hint and note)."""
    labels, row = [], None
    for c in controls('MacPopup Settings'):
        if c['role'] != 'AXStaticText':
            continue
        if c['value'] in DISPLAY + DICTIONARY:
            row = c['value']
        elif c['value'] == NOTE:
            labels.append(row)
    return labels


def in_order(labels):
    """The rows in the section's order (DISPLAY's Popup CSS rows come after the dictionary ones)."""
    order = DISPLAY[:-2] + DICTIONARY[:2] + DISPLAY[-2:] + DICTIONARY[2:]
    return [label for label in order if label in labels]


def enabled(role, description):
    found = [c['enabled'] for c in controls('MacPopup Settings') if c['role'] == role and c['description'] == description]
    return found[0] == '1' if found else None


def check_profile():
    """With the profile given and useYomitanDisplay on, then off."""
    rows = until(lambda: len(controlled()) == len(DISPLAY + DICTIONARY) and controlled(), timeout=10)
    equal(rows or controlled(), in_order(DISPLAY + DICTIONARY), 'rows controlled by Yomitan with its display settings used')
    equal(enabled('AXPopUpButton', 'Scale'), False, 'the Scale menu is disabled')
    # The section's first switch: Use Yomitan's display settings.
    ax('press', 'AXCheckBox', '', 1)
    time.sleep(1)
    equal(settings().get('useYomitanDisplay'), False, 'useYomitanDisplay saved')
    equal(controlled(), in_order(DICTIONARY), 'rows controlled by Yomitan without its display settings: the dictionary ones')
    equal(enabled('AXPopUpButton', 'Scale'), True, 'the Scale menu is enabled')


if __name__ == '__main__':
    retry = len(sys.argv) > 1 and sys.argv[1] == 'retry'
    if open_settings('Yomitan Popup', 'Use Yomitan’s display settings'):
        if retry:
            # The displayOptions requests at launch failed (MOCK_PROFILE_FAIL_FOR): no profile until YomitanAPIStatus
            # asks again, at its next check (every 30 s).
            time.sleep(2)
            equal(controlled(), [], 'rows controlled by Yomitan after the failed request')
            began = time.monotonic()
            rows = until(lambda: controlled(), timeout=40, interval=1)
            check(bool(rows), f'rows controlled by Yomitan once it was asked again ({len(rows or [])}, '
                              f'after {time.monotonic() - began:.0f} s more)')
        check_profile()
