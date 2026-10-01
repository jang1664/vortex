"""Summarize recorded FPGA checks, fair cycle comparisons, and row replacement."""
from __future__ import annotations

import csv
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.latency_bench.perf_log import parse_fpga_cycle_stats

TASK = Path(__file__).resolve().parent
PREVIOUS = ROOT / "agent-tasks/layout-fused-prefill-opt-20260930"


def main() -> None:
    records = {}
    for line in (PREVIOUS / "run_manifest.jsonl").open():
        record = json.loads(line)
        if "/final_short_" in record["log"] or "/final_fixed_" in record["log"]:
            records[record["label"]] = record
    checks = []
    for label, record in records.items():
        if label.startswith("perf_"):
            continue
        text = Path(record["log"]).read_text()
        matches = re.findall(r"errors=(\d+)", text)
        checks.append(dict(label=label, args=record["args"], log=record["log"],
            kernel_sha256=record["kernel_vxbin_sha256"],
            result="pass" if "PASSED!" in text else
                "unsupported_setup" if "KT>=QBLK" in text else "fail",
            value_errors=int(matches[-1]) if matches else None))
    comparisons = []
    for sequence in (1024, 4096):
        for name in ("quant_k", "quant_v", "softmax"):
            pair = []
            for implementation in ("final", "standalone"):
                record = records[f"perf_{name}_{implementation}_{sequence}"]
                stats = parse_fpga_cycle_stats(Path(record["log"]))
                if stats["fpga_cycle_samples"] != 3:
                    raise ValueError(f"expected three samples for {record['label']}")
                pair.append((record, stats))
            comparisons.append(dict(kernel=name, sequence=sequence,
                fused_cycles=pair[0][1]["fpga_cycle_p50"],
                standalone_cycles=pair[1][1]["fpga_cycle_p50"],
                overhead_percent=100 * (pair[0][1]["fpga_cycle_p50"] / pair[1][1]["fpga_cycle_p50"] - 1),
                fused_log=pair[0][0]["log"], standalone_log=pair[1][0]["log"],
                fused_kernel_sha256=pair[0][0]["kernel_vxbin_sha256"],
                standalone_kernel_sha256=pair[1][0]["kernel_vxbin_sha256"]))
    with (TASK / "kernel_cycle_comparison.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(comparisons[0]))
        writer.writeheader(); writer.writerows(comparisons)
    payload = dict(checks=checks, comparisons=comparisons,
        correctness_limitation="Representative checks do not prove all inputs. Earlier short masked rows showed intermittent mismatches.")
    (TASK / "kernel_validation.json").write_text(json.dumps(payload, indent=2) + "\n")
    print("Supported checks:", sum(c["result"] == "pass" for c in checks),
          "failed:", sum(c["result"] == "fail" for c in checks))
    for row in comparisons:
        print(row["kernel"], row["sequence"], f"{row['overhead_percent']:.2f}%")


if __name__ == "__main__":
    main()
