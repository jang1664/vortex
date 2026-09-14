#!/usr/bin/env python3
"""Publish only complete, numerically verified ACC comparison results."""
import hashlib
import json
from pathlib import Path
import subprocess

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
expected = [(mode, case) for mode in ['on', 'off', 'improve'] for case in ['m4', 'm256']]
expected += [('on_edges', case) for case in ['m1', 'm3_tail', 'n150', 'qrow', 'transpose', 'qrow_transpose']]
results = []
for label, case in expected:
    run = TASK / 'runs' / label / case
    result = json.loads((run / 'result.json').read_text())
    assert result['passed'] and result['source_changes'] == [], (label, case)
    if (run / 'analysis.json').exists():
        result['waveform'] = json.loads((run / 'analysis.json').read_text())
    result['evidence'] = str(run.relative_to(ROOT))
    results.append(result)

prior = json.loads((TASK / 'baseline.json').read_text())['reference_cycles']
baseline_checks = []
for mode in ['off', 'improve']:
    for case in ['m4', 'm256']:
        old = prior[mode][case]
        new = next(r for r in results if r['mode'] == mode and r['case'] == case)
        assert old['passed']
        for metric in ['gemm_cycles', 'core_cycles']:
            assert old[metric] == new[metric], (mode, case, metric)
        baseline_checks.append(dict(mode=mode, case=case, gemm_delta=0, core_delta=0))

unit_names = ['gemm_unit_v2_corrected2_on', 'gemm_unit_v2_corrected2_off',
              'gemm_unit_v2_corrected2_improve', 'gemm_unit_v2_backpressure', 'lmem_dma32']
units = {name: json.loads((TASK / 'verification' / f'{name}.json').read_text()) for name in unit_names}
assert all(r['status'] == 'pass' for r in units.values())
identity = json.loads((TASK / 'identity/result.json').read_text())
assert all(r['identical'] for r in identity['checks'])
common = {}
for name in ['VX_gemm_acc_internal.sv', 'VX_gemm_compute_core.sv', 'VX_lmem_dma_misal.sv']:
    path = 'hw/rtl/core/gemm/' + name
    old = subprocess.check_output(['git', 'show', f"{identity['baseline']}:{path}"], cwd=ROOT)
    new = (ROOT / path).read_bytes()
    assert old == new, path
    common[path] = hashlib.sha256(new).hexdigest()
for mode in ['on', 'off']:
    for case in ['m4', 'm256']:
        match = next(r for r in results if r['mode'] == mode and r['case'] == case)
        assert 'waveform' in match, (mode, case)

summary = dict(baseline=identity['baseline'], runs=results, unit_tests=units,
               baseline_cycle_checks=baseline_checks, unchanged_common_rtl=common,
               selected_rtl_checks=len(identity['checks']))
(TASK / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
lines = ['# ACC selection results', '',
         'All listed runs passed numerical checks with no RTL/config/app source changes during execution.', '',
         'Baseline: L32 D256 all_bram, MXU16, K=N512, q32, transpose=0, qdir=0, repeat=1. Only ACC selection differs between naive ON and OFF.', '',
         '| M | OFF GEMM | ON GEMM | OFF core | ON core | Core delta |',
         '|---|---:|---:|---:|---:|---:|']
for case in ['m4', 'm256']:
    off = next(r for r in results if r['mode'] == 'off' and r['case'] == case)
    on = next(r for r in results if r['mode'] == 'on' and r['case'] == case)
    delta = 100 * (on['core_cycles'][0] / off['core_cycles'][0] - 1)
    lines.append(f"| {case[1:]} | {off['gemm_cycles'][0]:,} | {on['gemm_cycles'][0]:,} | {off['core_cycles'][0]:,} | {on['core_cycles'][0]:,} | {delta:+.2f}% |")
lines += ['', 'The explicit ACC-to-LMEM output copy is part of the ON measurement. There is no claim that removing PSUM LMEM traffic must reduce total cycles.', '',
          '| M | OFF PSUM reads/writes | ON PSUM reads/writes | ON ACC writes | ON copy + drain cycles | ON output LMEM stall cycles |',
          '|---|---:|---:|---:|---:|---:|']
for case in ['m4', 'm256']:
    off = next(r['waveform'] for r in results if r['mode'] == 'off' and r['case'] == case)
    on = next(r['waveform'] for r in results if r['mode'] == 'on' and r['case'] == case)
    lines.append(f"| {case[1:]} | {off['psum_lmem_reads']:,}/{off['psum_lmem_writes']:,} | {on['psum_lmem_reads']}/{on['psum_lmem_writes']} | {on['acc_writes']:,} | {on['copy_and_drain_cycles']:,} | {on['final_lmem_stall_cycles']:,} |")
lines += ['', 'PSUM counts are wide requests, 64 bytes each for MXU16. Waveform checks prove final ACC writes = ACC output reads = final LMEM writes, and every output STORE allocation follows local DMA completion and physical LMEM write drain.', '',
          '## Additional correctness coverage', '', '| Case | GEMM cycles | Core cycles |', '|---|---:|---:|']
for result in results:
    if 'on_edges' in result['evidence']:
        lines.append(f"| {result['case']} | {result['gemm_cycles'][0]:,} | {result['core_cycles'][0]:,} |")
lines += ['', 'Exact workload tuples are defined in `run.py`. All five final unit checks passed. Existing DMA tests cover reorder/backpressure; blackbox output tests cover unequal source/destination strides.', '',
          '## Preservation', '',
          'Naive OFF and improve reproduce both historical M4/M256 GEMM and core cycles exactly. All 12 edited-translation-unit preprocessing comparisons pass (OFF/improve, debug/NDEBUG). All other RTL is unchanged; internal ACC, common compute and DMA wrapper SHA256 values are recorded in `results.json`.', '',
          'No synthesis was run. HBM timings are from the existing simulation model.', '']
(TASK / 'results.md').write_text('\n'.join(lines))
print(f'{len(results)} blackbox runs, {len(units)} unit checks and {len(identity["checks"])} RTL identity checks passed')
