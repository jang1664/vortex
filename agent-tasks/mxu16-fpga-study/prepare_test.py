#!/usr/bin/env python3
"""Reuse the original directed test; resize only its output-lane coverage count."""
import hashlib, json, subprocess, sys
from pathlib import Path
TASK=Path(__file__).resolve().parent
build=Path.cwd()
subprocess.run([sys.executable,str(TASK.parent/'array-fpga-study/prepare_test.py'),'--reference-sources',str(build/'mxu16_fpga/sources/wkv_16x16/sources.txt')],check=True)
p=build/'array_fpga_test/tb_ablation.sv'
s=p.read_text();old='checked_lanes!=576';assert s.count(old)==1
p.write_text(s.replace(old,'checked_lanes!=(18*16)'))
m=build/'array_fpga_test/test_manifest.json';data=json.loads(m.read_text())
data['source_hashes'][str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
data['coverage_counter_adaptation']='18 output vectors x 16 columns = 288 lanes per seed; all stimulus and arithmetic checks unchanged'
data['expected_lanes_per_seed']=288
m.write_text(json.dumps(data,indent=2)+'\n')
