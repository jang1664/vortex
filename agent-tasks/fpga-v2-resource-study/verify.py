#!/usr/bin/env python3
"""Audit report provenance, resource arithmetic, RTL/IP gates and plot inputs."""
import argparse,csv,json,math,re,sys
from pathlib import Path
TASK=Path(__file__).resolve().parent
sys.path.insert(0,str(TASK.parent/'array-fpga-study'))
from resources import KEYS,add,hierarchy,sha
from collect_native import breakdown
p=argparse.ArgumentParser();p.add_argument('results',type=Path,nargs='?',default=TASK/'results');a=p.parse_args();out=a.results
read=lambda n:json.loads((out/n).read_text())
for r in read('archive.json'):assert sha(out/r['file'])==r['sha256'],r['file']
rows=read('resources.json');by={r['point']:r for r in rows}
assert set(by)=={'fp_tcu_128','woq_16x16','wkv_16x16','lmem_8','lmem_32','cache_1','cache_4','axi_1','axi_4'}
parts=read('engine_breakdown.json')
tcu_tree=hierarchy(out/'reports/fp_tcu_128/hierarchy.rpt')
assert sum(r['module'].startswith('xil_fmul') for r in tcu_tree if not r['self'])==128
for r in rows:
 d=out/'reports'/r['point'];m=json.loads((d/'manifest.json').read_text())
 assert {k:r[k] for k in KEYS}==hierarchy(d/'hierarchy.rpt')[0]['counts']
 assert read(str(Path('reports')/r['point']/'status.json'))['success']
 assert read(str(Path('reports')/r['point']/'summary.json'))['blackboxes']==0
 text=(d/'utilization.rpt').read_text();assert 'Design State : Optimized' in text
 for k,label in {'LUT':'CLB LUTs*','FF':'CLB Registers','DSP':'DSPs','BRAM36eq':'Block RAM Tile','URAM':'URAM'}.items():
  match=re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([\d,.]+)',text,re.M)
  assert match and float(match[1].replace(',',''))==r[k],(r['point'],k)
 timing=(d/'timing_post_opt.rpt').read_text()
 for check in ('no_clock','unconstrained_internal_endpoints','loops'):assert f'checking {check} (0)' in timing
 assert '-period 10.000' in (d/'clock.xdc').read_text()
 assert r['BRAM36eq']==r['RAMB36']+r['RAMB18']/2
 if r['point'].startswith('axi_'):
  assert m['generics']['NUM_BANKS_OUT']==32 and m['generics']['NUM_HBM_PORTS']==32
  assert m['generics']['INTERLEAVE']==1 and m['generics']['ADDR_WIDTH_IN']==28 and m['generics']['ADDR_WIDTH_OUT']==34
 if r['MAC_per_cycle']:
  assert r['MAC_per_cycle']==(128 if r['point']=='fp_tcu_128' else 256)
  assert math.isclose(r['nominal_GOPS'],r['MAC_per_cycle']*.2)
  assert math.isclose(r['GOPS_per_kLUT'],r['nominal_GOPS']*1000/r['LUT'])
  assert math.isclose(r['GOPS_per_DSP'],r['nominal_GOPS']/r['DSP'])
 if r['point'] in parts:
  assert parts[r['point']]==breakdown(d/'hierarchy.rpt')
  assert add(parts[r['point']])=={k:r[k] for k in KEYS}
  assert r['internal_ACC_KiB']==256
for k in ['RAMB36','RAMB18','URAM']:assert by['woq_16x16'][k]==by['wkv_16x16'][k]
over=read('overhead.json');w=by['wkv_16x16'];q=by['woq_16x16']
for k in KEYS:
 assert over['WKV_minus_WoQ'][k]==w[k]-q[k]
 assert over['percent_over_WoQ'][k]==(100*(w[k]-q[k])/q[k] if q[k] else None)
 scaler=next(g for g in parts['wkv_16x16'] if g['component']=='Input scaler')
 assert over['input_scaler_counts'][k]==scaler[k]
 assert over['input_scaler_percent_of_WKV'][k]==(100*scaler[k]/w[k] if w[k] else None)
 assert next(g for g in parts['woq_16x16'] if g['component']=='Input scaler')[k]==0
comparison=read('comparison.json')
for r in comparison:
 c=add([by[r['engine']]]+[by[n] for n in r['memory_points']]);assert c=={k:r[k] for k in KEYS}
 assert math.isclose(r['GOPS_per_kLUT'],by[r['engine']]['nominal_GOPS']*1000/c['LUT'])
for i,key in enumerate(['engine_only_relative_GOPS_per_kLUT','with_memory_relative_GOPS_per_kLUT']):
 assert math.isclose(read('interpretation.json')[key],comparison[2+i]['GOPS_per_kLUT']/comparison[i]['GOPS_per_kLUT'])
assert read('verification/geometry_check/result.json')['status']=='pass'
assert read('verification/axi_geometry_check/result.json')['status']=='pass'
for p in read('verification/axi_geometry_check/result.json')['points']:
 assert p['status']=='pass' and p['physical_ports']==32 and p['transport_groups']==32 and p['address_bits']==34
assert read('verification/fpga_v2_test/verification.json')['status']=='pass'
v=read('verification/vendor_ip_check/result.json');assert v['status']=='pass' and v['measured_handshake_latency']==1
log=(out/'verification/fpga_v2_test/logs/sim.log').read_text()
for seed in (1234,2027,91):assert re.search(r'TEST PASSED seed='+str(seed)+r' compared_cycles=\d+ checked_lanes=288 low_ready_responses=4',log)
ip=read('ip_parameters.json')
for n,v in ip['wkv_16x16'].items():assert v['parameters']==ip['woq_16x16'][n]['parameters']
verified={Path(k).name:h for k,h in read('verification/fpga_v2_test/test_manifest.json')['source_hashes'].items()}
for n in ['woq_16x16','wkv_16x16']:
 for path,h in read('reports/'+n+'/manifest.json')['sources'].items():
  assert verified[Path(path).name]==h
  assert sha(out/'sources'/n/Path(path).name)==h
with (out/'resources.csv').open() as f:
 csvrows=list(csv.DictReader(f))
 for a,b in zip(csvrows,rows):
  for k,v in b.items():assert a[k]==str(v)
 assert len(csvrows)==len(rows)
for name,h in read('provenance/harness.json').items():assert sha(TASK.parents[1]/name)==h, name
for csvname,data in [('comparison.csv',comparison),('engine_breakdown.csv',[dict(engine=n,**{k:g[k] for k in ['component',*KEYS]}) for n,groups in parts.items() for g in groups])]:
 with (out/csvname).open() as f:
  actual=list(csv.DictReader(f));assert actual==[{k:str(v) for k,v in row.items()} for row in data]
if (out/'table6.json').exists():
 for row in read('table6.json'):
  for key in ['GOPS_per_kLUT','GOPS_per_DSP']:
   assert math.isclose(row['relative_'+key],by[row['point']][key]/by['fp_tcu_128'][key])
print('PASS: 9 optimized reports, hashes, CSV, 128/256 MAC geometry, matched IP/ACC, 864 directed lanes, vendor IP, breakdown and additive memory efficiency')
