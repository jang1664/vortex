#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build_dma_bram_phase1"

# shellcheck source=/dev/null
source "${ROOT_DIR}/configs/improve_th16_tcol32_hwexp_dcache.sh"

export VORTEX_RT_PATH="${BUILD_DIR}/runtime"
export SOFTMAX_VARIANT=opt

# xrtsim_vcs/simv does not depend on the RTL source list, so force a rebuild
# before the wrapper's normal incremental build step.
SIM_CONFIGS="${CONFIGS}"
SIM_CONFIGS+=" -DDBG_TRACE_PIPELINE -DDBG_TRACE_MEM -DDBG_TRACE_CACHE"
SIM_CONFIGS+=" -DDBG_TRACE_AFU -DDBG_TRACE_SCOPE -DDBG_TRACE_GBAR"
SIM_CONFIGS+=" -DDBG_TRACE_TCU -DDBG_TRACE_GEMM"
SIM_CONFIGS+=" -DDISABLE_FSDB -DNUM_CORES=1"
make -B -C "${BUILD_DIR}/sim/xrtsim_vcs" simv \
  CONFIGS="${SIM_CONFIGS}" FSDB_DUMP=1

cd "${BUILD_DIR}"
"${ROOT_DIR}/ci/run_black.sh" xrt-vcs-sim \
  --app softmax \
  --args "-batch 1 -heads 1 -seqq 2 -seqk 17 -mask 0" \
  --configs-extra "-DDISABLE_FSDB" \
  --cores 1 \
  --debug 0
