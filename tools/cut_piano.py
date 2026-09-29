"""MuseScore_General's "Grand Piano" preset as a plain SoundFont 2 file, cut to what the tracker plays.

Every reference note is rendered at velocity 64 (ReferenceNote's default), so only the zones that
sound at it are kept, the mezzo-forte layers rather than the fortissimo ones above 107. Each stereo
pair becomes one mono sample, the two channels mixed, since the reference is analysed in mono. The
Ogg Vorbis samples of the SoundFont 3 file are decoded to 16-bit PCM, and at 22,050 Hz the file is
13 MB against 100 MB for the preset as it was.

The result still relies on SoundFont modulators; flatten_soundfont.py works them out for
TinySoundFont, which does not implement them.

  pip install numpy soundfile librosa
  python tools/cut_piano.py --source MuseScore_General.sf3 --rate 22050 --out piano-cut.sf2
"""

from __future__ import annotations

import argparse
import io
import struct
from pathlib import Path

import numpy as np

GEN_PAN, GEN_KEYS, GEN_VELOCITIES, GEN_INSTRUMENT, GEN_SAMPLE = 17, 43, 44, 41, 53
VORBIS, MONO, RIGHT, LEFT = 0x10, 1, 2, 4


def chunks(buf: bytes, off: int, end: int):
    while off < end:
        cid, size = buf[off:off + 4].decode("latin1"), struct.unpack("<I", buf[off + 4:off + 8])[0]
        yield cid, off + 8, size
        off += 8 + size + (size & 1)


def records(buf: bytes, where: tuple[int, int], fmt: str) -> list[tuple]:
    off, size = where
    n = struct.calcsize(fmt)
    return [struct.unpack(fmt, buf[off + i:off + i + n]) for i in range(0, size, n)]


def read(path: Path) -> dict:
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"sfbk", "not a SoundFont"
    lists = {}
    for _, off, size in chunks(data, 12, len(data)):
        lists[data[off:off + 4].decode()] = {c: (o, s) for c, o, s in chunks(data, off + 4, off + size)}
    pdta = lists["pdta"]
    return {"data": data, "smpl": lists["sdta"]["smpl"],
            "phdr": records(data, pdta["phdr"], "<20sHHHIII"), "pbag": records(data, pdta["pbag"], "<HH"),
            "pmod": records(data, pdta["pmod"], "<HHhHH"), "pgen": records(data, pdta["pgen"], "<HH"),
            "inst": records(data, pdta["inst"], "<20sH"), "ibag": records(data, pdta["ibag"], "<HH"),
            "imod": records(data, pdta["imod"], "<HHhHH"), "igen": records(data, pdta["igen"], "<HH"),
            "shdr": records(data, pdta["shdr"], "<20sIIIIIBbHH")}


def zones(bags: list[tuple], first: int, last: int, gens: list[tuple], mods: list[tuple]) -> list[tuple[list, list]]:
    """(generators, modulators) of each zone from bag `first` up to, not including, `last`."""
    return [(gens[bags[b][0]:bags[b + 1][0]], mods[bags[b][1]:bags[b + 1][1]]) for b in range(first, last)]


def partner(sf: dict, index: int) -> int | None:
    """The other half of a stereo pair, by name: this SoundFont 3 leaves the links at zero."""
    name = sf["shdr"][index][0].rstrip(b"\0")
    other = name.replace(b"(L)", b"(R)") if b"(L)" in name else name.replace(b"(R)", b"(L)")
    return next((j for j, h in enumerate(sf["shdr"]) if h[0].rstrip(b"\0") == other and j != index), None)


