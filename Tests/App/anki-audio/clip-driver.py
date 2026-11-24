# clip-driver.py <reference>...: the driver of the Anki Audio tests, checking the cards' sound and pictures once the page
# is done. The page says what to expect with its log lines:
# - "TEST clip <k> <name>": the k-th sentence audio clip stored through AnkiConnect (storeMediaFile of a
#   macpopup-sentence-*.m4a, in mock.log, counted from 1) holds <name>.aiff (in $RUN, from voices.sh) whole, best of the
#   references given (names, e.g. voice0 voice1 voice2 voice3): its correlation (corr.swift) at least 0.3 and twice the
#   next one's. (Offline, Kyoko's lines under voicegame's music through AAC gave 0.60-0.68 for the line, under 0.1 for
#   the others.)
# - "TEST screenshot <name>": the last card screenshot stored (yomitan_screenshot_*) shows <name>.txt's text (Vision,
#   readtext.swift), more like it than any other reference's.
# The clips and pictures are saved in $RUN (clip-<k>.m4a, screenshot.*).
import base64, difflib, json, os, re, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import REPO, RUN, check, log, running


def stopped(kind, value, trace):
    """An error (e.g. a tool that didn't build) fails the test, as an unchecked clip would otherwise pass it."""
    sys.__excepthook__(kind, value, trace)
    print(f'TEST FAIL the clip check stopped: {value!r}', flush=True)


sys.excepthook = stopped
references = sys.argv[1:]


def app_log():
    try:
        with open(f'{RUN}/app.log', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


while running() and 'TEST done' not in app_log():
    time.sleep(0.5)
text = app_log()
expected_clips = re.findall(r'TEST clip (\d+) (\S+)', text)
expected_shots = re.findall(r'TEST screenshot (\S+)', text)

clips, shots = [], []
try:
    with open(f'{RUN}/mock.log', errors='replace') as f:
        for line in f:
            parts = line.split(' ', 3)
            if len(parts) == 4 and parts[0] == 'anki' and parts[2] == 'storeMediaFile':
                try:
                    params = json.loads(parts[3])
                except ValueError:
                    continue  # (a line still being written)
                name = params.get('filename', '')
                if name.startswith('macpopup-sentence-'):
                    clips.append(params.get('data', ''))
                elif 'screenshot' in name:
                    shots.append((name, params.get('data', '')))
except OSError:
    pass
log(f'clips stored: {len(clips)}, screenshots stored: {len(shots)}')


def build(name):
    return subprocess.run([f'{os.environ["HARNESS"]}/tools/build.sh', f'{REPO}/Tests/App/anki-audio/{name}.swift'],
                          capture_output=True, text=True, check=True).stdout.strip()


for k, name in expected_clips:
    k = int(k)
    if k > len(clips) or not clips[k - 1]:
        check(False, f'clip {k} ({name}): not stored')
        continue
    path = f'{RUN}/clip-{k}.m4a'
    with open(path, 'wb') as f:
        f.write(base64.b64decode(clips[k - 1]))
    out = subprocess.run([build('corr'), path] + [f'{RUN}/{r}.aiff' for r in references], capture_output=True, text=True).stdout
    log(out.strip())
    rows = {}
    for row in out.splitlines():
        fields = row.split()
        if len(fields) == 7:
            rows[fields[0].removesuffix('.aiff')] = (float(fields[1]), fields[6], fields[3], fields[4], fields[5])
    if name not in rows:
        check(False, f'clip {k} ({name}): corr gave no result')
        continue
    score, whole, start, end, length = rows[name]
    others = max((s for r, (s, *_) in rows.items() if r != name), default=0)
    best = max(rows, key=lambda r: rows[r][0])
    check(best == name and score >= 0.3 and score >= 2 * others,
          f'clip {k} holds {name}: correlation {score:.2f} (best: {best}, next {others:.2f})')
    check(whole == 'whole', f'clip {k} holds {name} whole: its speech at {start}-{end} s of {length} s ({whole})')

for name in expected_shots:
    if not shots:
        check(False, f'the screenshot ({name}): none stored')
        continue
    filename, data = shots[-1]
    path = f'{RUN}/screenshot{os.path.splitext(filename)[1]}'
    with open(path, 'wb') as f:
        f.write(base64.b64decode(data))
    read = subprocess.run([build('readtext'), path], capture_output=True, text=True).stdout.replace('\n', '')
    log(f'the screenshot reads: {read}')
    similar = {}
    for r in references:
        try:
            with open(f'{RUN}/{r}.txt') as f:
                similar[r] = difflib.SequenceMatcher(None, f.read().strip(), read).ratio()
        except OSError:
            pass
    best = max(similar, key=similar.get, default=None)
    check(best == name and similar[name] >= 0.6,
          f'the screenshot shows {name}: {similar.get(name, 0):.2f} alike (best: {best}, {json.dumps({r: round(s, 2) for r, s in similar.items()})})')
