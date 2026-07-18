#!/bin/bash

# Synthesis-only configuration for selective-PnR framework validation.
# Keep this close to the known-legal base_t8 setup while omitting optional TCU
# logic; no functionality claim is made by the top-analysis smoke test.
CONFIGS=""
# Four platform banks with two DMA ports keeps BANKS_PER_PORT > 1, which is
# required by the current VX_mem_remap part-select implementation.
CONFIGS+=" -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=4 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DDCACHE_DISABLE -DL2_ENABLE -DNUM_CLUSTERS=1 -DNUM_CORES=1 -DNUM_THREADS=8"
CONFIGS+=" -DNUM_DMA_CHANNELS=2"
# 2^19 bits maps the 64-bit local-memory bank to the supported 8192x64 macro;
# 2^20 would elaborate an unsupported 16384x64 fallback as one million flops.
CONFIGS+=" -DLMEM_LOG_SIZE=19"
CONFIGS+=" -DAFU_DONE_WAIT_CACHE_DRAIN"

export CONFIGS