def decode(sf: dict, index: int, rate: int | None) -> tuple[np.ndarray, int, int, int]:
    """A sample's PCM, its rate, and its loop in frames from its own start."""
    import soundfile
    name, start, end, loop_start, loop_end, sample_rate, *_rest, kind = sf["shdr"][index]
    off, _ = sf["smpl"]
    raw = sf["data"][off + start:off + end] if kind & VORBIS else None
    if raw is not None:
        # SoundFont 3: start and end are bytes of an Ogg stream, the loop is frames from its start
        pcm, sample_rate = soundfile.read(io.BytesIO(raw), dtype="float32")
    else:
        frames = np.frombuffer(sf["data"][off + 2 * start:off + 2 * end], "<i2")
        pcm, loop_start, loop_end = frames.astype(np.float32) / 32768, loop_start - start, loop_end - start
    if pcm.ndim > 1:
        pcm = pcm.mean(1)
    if rate and rate < sample_rate:
        import librosa
        scale = rate / sample_rate
        pcm = librosa.resample(pcm, orig_sr=sample_rate, target_sr=rate, res_type="soxr_hq")
        loop_start, loop_end, sample_rate = int(round(loop_start * scale)), int(round(loop_end * scale)), rate
    return np.clip(np.round(pcm * 32767), -32768, 32767).astype("<i2"), sample_rate, loop_start, loop_end


def riff(cid: str, body: bytes) -> bytes:
    return cid.encode() + struct.pack("<I", len(body)) + body + (b"\0" if len(body) & 1 else b"")


def listing(kind: str, parts: list[bytes]) -> bytes:
    return riff("LIST", kind.encode() + b"".join(parts))


def zstr(text: str, size: int | None = None) -> bytes:
    raw = text.encode("latin1")
    if size is not None:
        return raw[:size - 1].ljust(size, b"\0")
    raw += b"\0"
    return raw + (b"\0" if len(raw) & 1 else b"")


def covers(gens: list[tuple], velocity: int) -> bool:
    ranges = [a for o, a in gens if o == GEN_VELOCITIES]
    return not ranges or (ranges[0] & 255) <= velocity <= (ranges[0] >> 8)


