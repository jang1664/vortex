#!/usr/bin/env bash
# CPU-only preparation; no hardware or simulation is launched.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 CONFIGURED_BUILD TVM_ENVIRONMENT_SH [MANIFEST]" >&2
  exit 2
fi
attention_repo="$(realpath "$(dirname "$0")/../../..")"
attention_build="$(realpath "$1")"
attention_env="$(realpath "$2")"
attention_manifest="${3:-/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_cc4901d20c/manifest.json}"
source "$attention_env"
attention_python="${py:-python3}"
attention_root="$attention_build/fixtures/resident_attention"
mkdir -p "$attention_root/logs"
generate() {
  local name="$1"
  shift
  if [[ -f "$attention_root/$name/fixture.json" ]]; then
    echo "EXISTS $name"
    return
  fi
  echo "GENERATE $name"
  "$attention_python" -u "$attention_repo/tests/regression/llama_decoder_C4/reference.py" \
    generate --fixture "$attention_root/$name" --manifest "$attention_manifest" "$@" \
    > "$attention_root/logs/$name.log" 2>&1
  echo "READY $name"
}
for model in llama3-8b llama2-7b; do
  for seq in 16 128; do
    generate "${model}_prefill${seq}" --model "$model" --batch 1 --seq-len "$seq"
  done
  for capacity in 32 160 256; do
    past=128
    [[ "$capacity" != 32 ]] || past=16
    generate "${model}_decode_p${past}_c${capacity}" --model "$model" --batch 1 --seq-len 1 \
      --decoder-stage decode --past-kv-len "$past" --cache-capacity "$capacity" \
      --past-fixture "$attention_root/${model}_prefill${past}"
  done
done
generate llama3-8b_prefill144 --model llama3-8b --batch 1 --seq-len 144
echo "READY all resident attention fixtures: $attention_root"
