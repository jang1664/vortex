#!/bin/bash

python hw/syn/synopsys/top_analysis/run_subdesign_pnr.py \
    --config configs/improve_th32_tcol32_hwexp_dcache.sh \
    --candidate-config hw/syn/synopsys/top_analysis/C4_subdesign.yaml \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_improve_th32_tcol32_hwexp_dcache_subdesign

python hw/syn/synopsys/top_analysis/run_subdesign_pnr.py \
    --config configs/naive_gemm_th32_tcol32_hwexp_dcache.sh \
    --candidate-config hw/syn/synopsys/top_analysis/C3_subdesign_partial.yaml \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_naive_gemm_th32_tcol32_hwexp_dcache_subdesign_partial \
    --resume

python hw/syn/synopsys/top_analysis/run_subdesign_pnr.py \
    --config configs/tcu_th32_c1_rev2.sh \
    --candidate-config hw/syn/synopsys/top_analysis/C1_subdesign_partial.yaml \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_tcu_th32_c1_rev2_subdesign_partial

python hw/syn/synopsys/top_analysis/run_subdesign_pnr.py \
    --config configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh \
    --candidate-config hw/syn/synopsys/top_analysis/C3_subdesign_partial.yaml \
    --run-dir build/hw/syn/synopsys/top_analysis/Vortex_naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16_subdesign_partial \