#!/bin/bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
FPGA_BIN_ALIAS_RESOLVER="${SCRIPT_DIR}/resolve_fpga_bin_alias.py"
FPGA_BIN_ALIAS_MAP="${VORTEX_FPGA_BIN_ALIAS_MAP:-${SCRIPT_DIR}/fpga_bin_alias_map.yaml}"
if [[ ! -f "${FPGA_BIN_ALIAS_RESOLVER}" && -f "../ci/resolve_fpga_bin_alias.py" ]]; then
  FPGA_BIN_ALIAS_RESOLVER="$(realpath ../ci/resolve_fpga_bin_alias.py)"
fi
if [[ ! -f "${FPGA_BIN_ALIAS_MAP}" && -f "../ci/fpga_bin_alias_map.yaml" ]]; then
  FPGA_BIN_ALIAS_MAP="$(realpath ../ci/fpga_bin_alias_map.yaml)"
fi

list_fpga_bin_aliases() {
  "${PYTHON_BIN}" "${FPGA_BIN_ALIAS_RESOLVER}" --alias-map "${FPGA_BIN_ALIAS_MAP}" --list 2>/dev/null || true
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug]"
  echo "Modes:"
  echo "  rtlsim   - Run only rtlsim tests"
  echo "  xrtsim   - Run only xrtsim tests"
  echo "  xrt-vcs-sim   - Run only xrt-vcs-sim tests"
  echo "  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests"
  echo "  hw_emu    - Run only hw_emu tests"
  echo "  hw        - Run only hw tests"
  echo "Options:"
  echo "  --hw-debug, --enable-hw-debug-module"
  echo "      Append -DENABLE_HW_DEBUG_MODULE to CONFIGS"
  aliases="$(list_fpga_bin_aliases)"
  if [[ -n "${aliases}" ]]; then
    echo "FPGA bin aliases: ${aliases}"
  fi
  exit 0
fi

mode="${1:-}"
shift || true

if [[ "${mode}" == "" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug]"
  echo "Modes:"
  echo "  rtlsim   - Run only rtlsim tests"
  echo "  xrtsim   - Run only xrtsim tests"
  echo "  xrt-vcs-sim   - Run only xrt-vcs-sim tests"
  echo "  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests"
  echo "  hw_emu    - Run only hw_emu tests"
  echo "  hw        - Run only hw tests"
  exit 1
fi

APP=fpint_gemm_ffn_hw_improve
ARGS="-m 2 -n 32 -k 128"
CONFIGS_EXTRA=""
FPGA_BIN=improve_tcol1
FPGA_BIN_DIR=""
FPGA_BIN_CONFIGS=""
BENCH_FLAG=""
PERF_FLAG=""
DEBUG_FLAG=""
HW_DEBUG=0

resolve_fpga_bin() {
  local fpga_bin="$1"
  local resolved
  local resolver_args=(--alias-map "${FPGA_BIN_ALIAS_MAP}")
  resolved="$("${PYTHON_BIN}" "${FPGA_BIN_ALIAS_RESOLVER}" "${resolver_args[@]}" "${fpga_bin}")"
  FPGA_BIN_DIR="$(printf '%s\n' "${resolved}" | sed -n '1p')"
  FPGA_BIN_CONFIGS="$(printf '%s\n' "${resolved}" | sed -n '2p')"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP="$2"
      shift 2
      ;;
    --args)
      ARGS="$2"
      shift 2
      ;;
    --configs-extra)
      CONFIGS_EXTRA="$2"
      shift 2
      ;;
    --fpga-bin)
      FPGA_BIN="$2"
      shift 2
      ;;
    --bench)
      BENCH_FLAG="--bench"
      shift
      ;;
    --perf)
      PERF_FLAG="--perf=$2"
      shift 2
      ;;
    --debug)
      DEBUG_FLAG="--debug=$2"
      shift 2
      ;;
    --debug=*)
      DEBUG_FLAG="$1"
      shift
      ;;
    --hw-debug|--enable-hw-debug-module)
      HW_DEBUG=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug]"
      echo "  --hw-debug, --enable-hw-debug-module: append -DENABLE_HW_DEBUG_MODULE to CONFIGS"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug]"
      exit 1
      ;;
  esac
done

resolve_fpga_bin "${FPGA_BIN}"

if [[ -n "${FPGA_BIN_CONFIGS}" ]]; then
  if [[ ! -f "${FPGA_BIN_CONFIGS}" ]]; then
    echo "config file not found: ${FPGA_BIN_CONFIGS}" >&2
    exit 1
  fi
  source "${FPGA_BIN_CONFIGS}"
fi

# Base CONFIGS exported by the alias config or environment. Append script-specific flags.
CONFIGS="${CONFIGS:-}"
CONFIGS+=" -DWLOAD_AT_ONCE"

