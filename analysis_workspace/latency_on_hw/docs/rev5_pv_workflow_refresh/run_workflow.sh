#!/usr/bin/env bash
set -euo pipefail
repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export XRT_INI_PATH=/dev/null
unset XCL_EMULATION_MODE FPGA_BIN_DIR XRT_XCLBIN_PATH XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo"
"$PYTHON" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag th16_20261007_rev5_pipeline \
  --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev5.yaml \
  --suite-size full --candidates C4 \
  --from run --to run --rerun run \
  --filter 'app=fpint_gemm_ffn_hw' --filter 'name=attn_pv' \
  --model-execution parallel --parallel-fallback error --slurm-time 01:00:00