def write(sf: dict, bank: int, program: int, out: Path, rate: int | None, notice: str, velocity: int,
          stereo: str = "mix") -> dict:
    presets = sf["phdr"]
    k = next(i for i, p in enumerate(presets[:-1]) if p[2] == bank and p[1] == program)
    preset_zones = [z for z in zones(sf["pbag"], presets[k][3], presets[k + 1][3], sf["pgen"], sf["pmod"])
                    if covers(z[0], velocity)]
    instruments = sorted({g[1] for gens, _ in preset_zones for g in gens if g[0] == GEN_INSTRUMENT})
    inst_zones = {}
    for i in instruments:
        kept = []
        for gens, mods in zones(sf["ibag"], sf["inst"][i][1], sf["inst"][i + 1][1], sf["igen"], sf["imod"]):
            if not covers(gens, velocity):
                continue
            sample = next((a for o, a in gens if o == GEN_SAMPLE), None)
            if sample is not None and sf["shdr"][sample][9] & RIGHT:
                continue  # the right half is mixed into the left's mono sample
            kept.append(([(o, a) for o, a in gens if o != GEN_PAN], mods))
        inst_zones[i] = kept
    samples = sorted({g[1] for zs in inst_zones.values() for gens, _ in zs for g in gens if g[0] == GEN_SAMPLE})
    sample_map = {s: j for j, s in enumerate(samples)}
    inst_map = {i: j for j, i in enumerate(instruments)}

    pcm, shdr, position = [], [], 0
    for s in samples:
        name, _, _, _, _, _, pitch, correction, _, kind = sf["shdr"][s]
        audio, sample_rate, loop_start, loop_end = decode(sf, s, rate)
        if stereo == "mix" and kind & LEFT and (other := partner(sf, s)) is not None:
            right = decode(sf, other, rate)[0]
            n = min(len(audio), len(right))
            audio = ((audio[:n].astype(np.int32) + right[:n]) // 2).astype("<i2")
        if kind & LEFT:
            name = name.replace(b"(L)", b"   ")
        start, end = position, position + len(audio)
        shdr.append(struct.pack("<20sIIIIIBbHH", name, start, end, start + loop_start, start + loop_end, sample_rate,
                                pitch, correction, 0, MONO))
        pcm += [audio, np.zeros(46, "<i2")]  # SoundFont 2 wants 46 zero frames after each sample
        position = end + 46
    shdr.append(struct.pack("<20sIIIIIBbHH", zstr("EOS", 20), 0, 0, 0, 0, 0, 0, 0, 0, 0))

    def pack_zones(zone_list, remap_oper, remap):
        bags, gens, mods = [], [], []
        for zone_gens, zone_mods in zone_list:
            bags.append((len(gens), len(mods)))
            gens += [(o, remap[a] if o == remap_oper else a) for o, a in zone_gens]
            mods += list(zone_mods)
        return bags, gens, mods

    pbags, pgens, pmods = pack_zones(preset_zones, GEN_INSTRUMENT, inst_map)
    ibags, igens, imods, inst = [], [], [], []
    for i in instruments:
        bags, gens, mods = pack_zones(inst_zones[i], GEN_SAMPLE, sample_map)
        inst.append((sf["inst"][i][0], len(ibags)))
        ibags += [(g + len(igens), m + len(imods)) for g, m in bags]
        igens += gens
        imods += mods
    pbags.append((len(pgens), len(pmods)))
    ibags.append((len(igens), len(imods)))
    terminal_mod, terminal_gen = [(0, 0, 0, 0, 0)], [(0, 0)]

    name = presets[k][0]
    pdta = [
        riff("phdr", struct.pack("<20sHHHIII", name, program, bank, 0, 0, 0, 0)
             + struct.pack("<20sHHHIII", zstr("EOP", 20), 0, 0, len(pbags) - 1, 0, 0, 0)),
        riff("pbag", b"".join(struct.pack("<HH", *b) for b in pbags)),
        riff("pmod", b"".join(struct.pack("<HHhHH", *m) for m in pmods + terminal_mod)),
        riff("pgen", b"".join(struct.pack("<HH", *g) for g in pgens + terminal_gen)),
        riff("inst", b"".join(struct.pack("<20sH", *i) for i in inst) + struct.pack("<20sH", zstr("EOI", 20), len(ibags) - 1)),
        riff("ibag", b"".join(struct.pack("<HH", *b) for b in ibags)),
        riff("imod", b"".join(struct.pack("<HHhHH", *m) for m in imods + terminal_mod)),
        riff("igen", b"".join(struct.pack("<HH", *g) for g in igens + terminal_gen)),
        riff("shdr", b"".join(shdr)),
    ]
    info = [riff("ifil", struct.pack("<HH", 2, 4)), riff("isng", zstr("EMU8000")),
            riff("INAM", zstr("Grand Piano (MuseScore_General v0.2), velocity 64, mono")),
            riff("ICOP", zstr("Frank Wen 2000-02, Michael Cowgill 2014-17, S. Christian Collins 2018-20")),
            riff("ICMT", zstr(notice[:65000])), riff("ISFT", zstr("SoloPianoTracker cut_piano.py"))]
    body = b"sfbk" + listing("INFO", info) + listing("sdta", [riff("smpl", np.concatenate(pcm).tobytes())]) \
        + listing("pdta", pdta)
    out.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    return {"preset": name.rstrip(b"\0").decode("latin1"), "instruments": len(instruments), "samples": len(samples),
            "seconds": position / (rate or 44100), "bytes": out.stat().st_size}


def main() -> int:
    here = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="MuseScore_General.sf3 (v0.2)")
    ap.add_argument("--out", default="piano-cut.sf2")
    ap.add_argument("--rate", type=int, default=0, help="resample to this rate to save space (0 keeps each sample's own)")
    ap.add_argument("--velocity", type=int, default=64, help="keep only the zones that sound at this velocity")
    ap.add_argument("--stereo", choices=("mix", "left"), default="mix",
                    help="both channels of each stereo sample mixed, or the left alone")
    ap.add_argument("--license", default=str(here / "Piano" / "LICENSE.md"))
    args = ap.parse_args()
    notice = Path(args.license).read_text()
    print(write(read(Path(args.source)), 0, 0, Path(args.out), args.rate or None, notice, args.velocity, args.stereo))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
