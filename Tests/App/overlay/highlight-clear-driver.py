# Driver for highlight-clear.test.js: when the page logs "TEST shot <name> <x> <y> <width> <height>" (the line's rect in
# page points), captures the test instance's overlay window (its largest window, by window only) and compares that rect
# with the "before" shot's: a word's highlight shows in its "-end" shot, and nothing of it is left in its "-closed" one.
# Writes $RUN/<name>.done when it's done with a shot.
import os, subprocess, sys, time
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import RUN, PID, check, log, tool
from PIL import Image

winnum = tool('winnum')


def capture(name, rect):
    number = (subprocess.run([winnum, PID], capture_output=True, text=True).stdout.split() or [None])[0]
    path = f'{RUN}/{name}.png'
    if number:
        subprocess.run(['screencapture', '-x', '-o', '-l', number, path])
    if not os.path.exists(path):
        return None
    image = Image.open(path).convert('RGB')
    scale = image.size[0] / float(subprocess.run([winnum, PID], capture_output=True, text=True).stdout.split()[1])
    x, y, w, h = (round(v * scale) for v in rect)
    return image.crop((x, y, x + w, y + h))


def changed(a, b):
    """Pixels that differ clearly between two crops of the same size."""
    return sum(1 for p, q in zip(a.getdata(), b.getdata()) if max(abs(p[i] - q[i]) for i in range(3)) > 24)


before = None
done = set()
end = time.monotonic() + 140
while time.monotonic() < end:
    try:
        lines = open(f'{RUN}/app.log', encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        lines = []
    if any('TEST done' in line for line in lines):
        break
    for line in lines:
        if 'TEST shot ' not in line:
            continue
        name, *rect = line.split('TEST shot ', 1)[1].split()
        if name in done:
            continue
        done.add(name)
        crop = capture(name, [float(v) for v in rect])
        if crop is None:
            check(False, f'a screenshot for {name}')
        elif name == 'before':
            before = crop
        elif before is not None:
            count = changed(before, crop)
            if name.endswith('-end'):
                check(count > 50, f'{name}: the highlight shows ({count} pixels changed from before)')
            else:
                check(count < 20, f'{name}: nothing of the highlight left ({count} pixels changed from before)')
        open(f'{RUN}/{name}.done', 'w').write('done')
    time.sleep(0.1)
