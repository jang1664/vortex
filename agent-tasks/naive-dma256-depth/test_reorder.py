#!/usr/bin/env python3
"""Exercise splitter buffering using VCS in a configured build."""
import json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
BUILD=ROOT/'build_naive_dma256_unit_vcs';BUILD.mkdir(exist_ok=True)
with (TASK/'unit_configure.log').open('w') as log:
 subprocess.run(['../configure','--xlen=64','--tooldir=/opt/vortex',f'--prefix={Path.home()}/tools/vortex'],cwd=BUILD,stdout=log,stderr=subprocess.STDOUT,check=True)
raw=subprocess.check_output(['bash','-c','source "$1"; env -0','bash',str(TASK/'configs/d8_r32.sh')],cwd=ROOT)
env=dict(x.split('=',1) for x in raw.decode().split('\0') if '=' in x);env.update(CC='/usr/bin/gcc',CXX='/usr/bin/g++')
# DUT-only package shape; avoid irrelevant CPU/GEMM integration assertions.
rtl=ROOT/'hw/rtl';tb=TASK/'candidate/tb_mem_bus_split_depth.sv'
results=[]
for lanes,bytes_ in [(4,64),(32,8)]:
 for depth in [8,16,32,64,128]:
  name=f'l{lanes}_d{depth}';out=BUILD/'split_reorder'/name;out.mkdir(parents=True,exist_ok=True)
  cmd=['vcs','-full64','-sverilog','-timescale=1ns/1ps','+define+SIMULATION','+define+XLEN_64','+define+NDEBUG',f'+incdir+{rtl}','+libext+.sv','-y',str(rtl/'libs'),'-y',str(rtl/'mem'),str(rtl/'VX_gpu_pkg.sv'),str(rtl/'mem/VX_mem_bus_if.sv'),str(TASK/'candidate/VX_mem_bus_split.sv'),str(tb),'-top','tb_mem_bus_split_depth',f'-pvalue+tb_mem_bus_split_depth.LANES={lanes}',f'-pvalue+tb_mem_bus_split_depth.BYTES={bytes_}',f'-pvalue+tb_mem_bus_split_depth.DEPTH={depth}']
  with (out/'compile.log').open('w') as log:rc=subprocess.run(cmd,cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
  if rc: print(f'COMPILE FAIL {out}',flush=True);returncode=1;break
  with (out/'sim.log').open('w') as log:rc=subprocess.run(['./simv'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120).returncode
  text=(out/'sim.log').read_text();passed=rc==0 and 'TEST PASSED:' in text and 'Fatal' not in text
  results.append(dict(lanes=lanes,bytes=bytes_,depth=depth,passed=passed,log=str(out/'sim.log')))
  print(name,passed,flush=True)
  (TASK/'split_reorder_results.json').write_text(json.dumps(results,indent=2)+'\n')
  if not passed:sys.exit(1)
 else:continue
 sys.exit(1)
