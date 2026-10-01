#!/usr/bin/env python3
"""Elaborate the actual preprocessed package/header and check arithmetic geometry."""
import json, os, shlex, subprocess
from pathlib import Path
build=Path.cwd();out=build/'geometry_check';out.mkdir(exist_ok=True)
rtl=Path(os.environ['FIG5_RTL_ROOT'])
raw=out/'geometry_probe_raw.sv'
raw.write_text('''`include "VX_define.vh"
module geometry_probe;
import VX_tcu_pkg::*;
initial begin
 if (TCU_TC_M*TCU_TC_N*2*TCU_TC_K != 128) $fatal(1,"TCU geometry");
 if (`MXU_ROW != 16 || `MXU_COL != 16 || `MXU_COL_TILE != 16) $fatal(1,"MXU geometry");
 if (`GEMM_ACC_MEM_TOT_SIZE != 262144) $fatal(1,"ACC capacity");
 $display("GEOMETRY PASSED TCU=%0dx%0dx%0d FP16_MAC=128 MXU=%0dx%0d FPINT_MAC=256 ACC_bytes=%0d I_bytes=%0d O_bytes=%0d",TCU_TC_M,TCU_TC_N,2*TCU_TC_K,`MXU_ROW,`MXU_COL,`GEMM_ACC_MEM_TOT_SIZE,`GEMM_INPUT_DATA_SIZE,`GEMM_OUTPUT_DATA_SIZE);
 $finish;
end
endmodule
''')
pp=out/'geometry_probe.sv'
pp.write_text(subprocess.check_output(['verilator','-E','-P',*shlex.split(os.environ['CONFIGS']),'-I'+str(rtl/'hw/rtl'),str(raw)],text=True))
files=(build/'fpga_v2/sources/fp_tcu_128/sources.txt').read_text().splitlines()
with (out/'compile.log').open('w') as log:
 subprocess.run(['verilator','--binary','--top-module','geometry_probe','-Wno-fatal','-j','2','-MAKEFLAGS','CXX=/usr/bin/g++ CC=/usr/bin/gcc',*files,str(pp)],cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
log=subprocess.check_output([str(out/'obj_dir/Vgeometry_probe')],text=True)
(out/'run.log').write_text(log);assert 'GEOMETRY PASSED' in log
(out/'result.json').write_text(json.dumps(dict(status='pass',TCU_MAC_per_cycle=128,FPINT_MAC_per_cycle=256,internal_ACC_bytes=262144,log=log),indent=2)+'\n')
print(log)
