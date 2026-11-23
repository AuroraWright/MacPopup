# sections-driver.py <sections|steady>, for sections.test.js and steady.test.js: Settings' sections over Accessibility
# and window-only screenshots (screencapture -l, in the run folder), after scratch-tools/settings-shot.
#   sections: shows each section in turn (the sidebar's, which must be the ones in MARKERS): a text of its own shows, the
#     screenshot is the window's size and not blank, and a second one a second later shows the same form, pixel for
#     pixel (once more when it doesn't: the window's turning active or not may tint it).
#   steady: for sections with a setting whose control changes width (menus, numbers, the captured window), the page
#     sets one value and then the other (it applies what the driver says, see steady.test.js): the texts of the form's
#     left column (labels and hints) keep their frames, and none of their pixels change; the changed rows are logged.
import os, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, RUN, SUITE, check, equal, log, logged, tool, until, window_shot
from PIL import Image, ImageChops

MODE = sys.argv[1]
TITLE = 'MacPopup Settings'
# A text each section shows first (its first label, or the start of its description), in the sidebar's order.
MARKERS = {
    'General': 'Overlay type',
    'WebSockets': 'WebSocket URLs (one per line)',
    'Floating Window': 'Background opacity',
    'OCR Overlay': 'Only check for changes after input activity',
    'OCR': 'Text recognition engine',
    'Transcription': 'Speech recognition model',
    'Scanning': 'Yomitan API URL',
    'Yomitan Popup': 'Use Yomitan’s display settings',
    'Popup Shortcuts': 'Keyboard shortcuts that work whenever',
    'Controllers': 'Look up words with a game controller',
    'Anki': 'Enable Anki integration',
    'Anki Screenshot': 'Screenshot format',
    'Anki Audio': 'Sentence audio field',
    'IINA Integration': 'IINA plugin',
    'Permissions': 'Screen Recording',
}
# steady-pairs.sh's: a section, then two sets of values for it.
PAIRS = [
    ('Anki Screenshot', 'shot', {'screenshotResolution': '1x'}, {'screenshotResolution': 'full'}),
    ('OCR Overlay', 'ocr', {'gamepadOcrStart': 'bottom'}, {'gamepadOcrStart': 'top'}),
    ('General', 'general', {'language': 'ja', 'ocrWindow': {'ownerName': 'A', 'title': ''}},
     {'language': 'en', 'ocrWindow': {'ownerName': 'MacPopupTestNoSuchApp', 'title': 'A much longer window title than the other'}}),
    ('Yomitan Popup', 'popup',
     {'popupTheme': 'light', 'popupOuterTheme': 'light', 'popupScalingFactor': 1, 'popupWidth': 400, 'popupHeight': 250},
     {'popupTheme': 'site', 'popupOuterTheme': 'none', 'popupScalingFactor': 0.25, 'popupWidth': 12000, 'popupHeight': 9}),
]


def frames():
    """The Settings window's frame and its texts: ((x, y, w, h), [(text, (x, y, w, h))]), in points."""
    output = subprocess.run([tool('ax'), PID, 'frames', TITLE], capture_output=True, text=True).stdout
    window, texts = None, []
    for line in output.splitlines():
        role, _, rest = line.partition('\t')
        text, _, frame = rest.rpartition('\t')
        if frame == 'none':
            continue
        box = tuple(float(v) for v in frame.split())
        if role == 'AXWindow':
            window = box
        else:
            texts.append((text, box))
    return window, texts


def show(section):
    """Has Settings show a section, and waits for its marker: whether it came."""
    subprocess.run(['defaults', 'write', SUITE, 'settingsSection', '-string', section])
    marker = MARKERS[section]
    return bool(until(lambda: any(text.startswith(marker) for text, _ in frames()[1]), timeout=15, interval=0.3))


def shot(name):
    path = window_shot(TITLE, name)
    return Image.open(path).convert('RGB') if path else None


def changed_rows(a, b):
    """Where two shots differ: runs of 4-pixel rows with the leftmost and rightmost changed x (steady-diff.py)."""
    diff = ImageChops.difference(a, b).convert('L').point(lambda v: 255 if v > 24 else 0)
    runs = []
    for top in range(0, diff.height, 4):
        box = diff.crop((0, top, diff.width, min(diff.height, top + 4))).getbbox()
        if not box:
            continue
        if runs and top - runs[-1][3] <= 4:
            runs[-1] = (min(runs[-1][0], box[0]), runs[-1][1], max(runs[-1][2], box[2]), top + 4)
        else:
            runs.append((box[0], top, box[2], top + 4))
    return diff, runs


if not until(lambda: frames()[0], timeout=20, interval=0.5):
    check(False, 'the Settings window opened')
    sys.exit(0)

