#!/usr/bin/env python3
"""Repeat fixed cascade workloads; RSS is the entire headless child process."""
import argparse
import json
import math
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    default = root / ("zig-out/Suzume.app/Contents/MacOS/suzume" if sys.platform == "darwin" else "zig-out/bin/suzume")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path, default=default)
    parser.add_argument("--repeat", type=int, default=5)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if sys.platform not in ("darwin", "linux"):
        parser.error("RSS collection currently supports macOS and Linux")
    samples = {}
    peaks = []
    elements = {}
    optimize = None
    for _ in range(args.repeat):
        result = subprocess.run([
            "/usr/bin/time", "-l" if sys.platform == "darwin" else "-v",
            str(args.binary.resolve()), "--bench-css",
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=120)
        records = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{"case":')]
        assert {record["case"] for record in records} == {"siblings", "rows"}, result.stderr
        for record in records:
            mode = record.get("optimize", "unknown")
            if optimize is None:
                optimize = mode
            assert mode == optimize, "mixed optimization modes"
            samples.setdefault(record["case"], []).append(record["cascade_ns"] / 1e6)
            elements[record["case"]] = record["elements"]
        if sys.platform == "darwin":
            peak = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
            assert peak, result.stderr
            peaks.append(int(peak[1]))
        else:
            peak = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", result.stderr)
            assert peak, result.stderr
            peaks.append(int(peak[1]) * 1024)
    report = {
        "platform": platform.platform(),
        "binary": str(args.binary.resolve()),
        "repeats": args.repeat,
        "optimize": optimize,
        "timing_scope": "CSS parse/index/cascade only; DOM parsing excluded",
        "rss_scope": "peak entire headless process across both workloads; no GUI, layout, paint or JavaScript",
        "peak_rss_bytes_median": statistics.median(peaks),
        "peak_rss_bytes_samples": peaks,
        "cases": {},
    }
    for name, times in samples.items():
        report["cases"][name] = {
            "elements": elements[name],
            "median_ms": statistics.median(times),
            "p95_ms": sorted(times)[math.ceil(len(times) * .95) - 1],
            "samples_ms": times,
        }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
