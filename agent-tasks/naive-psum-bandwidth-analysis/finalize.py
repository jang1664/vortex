"""Check capture provenance and window consistency, then publish the report."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
checks=json.loads((TASK/'captures/validation.json').read_text())
assert len(checks)==2 and all(x['passed'] and not x['strict_failure'] for x in checks)
for m,cycles in [(4,19981),(256,675484)]:
    manifest=json.loads((TASK/'runs'/f'naive-m{m}'/'manifest.json').read_text())
    changed=[p for p,h in manifest['source_hashes'].items()
             if not (ROOT/p).is_file() or hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h]
    assert not changed,changed
    result=json.loads((TASK/'captures'/f'naive{m}'/'result.json').read_text())
    assert result['cycles']==cycles and result['counts']['input_fire']==m*1024
    assert not result['missing']

samples=np.load(TASK/'captures/naive256/samples.npz')
memory=np.load(TASK/'captures/naive256/memory/samples.npz')
window=np.load(TASK/'captures/naive256/physical/samples.npz')
start=50000;end=start+4096
for full_key,window_key in [('input_fire','compute_input_fire'),('psum_rd_order_block','psum_rd_order_block')]:
    np.testing.assert_array_equal(samples[full_key][start:end],window[window_key])
np.testing.assert_array_equal(memory['per_bank_req_valid'][start:end],window['per_bank_req_valid'])
np.testing.assert_array_equal(
    memory['per_bank_req_valid'][start:end] & memory['per_bank_req_ready'][start:end],
    window['per_bank_req_valid'] & window['per_bank_req_ready'])

waves={
    'naive4':TASK/'runs/naive-m4/wave.fsdb',
    'naive256':TASK/'runs/naive-m256/wave.fsdb',
    'improve4':ROOT/'agent-tasks/gemm-naive-improve-baseline/p4-candidate/improve-m4-iteration1/wave.fsdb',
    'improve256':ROOT/'agent-tasks/gemm-naive-improve-baseline/p4-candidate/improve-m256-iteration1/wave.fsdb',
}
provenance={}
for name,path in waves.items():
    with path.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    provenance[name]=dict(path=str(path.relative_to(ROOT)),sha256=digest,size=path.stat().st_size)
(TASK/'captures/final-provenance.json').write_text(json.dumps(dict(waves=provenance,window_consistent=True,source_hashes_match=True),indent=2)+'\n')
subprocess.run([sys.executable,str(TASK/'write_report.py')],cwd=ROOT,check=True)
historical=ROOT/'docs/hw_analysis/improve_vs_naive/fpint_gemm_m4_m256_gap_analysis.md'
old=historical.read_text()
note='> Historical analysis of the implementation before mandatory PSUM prefetch. For the current slot32 RTL, see [post-prefetch bandwidth attribution](fpint_gemm_post_prefetch_bandwidth.md).\n\n'
if note not in old:
    title,body=old.split('\n\n',1)
    historical.write_text(title+'\n\n'+note+body)
status=TASK/'STATUS.yaml'
text=status.read_text().replace('state: running','state: complete',1)
text+=f"  - timestamp: '{datetime.now():%Y-%m-%d %H:%M}'\n    event: Both fresh captures PASS and reproduce slot32 cycles. Full-trace analysis, source hashes, and cached-window consistency checks completed. Published fpint_gemm_post_prefetch_bandwidth.md; RTL and cycle-only comparison document unchanged.\n"
status.write_text(text)
print('Finalized analysis and report',flush=True)
