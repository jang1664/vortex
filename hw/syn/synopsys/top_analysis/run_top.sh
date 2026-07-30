#!/bin/bash

python hw/syn/synopsys/top_analysis/run.py --config configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh
python hw/syn/synopsys/top_analysis/run.py --config configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16.sh
python hw/syn/synopsys/top_analysis/run.py --config configs/tcu_th32_f16.sh