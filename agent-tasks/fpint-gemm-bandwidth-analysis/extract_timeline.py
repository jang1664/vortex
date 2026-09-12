import json,sys,csv,re
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli as f
name=sys.argv[1];out=ROOT/'docs/hw_analysis/improve_vs_naive/fsdb_m4'/name
wave=str(out/'m4.fsdb'); window=json.loads((out/'active_window.json').read_text());start,end=window['start'],window['end'];count=(end-start)//10000
base='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
node=base+('/gemm_node' if name=='improve' else '/gemm_node_naive')
compute=node+('/u_VX_gemm_unit_v2/u_compute_core' if name=='improve' else '/u_VX_gemm_compute_core')
signals={'input_fire':compute+'/input_fire','input_valid':node+'/i_gemm_bus_if/req_valid','input_ready':node+'/i_gemm_bus_if/req_ready','pipeline_busy':compute+'/pipeline_busy','consumer_block':compute+'/consumer_block_raw_valid','input_dma_start':node+'/input_dma_ctrl_if/start','input_dma_idle':node+'/input_dma_ctrl_if/idle','input_dma_done':node+'/input_dma_ctrl_if/done','weight_dma_start':node+'/weight_dma_ctrl_if/start','weight_dma_idle':node+'/weight_dma_ctrl_if/idle','weight_dma_done':node+'/weight_dma_ctrl_if/done','tagged_writeback':node+'/gemm_unit_v2_if/tagged_writeback','external_dma_busy':base+'/accel_perf.'+('hbm_dma.aggregate.busy' if name=='improve' else 'cpu_dma.busy')}
if name=='naive':
 signals.update({s:node+'/'+s for s in ['packetizer_cmd_valid','packetizer_cmd_ready','packetizer_active','packetizer_ingress_complete','packetizer_command_done','common_writeback_drained','psum_rd_order_block']})
 signals['fsm_state']=node+'/u_VX_gemm_ctrl_naive/u_VX_gemm_fsm_naive/state_q'
 signals['parent_full']=node+'/u_VX_gemm_ctrl_naive/parent_q_full'
 signals['parent_out_fire']=node+'/u_VX_gemm_ctrl_naive/parent_out_fire'
else:
 signals['input_context_count']=node+'/input_context_count_r'
 signals['input_context_full']=node+'/input_context_full'
(out/'csv').mkdir(exist_ok=True)
enum_text=(ROOT/'hw/rtl/core/gemm/VX_gemm_fsm_naive.sv').read_text().split('typedef enum logic [7:0] {',1)[1].split('} state_t;',1)[0]
enum_names=re.findall(r'\bS_[A-Z0-9_]+\b',re.sub(r'//[^\n]*','',enum_text))
enum_values={s:i for i,s in enumerate(enum_names)}
def read(item):
 label,s=item;cache=out/'csv'/f'{label}.csv'
 r=f.load_csv(str(cache)) if cache.exists() else f.report(wave,[s],bt=str(start)+'ps',et=str(end)+'ps')
 if not r.data_rows:raise RuntimeError(s)
 with (out/'csv'/f'{label}.csv').open('w') as h:
  wr=csv.writer(h);wr.writerow(['Time('+r.time_unit+')',s]);wr.writerows(r.data_rows)
 arr=np.zeros(count,dtype=np.int64)
 for j,row in enumerate(r.data_rows[:-1]):
  t,v=int(row[0]),row[1]; tnext=int(r.data_rows[j+1][0]);
  value=int(v,2) if re.fullmatch('[01]+',v) else enum_values.get(v,-1)
  lo=max(0,(t-start+9999)//10000);hi=min(count,(tnext-start+9999)//10000)
  arr[lo:hi]=value
 return label,arr
with ThreadPoolExecutor(max_workers=6) as pool:arrays=dict(pool.map(read,signals.items()))
np.savez_compressed(out/'timeline.npz',**arrays)
summary={'cycles':count,'signal_paths':signals,'unknown_cycles':{k:int(sum(a<0)) for k,a in arrays.items()},'high_cycles':{k:int(np.count_nonzero(a>0)) for k,a in arrays.items()}}
fires=arrays['input_fire']==1;valid=arrays['input_valid']==1;ready=arrays['input_ready']==1;ext=arrays['external_dma_busy']==1
summary['input_partition']={'fire':int(sum(fires)),'valid_not_ready':int(sum(valid & ~ready)),'no_valid_ready':int(sum(~valid & ready)),'no_valid_not_ready':int(sum(~valid & ~ready))}
summary['external_intersection']={'dma_and_input':int(sum(ext & fires)),'dma_no_input':int(sum(ext & ~fires)),'no_dma_input':int(sum(~ext & fires)),'no_dma_no_input':int(sum(~ext & ~fires))}
def runs(mask):
 d=np.diff(np.r_[False,mask,False].astype(int));return list(zip(np.where(d==1)[0].tolist(),np.where(d==-1)[0].tolist()))
bursts=runs(fires);lens=[b-a for a,b in bursts];gaps=[bursts[i+1][0]-bursts[i][1] for i in range(len(bursts)-1)]
summary['bursts']={'count':len(bursts),'length_hist':{str(x):lens.count(x) for x in sorted(set(lens))},'gap_min':min(gaps),'gap_median':float(np.median(gaps)),'gap_max':max(gaps),'first':bursts[:12],'last':bursts[-3:]}
summary['burst_gap_hist']={str(x):gaps.count(x) for x in sorted(set(gaps))}
if name=='naive':summary['fsm_residency']={enum_names[x] if x>=0 else 'unknown':int(sum(arrays['fsm_state']==x)) for x in np.unique(arrays['fsm_state'])}
(out/'timeline_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(name,json.dumps({k:v for k,v in summary.items() if k!='signal_paths'},indent=2))
