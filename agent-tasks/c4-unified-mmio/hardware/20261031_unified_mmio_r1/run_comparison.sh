#!/usr/bin/env bash
set -euo pipefail
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
comparison_repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
source "$comparison_repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
unset DEBUG DEBUG_AXI PERF PROFILE MAKEFLAGS
cd "$comparison_repo"
exec timeout --signal=TERM --kill-after=30s 3600 "$py" "$comparison_repo/agent-tasks/c4-sram-flash-attention/run_hardware_matrix.py" \
 --build "$comparison_repo/build_c4_unified_mmio_hw" \
 --fixtures "$comparison_repo/build_c4_sram_fusion/fixtures/resident_attention" \
 --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1 \
 --output "$comparison_repo/agent-tasks/c4-unified-mmio/hardware/20261031_attention_comparison" \
 --repetitions 3 \
 --case llama3-8b_decode_p16_c32 \
 --case llama3-8b_decode_p128_c256 \
 --case llama3-8b_prefill128
