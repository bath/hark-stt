#!/usr/bin/env python3
"""Render the whisper-dictation sound library.

    python3 sounds/generate.py <output-dir>

Writes <output-dir>/<pack>/{start,stop,done,error}.wav plus packs.json, the
index Hammerspoon reads to build the Sound menu. Standard library only, so the
installer can run it with the python3 that ships with the Command Line Tools.

Transitions:
  start  recording begins (keep it short: the mic is opening)
  stop   recording ends, Whisper is transcribing
  done   the text was pasted
  error  nothing was heard, or something failed
"""

import json
import math
import os
import random
import struct
import sys
import wave

SR = 44100
TAU = 2 * math.pi
TRANSITIONS = ("start", "stop", "done", "error")


# ---- synthesis primitives ----------------------------------------------------

def buf(seconds):
    return [0.0] * int(SR * seconds)


def envelope(i, n, attack, decay):
    t = i / SR
    a = min(1.0, t / attack) if attack > 0 else 1.0
    d = math.exp(-decay * i / n)
    tail = min(1.0, (n - i) / (0.004 * SR))
    return a * d * tail


def tone(b, t0, dur, f0, f1=None, glide=None, wave="sine", gain=0.3,
         attack=0.004, decay=6.9, partials=None, fm=None, vibrato=None):
    """Add one note. partials: [(ratio, level, extra_decay)]; fm: (ratio, index);
    vibrato: (rate_hz, depth_semitones)."""
    f1 = f0 if f1 is None else f1
    glide = dur if glide is None else glide
    start, n = int(t0 * SR), int(dur * SR)
    partials = partials or [(1.0, 1.0, 0.0)]
    phases = [0.0] * len(partials)
    mod_phase = 0.0
    for i in range(min(n, len(b) - start)):
        t = i / SR
        k = min(1.0, t / glide) if glide > 0 else 1.0
        f = f0 * (f1 / f0) ** k
        if vibrato:
            f *= 2 ** (vibrato[1] * math.sin(TAU * vibrato[0] * t) / 12)
        env = envelope(i, n, attack, decay)
        mod = 0.0
        if fm:
            mod_phase += TAU * f * fm[0] / SR
            mod = fm[1] * math.exp(-decay * 1.5 * i / n) * math.sin(mod_phase)
        s = 0.0
        for p, (ratio, level, extra) in enumerate(partials):
            phases[p] += TAU * f * ratio / SR
            x = phases[p] + mod
            if wave == "sine":
                v = math.sin(x)
            elif wave == "triangle":
                v = 2 / math.pi * math.asin(math.sin(x))
            else:  # band-limited square
                v, h = 0.0, 1
                while h <= 9 and f * ratio * h < SR / 2.5:
                    v += math.sin(h * x) / h
                    h += 2
                v *= 4 / math.pi
            s += v * level * math.exp(-extra * i / n)
        b[start + i] += gain * env * s


def noise(b, t0, dur, f0, f1=None, q=1.0, kind="bp", gain=0.3, attack=0.004, decay=6.9, seed=7):
    """Filtered noise burst (Chamberlin state-variable filter, swept cutoff)."""
    f1 = f0 if f1 is None else f1
    rng = random.Random(seed)
    start, n = int(t0 * SR), int(dur * SR)
    low = band = 0.0
    damp = 1.0 / q
    for i in range(min(n, len(b) - start)):
        k = i / n
        fc = min(f0 * (f1 / f0) ** k, SR / 6.5)
        g = 2 * math.sin(math.pi * fc / SR)
        x = rng.uniform(-1, 1)
        high = x - low - damp * band
        band += g * high
        low += g * band
        y = {"bp": band, "hp": high, "lp": low}[kind]
        b[start + i] += gain * envelope(i, n, attack, decay) * y


def pluck(b, t0, dur, f, gain=0.4, brightness=0.5, seed=3):
    """Karplus-Strong plucked string."""
    rng = random.Random(seed)
    period = max(2, int(SR / f))
    line = [rng.uniform(-1, 1) for _ in range(period)]
    start, n = int(t0 * SR), int(dur * SR)
    decay = 0.996 - 0.004 * (1 - brightness)
    for i in range(min(n, len(b) - start)):
        j = i % period
        nxt = line[(j + 1) % period]
        out = line[j]
        line[j] = decay * (brightness * out + (1 - brightness) * 0.5 * (out + nxt))
        b[start + i] += gain * out * min(1.0, (n - i) / (0.01 * SR))


