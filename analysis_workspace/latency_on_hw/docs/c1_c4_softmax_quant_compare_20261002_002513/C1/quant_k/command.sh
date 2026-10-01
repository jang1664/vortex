#!/bin/bash
set -e
source /tmp/vortex_vector_compare_b5azyy67/source/configs/tcu_th16_c1_v2.sh
ci/run_black.sh xrt-vcs-sim --app kv_cache_quant_w4a16 --args '-k 128 -n 128 -q 32 -d 0 -t 0 --quant-mode spinquant_signed_asymmetric'
