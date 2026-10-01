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
tag=th16_20260920_c4_slots16_v2r1
filter='app=~kv_cache_quant_layout_fused* | app=softmax_layout_fused'
variants=(--kernel-variant kv_cache_quant_layout_fused_w4a16=prefill_tiled_chunk_fp32
          --kernel-variant softmax_layout_fused=rev2_shuffle_cursor)
if [[ ${1:-} == pilot ]]; then
    "${PYTHON}" -m tools.latency_bench.selective_rerun \
        --suite "analysis_workspace/latency_on_hw/generated_suites/llama2_7b_main_full.${tag}/prefill_merged/prefill_merged_C4.pkl" \
        --out agent-tasks/latency-rerun-layout-fused-20261001/pilot \
        --stage prefill --fpga-bin C4 --build-dir build_latency_llama2 \
        --application-source-identity pilot --force \
        --filter 'app=kv_cache_quant_layout_fused_w4a16 & args=~"-k 1024 * -t 1 *"' \
        "${variants[@]}"
else
    "${PYTHON}" analysis_workspace/latency_on_hw/workflow.py pipeline \
        --tag "${tag}" --models "${1:?Specify llama2, llama3, or llama2,llama3}" \
        --candidates C4 --adopt-legacy --filter "${filter}" "${variants[@]}" "${@:2}"
fi
