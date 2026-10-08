#!/usr/bin/env python3
"""Fixes from Fedge's sound check (2026-10-08). Each function replaces one sound from the
earlier generators; they have their own seeds, so every other sound stays byte-identical.

    python3 audio/tools/synth_fixes.py            # writes all of them
    python3 audio/tools/synth_fixes.py --only sirens

synth_audio.py and synth_round3.py call apply() after their own groups, so a full regenerate
keeps the fixed versions. All output is original and CC0.
"""
import argparse

import numpy as np
from scipy import signal

import synth_audio as S
from synth_audio import (SR, add_at, adsr, brown, cfilt, circ_reverb, env_exp, fade, filt, midi, n_of, pan,
                         pink, softclip, stereo_noise, tt, white, write)


def R():
    return S.rng


# ------------------------------------------------------------------ voices ---

def vocal(f0, formants, dur=None, breath=0.15, bw=0.18):
    """A sung vowel: a buzzy glottal source through formant filters. f0 is an array in Hz."""
    n = len(f0)
    ph = 2 * np.pi * np.cumsum(f0) / SR
    src = signal.sawtooth(ph) * 0.8 + 0.2 * np.sin(ph)
    nz = white(n)
    out = np.zeros(n)
    for fc, g in formants:
        sos = signal.butter(2, [fc * (1 - bw), fc * (1 + bw)], btype="bandpass", fs=SR, output="sos")
        out += g * signal.sosfilt(sos, src + breath * nz * 1.5)
    return out


A_VOWEL = [(750, 1.0), (1150, 0.7), (2600, 0.25)]
O_VOWEL = [(500, 1.0), (900, 0.6), (2500, 0.15)]
U_VOWEL = [(320, 1.0), (800, 0.35), (2400, 0.1)]


def glide(n, a, b, curve=1.0):
    t = np.linspace(0, 1, n) ** curve
    return a + (b - a) * t


# -------------------------------------------------------------------- doors ---

def door_open():
    """Pneumatic hiss, then a contented sigh (the Sirius Cybernetics kind of door)."""
    n = n_of(1.5)
    x = np.zeros(n)
    m = n_of(0.45)
    tm = tt(m) / 0.45
    hiss = filt(white(m), "bandpass", [900, 8000]) * np.sin(np.pi * np.minimum(tm * 1.0, 1.0)) ** 0.7 * np.exp(-tm * 2.2)
    add_at(x, 0.7 * hiss, n_of(0.02), wrap=False)
    # A small servo "chk" at the start.
    k = n_of(0.03)
    add_at(x, 0.5 * filt(white(k), "bandpass", [1200, 4000]) * np.exp(-tt(k) / 0.006), 0, wrap=False)
    # The sigh: "ahhh", falling, breathy, with a slow swell.
    m = n_of(1.0)
    f0 = glide(m, 240, 170, 0.8)
    f0 *= 1 + 0.01 * np.sin(2 * np.pi * 5.0 * tt(m))
    v = vocal(f0, A_VOWEL, breath=0.5)
    v += 0.35 * vocal(f0 * 0.5, O_VOWEL, breath=0.3)
    env = np.sin(np.pi * np.clip(tt(m) / 1.0, 0, 1)) ** 1.3 * np.exp(-tt(m) / 0.8)
    add_at(x, 0.45 * v * env, n_of(0.22), wrap=False)
    x = filt(x, "lowpass", 7000)
    return fade(circ_reverb(x, 0.5, 0.12, lp=5000)[:, 0], 0.002, 0.15)


def door_close():
    """A softer, satisfied 'mmm' with a gentle pneumatic puff and a latch."""
    n = n_of(1.2)
    x = np.zeros(n)
    m = n_of(0.22)
    tm = tt(m)
    add_at(x, 0.55 * filt(white(m), "bandpass", [800, 6000]) * (np.sin(np.pi * tm / tm[-1]) ** 1.2), 0, wrap=False)
    m = n_of(0.8)
    f0 = glide(m, 190, 145, 0.7)
    v = vocal(f0, U_VOWEL, breath=0.2, bw=0.12) * (np.sin(np.pi * np.clip(tt(m) / 0.8, 0, 1)) ** 1.5)
    add_at(x, 0.5 * v, n_of(0.12), wrap=False)
    # Latch: a small thunk.
    m = n_of(0.12)
    tm = tt(m)
    add_at(x, 0.7 * np.sin(2 * np.pi * 110 * tm * (1 - 0.3 * tm / tm[-1])) * np.exp(-tm / 0.03), n_of(0.02), wrap=False)
    add_at(x, 0.3 * filt(white(m), "bandpass", [1500, 5000]) * np.exp(-tm / 0.004), n_of(0.02), wrap=False)
    x = filt(x, "lowpass", 6500)
    return fade(circ_reverb(x, 0.4, 0.1, lp=5000)[:, 0], 0.002, 0.12)


