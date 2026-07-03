#!/bin/bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
FPGA_BIN_ALIAS_RESOLVER="${SCRIPT_DIR}/resolve_fpga_bin_alias.py"
FPGA_BIN_ALIAS_MAP="${VORTEX_FPGA_BIN_ALIAS_MAP:-${SCRIPT_DIR}/fpga_bin_alias_map.yaml}"
XRT_DEVICE_DETECTOR="${SCRIPT_DIR}/xrt_device_detect.sh"
if [[ ! -f "${FPGA_BIN_ALIAS_RESOLVER}" && -f "../ci/resolve_fpga_bin_alias.py" ]]; then
  FPGA_BIN_ALIAS_RESOLVER="$(realpath ../ci/resolve_fpga_bin_alias.py)"
fi
if [[ ! -f "${FPGA_BIN_ALIAS_MAP}" && -f "../ci/fpga_bin_alias_map.yaml" ]]; then
  FPGA_BIN_ALIAS_MAP="$(realpath ../ci/fpga_bin_alias_map.yaml)"
fi
if [[ ! -f "${XRT_DEVICE_DETECTOR}" && -f "../ci/xrt_device_detect.sh" ]]; then
  XRT_DEVICE_DETECTOR="$(realpath ../ci/xrt_device_detect.sh)"
fi

list_fpga_bin_aliases() {
  "${PYTHON_BIN}" "${FPGA_BIN_ALIAS_RESOLVER}" --alias-map "${FPGA_BIN_ALIAS_MAP}" --list 2>/dev/null || true
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--no-srun] [--no-latency] [--power[=on|off]] [--power-out-dir DIR] [--power-auto-duration] [--power-max-iterations N]"
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
  echo "  --no-srun"
  echo "      Run hw mode directly instead of launching through srun"
  echo "  --no-latency"
  echo "      Skip the normal bench latency phase"
  echo "  --power[=on|off]"
  echo "      Enable separate bench power measurement and append matching --power args"
  echo "  --power-out-dir DIR"
  echo "      Directory for default power.csv and power_summary.csv"
  echo "  --power-csv-max-bytes N"
  echo "      Raw power CSV size limit in bytes (default: 1048576, 0 unlimited)"
  echo "  --power-auto-duration, --no-power-auto-duration"
  echo "      Forward bench auto-duration control when power measurement is enabled"
  echo "  --power-min-run-sec N, --power-max-run-sec N, --power-target-samples N"
  echo "      Auto-duration planning bounds"
  echo "  --power-max-iterations N"
  echo "      Auto-duration hard iteration cap (0 unlimited)"
  echo "  --power-min-interval N, --power-max-interval N"
  echo "      Auto-duration sampler interval bounds in seconds"
  aliases="$(list_fpga_bin_aliases)"
  if [[ -n "${aliases}" ]]; then
    echo "FPGA bin aliases: ${aliases}"
  fi
  exit 0
fi

mode="${1:-}"
shift || true

if [[ "${mode}" == "" ]]; then
  echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--no-srun] [--no-latency] [--power[=on|off]] [--power-out-dir DIR] [--power-auto-duration] [--power-max-iterations N]"
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
FPGA_BIN=naive_gemm
FPGA_BIN_DIR=""
FPGA_BIN_CONFIGS=""
BENCH_FLAG=""
PERF_FLAG=""
DEBUG_FLAG=""
HW_DEBUG=0
USE_SRUN=1
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
POWER_AUTO_DURATION=""
POWER_MIN_RUN_SEC=""
POWER_MAX_RUN_SEC=""
POWER_MAX_ITERATIONS=""
POWER_TARGET_SAMPLES=""
POWER_MIN_INTERVAL=""
POWER_MAX_INTERVAL=""
LATENCY_ENABLED=1

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
    configs+=" -DDBG_TRACE_GEMM_CTRL"
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

