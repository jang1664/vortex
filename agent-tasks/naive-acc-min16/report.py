"""Collect only completed minimum-16 comparisons and verify default cycle identity."""
import json
import re
import shlex
from pathlib import Path

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
RUNS = ROOT / 'agent-tasks/naive-acc-select/runs'
topologies = ['l16_bw64', 'l32_bw64', 'l32_bw256']
references = dict(l16_bw64='on_l16_bw64', l32_bw64='on_l32_bw64', l32_bw256='on')
results = []
for profile in ['current', 'min16', 'fifo4']:
    for topology in topologies:
        for case in ['m4', 'm256']:
            run = RUNS / f'min16_compare_{profile}_{topology}' / case
            result = json.loads((run / 'result.json').read_text())
            assert result['passed'] and result['source_changes'] == []
            util = re.findall(r'^PERF: input\s+([\d.]+)%', (run / 'wrapper.log').read_text(), re.M)
            assert len(util) == 1
            result['input_util_percent'] = float(util[0])
            result.update(profile=profile, topology=topology, evidence=str(run.relative_to(ROOT)))
            if profile == 'current':
                prior = json.loads((RUNS / references[topology] / case / 'result.json').read_text())
                assert prior['passed']
                for metric in ['gemm_cycles', 'core_cycles']:
                    assert result[metric] == prior[metric], (topology, case, metric)
            if profile == 'fifo4':
                prior = next(r for r in results if r['profile'] == 'min16' and r['topology'] == topology and r['case'] == case)
                old_flags, new_flags = set(shlex.split(prior['configs'])), set(shlex.split(result['configs']))
                assert old_flags - new_flags == {'-DGEMM_NAIVE_INPUT_LANE_FIFO_DEPTH=16', '-DGEMM_NAIVE_QPARAM_LANE_FIFO_DEPTH=16'}
                assert new_flags - old_flags == {'-DGEMM_NAIVE_INPUT_LANE_FIFO_DEPTH=4', '-DGEMM_NAIVE_QPARAM_LANE_FIFO_DEPTH=4'}
            results.append(result)
improve = []
for case in ['m4', 'm256']:
    run = RUNS / 'min16_compare_improve' / case
    result = json.loads((run / 'result.json').read_text())
    prior = json.loads((RUNS / 'improve' / case / 'result.json').read_text())
    assert result['passed'] and result['source_changes'] == [] and prior['passed']
    for metric in ['gemm_cycles', 'core_cycles']:
        assert result[metric] == prior[metric], (case, metric)
    result['evidence'] = str(run.relative_to(ROOT))
    improve.append(result)
identity = json.loads((TASK / 'identity/result.json').read_text())
assert len(identity) == 1144 and all(r['identical'] for r in identity)
units = json.loads((TASK / 'verification/unit_summary.json').read_text())
assert units['passed'] and all(r['status'] == 'pass' for r in units['runs'])
capacities = json.loads((TASK / 'verification/elaborated_capacity_audit.json').read_text())
assert len(capacities['profiles']) == 3 and all(p['passed'] for p in capacities['profiles'])
summary = dict(runs=results, improve=improve, improve_rtl_identity_checks=len(identity),
               default_gemm_core_cycle_delta=0, improve_gemm_core_cycle_delta=0,
               unit_tests=units, elaborated_capacities=capacities)
