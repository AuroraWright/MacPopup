# speech.py <plain|halves> [music] [sat]: the "// setup:" of the transcribe tests. In $RUN:
# - speech.wav (16 kHz mono), which the test instance plays in place of an app's audio (MACPOPUP_TEST_TRANSCRIPTION_FILE:
#   read from the file, never played to the speakers): 4 s of lead-in, then sentences said by Kyoko (say -o, nothing is
#   played) 3 s apart, and 5 s after the last; "plain": six sentences; "halves": four sentences, each said in two
#   halves with 0.35 s of silence between them (a stretch each with a 200 ms pause, joined again as one line that grows,
#   see GrowingLines); "music": make-music.py's music under all of it at -20 dB (alone in the lead-in and after);
# - speech.json: {"duration": s, "sentences": [{"text", "start", "end"}]} (seconds into the file);
# - models/SODA: Live Caption's models cloned (cp -c, copy on write) from the user's (Application Support/MacPopup/SODA;
#   the setup fails without them), and with "sat", models/SaT ("Detect sentence ends"). The user's stay as they are.
import json, os, subprocess, sys, wave
import numpy as np

sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.environ['RUN']
RATE = 16000
USER_MODELS = os.path.expanduser('~/Library/Application Support/MacPopup')
PLAIN = ['今日はとても良い天気ですね。', '駅までゆっくり歩いて行きました。', '明日の朝は早く起きなければなりません。',
         '彼女は窓の外をじっと見ていました。', 'この本はとても面白かったです。', 'みんなで一緒に晩ご飯を食べましょう。']
HALVES = [('昨日は雨が降っていたので', '家で本を読んでいました。'), ('駅の前の新しい店で', '美味しいケーキを買いました。'),
          ('週末になったら', '友達と海へ行くつもりです。'), ('この問題はとても難しいけれど', 'みんなで考えれば解けるはずです。')]


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout


def clone(name, marker):
    source = os.path.join(USER_MODELS, name)
    if not os.path.exists(os.path.join(source, marker)):
        raise SystemExit(f'no {source}/{marker}: load the model in Settings → Transcription first')
    run('cp', '-cRp', source, os.path.join(RUN, 'models', name))


def said(text, name):
    """Kyoko saying `text`, as 16 kHz samples (written by say -o, not played)."""
    path = os.path.join(RUN, f'{name}.wav')
    run(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'harness', 'tools', 'say.sh'), '-v', 'Kyoko',
        f'--data-format=LEI16@{RATE}', '-o', path, text)
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


def main():
    kind, extras = sys.argv[1], set(sys.argv[2:])
    clone('SODA', 'soda.json')
    if 'sat' in extras:
        clone('SaT', 'sat.json')
    parts, sentences, at = [np.zeros(4 * RATE, np.float32)], [], 4.0
    for n, sentence in enumerate(PLAIN if kind == 'plain' else HALVES if kind == 'halves' else []):
        if isinstance(sentence, tuple):
            first, second = said(sentence[0], f'voice{n}a'), said(sentence[1], f'voice{n}b')
            voice = np.concatenate([first, np.zeros(int(0.35 * RATE), np.float32), second])
            text = ''.join(sentence)
        else:
            voice, text = said(sentence, f'voice{n}'), sentence
        sentences.append({'text': text, 'start': round(at, 2), 'end': round(at + len(voice) / RATE, 2)})
        parts += [voice, np.zeros(3 * RATE, np.float32)]
        at += len(voice) / RATE + 3
    if not sentences:
        raise SystemExit(f'no sentences "{kind}"')
    audio = np.concatenate(parts + [np.zeros(2 * RATE, np.float32)])
    if 'music' in extras:
        music_path = os.path.join(RUN, 'music.wav')
        run(sys.executable, '-I', os.path.join(HERE, 'make-music.py'), music_path)
        with wave.open(music_path) as w:
            music = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
        audio = audio + np.resize(music, len(audio)) * 0.1
    audio = np.clip(audio, -1, 1)
    with wave.open(os.path.join(RUN, 'speech.wav'), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((audio * 32767).astype(np.int16).tobytes())
    duration = round(len(audio) / RATE, 2)
    with open(os.path.join(RUN, 'speech.json'), 'w') as f:
        json.dump({'duration': duration, 'sentences': sentences}, f, ensure_ascii=False, indent=1)
    print(f'speech.wav: {duration} s, {len(sentences)} sentences')


main()
