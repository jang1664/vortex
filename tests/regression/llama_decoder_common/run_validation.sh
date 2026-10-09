#!/usr/bin/env bash
# Run a prebuilt candidate app; the existing C++ final-output check is the gate.
set -euo pipefail
candidate= fixture= build= output= python_bin=python3
timing=0 repetitions=3 check_intermediates=0 profile_repetitions=
while (($#)); do
  case "$1" in
    --candidate) candidate=$2; shift 2;;
    --fixture) fixture=$2; shift 2;;
    --build) build=$2; shift 2;;
    --output) output=$2; shift 2;;
    --python) python_bin=$2; shift 2;;
    --timing) timing=1; shift;;
    --check-intermediates) check_intermediates=1; shift;;
    --repetitions) repetitions=$2; shift 2;;
    --profile-repetitions) profile_repetitions=$2; shift 2;;
    *) echo "Usage: $0 --candidate C1|C2|C3 --build DIR --fixture DIR --output DIR [--python PATH] [--timing] [--repetitions 3] [--profile-repetitions N] [--check-intermediates]" >&2; exit 2;;
  esac
done
case "$candidate" in
  C1) alias=tcu_th16_c1_v3_axi_fix;;
  C2) alias=naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix;;
  C3) alias=naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3_axi_fix;;
  *) echo "--candidate C1, C2 or C3 is required" >&2; exit 2;;
esac
[[ -n "$build" && -n "$fixture" && -n "$output" ]] || { echo "Missing required directory argument" >&2; exit 2; }
build=$(realpath "$build")
fixture=$(realpath "$fixture")
mkdir -p "$output"
output=$(realpath "$output")
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -x "$build/tests/regression/llama_decoder_$candidate/llama_decoder_$candidate" ]] || { echo "Build the candidate host and device binaries first" >&2; exit 2; }
declare -A cfg
while read -r name value; do cfg[$name]=$value; done < "$fixture/config.txt"
[[ ${cfg[candidate]:-} == "$candidate" ]] || { echo "Fixture candidate mismatch" >&2; exit 2; }
args=(--model "${cfg[model]}" --batch "${cfg[batch]}" --seq-len "${cfg[seq]}" --fixture "$fixture")
if [[ ${cfg[stage]:-prefill} == decode ]]; then
  args+=(--stage decode --past-kv-len "${cfg[past_kv]}" --cache-capacity "${cfg[cache_capacity]}")
fi
run_case() {
  local mode=$1 destination=$2 argument_string
  local run_args=("${args[@]}" --mode "$mode" --output "$destination" --repetitions "$repetitions")
  if [[ -n "$profile_repetitions" ]]; then run_args+=(--profile-repetitions "$profile_repetitions"); fi
  printf -v argument_string '%q ' "${run_args[@]}"
  (cd "$build" && ./ci/run_black.sh hw --fpga-bin "$alias" --app "llama_decoder_$candidate" --run-only --args "$argument_string")
}
mode=verify
if ((timing)); then mode=timing; fi
status=0
# Timing mode already verifies its preflight and final timed output in C++.
# Avoid executing a duplicate verify graph before that built-in check.
run_case "$mode" "$output/$mode" > "$output/$mode.log" 2>&1 || status=$?
printf '%s\n' "$status" > "$output/$mode.exit"
if ((check_intermediates)); then
  diagnostic_status=0
  "$python_bin" "$source_dir/reference.py" compare --fixture "$fixture" --output "$output/$mode" > "$output/${mode}_intermediates.log" 2>&1 || diagnostic_status=$?
  printf '%s\n' "$diagnostic_status" > "$output/${mode}_intermediates.exit"
  if ((diagnostic_status)); then
    echo "Intermediate diagnostic did not pass; see $output/${mode}_intermediates.log (does not change the final-output gate)." >&2
  fi
fi
if ((status)); then echo "FAIL: see $output/$mode.log" >&2; exit "$status"; fi
echo "PASS: $candidate final output ($output/$mode)"
