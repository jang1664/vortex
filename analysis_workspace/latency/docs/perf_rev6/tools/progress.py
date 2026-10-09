#!/usr/bin/env python3
import argparse,datetime,json,math,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[5]
OUT=Path(__file__).resolve().parents[1]
rows=json.loads((OUT/'measurements.json').read_text())
parser=argparse.ArgumentParser()
parser.add_argument('--case',default='llama2_ffn_decode')
options=parser.parse_args()
for candidate in ['c3','c4']:
    p=OUT/f'raw/{candidate}_{options.case}.json'
    if not p.exists():continue
    d=json.loads(p.read_text())
    elapsed=(datetime.datetime.now()-datetime.datetime.fromisoformat(d['started'])).total_seconds()
    if d['status']!='running':
        print(candidate.upper(),d['status'],round(d.get('elapsed_seconds',elapsed)), 's');continue
    cycles=0;write_bytes=0;output_milestones=[]
    with (ROOT/f'build_latency_perf_{candidate}_rev6/sim/xrtsim_vcs/simv.log').open() as f:
        for line in f:
            if line.startswith('FINE GEMM_WINDOW index='):
                cycles=(int(line.split('index=')[1].split()[0])+1)*1024
                if 'b64_' in options.case:
                    group_bytes=d['case']['m']*128*2 # configured standalone DMA NT=128
                    before=write_bytes//group_bytes
                    write_bytes+=int(re.search(r'wr_bytes=(\d+)',line).group(1))
                    if write_bytes//group_bytes>before:output_milestones.append(cycles)
    if 'b64_' in options.case:
        shape=d['case']
        lower_bound=shape['m']*math.ceil(shape['n']/16)*math.ceil(shape['k']/16)
        print(candidate.upper(),shape['id'],format(cycles,','),'selected GEMM cycles',
              f'{100*cycles/lower_bound:.1f}% of input-fire cycle lower bound',round(elapsed),'s elapsed')
        groups=math.ceil(shape['n']/128)
        note=f'  accepted AXI write {write_bytes:,}/{shape["m"]*shape["n"]*2:,} expected output B; {write_bytes//group_bytes}/{groups} group-equivalents (proxy, not done signal)'
        if len(output_milestones)>=2 and cycles:
            interval=(output_milestones[-1]-output_milestones[0])/(len(output_milestones)-1)
            end_cycle=output_milestones[-1]+(groups-len(output_milestones))*interval
            note+=f'; remaining ~{max(0,end_cycle-cycles)*elapsed/cycles/60:.1f} min'
        print(note)
        continue
    suffix='_m4' if options.case.endswith('_m4') else ''
    baseline=next(r for r in rows if r['key']==candidate+'_llama3_kv_decode'+suffix)
    estimate=baseline['gemm_cycles']*d['case']['n']/baseline['case']['n']
    print(candidate.upper(),'FFN',format(cycles,','),'cycles',f'{100*cycles/estimate:.1f}% of KV-scaled cycle estimate',round(elapsed),'s elapsed')
