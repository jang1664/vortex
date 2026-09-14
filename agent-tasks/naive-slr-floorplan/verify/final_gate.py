#!/usr/bin/env python3
"""Evaluate the complete simulation/preservation gate without counting aborted setups."""
import hashlib,json,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
TASK=HERE.parent
subprocess.run([sys.executable,str(HERE/'summarize.py')],check=True)
summary=json.loads((HERE/'summary.json').read_text())
required=[]
for mode in ['off','on']:
 for m,n,k in [(4,16,64),(16,16,64),(4,512,512),(256,512,512)]: required.append(f'candidate-naive-{mode}-m{m}-n{n}-k{k}')
 for m in [4,256]:required.append(f'candidate-improve-{mode}-m{m}-n512-k512')
required += [f'candidate-naive-on-m16-n64-k64-tag-w{w}-d{d}' for w in [0,1] for d in [0,1]]
checks={}
for name in required:
 p=TASK/'runs'/name/'result.json'
 checks[name]=p.exists() and json.loads(p.read_text())['passed']
 if 'candidate-naive-' in name:
  p=p.with_name('drain_audit.json')
  checks[name+'-drain']=p.exists() and json.loads(p.read_text())['passed']
for c in summary['improve_comparisons']:checks[f"improve-cycles-{c['mode']}-m{c['m']}"]=c['complete'] and c['passed']
for unit in json.loads((HERE/'unit_results.json').read_text()):
 if unit.get('required_gate',True):checks['unit-'+unit['test']]=unit['passed']
for name,count in [('improve-identity',1148),('naive-off-identity',574)]:
 records=json.loads((TASK/'runs'/name/'result.json').read_text())
 checks[name]=len(records)==count and all(r['identical'] for r in records)
anchor=TASK/'runs/baseline-naive-off-short4/result.json'
a=json.loads(anchor.read_text());b=json.loads((TASK/'runs/candidate-naive-off-m4-n16-k64/result.json').read_text())
checks['naive-baseline-short-anchor']=a['passed'] and a['gemm_cycles']==b['gemm_cycles'] and a['core_cycles']==b['core_cycles']
root=TASK.parents[1]
def rtl_hashes(base):
 return {str(p.relative_to(base)):hashlib.sha256(p.read_bytes()).hexdigest() for p in base.rglob('*') if p.is_file()}
checks['candidate-current-rtl-matches']=rtl_hashes(root/'hw/rtl')==rtl_hashes(root/'build_naive_slr_candidate_source/hw/rtl')
result=dict(passed=all(checks.values()),checks=checks,pending_or_failed=[k for k,v in checks.items() if not v])
(HERE/'simulation_gate.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(passed=result['passed'],checks=len(checks),pending_or_failed=result['pending_or_failed'])))
sys.exit(0 if result['passed'] else 1)
