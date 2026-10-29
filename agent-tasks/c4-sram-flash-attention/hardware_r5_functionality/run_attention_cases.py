import json
import subprocess
from pathlib import Path
folder = Path(__file__).resolve().parent
cases = [
    ('fp16_single', '-r -m 1 -n 128'),
    ('fp16_multitile', '-r -m 4 -n 256'),
    ('fp16_tail', '-r -m 16 -n 257'),
    ('fp32_tail', '-r -f -m 16 -n 257'),
    ('fp32_causal_mask', '-r -f -m 16 -n 384 -c -p 0'),
    ('fp32_full_rows', '-r -f -m 128 -n 256'),
    ('fp32_qk_overflow', '-r -f -m 1 -n 128 -s qk-overflow'),
    ('fp32_pv_overflow', '-r -f -m 1 -n 128 -s pv-overflow'),
    ('legacy_single', '-m 4 -n 128'),
]
results = []
for name, args in cases:
    print('START', name, args, flush=True)
    rc = subprocess.run(['bash', str(folder / 'run_case.sh'), name, 'flash_attn', args]).returncode
    results.append(dict(name=name, args=args, exit_code=rc))
    (folder / 'attention_cases.json').write_text(json.dumps(results, indent=2) + '\n')
    if rc:
        raise SystemExit(rc)
print('ALL_ATTENTION_CASES_PASS', flush=True)
