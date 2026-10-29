import json
import subprocess
from pathlib import Path
folder = Path(__file__).resolve().parent
repo = folder.parents[2]
fixture = repo / 'build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p16_c32'
results = []
for backend in ('legacy', 'resident', 'resident-fp32'):
    name = 'decoder_' + backend
    output = folder / name
    args = f'--model llama3-8b --batch 1 --seq-len 1 --stage decode --past-kv-len 16 --cache-capacity 32 --mode verify --attention-backend {backend} --fixture {fixture} --output {output}'
    print('START', name, flush=True)
    rc = subprocess.run(['bash', str(folder / 'run_case.sh'), name, 'llama_decoder_C4', args]).returncode
    results.append(dict(name=name, args=args, exit_code=rc))
    (folder / 'decoder_cases.json').write_text(json.dumps(results, indent=2) + '\n')
    if rc:
        raise SystemExit(rc)
print('ALL_DECODER_DEVICE_CASES_PASS', flush=True)
