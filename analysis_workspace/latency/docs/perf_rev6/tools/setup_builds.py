#!/usr/bin/env python3
"""Configure isolated simulation trees and add the passive observation source."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[5]
MONITOR=Path(__file__).with_name('fine_monitor.sv')
for candidate in ['c3','c4']:
    build=ROOT/f'build_latency_perf_{candidate}_rev6'
    build.mkdir(exist_ok=True)
    subprocess.run(['../configure','--xlen=64','--tooldir=/opt/vortex','--prefix='+str(Path.home()/'tools/vortex')],cwd=build,check=True)
    makefile=build/'sim/xrtsim_vcs/Makefile'
    text=makefile.read_text()
    text+='\n# Passive analysis-only monitor; no source RTL changes.\n'
    text+='RTL_PKGS += '+str(MONITOR)+'\n'
    text+='$(DESTDIR)/simv: '+str(MONITOR)+'\n'
    if candidate == 'c3':
        text+='$(DESTDIR)/simv: '+str(ROOT/'hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv')+'\n'
    makefile.write_text(text)
    print('Configured',build)
