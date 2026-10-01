#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${repo}/agent-tasks/layout-fused-prefill-opt-20260930/run_hw.sh" final_fixed
for seq in 130 1024 4096; do
  common="-k ${seq} -n 128 -q 128 -d 1 -t 1 --quant-mode spinquant_signed_asymmetric"
  fused=' --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled'
  run_case "verify_quant_k_final_${seq}" build_layout_final kv_cache_quant_layout_fused_w4a16 "${common}${fused}"
  if [[ ${seq} != 130 ]]; then
    for implementation in final standalone; do
      app=kv_cache_quant_layout_fused_w4a16; args="${common}${fused}"
      if [[ ${implementation} == standalone ]]; then app=kv_cache_quant_w4a16; args="${common}"; fi
      run_case "perf_quant_k_${implementation}_${seq}" build_layout_final "${app}" "${args} --copy-inputs --warmup=1 --iterations=3 --csv --output=${task_dir}/raw/final_fixed_quant_k_${implementation}_${seq}.csv" --bench
    done
  fi
done
