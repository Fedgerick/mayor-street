#!/usr/bin/env python3
"""Synthesizes every sound and music stem the game uses. No samples, no downloads.

    pip install numpy scipy soundfile
    python3 audio/tools/synth_audio.py            # writes audio/{sfx,ambience,music}/*.ogg
    python3 audio/tools/synth_audio.py --only music

Loops are built circularly (tile, filter, keep the middle copy; reverb by circular
convolution), so every loop point is seamless. All output is original and CC0.
"""
import argparse
import os

import numpy as np
import soundfile as sf
from scipy import signal

SR = 44100
ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
rng = np.random.default_rng(20261003)


# ------------------------------------------------------------------ helpers ---

def n_of(sec):
    return int(round(sec * SR))


def tt(n):
    return np.arange(n) / SR


def white(n):
    return rng.standard_normal(n)


def pink(n):
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.maximum(np.fft.rfftfreq(n, 1 / SR), 20.0)
    x = np.fft.irfft(spec / np.sqrt(f), n)
    return x / (np.std(x) + 1e-9)


def brown(n):
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.maximum(np.fft.rfftfreq(n, 1 / SR), 15.0)
    x = np.fft.irfft(spec / f, n)
    return x / (np.std(x) + 1e-9)


def filt(x, kind, f, order=2):
    sos = signal.butter(order, f, btype=kind, fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=0)


def cfilt(x, kind, f, order=2):
    """Filter a loop circularly so its ends still meet."""
    n = len(x)
    y = filt(np.concatenate([x, x, x]), kind, f, order)
    return y[n:2 * n]


def env_exp(n, tau, attack=0.002):
    t = tt(n)
    e = np.exp(-t / tau)
    a = n_of(attack)
    if a > 0:
        e[:a] *= np.linspace(0, 1, a)
    return e


def adsr(n, a, d, s, r):
    e = np.full(n, s, dtype=float)
    na, nd, nr = n_of(a), n_of(d), n_of(r)
    na = min(na, n)
    e[:na] = np.linspace(0, 1, na, endpoint=False)
    nd = min(nd, n - na)
    e[na:na + nd] = np.linspace(1, s, nd, endpoint=False)
    if nr > 0:
        nr = min(nr, n)
        e[n - nr:] *= np.linspace(1, 0, nr)
    return e


def add_at(buf, x, start, wrap=True):
    """Mix x into buf at sample `start`; wraps around the end for loops."""
    n = len(buf)
    start = int(start) % n if wrap else int(start)
    end = start + len(x)
    if end <= n:
        buf[start:end] += x
    elif wrap:
        k = n - start
        buf[start:] += x[:k]
        rest = x[k:]
        while len(rest) > 0:
            m = min(len(rest), n)
            buf[:m] += rest[:m]
            rest = rest[m:]
    else:
        buf[start:] += x[:n - start]


def pan(x, p):
    """Mono -> stereo, p in [-1, 1], equal power."""
    a = (p + 1) * np.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)], axis=1)


def stereo_noise(fn, n, corr=0.3):
    a, b = fn(n), fn(n)
    return np.stack([a, corr * a + (1 - corr) * b], axis=1)


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def fade(x, fin=0.002, fout=0.01):
    x = x.copy()
    a, b = n_of(fin), n_of(fout)
    if a:
        x[:a] *= np.linspace(0, 1, a)[:, None] if x.ndim == 2 else np.linspace(0, 1, a)
    if b:
        x[-b:] *= np.linspace(1, 0, b)[:, None] if x.ndim == 2 else np.linspace(1, 0, b)
    return x


def softclip(x, drive=1.0):
    return np.tanh(x * drive) / np.tanh(drive)


def norm_peak(x, p=0.9):
    m = np.max(np.abs(x))
    return x * (p / m) if m > 0 else x


def norm_rms(x, r):
    m = np.sqrt(np.mean(x ** 2))
    return x * (r / m) if m > 0 else x


def circ_reverb(x, seconds=2.0, wet=0.25, lp=6000.0, predelay=0.012):
    """Stereo reverb by circular FFT convolution (keeps loops seamless)."""
    n = len(x)
    ni = n_of(seconds)
    ir = np.zeros((ni, 2))
    for c in range(2):
        e = white(ni) * np.exp(-tt(ni) * 6.9 / seconds)
        ir[:, c] = filt(e, "lowpass", lp)
    pd = n_of(predelay)
    ir = np.concatenate([np.zeros((pd, 2)), ir])[:ni]
    ir /= np.sqrt(np.sum(ir ** 2, axis=0, keepdims=True))
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    out = np.zeros_like(x)
    for c in range(2):
        X = np.fft.rfft(x[:, c], n)
        H = np.fft.rfft(ir[:, c], n) if ni <= n else np.fft.rfft(ir[:n, c], n)
        out[:, c] = np.fft.irfft(X * H, n)
    out *= np.sqrt(np.mean(x ** 2)) / (np.sqrt(np.mean(out ** 2)) + 1e-9)
    return x * (1 - wet) + out * wet


def write(rel, x, peak=None, rms=None):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if rms is not None:
        x = norm_rms(x, rms)
    if peak is not None:
        x = norm_peak(x, peak)
    m = np.max(np.abs(x))
    if m > 0.98:
        x = softclip(x / m * 1.1, 1.2) * 0.97
    x = x.astype(np.float32)
    # libsndfile's Vorbis encoder can crash on one huge write, so feed it in blocks.
    with sf.SoundFile(path, "w", SR, 1 if x.ndim == 1 else x.shape[1], format="OGG", subtype="VORBIS") as f:
        for s in range(0, len(x), 1 << 15):
            f.write(x[s:s + (1 << 15)])
    print(f"  {rel:40s} {len(x) / SR:6.2f}s  {os.path.getsize(path) / 1024:7.1f} KB")


# ------------------------------------------------------------ sound effects ---

def fm_bell(f, dur, ratio=3.5, index=2.0, tau=0.5):
    n = n_of(dur)
    t = tt(n)
    ie = index * np.exp(-t / (tau * 0.5))
    x = np.sin(2 * np.pi * f * t + ie * np.sin(2 * np.pi * f * ratio * t))
    return x * env_exp(n, tau)


