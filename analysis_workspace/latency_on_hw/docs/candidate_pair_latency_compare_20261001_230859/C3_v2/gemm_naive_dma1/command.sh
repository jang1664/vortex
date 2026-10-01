#!/bin/bash
set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/candidate_pair_latency_compare_20261001_230859/C3_v2/config_dma1_diagnostic.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1'
