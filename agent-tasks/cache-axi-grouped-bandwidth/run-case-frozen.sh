#!/usr/bin/bash
# Run one reproducible case from an already configured build directory.
# Usage: run-case.sh BUILD PROFILE K CASE ATTEMPT [TIMEOUT_SECONDS]
# PROFILE: improve|naive; K: baseline|default|1|2; CASE: vecadd|softmax|small|large.
set -euo pipefail
task_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$task_dir/../.." && pwd)
build_dir=$1
profile=$2
transport=$3
test_case=$4
attempt=$5
limit=${6:-300}
case "$profile" in
    improve) source "$repo_dir/configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm8_tmem8.sh" ;;
    naive)
        source "$repo_dir/configs/naive_gemm_th16_tcol32_hwexp_dcache.sh"
        # Current naive split-PSUM implementation requires twice 16 PSUM lanes.
        CONFIGS+=" -DNUM_HBM_PORTS=8 -DLMEM_NUM_PORTS=32 -DLMEM_NUM_BANKS=32"
        export CONFIGS
        ;;
    *) exit 2 ;;
esac
case "$test_case" in
    vecadd) app=vecadd; perf=1; app_args='-n 4096' ;;
    softmax)
        app=softmax; perf=1
        export SOFTMAX_VARIANT=rev2_shuffle_grouped
        app_args='-batch 1 -heads 2 -seqq 16 -seqk 128 -mask 1'
        ;;
    small|large)
        app=fpint_gemm_ffn_hw
        if [[ "$profile" == naive ]]; then app+=_naive; fi
        perf=3
        if [[ "$test_case" == small ]]; then
            app_args='-m 32 -n 32 -k 128 -q 32 -t 0 -d 0'
        else
            app_args='-m 256 -n 256 -k 256 -q 32 -t 0 -d 0'
        fi
        ;;
    *) exit 2 ;;
esac
cd -- "$build_dir"
test -f config.mk
if [[ "$transport" == baseline ]]; then
    frozen_rtl="$repo_dir/build-cache-axi-baseline/frozen-rtl"
    test -d "$frozen_rtl"
    export MAKEFLAGS="${MAKEFLAGS:-} RTL_DIR=$frozen_rtl"
fi
run_dir="$task_dir/logs/$profile-$transport/$test_case-$attempt"
if [[ -e "$run_dir" ]]; then
    echo "Refusing to overwrite existing run: $run_dir" >&2
    exit 2
fi
mkdir -p "$run_dir"
cmd=(ci/run_black.sh xrt-vcs-sim --perf "$perf" --app "$app" --args "$app_args")
case "$transport" in
    baseline|default) ;;
    1|2) cmd+=(--configs-extra "-DNUM_BANKS_OUT=$transport") ;;
    *) exit 2 ;;
esac
printf '%q ' "${cmd[@]}" > "$run_dir/command.txt"
printf '\n' >> "$run_dir/command.txt"
printf '%s\n' "$CONFIGS" > "$run_dir/base-configs.txt"
git -C "$repo_dir" rev-parse HEAD > "$run_dir/revision.txt"
git -C "$repo_dir" diff -- hw/rtl > "$run_dir/rtl.patch"
if [[ "$transport" == baseline ]]; then
    printf '%s\n' "$frozen_rtl" > "$run_dir/rtl-source.txt"
    cp -- "$task_dir/baseline-rtl-sha256.json" "$run_dir/rtl-sha256.json"
    cp -- "$task_dir/baseline-prerequisites.patch" "$run_dir/rtl.patch"
else
    printf '%s\n' "$repo_dir/hw/rtl" > "$run_dir/rtl-source.txt"
fi
env | LC_ALL=C sort | sed -n '/^DRAM_/p; /^CACHE_/p; /^SOFTMAX_/p' > "$run_dir/model-env.txt"
date --iso-8601=seconds > "$run_dir/start.txt"
set +e
timeout "$limit" "${cmd[@]}" > "$run_dir/wrapper.log" 2>&1
result=$?
set -e
printf '%s\n' "$result" > "$run_dir/exit.txt"
date --iso-8601=seconds > "$run_dir/end.txt"
for log in sim/xrtsim_vcs/*.log sim/xrtsim_vcs/u55c_model_manifest.json; do
    if [[ -f "$log" ]]; then cp -- "$log" "$run_dir/"; fi
done
printf '%s: exit=%s logs=%s\n' "$test_case" "$result" "$run_dir"
exit "$result"
