#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2 --app elmul --args '-n 4096'
