#!/usr/bin/env python3
"""Round 3 sounds: rain, wind gusts, thunder, the radio tuning burst and four car radio stations.

    python3 audio/tools/synth_round3.py                 # everything
    python3 audio/tools/synth_round3.py --only weather
    python3 audio/tools/synth_round3.py --only radio

Builds on the helpers and instruments in synth_audio.py. Every group has its own seed, so
regenerating one leaves the others byte-identical. All output is original and CC0.
"""
import argparse

import numpy as np
from scipy import signal

import synth_audio as S
from synth_audio import (SR, add_at, adsr, brown, cfilt, circ_reverb, env_exp, fade, filt, fm_bell, midi,
                         n_of, pan, pink, softclip, stereo_noise, tt, white, write)


def R():
    """The shared random generator, as seeded by S._seeded()."""
    return S.rng


# ----------------------------------------------------------------- weather ---

AMB_SEC = 24.0


def drops(n, rate, f_lo, f_hi, tau, level):
    """Random droplet plinks scattered around the stereo field, wrapped so the loop is seamless."""
    x = np.zeros((n, 2))
    count = int(rate * n / SR)
    for _ in range(count):
        m = n_of(tau * 6)
        tm = tt(m)
        f = R().uniform(f_lo, f_hi)
        d = np.sin(2 * np.pi * f * tm * (1 + 0.5 * np.exp(-tm / 0.004))) * np.exp(-tm / tau)
        d += 0.6 * filt(white(m), "highpass", 3000) * np.exp(-tm / 0.0015)
        add_at(x, pan(d * level * R().uniform(0.3, 1.0), R().uniform(-1, 1)), R().integers(0, n))
    return x


def amb_rain(heavy):
    n = n_of(AMB_SEC)
    t = tt(n)
    base = stereo_noise(pink, n, 0.2)
    swell = 1.0 + 0.12 * np.sin(2 * np.pi * t * 3 / AMB_SEC) + 0.08 * np.sin(2 * np.pi * t * 7 / AMB_SEC + 1)
    hiss = cfilt(base, "bandpass", [1500, 11000] if heavy else [2500, 12000]) * swell[:, None]
    body = cfilt(base, "bandpass", [250, 1500]) * (0.9 if heavy else 0.35)
    x = hiss + body
    x += drops(n, 260 if heavy else 70, 1800, 5000, 0.006, 0.9 if heavy else 1.4)
    x += drops(n, 40 if heavy else 12, 500, 1400, 0.02, 0.6)  # bigger drops on puddles and cars
    if heavy:
        x += 0.5 * cfilt(stereo_noise(brown, n, 0.6), "lowpass", 220)
    return x


def amb_rain_roof():
    """Rain drumming on a car roof: dense, close and dull."""
    n = n_of(AMB_SEC)
    x = 0.5 * cfilt(stereo_noise(pink, n, 0.8), "bandpass", [300, 3000])
    taps = np.zeros(n)
    hits = R().integers(0, n, int(380 * AMB_SEC))
    np.add.at(taps, hits, R().uniform(0.2, 1.0, len(hits)))
    m = n_of(0.03)
    k = np.sin(2 * np.pi * 420 * tt(m)) * np.exp(-tt(m) / 0.006)
    drum = np.fft.irfft(np.fft.rfft(taps) * np.fft.rfft(k, n), n)  # circular, so it loops
    x += pan(cfilt(drum, "lowpass", 2500) * 0.5, 0)
    return x


def amb_gusts():
    """Gusty wind that whistles round corners. Strong, uneven swells with quiet gaps."""
    n = n_of(AMB_SEC)
    t = tt(n)
    g = np.zeros(n)
    for k, ph in [(1, 0.3), (2, 1.7), (3, 4.1), (5, 2.2)]:
        g += np.sin(2 * np.pi * t * k / AMB_SEC + ph) / k
    g = np.clip((g - g.min()) / (g.max() - g.min()), 0, 1) ** 2.2
    base = stereo_noise(pink, n, 0.3)
    rush = cfilt(base, "bandpass", [120, 1400]) * g[:, None]
    # Whistle: a narrow band whose centre rides the gust.
    w = np.zeros((n, 2))
    blk = 2048
    src = cfilt(stereo_noise(white, n, 0.2), "bandpass", [500, 2000])
    for s in range(0, n, blk):
        e = min(s + blk, n)
        fc = 650 + 700 * g[s]
        sos = signal.butter(2, [fc * 0.94, fc * 1.06], btype="bandpass", fs=SR, output="sos")
        seg = np.concatenate([src[max(s - 4096, 0):s], src[s:e]])
        w[s:e] = signal.sosfilt(sos, seg, axis=0)[-(e - s):]
    w *= (g ** 1.5)[:, None] * 0.9
    x = rush + w
    return cfilt(x, "highpass", 60)


