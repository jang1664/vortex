from pathlib import Path
import os,json,subprocess,shlex,time,re,signal,hashlib,difflib
out=Path(__file__).resolve().parent
record=json.loads((out/'experiment.json').read_text())
repo,build=Path(record['repo']),Path(record['build'])
env=os.environ.copy()
for k in ('CONFIGS','PERF','DEBUG','SCOPE','PROFILE','GUI','FSDB_DUMP','VORTEX_HOME','VORTEX_RT_PATH','VORTEX_KN_PATH','FPGA_BIN_DIR','XRT_XCLBIN_PATH','XRT_DEVICE_INDEX','XRT_DEVICE_BDF','XRT_INI_PATH','VX_KERNEL','ITYPE','OTYPE','ACC_TYPE'):
 env.pop(k,None)
env.update(PATH='/usr/bin:'+env['PATH'],CC='/usr/bin/gcc',CXX='/usr/bin/g++',MAKEFLAGS='-j4')
app=record['app'];args=record['modes'][0]['args']
results=[]

def run(folder,command,cwd=build):
 folder.mkdir(exist_ok=True)
 (folder/'command.sh').write_text('#!/bin/bash\nset -e\ncd '+shlex.quote(str(cwd))+'\n'+shlex.join(command)+'\n')
 start=time.monotonic();timeout=False
 with (folder/'run.log').open('w') as f:
  p=subprocess.Popen(command,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=record['max_seconds'])
  except subprocess.TimeoutExpired:
   timeout=True;os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   rc=124
 log=(folder/'run.log').read_text(errors='replace')
 r={'returncode':rc,'timed_out':timeout,'seconds':round(time.monotonic()-start,3),'passed':rc==0 and bool(re.search(r'\bPASSED\b',log))}
 perf=re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)',log)
 if perf:r.update(instrs=int(perf[-1][0]),cycles=int(perf[-1][1]),ipc=float(perf[-1][2]))
 d=re.search(r'HW XRT_DEVICE_INDEX=(\S+) XRT_DEVICE_BDF=(\S+)',log)
 if d:r.update(device_index=d[1],device_bdf=d[2])
 r['notable_lines']=[l for l in log.splitlines() if len(l)<350 and re.search(r'Invalid parameters|Mismatch|PASSED|FAILED|Verified job|Active MXU|QBLK=|TMEM.*overflow',l)][-16:]
 (folder/'result.json').write_text(json.dumps(r,indent=2)+'\n')
 return r

original=repo/'tests/regression'/app/'main.cpp';diagnostic=Path(record['diagnostic_source'])/'main.cpp'
(out/'host_guard.diff').write_text(''.join(difflib.unified_diff(original.read_text().splitlines(True),diagnostic.read_text().splitlines(True),fromfile=str(original),tofile=str(diagnostic))))
print('START original host, QBLK=16',flush=True)
basecmd=['ci/run_black.sh','hw','--fpga-bin',record['alias'],'--app',app]
r=run(out/'original_guard',basecmd+['--args',args]);print('ORIGINAL '+json.dumps(r),flush=True)
assert r['returncode']!=0 and 'Invalid parameters: QBLK=16' in (out/'original_guard/run.log').read_text(), 'Original host did not reject as expected'
config=repo/record['mapping']['configs']
appbuild=build/'tests/regression'/app
basebuild='set -e\nsource '+shlex.quote(str(config))+'\n'
buildcmd=basebuild+shlex.join(['make','-B','-C',str(appbuild),'TARGET=hw',app,'SRC_DIR='+record['diagnostic_source']])
print('BUILD diagnostic host only',flush=True)
r=run(out/'diagnostic_build',['bash','-c',buildcmd]);assert r['returncode']==0,r
try:
 for mode in record['modes']:
  print('START QBLK16 '+mode['id'],flush=True)
  r=run(out/mode['id'],basecmd+['--args',mode['args'],'--run-only']);r.update(mode)
  r['kernel_sha256']=hashlib.sha256((appbuild/'kernel.vxbin').read_bytes()).hexdigest()
  (out/mode['id']/'result.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r)
  (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+mode['id']+' '+json.dumps(r),flush=True)
  if r['timed_out']:break
finally:
 print('RESTORE original host binary',flush=True)
 restore=basebuild+shlex.join(['make','-B','-C',str(appbuild),'TARGET=hw',app])
 r=run(out/'restore_original_host',['bash','-c',restore]);assert r['returncode']==0,r
 assert hashlib.sha256(original.read_bytes()).hexdigest()==record['original_main_sha256']
 (out/'STATUS.yaml').write_text('status: complete\nmode: hw\nquantization_block: 16\noriginal_host_restored: true\ncompleted: '+str(len(results))+'\npassed: '+str(sum(r['passed'] for r in results))+'\n')
