# SoloPianoTracker

Follows a solo piano performance through its score as it is played. Give it the score and the audio
from a microphone, and it reports the bar being played about 40 times a second.

It is a Swift port of the online time warping follower in
[Matchmaker](https://github.com/pymatchmaker/matchmaker) (Arzt & Widmer, 2010), with changes for
following a pianist who is practising: starting anywhere, stopping, going back, playing slowly, and
playing in a noisy room. It is plain Swift and Foundation, with TinySoundFont (included) and zlib.
It is tested on macOS, and it builds for Android with the Swift SDK for Android.

```
swift build -c release
swift test -c release -Xswiftc -enable-testing    # 23 tests, about 15 s once built
```

Build it optimised. Unoptimised, the tests take over ten minutes, and a search of the whole piece is
too slow to keep up with live audio.

## Using it

```swift
import SoloPianoTracker

// The score, with its repeats written out and its notes timed in reference seconds
let draft = try MusicXMLReader.read(contentsOf: scoreURL)
let score = draft.score(title: draft.suggestedTitle, composer: draft.suggestedComposer, tempo: draft.suggestedTempo)
let plan = Plan(score: score, setup: .defaults(for: score))

// The settings the figures below were measured with
var options = FollowerOptions()
options.localReanchor = true
options.localReachSeconds = 1.5
options.localImprovement = 0.7
options.localEverySeconds = 2

// A reference at each of four tempos, played on the bundled piano and analysed as it plays
let extractor = ChromaExtractor(sampleRate: 44100, hopLength: 1024, fftLength: 2048)
let rates = [2, 1, 0.5, 0.25]
let references = try SoundFontRenderer(soundBank: pianoURL, sampleRate: 44100).analyse(rates.map { rate in
    plan.referenceNotes.map { ReferenceNote(onset: $0.onset / rate, duration: $0.duration / rate, pitch: $0.pitch) }
}, extractor: extractor)
let lastOnset = plan.referenceNotes.map(\.onset).max() ?? 0
let tracker = TempoChoice(members: zip(rates, references).map { rate, reference in
    TempoChoice.Member(rate: rate, follower: ScoreFollower(
        referenceFeatures: reference.features, referenceLevels: reference.levels, lastOnset: lastOnset / rate,
        extractor: extractor, options: options, movementStarts: plan.movementStarts.map { $0 / rate },
        barStarts: plan.barStarts.map { $0 / rate }, backStep: 1))
}, barStarts: plan.barStarts)

// Mono audio at 44.1 kHz, in buffers of any size, as it arrives
var hops = HopChunker(hopLength: extractor.hopLength)
hops.append(samples) { hop in
    guard let position = tracker.process(hop),
          let bar = plan.bar(atQuarters: plan.timeline.quarters(atSeconds: position.accepted)) else { return }
    print(plan.describe(bar))  // "bar 12", or "II, bar 12" in a work of several movements
}

// Told where the pianist is starting (bar 40), the tracker is there at once
tracker.begin(atReferenceSeconds: plan.timeline.seconds(atQuarters: plan.positions(ofBarNumbered: 40)[0]))
```

`piano-tracker` does the same from the command line on a WAV recording and writes every position to
files. Its options are listed at the top of `Sources/piano-tracker/main.swift`.

## What is Matchmaker's

| Here | Matchmaker |
|---|---|
| `ChromaExtractor` (`Chroma.swift`) | `librosa.feature.chroma_stft`, as its `ChromagramProcessor` calls it, with the tuning fixed at A440 |
| `OnlineTimeWarping.swift` | `dp/oltw_arzt.py` (`OnlineTimeWarpingArztFrame`) and `dp/dtw_loop.pyx` |
| `ScoreFollower.swift` | the frame buffering in `io/audio.py`, and the follower's run loop |
| `SoundFontRenderer.swift` | `utils/misc.py`, `generate_score_audio`, with TinySoundFont in place of FluidSynth |

Everything Matchmaker has no counterpart for can be switched off (`silenceGate`, `recovery` and
`freezeInRests` false, `calibrateSeconds` 0). Then the tracker gives Matchmaker's position on 99.94%
to 100% of frames in each of 7 ASAP recordings, and is never more than 2 frames (46 ms) apart. The
share of time within 0.5 s is the same to a tenth of a percent in every one. The chroma features agree
to 3e-6, and the frames that differ are near-ties decided by that rounding.

## What changed

### The alignment

- **Cost is normalised from the last relocation.** Matchmaker divides each cell's accumulated cost
  by `inputIndex + scoreIndex`, counted from the start of the performance. Here the steps are
  counted from the last relocation (`originInput`, `originFrame`). Otherwise, after a move a minute
  into a piece, every nearby cell looks equally good. Until something relocates, the two are the
  same.
- **The position can step back** (`backStep`, 1 in the settings above). Matchmaker's path only
  advances or stands still, so an error made where the music gives no cue to advance, such as a held,
  pedalled chord, was permanent. It may now retreat one reference frame per input frame.
- **Local re-anchor** (`localReanchor`). Every `localEverySeconds`, the last `localSeconds` of playing
  are compared with the reference within `localReachSeconds` of the position. If another place fits
  `localImprovement` better, the position moves there. This runs only while the playing is near the
  rendered tempo (`localPaceRange`, 0.8 to 1.25 over the last 8 s), because it compares second for
  second.
- **The search runs in parallel.** Places are shared among the cores, and chroma bins are compared
  four at a time. The output is unchanged.

### Silence and noise

- **A gate on what looks like notes** (`minPeakiness`, 0.62). Chroma is normalised per frame, so a
  frame of hum comes out as every pitch class at once and matches anything. A frame counts as playing
  only if its chroma is peaked, measured as 1 minus the mean of the normalised chroma. Mains hum
  measures 0.34 and piano playing about 0.74, whatever the gain. Five such frames in a row
  (`startFrames`) start the piece. The gate is armed before the first note, and again within
  `movementGateSeconds` (1.5 s) of a movement's end (`gateBetweenMovements`).
- **Listening to the room.** The seconds before the first note are the room with nobody playing. The
  gate is raised to the room's 99th percentile of peakiness plus `calibrationMargin`. It is never
  lowered, and never raised above `maxPeakiness` (0.7). A room above that is reported as `tooNoisy`
  (`RoomCalibration`). This needs `calibrateSeconds` (2 s) of waiting. A recording of the room can
  also set a level floor (`RoomNoise`), which is off by default.
- **Rests.** While the reference is silent and the input does not look like notes (`restPeakiness`,
  0.5), the position is held (`freezeInRests`). When playing returns after a wait longer than
  `reanchorAfterSeconds` (2 s), it picks up at the rest's first note (`reanchorAfterRest`). Releasing
  the hold takes `resumeFrames` (3) frames in a row above `minPeakiness`.

### Getting lost, and finding the place again

- **A trusted place.** The tracker trusts where it is after `trustSeconds` (2 s) at confidence
  `trustConfidence` (0.3) or more, without a relocation, at a place the music could have reached from
  the last trusted one.
- **Doubt.** After 2 s of low confidence the state becomes `.uncertain`. The accepted path goes on
  following, and nothing moves the trusted place.
- **Candidates near the trusted place.** The search runs from `recoveryBarsBack` (8) bars behind the
  trusted place to `recoveryBarsAhead` (8) bars ahead, plus `recoveryProgressRate` (1.5) reference
  seconds for every second since. It counts in played bars (`Plan.barStarts`), so a repeat is
  ordinary progress, and it never reaches back into an earlier movement. A candidate must fit
  `searchMargin` (1.15) better than the best place outside its own neighbourhood. Those rivals are
  drawn from `recoveryContextSeconds` (10 s) around the region.
- **Tried before moving.** A candidate runs on a path of its own. After `confirmSeconds` (1.5 s) of
  playing heard since it was proposed, it must fit that playing `confirmImprovement` (0.9) better than
  the accepted path, and it must have moved at a believable pace. Only then does it become the
  accepted path (`Relocation.structural`).
- **Further, with more evidence.** Up to `catchUpBarsAhead` (32) bars ahead, a candidate needs
  `catchUpMargin` (1.3), or two hits from blocks that share no playing. It then has to survive a 5 s
  trial that ends in a second search. After `distantAfterSeconds` (5 s) the whole piece is searched,
  with `distantMargin` (1.3) and a 4 s trial.
- **Being told.** `begin(atReferenceSeconds:)` makes a place trusted at once.
- **Ending.** Following stops only when the accepted path has stood at the last note for
  `finishHoldSeconds` (0.25 s).
- **Reported positions follow the accepted path** (`Position.accepted`), which only a confirmed
  candidate can move by more than the warping's own steps.

### Tempo

- **The tempo comes from the opening bars** (`TempoChoice`). Followers at 2, 1, ½ and ¼ of the score's
  tempo start together. Once the one that fits best has followed `openingBars` (10) bars, or after
  `openingSeconds` (60 s), it is kept and the rest stop. Fit is measured by laying the last 2 s of
  playing straight against each member's reference, and averaging over every sounding frame since the
  start. Another tempo must fit 5% better than the score's own (`preference`). A restart chooses
  again. Positions come back at the score's tempo.

### The reference

- **TinySoundFont replaces FluidSynth.** It plays MuseScore General's grand piano, which is the
  SoundFont Matchmaker renders with through partitura. TinySoundFont does not implement SoundFont
  modulators, so `Piano/piano.sf2` has every modulator worked out for velocity 64 at each key. It is
  velocity 64 only, mono, and 22,050 Hz, which makes it 13 MB. `tools/cut_piano.py` and
  `tools/flatten_soundfont.py` make it from `MuseScore_General.sf3`.
- **References are analysed as they play** (`SoundFontRenderer.analyse`), with several tempos side by
  side, so a quarter-speed reference is never held whole in memory.

### The score

Matchmaker's follower takes a rendered score.

- `MusicXMLReader` reads `.musicxml` and compressed `.mxl` files.
- `Plan` writes out repeats, endings and D.C./D.S., with each movement taking its own jump. It gives
  the bar and movement starts that bound recovery and re-arm the gate.

## Data

The recordings and scores are from [ASAP](https://github.com/fosfrancesco/asap-dataset) (Foscarin et
al., ISMIR 2020): scores with beat annotations aligned to
[MAESTRO](https://magenta.tensorflow.org/datasets/maestro) performances (Hawthorne et al., 2019), all
under CC BY-NC-SA 4.0 and not included here.

- **All:** 436 performances with trustworthy ground truth, 31.3 hours.
- **Tuning:** 100 of them, one per piece, across eleven composers. Every setting was chosen on these,
  then checked once on all 436.
- **Eleven:** 11 recordings (Bach, Beethoven ×2, Chopin, Haydn, Liszt ×2, Rachmaninoff ×2, Schubert,
  Schumann).
- **Tempo:** 20 takes of 60 s each, 12 of them Bach. Settings were chosen on 6 and are reported on
  the other 14. Slow playing is the recording time-stretched with its pitch kept, by a phase vocoder
  that costs 1 to 3.8 points by itself, so those figures are a floor. A wrong tempo marking is the
  reference rendered too fast or too slow.
- **Room:** a recording of a real room with nobody playing: -33 dB, with mains hum at 48 Hz and a
  cluster from 97 to 199 Hz.

The figures are the share of playing time in which the reported position is within a quarter note,
a bar, or 0.5 s of the ground truth. References were rendered with FluidSynth and MuseScore General,
as Matchmaker renders them, unless a row says TinySoundFont.

### All 436 performances

| | immediate search of the whole piece | bounded recovery, no re-anchor | bounded, re-anchor at any pace | **bounded, re-anchor near the rendered tempo** |
|---|---|---|---|---|
| within a quarter note | 80.7% | 80.0% | 80.8% | **81.6%** |
| within a bar | 92.9% | 92.5% | 93.1% | **93.7%** |
| more than 2 bars ahead / behind | 1.19% / 3.17% | 0.37% / 4.45% | 0.60% / 3.63% | **0.34% / 3.38%** |
| relocations landing more than 8 bars wrong | 46 | 17 | 27 | **14** |
| ... of them ahead / more than 30 bars ahead | 30 / 21 | 1 / 0 | 3 / 0 | **0 / 0** |

### Restarts

These are cut from the tuning set's 100 recordings: going back six bars, going back from 60% of the
take to 40%, and starting at 40%. "Found" means within a bar for 2 s running.

| | immediate search: found, median | bounded: found, median | relocations more than 8 bars wrong (immediate → bounded) |
|---|---|---|---|
| back six bars, not told | 91/100, 15.6 s | **96/100, 14.7 s** | 20 → **10** |
| back from 60% to 40%, not told | 77/100, 27.6 s | 74/100, 63.9 s | 31 → 38 |
| starting at 40%, not told | 85/100, 20.8 s | 61/100, 46.0 s | 16 → 60 |
| any of them, told | 299/300, under 0.4 s | **300/300, under 0.4 s** | 45 → **20** |

On the eleven recordings, plain online time warping (Matchmaker) found its place after a mid-piece
start in 0 of 11 takes, and after a jump back in 3 of 11. Told the bar, this tracker found it in 11 of
11 for both, with medians of 0.0 s and 0.3 s.

### Small errors

On the eleven recordings, at tempo, with the re-anchor running at any pace:

| | neither | `backStep 1` | `backStep 1` and local re-anchor |
|---|---|---|---|
| within 0.5 s | 83.5% | 83.8% | **85.1%** |
| median error | 121 ms | 116 ms | **109 ms** |
| frames where the position stood still | 48.7% | 42.9% | **42.3%** |
| longest freeze, averaged over takes | 2.67 s | 1.61 s | **1.46 s** |

### Tempo

On the 14 held-out takes, within a quarter note:

| | 1.00x | 0.60x | 0.25x | marked 4x too fast | marked 2x too slow | speeding up, 0.4x to 1x | mean of 13 conditions |
|---|---|---|---|---|---|---|---|
| one reference, at the score's tempo | 95.1% | 95.4% | 67.5% | 38.0% | 59.5% | 90.5% | 83.3% |
| **tempo from the opening bars** | 95.1% | 92.7% | **91.7%** | **92.4%** | **92.9%** | 83.6% | **92.2%** |
| reference rendered at the speed played (not possible live) | 95.1% | 94.2% | 86.3% | 95.1% | 95.1% | | |

At tempo, on the tuning set, following four tempos costs about one point against following one.

### Noise

The eleven recordings, and the room:

| | room alone: stays at bar 1 | room, then the performance: within 0.5 s | performance alone: within 0.5 s |
|---|---|---|---|
| level threshold only | 0/11 (median bar 9, worst 97) | 54.0% | 81.7% |
| **peakiness gate and start latch** | **11/11** | **77.9%** | **83.0%** |
| level floor measured in the room (`RoomNoise`) | 11/11 | 76.4% | 74.4% |

With the room mixed in as loud as the playing (0 dB), 67.1% is within 0.5 s with the gate, and
54.7% without it.

### Rests

The room was inserted into the longest written rest of 7 recordings.

| waited | without holding: drift, back in place | hold and pick up: drift, back in place | rest of the take within 0.5 s (without → with) |
|---|---|---|---|
| 5 s | 0.5 bars, 0.0 s | 0.5 bars, 0.4 s | 81.4% → 80.7% |
| 20 s | 1.0 bars, 3.5 s | 0.5 bars, 0.4 s | 79.6% → 80.8% |
| 40 s | 1.5 bars, 6.4 s | 0.5 bars, 0.4 s | 77.1% → 78.9% |

Across a quiet 60 s at a movement's end, re-arming the gate took the searches of the whole piece
from 56 to 0 and cut the CPU used by more than half, with the position unchanged.

### The reference

On the tuning set, following four tempos, within a bar:

| TinySoundFont playing | within a bar |
|---|---|
| MuseScore General's piano as published (modulators ignored) | 81.0% |
| **`Piano/piano.sf2`** (modulators worked out) | **90.9%** |

`SynthReference`, a few sine partials with a decay, is about 30 points worse within a quarter note
than a sampled piano on all 436 performances. The tests use it, playing the performance on a
different setting of it.

### Speed

Following one tempo takes about 0.07 ms of one laptop core per 23 ms hop, and following four takes
0.1 ms. The heaviest case is searching after a jump back of several pages in a 21-minute,
four-movement piece at four tempos. There the slowest hop takes 6.7 ms with the parallel search,
against 257 ms on one core, one bin at a time, when 154 hops fell behind their audio.

### Reading MusicXML

`MusicXMLReader` was checked against the Python reader, built on partitura, that it was ported from,
on 308 scores. 228 came out identical, and 292 agree on every bar and to within 0.5% of the notes.
Repeats and jumps agree throughout.

## Credits and licence

Online time warping with a step limit is Arzt & Widmer (2010). The follower is ported from
[Matchmaker](https://github.com/pymatchmaker/matchmaker) (Apache 2.0), the chroma from
[librosa](https://librosa.org) (ISC), and the SoundFont player is
[TinySoundFont](https://github.com/schellingb/TinySoundFont) (MIT). The piano is MuseScore General's
(MIT, notices in `Piano/LICENSE.md`). The measurements use ASAP and MAESTRO (CC BY-NC-SA 4.0).

This repository is under the Apache License 2.0 (`LICENSE`, `NOTICE`).
