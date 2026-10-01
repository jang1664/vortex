#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${repo}/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh"
export RISCV_TOOLCHAIN_PATH=/opt/vortex_profiles/rv64imaf_zfh_lp64f/riscv64-gnu-toolchain
export LIBC_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libc64
export LIBCRT_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libcrt64
export XILINX_XRT=/opt/xilinx/xrt
export THIRD_PARTY_DIR=/home/jaeyongjang/project.local/vortex_fpint/third_party
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export CXX=/usr/bin/g++
for model in llama2 llama3; do
    mkdir -p "${repo}/build_latency_${model}"
    cd "${repo}/build_latency_${model}"
    ../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
    make -C hw config
    make -C kernel -j4
    make -C runtime stub xrt TARGET=hw CXX=/usr/bin/g++ -j2
done
