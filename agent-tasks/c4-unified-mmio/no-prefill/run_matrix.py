#!/usr/bin/env python3
import datetime,json,subprocess,sys,yaml
from pathlib import Path
p=Path(__file__).resolve().parent
cases=[('fp32_multitile','-r -f -m 4 -n 256'),('fp16_multitile','-r -m 4 -n 256'),('legacy_single','-m 4 -n 128'),('fp32_tail','-r -f -m 16 -n 257'),('fp32_mask','-r -f -m 16 -n 384 -c -p 0'),('fp32_pv_overflow','-r -f -m 1 -n 128 -s pv-overflow'),('fp32_qk_overflow','-r -f -m 1 -n 128 -s qk-overflow')]
for name,args in cases:
 result=subprocess.run(['bash',str(p/'run_case.sh'),name,args])
 subprocess.run([sys.executable,str(p/'collect_results.py')],check=True)
 row=next(x for x in json.loads((p/'results.json').read_text())['cases'] if x['name']==name)
 status=yaml.safe_load((p/'STATUS.yaml').read_text())
 status['iterations'].append({'iteration':1,'test':'fullcore_'+name,'status':'pass' if row['passed'] else ('timeout' if result.returncode==124 else 'sim_fail'),'timestamp':datetime.datetime.now().astimezone().isoformat(),'error_summary':'' if row['passed'] else 'See archived wrapper and simv logs.','report':row['log'],'core_cycles':row['core_cycles'],'attention_cycles':row['attention_cycles'],'fix_applied':'None by verification agent; current no-prefill source and matching config.'})
 (p/'STATUS.yaml').write_text(yaml.safe_dump(status,sort_keys=False))
 print('Recorded',name,'PASS' if row['passed'] else 'FAIL',flush=True)
 if not row['passed']: sys.exit(result.returncode or 1)
