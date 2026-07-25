#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/../../../../../" && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build"}

python ${SCRIPT_DIR}/run.py --design-name VX_gemm_unit_top --period-ns 10  --extra-define "MXU_COL_TILE=32" --extra-define "GEMM_IMPROVE"
python ${SCRIPT_DIR}/run_sim_power.py --design-name VX_gemm_unit_top

python ${SCRIPT_DIR}/run.py --design-name VX_woq_gemm_unit_top --period-ns 10  --extra-define "MXU_COL_TILE=32" --extra-define "GEMM_IMPROVE"
python ${SCRIPT_DIR}/run_sim_power.py --design-name VX_woq_gemm_unit_top