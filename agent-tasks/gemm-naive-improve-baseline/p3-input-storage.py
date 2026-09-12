#!/usr/bin/env python3
"""Static Input executor declaration ledger; no simulation or synthesis."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import xml.etree.ElementTree as ET

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
spec = importlib.util.spec_from_file_location('inventory', TASK/'p2-qparam-storage.py')
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)
BUILD = ROOT/'build_p0_storage_rev3'
assert (BUILD/'config.mk').exists()
config = subprocess.check_output(['bash','-c', 'source configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
for mxu in (16,32):
    defines = [x for x in shlex.split(config) if not any(x.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
    defines += [f'-D{k}={mxu}' for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS')]
    xml = BUILD/f'p3-input-storage{mxu}.xml'
    command = ['verilator','--xml-only','--xml-output',str(xml),'--top-module','p3_input_storage_probe','-Wno-fatal','-DSYNTHESIS','-DNDEBUG','-DXLEN_64',*defines,
        '+incdir+'+str(ROOT/'hw/rtl'),'+incdir+'+str(ROOT/'hw/rtl/core/gemm')]
    for directory in ('libs','core/gemm','mem'): command += ['-y',str(ROOT/'hw/rtl'/directory)]
    command += [str(ROOT/'hw/rtl/VX_gpu_pkg.sv'),str(TASK/'p3-input-storage-probe.sv')]
    with (BUILD/f'p3-input-storage{mxu}.log').open('w') as log:
        subprocess.run(command,cwd=BUILD,stdout=log,stderr=subprocess.STDOUT,check=True)
    rows = ledger.inventory(xml)
    totals = {key:sum(row[key] for row in rows) for key in ('bits','payload_bits','metadata_bits')}
    assert totals['payload_bits'] == 832*8*(mxu//16),totals
    files = {x.get('filename') for x in ET.parse(xml).getroot().find('files') if str(ROOT/'hw/rtl') in x.get('filename','')}
    report = dict(status='pass',mxu=mxu,totals=totals,records=rows,command=command,
        source_hashes={f:ledger.sha(f) for f in files},xml_sha256=ledger.sha(xml),
        script_sha256=ledger.sha(__file__),probe_sha256=ledger.sha(TASK/'p3-input-storage-probe.sv'),
        scope='Full Input executor sequential declarations, including one context array; not mapped resources')
    (TASK/f'p3-input-storage{mxu}.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(mxu=mxu,**totals)),flush=True)