def doors():
    old = S._seeded(8801)
    write("sfx/door_open.ogg", door_open(), peak=0.6)
    write("sfx/door_close.ogg", door_close(), peak=0.7)
    S.rng = old


# ---------------------------------------------------------------- the dive ---

def glitch(x, events, crush=True):
    """Digital stutter: repeat short slices, bitcrush some spans, drop others out."""
    x = x.copy()
    n = len(x)
    for pos, ln, kind in events:
        s = n_of(pos)
        L = n_of(ln)
        if s + L >= n:
            continue
        if kind == "stutter":
            piece = x[s:s + max(L // 3, 64)].copy()
            reps = int(np.ceil(L / len(piece)))
            x[s:s + L] = np.tile(piece, (reps, 1))[:L]
        elif kind == "crush":
            hold = int(R().integers(10, 28))
            seg = x[s:s + L]
            seg = np.repeat(seg[::hold], hold, axis=0)[:L]
            q = 6.0
            x[s:s + L] = np.round(seg * q) / q * 1.2
        elif kind == "drop":
            x[s:s + L] *= 0.04
    return x


def electric(dur, f_from, f_to, peak_at):
    """A digital zap: FM buzz sliding in pitch, gated like a bad connection, plus sparse crackle."""
    n = n_of(dur)
    t = tt(n)
    u = t / dur
    f = f_from * (f_to / f_from) ** u
    ph = 2 * np.pi * np.cumsum(f) / SR
    idx = 2.5 + 2.0 * np.sin(2 * np.pi * 3.1 * t)
    x = np.sin(ph + idx * np.sin(1.41 * ph)) + 0.4 * signal.square(ph * 0.5)
    gate = 0.65 + 0.35 * np.sign(np.sin(2 * np.pi * 48 * t))
    x = filt(x, "highpass", 250) * gate
    e = np.where(u < peak_at, (u / peak_at) ** 1.6, ((1 - u) / (1 - peak_at)) ** 1.8)
    x = x * e
    # Crackle: sparse high-passed clicks.
    clicks = (R().random(n) > 0.9985).astype(float) * R().uniform(0.3, 1.0, n)
    clicks = filt(clicks, "highpass", 2500) * e
    st = np.stack([x, np.roll(x, n_of(0.004))], axis=1) * 0.35
    st += np.stack([clicks, np.roll(clicks, n_of(0.01))], axis=1) * 1.6
    return st


def dive(down):
    if down:
        dur, base = 3.2, S.whoosh(3.2, 4500, 250, 0.7)
        zap = electric(dur, 3500, 180, 0.7)
        sub_t = tt(n_of(dur))
        sub = np.sin(2 * np.pi * np.cumsum(90 * np.exp(-sub_t / 1.2) + 35) / SR) * np.clip((sub_t - 1.8) / 0.8, 0, 1) * np.exp(-np.maximum(sub_t - 2.6, 0) / 0.35)
        peak_at = 0.7
    else:
        dur, base = 2.6, S.whoosh(2.6, 300, 5500, 0.35)
        zap = electric(dur, 200, 4200, 0.35)
        sub = np.zeros(n_of(dur))
        peak_at = 0.35
    x = 0.8 * base + zap + 0.5 * np.stack([sub, sub], axis=1)
    # Glitches cluster where the effect is loudest.
    centre = dur * peak_at
    ev = []
    for _ in range(9):
        pos = float(np.clip(R().normal(centre, dur * 0.2), 0.05, dur - 0.3))
        ev.append((pos, float(R().uniform(0.03, 0.09)), str(R().choice(["stutter", "crush", "drop", "stutter"]))))
    x = glitch(x, ev)
    return fade(x, 0.01, 0.06)


def dives():
    old = S._seeded(8802)
    write("sfx/whoosh_down.ogg", dive(True), peak=0.65)
    write("sfx/whoosh_up.ogg", dive(False), peak=0.65)
    S.rng = old


# ------------------------------------------------------------------ sirens ---

def siren_loops():
    # Wail (2 s) and yelp (1 s), pitched down about a fourth from the first version.
    n = n_of(2.0)
    t = tt(n)
    f = 640 + 300 * np.sin(2 * np.pi * 0.5 * t - np.pi / 2)
    ph = 2 * np.pi * np.cumsum(f) / SR
    ph *= np.round(ph[-1] / (2 * np.pi)) * 2 * np.pi / ph[-1]
    s = np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph)
    write("sfx/siren_loop.ogg", cfilt(s, "lowpass", 3500), peak=0.6)
    n = SR
    t = tt(n)
    f = 780 + 300 * np.sin(2 * np.pi * 4 * t)
    ph = 2 * np.pi * np.cumsum(f) / SR
    ph *= np.round(ph[-1] / (2 * np.pi)) * 2 * np.pi / ph[-1]
    s = np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph)
    write("sfx/siren_yelp_loop.ogg", cfilt(s, "lowpass", 3500), peak=0.6)


