"""Capture a bounded, tag-correlated PSUM stall window for manual review."""
from pathlib import Path
import csv,json,re,sys
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
sys.path.insert(0,str(ROOT/'tools'));import fsdb_cli
CORE='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
N=CORE+'/gemm_node_naive';C=N+'/u_VX_gemm_compute_core';A=N+'/u_VX_gemm_acc_lmem';J=N+'/psum_rd_lane_split';L=CORE+'/mem_unit/local_mem'
p={k:C+'/'+v for k,v in {'head_tag':'post_head_ctrl.acc_txn_tag','head_addr':'post_head_ctrl.acc_rd_addr','head_psum_ready':'post_head_psum_ready','post_count':'post_txn_count','post_launch':'post_txn_launch','tree_credit':'tree_credit_q','input_valid':'input_bus_if/req_valid','input_ready':'input_bus_if/req_ready'}.items()}
p.update({k:A+'/'+v for k,v in {'rd_fire':'rd_lmem_fire','logical_slot':'rd_issue_slot','logical_rsp_slot':'rsp_slot','rsp_fire':'rsp_lmem_fire','core_rsp_tag':'acc_if/rd_rsp_tag','core_rsp_fire':'rsp_core_fire'}.items()})
p['request_txn']=N+'/psum_rd_transaction'
p.update({k:J+'/'+v for k,v in {'join_free':'free_slot','join_alloc':'wide_req_fire','join_issue':'issue_slot','join_issue_done':'issue_all_done','lane_req_valid':'lane_req_valid_mon','lane_req_fire':'lane_req_fire','lane_rsp_valid':'lane_rsp_valid_mon','lane_rsp_ready':'lane_rsp_ready_int','lane_rsp_tags':'lane_rsp_tag_mon','join_rsp_tag':'wide_bus_if/rsp_data.tag','join_rsp_valid':'wide_bus_if/rsp_valid','join_rsp_ready':'wide_bus_if/rsp_ready','lane_addr':'lane_req_addr_mon'}.items()})
for b in [0,4,8,12]:
    for k in ['root_valid','root_read','root_write','selected_root','selected','grant_fire']:
        p[f'b{b}_{k}']=L+f'/g_naive_psum_priority/req_xbar/g_bank[{b}]/'+k
r=fsdb_cli.report(str(ROOT/'agent-tasks/naive-input-single-cycle-issue/runs/v1/m256/wave.fsdb'),list(p.values()),bt='963500ns',et='966500ns')
assert r.time_unit=='1ps' and len(r.signal_names)==len(p)
ev=r.events();t=np.array([x.time for x in ev]);rows=[]
for cycle in range(96351,96650):
    e=ev[np.searchsorted(t,cycle*10000+5000,side='left')-1]
    row={'cycle':cycle}
    for key,name in zip(p,r.signal_names):
        value=e.values[name];row[key]=int(value,2) if re.fullmatch('[01]+',value) else value
    rows.append(row)
with (TASK/'stall-window.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
(TASK/'window-paths.json').write_text(json.dumps(p,indent=2)+'\n')
for row in rows:
    if 96575<=row['cycle']<=96585:print({k:row[k] for k in ['cycle','head_tag','head_addr','head_psum_ready','post_count','rd_fire','request_txn','logical_slot','rsp_fire','logical_rsp_slot','core_rsp_fire','core_rsp_tag']})
