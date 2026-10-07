"""Compact status for the two independently built FPGA measurements."""
import csv
import json
from collections import Counter
from datetime import datetime
from pathlib import Path
D = Path(__file__).resolve().parent
rev = json.loads((D / "revision.json").read_text())
print(datetime.now().isoformat(timespec="seconds"))
for model, info in rev["models"].items():
    p = Path(info["output"]) / "C4/refresh_fpint_gemm_ffn_hw/raw_db.csv"
    rows = list(csv.DictReader(p.open())) if p.exists() else []
    statuses = Counter(r["status"] for r in rows)
    print(f"{model}: {statuses['pass']}/{info['target_count']} PASS; failures={sum(v for k,v in statuses.items() if k not in ('','pass'))}")
    for stage in ("prefill", "generation"):
        p = D / f"{model}_{stage}.log"
        if p.exists():
            with p.open("rb") as f:
                f.seek(max(0, p.stat().st_size - 2500))
                lines = f.read().decode(errors="replace").splitlines()
            print(stage + ": " + (lines[-1] if lines else "empty"))
