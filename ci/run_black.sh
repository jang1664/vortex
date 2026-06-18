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
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--power[=MODE]] [--power-out-dir DIR]"
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
  echo "  --power[=separate|same|both|off]"
  echo "      Enable bench power measurement and append matching --power args"
  echo "  --power-out-dir DIR"
  echo "      Directory for default power.csv and power_summary.csv"
  echo "  --power-csv-max-bytes N"
  echo "      Raw power CSV size limit in bytes (default: 1048576, 0 unlimited)"
  aliases="$(list_fpga_bin_aliases)"
  if [[ -n "${aliases}" ]]; then
    echo "FPGA bin aliases: ${aliases}"
  fi
  exit 0
fi

mode="${1:-}"
shift || true

if [[ "${mode}" == "" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--power[=MODE]] [--power-out-dir DIR]"
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
POWER_MODE=""
POWER_OUT_DIR=""
POWER_CSV=""
POWER_SUMMARY=""
POWER_INTERVAL=""
POWER_FPGA_ID=""
POWER_ITERATIONS=""
POWER_IDLE_SEC=""
POWER_CSV_MAX_BYTES=1048576
POWER_SCRIPT=""

resolve_fpga_bin() {
  local fpga_bin="$1"
  local resolved
  local resolver_args=(--alias-map "${FPGA_BIN_ALIAS_MAP}")
  resolved="$("${PYTHON_BIN}" "${FPGA_BIN_ALIAS_RESOLVER}" "${resolver_args[@]}" "${fpga_bin}")"
  FPGA_BIN_DIR="$(printf '%s\n' "${resolved}" | sed -n '1p')"
  FPGA_BIN_CONFIGS="$(printf '%s\n' "${resolved}" | sed -n '2p')"
}

append_run_configs() {
  local configs="${1:-}"

  if [[ -n "${DEBUG_FLAG}" ]]; then
    configs+=" -DDBG_TRACE_PIPELINE"
    configs+=" -DDBG_TRACE_MEM"
    configs+=" -DDBG_TRACE_CACHE"
    configs+=" -DDBG_TRACE_AFU"
    configs+=" -DDBG_TRACE_SCOPE"
    configs+=" -DDBG_TRACE_GBAR"
    configs+=" -DDBG_TRACE_TCU"
    configs+=" -DDBG_TRACE_GEMM"
  fi

  if [[ "${HW_DEBUG}" == "1" ]]; then
    configs+=" -DENABLE_HW_DEBUG_MODULE"
  fi

  if [[ -n "${CONFIGS_EXTRA}" ]]; then
    configs+=" ${CONFIGS_EXTRA}"
  fi

  printf '%s' "${configs}"
}

append_arg() {
  local value="$1"
  if [[ -z "${ARGS}" ]]; then
    ARGS="${value}"
  else
    ARGS="${ARGS} ${value}"
  fi
}

append_power_args() {
  if [[ -z "${POWER_MODE}" || "${POWER_MODE}" == "off" ]]; then
    return
  fi

  BENCH_FLAG="--bench"

  if [[ -z "${POWER_OUT_DIR}" ]]; then
    POWER_OUT_DIR="$(pwd)/power_logs/$(date +%Y%m%d_%H%M%S)"
  fi
  mkdir -p "${POWER_OUT_DIR}"

  if [[ -z "${POWER_CSV}" ]]; then
    POWER_CSV="${POWER_OUT_DIR}/power.csv"
  fi
  if [[ -z "${POWER_SUMMARY}" ]]; then
    POWER_SUMMARY="${POWER_OUT_DIR}/power_summary.csv"
  fi

  append_arg "--power=${POWER_MODE}"
  append_arg "--power-csv=${POWER_CSV}"
  append_arg "--power-summary=${POWER_SUMMARY}"
  append_arg "--power-csv-max-bytes=${POWER_CSV_MAX_BYTES}"

  if [[ -n "${POWER_INTERVAL}" ]]; then
    append_arg "--power-interval=${POWER_INTERVAL}"
  fi
  if [[ -n "${POWER_FPGA_ID}" ]]; then
    append_arg "--power-fpga-id=${POWER_FPGA_ID}"
  fi
  if [[ -n "${POWER_ITERATIONS}" ]]; then
    append_arg "--power-iterations=${POWER_ITERATIONS}"
  fi
  if [[ -n "${POWER_IDLE_SEC}" ]]; then
    append_arg "--power-idle-sec=${POWER_IDLE_SEC}"
  fi
  if [[ -n "${POWER_SCRIPT}" ]]; then
    append_arg "--power-script=${POWER_SCRIPT}"
  fi

  echo "Power measurement enabled: mode=${POWER_MODE} csv=${POWER_CSV} summary=${POWER_SUMMARY} max_bytes=${POWER_CSV_MAX_BYTES}"
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
    --power)
      POWER_MODE="separate"
      if [[ $# -gt 1 && "${2:0:1}" != "-" ]]; then
        POWER_MODE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --power=*)
      POWER_MODE="${1#*=}"
      shift
      ;;
    --power-out-dir)
      POWER_OUT_DIR="$2"
      shift 2
      ;;
    --power-out-dir=*)
      POWER_OUT_DIR="${1#*=}"
      shift
      ;;
    --power-csv)
      POWER_CSV="$2"
      shift 2
      ;;
    --power-csv=*)
      POWER_CSV="${1#*=}"
      shift
      ;;
    --power-summary)
      POWER_SUMMARY="$2"
      shift 2
      ;;
    --power-summary=*)
      POWER_SUMMARY="${1#*=}"
      shift
      ;;
    --power-interval)
      POWER_INTERVAL="$2"
      shift 2
      ;;
    --power-interval=*)
      POWER_INTERVAL="${1#*=}"
      shift
      ;;
    --power-fpga-id)
      POWER_FPGA_ID="$2"
      shift 2
      ;;
    --power-fpga-id=*)
      POWER_FPGA_ID="${1#*=}"
      shift
      ;;
    --power-iterations)
      POWER_ITERATIONS="$2"
      shift 2
      ;;
    --power-iterations=*)
      POWER_ITERATIONS="${1#*=}"
      shift
      ;;
    --power-idle-sec)
      POWER_IDLE_SEC="$2"
      shift 2
      ;;
    --power-idle-sec=*)
      POWER_IDLE_SEC="${1#*=}"
      shift
      ;;
    --power-csv-max-bytes)
      POWER_CSV_MAX_BYTES="$2"
      shift 2
      ;;
    --power-csv-max-bytes=*)
      POWER_CSV_MAX_BYTES="${1#*=}"
      shift
      ;;
    --power-script)
      POWER_SCRIPT="$2"
      shift 2
      ;;
    --power-script=*)
      POWER_SCRIPT="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--power[=MODE]] [--power-out-dir DIR]"
      echo "  --hw-debug, --enable-hw-debug-module: append -DENABLE_HW_DEBUG_MODULE to CONFIGS"
      echo "  --power[=separate|same|both|off]: append bench power-measurement args"
      echo "  --power-csv-max-bytes N: raw power CSV size limit (default: 1048576, 0 unlimited)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug]"
      exit 1
      ;;
  esac
