# iina-dump.py: the driver of iina/dump-cache.test.js. Plays the test video as a live HLS stream (serve.py's
# /live/hls2.m3u8, subs.srt added) in the user's IINA, whose lines then say their video and audio are in IINA's cache;
# asks the plugin, as MacPopup does, to dump line 2 with 0.5 s around it (5.5–9 s) into a macpopup-dump-<id>.mkv in the
# temporary folder (the only name it accepts), and checks the reply and the file: video and audio, at least the range
# long (the dump starts at the keyframe before it), with the 880 Hz tone in it. Also that a request for a file elsewhere
# gets no reply. From research/iina/streams/probe.sh and probe.mjs (2026-11-10).
import json, os, re, sys, tempfile, uuid
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iina
from driver import check, equal, log


def main():
    player = iina.IINA()
    iina.on_stop(player.stop)
    dump = None
    try:
        player.start(f'{iina.WEB}/live/hls2.m3u8')
        if not check(player.listening(40), "the plugin's WebSocket server listens (IINA started)"):
            return
        player.add(player.mpv(), None, f'{iina.WEB}/subs.srt')
        client = iina.Plugin()
        line = client.wait_for(lambda m: '明日も晴れる' in (m.get('sentence') or ''), 60)
        if not check(bool(line), "the plugin's line 2"):
            return
        p = line[1]['player']
        log(f'line 2: {json.dumps(line[1], ensure_ascii=False)}')
        key = (p.get('audio') or {}).get('cache')
        if not check(bool(key) and (p.get('video') or {}).get('cache') == key, f"line 2's video and audio in IINA's cache: {p.get('video')}, {p.get('audio')}"):
            return
        # Elsewhere than the temporary folder: refused without a reply.
        bad = str(uuid.uuid4()).upper()
        client.send({'dump': {'id': bad, 'key': key, 'start': 5.5, 'end': 9.0, 'file': f'{iina.RUN}/macpopup-dump-{bad}.mkv'}})
        request = str(uuid.uuid4()).upper()
        dump = os.path.join(tempfile.gettempdir(), f'macpopup-dump-{request}.mkv')
        client.send({'dump': {'id': request, 'key': key, 'start': p['start'] - 0.5, 'end': p['end'] + 0.5, 'file': dump}})
        reply = client.wait_for(lambda m: (m.get('reply') or {}).get('id') == request, 30)
        equal(reply and reply[1]['reply'], {'id': request, 'file': dump}, "the plugin's reply")
        iina.time.sleep(1)
        check(client.wait_for(lambda m: (m.get('reply') or {}).get('id') == bad, 0.5) is None and not os.path.exists(f'{iina.RUN}/macpopup-dump-{bad}.mkv'),
              'a dump into a file elsewhere: no reply, no file')
        if check(os.path.exists(dump) and os.path.getsize(dump) > 10000, f'the dump: {os.path.getsize(dump) if os.path.exists(dump) else "none"} bytes'):
            kinds = iina.run(iina.FFPROBE, '-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', dump).stdout.split()
            check('video' in kinds and 'audio' in kinds, f'its streams: {kinds}')
            length = iina.duration(dump)
            check(3.4 <= length <= 6.5, f'it lasts {length:.2f} s (expected the 3.5 s asked for, from the keyframe before it: up to 6.5)')
            out = iina.run(iina.FFMPEG, '-hide_banner', '-nostats', '-i', dump, '-af', 'volumedetect', '-f', 'null', '-').stderr
            m = re.search(r'max_volume: (-?[\d.]+) dB', out)
            check(bool(m) and float(m.group(1)) > -12, f"the tone in it: max volume {m.group(1) if m else '-'} dB (expected > -12)")
        client.close()
    finally:
        if dump and os.path.exists(dump):
            os.remove(dump)
        check(player.stop(), 'IINA quit')
        iina.check_user_iina(check)


main()
