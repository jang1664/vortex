#!/usr/bin/env bash
set -euo pipefail
baseline_repo=/home/jaeyongjang/project.local/vortex-c4-unified-mmio-baseline-12382c883
baseline_evidence=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c4-unified-mmio/baseline
baseline_case=$1
baseline_args=$2
baseline_phase=${3:-run}
source "$baseline_repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export SIMLIB_DIR=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/vcs_simlib
unset DEBUG PERF VCS_SIMV_FLAGS VCS_SOCKET_PORT XCL_EMULATION_MODE
cd "$baseline_repo/build"
printf '%s\n' "$CONFIGS -DDISABLE_FSDB" > "$baseline_evidence/configs.txt"
date -Is > "$baseline_evidence/$baseline_case.started"
baseline_flags=()
baseline_timeout=300
if [[ "$baseline_phase" == build ]]; then
  baseline_flags+=(--build-only)
  baseline_timeout=1800
else
  baseline_flags+=(--run-only)
fi
set +e
timeout --signal=TERM --kill-after=30s "$baseline_timeout" ./ci/run_black.sh xrt-vcs-sim --app flash_attn --args "$baseline_args" --configs-extra '-DDISABLE_FSDB' "${baseline_flags[@]}" > "$baseline_evidence/$baseline_case.log" 2>&1
baseline_rc=$?
set -e
printf '%s\n' "$baseline_rc" > "$baseline_evidence/$baseline_case.exit"
date -Is > "$baseline_evidence/$baseline_case.finished"
if [[ "$baseline_phase" != build && -f sim/xrtsim_vcs/simv.log ]]; then cp sim/xrtsim_vcs/simv.log "$baseline_evidence/$baseline_case.simv.log"; fi
printf '%s exit=%s\n' "$baseline_case" "$baseline_rc"
exit "$baseline_rc"