def marimba(f, dur=0.35):
    n = n_of(dur)
    t = tt(n)
    x = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.12)
    x += 0.35 * np.sin(2 * np.pi * f * 4.0 * t) * np.exp(-t / 0.025)
    x += 0.1 * filt(white(n), "bandpass", [f * 2, min(f * 8, 18000)]) * np.exp(-t / 0.006)
    return x


def sfx_ui():
    n = n_of(0.06)
    t = tt(n)
    click = 0.6 * np.sin(2 * np.pi * 1900 * t) * np.exp(-t / 0.012) + 0.4 * filt(white(n), "highpass", 3000) * np.exp(-t / 0.003)
    write("sfx/ui_click.ogg", fade(click), peak=0.6)

    sel = np.zeros(n_of(0.4))
    add_at(sel, marimba(midi(81)), 0, wrap=False)
    add_at(sel, 0.8 * marimba(midi(88)), n_of(0.06), wrap=False)
    write("sfx/ui_select.ogg", fade(sel), peak=0.6)

    write("sfx/ui_toggle.ogg", fade(marimba(midi(86), 0.25)), peak=0.5)

    # Toast / notification: two soft bells.
    nt = np.zeros(n_of(0.9))
    add_at(nt, fm_bell(midi(84), 0.8, 2.0, 1.2, 0.35), 0, wrap=False)
    add_at(nt, 0.8 * fm_bell(midi(91), 0.7, 2.0, 1.2, 0.35), n_of(0.11), wrap=False)
    write("sfx/notify.ogg", fade(circ_reverb(nt, 0.8, 0.2)), peak=0.55)

    # Error: low, slightly sour double buzz.
    er = np.zeros(n_of(0.45))
    for k, f in enumerate([233.0, 196.0]):
        m = n_of(0.16)
        t = tt(m)
        x = signal.sawtooth(2 * np.pi * f * t) * adsr(m, 0.005, 0.05, 0.6, 0.04)
        add_at(er, filt(x, "lowpass", 1400), n_of(0.18 * k), wrap=False)
    write("sfx/error.ogg", fade(er), peak=0.5)

    # Cash: three coin clinks then a sparkle.
    cs = np.zeros(n_of(1.1))
    for k, f in enumerate([2637, 3136, 3951]):
        add_at(cs, fm_bell(f, 0.5, 1.41, 1.5, 0.12) * 0.7, n_of(0.07 * k), wrap=False)
    add_at(cs, fm_bell(midi(96), 0.9, 2.0, 0.8, 0.4) * 0.5, n_of(0.24), wrap=False)
    write("sfx/cash.ogg", fade(circ_reverb(cs, 0.7, 0.2)), peak=0.6)


def sfx_build():
    # Road: a heavy roller thump and gravel spread.
    n = n_of(0.6)
    t = tt(n)
    thump = np.sin(2 * np.pi * (55 + 60 * np.exp(-t / 0.03)) * t) * np.exp(-t / 0.12)
    gravel = filt(white(n), "bandpass", [400, 3500]) * np.exp(-t / 0.18)
    gravel *= 0.6 + 0.4 * (rng.random(n) > 0.7)
    write("sfx/build_road.ogg", fade(thump + 0.35 * gravel), peak=0.7)

    # Zone: a soft brush swish plus a rising three-note pluck.
    n = n_of(0.7)
    t = tt(n)
    sw = filt(white(n), "bandpass", [1500, 6000]) * np.sin(np.pi * np.clip(t / 0.25, 0, 1)) ** 2
    z = 0.25 * sw
    for k, m in enumerate([72, 76, 79]):
        add_at(z, 0.5 * marimba(midi(m), 0.4), n_of(0.05 + 0.07 * k), wrap=False)
    write("sfx/build_zone.ogg", fade(z), peak=0.6)

    # Bulldoze: crunch, rubble and a low drop.
    n = n_of(1.0)
    t = tt(n)
    drop = np.sin(2 * np.pi * (40 + 50 * np.exp(-t / 0.08)) * t) * np.exp(-t / 0.25)
    crunch = filt(brown(n), "lowpass", 900) * np.exp(-t / 0.3)
    crackles = filt(white(n) * (rng.random(n) > 0.985), "bandpass", [800, 5000]) * np.exp(-t / 0.35) * 4
    write("sfx/bulldoze.ogg", fade(drop + 0.6 * crunch + 0.4 * crackles), peak=0.75)

    # Building finished: wood knock plus a little chime.
    b = np.zeros(n_of(0.8))
    m = n_of(0.08)
    tk = tt(m)
    knock = np.sin(2 * np.pi * 420 * tk) * np.exp(-tk / 0.02) + 0.3 * filt(white(m), "bandpass", [600, 2500]) * np.exp(-tk / 0.01)
    add_at(b, knock, 0, wrap=False)
    add_at(b, 0.45 * fm_bell(midi(88), 0.6, 3.0, 1.0, 0.25), n_of(0.05), wrap=False)
    write("sfx/building_done.ogg", fade(b), peak=0.55)


