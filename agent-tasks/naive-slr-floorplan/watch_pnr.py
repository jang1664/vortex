#!/usr/bin/env python3
"""Print bounded progress from an archived wrapper run and its Vivado log."""
import json,sys
from pathlib import Path
run=Path(__file__).resolve().parent/'runs'/(sys.argv[1] if len(sys.argv)>1 else 'naive_slr_100m_v4')
state=json.loads((run/'state.json').read_text())
print('state:',state['state'],state.get('returncode',''))
physical=Path(state['physical_output'])
for label,path in [('wrapper',run/'wrapper.log'),('implementation',physical/'_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log')]:
 if not path.exists():continue
 with path.open('rb') as f:
  f.seek(max(0,path.stat().st_size-16384));lines=f.read().decode(errors='replace').splitlines()
 lines=[line for line in lines if line.strip()]
 print(label+':')
 for line in lines[-3:]:print(line[:900])
