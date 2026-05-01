#!/bin/bash
# Bash port of ci/test_fpint_hw.py — same sweep, same arg surface.
# Runs ci/blackbox.sh across (shape x QBLK x WTRANS x QDIR) for each backend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: test_fpint_hw.sh --mode <mode> [options] [--] [case args ...]
       test_fpint_hw.sh --model list

Modes:
  rtlsim       - Run rtlsim test
  xrt-vcs-sim  - Run xrt + VCS RTL sim test
  hw_emu       - Run xrt + hw_emu test
  hw           - Run FPGA test
  all          - Run all of the above in order

Options:
  --mode MODE              Backend mode (required unless --model list)
  --debug-level N          DEBUG_LEVEL env value (default: -1)
  --model NAME             Test only GEMM shapes from a known model config
                           ('--model list' prints registry and exits)
  --seq-lens CSV           Comma-separated seq lens for --model mode

Case args:
  Without --model, unknown args are treated as case args.
  Empty case args select the default sweep.
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
MODE=""
DEBUG_LEVEL="-1"
MODEL=""
SEQ_LENS=""
declare -a POS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --mode)         MODE="$2";        shift 2 ;;
    --mode=*)       MODE="${1#*=}";   shift ;;
    --debug-level)  DEBUG_LEVEL="$2"; shift 2 ;;
    --debug-level=*) DEBUG_LEVEL="${1#*=}"; shift ;;
    --model)        MODEL="$2";       shift 2 ;;
    --model=*)      MODEL="${1#*=}";  shift ;;
    --seq-lens)     SEQ_LENS="$2";    shift 2 ;;
    --seq-lens=*)   SEQ_LENS="${1#*=}"; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do POS+=("$1"); shift; done ;;
    *)  POS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# --model list shortcut
# ---------------------------------------------------------------------------
if [[ "${MODEL}" == "list" ]]; then
  REPO_ROOT_ENV="${REPO_ROOT}" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT_ENV"], "tools", "workload"))
from gen_kernel_cfgs import print_model_registry
print_model_registry()
'
  exit 0
fi

if [[ -z "${MODE}" ]]; then
  echo "ERROR: --mode is required (except with --model list)" >&2
  exit 2
fi

case "${MODE}" in
  rtlsim|xrt-vcs-sim|hw_emu|hw|all) ;;
  *) echo "ERROR: unknown mode: ${MODE}" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Kernel shape constraints (mirrors main.cpp validate block).
# ---------------------------------------------------------------------------
MXU_NT=32
MXU_KT=32
DMA_KT=128
DEFAULT_QBLKS=(32 64 128)
DEFAULT_WTRANS=(0 1)
DEFAULT_QDIR=(0 1)

DEFAULT_SHAPES=(
  "-m 1 -n 32 -k 32"
  "-m 32 -n 32 -k 32"
  "-m 128 -n 32 -k 32"
  "-m 128 -n 128 -k 64"
  "-m 128 -n 128 -k 96"
  "-m 256 -n 256 -k 256"
)

# Parse '-m M -n N -k K -q Q -t T -d D' into "M N K Q T D".
# Defaults match the .py: m=2, n=32, k=128, q=32, t=0, d=0.
parse_shape() {
  local args="$1"
  local M=2 N=32 K=128 Q=32 T=0 D=0
  # shellcheck disable=SC2206
  local -a tokens=( $args )
  local i=0
  while (( i < ${#tokens[@]} )); do
    local tok="${tokens[$i]}"
    case "$tok" in
      -m) M="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      -n) N="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      -k) K="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      -q) Q="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      -t) T="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      -d) D="${tokens[$((i+1))]}"; i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done
  echo "$M $N $K $Q $T $D"
}

