#!/usr/bin/env python3
"""Build the final report only from complete, numerically valid sweep evidence."""
import csv
import json
from pathlib import Path
import re

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

T = Path(__file__).resolve().parent
variants = ['l16', 'l32', 'd8_r32_ordered', 'd16_r32_ordered',
            'd32_r32_ordered', 'd64_r32_ordered', 'd128_r32_ordered',
            'd128_r64_ordered', 'd128_r128_ordered']
def label(v):
    return v.upper() if v in ['l16', 'l32'] else v.removesuffix('_ordered').upper().replace('_', '/')
results = {}
analysis = {}
for v in variants:
    for case in ['m4', 'm256']:
        p = T / 'runs' / v / case
        r = json.loads((p / 'result.json').read_text())
        a = json.loads((p / 'analysis.json').read_text())
        assert r['passed'] and a['numerically_valid'], (v, case)
        results[v, case] = r
        analysis[v, case] = a
for case in ['m4', 'm256']:
    reference = analysis['l16', case]['buses']['dma_global']
    for v in variants:
        bus = analysis[v, case]['buses']['dma_global']
        assert all(bus[k] == reference[k] for k in ['read_mask_bytes', 'write_mask_bytes']), (v, case)

def core(v, case='m256'):
    return results[v, case]['core_cycles'][0]
def dr(v):
    return tuple(map(int, re.match(r'd(\d+)_r(\d+)', v).groups()))
best = min(core(v) for v in variants[2:])
eligible = [v for v in variants[2:] if core(v) <= best * 1.01]
selected = min(eligible, key=dr)
selection = dict(variant=selected, depth=dr(selected)[0], slots=dr(selected)[1],
                 best_core_cycles=best, selected_core_cycles=core(selected),
                 rule='Smallest response depth within 1% of best valid M256 core cycles, then smallest DMA slot count',
                 eligible=eligible)
(T / 'selection.json').write_text(json.dumps(selection, indent=2) + '\n')

rows = []
for v in variants:
    for case in ['m4', 'm256']:
        r, a = results[v, case], analysis[v, case]
        c = a['dma_counters_at_gemm_end']
        q = a['splitters'].get('dcache', {})
        rows.append(dict(variant=v, case=case, passed=True,
                         gemm_cycles=r['gemm_cycles'][0], core_cycles=core(v, case),
                         dma_active_cycles=a['dma_active_cycles'],
                         dma_slots_max=a['dma_slots']['max'],
                         dma_slots_full_cycles=a['dma_slots']['full_cycles'],
                         dcache_context_max=q.get('context_max', ''),
                         dcache_context_full_cycles=q.get('context_full_dma_active_cycles', ''),
                         wait_dcache=c['wait_dcache'], wait_lmem=c['wait_lmem'],
                         useful_read_bytes=a['buses']['dma_global']['read_mask_bytes'],
                         aggregate_read_bytes=c['rd_bytes'],
                         hbm_read_bytes_per_gemm_cycle=a['aggregate_bus_rates']['hbm_all_clients']['response_bus_bytes_per_gemm_cycle']))
with (T / 'results.csv').open('w') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)

fig, axes = plt.subplots(1, 2, figsize=(13, 4.8), layout='constrained')
for ax, case in zip(axes, ['m4', 'm256']):
    values = [core(v, case) for v in variants]
    colors = ['#8193a3' if v in ['l16', 'l32'] else '#147d64' if v == selected else '#477ac2' for v in variants]
    bars = ax.bar(range(len(variants)), values, color=colors)
    ax.set_xticks(range(len(variants)), [label(v) for v in variants], rotation=55, ha='right')
    ax.set_title(case.upper() + ', K=N=512 (all numerical PASS)')
    ax.set_ylabel('Core cycles (lower is better)')
    ax.grid(axis='y', alpha=.2)
    ax.set_axisbelow(True)
    ax.bar_label(bars, labels=[f'{v:,}' for v in values], rotation=90, padding=3, fontsize=8)
    ax.set_ylim(0, max(values)*1.2)
fig.suptitle('Naive DMA width and response-depth exploration — selected: ' + label(selected))
fig.savefig(T / 'core_cycles.png', dpi=180)
fig.savefig(T / 'core_cycles.svg')
plt.close(fig)

