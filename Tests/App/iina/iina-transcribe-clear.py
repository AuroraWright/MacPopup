# iina-transcribe-clear.py: the driver of iina/transcribe-clear.test.js (Settings → IINA Integration → Saved
# transcriptions → Clear while IINA's video is transcribed; VideoTranscriber.clearTranscripts).
#   setup    (// setup:) iina.py's setup speech, then media/long/speech-long.mkv: its speech video looped LOOPS times
#            (stream copy), alone in its folder, so that Live Caption is still transcribing it ahead when Clear is pressed
#   (none)   the driver: opens Settings on IINA Integration, plays the long video in the user's IINA (muted), and once
#            the transcript is loaded and playback is CLEAR_AT s in, presses Clear… then Clear over Accessibility, with
#            mpv (position, subtitle shown, subtitle tracks; every 100 ms) and the transcripts folder (every 20 ms:
#            whether it's there, each version of lines.json) watched; then plays on for AFTER s and checks what the test
#            file's comment says. Prints the transcript before and after, the folder's changes and the log around the
#            clear. From evals/iina/clear/during.sh.
import glob, json, os, re, subprocess, sys, threading, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iina
from driver import PID, ax, check, controls, equal, log, open_settings, running, tool, until

RUN, TRANSCRIPTS = iina.RUN, iina.TRANSCRIPTS
TITLE = 'MacPopup transcription'
SETTINGS = 'MacPopup Settings'
QUESTION = 'Clear saved transcriptions?'
USER = os.path.expanduser('~/Library/Caches/com.aury.macpopup/Transcripts')
LOOPS = 30
CLEAR_AT = 20.0
AFTER = 22.0
# The new transcription starts 2 s before the position the plugin last told (each second), so its lines start at
# most about 3 s before the position read just before Clear: 1 s more for slack.
EARLIEST = 4.0


def setup():
    iina.setup('speech')
    media = os.path.join(RUN, 'media')
    os.makedirs(os.path.join(media, 'long'))
    one = os.path.join(media, 'local/speech.mkv')
    listing = os.path.join(media, 'long.txt')
    with open(listing, 'w') as f:
        f.write(f"file '{one}'\n" * LOOPS)
    long = os.path.join(media, 'long/speech-long.mkv')
    iina.ffmpeg('-f', 'concat', '-safe', '0', '-i', listing, '-c', 'copy', long)
    log(f'{long}: {iina.duration(long):.1f} s ({LOOPS} x {iina.duration(one):.2f} s)')


# --- What's watched


def user_listing():
    """The user's transcripts: each file's size and modification time, or None when the folder isn't there."""
    if not os.path.isdir(USER):
        return None
    out = {}
    for folder, _, names in os.walk(USER):
        for name in names:
            path = os.path.join(folder, name)
            st = os.stat(path)
            out[os.path.relpath(path, USER)] = [st.st_size, st.st_mtime_ns]
    return out


class Folder(threading.Thread):
    """Watches TRANSCRIPTS every 20 ms: .events (time, whether it's there, its folders) when that changes, and
    .versions (time, path, its JSON) for each new lines.json."""

    def __init__(self, started):
        super().__init__(daemon=True)
        self.started = started
        self.events, self.versions = [], []
        self.stopping = False

    def run(self):
        last, seen = None, {}
        while not self.stopping:
            now = round(time.monotonic() - self.started, 3)
            try:
                folders = sorted(os.listdir(TRANSCRIPTS)) if os.path.isdir(TRANSCRIPTS) else None
            except OSError:
                folders = None
            state = (folders is not None, tuple(folders or ()))
            if state != last:
                self.events.append((now, state[0], list(state[1])))
                last = state
            for path in glob.glob(os.path.join(TRANSCRIPTS, '*', 'lines.json')):
                try:
                    st = os.stat(path)
                    stamp = (st.st_ino, st.st_size, st.st_mtime_ns)
                    if seen.get(path) == stamp:
                        continue
                    with open(path) as f:
                        data = json.load(f)
                    seen[path] = stamp
                    self.versions.append((now, path, data))
                except (OSError, ValueError):
                    pass
            time.sleep(0.02)


