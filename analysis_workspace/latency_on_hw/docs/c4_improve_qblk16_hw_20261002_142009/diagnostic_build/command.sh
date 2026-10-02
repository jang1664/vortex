#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
bash -c 'set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh
make -B -C /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/tests/regression/fpint_gemm_ffn_hw TARGET=hw fpint_gemm_ffn_hw SRC_DIR=/tmp/vortex_improve_qblk16_rbfz59v7/fpint_gemm_ffn_hw'
