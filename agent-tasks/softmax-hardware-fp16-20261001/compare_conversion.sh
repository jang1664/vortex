#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
task="${repo}/agent-tasks/softmax-hardware-fp16-20261001"
source "${repo}/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh"
export XILINX_XRT=/opt/xilinx/xrt
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
mkdir -p "${task}/logs" "${task}/raw"
restore_kernels() {
    for app in softmax softmax_layout_fused; do
        cp "${task}/hardware_binaries/${app}/kernel.vxbin" "${repo}/build_layout_final/tests/regression/${app}/kernel.vxbin"
    done
}
trap restore_kernels EXIT
cd "${repo}/build_layout_final"
for policy in preserving hardware; do
    for app in softmax softmax_layout_fused; do
        cp "${task}/${policy}_binaries/${app}/kernel.vxbin" "tests/regression/${app}/kernel.vxbin"
        for seq in 1024 4096 16384 32768; do
            iterations=3; warmup=1
            if (( seq >= 16384 )); then iterations=1; warmup=0; fi
            label="${policy}_${app}_${seq}"
            timeout --kill-after=15s 900s ci/run_black.sh hw \
                --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_v2 \
                --run-only --bench --app "${app}" \
                --args "-batch 1 -heads 1 -seqq ${seq} -seqk ${seq} -mask 1 -scale 1 --copy-inputs --warmup=${warmup} --iterations=${iterations} --csv --output=${task}/raw/${label}.csv" \
                > "${task}/logs/${label}.log" 2>&1
            printf 'Completed %s\n' "${label}"
        done
    done
done
restore_kernels
for app in softmax softmax_layout_fused; do
    for spec in '19 33 40' '1024 1024 1024' '3 65537 65552'; do
        read -r q k stride <<< "${spec}"
        mask=1
        if (( k > 65536 )); then mask=0; fi
        timeout --kill-after=15s 300s ci/run_black.sh hw \
            --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_v2 \
            --run-only --app "${app}" \
            --args "-batch 1 -heads 1 -seqq ${q} -seqk ${k} -seqk-stride ${stride} -mask ${mask} -scale 1" \
            > "${task}/logs/verify_${app}_${q}_${k}.log" 2>&1
        printf 'Verified %s Q=%s K=%s\n' "${app}" "${q}" "${k}"
    done
done
