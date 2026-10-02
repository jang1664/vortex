#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2 --app kv_cache_quant_w4a16 --args '-k 128 -n 128 -q 32 -d 1 -t 0 --quant-mode spinquant_signed_symmetric'
