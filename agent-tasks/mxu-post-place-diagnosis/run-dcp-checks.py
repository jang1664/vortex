import json,subprocess,shlex
from pathlib import Path
root=Path(__file__).resolve().parents[2]
task=Path(__file__).resolve().parent
runs=json.loads((task/'dcp-checks.json').read_text())
active=[]
for run in runs:
 config=root/'configs'/(run['config']+'.sh')
 command='source '+shlex.quote(str(config))+'; exec vivado -mode batch -nolog -nojournal -source '+shlex.quote(str(root/'hw/syn/xilinx/xrt/tests/check_mxu_slr_dcp.tcl'))+' -tclargs '+shlex.quote(run['dcp'])+' '+shlex.quote(run['reports'])
 with open(run['log'],'x') as log:
  proc=subprocess.Popen(['bash','-c',command],cwd=root/'build',stdout=log,stderr=subprocess.STDOUT)
 active.append((run,proc))
 print(run['config'],proc.pid,flush=True)
for run,proc in active:
 run['returncode']=proc.wait()
 print(run['config'],'returncode',run['returncode'],flush=True)
(task/'dcp-check-results.json').write_text(json.dumps(runs,indent=2)+'\n')
raise SystemExit(any(r['returncode'] for r in runs))
