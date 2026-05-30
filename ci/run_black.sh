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
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--xrt-mem-map legacy|remap]"
  echo "Modes:"
  echo "  rtlsim   - Run only rtlsim tests"
  echo "  xrtsim   - Run only xrtsim tests"
  echo "  xrt-vcs-sim   - Run only xrt-vcs-sim tests"
  echo "  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests"
  echo "  hw_emu    - Run only hw_emu tests"
  echo "  hw        - Run only hw tests"
  aliases="$(list_fpga_bin_aliases)"
  if [[ -n "${aliases}" ]]; then
    echo "FPGA bin aliases: ${aliases}"
  fi
  exit 0
fi

mode="${1:-}"
shift || true

if [[ "${mode}" == "" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--xrt-mem-map legacy|remap]"
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
FPGA_BIN_CONFIGS_EXTRA=""
XRT_MEM_MAP_OVERRIDE=""

resolve_fpga_bin() {
  local fpga_bin="$1"
  local resolved
  local resolver_args=(--alias-map "${FPGA_BIN_ALIAS_MAP}")
  if [[ -n "${XRT_MEM_MAP_OVERRIDE}" ]]; then
    resolver_args+=(--xrt-mem-map "${XRT_MEM_MAP_OVERRIDE}")
  fi
  resolved="$("${PYTHON_BIN}" "${FPGA_BIN_ALIAS_RESOLVER}" "${resolver_args[@]}" "${fpga_bin}")"
  FPGA_BIN_DIR="$(printf '%s\n' "${resolved}" | sed -n '1p')"
  FPGA_BIN_CONFIGS_EXTRA="$(printf '%s\n' "${resolved}" | sed -n '2p')"
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
    --xrt-mem-map)
      XRT_MEM_MAP_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--xrt-mem-map legacy|remap]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--xrt-mem-map legacy|remap]"
      exit 1
      ;;
  esac
done

if [[ -n "${XRT_MEM_MAP_OVERRIDE}" && "${XRT_MEM_MAP_OVERRIDE}" != "legacy" && "${XRT_MEM_MAP_OVERRIDE}" != "remap" ]]; then
  echo "Invalid --xrt-mem-map: ${XRT_MEM_MAP_OVERRIDE}"
  exit 1
fi

resolve_fpga_bin "${FPGA_BIN}"

# Base CONFIGS exported by hw_config.sh (via .envrc). Append script-specific flags.
CONFIGS="${CONFIGS:-}"
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"
CONFIGS+=" -DWLOAD_AT_ONCE"

if [[ -n "${FPGA_BIN_CONFIGS_EXTRA}" ]]; then
  CONFIGS+=" ${FPGA_BIN_CONFIGS_EXTRA}"
fi

if [[ -n "${CONFIGS_EXTRA}" ]]; then
  CONFIGS+=" ${CONFIGS_EXTRA}"
fi

NUM_CORES=1
NUM_THREADS=8
DEBUG_LEVEL=3

# ----------------------------------------------------------------------------
# - rtlsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "rtlsim" || "${mode}" == "all" ]]; then
  CONFIGS="${CONFIGS}" \
  DRIVER=rtlsim \
  ./ci/blackbox.sh --cores=${NUM_CORES} --threads=${NUM_THREADS} --driver=rtlsim --app=${APP} --args="${ARGS}" --debug=${DEBUG_LEVEL}
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
  ./ci/blackbox.sh --debug=${DEBUG_LEVEL} --cores=${NUM_CORES} --driver=xrt --app=${APP} --args="${ARGS}"
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
  CONFIGS="${CONFIGS} -DNDEBUG" \
  DRIVER=xrt_vcs \
  FSDB_DUMP=1 \
  DEBUG_AXI=1 \
  ./ci/blackbox.sh --debug=${DEBUG_LEVEL} --cores=${NUM_CORES} --driver=xrt_vcs --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - xrt-vcs-pgsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "xrt-vcs-pgsim" || "${mode}" == "all" ]]; then
  DRAM_REQ_STALL_P_ENTER_PCT=70 \
  DRAM_REQ_STALL_P_EXIT_PCT=30 \
  DRAM_RSP_STALL_P_ENTER_PCT=70 \
  DRAM_RSP_STALL_P_EXIT_PCT=30 \
  DRAM_STALL_SEED=1234 \
  CONFIGS=${CONFIGS} \
  DRIVER=xrt_vcs_post \
  FSDB_DUMP=1 \
  DEBUG_AXI=1 \
  GUI=1 \
  NETLIST=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/gate_sim/vortex_afu_funcsim.v \
  ./ci/blackbox.sh --cores=${NUM_CORES} --threads=${NUM_THREADS} --driver=xrt_vcs_post --app=${APP} --args="${ARGS}" --debug=${DEBUG_LEVEL}
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
  DEBUG_LEVEL=${DEBUG_LEVEL} \
  ./ci/blackbox.sh --cores=${NUM_CORES} --threads=${NUM_THREADS} --driver=xrt --app=${APP} --args="${ARGS}" --debug=${DEBUG_LEVEL}
fi

# ----------------------------------------------------------------------------
# - hw
# ----------------------------------------------------------------------------
if [[ "${mode}" == "hw" || "${mode}" == "all" ]]; then
  echo "HW FPGA_BIN=${FPGA_BIN} FPGA_BIN_DIR=${FPGA_BIN_DIR} FPGA_BIN_CONFIGS_EXTRA=${FPGA_BIN_CONFIGS_EXTRA}"
  srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00 --pty bash -c "\
  CONFIGS=\"${CONFIGS}\" \
  FPGA_BIN_DIR=\"${FPGA_BIN_DIR}\" \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw \
  ./ci/blackbox.sh --threads=${NUM_THREADS} --cores=${NUM_CORES} --driver=xrt --app=${APP} --args=\"${ARGS}\" | tee bb.log
  "
  # CHIPSCOPE=1 \
fi
