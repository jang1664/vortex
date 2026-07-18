#!/usr/bin/env bash
#
# run_hw_test.sh — run torch_vortex native-op tests on the REAL U55C FPGA (xrt driver).
#
# The team's test_loop.sh is hardcoded to a single test (test_native_mm.py) with
# another user's absolute paths. This is the generalized, checkout-local version:
# pass one or more ops (or "all"), pick a device, and it drives the real board.
#
# Usage:
#   ./run_hw_test.sh <op> [op2 ...]        # run specific ops
#   ./run_hw_test.sh all                   # run every available op
#   ./run_hw_test.sh -d 0 rmsnorm silu     # -d/--device selects XRT device index
#   ./run_hw_test.sh -l                    # -l/--list available ops and exit
#
# Examples:
#   ./run_hw_test.sh rmsnorm               # rmsnorm on device 1 (default)
#   ./run_hw_test.sh rmsnorm rope silu     # three ops in sequence
#   ./run_hw_test.sh -d 0 all              # everything on device 0
#
# Success sign: each run's log prints  device name=xilinx_u55c_gen3x16...
# (if that line is absent you're on simx, not the real board.)
#
# NOTE: for shared-cluster etiquette, prefer running this INSIDE a SLURM
# allocation, e.g.:
#   srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=2:00:00 --pty bash
# then invoke this script.  Running it bare (outside SLURM) can collide with a
# teammate's reserved board.

set -uo pipefail

# --- locate the checkout relative to this script (no hardcoded home paths) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/test"

# --- tunables (override via env before calling) ---
# DEVICE is auto-selected below (SLURM-aware). Only an explicit -d flag or a
# preset XRT_DEVICE_INDEX pins it; otherwise we detect the accessible board.
# update FPGA_BIN_DIR to point to your own xclbin
DEVICE=""
DEVICE_SET=""
if [[ -n "${XRT_DEVICE_INDEX:-}" ]]; then DEVICE="$XRT_DEVICE_INDEX"; DEVICE_SET=1; fi
# Default bitstream: 8d9b4939d1 (alias improve_th16_tcol32_hwexp_dcache, "pack16" w/ per-group scale fix),
# alias `improve_th16_tcol32_hwexp_dcache`: NUM_THREADS=16, MXU 32x32, and it is
# the first fpint bitstream that actually instantiates the GEMM engine
# (-DENABLE_GEMM_ACCEL) without hanging. Required for mm_w4a16_opt.
FPGA_BIN_DIR="${FPGA_BIN_DIR:-/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin}"
# Compile-time CONFIGS must match how the bitstream was synthesized, else the
# host driver / kernel address maps disagree with the hardware. Sourced below.
CONFIG_FILE="${CONFIG_FILE:-$VORTEX_HOME/configs/improve_th16_tcol32_hwexp_dcache.sh}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-12.8}"
CONDA_ENV="${CONDA_ENV:-vortex}"

# --- discover available ops: map op-name -> test file ---------------------------
# Handles both `test_native_<op>.py` and other standalone tests that don't use the
# native_ prefix (e.g. test_mm_w4a16_opt.py, the FP-INT TCU layout-optimized GEMM).
# Add more filenames to the `ls` list below to expose additional standalone tests.
declare -A OP_FILE
while IFS= read -r f; do
  op="${f#test_}"; op="${op#native_}"; op="${op%.py}"   # strip test_ / native_ / .py
  OP_FILE["$op"]="$f"
done < <(cd "$TEST_DIR" 2>/dev/null && \
  ls test_native_*.py test_mm_w4a16_opt.py test_mm_w4a16_gemm_core_hw.py \
     test_spinquant_layer_accuracy_vortex_ops.py \
     test_spinquant_layer_accuracy_vortex_integration.py 2>/dev/null | sort -u)
OP_FILE["spinquant_layer_accuracy_vortex_integration_full"]="test_spinquant_layer_accuracy_vortex_integration.py"
mapfile -t AVAIL < <(printf '%s\n' "${!OP_FILE[@]}" | sort)

