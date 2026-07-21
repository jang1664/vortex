#!/usr/bin/env bash
# Run one strict-native SpinQuant layer, decode, or decoder-stack case on U55C.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 5 ]]; then
  echo "Usage: $0 CASE_DIR OUTPUT_DIR [STOP_AFTER] [PHYSICAL_PLAN] [DECODE_STEP_OR_STACK_LAYER]" >&2
  exit 2
fi

SPINQUANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_HOME="$(cd "$SPINQUANT_DIR/../.." && pwd)"
CASE_DIR="$(realpath "$1")"
OUTPUT_DIR="$(realpath -m "$2")"
STOP_AFTER="${3:-final_residual}"
PHYSICAL_PLAN="${4:-standalone}"
DECODE_STEP="${5:-}"
if [[ "$PHYSICAL_PLAN" != "standalone" && "$PHYSICAL_PLAN" != "fused" ]]; then
  echo "[fatal] PHYSICAL_PLAN must be standalone or fused" >&2
  exit 2
fi
CONFIG_FILE="$VORTEX_HOME/configs/improve_th16_tcol32_hwexp_dcache.sh"
FPGA_BIN_DIR_DEFAULT="/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/bin"

if [[ ! -f "$CASE_DIR/manifest.json" || ! -f "$CASE_DIR/tensors.pt" ]]; then
  echo "[fatal] invalid layer case: $CASE_DIR" >&2
  exit 2
fi

export LAYER_SPINQUANT_DIR="$SPINQUANT_DIR"
export LAYER_VORTEX_HOME="$VORTEX_HOME"
export LAYER_CASE_DIR="$CASE_DIR"
export LAYER_OUTPUT_DIR="$OUTPUT_DIR"
export LAYER_STOP_AFTER="$STOP_AFTER"
export LAYER_PHYSICAL_PLAN="$PHYSICAL_PLAN"
export LAYER_DECODE_STEP="$DECODE_STEP"
export LAYER_CONFIG_FILE="$CONFIG_FILE"
export LAYER_FPGA_BIN_DEFAULT="$FPGA_BIN_DIR_DEFAULT"

srun -p fpga --gres=fpga:u55c:1 --cpus-per-task=4 --mem=32G --time=1:20:00 \
  bash -c '
    set -euo pipefail
    cd "$LAYER_SPINQUANT_DIR"
    source /opt/anaconda3/etc/profile.d/conda.sh
    conda activate vortex
    source /opt/xilinx/xrt/setup.sh >/dev/null 2>&1
    source "$LAYER_VORTEX_HOME/ci/xrt_device_detect.sh"
    IDX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)")"
    if [[ -z "$IDX" ]]; then
      echo "[fatal] no accessible XRT device" >&2
      exit 3
    fi

    source "$LAYER_CONFIG_FILE"
    export CONFIGS
    export VORTEX_HOME="$LAYER_VORTEX_HOME"
    export PYTHONPATH="$LAYER_SPINQUANT_DIR:$LAYER_VORTEX_HOME/pytorch${PYTHONPATH:+:$PYTHONPATH}"
    export VORTEX_DRIVER=xrt
    export XRT_DEVICE_INDEX="$IDX"
    export XILINX_XRT=/opt/xilinx/xrt
    export XRT_INI_PATH=/dev/null
    export FPGA_BIN_DIR="${FPGA_BIN_DIR:-$LAYER_FPGA_BIN_DEFAULT}"
    export TORCH_VORTEX_STRICT_NATIVE=1
    # Opt in with TORCH_VORTEX_KERNEL_DEBUG=1 when a slow/hung hardware run
    # needs to be attributed to an exact layout/compute kernel.
    export TORCH_VORTEX_KERNEL_DEBUG="${TORCH_VORTEX_KERNEL_DEBUG:-0}"

    CASE_KIND="$(python -c "import json,sys; print(json.load(open(sys.argv[1])).get(\"case_kind\", \"layer\"))" "$LAYER_CASE_DIR/manifest.json")"
    DECODE_ARGS=()
    if [[ -n "$LAYER_DECODE_STEP" ]]; then
      if [[ "$CASE_KIND" == "decoder_stack" ]]; then
        DECODE_ARGS=(--stop-after-layer "$LAYER_DECODE_STEP")
      else
        DECODE_ARGS=(--decode-step "$LAYER_DECODE_STEP")
      fi
    fi
    echo "[info] device=$XRT_DEVICE_INDEX case_kind=$CASE_KIND stop_after=$LAYER_STOP_AFTER step_or_layer=${LAYER_DECODE_STEP:-n/a} physical_plan=$LAYER_PHYSICAL_PLAN output=$LAYER_OUTPUT_DIR"
    python -u -m spinquant_inference.layer_accuracy run \
      --case "$LAYER_CASE_DIR" \
      --backend vortex \
      --stop-after "$LAYER_STOP_AFTER" \
      --capture both \
      --physical-plan "$LAYER_PHYSICAL_PLAN" \
      --strict-native \
      "${DECODE_ARGS[@]}" \
      --output "$LAYER_OUTPUT_DIR"
  '
