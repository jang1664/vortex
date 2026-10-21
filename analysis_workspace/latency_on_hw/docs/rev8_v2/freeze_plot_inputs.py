"""Freeze the validated rev8 baseline plus selective rev8_v2 updates for plotting."""
import csv
import hashlib
import json
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[1]
REPO = WORKSPACE.parents[1]
sys.path.insert(0, str(REPO))
from tools.latency_bench.yaml_io import safe_load, safe_dump


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    output = HERE / "plot_inputs"
    output.mkdir(exist_ok=True)
    inventory = {"tag": "rev8_v2", "baseline_tag": "th16_20261017_rev8_pipeline",
                 "raw": {}, "suites": []}
    snapshot = safe_load((WORKSPACE / "generated_suites/llama2_7b_main_full.rev8_v2/prefill_merged/index.yaml").read_text())["experiment"]
    for model, key in (("llama2", "llama2_7b"), ("llama3", "llama3_8b")):
        for label in ("C1", "C2", "C3", "C4"):
            raw = WORKSPACE / f"outputs_{model}_main.rev8_v2/{label}/raw_db.csv"
            counts = {}
            with raw.open() as stream:
                for row in csv.DictReader(stream):
                    assert row["fpga_bin_label"] == label
                    assert row["xclbin_sha256"] == snapshot["candidates"][label]["xclbin_sha256"]
                    counts[row["app"]] = counts.get(row["app"], 0) + 1
            inventory["raw"][str(raw)] = {"sha256": sha(raw), "rows_by_app": counts}
        source = WORKSPACE / f"generated_suites/{key}_main_full.rev8_v2"
        for label in ("C1", "C2", "C3", "C4_fused"):
            for stage in ("prefill", "generation"):
                src = source / f"{label}_{stage}" / "index.yaml"
                index = safe_load(src.read_text())
                destination = output / "suites" / key / src.parent.name
                destination.mkdir(parents=True, exist_ok=True)
                for entry in index["generated"]:
                    original = src.parent / Path(entry["suite"]).name
                    target = destination / original.name
                    shutil.copy2(original, target)
                    entry["suite"] = str(target)
                    entry.pop("run_command", None)
                    inventory["suites"].append({"source": str(original), "output": str(target), "sha256": sha(target)})
                target = destination / "index.yaml"
                target.write_text(safe_dump(index, sort_keys=False))
                inventory["suites"].append({"source": str(src), "output": str(target), "sha256": sha(target)})
    (output / "input_inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    (output / "power_selection.json").write_text(json.dumps({"experiment": snapshot,
        "mode": "same_images_baseline_plus_selective_updates",
        "inventory": str(output / "input_inventory.json")}, indent=2) + "\n")
    print(f"Frozen {len(inventory['raw'])} raw databases and {len(inventory['suites'])} suite artifacts.")


if __name__ == "__main__":
    main()
