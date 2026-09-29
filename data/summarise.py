"""The README's "Against Matchmaker" tables, computed from the CSV files beside this one.

  python3 data/summarise.py
"""

import csv
import statistics
from pathlib import Path

HERE = Path(__file__).parent


def rows(name):
    return list(csv.DictReader(open(HERE / name)))


def num(x):
    return float(x) if x != "" else None


def weighted(rs, key):
    """Share of all playing time: each performance weighted by its length."""
    return sum(num(r[key]) * num(r["seconds"]) for r in rs) / sum(num(r["seconds"]) for r in rs)


def all_436():
    rs = rows("asap-436.csv")
    print(f"All {len(rs)} performances, {sum(num(r['seconds']) for r in rs) / 3600:.1f} h")
    for label, key, fmt in (("within a quarter note", "within_quarter", ".1%"), ("within a bar", "within_bar", ".1%"),
                            ("more than 2 bars behind", "behind_2_bars", ".2%"),
                            ("more than 2 bars ahead", "ahead_2_bars", ".2%")):
        print(f"  {label:44}" + "".join(f"{weighted(rs, f'{v}_{key}'):>12{fmt}}" for v in ("matchmaker", "tracker")))
    for label, test in (("performances followed less than half the time", lambda x: x < 0.5),
                        ("performances followed less than 80% of the time", lambda x: x < 0.8)):
        print(f"  {label:44}" + "".join(f"{sum(test(num(r[f'{v}_within_bar'])) for r in rs):>12}"
                                          for v in ("matchmaker", "tracker")))
    print(f"  {'relocations landing more than 8 bars wrong':44}"
          + "".join(f"{sum(int(r[f'{v}_relocations_over_8_bars_wrong']) for r in rs):>12}" for v in ("matchmaker", "tracker")))
    diff = [num(r["tracker_within_bar"]) - num(r["matchmaker_within_bar"]) for r in rs]
    print(f"  within a bar, by performance: tracker better by more than half a point on {sum(d > 0.005 for d in diff)},"
          f" worse on {sum(d < -0.005 for d in diff)}, the same on {sum(abs(d) <= 0.005 for d in diff)}")


def tempo():
    rs = rows("tempo-14.csv")
    conditions = list(dict.fromkeys(r["condition"] for r in rs))
    print(f"\nPractice tempos: {len({r['performance'] for r in rs})} takes, within a quarter note")
    print(f"  {'':20}" + "".join(f"{c[:10]:>11}" for c in conditions) + f"{'mean':>8}")
    for v in ("matchmaker", "tracker_one_tempo", "tracker"):
        means = [statistics.mean(num(r[f"{v}_within_quarter"]) for r in rs if r["condition"] == c) for c in conditions]
        print(f"  {v:20}" + "".join(f"{m:11.1%}" for m in means) + f"{statistics.mean(means):8.1%}")


def restarts():
    rs = rows("restarts-100.csv")
    print(f"\nRestarts: {len({r['performance'] for r in rs})} performances; found = within a bar for 2 s running")
    for kind in dict.fromkeys(r["restart"] for r in rs):
        these = [r for r in rs if r["restart"] == kind]
        cells = []
        for v in ("matchmaker", "tracker", "tracker_told"):
            found = [num(r[f"{v}_found_after_s"]) for r in these if r[f"{v}_found_after_s"] != ""]
            wrong = sum(int(r[f"{v}_relocations_over_8_bars_wrong"]) for r in these)
            cells.append(f"{len(found):3}/{len(these)}, median {statistics.median(found):5.1f} s, {wrong:2} wrong")
        print(f"  {kind:22}" + "  |  ".join(cells))


def noise():
    rs = rows("noise-11.csv")
    print("\nNoisy room: " + ", ".join(dict.fromkeys(r["follower"] for r in rs)))
    for case in dict.fromkeys(r["case"] for r in rs):
        cells = []
        for v in dict.fromkeys(r["follower"] for r in rs):
            these = [r for r in rs if r["case"] == case and r["follower"] == v]
            s = f"n={len(these)}"
            if these[0]["furthest_bar_while_nobody_plays"] != "":
                bars = [num(r["furthest_bar_while_nobody_plays"]) for r in these]
                s += f" bar 1 held {sum(b <= 1 for b in bars)}/{len(these)} (median bar {statistics.median(bars):g})"
            if these[0]["within_half_second"] != "":
                s += f" {statistics.mean(num(r['within_half_second']) for r in these):.1%} within 0.5 s"
            if these[0]["back_in_place_after_s"] != "":
                s += f" back after {statistics.median(num(r['back_in_place_after_s']) for r in these):.1f} s (median)"
            cells.append(s)
        print(f"  {case:38}" + "  |  ".join(cells))


if __name__ == "__main__":
    all_436()
    tempo()
    restarts()
    noise()
