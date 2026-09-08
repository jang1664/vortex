#!/usr/bin/env bash
set -euo pipefail
[[ -n "${SLURM_JOB_ID:-}" && -f config.mk ]] || exit 1
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
export PATH=/usr/bin:$PATH
unset VORTEX_RT_PATH TARGET U55C_PERFORMANCE_PROFILE
report_dir="$PWD/hardware-phase-${SLURM_JOB_ID}"
mkdir -p "$report_dir"
sha256sum tests/regression/reference_phase/{reference_phase,kernel.vxbin} > "$report_dir/before.sha256"
for polls in 1 256; do
    for rep in 0 1 2 3 4 5; do
        timeout 300 bash ci/run_black.sh hw --fpga-bin temp --app reference_phase \
            --args "$polls" > "$report_dir/phase${polls}_${rep}.log" 2>&1
        /opt/xilinx/xrt/bin/xrt-smi examine --device 0000:2a:00.1 \
            --report platform dynamic-regions memory --format JSON \
            --output "$report_dir/phase${polls}_${rep}_board.json" > "$report_dir/phase${polls}_${rep}_board.log" 2>&1
        echo "Completed polls=$polls repetition=$rep (zero is warm-up)"
    done
done
sha256sum -c "$report_dir/before.sha256"
echo "Reports: $report_dir"
