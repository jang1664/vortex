#!/usr/bin/env bash
# Archived executables only; temporary launch links restored even on failure.
set -euo pipefail
[[ -f config.mk && -f ci/run_black.reference.sh ]] || exit 1
repo=$(realpath ..)
source "$repo/configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh"
export PATH=/usr/bin:$PATH
export VORTEX_RT_PATH="$PWD/runtime"
export TARGET=xrtsim_vcs LOGIC_FREQ_HZ=100000000 HBM_AXI_FREQ_HZ=450000000
unset LOG_MAX_BYTES GUI U55C_PERFORMANCE_PROFILE
select_stage() {
    local selected="$repo/build_hbm_reference/sim/xrtsim_vcs/archived-$1-guarded-mul"
    for name in simv simv.daidir u55c_model_manifest.json; do
        [[ -L sim/xrtsim_vcs/$name && -e $selected/$name ]] || return 1
        ln -sfn "$selected/$name" "sim/xrtsim_vcs/$name"
    done
    [[ -L runtime/libxrtsim_vcs.so && -f $selected/libxrtsim_vcs.so ]] || return 1
    ln -sfn "$selected/libxrtsim_vcs.so" runtime/libxrtsim_vcs.so
}
trap 'select_stage document' EXIT
case_set=${REFERENCE_CASE_SET:-explore}
case "$case_set" in
    explore) shapes=('16 16 256' '64 64 64') ;;
    poll) shapes=('16 16 16 1' '16 16 16 256') ;;
    *) echo "Unknown case set" >&2; exit 1 ;;
esac
for mode in baseline document; do
    select_stage "$mode"
    sha256sum sim/xrtsim_vcs/simv runtime/libxrtsim_vcs.so sim/xrtsim_vcs/u55c_model_manifest.json \
        "$repo/build_hbm_reference/tests/regression/fpint_gemm_ffn_hw/kernel.vxbin" \
        "$repo/build_hbm_reference/tests/regression/fpint_gemm_ffn_hw/fpint_gemm_ffn_hw" > "${case_set}_${mode}_before.sha256"
    for shape in "${shapes[@]}"; do
        read -r m n k poll <<< "$shape"
        extra=""
        [[ -z "$poll" ]] || extra="--pol $poll"
        for rep in 1 2; do
            stem="explore_${mode}_gemm${m}x${n}x${k}_${rep}"
            [[ -z "$poll" ]] || stem="poll_${mode}_${poll}_${rep}"
            [[ ! -e $stem.log ]] || { echo "Refusing to overwrite $stem.log" >&2; exit 1; }
            timeout 300 bash ci/run_black.reference.sh xrt-vcs-sim --run-only \
                --app "$repo/build_hbm_reference/tests/regression/fpint_gemm_ffn_hw" \
                --args "-m $m -n $n -k $k -q 32 -r 1 $extra" > "$stem.log" 2>&1
            cp --update=none sim/xrtsim_vcs/simv.log "${stem}_simv.log"
            echo "Completed $stem"
        done
    done
    sha256sum -c "${case_set}_${mode}_before.sha256"
done
