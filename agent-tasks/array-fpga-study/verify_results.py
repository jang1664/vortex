#!/usr/bin/env python3
"""Check saved reports, arithmetic, IP settings, and non-overlapping partitions."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import tempfile
from resources import KEYS, add, hierarchy, sha
from collect_native import breakdown
p=argparse.ArgumentParser();p.add_argument('results',type=Path,nargs='?',default=Path(__file__).parent/'results');a=p.parse_args();root=a.results
read=lambda n:json.loads((root/n).read_text())
for item in read('archive.json'): assert sha(root/item['file'])==item['sha256'],item['file']
rows=read('engine_resources.json');assert [r['engine'] for r in rows]==['fp_tcu_native','woq_derived_native','wkv_native']
parts=read('engine_breakdown.json')
labels={'LUT':'CLB LUTs*','FF':'CLB Registers','DSP':'DSPs','BRAM36eq':'Block RAM Tile','URAM':'URAM'}
for r in rows:
    path=root/'reports'/r['engine']
    counts=hierarchy(path/'hierarchy.rpt')[0]['counts']
    assert {k:r[k] for k in KEYS}==counts
    text=(path/'utilization.rpt').read_text()
    assert 'Design State : Optimized' in text
    for k,label in labels.items():
        m=re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([\d,.]+)',text,re.M)
        assert m and float(m[1].replace(',',''))==r[k],(r['engine'],k)
    assert json.loads((path/'status.json').read_text())['success']
    assert json.loads((path/'summary.json').read_text())['blackboxes']==0
    timing=(path/'timing_post_opt.rpt').read_text()
    assert 'checking no_clock (0)' in timing and 'checking unconstrained_internal_endpoints (0)' in timing
    assert '-period 10.000' in (path/'clock.xdc').read_text()
    gops=2*r['MAC_per_cycle']*r['reference_MHz']/1000
    for actual,want in [(r['nominal_GOPS'],gops),(r['GOPS_per_kLUT'],gops*1000/r['LUT']),(r['GOPS_per_DSP'],gops/r['DSP'])]:assert math.isclose(actual,want)
    assert r['BRAM36eq']==r['RAMB36']+r['RAMB18']/2
    if r['engine'] in parts:
        assert parts[r['engine']]==breakdown(path/'hierarchy.rpt')
        assert add(parts[r['engine']])==counts
with (root/'engine_resources.csv').open() as f:assert list(csv.DictReader(f))==[{k:str(v) for k,v in r.items()} for r in rows]
w,q=rows[2],rows[1];over=read('overhead.json')
for k in (*KEYS,'BRAM36eq'):
    assert over['WKV_minus_WoQ'][k]==w[k]-q[k]
    assert over['percent_over_WoQ'][k]==(100*(w[k]-q[k])/q[k] if q[k] else None)
assert w['internal_ACC_KiB']==q['internal_ACC_KiB']==256
assert (w['RAMB36'],w['RAMB18'],w['URAM'])==(q['RAMB36'],q['RAMB18'],q['URAM'])
ips=read('ip_parameters.json')
for name,ip in ips['wkv_native'].items():
    assert ip['parameters']==ips['woq_derived_native'][name]['parameters']
    assert ip['parameters']['C_Latency']==ip['parameters']['C_Rate']=='1'
assert read('verification/rtl.json')['status']=='pass'
assert read('verification/vendor_ip.json')['status']=='pass'
log=(root/'verification/rtl_sim.log').read_text()
for seed in (1234,2027,91):assert re.search(r'TEST PASSED seed='+str(seed)+r' compared_cycles=\d+ checked_lanes=576 low_ready_responses=4',log)
c4=read('c4_resources.json')
for r in c4['reports']:assert sha(root/r['archived'])==r['sha256']
assert add(c4['groups'])==c4['accelerator']
assert add([c4['accelerator'],c4['shell_and_other']])==c4['device_design_total']
assert hierarchy(root/'reports/c4/hier_utilization.rpt')[0]['counts']==c4['device_design_total']
for g in c4['groups']:
    for k in KEYS:assert math.isclose(g['percent_of_accelerator'][k],100*g[k]/c4['accelerator'][k])
with (root/'c4_resources.csv').open() as f:
    columns=['component',*KEYS,'BRAM36eq']
    assert list(csv.DictReader(f))==[{k:str(g[k]) for k in columns} for g in c4['groups']]
from collect_c4 import collect as rebuild_c4
with tempfile.TemporaryDirectory(prefix='array-c4-verify-') as tmp:
    replay=rebuild_c4(root/'reports/c4',Path(tmp))
    for key in ('groups','accelerator','device_design_total','shell_and_other'):assert replay[key]==c4[key]
if (root/'dsp_attribution.json').exists():
    with (root/'reports/wkv_native/dsp_cells.csv').open() as f:dsp=list(csv.DictReader(f))
    assert len(dsp)==w['DSP']
    assert sum(g['count'] for g in read('dsp_attribution.json'))==w['DSP']
print('PASS: report hashes/counts, CSV, matched IP/ACC, efficiency and overhead, RTL/IP verification, C4 partition')
