import json
import subprocess
import sys
from pathlib import Path
folder = Path(__file__).resolve().parent
repo = folder.parents[2]
app = repo / 'tests/regression/llama_decoder_C4'
fixture = repo / 'build_c4_sram_fusion/fixtures/resident_attention/llama3-8b_decode_p16_c32'
commands = []
for backend in ('legacy', 'resident', 'resident-fp32'):
    commands.append(('cpu_' + backend, [sys.executable, str(app / 'reference.py'), 'compare', '--fixture', str(fixture), '--output', str(folder / ('decoder_' + backend))]))
for backend in ('resident', 'resident-fp32'):
    commands.append(('backend_' + backend, [sys.executable, str(app / 'compare_attention_backends.py'), '--legacy', str(folder / 'decoder_legacy'), '--resident', str(folder / ('decoder_' + backend))]))
results = []
for name, command in commands:
    with (folder / (name + '.log')).open('w') as output:
        rc = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=300).returncode
    results.append(dict(name=name, exit_code=rc))
    print(name, 'exit=' + str(rc), flush=True)
    (folder / 'decoder_comparisons.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(any(r['exit_code'] for r in results))
