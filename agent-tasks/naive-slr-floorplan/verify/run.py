#!/usr/bin/env python3
"""Run frozen-source SLR regressions and validate deterministic pass/fault markers."""
import importlib.util, json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
source = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('baseline', ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.ROOT = source
out = Path(sys.argv[sys.argv.index('--output') + 1]).resolve()
rc = runner.main()
spec = importlib.util.spec_from_file_location('verify_rtl', ROOT / 'tools/verify_rtl.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
manifest = json.loads((out/'manifest.json').read_text())
wrapper = (out/'wrapper.log').read_text(errors='replace')
simv = (out/'simv.log').read_text(errors='replace') if (out/'simv.log').exists() else ''
combined = wrapper + '\n' + simv
gemm = [int(x) for x in re.findall(r'^GEMM_LATENCY_DONE .*?\bL_gemm=(\d+)', simv, re.M)]
core = [int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),', wrapper, re.M)]
result = dict(runner_returncode=rc, wrapper_returncode=manifest['returncode'], tool_pass=verify.check_pass(combined), strict_failure=verify.has_strict_failure(combined), source_changes=manifest['source_changes_during_run'], gemm_cycles=gemm, core_cycles=core)
result['passed'] = rc == 0 and result['tool_pass'] and not result['strict_failure'] and not result['source_changes'] and len(gemm) == manifest['repeat'] and len(core) == 1
if not result['passed']: result['errors'] = verify.extract_errors(combined)
(out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result), flush=True)
sys.exit(0 if result['passed'] else 1)
