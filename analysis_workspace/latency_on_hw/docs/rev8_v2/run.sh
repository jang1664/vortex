#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export CC=/usr/bin/gcc CXX=/usr/bin/g++ XRT_INI_PATH=/dev/null
unset XCL_EMULATION_MODE FPGA_BIN_DIR XRT_XCLBIN_PATH XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo"
"$PYTHON" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag rev8_v2 --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml \
  --suite-size full --models llama2,llama3 --from generate --to refine \
  --filter 'stage=generation & shape.cache_update=append & (name=attn_k_transpose | name=kv_cache_dequant_k_to_attn_qkT)' \
  --model-execution parallel --parallel-fallback serial --slurm-time 02:00:00
