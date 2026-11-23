# resize-driver.py, for resize.test.js: drags the Settings window's right edge out 200 pt and in 150 pt, then its bottom
# edge down 150 pt (less when the screen has less room under it), with the real pointer, and checks its size after each:
# it resizes in height only (the sections' layout is made for its 820 pt width). Presses only where its window is in
# front, without modifiers; the pointer is put back afterwards.
import os, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, check, equal, keep_pointer, log, mouse, open_settings, running

TITLE = 'MacPopup Settings'


def frame(title=TITLE):
    ok, out = mouse('window', PID, *([title] if title else []))
    return [int(v) for v in out.split()[:4]] if ok else None


def drag(what, a, b):
    ok, out = mouse('drag', PID, *a, *b)
    time.sleep(0.6)
    now = frame()
    log(f'{what}: {out or "dragged"}, the window {now}')
    check(ok, f'{what}: dragged ({out or "ok"})')
    return now


if open_settings('WebSockets', 'WebSocket URLs (one per line)'):
    keep_pointer()
    time.sleep(1)
    start = frame()
    screen = frame(None)  # The instance's largest window: the overlay, as big as its screen.
    log(f'the window {start}, the overlay {screen}')
    if check(start is not None, 'the Settings window is on screen'):
        x, y, w, h = start
        equal(w, 820, 'its width at first')
        # Edges are grabbed just inside the window.
        now = drag('right edge out 200', (x + w - 1, y + h // 2), (x + w + 199, y + h // 2))
        equal(now and now[2:], [w, h], 'after dragging the right edge out 200 pt: its size')
        now = drag('right edge in 150', (x + w - 1, y + h // 2), (x + w - 151, y + h // 2))
        equal(now and now[2:], [w, h], 'after dragging the right edge in 150 pt: its size')
        # Room under it, leaving the Dock's.
        room = min(150, (screen[1] + screen[3] - 100) - (y + h)) if screen else 150
        if check(room >= 50, f'room under the window to drag its bottom edge ({room} pt)'):
            now = drag(f'bottom edge down {room}', (x + w // 2, y + h - 1), (x + w // 2, y + h - 1 + room))
            equal(now and now[2], w, f'after dragging the bottom edge down {room} pt: its width')
            check(now is not None and abs(now[3] - (h + room)) <= 2,
                  f'after dragging the bottom edge down {room} pt: its height {now and now[3]} (expected {h + room} ± 2)')
    check(running(), 'MacPopup still running')
