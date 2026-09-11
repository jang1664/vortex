#!/usr/bin/env python3
"""Strict-preedge actual M4 metadata-node service/overlap acceptance check."""
import argparse, importlib.util, json, re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE=Path(__file__).resolve().parent

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,HERE/file)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
base=module('install_base','p0-install-check.py')
contract=module('contract','p0-contract.py')

def main():
    parser=argparse.ArgumentParser(__doc__);parser.add_argument('--run',type=Path,required=True)
    args=parser.parse_args();out=args.run/'service';out.mkdir(exist_ok=False)
    manifest=json.loads((args.run/'manifest.json').read_text())
    assert manifest['passed'] and not manifest['source_changes_during_run']
    assert [manifest[k] for k in ('m','k','n','qdir','wtrans')]==[4,512,512,0,0]
    wave=args.run/'wave.fsdb'
    paths={'clk':'clk','reset':'reset','cfg':'cfg_start_fire',
        'valid':'i_gemm_bus_if/req_valid','ready':'i_gemm_bus_if/req_ready',
        'seq':'gemm_unit_v2_if/packet_ctrl.work_seq',
        'rd_addr':'gemm_unit_v2_if/packet_ctrl.acc_rd_addr','wr_addr':'gemm_unit_v2_if/packet_ctrl.acc_wr_addr',
        'cmd_valid':'input_executor/cmd_valid','cmd_ready':'input_executor/cmd_ready',
        'done_valid':'input_executor/done_valid','done_ready':'input_executor/done_ready','done_seq':'input_executor/done_work_seq',
        'wb':'u_VX_gemm_compute_core/acc_write_fire','wb_seq':'u_VX_gemm_compute_core/acc_result_data_out.ctrl.work_seq',
        'wb_addr':'u_VX_gemm_compute_core/acc_result_data_out.ctrl.acc_wr_addr',
        'tagged':'gemm_unit_v2_if/tagged_writeback','tagged_seq':'gemm_unit_v2_if/tagged_writeback_work_seq',
        'pending':'gemm_wr_lane_pending_r','pop':'gemm_wr_lane_pop','store':'output_store_done'}
    for n in (11,12,29,30,31,32,38,39):paths['cfg'+str(n)]='issue_if/regs['+str(n)+']'
    for f in ('work_seq','flags','rs1_data','rs2_data','stride','eff_mt','naive_final_base','naive_final_stride','naive_source_buffer','naive_source_generation','naive_terminal'):
        paths['cmd_'+f]='input_executor/cmd.'+f
    def read(item):
        key,path=item;r=base.fsdb_cli.report(str(wave),[base.NODE+'/'+path]);assert r.data_rows,path
        return key,dict(path=path,unit=r.time_unit,values=[[int(t),int(v,2) if re.fullmatch('[01]+',v) else None] for t,v in r.data_rows])
    with ThreadPoolExecutor(max_workers=4) as pool:signals=dict(pool.map(read,paths.items()))
    assert len({v['unit'] for v in signals.values()})==1
    (out/'signals.json').write_text(json.dumps(signals))
    expected=contract.stream(4,512,512,16,0,0)
    commands=[];samples=[];origin=None;stores=[]
    for edge,time,v in base.rising_samples(signals):
        if v['reset']!=0:continue
        if v['cfg']:
            assert origin is None
            assert [v['cfg'+str(i)] for i in (29,30,31,32,38,39)]==[4,512,512,5,0,0]
            origin=v['cfg11']+(v['cfg12']<<32)
        if origin is None:continue
        samples.append((edge,v['valid'],v['ready'],v['pop']))
        if v['cmd_valid'] and v['cmd_ready']:
            index=len(commands);e=expected[index];assert v['cmd_work_seq']==e['work_seq']==index+1
            checks={'rs1_data':origin+e['psum_base'],'rs2_data':origin+e['input_base'],
                'stride':64,'eff_mt':4,'naive_final_base':origin+e['final_base'],'naive_final_stride':256,
                'naive_source_buffer':e['source_bank'],'naive_source_generation':e['source_generation'],
                'naive_terminal':int(e['terminal'])}
            for key,val in checks.items():assert v['cmd_'+key]==val,(index,key,v['cmd_'+key],val)
            assert bool(v['cmd_flags']&16)==e['accumulate'] and bool(v['cmd_flags']&8)==e['last_k']
            commands.append(dict(descriptor=e,accept_edge=edge,input_edges=[],writeback_edges=[]))
        if v['valid'] and v['ready']:
            c=commands[v['seq']-1];e=c['descriptor'];row=len(c['input_edges']);assert row<4
            assert v['rd_addr']==origin+e['psum_base']+row*64
            assert v['wr_addr']==origin+(e['final_base']+row*256 if e['last_k'] else e['psum_base']+row*64)
            c['input_edges'].append(edge)
        if v['wb']:
            c=commands[v['wb_seq']-1];e=c['descriptor'];row=len(c['writeback_edges']);assert row<4
            assert v['wb_addr']==origin+(e['final_base']+row*256 if e['last_k'] else e['psum_base']+row*64)
            c['writeback_edges'].append(edge)
        if v['tagged']:
            c=commands[v['tagged_seq']-1];assert len(c['writeback_edges'])==4 and c['writeback_edges'][-1]==edge
            assert 'final_writeback_edge' not in c;c['final_writeback_edge']=edge
        if v['done_valid'] and v['done_ready']:
            c=commands[v['done_seq']-1];assert 'done_edge' not in c and len(c['input_edges'])==4
            assert edge>c['input_edges'][-1];c['done_edge']=edge
            if c['descriptor']['terminal']:assert c['final_writeback_edge']<edge and v['pending']==0
        if v['store']:stores.append(edge)
    assert len(commands)==1024 and len(stores)==4
    assert all(len(c['input_edges'])==len(c['writeback_edges'])==4 and 'done_edge' in c for c in commands)
    chosen=commands[256:768];first=chosen[0]['input_edges'][0];last=chosen[-1]['input_edges'][-1]
    pairs=[];excluded=[]
    for a,b in zip(chosen,chosen[1:]):
        da,db=a['descriptor'],b['descriptor']
        if da['owner']==db['owner'] and da['nb']!=db['nb']:
            pairs.append(dict(a=da['ordinal'],b=db['ordinal'],overlap=b['input_edges'][0]<a['final_writeback_edge'],
                input_b=b['input_edges'][0],writeback_a=a['final_writeback_edge']))
        else:excluded.append([da['ordinal'],db['ordinal']])
    assert len(pairs)==510 and excluded==[[511,512]]
    observed=[s for s in samples if first<=s[0]<=last];duration=last-first+1;assert len(observed)==duration
    overlap=sum(p['overlap'] for p in pairs)
    result=dict(commands=1024,input_rows=4096,stores=4,first_ordinal=256,last_ordinal=767,
        selected_rows=2048,first_edge=first,last_edge=last,interval_cycles=duration,density=2048/duration,
        eligible_pairs=510,excluded_pairs=excluded,overlapping_pairs=overlap,overlap_fraction=overlap/510,
        source_absent_ready_cycles=sum(v==0 and r==1 for _,v,r,_ in observed),
        input_backpressure_cycles=sum(v==1 and r==0 for _,v,r,_ in observed),
        required_max_interval=24186,required_min_overlap=255,
        service_pass=duration<=24186,overlap_pass=overlap>=255,
        sampling='strictly before rising edge, first edge index 0',wave_sha256=base.sha(wave))
    (out/'commands.json').write_text(json.dumps(commands,indent=2));(out/'pairs.json').write_text(json.dumps(pairs,indent=2))
    (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
    assert result['service_pass'] and result['overlap_pass']
if __name__=='__main__':main()
