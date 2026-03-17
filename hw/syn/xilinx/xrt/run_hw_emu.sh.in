#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

find_root_dir() {
  local candidates=()
  local cand
  local root
  if [[ -n "${VORTEX_HOME:-}" ]]; then
    candidates+=("${VORTEX_HOME}")
  fi
  candidates+=("$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)")
  candidates+=("$(cd -- "${SCRIPT_DIR}/../../../../.." && pwd)")

  for cand in "${candidates[@]}"; do
    [[ -z "${cand}" ]] && continue
    root="$(cd -- "${cand}" 2>/dev/null && pwd || true)"
    [[ -z "${root}" ]] && continue
    if [[ -f "${root}/hw/syn/xilinx/xrt/patches/cvfpu_xsim_guard.patch" && -d "${root}/third_party/cvfpu" ]]; then
      echo "${root}"
      return 0
    fi
  done
  return 1
}

ROOT_DIR="$(find_root_dir || true)"
if [[ -z "${ROOT_DIR}" ]]; then
  echo "[run_hw_emu] ERROR: failed to locate Vortex root directory." >&2
  echo "[run_hw_emu] Tried VORTEX_HOME, ${SCRIPT_DIR}/../../../.., ${SCRIPT_DIR}/../../../../.." >&2
  exit 1
fi

CVFPU_DIR="${ROOT_DIR}/third_party/cvfpu"
PATCH_FILE="${ROOT_DIR}/hw/syn/xilinx/xrt/patches/cvfpu_xsim_guard.patch"

apply_cvfpu_xsim_patch() {
  if [[ ! -f "${PATCH_FILE}" ]]; then
    echo "[run_hw_emu] ERROR: missing patch file: ${PATCH_FILE}" >&2
    exit 1
  fi
  if [[ ! -d "${CVFPU_DIR}" ]]; then
    echo "[run_hw_emu] ERROR: missing cvfpu submodule dir: ${CVFPU_DIR}" >&2
    exit 1
  fi

  if git -C "${CVFPU_DIR}" apply --check "${PATCH_FILE}" >/dev/null 2>&1; then
    echo "[run_hw_emu] Applying XSIM patch: ${PATCH_FILE}"
    git -C "${CVFPU_DIR}" apply "${PATCH_FILE}"
  elif git -C "${CVFPU_DIR}" apply -R --check "${PATCH_FILE}" >/dev/null 2>&1; then
    echo "[run_hw_emu] XSIM patch already applied, skipping."
  else
    echo "[run_hw_emu] ERROR: failed to apply patch cleanly: ${PATCH_FILE}" >&2
    echo "[run_hw_emu] Check local edits in ${CVFPU_DIR}/src/fpnew_pkg.sv" >&2
    exit 1
  fi
}

CONFIGS=""
CONFIGS+=" -DEXT_TCU_ENABLE"
CONFIGS+=" -DAFU_DONE_WAIT_CACHE_DRAIN"
# CONFIGS+=" -DFPU_FPNEW"

export PREFIX=core1_f100_tcu
export PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1
export NUM_CORES=1
export CONFIGS="-DEXT_TCU_ENABLE -DAFU_DONE_WAIT_CACHE_DRAIN"
export TARGET=hw_emu
export CLOCK_FREQ_HZ=100
export CONFIGS
export DEBUG=1
export PROFILE=1

if [[ "${CONFIGS}" == *"-DFPU_FPNEW"* ]]; then
  apply_cvfpu_xsim_patch
fi

mkdir -p ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}
make 2>&1 | tee ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}/build.log