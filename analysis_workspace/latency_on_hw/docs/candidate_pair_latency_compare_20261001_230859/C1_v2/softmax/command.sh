#!/bin/bash
set -e
source /tmp/vortex_candidate_pair__k9ghv_g/source/configs/tcu_th16_c1_v2.sh
ci/run_black.sh xrt-vcs-sim --app softmax --args '-batch 1 -heads 1 -seqq 256 -seqk 256 -seqk-stride 256 -mask 1'
