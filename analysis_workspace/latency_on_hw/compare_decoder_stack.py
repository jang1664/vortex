"""Compare a verified Llama3-8B B1 S1024 stack run with submission composition."""
import argparse
import csv
import json
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("--candidate", choices=("C1", "C2", "C3", "C4"), required=True)
    parser.add_argument("--stage", choices=("prefill", "decode"), required=True)
    parser.add_argument("--matched-per-layer-s", type=float, required=True,
                        help="standalone sum matched to the exact operation list and bitstream")
    args = parser.parse_args()
    with (args.result / "verification.json").open() as f:
        if not json.load(f)["pass"]:
            parser.error("final hidden verification failed")
    with (args.result / "stack_timings.csv").open() as f:
        rows = list(csv.DictReader(f))
    if len(rows) < 3 or any(int(r["layers"]) != 32 for r in rows):
        parser.error("expected at least three 32-layer repetitions")
    stage = "generation" if args.stage == "decode" else "prefill"
    baseline = Path(__file__).parent / "docs/rev5_v2/decoder_comparison.json"
    entry, = [r for r in json.loads(baseline.read_text())
              if r["candidate"] == args.candidate and r["stage"] == stage]
    submitted = 32 * entry["rev5_s" if stage == "generation" else "rev5_v2_s"]
    matched = 32 * args.matched_per_layer_s
    resident = [float(r["resident_s"]) for r in rows]
    median = statistics.median(resident)
    print(json.dumps(dict(candidate=args.candidate, stage=args.stage, method=rows[0]["method"],
                          resident_layers=int(rows[0]["resident_layers"]),
                          resident_s=median, resident_range_s=[min(resident), max(resident)],
                          actual_wall_s=statistics.median(float(r["actual_wall_s"]) for r in rows),
                          submission_s=submitted, matched_s=matched,
                          submission_error_pct=100*(submitted-median)/median,
                          matched_error_pct=100*(matched-median)/median), indent=2))


if __name__ == "__main__":
    main()
