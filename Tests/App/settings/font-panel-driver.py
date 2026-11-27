# font-panel-driver.py <panel|seeded|scroll>, for font-panel*.test.js: Settings → Floating Window → Font and the macOS
# Fonts panel over Accessibility (tools/ax.swift), the panel's level from the window list (tools/wins.swift), the
# saved settings, and window-only screenshots of Settings (seeded). After evals/settings-ax/steps-font*.zsh.
#   panel:  Choose… opens the panel at Settings' level, key, showing the size; its size field, shadow switch and
#           underline/strikethrough menus save fontSize and boxFontEffects (the row's text follows); Clear with the panel
#           open resets them and the panel; closing Settings closes the panel.
#   seeded: a font, size and effects already saved: the row's text and its drawing (background and text colors); Choose…
#           shows that typeface and size in the panel, and a size picked there keeps the font and effects; Clear (the
#           panel closed) resets the font, size and effects and nothing else.
#   scroll: the panel stays open while the Font row is scrolled out of view and back, closes on another section, and
#           with Settings.
# The typeface list itself isn't driven: neither AX selection nor posted clicks or keys send its action.
#
# A test instance showing the Fonts panel saves its frame ("NSWindow Frame NSFontPanel") in the user's own
# com.aury.macpopup domain (AppKit's frame autosave goes to the standard defaults, not the instance's suite). That key is
# put back as it was before the test (launch.sh's export, $RUN/user-settings.plist) once Settings and the panel are
# closed: deleted when it wasn't there, its old value written back when the panel moved. Nothing else of that domain is
# touched.
import os, plistlib, re, signal, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, RUN, SUITE, ax, check, controls, equal, log, open_settings, settings, tool, until, window_shot

MODE = sys.argv[1]
TITLE = 'MacPopup Settings'
PANEL = 'Fonts'
USER_DOMAIN = 'com.aury.macpopup'
FRAME_KEY = 'NSWindow Frame NSFontPanel'
KEYS = ('boxFontFamily', 'fontSize', 'boxFontEffects')
SEEDED_EFFECTS = {
    'color': '#ff0000ff', 'backgroundColor': '#00c000ff', 'underline': 'single', 'underlineColor': '#0000ffff',
    'shadow': {'x': 2, 'y': 3, 'blur': 4, 'color': '#000000ff'},
}


# The user's frame key.

def frame_key_before():
    """The key's value in launch.sh's export of the user's domain (before the instance started), or None."""
    with open(f'{RUN}/user-settings.plist', 'rb') as f:
        return plistlib.load(f).get(FRAME_KEY)


def frame_key_now():
    result = subprocess.run(['defaults', 'read', USER_DOMAIN, FRAME_KEY], capture_output=True, text=True)
    return result.stdout.removesuffix('\n') if result.returncode == 0 else None


def put_frame_key_back(before):
    now = frame_key_now()
    if now == before:
        log(f'the user\'s "{FRAME_KEY}": {"unchanged" if before is not None else "not there"}')
    elif before is None:
        subprocess.run(['defaults', 'delete', USER_DOMAIN, FRAME_KEY], capture_output=True)
        log(f'the user\'s "{FRAME_KEY}": written by the instance ({now!r}), deleted')
    else:
        subprocess.run(['defaults', 'write', USER_DOMAIN, FRAME_KEY, '-string', before], capture_output=True)
        log(f'the user\'s "{FRAME_KEY}": changed by the instance ({now!r}), its value from before written back')
    equal(frame_key_now(), before, f'the user\'s "{FRAME_KEY}" as before the test')


# Settings' Font row.

def saved():
    values = settings()
    return {key: values.get(key) for key in KEYS}


def saved_becomes(expected, timeout=5):
    return until(lambda: (lambda s: s if s == expected else None)(saved()), timeout=timeout) or saved()


