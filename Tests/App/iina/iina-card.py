# iina-card.py <case>: the driver of iina/card-<case>.test.js. Plays the test video (iina.py setup test) in the user's
# IINA as <case> says (a local file, HTTP, HLS, split video and audio, DASH fragments, a live stream, through a proxy,
# behind a cookie), while the page adds a card from line 2 (6–8.5 s, the 880 Hz tone 6–8.5 s). Checks where the plugin
# says the line's video and audio are read from, then the card's media in mock.log: the sentence audio is 5.5–9 s
# (iinaSentenceAudioPadding 500), silent, then the tone from 0.5 to 3.0 s, then silent; the screenshot is the frame from
# the line's middle (7.25 s), told by the brightness band at the top of the picture.
# From evals/iina/e2e-run.sh (local file) and streams/e2e.sh (the streams; 2026-11-10: "audio exact, frame
# within ±1" for local, HTTP, VOD HLS, split audio-add, live HLS, DASH EDL split, proxy and cookie gates).
import base64, json, os, re, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iina
from driver import check, log, until

RUN, WEB = iina.RUN, iina.WEB
WEBDIR = os.path.join(RUN, 'media/web')
LOCAL = os.path.join(RUN, 'media/local/test.mkv')
SUBS = f'{WEB}/subs.srt'


def edl(kind):
    with open(os.path.join(WEBDIR, f'dash-{kind}.edl')) as f:
        return f.read().strip()


# case: (what IINA plays, iina-cli options, an audio track to add, a subtitle file to add, where the plugin says line
# 2's video and audio are: kinds of source)
CASES = {
    'file': lambda: (LOCAL, ['--mpv-sid=1'], None, None, ('file', 'file')),
    'http': lambda: (f'{WEB}/test.mkv', ['--mpv-sid=1'], None, None, ('url', 'url')),
    'hls': lambda: (f'{WEB}/hls2/index.m3u8', [], None, SUBS, ('url', 'url')),
    'split': lambda: (f'{WEB}/video-only.mp4', [], f'{WEB}/audio-only.m4a', SUBS, ('url', 'url')),
    'dash': lambda: (edl('video'), [], edl('audio'), SUBS, ('fragments', 'fragments')),
    'live': lambda: (f'{WEB}/live/hls2.m3u8', [], None, SUBS, ('cache', 'cache')),
    'proxy': lambda: (f'{WEB}/gate-proxy/test.mkv', ['--mpv-sid=1', '--mpv-http-proxy=http://127.0.0.1:59886'], None, None, ('url', 'url')),
    'cookie': lambda: (f'{WEB}/gate-cookie/test.mkv', ['--mpv-sid=1', '--mpv-cookies=yes', f'--mpv-cookies-file={RUN}/cookies.txt'],
                       None, None, ('url', 'url')),
}


def kind(source):
    return next((k for k in ('file', 'url', 'fragments', 'cache') if isinstance(source, dict) and k in source), repr(source))


def mean_volume(path, start, length):
    out = iina.run(iina.FFMPEG, '-hide_banner', '-nostats', '-ss', start, '-t', length, '-i', path, '-af', 'volumedetect',
                   '-f', 'null', '-').stderr
    m = re.search(r'mean_volume: (-?[\d.]+|-inf) dB', out)
    return float(m.group(1)) if m and m.group(1) != '-inf' else -200.0


