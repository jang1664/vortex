#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${repo}/agent-tasks/layout-fused-prefill-opt-20260930/run_hw.sh" final_short
for pattern in zeros constant ties tiny large; do
    for cache in k v; do
        args="-k 17 -n 128 -q 128 -d 1 --input-pattern ${pattern} --emit-correction-qparams"
        if [[ ${cache} == k ]]; then
            args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric'
        else
            args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric'
        fi
        run_case "quant_${cache}_${pattern}" build_layout_final kv_cache_quant_layout_fused_w4a16 "${args}" || true
    done
done
for cache in k v; do
    args='-k 1 -n 128 -q 128 -d 1 --cache-update append --cache-capacity 65536 --cache-position 32768 --emit-correction-qparams'
    if [[ ${cache} == k ]]; then
        args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric'
    else
        args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --source-total-n 4096'
    fi
    run_case "quant_${cache}_append" build_layout_final kv_cache_quant_layout_fused_w4a16 "${args}" || true
done
run_case quant_k_wide_qblk build_layout_final kv_cache_quant_layout_fused_w4a16 \
    '-k 17 -n 130 -q 256 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric --emit-correction-qparams' || true
for args in \
    '-batch 2 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' \
    '-batch 1 -heads 1 -seqq 1 -seqk 1024 -mask 0' \
    '-batch 4 -heads 1 -seqq 1 -seqk 32768 -mask 0' \
    '-batch 64 -heads 1 -seqq 1 -seqk 32768 -mask 0'; do
    run_case "softmax_edge_$(echo "${args}" | tr ' ' '_')" build_layout_final softmax_layout_fused "${args} -scale 1" || true
done
for seq in 1024 4096; do
    for implementation in final standalone; do
        app=softmax_layout_fused
        if [[ ${implementation} == standalone ]]; then app=softmax; fi
        args="-batch 1 -heads 1 -seqq ${seq} -seqk ${seq} -mask 1 -scale 1"
        run_case "verify_softmax_${implementation}_${seq}" build_layout_final "${app}" "${args}" || true
        run_case "perf_softmax_${implementation}_${seq}" build_layout_final "${app}" \
            "${args} --copy-inputs --warmup=1 --iterations=3 --csv --output=${task_dir}/raw/final_short_softmax_${implementation}_${seq}.csv" --bench || true
    done
    for cache in k v; do
        common="-k ${seq} -n 128 -q 128 -d 1"
        if [[ ${cache} == k ]]; then
            common+=' -t 1 --quant-mode spinquant_signed_asymmetric'
            fused=' --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled'
        else
            common+=' -t 0 --quant-mode spinquant_signed_symmetric'
            fused=' --gemm-qdir 1 --layout-from gemm_c_tiled --source-total-n 4096'
        fi
        for implementation in final standalone; do
            app=kv_cache_quant_layout_fused_w4a16
            args="${common}${fused}"
            if [[ ${implementation} == standalone ]]; then app=kv_cache_quant_w4a16; args="${common}"; fi
            run_case "verify_quant_${cache}_${implementation}_${seq}" build_layout_final "${app}" "${args}" || true
            run_case "perf_quant_${cache}_${implementation}_${seq}" build_layout_final "${app}" \
                "${args} --copy-inputs --warmup=1 --iterations=3 --csv --output=${task_dir}/raw/final_short_quant_${cache}_${implementation}_${seq}.csv" --bench || true
        done
    done
done
