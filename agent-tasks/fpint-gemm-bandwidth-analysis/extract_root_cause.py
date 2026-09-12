import csv,json,sys,re
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli as f
out=ROOT/'docs/hw_analysis/improve_vs_naive/fsdb_m4/naive'; dest=out/'root_cause';dest.mkdir(exist_ok=True)
base='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node_naive'
dma=base+'/u_input_lmem_dma';impl=dma+'/dma_core/g_misaligned/u_impl';sync=base+'/u_VX_gemm_ctrl_naive/u_VX_gemm_sync_naive'
signals={}
def add(prefix,names,label=''):
 for name in names.split():signals[label+name.replace('/','_')]=prefix+'/'+name
add(dma,'cfg_fire perf_src_rd_req_fire perf_src_rd_data_fire perf_dst_wr_fire perf_src_rd_req_stall perf_src_rd_data_stall perf_dst_wr_stall','dma_')
add(impl,'state rd_state wr_state cmd_start precalc_issue precalc_done src_req_issue_fire src_req_fire src_rsp_fire gen_slot_valid gen_slot_ready gen_dst_valid gen_dst_ready dst_req_issue_fire dst_req_fire response_payload_read wr_slot_ready','impl_')
add(base,'input_dma_ctrl_if/start input_dma_ctrl_if/idle input_dma_ctrl_if/done gemm_ctrl_if/input_read_flag.idle input_notify_req input_notify_fire input_notify_pending_r packetizer_active packetizer_ingress_complete packetizer_command_done gemm_done_pending_r gemm_write_queues_empty gemm_wr_lane_pending_r gemm_wr_lane_push gemm_wr_lane_pop gemm_unit_v2_if/tagged_writeback i_gemm_bus_if/req_valid i_gemm_bus_if/req_ready')
add(sync,'in_valid opcode is_wait wait_reg_id wait_reg_val wait_target wait_satisfied can_accept upd0_valid','sync_')
core=base.rsplit('/',1)[0]
for lane in range(4):
 for prefix,label in [(base+f'/i_lane_mem_if[{lane}]',f'lane{lane}_'),(base+f'/lmem_bus_if[{lane}]',f'node_lmem{lane}_'),(core+f'/mem_unit/lmem_membus_arb_out_if[{lane}]',f'mem_arb{lane}_'),(core+f'/mem_unit/lmem_priority_if[{lane}]',f'local_mem{lane}_')]:
  add(prefix,'req_valid req_ready rsp_valid rsp_ready',label)
add(impl+'/gen_path','aligned_fast_path','path_')
add(core+'/mem_unit/local_mem','per_bank_req_valid per_bank_req_ready per_bank_req_rw per_bank_rsp_valid per_bank_rsp_ready','bank_')
add(core+'/mem_unit/lmem_priority_if[0]','req_data.addr','local0_')
add(base+'/u_input_packetizer','context_count','packet_')
start=83325000;lo=1480;hi=1680

def read(item):
 label,path=item;cache=dest/(label+'.csv')
 r=f.load_csv(str(cache)) if cache.exists() else f.report(str(out/'m4.fsdb'),[path],bt=str(start+lo*10000)+'ps',et=str(start+hi*10000)+'ps')
 if not r.data_rows:raise RuntimeError(path)
 with cache.open('w') as h:
  w=csv.writer(h);w.writerow(['Time('+r.time_unit+')',path]);w.writerows(r.data_rows)
 return label,[[ (int(t)-start)//10000,int(v,2) if re.fullmatch('[01]+',v) else v] for t,v in r.data_rows]
with ThreadPoolExecutor(max_workers=6) as pool:values=dict(pool.map(read,signals.items()))
(dest/'transitions.json').write_text(json.dumps({'signals':signals,'transitions':values},indent=2)+'\n')
for k,v in values.items():print(k,v[:30])