def echo(b, delay, feedback, wet):
    d = int(delay * SR)
    line = [0.0] * len(b)
    for i in range(len(b)):
        delayed = line[i - d] if i >= d else 0.0
        line[i] = b[i] + feedback * delayed
        b[i] += wet * delayed
    return b


def normalize(b, peak=0.7):
    m = max((abs(x) for x in b), default=0.0)
    if m > 0:
        scale = peak / m
        for i in range(len(b)):
            b[i] *= scale
    return b


def write_wav(path, b):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, x)) * 32767)) for x in b
        ))


def notes(*names):
    """Note names such as 'C6' or 'F#5' to Hz."""
    index = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    out = []
    for name in names:
        letter, rest = name[0], name[1:]
        shift = 0
        if rest.startswith("#"):
            shift, rest = 1, rest[1:]
        elif rest.startswith("b"):
            shift, rest = -1, rest[1:]
        semis = index[letter] + shift + (int(rest) - 4) * 12
        out.append(440.0 * 2 ** (semis / 12))
    return out


# ---- the packs ---------------------------------------------------------------
# Each sound is a function returning a sample buffer. Start sounds stay short
# because the microphone is opening while they play.

def bell(f, gain=0.3, dur=0.7):
    def render(b, t0=0.0):
        tone(b, t0, dur, f, gain=gain, decay=5,
             partials=[(1, 1, 0), (2.0, 0.35, 3), (2.76, 0.2, 5), (5.4, 0.08, 8)])
    return render


def marimba(b, t0, f, gain=0.35):
    tone(b, t0, 0.35, f, gain=gain, decay=9, partials=[(1, 1, 0), (4.0, 0.25, 14), (9.2, 0.06, 20)])


def kalimba(b, t0, f, gain=0.35):
    tone(b, t0, 0.5, f, gain=gain, decay=7, partials=[(1, 1, 0), (7.0, 0.2, 25), (3.0, 0.05, 15)])


def ep(b, t0, f, gain=0.18, dur=0.7):
    tone(b, t0, dur, f, gain=gain, decay=4.5, vibrato=(5.5, 0.04),
         partials=[(1, 1, 0), (2, 0.3, 3), (3, 0.08, 6)])


def wood(b, t0, f, gain=0.4):
    tone(b, t0, 0.09, f, gain=gain, decay=14, attack=0.001, partials=[(1, 1, 0), (2.4, 0.4, 10)])
    noise(b, t0, 0.02, f * 2, q=4, gain=0.3, attack=0.001, decay=8)


def bowl(b, t0, f, gain=0.25, dur=1.0):
    tone(b, t0, dur, f, gain=gain, attack=0.01, decay=4, vibrato=(3.2, 0.03),
         partials=[(1, 1, 0), (2.71, 0.45, 2), (5.15, 0.2, 4), (8.43, 0.06, 6)])


def click(b, t0, gain=0.5):
    noise(b, t0, 0.012, 3000, kind="hp", gain=gain, attack=0.0005, decay=6)


def chip(b, t0, f, dur=0.08, gain=0.12):
    tone(b, t0, dur, f, wave="square", gain=gain, attack=0.001, decay=2)


def with_buffer(seconds, *steps, fx=None):
    def render():
        b = buf(seconds)
        for step in steps:
            step(b)
        if fx:
            fx(b)
        return b
    return render


