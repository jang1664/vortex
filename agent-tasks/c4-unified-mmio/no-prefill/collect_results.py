#!/usr/bin/env python3
import json,re
from pathlib import Path
folder=Path(__file__).resolve().parent
cases={
 'fp32_multitile':'-r -f -m 4 -n 256',
 'fp16_multitile':'-r -m 4 -n 256',
 'legacy_single':'-m 4 -n 128',
 'fp32_tail':'-r -f -m 16 -n 257',
 'fp32_mask':'-r -f -m 16 -n 384 -c -p 0',
 'fp32_pv_overflow':'-r -f -m 1 -n 128 -s pv-overflow',
 'fp32_qk_overflow':'-r -f -m 1 -n 128 -s qk-overflow',
}
refs=json.loads((folder/'reference_results.json').read_text())
rows=[]
for name,args in cases.items():
 rc=folder/(name+'.exit')
 if not rc.exists(): continue
 log=(folder/(name+'.log')).read_text(errors='replace')
 phase=re.search(r'^ATTENTION_CYCLES (.+)$',log,re.M)
 fields=dict(re.findall(r'(\w+)=(\d+)',phase.group(1))) if phase else {}
 perf=re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)',log)
 passed=int(rc.read_text())==0 and bool(re.search(r'^PASSED$',log,re.M))
 rows.append({'name':name,'args':args,'exit_code':int(rc.read_text()),'passed':passed,
  'core_cycles':int(perf[-1][1]) if perf else None,
  'instructions':int(perf[-1][0]) if perf else None,
  'attention_cycles':{k:int(v) for k,v in fields.items()},
  'evidence':[l for l in log.splitlines() if l.startswith(('Kernel status=','SRAM copy','output:','output_vs_dense:','FP32_NUMERIC','ATTENTION_CYCLES','PERF:'))],
  'log':str(folder/(name+'.log')),
  'started':(folder/(name+'.started')).read_text().strip(),
  'finished':(folder/(name+'.finished')).read_text().strip()})
(folder/'results.json').write_text(json.dumps({'cases':rows},indent=2)+'\n')
comparison=[]
for row in rows:
 if not row['passed']: continue
 reference={}
 for label,table in refs.items():
  match=next((c for c in table['cases'] if c['name']==row['name']),None)
  if not match: continue
  reference[label]={}
  for metric,before,after in [('core',match['core_cycles'],row['core_cycles']),('attention',match['attention_cycles']['total'],row['attention_cycles']['total'])]:
   reference[label][metric]={'before':before,'after':after,'delta':after-before,'delta_percent':100*(after/before-1),'speedup':before/after}
 if reference: comparison.append({'case':row['name'],'args':row['args'],'comparisons':reference})
(folder/'cycle_comparison.json').write_text(json.dumps({'metric':'xrt-vcs-sim cycles under identical C4 config; lower is faster at fixed clock','fmax_measured':False,'cases':comparison},indent=2)+'\n')
for row in rows: print(row['name'],row['passed'],row['core_cycles'],row['attention_cycles'])
