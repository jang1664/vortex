"""Check offline rev5 plot completeness and preserved measurement provenance."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys

import pandas as pd

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[1]
sys.path.insert(0, str(WORKSPACE))
from plot import expected_plot_outputs, selected_plot_jobs

TAG = "th16_20261007_rev5_pipeline"
inventory = json.loads((HERE / "input_inventory.json").read_text())
for name, evidence in inventory["raw"].items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == evidence["sha256"], name

model_checks = {}
for model in ["llama2_7b", "llama3_8b"]:
    folder = WORKSPACE / f"composed_results.{TAG}" / model
    manifest = json.loads((folder / "manifest.json").read_text())
    assert manifest["completeness"]["complete"], manifest["completeness"]
    cols = ["app", "compose_status", "expected_xclbin_sha256", "source_xclbin_sha256s"]
    counts = Counter()
    for frame in pd.read_csv(folder / "composed.csv", usecols=cols, chunksize=20000, keep_default_na=False):
        counts.update(frame["compose_status"])
        for expected, source in frame[["expected_xclbin_sha256", "source_xclbin_sha256s"]].itertuples(index=False, name=None):
            hashes = set(re.findall(r"[0-9a-f]{64}", source))
            assert hashes == {expected}, (model, expected, source)
    model_checks[model] = {"rows_by_status": dict(counts), "completeness": manifest["completeness"],
                           "all_source_image_hashes_match_application_selection": True}

root = WORKSPACE / f"figure_output.{TAG}"
jobs = selected_plot_jobs("all")
artifacts = []
for family, metric in jobs:
    for relative in expected_plot_outputs(family, formats=("png", "pdf", "svg"), power_metric=metric):
        path = root / relative
        assert path.is_file() and path.stat().st_size > 0, path
        artifacts.append(str(relative))

result = {"status": "complete", "raw_databases_unchanged": True,
          "models": model_checks, "render_jobs": len(jobs), "artifacts": artifacts,
          "output_root": str(root)}
(HERE / "completion.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({k: v for k, v in result.items() if k != "artifacts"}, indent=2))
