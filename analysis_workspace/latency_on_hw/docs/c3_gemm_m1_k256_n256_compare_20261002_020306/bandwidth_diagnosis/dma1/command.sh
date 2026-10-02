#!/bin/bash
set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c3_gemm_m1_k256_n256_compare_20261002_020306/bandwidth_diagnosis/config_dma1.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1'