append_latency_args() {
  if [[ "${LATENCY_ENABLED}" == "0" ]]; then
    BENCH_FLAG="--bench"
    append_arg "--no-latency"
  fi
}

append_power_args() {
  case "${POWER_MODE}" in
    ""|off|false|0)
      return
      ;;
    separate|on|true|1)
      POWER_MODE="separate"
      ;;
    *)
      echo "Unsupported --power mode: ${POWER_MODE}; supported modes are on, separate, and off" >&2
      exit 1
      ;;
  esac

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
  if [[ -n "${POWER_AUTO_DURATION}" ]]; then
    append_arg "--power-auto-duration=${POWER_AUTO_DURATION}"
  fi
  if [[ -n "${POWER_MIN_RUN_SEC}" ]]; then
    append_arg "--power-min-run-sec=${POWER_MIN_RUN_SEC}"
  fi
  if [[ -n "${POWER_MAX_RUN_SEC}" ]]; then
    append_arg "--power-max-run-sec=${POWER_MAX_RUN_SEC}"
  fi
  if [[ -n "${POWER_MAX_ITERATIONS}" ]]; then
    append_arg "--power-max-iterations=${POWER_MAX_ITERATIONS}"
  fi
  if [[ -n "${POWER_TARGET_SAMPLES}" ]]; then
    append_arg "--power-target-samples=${POWER_TARGET_SAMPLES}"
  fi
  if [[ -n "${POWER_MIN_INTERVAL}" ]]; then
    append_arg "--power-min-interval=${POWER_MIN_INTERVAL}"
  fi
  if [[ -n "${POWER_MAX_INTERVAL}" ]]; then
    append_arg "--power-max-interval=${POWER_MAX_INTERVAL}"
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
    --no-srun)
      USE_SRUN=0
      shift
      ;;
    --no-latency|--skip-latency)
      LATENCY_ENABLED=0
      shift
      ;;
    --latency)
      LATENCY_ENABLED=1
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
    --power-auto-duration)
      POWER_AUTO_DURATION="on"
      if [[ $# -gt 1 && "${2:0:1}" != "-" ]]; then
        POWER_AUTO_DURATION="$2"
        shift 2
      else
        shift
      fi
      ;;
    --power-auto-duration=*)
      POWER_AUTO_DURATION="${1#*=}"
      shift
      ;;
    --no-power-auto-duration)
      POWER_AUTO_DURATION="off"
      shift
      ;;
    --power-min-run-sec)
      POWER_MIN_RUN_SEC="$2"
      shift 2
      ;;
    --power-min-run-sec=*)
      POWER_MIN_RUN_SEC="${1#*=}"
      shift
      ;;
    --power-max-run-sec)
      POWER_MAX_RUN_SEC="$2"
      shift 2
      ;;
    --power-max-run-sec=*)
      POWER_MAX_RUN_SEC="${1#*=}"
      shift
      ;;
    --power-max-iterations)
      POWER_MAX_ITERATIONS="$2"
      shift 2
      ;;
    --power-max-iterations=*)
      POWER_MAX_ITERATIONS="${1#*=}"
      shift
      ;;
    --power-target-samples)
      POWER_TARGET_SAMPLES="$2"
      shift 2
      ;;
    --power-target-samples=*)
      POWER_TARGET_SAMPLES="${1#*=}"
      shift
      ;;
    --power-min-interval)
      POWER_MIN_INTERVAL="$2"
      shift 2
      ;;
    --power-min-interval=*)
      POWER_MIN_INTERVAL="${1#*=}"
      shift
      ;;
    --power-max-interval)
      POWER_MAX_INTERVAL="$2"
      shift 2
      ;;
    --power-max-interval=*)
      POWER_MAX_INTERVAL="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--no-srun] [--no-latency] [--power[=on|off]] [--power-out-dir DIR] [--power-auto-duration] [--power-max-iterations N]"
      echo "  --hw-debug, --enable-hw-debug-module: append -DENABLE_HW_DEBUG_MODULE to CONFIGS"
      echo "  --no-srun: run hw mode directly instead of launching through srun"
      echo "  --no-latency: append --no-latency to bench args"
      echo "  --power[=on|off]: append separate bench power-measurement args"
      echo "  --power-csv-max-bytes N: raw power CSV size limit (default: 1048576, 0 unlimited)"
      echo "  --power-auto-duration, --no-power-auto-duration: forward bench auto-duration control"
      echo "  --power-max-iterations N: auto-duration hard iteration cap (0 unlimited)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <mode> [--app APP] [--args \"...\"] [--configs-extra \"...\"] [--fpga-bin ALIAS_OR_PATH] [--bench] [--perf CLASS] [--debug LEVEL] [--hw-debug] [--no-srun]"
      exit 1
      ;;
  esac
