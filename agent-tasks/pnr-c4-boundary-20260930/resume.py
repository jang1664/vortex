#!/usr/bin/env python3
"""Resume only C4 after recorded source and DCP validation."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

TASK = Path(__file__).resolve().parent
REPO = TASK.parents[1]
manifest = json.loads((TASK / 'manifest.json').read_text())
verification = json.loads((REPO / manifest['validation_evidence']).read_text())
assert verification['passed'] is True
assert len(manifest['runs']) == 1
run = manifest['runs'][0]
assert run['config'] == 'th32_c1_improve_m32_tcol32'
output = Path(run['output'])
source = REPO / 'hw/syn/xilinx/xrt'
for relative, digest in verification['source_sha256'].items():
    assert hashlib.sha256((REPO / relative).read_bytes()).hexdigest() == digest, relative
assert (TASK / 'previous-attempt/impl_1/level0_wrapper_opt.dcp').is_file()
checkpoint = output / '_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_opt.dcp'
assert checkpoint.is_file()
assert not (TASK / 'status.json').exists(), 'Resume already started'
for name in ['mxu_slr_floorplan.tcl', 'post_opt_hook.tcl', 'post_place_hook.tcl']:
    shutil.copy2(source / name, output / 'xrt_backup' / name)
manifest['source_sha256'] = verification['source_sha256']
manifest['runtime_sha256'] = {
    name: hashlib.sha256((output / 'xrt_backup' / name).read_bytes()).hexdigest()
    for name in ['mxu_slr_floorplan.tcl', 'post_opt_hook.tcl', 'post_place_hook.tcl']}
manifest['pending_validation'] = False
(TASK / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
session = 'pnr_c4_boundary_20260930'
command = 'exec python3 ' + shlex.quote(str(TASK / 'monitor.py')) + ' >> ' + shlex.quote(str(TASK / 'monitor.log')) + ' 2>&1'
argv = ['tmux', 'new-session', '-d', '-s', session]
for key in ['AUTOMATE_SECRET', 'AUTOMATE_TO']:
    if key in os.environ:
        argv.extend(['-e', key + '=' + os.environ[key]])
argv.append(command)
subprocess.run(argv, check=True)
print('Started C4 monitor in tmux session:', session)
