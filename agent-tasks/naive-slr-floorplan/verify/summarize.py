#!/usr/bin/env python3
"""Summarize completed runs and compare matched improve cycle vectors."""
import json
from pathlib import Path
TASK=Path(__file__).resolve().parents[1]
rows=[]
for result in sorted((TASK/'runs').glob('*/result.json')):
 if not result.with_name('manifest.json').exists(): continue
 r=json.loads(result.read_text()); m=json.loads(result.with_name('manifest.json').read_text())
 rows.append(dict(run=result.parent.name,classification=('aborted infrastructure setup' if m.get('returncode') in [-15,143] and not r['gemm_cycles'] else 'simulation'),passed=r['passed'],gemm=r['gemm_cycles'],core=r['core_cycles'],backend=m['backend'],m=m['m'],n=m['n'],k=m['k'],config=m['config']))
comparisons=[]
for mode in ['off','on']:
 for size in [4,256]:
  pre=next((r for r in rows if r['run'].startswith(f'baseline-improve-{mode}-m{size}') and r['passed']),None)
  post=next((r for r in rows if r['run']==f'candidate-improve-{mode}-m{size}-n512-k512'),None)
  comparisons.append(dict(mode=mode,m=size,complete=bool(pre and post),passed=bool(pre and post and post['passed'] and pre['gemm']==post['gemm'] and pre['core']==post['core']),before=pre,after=post))
(TASK/'verify/summary.json').write_text(json.dumps(dict(runs=rows,improve_comparisons=comparisons),indent=2)+'\n')
lines=['# Simulation results','','| Run | Classification | Pass | GEMM cycles | Core cycles |','|---|---|---|---|---|']
lines += [f"| {r['run']} | {r['classification']} | {r['passed']} | {r['gemm']} | {r['core']} |" for r in rows]
lines += ['','## Improve cycle preservation','']+[f"- SLR {r['mode']}, M{r['m']}: "+('PASS' if r['passed'] else 'FAIL' if r['complete'] else 'pending') for r in comparisons]
(TASK/'verify/results.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(dict(completed=len(rows),passing=sum(r['passed'] for r in rows),comparisons=[(r['mode'],r['m'],r['complete'],r['passed']) for r in comparisons])))
