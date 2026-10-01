#!/usr/bin/env bash

set -euo pipefail

# configure links build/ci scripts to the source tree. Keep the invocation
# tree for build selection, but resolve the link to locate source configs.
ENTRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${ENTRY_ROOT}" != "${REPO_ROOT}" ]]; then
  DEFAULT_BUILD_ROOT="${ENTRY_ROOT}"
elif [[ -f "config.mk" ]]; then
  DEFAULT_BUILD_ROOT="$(pwd)"
else
  DEFAULT_BUILD_ROOT="${REPO_ROOT}/build"
fi

PLATFORM="${PLATFORM:-xilinx_u55c_gen3x16_xdma_3_202210_1}"
TARGET=hw
CLOCK_FREQ_HZ="${CLOCK_FREQ_HZ:-100}"
BUILD_ROOT="${BUILD_DIR:-${DEFAULT_BUILD_ROOT}}"

CONFIG_ARG=""
POSTFIX=""
PERF_VALUE="${PERF:-}"
DEBUG_VALUE="${DEBUG:-}"
CONGESTION_FAIL_FAST_ENV="${CONGESTION_FAIL_FAST:-}"
NO_EARLY_FAIL=0

usage() {
  cat <<'EOF'
Usage: ci/run_syn_hw.sh --config NAME_OR_PATH [--build-dir DIR] [--postfix VALUE] [--perf [VALUE]] [--debug [VALUE]] [--no-early-fail]

Options:
  -c, --config NAME_OR_PATH  Config name or path. A bare name is resolved from
                             the repository's configs/ directory.
      --build-dir DIR        Configured build root (overrides BUILD_DIR).
                             Otherwise use the invoked build tree, configured
                             current directory, or repo/build, in that order.
      --postfix VALUE        Append _VALUE to the config-derived PREFIX.
      --perf [VALUE]         Pass PERF to make (default value: 1).
      --debug [VALUE]        Pass DEBUG to make (default value: 3).
      --no-early-fail        Disable the post-place congestion fail-fast gate.
                             Routing continues at congestion level 7 or higher.
  -h, --help                 Show this help.

Assignment-style arguments are also accepted:
  CONFIG=improve_th16_tcol32_hwexp_dcache PERF=1
  CONFIG=configs/improve_th16_tcol32_hwexp_dcache.sh DEBUG=3

Examples:
  ci/run_syn_hw.sh --config improve_th32_tcol32_hwexp_dcache --perf
  ci/run_syn_hw.sh --config configs/improve_th32_tcol32_hwexp_dcache.sh --debug 3
  ci/run_syn_hw.sh --config improve_th32_tcol32_hwexp_dcache --no-early-fail
  ci/run_syn_hw.sh --config improve_th32_tcol32_hwexp_dcache --postfix v2

The same gate can be controlled with the CONGESTION_FAIL_FAST environment
variable (1: enabled, 0: disabled; overrides the config). PERF and DEBUG can
also be set in the environment. Non-empty PERF/DEBUG values, including 0,
enable their Makefile features; omit or unset them to disable those features.
Set PLATFORM in the environment to override the default U55C platform name,
including with an absolute .xpfm path when platform-name lookup is ambiguous.
CLOCK_FREQ_HZ overrides the default kernel clock of 100 (MHz in the Makefile).
Export PLACE_DESIGN_DIRECTIVE and ROUTE_DESIGN_DIRECTIVE in the config to select
Vivado implementation directives. Unset or empty values use the tool defaults.

Configure the build root before running this script, for example from build/:
  ../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
  ./ci/run_syn_hw.sh --config th32_c1_improve_m32_tcol32.sh
Synthesis runs in BUILD_DIR/hw/syn/xilinx/xrt, with the log under its output directory.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    -c|--config)
      (($# >= 2)) || fail "$1 requires a value"
      CONFIG_ARG="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_ARG="${1#*=}"
      shift
      ;;
    --build-dir)
      (($# >= 2)) || fail "$1 requires a value"
      [[ -n "$2" && "$2" != -* ]] || fail "$1 requires a directory"
      BUILD_ROOT="$2"
      shift 2
      ;;
    --build-dir=*)
      BUILD_ROOT="${1#*=}"
      [[ -n "${BUILD_ROOT}" ]] || fail "--build-dir requires a directory"
      shift
      ;;
    --postfix)
      (($# >= 2)) || fail "$1 requires a value"
      [[ -n "$2" ]] || fail "$1 requires a non-empty value"
      POSTFIX="$2"
      shift 2
      ;;
    --postfix=*)
      POSTFIX="${1#*=}"
      [[ -n "${POSTFIX}" ]] || fail "--postfix requires a non-empty value"
      shift
      ;;
    --perf)
      PERF_VALUE=1
      if (($# >= 2)) && [[ "$2" =~ ^[0-9]+$ ]]; then
        PERF_VALUE="$2"
        shift
      fi
      shift
      ;;
    --perf=*|PERF=*)
      PERF_VALUE="${1#*=}"
      [[ "${PERF_VALUE}" =~ ^[0-9]+$ ]] || fail "PERF must be an integer"
      shift
      ;;
    --debug)
      DEBUG_VALUE=3
      if (($# >= 2)) && [[ "$2" =~ ^[0-9]+$ ]]; then
        DEBUG_VALUE="$2"
        shift
      fi
      shift
      ;;
    --debug=*|DEBUG=*)
      DEBUG_VALUE="${1#*=}"
      [[ "${DEBUG_VALUE}" =~ ^[0-9]+$ ]] || fail "DEBUG must be an integer"
      shift
      ;;
    --no-early-fail)
      NO_EARLY_FAIL=1
      shift
      ;;
    CONFIG=*|CONFIG_FILE=*)
      CONFIG_ARG="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${CONFIG_ARG}" ]] || {
  usage >&2
  exit 2
}
[[ -z "${PERF_VALUE}" || "${PERF_VALUE}" =~ ^[0-9]+$ ]] || fail "PERF must be an integer"
[[ -z "${DEBUG_VALUE}" || "${DEBUG_VALUE}" =~ ^[0-9]+$ ]] || fail "DEBUG must be an integer"
[[ "${CLOCK_FREQ_HZ}" =~ ^[0-9]+$ && "${CLOCK_FREQ_HZ}" =~ [1-9] ]] || \
  fail "CLOCK_FREQ_HZ must be a positive integer (MHz)"