PACKS = [
    ("pop", "Pop", "Round bubble pops that bend up to start and down to stop. Made for Notch Island.", {
        "start": with_buffer(0.18, lambda b: tone(b, 0, 0.14, 280, 900, glide=0.08, gain=0.6, attack=0.002)),
        "stop": with_buffer(0.18, lambda b: tone(b, 0, 0.14, 900, 280, glide=0.08, gain=0.6, attack=0.002)),
        "done": with_buffer(0.12, lambda b: tone(b, 0, 0.07, 1200, 1500, gain=0.4, attack=0.002)),
        "error": with_buffer(0.4, lambda b: tone(b, 0, 0.16, 420, 200, gain=0.5, attack=0.002),
                             lambda b: tone(b, 0.16, 0.18, 340, 160, gain=0.5, attack=0.002)),
    }),
    ("soft-bell", "Soft Bell", "A clear bell to start, a lower bell to stop, a small chime when the text lands.", {
        "start": with_buffer(0.75, lambda b: bell(880)(b)),
        "stop": with_buffer(0.75, lambda b: bell(659.25)(b)),
        "done": with_buffer(0.6, lambda b: bell(1046.5, 0.2, 0.45)(b), lambda b: bell(1318.5, 0.18, 0.5)(b, 0.08)),
        "error": with_buffer(0.8, lambda b: bell(440, 0.25)(b), lambda b: bell(415.3, 0.25)(b, 0.12)),
    }),
    ("pluck", "Pluck", "Two plucked string notes, going up to start and down to stop.", {
        "start": with_buffer(0.5, lambda b: pluck(b, 0, 0.4, 523.25), lambda b: pluck(b, 0.07, 0.43, 783.99, seed=4)),
        "stop": with_buffer(0.5, lambda b: pluck(b, 0, 0.4, 783.99), lambda b: pluck(b, 0.07, 0.43, 523.25, seed=4)),
        "done": with_buffer(0.4, lambda b: pluck(b, 0, 0.4, 1046.5, brightness=0.7)),
        "error": with_buffer(0.5, lambda b: pluck(b, 0, 0.5, 196, brightness=0.2)),
    }),
    ("whoosh", "Whoosh", "Soft air that rises to start and falls to stop.", {
        "start": with_buffer(0.4, lambda b: noise(b, 0, 0.38, 500, 4200, q=1.6, gain=0.9, attack=0.12, decay=3)),
        "stop": with_buffer(0.4, lambda b: noise(b, 0, 0.38, 4200, 500, q=1.6, gain=0.9, attack=0.12, decay=3)),
        "done": with_buffer(0.1, lambda b: noise(b, 0, 0.08, 3000, q=3, gain=0.8, attack=0.004)),
        "error": with_buffer(0.5, lambda b: noise(b, 0, 0.45, 900, 250, q=2, kind="lp", gain=1.2, attack=0.05, decay=4)),
    }),
    ("shimmer", "Shimmer", "A fast four-note arpeggio with a light echo. Up to start, down to stop.", {
        "start": with_buffer(1.1, *[(lambda f, i: lambda b: tone(b, i * 0.06, 0.6, f, gain=0.15))(f, i)
                                   for i, f in enumerate(notes("C5", "E5", "G5", "B5"))],
                             fx=lambda b: echo(b, 0.16, 0.38, 0.5)),
        "stop": with_buffer(1.1, *[(lambda f, i: lambda b: tone(b, i * 0.06, 0.6, f, gain=0.15))(f, i)
                                  for i, f in enumerate(notes("B5", "G5", "E5", "C5"))],
                            fx=lambda b: echo(b, 0.16, 0.38, 0.5)),
        "done": with_buffer(0.8, lambda b: tone(b, 0, 0.4, notes("E6")[0], gain=0.12),
                            lambda b: tone(b, 0.07, 0.4, notes("G6")[0], gain=0.12),
                            fx=lambda b: echo(b, 0.16, 0.35, 0.45)),
        "error": with_buffer(0.9, lambda b: tone(b, 0, 0.5, notes("E5")[0], gain=0.15),
                             lambda b: tone(b, 0.1, 0.5, notes("Eb5")[0], gain=0.15),
                             fx=lambda b: echo(b, 0.16, 0.3, 0.4)),
    }),
    ("tape", "Tape Deck", "The clunk of a record button. One click to start, two to stop.", {
        "start": with_buffer(0.12, lambda b: click(b, 0), lambda b: tone(b, 0, 0.09, 140, 60, gain=0.6, attack=0.001)),
        "stop": with_buffer(0.2, lambda b: click(b, 0), lambda b: tone(b, 0, 0.08, 140, 60, gain=0.5, attack=0.001),
                            lambda b: click(b, 0.08), lambda b: tone(b, 0.08, 0.08, 140, 60, gain=0.5, attack=0.001)),
        "done": with_buffer(0.05, lambda b: click(b, 0, 0.4)),
        "error": with_buffer(0.35, lambda b: tone(b, 0, 0.3, 110, 70, gain=0.6, attack=0.002, decay=4),
                             lambda b: click(b, 0)),
    }),
    ("power-up", "Power Up", "A short retro synth rise to start and a fall to stop.", {
        "start": with_buffer(0.22, lambda b: tone(b, 0, 0.2, 220, 880, wave="square", gain=0.12, decay=2)),
        "stop": with_buffer(0.22, lambda b: tone(b, 0, 0.2, 880, 220, wave="square", gain=0.12, decay=2)),
        "done": with_buffer(0.18, lambda b: chip(b, 0, 660, 0.06), lambda b: chip(b, 0.07, 990, 0.08)),
        "error": with_buffer(0.35, lambda b: tone(b, 0, 0.32, 180, 90, wave="square", gain=0.12, decay=2)),
    }),
    ("sonar", "Sonar", "A sonar ping with a long echo. High to start, lower to stop.", {
        "start": with_buffer(1.3, lambda b: tone(b, 0, 0.5, 1400, gain=0.35, attack=0.003, decay=5),
                             fx=lambda b: echo(b, 0.18, 0.4, 0.55)),
        "stop": with_buffer(1.3, lambda b: tone(b, 0, 0.5, 980, gain=0.35, attack=0.003, decay=5),
                            fx=lambda b: echo(b, 0.18, 0.4, 0.55)),
        "done": with_buffer(0.6, lambda b: tone(b, 0, 0.2, 1760, gain=0.2, attack=0.003),
                            fx=lambda b: echo(b, 0.12, 0.3, 0.4)),
        "error": with_buffer(1.0, lambda b: tone(b, 0, 0.45, 520, 470, gain=0.35, attack=0.003, decay=5),
                             fx=lambda b: echo(b, 0.2, 0.35, 0.5)),
    }),
    ("marimba", "Marimba", "Warm wooden mallet notes. Two up, two down, a small run when the text lands.", {
        "start": with_buffer(0.45, lambda b: marimba(b, 0, notes("G5")[0]), lambda b: marimba(b, 0.07, notes("C6")[0])),
        "stop": with_buffer(0.45, lambda b: marimba(b, 0, notes("C6")[0]), lambda b: marimba(b, 0.07, notes("G5")[0])),
        "done": with_buffer(0.5, *[(lambda f, i: lambda b: marimba(b, i * 0.05, f, 0.28))(f, i)
                                  for i, f in enumerate(notes("C6", "E6", "G6"))]),
        "error": with_buffer(0.5, lambda b: marimba(b, 0, notes("E4")[0]), lambda b: marimba(b, 0.1, notes("Eb4")[0])),
    }),
    ("glass", "Glass", "Small glassy tinkles, like tapping a wine glass.", {
        "start": with_buffer(0.5, lambda b: tone(b, 0, 0.45, 2093, gain=0.25, attack=0.001, decay=7, fm=(1.41, 2.5))),
        "stop": with_buffer(0.5, lambda b: tone(b, 0, 0.45, 1568, gain=0.25, attack=0.001, decay=7, fm=(1.41, 2.5))),
        "done": with_buffer(0.5, lambda b: tone(b, 0, 0.3, 2637, gain=0.18, attack=0.001, decay=8, fm=(1.41, 2)),
                            lambda b: tone(b, 0.08, 0.35, 3136, gain=0.15, attack=0.001, decay=8, fm=(1.41, 2))),
        "error": with_buffer(0.6, lambda b: tone(b, 0, 0.55, 740, gain=0.3, attack=0.001, decay=6, fm=(1.41, 4))),
    }),
    ("droplet", "Droplet", "Water drops. A drip up to start, a drop down to stop.", {
        "start": with_buffer(0.12, lambda b: tone(b, 0, 0.09, 600, 1800, glide=0.03, gain=0.6, attack=0.001, decay=8)),
        "stop": with_buffer(0.12, lambda b: tone(b, 0, 0.09, 1600, 500, glide=0.04, gain=0.6, attack=0.001, decay=8)),
        "done": with_buffer(0.2, lambda b: tone(b, 0, 0.07, 900, 2400, glide=0.025, gain=0.45, attack=0.001, decay=8),
                            lambda b: tone(b, 0.09, 0.07, 1100, 2800, glide=0.025, gain=0.4, attack=0.001, decay=8)),
        "error": with_buffer(0.2, lambda b: tone(b, 0, 0.16, 380, 150, glide=0.08, gain=0.6, attack=0.001, decay=6)),
    }),
    ("typewriter", "Typewriter", "A key strike to start, the carriage to stop, the little bell when the text lands.", {
        "start": with_buffer(0.08, lambda b: click(b, 0, 0.6), lambda b: tone(b, 0, 0.05, 220, 120, gain=0.4, attack=0.0005)),
        "stop": with_buffer(0.3, lambda b: noise(b, 0, 0.22, 1800, 900, q=2, gain=0.4, attack=0.02, decay=3),
                            lambda b: click(b, 0.22, 0.6)),
        "done": with_buffer(0.7, lambda b: tone(b, 0, 0.65, 2093, gain=0.25, attack=0.001, decay=5,
                                                partials=[(1, 1, 0), (2.76, 0.3, 4), (5.4, 0.1, 8)])),
        "error": with_buffer(0.25, lambda b: click(b, 0, 0.5), lambda b: tone(b, 0, 0.08, 120, 70, gain=0.5),
                             lambda b: click(b, 0.12, 0.5), lambda b: tone(b, 0.12, 0.08, 110, 65, gain=0.5)),
    }),
    ("kalimba", "Kalimba", "Thumb-piano notes with a bright metallic ring.", {
        "start": with_buffer(0.6, lambda b: kalimba(b, 0, notes("E5")[0]), lambda b: kalimba(b, 0.08, notes("A5")[0])),
        "stop": with_buffer(0.6, lambda b: kalimba(b, 0, notes("A5")[0]), lambda b: kalimba(b, 0.08, notes("E5")[0])),
        "done": with_buffer(0.6, lambda b: kalimba(b, 0, notes("C6")[0], 0.28), lambda b: kalimba(b, 0.07, notes("E6")[0], 0.28)),
        "error": with_buffer(0.65, lambda b: kalimba(b, 0, notes("A4")[0]), lambda b: kalimba(b, 0.1, notes("G#4")[0])),
    }),
    ("blip", "Blip", "Tiny pure tones. The most neutral choice.", {
        "start": with_buffer(0.06, lambda b: tone(b, 0, 0.045, 1320, gain=0.35, attack=0.002, decay=3)),
        "stop": with_buffer(0.06, lambda b: tone(b, 0, 0.045, 990, gain=0.35, attack=0.002, decay=3)),
        "done": with_buffer(0.12, lambda b: tone(b, 0, 0.04, 1320, gain=0.3, attack=0.002, decay=3),
                            lambda b: tone(b, 0.06, 0.04, 1760, gain=0.3, attack=0.002, decay=3)),
        "error": with_buffer(0.2, lambda b: tone(b, 0, 0.07, 440, gain=0.35, attack=0.002, decay=2),
                             lambda b: tone(b, 0.1, 0.08, 330, gain=0.35, attack=0.002, decay=2)),
    }),
    ("woodblock", "Wood Block", "Hollow wooden knocks. High to start, low to stop.", {
        "start": with_buffer(0.1, lambda b: wood(b, 0, 1100)),
        "stop": with_buffer(0.1, lambda b: wood(b, 0, 780)),
        "done": with_buffer(0.18, lambda b: wood(b, 0, 1100, 0.3), lambda b: wood(b, 0.07, 1400, 0.3)),
        "error": with_buffer(0.3, lambda b: wood(b, 0, 420), lambda b: wood(b, 0.09, 400), lambda b: wood(b, 0.18, 380)),
    }),
    ("harp", "Harp", "A quick harp sweep, up to start and down to stop.", {
        "start": with_buffer(0.75, *[(lambda f, i: lambda b: pluck(b, i * 0.035, 0.5, f, gain=0.25, brightness=0.6, seed=i))(f, i)
                                    for i, f in enumerate(notes("C5", "D5", "E5", "G5", "A5", "C6"))]),
        "stop": with_buffer(0.75, *[(lambda f, i: lambda b: pluck(b, i * 0.035, 0.5, f, gain=0.25, brightness=0.6, seed=i))(f, i)
                                   for i, f in enumerate(notes("C6", "A5", "G5", "E5", "D5", "C5"))]),
        "done": with_buffer(0.6, *[(lambda f, i: lambda b: pluck(b, i * 0.05, 0.45, f, gain=0.25, brightness=0.7, seed=i))(f, i)
                                  for i, f in enumerate(notes("G5", "C6", "E6"))]),
        "error": with_buffer(0.6, lambda b: pluck(b, 0, 0.5, notes("E3")[0], brightness=0.2),
                             lambda b: pluck(b, 0.1, 0.5, notes("Eb3")[0], brightness=0.2, seed=9)),
    }),
    ("cosmic", "Cosmic", "Sci-fi sweeps with a little wobble.", {
        "start": with_buffer(0.35, lambda b: tone(b, 0, 0.3, 300, 1200, gain=0.3, decay=3, fm=(0.5, 1.5), vibrato=(18, 0.4))),
        "stop": with_buffer(0.35, lambda b: tone(b, 0, 0.3, 1200, 300, gain=0.3, decay=3, fm=(0.5, 1.5), vibrato=(18, 0.4))),
        "done": with_buffer(0.4, lambda b: tone(b, 0, 0.3, 1800, 2600, gain=0.2, decay=5, fm=(2.01, 1.2)),
                            fx=lambda b: echo(b, 0.09, 0.3, 0.4)),
        "error": with_buffer(0.5, lambda b: tone(b, 0, 0.45, 220, 140, gain=0.35, decay=3, vibrato=(9, 1.2))),
    }),
    ("keys", "Electric Piano", "Soft electric piano chords, rolled up to start and down to stop.", {
        "start": with_buffer(0.85, *[(lambda f, i: lambda b: ep(b, i * 0.03, f))(f, i)
                                    for i, f in enumerate(notes("C5", "E5", "G5", "B5"))]),
        "stop": with_buffer(0.85, *[(lambda f, i: lambda b: ep(b, i * 0.03, f))(f, i)
                                   for i, f in enumerate(notes("B4", "G4", "E4", "C4"))]),
        "done": with_buffer(0.6, lambda b: ep(b, 0, notes("G5")[0], 0.22, 0.5), lambda b: ep(b, 0, notes("D6")[0], 0.14, 0.5)),
        "error": with_buffer(0.85, *[(lambda f, i: lambda b: ep(b, i * 0.03, f))(f, i)
                                    for i, f in enumerate(notes("A3", "C4", "E4"))]),
    }),
    ("arcade", "Arcade", "8-bit chiptune. The pasted sound is a coin.", {
        "start": with_buffer(0.16, lambda b: chip(b, 0, notes("C6")[0], 0.06), lambda b: chip(b, 0.06, notes("G6")[0], 0.08)),
        "stop": with_buffer(0.16, lambda b: chip(b, 0, notes("G6")[0], 0.06), lambda b: chip(b, 0.06, notes("C6")[0], 0.08)),
        "done": with_buffer(0.35, lambda b: chip(b, 0, notes("B5")[0], 0.07), lambda b: chip(b, 0.07, notes("E6")[0], 0.25)),
        "error": with_buffer(0.4, *[(lambda f, i: lambda b: chip(b, i * 0.09, f, 0.09))(f, i)
                                   for i, f in enumerate(notes("E4", "C#4", "A#3", "G3"))]),
    }),
    ("thump", "Soft Thump", "Low, felt-like thumps you feel more than hear.", {
        "start": with_buffer(0.15, lambda b: tone(b, 0, 0.13, 130, 60, gain=0.9, attack=0.002, decay=5),
                             lambda b: click(b, 0, 0.08)),
        "stop": with_buffer(0.25, lambda b: tone(b, 0, 0.1, 120, 60, gain=0.8, attack=0.002, decay=5),
                            lambda b: tone(b, 0.11, 0.12, 120, 55, gain=0.8, attack=0.002, decay=5)),
        "done": with_buffer(0.12, lambda b: tone(b, 0, 0.1, 220, 120, gain=0.6, attack=0.002, decay=6)),
        "error": with_buffer(0.4, lambda b: tone(b, 0, 0.35, 90, 45, gain=1.0, attack=0.002, decay=4)),
    }),
    ("chirp", "Chirp", "Quick bird-like chirps. Up to start, down to stop, a trill when the text lands.", {
        "start": with_buffer(0.12, lambda b: tone(b, 0, 0.06, 2000, 3600, gain=0.3, attack=0.002, decay=3),
                             lambda b: tone(b, 0.06, 0.05, 2400, 3800, gain=0.25, attack=0.002, decay=3)),
        "stop": with_buffer(0.12, lambda b: tone(b, 0, 0.07, 3600, 1800, gain=0.3, attack=0.002, decay=3)),
        "done": with_buffer(0.25, lambda b: tone(b, 0, 0.22, 3000, gain=0.22, attack=0.002, decay=3, vibrato=(30, 2))),
        "error": with_buffer(0.3, lambda b: tone(b, 0, 0.25, 900, 700, gain=0.3, attack=0.002, decay=3, vibrato=(12, 1.5))),
    }),
    ("bowl", "Singing Bowl", "A calm metal bowl with a long, gentle ring.", {
        "start": with_buffer(1.0, lambda b: bowl(b, 0, 660)),
        "stop": with_buffer(1.0, lambda b: bowl(b, 0, 495)),
        "done": with_buffer(0.6, lambda b: bowl(b, 0, 990, 0.16, 0.55)),
        "error": with_buffer(1.0, lambda b: bowl(b, 0, 300, 0.3)),
    }),
    ("whisper-click", "Faint Click", "Almost nothing: a faint tick at each step.", {
        "start": with_buffer(0.03, lambda b: click(b, 0, 0.3)),
        "stop": with_buffer(0.1, lambda b: click(b, 0, 0.3), lambda b: click(b, 0.06, 0.25)),
        "done": with_buffer(0.03, lambda b: click(b, 0, 0.2)),
        "error": with_buffer(0.12, lambda b: tone(b, 0, 0.1, 200, gain=0.3, decay=4)),
    }),
]

