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
rtl=ROOT/'hw/rtl';tb=ROOT/'hw/unittest/mem_bus_split_depth/tb_mem_bus_split_depth.sv'
results=[]
matrix=[(l,b,d,1,1,o,o,12) for o in [0,1] for l,b in [(4,64),(32,8)] for d in [8,16,32,64,128]]
matrix += [(l,b,d,0,2,1,1,12) for l,b in [(4,64),(32,8)] for d in [8,128]]
matrix += [(l,b,128,1,2,1,1,5) for l,b in [(4,64),(32,8)]]
for lanes,bytes_,depth,masked,seed,reorder,inject,tagbits in matrix:
 name=f'l{lanes}_d{depth}_m{masked}_s{seed}_o{reorder}_t{tagbits}'
 out=BUILD/'split_guarded_uuid'/name;out.mkdir(parents=True,exist_ok=True)
 cmd=['vcs','-full64','-sverilog','-timescale=1ns/1ps','+define+SIMULATION','+define+XLEN_64','+define+NDEBUG','+define+GEMM_NAIVE',f'+incdir+{rtl}','+libext+.sv','-y',str(rtl/'libs'),'-y',str(rtl/'mem'),str(rtl/'VX_gpu_pkg.sv'),str(rtl/'mem/VX_mem_bus_if.sv'),str(TASK/'final_candidate/VX_mem_bus_split.sv'),str(tb),'-top','tb_mem_bus_split_depth']
 for k,v in dict(LANES=lanes,BYTES=bytes_,DEPTH=depth,MASKED=masked,SEED=seed,REORDER=reorder,INJECT_REORDER=inject,TAG_BITS=tagbits).items():cmd.append(f'-pvalue+tb_mem_bus_split_depth.{k}={v}')
 with (out/'compile.log').open('w') as log:rc=subprocess.run(cmd,cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
 if rc:raise RuntimeError(f'Compile failed: {out}')
 with (out/'sim.log').open('w') as log:rc=subprocess.run(['./simv'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120).returncode
 text=(out/'sim.log').read_text();passed=rc==0 and 'TEST PASSED:' in text and 'Fatal' not in text
 results.append(dict(lanes=lanes,bytes=bytes_,depth=depth,masked=masked,seed=seed,reorder=reorder,tagbits=tagbits,passed=passed,log=str(out/'sim.log')))
 print(name,passed,flush=True)
 (TASK/'split_guarded_uuid_results.json').write_text(json.dumps(results,indent=2)+'\n')
 if not passed:sys.exit(1)
