# pointer.py: the driver of interactive tests whose page moves the real pointer (// driver: python3 -I
# "$HARNESS/tools/pointer.py", with MOCK_RUN_FILES=1). Does each move or click test-lib's pointerMove and pointerClick ask
# for ("TEST pointer move <name> <w>x<h> <x0> <y0> <x1> <y1> <ms>" or "TEST pointer click <name> <w>x<h> <x> <y>": points
# of the page, whose window is the instance's window of that size) with tools/mouse.swift, which goes only where the
# instance's window is in front, and answers in its log (driver.log, which the page reads): "pointer <name> moved",
# "pointer <name> clicked" or "pointer <name> refused: …". Ends once the page logs "TEST done" or the app quits, and
# puts the pointer back where it was.
import os, re, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, app_log, keep_pointer, log, mouse, running

REQUEST = re.compile(r'TEST pointer (move|click) (\S+) (\d+)x(\d+) ((?:-?[\d.]+ ?)+)')

keep_pointer()
handled = set()
while running():
    text = app_log()
    for kind, name, width, height, numbers in REQUEST.findall(text):
        if name in handled:
            continue
        handled.add(name)
        values = [float(n) for n in numbers.split()]
        ok, window = mouse('window', PID, width, height)
        if not ok:
            log(f'pointer {name} refused: no {width}x{height} window of the instance ({window})')
            continue
        x, y = (int(v) for v in window.split()[:2])
        if kind == 'move':
            x0, y0, x1, y1, ms = values[:5]
            ok, out = mouse('move', PID, round(x + x0), round(y + y0), round(x + x1), round(y + y1), round(ms))
        else:
            ok, out = mouse('click', PID, round(x + values[0]), round(y + values[1]))
        log(f"pointer {name} {('moved' if kind == 'move' else 'clicked') if ok else f'refused: {out}'}")
    if 'TEST done' in text:
        break
    time.sleep(0.05)
