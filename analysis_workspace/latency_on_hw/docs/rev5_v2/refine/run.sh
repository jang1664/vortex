#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export XRT_INI_PATH=/dev/null
export CXX=/usr/bin/g++ CC=/usr/bin/gcc
unset XCL_EMULATION_MODE FPGA_BIN_DIR XRT_XCLBIN_PATH XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo"
for model in llama2 llama3; do
  (source configs/tcu_th16_c1_v3.sh
   cd "build_latency_$model"
   ../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
  ) > "analysis_workspace/latency_on_hw/docs/rev5_v2/refine/configure_$model.log" 2>&1
done
"$PYTHON" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag rev5_v2 --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev5.yaml \
  --suite-size full --from refine --to refine --rerun refine --filter 'backend=head_reorder' \
  --adopt-legacy --model-execution parallel --parallel-fallback error --slurm-time 01:00:00
