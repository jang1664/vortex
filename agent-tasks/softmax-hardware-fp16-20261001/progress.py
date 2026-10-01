from pathlib import Path
import csv
from collections import Counter

ROOT = Path(__file__).resolve().parents[2]
for model in ("llama2", "llama3"):
    root = ROOT / "analysis_workspace/latency_on_hw" / (
        f"outputs_{model}_main.th16_20260920_c4_slots16_v2r1/C4/remeasurements")
    paths = list(root.glob("generation.20261001*"))
    if not paths:
        continue
    path = max(paths, key=lambda p: p.stat().st_mtime) / "raw_db.csv"
    if not path.exists():
        continue
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    counts = Counter(r["status"] for r in rows)
    print(model, f"{counts['pass']}/{len(rows)} complete",
          f"{sum(v for k, v in counts.items() if k not in ('', 'pass'))} failed")
