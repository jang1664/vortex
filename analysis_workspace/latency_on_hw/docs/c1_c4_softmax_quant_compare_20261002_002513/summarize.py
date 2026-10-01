from pathlib import Path
import json, csv
out = Path(__file__).parent
record = json.loads((out / "experiment.json").read_text())
results = json.loads((out / "results.json").read_text())
assert len(results) == 12 and all(r["passed"] for r in results)
by = {(r["candidate"], r["workload"]["id"]): r for r in results}
ids = ["softmax", "quant_k", "quant_v"]
rows = []
for key in ["C1", "C2", "C3", "C4"]:
    row = {"candidate": key}
    for name in ids:
        value = by[key, name]
        ref = by["C1", name]
        row[name + "_cycles"] = value["cycles"]
        row[name + "_delta_vs_C1"] = value["cycles"] - ref["cycles"]
        row[name + "_change_percent_vs_C1"] = 100 * (value["cycles"] - ref["cycles"]) / ref["cycles"]
        row[name + "_instructions"] = value["instrs"]
        row[name + "_passed"] = value["passed"]
    rows.append(row)
with (out / "comparison.csv").open("w", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
text = "# C1-C4 softmax and quantization cycle comparison\n\n"
text += "All twelve runs passed their CPU reference checks in configured, independent build directories using `ci/run_black.sh xrt-vcs-sim`. The same snapshot, source variants, shapes and deterministic inputs are used for each candidate. Values are full-kernel core cycles from a single cold launch, rather than isolated compute-stage cycles.\n\n"
text += "## Configurations\n\n| Candidate | Config | Alias |\n|---|---|---|\n"
for cfg in record["configs"]:
    alias = cfg["alias"] or "-"
    text += f"| {cfg['key']} | `configs/{cfg['config']}` | {alias} |\n"
text += "\nC4 uses the original config resolved by the requested alias; it is not the spread_v2 config. C2 originally specified two DMA D-cache ports without response reordering. Its source config now explicitly enables `DMA_SPLIT_RSP_REORDER=1`, as required by the naive multi-port static assertion. No other implementation or config changes were made for these runs.\n\n"
text += "## Workloads\n\n| Workload | App / variant | Shape and mode |\n|---|---|---|\n"
text += "| Softmax | `softmax` / `rev2_shuffle_grouped` | FP16, batch=1, heads=1, Q=K=128, stride=128, causal mask, scale=0.125 |\n"
text += "| K quantization | `kv_cache_quant_w4a16` / `groupwise_fp16` | K=N=128, QBLK=32, QDIR=0, WTRANS=0, signed asymmetric |\n"
text += "| V quantization | `kv_cache_quant_w4a16` / `groupwise_fp16` | K=N=128, QBLK=32, QDIR=1, WTRANS=0, signed symmetric |\n"
text += "\nEach quantization case processes 16,384 FP16 values and writes packed INT4, scales and zero points. The host checks the packed bytes and all scale/zero-point bit patterns against the CPU reference. Softmax uses its existing numeric reference tolerance. These cached SIMT variants use ordinary load/store operations; they do not submit common-DMA descriptors.\n\n"
text += "## Core cycles\n\n| Candidate | Softmax | K quantization | V quantization | Verification |\n|---|---:|---:|---:|---|\n"
for row in rows:
    text += f"| {row['candidate']} | {row['softmax_cycles']:,} | {row['quant_k_cycles']:,} | {row['quant_v_cycles']:,} | PASS / PASS / PASS |\n"
text += "\n## Changes relative to C1\n\nNegative percentages mean fewer cycles.\n\n| Candidate | Softmax delta | K quantization delta | V quantization delta |\n|---|---:|---:|---:|\n"
for row in rows:
    values = [f"{row[name + '_delta_vs_C1']:+,} ({row[name + '_change_percent_vs_C1']:+.3f}%)" for name in ids]
    text += "| " + row["candidate"] + " | " + " | ".join(values) + " |\n"
text += "\nThe entire config is compared, including cache geometry and LMEM capacity. Softmax compiles its local scratch partition from `LMEM_SIZE`, so identical source variants can produce different binaries and instruction counts. DMA port counts alone cannot explain this cached-load/store workload. Results for this small shape should not be extrapolated to full attention workloads or hardware latency.\n\n"
text += "## Binary and instruction evidence\n\n| Candidate | Workload | Instructions | Kernel SHA-256 | Log |\n|---|---|---:|---|---|\n"
for r in results:
    folder = Path(r["log"]).relative_to(out)
    text += f"| {r['candidate']} | {r['workload']['id']} | {r['instrs']:,} | `{r['kernel_sha256']}` | [{folder}]({folder}) |\n"
text += "\n## Reproduction\n\nThe experiment record includes each configured build, frozen config, exact args and explicit variant environment. The runner executes config builds concurrently and runs their three workloads sequentially. It uses a five-minute progress checkpoint and up to thirty-five minutes per workload for slow runs. Shared caches contain Xilinx libraries/IP only; each build has its own simulator, runtime and kernel outputs.\n\n"
text += "- Source snapshot: `" + record["source"] + "`.\n"
text += "- Snapshot Git HEAD: `" + record["git_head"] + "`; the C2 config correction is recorded separately.\n"
text += "- `run_compare.py`, `experiment.json`, `config_metadata.json`, `source_sha256.json`: commands, selected defines, model settings and source fingerprints.\n"
text += "- `results.json`, `comparison.csv`: machine-readable measurements.\n"
text += "- `C1/` through `C4/`: configs, per-case commands, compiler and simulator logs, model manifests and result records.\n"
(out / "SUMMARY.md").write_text(text)
(out / "STATUS.yaml").write_text("task: c1_c4_softmax_quant_compare\nstatus: complete\nmode: xrt-vcs-sim\nverification: All twelve runs passed CPU reference checks.\nreport: SUMMARY.md\n")
print(out / "SUMMARY.md")
for row in rows:
    print(row)
