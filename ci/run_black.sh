#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--debug LEVEL]"
  echo "Modes:"
  echo "  rtlsim   - Run only rtlsim tests"
  echo "  xrtsim   - Run only xrtsim tests"
  echo "  xrt-vcs-sim   - Run only xrt-vcs-sim tests"
  echo "  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests"
  echo "  hw_emu    - Run only hw_emu tests"
  echo "  hw        - Run only hw tests"
  exit 0
fi

mode="${1:-}"
shift || true

if [[ "${mode}" == "" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--debug LEVEL]"
  echo "Modes:"
  echo "  rtlsim   - Run only rtlsim tests"
  echo "  xrtsim   - Run only xrtsim tests"
  echo "  xrt-vcs-sim   - Run only xrt-vcs-sim tests"
  echo "  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests"
  echo "  hw_emu    - Run only hw_emu tests"
  echo "  hw        - Run only hw tests"
  exit 1
fi

APP=fpint_gemm_ffn_hw
ARGS="-m 2 -n 32 -k 128"
CONFIGS_EXTRA=""
DEBUG_FLAG=""

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
    --debug)
      DEBUG_FLAG="--debug=$2"
      shift 2
      ;;
    --debug=*)
      DEBUG_FLAG="$1"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--debug LEVEL]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--debug LEVEL]"
      exit 1
      ;;
  esac
done

# Base CONFIGS exported by hw_config.sh (via .envrc). Append script-specific flags.
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"

if [[ -n "${CONFIGS_EXTRA}" ]]; then
  CONFIGS+=" ${CONFIGS_EXTRA}"
fi

# ----------------------------------------------------------------------------
# - rtlsim
# ----------------------------------------------------------------------------
if [[ "${mode}" == "rtlsim" || "${mode}" == "all" ]]; then
  CONFIGS="${CONFIGS}" \
  DRIVER=rtlsim \
  ./ci/blackbox.sh ${DEBUG_FLAG} --driver=rtlsim --app=${APP} --args="${ARGS}"
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
  ./ci/blackbox.sh ${DEBUG_FLAG} --cores=${NUM_CORES} --driver=xrt --app=${APP} --args="${ARGS}"
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
  CONFIGS=${CONFIGS} \
  DRIVER=xrt_vcs \
  ./ci/blackbox.sh ${DEBUG_FLAG} --cores=${NUM_CORES} --driver=xrt_vcs --app=${APP} --args="${ARGS}"
fi
  # FSDB_DUMP=1 \
  # DEBUG_AXI=1 \
  # ./ci/blackbox.sh ${DEBUG_FLAG} --cores=${NUM_CORES} --driver=xrt_vcs --app=${APP} --args="${ARGS}"

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
  ./ci/blackbox.sh ${DEBUG_FLAG} --driver=xrt_vcs_post --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - hw_emu
# ----------------------------------------------------------------------------
if [[ "${mode}" == "hw_emu" || "${mode}" == "all" ]]; then
  CONFIGS=${CONFIGS} \
  FPGA_BIN_DIR=${FPGA_BIN_DIR:-${BUILD_DIR}/hw/syn/xilinx/xrt/hw_emu/bin} \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw_emu \
  ./ci/blackbox.sh ${DEBUG_FLAG} --driver=xrt --app=${APP} --args="${ARGS}"
fi

# ----------------------------------------------------------------------------
# - hw
# ----------------------------------------------------------------------------
if [[ "${mode}" == "hw" || "${mode}" == "all" ]]; then
  srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00 --pty bash -c "\
  CONFIGS=\"${CONFIGS}\" \
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex_naive/build/hw/syn/xilinx/xrt/core1_th32_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw \
  ./ci/blackbox.sh ${DEBUG_FLAG} --driver=xrt --app=${APP} --args=\"${ARGS}\" | tee bb.log
  "
  # CHIPSCOPE=1 \
fi
