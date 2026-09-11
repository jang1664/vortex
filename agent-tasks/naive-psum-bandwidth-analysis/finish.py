"""Wait for capture completion, validate logs, then extract final full traces."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
manifest=TASK/'runs/naive-m256/manifest.json'
while True:
    try:
        state=json.loads(manifest.read_text())
        if state.get('state')=='finished':break
    except (FileNotFoundError,json.JSONDecodeError):
        pass
    time.sleep(15)
spec=importlib.util.spec_from_file_location('verify_rtl',ROOT/'tools/verify_rtl.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
checks=[]
for m in (4,256):
    run=TASK/'runs'/f'naive-m{m}'
    state=json.loads((run/'manifest.json').read_text())
    combined=(run/'wrapper.log').read_text(errors='replace')+'\n'+(run/'simv.log').read_text(errors='replace')
    result=dict(m=m,returncode=state['returncode'],passed=verify.check_pass(combined),
                strict_failure=verify.has_strict_failure(combined),source_changes=state['source_changes_during_run'])
    assert result['returncode']==0 and result['passed'] and not result['strict_failure'] and result['source_changes']==[]
    checks.append(result)
(TASK/'captures/validation.json').write_text(json.dumps(checks,indent=2)+'\n')
print('Both captures PASS; extracting full M256 trace',flush=True)

def extract(command):
    with (TASK/'captures'/(command[0]+'.log')).open('w') as output:
        subprocess.run([sys.executable,str(TASK/command[0]),*command[1:]],cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,check=True)
    print('Completed '+command[0],flush=True)

with ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(extract,[['analyze.py','naive256'],['memory.py','naive256'],['weight.py','naive256']]))
