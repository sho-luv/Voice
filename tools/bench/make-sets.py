#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""make-sets.py — build the test sets `Voice --bench` is scored on.

Usage:
  tools/bench/make-sets.py <bench-dir>

<bench-dir>/clean/*.wav (16 kHz mono) and <bench-dir>/refs.json ({id: reference text}) must
exist. The numbers in MODELS.md use the 73 utterances of hf-internal-testing/librispeech_asr_dummy
(clean/validation). Writes one folder per fault a real dictation can have (quiet talker, key
click, clipped start or end, room noise, hum, clipping, silence around the speech, no speech
at all) and long recordings made by joining the clean set. Needs numpy.
"""
import numpy as np, wave, os, sys, json
B = sys.argv[1]
rng = np.random.default_rng(7)
def read(p):
    with wave.open(p) as w: return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768
def write(p, x):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with wave.open(p, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())
def pink(n):
    f = np.fft.rfftfreq(n); f[0] = f[1]
    x = np.fft.irfft(np.fft.rfft(rng.standard_normal(n)) / np.sqrt(f), n)
    return x / np.sqrt(np.mean(x**2))
def rms(x): return np.sqrt(np.mean(x**2))
names = sorted(f[:-4] for f in os.listdir(f"{B}/clean"))
for n in names:
    x = read(f"{B}/clean/{n}.wav"); N = len(x)
    # quiet talker (peak ~ -40 dBFS) plus one loud click (key press / start chime bleed)
    q = x / np.max(np.abs(x)) * 0.01; q[800:808] = 0.9
    write(f"{B}/quiet_click/{n}.wav", q)
    write(f"{B}/quiet/{n}.wav", x / np.max(np.abs(x)) * 0.01)
    write(f"{B}/veryquiet/{n}.wav", x / np.max(np.abs(x)) * 0.002)
    write(f"{B}/tail_cut200/{n}.wav", x[: N - 3200])
    write(f"{B}/tail_cut400/{n}.wav", x[: N - 6400])
    write(f"{B}/head_cut250/{n}.wav", x[4000:])
    # room noise at 10 dB SNR, 60 Hz hum and a DC offset (cheap USB mic)
    t = np.arange(N) / 16000
    write(f"{B}/noise10/{n}.wav", x + pink(N) * rms(x) * 10 ** (-10 / 20))
    write(f"{B}/noise5/{n}.wav", x + pink(N) * rms(x) * 10 ** (-5 / 20))
    write(f"{B}/hum_dc/{n}.wav", x * 0.5 + 0.08 + 0.08 * np.sin(2 * np.pi * 60 * t) + 0.04 * np.sin(2 * np.pi * 120 * t))
    # clipped: talker too close / input gain too high
    write(f"{B}/clipped/{n}.wav", np.clip(x / np.max(np.abs(x)) * 6, -1, 1))
    # 1.5 s of silence before and after (hands-free: thinking before speaking)
    pad = pink(24000) * 0.001
    write(f"{B}/padded/{n}.wav", np.concatenate([pad, x, pad]))
# no speech at all
for i, lvl in enumerate([0.0, 0.0005, 0.003, 0.02]):
    write(f"{B}/nospeech/noise{i}.wav", pink(48000) * lvl)
k = np.zeros(32000); k[4000:4010] = 0.8; k[20000:20012] = -0.7
write(f"{B}/nospeech/clicks.wav", k + pink(32000) * 0.001)
# long-form: everything in one recording with 0.7 s pauses (hands-free mode)
parts = []; ref = []
refs = json.load(open(f"{B}/refs.json"))
for n in names:
    parts += [read(f"{B}/clean/{n}.wav"), np.zeros(11200)]; ref.append(refs[n])
write(f"{B}/long/long_all.wav", np.concatenate(parts))
half = len(names) // 6
write(f"{B}/long/long_80s.wav", np.concatenate(parts[: half * 2]))
json.dump({"long_all": " ".join(ref), "long_80s": " ".join(ref[:half])}, open(f"{B}/refs_long.json", "w"))
print("ok", len(names))