fifo4_audit = json.loads((TASK / 'verification/fifo4_config_audit.json').read_text())
assert len(fifo4_audit) == 3 and all(r['passed'] for r in fifo4_audit)
summary['fifo4_config_audit'] = fifo4_audit
fifo4_capacities = json.loads((TASK / 'verification/fifo4_elaborated_capacity_audit.json').read_text())
assert len(fifo4_capacities['profiles']) == 3 and all(p['passed'] for p in fifo4_capacities['profiles'])
summary['fifo4_elaborated_capacities'] = fifo4_capacities
(TASK / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
lines = ['# Naive ACC current vs minimum-16 buffering', '',
         'TH16, MXU16, K=N512, q32, qdir0, transpose0, repeat1, xrt-vcs-sim. All runs passed numerical checks without source changes during execution.', '',
         'Current means the three named `_acc.sh` configs, including BUF8 for BW256. It is not the per-workload best point from previous sweeps.', '',
         '| Profile capacity | Current | Minimum16 |', '|---|---:|---:|',
         '| External DMA outstanding | 32 | 32 |', '| Splitter depth | 8 | 16 |',
         '| Weight response slots | 8 | 16 |', '| ACC output DMA slots | 16 | 16 |',
         '| Input response slots / lane FIFO | 16 / 8 | 16 / 16 |',
         '| Scale and zero response slots / lane FIFO, each | 8 / 4 | 16 / 16 |', '',
         'BW64 has no cache splitter; its splitter depth affects LMEM only. Cache internals, command queues, skids and ACC capacity are unchanged.', '',
         '| Topology | M | Current GEMM | Minimum16 GEMM | GEMM change | Current core | Minimum16 core | Core change |',
         '|---|---:|---:|---:|---:|---:|---:|---:|']
for topology in topologies:
    for case in ['m4', 'm256']:
        rows = {p: next(r for r in results if r['profile'] == p and r['topology'] == topology and r['case'] == case)
                for p in ['current', 'min16']}
        a, b = rows['current'], rows['min16']
        ga, gb, ca, cb = a['gemm_cycles'][0], b['gemm_cycles'][0], a['core_cycles'][0], b['core_cycles'][0]
        lines.append(f'| {topology} | {case[1:]} | {ga:,} | {gb:,} | {(gb/ga-1)*100:+.2f}% | {ca:,} | {cb:,} | {(cb/ca-1)*100:+.2f}% |')
lines += ['', f"All {units['pass_count']} final unit checks passed. All six current-profile runs reproduce their prior GEMM/core cycles exactly. Improve M4/M256 also reproduce prior cycles exactly; all1,144 selected-RTL comparisons pass. No synthesis was run.", '',
          'This is one combined minimum-capacity experiment, not an independent sweep of each parameter. Numerical correctness, unit coverage and final status are recorded in STATUS.yaml and verification/.', '']
lines += ['## Follow-up: 16 response slots with lane FIFO4', '',
          'Only input/scale/zero lane response FIFO depth changes from16 to4. These FIFOs precede tag-indexed OOO response RAM; the output holding stage is unchanged. All slot settings retain the minimum16 profile (external DMA32, other scoped slots16). No RTL changes were needed for this follow-up.', '',
          '| Topology | M | FIFO16 GEMM | FIFO4 GEMM | GEMM change | FIFO16 core | FIFO4 core | Core change |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
for topology in topologies:
    for case in ['m4', 'm256']:
        a, b = [next(r for r in results if r['profile'] == p and r['topology'] == topology and r['case'] == case)
                for p in ['min16', 'fifo4']]
        ga, gb, ca, cb = a['gemm_cycles'][0], b['gemm_cycles'][0], a['core_cycles'][0], b['core_cycles'][0]
        lines.append(f'| {topology} | {case[1:]} | {ga:,} | {gb:,} | {(gb/ga-1)*100:+.2f}% | {ca:,} | {cb:,} | {(cb/ca-1)*100:+.2f}% |')
lines += ['', 'All six FIFO4 runs passed numerical verification with no source changes during execution. Config audits verify that only the two lane-FIFO depth defines differ from minimum16. The completed FIFO4 M4 waveforms pass all58 capacity checks, confirming FIFO4 and retained slot capacities. The unit and improve controls above belong to the preceding RTL implementation experiment and were not rerun for this config-only follow-up.', '']
(TASK / 'results.md').write_text('\n'.join(lines))
print('18 naive comparisons + 2 improve controls PASS; default/improve cycle delta zero')
