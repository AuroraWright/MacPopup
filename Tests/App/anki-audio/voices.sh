#!/bin/zsh
# voices.sh <dir>: the sound files the Anki Audio tests play (a test's "// setup:", into $RUN; none are committed),
# written with `say -o` (nothing is played; through harness/tools/say.sh, which tries again when it hangs):
# - voice0-3.aiff and .txt: windows/voicegame.swift's four lines, spoken by Kyoko (4.1, 5.6, 4.3 and 6.6 s);
# - voice-app.aiff (and .wav, for a web page): the captured app's Japanese line; voice-other.aiff: another app's English
#   line (Samantha);
# - silence.wav: 10 s of silence, windows/freezegame.swift's music.
set -euo pipefail
say=${0:A:h:h}/harness/tools/say.sh
cd "$1"
lines=("今日はいい天気ですね。少し散歩でもしませんか？" "あの扉の向こうに、まだ誰も知らない世界が広がっているんだよ。本当に。"
    "そんなこと言われても、私にはどうすることもできないよ。" "待って！その鍵を使えば、地下の倉庫に入れるはずだ。急いで行こう、時間がないんだ。")
for i in 0 1 2 3; do
    $say -v Kyoko -o voice$i.aiff "${lines[i + 1]}"
    print -r -- "${lines[i + 1]}" > voice$i.txt
done
$say -v Kyoko -o voice-app.aiff "ねえ、聞こえる？今日の放課後、屋上で待ってるからね。"
$say -v Kyoko -o voice-app.wav --data-format=LEI16@22050 "ねえ、聞こえる？今日の放課後、屋上で待ってるからね。"
$say -v Samantha -o voice-other.aiff "This is another app talking over the game, which should not be recorded."
python3 -I -c 'import sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050); w.writeframes(b"\0\0" * 220500); w.close()' silence.wav
for f in voice*.aiff voice-app.wav silence.wav; do print -r -- "$f $(afinfo $f | awk '/estimated duration/ {print $3}') s"; done
