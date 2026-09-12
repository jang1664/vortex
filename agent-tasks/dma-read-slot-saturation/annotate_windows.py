"""Extract review windows directly from the selected FSDBs using fsdb_cli."""
import csv, json, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
CORE='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
JOBS=[('N4_WEIGHT','naive32-m4',18740,18810),('N256_PSUM','naive32-m256',635440,635500),('N256_RECOVERY','naive32-m256',108000,108060),('I256_STREAM','improve16-m256',264495,264555)]
def extract(job):
 label,case,lo,hi=job
 d=json.loads((TASK/'captures'/case/'result.json').read_text())
 naive=case.startswith('naive');node=CORE+('/gemm_node_naive' if naive else '/gemm_node')
 compute=node+('/u_VX_gemm_compute_core' if naive else '/u_VX_gemm_unit_v2/u_compute_core')
 signals={k:compute+'/'+k for k in ['input_fire','compute_ready','weight_ready','prealigner_out_valid','pre_meta_valid_out','post_txn_count','post_head_psum_ready','post_head_scaled_ready','post_txn_launch','acc_result_credit','acc_result_commit']}
 signals.update({k:compute+'/input_bus_if/'+k for k in ['req_valid','req_ready']})
 signals['dma_busy']=CORE+('/accel_perf.cpu_dma.busy' if naive else '/accel_perf.hbm_dma.aggregate.busy')
 if naive:
  signals.update({k:node+'/'+k for k in ['psum_rd_order_block','psum_rd_pending_conflict','psum_rd_current_conflict','acc_txn_accept_ready']})
  for bus in ['psum_rd_raw_bus_if','psum_rd_wide_bus_if']:
   for k in ['req_valid','req_ready','rsp_valid','rsp_ready']:
    signals[bus+'.'+k]=node+'/'+bus+'/'+k
 else:
  for k in ['rd_req_valid','rd_req_ready','rd_rsp_valid']:
   signals['acc_if.'+k]=node+'/u_VX_gemm_unit_v2/acc_if/'+k
 report=fsdb_cli.report(str(ROOT/d['run']/'wave.fsdb'),list(signals.values()),bt=f'{lo*10}ns',et=f'{hi*10+10}ns')
 assert report.time_unit=='1ps'
 names=report.signal_names;rows=report.data_rows
 assert len(names)==len(signals),(names,signals)
 # fsdbreport preserves requested signal order; verify to avoid mislabeling.
 assert all(n==v or n.endswith(v) for n,v in zip(names,signals.values())),names
 carried=[None]*len(signals)
 dense=[]
 for row in rows:
  for k,value in enumerate(row[1:]):
   if value:
    assert set(value)<=set('01'),value
    carried[k]=int(value,2)
  dense.append(carried.copy())
 times=np.array([int(r[0]) for r in rows]);edges=np.arange(lo,hi)*10000+5000
 idx=np.searchsorted(times,edges,side='left')-1;assert np.all(idx>=0)
 samples=[]
 for c,j in zip(range(lo,hi),idx):
  vals=dense[j];assert all(v is not None for v in vals),vals
  samples.append(dict(cycle=c,relative_cycle=c-d['boundaries']['cfg'],time_ns=c*10+5,**dict(zip(signals,vals))))
 out=TASK/'annotations';out.mkdir(exist_ok=True)
 with (out/(label+'.csv')).open('w') as f:
  w=csv.DictWriter(f,fieldnames=list(samples[0]));w.writeheader();w.writerows(samples)
 (out/(label+'.json')).write_text(json.dumps(dict(case=case,fsdb=d['run']+'/wave.fsdb',start=lo,end_exclusive=hi,signals=signals),indent=2)+'\n')
 return label,len(samples)
if __name__=='__main__':
 with ThreadPoolExecutor(max_workers=4) as pool:
  for result in pool.map(extract,JOBS): print(result,flush=True)
