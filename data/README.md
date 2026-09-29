# Data

Per-performance results behind the README's "Against Matchmaker" tables. `python3 summarise.py`
prints those tables from these files.

Everything here was measured with this repository's `piano-tracker` (commit 8a1a2f2), run by a
Python harness that is not part of this repository. The recordings and scores are
[ASAP](https://github.com/fosfrancesco/asap-dataset)'s and [MAESTRO](https://magenta.tensorflow.org/datasets/maestro)'s
(CC BY-NC-SA 4.0), and are not included. A performance is named by its path in ASAP, without `.wav`.

## How it was measured

- **Reference:** the ASAP score with its repeats written out, rendered with FluidSynth and MuseScore
  General, as Matchmaker renders it. Both followers are given the same reference.
- **Ground truth:** ASAP's beat annotations for the recording.
- **Within a quarter note, within a bar, within half a second:** the share of the playing time in
  which the reported position is that close to the ground truth. In the first three files below,
  time after a follower stops reporting counts against it, as if the position were held where it
  stopped. In `noise-11.csv` the share is of the frames reported while the pianist plays.
- **Relocations landing more than 8 bars wrong:** moves to a new place (`Relocation.structural`)
  that end more than 8 bars from the ground truth.

The two followers:

- **matchmaker:** this tracker with everything Matchmaker has no counterpart for switched off:
  `--silence-gate 0 --recovery 0 --freeze-in-rests 0 --calibrate-seconds 0`. In this state it gives
  Matchmaker's own position on 99.94% to 100% of frames (see the README).
- **tracker:** the settings in the README's "Using it": `--calibrate-seconds 0 --back-step 1
  --local-reanchor 1 --local-reach 1.5 --local-improvement 0.7 --local-every 2`, with the bar
  starts (`--bars`). In `tempo-14.csv` it also has `--members 2,1,0.5,0.25` (`TempoChoice`), and
  `tracker_one_tempo` is the same without it.

## Files

**`asap-436.csv`**: every ASAP performance with trustworthy ground truth (436, 31.3 hours), each
followed from start to finish. `set` is `tuning` for the 100 performances every setting was chosen
on, and `check` for the other 336. For each follower: `within_quarter`, `within_bar`,
`median_error_quarters`, `ahead_2_bars` and `behind_2_bars` (share of time more than 2 bars out),
`relocations`, `relocations_over_8_bars_wrong` and `relocations_over_8_bars_ahead`.

**`restarts-100.csv`**: the 100 tuning performances, cut three ways. In "back six bars" the pianist
plays to halfway, then goes back six bars. In "back from 60% to 40%" they play to 60% of the
performance, then go back to 40%. In "start at 40%" they start at 40% of the way through. The
columns are `found_after_s`, the seconds from the restart until the position has been within a bar
for 2 s running (empty if never), and `relocations_over_8_bars_wrong`. `tracker_told` is the tracker
told where the pianist restarts (`begin(atReferenceSeconds:)`). Matchmaker has no way to be told.

**`tempo-14.csv`**: 14 takes of 60 s (8 of them Bach), in 13 conditions each. These takes were
held out from the tempo settings, which were chosen on 6 others. The conditions:
- The recording time-stretched to a fraction of its speed, with its pitch kept (`0.25x` to `1.00x`),
  by a phase vocoder that costs 1 to 3.8 points by itself.
- The reference rendered at 2 or 4 times the score's tempo, or at half of it, against the untouched
  recording (`marked 2x too fast` and so on). This is a score with a wrong tempo marking.
- The speed changing during the take (`slowing`, `speeding`, `sudden`, `round trip`).

The columns are `within_quarter` and `within_bar` for each follower.

**`noise-11.csv`**: 11 recordings (Bach, Beethoven ×2, Chopin, Haydn, Liszt ×2, Rachmaninoff ×2,
Schubert, Schumann), with a recording of a real room with nobody playing. The room is at -33 dB, with
mains hum at 48 Hz and a cluster from 97 to 199 Hz; it is not included. The cases:
- `room alone`: only the room.
- `room, then the performance`: the room, then the recording.
- `performance alone`: the recording, untouched.
- `room mixed in at 0 dB`: the room, as loud as the playing, mixed in throughout.
- `room in the longest rest for 20 s` and `for 40 s`: the room inserted into the longest written rest.
  Only 5 of the 11 have a rest where nothing sounds.

The columns are `furthest_bar_while_nobody_plays`, `bar_when_playing_starts`, `within_half_second`,
`drift_in_rest_bars` and `back_in_place_after_s` (within 1 s of the truth for 2 s
running, after the wait). `tracker_listening_to_the_room` is the tracker with `--calibrate-seconds 2`,
the engine's default.