def whoosh(dur, f_from, f_to, peak_at):
    n = n_of(dur)
    t = tt(n) / dur
    x = stereo_noise(pink, n, 0.5)
    cut = f_from * (f_to / f_from) ** t
    # Time-varying lowpass: process in short blocks.
    out = np.zeros_like(x)
    blk = 512
    zi = [None, None]
    for s in range(0, n, blk):
        c = float(cut[min(s + blk // 2, n - 1)])
        sos = signal.butter(2, [max(c * 0.25, 30), min(c, 18000)], btype="bandpass", fs=SR, output="sos")
        for ch in range(2):
            if zi[ch] is None:
                zi[ch] = signal.sosfilt_zi(sos) * 0
            out[s:s + blk, ch], zi[ch] = signal.sosfilt(sos, x[s:s + blk, ch], zi=zi[ch])
    e = np.where(t < peak_at, (t / peak_at) ** 1.5, ((1 - t) / (1 - peak_at)) ** 2)
    return out * e[:, None]


def sfx_transitions():
    write("sfx/whoosh_down.ogg", fade(whoosh(3.2, 5000, 250, 0.7), 0.01, 0.05), peak=0.6)
    write("sfx/whoosh_up.ogg", fade(whoosh(2.6, 300, 6000, 0.35), 0.01, 0.05), peak=0.6)


def footstep(heavy=1.0):
    n = n_of(0.16)
    t = tt(n)
    heel = filt(white(n), "bandpass", [rng.uniform(250, 400), rng.uniform(2500, 4000)]) * np.exp(-t / rng.uniform(0.012, 0.02))
    thud = np.sin(2 * np.pi * rng.uniform(70, 95) * t) * np.exp(-t / 0.03) * heavy
    scuff = np.zeros(n)
    d = n_of(rng.uniform(0.025, 0.045))
    scuff[d:] = filt(white(n - d), "bandpass", [1500, 7000]) * np.exp(-tt(n - d) / 0.02) * 0.4
    return fade(heel + 0.8 * thud + scuff, 0.001, 0.02)


def sfx_street():
    for i in range(4):
        write(f"sfx/step_{i + 1}.ogg", footstep(), peak=0.55)
    n = n_of(0.3)
    t = tt(n)
    land = np.sin(2 * np.pi * 60 * t) * np.exp(-t / 0.06) + 0.6 * filt(white(n), "bandpass", [200, 3000]) * np.exp(-t / 0.04)
    write("sfx/land.ogg", fade(land), peak=0.7)

    # Car door open: latch click and a short creak.
    n = n_of(0.45)
    t = tt(n)
    latch = filt(white(n), "bandpass", [2000, 7000]) * np.exp(-t / 0.006)
    ring = 0.3 * np.sin(2 * np.pi * 1250 * t) * np.exp(-t / 0.05)
    creak = np.zeros(n)
    d = n_of(0.06)
    m = n - d
    tc = tt(m)
    creak[d:] = 0.15 * filt(signal.sawtooth(2 * np.pi * (180 + 40 * np.sin(2 * np.pi * 3 * tc)) * tc), "bandpass", [600, 2400]) * np.sin(np.pi * tc / tc[-1])
    write("sfx/door_open.ogg", fade(latch + ring + creak), peak=0.6)

    # Car door close: body thunk and latch.
    n = n_of(0.5)
    t = tt(n)
    thunk = np.sin(2 * np.pi * (65 + 40 * np.exp(-t / 0.02)) * t) * np.exp(-t / 0.09)
    body = filt(white(n), "lowpass", 700) * np.exp(-t / 0.05)
    latch = np.zeros(n)
    d = n_of(0.015)
    latch[d:] = filt(white(n - d), "bandpass", [2500, 8000]) * np.exp(-tt(n - d) / 0.004)
    write("sfx/door_close.ogg", fade(thunk + 0.5 * body + 0.5 * latch), peak=0.75)

    # Engine start: starter whir, then the engine catches.
    n = n_of(1.3)
    t = tt(n)
    sm = n_of(0.75)
    ts = tt(sm)
    starter = signal.sawtooth(2 * np.pi * 210 * ts) * (0.55 + 0.45 * np.sin(2 * np.pi * 11 * ts))
    starter = filt(starter, "bandpass", [150, 1800]) * adsr(sm, 0.02, 0.1, 0.8, 0.05)
    x = np.zeros(n)
    x[:sm] += 0.5 * starter
    catch = engine_cycle_train(n - n_of(0.6), 44.1 * 1.6, load=0.8, rough=0.25)
    catch *= np.exp(-tt(len(catch)) / 0.4) * 0.8 + 0.2
    catch *= np.clip(tt(len(catch)) / 0.03, 0, 1)
    x[n_of(0.6):] += catch
    write("sfx/engine_start.ogg", fade(x, 0.005, 0.15), peak=0.7)

    # Crash: low hit, metal clang, glass.
    n = n_of(1.4)
    t = tt(n)
    hit = np.sin(2 * np.pi * (45 + 70 * np.exp(-t / 0.03)) * t) * np.exp(-t / 0.15)
    metal = sum(np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) * np.exp(-t / rng.uniform(0.08, 0.4))
                for f in [311, 523, 787, 1103, 1609, 2311]) / 4
    crunch = filt(brown(n), "lowpass", 1500) * np.exp(-t / 0.12)
    glass = np.zeros(n)
    for _ in range(40):
        g = fm_bell(rng.uniform(3000, 8000), 0.12, rng.uniform(1.2, 2.7), 1.0, 0.03)
        add_at(glass, g * rng.uniform(0.1, 0.4), n_of(rng.uniform(0.02, 0.5) ** 1.5), wrap=False)
    write("sfx/crash.ogg", fade(hit + 0.5 * metal + 0.7 * crunch + 0.5 * glass), peak=0.85)

    # Distant horn: beep-beep, for the city bed.
    n = n_of(0.75)
    h = np.zeros(n)
    for k, d in enumerate([0.0, 0.3]):
        m = n_of(0.22 if k == 0 else 0.32)
        tm = tt(m)
        tone = signal.square(2 * np.pi * 415 * tm) + signal.square(2 * np.pi * 523 * tm)
        add_at(h, filt(tone, "bandpass", [350, 2000]) * adsr(m, 0.01, 0.02, 1, 0.05), n_of(d), wrap=False)
    write("sfx/horn_distant.ogg", fade(filt(h, "lowpass", 1500)), peak=0.5)


def sfx_loops():
    # Player horn, held: 400 + 500 Hz fit a whole number of cycles in 1 s.
    n = SR
    t = tt(n)
    tone = signal.square(2 * np.pi * 400 * t, 0.4) + 0.9 * signal.square(2 * np.pi * 500 * t, 0.4)
    write("sfx/horn_loop.ogg", cfilt(cfilt(tone, "bandpass", [300, 2500]), "lowpass", 3000), peak=0.55)

    # Engine: one cycle = 1000 samples (44.1 Hz firing), 88 cycles a loop.
    write("sfx/engine_idle_loop.ogg", engine_loop(load=0.0), peak=0.7)
    write("sfx/engine_load_loop.ogg", engine_loop(load=1.0), peak=0.7)

    # Tyre roll / road noise.
    n = n_of(2.0)
    roll = cfilt(pink(n), "bandpass", [80, 900])
    roll += 0.3 * cfilt(white(n), "bandpass", [1500, 4000])
    write("sfx/road_roll_loop.ogg", roll, peak=0.6)

    # Skid: narrow squeal that wobbles.
    n = n_of(1.5)
    t = tt(n)
    sq = np.zeros(n)
    for f, a in [(1180, 1.0), (1730, 0.6), (2350, 0.35)]:
        wob = 1 + 0.02 * np.sin(2 * np.pi * 4 * t) + 0.01 * np.sin(2 * np.pi * 9.333 * t)
        ph = 2 * np.pi * np.cumsum(f * wob) / SR
        sq += a * np.sin(ph)
    # Make it seamless: fix phase drift by circular crossfade of a slightly longer render.
    sq = sq * (0.7 + 0.3 * np.sin(2 * np.pi * 2 * t) ** 2)
    sq += 0.5 * cfilt(white(n), "bandpass", [900, 3000])
    write("sfx/skid_loop.ogg", loop_xfade(sq, 0.15), peak=0.55)

    # AI traffic car: soft engine hum plus rolling.
    hum = engine_loop(load=0.2, base_lp=900, rough=0.08)
    m = len(hum)
    car = 0.6 * hum + 0.5 * cfilt(pink(m), "bandpass", [100, 1200])
    write("sfx/traffic_car_loop.ogg", car, peak=0.6)

    # Siren (for emergency jobs): 2 s wail.
    n = n_of(2.0)
    t = tt(n)
    f = 950 + 450 * np.sin(2 * np.pi * 0.5 * t - np.pi / 2)
    ph = 2 * np.pi * np.cumsum(f) / SR
    ph *= np.round(ph[-1] / (2 * np.pi)) * 2 * np.pi / ph[-1]
    s = np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph)
    write("sfx/siren_loop.ogg", cfilt(s, "lowpass", 4000), peak=0.6)


def loop_xfade(x, sec):
    k = n_of(sec)
    n = len(x) - k
    out = x[:n].copy()
    f = np.linspace(0, 1, k)
    out[:k] = x[n:n + k] * np.sqrt(1 - f) + x[:k] * np.sqrt(f)
    return out


def engine_cycle_train(n, f0, load=0.0, rough=0.15):
    """Combustion pulses at f0 with cycle-to-cycle variation (not loop-exact)."""
    x = np.zeros(n)
    per = SR / f0
    k = 0
    while k * per < n:
        m = int(per * 2.5)
        tm = tt(m)
        a = 1 + rough * rng.standard_normal()
        p = np.sin(2 * np.pi * (2.6 * f0) * tm) * np.exp(-tm * f0 * 2.2) * a
        p += (0.3 + 0.6 * load) * white(m) * np.exp(-tm * f0 * 4) * a
        add_at(x, p, int(k * per), wrap=False)
        k += 1
    x = filt(x, "lowpass", 1200 + 1800 * load)
    return x


def engine_loop(load=0.0, base_lp=1300, rough=0.15):
    per = 1000
    cycles = 88
    n = per * cycles
    x = np.zeros(n)
    f0 = SR / per
    for k in range(cycles):
        m = int(per * 2.5)
        tm = tt(m)
        a = 1 + rough * rng.standard_normal()
        p = np.sin(2 * np.pi * (2.6 * f0) * tm) * np.exp(-tm * f0 * 2.2) * a
        p += 0.5 * np.sin(2 * np.pi * (1.0 * f0) * tm) * np.exp(-tm * f0 * 1.0)
        p += (0.25 + 0.7 * load) * white(m) * np.exp(-tm * f0 * 4) * a
        add_at(x, p, k * per)  # wraps: loop exact
    x = cfilt(x, "lowpass", base_lp + 2200 * load)
    x = cfilt(x, "highpass", 30)
    if load > 0.5:
        x = softclip(x / np.max(np.abs(x)) * 1.6, 1.5)
    return x


def sfx_missions():
    """Mission cues (missions/missions.gd). Own seed so regenerating them leaves the rest alone."""
    global rng
    keep, rng = rng, np.random.default_rng(777)

    # Payphone: an old bell ringer, ring-ring ... ring-ring (about 4 s, played once).
    x = np.zeros(n_of(4.2))
    for start in (0.0, 0.6, 2.4, 3.0):
        m = n_of(0.42)
        t = tt(m)
        clapper = 0.5 + 0.5 * signal.square(2 * np.pi * 20 * t)
        bell = sum(a * np.sin(2 * np.pi * f * t) for f, a in [(1180, 1.0), (1470, 0.7), (2350, 0.4), (3300, 0.25)])
        add_at(x, bell * clapper * adsr(m, 0.005, 0.05, 0.9, 0.08), n_of(start), wrap=False)
    x = filt(x, "bandpass", [500, 5000])
    write("sfx/phone_ring.ogg", fade(circ_reverb(x, 0.6, 0.15)), peak=0.6)

    # Dispatch radio: squelch click, crackly band-limited static, a tone blip.
    n = n_of(1.3)
    t = tt(n)
    st = filt(white(n), "bandpass", [600, 3200]) * (0.5 + 0.5 * (rng.random(n) > 0.6))
    st *= 0.6 + 0.4 * np.sin(2 * np.pi * 7 * t) ** 2
    crack = filt((rng.random(n) > 0.997) * rng.uniform(-1, 1, n), "highpass", 1500) * 3
    blip = np.zeros(n)
    m = n_of(0.12)
    blip[n_of(0.05):n_of(0.05) + m] = np.sin(2 * np.pi * 1400 * tt(m)) * adsr(m, 0.005, 0.01, 1, 0.02)
    e = adsr(n, 0.01, 0.1, 0.8, 0.25)
    write("sfx/radio_static.ogg", fade(0.5 * st * e + crack * e + 0.6 * blip), peak=0.55)

    def brass(f, dur, vel=1.0):
        m = n_of(dur + 0.25)
        tm = tt(m)
        y = np.zeros(m)
        for k in range(1, 9):
            y += (1 / k) * np.sin(2 * np.pi * k * f * tm) * np.exp(-tm * k * 0.6)
        return filt(y, "lowpass", 3500) * adsr(m, 0.03, 0.1, 0.8, 0.25) * vel

    # Mission start: a rising three-note stab over a low hit.
    x = np.zeros(n_of(1.6))
    add_at(x, 0.8 * kick(1.0), 0, wrap=False)
    for k, mm in enumerate([57, 60, 64]):
        add_at(x, brass(midi(mm), 0.18 if k < 2 else 0.7, 0.6), n_of(0.12 * k), wrap=False)
        add_at(x, brass(midi(mm + 12), 0.18 if k < 2 else 0.7, 0.3), n_of(0.12 * k), wrap=False)
    write("sfx/mission_start.ogg", fade(circ_reverb(x, 1.2, 0.2)), peak=0.7)

    # Checkpoint: a bright double ding.
    x = np.zeros(n_of(0.8))
    add_at(x, fm_bell(midi(88), 0.6, 2.0, 1.0, 0.18), 0, wrap=False)
    add_at(x, 0.8 * fm_bell(midi(95), 0.6, 2.0, 1.0, 0.2), n_of(0.08), wrap=False)
    write("sfx/checkpoint.ogg", fade(circ_reverb(x, 0.6, 0.15)), peak=0.6)

    # Passed: major arpeggio up to a held chord, with a snare roll into a hit.
    x = np.zeros(n_of(2.6))
    for k, mm in enumerate([60, 64, 67]):
        add_at(x, brass(midi(mm), 0.14, 0.55), n_of(0.11 * k), wrap=False)
    for k in range(4):
        add_at(x, 0.25 * snare(1.5), n_of(0.05 + 0.07 * k), wrap=False)
    add_at(x, kick(1.0), n_of(0.36), wrap=False)
    add_at(x, 0.6 * snare(), n_of(0.36), wrap=False)
    for mm in [60, 64, 67, 72]:
        add_at(x, brass(midi(mm), 1.3, 0.45), n_of(0.36), wrap=False)
    add_at(x, 0.4 * fm_bell(midi(84), 1.5, 2.0, 0.8, 0.5), n_of(0.36), wrap=False)
    write("sfx/mission_passed.ogg", fade(circ_reverb(x, 1.6, 0.22), 0.002, 0.3), peak=0.75)

    # Failed: a sagging minor descent over a dull low hit.
    x = np.zeros(n_of(2.4))
    add_at(x, kick(0.6), 0, wrap=False)
    for k, mm in enumerate([64, 63, 60]):
        add_at(x, brass(midi(mm), 0.3 if k < 2 else 1.2, 0.5), n_of(0.32 * k), wrap=False)
        add_at(x, brass(midi(mm - 12), 0.3 if k < 2 else 1.2, 0.35), n_of(0.32 * k), wrap=False)
    x = filt(x, "lowpass", 2200)
    write("sfx/mission_failed.ogg", fade(circ_reverb(x, 1.4, 0.2), 0.002, 0.3), peak=0.7)
    rng = keep


# ---------------------------------------------------------------- ambience ---

AMB_SEC = 24.0


def amb_city(night=False):
    n = n_of(AMB_SEC)
    t = tt(n)
    rumble = cfilt(stereo_noise(brown, n, 0.6), "lowpass", 260)
    # A few slow swells, like traffic waves several blocks away (whole cycles per loop).
    sw = 0.7 + 0.15 * np.sin(2 * np.pi * t * 3 / AMB_SEC) + 0.15 * np.sin(2 * np.pi * t * 7 / AMB_SEC + 1)
    rumble *= sw[:, None]
    hiss = cfilt(stereo_noise(pink, n, 0.2), "bandpass", [400, 2500]) * (0.12 if night else 0.25)
    x = rumble + hiss
    # Far cars passing: band-limited noise bumps panned across.
    for _ in range(6 if night else 16):
        d = rng.uniform(1.5, 4.0)
        m = n_of(d)
        tm = tt(m) / d
        car = filt(pink(m), "bandpass", [120, rng.uniform(700, 1400)]) * np.sin(np.pi * tm) ** 2
        p = np.linspace(rng.uniform(-1, 0), rng.uniform(0, 1), m) * rng.choice([-1, 1])
        st = np.stack([car * np.cos((p + 1) * np.pi / 4), car * np.sin((p + 1) * np.pi / 4)], axis=1)
        add_at(x, st * rng.uniform(0.2, 0.5), rng.integers(0, n))
    if night:
        x += 0.02 * pan(np.sin(2 * np.pi * 60 * t) + 0.5 * np.sin(2 * np.pi * 120 * t), 0)
    return x


def chirp_bird(kind):
    if kind == 0:  # quick descending tweets
        out = []
        for _ in range(rng.integers(2, 6)):
            d = rng.uniform(0.05, 0.1)
            m = n_of(d)
            tm = tt(m) / d
            f = rng.uniform(3500, 5200) * (1 - 0.35 * tm)
            ph = 2 * np.pi * np.cumsum(f) / SR
            out.append(np.sin(ph) * np.sin(np.pi * tm) ** 2)
            out.append(np.zeros(n_of(rng.uniform(0.04, 0.09))))
        return np.concatenate(out)
    if kind == 1:  # trill
        d = rng.uniform(0.4, 0.9)
        m = n_of(d)
        tm = tt(m)
        f = rng.uniform(2800, 4200) + 600 * np.sin(2 * np.pi * rng.uniform(18, 28) * tm)
        ph = 2 * np.pi * np.cumsum(f) / SR
        return np.sin(ph) * np.sin(np.pi * tm / d) ** 2
    # two-note whistle
    out = []
    base = rng.uniform(2200, 3200)
    for r in [1.0, rng.choice([0.84, 1.19, 1.26])]:
        d = rng.uniform(0.15, 0.25)
        m = n_of(d)
        tm = tt(m) / d
        f = base * r * (1 + 0.04 * np.sin(np.pi * tm))
        ph = 2 * np.pi * np.cumsum(f) / SR
        out.append(np.sin(ph) * np.sin(np.pi * tm) ** 1.5)
        out.append(np.zeros(n_of(0.06)))
    return np.concatenate(out)


def amb_birds():
    n = n_of(AMB_SEC)
    x = 0.04 * cfilt(stereo_noise(pink, n, 0.3), "bandpass", [300, 1500])  # leafy air
    for _ in range(30):
        b = chirp_bird(rng.integers(0, 3)) * rng.uniform(0.15, 0.6)
        add_at(x, pan(b, rng.uniform(-0.9, 0.9)), rng.integers(0, n))
    return circ_reverb(x, 1.2, 0.2, lp=7000)


def amb_crickets():
    n = n_of(AMB_SEC)
    t = tt(n)
    x = 0.03 * cfilt(stereo_noise(pink, n, 0.3), "lowpass", 400)
    for _ in range(7):
        f = rng.uniform(3900, 5200)
        rate = rng.uniform(2.0, 3.5)  # chirps per second
        pulses = rng.integers(3, 5)
        e = np.zeros(n)
        per = 1.0 / rate
        k = rng.uniform(0, per)
        while k < AMB_SEC:
            for p in range(pulses):
                m = n_of(0.018)
                add_at(e, np.sin(np.pi * np.arange(m) / m) ** 2, n_of(k + p * 0.028))
            k += per * rng.uniform(0.9, 1.1)
        c = np.sin(2 * np.pi * f * t) * e * rng.uniform(0.15, 0.4)
        x += pan(c, rng.uniform(-0.9, 0.9))
    return x


def amb_wind():
    n = n_of(AMB_SEC)
    t = tt(n)
    base = stereo_noise(pink, n, 0.4)
    g = 0.55 + 0.25 * np.sin(2 * np.pi * t * 2 / AMB_SEC) + 0.2 * np.sin(2 * np.pi * t * 5 / AMB_SEC + 2)
    low = cfilt(base, "bandpass", [80, 500]) * g[:, None]
    high = cfilt(base, "bandpass", [600, 2200]) * (g ** 3)[:, None] * 0.5
    return low + high


def amb_crowd():
    """Murmur from a dozen fake voices: glottal buzz through moving vowel formants."""
    n = n_of(AMB_SEC)
    x = np.zeros((n, 2))
    formants = [(730, 1090), (530, 1840), (270, 2290), (570, 840), (440, 1020), (300, 870), (660, 1720)]
    for v in range(14):
        f0 = rng.uniform(95, 230)
        t = tt(n)
        jitter = 1 + 0.03 * cfilt(white(n), "lowpass", 4)
        ph = 2 * np.pi * np.cumsum(f0 * jitter) / SR
        src = signal.sawtooth(ph)
        voice = np.zeros(n)
        pos = rng.integers(0, n)
        while pos < n + n:  # fill one loop length worth of syllables, wrapping
            words = rng.integers(3, 9)
            for _ in range(words):
                d = rng.uniform(0.09, 0.22)
                m = n_of(d)
                f1, f2 = formants[rng.integers(0, len(formants))]
                seg_idx = (np.arange(m) + pos) % n
                seg = src[seg_idx]
                y = 0.6 * filt(seg, "bandpass", [f1 * 0.8, f1 * 1.2]) + 0.4 * filt(seg, "bandpass", [f2 * 0.85, f2 * 1.15])
                y *= np.sin(np.pi * np.arange(m) / m) ** 1.5
                add_at(voice, y, pos)
                pos += m
            pos += n_of(rng.uniform(0.3, 1.5))
            if pos > n * 1.0 + n_of(1.0):
                break
        x += pan(voice * rng.uniform(0.4, 1.0), rng.uniform(-0.8, 0.8))
    x = cfilt(x, "lowpass", 2600)
    return circ_reverb(x, 1.0, 0.35, lp=4000)


def amb_sea():
    n = n_of(AMB_SEC)
    t = tt(n)
    x = np.zeros((n, 2))
    wave_n = 3
    for w in range(wave_n):
        period = AMB_SEC / rng.choice([3, 4])
        ph = rng.uniform(0, 1)
        e = (0.5 + 0.5 * np.sin(2 * np.pi * (t / period + ph))) ** 3
        body = cfilt(stereo_noise(brown, n, 0.5), "lowpass", 500) * e[:, None]
        foam = cfilt(stereo_noise(pink, n, 0.3), "bandpass", [800, 5000]) * (e ** 2)[:, None] * 0.35
        x += body + foam
    return x


# ------------------------------------------------------------------- music ---

BPM = 92
BEAT = 60.0 / BPM
BARS = 32
SWING = 0.58

# Chords as MIDI notes (voicing), bass root.
A_SEC = [([53, 57, 60, 64], 41), ([52, 55, 59, 62], 40), ([50, 53, 57, 60, 64], 38), ([48, 52, 55, 59], 36),
         ([53, 57, 60, 64], 41), ([52, 55, 59, 62], 40), ([50, 53, 57, 60], 38), ([50, 53, 55, 60, 64], 43)]
B_SEC = [([57, 60, 64, 67, 71], 45), ([53, 57, 60, 64, 67], 41), ([52, 55, 59, 60, 64], 36), ([55, 59, 62, 64], 43),
         ([57, 60, 64, 67], 45), ([53, 57, 60, 64], 41), ([55, 59, 60, 64], 36), ([55, 59, 62, 65], 43)]
SONG = A_SEC + B_SEC + A_SEC + B_SEC
PENTA = [57, 60, 62, 64, 67, 69, 72, 74, 76, 79]


def bar_start(b):
    return b * 4 * BEAT


def step_time(bar, sixteenth):
    """Swung sixteenth grid."""
    beat, sub = divmod(sixteenth, 4)
    pair, odd = divmod(sub, 2)
    off = (pair * 2 + (SWING * 2 if odd else 0)) * BEAT / 4
    return bar_start(bar) + beat * BEAT + off


def epiano(f, dur, vel=1.0):
    n = n_of(dur + 0.6)
    t = tt(n)
    ie = 1.6 * np.exp(-t / 0.35) + 0.15
    x = np.sin(2 * np.pi * f * t + ie * np.sin(2 * np.pi * f * t))
    x += 0.25 * np.sin(2 * np.pi * f * 14 * t) * np.exp(-t / 0.02)  # tine
    e = np.exp(-t / 1.4)
    e[:n_of(0.004)] *= np.linspace(0, 1, n_of(0.004))
    r = n_of(dur)
    e[r:] *= np.exp(-tt(n - r) / 0.12)
    return x * e * vel


def pad(freqs, dur):
    n = n_of(dur + 1.0)
    t = tt(n)
    x = np.zeros(n)
    for f in freqs:
        for d in (-0.08, 0.0, 0.07):
            x += signal.sawtooth(2 * np.pi * f * 2 ** (d / 12) * t + rng.uniform(0, 6))
    x = filt(x, "lowpass", 1100, 2)
    e = np.ones(n)
    a = n_of(0.7)
    e[:a] = np.linspace(0, 1, a) ** 2
    r = n_of(dur)
    e[r:] *= np.exp(-tt(n - r) / 0.4)
    return x * e / (3 * len(freqs))


def pluck(f, dur=0.35, bright=1.0):
    n = n_of(dur + 0.2)
    t = tt(n)
    x = np.zeros(n)
    kmax = int(min(24, 9000 / f))
    for k in range(1, kmax + 1):
        x += (1 / k) * np.sin(2 * np.pi * k * f * t + 0.3 * k) * np.exp(-t * (3 + k * 2.2 / bright))
    x[:n_of(0.002)] *= np.linspace(0, 1, n_of(0.002))
    return x


def bass(f, dur, saw=0.0):
    n = n_of(dur + 0.08)
    t = tt(n)
    x = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) + 0.12 * np.sin(2 * np.pi * 3 * f * t)
    if saw > 0:
        for k in range(4, 12):
            x += saw * (1 / k) * np.sin(2 * np.pi * k * f * t) * np.exp(-t * k * 1.5)
    e = adsr(n, 0.006, 0.12, 0.75, 0.06)
    return x * e


