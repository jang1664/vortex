#!/usr/bin/env python3
import datetime,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[5]
OUT=Path(__file__).resolve().parents[1]
rows=json.loads((OUT/'measurements.json').read_text())
for candidate in ['c3','c4']:
    p=OUT/f'raw/{candidate}_llama2_ffn_decode.json'
    if not p.exists():continue
    d=json.loads(p.read_text())
    elapsed=(datetime.datetime.now()-datetime.datetime.fromisoformat(d['started'])).total_seconds()
    if d['status']!='running':
        print(candidate.upper(),d['status'],round(d.get('elapsed_seconds',elapsed)), 's');continue
    cycles=0
    with (ROOT/f'build_latency_perf_{candidate}_rev6/sim/xrtsim_vcs/simv.log').open() as f:
        for line in f:
            if line.startswith('FINE GEMM_WINDOW index='):
                cycles=(int(line.split('index=')[1].split()[0])+1)*1024
    baseline=next(r for r in rows if r['key']==candidate+'_llama3_kv_decode')
    estimate=baseline['gemm_cycles']*11008/1024
    print(candidate.upper(),'FFN',format(cycles,','),'cycles',f'{100*cycles/estimate:.1f}% of KV-scaled cycle estimate',round(elapsed),'s elapsed')