if [[ -n "${DEBUG_FLAG}" ]]; then
  CONFIGS+=" -DDBG_TRACE_PIPELINE"
  CONFIGS+=" -DDBG_TRACE_MEM"
  CONFIGS+=" -DDBG_TRACE_CACHE"
  CONFIGS+=" -DDBG_TRACE_AFU"
  CONFIGS+=" -DDBG_TRACE_SCOPE"
  CONFIGS+=" -DDBG_TRACE_GBAR"
  CONFIGS+=" -DDBG_TRACE_TCU"
  CONFIGS+=" -DDBG_TRACE_GEMM"
fi

if [[ "${HW_DEBUG}" == "1" ]]; then
  CONFIGS+=" -DENABLE_HW_DEBUG_MODULE"
fi

if [[ -n "${CONFIGS_EXTRA}" ]]; then
  CONFIGS+=" ${CONFIGS_EXTRA}"
fi

# ----------------------------------------------------------------------------
# - rtlsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "rtlsim" || "${mode}" == "all" ]]; then
  CONFIGS="${CONFIGS}" \
  DRIVER=rtlsim \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=rtlsim --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - xrtsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "xrtsim" || "${mode}" == "all" ]]; then
  DRAM_REQ_STALL_P_ENTER_PCT=70 \
  DRAM_REQ_STALL_P_EXIT_PCT=30 \
  DRAM_RSP_STALL_P_ENTER_PCT=70 \
  DRAM_RSP_STALL_P_EXIT_PCT=30 \
  DRAM_STALL_SEED=1234 \
  CONFIGS=${CONFIGS} \
  TARGET=xrtsim \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - xrt-vcs-sim
# ----------------------------------------------------------------------------
# DRAM_REQ_STALL_P_ENTER_PCT=0 \
# DRAM_REQ_STALL_P_EXIT_PCT=100 \
# DRAM_RSP_STALL_P_ENTER_PCT=0 \
# DRAM_RSP_STALL_P_EXIT_PCT=100 \
# DRAM_STALL_SEED=1234 \
# CACHE_REQ_STALL_P_ENTER_PCT=0 \
# CACHE_REQ_STALL_P_EXIT_PCT=100 \
# CACHE_RSP_STALL_P_ENTER_PCT=0 \
# CACHE_RSP_STALL_P_EXIT_PCT=100 \
# CACHE_STALL_SEED=1234 \
if [[ "${mode}" == "xrt-vcs-sim" || "${mode}" == "all" ]]; then
  xrt_vcs_env=(
    "CONFIGS=${CONFIGS} -DNDEBUG"
    "DRIVER=xrt_vcs"
  )
  if [[ -n "${FPGA_BIN_DIR}" ]]; then
    xrt_vcs_env+=("XRT_XCLBIN_PATH=${FPGA_BIN_DIR}/vortex_afu.xclbin")
  fi
  if [[ -n "${DEBUG_FLAG}" ]]; then
    xrt_vcs_env+=("FSDB_DUMP=1" "DEBUG_AXI=1")
  fi
  env "${xrt_vcs_env[@]}" ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt_vcs --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - xrt-vcs-pgsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "xrt-vcs-pgsim" || "${mode}" == "all" ]]; then
  xrt_vcs_post_env=(
    "DRAM_REQ_STALL_P_ENTER_PCT=70"
    "DRAM_REQ_STALL_P_EXIT_PCT=30"
    "DRAM_RSP_STALL_P_ENTER_PCT=70"
    "DRAM_RSP_STALL_P_EXIT_PCT=30"
    "DRAM_STALL_SEED=1234"
    "CONFIGS=${CONFIGS}"
    "DRIVER=xrt_vcs_post"
    "NETLIST=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/gate_sim/vortex_afu_funcsim.v"
  )
  if [[ -n "${FPGA_BIN_DIR}" ]]; then
    xrt_vcs_post_env+=("XRT_XCLBIN_PATH=${FPGA_BIN_DIR}/vortex_afu.xclbin")
  fi
  if [[ -n "${DEBUG_FLAG}" ]]; then
    xrt_vcs_post_env+=("FSDB_DUMP=1" "DEBUG_AXI=1" "GUI=1")
  fi
  env "${xrt_vcs_post_env[@]}" ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt_vcs_post --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - hw_emu
# ----------------------------------------------------------------------------
if [[ "${mode}" == "hw_emu" || "${mode}" == "all" ]]; then
  CONFIGS=${CONFIGS} \
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw_emu/bin \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw_emu \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - hw
# ----------------------------------------------------------------------------
if [[ "${mode}" == "hw" || "${mode}" == "all" ]]; then
  echo "HW FPGA_BIN=${FPGA_BIN} FPGA_BIN_DIR=${FPGA_BIN_DIR} FPGA_BIN_CONFIGS=${FPGA_BIN_CONFIGS}"
  srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00 --pty bash -c "\
  CONFIGS=\"${CONFIGS}\" \
  FPGA_BIN_DIR=\"${FPGA_BIN_DIR}\" \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt --app=${APP} --args=\"${ARGS}\" | tee bb.log
  "
  # CHIPSCOPE=1 \
fi
