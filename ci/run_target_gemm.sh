#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh"

MODE="run"
BUILD_DIR="${TARGET_GEMM_BUILD_DIR:-${REPO_ROOT}/build}"
OUTPUT_ROOT=""
M=4
N=256
K=256
QBLK=32
WTRANS=0
QDIR=1
WLOAD=8
PERF_CLASS=3
TIMEOUT_SEC=1800
CONFIGS_EXTRA=""
EXTRA_APP_ARGS=""
DO_CONFIGURE=0
FORCE_REBUILD=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ci/run_target_gemm.sh [MODE] [OPTIONS]

Run the GEMM_IMPROVE xrt-vcs-sim target.

Modes:
  run          No FSDB, no GEMM trace (default)
  trace        No FSDB, enable GEMM text traces
  fsdb         Full-design FSDB
  fsdb-gemm    GEMM node-only FSDB
  fsdb-trace   Full-design FSDB plus GEMM text traces

Options:
  --m M                    M dimension (default: 4)
  --n N                    N dimension (default: 256)
  --k K                    K dimension (default: 256)
  --qblk Q                 quantization block size (default: 32)
  --wtrans 0|1             weight transpose flag (default: 0)
  --qdir 0|1               quantization direction (default: 1)
  --wload 4|8|16|32        GEMM weight columns per load (default: 8)
  --config FILE             source config file (repo-relative or absolute)
  --perf CLASS             profiling class (default: 3)
  --no-perf                disable profiling
  --timeout SEC            wall-clock timeout (default: 1800)
  --configs-extra "..."    append RTL compile defines
  --extra-app-args "..."   append application arguments
  --build-dir DIR           configured build directory
  --output-root DIR         artifact directory root
  --configure               configure the selected build directory first
  --rebuild                 force VCS re-elaboration
  --dry-run                 validate and print commands without executing
  -h, --help                show this help

Examples:
  ci/run_target_gemm.sh
  ci/run_target_gemm.sh --wload 16
  ci/run_target_gemm.sh --config configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh
  ci/run_target_gemm.sh trace --k 512
  ci/run_target_gemm.sh fsdb-gemm --timeout 3600 --rebuild
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 ]] || die "$1 requires a value"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

append_define_once() {
  local configs="$1"
  local define="$2"
  if [[ " ${configs} " != *" ${define} "* ]]; then
    configs+=" ${define}"
  fi
  printf '%s' "${configs}"
}

replace_wload_define() {
  local configs="$1"
  local value="$2"
  local token
  local count=0
  local -a tokens=()
  local -a replaced=()

  read -r -a tokens <<< "${configs}"
  for token in "${tokens[@]}"; do
    if [[ "${token}" =~ ^-DMXU_WLOAD_NUM=[0-9]+$ ]]; then
      replaced+=("-DMXU_WLOAD_NUM=${value}")
      ((count += 1))
    else
      replaced+=("${token}")
    fi
  done
  [[ "${count}" == 1 ]] || \
    die "selected config must contain exactly one -DMXU_WLOAD_NUM=<value> token (found ${count})"
  printf '%s' "${replaced[*]}"
}

if [[ $# -gt 0 && "$1" != -* ]]; then
  MODE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --m)
      require_value "$@"; M="$2"; shift 2 ;;
    --n)
      require_value "$@"; N="$2"; shift 2 ;;
    --k)
      require_value "$@"; K="$2"; shift 2 ;;
    --qblk)
      require_value "$@"; QBLK="$2"; shift 2 ;;
    --wtrans)
      require_value "$@"; WTRANS="$2"; shift 2 ;;
    --qdir)
      require_value "$@"; QDIR="$2"; shift 2 ;;
    --wload)
      require_value "$@"; WLOAD="$2"; shift 2 ;;
    --config)
      require_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
    --perf)
      require_value "$@"; PERF_CLASS="$2"; shift 2 ;;
    --no-perf)
      PERF_CLASS=""; shift ;;
    --timeout)
      require_value "$@"; TIMEOUT_SEC="$2"; shift 2 ;;
    --configs-extra)
      require_value "$@"; CONFIGS_EXTRA="$2"; shift 2 ;;
    --extra-app-args)
      require_value "$@"; EXTRA_APP_ARGS="$2"; shift 2 ;;
    --build-dir)
      require_value "$@"; BUILD_DIR="$2"; shift 2 ;;
    --output-root)
      require_value "$@"; OUTPUT_ROOT="$2"; shift 2 ;;
    --configure)
      DO_CONFIGURE=1; shift ;;
    --rebuild)
      FORCE_REBUILD=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

