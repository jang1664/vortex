#!/usr/bin/env bash
set -euo pipefail
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export PATH=/usr/bin:$PATH
unset DEBUG DEBUG_AXI PERF PROFILE XCL_EMULATION_MODE XRT_DEVICE_INDEX XRT_DEVICE_BDF VORTEX_FPGA_BIN_ALIAS_MAP MAKEFLAGS
exec python3 -u /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c4-unified-mmio/hardware/20261031_unified_mmio_r1/run_matrix.py