done

append_latency_args
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
# CACHE_REQ_STALL_P_ENTER_PCT=0 \
# CACHE_REQ_STALL_P_EXIT_PCT=100 \
# CACHE_RSP_STALL_P_ENTER_PCT=0 \
# CACHE_RSP_STALL_P_EXIT_PCT=100 \
# CACHE_STALL_SEED=1234 \
if [[ "${mode}" == "xrt-vcs-sim" || "${mode}" == "all" ]]; then
  xrt_vcs_env=(
    "CONFIGS=${CONFIGS}"
    "DRIVER=xrt_vcs"
    "FSDB_DUMP=1"
    "DRAM_REQ_STALL_P_ENTER_PCT=50"
    "DRAM_REQ_STALL_P_EXIT_PCT=50"
    "DRAM_RSP_STALL_P_ENTER_PCT=50"
    "DRAM_RSP_STALL_P_EXIT_PCT=50"
    "DRAM_STALL_SEED=1234"
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
  HW_COMMAND="\
  source \"${XRT_DEVICE_DETECTOR}\"; \
  if [[ -z \"\${XRT_INI_PATH:-}\" ]]; then \
    export XRT_INI_PATH=/dev/null; \
  fi; \
  if [[ -z \"\${XRT_DEVICE_INDEX:-}\" ]]; then \
    if ! XRT_DEVICE_INDEX=\"\$(resolve_fpga_id auto)\"; then \
      echo \"failed to resolve allocated XRT_DEVICE_INDEX\" >&2; \
      exit 1; \
    fi; \
    export XRT_DEVICE_INDEX; \
  fi; \
  if [[ -z \"\${XRT_DEVICE_BDF:-}\" ]]; then \
    if ! XRT_DEVICE_BDF=\"\$(resolve_xrt_user_bdf \"\${XRT_DEVICE_INDEX:-auto}\")\"; then \
      echo \"failed to resolve allocated XRT_DEVICE_BDF\" >&2; \
      exit 1; \
    fi; \
    export XRT_DEVICE_BDF; \
  fi; \
  echo \"HW XRT_DEVICE_INDEX=\${XRT_DEVICE_INDEX:-} XRT_DEVICE_BDF=\${XRT_DEVICE_BDF:-}\"; \
  echo \"HW XRT_INI_PATH=\${XRT_INI_PATH:-}\"; \
  CONFIGS=\"${CONFIGS}\" \
  FPGA_BIN_DIR=\"${FPGA_BIN_DIR}\" \
  PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 \
  DRIVER=xrt \
  TARGET=hw \
  ./ci/blackbox.sh ${BENCH_FLAG} ${PERF_FLAG} ${DEBUG_FLAG} --driver=xrt --app=${APP} --args=\"${ARGS}\"
  "
  if [[ "${USE_SRUN}" == "1" ]]; then
    srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=12:00:00 --pty bash -c "${HW_COMMAND}"
  else
    bash -c "${HW_COMMAND}"
  fi
  # CHIPSCOPE=1 \
fi
