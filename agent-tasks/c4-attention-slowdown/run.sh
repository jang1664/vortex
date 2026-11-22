#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
unset DEBUG DEBUG_AXI PERF PROFILE MAKEFLAGS XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo/build_c4_unified_mmio_hw"
exec python3 "$repo/agent-tasks/c4-attention-slowdown/run.py" "$@"
