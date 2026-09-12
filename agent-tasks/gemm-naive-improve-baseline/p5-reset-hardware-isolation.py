#!/usr/bin/env python3
import hashlib,importlib.util,json,shlex,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('pre',TASK/'p1-improve-preprocess.py');pre=importlib.util.module_from_spec(spec);spec.loader.exec_module(pre)
out=TASK/'p5-verification/reset-hardware-isolation';out.mkdir(exist_ok=False)
reference=TASK/'p1-isolation/iteration15/candidate/hw/rtl/core/gemm/VX_gemm_node_naive.sv';current=ROOT/'hw/rtl/core/gemm/VX_gemm_node_naive.sv'
manifest=json.loads((TASK/'p4-regression/naive-m256-final1/manifest.json').read_text())
assert hashlib.sha256(reference.read_bytes()).hexdigest()==manifest['source_hashes']['hw/rtl/core/gemm/VX_gemm_node_naive.sv']
config=subprocess.check_output(['bash','-c','source agent-tasks/fpint-gemm-latency-compare/naive.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
records=[]
for mx in (16,32):
 defines=[d for d in shlex.split(config) if not any(d.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
 defines += ['-D'+k+'='+str(mx) for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS')]
 for perf in (False,True):
  texts={};commands={}
  for label,source in (('measured_reference',reference),('diagnostic_candidate',current)):
   cmd=['verilator','-E','-DSYNTHESIS','-DNDEBUG','-DXLEN_64',*defines]
   if perf:cmd+=['-DPERF_ENABLE']
   cmd+=['+incdir+'+str(ROOT/'hw/rtl'),str(source)]
   result=subprocess.run(cmd,cwd=ROOT,text=True,capture_output=True);assert result.returncode==0,result.stderr
   texts[label]=pre.normalized(result.stdout);commands[label]=cmd
  assert texts['measured_reference']==texts['diagnostic_candidate']
  records.append(dict(mxu=mx,perf=perf,equal=True,commands=commands,sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in texts.items()}))
report=dict(status='pass',scope='Measured naive node versus diagnostic addition: synthesis-selected RTL identity, MXU16/32 PERF off/on; no synthesis run',reference_sha256=hashlib.sha256(reference.read_bytes()).hexdigest(),current_sha256=hashlib.sha256(current.read_bytes()).hexdigest(),records=records)
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='records'}))