class Samples(threading.Thread):
    """mpv every 100 ms: .samples ({t, pos, text, subs})."""

    def __init__(self, mpv, started):
        super().__init__(daemon=True)
        self.mpv, self.started = mpv, started
        self.samples = []
        self.stopping = False

    def run(self):
        while not self.stopping:
            try:
                pos = self.mpv.get('time-pos')
                text = self.mpv.get('sub-text') or ''
                tracks = self.mpv.get('track-list') or []
            except (OSError, EOFError, ValueError) as error:
                log(f'mpv went away: {error!r}')
                return
            if pos is not None:
                subs = [{'id': t['id'], 'title': t.get('title'), 'selected': t.get('selected'), 'file': t.get('external-filename')}
                        for t in tracks if t['type'] == 'sub']
                self.samples.append({'t': round(time.monotonic() - self.started, 2), 'pos': round(pos, 2), 'text': text, 'subs': subs})
            time.sleep(0.1)

    def last(self):
        return self.samples[-1] if self.samples else None


def ours(sample):
    return [s for s in sample['subs'] if s['title'] == TITLE]


def loaded(sample):
    """The transcript's track, selected, from the transcripts folder: its file, or None."""
    track = next((s for s in ours(sample) if s['selected'] and (s['file'] or '').startswith(TRANSCRIPTS + '/')), None)
    return track['file'] if track else None


# --- Settings


def row():
    """The Saved transcriptions row's text ("2 videos, 360 KB", "None") and whether Clear… is enabled."""
    found, text, enabled = False, None, None
    for c in controls(SETTINGS):
        if c['role'] == 'AXStaticText' and c['value'] == 'Saved transcriptions':
            found = True
        elif found and text is None and c['role'] == 'AXStaticText' and re.match(r'^(None|\d+ videos?, .+)$', c['value']):
            text = c['value']
        elif found and c['role'] == 'AXButton' and 'Clear…' in (c['title'], c['description']):
            enabled = c['enabled'] == '1'
            break
    return text, enabled


def sheet():
    return any(c['role'] == 'AXStaticText' and c['value'] == QUESTION for c in controls(SETTINGS))


