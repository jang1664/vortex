#!/usr/bin/env bash

# Current WLOAD4 production configuration with the response payload storage
# selections overridden explicitly to FF for reproducible A/B comparisons.
DPRAM_TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${DPRAM_TASK_ROOT}/configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh"
CONFIGS+=" -DI_LMEM_DMA_RESPONSE_DATA_RAM=0 -DW_LMEM_DMA_RESPONSE_DATA_RAM=0"
CONFIGS+=" -DSZ_LMEM_DMA_RESPONSE_DATA_RAM=0 -DW_TMEM_WIDE_RESPONSE_DATA_RAM=0"
unset DPRAM_TASK_ROOT
export CONFIGS
