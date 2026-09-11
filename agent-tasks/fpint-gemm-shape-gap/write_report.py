#!/usr/bin/env python3
"""Write the measured shape-gap diagnosis separately from the cycle-only report."""
import hashlib,json
from pathlib import Path
import numpy as np
from analyze import ROOT,TASK,BASE,RUNS
results={n:json.loads((TASK/'captures'/n/'result.json').read_text()) for n in RUNS}
commands={n:json.loads((TASK/'captures'/n/'command-gaps.json').read_text()) for n in ['improve4','improve256']}
physical={n:json.loads((TASK/'captures'/n/'physical/result.json').read_text()) for n in ['naive4','naive256']}
provenance={}
for n,r in results.items():
 assert not r['missing'] and r['cycles']==int(r['log']['L_gemm'])
 done=np.load(TASK/'captures'/n/'done.npz');edge=int(((done['t'][done['v']==1]-5000)//10000+1)[0]);assert edge==int(r['log']['e_valid'])
 run=BASE/RUNS[n];m=json.loads((run/'manifest.json').read_text())
 digest=hashlib.sha256()
 with (run/'wave.fsdb').open('rb') as f:
  for chunk in iter(lambda:f.read(8*1024*1024),b''):digest.update(chunk)
 provenance[n]={'run':str(run.relative_to(ROOT)),'wave_sha256':digest.hexdigest(),'capture_git_head':m['git_head'],'configs':m['configs'],'source_changes_during_run':m['source_changes_during_run'],'endpoint_fsdb_match':True}
(TASK/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
p=physical['naive256'];s=np.load(TASK/'captures/naive256/samples.npz');sl=slice(50000,54096)
window={'cycles':4096,'input_fire':int(s['input_fire'][sl].sum()),'post_launches':int(s['post_txn_launch'][sl].sum()),'post_queue_full':int((s['post_txn_count'][sl]==4).sum()),'post_wait_psum':int((s['post_head_psum_ready'][sl]==0).sum()),'tree_credit_zero':int((s['tree_credit_q'][sl]==0).sum()),'bank_utilization_percent':100*p['bank_request_words']/(4096*16)}
(TASK/'window-summary.json').write_text(json.dumps(window,indent=2)+'\n')
lines=['# Why improve has a larger speedup at M256 than M4','',
'The current gap is dominated by naive\'s variable-latency LMEM partial-sum path and the bounded queues that absorb it. Improve keeps partial sums in a dedicated internal accumulator and reaches almost one accepted input per cycle at M256. M4 gives improve shorter four-row commands and more exposed gaps, so its advantage is smaller there. The observed result is not explained by external-DMA bandwidth alone.','',
'## Current measurements','',
'TH16 / MXU16x16, K=N=512, QCOL, non-transposed weights, corrected vectors. GEMM cycles run from accepted configuration to first completion-valid. Input means one accepted 16-element activation vector, not an entire microtile.','',
'| M | Input transfers per backend | Improve GEMM cycles | Naive GEMM cycles | Naive / improve | Improve cycles/input | Naive cycles/input |',
'|---:|---:|---:|---:|---:|---:|---:|']
for m in (4,256):
 i,n=results[f'improve{m}'],results[f'naive{m}'];rows=i['counts']['input_fire'];assert rows==n['counts']['input_fire']
 lines.append(f"| {m} | {rows:,} | {i['cycles']:,} | {n['cycles']:,} | {n['cycles']/i['cycles']:.3f}x | {i['cycles']/rows:.3f} | {n['cycles']/rows:.3f} |")
lines+=['','When M increases 64x, improve becomes more efficient per input (1.574 to 1.041 cycles), while naive improves less (6.237 to 5.020). This directly explains the ratio increasing from 3.961x to 4.822x. It does not mean naive becomes slower per input at M256.','',
'## 1. Most naive M256 stalls occur while external DMA is idle','',
'| Backend / M | External DMA active cycles | Input valid but not ready | Of those, external DMA idle |',
'|---|---:|---:|---:|']
for name in ['improve4','naive4','improve256','naive256']:
 c=results[name]['counts'];lines.append(f"| {name} | {c['external_busy']:,} | {c['input_backpressure']:,} | {c['input_stall_external_idle']:,} |")
lines+=['',
'For naive M256, **1,000,917 of 1,032,476 input-stall cycles (96.94%) occur with external DMA idle**. External DMA is active for only 59,559 / 1,315,844 cycles (4.53%). This rules out continuing external transfers as the immediate cause of most input stalls. External-DMA active time includes concurrent useful work and is not an additive latency component or a pure bandwidth measurement.','',
'Busy is sampled from `core/accel_perf.cpu_dma.busy` for naive and `core/accel_perf.hbm_dma.aggregate.busy` for improve. The old printed DMA-union overlap includes local engines and cannot substitute for this comparison.','',
'## 2. Follow the stall back to the partial-sum path','',
'| Observed condition | Naive M4 | Naive M256 | Improve M256 |',
'|---|---:|---:|---:|']
for title,key in [('Oldest postprocessing operation waits for partial sum','post_wait_psum'),('Accumulator read request valid but not ready','acc_rd_req_stall'),('Compute operands present but no pipeline credit','compute_wait_credit'),('Accumulator write request valid but not ready','acc_wr_stall')]:
 lines.append('| '+title+' | '+' | '.join(f"{results[n]['counts'][key]:,}" for n in ['naive4','naive256','improve256'])+' |')
lines+=['',
'These conditions overlap; do not add their cycle counts. The important chain is visible in the RTL and waveforms:',
'', '```mermaid','flowchart LR','  A[LMEM partial-sum response and read-slot wait] --> B[Four-entry postprocessing queue fills]','  B --> C[Conversion/result queues stop draining]','  C --> D[Compute pipeline credits exhausted]','  D --> E[Input ready falls despite valid data]','```','',
'- [Naive accumulator](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv:165) accepts a read only if its transaction exists and either a matching prefetched slot or a free slot exists. Completed speculative reads retain their slots until the corresponding demand is accepted and the response is consumed. There are eight adapter read slots.',
'- [Common postprocessing](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:2261) cannot launch the oldest operation until its partial sum is ready. It has four postprocessing entries. A held read request also blocks new postprocessing launches at the conversion output.',
'- [Compute admission](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1769) requires available pipeline credit. The blocked pipeline eventually lowers input ready through the input buffers.',
'- [Improve accumulator](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv:95) has a dedicated internal memory path with read-request ready tied high. In the M256 trace it accepts and returns all 253,952 partial-sum reads without read-request stalls; the oldest postprocessing operation never waits for its partial sum.',
'',
'The architectural difference therefore includes **where partial sums are accumulated**, in addition to TMEM operand placement and tile-major layout. Every additional output row still needs these internal partial-sum reads/writes. Their counts grow 64x from M4 to M256 (3,968 to 253,952 reads per backend), even though external weight-load overhead is amortized.','',
'## 3. The naive limit is latency/queue handling, not saturated aggregate bank bandwidth','',
'A fixed 4,096-cycle window at configuration +50,000 through +54,095 in naive M256 has no external DMA activity. Its measured details are:',
'',
'| Window observation | Result |','|---|---:|',
'| Input transfers | 801 |','| Completed postprocessing launches | 799 |','| Cycles waiting for partial sum at postprocessing head | 3,297 |','| Four-entry postprocessing queue full | 3,125 |','| Eight adapter read slots full | 2,337 |','| Core read request blocked | 2,216 |','| Blocked reads with all adapter slots occupied and no matching slot | 2,216 |','| Speculative / late-demand read allocations | 286 / 514 |','| Physical response-slot join full (four slots) | 535 |','| Physical read request blocked by that full join | 461 |','| Physical response FIFO full | 0 |','| Same-address read-before-write guard blocking | 0 |','| PSUM write-request stall | 0 |',
'| Accepted physical bank words, all 16 banks combined | 16,148 |',
f"| Aggregate bank request utilization | {window['bank_utilization_percent']:.2f}% |",'',
'Of 798 fully observed physical wide-read request/response pairs, 665 return after 11 cycles; the rest take 12–20 cycles. This is measured from the join\'s wide request handshake to the response handshake into the accumulator adapter, including the transport/join path. The core demand-to-response latency is a separate interval: prefetched hits are often one cycle, while late-demand reads take 13–30 cycles in this window.',
'',
'On average 2.94 of the eight adapter slots contain completed reads whose normal core demand has not yet been accepted. The four-slot physical join is thus only one part of the bound: the eight adapter slots and four postprocessing entries also limit useful requests in flight. The trace does not support describing the whole slowdown as a fully utilized LMEM bank array. The busiest individual bank accepts requests on 1,366 / 4,096 cycles (33.35%).',
'',
'For example, at configuration +50,103 the adapter has eight occupied slots and holds a new read with ready=0. At +50,105 Input has valid=1 and ready=0; that persists through at least +50,117. External DMA is idle throughout this window.',
'',
'These observations identify the present bottleneck. They do not establish the exact speedup obtainable by enlarging any one queue; that would require a separate controlled RTL experiment, which was not performed.','',
'## 4. Why improve benefits more from increasing M','',
'| Improve input behavior | M4 | M256 |','|---|---:|---:|',
'| Input commands | 1,024 | 2,048 |','| Rows per command | 4 | 128 |',
'| Successive input transfers one cycle apart | 2,994 / 4,095 | 262,135 / 262,143 |',
'| Empty cycles inside commands | 777 | 2 |','| Empty cycles between commands | 1,202 | 8,197 |',
'| Input-acceptance cycles / GEMM cycles | 63.51% | 96.07% |','',
'At M256, 2,040 of 2,047 command boundaries introduce no input gap. The other seven have a 1,172-cycle transfer-to-transfer interval, and there is one two-cycle internal bubble. Most of the invocation is consequently a one-input-per-cycle stream.',
'',
'At M4, four-row commands expose operand delivery and command-boundary gaps much more frequently. The 1,202 between-command and 777 within-command empty cycles total 1,979 of its 6,075-cycle input span. These are directly counted gaps; they are not all attributed to a single DMA state or to weight wait, since stages overlap. Compute-side weight-not-ready occurs on 335 cycles at M4 versus one at M256.',
'',
'Increasing M therefore removes a larger fraction of improve\'s exposed overhead. Naive still spends about five cycles per input because the partial-sum path throttles the same common compute pipeline. An external-memory arithmetic-intensity argument alone misses that internal-memory bottleneck.','',
'## Evidence and reproducibility','',
'Analysis uses `fsdb_cli.report` on the four existing passing captures listed below. Samples are taken strictly before the 10 ns rising clock edge; configuration and first completion-valid match the logged normalized endpoints. Input, compute, read-response and writeback counts match the expected work. No RTL or simulation configuration was changed, and no new simulation was run.','']
for name,r in results.items():lines.append(f"- `{name}`: `{r['run']}/wave.fsdb`.")
lines+=['','Scripts are in `agent-tasks/fpint-gemm-shape-gap/`: `analyze.py`, `physical.py`, `improve_commands.py`, and `write_report.py`. Local `captures/` contains cached transitions, strict-preedge arrays and result JSON; `provenance.json` records wave hashes and capture configs. The physical queue/bank findings are scoped to the stated window; whole-invocation counters above are full-trace measurements.','',
'The initial extraction used nonexistent accumulator-write and external-busy aliases; these were corrected to `wr_req_*` and `accel_perf.*` without changing the waveforms. The completed extraction has no missing signals.','',
'The cycle-only `fpint_gemm_latency.md` is intentionally unchanged.']
followup=TASK/'prefetch-followup.md'
if followup.exists():lines.extend(['',followup.read_text()])
report=ROOT/'docs/hw_analysis/improve_vs_naive/fpint_gemm_m4_m256_gap_analysis.md';report.write_text('\n'.join(lines)+'\n');print(report)
