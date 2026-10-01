#!/usr/bin/env python3
"""Compile exact preprocessed production/derived wrapper snapshots for unit test."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

build=Path.cwd()
m=json.loads((build/'test_manifest.json').read_text())
cmd=m['compile_command']
fingerprint=hashlib.sha256(json.dumps(cmd).encode())
for p in m['compilation_sources']:
    fingerprint.update(Path(p).read_bytes())
key=fingerprint.hexdigest()
cache=build/'compile.sha256'
if cache.exists() and cache.read_text()==key and (build/'obj_dir/Vtb_ablation').exists():
    print('Exact test source/command fingerprint unchanged; reuse compiled executable')
    sys.exit(0)
(build/'logs').mkdir(exist_ok=True)
with (build/'logs/compile.log').open('w') as log:
    env=dict(os.environ,CC='/usr/bin/gcc',CXX='/usr/bin/g++')
    result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,env=env)
if result.returncode:
    print((build/'logs/compile.log').read_text()[-10000:])
    sys.exit(result.returncode)
cache.write_text(key)
print('Compilation completed')
