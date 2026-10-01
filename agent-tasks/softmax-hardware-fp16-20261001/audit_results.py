"""Audit selective replacement and report both historical C4 baselines."""
from pathlib import Path
import csv
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BASE = ROOT / "analysis_workspace/latency_on_hw"
TAG = "th16_20260920_c4_slots16_v2r1"
sys.path.insert(0, str(ROOT))
csv.field_size_limit(sys.maxsize)
from tools.latency_bench.raw_db import _measurement_key_from_row

def raw(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def totals(base, model):
    path = next((base / f"figure_prepare.{TAG}").glob(
        f"{model}_e2e_no_area_norm_gemm_layout_vector_stacked*/total.csv"))
    return {(r["stage"], r["batch"], r["seq_len"], r["variant"]):
            float(r["final_total_latency_s"]) for r in raw(path)}

def main():
    backup = Path(json.loads((TASK / "backup.json").read_text())["backup"])
    expected_sha = next(r["kernel_vxbin_sha256"] for r in
        json.loads((TASK / "comparison_binaries.json").read_text())
        if r["app"] == "softmax_layout_fused" and r["conversion_policy"] == "hardware")
    audit = []
    summary = []
    for model, slug in (("llama2", "llama2_7b"), ("llama3", "llama3_8b")):
        dirname = f"outputs_{model}_main.{TAG}"
        for candidate in ("C1", "C3", "C4"):
            old_path = backup / dirname / candidate / "raw_db.csv"
            new_path = BASE / dirname / candidate / "raw_db.csv"
            old_rows, new_rows = raw(old_path), raw(new_path)
            old = {_measurement_key_from_row(r): r for r in old_rows}
            new = {_measurement_key_from_row(r): r for r in new_rows}
            preserved = [k for k, r in old.items()
                         if candidate != "C4" or r["app"] != "softmax_layout_fused"]
            assert all(new.get(k) == old[k] for k in preserved), "unselected row changed"
            selected = [k for k in old if k not in preserved]
            assert all(new.get(k, {}).get("status") == "pass" for k in selected)
            assert all(new[k].get("run_id") != old[k].get("run_id") for k in selected)
            added = set(new) - set(old)
            assert all(new[k]["app"] == "softmax_layout_fused" for k in added)
            if selected or added:
                index_path = new_path.parent / "kernel_variants.json"
                index = json.loads(index_path.read_text())
                metadata = index["runs"]
                # Refinement writes authoritative per-run metadata directly;
                # add those runs to the selective-rerun root index as well.
                metadata_paths = {}
                for run_id in {new[k]["run_id"] for k in (*selected, *added)}:
                    metadata_path = new_path.parent / "runs" / run_id / "kernel_variants.json"
                    if not metadata_path.is_file():
                        matches = list((new_path.parent / "interpolation" / "refinements").glob(
                            f"**/runs/{run_id}/kernel_variants.json"))
                        assert len(matches) == 1, f"missing or ambiguous run metadata: {run_id}"
                        metadata_path = matches[0]
                    metadata_paths[run_id] = str(metadata_path)
                    metadata[run_id] = json.loads(metadata_path.read_text())["apps"]
                index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
                assert all(metadata[new[k]["run_id"]]["softmax_layout_fused"]
                           ["kernel_vxbin_sha256"] == expected_sha for k in (*selected, *added)), \
                    "selected row uses a different kernel binary"
                policy = dict(row_app="softmax_layout_fused",
                    kernel_variant="rev2_shuffle_cursor",
                    conversion_policy="existing hardware FP16 conversion, including Vivado subnormal flush-to-zero",
                    software_subnormal_preservation=False,
                    kernel_vxbin_sha256=expected_sha,
                    measured_rows=len(selected) + len(added),
                    run_ids=sorted({new[k]["run_id"] for k in (*selected, *added)}),
                    run_metadata_paths=metadata_paths)
                (new_path.parent / "softmax_conversion_policy.json").write_text(
                    json.dumps(policy, indent=2) + "\n")
            audit.append(dict(model=model, candidate=candidate,
                untouched_rows=len(preserved), replaced_softmax_rows=len(selected),
                added_softmax_probes=len(added),
                byte_identical=hashlib.sha256(old_path.read_bytes()).digest()
                    == hashlib.sha256(new_path.read_bytes()).digest()))
        original = totals(BASE / "backups/20261001T011103", slug)
        preserving = totals(backup, slug)
        current = totals(BASE, slug)
        for seq in (1024, 2048, 4096, 8192, 16384, 32768):
            key = ("prefill", "1", str(seq), "all_fpint_gemm_improve_fused_layout_spinquant")
            c3key = (*key[:3], "all_fpint_gemm_naive_spinquant")
            value = current[key]
            summary.append(dict(model=model, sequence=seq,
                current_c4_seconds=value, historical_c4_seconds=original[key],
                preserving_c4_seconds=preserving[key], c3_seconds=current[c3key],
                change_vs_preserving_percent=100 * (value / preserving[key] - 1),
                change_vs_historical_percent=100 * (value / original[key] - 1),
                current_c4_over_c3=value / current[c3key]))
    (TASK / "output_audit.json").write_text(json.dumps(audit, indent=2) + "\n")
    with (TASK / "e2e_comparison.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary[0]))
        writer.writeheader(); writer.writerows(summary)
    for row in summary:
        print(row["model"], row["sequence"],
              f"versus preserving {row['change_vs_preserving_percent']:+.2f}%",
              f"versus historical {row['change_vs_historical_percent']:+.2f}%",
              f"C4/C3 {row['current_c4_over_c3']:.4f}")
    print("Row audit:", audit)

if __name__ == "__main__":
    main()
