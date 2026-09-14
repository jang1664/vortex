#!/usr/bin/env python3
"""Sample immutable FSDB evidence at pre-edge values; separate valid performance from failures."""
import json,re,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'));import fsdb_cli
TASK=Path(__file__).resolve().parent
run=Path(sys.argv[1]);wave=str(run/'wave.fsdb');result=json.loads((run/'result.json').read_text())
line=re.search(r'^GEMM_LATENCY_DONE .*',(run/'simv.log').read_text(),re.M)[0]
cfg=int(re.search(r'e_cfg=(\d+)',line)[1]);end=int(re.search(r'e_hs=(\d+)',line)[1]);cycles=np.arange(1,end);times=cycles*10000+5000;gemm=cycles>=cfg
cache=run/'samples';cache.mkdir(exist_ok=True)
C='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
DMA=C+'/u_VX_dma_node/u_dma_unit/g_misaligned/u_impl'
def sample(path,popcount=False):
 key=path.replace('/','__').replace('.','_')+('_pop' if popcount else '')
 dest=cache/(key+'.npz')
 if dest.exists():
  z=np.load(dest);t=z['t'];v=z['v']
 else:
  r=fsdb_cli.report(wave,[path]);assert r.data_rows,path
  assert r.time_unit=='1ps',r.time_unit
  t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
  v=np.array([(-1 if re.search('[xXzZ]',x[1]) else (x[1].count('1') if popcount else int(x[1],2))) for x in r.data_rows],dtype=np.int64)
  np.savez_compressed(dest,t=t,v=v)
 i=np.searchsorted(t,times,side='left')-1
 return v[np.maximum(i,0)]
def count(x):return int(np.count_nonzero(x))
busy=sample(DMA+'/perf.busy')==1
summary=dict(variant=result['variant'],case=result['case'],numerically_valid=result['passed'],window='[cycle 1, GEMM e_hs), sampled immediately before rising edges',gemm_window_cycles=int(gemm.sum()),dma_active_cycles=count(busy),gemm_cycles=result['gemm_cycles'],core_cycles=result['core_cycles'])
summary['dma_counters_at_gemm_end']={}
for name in ['rd_bytes','wr_bytes','active_cycles','src_rd_req_fire','src_rd_req_stall','src_rd_data_fire','src_rd_data_stall','dst_wr_fire','dst_wr_stall','wait_dcache','wait_lmem']:
 v=sample(DMA+'/perf.'+name);summary['dma_counters_at_gemm_end'][name]=int(v[-1])
slots=sample(DMA+'/slot_occupancy_r');rslots=int(re.search(r'-DDMA_NODE_RD_OUTSTANDING_SLOT=(\d+)',result['configs'])[1])
summary['dma_slots']=dict(limit=rslots,max=int(slots.max()),full_cycles=count(busy&(slots==rslots)),mean_when_busy=float(slots[busy].mean()))
Dmatch=re.search(r'-DDMA_SPLIT_RSP_DEPTH=(\d+)',result['configs']);depth=int(Dmatch[1]) if Dmatch else 8
ports=16 if result['variant']=='l16' else 32
splits=[('lmem',C+'/u_VX_dma_node/g_split_lmem_lanes/lmem_lane_split',ports)]
if result['variant'].startswith('d'):splits.append(('dcache',C+'/mem_unit/g_split_dma_dcache_ports/dma_dcache_split',4))
summary['splitters']={}
for name,path,lanes in splits:
 ordered='-DDMA_SPLIT_RSP_REORDER=1' in result['configs']
 rp=path+'/g_reorder_response/response_store'
 context_path=(rp+'/contexts/size') if ordered else (path+'/g_masked_response/rsp_context_queue/size')
 occ=sample(context_path);full=sample(path+'/rsp_ctx_full')==1
 lane=[]
 for i in range(lanes):
  if ordered:
   v=sample(rp+f'/g_lane[{i}]/received_r',True)
  else:
   # Pre-reorder evidence has no g_fifo generate scope.
   extra='g_fifo/' if result['variant']=='l32' else ''
   v=sample(path+f'/g_lane_rsp[{i}]/'+extra+'rsp_skid/g_ebN/fifo_queue/size')
  lane.append(dict(lane=i,max_buffered_responses=int(v.max()),at_requested_depth_cycles=count(v==depth)))
 entry=dict(requested_depth=depth,reorder=ordered,context_max=int(occ.max()),context_full_cycles=count(full),context_full_dma_active_cycles=count(full&busy),lanes=lane)
 if ordered:
  entry['assembly_wait_cycles']=count((sample(rp+'/context_empty')==0)&(sample(rp+'/all_complete')==0))
  entry['output_stall_cycles']=count((sample(rp+'/output_valid_r')==1)&(sample(rp+'/response_ready')==0))
 summary['splitters'][name]=entry
