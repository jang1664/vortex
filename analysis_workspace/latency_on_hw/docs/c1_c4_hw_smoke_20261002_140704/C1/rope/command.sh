#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin tcu_th16_c1_v2_rev2 --app rope --args '-batch 1 -seq 32 -heads 2 -headdim 64 -maxseq 64 -offset 0'
