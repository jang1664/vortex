from pathlib import Path
import json
from collections import Counter
from tools.latency_bench.suite_io import indexed_suites
from tools.latency_bench.suite import load_suite
from tools.latency_bench.selective_rerun import selected_suite
repo = Path(__file__).resolve().parents[5]
w = repo / 'analysis_workspace/latency_on_hw'
filters = ('stage=generation & app=kv_cache_quant_layout_fused_w4a16 & (shape.source_total_k=8 | shape.source_total_k=64)',)
result = {}
for model, key in [('llama2','llama2_7b'),('llama3','llama3_8b')]:
    stages = {}
    for stage in ('prefill','generation'):
        index = w / 'generated_suites' / f'{key}_main_full.rev5_v2' / f'{stage}_merged/index.yaml'
        suite_path = next(path for label,path in indexed_suites(index) if label == 'C4')
        suite = load_suite(suite_path, repo_root=repo)
        selected = selected_suite(suite,w/f'outputs_{model}_main.rev5_v2/C4/raw_db.csv',filters,'C4',stage)
        executions = {c.exec_key:c for c in selected.cases if c.measurement_kind == 'measured'}
        assert all(c.source != 'historical_raw_db' and '--source-total-k ' in c.args for c in selected.cases)
        stages[stage] = {'logical_cases':len(selected.cases),'physical_executions':len(executions),
            'source_rows':dict(Counter(str(c.shape.get('source_total_k')) for c in executions.values())),
            'executions':[{'exec_key':k,'name':c.name,'args':c.measurement_args or c.args,'shape':c.shape} for k,c in executions.items()]}
    assert stages['prefill']['logical_cases'] == 0
    assert stages['generation']['physical_executions'] > 0
    result[model] = stages
out = Path(__file__).with_name('selection.json')
out.write_text(json.dumps(result,indent=2)+'\n')
for model,stages in result.items():
    print(model,{stage:{k:v for k,v in data.items() if k != 'executions'} for stage,data in stages.items()})
