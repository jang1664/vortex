#!/usr/bin/env python3
"""Validate and summarize all sixteen retained v2 verification results."""
import hashlib
import json
from pathlib import Path

VERIFY = Path(__file__).resolve().parent
RUNS = VERIFY.parent / 'runs' / 'v2'
rows = []
reference = None
for quota in (1, 2, 4, 8):
    for case in ('short4', 'short16', 'm4', 'm256'):
        out = RUNS / f'r{quota}-{case}'
        result = json.loads((out / 'result.json').read_text())
        manifest = json.loads((out / 'manifest.json').read_text())
        assert result['passed'], str(out)
        assert result['source_changes'] == [] and result['config_unchanged'], str(out)
        sources = manifest['source_hashes']
        if reference is None:
            reference = sources
        assert sources == reference, f'Source snapshot differs: {out}'
        rows.append(dict(quota=quota, case=case, passed=True,
                         gemm_cycles=result['gemm_cycles'][0],
                         core_cycles=result['core_cycles'][0],
                         fsdb_bytes=result['fsdb_bytes'], log_dir=result['log_dir']))
digest = hashlib.sha256(json.dumps(reference, sort_keys=True).encode()).hexdigest()
summary = dict(iteration='v2', passed_cases=len(rows), source_file_count=len(reference),
               source_hashes_identical=True, source_map_sha256=digest, results=rows)
(VERIFY / 'summary-v2.json').write_text(json.dumps(summary, indent=2) + '\n')
lines = ['# VCS verification results', '',
         'All sixteen v2 runs passed the deterministic verification gates.', '',
         '| Read quota | Case | PASS | GEMM cycles | Core cycles |',
         '|---:|---|---|---:|---:|']
for row in rows:
    lines.append(f"| {row['quota']} | {row['case']} | PASS | {row['gemm_cycles']} | {row['core_cycles']} |")
lines += ['', 'Short cases use K64/N16 and M4 or M16. Benchmark cases use K512/N512.', '',
          f'Every run has an identical {len(reference)}-file RTL/config/app source hash map,',
          'no source changes during execution, and an unchanged per-quota config profile.',
          f'The canonical source-map SHA-256 is `{digest}`.', '',
          'Each run required wrapper and runner status zero, `tools/verify_rtl.py` PASS',
          'without strict failure, exactly one GEMM/core measurement, and a nonempty FSDB.',
          'Hazard and arbitration coverage are analyzed separately by the task owner.', '',
          'Iteration v1 stopped on an undeclared-identifier compilation error before simulation;',
          'v2 includes the declaration-order fix and is the completed sweep.', '',
          'Raw manifests, logs, and waveforms are retained under `../runs/v2/r<quota>-<case>/`.',
          'No production config or RTL was changed by the verification agent.', '']
(VERIFY / 'results.md').write_text('\n'.join(lines))
print(json.dumps({k: summary[k] for k in summary if k != 'results'}))
