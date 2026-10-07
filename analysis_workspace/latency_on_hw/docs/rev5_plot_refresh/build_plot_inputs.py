"""Build offline, per-application image selections for the mixed-image rev5."""
from copy import deepcopy
import csv
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[1]
REPO = WORKSPACE.parents[1]
sys.path.insert(0, str(REPO))
from tools.latency_bench.candidate_map import _digest, validate_snapshot
from tools.latency_bench.suite_io import read_suite_payload, write_suite_payload
from tools.latency_bench.yaml_io import safe_load, safe_dump

OLD = "th16_20261004_rev4_pipeline"
NEW = "th16_20261007_rev5_pipeline"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    inventory = {"tag": NEW, "baseline_tag": OLD, "raw": {}, "suites": []}
    old_snapshot = safe_load((WORKSPACE / "generated_suites" /
        f"llama2_7b_main_full.{OLD}/prefill_merged/index.yaml").read_text())["experiment"]
    new_snapshot = safe_load((WORKSPACE / "generated_suites" /
        f"llama2_7b_main_full.{NEW}/prefill_merged/index.yaml").read_text())["experiment"]
    gemm_snapshot = deepcopy(old_snapshot)
    gemm_snapshot["candidates"]["C4"] = new_snapshot["candidates"]["C4"]
    gemm_snapshot["selection_digest"] = _digest(gemm_snapshot["candidates"])
    validate_snapshot(old_snapshot)
    validate_snapshot(gemm_snapshot)
    for model, key in [("llama2", "llama2_7b"), ("llama3", "llama3_8b")]:
        for candidate in ["C1", "C3", "C4"]:
            raw = WORKSPACE / f"outputs_{model}_main.{NEW}/{candidate}/raw_db.csv"
            counts = {}
            with raw.open() as stream:
                for row in csv.DictReader(stream):
                    snapshot = gemm_snapshot if row["app"] == "fpint_gemm_ffn_hw" else old_snapshot
                    expected = snapshot["candidates"][candidate]
                    assert row["fpga_bin_label"] == candidate, (raw, row["app"])
                    assert row["xclbin_sha256"] == expected["xclbin_sha256"], (raw, row["app"])
                    assert row["fpga_bin_alias"] == expected["alias"], (raw, row["app"])
                    counts[row["app"]] = counts.get(row["app"], 0) + 1
            inventory["raw"][str(raw)] = {"sha256": sha(raw), "rows_by_app": counts}
        source = WORKSPACE / "generated_suites" / f"{key}_main_full.{OLD}"
        target = HERE / "suites" / key
        for index in sorted(source.glob("*_*fill/index.yaml")) + sorted(source.glob("*_generation/index.yaml")):
            payload = safe_load(index.read_text())
            destination = target / index.parent.name
            destination.mkdir(parents=True, exist_ok=True)
            for entry in payload["generated"]:
                src = index.parent / Path(entry["suite"]).name
                suite = read_suite_payload(src)
                app = suite["defaults"]["app"]
                suite["experiment"] = deepcopy(gemm_snapshot if app == "fpint_gemm_ffn_hw" else old_snapshot)
                out = destination / src.name
                write_suite_payload(out, suite)
                entry["suite"] = str(out)
                entry.pop("run_command", None)
                inventory["suites"].append({"source": str(src), "source_sha256": sha(src),
                    "output": str(out), "sha256": sha(out), "app": app,
                    "selection_digest": suite["experiment"]["selection_digest"]})
            payload.pop("experiment", None)
            payload["offline_plot_provenance"] = "Per-application selections are captured in each suite; do not use this mixed-image view for hardware runs."
            (destination / "index.yaml").write_text(safe_dump(payload, sort_keys=False))
    (HERE / "input_inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    # The power renderer accepts only one SHA per candidate. All six explicit
    # raw inputs were instead checked above against the per-application policy.
    # Preserve their original image metadata; never relabel old vector rows.
    (HERE / "power_selection.json").write_text(json.dumps({
        "experiment": {}, "mode": "explicit_raw_dbs_validated_per_application",
        "inventory": str(HERE / "input_inventory.json"),
        "old_snapshot": old_snapshot, "gemm_snapshot": gemm_snapshot,
    }, indent=2) + "\n")
    print(f"Validated {len(inventory['raw'])} raw databases and wrote {len(inventory['suites'])} application suites.")


if __name__ == "__main__":
    main()
