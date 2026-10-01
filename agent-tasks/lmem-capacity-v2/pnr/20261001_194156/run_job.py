#!/usr/bin/env python3
import argparse,datetime,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--profile',required=True);p.add_argument('--build',required=True);p.add_argument('--config',required=True);p.add_argument('--directory',required=True);a=p.parse_args()
def now():return datetime.datetime.now().astimezone().isoformat()
dir=Path(a.directory);state=dict(profile=a.profile,job_id=os.environ.get('SLURM_JOB_ID'),started_at=now(),state='RUNNING')
command=[str(Path(a.build)/'hw/syn/xilinx/xrt/run_hw.sh'),'--config',a.config,'--no-early-fail']
state['command']=command
(dir/'execution.json').write_text(json.dumps(state,indent=2)+'\n')
print(a.profile+' started '+state['started_at'],flush=True)
with (dir/'pnr.log').open('w') as log:
 try:
  process=subprocess.Popen(command,cwd=a.build,stdout=log,stderr=subprocess.STDOUT)
  state['pid']=process.pid;(dir/'execution.json').write_text(json.dumps(state,indent=2)+'\n')
  rc=process.wait()
 except Exception as error:
  state['error']=str(error);rc=1
state.update(finished_at=now(),returncode=rc,state='COMPLETED' if rc==0 else 'FAILED')
(dir/'execution.json').write_text(json.dumps(state,indent=2)+'\n')
print(a.profile+' '+state['state']+' rc='+str(rc),flush=True)
raise SystemExit(rc)
