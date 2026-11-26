"""Summarize completed diagnostic hardware timing, then localize hidden-state error."""
import argparse
import csv
import json
import statistics
from pathlib import Path

import numpy as np


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, rows[0])
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    baseline = Path(__file__).parent / "docs/rev5_v2/decoder_comparison.json"
    submission = json.loads(baseline.read_text())
    timings = []
    for row in submission:
        candidate = row["candidate"]
        prefill = row["stage"] == "prefill"
        stage = "prefill" if prefill else "decode"
        result = args.root / candidate / f"measured_{stage}"
        with (result / "stack_timings.csv").open() as stream:
            samples = list(csv.DictReader(stream))
        if len(samples) != 3 or any(int(s["layers"]) != 32 for s in samples):
            raise ValueError(f"incomplete measurements in {result}")
        resident = [float(s["resident_s"]) for s in samples]
        elapsed = statistics.median(resident)
        composed = 32 * row["rev5_v2_s" if prefill else "rev5_s"]
        passed = json.loads((result / "verification.json").read_text())["pass"]
        timings.append(dict(candidate=candidate, stage=stage, output_pass=passed,
                            resident_layers=samples[0]["resident_layers"],
                            method=samples[0]["method"], resident_s=elapsed,
                            min_s=min(resident), max_s=max(resident),
                            actual_s=statistics.median(float(s["actual_wall_s"]) for s in samples),
                            submitted_composition_s=composed,
                            submission_error_pct=100*(composed-elapsed)/elapsed))
    write_csv(args.root / "diagnostic_latency.csv", timings)

    layers = []
    for timing in timings:
        candidate, stage = timing["candidate"], timing["stage"]
        base = args.root / candidate
        for layer in range(32):
            reference = base / stage / f"layer-{layer}" / "reference/output.bin"
            measured = base / f"measured_{stage}"
            if layer != 31:
                measured = measured / f"layer-{layer}"
            x = np.fromfile(measured / "output.bin", np.float16).astype(np.float64)
            y = np.fromfile(reference, np.float16).astype(np.float64)
            if not x.size or x.shape != y.shape:
                raise ValueError(f"invalid hidden shape at {measured}")
            finite = np.isfinite(x) & np.isfinite(y)
            difference = x[finite] - y[finite]
            bad = np.abs(difference) > np.where(abs(y[finite]) < .25, .005, .005 * abs(y[finite]))
            layers.append(dict(candidate=candidate, stage=stage, layer=layer,
                               elements=x.size, nonfinite=int((~finite).sum()),
                               violation_pct=100*bad.sum()/x.size,
                               relative_l2=np.linalg.norm(difference)/max(np.linalg.norm(y[finite]),1e-30)))
    write_csv(args.root / "layer_errors.csv", layers)


if __name__ == "__main__":
    main()