[[ -z "${POSTFIX}" || "${POSTFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
  fail "postfix must contain only letters, digits, '.', '_', or '-' and start with a letter or digit"

resolve_config() {
  local candidate="$1"

  if [[ -f "${candidate}" ]]; then
    readlink -f "${candidate}"
    return
  fi
  if [[ -f "${REPO_ROOT}/${candidate}" ]]; then
    readlink -f "${REPO_ROOT}/${candidate}"
    return
  fi
  if [[ "${candidate}" != *.sh ]]; then
    candidate="${candidate}.sh"
  fi
  if [[ -f "${REPO_ROOT}/configs/${candidate}" ]]; then
    readlink -f "${REPO_ROOT}/configs/${candidate}"
    return
  fi

  fail "config not found: $1"
}

CONFIG_FILE="$(resolve_config "${CONFIG_ARG}")"
[[ -d "${BUILD_ROOT}" ]] || fail "build directory not found: ${BUILD_ROOT}; configure it first"
BUILD_ROOT="$(cd "${BUILD_ROOT}" && pwd)"
SYNTH_DIR="${BUILD_ROOT}/hw/syn/xilinx/xrt"
[[ -f "${BUILD_ROOT}/config.mk" && -f "${SYNTH_DIR}/Makefile" ]] || \
  fail "build directory is not configured: ${BUILD_ROOT}; run configure there first"
cmp -s "${SYNTH_DIR}/Makefile" "${REPO_ROOT}/hw/syn/xilinx/xrt/Makefile" || \
  fail "build Makefile is out of date; rerun ${REPO_ROOT}/configure --xlen=64 --tooldir=/opt/vortex --prefix=\"${HOME}/tools/vortex\" from ${BUILD_ROOT}"
PREFIX="$(basename "${CONFIG_FILE}" .sh)"
if [[ -n "${POSTFIX}" ]]; then
  PREFIX="${PREFIX}_${POSTFIX}"
fi

# Some config files source another file with a repository-relative path.
cd "${REPO_ROOT}"
source "${CONFIG_FILE}"
cd "${SYNTH_DIR}"

if ((NO_EARLY_FAIL)); then
  CONGESTION_FAIL_FAST_VALUE=0
else
  CONGESTION_FAIL_FAST_VALUE="${CONGESTION_FAIL_FAST_ENV:-${CONGESTION_FAIL_FAST:-1}}"
fi
[[ "${CONGESTION_FAIL_FAST_VALUE}" =~ ^[01]$ ]] || \
  fail "CONGESTION_FAIL_FAST must be 0 or 1"

PERF_VALUE="${PERF_VALUE:-${PERF:-}}"
DEBUG_VALUE="${DEBUG_VALUE:-${DEBUG:-}}"
PLACE_DESIGN_DIRECTIVE_VALUE="${PLACE_DESIGN_DIRECTIVE:-}"
ROUTE_DESIGN_DIRECTIVE_VALUE="${ROUTE_DESIGN_DIRECTIVE:-}"
[[ -z "${PERF_VALUE}" || "${PERF_VALUE}" =~ ^[0-9]+$ ]] || fail "PERF must be an integer"
[[ -z "${DEBUG_VALUE}" || "${DEBUG_VALUE}" =~ ^[0-9]+$ ]] || fail "DEBUG must be an integer"

# Match the Makefile's XSA naming when PLATFORM is an absolute .xpfm path.
PLATFORM_NAME="$(basename "${PLATFORM}" .xpfm)"
OUTPUT_DIR="${PREFIX}_${PLATFORM_NAME}_${TARGET}"
mkdir -p "${OUTPUT_DIR}"

MAKE_ENV=(
  "PREFIX=${PREFIX}"
  "PLATFORM=${PLATFORM}"
  "CONFIGS=${CONFIGS:-}"
  "TARGET=${TARGET}"
  "CLOCK_FREQ_HZ=${CLOCK_FREQ_HZ}"
  "CONGESTION_FAIL_FAST=${CONGESTION_FAIL_FAST_VALUE}"
  "PLACE_DESIGN_DIRECTIVE=${PLACE_DESIGN_DIRECTIVE_VALUE}"
  "ROUTE_DESIGN_DIRECTIVE=${ROUTE_DESIGN_DIRECTIVE_VALUE}"
  "PERF=${PERF_VALUE}"
  "DEBUG=${DEBUG_VALUE}"
)

echo "Config: ${CONFIG_FILE}"
echo "Build:  ${SYNTH_DIR}"
echo "Prefix: ${PREFIX}"
echo "PERF:   ${PERF_VALUE:-disabled}"
echo "DEBUG:  ${DEBUG_VALUE:-disabled}"
echo "Place directive: ${PLACE_DESIGN_DIRECTIVE_VALUE:-default}"
echo "Route directive: ${ROUTE_DESIGN_DIRECTIVE_VALUE:-default}"
echo "Congestion early fail: $([[ "${CONGESTION_FAIL_FAST_VALUE}" == 1 ]] && echo enabled || echo disabled)"

env "${MAKE_ENV[@]}" make 2>&1 | tee "${OUTPUT_DIR}/${PREFIX}.log"
