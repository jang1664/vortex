#!/usr/bin/env python3
"""Static XML elaboration only; no synthesis or runtime simulation."""
import argparse, hashlib, json, shlex, subprocess, shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
p=argparse.ArgumentParser(); p.add_argument('--output',type=Path,required=True); p.add_argument('--mxu',type=int,default=16); p.add_argument('--revision',choices=['baseline','candidate'],required=True); a=p.parse_args()
out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
snapshot=TASK/'p1-isolation/iteration15'/a.revision
# Verilator 5.028 cannot resolve dotted $bits in parameter constants.
# On a private copy, expand exactly the packed VX_mem_bus_if type widths.
original_snapshot=snapshot
snapshot=out/'source'
shutil.copytree(original_snapshot,snapshot)
transport=snapshot/'hw/rtl/mem/VX_slr_mem_bus.sv'
source=transport.read_text()
replacements={
 '$bits(upstream_if.req_data)': '(1 + upstream_if.ADDR_WIDTH + 9 * upstream_if.DATA_SIZE + upstream_if.FLAGS_WIDTH + upstream_if.TAG_WIDTH)',
 '$bits(upstream_if.rsp_data)': '(8 * upstream_if.DATA_SIZE + upstream_if.TAG_WIDTH)',
 '$bits(upstream_if.rsp_data.tag)': 'upstream_if.TAG_WIDTH',
}
for before,after in replacements.items():
 assert source.count(before)==1, before
 source=source.replace(before,after)
transport.write_text(source)
(out/'frontend-adaptations.json').write_text(json.dumps(replacements,indent=2)+'\n')
config=subprocess.check_output(['bash','-c','source agent-tasks/fpint-gemm-latency-compare/improve.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
defines=[d for d in shlex.split(config) if not any(d.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
defines += ['-D'+k+'='+str(a.mxu) for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS')]
cmd=['verilator','--xml-only','--xml-output',str(out/'design.xml'),'--top-module','VX_gemm_node_ooc','-Wno-fatal','-DSYNTHESIS','-DNDEBUG','-DXLEN_64','-DPLATFORM_MEMORY_ID_WIDTH=8',*defines]
manifest=ROOT/'hw/syn/xilinx/gemm_node_ooc/sources.list'
inputs={}
for line in manifest.read_text().splitlines():
 line=line.strip()
 if not line or line.startswith('#'): continue
 prefix='+incdir+' if line.startswith('+incdir+') else ''
 rel=line[len(prefix):]
 path=snapshot/rel if (snapshot/rel).exists() else ROOT/rel
 if rel.startswith('hw/rtl/') and not (snapshot/rel).exists(): raise RuntimeError('Missing frozen RTL: '+rel)
 cmd.append(prefix+str(path))
 if path.is_file(): inputs[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
cmd += ['-y',str(snapshot/'hw/rtl/libs'),'-y',str(snapshot/'hw/rtl/mem'),str(TASK/'p0-boundary-storage-vendor.sv')]
(out/'command.txt').write_text(shlex.join(cmd)+'\n')
with (out/'compile.log').open('w') as log: result=subprocess.run(cmd,cwd=ROOT/'build_p0_boundary_storage_rev3',stdout=log,stderr=subprocess.STDOUT)
report=dict(status='pass' if result.returncode==0 else 'compile_error',returncode=result.returncode,revision=a.revision,mxu=a.mxu,scope='Static elaborated XML; opaque vendor bodies; no synthesis',inputs=inputs)
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps({k:v for k,v in report.items() if k!='inputs'})); raise SystemExit(result.returncode)