# ------------------------------------------------------------ busted/wasted ---

def laugh(level=1.0):
    """A mocking 'HA-ha': two quick falling syllables, the second longer and lower."""
    out = np.zeros(n_of(0.9))
    for start, dur, f_a, f_b, g in [(0.0, 0.2, 360, 270, 1.0), (0.27, 0.42, 300, 190, 0.8)]:
        m = n_of(dur)
        f0 = glide(m, f_a, f_b, 0.7) * (1 + 0.012 * np.sin(2 * np.pi * 9 * tt(m)))
        v = vocal(f0, A_VOWEL, breath=0.45, bw=0.16)
        # The "h": a short burst of breath at the front of each syllable.
        hn = n_of(0.04)
        v[:hn] += 0.6 * filt(white(hn), "bandpass", [900, 3500]) * np.linspace(1, 0, hn)
        env = np.clip(tt(m) / 0.02, 0, 1) * np.exp(-tt(m) / (dur * 0.7))
        add_at(out, g * v * env, n_of(start), wrap=False)
    # A bit of nasal honk makes it cheeky rather than cheerful.
    out += 0.25 * filt(out, "bandpass", [1500, 2200])
    return level * out


def crowd_aww(dur=1.9, voices=9):
    """A crowd's disappointed 'aww': many voices, gliding down, a little out of step."""
    n = n_of(dur)
    x = np.zeros((n, 2))
    for _ in range(voices):
        f_a = R().uniform(170, 330)
        lag = n_of(R().uniform(0.0, 0.22))
        m = n - lag
        f0 = glide(m, f_a, f_a * R().uniform(0.72, 0.84), 0.9) * (1 + 0.008 * np.sin(2 * np.pi * R().uniform(4, 6) * tt(m)))
        va = vocal(f0, A_VOWEL, breath=0.35, bw=0.2)
        vo = vocal(f0, O_VOWEL, breath=0.35, bw=0.2)
        mix = np.linspace(0, 1, m)  # "aaa" slides toward "ooo"
        env = np.sin(np.pi * np.clip(tt(m) / (dur - lag / SR), 0, 1)) ** 1.1
        x[lag:] += pan((va * (1 - mix) + vo * mix) * env * 0.5, R().uniform(-0.9, 0.9))
    return x


def busted_wasted():
    old = S._seeded(8803)
    # Busted: the original whistle, cuffs and sting, plus a mocking laugh over the sting.
    n = n_of(2.9)
    bs = np.zeros(n)
    for d, ln in [(0.0, 0.18), (0.26, 0.45)]:
        m = n_of(ln)
        tm = tt(m)
        f = 2900 * (1 + 0.03 * np.sin(2 * np.pi * 38 * tm))
        wh = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.3 * filt(white(m), "bandpass", [2500, 3500])
        add_at(bs, 0.5 * wh * adsr(m, 0.01, 0.02, 1, 0.04), n_of(d), wrap=False)
    for d in (0.95, 1.08):
        m = n_of(0.05)
        add_at(bs, 0.4 * filt(white(m), "bandpass", [2500, 9000]) * np.exp(-tt(m) / 0.005), n_of(d), wrap=False)
    m = n_of(1.6)
    tm = tt(m)
    sting = sum(np.sin(2 * np.pi * midi(mm) * tm) for mm in [40, 47, 51]) * np.exp(-tm / 0.7) * 0.4
    add_at(bs, sting, n_of(1.05), wrap=False)
    add_at(bs, laugh(0.55), n_of(1.25), wrap=False)
    write("sfx/busted.ogg", fade(circ_reverb(bs, 1.2, 0.2), 0.002, 0.3), peak=0.75)

    # Wasted: the heavy hit and falling drone, with a crowd's "aww" settling in after the hit.
    n = n_of(3.7)
    t = tt(n)
    ws = np.sin(2 * np.pi * np.cumsum(50 + 40 * np.exp(-t / 0.05)) / SR) * np.exp(-t / 0.6)
    for mm in [45, 52, 56]:
        f = midi(mm) * (1 - 0.12 * t / t[-1])
        ws += 0.25 * signal.sawtooth(2 * np.pi * np.cumsum(f) / SR) * np.clip(t / 0.3, 0, 1) * np.exp(-t / 1.6)
    ws = filt(ws, "lowpass", 1200)
    st = np.stack([ws, ws], axis=1)
    st[n_of(0.45):n_of(0.45) + n_of(1.9)] += 0.7 * crowd_aww()
    write("sfx/wasted.ogg", fade(circ_reverb(st, 2.0, 0.3), 0.002, 0.5), peak=0.8)
    S.rng = old


