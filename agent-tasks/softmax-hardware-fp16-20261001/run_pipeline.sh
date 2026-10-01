#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${repo}"
export RISCV_TOOLCHAIN_PATH=/opt/vortex_profiles/rv64imaf_zfh_lp64f/riscv64-gnu-toolchain
export LIBC_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libc64
export LIBCRT_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libcrt64
export XILINX_XRT=/opt/xilinx/xrt
export THIRD_PARTY_DIR=/home/jaeyongjang/project.local/vortex_fpint/third_party
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export CXX=/usr/bin/g++
export PYTHONPATH="${repo}${PYTHONPATH:+:${PYTHONPATH}}"
"${PYTHON}" analysis_workspace/latency_on_hw/workflow.py pipeline \
    --tag th16_20260920_c4_slots16_v2r1 --models "${1:?Specify models}" \
    --candidates C4 --adopt-legacy --filter 'app=softmax_layout_fused' \
    --kernel-variant kv_cache_quant_layout_fused_w4a16=prefill_tiled_chunk_fp32 \
    --kernel-variant softmax_layout_fused=rev2_shuffle_cursor "${@:2}"
