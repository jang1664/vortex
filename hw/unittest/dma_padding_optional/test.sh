#!/usr/bin/env bash
set -uo pipefail

MODE="${1:-regression}"
SIM_EXEC="${SIM_EXEC:-vcs}"
TEST_DIR="${UNITTEST_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "${TEST_DIR}"

mkdir -p logs
pass=0
fail=0

run_positive() {
  local name="$1"
  shift
  if make run SIM_EXEC="${SIM_EXEC}" "$@"; then
    pass=$((pass + 1))
    echo "[PASS] ${name}"
  else
    fail=$((fail + 1))
    echo "[FAIL] ${name}"
  fi
}

run_expected_failure() {
  local name="$1"
  local pattern="$2"
  shift 2
  local log_file="logs/expected_${name}.log"
  local run_status
  make run SIM_EXEC="${SIM_EXEC}" "$@" >"${log_file}" 2>&1
  run_status=$?
  if rg -q -F "${pattern}" "${log_file}"; then
    pass=$((pass + 1))
    echo "[PASS] ${name}: expected failure observed (status=${run_status})"
  elif [[ ${run_status} -eq 0 ]]; then
    fail=$((fail + 1))
    echo "[FAIL] ${name}: required failure signature was not observed"
  else
    fail=$((fail + 1))
    echo "[FAIL] ${name}: failed for an unexpected reason; see ${log_file}"
  fi
}

case "${MODE}" in
  regression|all)
    run_positive parity32 DATA_SIZE=32 NEGATIVE_PADDING=0
    run_positive parity64 DATA_SIZE=64 NEGATIVE_PADDING=0
    run_positive dims1 DATA_SIZE=64 DIM_COMPARE=1 SPECIAL_MAX_DIMS=1
    run_positive dims2 DATA_SIZE=64 DIM_COMPARE=1 SPECIAL_MAX_DIMS=2
    run_positive misal_dims1 DATA_SIZE=64 DIM_COMPARE=1 \
      SPECIAL_MAX_DIMS=1 USE_MISALIGN=1
    run_positive misal_dims2 DATA_SIZE=64 DIM_COMPARE=1 \
      SPECIAL_MAX_DIMS=2 USE_MISALIGN=1
    run_expected_failure nonzero_padding \
      "padding-disabled DMA accepted nonzero padding" \
      DATA_SIZE=64 NEGATIVE_PADDING=1
    run_expected_failure unequal_width \
      "padding-disabled aligned DMA requires equal dcache/lmem bus widths" \
      TOP_MODULE=tb_VX_dma_padding_width_invalid
    run_expected_failure bound_upper \
      "exceeds BOUND_WIDTH" \
      DATA_SIZE=64 NEGATIVE_BOUND=1
    run_expected_failure inactive_bound_1d \
      "inactive bound[1]" \
      DATA_SIZE=64 DIM_COMPARE=1 SPECIAL_MAX_DIMS=1 NEGATIVE_INACTIVE=1
    run_expected_failure inactive_bound_2d \
      "inactive bound[2]" \
      DATA_SIZE=64 DIM_COMPARE=1 SPECIAL_MAX_DIMS=2 NEGATIVE_INACTIVE=1
    run_expected_failure max_dims_zero \
      "MAX_DIMS(0) must be from 1 through 3" \
      TOP_MODULE=tb_VX_dma_max_dims_invalid INVALID_MAX_DIMS=0
    run_expected_failure max_dims_four \
      "MAX_DIMS(4) must be from 1 through 3" \
      TOP_MODULE=tb_VX_dma_max_dims_invalid INVALID_MAX_DIMS=4
    ;;
  parity32)
    run_positive parity32 DATA_SIZE=32 NEGATIVE_PADDING=0
    ;;
  parity64)
    run_positive parity64 DATA_SIZE=64 NEGATIVE_PADDING=0
    ;;
  *)
    echo "usage: $0 [regression|all|parity32|parity64]" >&2
    exit 2
    ;;
esac

echo "[RESULT] pass=${pass} fail=${fail}"
[[ ${fail} -eq 0 ]]
