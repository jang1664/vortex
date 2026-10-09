#!/usr/bin/env bash
# Run after reference.py generate and compile-tvm for both model fixtures.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 CONFIGURED_BUILD_DIR TVM_ENVIRONMENT_SH" >&2
  exit 2
fi
script="$(readlink -f "$0")"
build="$(realpath "$1")"
tvm_environment="$(realpath "$2")"
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
  exec srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=00:30:00 \
    bash "$script" "$build" "$tvm_environment"
fi
source "$tvm_environment"
repo="$(realpath "$(dirname "$script")/../../..")"
helper="$repo/tests/regression/llama_decoder_C4/reference.py"
python_exec="${py:-python3}"
alias_name=improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update
source "$repo/ci/xrt_device_detect.sh"
export XRT_DEVICE_INDEX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)")"
export XRT_DEVICE_BDF="$(resolve_xrt_user_bdf "$XRT_DEVICE_INDEX")"
export VORTEX_DRIVER=xrt TARGET=hw XRT_INI_PATH=/dev/null
export XRT_XCLBIN_PATH=/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/bin/vortex_afu.xclbin
export FPGA_BIN_DIR="$(dirname "$XRT_XCLBIN_PATH")"
results="$build/results/final"
mkdir -p "$results"
printf 'job=%s\nbdf=%s\ndevice_index=%s\nxclbin=%s\n' \
  "$SLURM_JOB_ID" "$XRT_DEVICE_BDF" "$XRT_DEVICE_INDEX" "$XRT_XCLBIN_PATH" > "$results/session.txt"
sha256sum "$XRT_XCLBIN_PATH" > "$results/xclbin.sha256"
cd "$build"
for model in llama3 llama2; do
  preset=llama3-8b
  [[ "$model" != llama2 ]] || preset=llama2-7b
  fixture="$build/fixtures/${model}_b1_s32_cpp"
  destination="$results/$model"
  mkdir -p "$destination"
  echo "VERIFY $preset on $XRT_DEVICE_BDF"
  ./ci/run_black.sh hw --no-srun --fpga-bin "$alias_name" --app llama_decoder_C4 \
    --args "--model $preset --batch 1 --seq-len 32 --mode verify --fixture $fixture --output $destination/verify" \
    > "$destination/verify.log" 2>&1
  "$python_exec" -u "$helper" compare --fixture "$fixture" --output "$destination/verify" \
    > "$destination/compare.log" 2>&1
  "$python_exec" -u "$helper" run-tvm --fixture "$fixture" --output "$destination/verify" \
    > "$destination/tvm.log" 2>&1
  echo "FUNCTIONALITY PASS $preset; measuring independent operators and connected decoder"
  for mode in isolated timing; do
    ./ci/run_black.sh hw --no-srun --fpga-bin "$alias_name" --app llama_decoder_C4 \
      --args "--model $preset --batch 1 --seq-len 32 --mode $mode --repetitions 3 --fixture $fixture --output $destination/$mode" \
      > "$destination/$mode.log" 2>&1
  done
done
sha256sum "$build/tests/regression/llama_decoder_C4/kernel.vxbin" > "$results/kernel.sha256"
echo "VALIDATION AND MEASUREMENTS COMPLETE $results"
