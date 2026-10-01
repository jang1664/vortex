#!/usr/bin/env python3
import argparse,datetime,json,os,re,shutil
from pathlib import Path
TASK=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--brief',action='store_true');p.add_argument('--record',action='store_true');a=p.parse_args()
m=json.loads((TASK/'manifest.json').read_text());now=datetime.datetime.now().astimezone();rows=[]
def tail(path,limit=196608):
 try:
  with path.open('rb') as f:f.seek(max(0,path.stat().st_size-limit));return f.read().decode(errors='replace')
 except OSError:return ''
for r in m['profiles']:
 statefile=Path(r['directory'])/'execution.json';e=json.loads(statefile.read_text()) if statefile.exists() else {}
 row=dict(profile=r['profile'],state=e.get('state','STARTING'),pid=r['driver_pid'],elapsed_seconds=int((now-datetime.datetime.fromisoformat(r['started_at'])).total_seconds()))
 if not a.brief:
  output=Path(r['build'])/'hw/syn/xilinx/xrt'/(Path(r['config']).stem+'_'+m['platform']+'_hw')
  log=Path(r['directory'])/'pnr.log';text=tail(log);phase='RTL/IP packaging'
  runlogs=list(output.glob('_x/link/vivado/vpl/prj/prj.runs/*/runme.log'))+list(output.glob('_x/link/vivado/vpl/vivado.log'))
  started_epoch=datetime.datetime.fromisoformat(e.get('started_at',r['started_at'])).timestamp()
  for q in sorted(runlogs,key=lambda q:q.stat().st_mtime):
   if q.stat().st_mtime>=started_epoch:text+='\n'+tail(q)
  markers=[('v++ link','v++'),('Synthesis','Starting synth_design'),('Synthesis','synth_design -'),('Implementation preparation','Step impl: Started'),('Optimization','Starting opt_design'),('Optimization','Command: opt_design'),('Placement','Starting place_design'),('Placement','Command: place_design'),('Placement','Phase 1 Placer'),('Routing','Starting route_design'),('Routing','Command: route_design'),('Routing','Phase 1 Build RT'),('Bitstream generation','Starting write_bitstream'),('Bitstream generation','Command: write_bitstream')]
  for name,marker in markers:
   if marker in text:phase=name
  if row['state']=='COMPLETED':phase='Finished'
  row.update(phase=phase,returncode=e.get('returncode'),output=str(output),log=str(log),log_modified_at=datetime.datetime.fromtimestamp(log.stat().st_mtime).astimezone().isoformat() if log.exists() else None,errors=re.findall(r'^ERROR:.*$',text,re.MULTILINE)[-8:],critical_warnings=re.findall(r'^CRITICAL WARNING:.*$',text,re.MULTILINE)[-8:],latest_log_lines=[s for s in tail(log,4096).splitlines() if not s.startswith('#')][-6:])
  row['xclbins']=[str(q) for q in output.glob('bin/*.xclbin')]
 rows.append(row)
report=dict(checked_at=now.isoformat(),next_check_at=m.get('next_check_at'),rows=rows)
if not a.brief:
 disk=shutil.disk_usage(m['root']);report['disk_free_gib']=round(disk.free/2**30,1)
 with open('/proc/meminfo') as f:mem=dict(re.findall(r'^(\w+):\s+(\d+)',f.read(),re.MULTILINE))
 report['memory_available_gib']=round(int(mem['MemAvailable'])/2**20,1)
if a.record:
 report['next_check_at']=(now+datetime.timedelta(seconds=m['monitor_interval_seconds'])).isoformat()
 dest=TASK/'checks';dest.mkdir(exist_ok=True);(dest/(now.strftime('%Y%m%d_%H%M%S')+'.json')).write_text(json.dumps(report,indent=2)+'\n')
 (TASK/'latest_status.json').write_text(json.dumps(report,indent=2)+'\n')
 m['last_check_at']=now.isoformat();m['next_check_at']=(now+datetime.timedelta(seconds=m['monitor_interval_seconds'])).isoformat();(TASK/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
print(json.dumps(report,indent=2))