def thunder(seed_shift, dur=7.5, crack=1.0):
    n = n_of(dur)
    t = tt(n)
    x = np.zeros(n)
    # Crack: a burst of bright noise with a few stuttering sub-strikes.
    for k, d in enumerate([0.0, 0.05, 0.13, 0.21][: 2 + seed_shift % 3]):
        s = n_of(d)
        m = n_of(0.25)
        add_at(x, crack * filt(white(m), "bandpass", [700, 6000]) * np.exp(-tt(m) / 0.04) * (0.9 ** k), s, wrap=False)
    # Rolling rumble: brown noise with lumpy echoes off hills and towers.
    roll = filt(brown(n), "lowpass", 180)
    e = np.zeros(n)
    tpos = 0.15
    while tpos < dur - 0.5:
        a = R().uniform(0.3, 1.0) * np.exp(-tpos / 2.4)
        s = n_of(tpos)
        m = n - s
        e[s:] += a * np.exp(-tt(m) / R().uniform(0.25, 0.8)) * np.clip(tt(m) / 0.08, 0, 1)
        tpos += R().uniform(0.15, 0.7)
    x += 2.2 * roll * e
    x += 0.5 * filt(brown(n), "bandpass", [40, 120]) * np.exp(-t / 2.0)
    x = softclip(x / np.max(np.abs(x)) * 1.4, 1.3)
    st = np.stack([x, np.roll(x, n_of(0.012)) * 0.95], axis=1)
    return fade(st, 0.001, 1.0)


def radio_tune():
    """Turning the dial: static with a whistle sliding through stations."""
    n = n_of(0.55)
    t = tt(n)
    nz = filt(white(n), "bandpass", [400, 5000])
    am = 0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 37 * t + 2 * np.sin(2 * np.pi * 9 * t)))
    f = 3200 * np.exp(-t * 3.5) + 500
    wh = np.sin(2 * np.pi * np.cumsum(f) / SR) * 0.35
    x = (nz * am * 0.6 + wh) * adsr(n, 0.005, 0.1, 0.8, 0.15)
    return fade(x, 0.002, 0.05)


def weather():
    old = S._seeded(5150)
    write("ambience/amb_rain_light.ogg", amb_rain(False), rms=0.08)
    write("ambience/amb_rain_heavy.ogg", amb_rain(True), rms=0.12)
    write("ambience/amb_rain_roof.ogg", amb_rain_roof(), rms=0.09)
    write("ambience/amb_gusts.ogg", amb_gusts(), rms=0.10)
    write("sfx/thunder_1.ogg", thunder(1), peak=0.9)
    write("sfx/thunder_2.ogg", thunder(2, 9.0, 0.6), peak=0.85)
    write("sfx/radio_tune.ogg", radio_tune(), peak=0.6)
    S.rng = old


def bus_stop():
    """A bus pulling in: brake squeal, the air-brake "pssh", then the doors hissing open."""
    n = n_of(3.2)
    t = tt(n)
    x = np.zeros(n)
    m = n_of(0.7)
    tm = tt(m)
    sq = np.sin(2 * np.pi * np.cumsum(2300 + 120 * np.sin(2 * np.pi * 7 * tm)) / SR)
    x[:m] += 0.25 * sq * adsr(m, 0.05, 0.2, 0.7, 0.2)
    for start, dur, lo, hi, g in [(0.75, 0.6, 1500, 9000, 1.0), (1.6, 0.9, 2500, 11000, 0.6)]:
        s0 = n_of(start)
        k = n_of(dur)
        e = np.clip(tt(k) / 0.01, 0, 1) * np.exp(-tt(k) / (dur * 0.35))
        x[s0:s0 + k] += g * filt(white(k), "bandpass", [lo, hi]) * e
    s0 = n_of(1.65)  # door clunk
    k = n_of(0.15)
    x[s0:s0 + k] += 0.5 * np.sin(2 * np.pi * 90 * tt(k)) * np.exp(-tt(k) / 0.03)
    return fade(x, 0.002, 0.2)


