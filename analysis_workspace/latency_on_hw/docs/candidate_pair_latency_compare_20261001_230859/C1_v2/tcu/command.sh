#!/bin/bash
set -e
source /tmp/vortex_candidate_pair__k9ghv_g/source/configs/tcu_th16_c1_v2.sh
ci/run_black.sh xrt-vcs-sim --app sgemm_tcu --args '-m 128 -n 128 -k 256'
