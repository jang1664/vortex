#!/bin/bash
set -e
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build
ci/run_black.sh hw --fpga-bin tcu_th16_c1_v2_rev2 --app softmax --args '-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1'
