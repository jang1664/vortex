"""Apply the agreed two-shape non-regression gate to completed VCS results."""
import argparse
import json
import math
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('iteration', type=Path)
a = p.parse_args()
baseline = {'m4': 15970, 'm256': 671993}
rows = []
source_snapshots = []
for quota in [1, 2, 4, 8]:
    cases = {}
    for case in ['short4', 'short16', 'm4', 'm256']:
        run = a.iteration / f'r{quota}-{case}'
        result = json.loads((run / 'result.json').read_text())
        manifest = json.loads((run / 'manifest.json').read_text())
        assert result['passed'] and not result['source_changes'], str(run)
        assert result['read_quota'] == quota and result['case'] == case
        source_snapshots.append(manifest['source_hashes'])
        cases[case] = {key: result[key][0] for key in ['gemm_cycles', 'core_cycles']}
    eligible = all(cases[case]['gemm_cycles'] <= value for case, value in baseline.items())
    score = math.sqrt(math.prod(value / cases[case]['gemm_cycles'] for case, value in baseline.items()))
    rows.append(dict(read_quota=quota, eligible=eligible, geometric_mean_speedup=score, cases=cases))
assert all(snapshot == source_snapshots[0] for snapshot in source_snapshots), 'Sweep RTL source hashes differ'
eligible = [row for row in rows if row['eligible'] and row['geometric_mean_speedup'] > 1]
selected = max(eligible, key=lambda row: (row['geometric_mean_speedup'], -row['read_quota'])) if eligible else None
report = dict(baseline_gemm_cycles=baseline, candidates=rows,
              selected_quota=selected['read_quota'] if selected else None,
              source_hashes_identical=True)
(a.iteration / 'selection.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
