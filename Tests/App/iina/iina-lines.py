# iina-lines.py: the driver of iina/plugin-lines.test.js. Plays the test video (media/local/test.mkv, its Japanese
# subtitle track selected) in the user's IINA and reads the plugin's WebSocket as MacPopup's page does (subscribed to
# what the window plays): its three lines with their times, where their video and audio are (the file, streams 0
# and 1), sent as each is shown; and each second's status of the window. From evals/iina/plugin-run.sh and
# client.mjs (2026-11-07: "logs the plugin's messages until the third line"; the plugin's own screenshot was removed
# since).
import os, re, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iina
from driver import check, equal, log

VIDEO = os.path.join(iina.RUN, 'media/local/test.mkv')


def main():
    if not check(iina.app_logged(r'TEST ready', 40), 'the page started'):
        return
    player = iina.IINA()
    iina.on_stop(player.stop)
    try:
        player.start(VIDEO, '--mpv-sid=1')
        if not check(player.listening(40), "the plugin's WebSocket server listens (IINA started)"):
            return
        try:
            mpv = player.mpv(20)
            for name in ('path', 'pause', 'time-pos', 'sid', 'sub-text', 'mute', 'idle-active'):
                log(f'mpv {name}: {mpv.get(name)!r}')
        except (RuntimeError, OSError, EOFError) as error:
            log(f"mpv's IPC: {error}")
        client = iina.Plugin()
        client.send({'subscribe': 'playing'})
        third = client.wait_for(lambda m: iina.LINES[2][0] in (m.get('sentence') or ''), 45)
        if not check(bool(third), 'the third line came'):
            try:
                mpv = player.mpv(5)
                for name in ('path', 'pause', 'time-pos', 'sid', 'sub-text', 'idle-active'):
                    log(f'mpv {name} then: {mpv.get(name)!r}')
            except (RuntimeError, OSError, EOFError) as error:
                log(f"mpv's IPC then: {error}")
            log(f'messages from the plugin: {client.messages[:5]} (closed: {client.closed})')
        time.sleep(2.5)
        lines = [(t, m) for t, m in client.messages if 'sentence' in m]
        for t, m in lines:
            log(f'{t:6.2f} line {m}')
        equal([(m['sentence'], m['player'].get('start'), m['player'].get('end')) for _, m in lines],
              [list(line) for line in iina.LINES], "the lines' text, start and end")
        file = {'file': VIDEO, 'stream': 0}, {'file': VIDEO, 'stream': 1}
        equal([[m['player'].get('video'), m['player'].get('audio')] for _, m in lines], [list(file)] * len(lines),
              "where each line's video and audio are read from")
        labels = [m['player'].get('line') or '' for _, m in lines]
        check(len({l.rsplit('#', 1)[0] for l in labels}) == 1 and [l.rsplit('#', 1)[-1] for l in labels] == ['1', '2', '3'],
              f"the lines' ids, one window's lines 1 to 3: {labels}")
        times = [t for t, _ in lines]
        if len(times) == 3:
            # (The first line may have come as the last line when connecting.)
            gaps = [round(b - a, 2) for a, b in zip(times, times[1:])]
            check(abs(gaps[1] - 5.0) <= 0.6 and (times[0] < 0.3 or abs(gaps[0] - 4.0) <= 0.6),
                  f'sent as each is shown: {gaps} s apart (expected 4 and 5 ± 0.6, the subtitles at 2, 6 and 11 s)')
        statuses = [m['playing'] for _, m in client.messages if 'playing' in m]
        check(len(statuses) >= 8, f"the window's statuses, about one a second: {len(statuses)}")
        if statuses:
            s = statuses[-1]
            log(f'last status: {s}')
            equal([s.get('media'), s.get('track'), s.get('paused'), s.get('subtitles'), s.get('audio')],
                  [VIDEO, '1', False, ['jpn'], {'file': VIDEO, 'stream': 1}],
                  "the status's media, audio track, paused, subtitle languages and audio source")
            check('test.mkv' in (s.get('titles') or []), f"the status's titles: {s.get('titles')}")
            check(abs((s.get('duration') or 0) - 20) < 0.2, f"the status's duration: {s.get('duration')} (expected 20)")
            positions = [x.get('position') or 0 for x in statuses]
            check(all(b >= a for a, b in zip(positions, positions[1:])) and positions[-1] > 12,
                  f'positions going on: {[round(p, 1) for p in positions]}')
            check(len({x.get('key') for x in statuses}) == 1, "one window's key")
        client.close()
        check(iina.app_logged(r'TEST done', 100), 'the page finished')
    finally:
        check(player.stop(), 'IINA quit')
        iina.check_user_iina(check)


main()
