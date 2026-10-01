#!/usr/bin/env python3
"""Run current AXI static assertions and check elaborated 32-port geometry."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import run

build=Path.cwd();assert (build/'config.mk').exists()
assert '-DNUM_THREADS=8' in os.environ['CONFIGS'], 'Source fig5_fpga_memory.sh'
out=build/'axi_geometry_check';out.mkdir(exist_ok=True)
defs=[x for x in shlex.split(os.environ['CONFIGS']) if x!='-DSYNTHESIS']+['-DSIMULATION']
flist=run.f.prepare('VX_axi_adapter',out/'sources',defs)
files=flist.read_text().splitlines();results=[]
for n in (1,4):
 point=out/str(n);point.mkdir(exist_ok=True)
 tb=point/'axi_geometry_probe.sv'
 tb.write_text(f'''module axi_geometry_probe;
 VX_axi_adapter #(.NUM_PORTS_IN({n}), .NUM_BANKS_OUT(32), .NUM_HBM_PORTS(32),
 .INTERLEAVE(1), .DATA_WIDTH(512), .ADDR_WIDTH_IN(28), .ADDR_WIDTH_OUT(34),
 .TAG_WIDTH_IN(16), .TAG_WIDTH_OUT(16)) dut(.clk(1'b0), .reset(1'b1));
 initial begin
  #1;
  if ($size(dut.m_axi_arvalid)!=32 || $size(dut.m_axi_awvalid)!=32)
   $fatal(1,"Physical output port count");
  if ($bits(dut.m_axi_araddr[0])!=34 || $bits(dut.mem_req_addr[0])!=28)
   $fatal(1,"Physical address width");
  if (dut.PORTS_PER_GROUP!=1 || dut.NUM_PORTS_IN!={n})
   $fatal(1,"Transport group geometry");
  $display("AXI GEOMETRY PASSED requests={n} groups=32 HBM_ports=32 address_bits=34");
  $finish;
 end
endmodule
''')
 cmd=['verilator','--binary','--timing','--top-module','axi_geometry_probe','-Wno-fatal',
      '-j','2','-MAKEFLAGS','CXX=/usr/bin/g++ CC=/usr/bin/gcc',*files,str(tb)]
 with (point/'compile.log').open('w') as log:
  subprocess.run(cmd,cwd=point,stdout=log,stderr=subprocess.STDOUT,check=True)
 log=subprocess.check_output([str(point/'obj_dir/Vaxi_geometry_probe')],text=True)
 (point/'run.log').write_text(log);assert 'AXI GEOMETRY PASSED' in log
 results.append(dict(input_ports=n,transport_groups=32,physical_ports=32,address_bits=34,status='pass',log=log))
 print(log)
(out/'result.json').write_text(json.dumps(dict(status='pass',points=results,
 scope='Actual current production static assertions enabled with SIMULATION; elaborated geometry only, not a new AXI traffic test.'),indent=2)+'\n')
