#!/usr/bin/env bash
set -uo pipefail
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh
unset DEBUG DEBUG_AXI MAKEFLAGS PERF PROFILE SKIP_POST_ROUTE_QOR POST_ROUTE_EXPLORE_HOLD_FIX
export PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 TARGET=hw
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export PATH=/usr/bin:$PATH
./run_hw.sh --config improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion --clock-freq 100 --postfix 20261030_unified_mmio_r1
pnr_rc=$?
printf '%s\n' "$pnr_rc" > /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c4-unified-mmio/pnr/20261030_unified_mmio_r1/exit_code.txt
exit "$pnr_rc"
