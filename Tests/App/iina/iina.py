# iina.py: what the IINA tests (Tests/App/iina/*.test.js) share. They play videos in the user's IINA
# (/Applications/IINA.app) with its own MacPopup plugin, on the port its .preferences give (6680 by default, which the
# tests' settings use), started with "-key NO" arguments that turn off playback history, recent files, resuming and
# media keys for that run only (NSUserDefaults' argument domain, which IINA skips when it reads its arguments): its
# settings, plugins and their .preferences aren't written. Setup notes them and each driver checks they're unchanged at
# the end; a test doesn't start while IINA runs, and only the IINA it started is quit.
# The transcript tests keep the test instance's transcripts in /Users/Shared/Library/Caches/com.aury.macpopup/Transcripts
# (// env: MACPOPUP_TRANSCRIPTS_DIRECTORY), a path the plugin takes transcripts from (global.js: /Users/<any>/Library/
# Caches/com.aury.macpopup/Transcripts/<key>/), not the user's own; its files are deleted at setup and at the end (a
# stream's transcript would otherwise be found again by the next run), its folders left.
#   python3 -I iina.py setup test|speech      (// setup:) the user's IINA noted, the test media in $RUN/media (and for
#                                             speech, Live Caption's models cloned into $RUN/models)
#   python3 -I iina.py beside                 (// beside:) the web server (serve.py) on $RUN/media/web; when stopped,
#                                             quits the IINA the test started if still running
# Drivers import it (sys.path) for IINA (start/stop it), Plugin (a WebSocket client of the plugin), MPV (its IPC
# socket) and the checks of harness/tools/driver.py.
import base64, hashlib, json, os, plistlib, re, shutil, signal, socket, subprocess, sys, tempfile, threading, time, unicodedata

sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get('REPO') or os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
RUN = os.environ.get('RUN', '')
sys.path.insert(0, os.path.join(REPO, 'Tests/App/harness/tools'))
sys.path.insert(0, HERE)

USER_IINA = '/Applications/IINA.app'
USER_SUPPORT = os.path.expanduser('~/Library/Application Support/com.colliderli.iina')
PLUGIN_ID = 'com.aury.macpopup.iina'
TRANSCRIPTS = '/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts'
TEST_PORT = 6680  # (in the tests' settings: ws://127.0.0.1:6680)
# Set for the user's IINA for one run, not written: "-key NO" arguments.
RUN_DEFAULTS = ('recordPlaybackHistory', 'recordRecentFiles', 'resumeLastPosition', 'useMediaKeys',
                'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate')
WEB = 'http://127.0.0.1:59885'
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'

# The test video's lines (evals/iina/subs.srt): text, start, end; a tone plays only while each shows (440 Hz,
# 880 Hz, 660 Hz). A band at the top of the picture is as bright as 12 levels a second (0 at 0 s, 87 at 7.25 s), for
# telling which frame a screenshot is.
LINES = [('今日はいい天気ですね。', 2.0, 4.0), ('明日も晴れるといいな。', 6.0, 8.5), ('猫が窓の外を見ている。', 11.0, 13.0)]
# The speech video's sentences (said by macOS's Kyoko), 3 s apart, the first 5 s in.
SENTENCES = ['今日はとても良い天気ですね。', '駅までゆっくり歩いて行きました。', '明日の朝は早く起きなければなりません。',
             '彼女は窓の外をじっと見ていました。', 'この本はとても面白かったです。', 'みんなで一緒に晩ご飯を食べましょう。']


def log(message):
    print(message, flush=True)


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)


# --- The user's IINA


def iina_processes():
    """The processes running from the user's IINA: (pid, parent's pid, command line)."""
    out = run('ps', '-axo', 'pid=,ppid=,command=').stdout
    return [(int(parts[0]), int(parts[1]), parts[2]) for parts in (line.split(None, 2) for line in out.splitlines())
            if len(parts) == 3 and parts[2].startswith(USER_IINA + '/Contents/MacOS/')]


def user_pids():
    """The processes running from the user's IINA: pids."""
    return [pid for pid, _, _ in iina_processes()]


