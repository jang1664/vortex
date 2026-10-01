#!/bin/bash
set -e
source /tmp/vortex_softmax_compare_j_ndwifz/source/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh
ci/run_black.sh xrt-vcs-sim --app softmax --args '-batch 1 -heads 1 -seqq 1024 -seqk 1024 -seqk-stride 1024 -mask 1'
