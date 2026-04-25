#!/usr/bin/env python3
"""Aggregate Vortex latency bench CSV (long format) into a summary table.

Input CSV (produced by tests/common/bench_harness.cpp):
    label,iter,latency_ms
    softmax@xclbin_v3,0,1.234
    softmax@xclbin_v3,1,1.256
    ...

Output: one row per label with min/median/mean/p95/max/stddev/n.
"""

import argparse
import csv
import math
import statistics
import sys
from collections import defaultdict


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = p * (len(sorted_vals) - 1)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return sorted_vals[lo]
    frac = idx - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="path to raw bench csv")
    ap.add_argument("--out", help="optional output summary csv")
    args = ap.parse_args()

    samples = defaultdict(list)
    with open(args.csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                samples[row["label"]].append(float(row["latency_ms"]))
            except (KeyError, ValueError):
                continue

    if not samples:
        print("no samples found", file=sys.stderr)
        sys.exit(1)

    rows = []
    for label, vals in sorted(samples.items()):
        s = sorted(vals)
        rows.append({
            "label":   label,
            "n":       len(vals),
            "min":     s[0],
            "median":  percentile(s, 0.5),
            "mean":    statistics.fmean(vals),
            "p95":     percentile(s, 0.95),
            "max":     s[-1],
            "stddev":  statistics.pstdev(vals) if len(vals) > 1 else 0.0,
        })

    label_w = max(len(r["label"]) for r in rows)
    hdr = f"{'label':<{label_w}}  {'n':>4}  {'min':>9}  {'median':>9}  {'mean':>9}  {'p95':>9}  {'max':>9}  {'stddev':>9}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['label']:<{label_w}}  {r['n']:>4}  "
              f"{r['min']:>9.4f}  {r['median']:>9.4f}  {r['mean']:>9.4f}  "
              f"{r['p95']:>9.4f}  {r['max']:>9.4f}  {r['stddev']:>9.4f}")
    print("(all latencies in milliseconds)")

    if args.out:
        with open(args.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            for r in rows:
                w.writerow(r)
        print(f"\nsummary written to: {args.out}")


if __name__ == "__main__":
    main()
