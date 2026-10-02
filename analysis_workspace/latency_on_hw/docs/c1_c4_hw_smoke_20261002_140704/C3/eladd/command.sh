#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2 --app eladd --args '-n 4096'