def bus():
    old = S._seeded(6060)
    write("sfx/bus_stop.ogg", bus_stop(), peak=0.8)
    S.rng = old


# ------------------------------------------------------------------- radio ---

class Grid:
    def __init__(self, bpm, swing=0.5):
        self.bpm = bpm
        self.beat = 60.0 / bpm
        self.swing = swing

    def bar(self, b):
        return b * 4 * self.beat

    def at(self, b, s16):
        beat, sub = divmod(s16, 4)
        pair, odd = divmod(sub, 2)
        off = (pair * 2 + (self.swing * 2 if odd else 0)) * self.beat / 4
        return self.bar(b) + beat * self.beat + off

    def n(self, bars):
        return n_of(self.bar(bars))


def saw_stack(f, dur, detune=(-0.1, 0.0, 0.1), cutoff=3000.0, env=(0.01, 0.2, 0.7, 0.1)):
    m = n_of(dur + env[3])
    tm = tt(m)
    y = sum(signal.sawtooth(2 * np.pi * f * 2 ** (d / 12) * tm + R().uniform(0, 6)) for d in detune) / len(detune)
    y = filt(y, "lowpass", min(cutoff, 16000))
    return y * adsr(m, *env)


def square_lead(f, dur, vib=0.005):
    m = n_of(dur + 0.12)
    tm = tt(m)
    v = 1 + vib * np.sin(2 * np.pi * 5.5 * tm) * np.clip(tm / 0.25, 0, 1)
    ph = 2 * np.pi * np.cumsum(f * v) / SR
    y = sum(np.sin(k * ph) / k for k in (1, 3, 5, 7, 9))
    y = filt(y, "lowpass", 4500)
    return y * adsr(m, 0.008, 0.1, 0.75, 0.1)


def sub808(f, dur, glide_from=None):
    m = n_of(dur + 0.05)
    tm = tt(m)
    fr = np.full(m, f)
    if glide_from:
        fr = f + (glide_from - f) * np.exp(-tm / 0.06)
    y = np.sin(2 * np.pi * np.cumsum(fr) / SR)
    y = softclip(y * 1.6, 1.4)
    y[:n_of(0.003)] *= np.linspace(0, 1, n_of(0.003))
    return y * np.exp(-tm / max(dur * 0.9, 0.2)) * np.clip((dur + 0.05 - tm) / 0.05, 0, 1)


def gated_snare():
    m = n_of(0.45)
    tm = tt(m)
    y = S.snare(0.8)
    y = np.pad(y, (0, m - len(y)))
    tail = filt(white(m), "bandpass", [600, 8000]) * np.exp(-tm / 0.6) * 0.6
    gate = np.clip((0.32 - tm) / 0.03, 0, 1)
    return (y + tail) * gate


