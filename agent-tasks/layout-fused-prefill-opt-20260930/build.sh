#!/usr/bin/env bash
set -euo pipefail
task_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "${task_dir}/../.." && pwd)
build_name=${1:?Specify build_layout_baseline or build_layout_variants}
cd "${repo_dir}/${build_name}"
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh
export RISCV_TOOLCHAIN_PATH=/opt/vortex_profiles/rv64imaf_zfh_lp64f/riscv64-gnu-toolchain
export LIBC_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libc64
export LIBCRT_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libcrt64
export XILINX_XRT=/opt/xilinx/xrt
export THIRD_PARTY_DIR=/home/jaeyongjang/project.local/vortex_fpint/third_party
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
make -C hw config
make -C kernel -j4
make -C runtime stub xrt TARGET=hw CXX=/usr/bin/g++ -j2
export KV_CACHE_QUANT_VARIANT=groupwise_fp32
export SOFTMAX_VARIANT=rev2_shuffle_safe
if [[ ${build_name} == build_layout_chunk || ${build_name} == build_layout_refined || ${build_name} == build_layout_final ]]; then
    export SOFTMAX_LAYOUT_FUSED_VARIANT=rev2_shuffle_cursor
    export KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=prefill_tiled_chunk_fp32
elif [[ ${build_name} == build_layout_control ]]; then
    export SOFTMAX_LAYOUT_FUSED_VARIANT=rev2_shuffle_safe
    export KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=prefill_group_fp32
elif [[ ${build_name} == build_layout_variants || ${build_name} == build_layout_fp32 ]]; then
    export SOFTMAX_LAYOUT_FUSED_VARIANT=rev2_shuffle_cursor
    if [[ ${build_name} == build_layout_fp32 ]]; then
        export KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=prefill_group_fp32
    else
        export KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=${KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT:-prefill_warp_group}
    fi
else
    # The historical grouped variant assumes 32-wide masked-store addresses.
    export SOFTMAX_LAYOUT_FUSED_VARIANT=rev2_shuffle
fi
for app in softmax_layout_fused kv_cache_quant_layout_fused_w4a16 softmax kv_cache_quant_w4a16; do
    # These Makefiles are copied by configure; refresh after adding a variant.
    cp "${repo_dir}/tests/regression/${app}/Makefile" "tests/regression/${app}/Makefile"
    make -C "tests/regression/${app}" all bench CXX=/usr/bin/g++
done
