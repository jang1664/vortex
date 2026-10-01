#!/bin/bash
set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-dma-ports2-debug-20261001_233758/config_fixed.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1'
