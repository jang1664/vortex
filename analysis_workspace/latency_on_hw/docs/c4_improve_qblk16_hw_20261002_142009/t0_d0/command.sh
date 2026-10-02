#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2 --app fpint_gemm_ffn_hw --args '-m 128 -n 256 -k 256 -q 16 -t 0 -d 0 -r 1' --run-only
