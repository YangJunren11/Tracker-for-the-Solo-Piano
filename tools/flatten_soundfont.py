"""A SoundFont with nothing left for the player to interpret: every modulator worked out in advance.

TinySoundFont, which plays the tracker's reference, does not implement SoundFont modulators, and
MuseScore General's piano leans on them: its filter sits at about 300 Hz until the key played opens
it by up to 8000 cents, the note's loudness and the attack's brightness hang on the velocity, and
the key sets the release. Ignored, every note above the bass is muffled.

Every reference note is played at velocity 64 (ReferenceNote's default), so each modulator's effect
is a constant for each key. This writes one instrument zone per key and layer, each carrying every
generator's total (the instrument's, the preset's added to it, and each modulator evaluated at
velocity 64 and that key, as SoundFont 2.04 defines them: sources, curves, the default modulators
and which zone's replace which) and no modulators. The samples are the same.

  python tools/flatten_soundfont.py --source piano-cut.sf2      # Piano/piano.sf2
"""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

import numpy as np

from cut_piano import listing, read, riff, zones, zstr

KEY_RANGE, VEL_RANGE, INSTRUMENT, SAMPLE_ID = 43, 44, 41, 53
# Generators that are not amounts to add up: ranges, links, and the ones only an instrument may set
NOT_ADDITIVE = {KEY_RANGE, VEL_RANGE, INSTRUMENT, SAMPLE_ID, 0, 1, 2, 3, 4, 12, 45, 46, 47, 50, 54, 57, 58}
# SoundFont 2.04 defaults, for a generator a zone leaves out but a preset or modulator adds to
DEFAULTS = {8: 13500, 21: -12000, 22: 0, 23: -12000, 24: 0, 25: -12000, 26: -12000, 27: -12000, 28: -12000,
            29: 0, 30: -12000, 33: -12000, 34: -12000, 35: -12000, 36: -12000, 37: 0, 38: -12000, 56: 100}
SIGNED = lambda a: a - 65536 if a > 32767 else a
VELOCITY = 64

# The default modulators every instrument zone starts with (2.04, 8.4); an identical one in a zone
# replaces it. Only these two depend on anything but controllers left at rest.
DEFAULT_MODULATORS = [(0x0502, 48, 960, 0, 0),  # velocity -> attenuation, negative unipolar concave
                      (0x0102, 8, -2400, 0, 0)]  # velocity -> filter cutoff, negative unipolar linear


def concave(x: float) -> float:
    return 1.0 if x >= 1 else min(1.0, max(0.0, -20 / 96 * math.log10((1 - x) ** 2)))


def source(value: int, key: int) -> float:
    """A modulator source's output, for this velocity and key."""
    index, cc, backwards, bipolar, kind = value & 127, (value >> 7) & 1, (value >> 8) & 1, (value >> 9) & 1, value >> 10
    if cc:
        return 0.0  # controllers at rest; none here moves with the key
    if index == 0:  # "no controller": a constant 1
        return 1.0
    x = {2: VELOCITY, 3: key}.get(index)
    if x is None:
        return 0.0  # pressure, pitch wheel: at rest
    x /= 127
    if backwards:
        x = 1 - x
    curve = [lambda v: v, concave, lambda v: 1 - concave(1 - v), lambda v: 1.0 if v >= 0.5 else 0.0][kind]
    if bipolar:
        return curve(2 * x - 1) if x >= 0.5 else -curve(1 - 2 * x)
    return curve(x)


def modulated(mods: list[tuple], key: int) -> dict[int, float]:
    """Each destination's total from these modulators."""
    out: dict[int, float] = {}
    for src, dest, amount, amount_src, transform in mods:
        value = amount * source(src, key) * (source(amount_src, key) if amount_src else 1.0)
        if transform == 2:
            value = abs(value)
        out[dest] = out.get(dest, 0.0) + value
    return out


def replace(base: list[tuple], local: list[tuple]) -> list[tuple]:
    """Modulators of a zone over those it inherits: identical source, destination, amount source and
    transform replace, the rest add."""
    same = lambda m: (m[0], m[1], m[3], m[4])
    kept = [m for m in base if same(m) not in {same(n) for n in local}]
    return kept + list(local)


