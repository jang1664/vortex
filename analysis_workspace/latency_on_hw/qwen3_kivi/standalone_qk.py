"""Summarize device PERF intervals in the standalone Rev7 QK measurements."""

import csv
import argparse
import json
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "directory", type=Path, help="Directory containing the two benchmark logs and clock snapshot"
)
out = parser.parse_args().directory
snapshot = json.loads((out / "candidate_snapshot.json").read_text())
lengths = (1024, 8192, 32768)
samples = {}
for candidate in ("C1", "C4"):
    log = (out / f"qk_{candidate}.stdout").read_text()
    spans = re.findall(
        r"\[bench-perf\] iteration=1/1 begin(.*?)\[bench-perf\] iteration=1/1 end", log, flags=re.S
    )
    assert len(spans) == len(lengths)
    cycles = [int(re.search(r"^PERF: instrs=\d+, cycles=(\d+)", s, re.M)[1]) for s in spans]
    period = snapshot["candidates"][candidate]["fpga_period_s"]
    samples[candidate] = [(n, n * period * 1000) for n in cycles]

rows = []
for length, (c1, t1), (c4, t4) in zip(lengths, samples["C1"], samples["C4"]):
    rows.append([length, c1, c4, f"{t1:.5f}", f"{t4:.5f}", f"{t1/t4:.3f}"])
with (out / "decode_qk.csv").open("w") as f:
    writer = csv.writer(f)
    writer.writerow(
        ["kv_tokens", "c2_from_c1_cycles", "c4_cycles", "c2_from_c1_ms", "c4_ms", "c2_over_c4"]
    )
    writer.writerows(rows)
fig, ax = plt.subplots(figsize=(4.6, 3.15), layout="constrained")
for i, (candidate, label, color) in enumerate(
    [("C1", "C2 (C1 FP16 TCU)", "#364a75"), ("C4", "C4 (INT4 Q-ROW)", "#af4822")]
):
    ax.bar(
        [j + (i - 0.5) * 0.32 for j in range(3)],
        [ms for _, ms in samples[candidate]],
        0.32,
        color=color,
        label=label,
        zorder=2,
    )
ax.set(
    yscale="log",
    ylabel="QK kernel latency (ms)",
    xlabel="KV length (tokens)",
    xticks=[0, 1, 2],
    xticklabels=["1K", "8K", "32K"],
    ylim=(0.1, 300),
    title="U55C Rev7 · decode QK (M=4, K=128)",
)
ax.grid(axis="y", alpha=0.25)
ax.legend(frameon=False, fontsize=8)
fig.savefig(out / "decode_qk.pdf")