done

append_power_args

# Base CONFIGS for simulation modes comes from the environment only. FPGA bin
# aliases are resolved below in hw mode, where the alias config is required.
CONFIGS="$(append_run_configs "${CONFIGS:-}")"

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
    "FSDB_DUMP=1"
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
  resolve_fpga_bin "${FPGA_BIN}"
  if [[ -n "${FPGA_BIN_CONFIGS}" ]]; then
    if [[ ! -f "${FPGA_BIN_CONFIGS}" ]]; then
      echo "config file not found: ${FPGA_BIN_CONFIGS}" >&2
      exit 1
    fi
    source "${FPGA_BIN_CONFIGS}"
    CONFIGS="$(append_run_configs "${CONFIGS:-}")"
  fi
  echo "HW FPGA_BIN=${FPGA_BIN} FPGA_BIN_DIR=${FPGA_BIN_DIR} FPGA_BIN_CONFIGS=${FPGA_BIN_CONFIGS}"
  srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=12:00:00 --pty bash -c "\
  CONFIGS=\"${CONFIGS}\" \
  FPGA_BIN_DIR=\"${FPGA_BIN_DIR}\" \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt --app=${APP} --args=\"${ARGS}\" | tee bb.log
  "
  # CHIPSCOPE=1 \
fi
