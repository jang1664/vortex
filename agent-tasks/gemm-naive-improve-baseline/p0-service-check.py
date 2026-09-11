#!/usr/bin/env python3
"""Actual corrected-baseline M4 Input service, identity and fixed-window metrics."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import re
import statistics
import subprocess

HERE = Path(__file__).resolve().parent

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

base = module('install_base', 'p0-install-check.py')
contract = module('planned_contract', 'p0-contract.py')


def paths():
    p = dict(clk='clk', reset='reset', cfg='u_VX_gemm_ctrl_naive/cfg_start_fire',
             cmd_valid='packetizer_cmd_valid', cmd_ready='packetizer_cmd_ready',
             in_valid='i_gemm_bus_if/req_valid', in_ready='i_gemm_bus_if/req_ready',
             in_seq='gemm_unit_v2_if/packet_ctrl.work_seq',
             in_rd_addr='gemm_unit_v2_if/packet_ctrl.acc_rd_addr',
             in_wr_addr='gemm_unit_v2_if/packet_ctrl.acc_wr_addr',
             input_fire='u_VX_gemm_compute_core/input_fire',
             ingress='packetizer_ingress_complete', command_done='packetizer_command_done',
             active_seq='packetizer_active_work_seq',
             wb='u_VX_gemm_compute_core/acc_write_fire',
             wb_seq='u_VX_gemm_compute_core/acc_result_data_out.ctrl.work_seq',
             wb_addr='u_VX_gemm_compute_core/acc_result_data_out.ctrl.acc_wr_addr',
             tagged_wb='gemm_unit_v2_if/tagged_writeback',
             tagged_seq='gemm_unit_v2_if/tagged_writeback_work_seq',
             wr_pending='gemm_wr_lane_pending_r', wr_push='gemm_wr_lane_push', wr_pop='gemm_wr_lane_pop',
             weight_start='weight_dma_ctrl_if/start', weight_idle='weight_dma_ctrl_if/idle',
             dma_start='gemm_dma_ctrl_if/start', dma_idle='gemm_dma_ctrl_if/idle', dma_done='gemm_dma_ctrl_if/done',
             store_done='output_store_done')
    for i in (1,2,5,6,11,12,29,30,31,32):
        p[f'cfg{i}'] = f'u_VX_gemm_ctrl_naive/cfg_reg_if/regs[{i}]'
    for label, prefix, fields in [
        ('cmd', 'gemm_ctrl_if/input_read_ctrl.cmd', ('instr','flags','rs1_data','rs2_data','stride','work_seq','eff_mt')),
        ('weight', 'gemm_ctrl_if/weight_read_ctrl.cmd', ('rs2_data','work_seq')),
        ('dma', 'gemm_dma_ctrl_if/cmd', ('instr','rd','rs1_data','rs2_data','flags'))]:
        for field in fields:
            p[f'{label}_{field}'] = prefix + '.' + field
    return {key: base.NODE + '/' + value for key, value in p.items()}


def capture(wave):
    def read(item):
        key, path = item
        result = base.fsdb_cli.report(str(wave), [path])
        if not result.data_rows:
            raise ValueError('Missing FSDB signal: ' + path)
        return key, dict(path=path, unit=result.time_unit,
                         values=[[int(t), int(v,2) if re.fullmatch('[01]+',v) else None]
                                 for t,v in result.data_rows])
    with ThreadPoolExecutor(max_workers=4) as pool:
        return dict(pool.map(read, paths().items()))


def distribution(values):
    ordered = sorted(values)
    return dict(count=len(values), minimum=min(values), median=statistics.median(values),
                p90=ordered[(9*(len(ordered)-1))//10], maximum=max(values), mean=statistics.mean(values))


def extract(signals, installs, lmem_log_size):
    lmem_mask = (1 << lmem_log_size) - 1
    quant = {(r['resource'], r['generation']): r for r in installs['records']}
    cfg, origin, input_base, output_base = None, None, None, None
    commands, weights, loads, stores = [], {}, {}, []
    active_dma = None
    load_count = 0
    source_generations = {}
    window_samples = []
    for edge, time, v in base.rising_samples(signals):
        if v['reset'] is None or v['reset']:
            continue
        if v['cfg']:
            if cfg is not None:
                raise ValueError('Expected one baseline invocation')
            cfg = edge
            if [v[f'cfg{x}'] for x in (29,30,31,32)] != [4,512,512,5]:
                raise ValueError('Expected M4 K512 N512 QBLK32')
            origin = v['cfg11'] + (v['cfg12'] << 32)
            input_base = v['cfg1'] + (v['cfg2'] << 32)
            output_base = v['cfg5'] + (v['cfg6'] << 32)
        if cfg is None:
            continue
        window_samples.append((edge,v['in_valid'],v['in_ready'],v['wr_pop'],v['wr_pending']))
        if v['dma_done'] and active_dma is not None:
            active_dma['complete_edge'] = edge
            loads[active_dma['lmem_base']] = active_dma
            active_dma = None
        if v['dma_start'] and v['dma_idle']:
            opcode = v['dma_instr'] & 255
            if opcode == 0x10 and v['dma_rd'] == 0:
                if active_dma is not None:
                    raise ValueError('Overlapping external input load owners')
                address = v['dma_rs1_data']
                source_generations[address] = source_generations.get(address, 0) + 1
                active_dma = dict(lmem_base=address, tensor_base=v['dma_rs2_data'],
                                  dma_tile=load_count, source_generation=source_generations[address],
                                  accept_edge=edge)
                load_count += 1
            if opcode == 0x11:
                n_byte = v['dma_rs1_data'] - output_base
                if n_byte % 256:
                    raise ValueError('Output store owner address not aligned to N tile')
                stores.append(dict(owner=n_byte//256+1, accept_edge=edge, source_lmem=v['dma_rs2_data']))
        if v['store_done']:
            waiting = [s for s in stores if 'complete_edge' not in s]
            if len(waiting) != 1:
                raise ValueError('Unowned output store completion')
            waiting[0]['complete_edge'] = edge
        if v['weight_start'] and v['weight_idle']:
            seq = v['weight_work_seq']
            if seq in weights:
                raise ValueError('Duplicate weight descriptor')
            weights[seq] = v['weight_rs2_data'] - origin
        if v['cmd_valid'] and v['cmd_ready']:
            seq = v['cmd_work_seq']
            if seq != len(commands)+1 or seq not in weights:
                raise ValueError('Input command not exactly once in fixed N-fast order')
            q = quant['s',seq]
            z = quant['z',seq]
            if q['col'] != z['col'] or q['row'] != z['row']:
                raise ValueError('S/Z command coordinates disagree')
            input_address = v['cmd_rs2_data']
            candidates = [d for address,d in loads.items() if address <= input_address < address + 32768]
            if len(candidates)!=1:
                raise ValueError('Input command lacks a unique completed source tile')
            load = candidates[0]
            micro_k_bytes = input_address - load['lmem_base']
            tensor_byte = load['tensor_base'] - input_base + micro_k_bytes
            mt_row, global_k_byte = divmod(tensor_byte,512*2)
            global_k = global_k_byte//2
            nt, n_local = divmod(q['col'],128)
            kt, k_local = divmod(global_k,128)
            if micro_k_bytes!=k_local*2 or global_k//32!=q['row']:
                raise ValueError('Input and quant source generation/offset disagree')
            flags = v['cmd_flags']
            last_k = bool(flags & 8)
            c = dict(ordinal=len(commands),work_seq=seq,owner=nt+1,dma_tile=load['dma_tile'],
                     mt=mt_row//128,nt=nt,kt=kt,kb=k_local//16,nb=n_local//16,
                     source_bank=flags&1,source_generation=load['source_generation'],
                     rows=v['cmd_eff_mt'],columns=16,global_k=global_k,
                     accumulate=bool(flags&4),last_k=last_k,terminal=last_k and n_local==112,
                     input_base=input_address-origin,psum_base=v['cmd_rs1_data']-origin,
                     final_base=(v['cmd_stride']-origin)&lmem_mask,weight_base=weights[seq],
                     scale_base=q['source_lmem']-origin,zero_base=z['source_lmem']-origin,
                     admission_wait=None,
                     completion={'event':'physical_command_drain','notification':'separate legacy NOTIFY'})
            commands.append(dict(descriptor=c,accept_edge=edge,input_edges=[],writeback_edges=[],writeback_addresses=[],
                                 raw_addresses=dict(input=v['cmd_rs2_data'],psum=v['cmd_rs1_data'],final=v['cmd_stride'],origin=origin)))
        if v['in_valid'] and v['in_ready']:
            seq=v['in_seq']
            if v['input_fire']!=1 or not 1<=seq<=len(commands):
                raise ValueError('Input interface/compute acceptance mismatch')
            c=commands[seq-1]
            row=len(c['input_edges'])
            d=c['descriptor']
            if row>=d['rows'] or v['in_rd_addr']-origin!=d['psum_base']+row*64:
                raise ValueError('Input accepted row count/address mismatch')
            expected_write=(d['final_base']+row*256) if d['last_k'] else (d['psum_base']+row*64)
            if ((v['in_wr_addr']-origin)&lmem_mask)!=expected_write:
                raise ValueError('Input write-address mapping mismatch')
            c['input_edges'].append(edge)
        elif v['input_fire']:
            raise ValueError('Compute input fires without actual interface handshake')
        if v['ingress']:
            c=commands[v['active_seq']-1]
            if len(c['input_edges'])!=c['descriptor']['rows'] or c['input_edges'][-1]!=edge:
                raise ValueError('Ingress event differs from last accepted row')
            c['ingress_edge']=edge
        if v['wb']:
            c=commands[v['wb_seq']-1]
            row=len(c['writeback_edges'])
            d=c['descriptor']
            expected=(d['final_base']+row*256) if d['last_k'] else (d['psum_base']+row*64)
            if row>=4 or ((v['wb_addr']-origin)&lmem_mask)!=expected:
                raise ValueError('Accepted writeback address/order mismatch')
            c['writeback_edges'].append(edge)
            c['writeback_addresses'].append((v['wb_addr']-origin)&lmem_mask)
        if v['tagged_wb']:
            c=commands[v['tagged_seq']-1]
            if len(c['writeback_edges'])!=4 or c['writeback_edges'][-1]!=edge:
                raise ValueError('Tagged final-row writeback mismatch')
            c['final_compute_writeback_edge']=edge
        if v['command_done']:
            c=commands[v['active_seq']-1]
            if v['wr_pending']!=0 or 'final_compute_writeback_edge' not in c:
                raise ValueError('Physical command drain before final writeback/zero pending lanes')
            c['physical_command_done_edge']=edge
    if len(commands)!=1024 or load_count!=16 or len(stores)!=4:
        raise ValueError('Incomplete baseline descriptor/owner coverage')
    for c in commands:
        if len(c['input_edges'])!=4 or len(c['writeback_edges'])!=4 or 'physical_command_done_edge' not in c:
            raise ValueError('Incomplete per-command row or retirement coverage')
    expected=contract.stream(4,512,512,16,0,0)
    geometry_fields=set(expected[0])-{'admission_wait','completion'}
    for c,e in zip(commands,expected):
        for field in geometry_fields:
            if c['descriptor'][field]!=e[field]:
                raise ValueError(f"Actual canonical field differs: ordinal{e['ordinal']} {field} actual={c['descriptor'][field]} expected={e[field]}")
    for s in stores:
        owned=[c for c in commands if c['descriptor']['owner']==s['owner']]
        if not owned[-1]['descriptor']['terminal'] or not owned[-1]['physical_command_done_edge']<s['accept_edge']<=s['complete_edge']:
            raise ValueError('Output owner store boundary mismatch')
    return commands,stores,window_samples,sorted(geometry_fields)


def metrics(commands,samples):
    chosen=commands[256:768]
    first,last=chosen[0]['input_edges'][0],chosen[-1]['input_edges'][-1]
    duration=last-first+1
    count=sum(len(c['input_edges']) for c in chosen)
    pairs=[]
    for a,b in zip(chosen,chosen[1:]):
        da,db=a['descriptor'],b['descriptor']
        eligible=da['owner']==db['owner'] and da['nb']!=db['nb']
        pairs.append(dict(a=da['ordinal'],b=db['ordinal'],eligible=eligible,
                          first_input_b=b['input_edges'][0],final_compute_writeback_a=a['final_compute_writeback_edge'],
                          overlap=b['input_edges'][0]<a['final_compute_writeback_edge'],
                          input_gap=b['input_edges'][0]-a['input_edges'][-1]-1,
                          admission_spacing=b['accept_edge']-a['accept_edge']))
    eligible=[p for p in pairs if p['eligible']]
    excluded=[(p['a'],p['b']) for p in pairs if not p['eligible']]
    if len(eligible)!=510 or excluded!=[(511,512)] or count!=2048:
        raise ValueError('Actual fixed middle window eligibility differs from gate')
    observation=[s for s in samples if first<=s[0]<=last]
    if len(observation)!=duration:
        raise ValueError('Missing GEMM clock samples')
    by_dma=[]
    for dma in sorted({c['descriptor']['dma_tile'] for c in chosen}):
        rows=[c for c in chosen if c['descriptor']['dma_tile']==dma]
        start,end=rows[0]['input_edges'][0],rows[-1]['input_edges'][-1]
        local_pairs=[p for p in eligible if commands[p['a']]['descriptor']['dma_tile']==dma and commands[p['b']]['descriptor']['dma_tile']==dma]
        by_dma.append(dict(dma_tile=dma,first_ordinal=rows[0]['descriptor']['ordinal'],last_ordinal=rows[-1]['descriptor']['ordinal'],
                           input_rows=sum(len(c['input_edges']) for c in rows),interval_cycles=end-start+1,
                           density=sum(len(c['input_edges']) for c in rows)/(end-start+1),eligible_pairs=len(local_pairs),
                           overlapping_pairs=sum(p['overlap'] for p in local_pairs),
                           input_gap=distribution([p['input_gap'] for p in local_pairs])))
    selected_writebacks=sum(first<=edge<=last for c in chosen for edge in c['writeback_edges'])
    completed=sum(first<=c['physical_command_done_edge']<=last for c in chosen)
    return dict(first_ordinal=256,last_ordinal=767,first_input_edge=first,last_input_edge=last,
                interval_definition='[first_input_edge, last_input_edge+1)',interval_cycles=duration,
                accepted_input_rows=count,input_handshake_density=count/duration,
                required_candidate_density=1.25*count/duration,
                maximum_candidate_interval_cycles=(duration*4)//5,
                eligible_pairs=len(eligible),excluded_pairs=excluded,overlapping_pairs=sum(p['overlap'] for p in eligible),
                required_candidate_overlapping_pairs=255,overlap_fraction=sum(p['overlap'] for p in eligible)/len(eligible),
                input_gap=distribution([p['input_gap'] for p in eligible]),
                next_input_minus_previous_final_writeback=distribution([p['first_input_b']-p['final_compute_writeback_a'] for p in eligible]),
                command_accept_to_first_input=distribution([c['input_edges'][0]-c['accept_edge'] for c in chosen]),
                last_input_to_final_compute_writeback=distribution([c['final_compute_writeback_edge']-c['input_edges'][-1] for c in chosen]),
                final_writeback_to_physical_command_done=distribution([c['physical_command_done_edge']-c['final_compute_writeback_edge'] for c in chosen]),
                selected_last_command_final_writeback_edge=chosen[-1]['final_compute_writeback_edge'],
                selected_last_command_physical_done_edge=chosen[-1]['physical_command_done_edge'],
                command_accept_spacing=distribution([p['admission_spacing'] for p in eligible]),
                source_absent_ready_cycles=sum(valid==0 and ready==1 for _,valid,ready,_,_ in observation),
                input_backpressure_cycles=sum(valid==1 and ready==0 for _,valid,ready,_,_ in observation),
                selected_acc_writeback_rows_in_same_interval=selected_writebacks,
                selected_acc_writeback_rows_per_cycle=selected_writebacks/duration,
                selected_physical_command_drains_in_same_interval=completed,
                selected_physical_command_drains_per_cycle=completed/duration,
                physical_narrow_write_handshakes_in_same_interval=sum(pop for _,_,_,pop,_ in observation),
                per_dma_tile=by_dma,pairs=pairs)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,default=HERE/'p0-baseline/naive-m4-retry1')
    parser.add_argument('--prefix',type=Path,default=HERE/'p0-service-naive-m4')
    args=parser.parse_args()
    manifest=json.loads((args.run/'manifest.json').read_text())
    if manifest.get('returncode')!=0:
        raise ValueError('Unfinished or failed baseline')
    wave=args.run/'wave.fsdb'
    wave_hash=base.sha(wave)
    source_installs=json.loads((HERE/'p0-install-naive-m4-results.json').read_text())
    if source_installs['wave_sha256']!=wave_hash or source_installs['status']!='pass':
        raise ValueError('S/Z ownership evidence from a different or failing waveform')
    snapshot=args.prefix.with_name(args.prefix.name+'-snapshot.json')
    if snapshot.exists():
        saved=json.loads(snapshot.read_text())
        if saved['wave_sha256']!=wave_hash:
            raise ValueError('Snapshot waveform changed')
        signals=saved['signals']
    else:
        signals=capture(wave)
        snapshot.write_text(json.dumps(dict(wave_sha256=wave_hash,signals=signals))+'\n')
    lmem_log_size=int(re.search(r'-DLMEM_LOG_SIZE=(\d+)',manifest['configs']).group(1))
    commands,stores,samples,fields=extract(signals,source_installs,lmem_log_size)
    descriptors=[c['descriptor'] for c in commands]
    trace=args.prefix.with_name(args.prefix.name+'-input-trace.json')
    trace.write_text(json.dumps(descriptors,indent=2)+'\n')
    # The CLI rejects this real legacy trace before writing its generated
    # artifacts. Never fill missing redesign metadata with model values.
    existing_contract_artifacts = {name: base.sha(HERE/name) for name in ('p0-contract-inputs.json','p0-contract-results.json') if (HERE/name).exists()}
    cli=subprocess.run(['python3',str(HERE/'p0-contract.py'),'--input-trace',str(trace)],capture_output=True,text=True)
    if cli.returncode==0 or 'RTL descriptor stream differs from contract' not in cli.stderr:
        raise ValueError('Expected legacy-vs-redesign metadata rejection not observed: '+cli.stderr[-1000:])
    if existing_contract_artifacts!={name:base.sha(HERE/name) for name in existing_contract_artifacts}:
        raise ValueError('Contract CLI unexpectedly modified its generated artifacts')
    result=dict(status='pass',scope='corrected legacy naive baseline, not candidate performance',
                input_trace_cli=dict(returncode=cli.returncode,expected_rejection='RTL descriptor stream differs from contract',
                                     existing_contract_artifacts_unchanged=True),
                wave_sha256=wave_hash,manifest_sha256=base.sha(args.run/'manifest.json'),
                contract_sha256=base.sha(HERE/'p0-contract.py'),canonical_geometry_fields_compared=fields,
                lmem_address_normalization=dict(log_size=lmem_log_size,method='(raw-origin) modulo LMEM size',
                    legacy_final_address='cmd.stride is32bits and drops upper LMEM address bits; raw addresses retained, physical offset checked only'),
                full_redesigned_metadata_contract_matches=False,
                metadata_difference='legacy commands use separate WAIT/NOTIFY and physical command drain; redesigned admission_wait/completion fields are absent',
                window=metrics(commands,samples),output_stores=stores,commands=commands,
                endpoint_definitions=dict(command_accept='packetizer_cmd_valid && packetizer_cmd_ready',
                    input='i_gemm_bus_if.req_valid && req_ready, verified against compute_core.input_fire',
                    compute_writeback='compute_core.acc_write_fire with carried acc_result_data_out.ctrl.work_seq',
                    final_compute_writeback='last of four accepted writeback rows, cross-checked against tagged_writeback',
                    physical_command_done='packetizer_command_done with zero pending narrow write lanes',
                    external_store_done='output_store_done cache-path retirement; not final HBM visibility'))
    output=args.prefix.with_name(args.prefix.name+'-results.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({key:value for key,value in result['window'].items() if key not in ('pairs','per_dma_tile')},indent=2))

if __name__=='__main__':
    main()
