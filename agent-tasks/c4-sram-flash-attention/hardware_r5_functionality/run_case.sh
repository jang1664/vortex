#!/usr/bin/env bash
set -euo pipefail
fusion_repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
fusion_results="$fusion_repo/agent-tasks/c4-sram-flash-attention/hardware_r5_functionality"
fusion_case="$1"
fusion_app="$2"
fusion_args="${3:-}"
source "$fusion_repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export VORTEX_FPGA_BIN_ALIAS_MAP="$fusion_repo/ci/fpga_bin_alias_map.yaml"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export PATH=/usr/bin:$PATH
export XRT_INI_PATH=/dev/null
unset XCL_EMULATION_MODE XRT_DEVICE_INDEX XRT_DEVICE_BDF DEBUG PERF PROFILE
cd "$fusion_repo/build_c4_sram_hardware"
date -Is > "$fusion_results/$fusion_case.started"
set +e
timeout --signal=TERM --kill-after=30s 300s ./ci/run_black.sh hw   --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_r5   --app "$fusion_app" --args "$fusion_args"   > "$fusion_results/$fusion_case.log" 2>&1
fusion_rc=$?
set -e
printf '%s\n' "$fusion_rc" > "$fusion_results/$fusion_case.exit"
date -Is > "$fusion_results/$fusion_case.finished"
printf '%s exit=%s\n' "$fusion_case" "$fusion_rc"
exit "$fusion_rc"