# Echo human-readable reason and return 1 if invalid; return 0 if valid.
check_constraints() {
  local M=$1 N=$2 K=$3 Q=$4 T=$5 D=$6
  if (( N <= 0 || N % MXU_NT != 0 )); then
    echo "N=$N must be positive multiple of MXU_NT=$MXU_NT"; return 1
  fi
  if (( K <= 0 || K % MXU_KT != 0 )); then
    echo "K=$K must be positive multiple of MXU_KT=$MXU_KT"; return 1
  fi
  if (( Q <= 0 )); then
    echo "QBLK=$Q must be positive"; return 1
  fi
  if [[ "$T" != "0" && "$T" != "1" ]]; then
    echo "WTRANS=$T must be 0 or 1"; return 1
  fi
  if [[ "$D" != "0" && "$D" != "1" ]]; then
    echo "QDIR=$D must be 0 or 1"; return 1
  fi
  if (( D == 0 )); then
    if (( DMA_KT % Q != 0 )); then
      echo "QCOL: DMA_KT=$DMA_KT not divisible by QBLK=$Q"; return 1
    fi
    if (( K % Q != 0 )); then
      echo "QCOL: K=$K not divisible by QBLK=$Q"; return 1
    fi
  else
    if (( N % Q != 0 )); then
      echo "QROW: N=$N not divisible by QBLK=$Q"; return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Build CASE_ARGS
# ---------------------------------------------------------------------------
declare -a CASE_ARGS=()

if [[ -n "${MODEL}" ]]; then
  if (( ${#POS[@]} > 0 )); then
    echo "ERROR: --model and positional case args are mutually exclusive" >&2
    exit 2
  fi
  mapfile -t CASE_ARGS < <(
    REPO_ROOT_ENV="${REPO_ROOT}" \
    MODEL_ENV="${MODEL}" \
    SEQ_LENS_ENV="${SEQ_LENS}" \
    python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT_ENV"], "tools", "workload"))
from gen_kernel_cfgs import (
    DEFAULT_QBLKS, parse_seq_lens_csv, build_fpint_gemm_args_for_model,
)
seq_raw = os.environ.get("SEQ_LENS_ENV") or None
seq_lens = parse_seq_lens_csv(seq_raw)
cases = build_fpint_gemm_args_for_model(
    os.environ["MODEL_ENV"], seq_lens, qblks=DEFAULT_QBLKS,
    batch=1, stages=("prefill",),
)
for c in cases:
    print(c)
'
  )
  echo "# model=${MODEL}  seq_lens=${SEQ_LENS:-default}  cases=${#CASE_ARGS[@]}"
else
  if [[ -n "${SEQ_LENS}" ]]; then
    echo "WARNING: --seq-lens is ignored without --model" >&2
  fi
  if (( ${#POS[@]} == 0 )); then
    for shape in "${DEFAULT_SHAPES[@]}"; do
      for q in "${DEFAULT_QBLKS[@]}"; do
        for t in "${DEFAULT_WTRANS[@]}"; do
          for d in "${DEFAULT_QDIR[@]}"; do
            CASE_ARGS+=("$shape -q $q -t $t -d $d")
          done
        done
      done
    done
  else
    # Match .py: if any positional arg has no space, treat the whole
    # list as a single case (CLI tokens); otherwise each element is a case.
    has_token=0
    for a in "${POS[@]}"; do
      if [[ "$a" != *" "* ]]; then has_token=1; break; fi
    done
    if (( has_token == 1 )); then
      CASE_ARGS=("${POS[*]}")
    else
      CASE_ARGS=("${POS[@]}")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# CONFIGS — base from hw_config.sh (.envrc), append script-specific flags.
# ---------------------------------------------------------------------------
: "${CONFIGS:=}"
EXTRAS=(
  -DNDEBUG
  -DDBG_TRACE_PIPELINE
  -DDBG_TRACE_MEM
  -DDBG_TRACE_CACHE
  -DDBG_TRACE_AFU
  -DDBG_TRACE_SCOPE
  -DDBG_TRACE_GBAR
  -DDBG_TRACE_TCU
  -DDBG_TRACE_GEMM
)
CONFIGS="${CONFIGS} ${EXTRAS[*]}"
# trim leading/trailing whitespace
CONFIGS="${CONFIGS#"${CONFIGS%%[![:space:]]*}"}"
CONFIGS="${CONFIGS%"${CONFIGS##*[![:space:]]}"}"

# Drop VCD_OUTPUT when DEBUG_LEVEL=0 (huge VCDs with no useful traces).
if [[ "${DEBUG_LEVEL}" == "0" && "${CONFIGS}" == *"-DVCD_OUTPUT"* ]]; then
  CONFIGS="${CONFIGS//-DVCD_OUTPUT/}"
fi
export CONFIGS

# ---------------------------------------------------------------------------
# Shared env
# ---------------------------------------------------------------------------
declare -a DEBUG_ARGS=()
if [[ "${DEBUG_LEVEL}" != "-1" ]]; then
  DEBUG_ARGS=("--debug=${DEBUG_LEVEL}")
fi

export VERILATOR_SEED=$((RANDOM + 1))
export DEBUG_LEVEL
: "${MAX_LOG_BYTES:=$((10 * 1024 * 1024))}"
export LOG_MAX_BYTES="${MAX_LOG_BYTES}"
export MAX_LOG_BYTES

APP="${APP:-fpint_gemm_ffn_hw}"
BASE_LOG_DIR="${LOG_DIR:-run_logs_fpint_gemm_ffn_hw}"

# ---------------------------------------------------------------------------
# Sweep runner — returns failed case count as exit code (clamped to 255).
# ---------------------------------------------------------------------------
run_sweep() {
  local driver="$1"
  local log_suffix="$2"
  shift 2
  # remaining args are KEY=VALUE env entries

  local log_dir
  if [[ "${MODE}" == "all" ]]; then
    log_dir="${BASE_LOG_DIR}${log_suffix}"
  else
    log_dir="${BASE_LOG_DIR}"
  fi
  rm -rf "${log_dir}"
  mkdir -p "${log_dir}"

  local total=${#CASE_ARGS[@]}
  local failed=0 passed=0 skipped=0

  echo "+ driver=${driver}  log_dir=${log_dir}"
  if (( $# > 0 )); then
    echo "+ env: $*"
  else
    echo "+ env: (none)"
  fi

  local i=0
  for args in "${CASE_ARGS[@]}"; do
    i=$((i+1))
    local log_file="${log_dir}/run_case_${i}.log"
    local header="[${i}/${total}] Running: ${args}"
    echo "${header}"
    echo "${header}" > "${log_file}"

    local shape_vals reason msg rc=0
    shape_vals="$(parse_shape "${args}")"
    local M N K Q T D
    read -r M N K Q T D <<< "${shape_vals}"

    if reason="$(check_constraints "$M" "$N" "$K" "$Q" "$T" "$D")"; then
      env "$@" DRIVER="${driver}" \
        ./ci/blackbox.sh \
          --driver="${driver}" \
          --app="${APP}" \
          "${DEBUG_ARGS[@]+"${DEBUG_ARGS[@]}"}" \
          --log="${log_file}" \
          --args="${args}" || rc=$?
      if (( rc == 0 )); then
        msg="[${i}/${total}] PASS (log: ${log_file})"
        passed=$((passed+1))
      else
        msg="[${i}/${total}] FAIL (log: ${log_file})"
        failed=$((failed+1))
      fi
    else
      msg="[${i}/${total}] SKIP (constraint: ${reason})"
      skipped=$((skipped+1))
    fi
    echo "${msg}"
    echo "${msg}" >> "${log_file}"
  done

  local summary="Summary [${driver}]: total=${total}, failed=${failed}, passed=${passed}, skipped=${skipped}"
  echo "${summary}"
  echo "${summary}" > "${log_dir}/summary.log"

  if (( failed > 255 )); then return 255; fi
  return $failed
}

# ---------------------------------------------------------------------------
# Per-mode dispatch
# ---------------------------------------------------------------------------
# rtlsim
if [[ "${MODE}" == "rtlsim" || "${MODE}" == "all" ]]; then
  rc=0
  run_sweep "rtlsim" "_rtlsim" || rc=$?
  if (( rc != 0 )); then
    echo "ERROR: rtlsim test reported $rc failure(s)" >&2
    exit $rc
  fi
fi

# xrt-vcs-sim (xrt runtime + VCS RTL simv)
if [[ "${MODE}" == "xrt-vcs-sim" || "${MODE}" == "all" ]]; then
  run_sweep "xrt_vcs" "_xrt_vcs" \
    FSDB_DUMP=1 DEBUG_AXI=1 || true
fi

# xrt + hw_emu
if [[ "${MODE}" == "hw_emu" || "${MODE}" == "all" ]]; then
  run_sweep "xrt" "_hw_emu" \
    FPGA_BIN_DIR="/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw_emu/bin" \
    TARGET=hw_emu \
    PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 || true
fi

# FPGA
if [[ "${MODE}" == "hw" || "${MODE}" == "all" ]]; then
  run_sweep "xrt" "_hw" \
    FPGA_BIN_DIR="/home/jaeyongjang/project.local/vortex/build/hw/syn/xilinx/xrt/hw/bin" \
    TARGET=hw \
    PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 || true
fi

exit 0
