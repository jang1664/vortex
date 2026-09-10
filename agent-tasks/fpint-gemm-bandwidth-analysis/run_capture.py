#!/usr/bin/env python3
import json, os, re, shutil, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
name=sys.argv[1]
build=ROOT/f'build_fpint_latency_{name}_vcs'
out=ROOT/'docs/hw_analysis/improve_vs_naive/fsdb_m4'/name
out.mkdir(parents=True,exist_ok=True)
config=ROOT/'agent-tasks/fpint-gemm-latency-compare'/f'{name}.sh'
raw=subprocess.check_output(['bash','-c','source "$1"; env -0','bash',str(config)],cwd=ROOT)
env=dict(v.split('=',1) for v in raw.decode().split('\0') if '=' in v)
for k in ['DEBUG','PERF','SCOPE','LOG_MAX_BYTES','FPGA_BIN_DIR','XRT_XCLBIN_PATH']:
 env.pop(k,None)
env.update(CC='/usr/bin/gcc',CXX='/usr/bin/g++',GUI='0',PATH='/usr/bin:'+env['PATH'],VCS_SIMV_FLAGS=f'+fsdb_file={out}/m4.fsdb')
app='fpint_gemm_ffn_hw'+('_naive' if name=='naive' else '')
cmd=['timeout','600','ci/run_black.sh','xrt-vcs-sim','--perf','3','--app',app,'--args','-m 4 -k 512 -n 512 -q 32 -t 0 -d 0 -r 1']
# Force source re-elaboration, preserving the previous executable.
simv=build/'sim/xrtsim_vcs/simv'
if simv.exists(): simv.rename(simv.with_name('simv_before_fsdb_analysis'))
with (out/'wrapper.log').open('w') as f:
 rc=subprocess.run(cmd,cwd=build,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
for f in ['simv.log','u55c_model_manifest.json']:
 shutil.copy2(build/'sim/xrtsim_vcs'/f,out/f)
log=(out/'wrapper.log').read_text()
r={'returncode':rc,'passed':bool(re.search(r'^PASSED$',log,re.M)),'command':cmd,'CONFIGS':env['CONFIGS'],'perf':[l for l in log.splitlines() if l.startswith('PERF:')]}
(out/'manifest.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps(r),flush=True)
sys.exit(0 if rc==0 and r['passed'] else 1)
