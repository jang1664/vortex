#!/usr/bin/env bash
# One board warm-up plus five fresh-process samples per preselected smoke case.
set -euo pipefail
[[ -n "${SLURM_JOB_ID:-}" && -f config.mk && -f ci/run_black.sh ]] || exit 1
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
export PATH=/usr/bin:$PATH
unset VORTEX_RT_PATH TARGET U55C_PERFORMANCE_PROFILE
report_dir="$PWD/hardware-repeats-${SLURM_JOB_ID}"
mkdir -p "$report_dir"
sha256sum tests/regression/fpint_gemm_ffn_hw/{fpint_gemm_ffn_hw,kernel.vxbin} > "$report_dir/before.sha256"
case "${REFERENCE_CASE_SET:-smoke}" in
    smoke) cases=("16 16 16 16" "64 16 16 64") ;;
    explore) cases=("16x16x256 16 16 256" "64x64x64 64 64 64") ;;
    poll) cases=("poll1 16 16 16 1" "poll256 16 16 16 256") ;;
    longk) cases=("16x16x4096 16 16 4096") ;;
    heldout) cases=("16x16x1024 16 16 1024" "64x64x256 64 64 256" "128x128x64 128 128 64") ;;
    *) echo "Unknown case set" >&2; exit 1 ;;
esac
for shape in "${cases[@]}"; do
    read -r label m n k poll <<< "$shape"
    extra=""
    [[ -z "$poll" ]] || extra="--pol $poll"
    for rep in 0 1 2 3 4 5; do
        timeout 300 bash ci/run_black.sh hw --fpga-bin temp --app fpint_gemm_ffn_hw \
            --args "-m $m -n $n -k $k -q 32 -r 1 $extra" > "$report_dir/gemm${label}_${rep}.log" 2>&1
        /opt/xilinx/xrt/bin/xrt-smi examine --device 0000:2a:00.1 \
            --report platform dynamic-regions memory --format JSON \
            --output "$report_dir/gemm${label}_${rep}_board.json" > "$report_dir/gemm${label}_${rep}_board.log" 2>&1
        echo "Completed M=$m N=$n K=$k repetition=$rep (zero is warm-up)"
    done
done
sha256sum -c "$report_dir/before.sha256"
echo "Reports: $report_dir"
