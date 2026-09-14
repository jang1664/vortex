"""Cache selected full-run scalar/vector FSDB signals for causal diagnosis."""
from pathlib import Path
import concurrent.futures as cf
import argparse,json,re,sys
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
ap=argparse.ArgumentParser();ap.add_argument('group',choices=['core','acc','bank','port']);args=ap.parse_args()
OUT=TASK/'captures';OUT.mkdir(exist_ok=True)
RUN=ROOT/'agent-tasks/naive-input-single-cycle-issue/runs/v1/m256'
CORE='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
N=CORE+'/gemm_node_naive';C=N+'/u_VX_gemm_compute_core';A=N+'/u_VX_gemm_acc_lmem';J=N+'/psum_rd_lane_split';L=CORE+'/mem_unit/local_mem'
groups={}
groups['core']={k:C+'/'+k for k in ['int2fp_launch_ready','merged_fifo_pop','int2fp_result_pop','post_txn_space','rd_hold_valid','post_head_d3_raw_stall','qcol_scale_ready','out_scaler_input_ready','post_txn_launch','acc_result_commit']}
groups['acc']={k:A+'/'+k for k in ['prefetch_alloc','rd_lmem_fire','rsp_lmem_fire','rd_core_fire','rsp_core_fire','rd_issue_candidate_raw_block','rd_issue_candidate_valid','read_slot_valid','read_slot_issued','read_slot_completed','rd_issue_slot','rsp_slot']}
groups['acc'].update({k:N+'/'+k for k in ['psum_rd_order_block','psum_write_table_full','psum_write_waw_block','psum_write_war_block']})
groups['acc'].update({'join_'+k:J+'/'+k for k in ['wide_req_fire','free_slot_valid','issue_slot_valid','issue_slot','issue_all_done','lane_req_valid_mon','lane_req_ready_mon','lane_req_fire','lane_rsp_valid_mon','lane_rsp_ready_int','slot_valid','slot_complete']})
groups['acc'].update({prefix+'_'+k:N+'/'+bus+'/'+k for prefix,bus in [('wr','psum_wr_raw_bus_if'),('rd','psum_rd_raw_bus_if')] for k in ['req_valid','req_ready']})
groups['bank']={f'bank{b}_{k}':L+f'/g_naive_psum_priority/req_xbar/g_bank[{b}]/'+k for b in [0,8] for k in ['root_valid','root_read','root_write','selected_root','selected','grant_fire','buffer_ready','read_streak','locked']}
groups['bank'].update({k:L+'/'+k for k in ['per_bank_req_valid','per_bank_req_ready','per_bank_req_rw']})
groups['port']={f'port{p}_{typ}{i}_{k}':CORE+f'/mem_unit/g_lmem_priority_order[{p}]/priority_arb_{typ}_if[{i}]/'+k for p in [0,8] for typ,i in [('in',0),('in',1),('out',0)] for k in ['req_valid','req_ready']}
groups['port'].update({'prefetch_free_slot':A+'/prefetch_free_slot'})
def extract(item):
    key,path=item;cache=OUT/(key+'.npz')
    if not cache.exists():
        r=fsdb_cli.report(str(RUN/'wave.fsdb'),[path]);assert r.time_unit=='1ps' and r.data_rows,path
        t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
        v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
        if key in ['per_bank_req_ready','per_bank_req_rw']:
            v=np.array([int(re.sub('[xXzZ]','0',x[1]),2) for x in r.data_rows],dtype=np.int64)
            known=np.array([int(''.join('1' if b in '01' else '0' for b in x[1]),2) for x in r.data_rows],dtype=np.int64)
            np.savez_compressed(cache,t=t,v=v,known=known)
        else:np.savez_compressed(cache,t=t,v=v)
    print(key,'cached',flush=True)
with cf.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(extract,groups[args.group].items()))
(TASK/(args.group+'-paths.json')).write_text(json.dumps(groups[args.group],indent=2)+'\n')
