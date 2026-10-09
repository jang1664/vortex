from pathlib import Path
import json, shlex
from collections import Counter
from tools.latency_bench.suite import load_suite
from tools.latency_bench.suite_io import indexed_suites
from tools.latency_bench.selective_rerun import selected_suite
repo=Path(__file__).resolve().parents[4]
w=repo/'analysis_workspace/latency_on_hw'
filters=('stage=generation & (app=fpint_gemm_ffn_hw | app=fpint_gemm_ffn_hw_naive) & (shape.M=1 | shape.M=4)',)
result={}
for model,key in [('llama2','llama2_7b'),('llama3','llama3_8b')]:
 result[model]={}
 for stage in ('prefill','generation'):
  for label,path in indexed_suites(w/f'generated_suites/{key}_main_full.rev5_v3/{stage}_merged/index.yaml'):
   s=selected_suite(load_suite(path,repo_root=repo),w/f'outputs_{model}_main.rev5_v3/{label}/raw_db.csv',filters,label,stage)
   cases={c.exec_key:c for c in s.cases if c.measurement_kind=='measured'}
   for c in cases.values():
    a=shlex.split(c.args); b=shlex.split(c.measurement_args)
    assert c.shape['preserve_execution_m'] is True and c.source!='historical_raw_db'
    assert a[a.index('-m')+1]==b[b.index('-m')+1]
    assert int(b[b.index('-m')+1]) in (1,4)
    assert all(int(b[b.index(opt)+1])%32==0 for opt in ('-k','-n'))
   assert len(cases)==(54 if model=='llama2' else 56) if stage=='generation' and label in ('C3','C4') else len(cases)==0
   result[model][f'{stage}:{label}']=[{'exec_key':k,'app':c.app,'name':c.name,'args':c.measurement_args,'logical_args':c.args} for k,c in cases.items()]
   print(model,stage,label,len(cases),flush=True)
Path(__file__).with_name('selection.json').write_text(json.dumps(result,indent=2)+'\n')