def kick(punch=1.0):
    n = n_of(0.45)
    t = tt(n)
    f = 46 + 90 * np.exp(-t / 0.035) * punch
    ph = 2 * np.pi * np.cumsum(f) / SR
    x = np.sin(ph) * np.exp(-t / 0.28)
    x += 0.25 * punch * filt(white(n), "highpass", 2000) * np.exp(-t / 0.004)
    return x


def snare(tight=1.0):
    n = n_of(0.3)
    t = tt(n)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05)
    nz = filt(white(n), "bandpass", [1200, 7000]) * np.exp(-t / (0.12 / tight))
    return 0.6 * tone + nz


def clap():
    n = n_of(0.35)
    t = tt(n)
    e = np.zeros(n)
    for d in (0.0, 0.011, 0.022):
        s = n_of(d)
        e[s:] += np.exp(-tt(n - s) / 0.006)
    e += 0.6 * np.exp(-np.maximum(t - 0.03, 0) / 0.09) * (t > 0.03)
    return filt(white(n), "bandpass", [900, 3500]) * e


def hat(open_=False):
    n = n_of(0.4 if open_ else 0.08)
    t = tt(n)
    return filt(white(n), "highpass", 7000) * np.exp(-t / (0.16 if open_ else 0.025))


def shaker():
    n = n_of(0.1)
    t = tt(n)
    e = np.clip(t / 0.02, 0, 1) * np.exp(-t / 0.03)
    return filt(white(n), "bandpass", [4000, 11000]) * e


