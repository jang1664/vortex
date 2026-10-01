#!/bin/bash
set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c1_c4_softmax_quant_compare_20261002_002513/dma_port_diagnosis/config_dma1.sh
ci/run_black.sh xrt-vcs-sim --app softmax --args '-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1'
