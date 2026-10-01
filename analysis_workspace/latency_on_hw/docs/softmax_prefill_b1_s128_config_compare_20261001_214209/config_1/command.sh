#!/bin/bash
set -e
source /tmp/vortex_softmax_compare_j_ndwifz/source/configs/tcu_th16_c1.sh
ci/run_black.sh xrt-vcs-sim --app softmax --args '-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1'