def row_text():
    """The text under the Font row's buttons ("System font, 24 px")."""
    texts = [c['value'] for c in controls(TITLE) if c['role'] == 'AXStaticText' and re.search(r', [\d.]+ px$', c['value'])]
    return texts[0] if texts else None


def row_text_becomes(expected, timeout=5):
    return until(lambda: (lambda t: t if t == expected else None)(row_text()), timeout=timeout) or row_text()


def clear_enabled():
    """Whether the Font row's Clear (the button after Choose…) is enabled, or None without the row."""
    buttons = [c for c in controls(TITLE) if c['role'] == 'AXButton']
    names = [c['description'] or c['title'] for c in buttons]
    if 'Choose…' not in names or names[names.index('Choose…') + 1:][:1] != ['Clear']:
        return None
    return buttons[names.index('Choose…') + 1]['enabled'] == '1'


def press_choose():
    ok, _ = ax('press', 'AXButton', 'Choose…', 1)
    return check(ok and bool(until(panel_on_screen, timeout=5)), 'Choose… shows the Fonts panel')


# The Fonts panel.

def on_screen():
    """The instance's on-screen windows: {title: layer}."""
    lines = subprocess.run([tool('wins'), PID], capture_output=True, text=True).stdout.splitlines()
    return {fields[6]: int(fields[1]) for fields in (line.split('\t') for line in lines) if len(fields) == 7 and fields[6]}


def panel_on_screen():
    return PANEL in on_screen()


def size_field():
    """The panel's size field (the text field outside its lists): its value and its n for ax set, or (None, None)."""
    fields = [c for c in controls() if c['role'] == 'AXTextField']
    for c in fields:
        if c['window'] == PANEL and c['help'] == '':
            value = c['value']
            same = [d for d in fields if value in (d['help'], d['title'], d['description'], d['placeholder'], d['value'])]
            return value, same.index(c) + 1
    return None, None


def set_size(size):
    """Types a size into the panel's size field and confirms it, as Return does."""
    value, n = size_field()
    return value is not None and ax('set', 'AXTextField', value, n, size)[0]


def shadow_switch():
    found = [c['value'] for c in controls(PANEL) if c['role'] == 'AXCheckBox' and c['description'] == 'Shadow Toggle']
    return found[0] if found else None


def pick(menu, item):
    """Opens one of the panel's effects menus (its menu button's description) and picks an item."""
    ok, _ = ax('press', 'AXMenuButton', menu, 1)
    shown = ok and until(lambda: any(c['role'] == 'AXMenuItem' and c['title'] == item for c in controls()), timeout=5)
    return bool(shown) and ax('press', 'AXMenuItem', item, 1)[0]


def close_settings():
    if TITLE in on_screen() or TITLE in subprocess.run([tool('ax'), PID, 'windows'], capture_output=True, text=True).stdout:
        ax('close', TITLE)
    gone = until(lambda: not {TITLE, PANEL} & set(on_screen()), timeout=5)
    return gone


# The row's drawing (seeded).

def row_pixels(name):
    """Window-only screenshot of Settings, and the Font row's text cropped from it: (green background fraction, red text
    fraction), or None. (#00c000 and #ff0000 saved, loosely, as the display's color space shifts them.)"""
    from PIL import Image
    output = subprocess.run([tool('ax'), PID, 'frames', TITLE], capture_output=True, text=True).stdout
    window = text = None
    for line in output.splitlines():
        role, value, frame = (line.split('\t') + ['', ''])[:3]
        if frame == 'none' or not frame:
            continue
        box = tuple(float(v) for v in frame.split())
        if role == 'AXWindow':
            window = box
        elif re.search(r', [\d.]+ px$', value):
            text = box
    path = window_shot(TITLE, name)
    if not (window and text and path):
        return None
    image = Image.open(path).convert('RGB')
    scale = image.width / window[2]
    x, y, w, h = text
    crop = image.crop(tuple(round(v * scale) for v in (x - window[0], y - window[1], x - window[0] + w, y - window[1] + h)))
    data = crop.tobytes()
    pixels = [tuple(data[i:i + 3]) for i in range(0, len(data), 3)]
    green = sum(1 for r, g, b in pixels if g > 140 and r < 120 and b < 110 and g - r > 60) / len(pixels)
    red = sum(1 for r, g, b in pixels if r > 170 and g < 110 and b < 110) / len(pixels)
    log(f'{name}: {crop.width}x{crop.height} pixels, {green:.1%} green, {red:.1%} red')
    return green, red