def hook(chords, scale, bars, seed_rhythms, start=72):
    """A two-bar motif, repeated with a varied answer, anchored to chord tones."""
    out = []
    motif = []
    last = start
    for k, s in enumerate(seed_rhythms):
        choices = [p for p in scale if abs(p - last) <= 5] or scale
        note = int(R().choice(choices))
        motif.append((s, note))
        last = note
    for b in range(0, bars, 2):
        chord = chords[b % len(chords)]
        tones = [c + 12 * k for c in chord for k in (1, 2) if c + 12 * k in scale]
        for i, (s, note) in enumerate(motif):
            if (b // 2) % 2 == 1 and i >= len(motif) // 2:
                note = min(tones or scale, key=lambda x: abs(x - note - 2))  # the answer resolves differently
            ln = (motif[i + 1][0] - s) if i + 1 < len(motif) else 32 - s
            out.append((b + s // 16, s % 16, max(ln, 2), note))
    return out


def jingle(g, style, root):
    """A two-bar station jingle: sweep up, a signature motif, a final chord."""
    n = g.n(2) + n_of(2.0)
    x = np.zeros((n, 2))
    sweep_n = g.n(1)
    sw = filt(white(sweep_n), "bandpass", [600, 9000]) * np.linspace(0, 1, sweep_n) ** 3 * 0.25
    add_at(x, pan(sw, 0), 0, wrap=False)
    if style == "pop":
        motif = [(0, 12), (2, 7), (4, 16), (8, 19)]  # bright "K-M-A-Y" four notes, then 9, 2, 1 blips
        for s, iv in motif:
            add_at(x, pan(fm_bell(midi(root + 24 + iv), 1.2, 2.0, 1.4, 0.5) * 0.35, 0.1), n_of(g.at(1, s)), wrap=False)
            add_at(x, pan(square_lead(midi(root + 12 + iv), g.beat * 0.45) * 0.18, 0.1), n_of(g.at(1, s)), wrap=False)
        for i, iv in enumerate([9, 2, 1]):
            add_at(x, pan(np.sin(2 * np.pi * midi(root + 36 + iv) * tt(n_of(0.08))) * env_exp(n_of(0.08), 0.03) * 0.2, 0.3), n_of(g.at(1, 12) + i * 0.09), wrap=False)
        for c in (0, 4, 7, 12):
            add_at(x, pan(saw_stack(midi(root + 12 + c), g.beat * 1.5, cutoff=5000) * 0.12, 0), n_of(g.at(1, 14)), wrap=False)
    elif style == "lofi":
        for i, c in enumerate([0, 4, 7, 11, 14]):
            add_at(x, pan(S.epiano(midi(root + 12 + c), g.beat * 3, 0.45), -0.4 + 0.2 * i), n_of(g.at(1, 0) + i * 0.06), wrap=False)
        for s, iv in [(8, 19), (11, 16)]:
            add_at(x, pan(fm_bell(midi(root + 24 + iv), 1.5, 3.5, 1.0, 0.6) * 0.25, 0.3), n_of(g.at(1, s)), wrap=False)
        add_at(x, np.stack([S.vinyl(n), S.vinyl(n)], axis=1) * 3, 0, wrap=False)
    elif style == "wave":
        for s in range(0, 16):
            add_at(x, pan(S.pluck(midi(root + 24 + [0, 7, 12, 15][s % 4]), 0.2) * 0.25 * (s / 16), 0.4 * np.sin(s)), n_of(g.at(0, s)), wrap=False)
        add_at(x, pan(gated_snare() * 0.9, 0), n_of(g.at(1, 0)), wrap=False)
        add_at(x, pan(S.kick(1.2), 0), n_of(g.at(1, 0)), wrap=False)
        for c in (0, 3, 7, 10):
            add_at(x, pan(saw_stack(midi(root + 12 + c), g.beat * 3, cutoff=2500, env=(0.05, 0.4, 0.8, 0.6)) * 0.13, 0), n_of(g.at(1, 0)), wrap=False)
    elif style == "trap":
        for s in range(8, 16):
            add_at(x, pan(S.hat() * 0.3, 0.3), n_of(g.at(0, s)), wrap=False)
            add_at(x, pan(S.hat() * 0.2, 0.3), n_of(g.at(0, s) + g.beat / 8), wrap=False)
        add_at(x, pan(sub808(midi(root - 12), g.beat * 3, glide_from=midi(root)) * 0.8, 0), n_of(g.at(1, 0)), wrap=False)
        add_at(x, pan(S.clap() * 0.6, 0), n_of(g.at(1, 0)), wrap=False)
        for s, iv in [(0, 15), (3, 14), (6, 12)]:
            add_at(x, pan(fm_bell(midi(root + 24 + iv), 1.0, 3.0, 1.6, 0.35) * 0.3, -0.2), n_of(g.at(1, s)), wrap=False)
    return circ_reverb(x, 1.6, 0.25, lp=7000)


def song_pop(g, bars, chords, root, scale):
    """KMAY: bright synth-pop. Four on the floor, offbeat hats, pumping chords, square lead hook."""
    n = g.n(bars) + n_of(2.0)
    drm, bas, chd, lead = (np.zeros((n, 2)) for _ in range(4))
    melody = hook(chords, scale, bars, [0, 3, 6, 8, 12, 16, 19, 22, 24])
    for b in range(bars):
        chord = chords[b % len(chords)]
        intro = b < 4
        chorus = (b // 8) % 2 == 1
        for beat in range(4):
            if not intro:
                add_at(drm, pan(S.kick(1.0), 0), n_of(g.at(b, beat * 4)), wrap=False)
            add_at(drm, pan(S.hat(open_=True) * 0.18, 0.25), n_of(g.at(b, beat * 4 + 2)), wrap=False)
        if not intro:
            for s in (4, 12):
                add_at(drm, pan(S.clap() * 0.55, -0.05), n_of(g.at(b, s)), wrap=False)
            for s in range(0, 16, 2):
                add_at(drm, pan(S.shaker() * 0.15, -0.3), n_of(g.at(b, s + 1)), wrap=False)
        for s in range(0, 16, 2):
            iv = 12 if s % 4 == 2 else 0
            add_at(bas, pan(S.bass(midi(chord[0] - 12 + iv), g.beat * 0.45, saw=0.6) * 0.8, 0), n_of(g.at(b, s)), wrap=False)
        for beat in range(4):
            for i, c in enumerate(chord):
                y = saw_stack(midi(c + 12), g.beat * 0.8, cutoff=3500 if chorus else 2200, env=(0.03, 0.15, 0.7, 0.15)) * 0.09
                add_at(chd, pan(y, -0.5 + i / max(len(chord) - 1, 1)), n_of(g.at(b, beat * 4) + 0.02), wrap=False)
    for b, s, ln, note in melody:
        if b < bars and (b // 8) % 2 == 1:
            add_at(lead, pan(square_lead(midi(note), ln * g.beat / 4 * 0.9) * 0.2, 0.1), n_of(g.at(b, s)), wrap=False)
    # Sidechain pump on the chords.
    t = tt(n)
    pump = 0.45 + 0.55 * np.clip(((t % g.beat) / g.beat) * 2.2, 0, 1)
    x = 0.85 * drm + 0.75 * bas + 0.8 * chd * pump[:, None] + 0.9 * lead
    return circ_reverb(x, 1.4, 0.18, lp=8000)


def song_lofi(g, bars, chords, root, scale):
    """Harbor Lo-Fi: dusty swung boom-bap, jazzy electric piano sevenths, a lazy bell tune."""
    n = g.n(bars) + n_of(2.0)
    drm, keys, bas, mel = (np.zeros((n, 2)) for _ in range(4))
    melody = hook(chords, scale, bars, [0, 6, 10, 16, 22, 26])
    for b in range(bars):
        chord = chords[b % len(chords)]
        for s in (0, 7, 10) if b % 2 == 0 else (0, 3, 10):
            add_at(drm, pan(S.kick(0.7) * 0.9, 0), n_of(g.at(b, s)), wrap=False)
        for s in (4, 12):
            add_at(drm, pan(S.snare(0.7) * 0.55, 0.05), n_of(g.at(b, s) + 0.012), wrap=False)
        for s in range(0, 16, 2):
            add_at(drm, pan(S.hat() * (0.22 if s % 4 else 0.12), 0.3), n_of(g.at(b, s)), wrap=False)
        for i, c in enumerate(chord):
            add_at(keys, pan(S.epiano(midi(c), g.beat * 3.2, 0.42), -0.35 + 0.7 * i / len(chord)), n_of(g.at(b, 0) + 0.015 * i), wrap=False)
        add_at(bas, pan(S.bass(midi(chord[0] - 12), g.beat * 2.5) * 0.8, 0), n_of(g.at(b, 0)), wrap=False)
        add_at(bas, pan(S.bass(midi(chord[0] - 5), g.beat * 0.9) * 0.6, 0), n_of(g.at(b, 10)), wrap=False)
    for b, s, ln, note in melody:
        if b < bars and b >= 4 and (b // 4) % 2 == 1:
            add_at(mel, pan(fm_bell(midi(note), 1.6, 3.5, 1.2, 0.5) * 0.18, 0.25), n_of(g.at(b, s)), wrap=False)
    x = 0.8 * drm + 0.75 * keys + 0.7 * bas + mel
    x = filt(x, "lowpass", 5200)
    # Tape wobble: a slow wow, done as a gentle time-varying delay.
    t = tt(n)
    d = (0.0018 * (1 + np.sin(2 * np.pi * 0.6 * t))) * SR
    idx = np.clip(np.arange(n) - d, 0, n - 1)
    lo = idx.astype(int)
    fr = (idx - lo)[:, None]
    hi = np.minimum(lo + 1, n - 1)
    x = x[lo] * (1 - fr) + x[hi] * fr
    x += np.stack([S.vinyl(n), S.vinyl(n)], axis=1) * 2.5
    return circ_reverb(x, 1.8, 0.22, lp=4500)


def song_wave(g, bars, chords, root, scale):
    """Night Drive: synthwave. Rolling sixteenth bass, gated snare, sparkling arp, brassy saw lead."""
    n = g.n(bars) + n_of(2.0)
    drm, bas, arp, pad, lead = (np.zeros((n, 2)) for _ in range(5))
    melody = hook(chords, scale, bars, [0, 4, 8, 14, 16, 20, 24, 28])
    for b in range(bars):
        chord = chords[b % len(chords)]
        intro = b < 4
        if not intro:
            for s in (0, 8):
                add_at(drm, pan(S.kick(1.1), 0), n_of(g.at(b, s)), wrap=False)
            for s in (4, 12):
                add_at(drm, pan(gated_snare() * 0.7, 0), n_of(g.at(b, s)), wrap=False)
            for s in range(0, 16, 2):
                add_at(drm, pan(S.hat() * 0.2, 0.35), n_of(g.at(b, s)), wrap=False)
        for s in range(16):
            add_at(bas, pan(S.bass(midi(chord[0] - 12), g.beat / 4 * 0.8, saw=1.0) * (0.8 if s % 4 == 0 else 0.55), 0), n_of(g.at(b, s)), wrap=False)
        tones = [chord[i % len(chord)] + 24 + (12 if i >= len(chord) else 0) for i in range(len(chord) * 2)]
        for s in range(16):
            add_at(arp, pan(S.pluck(midi(tones[s % len(tones)]), 0.25, 1.4) * 0.22, 0.6 * np.sin(s * 0.9)), n_of(g.at(b, s)), wrap=False)
        add_at(pad, pan(saw_stack(midi(chord[1] + 12), 4 * g.beat, cutoff=1500, env=(0.4, 0.5, 0.8, 0.5)) * 0.15, -0.3), n_of(g.bar(b)), wrap=False)
        add_at(pad, pan(saw_stack(midi(chord[2] + 12), 4 * g.beat, cutoff=1500, env=(0.4, 0.5, 0.8, 0.5)) * 0.15, 0.3), n_of(g.bar(b)), wrap=False)
    for b, s, ln, note in melody:
        if b < bars and (b // 8) % 2 == 1:
            add_at(lead, pan(saw_stack(midi(note), ln * g.beat / 4 * 0.95, cutoff=3200, env=(0.03, 0.2, 0.8, 0.2)) * 0.2, 0.0), n_of(g.at(b, s)), wrap=False)
    x = 0.85 * drm + 0.7 * bas + 0.6 * arp + 0.8 * pad + 0.9 * lead
    return circ_reverb(x, 2.6, 0.3, lp=6500)


def song_trap(g, bars, chords, root, scale):
    """BOOM: trap. Half-time clap, rolling hats, gliding 808s, a dark bell line."""
    n = g.n(bars) + n_of(2.0)
    drm, sub, mel = (np.zeros((n, 2)) for _ in range(3))
    melody = hook(chords, scale, bars, [0, 3, 6, 10, 12, 16, 19, 22, 26])
    for b in range(bars):
        chord = chords[(b // 2) % len(chords)]
        intro = b < 4
        if not intro:
            add_at(drm, pan(S.clap() * 0.7, 0), n_of(g.at(b, 8)), wrap=False)
            add_at(drm, pan(S.snare(1.3) * 0.3, 0), n_of(g.at(b, 8)), wrap=False)
            for s, glide in ((0, None), (6, None), (10, chord[0] + 7)) if b % 2 == 0 else ((0, None), (11, None)):
                f = midi(chord[0] - 12 if s != 10 else chord[0] - 12)
                add_at(sub, pan(sub808(f, g.beat * 1.4, glide_from=midi(glide - 12) if glide else None) * 0.9, 0), n_of(g.at(b, s)), wrap=False)
                add_at(drm, pan(S.kick(0.8) * 0.6, 0), n_of(g.at(b, s)), wrap=False)
        for s in range(0, 16, 2):
            add_at(drm, pan(S.hat() * 0.28, 0.25), n_of(g.at(b, s)), wrap=False)
            if (b % 4 == 3 and s >= 10) or s == 14:  # rolls
                for k in (1, 2, 3):
                    add_at(drm, pan(S.hat() * 0.16, 0.25), n_of(g.at(b, s) + k * g.beat / 6), wrap=False)
        if b % 2 == 0:
            add_at(drm, pan(S.hat(open_=True) * 0.12, -0.3), n_of(g.at(b, 15)), wrap=False)
    for b, s, ln, note in melody:
        if b < bars:
            add_at(mel, pan(fm_bell(midi(note), 1.0, 3.0, 1.6, 0.3) * 0.22, -0.15), n_of(g.at(b, s)), wrap=False)
            add_at(mel, pan(S.pluck(midi(note - 12), 0.3) * 0.08, -0.15), n_of(g.at(b, s)), wrap=False)
    x = 0.85 * drm + 0.85 * sub + 0.9 * mel
    return circ_reverb(x, 1.6, 0.18, lp=7000)


# Station: (file, bpm, swing, style, song fn, [(chords, root, scale) per song], bars per song)
C_MAJ = [60, 62, 64, 67, 69, 72, 74, 76, 79, 81, 84]
A_MIN = [57, 60, 62, 64, 67, 69, 72, 74, 76, 79, 81]
EB_MAJ = [63, 65, 67, 70, 72, 75, 77, 79, 82, 84]
C_MIN = [60, 63, 65, 67, 70, 72, 75, 77, 79, 82, 84]
D_MAJ = [62, 64, 66, 69, 71, 74, 76, 78, 81, 83, 86]
F_MIN = [65, 68, 70, 72, 75, 77, 80, 82, 84, 87]
STATIONS = [
    ("radio_kmay", 112, 0.5, "pop", song_pop, 24, 60, [
        ([[60, 64, 67], [55, 59, 62], [57, 60, 64], [53, 57, 60]], C_MAJ),          # I V vi IV
        ([[62, 66, 69], [59, 62, 66], [55, 59, 62], [57, 61, 64]], D_MAJ),          # I vi IV V in D
    ]),
    ("radio_lofi", 78, 0.6, "lofi", song_lofi, 16, 63, [
        ([[53, 56, 60, 63], [58, 62, 65, 68], [51, 55, 58, 62], [48, 51, 55, 58]], EB_MAJ),   # ii V I vi in Eb
        ([[56, 60, 63, 67], [55, 58, 62, 65], [53, 56, 60, 63], [58, 62, 65, 68]], EB_MAJ),
    ]),
    ("radio_wave", 100, 0.5, "wave", song_wave, 20, 57, [
        ([[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]], A_MIN),          # i VI III VII
        ([[50, 53, 57], [53, 57, 60], [57, 60, 64], [55, 59, 62]], A_MIN),
    ]),
    ("radio_boom", 140, 0.5, "trap", song_trap, 28, 60, [
        ([[48, 51, 55], [44, 48, 51], [41, 44, 48], [43, 47, 50]], C_MIN),          # i VI iv V
        ([[53, 56, 60], [49, 53, 56], [51, 55, 58], [48, 51, 55]], F_MIN),
    ]),
]


def station(file, bpm, swing, style, song_fn, bars, root, songs, seed):
    old = S._seeded(seed)
    g = Grid(bpm, swing)
    total = 2 + bars + 2 + bars
    n = g.n(total)
    out = np.zeros((n, 2))
    pos = 0
    for k, (chords, scale) in enumerate(songs):
        add_at(out, jingle(g, style, root + (0 if k == 0 else 2)), n_of(g.bar(pos)))
        pos += 2
        add_at(out, song_fn(g, bars, chords, chords[0][0], scale), n_of(g.bar(pos)))
        pos += bars
    write(f"music/{file}.ogg", out, rms=0.11)
    S.rng = old


def radio():
    for i, st in enumerate(STATIONS):
        station(*st, seed=1077 + i)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["weather", "bus", "radio"])
    a = ap.parse_args()
    if a.only in (None, "weather"):
        print("weather")
        weather()
    if a.only in (None, "bus"):
        print("bus")
        bus()
    if a.only in (None, "radio"):
        print("radio")
        radio()


if __name__ == "__main__":
    main()