summary['buses']={}
def bus(name,path,bytes_):
 qv=sample(path+'/req_valid')==1;qr=sample(path+'/req_ready')==1;rw=sample(path+'/req_data.rw');rv=sample(path+'/rsp_valid')==1;rr=sample(path+'/rsp_ready')==1
 q=qv&qr;p=rv&rr;mask=sample(path+'/req_data.byteen',True)
 assert (mask[q]>=0).all(), 'unknown consumed byte mask '+name
 entry=dict(requests=count(q),read_requests=count(q&(rw==0)),write_requests=count(q&(rw==1)),responses=count(p),request_stall=count(qv&~qr),response_stall=count(rv&~rr),read_mask_bytes=int(mask[q&(rw==0)].sum()),write_mask_bytes=int(mask[q&(rw==1)].sum()),response_bus_bytes=count(p)*bytes_,responses_during_dma_active=count(p&busy),peak_response_bytes_per_cycle=bytes_ if count(p) else 0)
 summary['buses'][name]=entry
 return np.where(q&(rw==0),mask,0),np.where(q&(rw==1),mask,0),p.astype(np.int64)*bytes_
bus('dma_global',C+'/dma_global_data_if',256 if result['variant'].startswith('d') else 64)
summary['aggregate_bus_rates']={}
def rates(rd,wr,rsp):
 return dict(read_mask_bytes=int(rd.sum()),write_mask_bytes=int(wr.sum()),response_bus_bytes=int(rsp.sum()),peak_read_mask_bytes_per_cycle=int(rd.max()),peak_write_mask_bytes_per_cycle=int(wr.max()),peak_response_bus_bytes_per_cycle=int(rsp.max()),read_mask_bytes_per_dma_active_cycle=float(rd[busy].sum()/max(1,busy.sum())),write_mask_bytes_per_dma_active_cycle=float(wr[busy].sum()/max(1,busy.sum())),response_bus_bytes_per_dma_active_cycle=float(rsp[busy].sum()/max(1,busy.sum())),response_bus_bytes_per_gemm_cycle=float(rsp[gemm].sum()/max(1,gemm.sum())))
for group,lanes,bytes_,base in [('lmem',ports,8,C+'/dma_local_data_if'),('dcache',4,64,C+'/mem_unit/dcache_dma_lane_if')]:
 if group=='dcache' and not result['variant'].startswith('d'):continue
 total=[np.zeros(len(cycles),dtype=np.int64) for _ in range(3)]
 for i in range(lanes):
  values=bus(f'{group}_lane{i}',base+f'[{i}]',bytes_)
  for j in range(3):total[j]+=values[j]
 summary['aggregate_bus_rates'][group]=rates(*total)
AXI='/tb_vcs_xrtsim/dut/vortex_axi'
rtotal=np.zeros(len(cycles),dtype=np.int64);wtotal=rtotal.copy();artotal=rtotal.copy()
summary['hbm_ports']=[]
for i in range(8):
 def ax(s):return sample(AXI+f'/m_axi_{s}[{i}]')
 rf=(ax('rvalid')==1)&(ax('rready')==1);wf=(ax('wvalid')==1)&(ax('wready')==1);af=(ax('arvalid')==1)&(ax('arready')==1)
 wb=sample(AXI+f'/m_axi_wstrb[{i}]',True);assert (wb[wf]>=0).all()
 rtotal+=rf.astype(np.int64)*64;wtotal+=np.where(wf,wb,0);artotal+=af.astype(np.int64)*64
 summary['hbm_ports'].append(dict(port=i,read_beats=count(rf),read_beats_during_dma=count(rf&busy),write_bytes=int(wb[wf].sum())))
summary['aggregate_bus_rates']['hbm_all_clients']=rates(artotal,wtotal,rtotal)
summary['dcache_counters_at_gemm_end']={n:int(sample(C.rsplit('/g_cores',1)[0]+'/dcache_perf.'+n)[-1]) for n in ['reads','writes','read_misses','write_misses','mshr_stalls','crsp_stalls']}
summary['physical_note']='Bus widths, mask bytes, and DMA aggregate counters are reported separately; failed numerical runs are not performance candidates.'
(run/'analysis.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:v for k,v in summary.items() if k not in ['buses','splitters']}),flush=True)
