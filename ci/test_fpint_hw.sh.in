#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "" ]]; then
  echo "Usage: $0 <mode> [extra args forwarded to test.sh]"
  echo "Modes:"
  echo "  rtlsim       - Run rtlsim test"
  echo "  xrt-vcs-sim  - Run xrt + VCS RTL sim test"
  echo "  hw_emu       - Run xrt + hw_emu test"
  echo "  hw           - Run FPGA test"
  echo "  all          - Run all of the above in order"
  echo "Options:"
  echo "  --debug-arg=always|omit|auto"
  echo "  --debug-always | --debug-omit | --debug-auto"
  exit 0
fi

mode="${1}"
shift

DEBUG_ARG_MODE="always"
declare -a FORWARD_ARGS=()

for arg in "$@"; do
  case "${arg}" in
    --debug-arg=always|--debug-arg=omit|--debug-arg=auto)
      DEBUG_ARG_MODE="${arg#*=}"
      ;;
    --debug-always)
      DEBUG_ARG_MODE="always"
      ;;
    --debug-omit)
      DEBUG_ARG_MODE="omit"
      ;;
    --debug-auto)
      DEBUG_ARG_MODE="auto"
      ;;
    --debug-arg=*)
      echo "ERROR: invalid debug arg mode: ${arg#*=} (expected always, omit, or auto)" >&2
      exit 1
      ;;
    *)
      FORWARD_ARGS+=("${arg}")
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
CONFIGS+=" -DNUM_CORES=1"

# ------------------------------------------------------------------------
# - Add DBG flag if you want
# ------------------------------------------------------------------------
# CONFIGS+=" -DDBG_TRACE_PIPELINE"
# CONFIGS+=" -DDBG_TRACE_MEM"
# CONFIGS+=" -DDBG_TRACE_CACHE"
# CONFIGS+=" -DDBG_TRACE_AFU"
# CONFIGS+=" -DDBG_TRACE_SCOPE"
# CONFIGS+=" -DDBG_TRACE_GBAR"
# CONFIGS+=" -DDBG_TRACE_TCU"
# CONFIGS+=" -DDBG_TRACE_GEMM"
# CONFIGS+=" -DVCD_OUTPUT"

export VERILATOR_SEED=$((RANDOM + 1))

DEBUG_LEVEL=0

if [[ "${DEBUG_LEVEL}" -eq 0 ]]; then
  if [[ "${CONFIGS}" == *"-DVCD_OUTPUT"* ]]; then
    # drop VCD_OUTPUT if DEBUG_LEVEL is 0, since it generates huge log files and isn't useful without debug messages
    CONFIGS="${CONFIGS//-DVCD_OUTPUT/}"
  fi
fi

export CONFIGS
# ------------------------------------------------------------------------
# - clean if you want
# ------------------------------------------------------------------------
# make -C runtime/rtlsim clean

# ------------------------------------------------------------------------
# - rtlsim
# ------------------------------------------------------------------------
if [[ "${mode}" == "rtlsim" || "${mode}" == "all" ]]; then
  set +e
  DRIVER=rtlsim \
  DEBUG_LEVEL=${DEBUG_LEVEL} \
  bash tests/regression/fpint_gemm_ffn_hw_improve/test.sh --debug-arg="${DEBUG_ARG_MODE}" "${FORWARD_ARGS[@]}"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "ERROR: rtlsim test exited with code $rc (signal=$(( rc > 128 ? rc - 128 : 0 )))"
    exit $rc
  fi
fi

# ------------------------------------------------------------------------
# - xrt-vcs-sim (xrt runtime + VCS RTL simv)
# ------------------------------------------------------------------------
if [[ "${mode}" == "xrt-vcs-sim" || "${mode}" == "all" ]]; then
  DRIVER=xrt_vcs \
  DEBUG_LEVEL=${DEBUG_LEVEL} \
  FSDB_DUMP=1 \
  DEBUG_AXI=1 \
  bash tests/regression/fpint_gemm_ffn_hw_improve/test.sh --debug-arg="${DEBUG_ARG_MODE}" "${FORWARD_ARGS[@]}"
fi

# ------------------------------------------------------------------------
# - xrt + hw_emu
# ------------------------------------------------------------------------
if [[ "${mode}" == "hw_emu" || "${mode}" == "all" ]]; then
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw_emu/bin \
  TARGET=hw_emu \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  DEBUG_LEVEL=${DEBUG_LEVEL} \
  bash tests/regression/fpint_gemm_ffn_hw_improve/test.sh --debug-arg="${DEBUG_ARG_MODE}" "${FORWARD_ARGS[@]}"
fi

# ------------------------------------------------------------------------
# - FPGA
# ------------------------------------------------------------------------
if [[ "${mode}" == "hw" || "${mode}" == "all" ]]; then
  FPGA_BIN_DIR=/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin \
  TARGET=hw \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  CHIPSCOPE=1 \
  DEBUG_LEVEL=${DEBUG_LEVEL} \
  bash tests/regression/fpint_gemm_ffn_hw_improve/test.sh --debug-arg="${DEBUG_ARG_MODE}" "${FORWARD_ARGS[@]}"
fi