# Sounds that ship with macOS. Played straight from /System/Library/Sounds.
SYSTEM = "/System/Library/Sounds/{}.aiff"
SYSTEM_PACKS = [
    ("mac-classic", "macOS Classic", "Built-in Mac sounds: Tink, Pop, Glass, Basso.",
     {"start": "Tink", "stop": "Pop", "done": "Glass", "error": "Basso"}),
    ("mac-bright", "macOS Bright", "Built-in Mac sounds: Morse, Bottle, Hero, Funk.",
     {"start": "Morse", "stop": "Bottle", "done": "Hero", "error": "Funk"}),
    ("mac-deep", "macOS Deep", "Built-in Mac sounds: Purr, Submarine, Ping, Sosumi.",
     {"start": "Purr", "stop": "Submarine", "done": "Ping", "error": "Sosumi"}),
]

DEFAULT_PACK = "pop"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: generate.py <output-dir>")
    out = sys.argv[1]
    index = {"default": DEFAULT_PACK, "transitions": list(TRANSITIONS), "packs": []}
    for pack_id, name, description, sounds in PACKS:
        os.makedirs(os.path.join(out, pack_id), exist_ok=True)
        files = {}
        for transition in TRANSITIONS:
            path = os.path.join(pack_id, transition + ".wav")
            write_wav(os.path.join(out, path), normalize(sounds[transition]()))
            files[transition] = path
        index["packs"].append({"id": pack_id, "name": name, "description": description, "files": files})
    for pack_id, name, description, sounds in SYSTEM_PACKS:
        files = {t: SYSTEM.format(sounds[t]) for t in TRANSITIONS if os.path.exists(SYSTEM.format(sounds[t]))}
        if len(files) == len(TRANSITIONS):
            index["packs"].append({"id": pack_id, "name": name, "description": description, "files": files})
    with open(os.path.join(out, "packs.json"), "w") as f:
        json.dump(index, f, indent=2)
    print(f"{len(index['packs'])} sound packs → {out}")


if __name__ == "__main__":
    main()
