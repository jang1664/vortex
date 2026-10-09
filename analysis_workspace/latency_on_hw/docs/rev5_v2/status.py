"""Report new completed measurements, including the active staging database."""
import csv
import json
from pathlib import Path

DOC = Path(__file__).resolve().parent
BASELINE = json.loads((DOC / "baseline.json").read_text())
SELECTION = json.loads((DOC / "selection.json").read_text())
for model, spec in BASELINE["models"].items():
    out = Path(spec["output"])
    rows = {}
    for path in [out / "C1/raw_db.csv", *sorted((out / "C1/remeasurements").glob("*/raw_db.csv"))]:
        with path.open(newline="") as source:
            rows.update({r["exec_key"]: r for r in csv.DictReader(source)
                         if str(out) in r.get("log_file", "")})
    for stage, selection in SELECTION["models"][model].items():
        keys = {c["exec_key"] for c in selection["physical_cases"]}
        passed = sum(rows.get(k, {}).get("status") == "pass" for k in keys)
        failed = [k for k in keys if rows.get(k, {}).get("status") not in (None, "", "pass")]
        print(f"{model} {stage}: {passed}/{len(keys)} passed; failures={failed}")
