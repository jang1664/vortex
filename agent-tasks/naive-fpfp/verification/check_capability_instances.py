#!/usr/bin/env python3
"""Check active instance sites after preprocessing the naive node and compute core."""
import json
from pathlib import Path
import re
import shlex
import subprocess

repo = Path(__file__).resolve().parents[3]
rtl = repo / 'hw/rtl'
sources = [rtl / 'core/gemm' / name for name in ('VX_gemm_node_naive.sv', 'VX_gemm_compute_core.sv')]
patterns = {
    'fp16_front': r'\bVX_gemm_fpfp_front\s*#',
    'fpint_tree': r'\bVX_gemm_tree_v\d+\s*(?:#|u_mxu)',
    'prealigner': r'\bVX_prealigner\s*#',
    'pint_converter': r'\bVX_pint2fp\s*#',
    'input_scaler': r'\)\s*u_in_scaler\s*\(',
    'output_scaler': r'\)\s*u_out_scaler\s*\(',
    'qparam_pair': r'\bVX_naive_qparam_pair\s*#',
    'int4_weight_executor': r'\)\s*weight_executor\s*\(',
    'fp16_weight_executor': r'\)\s*fp16_weight_executor\s*\(',
}
rows = []
for build_name, fpint, fpfp in [('build_fpfp_wload4', False, True),
                               ('build_fpfp_naive_before', True, False),
                               ('build_fpfp_dual', True, True)]:
    build = repo / build_name
    config = subprocess.check_output(['bash', '-c', 'source ./config.sh; printf "%s" "$CONFIGS"'], cwd=build, text=True)
    command = ['verilator', '-E', '-P', '-Wno-fatal'] + shlex.split(config)
    command += ['-D' + x for x in ('SIMULATION', 'SV_DPI', 'VCS', 'NOXRT', 'XLEN_64', 'NDEBUG', 'PERF_ENABLE')]
    command += ['-I' + str(x) for x in [rtl, rtl / 'libs', rtl / 'core/gemm', rtl / 'fpu', repo / 'hw/dpi']]
    result = subprocess.run(command + [str(x) for x in sources], capture_output=True, text=True)
    (build / 'selected_node_core.sv').write_text(result.stdout)
    checks = {}
    for name, pattern in patterns.items():
        actual = bool(re.search(pattern, result.stdout))
        expected = fpfp if name.startswith('fp16_') else fpint
        checks[name] = {'present': actual, 'expected': expected, 'pass': actual == expected}
    rows.append({'build': build_name, 'status': 'pass' if result.returncode == 0 and all(x['pass'] for x in checks.values()) else 'fail',
                 'preprocessor_returncode': result.returncode, 'checks': checks})
report = {'status': 'pass' if all(x['status'] == 'pass' for x in rows) else 'fail',
          'method': 'Instance sites in preprocessed VX_gemm_node_naive and VX_gemm_compute_core, not module definitions or synthesis.',
          'configurations': rows}
Path(__file__).with_name('capability_instances.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['status'] == 'pass' else 1)
