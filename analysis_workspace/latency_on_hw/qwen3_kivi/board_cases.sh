#!/usr/bin/env bash
# Sourced by reproduce.sh inside the configured C4 build and U55C allocation.
while IFS='|' read -r app opts; do
  "$VORTEX_HOME/ci/run_black.sh" hw --no-srun --fpga-bin "$fpga_alias" --app "$app" --args "$opts" < /dev/null
done <<'CASES'
rmsnorm|-batch 1 -seq 32 -hidden 128 --tiled-heads 32
rmsnorm|-batch 4 -seq 8 -hidden 128 --tiled-heads 8
kv_cache_quant_w4a16|-k 1 -n 128 -q 32 -d 0 -t 1 --quant-mode kivi_int_zp --kivi-update-key
kv_cache_quant_w4a16|-k 19 -n 128 -q 32 -d 0 -t 1 --quant-mode kivi_int_zp --kivi-update-key
kv_cache_quant_w4a16|-k 1 -n 128 -q 32 -d 1 -t 0 --quant-mode kivi_int_zp
kv_cache_quant_layout_fused_w4a16|-k 64 -n 128 -q 32 -d 0 -t 1 --source-transposed --gemm-qdir 1 --quant-mode kivi_int_zp
kv_cache_quant_layout_fused_w4a16|-k 64 -n 128 -q 32 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --source-total-n 1024 --quant-mode kivi_int_zp
kv_cache_quant_layout_fused_w4a16|-k 1 -n 128 -q 32 -d 0 -t 1 --source-transposed --gemm-qdir 1 --quant-mode kivi_int_zp --cache-update append --cache-capacity 384 --cache-position 128
kv_cache_quant_layout_fused_w4a16|-k 19 -n 128 -q 32 -d 0 -t 1 --source-transposed --gemm-qdir 1 --quant-mode kivi_int_zp --cache-update append --cache-capacity 384 --cache-position 178
kv_cache_quant_layout_fused_w4a16|-k 1 -n 128 -q 32 -d 1 -t 0 --gemm-qdir 1 --quant-mode kivi_int_zp --cache-update append --cache-capacity 384 --cache-position 178 --layout-from gemm_c_tiled --source-total-k 8 --source-total-n 1024 --head-col-offset 128
CASES
