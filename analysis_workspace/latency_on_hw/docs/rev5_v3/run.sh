#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
export PATH="/home/jaeyongjang/.conda/envs/vortex/bin:$PATH"
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export XRT_INI_PATH=/dev/null CXX=/usr/bin/g++ CC=/usr/bin/gcc
unset XCL_EMULATION_MODE FPGA_BIN_DIR XRT_XCLBIN_PATH XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo"
for model in llama2 llama3; do
  (source configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh
   cd "build_latency_$model"
   ../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
  ) > "analysis_workspace/latency_on_hw/docs/rev5_v3/configure_$model.log" 2>&1
done
"$PYTHON" -u analysis_workspace/latency_on_hw/workflow.py pipeline \
  --tag rev5_v3 --candidate-map analysis_workspace/latency_on_hw/candidate_fpga_bins.rev5.yaml \
  --suite-size full --from run --to run --rerun run \
  --filter 'stage=generation & (app=fpint_gemm_ffn_hw | app=fpint_gemm_ffn_hw_naive) & (shape.M=1 | shape.M=4)' \
  --model-execution parallel --parallel-fallback error --slurm-time 01:00:00
