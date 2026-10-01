#!/usr/bin/env python3
"""Capture explicitly selected alias/config provenance from installed FPGA binaries."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

TASK=Path(__file__).resolve().parent
ROOT=TASK.parents[1]
ALIASES=['tcu_th16_c1_v2',
 'naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr',
 'naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr',
 'improve_th16_tcol16_m16_t8_bigmem_all_bram_spread']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def normalize(s):
 return dict(x[2:].split('=',1) if '=' in x else [x[2:],'1']
             for x in s.split() if x.startswith('-D'))
def main():
 text=(ROOT/'ci/fpga_bin_alias_map.yaml').read_text();rows={}
 for i,alias in enumerate(ALIASES,1):
  m=re.search(r'^  '+re.escape(alias)+r':\n    path: (\S+)\n    configs: (\S+)',text,re.M)
  assert m,alias
  binary=Path(m[1]).parent;cfg=ROOT/m[2]
  manifest=json.loads((binary/'manifest.json').read_text())
  config=subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',str(cfg)],text=True)
  selected=normalize(config);archived=normalize(manifest['params']['CONFIGS'])
  delta={k:[v,archived.get(k)] for k,v in selected.items() if archived.get(k)!=v}
  assert not delta,(alias,delta)
  rows['C'+str(i)]=dict(alias=alias,bin_path=m[1],config=m[2],config_sha256=sha(cfg),
   config_defines=config.strip(),binary_manifest_sha256=sha(binary/'manifest.json'),
   binary_id=manifest['id'],binary_build_defines=manifest['params']['CONFIGS'],
   binary_added_defines={k:v for k,v in archived.items() if k not in selected},
   note='Selected config matches archived build explicit defines; current branch RTL is used for new OOC experiment, not a reroute of this binary.')
 result=dict(rtl_commit=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
  branch='fpint-fpga-v2',alias_map_sha256=sha(ROOT/'ci/fpga_bin_alias_map.yaml'),candidates=rows,
  memory_profile='User explicitly retained prior controlled LMEM8/32 + cache/AXI1/4 sweep; distinct from actual candidate memory system.')
 (TASK/'candidate_provenance.json').write_text(json.dumps(result,indent=2)+'\n')
 print('PASS: all four explicit candidate configs match installed binary manifest defines')
if __name__=='__main__':main()