case "${MODE}" in
  run|trace|fsdb|fsdb-gemm|fsdb-trace) ;;
  *) die "unknown mode '${MODE}' (expected run, trace, fsdb, fsdb-gemm, or fsdb-trace)" ;;
esac

is_positive_integer "${M}" || die "--m must be a positive integer"
is_positive_integer "${N}" || die "--n must be a positive integer"
is_positive_integer "${K}" || die "--k must be a positive integer"
is_positive_integer "${QBLK}" || die "--qblk must be a positive integer"
[[ "${WTRANS}" == 0 || "${WTRANS}" == 1 ]] || die "--wtrans must be 0 or 1"
[[ "${QDIR}" == 0 || "${QDIR}" == 1 ]] || die "--qdir must be 0 or 1"
[[ "${WLOAD}" == 4 || "${WLOAD}" == 8 || "${WLOAD}" == 16 || "${WLOAD}" == 32 ]] || \
  die "--wload must be one of 4, 8, 16, or 32"
[[ -z "${PERF_CLASS}" ]] || is_positive_integer "${PERF_CLASS}" || die "--perf must be a positive integer"
is_positive_integer "${TIMEOUT_SEC}" || die "--timeout must be a positive integer"
if [[ "${CONFIG_FILE}" != /* ]]; then
  CONFIG_FILE="${REPO_ROOT}/${CONFIG_FILE}"
fi
CONFIG_FILE="$(realpath -m -- "${CONFIG_FILE}")"
[[ -f "${CONFIG_FILE}" ]] || die "config not found: ${CONFIG_FILE}"
if [[ "${EXTRA_APP_ARGS}" =~ (^|[[:space:]])-m ]]; then
  die "--extra-app-args cannot override --m (M=${M})"
fi
if [[ "${CONFIGS_EXTRA}" =~ (^|[[:space:]])-[DU]MXU_WLOAD_NUM($|=|[[:space:]]) ]]; then
  die "--configs-extra cannot override --wload (MXU_WLOAD_NUM=${WLOAD})"
fi
if [[ "${CONFIGS_EXTRA}" =~ (^|[[:space:]])-UGEMM_IMPROVE($|[[:space:]]) ]]; then
  die "--configs-extra cannot disable the fixed GEMM_IMPROVE target"
fi

# The runner executes from inside BUILD_DIR.  Canonicalize caller-supplied
# paths first so a relative --build-dir is not resolved a second time there,
# and so trace artifacts keep the caller-selected output location.
BUILD_DIR="$(realpath -m -- "${BUILD_DIR}")"
if [[ -n "${OUTPUT_ROOT}" ]]; then
  OUTPUT_ROOT="$(realpath -m -- "${OUTPUT_ROOT}")"
fi

if [[ "${DO_CONFIGURE}" == 1 ]]; then
  mkdir -p "${BUILD_DIR}"
  echo "[target-gemm] configuring ${BUILD_DIR}"
  if [[ "${DRY_RUN}" == 0 ]]; then
    (
      cd "${BUILD_DIR}"
      "${REPO_ROOT}/configure" --xlen=64 --tooldir=/opt/vortex --prefix="${HOME}/tools/vortex"
    )
  fi
fi

if [[ "${DRY_RUN}" == 0 ]]; then
  [[ -x "${BUILD_DIR}/ci/run_black.sh" ]] || \
    die "${BUILD_DIR} is not configured; rerun with --configure"
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
BASE_CONFIGS="${CONFIGS:-}"
[[ " ${BASE_CONFIGS} " == *" -DGEMM_IMPROVE "* ]] || \
  die "selected config does not enable GEMM_IMPROVE"
BASE_CONFIGS="$(replace_wload_define "${BASE_CONFIGS}" "${WLOAD}")"
[[ " ${BASE_CONFIGS} " == *" -DMXU_WLOAD_NUM=${WLOAD} "* ]] || \
  die "internal error: selected configs do not set MXU_WLOAD_NUM=${WLOAD}"

EFFECTIVE_CONFIGS="${BASE_CONFIGS}"
case "${MODE}" in
  run)
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDISABLE_FSDB)" ;;
  trace)
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDISABLE_FSDB)"
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM)"
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM_FSM)"
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM_CTRL)" ;;
  fsdb) ;;
  fsdb-gemm)
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DFSDB_GEMM_ONLY)" ;;
  fsdb-trace)
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM)"
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM_FSM)"
    EFFECTIVE_CONFIGS="$(append_define_once "${EFFECTIVE_CONFIGS}" -DDBG_TRACE_GEMM_CTRL)" ;;
esac
if [[ -n "${CONFIGS_EXTRA}" ]]; then
  EFFECTIVE_CONFIGS+=" ${CONFIGS_EXTRA}"
fi

COMPILE_CONFIGS="${EFFECTIVE_CONFIGS}"
if [[ -n "${PERF_CLASS}" ]]; then
  COMPILE_CONFIGS="$(append_define_once "${COMPILE_CONFIGS}" -DPERF_ENABLE)"
fi

APP_ARGS="-m ${M} -n ${N} -k ${K} -q ${QBLK} -t ${WTRANS} -d ${QDIR}"
if [[ -n "${EXTRA_APP_ARGS}" ]]; then
  APP_ARGS+=" ${EXTRA_APP_ARGS}"
fi

if [[ -z "${OUTPUT_ROOT}" ]]; then
  OUTPUT_ROOT="${BUILD_DIR}/run_logs/target_gemm"
fi
RUN_TAG="$(date +%Y%m%d-%H%M%S)_${MODE}_wload${WLOAD}_m${M}_n${N}_k${K}_q${QBLK}_t${WTRANS}_d${QDIR}_pid$$"
RUN_DIR="${OUTPUT_ROOT}/${RUN_TAG}"
SIM_DIR="${BUILD_DIR}/sim/xrtsim_vcs"
SIMV="${SIM_DIR}/simv"
STAMP_FILE="${SIM_DIR}/.target_gemm_simv_fingerprint"
MAKE_CONFIG_STAMP="${SIM_DIR}/.simv_config.stamp"
mkdir -p "${RUN_DIR}"

FINGERPRINT="$({
  printf '%s\n' "CONFIGS=${COMPILE_CONFIGS}"
  printf '%s\n' "FSDB_DUMP=1"
  sha256sum "${CONFIG_FILE}" "${REPO_ROOT}/hw/rtl/VX_config.vh" \
    "${REPO_ROOT}/sim/xrtsim_vcs/tb_vcs_xrtsim.sv"
} | sha256sum | cut -d' ' -f1)"

REBUILD_REASON=""
if [[ "${FORCE_REBUILD}" == 1 ]]; then
  REBUILD_REASON="--rebuild requested"
elif [[ ! -x "${SIMV}" ]]; then
  REBUILD_REASON="simv is missing"
elif [[ ! -f "${STAMP_FILE}" ]] || [[ "$(<"${STAMP_FILE}")" != "${FINGERPRINT}" ]]; then
  REBUILD_REASON="compile fingerprint changed"
elif [[ -f "${MAKE_CONFIG_STAMP}" && "${MAKE_CONFIG_STAMP}" -nt "${STAMP_FILE}" ]]; then
  REBUILD_REASON="simv configuration changed outside this runner"
elif find "${REPO_ROOT}/hw/rtl" "${REPO_ROOT}/sim/xrtsim_vcs" \
    -type f \( -name '*.sv' -o -name '*.v' -o -name '*.vh' -o -name '*.cpp' -o -name '*.h' -o -name 'Makefile' \) \
    -newer "${SIMV}" -print -quit | grep -q .; then
  REBUILD_REASON="RTL or simulator source is newer than simv"
fi

RUNNER=("${BUILD_DIR}/ci/run_black.sh" xrt-vcs-sim
  --app fpint_gemm_ffn_hw
  --args "${APP_ARGS}")
if [[ -n "${PERF_CLASS}" ]]; then
  RUNNER+=(--perf "${PERF_CLASS}")
fi

FSDB_FILE=""
VCS_FLAGS=""
if [[ "${MODE}" == fsdb || "${MODE}" == fsdb-gemm || "${MODE}" == fsdb-trace ]]; then
  FSDB_FILE="${RUN_DIR}/target_gemm.fsdb"
  VCS_FLAGS="+fsdb_file=${FSDB_FILE}"
fi

{
  printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
  printf 'repo_root=%s\n' "${REPO_ROOT}"
  printf 'build_dir=%s\n' "${BUILD_DIR}"
  printf 'config_file=%s\n' "${CONFIG_FILE}"
  printf 'mode=%s\n' "${MODE}"
  printf 'wload=%s\n' "${WLOAD}"
  printf 'm=%s\n' "${M}"
  printf 'app=fpint_gemm_ffn_hw\n'
  printf 'app_args=%s\n' "${APP_ARGS}"
  printf 'perf_class=%s\n' "${PERF_CLASS:-disabled}"
  printf 'timeout_sec=%s\n' "${TIMEOUT_SEC}"
  printf 'configs=%s\n' "${EFFECTIVE_CONFIGS}"
  printf 'compile_configs=%s\n' "${COMPILE_CONFIGS}"
  printf 'compile_fingerprint=%s\n' "${FINGERPRINT}"
  printf 'rebuild_reason=%s\n' "${REBUILD_REASON:-reuse matching simv}"
  printf 'fsdb_file=%s\n' "${FSDB_FILE:-disabled}"
  printf 'command='; printf '%q ' "${RUNNER[@]}"; printf '\n'
} > "${RUN_DIR}/manifest.txt"

echo "[target-gemm] mode=${MODE} wload=${WLOAD} workload='${APP_ARGS}'"
echo "[target-gemm] config=${CONFIG_FILE}"
echo "[target-gemm] artifacts=${RUN_DIR}"

if [[ -n "${REBUILD_REASON}" ]]; then
  echo "[target-gemm] rebuilding simv: ${REBUILD_REASON}"
  printf 'make -C %q FSDB_DUMP=1 CONFIGS=%q simv\n' "${SIM_DIR}" "${COMPILE_CONFIGS}" \
    | tee "${RUN_DIR}/compile-command.log"
  if [[ "${DRY_RUN}" == 0 ]]; then
    # The VCS Makefile tracks command-line defines, but RTL files discovered
    # through -y library directories are not prerequisites.  Advancing the
    # generated config stamp forces only VCS re-elaboration and leaves the
    # expensive precompiled Xilinx simulation libraries intact.
    if [[ -f "${MAKE_CONFIG_STAMP}" ]]; then
      touch "${MAKE_CONFIG_STAMP}"
    fi
    PATH="/usr/bin:${PATH}" make -C "${SIM_DIR}" FSDB_DUMP=1 \
      CONFIGS="${COMPILE_CONFIGS}" simv 2>&1 | tee "${RUN_DIR}/compile-wrapper.log"
    printf '%s\n' "${FINGERPRINT}" > "${STAMP_FILE}"
  fi
else
  echo "[target-gemm] reusing matching simv"
fi

echo -n "[target-gemm] running: "
printf '%q ' "${RUNNER[@]}"
printf '\n'
if [[ "${DRY_RUN}" == 1 ]]; then
  echo "[target-gemm] dry-run complete"
  exit 0
fi

set +e
(
  cd "${BUILD_DIR}"
  PATH="/usr/bin:${PATH}" \
  CONFIGS="${EFFECTIVE_CONFIGS}" \
  VCS_SIMV_FLAGS="${VCS_FLAGS}" \
    timeout --signal=TERM --kill-after=30s "${TIMEOUT_SEC}s" "${RUNNER[@]}"
) 2>&1 | tee "${RUN_DIR}/wrapper.log"
STATUS=${PIPESTATUS[0]}
set -e

[[ ! -f "${SIM_DIR}/compile.log" ]] || cp -p "${SIM_DIR}/compile.log" "${RUN_DIR}/compile.log"
[[ ! -f "${SIM_DIR}/simv.log" ]] || cp -p "${SIM_DIR}/simv.log" "${RUN_DIR}/simv.log"
printf 'exit_status=%s\n' "${STATUS}" >> "${RUN_DIR}/manifest.txt"

if [[ "${STATUS}" -ne 0 ]]; then
  echo "[target-gemm] FAILED (status=${STATUS}); inspect ${RUN_DIR}" >&2
  exit "${STATUS}"
fi

echo "[target-gemm] PASSED; artifacts=${RUN_DIR}"
