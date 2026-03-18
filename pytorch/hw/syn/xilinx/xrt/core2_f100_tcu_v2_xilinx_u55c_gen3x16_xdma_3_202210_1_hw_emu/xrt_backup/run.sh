#!/bin/bash

set -o pipefail

export PREFIX=core1_f100_tcu
export PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1
export NUM_CORES=1
export CONFIGS="-DEXT_TCU_ENABLE -DAFU_DONE_WAIT_CACHE_DRAIN"
export TARGET=hw
export CLOCK_FREQ_HZ=100
export MAX_JOBS=16
export DEBUG=1
export PROFILE=1
mkdir -p ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}
make 2>&1 | tee ${PREFIX}_xilinx_u55c_gen3x16_xdma_3_202210_1_${TARGET}/build.log