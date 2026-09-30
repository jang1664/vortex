#!/usr/bin/env python3
"""Collect only measured reports; archive enough evidence for offline replay."""
import argparse, csv, json, re, shutil, sys
from pathlib import Path
TASK=Path(__file__).resolve().parent
sys.path.insert(0,str(TASK.parent/'array-fpga-study'))
from resources import hierarchy, sha, KEYS, add
from collect_native import breakdown, resolved_ips

def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2)+'\n')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('build',type=Path);p.add_argument('--output',type=Path,default=TASK/'results');a=p.parse_args()
 build=a.build.resolve();root=build/'mxu16_fpga';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
 names=['fp_tcu_64','woq_16x16','wkv_16x16','lmem_8','lmem_32','cache_1','cache_4','axi_1','axi_4']
 archive=[];rows=[];parts={};ip={}
 def copy(src,dst):
  q=out/dst;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,q)
  archive.append(dict(file=str(dst),sha256=sha(q),original=str(src)))
 for name in names:
  d=root/name;assert json.loads((d/'status.json').read_text())['success'],name
  assert json.loads((d/'summary.json').read_text())['blackboxes']==0
  m=json.loads((d/'manifest.json').read_text())
  for source,h in m['sources'].items():assert sha(source)==h,source
  c=hierarchy(d/'hierarchy.rpt')[0]['counts'];mac=m['MAC_per_cycle'];gops=mac*.2
  row=dict(point=name,**c,BRAM36eq=c['RAMB36']+c['RAMB18']/2,MAC_per_cycle=mac,reference_MHz=100,internal_ACC_KiB=m['internal_ACC_KiB'])
  if mac:row.update(nominal_GOPS=gops,GOPS_per_kLUT=gops*1000/c['LUT'],GOPS_per_DSP=gops/c['DSP'])
  rows.append(row)
  for f in ['hierarchy.rpt','utilization.rpt','timing_post_opt.rpt','primitives.csv','summary.json','status.json','manifest.json','clock.xdc','command.json','ip_setup.tcl','verification_gate.json']:
   if (d/f).exists():copy(d/f,Path('reports')/name/f)
  if mac:ip[name]=resolved_ips(d)
  if name in ['woq_16x16','wkv_16x16']:parts[name]=breakdown(d/'hierarchy.rpt')
 points={r['point']:r for r in rows};woq=points['woq_16x16'];wkv=points['wkv_16x16']
 for k in ['RAMB36','RAMB18','URAM']:assert woq[k]==wkv[k], 'Matched-pair storage differs'
 for n,v in ip['wkv_16x16'].items():assert v['parameters']==ip['woq_16x16'][n]['parameters']
 scaler=next(g for g in parts['wkv_16x16'] if g['component']=='Input scaler')
 assert all(g[k]==0 for g in parts['woq_16x16'] if g['component']=='Input scaler' for k in KEYS)
 overhead=dict(WKV_minus_WoQ={k:wkv[k]-woq[k] for k in KEYS},percent_over_WoQ={k:100*(wkv[k]-woq[k])/woq[k] if woq[k] else None for k in KEYS},input_scaler_counts={k:scaler[k] for k in KEYS},input_scaler_percent_of_WKV={k:100*scaler[k]/wkv[k] if wkv[k] else None for k in KEYS})
 comparison=[]
 for engine,mem in [('fp_tcu_64',['lmem_8','cache_1','axi_1']),('wkv_16x16',['lmem_32','cache_4','axi_4'])]:
  for withmem in (False,True):
   c=add([points[engine]]+[points[n] for n in mem] if withmem else [points[engine]])
   gops=points[engine]['nominal_GOPS']
   comparison.append(dict(engine=engine,scope='engine + memory subsystem' if withmem else 'engine only',memory_points=mem if withmem else [],**c,BRAM36eq=c['RAMB36']+c['RAMB18']/2,nominal_GOPS=gops,GOPS_per_kLUT=gops*1000/c['LUT'],GOPS_per_DSP=gops/c['DSP']))
 for sub,files in [('array_fpga_test',['verification.json','test_manifest.json','logs/sim.log']),('vendor_ip_check',['result.json']),('geometry_check',['result.json','run.log'])]:
  for f in files:copy(build/sub/f,Path('verification')/sub/f)
 assert json.loads((build/'array_fpga_test/verification.json').read_text())['status']=='pass'
 assert json.loads((build/'vendor_ip_check/result.json').read_text())['status']=='pass'
 assert json.loads((build/'geometry_check/result.json').read_text())['status']=='pass'
 test=json.loads((build/'array_fpga_test/test_manifest.json').read_text())
 verified={Path(k).name:v for k,v in test['source_hashes'].items()}
 for name in ['wkv_16x16','woq_16x16']:
  m=json.loads((root/name/'manifest.json').read_text())
  for path,h in m['sources'].items():assert verified[Path(path).name]==h
  for file in ('snapshot.json','ablation.json'):
   q=root/'sources'/name/file
   if q.exists():copy(q,Path('provenance')/name/file)
 copy(root/'sources/fp_tcu_64/snapshot.json',Path('provenance/fp_tcu_64/snapshot.json'))
 copy(build/'rtl_edits.json',Path('provenance/rtl_edits.json'))
 save(out/'resources.json',rows);save(out/'engine_breakdown.json',parts);save(out/'overhead.json',overhead)
 save(out/'comparison.json',comparison);save(out/'ip_parameters.json',ip)
 save(out/'interpretation.json',dict(engine_only_relative_GOPS_per_kLUT=comparison[2]['GOPS_per_kLUT']/comparison[0]['GOPS_per_kLUT'],with_memory_relative_GOPS_per_kLUT=comparison[3]['GOPS_per_kLUT']/comparison[1]['GOPS_per_kLUT'],engine_relative_GOPS_per_DSP=wkv['GOPS_per_DSP']/points['fp_tcu_64']['GOPS_per_DSP'],scope='Native DSP mapping; 100 MHz nominal reference; separately synthesized block costs added, not integrated timing or sustained throughput.',memory='LMEM 8/32 banks, 512 KiB, 8 B; cache 1/4 banks, 4 MiB, 16 B words, 64 B lines; AXI 1/4 inputs, 32 outputs, 64 B. FP-INT has an additional 256 KiB ACC.'))
 for file,data in [('resources.csv',rows),('comparison.csv',comparison),('engine_breakdown.csv',[dict(engine=n,**{k:g[k] for k in ['component',*KEYS]}) for n,groups in parts.items() for g in groups])]:
  keys=list(dict.fromkeys(k for r in data for k in r))
  with (out/file).open('w') as f:w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(data)
 repo=TASK.parents[1]
 scripts=list(TASK.glob('*.py'))+[TASK/'requirements.txt',repo/'configs/mxu16_fpga_compute.sh',repo/'configs/fig5_fpga_memory.sh']
 scripts += [TASK.parent/'fig5-fpga'/n for n in ['run.py','synth.tcl','report.tcl']]
 scripts += [TASK.parent/'array-fpga-study'/n for n in ['prepare_test.py','prepare_woq.py','resources.py','collect_native.py','check_vendor_ip.py','vendor_ip_sim.tcl','vendor_ip_tb.sv','test/tb_ablation.sv','test/fp_axis_models.sv','test/compile_test.py']]
 save(out/'provenance/harness.json',{str(s.relative_to(repo)):sha(s) for s in scripts})
 save(out/'provenance/checkpoints.json',{n:sha(root/n/'post_opt.dcp') for n in names})
 save(out/'provenance/rtl_support.json',{n:sha(build.parent/n) for n in ['hw/scripts/xilinx_ip_gen.tcl','hw/scripts/xilinx_async_bram_patch.tcl']})
 save(out/'archive.json',archive)
 print(json.dumps(dict(engines=rows[:3],overhead=overhead,interpretation=json.loads((out/'interpretation.json').read_text())),indent=2))
if __name__=='__main__':main()
