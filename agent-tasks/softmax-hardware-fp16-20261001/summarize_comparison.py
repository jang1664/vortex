"""Compare preserving and hardware FP16 conversion on identical inputs."""
from pathlib import Path
import csv
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.latency_bench.perf_log import parse_fpga_cycle_stats

TASK = Path(__file__).resolve().parent

def main():
    rows = []
    for app in ("softmax", "softmax_layout_fused"):
        for seq in (1024, 4096, 16384, 32768):
            stats = []
            for policy in ("preserving", "hardware"):
                path = TASK / "logs" / f"{policy}_{app}_{seq}.log"
                if not path.exists():
                    break
                value = parse_fpga_cycle_stats(path)
                if not value.get("fpga_cycle_samples"):
                    break
                stats.append(value)
            if len(stats) != 2:
                continue
            before, after = (s["fpga_cycle_p50"] for s in stats)
            rows.append(dict(app=app, sequence=seq,
                preserving_cycles=before, hardware_cycles=after,
                change_percent=100 * (after / before - 1),
                samples_per_policy=stats[0]["fpga_cycle_samples"]))
    if rows:
        with (TASK / "conversion_comparison.csv").open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    for row in rows:
        print(row["app"], row["sequence"], f"{row['change_percent']:+.2f}%",
              "samples", row["samples_per_policy"])
    if len(rows) == 8:
        for seq in (1024, 4096, 16384, 32768):
            pair = {r["app"]: r for r in rows if r["sequence"] == seq}
            ratio = pair["softmax_layout_fused"]["hardware_cycles"] / pair["softmax"]["hardware_cycles"]
            print("Hardware conversion fused overhead", seq, f"{100 * (ratio - 1):.2f}%")

if __name__ == "__main__":
    main()