list_ops() { printf '  %s\n' "${AVAIL[@]}"; }

# --- arg parsing ---
OPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device) DEVICE="$2"; DEVICE_SET=1; shift 2 ;;
    -l|--list)   echo "Available ops:"; list_ops; exit 0 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    all)         OPS=("${AVAIL[@]}"); shift ;;
    -*)          echo "Unknown flag: $1" >&2; exit 2 ;;
    *)           OPS+=("$1"); shift ;;
  esac
done

if [[ ${#OPS[@]} -eq 0 ]]; then
  echo "Usage: $(basename "$0") <op> [op2 ...] | all   (-l to list, -h for help)" >&2
  echo "Available ops:" >&2; list_ops >&2
  exit 2
fi

# --- validate requested ops ---
for op in "${OPS[@]}"; do
  if [[ -z "${OP_FILE[$op]:-}" ]]; then
    echo "ERROR: no test for op '$op' (no matching test file in $TEST_DIR)" >&2
    echo "Available ops:" >&2; list_ops >&2
    exit 2
  fi
done

# --- conda env ---
if [[ -f /opt/anaconda3/etc/profile.d/conda.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/anaconda3/etc/profile.d/conda.sh
  conda activate "$CONDA_ENV"
fi

# --- XRT runtime (real FPGA driver) ---
if [[ -f /opt/xilinx/xrt/setup.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/xilinx/xrt/setup.sh >/dev/null 2>&1
else
  echo "WARNING: /opt/xilinx/xrt/setup.sh not found — XRT may not be initialized." >&2
fi

# --- pick the FPGA device index (SLURM-aware) ---------------------------------
# CRITICAL: XRT numbers devices GLOBALLY (0 -> 2a:00.1, 1 -> 3d:00.1), NOT
# cgroup-locally. Inside a SLURM allocation the granted board is the only one
# visible, but its XRT index is still its global index. A naive "probe --device
# N --report platform" fails with EPERM for every N inside the cgroup (that
# report needs mgmt-pf access), so it can't tell you the index. Opening the
# WRONG index (e.g. 0 when you were granted 3d = index 1) hits a board you don't
# own -> EPERM -> the Vortex XRT runtime dereferences a bad handle -> SEGFAULT.
#
# The team's ci/xrt_device_detect.sh already solves this: when numeric probing
# fails it falls back to parsing the single available BDF and mapping it to the
# global index. Reuse it instead of rolling our own.
DEVICE_DETECTOR="$VORTEX_HOME/ci/xrt_device_detect.sh"
if [[ -z "$DEVICE_SET" ]]; then
  if [[ -f "$DEVICE_DETECTOR" ]]; then
    # shellcheck disable=SC1090
    source "$DEVICE_DETECTOR"
    SMI="$(resolve_xrt_smi)"
    if DEVICE="$(detect_single_accessible_xrt_index "$SMI" 2>/dev/null)"; then
      echo "[info] resolved XRT_DEVICE_INDEX=$DEVICE (via team detector; SLURM_JOB_ID=${SLURM_JOB_ID:-none})"
    else
      DEVICE=""
      echo "[error] ci/xrt_device_detect.sh could not resolve an accessible XRT device." >&2
      echo "        Inside SLURM: board may not be granted. Outside SLURM: another job holds it." >&2
      echo "        Check: squeue -p fpga ; $VORTEX_HOME/tools/vortex-smi" >&2
    fi
  else
    echo "[warn] $DEVICE_DETECTOR not found; falling back to device 1 (3d:00.1)." >&2
    DEVICE=1
  fi
  if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "[warn] not inside a SLURM allocation — you may clash with a teammate's board." >&2
    echo "       reserve one first:  srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=2:00:00 --pty bash" >&2
  fi
fi

# --- compile-time CONFIGS to match the bitstream (see e440499 alias map) ------
# The bitstream at FPGA_BIN_DIR was synthesized with a specific set of -D
# defines. The host driver + device kernels must be built with the SAME defines
# so their register/memory maps agree with the hardware. Sourcing the alias
# config exports $CONFIGS into the environment for any (re)build in this shell.
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  export CONFIGS
  echo "[info] sourced CONFIGS from $CONFIG_FILE"
else
  echo "WARNING: CONFIG_FILE not found: $CONFIG_FILE" >&2
  echo "         CONFIGS not exported; a rebuilt driver/kernel may mismatch the bitstream." >&2
fi

# --- runtime env (mirrors report §4-B + team test_loop.sh conventions) ---
export VORTEX_HOME
export CUDA_HOME
export PYTHONPATH="$VORTEX_HOME/pytorch/spinquant:$VORTEX_HOME/pytorch${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$VORTEX_HOME/build/runtime:${LD_LIBRARY_PATH:-}"
export VORTEX_DRIVER=xrt
export RUN_VORTEX_TESTS=1
if [[ -z "$DEVICE" ]]; then
  echo "[fatal] no usable XRT device index resolved; aborting before the runtime segfaults on a board you don't own." >&2
  exit 3
fi
export XRT_DEVICE_INDEX="$DEVICE"
export FPGA_BIN_DIR                       # absolute -> robust regardless of cwd
export XILINX_XRT="${XILINX_XRT:-/opt/xilinx/xrt}"

# CRITICAL: the xrt.ini shipped next to each vortex_afu.xclbin enables profiling
# ([Debug] profile=true, device_trace=fine). With profiling on, xclOpen() dlopens
# libxdp_hal_device_offload_plugin.so, whose constructor SEGFAULTS in this XRT
# install -- crashing the process during device init, before any op runs. The
# team's ci/run_black.sh avoids this by forcing XRT_INI_PATH=/dev/null (no ini ->
# no profiling -> no XDP plugin). torch_vortex's __init__ does NOT, so it would
# otherwise pick up the bin-dir xrt.ini and crash. Force it off here too.
export XRT_INI_PATH="${XRT_INI_PATH:-/dev/null}"

if [[ ! -f "$FPGA_BIN_DIR/vortex_afu.xclbin" ]]; then
  echo "WARNING: no vortex_afu.xclbin under FPGA_BIN_DIR=$FPGA_BIN_DIR" >&2
  echo "         override with:  FPGA_BIN_DIR=<dir> $(basename "$0") ..." >&2
fi

echo "=================================================================="
echo " torch_vortex on REAL FPGA (U55C)"
echo "   VORTEX_HOME   = $VORTEX_HOME"
echo "   device index  = $XRT_DEVICE_INDEX"
echo "   FPGA_BIN_DIR  = $FPGA_BIN_DIR"
echo "   CONFIG_FILE   = $CONFIG_FILE"
echo "   ops           = ${OPS[*]}"
echo "=================================================================="

cd "$TEST_DIR" || { echo "ERROR: cannot cd to $TEST_DIR" >&2; exit 1; }

# --- run each op, track pass/fail (init empty; set -u treats unset arrays as errors) ---
PASSED=()
FAILED=()
rc_all=0
for op in "${OPS[@]}"; do
  echo
  echo ">>> [$op] python ${OP_FILE[$op]}  (device $XRT_DEVICE_INDEX)"
  echo "------------------------------------------------------------------"
  if [[ "$op" == "spinquant_layer_accuracy_vortex_integration_full" ]]; then
    RUN_SPINQUANT_FUSED_FULL=1 python "${OP_FILE[$op]}"
    rc=$?
  else
    python "${OP_FILE[$op]}"
    rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    PASSED+=("$op")
  else
    FAILED+=("$op")
    rc_all=1
  fi
done

# --- summary ---
echo
echo "=================================================================="
echo " SUMMARY (device $XRT_DEVICE_INDEX)"
[[ ${#PASSED[@]} -gt 0 ]] && echo "   PASS: ${PASSED[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && echo "   FAIL: ${FAILED[*]}"
echo "=================================================================="
echo "Tip: confirm real HW ran by looking for 'device name=xilinx_u55c_gen3x16...' above."
exit "$rc_all"
