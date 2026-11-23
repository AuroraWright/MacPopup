# iina-transcribe.py <case>: the driver of iina/transcribe-<case>.test.js ("Transcribe videos without subtitles",
# VideoTranscriber.swift). Plays the speech video (iina.py setup speech: six sentences said by Kyoko, 3 s apart, no
# subtitles) in the user's IINA (file: the local file; http, hls: over serve.py; dash: DASH fragments as an EDL with the
# audio added, as IINA's yt-dlp plugin plays YouTube; seek: the local file from just before the 4th sentence, back to
# the start once the 5th is over), watches mpv over its IPC socket (position, subtitle shown, subtitle tracks, every
# 100 ms) and the transcript file (the test instance's, in iina.TRANSCRIPTS), and checks:
# the transcript is loaded as a selected subtitle track "MacPopup transcription" soon after playback starts; each
# sentence is in it (Live Caption; most of its characters), starting near when it's said; no cue twice; IINA shows the
# cues as they're played. From scratch-tools/iina/subreload/run-e2e.sh, observe.py and net-run.sh (2026-11-21, Live
# Caption on a recording of speech: local file "track loaded 2.9 s after playback started, 10 lines at the times the
# app's replay gives"; seek "first line 2.5 s after the start, then 0–38 s filled in, no line twice"; HTTP 10 lines,
# HLS 11, DASH 11).
import glob, json, os, re, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iina
from driver import check, equal, log

RUN, WEB = iina.RUN, iina.WEB
TRANSCRIPTS = iina.TRANSCRIPTS
TITLE = 'MacPopup transcription'


def cues(path):
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
            start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
            end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
            body = block[m.end():].strip()
            out.append((round(start, 3), round(end, 3), body))
    return out


def transcript_files():
    return glob.glob(os.path.join(TRANSCRIPTS, '*', TITLE))


def main():
    case = sys.argv[1]
    with open(os.path.join(RUN, 'media/sentences.json')) as f:
        sentences = json.load(f)
    local = os.path.join(RUN, 'media/local/speech.mkv')
    options, audio, seeks = [], None, []
    if case == 'file':
        media = local
    elif case == 'http':
        media = f'{WEB}/speech.mkv'
    elif case == 'hls':
        media = f'{WEB}/hls2/index.m3u8'
    elif case == 'dash':
        with open(os.path.join(RUN, 'media/web/dash-video.edl')) as f:
            media = f.read().strip()
        with open(os.path.join(RUN, 'media/web/dash-audio.edl')) as f:
            audio = f.read().strip()
    elif case == 'seek':
        media = local
        options = [f'--mpv-start={sentences[3]["start"] - 1.0:.2f}']
        seeks = [(sentences[4]['end'] + 1.0, 0.0)]
    else:
        raise SystemExit(f'no case {case}')
    if not check(iina.app_logged(r'TEST overlay loaded', 40), 'the overlay loaded'):
        return
    time.sleep(3)
    player = iina.IINA()
    iina.on_stop(player.stop)
    try:
        player.start(media, *options)
        if not check(player.listening(40), "the plugin's WebSocket server listens (IINA started)"):
            return
        mpv = player.mpv()
        if audio:
            player.add(mpv, audio, None)
        end = time.monotonic() + 30
        while mpv.get('time-pos') is None and time.monotonic() < end:
            time.sleep(0.05)
        started = time.monotonic()
        total = (mpv.get('duration') or 45) + 15
        samples, appeared = [], {}
        while True:
            now = time.monotonic() - started
            try:
                pos = mpv.get('time-pos')
                if pos is None or mpv.get('eof-reached') or now > total + 40:
                    break
                if seeks and pos >= seeks[0][0]:
                    mpv.send('seek', seeks.pop(0)[1], 'absolute+exact')
                    total += 45
                    continue
                text = mpv.get('sub-text') or ''
                tracks = mpv.get('track-list') or []
            except (OSError, EOFError) as error:
                log(f'mpv went away: {error!r}')
                break
            subs = [{'id': t['id'], 'title': t.get('title'), 'selected': t.get('selected'), 'file': t.get('external-filename')}
                    for t in tracks if t['type'] == 'sub']
            samples.append({'t': round(now, 2), 'pos': round(pos, 2), 'text': text, 'subs': subs})
            for path in transcript_files():
                for cue in cues(path):
                    appeared.setdefault(cue, round(now, 2))
            time.sleep(0.1)
        time.sleep(3)
        with open(os.path.join(RUN, 'samples.jsonl'), 'w') as f:
            for s in samples:
                f.write(json.dumps(s, ensure_ascii=False) + '\n')
        files = transcript_files()
        check(len(files) == 1, f'one transcript: {[os.path.relpath(p, RUN) for p in files]}')
        final = cues(files[0]) if files else []
        for cue in final:
            log(f'cue {cue[0]:6.2f}–{cue[1]:6.2f} (in the file after {appeared.get(cue, "-")} s) {cue[2]}')

        loaded = next((s for s in samples if any(t['title'] == TITLE and t['selected'] and (t['file'] or '').startswith(TRANSCRIPTS)
                                                 for t in s['subs'])), None)
        limit = 10 if case in ('file', 'seek') else 20
        check(loaded is not None and loaded['t'] <= limit,
              f'the transcript loaded as the selected subtitle track "{TITLE}" after {loaded["t"] if loaded else "-"} s of playback '
              f'(expected within {limit} s; 2.9 s on 2026-11-21)')

        found = []
        for n, sentence in enumerate(sentences):
            near = [c for c in final if c[1] > sentence['start'] - 1.0 and c[0] < sentence['end'] + 1.0]
            text = ''.join(c[2] for c in near)
            score = iina.similarity(sentence['text'], text)
            begins = near[0][0] - sentence['start'] if near else None
            ok = score >= 0.6 and begins is not None and -1.0 <= begins <= 1.5
            found.append(ok)
            log(f'sentence {n} at {sentence["start"]} s: {score:.2f} of {sentence["text"]} in {text!r}, '
                f'starting {begins if begins is None else round(begins, 2)} s from it')
        check(sum(found) >= 5, f'sentences in the transcript, starting within -1 to +1.5 s of when they are said: {sum(found)} of '
                               f'{len(sentences)} ({found})')
        texts = [iina.plain(c[2]) for c in final]
        check(len(texts) == len(set(texts)) and all(a[1] <= b[0] + 0.01 for a, b in zip(final, final[1:])),
              'no cue twice, cues in order without overlapping')
        shown = 0
        for cue in final:
            if any(iina.plain(cue[2]) and iina.plain(cue[2]) in iina.plain(s['text']) and cue[0] - 0.3 <= s['pos'] <= cue[1] + 0.3
                   for s in samples):
                shown += 1
        check(shown >= len(final) - 1 and shown >= 4, f'cues IINA showed while they played: {shown} of {len(final)}')

        if case == 'seek':
            order = sorted((t, c) for c, t in appeared.items())
            first = order[0][1] if order else None
            fourth = sentences[3]
            check(first is not None and first[0] >= fourth['start'] - 1.0 and first[0] < fourth['end'] + 1.0 and order[0][0] <= 8,
                  f'the first cue transcribed is the 4th sentence, where playback started: {first} after {order[0][0] if order else "-"} s')
            check(all(found[:3]), f'the sentences before the start filled in by the end: {found[:3]}')
        mpv.sock.close()
    finally:
        check(player.stop(), 'IINA quit')
        iina.check_user_iina(check)


main()
