"""Measure confirmation, release and hold errors against annotated video intervals."""
import argparse
import csv
import json

from gestures import LABELS


def measure(events, start, end, expected, previous):
    frames = [e for e in events if start <= e["t"] < end]
    first = next((i for i, e in enumerate(frames) if e["stable"] == expected), None)
    entry = None if first is None else round(1000 * (frames[first]["t"] - start))
    false_releases = None
    if first is not None:
        false_releases = sum(a["stable"] == expected and b["stable"] != expected
                             for a, b in zip(frames[first:], frames[first + 1:]))
    last = next((e for e in reversed(events) if e["t"] < start), None)
    held = (last is not None and last["stable"] == previous) or (frames and frames[0]["stable"] == previous)
    release = next((round(1000 * (e["t"] - start)) for e in frames
                    if held and previous in (1, 2) and expected != previous and e["stable"] != previous),
                   None)
    return dict(start=start, end=end, expected=LABELS[expected], samples=len(frames),
                enter_ms=entry, previous_release_ms=release, false_releases=false_releases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="run.py JSONL output")
    parser.add_argument("intervals", help="CSV with start,end,label; seconds and class names")
    args = parser.parse_args()
    with open(args.log) as stream:
        events = [dict(t=e["t"], stable=e["stable"]) for e in map(json.loads, stream)
                  if e["event"] != "end"]
    classes = {name: k for k, name in LABELS.items()}
    previous = previous_end = None
    with open(args.intervals, newline="") as stream:
        for row in csv.DictReader(stream):
            start, end = float(row["start"]), float(row["end"])
            if start < 0 or end <= start or (previous_end is not None and start < previous_end):
                parser.error("intervals must be positive-length, ordered and non-overlapping")
            expected = classes[row["label"]]
            print(json.dumps(measure(events, start, end, expected,
                                     previous if start == previous_end else None)))
            previous, previous_end = expected, end


if __name__ == "__main__":
    main()
