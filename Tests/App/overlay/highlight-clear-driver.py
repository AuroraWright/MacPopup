# Driver for highlight-clear.test.js: when the page logs "TEST shot <name> <x> <y> <width> <height>" (a rect in page
# points: the word's highlight boxes), captures the test instance's overlay window (its largest window, by window only)
# and compares that rect with the same one in the "before" shot (taken with nothing highlighted): a word's highlight
# shows in its "-end" shot, and nothing of it is left in its "-closed" one. Writes $RUN/<name>.done when it's done
# with a shot. Every shot logged before the page's "TEST done" is handled, and all six comparisons must have been made.
import os, subprocess, sys, time
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import RUN, PID, check, tool
from PIL import Image

winnum = tool('winnum')
COMPARISONS = 6


def capture(name):
    """The overlay window's screenshot and its pixels per point, or None."""
    windows = subprocess.run([winnum, PID], capture_output=True, text=True).stdout.split()
    path = f'{RUN}/{name}.png'
    if windows:
        subprocess.run(['screencapture', '-x', '-o', '-l', windows[0], path])
    if not os.path.exists(path):
        return None
    image = Image.open(path).convert('RGB')
    return image, image.size[0] / float(windows[1])


def crop(shot, rect):
    image, scale = shot
    x, y, w, h = (round(v * scale) for v in rect)
    return image.crop((x, y, x + w, y + h))


def pixels(image):
    return image.get_flattened_data() if hasattr(image, 'get_flattened_data') else image.getdata()


def changed(a, b):
    """Pixels that differ clearly between two crops of the same size."""
    return sum(1 for p, q in zip(pixels(a), pixels(b)) if max(abs(p[i] - q[i]) for i in range(3)) > 24)


before = None
handled = set()
compared = 0
end = time.monotonic() + 140
while time.monotonic() < end:
    try:
        lines = open(f'{RUN}/app.log', encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        lines = []
    finished = any('TEST done' in line for line in lines)
    for line in lines:
        if 'TEST shot ' not in line:
            continue
        name, *rect = line.split('TEST shot ', 1)[1].split()
        if name in handled:
            continue
        handled.add(name)
        shot = capture(name)
        if shot is None:
            check(False, f'a screenshot for {name}')
        elif name == 'before':
            before = shot
        elif before is not None:
            rect = [float(v) for v in rect]
            count = changed(crop(before, rect), crop(shot, rect))
            compared += 1
            if name.endswith('-end'):
                check(count > 50, f'{name}: the highlight shows ({count} pixels changed from before)')
            else:
                check(count < 20, f'{name}: nothing of the highlight left ({count} pixels changed from before)')
        open(f'{RUN}/{name}.done', 'w').write('done')
    if finished:
        break
    time.sleep(0.1)
check(compared == COMPARISONS, f'screenshots compared: {compared} (expected {COMPARISONS})')