# ---------------------------------------------------------------- ambience ---

AMB_SEC = 24.0


def amb_city_day():
    """Traffic that breathes: deep irregular swells, a couple of lulls, cars of very different loudness."""
    n = n_of(AMB_SEC)
    t = tt(n)
    swell = np.zeros(n)
    for k in (1, 2, 3, 5, 8):
        swell += R().uniform(0.5, 1.0) / k ** 0.5 * np.sin(2 * np.pi * t * k / AMB_SEC + R().uniform(0, 6.28))
    swell = (swell - swell.min()) / (swell.max() - swell.min())
    level = 0.3 + 0.7 * swell ** 1.2
    # Two lulls where the street almost empties out.
    for centre, width in [(R().uniform(4, 9), R().uniform(1.6, 2.6)), (R().uniform(14, 21), R().uniform(1.2, 2.2))]:
        d = np.minimum(np.abs(t - centre), AMB_SEC - np.abs(t - centre))
        level *= 1 - 0.72 * np.exp(-(d / width) ** 2)
    rumble = cfilt(stereo_noise(brown, n, 0.6), "lowpass", 260) * level[:, None]
    hiss = cfilt(stereo_noise(pink, n, 0.2), "bandpass", [400, 2500]) * (0.25 * (0.4 + 0.6 * level))[:, None]
    x = rumble + hiss
    for _ in range(18):
        d = R().uniform(1.5, 4.5)
        m = n_of(d)
        tm = tt(m) / d
        car = filt(pink(m), "bandpass", [120, R().uniform(700, 1500)]) * np.sin(np.pi * tm) ** 2
        p = np.linspace(R().uniform(-1, 0), R().uniform(0, 1), m) * R().choice([-1, 1])
        stc = np.stack([car * np.cos((p + 1) * np.pi / 4), car * np.sin((p + 1) * np.pi / 4)], axis=1)
        add_at(x, stc * R().choice([0.12, 0.2, 0.35, 0.6, 0.9]), R().integers(0, n))
    return x


def amb_crickets():
    """Crickets that come and go: each one chirps in bursts of a few seconds, at a wandering rate."""
    n = n_of(AMB_SEC)
    t = tt(n)
    x = 0.03 * cfilt(stereo_noise(pink, n, 0.3), "lowpass", 400)
    for _ in range(8):
        f = R().uniform(3800, 5300)
        gate = np.zeros(n)
        k = R().uniform(0, AMB_SEC)
        while True:
            on = R().uniform(1.5, 5.5)
            m = n_of(on)
            add_at(gate, np.sin(np.pi * np.arange(m) / m) ** 0.6, n_of(k))
            k += on + R().uniform(1.5, 6.5)
            if k > AMB_SEC * 2:
                break
        gate = np.clip(gate, 0, 1)
        e = np.zeros(n)
        rate = R().uniform(1.8, 3.6)
        pulses = int(R().integers(2, 6))
        k = R().uniform(0, 1 / rate)
        while k < AMB_SEC:
            for p in range(pulses):
                m = n_of(0.018)
                add_at(e, np.sin(np.pi * np.arange(m) / m) ** 2 * R().uniform(0.6, 1.0), n_of(k + p * 0.028))
            rate_now = rate * (1 + 0.25 * np.sin(2 * np.pi * k * 2 / AMB_SEC + f))
            k += (1.0 / rate_now) * R().uniform(0.8, 1.25)
        c = np.sin(2 * np.pi * f * t) * e * gate * R().uniform(0.2, 0.55)
        x += pan(c, R().uniform(-0.9, 0.9))
    return x


