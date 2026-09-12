import json,sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli as f
name=sys.argv[1];out=ROOT/'docs/hw_analysis/improve_vs_naive/fsdb_m4'/name
wave=str(out/'m4.fsdb'); base='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
node=base+('/gemm_node' if name=='improve' else '/gemm_node_naive')
ctrl=node+('/u_VX_gemm_ctrl/invocation_active_q' if name=='improve' else '/u_VX_gemm_ctrl_naive/job_active_q')
r=f.report(wave,[ctrl]); rows=r.data_rows
start=next(int(t) for t,v in rows if v=='1');end=next(int(t) for t,v in rows if int(t)>start and v=='0')
(out/'active_window.json').write_text(json.dumps({'signal':ctrl,'unit':r.time_unit,'start':start,'end':end,'cycles':(end-start)//10000,'rows':rows},indent=2)+'\n')
fields=['rd_bytes','wr_bytes','xfer_count','active_cycles','src_rd_req_fire','src_rd_req_stall','src_rd_data_fire','src_rd_data_stall','dst_wr_fire','dst_wr_stall','wait_dcache','wait_lmem']
signals=[base+'/accel_perf.'+dma+'.'+field for dma in ['cpu_dma','hbm_dma.aggregate','lmem_dma_input','lmem_dma_weight','lmem_dma_sz','lmem_dma_output'] for field in fields]
signals += [base+'/accel_perf.'+x for x in ['gemm_node.total_cycles','gemm_node.lmem_rd_bytes','gemm_node.lmem_wr_bytes','dma_union_active_cycles','overlap_dma_mxu','hbm_dma.active_cycles_max','hbm_dma.active_cycles_min']]
def read(s):
 r=f.report(wave,[s],bt=str(end+10000)+'ps',et=str(end+20000)+'ps')
 if not r.data_rows:raise RuntimeError(s)
 v=r.data_rows[0][1];return s.split('/accel_perf.')[1],int(v,2)
with ThreadPoolExecutor(max_workers=6) as pool:res=dict(pool.map(read,signals))
(out/'counters.json').write_text(json.dumps(res,indent=2)+'\n')
print(name,'window',start,end,(end-start)//10000)
print(json.dumps(res,indent=2))
