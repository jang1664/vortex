#!/bin/bash
set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c1_c4_softmax_quant_compare_20261002_002513/dma_port_diagnosis/config_dma1.sh
ci/run_black.sh xrt-vcs-sim --app kv_cache_quant_w4a16 --args '-k 128 -n 128 -q 32 -d 1 -t 0 --quant-mode spinquant_signed_symmetric'