# The modes.

def panel():
    equal(row_text(), 'System font, 24 px', "the row's text at first")
    equal(clear_enabled(), False, 'Clear disabled at first')
    check(not panel_on_screen(), 'no Fonts panel before Choose…')
    if not press_choose():
        return
    time.sleep(1)
    layers = on_screen()
    check(layers.get(PANEL) == layers.get(TITLE) and layers.get(PANEL, 0) > 3,
          f"the panel's window level is Settings' (panel {layers.get(PANEL)}, Settings {layers.get(TITLE)}, floating 3)")
    out = subprocess.run([tool('ax'), PID, 'focused'], capture_output=True, text=True).stdout.strip()
    equal(out, PANEL, 'the key window after Choose…')
    equal(size_field()[0], '24', "the panel's size")

    check(set_size(30), 'a size typed into the panel')
    equal(saved_becomes({'boxFontFamily': '', 'fontSize': 30, 'boxFontEffects': {}}),
          {'boxFontFamily': '', 'fontSize': 30, 'boxFontEffects': {}}, 'saved after the size 30')
    equal(row_text_becomes('System font, 30 px'), 'System font, 30 px', "the row's text")
    equal(clear_enabled(), True, 'Clear enabled')

    ax('press', 'AXCheckBox', 'Shadow Toggle', 1)
    with_shadow = until(lambda: (lambda s: s if 'shadow' in s['boxFontEffects'] else None)(saved()), timeout=5) or saved()
    shadow = with_shadow['boxFontEffects'].get('shadow') or {}
    check(set(shadow) == {'x', 'y', 'blur', 'color'} and isinstance(shadow.get('blur'), (int, float))
          and re.fullmatch(r'#000000[0-9a-f]{2}', str(shadow.get('color'))),
          f"the panel's shadow switch saves a shadow: {shadow}")
    equal([with_shadow['boxFontFamily'], with_shadow['fontSize']], ['', 30], 'the font and size kept')

    check(pick('text underline', 'Double'), 'Double picked in the underline menu')
    until(lambda: saved()['boxFontEffects'].get('underline'), timeout=5)
    check(pick('text strikethrough', 'Single'), 'Single picked in the strikethrough menu')
    effects = (until(lambda: (lambda s: s if s['boxFontEffects'].get('strikethrough') else None)(saved()), timeout=5)
               or saved())['boxFontEffects']
    equal({k: effects.get(k) for k in ('underline', 'strikethrough')}, {'underline': 'double', 'strikethrough': 'single'},
          'saved lines')
    check('shadow' in effects, 'the shadow kept with the lines')

    ax('press', 'AXButton', 'Clear', 1)
    defaults = {'boxFontFamily': '', 'fontSize': 24, 'boxFontEffects': {}}
    equal(saved_becomes(defaults), defaults, 'Clear (the panel open): the defaults saved')
    equal(row_text_becomes('System font, 24 px'), 'System font, 24 px', "the row's text after Clear")
    equal(clear_enabled(), False, 'Clear disabled after Clear')
    equal([size_field()[0], shadow_switch()], ['24', '0'], "the panel after Clear: its size and shadow switch")
    check(panel_on_screen(), 'the panel stays open after Clear')

    check(close_settings(), 'closing Settings closes the Fonts panel')


