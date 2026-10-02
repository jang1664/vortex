#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2 --app fpint_gemm_ffn_hw_naive --args '-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1'
