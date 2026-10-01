#!/bin/bash
set -e
source /tmp/vortex_c3_assert_8r9z37bq/source/configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 128 -n 256 -k 256 -q 32 -t 1 -d 0 -r 1'