def seeded():
    text = row_text()
    check(bool(text) and text.endswith(', 30 px') and 'W3' in text and not text.startswith('System font'),
          f"the row's text names the saved font: {text!r}")
    equal(clear_enabled(), True, 'Clear enabled')
    time.sleep(0.5)
    pixels = row_pixels('row-effects')
    check(bool(pixels) and pixels[0] > 0.25 and pixels[1] > 0.005,
          f"the row's text drawn with the saved background and text colors: {pixels}")

    if press_choose():
        time.sleep(1)
        typeface = subprocess.run([tool('ax'), PID, 'selected', 'typeface list'], capture_output=True, text=True).stdout.strip()
        check(typeface in ('ヒラギノ明朝 ProN', 'Hiragino Mincho ProN'), f"the panel's typeface: {typeface!r}")
        equal(size_field()[0], '30', "the panel's size")
        check(set_size(36), 'a size typed into the panel')
        expected = {'boxFontFamily': 'HiraMinProN-W3', 'fontSize': 36, 'boxFontEffects': SEEDED_EFFECTS}
        equal(saved_becomes(expected), expected, 'a size from the panel keeps the font and effects')
        ax('close', PANEL)
        check(bool(until(lambda: not panel_on_screen(), timeout=5)), "the panel closed (its close button)")

    ax('press', 'AXButton', 'Clear', 1)
    defaults = {'boxFontFamily': '', 'fontSize': 24, 'boxFontEffects': {}}
    equal(saved_becomes(defaults), defaults, 'Clear: the defaults saved')
    equal(settings().get('linePadding'), 7, 'Line spacing kept by Clear')
    equal(row_text_becomes('System font, 24 px'), 'System font, 24 px', "the row's text after Clear")
    equal(clear_enabled(), False, 'Clear disabled after Clear')
    time.sleep(0.5)
    pixels = row_pixels('row-cleared')
    check(bool(pixels) and pixels[0] < 0.01 and pixels[1] < 0.001, f"the row's text drawn without the colors: {pixels}")
    close_settings()


def scroll():
    if not press_choose():
        return
    window = until(lambda: next((tuple(map(float, line.split('\t')[2].split())) for line in
                                 subprocess.run([tool('ax'), PID, 'frames', TITLE], capture_output=True, text=True).stdout.splitlines()
                                 if line.startswith('AXWindow\t')), None), timeout=5)

    def choose_frame():
        out = subprocess.run([tool('ax'), PID, 'frame', 'AXButton', 'Choose…', '1'], capture_output=True, text=True)
        return tuple(map(float, out.stdout.splitlines()[0].split())) if out.returncode == 0 else None

    def in_view(frame):
        return frame is not None and frame[1] + frame[3] > window[1] and frame[1] < window[1] + window[3]

    ax('scroll', 'Line spacing', 1)
    time.sleep(1.2)
    frame = choose_frame()
    check(not in_view(frame), f'the Font row scrolled out of view (Choose… {"at " + str(frame) if frame else "unloaded"}, '
          f'the window {window})')
    check(panel_on_screen(), 'the panel stays open with the row out of view')
    ax('scroll', 'Line spacing', 0)
    time.sleep(1.2)
    check(in_view(choose_frame()), 'the Font row back in view')
    check(panel_on_screen(), 'the panel still open')

    subprocess.run(['defaults', 'write', SUITE, 'settingsSection', '-string', 'General'])
    check(bool(until(lambda: not panel_on_screen(), timeout=5)), 'another section closes the panel')
    check(TITLE in on_screen(), 'Settings stays open')
    if open_settings('Floating Window', 'Font') and press_choose():
        check(close_settings(), 'closing Settings closes the panel')


def main():
    before = frame_key_before()
    log(f'the user\'s "{FRAME_KEY}" before: {before!r}')
    # launch.sh's watchdog ends a stuck driver with SIGTERM: the key is put back then too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        if open_settings('Floating Window', 'Font'):
            {'panel': panel, 'seeded': seeded, 'scroll': scroll}[MODE]()
    finally:
        close_settings()
        time.sleep(1)
        put_frame_key_back(before)


main()
