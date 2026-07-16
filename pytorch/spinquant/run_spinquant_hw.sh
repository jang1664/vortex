#!/usr/bin/env bash
#
# run_spinquant_hw.sh — run SpinQuant W4A16 Llama-2 inference on the REAL U55C FPGA.
#
# Wraps the whole environment the Vortex XRT path needs (see the notes below) and
# launches spinquant_inference.generate through a SLURM allocation so it does not
# collide with a teammate's board.
#
# Usage:
#   ./run_spinquant_hw.sh                       # default: "Once upon a time", 1 token, debug=2
#   ./run_spinquant_hw.sh "Hello there" 8       # custom prompt + max_new_tokens
#   ./run_spinquant_hw.sh "Hello" 1 trace       # + report Vortex-native vs CPU-fallback ops
#   TRACE_OPS=1 ./run_spinquant_hw.sh           # same, via env var
#
# Why each piece is required (all learned the hard way):
#   * XRT_INI_PATH=/dev/null   — the xrt.ini next to the xclbin has profile=true,
#                                which makes xclOpen() dlopen a buggy XDP plugin
#                                whose ctor SEGFAULTs. /dev/null disables profiling.
#   * XRT_DEVICE_INDEX via team detector — XRT numbers devices GLOBALLY (3d=1),
#                                not cgroup-locally; a naive probe returns nothing
#                                inside SLURM and opening index 0 hits a board you
#                                do not own -> segfault.
#   * source configs/...sh     — exports $CONFIGS matching how the bitstream was
#                                synthesized (NUM_THREADS=16, MXU 32x32, GEMM accel).
#   * generate.py prewarms the mm_w4a16_opt kernels before the weights load, so the
#                                GEMM kernel's fixed VMA (0x80000000) is reserved
#                                before the ~3.5 GB of int4 weights fill memory.
#
# NOTE: a full 7B prefill on the board is slow (checkpoint load alone > 10 min);
# the SLURM time limit is set to 1h20 accordingly. Output is currently garbage
# because the GEMM engine's per-group scale bug (team RTL) corrupts multi-group
# logits — this script confirms the run COMPLETES, not that it is numerically right.

set -uo pipefail

PROMPT="${1:-Once upon a time}"
MAX_NEW="${2:-1}"
DEBUG="${DEBUG:-2}"
# TRACE_OPS=1 (env) OR passing "trace" as the 3rd arg -> report which aten ops ran
# natively on Vortex vs fell back to CPU (spinquant_inference/utils/op_trace.py).
TRACE_OPS="${TRACE_OPS:-0}"
[[ "${3:-}" == "trace" ]] && TRACE_OPS=1
TRACE_FLAG=""
[[ "$TRACE_OPS" == "1" ]] && TRACE_FLAG="--trace-ops"

# Resolve paths relative to this script so the repo can be relocated/renamed.
SPINQUANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_HOME="$(cd "$SPINQUANT_DIR/../.." && pwd)"   # spinquant lives at $VORTEX_HOME/pytorch/spinquant
FPGA_BIN_DIR_DEFAULT="/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin"
CONFIG_FILE="$VORTEX_HOME/configs/improve_th16_tcol32_hwexp_dcache.sh"

srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=32G --time=1:20:00 bash -c '
  set -uo pipefail
  cd "'"$SPINQUANT_DIR"'"

  source /opt/anaconda3/etc/profile.d/conda.sh 2>/dev/null; conda activate vortex 2>/dev/null
  source /opt/xilinx/xrt/setup.sh >/dev/null 2>&1

  # Resolve the granted board to its GLOBAL XRT index (BDF fallback inside cgroup).
  source "'"$VORTEX_HOME"'/ci/xrt_device_detect.sh"
  IDX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)" 2>/dev/null)"
  if [[ -z "$IDX" ]]; then echo "[fatal] no accessible XRT device"; exit 3; fi

  # Compile-time defines matching the bitstream.
  source "'"$CONFIG_FILE"'"; export CONFIGS

  export VORTEX_HOME="'"$VORTEX_HOME"'"
  export CUDA_HOME=/usr/local/cuda-12.8
  export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$VORTEX_HOME/build/runtime:${LD_LIBRARY_PATH:-}"
  export VORTEX_DRIVER=xrt
  export XRT_DEVICE_INDEX="$IDX"
  export XILINX_XRT=/opt/xilinx/xrt
  export XRT_INI_PATH=/dev/null
  export FPGA_BIN_DIR="${FPGA_BIN_DIR:-'"$FPGA_BIN_DIR_DEFAULT"'}"

  echo "[info] XRT_DEVICE_INDEX=$IDX  FPGA_BIN_DIR=$FPGA_BIN_DIR  TRACE_OPS='"$TRACE_OPS"'"
  python -u -m spinquant_inference.generate \
      --model meta-llama/Llama-2-7b-hf \
      --checkpoint bin/consolidated.01.pth \
      --prompt "'"$PROMPT"'" \
      --max_new_tokens '"$MAX_NEW"' \
      --device=vortex --debug='"$DEBUG"' '"$TRACE_FLAG"'
'