fig, axes = plt.subplots(1, 2, figsize=(13, 4.8), layout='constrained')
for ax, case in zip(axes, ['m4', 'm256']):
    values = [analysis[v, case]['dma_active_cycles'] for v in variants]
    bars = ax.bar(range(len(variants)), values, color=['#147d64' if v == selected else '#477ac2' for v in variants])
    ax.set_xticks(range(len(variants)), [label(v) for v in variants], rotation=55, ha='right')
    ax.set_title(case.upper() + ', K=N=512')
    ax.set_ylabel('DMA active cycles (lower is better)')
    ax.grid(axis='y', alpha=.2)
    ax.set_axisbelow(True)
    ax.bar_label(bars, labels=[f'{v:,}' for v in values], rotation=90, padding=3, fontsize=8)
    ax.set_ylim(0, max(values)*1.2)
fig.suptitle('External DMA activity — identical enabled payload bytes across configurations')
fig.savefig(T / 'dma_active_cycles.png', dpi=180)
fig.savefig(T / 'dma_active_cycles.svg')
plt.close(fig)

lines = [
    '# Naive D256 simulation results', '',
    f'Selected **{label(selected)}**: response depth {dr(selected)[0]}, DMA outstanding slots {dr(selected)[1]}, response reordering enabled.', '',
    f'M256 core cycles: **{core(selected):,}**. This is {(1-core(selected)/core("l32"))*100:.2f}% lower than L32 ({core("l32"):,}) and {(1-core(selected)/core("l16"))*100:.2f}% lower than L16 ({core("l16"):,}).', '',
    'Selection rule: smallest response depth within 1% of the best valid M256 core cycles, then smallest DMA slot count. M4 is reported separately. All 18 naive application cases below passed numerical verification.', '',
    '![Measured core cycles](core_cycles.png)', '',
    '## Cycle results', '',
    '| Configuration | M4 core | M4 GEMM | M256 core | M256 GEMM |',
    '|---|---:|---:|---:|---:|',
]
for v in variants:
    lines.append(f'| {label(v)} | {core(v,"m4"):,} | {results[v,"m4"]["gemm_cycles"][0]:,} | {core(v):,} | {results[v,"m256"]["gemm_cycles"][0]:,} |')
lines += ['', 'L16/L32 retain the original ordered-lane FIFO path. Every D/R entry uses the SRAM reorder path, four fixed DMA-to-cache lanes, and four L1 memory ports. Failed depth-only runs are excluded; their diagnosis is in [README.md](README.md).', '', '## M256 buffering and stalls', '',
          '![DMA active cycles](dma_active_cycles.png)', '',
          '| Configuration | DMA active | Cache context max/full cycles | DMA slots max/full cycles | Cache wait | LMEM wait |',
          '|---|---:|---:|---:|---:|---:|']
for v in variants:
    a = analysis[v, 'm256']; q = a['splitters'].get('dcache'); s = a['dma_slots']; c = a['dma_counters_at_gemm_end']
    context = f'{q["context_max"]:,} / {q["context_full_dma_active_cycles"]:,}' if q else 'No cache splitter'
    lines.append(f'| {label(v)} | {a["dma_active_cycles"]:,} | {context} | {s["max"]:,} / {s["full_cycles"]:,} | {c["wait_dcache"]:,} | {c["wait_lmem"]:,} |')
lines += ['', 'Full-cycle measurements are restricted to DMA-active cycles. Wait counters can overlap and must not be added as disjoint latency components. Requested D128/R32 is tag-limited to 64 effective reorder slots; D128/R64 and D128/R128 have 128. Each splitter has one additional output holding stage.', '',
          '## Payload and bandwidth', '',
          '| Configuration / case | DMA active cycles | Enabled read bytes | Aggregate read bytes | Enabled read B / DMA-active cycle | HBM read B / GEMM cycle |',
          '|---|---:|---:|---:|---:|---:|']
for v in dict.fromkeys(['l16', 'l32', selected, 'd16_r32_ordered']):
    for case in ['m4', 'm256']:
        a = analysis[v, case]; enabled = a['buses']['dma_global']['read_mask_bytes']; active = a['dma_active_cycles']; aggregate = a['dma_counters_at_gemm_end']['rd_bytes']; hbm = a['aggregate_bus_rates']['hbm_all_clients']['response_bus_bytes_per_gemm_cycle']
        lines.append(f'| {label(v)} / {case.upper()} | {active:,} | {enabled:,} | {aggregate:,} | {enabled/active:.2f} | {hbm:.2f} |')
