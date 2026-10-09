#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh"
export VORTEX_DRIVER=xrt TARGET=hw
export XRT_XCLBIN_PATH=/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/bin/vortex_afu.xclbin
export FPGA_BIN_DIR="$(dirname "$XRT_XCLBIN_PATH")"
out="$repo/build/tvm_llama3_layer1_prefill1k_rev5"
if [[ "$1" == run ]]; then
    : "${SLURM_JOB_ID:?Run this stage inside a single U55C allocation}"
    source "$repo/ci/xrt_device_detect.sh"
    XRT_DEVICE_INDEX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)")"
    XRT_DEVICE_BDF="$(resolve_xrt_user_bdf "$XRT_DEVICE_INDEX")"
    export XRT_DEVICE_INDEX XRT_DEVICE_BDF
    export LD_PRELOAD="$out/counter_probe.so"
    printf 'JOB=%s BDF=%s\n' "$SLURM_JOB_ID" "$XRT_DEVICE_BDF"
fi
exec "$py" -u "$repo/analysis_workspace/latency_on_hw/docs/tvm_llama3_layer1_prefill1k_rev5/benchmark.py" \
    --stage "$1" --output "$out"
