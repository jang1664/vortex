#!/usr/bin/env python3
"""Check actual GEMM/DMA retirement quiescence in completed naive VCS waves."""
import json, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
base='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/'
for arg in sys.argv[1:]:
 out=Path(arg).resolve(); manifest=json.loads((out/'manifest.json').read_text())
 assert manifest['state']=='finished' and manifest['returncode']==0 and manifest['backend']=='naive'
 slr='-DGEMM_SLR_PIPELINE' in manifest['configs']
 names=['gemm_node_naive/done_if/valid','gemm_node_naive/done_if/ready','gemm_node_naive/executor_idle','gemm_node_naive/gemm_wr_lane_pending_r','gemm_node_naive/gemm_unit_v2_if/pipeline_empty','u_VX_dma_node/done_if/valid','u_VX_dma_node/done_if/ready','u_VX_dma_node/dma_writes_drained']
 if slr:names+=['u_VX_dma_node/slr_requests_drained']
 report=fsdb_cli.report(str(out/'wave.fsdb'),[base+n for n in names])
 assert report.signal_names == [base+n for n in names],report.signal_names
 values=['x']*len(names); gemm=[];dma=[]; faults=[];previous_gemm=False;previous_dma=False
 for row in report.data_rows:
  for i,value in enumerate(row[1:]):
   if value: values[i]=value
  g=values[0:2]==['1','1'];d=values[5:7]==['1','1']
  if g and not previous_gemm:
   record=dict(time=row[0],executor_idle=values[2],gemm_write_pending=values[3],pipeline_empty=values[4],dma_writes_drained=values[7],slr_requests_drained=values[8] if slr else None)
   gemm.append(record)
   if values[2]!='1111' or set(values[3])!={'0'} or values[4]!='1' or values[7]!='1' or (slr and values[8]!='1'):faults.append(record)
  if d and not previous_dma:
   record=dict(time=row[0],dma_writes_drained=values[7],slr_requests_drained=values[8] if slr else None);dma.append(record)
   if values[7]!='1' or (slr and values[8]!='1'):faults.append(record)
  previous_gemm=g;previous_dma=d
 result=dict(passed=not faults and len(gemm)==manifest['repeat'] and len(dma)>0,gemm_retirements=gemm,dma_retirement_count=len(dma),faults=faults)
 (out/'drain_audit.json').write_text(json.dumps(result,indent=2)+'\n')
 print(out.name,result['passed'],len(gemm),len(dma),flush=True)
 if not result['passed']:sys.exit(1)
