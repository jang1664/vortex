#!/usr/bin/env bash
set -eo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/agent-tasks/source-join-ff-bw/pnr"
mkdir -p "$out"
source /tool/Program/Xilinx/2025.1/Vivado/settings64.sh
export PLATFORM=/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm
export PLATFORM_REPO_PATHS=/opt/xilinx/platforms
export JOBS=8
unset PERF DEBUG SCOPE CHIPSCOPE
config="$repo/configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh"
postfix="source_join_ff_bw_$(date +%Y%m%d_%H%M%S)"
printf '%s\n' "$postfix" > "$out/postfix.txt"
printf '%s\n' "$repo/build/hw/syn/xilinx/xrt/$(basename "$config" .sh)_${postfix}_xilinx_u55c_gen3x16_xdma_3_202210_1_hw" > "$out/output-dir.txt"
cp "$config" "$out/config.sh"
cd "$repo"
git diff -- hw/rtl > "$out/rtl.diff"
sha256sum hw/rtl/core/gemm/VX_naive_source_join.sv hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv > "$out/rtl.sha256"
date -Is > "$out/start.txt"
cd "$repo/build/hw/syn/xilinx/xrt"
set +e
./run_hw.sh --config "$config" --postfix "$postfix" --slr-floorplan 1 > "$out/run.log" 2>&1
rc=$?
printf '%s\n' "$rc" > "$out/exitcode"
date -Is > "$out/end.txt"
exit "$rc"
