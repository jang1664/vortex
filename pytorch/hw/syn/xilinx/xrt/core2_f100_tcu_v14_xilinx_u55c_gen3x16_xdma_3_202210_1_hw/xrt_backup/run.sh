#!/bin/bash

set -o pipefail

export PREFIX=core2_f100_tcu_v14
export PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1
export NUM_CORES=2
export CONFIGS="-DEXT_TCU_ENABLE -DAFU_DONE_WAIT_CACHE_DRAIN -DASYNC_BRAM_PATCH"
export TARGET=hw
export CLOCK_FREQ_HZ=100
export MAX_JOBS=16
export DEBUG=1
export PROFILE=1
mkdir -p ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}
make 2>&1 | tee ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}/build.log

export PREFIX=core2_f100_tcu_v15
export PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1
export NUM_CORES=2
export CONFIGS="-DEXT_TCU_ENABLE -DAFU_DONE_WAIT_CACHE_DRAIN"
export TARGET=hw
export CLOCK_FREQ_HZ=100
export MAX_JOBS=16
export DEBUG=1
export PROFILE=1
mkdir -p ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}
make 2>&1 | tee ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}/build.log