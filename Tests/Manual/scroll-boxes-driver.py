# scroll-boxes-driver.py [what], for scroll-boxes.test.js and popup-scroll.test.js: asks the person at the Mac to scroll
# `what` (the text box by default), and records the test instance's overlay window alone (tools/rec-window.swift) for
# 15 s from the first scroll into $RUN/scroll.mov.
import os, subprocess, sys
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
sys.path.insert(0, os.path.join(os.environ['REPO'], 'Tests/Manual'))
from driver import PID, RUN, check, logged
from manual import built, done, here, prompt

WHAT = sys.argv[1] if len(sys.argv) > 1 else 'the text box near the bottom of the screen'

try:
    if check(bool(logged('box', timeout=60)), 'the page is ready'):
        prompt(f'Put the pointer over {WHAT} and scroll it up and down with two fingers, for about 15 s.')
        if check(bool(logged('scrolling', timeout=240)), f'someone scrolled {WHAT}'):
            movie = os.path.join(RUN, 'scroll.mov')
            result = subprocess.run([built(here('tools/rec-window.swift')), PID, '15', movie], capture_output=True, text=True)
            saved = result.returncode == 0 and os.path.exists(movie) and os.path.getsize(movie) > 0
            check(saved, f'the recording: {movie} ({result.stdout.strip()[-200:]})')
            prompt('Recorded: you can stop scrolling. Check scroll.mov in the run folder frame by frame.')
finally:
    done()
