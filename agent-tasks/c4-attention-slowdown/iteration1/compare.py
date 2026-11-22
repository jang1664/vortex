#!/usr/bin/env python3
"""Archive this iteration's matched hardware comparison and validation."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASK = HERE.parent
RUNS = TASK / 'runs/iteration1'
resident = json.loads((RUNS / 'resident/summary.json').read_text())
legacy = json.loads((RUNS / 'legacy/summary.json').read_text())
before = json.loads((TASK / 'measurements.json').read_text())['variants']['instrumented']
report = {
    'clock_mhz': 100,
    'metric': 'Attention core cycles: resident median versus sum of QK/softmax/PV medians, three samples each',
    'scope': 'Llama3-8B, batch 1, FP16 resident output, unchanged unified-MMIO FPGA image',
    'cases': {},
}
for case, current in resident.items():
    separate = legacy[case]
    assert current['kernel_sha256'] == separate['kernel_sha256']
    assert current['verification']['pass'] and separate['verification']['pass']
    boundaries = json.loads((RUNS / 'resident' / case / 'attention_backend_comparison.json').read_text())
    assert boundaries['pass_all']
    references = {
        backend: json.loads((RUNS / backend / case / 'intermediate_comparison.json').read_text())
        for backend in ['legacy', 'resident']
    }
    assert all(result['pass_all'] and result['complete_decoder'] for result in references.values())
    exact = {}
    for name in ['q_hadamard.bin', 'context.bin', 'output.bin']:
        a = (RUNS / 'resident' / case / name).read_bytes()
        b = (TASK / 'runs/instrumented' / case / name).read_bytes()
        exact[name] = a == b
    assert all(exact.values())
    old_cycles = before[case]['median_cycles']['cycles']
    new_cycles = current['median']['cycles']
    separate_cycles = separate['median']['cycles']
    report['cases'][case] = {
        'before_flash_cycles': old_cycles,
        'flash_cycles': new_cycles,
        'separate_sum_cycles': separate_cycles,
        'flash_time_reduction_percent': 100 * (1 - new_cycles / old_cycles),
        'flash_over_separate': new_cycles / separate_cycles,
        'before_phase_cycles': before[case]['median_cycles'],
        'after_phase_cycles': current['median'],
        'legacy_operation_medians': separate['operation_medians'],
        'resident_samples': current['samples'],
        'legacy_samples': separate['samples'],
        'kernel_sha256': current['kernel_sha256'],
        'output_sha256': current['output_sha256'],
        'context_sha256': hashlib.sha256((RUNS / 'resident' / case / 'context.bin').read_bytes()).hexdigest(),
        'same_as_before': exact,
        'cpu_reference_pass': {backend: result['pass_all'] for backend, result in references.items()},
        'backend_comparison': boundaries,
    }
checks = {}
for name in ['legacy_single', 'fp16_multitile', 'fp32_multitile', 'fp16_mask_tail', 'fp32_mask_tail']:
    log = RUNS / 'validation' / (name + '.log')
    lines = log.read_text().splitlines()
    assert 'PASSED' in lines, name
    checks[name] = {
        'passed': True,
        'log': str(log.relative_to(TASK)),
        'evidence': [line for line in lines if any(word in line for word in
                    ['max_abs', 'max_rel', 'attention_cycles', 'PASSED', 'FP32 output', 'error='])],
    }
(HERE / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
(HERE / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
for case, result in report['cases'].items():
    print(case, f"{result['flash_cycles'] / 100000:.5f} ms vs "
          f"{result['separate_sum_cycles'] / 100000:.5f} ms; "
          f"{result['flash_over_separate']:.2f}x; "
          f"time reduction {result['flash_time_reduction_percent']:.1f}%")
