"""Generates sounds/owned_chime.wav, a ~1.5s chime. To use it as the success sound, rename it to owned.wav.
Run: python3 extras/make_chime.py"""
import math, os, struct, wave

RATE = 44100
LENGTH = 1.5
# Rising major arpeggio, each note a soft bell: a sine plus a quieter octave,
# quick attack, exponential decay. Later notes overlap the earlier ones.
NOTES = [(0.00, 783.99), (0.11, 987.77), (0.22, 1174.66), (0.33, 1567.98)]  # G5 B5 D6 G6

samples = [0.0] * int(RATE * LENGTH)
for start, freq in NOTES:
    s0 = int(start * RATE)
    for i in range(len(samples) - s0):
        t = i / RATE
        env = min(1, t / 0.006) * math.exp(-t * 3.2)
        v = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(4 * math.pi * freq * t) * math.exp(-t * 6)
        samples[s0 + i] += 0.2 * env * v
fade = int(0.15 * RATE)  # end on silence, no click
for i in range(fade):
    samples[-1 - i] *= i / fade

with wave.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sounds", "owned_chime.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples))
