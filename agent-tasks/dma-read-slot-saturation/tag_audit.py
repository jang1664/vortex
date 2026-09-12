import pathlib, subprocess, shlex, re, json
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path(__file__).resolve().parent/'runs/tag-audit'
OUT.mkdir(parents=True,exist_ok=True)
incs=[f'+incdir+{p}' for p in sorted({p.parent for p in (ROOT/'hw/rtl').rglob('*.vh')})]
head=OUT/'head_pkg.sv'
head.write_text(subprocess.check_output(['git','show','93bf45d0:hw/rtl/VX_gpu_pkg.sv'],cwd=ROOT,text=True))
current=ROOT/'hw/rtl/VX_gpu_pkg.sv'
configs={'naive':'agent-tasks/dma-read-slot-saturation/baseline-naive.sh','improve':'agent-tasks/dma-read-slot-saturation/baseline-improve.sh'}
records=[]
for backend,config in configs.items():
 flags=shlex.split(subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',config],cwd=ROOT,text=True))
 for depth in (8,16,32,64,128,256):
  macro='DMA_NODE_RD_OUTSTANDING_SLOT' if backend=='naive' else 'TMEM_DMA_RD_OUTSTANDING_SLOT'
  for nd in (False,True):
   args=['verilator','-E','-DXLEN_64','-DPERF_ENABLE',*(['-DNDEBUG'] if nd else []),*flags,f'-D{macro}={depth}',*incs]
   def expand(file):
    txt=subprocess.check_output([*args,str(file)],cwd=ROOT,text=True)
    return '\n'.join(x.strip() for x in txt.splitlines() if x.strip() and not x.lstrip().startswith('`line'))
   old,new=expand(head),expand(current)
   # Naive-only change is absent from improve's LMEM declaration.
   if backend=='improve':
    assert re.search(r'localparam LMEM_TAG_WIDTH\s*=\s*(.*?);',old,re.S).group(0)==re.search(r'localparam LMEM_TAG_WIDTH\s*=\s*(.*?);',new,re.S).group(0)
   pat=r'localparam LMEM_TAG_WIDTH\s*=\s*(.*?);'
   expr=re.search(pat,new,re.S).group(1)
   # Save exact selected expression; no simulation is performed.
   records.append(dict(backend=backend,depth=depth,ndebug=nd,improve_lmem_identity=True if backend=='improve' else None,lmem_expression=expr))
(OUT/'result.json').write_text(json.dumps(records,indent=2)+'\n')
print(f'{len(records)} package preprocessing checks complete; all improve LMEM declarations match pre-sweep commit 93bf45d0')

# Static elaboration only: expose package constants as output literals in XML.
import xml.etree.ElementTree as ET
probe=OUT/'tag_probe.sv'
probe.write_text("module tag_probe(output wire [31:0] lmem, gemm, dcache, uuid);\nassign lmem=VX_gpu_pkg::LMEM_TAG_WIDTH; assign gemm=VX_gpu_pkg::GEMM_BASE_TAG_WIDTH; assign dcache=VX_gpu_pkg::DMA_DCACHE_TAG_WIDTH; assign uuid=VX_gpu_pkg::UUID_WIDTH; endmodule\n")
widths=[]
for backend,config in configs.items():
 flags=shlex.split(subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',config],cwd=ROOT,text=True))
 for depth in (8,16,32,64,128,256):
  macro='DMA_NODE_RD_OUTSTANDING_SLOT' if backend=='naive' else 'TMEM_DMA_RD_OUTSTANDING_SLOT'
  xml=OUT/f'{backend}-{depth}.xml'
  cmd=['verilator','--xml-only','--xml-output',str(xml),'--Mdir',str(OUT/'obj'),'-Wno-fatal','--top-module','tag_probe','-DXLEN_64','-DPERF_ENABLE','-DNDEBUG',*flags,f'-D{macro}={depth}',*incs,str(current),str(probe)]
  result=subprocess.run(cmd,cwd=ROOT,text=True,capture_output=True)
  if result.returncode: raise RuntimeError(result.stderr[-2000:])
  tree=ET.parse(xml); vals={}
  for assign in tree.findall('.//assign'):
   const=assign.find('const'); var=assign.find('varref')
   if const is not None and var is not None and var.attrib['name'] in ('lmem','gemm','dcache','uuid'): vals[var.attrib['name']]=int(const.attrib['name'].split("h")[1],16)
  assert set(vals)=={'lmem','gemm','dcache','uuid'}, vals
  bits=vals['lmem' if backend=='naive' else 'gemm']-vals['uuid']
  assert bits >= (depth-1).bit_length()
  widths.append(dict(backend=backend,depth=depth,tag_value_bits=bits,**vals))
(OUT/'widths.json').write_text(json.dumps(widths,indent=2)+'\n')
print(json.dumps(widths))
