"""Compare plotted rev8 and rev8_v2 components, retaining their exact units."""
import csv
import json
from pathlib import Path
import sys

import pandas as pd

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[1]
sys.path.insert(0, str(WORKSPACE.parents[1]))
from analysis_workspace.latency_on_hw.plot import _build_gemm_layout_stack

csv.field_size_limit(100_000_000)
TAGS = ("th16_20261017_rev8_pipeline", "rev8_v2")


def read_components(tag, model):
    folders = list((WORKSPACE / f"figure_prepare.{tag}").glob(
        f"{model}_*e2e_no_area_norm_gemm_layout_vector_stacked_by_name_backend*"))
    assert len(folders) == 1, folders
    folder = folders[0]
    denominators = {}
    with (folder / "total.csv").open() as stream:
        for row in csv.DictReader(stream):
            assert int(row["missing_case_count"]) == 0
            if row["variant"] != "all_fpint_gemm_improve_fused_layout_spinquant":
                continue
            if row["stage"] == "generation" and row["aggregation_kind"] != "average_tpot":
                continue
            key = (row["stage"], int(row["batch"]), int(row["seq_len"]))
            denominators[key] = float(row["final_total_latency_s"])
    df = pd.read_csv(folder / "excel_figure_data.csv")
    for column in ("stage", "batch", "seq"):
        df[column] = df[column].ffill()
    df["model"] = model
    stack = _build_gemm_layout_stack(pd, df, include_vector=True)
    result = {}
    for _, row in stack.iterrows():
        stage = str(row["stage"]).lower()
        seq = str(row["seq"]).lower()
        seq = int(float(seq[:-1]) * 1024) if seq.endswith("k") else int(seq)
        key = (stage, int(row["batch"]), seq, row["candidate"])
        denominator = denominators[key[:3]]
        original = df[(df["stage"] == row["stage"]) & (df["batch"] == row["batch"])
                      & (df["seq"] == row["seq"]) & (df["candidate"] == row["candidate"])].iloc[0]
        result[key] = {name: float(row[name]) * denominator for name in ("gemm", "vector", "layout")}
        result[key]["total"] = float(original["total"]) * denominator
        transpose = original.get("attn_k_transpose::head_transpose", 0.0)
        result[key]["transpose"] = 0.0 if pd.isna(transpose) else float(transpose) * denominator
    return result


def main():
    comparison = []
    for model in ("llama2", "llama3"):
        old, new = (read_components(tag, model) for tag in TAGS)
        assert old.keys() == new.keys()
        for key in old:
            stage, batch, seq, candidate = key
            record = dict(model=model, stage=stage, batch=batch, context=seq,
                          candidate=candidate, old=old[key], new=new[key])
            record["e2e_change_percent"] = 100 * (new[key]["total"] / old[key]["total"] - 1)
            # Only K maintenance changed. GEMMs and all other candidates retain
            # their measured data, and prefill is unaffected by incremental decode.
            assert abs(new[key]["gemm"] - old[key]["gemm"]) < 1e-7
            if stage == "prefill" or candidate in ("C3", "C4"):
                assert abs(new[key]["total"] - old[key]["total"]) < 1e-7
            comparison.append(record)
    (HERE / "comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")
    lines = ["# rev8 versus rev8_v2", "",
             "B1, context 8192. Seconds per output token, averaged over 128 decode steps and all 32 layers. These are aggregated FPGA-cycle estimates, not measured whole-model wall times. The ordinary E2E plot excludes dequantization by the existing policy.", "",
             "| Model | Candidate | Vector rev8 | Vector rev8_v2 | K transpose rev8 | K transpose rev8_v2 | E2E rev8 | E2E rev8_v2 | E2E change |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for r in comparison:
        if r["stage"] != "generation" or r["batch"] != 1 or r["context"] != 8192:
            continue
        a, b = r["old"], r["new"]
        lines.append(f"| {r['model']} | {r['candidate']} | {a['vector']:.6f} | {b['vector']:.6f} | {a['transpose']:.6f} | {b['transpose']:.6f} | {a['total']:.6f} | {b['total']:.6f} | {r['e2e_change_percent']:+.2f}% |")
    lines += ["", "All GEMM components, all prefill totals, and C3/C4 totals were checked unchanged. See `comparison.json` for every workload.", ""]
    (HERE / "COMPARISON.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
