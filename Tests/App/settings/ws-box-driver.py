# ws-box-driver.py <case>, for the ws-box-*.test.js tests: types into Settings → WebSockets' URL box with real keys
# (clicking into it first), ends the editing (⌃⇥) and checks the URLs saved, the text the box shows and how many lines
# tall it is. Keys go only while the test instance is the frontmost app and none of its menus is open, the click only
# where its Settings window is in front, without modifiers; the pointer is put back afterwards.
import os, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, ax, check, controls, equal, keep_pointer, keys, log, logged, mouse, open_settings, running, settings

LONG = 'ws://127.0.0.1:59901/a-very-long-path-that-goes-past-the-right-edge-of-the-settings-box/and-further-still/end'
# The steps typed (after a click in the box and ⌘↓ to its end), the URLs then saved and the box's lines.
CASES = {
    # A stored URL with line breaks in it shows as lines (typing on the fifth once recursed until the stack
    # overflowed); Return on the fifth beeps and adds nothing.
    'linebreaks': (['type:x', 'return', 'type:y'], ['ws://a', 'ws://b', 'ws://c', 'ws://d', 'ws://exy'], 5),
    # Text with Windows line breaks typed as one key press (as a paste): split into lines, keeping those that fit.
    'crlf': (['return', 'type:ws://b\\r\\nws://c\\r\\nws://d\\r\\nws://e\\r\\nws://f\\r\\nws://g'],
             ['ws://a', 'ws://b', 'ws://c', 'ws://d', 'ws://e'], 5),
    # Return on the fifth line beeps, and the next letter goes on it.
    'fifth': (['return', 'type:b', 'return', 'type:c', 'return', 'type:d', 'return', 'type:e', 'return', 'type:f'],
              ['ws://a', 'b', 'c', 'd', 'ef'], 5),
    # A long URL doesn't wrap: three URLs and the empty line under them.
    'long': (['return', 'type:ws://x'], ['ws://127.0.0.1:59900', LONG, 'ws://x'], 4),
    # The list changed while Settings is open (the page saves 5 URLs, as an import would) after an edit that left the
    # text as it was: the box grows to them.
    'import': (['return', 'backspace'], [f'ws://127.0.0.1:5991{n}' for n in range(1, 6)], 5),
}
case = sys.argv[1]
steps, want, want_lines = CASES[case]
# CodeEditor.height: 13 pt a line (NSLayoutManager's for the small monospaced system font), 4 pt insets above and
# below, the 1 pt border (no scroller with overlay scrollbars).
LINE, EXTRA = 13, 10


def frames():
    ok, out = ax('frame', 'AXTextArea', '*', 1)
    rows = [[float(v) for v in line.split()] if line != 'none' else None for line in out.splitlines()[:2]]
    return (rows + [None, None])[:2] if ok else (None, None)


def text():
    areas = [c['value'] for c in controls('MacPopup Settings') if c['role'] == 'AXTextArea']
    return areas[0] if areas else None


if open_settings('WebSockets', 'WebSocket URLs (one per line)'):
    keep_pointer()
    time.sleep(1)
    area, scroll = frames()
    log(f'the box: text {area}, scroll view {scroll}')
    sent = check(scroll is not None, 'the URL box is there')
    if sent:
        x, y = scroll[0] + scroll[2] / 2, scroll[1] + min(scroll[3] / 2, 20)
        ok, out = mouse('click', PID, round(x), round(y))
        sent = check(ok, f'clicked into the box ({out or "ok"})')
        time.sleep(0.3)
    if sent:
        sent = keys([PID], 'textend')
        time.sleep(0.4)
    for step in steps:
        if not sent:
            break
        sent = keys([PID], step)
        time.sleep(0.4)
    if sent:
        sent = keys([PID], 'end')
        time.sleep(0.4)
    check(sent, 'every key sent (the test instance in front, no menu open)')
    if case == 'import':
        log('edited')
        check(bool(logged('saved 5 URLs', timeout=20)), 'the page saved 5 URLs')
    time.sleep(1.5)
    check(running(), 'MacPopup still running')
    equal(settings().get('websocketUrls'), want, 'the URLs saved')
    # (ax list puts a space for each line break.)
    equal(text(), ' '.join(want), 'the text in the box, its lines joined with spaces')
    area, scroll = frames()
    log(f'the box at the end: text {area}, scroll view {scroll}')
    lines = round((scroll[3] - EXTRA) / LINE) if scroll else None
    equal(lines, want_lines, f'the box\'s lines ({scroll[3] if scroll else "-"} pt tall)')
    if case == 'long':
        check(area is not None and scroll is not None and area[2] > scroll[2] + 50,
              f'the long URL doesn\'t wrap: the text is wider than the box ({area and area[2]} pt, the box {scroll and scroll[2]} pt)')
