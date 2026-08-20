#!/usr/bin/env python3
"""
audio_director.py — synthesizes the game's sound, because nothing else does.

Audio was the weakest subsystem by a distance: seven SFX and no music, no way to
make more of either. Art has a generator, levels have a generator, and sound had
a folder of files nobody could regenerate. This closes that.

Everything is synthesized from scratch — no samples, no dependencies beyond numpy
— so a new sound is a few lines of parameters rather than a licensing question,
and the whole set is reproducible from this file.

    python3 Tools/audio_director.py                     # every SFX + every theme
    python3 Tools/audio_director.py --only jump,coin     # just these
    python3 Tools/audio_director.py --themes             # music only
    python3 Tools/audio_director.py --list               # what it can make

Design notes that matter:

  • Cartoon SFX are *pitch gestures*, not timbres. A jump is a rising sweep, a
    hurt is a falling one, a coin is two quick steps up. Get the gesture right and
    a crude waveform reads correctly; get it wrong and no amount of filtering
    helps.
  • Music loops are made seamless the same way the backdrop layers are: generate
    the loop, then fold the decaying tail back over the head so the wrap joins
    mid-phrase instead of clicking.
  • Everything is mono 44.1kHz 16-bit. SpriteKit's `playSoundFileNamed` is fire-
    and-forget with no panning, so stereo would be wasted bytes.
"""
import argparse, math, os, struct, sys, wave

try:
    import numpy as np
except ImportError:
    print("audio_director needs numpy:  python3 -m pip install numpy", file=sys.stderr)
    sys.exit(1)

RATE = 44100


# ─────────────────────────────────────────────────────────────────────────────
# Primitives
# ─────────────────────────────────────────────────────────────────────────────

def t_axis(seconds):
    return np.arange(int(RATE * seconds), dtype=np.float32) / RATE


def sine(freq, seconds, phase=0.0):
    """`freq` may be a scalar or an array the same length as the output — an
    array is how every sweep in this file is written."""
    t = t_axis(seconds)
    if np.ndim(freq) == 0:
        return np.sin(2 * np.pi * freq * t + phase).astype(np.float32)
    # Integrate instantaneous frequency, or a sweep's pitch drifts from what was
    # asked for and two sweeps that should harmonise don't.
    return np.sin(2 * np.pi * np.cumsum(np.asarray(freq, np.float32)) / RATE
                  + phase).astype(np.float32)


def square(freq, seconds, duty=0.5):
    return np.where(_phase(freq, seconds) % 1.0 < duty, 1.0, -1.0).astype(np.float32)


def saw(freq, seconds):
    return (2 * (_phase(freq, seconds) % 1.0) - 1).astype(np.float32)


def triangle(freq, seconds):
    p = _phase(freq, seconds) % 1.0
    return (4 * np.abs(p - 0.5) - 1).astype(np.float32)


def _phase(freq, seconds):
    if np.ndim(freq) == 0:
        return freq * t_axis(seconds)
    return np.cumsum(np.asarray(freq, np.float32)) / RATE


def noise(seconds, seed=0):
    rng = np.random.default_rng(seed)
    return rng.uniform(-1, 1, int(RATE * seconds)).astype(np.float32)


def sweep(start, end, seconds, curve=1.0):
    """A pitch ramp. `curve` > 1 spends longer near `start`, which is what makes
    a jump sound like it leaves the ground rather than teleports."""
    f = np.linspace(0.0, 1.0, int(RATE * seconds), dtype=np.float32) ** curve
    return start + (end - start) * f


def env(seconds, attack=0.005, decay=0.0, sustain=1.0, release=0.1):
    """Attack / decay / sustain / release, clamped to fit `seconds`."""
    n = int(RATE * seconds)
    a, d, r = (max(1, int(RATE * x)) for x in (attack, max(decay, 1e-4), release))
    a, d, r = min(a, n), min(d, n), min(r, n)
    s = max(0, n - a - d - r)
    out = np.concatenate([
        np.linspace(0, 1, a, dtype=np.float32),
        np.linspace(1, sustain, d, dtype=np.float32),
        np.full(s, sustain, dtype=np.float32),
        np.linspace(sustain, 0, r, dtype=np.float32),
    ])
    return _fit(out, n)