def rim():
    n = n_of(0.1)
    t = tt(n)
    return np.sin(2 * np.pi * 1700 * t) * np.exp(-t / 0.012) + 0.4 * filt(white(n), "bandpass", [2000, 6000]) * np.exp(-t / 0.005)


def vinyl(n):
    x = 0.004 * cfilt(white(n), "bandpass", [1000, 8000])
    clicks = (rng.random(n) > 0.99985).astype(float) * rng.uniform(0.05, 0.25, n)
    return x + cfilt(clicks, "highpass", 1500)


def music():
    n = n_of(BARS * 4 * BEAT)

    def buf():
        return np.zeros((n, 2))

    # ---- mayor: electric piano, pad, sub bass, soft beat, melody, vinyl -----
    m_keys, m_pad, m_bass, m_drm, m_mel = buf(), buf(), buf(), buf(), buf()
    for b, (chord, root) in enumerate(SONG):
        t0 = bar_start(b)
        freqs = [midi(x) for x in chord]
        # Comp: beat 1 and the swung "and" of 2.
        for hit, vel in [(0, 1.0), (6, 0.7)]:
            st = step_time(b, hit)
            for i, f in enumerate(freqs):
                add_at(m_keys, pan(epiano(f, BEAT * 1.6, vel * 0.5), -0.3 + 0.6 * i / len(freqs)), n_of(st + 0.008 * i))
        add_at(m_pad, pan(pad([midi(x + 12) for x in chord[1:3]], 4 * BEAT), 0.0), n_of(t0))
        add_at(m_bass, pan(bass(midi(root), 3.5 * BEAT), 0), n_of(t0))
        in_intro = b < 4
        if not in_intro:
            add_at(m_drm, pan(kick(0.6), 0), n_of(step_time(b, 0)))
            add_at(m_drm, pan(kick(0.5) * 0.7, 0), n_of(step_time(b, 10)))
            add_at(m_drm, pan(rim() * 0.35, 0.2), n_of(step_time(b, 4)))
            add_at(m_drm, pan(rim() * 0.35, 0.2), n_of(step_time(b, 12)))
            for s in range(0, 16, 2):
                add_at(m_drm, pan(shaker() * (0.25 if s % 4 else 0.15), -0.3), n_of(step_time(b, s)))
    # Melody over the B sections, chord-tone anchored pentatonic phrases.
    rhythms = [[0, 3, 6, 10], [0, 4, 6, 8, 12], [2, 6, 10, 14], [0, 6, 8, 11]]
    for b, (chord, root) in enumerate(SONG):
        if (b // 8) % 2 == 0:
            continue
        rhy = rhythms[(b * 7 + 3) % len(rhythms)]
        tones = [x + 12 for x in chord if (x + 12) in PENTA or (x + 12) - 12 in PENTA] or PENTA
        last = None
        for k, s in enumerate(rhy):
            if k == 0:
                note = min(tones, key=lambda x: abs(x - (last or 69)))
            else:
                choices = [p for p in PENTA if abs(p - (last or 69)) <= 4]
                note = int(rng.choice(choices))
            last = note
            dur = (rhy[k + 1] - s if k + 1 < len(rhy) else 16 - s) * BEAT / 4
            f = midi(note + 12)
            nn = n_of(dur + 0.3)
            tm = tt(nn)
            vib = 1 + 0.004 * np.sin(2 * np.pi * 5.2 * tm) * np.clip(tm / 0.3, 0, 1)
            ph = 2 * np.pi * np.cumsum(f * vib) / SR
            lead = (np.sin(ph) + 0.18 * np.sin(2 * ph) + 0.06 * np.sin(3 * ph)) * adsr(nn, 0.015, 0.2, 0.6, 0.25)
            add_at(m_mel, pan(lead * 0.22, 0.15), n_of(step_time(b, s)))
    mayor = (0.9 * m_keys + 0.55 * m_pad + 0.55 * m_bass + 0.7 * m_drm + 0.8 * m_mel)
    mayor = cfilt(mayor, "lowpass", 7000)
    mayor = circ_reverb(mayor, 2.4, 0.28, lp=5000)
    mayor += np.stack([vinyl(n), vinyl(n)], axis=1)

    # ---- street: plucked arpeggio, syncopated bass, light percussion --------
    s_arp, s_bass, s_perc = buf(), buf(), buf()
    arp_order = [0, 1, 2, 3, 2, 1, 3, 2]
    for b, (chord, root) in enumerate(SONG):
        tones = [midi(x + 12) for x in chord]
        for s in range(16):
            i = arp_order[s % len(arp_order)] % len(tones)
            vel = 0.55 if s % 4 == 0 else 0.35
            add_at(s_arp, pan(pluck(tones[i], 0.3) * vel, 0.5 * np.sin(s * 0.7)), n_of(step_time(b, s)))
        bl = [(0, 0, 3), (3, 0, 1), (6, 12, 2), (10, 7, 2), (14, 12, 2)]
        for s, iv, ln in bl:
            add_at(s_bass, pan(bass(midi(root + iv), ln * BEAT / 4 * 0.95, saw=0.5), 0), n_of(step_time(b, s)))
        for s in range(0, 16, 2):
            add_at(s_perc, pan(hat() * (0.3 if s % 4 == 2 else 0.18), 0.25), n_of(step_time(b, s)))
        add_at(s_perc, pan(clap() * 0.4, -0.1), n_of(step_time(b, 12)))
    street = 0.75 * s_arp + 0.75 * s_bass + 0.6 * s_perc
    street = circ_reverb(street, 1.6, 0.2, lp=6000)

    # ---- drive: full drums plus a sub octave, layered on top of street -----
    d_drm, d_sub = buf(), buf()
    kick_pat = [0, 7, 10]
    for b, (chord, root) in enumerate(SONG):
        for s in kick_pat:
            add_at(d_drm, pan(kick(1.0), 0), n_of(step_time(b, s)))
        if b % 4 == 3:
            add_at(d_drm, pan(kick(0.8) * 0.8, 0), n_of(step_time(b, 14)))
        for s in (4, 12):
            add_at(d_drm, pan(snare() * 0.8, 0.05), n_of(step_time(b, s)))
        for s in range(16):
            v = 0.35 if s % 2 == 0 else 0.18
            add_at(d_drm, pan(hat(open_=(s == 14)) * v, 0.3), n_of(step_time(b, s)))
        if b % 8 == 7:
            for s in (13, 14, 15):
                add_at(d_drm, pan(snare(1.5) * 0.45, -0.1), n_of(step_time(b, s)))
        add_at(d_sub, pan(bass(midi(root - 12), 3.8 * BEAT), 0), n_of(bar_start(b)))
    drive = 0.85 * d_drm + 0.5 * d_sub
    drive = circ_reverb(drive, 1.0, 0.12, lp=7000)

    write("music/music_mayor.ogg", mayor, rms=0.11)
    write("music/music_street.ogg", street, rms=0.11)
    write("music/music_drive.ogg", drive, rms=0.10)


def ambience():
    write("ambience/amb_city_day.ogg", amb_city(False), rms=0.12)
    write("ambience/amb_city_night.ogg", amb_city(True), rms=0.09)
    write("ambience/amb_birds.ogg", amb_birds(), rms=0.06)
    write("ambience/amb_crickets.ogg", amb_crickets(), rms=0.05)
    write("ambience/amb_wind.ogg", amb_wind(), rms=0.10)
    write("ambience/amb_crowd.ogg", amb_crowd(), rms=0.10)
    write("ambience/amb_sea.ogg", amb_sea(), rms=0.10)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["sfx", "missions", "ambience", "music"])
    a = ap.parse_args()
    if a.only in (None, "sfx"):
        print("sfx")
        sfx_ui()
        sfx_build()
        sfx_transitions()
        sfx_street()
        sfx_loops()
    if a.only in (None, "sfx", "missions"):
        print("missions")
        sfx_missions()
    if a.only in (None, "ambience"):
        print("ambience")
        ambience()
    if a.only in (None, "music"):
        print("music")
        music()


if __name__ == "__main__":
    main()
