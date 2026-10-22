#!/usr/bin/env python3
"""Генерирует Resources/Demo/demo.wav и silence.wav (только стандартная библиотека).

demo.wav: 20 с, 44 100 Гц, моно, 16 бит, 120 BPM. Бочка на каждую долю,
малый барабан на 2 и 4, хай-хэт восьмыми, бас-линия синусом 55/65/73 Гц,
подклад из трех пил через однополюсный ФНЧ. Пик нормализуется до -1 dBFS,
шум детерминирован (seed 42), поэтому файл получается одинаковым при каждом запуске.
silence.wav: 20 с нулей в том же формате.
"""

import math
import random
import struct
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
DURATION = 20.0
BPM = 120.0
SEED = 42
PEAK_DBFS = -1.0

BEAT = 60.0 / BPM            # 0.5 с
BAR = 4 * BEAT               # 2 с
TOTAL = int(SAMPLE_RATE * DURATION)

# Корень баса на каждый такт и аккорд подклада к нему (Am, C, Dm, C).
BASS_ROOTS = [55.0, 65.0, 73.0, 65.0]
CHORDS = {
    55.0: (220.00, 261.63, 329.63),
    65.0: (261.63, 329.63, 392.00),
    73.0: (293.66, 349.23, 440.00),
}


def add_kick(buf):
    length = int(0.150 * SAMPLE_RATE)
    beats = int(DURATION / BEAT)
    for b in range(beats):
        start = int(b * BEAT * SAMPLE_RATE)
        phase = 0.0
        for i in range(length):
            n = start + i
            if n >= TOTAL:
                break
            t = i / SAMPLE_RATE
            freq = 55.0 + 95.0 * math.exp(-t / 0.025)   # падает от 150 к 55 Гц
            phase += 2.0 * math.pi * freq / SAMPLE_RATE
            env = math.exp(-t / 0.045) * min(1.0, i / 32.0)
            buf[n] += 0.95 * env * math.sin(phase)


def add_snare(buf, rng):
    length = int(0.150 * SAMPLE_RATE)
    beats = int(DURATION / BEAT)
    for b in range(beats):
        if b % 4 not in (1, 3):     # доли 2 и 4
            continue
        start = int(b * BEAT * SAMPLE_RATE)
        for i in range(length):
            n = start + i
            if n >= TOTAL:
                break
            t = i / SAMPLE_RATE
            noise = rng.uniform(-1.0, 1.0) * math.exp(-t / 0.040)
            tone = math.sin(2.0 * math.pi * 180.0 * t) * math.exp(-t / 0.060)
            buf[n] += 0.45 * noise + 0.35 * tone


def add_hihat(buf, rng):
    length = int(0.040 * SAMPLE_RATE)
    step = BEAT / 2.0               # восьмые
    count = int(DURATION / step)
    for k in range(count):
        start = int(k * step * SAMPLE_RATE)
        prev = 0.0
        for i in range(length):
            n = start + i
            if n >= TOTAL:
                break
            t = i / SAMPLE_RATE
            white = rng.uniform(-1.0, 1.0)
            high = white - prev        # разность соседних сэмплов: простой ФВЧ
            prev = white
            accent = 1.0 if k % 2 == 1 else 0.7
            buf[n] += 0.12 * accent * high * math.exp(-t / 0.012)


def add_bass(buf):
    phase = 0.0
    for n in range(TOTAL):
        t = n / SAMPLE_RATE
        bar = int(t / BAR)
        freq = BASS_ROOTS[bar % len(BASS_ROOTS)]
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        in_beat = (t % BEAT) / BEAT
        env = 0.55 + 0.45 * math.exp(-in_beat * 4.0)   # легкий акцент на долю
        buf[n] += 0.32 * env * math.sin(phase)


def add_pad(buf):
    cutoff = 900.0
    alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff / SAMPLE_RATE)
    phases = [0.0, 0.0, 0.0]
    lp = 0.0
    for n in range(TOTAL):
        t = n / SAMPLE_RATE
        bar = int(t / BAR)
        chord = CHORDS[BASS_ROOTS[bar % len(BASS_ROOTS)]]
        x = 0.0
        for j, freq in enumerate(chord):
            phases[j] += freq / SAMPLE_RATE
            phases[j] -= math.floor(phases[j])
            x += 2.0 * phases[j] - 1.0      # пила
        lp += alpha * (x - lp)              # однополюсный ФНЧ
        buf[n] += 0.06 * lp


def fade_edges(buf, seconds=0.01):
    length = int(seconds * SAMPLE_RATE)
    for i in range(length):
        g = i / length
        buf[i] *= g
        buf[TOTAL - 1 - i] *= g


def normalize(buf):
    peak = max(abs(v) for v in buf)
    if peak == 0.0:
        return
    gain = (10.0 ** (PEAK_DBFS / 20.0)) / peak
    for n in range(TOTAL):
        buf[n] *= gain


def write_wav(path, samples):
    frames = bytearray()
    for v in samples:
        q = int(round(v * 32767.0))
        q = max(-32768, min(32767, q))
        frames += struct.pack("<h", q)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(frames))


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Resources" / "Demo"
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(SEED)
    buf = [0.0] * TOTAL
    add_kick(buf)
    add_snare(buf, rng)
    add_hihat(buf, rng)
    add_bass(buf)
    add_pad(buf)
    fade_edges(buf)
    normalize(buf)

    write_wav(out_dir / "demo.wav", buf)
    write_wav(out_dir / "silence.wav", [0.0] * TOTAL)
    print(f"wrote {out_dir / 'demo.wav'} and {out_dir / 'silence.wav'}")


if __name__ == "__main__":
    main()