def app_log():
    try:
        with open(os.path.join(RUN, 'app.log'), errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def spoken(log_text):
    """How many stretches the app logged transcribing ("… s of speech in … ms with Live Caption: …")."""
    return len(re.findall(r'^\[transcription\] [\d.]+ s of speech in .* with ', log_text, re.M))


def summary(data):
    lines = data.get('lines', [])
    return f'{len(lines)} lines, first starts {[round(l[0], 1) for l in lines[:5]]}, covered {[[round(a, 1), round(b, 1)] for a, b in data.get("covered", [])]}'


def main():
    with open(os.path.join(RUN, 'media/sentences.json')) as f:
        cycle_sentences = json.load(f)
    one = iina.duration(os.path.join(RUN, 'media/local/speech.mkv'))
    video = os.path.join(RUN, 'media/long/speech-long.mkv')
    total = iina.duration(video)
    sentences = [dict(s, start=s['start'] + n * one, end=s['end'] + n * one) for n in range(LOOPS) for s in cycle_sentences]
    user_before = user_listing()
    subprocess.run(['defaults', 'write', os.environ['SUITE'], 'settingsSection', '-string', 'IINA Integration'])
    if not check(iina.app_logged(r'TEST overlay loaded', 40), 'the overlay loaded'):
        return
    if not open_settings('IINA Integration', 'Saved transcriptions'):
        return
    player = iina.IINA()
    iina.on_stop(player.stop)
    watcher = sampler = None
    try:
        player.start(video)
        if not check(player.listening(40), "the plugin's WebSocket server listens (IINA started)"):
            return
        mpv = player.mpv()
        end = time.monotonic() + 30
        while mpv.get('time-pos') is None and time.monotonic() < end:
            time.sleep(0.05)
        started = time.monotonic()
        watcher, sampler = Folder(started), Samples(mpv, started)
        watcher.start()
        sampler.start()

        # Until the transcript is IINA's track and playback is CLEAR_AT s in.
        ready = until(lambda: (lambda s: s if s and loaded(s) and s['pos'] >= CLEAR_AT else None)(sampler.last()),
                      timeout=CLEAR_AT + 30, interval=0.1)
        if not check(bool(ready), f'the transcript loaded as the selected track "{TITLE}" and playback {CLEAR_AT} s in: '
                                  f'{sampler.last()}'):
            return
        track_file = loaded(ready)
        key_folder = os.path.dirname(track_file)
        before = watcher.versions[-1][2] if watcher.versions else {}
        log(f'before the clear: {os.listdir(TRANSCRIPTS)}; {key_folder}: {sorted(os.listdir(key_folder))}; {summary(before)}')
        text, enabled = row()
        log(f'the row before: {text!r}, Clear… enabled: {enabled}')

        # Clear… (its press returns once its sheet is closed), then Clear.
        press = subprocess.Popen([tool('ax'), PID, 'press', 'AXButton', 'Clear…', '1'], stdout=subprocess.PIPE, text=True)
        if not check(bool(until(sheet, timeout=10, interval=0.3)), f'Clear… asks first ("{QUESTION}")'):
            press.kill()
            return
        text_before = app_log()
        stretches = spoken(text_before)
        last = before.get('covered', [[0, 0]])[-1][1] if before.get('covered') else 0
        position = mpv.get('time-pos')
        check(stretches < len(sentences) and last < total - 1,
              f'still transcribing when Clear is pressed: {stretches} stretches transcribed of the {len(sentences)} sentences, '
              f'the transcript done to {last:.1f} s of {total:.1f} s, playback at {position:.2f} s')
        earlier = [l for l in before.get('lines', []) if l[0] < position - EARLIEST]
        check(len(earlier) >= 2, f'the transcript before the clear has lines from before {position - EARLIEST:.1f} s: {len(earlier)}')
        cleared = round(time.monotonic() - started, 3)
        ax('press', 'AXButton', 'Clear', 1)
        log(f'Clear pressed at {cleared} s, playback at {position:.2f} s')
        check(bool(until(lambda: not sheet(), timeout=10, interval=0.3)), 'the sheet went after Clear')
        closed = round(time.monotonic() - started, 3)
        try:
            log(f'Clear…: {press.communicate(timeout=15)[0].strip()}')
        except subprocess.TimeoutExpired:
            press.kill()

        until(lambda: (lambda s: s and (s['pos'] >= position + AFTER or s['pos'] >= total - 2))(sampler.last()),
              timeout=AFTER + 20, interval=0.2)
        time.sleep(2.5)  # (a save is at most 2 s after a line)
        watcher.stopping = sampler.stopping = True
        watcher.join(2)
        sampler.join(2)
        samples = sampler.samples
        with open(os.path.join(RUN, 'samples.jsonl'), 'w') as f:
            for s in samples:
                f.write(json.dumps(s, ensure_ascii=False) + '\n')
        with open(os.path.join(RUN, 'folder.json'), 'w') as f:
            json.dump({'events': watcher.events, 'versions': [(t, p, summary(d)) for t, p, d in watcher.versions]}, f,
                      ensure_ascii=False, indent=1)
        for t, there, folders in watcher.events:
            log(f'folder at {t:7.3f} s: {"there" if there else "GONE"} {[f[:8] for f in folders]}')
        # The folder removed, then made again by the new transcript.
        gone = [t for t, there, _ in watcher.events if t >= cleared - 0.5 and not there]
        back = [t for t, there, _ in watcher.events if gone and t > gone[0] and there]
        # (The versions saved once it's removed, or else once the sheet went: the old job may save meanwhile.)
        after = [(t, p, d) for t, p, d in watcher.versions if t > (gone[0] if gone else closed)]
        for t, p, d in after[:4]:
            log(f'  lines.json at {t} s: {summary(d)}')
        check(bool(gone), f'the transcripts folder removed after Clear (gone at {gone[:1]} s, Clear pressed at {cleared} s, '
                          f'made again at {back[:1]} s)')
        check(watcher.events[-1][1] and watcher.events[-1][2] == [os.path.basename(key_folder)],
              f"made again with the video's transcript folder only: {[f[:8] for f in watcher.events[-1][2]]}")

        # Nothing from before written back; the transcription started over from where the video is played.
        bound = position - EARLIEST
        old = [(t, l) for t, _, d in after for l in d.get('lines', []) if l[0] < bound]
        old_covered = [(t, c) for t, _, d in after for c in d.get('covered', []) if c[0] < bound]
        check(after and not old and not old_covered,
              f'no line or part done from before {bound:.1f} s written after the clear: {len(after)} versions of lines.json, '
              f'{old[:3]}, {old_covered[:3]}')
        final = after[-1][2] if after else {}
        log(f'after: {summary(final)}')
        first = next((t for t, _, d in after if d.get('lines')), None)
        check(first is not None and first - cleared <= 10,
              f'the new transcript has lines {round(first - cleared, 2) if first else "-"} s after the clear (expected within 10 s)')
        covered = final.get('covered', [])
        check(bool(covered) and bound <= covered[0][0] <= position,
              f'the new transcript starts at {covered[0][0] if covered else "-"} s, from where the video was played '
              f'({position:.2f} s, 2 s before it)')
        later = app_log()[len(text_before):]
        again = re.findall(r"^\[transcription\] transcribing IINA's video ahead: (.*)$", later, re.M)
        equal(again, [video], "transcribing IINA's video ahead again after the clear (the log)")
        problems = re.findall(r"^\[transcription\] (couldn't .*|IINA didn't .*|the model couldn't .*|stopped transcribing .*)$",
                              app_log(), re.M)
        equal(problems, [], 'no transcription errors or stops in the log')

        srt = os.path.join(key_folder, TITLE)
        cues = read_cues(srt)
        check(bool(cues) and all(c[0] >= bound for c in cues),
              f'the subtitle file has only cues from {bound:.1f} s on: {len(cues)} cues, first {cues[0] if cues else None}')
        played = samples[-1]['pos'] if samples else 0
        said = [s for s in sentences if s['start'] >= position + 0.5 and s['end'] + 1.5 <= played]
        found = []
        for s in said:
            near = [c for c in cues if c[1] > s['start'] - 1.0 and c[0] < s['end'] + 1.0]
            score = iina.similarity(s['text'], ''.join(c[2] for c in near))
            begins = near[0][0] - s['start'] if near else None
            found.append(score >= 0.6 and begins is not None and -1.0 <= begins <= 1.5)
            log(f'sentence at {s["start"]:.2f} s: {score:.2f} of {s["text"]}, starting {begins if begins is None else round(begins, 2)} s from it')
        check(len(said) >= 2 and sum(found) >= len(said) - 1,
              f'the sentences said after the clear in the new transcript: {sum(found)} of {len(said)} ({found})')

        # IINA's track: one, selected, of the same file, all along; it shows the new cues.
        since = [s for s in samples if s['t'] >= cleared]
        odd = [(s['t'], ours(s)) for s in since if len(ours(s)) != 1 or loaded(s) != track_file]
        check(bool(since) and not odd, f'one "{TITLE}" track, selected, of {track_file[len(TRANSCRIPTS) + 1:][:12]}…, all '
                                       f'along after the clear: {len(since)} samples, {odd[:3]}')
        if since:
            log(f"IINA's subtitle tracks at the end: {since[-1]['subs']}")
        shown_cues = [c for c in cues if c[0] >= position + 2 and c[1] <= played]
        shown = sum(1 for c in shown_cues
                    if any(iina.plain(c[2]) and iina.plain(c[2]) in iina.plain(s['text']) and c[0] - 0.3 <= s['pos'] <= c[1] + 0.3
                           for s in since))
        check(len(shown_cues) >= 2 and shown >= len(shown_cues) - 1,
              f'cues of the new transcript IINA showed while they played: {shown} of {len(shown_cues)}')

        # Settings and the app.
        row_after = until(lambda: (lambda r: r if r[0] and r[0].startswith('1 video,') else None)(row()), timeout=10) or row()
        check(bool(row_after[0] and re.match(r'^1 video, ', row_after[0])) and row_after[1] is True,
              f'the row counts the new transcript: {row_after}')
        alert = [c['value'] for c in controls() if c['role'] == 'AXStaticText' and 'Couldn’t' in c['value']]
        equal(alert, [], 'no alert')
        check(running(), 'the app still runs')
        for line in [l for l in app_log().splitlines() if l.startswith('[transcription] transcribing') or 'stopped' in l][:10]:
            log(f'  {line[:160]}')
        mpv.sock.close()
    finally:
        if watcher:
            watcher.stopping = True
        if sampler:
            sampler.stopping = True
        check(player.stop(), 'IINA quit')
        iina.check_user_iina(check)
        user_after = user_listing()
        check(user_after == user_before, "the user's transcripts (~/Library/Caches/com.aury.macpopup/Transcripts) unchanged: "
                                         f'{len(user_before or {})} files'
                                         + ('' if user_after == user_before else f' (NOW {len(user_after or {})}: {user_after})'))


def read_cues(path):
    """A SubRip file's cues: (start, end, text)."""
    try:
        with open(path, errors='replace') as f:
            text = f.read()
    except OSError:
        return []
    out = []
    stamp = r'(\d+):(\d+):(\d+)[,.](\d+)'
    for block in re.split(r'\n\s*\n', text.replace('\r\n', '\n')):
        m = re.search(stamp + r'\s*-->\s*' + stamp, block)
        if m:
            g = [int(x) for x in m.groups()]
            out.append((round(g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000, 3),
                        round(g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000, 3), block[m.end():].strip()))
    return out


if __name__ == '__main__':
    if sys.argv[1:] == ['setup']:
        try:
            setup()
        except (RuntimeError, OSError) as error:
            log(f'setup failed: {error}')
            sys.exit(1)
    else:
        main()