if MODE == 'sections':
    sidebar = [text for text, (x, y, w, h) in frames()[1] if text in MARKERS]
    # (A section title can also be a text of the form shown, e.g. a hint naming it: the sidebar's come first.)
    equal(sidebar[:len(MARKERS)], list(MARKERS), "the sidebar's sections")
    for n, section in enumerate(MARKERS, 1):
        if not check(show(section), f'{section} shows "{MARKERS[section]}"'):
            continue
        time.sleep(1.5)
        window, _ = frames()
        name = f'{n:02d}-{section.replace(" ", "-").lower()}'
        first = shot(name)
        time.sleep(1)
        again = shot(f'{name}-again')
        if not check(first is not None and again is not None, f'{section}: screenshots taken'):
            continue
        scale = first.width / window[2]
        check(scale in (1, 2, 3) and abs(first.height - window[3] * scale) <= 2,
              f'{section}: the screenshot {first.width}x{first.height} is the window ({window[2]:.0f}x{window[3]:.0f} points)')
        # The form, right of the sidebar (200 points): many colors, and more than a sliver of it drawn.
        form = first.crop((int(201 * scale), 0, first.width, first.height))
        colors = len(form.getcolors(1 << 20) or [])
        background = max(form.getcolors(1 << 20))[0]
        drawn = 1 - background / (form.width * form.height)
        check(colors >= 50 and drawn >= 0.02, f'{section}: the form drawn ({colors} colors, {drawn:.1%} not background)')
        # The form only: the title bar and sidebar change with the window's being active or not, which another app
        # coming to the front changes. Once more when they differ, in case that also tinted the form's controls.
        form_box = (int(201 * scale), int(30 * scale), first.width, first.height)
        _, runs = changed_rows(first.crop(form_box), again.crop(form_box))
        if runs:
            log(f'{section}: changed a second later (rows {runs[:5]}), once more')
            time.sleep(1)
            first, again = again, shot(f'{name}-again2')
            _, runs = changed_rows(first.crop(form_box), again.crop(form_box))
        check(not runs, f"{section}: the form the same a second later" + (f' (changed rows {runs[:5]})' if runs else ''))
else:
    for n, (section, name, a, b) in enumerate(PAIRS):
        states = []
        for step, values in ((2 * n + 1, a), (2 * n + 2, b)):
            log(f'apply {step} {__import__("json").dumps(values, ensure_ascii=False)}')
            if not check(bool(logged(f'applied {step}', timeout=20)), f'{section}: the page applied {values}'):
                break
            if step % 2 and not check(show(section), f'{section} shows "{MARKERS[section]}"'):
                break
            time.sleep(1.5)
            window, texts = frames()
            image = shot(f'steady-{name}-{"ab"[step % 2 == 0]}')
            states.append((window, texts, image))
        if len(states) < 2 or not check(all(s[2] is not None for s in states), f'{section}: screenshots taken'):
            continue
        (wa, ta, ia), (wb, tb, ib) = states
        if not check(wa == wb and ia.size == ib.size, f'{section}: the same window size ({wa[2]:.0f}x{wa[3]:.0f}, {wb[2]:.0f}x{wb[3]:.0f})'):
            continue
        scale = ia.width / wa[2]
        # The form's left column: the texts starting at its left edge (labels and their hints).
        form_left = min(x for _, (x, y, w, h) in ta if x > wa[0] + 201)
        left = lambda texts: [(t, f) for t, f in texts if abs(f[0] - form_left) <= 4]
        la, lb = left(ta), left(tb)
        moved = [(t, fa, fb) for (t, fa), (_, fb) in zip(la, lb) if any(abs(p - q) > 0.5 for p, q in zip(fa, fb))]
        equal([t for t, _ in la], [t for t, _ in lb], f'{section}: the left column\'s texts')
        check(not moved, f'{section}: {len(la)} labels and hints keep their frames'
              + ''.join(f'; "{t[:40]}" {fa} -> {fb}' for t, fa, fb in moved[:5]))
        diff, runs = changed_rows(ia, ib)
        log(f'{section}: changed rows (pixels) ' + ', '.join(f'y {t}-{bt}: x {l}-{r}' for l, t, r, bt in runs))
        touched = []
        for t, (x, y, w, h) in la:
            box = tuple(round(v) for v in ((x - wa[0]) * scale, (y - wa[1]) * scale, (x - wa[0] + w) * scale, (y - wa[1] + h) * scale))
            if diff.crop(box).getbbox():
                touched.append(t[:40])
        check(not touched, f'{section}: no pixel of the left column changed' + (f' (changed: {touched})' if touched else ''))
    log('apply end')
