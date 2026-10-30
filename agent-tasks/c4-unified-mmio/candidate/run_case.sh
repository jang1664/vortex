#!/usr/bin/env bash
set -euo pipefail
candidate_repo=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv
candidate_evidence=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c4-unified-mmio/candidate
candidate_case=$1
candidate_args=$2
candidate_phase=${3:-run}
candidate_app=${4:-flash_attn}
source "$candidate_repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export SIMLIB_DIR=/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/vcs_simlib
unset DEBUG PERF VCS_SIMV_FLAGS VCS_SOCKET_PORT XCL_EMULATION_MODE
cd "$candidate_repo/build_c4_unified_mmio"
printf '%s\n' "$CONFIGS -DDISABLE_FSDB" > "$candidate_evidence/configs.txt"
date -Is > "$candidate_evidence/$candidate_case.started"
candidate_flags=()
candidate_timeout=${CANDIDATE_TIMEOUT:-300}
if [[ "$candidate_phase" == build ]]; then
  candidate_flags+=(--build-only)
  candidate_timeout=1800
else
  candidate_flags+=(--run-only)
fi
set +e
timeout --signal=TERM --kill-after=30s "$candidate_timeout" ./ci/run_black.sh xrt-vcs-sim --app "$candidate_app" --args "$candidate_args" --configs-extra '-DDISABLE_FSDB' "${candidate_flags[@]}" > "$candidate_evidence/$candidate_case.log" 2>&1
candidate_rc=$?
set -e
printf '%s\n' "$candidate_rc" > "$candidate_evidence/$candidate_case.exit"
date -Is > "$candidate_evidence/$candidate_case.finished"
if [[ "$candidate_phase" != build && -f sim/xrtsim_vcs/simv.log ]]; then cp sim/xrtsim_vcs/simv.log "$candidate_evidence/$candidate_case.simv.log"; fi
printf '%s exit=%s\n' "$candidate_case" "$candidate_rc"
exit "$candidate_rc"
