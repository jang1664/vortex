"""Compare copied raw databases to their immutable pre-rerun backups."""
from pathlib import Path
import csv
import json
import sys
from collections import Counter
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.latency_bench.raw_db import _measurement_key_from_row
from tools.latency_bench.kernel_variants import source_identity
TAG = "th16_20260920_c4_slots16_v2r1"
BASE = ROOT / "analysis_workspace/latency_on_hw"
BACKUP = BASE / "backups/20261001T011103"
VARIANTS = {"softmax_layout_fused": "rev2_shuffle_cursor",
            "kv_cache_quant_layout_fused_w4a16": "prefill_tiled_chunk_fp32"}
ORIGINAL = "/home/jaeyongjang/project.local/vortex_fpint/analysis_workspace/latency_on_hw"

def rows(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def main():
    audit = []; comparison = []
    for model in ("llama2", "llama3"):
        for label in ("C1", "C3", "C4"):
            relative = Path(f"outputs_{model}_main.{TAG}/{label}/raw_db.csv")
            before = [{k: v.replace(ORIGINAL, str(BASE)) for k, v in row.items()}
                      for row in rows(BACKUP / relative)]
            after = rows(BASE / relative)
            current = {_measurement_key_from_row(r): r for r in after}
            selected = [r for r in before if label == "C4" and r["app"] in VARIANTS]
            untouched = [r for r in before if r not in selected]
            changed = [r["exec_key"] for r in untouched if current.get(_measurement_key_from_row(r)) != r]
            final = []; pending = []; metadata_cache = {}
            for old in selected:
                new = current.get(_measurement_key_from_row(old), {})
                run_id = new.get("run_id", "")
                manifest = (BASE / relative).parent / "runs" / run_id / "manifest.json"
                if run_id not in metadata_cache:
                    metadata_cache[run_id] = json.loads(manifest.read_text()) if manifest.exists() else {}
                metadata = metadata_cache[run_id].get("kernel_variants", {}).get(old["app"], {})
                good = (new.get("status") == "pass" and new.get("run_id") != old["run_id"]
                    and metadata.get("selected") == VARIANTS[old["app"]]
                    and metadata.get("source_identity") == source_identity(ROOT, old["app"]))
                (final if good else pending).append(old["exec_key"])
                if good:
                    a, b = float(old["fpga_cycle_avg"]), float(new["fpga_cycle_avg"])
                    comparison.append(dict(model=model, app=old["app"], args=old["args"],
                        old_cycles=a, new_cycles=b, change_percent=100 * (b / a - 1),
                        old_run_id=old["run_id"], new_run_id=run_id,
                        selected_variant=metadata["selected"], kernel_sha256=metadata["kernel_vxbin_sha256"]))
            entry = dict(model=model, label=label, before_rows=len(before), after_rows=len(after),
                selected_original_rows=len(selected), final_rows=len(final), pending_rows=len(pending),
                unchanged_unselected_rows=len(untouched)-len(changed), unexpected_changed_exec_keys=changed,
                new_physical_rows=len(set(current)-{_measurement_key_from_row(r) for r in before}))
            audit.append(entry)
            print(model,label,{k:entry[k] for k in ("final_rows","pending_rows","unchanged_unselected_rows","new_physical_rows")})
    task = Path(__file__).resolve().parent
    (task / "output_audit.json").write_text(json.dumps(audit,indent=2)+"\n")
    if comparison:
        with (task / "original_vs_final_cycles.csv").open("w",newline="") as f:
            writer=csv.DictWriter(f,fieldnames=list(comparison[0])); writer.writeheader(); writer.writerows(comparison)
    assert not any(item["unexpected_changed_exec_keys"] for item in audit), "unselected rows changed"
    if "--require-complete" in sys.argv:
        assert not any(item["pending_rows"] for item in audit), "selected rows remain unfinished"
if __name__ == "__main__":
    main()
