#!/usr/bin/env python3
"""Check consumed lane tags against the active aggregate response context."""
import json,re,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'));import fsdb_cli
run=Path(sys.argv[1]);wave=str(run/'wave.fsdb')
meta=re.search(r'^GEMM_LATENCY_DONE .*', (run/'simv.log').read_text(),re.M)[0]
end=int(re.search(r'e_hs=(\d+)',meta)[1])+100
cycles=np.arange(1,end);times=cycles*10000+5000
C='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
results=[]
for prefix,lanes in [(C+'/mem_unit/g_split_dma_dcache_ports/dma_dcache_split',4),(C+'/u_VX_dma_node/g_split_lmem_lanes/lmem_lane_split',32)]:
 def sample(s):
  r=fsdb_cli.report(wave,[prefix+'/'+s]);assert r.data_rows,s
  t=np.array([int(x[0]) for x in r.data_rows]);v=[x[1] for x in r.data_rows]
  idx=np.searchsorted(t,times,side='left')-1
  return [v[i] for i in idx]
 pop=sample('rsp_ctx_pop');mask=sample('g_masked_response/rsp_ctx_mask');tag=sample('g_masked_response/rsp_ctx_tag');skid=sample('skid_tag')
 bad=[];total=0
 for i,x in enumerate(pop):
  if x!='1':continue
  total+=1;w=len(skid[i])//lanes;m=int(mask[i],2)
  for l in range(lanes):
   if not (m>>l&1):continue
   got=skid[i][len(skid[i])-(l+1)*w:len(skid[i])-l*w]
   if got!=tag[i]:bad.append(dict(cycle=int(cycles[i]),lane=l,expected=tag[i],actual=got))
 result=dict(splitter=prefix,responses=total,mismatched_lane_tags=len(bad),examples=bad[:12]);results.append(result)
 print(json.dumps(result),flush=True)
(run/'response_order.json').write_text(json.dumps(results,indent=2)+'\n')