def flatten(sf: dict, bank: int = 0, program: int = 0) -> list[tuple[int, dict[int, int]]]:
    """(sample, generators) for every key and layer that sounds at velocity 64."""
    presets = sf["phdr"]
    k = next(i for i, p in enumerate(presets[:-1]) if p[2] == bank and p[1] == program)
    pzones = zones(sf["pbag"], presets[k][3], presets[k + 1][3], sf["pgen"], sf["pmod"])
    pglobal = pzones[0] if pzones and not any(o == INSTRUMENT for o, _ in pzones[0][0]) else ([], [])
    out = []
    for pgens, pmods in pzones:
        instrument = next((a for o, a in pgens if o == INSTRUMENT), None)
        if instrument is None:
            continue
        preset = {o: SIGNED(a) for o, a in pglobal[0]} | {o: SIGNED(a) for o, a in pgens}
        vr = preset.get(VEL_RANGE)
        if vr is not None and not ((vr & 255) <= VELOCITY <= ((vr >> 8) & 255)):
            continue
        preset_mods = replace(pglobal[1], pmods)
        izones = zones(sf["ibag"], sf["inst"][instrument][1], sf["inst"][instrument + 1][1], sf["igen"], sf["imod"])
        iglobal = izones[0] if izones and not any(o == SAMPLE_ID for o, _ in izones[0][0]) else ([], [])
        for igens, imods in izones:
            sample = next((a for o, a in igens if o == SAMPLE_ID), None)
            if sample is None:
                continue
            gens = {o: a for o, a in iglobal[0]} | {o: a for o, a in igens}
            ivr = gens.get(VEL_RANGE)
            if ivr is not None and not ((ivr & 255) <= VELOCITY <= ((ivr >> 8) & 255)):
                continue
            keys = gens.get(KEY_RANGE, 127 << 8)
            pkeys = preset.get(KEY_RANGE, 127 << 8)
            low, high = max(keys & 255, pkeys & 255), min((keys >> 8) & 255, (pkeys >> 8) & 255)
            inst_mods = replace(replace(DEFAULT_MODULATORS, iglobal[1]), imods)
            for key in range(low, high + 1):
                total: dict[int, float] = {}
                for o, a in gens.items():
                    total[o] = SIGNED(a) if o not in (KEY_RANGE, VEL_RANGE) else a
                for o, a in preset.items():
                    if o in NOT_ADDITIVE:
                        continue
                    total[o] = total.get(o, DEFAULTS.get(o, 0)) + a
                for mods in (inst_mods, preset_mods):
                    for dest, value in modulated(mods, key).items():
                        if dest not in NOT_ADDITIVE:
                            total[dest] = total.get(dest, DEFAULTS.get(dest, 0)) + value
                total.pop(VEL_RANGE, None)
                total.pop(SAMPLE_ID, None)
                total[KEY_RANGE] = key | (key << 8)
                out.append((sample, {o: int(round(v)) for o, v in total.items()}))
    return out


def write(sf: dict, flat: list[tuple[int, dict[int, int]]], out: Path, notice: str) -> dict:
    samples = sorted({s for s, _ in flat})
    remap = {s: i for i, s in enumerate(samples)}
    off, _ = sf["smpl"]
    data = sf["data"]
    pcm, shdr, position = [], [], 0
    for s in samples:
        name, start, end, loop_start, loop_end, rate, pitch, correction, _, kind = sf["shdr"][s]
        frames = np.frombuffer(data[off + 2 * start:off + 2 * end], "<i2")
        new_start = position
        shdr.append(struct.pack("<20sIIIIIBbHH", name, new_start, new_start + len(frames),
                                new_start + loop_start - start, new_start + loop_end - start,
                                rate, pitch, correction, 0, 1))
        pcm += [frames, np.zeros(46, "<i2")]
        position += len(frames) + 46
    shdr.append(struct.pack("<20sIIIIIBbHH", zstr("EOS", 20), 0, 0, 0, 0, 0, 0, 0, 0, 0))

    igens, ibags = [], []
    for sample, gens in flat:
        ibags.append((len(igens), 0))
        igens.append((KEY_RANGE, gens.pop(KEY_RANGE)))  # first, as the specification asks
        for o in sorted(gens):
            igens.append((o, gens[o] & 0xFFFF))
        igens.append((SAMPLE_ID, remap[sample]))  # last
    ibags.append((len(igens), 0))
    terminal_mod = struct.pack("<HHhHH", 0, 0, 0, 0, 0)
    pdta = [
        riff("phdr", struct.pack("<20sHHHIII", zstr("Piano (flattened)", 20), 0, 0, 0, 0, 0, 0)
             + struct.pack("<20sHHHIII", zstr("EOP", 20), 0, 0, 1, 0, 0, 0)),
        riff("pbag", struct.pack("<HH", 0, 0) + struct.pack("<HH", 1, 0)),
        riff("pmod", terminal_mod),
        riff("pgen", struct.pack("<HH", INSTRUMENT, 0) + struct.pack("<HH", 0, 0)),
        riff("inst", struct.pack("<20sH", zstr("Piano (flattened)", 20), 0) + struct.pack("<20sH", zstr("EOI", 20), len(ibags) - 1)),
        riff("ibag", b"".join(struct.pack("<HH", *b) for b in ibags)),
        riff("imod", terminal_mod),
        riff("igen", b"".join(struct.pack("<HH", *g) for g in igens) + struct.pack("<HH", 0, 0)),
        riff("shdr", b"".join(shdr)),
    ]
    info = [riff("ifil", struct.pack("<HH", 2, 4)), riff("isng", zstr("EMU8000")),
            riff("INAM", zstr("Grand Piano (MuseScore_General v0.2), flattened for TinySoundFont")),
            riff("ICOP", zstr("Frank Wen 2000-02, Michael Cowgill 2014-17, S. Christian Collins 2018-20")),
            riff("ICMT", zstr(notice[:65000])), riff("ISFT", zstr("SoloPianoTracker flatten_soundfont.py"))]
    body = b"sfbk" + listing("INFO", info) + listing("sdta", [riff("smpl", np.concatenate(pcm).tobytes())]) \
        + listing("pdta", pdta)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    return {"zones": len(flat), "samples": len(samples), "bytes": out.stat().st_size}


def main() -> int:
    here = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="piano-cut.sf2", help="the piano from cut_piano.py")
    ap.add_argument("--out", default=str(here / "Piano" / "piano.sf2"))
    ap.add_argument("--license", default=str(here / "Piano" / "LICENSE.md"))
    args = ap.parse_args()
    sf = read(Path(args.source))
    print(write(sf, flatten(sf), Path(args.out), Path(args.license).read_text()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
