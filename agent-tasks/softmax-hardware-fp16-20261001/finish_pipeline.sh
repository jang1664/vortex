#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${repo}"
task=agent-tasks/softmax-hardware-fp16-20261001
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
# Strict CPU-reference overflow verification in the comparison job records the
# deliberately accepted FTZ difference. Check short masked fused shapes here.
export XILINX_XRT=/opt/xilinx/xrt
cd build_layout_final
for spec in '19 33 40' '1024 1024 1024'; do
    read -r q k stride <<< "${spec}"
    timeout --kill-after=15s 300s ci/run_black.sh hw \
        --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_v2 \
        --run-only --app softmax_layout_fused \
        --args "-batch 1 -heads 1 -seqq ${q} -seqk ${k} -seqk-stride ${stride} -mask 1 -scale 1" \
        > "${repo}/${task}/logs/verify_softmax_layout_fused_${q}_${k}.log" 2>&1
done
cd "${repo}"
"${PYTHON}" - <<'PY'
import importlib.util, json
from pathlib import Path
path=Path('agent-tasks/latency-rerun-layout-fused-20261001/share_softmax_measurements.py')
spec=importlib.util.spec_from_file_location('shared_softmax',path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
results=[module.share('llama2','llama3'),module.share('llama3','llama2')]
Path('agent-tasks/softmax-hardware-fp16-20261001/shared_measurements.json').write_text(json.dumps(results,indent=2)+'\n')
print([{k:v for k,v in r.items() if k not in ('exec_keys','run_ids')} for r in results])
PY
bash "${task}/run_pipeline.sh" llama2,llama3 --from run --to plot
"${PYTHON}" "${task}/audit_results.py"