def user_iina_running():
    return bool(user_pids())


def user_port():
    """The port of the user's MacPopup plugin: its .preferences', or Info.json's default."""
    try:
        with open(os.path.join(USER_SUPPORT, 'plugins/.preferences', f'{PLUGIN_ID}.plist'), 'rb') as f:
            port = plistlib.load(f).get('port')
        if port:
            return int(port)
    except (OSError, ValueError, plistlib.InvalidFileException):
        pass
    with open(os.path.join(USER_SUPPORT, 'plugins', f'{PLUGIN_ID}.iinaplugin', 'Info.json')) as f:
        return int(json.load(f).get('preferenceDefaults', {}).get('port', 6680))


def stop_pids(pids, timeout=10):
    """Quits these processes (SIGTERM, then SIGKILL) if they still run IINA: whether none is left."""
    def left():
        return [pid for pid in pids if pid in user_pids()]
    for pid in left():
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    end = time.monotonic() + timeout
    while left() and time.monotonic() < end:
        time.sleep(0.2)
    for pid in left():
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    time.sleep(0.5)
    return not left()


# --- The user's IINA's settings and files, only read


def user_state():
    """IINA's settings (defaults export, as XML) and every file in its Application Support folder (plugins,
    .preferences, .data, watch_later…): sizes, times and hashes of the small ones."""
    export = subprocess.run(['defaults', 'export', 'com.colliderli.iina', '-'], capture_output=True).stdout
    xml = subprocess.run(['plutil', '-convert', 'xml1', '-o', '-', '-'], input=export, capture_output=True).stdout
    files = {}
    for folder, dirs, names in os.walk(USER_SUPPORT):
        for name in dirs + names:
            path = os.path.join(folder, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            # Folders by name, files by content (IINA writes its plugins' .preferences again, unchanged, at launch);
            # large ones by size and time.
            entry = []
            if name in names and os.path.isfile(path) and not os.path.islink(path):
                entry = [st.st_size]
                if st.st_size < 20_000_000:
                    with open(path, 'rb') as f:
                        entry.append(hashlib.sha256(f.read()).hexdigest())
                else:
                    entry.append(st.st_mtime_ns)
            files[os.path.relpath(path, USER_SUPPORT)] = entry
    try:
        keys = {k: hashlib.sha256(repr(v).encode()).hexdigest() for k, v in plistlib.loads(xml).items()}
    except (plistlib.InvalidFileException, ValueError, AttributeError):
        keys = {}
    return {'settings': hashlib.sha256(xml).hexdigest(), 'keys': keys, 'files': files}


def check_user_iina(check):
    """The check that the user's IINA settings and files are as setup noted them."""
    try:
        with open(os.path.join(RUN, 'iina-user-before.json')) as f:
            before = json.load(f)
    except OSError:
        return check(False, "the user's IINA wasn't noted before the test (setup)")
    after = user_state()
    changed = sorted(set(before['files']) ^ set(after['files'])
                     | {k for k in before['files'] if k in after['files'] and before['files'][k] != after['files'][k]})
    settings_same = before['settings'] == after['settings']
    a, b = before.get('keys', {}), after.get('keys', {})
    keys = sorted(set(a) ^ set(b) | {k for k in a if k in b and a[k] != b[k]})
    return check(settings_same and not changed,
                 "the user's IINA settings, plugins and their preferences unchanged"
                 + ('' if settings_same else f' (IINA SETTINGS CHANGED: {keys[:20]})')
                 + (f' (CHANGED: {changed[:10]})' if changed else '')
                 + ('' if settings_same and not changed else
                    f'; copies from before: {RUN}/iina-settings-before.plist, {RUN}/iina-plugin-preferences-before'))


# --- Test media


def ffmpeg(*args):
    result = run(FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', *args)
    if result.returncode:
        raise RuntimeError(f'ffmpeg {" ".join(map(str, args))[:200]} failed: {result.stderr.strip()[-500:]}')


def duration(path):
    return float(run(FFPROBE, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path).stdout.strip() or 0)


def streams(video, web):
    """web/: the video as served (HTTP), HLS with a keyframe every 2 s (hls2/), DASH with fixed segments (dash2/),
    video-only.mp4 + audio-only.m4a (yt-dlp's bestvideo+bestaudio), and the EDLs that play dash2/ as IINA's yt-dlp
    plugin does (dash-video.edl unescaped, for the command line; dash-audio.edl escaped, for audio-add)."""
    os.makedirs(os.path.join(web, 'hls2'))
    os.makedirs(os.path.join(web, 'dash2'))
    shutil.copy(video, web)
    name = os.path.basename(video)
    gop = ['-c:v', 'libx264', '-preset', 'veryfast', '-g', '48', '-keyint_min', '48', '-sc_threshold', '0', '-c:a', 'aac', '-b:a', '128k']
    ffmpeg('-i', video, '-map', '0:v', '-map', '0:a', *gop, '-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod',
           '-hls_segment_filename', f'{web}/hls2/seg%03d.ts', f'{web}/hls2/index.m3u8')
    ffmpeg('-i', video, '-map', '0:v', '-map', '0:a', *gop, '-f', 'dash', '-seg_duration', '2', '-use_template', '1',
           '-use_timeline', '0', '-adaptation_sets', 'id=0,streams=v id=1,streams=a', f'{web}/dash2/manifest.mpd')
    ffmpeg('-i', video, '-map', '0:v', '-c:v', 'copy', '-movflags', '+faststart', f'{web}/video-only.mp4')
    ffmpeg('-i', video, '-map', '0:a', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', f'{web}/audio-only.m4a')
    for stream, kind, escape in ((0, 'video', False), (1, 'audio', True)):
        with open(f'{web}/dash-{kind}.edl', 'w') as f:
            f.write(dash_edl(f'{web}/dash2', f'{WEB}/dash2', stream, escape))
    return name


def dash_edl(folder, base, stream, escape):
    """The edl:// URL of one DASH track (research/iina/streams/dash-edl.sh with ONE=1): its init segment and each
    fragment with its length; URLs written %<length>%<url> when escaped."""
    esc = (lambda u: f'%{len(u)}%{u}') if escape else (lambda u: u)
    init = os.path.join(folder, f'init-stream{stream}.m4s')
    edl = f'edl://!mp4_dash,init={esc(f"{base}/init-stream{stream}.m4s")};'
    previous = 0.0
    joined = os.path.join(folder, f'.joined-{stream}.mp4')
    for name in sorted(n for n in os.listdir(folder) if n.startswith(f'chunk-stream{stream}-')):
        # (A fragment after the init segment reads as lasting until its end.)
        with open(joined, 'wb') as out:
            for part in (init, os.path.join(folder, name)):
                with open(part, 'rb') as f:
                    out.write(f.read())
        end = duration(joined)
        edl += f'{esc(f"{base}/{name}")},length={end - previous:.6f};'
        previous = end
    return edl


def make_test_media(media):
    """media/local/test.mkv (alone in its folder: IINA queues the other files of a video's folder): 20 s of testsrc2
    with the brightness band, the lines as a Japanese subtitle track (not default) and the tones; media/web/ (streams)
    with subs.srt."""
    os.makedirs(os.path.join(media, 'local'))
    srt = os.path.join(media, 'subs.srt')
    with open(srt, 'w') as f:
        for n, (text, start, end) in enumerate(LINES, 1):
            stamp = lambda t: f'00:00:{int(t):02d},{round(t % 1 * 1000):03d}'
            f.write(f'{n}\n{stamp(start)} --> {stamp(end)}\n{text}\n\n')
    tone = 'if(between(t,2,4),sin(2*PI*440*t),if(between(t,6,8.5),sin(2*PI*880*t),if(between(t,11,13),sin(2*PI*660*t),0)))*0.5'
    video = os.path.join(media, 'local/test.mkv')
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24:duration=20',
           '-f', 'lavfi', '-i', "color=c=black:s=1280x80:r=24:d=20,format=gray,geq=lum='clip(T*12,0,255)'",
           '-f', 'lavfi', '-i', f"aevalsrc='{tone}|{tone}':s=48000:d=20", '-i', srt,
           '-filter_complex', '[1:v]format=yuv420p[band];[0:v][band]overlay=0:0,format=yuv420p[v]',
           '-map', '[v]', '-map', '2:a', '-map', '3:s', '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'libopus',
           '-b:a', '96k', '-c:s', 'srt', '-metadata:s:s:0', 'language=jpn', video)
    web = os.path.join(media, 'web')
    os.makedirs(web)
    streams(video, web)
    shutil.copy(srt, web)


def make_speech_media(media):
    """media/local/speech.mkv: SENTENCES said by Kyoko (say -o, never to the speakers) over a grey picture, no subtitle
    track; sentences.json (text, start, end); media/web/ (streams)."""
    os.makedirs(os.path.join(media, 'local'))
    voices, timeline, at = [], [], 5.0
    for n, text in enumerate(SENTENCES):
        voice = os.path.join(media, f'voice{n}.aiff')
        result = run('say', '-v', 'Kyoko', '-o', voice, text)
        if result.returncode or not os.path.exists(voice):
            raise RuntimeError(f'say -v Kyoko -o failed: {result.stderr.strip()}')
        length = duration(voice)
        voices.append(voice)
        timeline.append({'text': text, 'start': round(at, 3), 'end': round(at + length, 3)})
        at += length + 3.0
    total = at + 2.0
    inputs = [arg for v in voices for arg in ('-i', v)]
    delays = ''.join(f'[{n}:a]aresample=48000,aformat=channel_layouts=mono,adelay=delays={round(t["start"] * 1000)}:all=1[a{n}];'
                     for n, t in enumerate(timeline))
    mix = ''.join(f'[a{n}]' for n in range(len(voices))) + f'amix=inputs={len(voices)}:normalize=0:duration=longest,apad=whole_dur={total}[a]'
    video = os.path.join(media, 'local/speech.mkv')
    ffmpeg(*inputs, '-f', 'lavfi', '-i', f'color=c=gray:s=640x360:r=24:d={total}', '-filter_complex', delays + mix,
           '-map', f'{len(voices)}:v', '-map', '[a]', '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', '-b:a', '128k',
           '-t', f'{total}', video)
    with open(os.path.join(media, 'sentences.json'), 'w') as f:
        json.dump(timeline, f, ensure_ascii=False, indent=1)
    streams(video, os.path.join(media, 'web'))


def clear_transcripts():
    """Deletes the files in TRANSCRIPTS' folders (the folders stay): only the tests' (the user's are in their own
    ~/Library/Caches), and not when a part of its path leads elsewhere (/Users/Shared is anyone's to change). Each
    folder is opened without following links and its files are deleted from it, so a folder swapped for a link
    meanwhile can't lead elsewhere; only in folders that are the user's."""
    if not os.path.isdir(TRANSCRIPTS):
        return
    if os.path.realpath(TRANSCRIPTS) != TRANSCRIPTS or os.stat(TRANSCRIPTS).st_uid != os.getuid():
        log(f"{TRANSCRIPTS} leads elsewhere or isn't the user's: its files are left alone")
        return
    for folder, _, names, fd in os.fwalk(TRANSCRIPTS, follow_symlinks=False):
        if os.fstat(fd).st_uid != os.getuid():
            log(f"{folder} isn't the user's: its files are left alone")
            continue
        for name in names:
            os.unlink(name, dir_fd=fd)


def setup(kind):
    if user_iina_running():
        raise RuntimeError("the user's IINA is running")
    # The plugin tested is the one IINA has: it must be the repo's, on the port the tests' settings name.
    installed = os.path.join(USER_SUPPORT, 'plugins', f'{PLUGIN_ID}.iinaplugin')
    repo = os.path.join(REPO, 'iina-plugin')
    for name in sorted(os.listdir(repo)):
        try:
            with open(os.path.join(repo, name), 'rb') as a, open(os.path.join(installed, name), 'rb') as b:
                same = a.read() == b.read()
        except OSError:
            same = False
        if not same:
            raise RuntimeError(f"IINA's MacPopup plugin isn't the repo's ({name} differs or is missing in {installed}): "
                               'install the repo\'s iina-plugin/ first')
    if user_port() != TEST_PORT:
        raise RuntimeError(f"IINA's MacPopup plugin is on port {user_port()}, the tests' settings use {TEST_PORT}")
    with open(os.path.join(RUN, 'iina-user-before.json'), 'w') as f:
        json.dump(user_state(), f)
    # Copies, to put back by hand if the check after finds them changed (the test doesn't write the user's IINA's
    # settings, even to put them back).
    subprocess.run(['defaults', 'export', 'com.colliderli.iina', os.path.join(RUN, 'iina-settings-before.plist')],
                   capture_output=True)
    preferences = os.path.join(USER_SUPPORT, 'plugins', '.preferences')
    if os.path.isdir(preferences):
        shutil.copytree(preferences, os.path.join(RUN, 'iina-plugin-preferences-before'), symlinks=True)
    media = os.path.join(RUN, 'media')
    if kind == 'speech':
        clear_transcripts()
        soda = os.path.expanduser('~/Library/Application Support/MacPopup/SODA')
        if not os.path.exists(os.path.join(soda, 'soda.json')):
            raise RuntimeError("Live Caption's models aren't loaded (Settings → Transcription): no " + soda)
        # A clone (copy on write) in the instance's models folder: the user's stay as they are.
        result = run('cp', '-cRp', soda, os.path.join(RUN, 'models/SODA'))
        if result.returncode:
            raise RuntimeError(f'cloning the SODA models failed: {result.stderr.strip()}')
        make_speech_media(media)
    else:
        make_test_media(media)
    log(f'media in {media}')


# --- Running IINA


class IINA:
    """The user's IINA for this test."""

    def __init__(self):
        self.cli = None
        self.started = None
        self.socket = os.path.join(tempfile.gettempdir(), f'macpopup-test-mpv-{os.getpid()}.sock')
        self.port = user_port()
        self.pids = []

    def start(self, media, *options):
        """Plays media (a path or URL) muted, with iina-cli's options ("--mpv-…")."""
        if user_iina_running():
            raise RuntimeError('IINA is running')
        defaults = [a for key in RUN_DEFAULTS for a in (f'-{key}', 'NO')]
        args = [os.path.join(USER_IINA, 'Contents/MacOS/iina-cli'), '--no-stdin', *defaults, '--mpv-mute=yes',
                '--mpv-resume-playback=no', '--mpv-save-position-on-quit=no', f'--mpv-input-ipc-server={self.socket}',
                *options, media]
        log(f'starting: {" ".join(args)}')
        self.cli = subprocess.Popen(args, stdout=open(os.path.join(RUN, 'iina.log'), 'a'), stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL)
        self.started = time.monotonic()

    def listening(self, timeout=40):
        """Whether the plugin's WebSocket server took connections within timeout s."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.note_pids()
            try:
                socket.create_connection(('127.0.0.1', self.port), timeout=1).close()
                return True
            except OSError:
                time.sleep(0.3)
        return False

    def note_pids(self):
        """The IINA this test started (iina-cli, and the IINA it started, with this test's mpv socket): noted for stop
        and for beside's cleanup. Not any other IINA, e.g. one the user opened meanwhile."""
        if not self.cli:
            return
        new = [pid for pid, parent, command in iina_processes()
               if pid not in self.pids and (self.cli.pid in (pid, parent) or self.socket in command)]
        if new:
            self.pids += new
            with open(os.path.join(RUN, 'iina-pids'), 'a') as f:
                f.write(''.join(f'{pid}\n' for pid in new))

    def mpv(self, timeout=40):
        return MPV(self.socket, timeout)

    def add(self, mpv, audio=None, subtitles=None):
        """Adds tracks as IINA's yt-dlp plugin does (research/iina/streams/add.py), once mpv plays."""
        end = time.monotonic() + 20
        while mpv.send('get_property', 'time-pos').get('error') != 'success' and time.monotonic() < end:
            time.sleep(0.1)
        for command, url in (('audio-add', audio), ('sub-add', subtitles)):
            if url:
                log(f'{command} {url[:120]}: {mpv.send(command, url, "select")}')

    def log_tail(self, lines=60):
        """Prints the end of this run's IINA log, if the user has IINA's logging on (~/Library/Logs/com.colliderli.iina,
        with the plugins' console lines; only read), for telling why a test failed."""
        logs = os.path.expanduser('~/Library/Logs/com.colliderli.iina')
        since = time.time() - (time.monotonic() - self.started) - 5 if self.started else 0
        found = []
        for folder, _, names in os.walk(logs):
            found += [os.path.join(folder, n) for n in names
                      if n.endswith('.log') and os.stat(os.path.join(folder, n)).st_mtime >= since]
        found = sorted(found, key=os.path.getmtime)[-1:]
        if not found:
            log(f"IINA's log: none of this run in {logs} (IINA's logging off?)")
        for path in sorted(found):
            with open(path, errors='replace') as f:
                tail = f.read().splitlines()[-lines:]
            log(f"IINA's log {path} (last {len(tail)} lines):")
            for line in tail:
                log(f'  {line}')

    def stop(self):
        """Quits the IINA this test started: whether it's gone."""
        self.log_tail()
        self.note_pids()
        gone = stop_pids(self.pids)
        others = [pid for pid in user_pids() if pid not in self.pids]
        if others:
            log(f'IINA running that this test didn\'t start, left alone: {others}')
        if self.cli and self.cli.poll() is None:
            self.cli.kill()
        if os.path.exists(self.socket):
            os.remove(self.socket)
        return gone


class MPV:
    """mpv's JSON IPC (IINA's --mpv-input-ipc-server)."""

    def __init__(self, path, timeout=40):
        end = time.monotonic() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.connect(path)
                break
            except OSError:
                if time.monotonic() > end:
                    raise RuntimeError(f"mpv's IPC socket never came ({path})")
                time.sleep(0.2)
        self.buffer = b''
        self.next_id = 1
        self.lock = threading.Lock()

    def send(self, *command):
        with self.lock:
            rid = self.next_id
            self.next_id += 1
            self.sock.sendall((json.dumps({'command': list(command), 'request_id': rid}) + '\n').encode())
            while True:
                while b'\n' not in self.buffer:
                    data = self.sock.recv(65536)
                    if not data:
                        raise EOFError
                    self.buffer += data
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line)
                if message.get('request_id') == rid:
                    return message

    def get(self, name):
        return self.send('get_property', name).get('data')


class Plugin:
    """A WebSocket client of the plugin, as MacPopup's page is: each message with its time (s since connecting) in
    .messages, collected in the background."""

    def __init__(self, port=None, timeout=40):
        port = port or user_port()
        end = time.monotonic() + timeout
        while True:
            try:
                self.sock = socket.create_connection(('127.0.0.1', port), timeout=2)
                key = base64.b64encode(os.urandom(16)).decode()
                self.sock.sendall(f'GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                  f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
                head = b''
                while b'\r\n\r\n' not in head:
                    data = self.sock.recv(4096)
                    if not data:
                        raise OSError('closed')
                    head += data
                if b' 101 ' not in head.split(b'\r\n', 1)[0]:
                    raise OSError(head.split(b'\r\n', 1)[0].decode(errors='replace'))
                self.buffer = head.split(b'\r\n\r\n', 1)[1]
                break
            except OSError:
                if time.monotonic() > end:
                    raise RuntimeError(f"the plugin's WebSocket on {port} never answered")
                time.sleep(0.3)
        self.sock.settimeout(None)
        self.started = time.monotonic()
        self.messages = []
        self.closed = False
        self.send_lock = threading.Lock()
        threading.Thread(target=self.read, daemon=True).start()

    def frame(self, opcode, payload):
        n = len(payload)
        length = bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + n.to_bytes(2, 'big') if n < 65536 else bytes([0x80 | 127]) + n.to_bytes(8, 'big')
        mask = os.urandom(4)
        return bytes([0x80 | opcode]) + length + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    def send(self, message):
        with self.send_lock:
            self.sock.sendall(self.frame(1, json.dumps(message).encode()))

    def take(self, n):
        while len(self.buffer) < n:
            data = self.sock.recv(65536)
            if not data:
                raise EOFError
            self.buffer += data
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def read(self):
        parts = b''
        try:
            while True:
                b0, b1 = self.take(2)
                n = b1 & 0x7f
                if n == 126:
                    n = int.from_bytes(self.take(2), 'big')
                elif n == 127:
                    n = int.from_bytes(self.take(8), 'big')
                mask = self.take(4) if b1 & 0x80 else None
                payload = self.take(n)
                if mask:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                opcode = b0 & 0x0f
                if opcode == 8:
                    break
                if opcode == 9:
                    with self.send_lock:
                        self.sock.sendall(self.frame(10, payload))
                    continue
                if opcode in (0, 1, 2):
                    parts += payload
                    if b0 & 0x80:
                        try:
                            message = json.loads(parts.decode())
                        except ValueError:
                            message = {'unreadable': parts.decode(errors='replace')}
                        self.messages.append((round(time.monotonic() - self.started, 2), message))
                        parts = b''
        except (OSError, EOFError, ValueError):
            pass
        self.closed = True

    def wait_for(self, find, timeout):
        """The first message (time, message) for which find(message) is truthy, or None after timeout s."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for item in list(self.messages):
                if find(item[1]):
                    return item
            time.sleep(0.1)
        return None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --- For drivers


def app_logged(pattern, timeout):
    """Whether app.log has a line matching pattern within timeout s."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            with open(os.path.join(RUN, 'app.log'), errors='replace') as f:
                if re.search(pattern, f.read(), re.M):
                    return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def plain(text):
    """Text without punctuation, spaces or width differences, for comparing transcripts."""
    text = unicodedata.normalize('NFKC', text or '')
    return ''.join(c for c in text if not unicodedata.category(c).startswith(('P', 'Z', 'C', 'S')))


def similarity(expected, got):
    """How much of expected is in got (longest common subsequence / its length), 0 to 1."""
    a, b = plain(expected), plain(got)
    if not a:
        return 0.0
    row = [0] * (len(b) + 1)
    for ca in a:
        previous = 0
        for j, cb in enumerate(b, 1):
            previous, row[j] = row[j], previous + 1 if ca == cb else max(row[j], row[j - 1])
    return row[-1] / len(a)


def on_stop(cleanup):
    """Runs cleanup (once) when the driver is stopped (the test's timeout) or ends."""
    done = []

    def handler(*_):
        if not done:
            done.append(1)
            cleanup()
        sys.exit(1)
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGHUP, handler)


def beside():
    """The web server; when stopped, quits the IINA the test started if left running, and deletes the transcripts'
    files (TRANSCRIPTS)."""
    import serve
    web = os.path.join(RUN, 'media/web')
    if os.path.isdir(web):
        serve.serve(web, os.path.join(RUN, 'serve.log'))
        log(f'serving {web} on {serve.PORT}, proxy on {serve.PROXY_PORT}')

    def stopped(*_):
        try:
            with open(os.path.join(RUN, 'iina-pids')) as f:
                pids = [int(line) for line in f if line.strip()]
        except (OSError, ValueError):
            pids = []
        if [pid for pid in pids if pid in user_pids()]:
            log(f'quitting the IINA the test started, left running: {pids}')
            stop_pids(pids)
        clear_transcripts()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    signal.signal(signal.SIGHUP, stopped)
    while True:
        time.sleep(3600)


if __name__ == '__main__':
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'setup' and len(sys.argv) == 3 and sys.argv[2] in ('test', 'speech'):
        try:
            setup(sys.argv[2])
        except (RuntimeError, OSError) as error:
            log(f'setup failed: {error}')
            sys.exit(1)
    elif command == 'beside':
        beside()
    else:
        log('usage: iina.py setup test|speech | beside')
        sys.exit(2)
