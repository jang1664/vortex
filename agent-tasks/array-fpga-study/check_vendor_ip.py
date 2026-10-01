#!/usr/bin/env python3
"""Run generated AMD FP IP models; complements the fast directed RTL test."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import re
from resources import sha
p=argparse.ArgumentParser();p.add_argument('baseline',type=Path);a=p.parse_args()
task=Path(__file__).resolve().parent
assert (Path.cwd()/'config.mk').exists()
assert '-DVIVADO' in os.environ['CONFIGS']
out=Path.cwd()/'vendor_ip_check';out.mkdir(exist_ok=True)
vivado=os.environ.get('VIVADO','/tool/Program/Xilinx/2025.1/Vivado/bin/vivado')
cmd=[vivado,'-mode','batch','-source',str(task/'vendor_ip_sim.tcl'),'-tclargs',str(a.baseline.resolve()),str(out),str(task/'vendor_ip_tb.sv')]
with (out/'console.log').open('w') as f:
 rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
text=(out/'console.log').read_text()
m=re.search(r'VENDOR IP TEST PASSED accepted=(\d+) returned=(\d+) measured_handshake_latency=(\d+) consecutive_outputs=(\d+)',text)
result=dict(status='pass' if rc==0 and m else 'sim_fail',exit_code=rc,command=cmd,
 testbench_sha256=sha(task/'vendor_ip_tb.sv'),log_sha256=sha(out/'console.log'),
 scope='Actual generated AMD FP16 multiply, FP32 multiply/add models; directed finite arithmetic, always ready, burst + valid gaps; not full IEEE proof')
if m: result.update(zip(('accepted','returned','measured_handshake_latency','consecutive_outputs'),map(int,m.groups())))
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
if result['status']!='pass': raise SystemExit(1)
