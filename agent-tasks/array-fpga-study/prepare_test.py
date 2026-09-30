#!/usr/bin/env python3
"""Prepare new_tb for tools/verify_rtl.py's unittest Makefile interface.

Run from configured build after sourcing configs/fig5_fpga_compute.sh.
The arithmetic simulation models are independent directed-test models, not
vendor IP models. Synthesis never includes the test directory or these models.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from prepare_woq import derive_woq

TASK=Path(__file__).resolve().parent
ROOT=TASK.parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--reference-sources',type=Path)
    a=ap.parse_args()
    build=Path.cwd()
    if not (build/'config.mk').is_file(): raise RuntimeError('Run from a configured build directory')
    defines=shlex.split(os.environ.get('CONFIGS',''))
    if '-DVIVADO' not in defines or '-DGEMM_IMPROVE' not in defines: raise RuntimeError('Source configs/fig5_fpga_compute.sh first')
    dest=build/'array_fpga_test'; dest.mkdir(exist_ok=True)
    verilator=shutil.which('verilator') or '/opt/vortex/verilator/share/verilator/bin/verilator'
    os.environ['PATH']=str(Path(verilator).parent)+os.pathsep+os.environ['PATH']
    if a.reference_sources:
        flist=a.reference_sources.resolve()
        old=json.loads((flist.parent/'snapshot.json').read_text())
        if old['defines']!=defines: raise RuntimeError('Reference snapshot config differs')
    else:
        spec=importlib.util.spec_from_file_location('fig5_run',ROOT/'agent-tasks/fig5-fpga/run.py')
        mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
        flist=mod.prepare('VX_gemm_unit_top',dest/'sources/wkv',defines)
    woq=derive_woq(flist,dest/'sources/woq')
    rtl=Path(os.environ.get('FIG5_RTL_ROOT',ROOT))/'hw/rtl'
    tb=dest/'tb_ablation.sv'
    command=[verilator,'-E','-P',*defines,f'-I{rtl}',str(TASK/'test/tb_ablation.sv')]
    tb.write_text(subprocess.check_output(command,text=True))
    paths=[Path(p) for p in flist.read_text().splitlines() if p.strip()]
    # All dependencies are byte-identical. Compile shared modules once and add
    # only the differently named derived wrapper.
    sources=[*paths,woq.parent/'VX_gemm_unit_woq_top.sv',TASK/'test/fp_axis_models.sv',tb]
    cmd=[verilator,'--binary','--timing','--top-module','tb_ablation','-Wno-fatal','-j','8',
         '--output-split','10000','--output-split-cfuncs','100',
         '-MAKEFLAGS','CXX=/usr/bin/g++ CC=/usr/bin/gcc',
         *map(str,sources)]
    manifest=dict(test_type='new_tb',runner='tools/verify_rtl.py unittest',defines=defines,
        reference_sources=str(flist),derived_sources=str(woq),
        compile_command=cmd,compilation_sources=list(map(str,sources)),
        source_hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        seeds=[1234,2027,91],
        coverage=['cycle/data equality on QCOL row load','integer numerical oracle','both buffer banks',
                  'three accumulated K tiles','input bubbles','reset and restart','WKV QROW and column load'],
        limitations=['Simulation-only finite directed arithmetic and AXI models; not Xilinx IP simulation or IEEE corner cases',
                     'Production output readout is a valid pulse independent of ready; low-ready test checks equivalence, not lossless backpressure',
                     'SYNTHESIS-preprocessed exact datapath; production simulation-only assertions are absent'])
    (dest/'test_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (dest/'Makefile').write_text('SHELL := /bin/bash\n.PHONY: compile run\ncompile:\n\tpython3 '+str(TASK/'test/compile_test.py')+'\nrun:\n\t@mkdir -p logs\n\t@set -e -o pipefail; { for seed in 1234 2027 91; do ./obj_dir/Vtb_ablation +SEED=$$seed; done; } 2>&1 | tee logs/sim.log\n')
    print(dest)

if __name__=='__main__': main()
