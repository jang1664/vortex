#!/usr/bin/env bash
# Diagnostic-only archived stage; restore the observer-free launch on exit.
set -euo pipefail
[[ -f config.mk && -f ci/run_black.reference.sh ]] || exit 1
repo=$(realpath ..)
source "$repo/configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh"
export PATH=/usr/bin:$PATH
export VORTEX_RT_PATH="$PWD/runtime" TARGET=xrtsim_vcs
export LOGIC_FREQ_HZ=100000000 HBM_AXI_FREQ_HZ=450000000
unset LOG_MAX_BYTES GUI U55C_PERFORMANCE_PROFILE
stem=${REFERENCE_TRACE_LABEL:-longk_window}
[[ "$stem" =~ ^[a-zA-Z0-9_-]+$ && ! -e "$stem.log" ]] || exit 2
stage_name=${REFERENCE_STAGE_NAME:-archived-document-longk-trace}
[[ "$stage_name" =~ ^archived-[a-z0-9-]+$ ]] || exit 2
trace_stage="$repo/build_hbm_reference/sim/xrtsim_vcs/$stage_name"
clean_stage="$repo/build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-mul"
for name in simv simv.daidir u55c_model_manifest.json; do
    [[ -L sim/xrtsim_vcs/$name && -e $trace_stage/$name && -e $clean_stage/$name ]] || exit 2
done
[[ -L runtime/libxrtsim_vcs.so && -f $trace_stage/libxrtsim_vcs.so
   && -f $clean_stage/libxrtsim_vcs.so ]] || exit 2
select_stage() {
    for name in simv simv.daidir u55c_model_manifest.json; do
        ln -sfn "$1/$name" "sim/xrtsim_vcs/$name"
    done
    ln -sfn "$1/libxrtsim_vcs.so" runtime/libxrtsim_vcs.so
}
trap 'select_stage "$clean_stage"' EXIT
select_stage "$trace_stage"
app_name=${REFERENCE_APP_NAME:-fpint_gemm_ffn_hw}
[[ "$app_name" =~ ^[a-zA-Z0-9_]+$ ]] || exit 2
app="$repo/build_hbm_reference/tests/regression/$app_name"
sha256sum sim/xrtsim_vcs/simv runtime/libxrtsim_vcs.so \
    sim/xrtsim_vcs/u55c_model_manifest.json \
    "$app/kernel.vxbin" "$app/$app_name" > "${stem}_before.sha256"
set +e
timeout 300 bash ci/run_black.reference.sh xrt-vcs-sim --run-only \
    --app "$app" \
    --args "${REFERENCE_APP_ARGS:--m 16 -n 16 -k 4096 -q 32 -r 1}" > "$stem.log" 2>&1
run_status=$?
set -e
cp --update=none sim/xrtsim_vcs/simv.log "${stem}_simv.log"
sha256sum -c "${stem}_before.sha256"
printf 'workload_exit=%s\n' "$run_status"
exit "$run_status"