def amb_rain_light():
    """Drizzle as soft patter on pavement: no ringing drops, so it never sounds like water on water."""
    n = n_of(AMB_SEC)
    t = tt(n)
    base = stereo_noise(pink, n, 0.2)
    swell = 1.0 + 0.1 * np.sin(2 * np.pi * t * 3 / AMB_SEC) + 0.06 * np.sin(2 * np.pi * t * 7 / AMB_SEC + 1)
    hiss = cfilt(base, "bandpass", [1800, 7500]) * swell[:, None] * 0.55
    body = cfilt(base, "bandpass", [200, 1100]) * 0.22
    x = hiss + body
    # Patter: short, dry ticks, no pitch.
    ticks = np.zeros((n, 2))
    for _ in range(int(55 * AMB_SEC)):
        m = n_of(0.006)
        tick = filt(white(m), "bandpass", [1500, 6000]) * np.exp(-tt(m) / 0.0015)
        add_at(ticks, pan(tick * R().uniform(0.1, 0.6), R().uniform(-1, 1)), R().integers(0, n))
    return x + 0.6 * ticks


# ----------------------------------------------------------------- thunder ---

def thunder_1(dur=7.5):
    """A close strike: a sharp crack with a punch of bass, then the long rolling rumble."""
    n = n_of(dur)
    t = tt(n)
    x = np.zeros(n)
    # The crack: a click, a bright burst and a tight bass punch, all in the first 80 ms.
    click = np.zeros(n)
    click[:n_of(0.0012)] = np.hanning(n_of(0.0012) * 2)[n_of(0.0012):] * 1.0
    x += 1.4 * click
    m = n_of(0.35)
    tm = tt(m)
    x[:m] += 1.0 * filt(white(m), "bandpass", [1200, 9000]) * np.exp(-tm / 0.022)
    x[:m] += 0.6 * filt(white(m), "bandpass", [400, 2000]) * np.exp(-tm / 0.07)
    punch = np.sin(2 * np.pi * np.cumsum(38 + 90 * np.exp(-tm / 0.03)) / SR) * np.exp(-tm / 0.14)
    x[:m] += 1.9 * softclip(punch * 1.8, 1.4)
    # A few ragged after-cracks.
    for d, g in [(0.06, 0.55), (0.14, 0.4), (0.27, 0.3)]:
        k = n_of(0.2)
        add_at(x, g * filt(white(k), "bandpass", [700, 6000]) * np.exp(-tt(k) / 0.035), n_of(d), wrap=False)
    # Rolling rumble after the crack.
    roll = filt(brown(n), "lowpass", 180)
    e = np.zeros(n)
    tpos = 0.12
    while tpos < dur - 0.5:
        a = R().uniform(0.3, 1.0) * np.exp(-tpos / 2.4)
        s0 = n_of(tpos)
        mm = n - s0
        e[s0:] += a * np.exp(-tt(mm) / R().uniform(0.25, 0.8)) * np.clip(tt(mm) / 0.08, 0, 1)
        tpos += R().uniform(0.15, 0.7)
    x += 2.0 * roll * e
    x += 0.5 * filt(brown(n), "bandpass", [40, 120]) * np.exp(-t / 2.0)
    x = softclip(x / np.max(np.abs(x)) * 1.5, 1.3)
    st = np.stack([x, np.roll(x, n_of(0.012)) * 0.95], axis=1)
    return fade(st, 0.0005, 1.0)


def apply(group=None):
    """Called by the other generators after they write a group; group None = everything."""
    if group in (None, "sfx"):
        doors()
        dives()
        siren_loops()
    if group in (None, "action"):
        siren_loops()
        busted_wasted()
    if group in (None, "ambience"):
        old = S._seeded(8804)
        write("ambience/amb_city_day.ogg", amb_city_day(), rms=0.12)
        write("ambience/amb_crickets.ogg", amb_crickets(), rms=0.05)
        S.rng = old
    if group in (None, "weather"):
        old = S._seeded(8805)
        write("ambience/amb_rain_light.ogg", amb_rain_light(), rms=0.05)
        write("sfx/thunder_1.ogg", thunder_1(), peak=0.93)
        S.rng = old


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["sfx", "action", "ambience", "weather"])
    a = ap.parse_args()
    apply(a.only)


if __name__ == "__main__":
    main()
