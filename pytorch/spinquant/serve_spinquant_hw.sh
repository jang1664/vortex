#!/usr/bin/env bash
#
# serve_spinquant_hw.sh — persistent SpinQuant inference on the REAL U55C FPGA.
#
# Loads the 7B model ONCE onto the board, then reads prompts interactively so
# every generation after the first reuses the on-device weights (no reload).
# Same environment as run_spinquant_hw.sh (device-index detector, XRT_INI=/dev/null
# to dodge the XDP-plugin segfault, sourced bitstream config, kernel prewarm).
#
# Usage:
#   ./serve_spinquant_hw.sh                 # max_new_tokens=1 (default)
#   ./serve_spinquant_hw.sh 20              # 20 new tokens per prompt
# Then type one prompt per line; blank line / "quit" / Ctrl-D exits.
#
# Runs through srun --pty so stdin is a real terminal. Hold the allocation for as
# long as you want to keep the model resident; exiting frees the board.

set -uo pipefail

MAX_NEW="${1:-1}"
DEBUG="${DEBUG:-1}"

# Resolve paths relative to this script so the repo can be relocated/renamed.
SPINQUANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_HOME="$(cd "$SPINQUANT_DIR/../.." && pwd)"   # spinquant lives at $VORTEX_HOME/pytorch/spinquant
FPGA_BIN_DIR_DEFAULT="/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin"
CONFIG_FILE="$VORTEX_HOME/configs/improve_th16_tcol32_hwexp_dcache.sh"

srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=32G --time=4:00:00 --pty bash -c '
  set -uo pipefail
  cd "'"$SPINQUANT_DIR"'"

  source /opt/anaconda3/etc/profile.d/conda.sh 2>/dev/null; conda activate vortex 2>/dev/null
  source /opt/xilinx/xrt/setup.sh >/dev/null 2>&1

  source "'"$VORTEX_HOME"'/ci/xrt_device_detect.sh"
  IDX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)" 2>/dev/null)"
  if [[ -z "$IDX" ]]; then echo "[fatal] no accessible XRT device"; exit 3; fi

  source "'"$CONFIG_FILE"'"; export CONFIGS
  export VORTEX_HOME="'"$VORTEX_HOME"'"
  export CUDA_HOME=/usr/local/cuda-12.8
  export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$VORTEX_HOME/build/runtime:${LD_LIBRARY_PATH:-}"
  export VORTEX_DRIVER=xrt
  export XRT_DEVICE_INDEX="$IDX"
  export XILINX_XRT=/opt/xilinx/xrt
  export XRT_INI_PATH=/dev/null
  export FPGA_BIN_DIR="${FPGA_BIN_DIR:-'"$FPGA_BIN_DIR_DEFAULT"'}"

  echo "[info] XRT_DEVICE_INDEX=$IDX  FPGA_BIN_DIR=$FPGA_BIN_DIR"
  python -u -m spinquant_inference.serve_spinquant \
      --model meta-llama/Llama-2-7b-hf \
      --checkpoint bin/consolidated.01.pth \
      --device=vortex --max_new_tokens '"$MAX_NEW"' --debug '"$DEBUG"'
'
