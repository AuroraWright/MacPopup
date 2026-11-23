"""make-music.py <out.wav>: 60 s of synthetic background music (plucked chords, a bass line and a soft beat, 16 kHz
mono) to play under the test voices: no speech in it, for the sound classifier to tell apart. Made at test time by
speech.py (from evals/transcribe)."""
import sys, wave
import numpy as np

sr, bpm = 16000, 96
beat = 60 / bpm
rng = np.random.default_rng(1)
out = np.zeros(sr * 60, np.float32)

def pluck(freq, seconds):
    period = int(sr / freq)
    buf = rng.uniform(-1, 1, period)
    n = int(sr * seconds)
    y = np.empty(n, np.float32)
    for i in range(n):
        y[i] = buf[i % period]
        buf[i % period] = 0.498 * (buf[i % period] + buf[(i + 1) % period])
    return y

chords = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
t, bar = 0.0, 0
while t < 59:
    chord = chords[bar % 4]
    for k in range(4):
        start = int((t + k * beat) * sr)
        for j, f in enumerate(chord):
            note = pluck(f * (2 if k % 2 else 1), beat * 1.5) * 0.25
            s = start + int(j * 0.02 * sr)
            out[s:s + len(note)] += note[:max(0, len(out) - s)]
        bass = np.sin(2 * np.pi * chord[0] / 2 * np.arange(int(beat * sr)) / sr) * np.exp(-np.arange(int(beat * sr)) / (0.3 * sr)) * 0.3
        out[start:start + len(bass)] += bass[:max(0, len(out) - start)]
        kick = np.sin(2 * np.pi * 60 * np.arange(int(0.15 * sr)) / sr) * np.exp(-np.arange(int(0.15 * sr)) / (0.03 * sr)) * 0.5
        out[start:start + len(kick)] += kick[:max(0, len(out) - start)]
    t += 4 * beat
    bar += 1
out /= np.abs(out).max()
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((out * 32767 * 0.9).astype(np.int16).tobytes())