def _fit(x, n):
    if len(x) == n:
        return x
    if len(x) > n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x), dtype=np.float32)])


def lowpass(x, cutoff):
    """One-pole. Enough to take the edge off a square wave, which is all these
    sounds need — a steeper filter would just cost clarity at this length."""
    a = math.exp(-2 * math.pi * cutoff / RATE)
    out = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):                 # short buffers; readability wins
        acc = (1 - a) * v + a * acc
        out[i] = acc
    return out


def comb(x, delay_ms, feedback=0.35, mix=0.3):
    """A cheap tail. Not a reverb — but a coin with no tail sounds like a click,
    and a real reverb is 200 lines for a 0.3 second sound."""
    d = max(1, int(RATE * delay_ms / 1000))
    out = x.copy()
    for i in range(d, len(out)):
        out[i] += feedback * out[i - d]
    return (1 - mix) * x + mix * out


def mix(*layers):
    n = max(len(l) for l in layers)
    out = np.zeros(n, dtype=np.float32)
    for layer in layers:
        out[:len(layer)] += layer
    return out


def dc_block(x, window_ms=18.0):
    """Remove any DC offset, by subtracting a slow moving average.

    A square wave with a duty cycle other than 0.5 carries a constant offset —
    `stomp` and `boss_die` both use one for their bite — and an offset means the
    waveform does not start or end at zero. That is an audible click at both ends,
    and it eats headroom that should be going into the sound.

    Box-filtered with a cumulative sum so it stays O(n): a per-sample recursive
    high-pass would be correct too, but the themes are half a million samples and
    a Python loop over them is not free.
    """
    w = max(3, int(RATE * window_ms / 1000) | 1)
    padded = np.concatenate([np.full(w // 2, x[0], np.float32), x,
                             np.full(w // 2, x[-1], np.float32)])
    cumulative = np.concatenate([[0.0], np.cumsum(padded, dtype=np.float64)])
    average = ((cumulative[w:] - cumulative[:-w]) / w).astype(np.float32)
    return (x - average[:len(x)]).astype(np.float32)


def normalize(x, peak=0.89, declick=True):
    """Leave headroom, remove DC, and force the ends to silence.

    Headroom because SpriteKit sums concurrent sounds — a set normalised to 1.0
    clips the moment two coins land together.

    `declick` must be **off for loops**. Removing DC shifts a sample that the
    envelope left at exactly zero to slightly off-zero, which clicks on a one-shot
    — but forcing a loop's ends to silence would put an audible dip at the loop
    point, which is worse. A loop's ends are matched to *each other* by
    `seamless`, not to zero.
    """
    x = dc_block(x)
    if declick:
        n = min(int(RATE * 0.002), len(x) // 4)
        if n > 1:
            x = x.copy()
            ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
            x[:n] *= ramp
            x[-n:] *= ramp[::-1]
    m = float(np.max(np.abs(x))) or 1.0
    return (x / m * peak).astype(np.float32)


def seamless(x, fade_ms=120):
    """Fold the tail over the head so a loop wraps without a click.

    The same offset-blend the backdrop layers use, in one dimension: the last
    `fade` samples cross-fade over the first, then get cropped, so the wrap point
    lands mid-phrase where the ear can't find it.
    """
    fade = min(int(RATE * fade_ms / 1000), len(x) // 3)
    if fade < 8:
        return x
    ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
    head = x[:fade] * ramp + x[-fade:] * (1 - ramp)
    return np.concatenate([head, x[fade:-fade]])


def write_wav(path, samples):
    data = np.clip(samples, -1.0, 1.0)
    pcm = (data * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(pcm)
    return len(data) / RATE


# ─────────────────────────────────────────────────────────────────────────────
# Sound effects
#
# Every one is a gesture first. The comments say what the gesture is, because
# that is the part worth preserving if someone re-voices the game.
# ─────────────────────────────────────────────────────────────────────────────

def sfx_jump():
    """Rising sweep, fast — leaving the ground."""
    d = 0.20
    body = triangle(sweep(340, 880, d, curve=0.6), d) * env(d, 0.004, 0.02, 0.55, 0.12)
    air = noise(d, 3) * env(d, 0.002, 0.04, 0.0, 0.05) * 0.12
    return normalize(mix(body, lowpass(air, 3000)))


def sfx_land():
    """A thud with a short body: mass arriving, no pitch content to speak of."""
    d = 0.16
    thud = sine(sweep(190, 70, d, 0.5), d) * env(d, 0.001, 0.03, 0.3, 0.10)
    dust = lowpass(noise(d, 7), 1400) * env(d, 0.001, 0.05, 0.0, 0.08) * 0.5
    return normalize(mix(thud, dust))


def sfx_coin():
    """Two quick steps up a fifth — the universal "you got a thing".

    One note reads as a beep; the interval is what makes it a reward.
    """
    a, b = 0.055, 0.13
    first = square(988, a, 0.5) * env(a, 0.002, 0.01, 0.7, 0.03)
    second = square(1480, b, 0.5) * env(b, 0.002, 0.02, 0.5, 0.09)
    out = np.concatenate([first, second])
    return normalize(comb(out * 0.7, 42, 0.30, 0.34))


def sfx_stomp():
    """Down-sweep with a squash: something soft has been landed on."""
    d = 0.18
    body = square(sweep(420, 120, d, 0.7), d, 0.35) * env(d, 0.001, 0.02, 0.4, 0.10)
    return normalize(lowpass(body, 2200))


def sfx_pop():
    """Very short up-sweep. A crate breaking, a bubble going."""
    d = 0.09
    return normalize(triangle(sweep(600, 1500, d, 0.4), d)
                     * env(d, 0.001, 0.01, 0.3, 0.06))


def sfx_hurt():
    """Falling minor third, wobbled — the cartoon "ow", not a pain sound."""
    d = 0.30
    wobble = 1 + 0.05 * np.sin(2 * np.pi * 11 * t_axis(d))
    body = saw(sweep(520, 300, d, 0.8) * wobble, d) * env(d, 0.004, 0.05, 0.45, 0.18)
    return normalize(lowpass(body, 2600))


def sfx_pound():
    """Impact: a low hit plus a bright crack, so it reads through the music."""
    d = 0.34
    boom = sine(sweep(150, 45, d, 0.45), d) * env(d, 0.001, 0.05, 0.35, 0.24)
    crack = lowpass(noise(d, 11), 5200) * env(d, 0.001, 0.02, 0.05, 0.12) * 0.55
    return normalize(mix(boom, crack))


def sfx_dash():
    """A whoosh: filtered noise swept upward, no pitch — speed, not a note."""
    d = 0.22
    n = lowpass(noise(d, 17), 6000)
    # Amplitude swell rather than a filter sweep: cheaper and reads the same at
    # this length.
    swell = np.linspace(0.2, 1.0, len(n), dtype=np.float32) ** 2
    tone = triangle(sweep(220, 700, d, 0.5), d) * 0.25
    return normalize(mix(n * swell * env(d, 0.01, 0.02, 0.8, 0.10), tone
                         * env(d, 0.01, 0.05, 0.4, 0.12)))


def sfx_spring():
    """Boing. A fast up-sweep with vibrato, which is the whole trick."""
    d = 0.34
    base = sweep(260, 1000, d, 0.35)
    vib = 1 + 0.10 * np.sin(2 * np.pi * 18 * t_axis(d))
    return normalize(triangle(base * vib, d) * env(d, 0.003, 0.04, 0.5, 0.22))


def sfx_checkpoint():
    """Three rising notes, resolved — safety, arrival, "keep going"."""
    notes, out = (784, 988, 1319), []
    for i, f in enumerate(notes):
        d = 0.10 if i < 2 else 0.24
        out.append(sine(f, d) * env(d, 0.004, 0.02, 0.6, d * 0.6) * 0.9)
    return normalize(comb(np.concatenate(out), 60, 0.32, 0.38))


def sfx_crusher():
    """Grinding stone: low noise with slow amplitude modulation."""
    d = 0.55
    n = lowpass(noise(d, 23), 700)
    grind = 1 + 0.5 * np.sin(2 * np.pi * 9 * t_axis(d))
    return normalize(n * grind * env(d, 0.02, 0.1, 0.7, 0.2))


def sfx_hover():
    """Helicopter hair: a rotor, so amplitude modulation at rotor rate.

    Held while the player hovers, which means SpriteKit repeats it — so it is a
    loop, and it is built as one. The length is an exact whole number of rotor
    cycles, so the modulation is periodic and the wrap has nothing to step over;
    an attack/release envelope here would put a dip at the loop point, which is
    the one artefact a sustained sound cannot hide.
    """
    rotor_hz, cycles = 26.0, 11
    d = cycles / rotor_hz
    depth = 0.7
    swirl = 1 - depth + depth * (0.5 + 0.5 * np.sin(2 * np.pi * rotor_hz * t_axis(d)))
    n = lowpass(noise(d, 29), 2200)
    return normalize(seamless(n * swirl, fade_ms=40), declick=False)


def sfx_win():
    """A little fanfare: root, fifth, octave, held. Four notes is a tune."""
    plan = [(523, 0.12), (659, 0.12), (784, 0.12), (1047, 0.42)]
    out = []
    for f, d in plan:
        voice = mix(square(f, d, 0.5) * 0.6, sine(f * 2, d) * 0.25)
        out.append(voice * env(d, 0.004, 0.03, 0.65, d * 0.5))
    return normalize(comb(np.concatenate(out), 85, 0.35, 0.42))


def sfx_boss_hit():
    """Big, wrong-sounding: two detuned saws falling together."""
    d = 0.26
    a = saw(sweep(300, 120, d, 0.7), d)
    b = saw(sweep(307, 123, d, 0.7), d)          # detune = menace
    return normalize(lowpass(mix(a, b) * env(d, 0.002, 0.03, 0.4, 0.16), 2000))


def sfx_boss_die():
    """A long collapse. Pitch and filter both fall; the tail does the work."""
    d = 0.95
    body = mix(saw(sweep(420, 60, d, 1.6), d),
               square(sweep(210, 30, d, 1.6), d, 0.4) * 0.5)
    return normalize(lowpass(body * env(d, 0.01, 0.2, 0.5, 0.6), 1500))


def sfx_menu():
    """One short click-tone. Menus need feedback, not personality."""
    d = 0.06
    return normalize(sine(1100, d) * env(d, 0.001, 0.01, 0.4, 0.04) * 0.8)


SFX = {
    "jump": sfx_jump, "land": sfx_land, "coin": sfx_coin, "stomp": sfx_stomp,
    "pop": sfx_pop, "hurt": sfx_hurt, "pound": sfx_pound, "dash": sfx_dash,
    "spring": sfx_spring, "checkpoint": sfx_checkpoint, "crusher": sfx_crusher,
    "hover": sfx_hover, "win": sfx_win, "boss_hit": sfx_boss_hit,
    "boss_die": sfx_boss_die, "menu": sfx_menu,
}


# ─────────────────────────────────────────────────────────────────────────────
# Music
#
# A theme is a mood, a key and a tempo. Four bars, seamlessly looped, with a
# bassline, a chord pad and an arpeggio — enough structure that it does not
# announce itself as a loop, little enough that it stays out of the way.
# ─────────────────────────────────────────────────────────────────────────────

SCALES = {
    "major":      [0, 2, 4, 5, 7, 9, 11],
    "minor":      [0, 2, 3, 5, 7, 8, 10],
    "lydian":     [0, 2, 4, 6, 7, 9, 11],      # bright, slightly unreal
    "dorian":     [0, 2, 3, 5, 7, 9, 10],      # minor but not sad
}

MOODS = {
    # mood → scale, tempo, root midi note, chord degrees per bar, brightness
    "calm":       ("lydian", 84,  57, [0, 3, 4, 3], 0.55),
    "adventure":  ("major",  108, 55, [0, 4, 5, 3], 0.75),
    "tense":      ("dorian", 120, 52, [0, 5, 3, 4], 0.45),
    "boss":       ("minor",  138, 45, [0, 0, 5, 4], 0.35),
    "evening":    ("dorian", 76,  50, [0, 3, 5, 4], 0.40),
}


def midi_hz(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def theme(mood="adventure", seed=1, bars=4):
    """One seamless loop for a level."""
    scale_name, bpm, root, degrees, bright = MOODS[mood]
    scale = SCALES[scale_name]
    rng = np.random.default_rng(seed)
    beat = 60.0 / bpm
    bar = beat * 4

    def degree_note(degree, octave=0):
        return root + scale[degree % len(scale)] + 12 * (octave + degree // len(scale))

    layers = []
    for index, degree in enumerate(degrees[:bars]):
        offset = index * bar

        # Bass: root on beats 1 and 3. The floor everything else sits on.
        for hit in (0.0, 2 * beat):
            d = beat * 0.9
            f = midi_hz(degree_note(degree) - 12)
            voice = mix(sine(f, d), triangle(f, d) * 0.3)
            layers.append((offset + hit, voice * env(d, 0.006, 0.08, 0.5, d * 0.4) * 0.55))

        # Pad: the triad, held across the bar, filtered by mood brightness.
        chord = [degree_note(degree + step) for step in (0, 2, 4)]
        pad = mix(*[triangle(midi_hz(n), bar) * 0.22 for n in chord])
        layers.append((offset, lowpass(pad, 700 + 2600 * bright)
                       * env(bar, 0.06, 0.2, 0.7, bar * 0.35)))

        # Arpeggio: eighth notes wandering the chord. The only random element,
        # seeded, so a theme is reproducible from its name.
        for step in range(8):
            if rng.random() < 0.28:
                continue                        # rests are what make it a phrase
            d = beat * 0.42
            n = degree_note(degree + int(rng.choice([0, 2, 4, 6])), octave=1)
            voice = square(midi_hz(n), d, 0.5) * 0.16
            layers.append((offset + step * beat / 2,
                           voice * env(d, 0.004, 0.02, 0.4, d * 0.5)))

    total = int(RATE * bar * min(bars, len(degrees)))
    # Room past the end for tails, which `seamless` then folds back over the head
    # — that fold is what makes the loop join mid-phrase instead of clicking.
    out = np.zeros(total + RATE, dtype=np.float32)
    for at, voice in layers:
        start = int(RATE * at)
        out[start:start + len(voice)] += voice[:len(out) - start]
    return normalize(seamless(out[:total + RATE // 2], fade_ms=400),
                     peak=0.62, declick=False)


THEMES = {
    "theme_grove":   ("calm", 11),
    "theme_hollow":  ("tense", 23),
    "theme_ridge":   ("adventure", 37),
    "theme_arena":   ("boss", 53),
    "theme_evening": ("evening", 67),
    "theme_menu":    ("calm", 83),
}


# ─────────────────────────────────────────────────────────────────────────────

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(here, "..", "Assets", "Audio"))
    ap.add_argument("--only", help="comma-separated names (SFX or themes)")
    ap.add_argument("--themes", action="store_true", help="music only")
    ap.add_argument("--sfx", action="store_true", help="sound effects only")
    ap.add_argument("--list", action="store_true", help="list what can be made")
    args = ap.parse_args()

    if args.list:
        print("sound effects:", ", ".join(sorted(SFX)))
        print("themes:       ", ", ".join(f"{n} ({m})" for n, (m, _) in
                                          sorted(THEMES.items())))
        print("moods:        ", ", ".join(sorted(MOODS)))
        return 0

    wanted = {n.strip() for n in args.only.split(",")} if args.only else None
    os.makedirs(args.out, exist_ok=True)
    made = 0

    if not args.themes:
        for name, build in sorted(SFX.items()):
            if wanted and name not in wanted:
                continue
            path = os.path.join(args.out, f"{name}.wav")
            seconds = write_wav(path, build())
            print(f"  ✓ {name}.wav  {seconds:.2f}s")
            made += 1

    if not args.sfx:
        for name, (mood, seed) in sorted(THEMES.items()):
            if wanted and name not in wanted:
                continue
            path = os.path.join(args.out, f"{name}.wav")
            seconds = write_wav(path, theme(mood, seed))
            print(f"  ✓ {name}.wav  {seconds:.2f}s  ({mood})")
            made += 1

    print(f"{made} file(s) → {os.path.normpath(args.out)}")
    if not made:
        print("nothing matched --only", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
