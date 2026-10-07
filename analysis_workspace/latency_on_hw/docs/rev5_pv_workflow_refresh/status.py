import csv
import json
from pathlib import Path

doc = Path(__file__).resolve().parent
cutoff = (doc / 'before.json').stat().st_mtime
before = json.loads((doc / 'before.json').read_text())
for model, saved in before.items():
    root = Path(saved['C4']['path']).parent
    counts = {}
    for staging in sorted((root / 'remeasurements').glob('*')):
        if staging.stat().st_mtime < cutoff:
            continue
        db = staging / 'raw_db.csv'
        rows = list(csv.DictReader(db.open())) if db.exists() else []
        status = {}
        for row in rows:
            state = row.get('status') or 'pending'
            status[state] = status.get(state, 0) + 1
        counts[staging.name] = status
    print(model, json.dumps(counts), flush=True)
