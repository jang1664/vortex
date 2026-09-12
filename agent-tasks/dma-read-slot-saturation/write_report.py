"""Publish measured DMA capacity sweeps and additive GEMM phase comparisons."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
DOC = ROOT / 'docs/hw_analysis/improve_vs_naive'
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--improve-depth', type=int, required=True)
ap.add_argument('--naive-depth', type=int, required=True)
args = ap.parse_args()
records = {}
for path in (TASK / 'captures').glob('*/result.json'):
    d = json.loads(path.read_text())
    manifest = json.loads((ROOT / d['run'] / 'manifest.json').read_text())
    assert manifest['passed'] and not manifest['source_changes_during_run']
    cores = [int(re.search(r'cycles=(\d+)', line)[1]) for line in manifest['perf']
             if line.startswith('PERF: instrs=')]
    assert len(cores) == 1
    d['core_cycles'] = cores[0]
    records[d['backend'], d['depth'], d['m']] = d
selected = {b: {m: records[b, depth, m] for m in (4, 256)}
            for b, depth in [('improve', args.improve_depth), ('naive', args.naive_depth)]}
def number(n):
    return f'{n:,}'

text = '# External DMA read-slot saturation and phase comparison\n\n'
text += (f'Selected external DMA read slots: **improve {args.improve_depth} per channel** '
         f'and **naive {args.naive_depth}**. These are response-RAM/OOO slots in the external DMA, '
         'independent of the eight local Weight response slots and sixteen naive PSUM slots. '
         'TH16/MXU16, M4/M256, K=N512, QBLK32, QCOL, WTRANS0, one repetition, current N-fast microtile traversal.\n\n')
text += ('Improve uses eight aligned DMA units; naive uses one misaligned DMA unit. '
         'The source and destination paths, engine count, and data-realignment behavior remain different. '
         'This is a comparison after sizing each DMA, not an isolated test of HBM bandwidth.\n\n')
text += (f'The selected response-data RAM capacity is improve 8 × {args.improve_depth} × 64 B '
         f'= {8*args.improve_depth*64:,} B and naive {args.naive_depth} × 128 B '
         f'= {args.naive_depth*128:,} B, excluding metadata and downstream queues. '
         'The dual-port RAM instances are '
         '[aligned DMA](../../../hw/rtl/core/VX_dma_unit_align.sv:1466) and '
         '[misaligned DMA](../../../hw/rtl/core/VX_dma_unit_misal.sv:716).\n\n')
text += '## Capacity sweep\n\n'
text += ('DMA read-active cycles are the union of cycles in which at least one external DMA unit is active '
         'in the DRAM-to-operand-memory direction. They include setup, response latency, and destination '
         'backpressure; they overlap GEMM computation and must not be added to total GEMM cycles.\n\n')
for backend in ['improve', 'naive']:
    text += f'### {backend}\n\n| Slots | M4 GEMM | M256 GEMM | M4 DMA read-active | M256 DMA read-active | M4 max occupied | M256 max occupied |\n'
    text += '|---:|---:|---:|---:|---:|---:|---:|\n'
    depths = sorted({depth for b, depth, m in records if b == backend})
    for depth in depths:
        if not all((backend, depth, m) in records for m in [4, 256]):
            continue
        a, b = (records[backend, depth, m] for m in [4, 256])
        values = [depth, a['gemm_cycles'], b['gemm_cycles'], a['dma_read_union_busy'],
                  b['dma_read_union_busy'], max(u['max_occupancy'] for u in a['dma_units']),
                  max(u['max_occupancy'] for u in b['dma_units'])]
        text += '| ' + ' | '.join(number(v) for v in values) + ' |\n'
    text += '\n'
text += ('A full response RAM alone does not establish a throughput bottleneck: a destination-limited DMA '
         'can keep the RAM full even after its total transfer time saturates. Likewise, removing slot-full '
         'waiting can move waiting to the source request interface. The sweep therefore compares measured '
         'transfer activity and whole-GEMM cycles, with a larger capacity as confirmation.\n\n')
text += '## Selection and whole-GEMM tradeoff\n\n'
for backend, depth in [('improve', args.improve_depth), ('naive', args.naive_depth)]:
    confirm = depth * 2
    for m in (4, 256):
        a, b = records[backend, depth, m], records[backend, confirm, m]
        for key in ('gemm_cycles', 'core_cycles', 'phases', 'dma_read_union_busy', 'dma_write_union_busy'):
            assert a[key] == b[key], (backend, depth, confirm, m, key)
    text += (f'**{backend}: select {depth}, confirmed with {confirm}.** Both matrix sizes have identical '
             'GEMM/core cycles, all five phase lengths, and DMA read/write-active times at these two capacities. '
             'This is the measured plateau for these workloads; it is not a guarantee for other shapes.\n\n')
text += ('Naive M256 still fills the RAM at depth64. Full-with-pending-read cycles fall from 20,670 '
         'at depth32 to 16,572 at depth64, while source request-stall cycles rise from 13,598 to 15,226. '
         'However, destination-write stalls remain 26,100 cycles and DMA read-active time remains '
         '60,501 cycles. Extra buffering shifts where requests wait without improving delivery time. '
         'Therefore the throughput plateau is depth32 even though depth64 can also become full.\n\n')
text += 'The naive setting targets DMA transfer saturation. The smallest whole-GEMM result in this sweep remains depth16:\n\n'
text += '| M | Depth16 GEMM | Selected GEMM | GEMM increase | DMA read-active reduction |\n|---:|---:|---:|---:|---:|\n'
for m in (4, 256):
    old, new = records['naive', 16, m], selected['naive'][m]
    delta = new['gemm_cycles'] - old['gemm_cycles']
    text += (f"| {m} | {old['gemm_cycles']:,} | {new['gemm_cycles']:,} | {delta:,} ({delta/old['gemm_cycles']*100:.4f}%) | "
             f"{old['dma_read_union_busy']-new['dma_read_union_busy']:,} |\n")
text += ('\nThe phase evidence locates the regression in the Input interval, while the external DMA itself '
         'finishes its read-active work sooner. Changed contention and overlap with LMEM operand/PSUM traffic '
         'are a timing interpretation, not a separately isolated causal experiment.\n\n')
text += '## Additive wall-clock phases\n\n'
text += ('Boundaries are configuration acceptance, first accepted Input, last accepted Input, last accumulator '
         'write, final output-store completion, and GEMM completion-valid. Phase lengths are distances between '
         'these edges and sum exactly to GEMM latency. The Output tail is only the work remaining after the last '
         'accumulator write; it is not the total time spent on all output transfers.\n\n')
names = {'startup': 'Preparation to first Input', 'input_stream': 'First to last Input',
         'compute_drain': 'Last Input to last accumulator write',
         'output_tail': 'Remaining Output stores', 'finalize': 'Completion notification'}
for m in [4, 256]:
    i, n = selected['improve'][m], selected['naive'][m]
    text += f'### M{m}\n\n| Phase | Improve | Naive | Naive minus improve |\n|---|---:|---:|---:|\n'
    for key, label in names.items():
        a, b = i['phases'][key], n['phases'][key]
        text += f'| {label} | {a:,} | {b:,} | {b-a:,} |\n'
    text += f"| **GEMM total** | **{i['gemm_cycles']:,}** | **{n['gemm_cycles']:,}** | **{n['gemm_cycles']-i['gemm_cycles']:,}** |\n\n"
text += '## Overlapping activity and stalls\n\n'
text += '| Observation | Improve M4 | Naive M4 | Improve M256 | Naive M256 |\n|---|---:|---:|---:|---:|\n'
for label, key in [('DMA read-active', 'dma_read_union_busy'), ('DMA write-active', 'dma_write_union_busy'),
                   ('Input valid but not ready', 'input_backpressure'),
                   ('Input backpressure while external DMA idle', 'input_backpressure_dma_idle'),
                   ('Compute operand waiting for Weight', 'weight_wait'),
                   ('PSUM is the remaining postprocessing blocker', 'psum_only_wait')]:
    values = [selected[b][m][key] for m in [4, 256] for b in ['improve', 'naive']]
    text += '| ' + label + ' | ' + ' | '.join(number(v) for v in values) + ' |\n'
text += '\nThese counters overlap across pipeline stages; their sums are not latency attribution.\n\n'
text += '| M | Read payload, both backends | Improve effective read B/cycle | Naive effective read B/cycle |\n|---:|---:|---:|---:|\n'
for m in (4, 256):
    i, n = selected['improve'][m], selected['naive'][m]
    payload = i['dma_counter_delta']['rd_bytes']
    assert payload == n['dma_counter_delta']['rd_bytes']
    text += (f"| {m} | {payload:,} B | {payload/i['dma_read_union_busy']:.2f} | "
             f"{payload/n['dma_read_union_busy']:.2f} |\n")
text += ('\nThis delivery rate divides useful read payload by read-active wall-clock cycles. It includes the DMA '
         'and destination-memory path, so it cannot identify physical HBM bandwidth alone. The equal payload '
         'and shorter improve DMA activity support a memory-delivery advantage; PSUM ordering and compute '
         'overlap explain why GEMM speedup is much smaller than the delivery-rate ratio.\n\n')

text += ('Preparation benefits from improve\'s parallel direct DMA launch and delivery path. Naive programs and '
         'polls descriptors through its [DMA executor](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:543), '
         'while improve launches [multiple DMA channels](../../../hw/rtl/mem/VX_dma_engine.sv:136).\n\n')
text += ('The Input interval contains both operand delivery and backpressure from downstream computation. '
         'At M4, Weight delivery is exposed because each weight microtile serves only four rows. At M256, each '
         'weight microtile serves 128 rows and naive\'s LMEM PSUM path dominates the measured postprocessing waits. '
         'Naive retains conservative [bank-set write/read ordering](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:578); '
         'increasing external DMA slots does not remove this restriction.\n\n')
text += '| Naive PSUM ordering observation | M4 | M256 |\n|---|---:|---:|\n'
for key, label in [('psum_rd_order_block', 'Read request blocked by bank-set ordering'),
                   ('psum_rd_pending_conflict', 'Prior queued writes to the same bank set'),
                   ('psum_rd_current_conflict', 'Current write request to the same bank set')]:
    text += f"| {label} | {selected['naive'][4]['node_stalls'][key]:,} | {selected['naive'][256]['node_stalls'][key]:,} |\n"
text += ('\nPending and current conflicts can occur together. The pending counter remains nonzero until all '
         'reserved write lanes reach their actual LMEM banks; it is broader than an exact same-address '
         'hazard check. These observations identify an internal-memory dependency limit that increasing '
         'external DMA response storage cannot directly remove.\n\n')
text += ('Improve must [copy accumulator slices to TMEM before external Output DMA](../../../hw/rtl/core/gemm/VX_gemm_fsm.sv:2322). '
         'Naive [stores an output macro tile from LMEM](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv:198). '
         'The differing paths and amount of output work already overlapped with computation explain why '
         'the residual Output tail need not favor improve.\n\n')
text += '## Evidence and scope\n\n'
text += ('All measured candidates passed `xrt-vcs-sim` using the configured-build wrapper, unchanged source '
         'manifests, and deterministic `tools/verify_rtl.py` checks. The FSM, arithmetic pipeline, Weight/PSUM '
         'capacities and layouts were fixed across the sweep. `VX_gpu_pkg.sv` now grows the relevant tag width '
         'with each backend\'s external slot override; default effective widths are preserved. No synthesis or '
         'reset microtests were used. The selected production profiles expand to exactly the tested macros; '
         'RTL and application hashes still match the selected runs after the two config edits. '
         'Improve depth8 reuses the prior N-fast captures; depths16/32 and all naive candidates were run freshly.\n\n')
text += ('Reproduction, accepted run manifests, FSDBs and strict-preedge analysis are under '
         '`agent-tasks/dma-read-slot-saturation/`. The active RAM bindings and tag constraints are documented in '
         '`audit.md`. Current GEMM/core comparisons are in [the cycle-only report](fpint_gemm_latency.md).\n')
text += '\n### Accepted waveform runs\n\n| Backend | Depth | M | Run directory |\n|---|---:|---:|---|\n'
for (backend, depth, m), d in sorted(records.items()):
    text += f"| {backend} | {depth} | {m} | `{d['run']}` |\n"
text += ('\nUse `python3 agent-tasks/dma-read-slot-saturation/analyze.py RUN --depth N --out CAPTURE` '
         'for each completed run, then `python3 agent-tasks/dma-read-slot-saturation/write_report.py '
         f'--improve-depth {args.improve_depth} --naive-depth {args.naive_depth}`. '
         'Raw FSDBs and transition caches are local ignored artifacts. Reproducers source frozen baseline '
         'profiles and add exactly one backend-specific depth override.\n')
text += '\nFor cycle-specific signal annotations and RTL explanations, see [the detailed review guide](fpint_gemm_annotated_explanation.md).\n'
(DOC / 'fpint_gemm_dma_slot_saturation.md').write_text(text)

text = '# FPINT GEMM cycle 비교: improve vs naive\n\n'
text += ('현재 RTL 기준, `xrt-vcs-sim`, TH16 / MXU16×16, K=N=512, micro-tile N-fast.\n'
         f'외부 DMA read slot: improve 채널당 {args.improve_depth}개, naive {args.naive_depth}개. '
         'Weight response slot은 양쪽 모두 8개, naive PSUM read/response slot은 16개.\n')
for title, key in [('GEMM cycles', 'gemm_cycles'), ('전체 커널 core cycles', 'core_cycles')]:
    text += f'\n## {title}\n\n| M | improve | naive | 차이 (naive − improve) | naive / improve | improve의 cycle 감소율 |\n|---:|---:|---:|---:|---:|---:|\n'
    for m in [4, 256]:
        i, n = selected['improve'][m][key], selected['naive'][m][key]
        text += f'| {m} | {i:,} | {n:,} | {n-i:,} | {n/i:.3f}× | {(n-i)/n*100:.2f}% |\n'
    if key == 'gemm_cycles':
        text += '\nGEMM cycles는 configuration 수락부터 최초 completion-valid까지의 구간이다.\n'
text += '\n감소율 = `(naive − improve) / naive × 100`.\n'
(DOC / 'fpint_gemm_latency.md').write_text(text)
print('Published reports for selected depths', args.improve_depth, args.naive_depth)
