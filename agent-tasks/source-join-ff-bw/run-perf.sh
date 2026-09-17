#!/usr/bin/env bash
set -euo pipefail
phase=${1:?before or after}
backend=${2:?naive or improve}
repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/agent-tasks/source-join-ff-bw/$phase/$backend"
mkdir -p "$out"
cd "$repo"
if [[ $backend == naive ]]; then
 config=configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh
 app=fpint_gemm_ffn_hw_naive
else
 config=configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh
 app=fpint_gemm_ffn_hw
fi
source "$config"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
unset DEBUG PERF SCOPE GUI POST_IMPL
cp "$config" "$out/config.sh"
printf '%s\n' "$CONFIGS" > "$out/configs.txt"
git rev-parse HEAD > "$out/git-head.txt"
sha256sum hw/rtl/core/gemm/VX_naive_source_join.sv hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv > "$out/rtl.sha256"
printf '%s\n' "$(command -v vcs)" "$(command -v vivado)" > "$out/tools.txt"
env | sort | grep -E '^(PATH|LD_LIBRARY_PATH|VCS_HOME|VIVADO|XILINX|DRAM_|CACHE_|U55C_|VORTEX_|XRT_|CC=|CXX=)' > "$out/environment.txt" || true
cd "$repo/build"
# The simv make rule does not track library RTL. Force its configuration stamp
# to be newer than the executable without deleting existing build artifacts.
touch sim/xrtsim_vcs/.simv_config.stamp
for m in 1 4 256; do
 date -Is > "$out/m${m}.start"
 set +e
 timeout --signal=TERM --kill-after=30s 1800 ci/run_black.sh xrt-vcs-sim --app "$app" --args "-m $m -k 256 -n 256 -q 32 -d 0 -t 0 -r 1" --perf 3 > "$out/m${m}.log" 2>&1
 rc=$?
 set -e
 printf '%s\n' "$rc" > "$out/m${m}.exitcode"
 cp sim/xrtsim_vcs/simv.log "$out/m${m}.simv.log" 2>/dev/null || true
 sha256sum sim/xrtsim_vcs/simv tests/regression/"$app"/kernel.vxbin runtime/libvortex.so runtime/libvortex-xrt.so > "$out/m${m}.binaries.sha256"
 cp sim/xrtsim_vcs/.simv_config.stamp "$out/m${m}.simv_config.stamp"
 date -Is > "$out/m${m}.end"
 [[ $rc == 0 ]] || exit "$rc"
done