def band(path, time_at=None):
    """The brightness of the band at the top of a picture (or of a video's frame at time_at), 0–255."""
    seek = ['-ss', str(time_at)] if time_at is not None else []
    out = iina.subprocess.run([iina.FFMPEG, '-v', 'error', *seek, '-i', path, '-frames:v', '1', '-vf',
                               'crop=iw:ih*50/720:0:ih*15/720,scale=1:1:flags=area', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                              capture_output=True).stdout
    return out[0] if out else None


def stored(lines):
    """storeMediaFile's files in mock.log: {filename: bytes}."""
    files = {}
    for line in lines:
        m = re.match(r'anki \d+ storeMediaFile (.*)$', line)
        if m:
            params = json.loads(m.group(1))
            files[params.get('filename')] = base64.b64decode(params.get('data') or '')
    return files


def main():
    case = sys.argv[1]
    media, options, audio, subtitles, kinds = CASES[case]()
    if case == 'cookie':
        with open(os.path.join(RUN, 'cookies.txt'), 'w') as f:
            f.write('# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\tmacpopup\tyes\n')
    if not check(iina.app_logged(r'TEST ready', 40), 'the page started'):
        return
    player = iina.IINA()
    iina.on_stop(player.stop)
    try:
        player.start(media, *options)
        if not check(player.listening(40), "the plugin's WebSocket server listens (IINA started)"):
            return
        if audio or subtitles:
            player.add(player.mpv(), audio, subtitles)
        client = iina.Plugin()
        line = client.wait_for(lambda m: '明日も晴れる' in (m.get('sentence') or ''), 60)
        if check(bool(line), "the plugin's line 2"):
            p = line[1]['player']
            check(abs(p.get('start', 0) - 6.0) < 0.05 and abs(p.get('end', 0) - 8.5) < 0.05,
                  f"line 2's times: {p.get('start')}–{p.get('end')} (expected 6–8.5)")
            check((kind(p.get('video')), kind(p.get('audio'))) == kinds,
                  f"where line 2's video and audio are read from: {kind(p.get('video'))}, {kind(p.get('audio'))} (expected {kinds[0]}, {kinds[1]})")
            log(f'line 2: {json.dumps(line[1], ensure_ascii=False)[:600]}')
            if case == 'proxy':
                check((p.get('audio') or {}).get('proxy') == 'http://127.0.0.1:59886', f"the audio's proxy: {(p.get('audio') or {}).get('proxy')}")
            if case == 'cookie':
                headers = (p.get('audio') or {}).get('headers') or []
                check('Cookie: macpopup=yes' in headers, f"the audio's headers: {headers}")
        done = iina.app_logged(r'TEST done', 120)
        check(done, 'the page finished')
        with open(os.path.join(RUN, 'mock.log'), errors='replace') as f:
            files = stored(f.read().splitlines())
        sounds = [name for name in files if name and name.endswith('.m4a')]
        shots = [name for name in files if name and name.endswith('.jpg')]
        if check(len(sounds) == 1, f'one sentence audio stored: {sounds}'):
            path = os.path.join(RUN, 'card-audio.m4a')
            with open(path, 'wb') as f:
                f.write(files[sounds[0]])
            length = iina.duration(path)
            check(abs(length - 3.5) <= 0.15, f'the sentence audio lasts {length:.3f} s (expected 3.5 ± 0.15: 5.5–9 s)')
            parts = [('silent', 0.0, 0.4), ('the tone', 0.6, 1.7), ('silent', 3.1, 0.35)]
            levels = [(name, round(mean_volume(path, start, span), 1)) for name, start, span in parts]
            check(levels[0][1] < -50 and levels[1][1] > -20 and levels[2][1] < -50,
                  f'mean volumes 0–0.4, 0.6–2.3, 3.1–3.45 s: {[v for _, v in levels]} dB (expected silent < -50, tone > -20, silent < -50)')
        if check(len(shots) == 1, f'one screenshot stored: {shots}'):
            path = os.path.join(RUN, 'card-shot.jpg')
            with open(path, 'wb') as f:
                f.write(files[shots[0]])
            size = iina.run(iina.FFPROBE, '-v', 'error', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', path).stdout.strip()
            log(f'screenshot {size}')
            shot = band(path)
            source = {t: band(LOCAL, t) for t in (6.0, 7.25, 8.5)}
            if check(shot is not None and None not in source.values(), f'band levels: screenshot {shot}, video at 6, 7.25, 8.5 s {source}'):
                nearest = min(source, key=lambda t: abs(source[t] - shot))
                slope = (source[8.5] - source[6.0]) / 2.5
                at = 7.25 + (shot - source[7.25]) / slope if slope else 0
                check(nearest == 7.25 and abs(at - 7.25) <= 0.35,
                      f"the screenshot is from {at:.2f} s (expected the line's middle, 7.25 ± 0.35; nearest of 6, 7.25, 8.5: {nearest})")
        client.close()
    finally:
        check(player.stop(), 'IINA quit')
        iina.check_user_iina(check)


main()
