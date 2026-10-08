#!/usr/bin/env python3
"""Collect an orphaned run after the controller is lost; never rerun it."""
import datetime,json,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[5]
OUT=Path(__file__).resolve().parents[1]
for candidate in ['c3','c4']:
    status=OUT/f'raw/{candidate}_llama2_ffn_decode.json'
    rec=json.loads(status.read_text())
    if rec['status']!='running':continue
    build=ROOT/f'build_latency_perf_{candidate}_rev6'
    active=False
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():continue
        try:
            cwd=(entry/'cwd').resolve()
            cmd=(entry/'cmdline').read_bytes().split(b'\0')
        except OSError:continue
        if build in [cwd,*cwd.parents] and cmd and (cmd[0]==b'timeout' or cmd[0].endswith(b'/simv') or cmd[0]==b'./simv'):
            active=True;break
    if active:continue
    log=OUT/f'raw/{candidate}_llama2_ffn_decode.log'
    passed=any(line.strip()=='PASSED' for line in log.open())
    sim=build/'sim/xrtsim_vcs/simv.log'
    normal=False
    with sim.open() as stream:
        for line in stream:
            if '[TB] Received SHUTDOWN command' in line:normal=True
    rec['status']='passed' if passed and normal else 'failed'
    rec['returncode']=None
    rec['completion_evidence']='Recovered after daemon restart: original controller exit status unavailable; reference PASSED and normal simulator SHUTDOWN checked.'
    rec['elapsed_seconds']=(datetime.datetime.now()-datetime.datetime.fromisoformat(rec['started'])).total_seconds()
    rec['elapsed_seconds_note']='Approximate collection time; controller lost, does not affect measured RTL cycle metrics.'
    for source,suffix in [('simv.log','simv.log'),('u55c_model_manifest.json','model.json')]:
        shutil.copy2(build/'sim/xrtsim_vcs'/source,OUT/f'raw/{candidate}_llama2_ffn_decode.{suffix}')
    status.write_text(json.dumps(rec,indent=2))
    print('Recovered',candidate,rec['status'])