lines += ['', 'Enabled read bytes count accepted byte enables, including repeated requested data, and are distinct from unique matrix bytes. Aggregate DMA counters count full wide responses including inactive lanes. HBM figures include all clients and the full GEMM interval, so they are not DMA-only sustained throughput.', '',
          'The generalized DMA throughput unit test reaches **256 B/cycle for 16 consecutive beats in both directions**. Full-application per-cycle peaks and per-lane traffic are preserved in each `analysis.json`; a peak does not imply sustained 256 B/cycle across the complete workload.', '',
          '## Interpretation', '',
          f'- The largest end-to-end change is L16 to L32: {(1-core("l32")/core("l16"))*100:.2f}% fewer M256 core cycles. External DMA active cycles nevertheless increase from {analysis["l16","m256"]["dma_active_cycles"]:,} to {analysis["l32","m256"]["dma_active_cycles"]:,}; DMA counters alone do not predict total GEMM latency when work overlaps and shares LMEM.',
          f'- At D8/R32, M256 cache contexts are full for {analysis["d8_r32_ordered","m256"]["splitters"]["dcache"]["context_full_dma_active_cycles"]:,} DMA-active cycles. At D16/R32 this changes to {analysis["d16_r32_ordered","m256"]["splitters"]["dcache"]["context_full_dma_active_cycles"]:,}. Compare the slot and LMEM wait columns before attributing remaining stalls to HBM.',
          f'- D16/R32 reduces M256 DMA-active cycles by {(1-analysis["d16_r32_ordered","m256"]["dma_active_cycles"]/analysis["d8_r32_ordered","m256"]["dma_active_cycles"])*100:.2f}% relative to D8/R32, while total core cycles improve by only {(1-core("d16_r32_ordered")/core("d8_r32_ordered"))*100:.3f}%. This is consistent with most of the external DMA improvement being hidden by overlap with other GEMM work.',
          f'- D8/R32 stores at most {max(x["max_buffered_responses"] for x in analysis["d8_r32_ordered","m256"]["splitters"]["dcache"]["lanes"])} returned responses per cache lane while its eight contexts saturate. The depth limit primarily restricts outstanding contexts waiting for data, rather than exhausting payload SRAM with already returned data.',
          '- Enabled payload occupies 31.43% of aggregate DMA read bytes in M4 and 63.64% in M256. Widening the DMA does not multiply useful traffic when only some cache lanes are active. All variants transfer the same enabled payload bytes.',
          f'- The selected configuration has {analysis[selected,"m256"]["dma_active_cycles"]:,} DMA-active cycles versus {results[selected,"m256"]["gemm_cycles"][0]:,} GEMM cycles. Its LMEM wait counter is {analysis[selected,"m256"]["dma_counters_at_gemm_end"]["wait_lmem"]:,}; the complete workload is not a continuous external-memory streaming benchmark.',
          f'- The fastest M4 D256 case is {label(min(variants[2:], key=lambda v: core(v,"m4")))} at {min(core(v,"m4") for v in variants[2:]):,} core cycles. The M256-based selection has {core(selected,"m4"):,} M4 core cycles. Choose the M4 result explicitly when small-matrix latency is the priority.', '',
          '## Verification and reproducibility', '',
          '- Splitter: 29/29 cases passed, including deliberately reordered lane responses, masks, backpressure, tag wraparound, and tag-namespace limits.',
          '- Generalized DMA functional test: 2,126/2,126 passed; 256 B/cycle throughput mode passed both directions.',
          '- Improve: M4 GEMM/core 6,431/12,205; M256 272,856/278,622, exactly matching the pre-edit baseline (zero cycle delta).',
          '- Improve selected RTL: 570/570 comparisons identical. The new helper is excluded from improve preprocessing; no improve synthesis was run.',
          '- Guard/format cleanup preserves selected naive logic tokens (excluding the unused debug label parameter); see `identity/guarded_candidate.json`.', '',
          'See [README.md](README.md) for implementation, commands, tag-depth limits, and provenance details, including the two baseline simulations launched before the authorized source transition. Raw measurements are in [results.csv](results.csv); the selection is in [selection.json](selection.json). Configuration and RTL hashes, numerical logs, and FSDB evidence are retained under `runs/`.', '']
(T / 'results.md').write_text('\n'.join(lines))
print(json.dumps(selection, indent=2))
