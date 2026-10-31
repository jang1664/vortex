#!/usr/bin/env python3
import csv,json,statistics
from pathlib import Path
r=Path(__file__).resolve().parent
m=json.loads((r/'matrix.json').read_text())
assert m['passed'] is True
columns=['cycles','attention_total_cycles','gemm_submit_cycles','gemm_wait_cycles','sram_copy_cycles','simd_cycles']
summary=[]
for case in m['cases']:
    modes={}
    for backend in m['backends']:
        with (r/case/'timing'/backend/'profile.csv').open() as f: rows=list(csv.DictReader(f))
        ops={}
        for op in sorted(set(x['operation'] for x in rows)):
            selected=[x for x in rows if x['operation']==op]
            assert len(selected)==3
            ops[op]={c:statistics.median(int(x[c]) for x in selected) for c in columns}
            ops[op]['cycle_samples']=[int(x['cycles']) for x in selected]
        names=['qk','softmax','pv'] if backend=='legacy' else ['attention']
        cycles=sum(ops[n]['cycles'] for n in names)
        modes[backend]={'attention_cycles':cycles,'attention_ms':cycles/100000,'ops':{n:ops[n] for n in names},'decoder_sum_cycles':sum(x['cycles'] for x in ops.values())}
        for mode in ['verify','timing']:
            assert m['correctness'][case][mode][backend]['verification']['pass'] is True
        if backend!='legacy':
            assert m['correctness'][case]['verify'][backend]['backend_comparison']['pass_all'] is True
            modes[backend]['slowdown']=cycles/modes['legacy']['attention_cycles']
    summary.append({'case':case,'backends':modes})
(r/'comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['# FlashAttention versus separate QK + softmax + PV','',
'Current SRAM FlashAttention is slower in all three measured workloads. All numerical checks passed.','',
'## Method','',
'- Llama3-8B, batch 1, complete attention across all heads. Same fixtures, same current unified-MMIO FPGA image and config, same decoder executable; only `--attention-backend` changes.',
'- Image: `'+m['image']+'`; SHA256 `'+m['image_sha256']+'`.',
'- Image clock: 100 MHz. Reported milliseconds are core cycles / 100,000; they exclude host launch/wait time. They are attention-only, not whole-decoder latency.',
'- Existing legacy path dispatches QK, softmax and PV as separate kernels (batched heads per GEMM phase). Baseline is the sum of their three per-operation median core-cycle counts.',
'- FlashAttention is the complete `attention` operation including input adapters, initialization, GEMM, SRAM copies, SIMD and final output. No diagnostic timing or early-stop shortcut.',
'- Three measured profile passes per backend after warmup; wall timing uses separate passes and is not mixed into these comparisons.',
'- Verify runs passed full CPU intermediate/final-output checks. Cross-backend checks passed with identical Q and packed K/V inputs; timing runs also passed output gates.',
'- Scope is three selected cases, not the full nine-case functionality matrix or a large-sequence scaling study.','',
'## Attention latency','',
'| Workload | Separate QK + softmax + PV (ms) | Flash FP16 (ms) | FP16 slowdown | Flash FP32 (ms) | FP32 slowdown |',
'|---|---:|---:|---:|---:|---:|']
labels={'llama3-8b_decode_p16_c32':'Decode: 1 query, KV=17, capacity=32','llama3-8b_decode_p128_c256':'Decode: 1 query, KV=129, capacity=256','llama3-8b_prefill128':'Prefill: 128 queries, KV=128'}
for row in summary:
    b=row['backends']; a=b['legacy']; f=b['resident']; g=b['resident-fp32']
    lines.append(f"| {labels[row['case']]} | {a['attention_ms']:.4f} | {f['attention_ms']:.4f} | {f['slowdown']:.2f}x | {g['attention_ms']:.4f} | {g['slowdown']:.2f}x |")
lines+=['','## Separate operation medians (cycles)','','| Workload | QK | Softmax | PV | Sum |','|---|---:|---:|---:|---:|']
for row in summary:
    a=row['backends']['legacy']; o=a['ops']
    lines.append(f"| {labels[row['case']]} | {o['qk']['cycles']} | {o['softmax']['cycles']} | {o['pv']['cycles']} | {a['attention_cycles']} |")
lines+=['','## Resident phase medians (cycles)','','`simd` includes initialization, online softmax, partial accumulation/rescaling and final normalization/output. `gemm_wait` includes input loads, internal SRAM DMA and polling; `sram_copy` covers one-time OBUF initialization. Individual phase medians need not sum exactly to the operation median.','','| Workload | Mode | Whole attention | Shared-kernel total | SIMD | GEMM wait incl. DMA | OBUF init |','|---|---|---:|---:|---:|---:|---:|']
for row in summary:
 for mode in ['resident','resident-fp32']:
    p=row['backends'][mode]['ops']['attention']
    lines.append(f"| {labels[row['case']]} | {mode} | {p['cycles']} | {p['attention_total_cycles']} | {p['simd_cycles']} | {p['gemm_wait_cycles']} | {p['sram_copy_cycles']} |")
lines+=['','## Interpretation','',
'- SIMD work is a substantial measured cost. Current flash scheduling executes GEMM, DMA and SIMD sequentially. SRAM residency by itself does not establish a latency improvement.',
'- Capacity=32 requires K/V padding/repacking to the fixed 128-key tile in `prepare_attention_inputs()`. The difference between whole-operation and shared-kernel timing also includes dispatch/wrapper overhead; it is not an isolated padding timer.',
'- Capacity=256 uses direct stored tiles, yet remains slower; input padding alone does not explain the result.',
'- No new RTL, kernel optimization, or timing exception was introduced for this comparison. The original config and numerical thresholds were retained.','',
'Raw evidence: `matrix.json`, each case’s `verify/` and `timing/` directories, and `logs/`. The launcher is [run_comparison.sh](../20261031_unified_mmio_r1/run_comparison.sh). `comparison.json` retains median values and all three cycle samples.']
(r/'RESULTS.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[17:24]))
print(json.dumps([{ 'case':x['case'], 'modes': {k:{a:v[a] for a in ['attention_cycles','attention_ms']+(['slowdown'] if k!='legacy' else [])} for k,v in x['backends'].items()}} for x in summary],indent=2))
